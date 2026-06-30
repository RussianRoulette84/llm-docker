"""http_handler — BuilderHandler: HTTP dispatch, auth, JSON I/O. Mixes in RoutesMixin."""
from __future__ import annotations
import json
import os
import sys
import time  # noqa: F401
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, parse_qsl, unquote, urlsplit

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import banner as _banner                   # noqa: E402
from events import EventStore              # noqa: E402,F401
from security import HTTPReject, SizeLimits  # noqa: E402,F401
from ws import handle_ws_upgrade           # noqa: E402
from app_context import AppContext         # noqa: E402,F401
from routes import RoutesMixin             # noqa: E402

# CORS only for the browser-facing /log endpoint.
_CORS_ALLOWED_PATHS = frozenset({"/log"})

# Plain-English reason for the access-log tail. Operator-facing, not the wire
# status text — "why did my job get rejected" in the words they think in.
_HTTP_REASONS = {
    400: "bad params",
    401: "auth required",
    403: "forbidden",
    404: "no such job/route",
    405: "method not allowed",
    412: "command hash mismatch",
    413: "payload too large",
    429: "rate limited",
    500: "server error",
    503: "busy",
}


def _http_reason(code: int) -> str:
    return _HTTP_REASONS.get(code, "")


# Verbose-console mute list: high-frequency polls (+ the log-ingest, which
# already becomes a *_log event). Muted only on success — 4xx/5xx always show.
_VERBOSE_MUTE = frozenset({"/build_status", "/events", "/status", "/", "/ws", "/log"})


def _response_summary(obj) -> str:
    """One-line gist of a response for the verbose console. Prefers the
    meaningful field (error / status / returncode), never dumps full bodies."""
    if not isinstance(obj, dict):
        return str(obj)[:100]
    for key in ("error", "status", "state"):
        if obj.get(key):
            v = obj[key]
            if key == "status" and "returncode" in obj:
                return f"{v}·rc={obj['returncode']}"
            return str(v)[:100]
    if "jobs" in obj and isinstance(obj["jobs"], dict):
        return f"{len(obj['jobs'])} jobs"
    if "events" in obj and isinstance(obj["events"], list):
        return f"{len(obj['events'])} events"
    return f"{len(obj)} keys"


def _response_body(obj) -> str:
    """The actual response payload for the verbose console — the real output a
    human wants to read. For log/text endpoints it's the raw text; otherwise a
    pretty-printed JSON. Capped so a giant response can't flood the stream."""
    if isinstance(obj, dict) and isinstance(obj.get("text"), str):
        return obj["text"][:8000]
    try:
        return json.dumps(obj, indent=2, default=str)[:4000]
    except Exception:
        return str(obj)[:2000]


class BuilderHandler(RoutesMixin, BaseHTTPRequestHandler):
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
        # The api pane shows banner + job/system events only. ALL HTTP traffic
        # (calls + responses) now lives in the verbose console (cld-verbose, via
        # the http_call event), so the access-log is silenced here by default —
        # set BUILDER_API_HTTP_VERBOSE=1 to restore it for debugging.
        if not os.environ.get("BUILDER_API_HTTP_VERBOSE"):
            return
        try:
            code = int(args[1])
        except (IndexError, ValueError, TypeError):
            code = 200
        path = getattr(self, "path", "") or ""
        method = getattr(self, "command", "") or "?"
        split = urlsplit(path)
        # Outcome is tinted by severity (5xx red, 4xx yellow); name + emoji
        # come from the job's family so a rejected call reads exactly like a
        # real run's row (same emoji, same color), just with a reject reason.
        msg_color = _banner.RED if code >= 500 else _banner.YELLOW
        if split.path.startswith("/job/"):
            subject = unquote(split.path[len("/job/"):]) or "?"
            family, color = _banner._classify(subject)
            glyph = _banner._family_emoji(family)
            qs = ",".join(f"{k}={v}" for k, v in parse_qsl(split.query))
            msg = f"{code} {_http_reason(code)}" + (f"·{qs}" if qs else "")
        else:
            ip = self.client_address[0] if self.client_address else "?"
            subject, color, glyph = "http", _banner.GREY, "🌐"
            msg = f"{method} {split.path} → {code} {_http_reason(code)} {ip}"
        sys.stderr.write(_banner.format_event_row(
            time.strftime("%H:%M:%S"), color, glyph, subject, msg, msg_color,
        ))

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
        self._emit_http_call(status, obj)

    def _emit_http_call(self, status: int, obj) -> None:
        """Fan a per-request `call → response` event to the verbose console
        (cld-verbose, via /ws). Live-only (persist=False) so the JSONL never
        bloats. Mirrors the access-log's 2xx-poll suppression: high-frequency
        poll endpoints are muted on success but ALWAYS shown on 4xx/5xx."""
        try:
            split = urlsplit(self.path or "")
            path = split.path
            if status < 400 and path in _VERBOSE_MUTE:
                return
            self.app.events.append("http_call", {
                "method": getattr(self, "command", "?"),
                "path": path,
                "query": {k: v[0] for k, v in parse_qs(split.query).items()},
                "status": status,
                "summary": _response_summary(obj),
                "body": _response_body(obj),
                "agent_id": self.headers.get("X-Agent-ID"),
                "ip": self.client_address[0] if self.client_address else None,
            }, persist=False)
        except Exception:
            # The verbose feed must never break the request path.
            pass

