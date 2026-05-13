#!/usr/bin/env python3
"""
builder-api — a project-agnostic HTTP daemon for build / run / logs /
events, designed to be called by the Docker container (Claude, OpenCode)
running on the host via host.docker.internal.

Boot flow (`python3 server.py --project <name>`):

    1. config.load(project)     → read ~/.llm-docker/builder-api.toml,
                                  resolve global + language + project view
    2. events.EventStore(...)   → open jsonl feed (or no-op if disabled)
    3. BuildQueue(...).start()  → spawn worker thread
    4. RuntimeManager(...)      → track /run process
    5. SizeLimits + AuthGate    → per-request clamps + auth
    6. ThreadingHTTPServer(...) → bind and serve_forever
    7. SIGINT/SIGTERM handler   → shut down queue + runtime, exit clean

The handler is intentionally flat: one `dispatch()` per method, one
small per-endpoint function. No decorators, no framework magic.
"""

from __future__ import annotations

import json
import os
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, urlsplit

# When run directly (__name__ == "__main__"), the package isn't on sys.path;
# add the script's directory so sibling modules import without packaging.
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import banner as _banner                       # noqa: E402
import config as _config                       # noqa: E402
from build_queue import BuildQueue, QueueFull  # noqa: E402
from events import EventStore                  # noqa: E402
import jobs as _jobs                           # noqa: E402
from logs import LogStore                      # noqa: E402
from runtime import RuntimeManager             # noqa: E402
from security import AuthGate, HTTPReject, SizeLimits  # noqa: E402
from ws import handle_ws_upgrade               # noqa: E402


# No-op lifecycle callbacks. The plugin feature was dropped (security: a
# plugin file in container-writable paths was a host-exec escape vector).
# Build/runtime callbacks remain in the API for future use but default to
# no-ops; nothing in the host config can register handlers.
def _noop(*_args, **_kwargs) -> None:
    return None


# Paths for which we emit CORS headers. Anything else gets bare responses so
# browsers block cross-origin writes from random pages (CSRF defense in depth
# on top of the password requirement). `/log` is the one endpoint designed to
# be hit by a browser; OPTIONS is the CORS preflight itself.
_CORS_ALLOWED_PATHS = frozenset({"/log"})


# ---------------------------------------------------------------------------
# AppContext holds every subsystem. Attached to the handler class so each
# request can reach state without a module-level global.
# ---------------------------------------------------------------------------


class AppContext:
    def __init__(self, cfg) -> None:
        self.cfg = cfg
        self.start_ts = time.time()

        self.events = EventStore(
            cfg.events.path,
            max_bytes=cfg.events.max_bytes,
            drop_bytes=cfg.events.drop_bytes,
        )
        self.log_store = LogStore(cfg.log_aliases)
        self.size_limits = SizeLimits(cfg)
        self.auth = AuthGate(cfg, self.events.append)

        self.runtime = RuntimeManager(
            cfg, self.events,
            on_run_start=_noop, on_run_exit=_noop,
        )
        self.build_queue = BuildQueue(
            cfg, self.events,
            on_build_start=_noop, on_build_finish=_noop,
        )
        self.build_queue.start()

        # Live event tail: every EventStore.append() surfaces as one
        # colored line on stderr. Subscribed BEFORE the first event so
        # `server_started` lands in the user's view too.
        self.events.subscribe(_banner.event_line)

        # NO hot-reload of the host toml. v2.4.x removed the
        # ConfigWatcher subsystem entirely. The cage's job surface only
        # grows on a deliberate operator action (kill + relaunch the
        # daemon) — never silently via a file write. Rationale: an
        # in-container agent that gets a splice script run on the host
        # would otherwise widen the exec surface mid-session. With no
        # hot-reload, the banner's startup job list IS the audit
        # checkpoint; nothing new can sneak in between restarts.

    def shutdown(self) -> None:
        self.build_queue.shutdown()
        self.runtime.shutdown()


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------


