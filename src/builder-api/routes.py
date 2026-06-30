"""routes — RoutesMixin: the _ep_* HTTP endpoint handlers (mixed into BuilderHandler)."""
from __future__ import annotations
import json  # noqa: F401
import sys
import time  # noqa: F401
from pathlib import Path
from typing import Optional  # noqa: F401

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import jobs as _jobs                       # noqa: E402
from build_queue import QueueFull          # noqa: E402


def _is_truthy_query(query: dict, name: str) -> bool:
    """`?dryrun=1` style flag check. Accepts 1/true/yes/on (case-insensitive)
    and bare `?dryrun` (zero-length value). Anything else is falsy."""
    vals = query.get(name)
    if not vals:
        return False
    v = (vals[0] or "").strip().lower()
    return v in ("", "1", "true", "yes", "on")


class RoutesMixin:
    """The _ep_* endpoint handlers. Mixed into BuilderHandler; each method
    uses self.app / self._serve_json / self.path etc. from the handler."""
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
        # moved to host-only ~/.llm-docker/api_config/builder-api.toml — projects no
        # longer declare a `[build]` block. Everything goes through
        # POST /job/<name>, which has the same security model.
        return 410, {
            "error": "endpoint removed",
            "use": "POST /job/<name>",
            "note": "Per-project [build] tables are gone. Declare your "
                    "commands as [jobs.X] in ~/.llm-docker/api_config/builder-api.toml.",
        }

    def _ep_job_post(self, job_name: str, query: dict) -> tuple[int, dict]:
        cfg = self.app.cfg
        job = cfg.jobs.get(job_name)

        # Generic verbs declared in the base toml ([verb.<name>]) need a
        # different "not implemented" message than ordinary missing jobs:
        # the verb is part of the vocabulary, this project just doesn't
        # implement it. Surface that distinction so callers get a useful
        # 404 instead of a generic "unknown_job".
        verb = cfg.verbs.get(job_name)
        if job is None and verb is not None:
            return 404, {
                "error": "verb_not_implemented",
                "verb": job_name,
                "project": cfg.name,
                "declared_platforms": list(verb.platforms),
                "implemented_platforms": [],
                "hint": (
                    f"add a [project.{cfg.name}.jobs.{job_name}.platforms."
                    f"<platform>] block to your project's shard."
                ),
            }
        if job is None:
            return 404, {
                "error": "unknown_job",
                "name": job_name,
                "available": sorted(cfg.jobs.keys()),
            }

        # Verb/hub dispatch: a hub job has no command of its own; the
        # request must select a platform whose leaf job actually runs.
        # The leaf goes through the SAME validation / hash / mutation
        # pipeline below, so the security stack is identical to a flat
        # job — only the resolution step is new.
        if job.is_hub:
            qs_platform = query.get("platform") or []
            requested = (qs_platform[0] if qs_platform else "").strip()
            if not requested:
                return 400, {
                    "error": "missing_param",
                    "param": (verb.required_param if verb else "platform"),
                    "verb": job_name,
                    "declared_platforms": (
                        list(verb.platforms) if verb else []
                    ),
                    "implemented_platforms": sorted(job.platforms.keys()),
                    "hint": (
                        f"call POST /job/{job_name}?platform=<one of "
                        f"{sorted(job.platforms.keys())}>"
                    ),
                }
            if verb is not None and requested not in verb.platforms:
                return 400, {
                    "error": "platform_not_declared",
                    "verb": job_name,
                    "platform": requested,
                    "declared_platforms": list(verb.platforms),
                }
            if requested not in job.platforms:
                return 404, {
                    "error": "verb_not_implemented",
                    "verb": job_name,
                    "platform": requested,
                    "project": cfg.name,
                    "declared_platforms": (
                        list(verb.platforms) if verb else []
                    ),
                    "implemented_platforms": sorted(job.platforms.keys()),
                }
            job = job.platforms[requested]

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
        # the caller to opt in EXPLICITLY. Stops a carpet-test pattern
        # (POST + race-to-DELETE) from accidentally firing destructive
        # in-place rewrites (prettier --write, pint without --test, ruff
        # format, etc.) — the cancel race is unwinnable on fast file
        # walkers, so the only safe answer is to refuse the request.
        # 428 Precondition Required is the right semantic.
        #
        # Two equivalent ways to confirm — caller picks whichever its
        # HTTP transport supports:
        #   * header  `X-Mutation-Confirmed: yes`   (preferred — out-of-band)
        #   * query   `?confirm=yes`                (fallback for proxies /
        #                                            MCP wrappers that can't
        #                                            set custom headers)
        # Both are equally explicit caller opt-ins; the gate's value is the
        # conscious confirmation, not the transport.
        if job.mutates_filesystem:
            hdr = (self.headers.get("X-Mutation-Confirmed") or "").strip().lower()
            qs_conf = (query.get("confirm") or [""])[0].strip().lower()
            if hdr != "yes" and qs_conf != "yes":
                return 428, {
                    "error": "mutation_confirmation_required",
                    "job": job_name,
                    "reason": "this job is declared `mutates_filesystem = true`",
                    "fix": (
                        "send header `X-Mutation-Confirmed: yes` OR add "
                        "`?confirm=yes` to the URL to confirm intent to "
                        "run a write-in-place job"
                    ),
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
        verbs_out: dict[str, dict] = {}
        for name, vs in cfg.verbs.items():
            entry = vs.to_public()
            job = cfg.jobs.get(name)
            entry["implemented_platforms"] = (
                sorted(job.platforms.keys())
                if (job is not None and job.is_hub) else []
            )
            verbs_out[name] = entry
        return {
            "jobs": {name: job.to_public() for name, job in cfg.jobs.items()},
            "verbs": verbs_out,
            "config_version": "0.4",
            "config_mtime": cfg.config_mtime,
            "project": cfg.name,
            "languages": list(cfg.languages),
            "shard_paths": [str(p) for p in cfg.shard_paths],
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