class BuilderHandler(BaseHTTPRequestHandler):
    # Populated by main() before serve_forever starts.
    app: AppContext = None  # type: ignore[assignment]

    server_version = "builder-api/0.1"
    sys_version = ""  # hide Python/3.x from Server header

    # Per-socket read timeout (seconds). Set from config in main(); applies to
    # the request line + headers + body. Does NOT limit long-poll or WebSocket
    # sessions — those don't read from the socket during their wait.
    timeout = 30

    # ------------------------------------------------------------------
    # Dispatch entry points
    # ------------------------------------------------------------------

    def do_GET(self) -> None:
        self._dispatch("GET")

    def do_POST(self) -> None:
        self._dispatch("POST")

    def do_DELETE(self) -> None:
        self._dispatch("DELETE")

    def do_OPTIONS(self) -> None:
        # CORS preflight — browsers send this before a cross-origin POST /log.
        # We keep the surface wide (Allow-Origin: *) because the API is
        # intended for dev-time use; the password header is still required
        # for anything that mutates, so an unknown origin can't actually
        # do damage without the secret.
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header(
            "Access-Control-Allow-Headers",
            "Content-Type, X-Agent-ID, X-Builder-API-Password",
        )
        self.send_header("Access-Control-Max-Age", "86400")
        self.end_headers()

    # ------------------------------------------------------------------
    # log_message: prefix agent id so ops can tell who hit what endpoint.
    # Identical behavior to the reference implementation.
    # ------------------------------------------------------------------

    def log_message(self, fmt: str, *args) -> None:
        # Dim every HTTP access line so it falls into the visual background
        # behind the colored event tail. 4xx / 5xx surface in red. The
        # interesting state changes (build_*, config_reloaded) come through
        # banner.event_line via the EventStore subscription, so we don't
        # repeat ourselves here.
        agent = self.headers.get("X-Agent-ID") or "-"
        ip = self.client_address[0] if self.client_address else "?"
        line = fmt % args
        try:
            code = int(args[1])
        except (IndexError, ValueError, TypeError):
            code = 200
        c = _banner.GREY if code < 400 else _banner.RED
        if _banner._is_narrow():
            # Narrow window: just the request + code, no ip/agent padding.
            sys.stderr.write(
                f"{_banner.DIM}{time.strftime('%H:%M')}{_banner.RST} "
                f"{c}{_banner.DIM}· {line}{_banner.RST}\n"
            )
        else:
            sys.stderr.write(
                f"  {_banner.DIM}{time.strftime('%H:%M:%S')}{_banner.RST}  "
                f"{c}{_banner.DIM}· http{' ':<19}{_banner.RST}  "
                f"{_banner.GREY}{ip} {agent}  {line}{_banner.RST}\n"
            )

    # ------------------------------------------------------------------
    # Core dispatch
    # ------------------------------------------------------------------

    def _dispatch(self, method: str) -> None:
        try:
            self._dispatch_inner(method)
        except HTTPReject:
            # SizeLimits already wrote the 4xx response; just stop.
            return

    def _dispatch_inner(self, method: str) -> None:
        self.app.size_limits.check_url(self)  # raises HTTPReject on 414

        split = urlsplit(self.path)
        # Flag whether this endpoint is allowed to advertise CORS. Response
        # helpers (and auth rejects) check this so only the browser-facing
        # path gets an Access-Control-Allow-Origin header; everything else
        # stays cross-origin-blocked by default SOP.
        self._cors_allowed = split.path in _CORS_ALLOWED_PATHS
        path = split.path
        query = parse_qs(split.query, keep_blank_values=False)

        # -------- Core routing table --------
        route = (method, path)

        if route == ("GET", "/"):
            self._serve_json(200, self._ep_root())
            return
        if route == ("GET", "/status"):
            if not self._maybe_auth(read=True):
                return
            self._serve_json(200, self._ep_status())
            return
        if route == ("POST", "/build"):
            if not self._maybe_auth(read=False):
                return
            self._serve_json(*self._ep_build_post(query))
            return
        if route == ("GET", "/build_status"):
            if not self._maybe_auth(read=True):
                return
            self._serve_json(*self._ep_build_status(query))
            return
        if method == "POST" and path.startswith("/job/"):
            if not self._maybe_auth(read=False):
                return
            job_name = path[len("/job/"):]
            self._serve_json(*self._ep_job_post(job_name, query))
            return
        if route == ("GET", "/jobs"):
            if not self._maybe_auth(read=True):
                return
            self._serve_json(200, self._ep_jobs())
            return
        if route == ("GET", "/queue"):
            if not self._maybe_auth(read=True):
                return
            self._serve_json(200, self.app.build_queue.snapshot())
            return
        if method == "DELETE" and path.startswith("/queue/"):
            if not self._maybe_auth(read=False):
                return
            build_id = path[len("/queue/"):]
            self._serve_json(*self._ep_queue_delete(build_id))
            return
        if route == ("DELETE", "/current/cancel"):
            if not self._maybe_auth(read=False):
                return
            self._serve_json(*self._ep_current_cancel())
            return
        if route == ("GET", "/logs"):
            if not self._maybe_auth(read=True):
                return
            self._serve_json(*self._ep_logs(query))
            return
        if route == ("GET", "/events"):
            if not self._maybe_auth(read=True):
                return
            self._serve_json(200, self._ep_events(query))
            return
        if route == ("POST", "/log"):
            # Browser / external log ingest → appended to the event feed and
            # pushed live to every open /ws subscriber.
            if not self._maybe_auth(read=False):
                return
            self._serve_json(*self._ep_log_post())
            return
        if route == ("POST", "/run"):
            if not self._maybe_auth(read=False):
                return
            self._serve_json(*self._ep_run())
            return
        if route == ("POST", "/stop"):
            if not self._maybe_auth(read=False):
                return
            self._serve_json(*self._ep_stop())
            return
        if route == ("GET", "/ws"):
            # WebSocket is ALWAYS auth'd regardless of auth_reads.
            if not self.app.auth.check(self, require_auth=True):
                return
            handle_ws_upgrade(
                self,
                log_store=self.app.log_store,
                events_store=self.app.events,
                runtime=self.app.runtime,
                build_queue=self.app.build_queue,
                query=query,
            )
            return

        self._serve_json(404, {"error": "not found", "path": path})

    # ------------------------------------------------------------------
    # Auth helper: respects cfg.auth_reads on GETs.
    # ------------------------------------------------------------------

    def _maybe_auth(self, *, read: bool) -> bool:
        require = (not read) or self.app.cfg.auth_reads
        return self.app.auth.check(self, require_auth=require)

    # ------------------------------------------------------------------
    # Endpoints
    # ------------------------------------------------------------------

    def _ep_root(self) -> dict:
        return {
            "name": self.app.cfg.name,
            "version": "0.1",
            "port": self.app.cfg.port,
            "bind": self.app.cfg.bind,
            "uptime_s": round(time.time() - self.app.start_ts, 2),
        }

    def _ep_status(self) -> dict:
        current = self.app.build_queue.current()
        return {
            "name": self.app.cfg.name,
            "uptime_s": round(time.time() - self.app.start_ts, 2),
            "runtime": self.app.runtime.status(),
            "current_build": current.to_public() if current else None,
        }

    def _ep_build_post(self, query: dict) -> tuple[int, dict]:
        # Legacy single-`[build]` endpoint. Removed when the config layer
        # moved to host-only ~/.llm-docker/builder-api.toml — projects no
        # longer declare a `[build]` block. Everything goes through
        # POST /job/<name>, which has the same security model.
        return 410, {
            "error": "endpoint removed",
            "use": "POST /job/<name>",
            "note": "Per-project [build] tables are gone. Declare your "
                    "commands as [jobs.X] in ~/.llm-docker/builder-api.toml.",
        }

    def _ep_job_post(self, job_name: str, query: dict) -> tuple[int, dict]:
        cfg = self.app.cfg
        job = cfg.jobs.get(job_name)
        if job is None:
            return 404, {
                "error": "unknown_job",
                "name": job_name,
                "available": sorted(cfg.jobs.keys()),
            }

        body = self._read_json_body()
        if body is None:
            return 400, {"error": "invalid JSON body"}

        params = body.get("params") or {}
        agent_id = body.get("agent_id") or self.headers.get("X-Agent-ID") or ""

        # 1. Param validation against placeholders.
        try:
            argv, normalized = _jobs.validate_and_substitute(job, params)
        except _jobs.ValidationError as e:
            return 400, e.to_response(f"/job/{job_name}")

        # 2. Resolve command + verify sha256 (if pinned). Both faults are
        # 412 Precondition Failed — distinct status from validation 400 so
        # MCP clients can render an integrity violation differently.
        try:
            resolved = _jobs.verify_command_hash(job, cfg.project_root)
        except _jobs.CommandHashMismatch as e:
            return 412, e.to_response()
        except _jobs.CommandNotFound as e:
            return 412, e.to_response()

        # 3. Dryrun shortcut: report what WOULD run without enqueueing.
        # Dryrun bypasses the mutation gate below since nothing actually
        # runs — a carpet-test wanting to verify the contract can still
        # do `POST /job/<name>?dryrun=1` safely.
        if _is_truthy_query(query, "dryrun"):
            return 200, {
                "dryrun": True,
                "job": job_name,
                "would_run": [str(resolved), *argv],
                "cwd": str(cfg.project_root),
                "timeout_s": job.timeout_s,
                "mutates_filesystem": job.mutates_filesystem,
                "matched_placeholders": normalized,
            }

        # 4. Mutation gate. Jobs declared `mutates_filesystem = true` need
        # the caller to opt in via `X-Mutation-Confirmed: yes`. Stops a
        # carpet-test pattern (POST + race-to-DELETE) from accidentally
        # firing destructive in-place rewrites (prettier --write, pint
        # without --test, ruff format, etc.) — the cancel race is
        # unwinnable on fast file walkers, so the only safe answer is to
        # refuse the request. 428 Precondition Required is the right
        # semantic ("you need to send more headers").
        if job.mutates_filesystem:
            confirmed = (self.headers.get("X-Mutation-Confirmed") or "").strip().lower()
            if confirmed != "yes":
                return 428, {
                    "error": "mutation_confirmation_required",
                    "job": job_name,
                    "reason": "this job is declared `mutates_filesystem = true`",
                    "fix": "send header `X-Mutation-Confirmed: yes` to confirm "
                           "intent to run a write-in-place job",
                }

        # 5. Enqueue (or get existing entry under dedupe window).
        try:
            entry = self.app.build_queue.enqueue_job(
                args=argv,
                command=str(resolved),
                timeout_s=job.timeout_s,
                kill_after_s=job.kill_after_s,
                cwd=job.cwd,
                job_name=job_name,
                params=normalized,
                agent_id=str(agent_id),
            )
        except QueueFull as e:
            return 429, {"error": str(e)}
        return 202, {"queue_id": entry.id, **entry.to_public()}

    def _ep_jobs(self) -> dict:
        cfg = self.app.cfg
        return {
            "jobs": {name: job.to_public() for name, job in cfg.jobs.items()},
            "config_version": "0.3",
            "config_mtime": cfg.config_mtime,
            "project": cfg.name,
            "languages": list(cfg.languages),
        }

    def _ep_build_status(self, query: dict) -> tuple[int, dict]:
        ids = query.get("id") or []
        if not ids:
            return 400, {"error": "missing id param"}
        wait_s = float((query.get("wait") or ["0"])[0] or "0")
        wait_s = max(0.0, min(wait_s, 60.0))
        return 200, self.app.build_queue.wait(ids[0], wait_s)

    def _ep_current_cancel(self) -> tuple[int, dict]:
        result = self.app.build_queue.cancel_current()
        if result is None:
            return 404, {"error": "no_current_build"}
        return 200, {"ok": True, **result}

    def _ep_queue_delete(self, build_id: str) -> tuple[int, dict]:
        if not build_id:
            return 400, {"error": "missing queue id"}
        ok = self.app.build_queue.cancel(build_id)
        if not ok:
            return 404, {"error": "not pending (already running, finished, or unknown)"}
        return 200, {"ok": True, "cancelled": build_id}

    def _ep_logs(self, query: dict) -> tuple[int, dict]:
        files = query.get("file") or []
        if not files:
            return 400, {
                "error": "missing file param",
                "available": sorted(self.app.log_store.alias_names()),
            }
        n = int((query.get("n") or ["200"])[0] or "200")
        try:
            text = self.app.log_store.tail(files[0], n)
        except KeyError:
            return 404, {
                "error": f"unknown log alias: {files[0]}",
                "available": sorted(self.app.log_store.alias_names()),
            }
        return 200, {"file": files[0], "lines": n, "text": text}

    def _ep_events(self, query: dict) -> dict:
        type_ = (query.get("type") or [None])[0]
        since_s = (query.get("since") or [None])[0]
        pid_s = (query.get("pid") or [None])[0]
        n_s = (query.get("n") or ["200"])[0]

        since = float(since_s) if since_s else None
        pid = int(pid_s) if pid_s else None
        n = int(n_s or "200")
        return self.app.events.query(type_=type_, since=since, n=n, pid=pid)

    # Generous defensive caps on log payloads. Browser console logs can include
    # very long stack traces or stringified objects; accept but truncate so a
    # rogue page doesn't fill the events file in one burst.
    _LOG_MESSAGE_MAX = 16 * 1024   # 16 KB
    _LOG_STACK_MAX   = 8 * 1024    # 8 KB
    _LOG_URL_MAX     = 2 * 1024    # 2 KB

    def _ep_log_post(self) -> tuple[int, dict]:
        """
        Ingest an external/browser log line. Shape:
            {
              "level":    "log" | "warn" | "error" | "info" | "debug",
              "message":  "<string>",
              "source":   "browser" (default; any [a-z0-9_-] token OK),
              "url":      "<page URL>",        (optional)
              "stack":    "<stack trace>",      (optional)
              "timestamp": <unix float>,        (optional; defaults to now)
              "agent_id": "<label>"             (optional)
            }
        Appended to the event feed as `type = "<source>_log"` so subscribers
        can filter with /events?type=browser_log. Live-pushed to every /ws.
        """
        body = self._read_json_body()
        if body is None:
            return 400, {"error": "invalid JSON body"}

        message = body.get("message")
        if not isinstance(message, str) or not message:
            return 400, {"error": "message must be a non-empty string"}

        level = str(body.get("level") or "log").lower()
        if level not in ("log", "warn", "error", "info", "debug"):
            level = "log"

        source_raw = str(body.get("source") or "browser").lower()
        # Restrict `source` to a conservative alphabet so the synthesised event
        # `type` can't inject weird characters into downstream filters.
        import re as _re
        if not _re.fullmatch(r"[a-z0-9_-]{1,32}", source_raw):
            source_raw = "browser"

        payload = {
            "level": level,
            "message": message[: self._LOG_MESSAGE_MAX],
            "source": source_raw,
        }
        if body.get("url"):
            payload["url"] = str(body["url"])[: self._LOG_URL_MAX]
        if body.get("stack"):
            payload["stack"] = str(body["stack"])[: self._LOG_STACK_MAX]
        if body.get("agent_id"):
            payload["agent_id"] = str(body["agent_id"])[:128]
        if body.get("timestamp") is not None:
            try:
                payload["client_ts"] = float(body["timestamp"])
            except (TypeError, ValueError):
                pass

        self.app.events.append(f"{source_raw}_log", payload)
        return 202, {"ok": True}

    def _ep_run(self) -> tuple[int, dict]:
        res = self.app.runtime.run()
        return (200 if res.get("ok") else 400), res

    def _ep_stop(self) -> tuple[int, dict]:
        return 200, self.app.runtime.stop()

    # ------------------------------------------------------------------
    # JSON I/O helpers
    # ------------------------------------------------------------------

    def _read_json_body(self) -> Optional[dict]:
        """
        Returns the parsed JSON body as a dict, or None for JSON parse errors
        (caller maps to 400). Raises HTTPReject if the body exceeded the size
        limit (SizeLimits already wrote the 413). That split is deliberate:
        callers must not treat "response already sent" and "parse error" the
        same way, or they'd send a 400 on top of the 413 and corrupt HTTP.
        """
        raw = self.app.size_limits.read_body(self)  # may raise HTTPReject
        if not raw:
            return {}
        try:
            obj = json.loads(raw.decode("utf-8"))
        except Exception:
            return None
        if not isinstance(obj, dict):
            return None
        return obj

    def _serve_json(self, status: int, obj: dict) -> None:
        body = json.dumps(obj, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        # CORS is emitted ONLY for the browser-facing endpoint (`/log`), set
        # via `self._cors_allowed` at the top of dispatch. Other endpoints
        # stay cross-origin-blocked so a stray malicious page can't trigger
        # `/build` or `/run` even if it guesses the password.
        if getattr(self, "_cors_allowed", False):
            self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass


def _is_truthy_query(query: dict, name: str) -> bool:
    """`?dryrun=1` style flag check. Accepts 1/true/yes/on (case-insensitive)
    and bare `?dryrun` (zero-length value). Anything else is falsy."""
    vals = query.get(name)
    if not vals:
        return False
    v = (vals[0] or "").strip().lower()
    return v in ("", "1", "true", "yes", "on")


# ---------------------------------------------------------------------------
# main()
# ---------------------------------------------------------------------------


def _parse_args(argv: list[str]) -> tuple[str, Optional[Path]]:
    """Returns (project_name, config_path_override). Tiny stdlib parser
    so we don't need argparse for two flags."""
    project: Optional[str] = None
    config_override: Optional[Path] = None
    it = iter(argv)
    for tok in it:
        if tok == "--project":
            project = next(it, None)
        elif tok.startswith("--project="):
            project = tok.split("=", 1)[1]
        elif tok == "--config":
            v = next(it, None)
            config_override = Path(v).expanduser() if v else None
        elif tok.startswith("--config="):
            config_override = Path(tok.split("=", 1)[1]).expanduser()
    if not project:
        # Fallback: basename of cwd, so old `python3 server.py` invocations
        # in a project root still work for one-off testing.
        project = Path.cwd().name
    return project, config_override


def main() -> int:
    project_name, config_override = _parse_args(sys.argv[1:])
    cfg = _config.load(project_name, config_path=config_override)

    app = AppContext(cfg)
    BuilderHandler.app = app
    # Request-read timeout (slowloris protection). Per-socket; doesn't bound
    # long-poll or WebSocket lifetime since those don't read from the socket
    # during their wait. Build subprocess timeout is [build].timeout_s.
    BuilderHandler.timeout = max(1, int(cfg.security.request_timeout_s))

    # Install signal handlers BEFORE binding so a fast Ctrl-C still cleans up.
    server_holder: dict = {}

    def _graceful_exit(signum, frame):  # type: ignore[no-untyped-def]
        # Signal handlers run on the main thread, which is also the thread
        # blocked in `serve_forever()`. Calling `server.shutdown()` here
        # deadlocks (shutdown waits for serve_forever to return, which can't
        # because the main thread is stuck in the signal handler). Same for
        # `app.shutdown()` if any subsystem joins on the main thread.
        # So: just `os._exit(0)` immediately. Daemon threads (build worker,
        # config watcher, runtime) die with the process; in-flight subprocs
        # were spawned with `start_new_session=True` so they're in their
        # own process group and survive briefly until docker compose / make
        # / etc. finish naturally.
        sys.stderr.write(f"\n[builder-api] received signal {signum}, exiting.\n")
        os._exit(0)

    signal.signal(signal.SIGINT, _graceful_exit)
    signal.signal(signal.SIGTERM, _graceful_exit)

    try:
        server = ThreadingHTTPServer((cfg.bind, cfg.port), BuilderHandler)
    except OSError as e:
        sys.stderr.write(f"[builder-api] bind failed on {cfg.bind}:{cfg.port}: {e}\n")
        return 1
    server_holder["server"] = server

    # Banner first, then the event — otherwise `server_started` would
    # print on top of the ASCII art via the live subscription.
    _banner.show_banner(cfg.name, cfg.bind, cfg.port, list(cfg.jobs.keys()))
    app.events.append(
        "server_started",
        {
            "name": cfg.name,
            "bind": cfg.bind,
            "port": cfg.port,
            "auth_reads": cfg.auth_reads,
            "has_password": bool(cfg.password),
            "languages": list(cfg.languages),
        },
    )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        _graceful_exit(signal.SIGINT, None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
