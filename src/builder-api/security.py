"""
security.py — auth gate + per-IP rate limit for failed-auth lockouts.

Import points:
    - `AuthGate(cfg, events)` is constructed once in server.py.
    - `gate.check(handler)` is called at the top of every request. It returns
      True if the request passes auth, False if it was rejected (in which case
      the gate has already written the 401/429 response body).

This module has NO knowledge of HTTP framing; it only needs the handler's
client_address, headers, and a helper to send short status responses. Keeping
it pure means it's easy to unit-test.
"""

from __future__ import annotations

import json
import sys
import threading
import time
from collections import deque
from typing import Optional


class HTTPReject(Exception):
    """
    Raised by SizeLimits when it has already written a 4xx response to the
    wire. The top-level dispatcher catches this and returns without sending
    a second response (which would corrupt the HTTP stream).
    """


# ---------------------------------------------------------------------------
# Rate limit: sliding window per IP. Failures only — successful auth is not
# counted. Lockout is a timestamp-until; we skip the window check while locked.
# ---------------------------------------------------------------------------

class _IPState:
    __slots__ = ("failures", "locked_until")

    def __init__(self) -> None:
        self.failures: deque[float] = deque()  # timestamps of recent fails
        self.locked_until: float = 0.0         # 0 when not locked


class AuthGate:
    """
    Combines password check, rate limiting, and request-size limits.

    Behavior:
      - POST / DELETE → always auth-required.
      - GET / WS     → auth-required iff cfg.auth_reads is True (server sets
                        this to True by default when bind != 127.0.0.1).
      - WS           → ALWAYS auth, regardless of auth_reads (streaming is
                        more sensitive than single reads).

    The rate limiter counts ONLY *authentication failures* (401). It does not
    throttle successful requests. On lockout we return 429 for the remaining
    window; the event `auth_failure_lockout` is appended once per transition
    into locked state.
    """

    def __init__(self, cfg, events_appender) -> None:
        self._cfg = cfg
        self._events = events_appender  # callable(type: str, payload: dict)
        self._lock = threading.Lock()
        self._ips: dict[str, _IPState] = {}

        sec = cfg.security
        self._window_s = 60.0
        self._max_failures = sec.auth_failures_per_min
        self._lockout_s = float(sec.lockout_s)

    # ---- public gate ------------------------------------------------------

    def check(self, handler, *, require_auth: bool) -> bool:
        """
        Returns True if the request may proceed; False if already rejected
        (handler.send_response has been called).
        """
        ip = handler.client_address[0] if handler.client_address else "unknown"

        # 1. Check lockout first — cheaper than a password comparison, and a
        #    locked-out attacker shouldn't even get the auth branch.
        now = time.time()
        with self._lock:
            state = self._ips.get(ip)
            if state is not None and state.locked_until > now:
                remaining = int(state.locked_until - now)
                self._short_response(
                    handler,
                    429,
                    f"rate limited: {remaining}s remaining",
                    retry_after=remaining,
                )
                return False

        # 2. Auth branch.
        if not require_auth:
            return True

        # If no password is configured, auth is inherently unenforceable.
        # config.py already refuses non-loopback binds without a password,
        # so reaching this branch implies the operator accepted loopback-
        # trust. Fail open rather than brick every POST/DELETE with 401.
        expected = self._cfg.password
        if not expected:
            return True

        password = self._extract_password(handler)
        if password and _constant_time_eq(password, expected):
            return True

        # Auth failed — record, maybe lock out.
        self._record_failure(ip, now)
        self._short_response(handler, 401, "authentication required")
        return False

    # ---- internals --------------------------------------------------------

    def _extract_password(self, handler) -> Optional[str]:
        """
        Pull the client-supplied password from either the header or the
        ?key= query param. Either is acceptable so curl-friendly use is easy.
        """
        hdr = handler.headers.get("X-Builder-API-Password")
        if hdr:
            return hdr

        # Parse ?key= out of the raw path. We don't trust any URL parser
        # that might have normalized %-escapes in weird ways here.
        path = handler.path or ""
        qpos = path.find("?")
        if qpos == -1:
            return None
        from urllib.parse import parse_qs
        qs = parse_qs(path[qpos + 1 :], keep_blank_values=False)
        vals = qs.get("key")
        if vals:
            return vals[0]
        return None

    def _record_failure(self, ip: str, now: float) -> None:
        with self._lock:
            state = self._ips.setdefault(ip, _IPState())
            window_start = now - self._window_s

            # Drop failures older than the window.
            while state.failures and state.failures[0] < window_start:
                state.failures.popleft()

            state.failures.append(now)
            if len(state.failures) >= self._max_failures:
                was_locked = state.locked_until > now
                state.locked_until = now + self._lockout_s
                state.failures.clear()
                if not was_locked:
                    self._emit_lockout(ip, now)

    def _emit_lockout(self, ip: str, now: float) -> None:
        # Warn the operator on the tty so they notice; also append an event
        # so the feed shows it historically.
        sys.stderr.write(
            f"[builder-api] SECURITY: {self._max_failures} failed auth "
            f"attempts from {ip} in {int(self._window_s)}s — "
            f"locked out for {int(self._lockout_s)}s\n"
        )
        sys.stderr.flush()
        try:
            self._events(
                "auth_failure_lockout",
                {
                    "ip": ip,
                    "lockout_s": int(self._lockout_s),
                    "at": now,
                    "threshold": self._max_failures,
                    "window_s": int(self._window_s),
                },
            )
        except Exception:
            # Events backend might not be ready during early boot; never let
            # a logging failure turn a security event into a 500.
            pass

    # ---- small helper to avoid pulling BaseHTTPRequestHandler into tests ---

    def _short_response(self, handler, status: int, message: str, *, retry_after: int = 0) -> None:
        body = json.dumps({"error": message}).encode("utf-8")
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        # CORS is only advertised when the path was flagged cors-allowed by
        # the dispatcher (browser endpoints). Keeps auth failures for other
        # endpoints opaque to cross-origin callers.
        if getattr(handler, "_cors_allowed", False):
            handler.send_header("Access-Control-Allow-Origin", "*")
        if retry_after > 0:
            handler.send_header("Retry-After", str(retry_after))
        handler.end_headers()
        try:
            handler.wfile.write(body)
        except BrokenPipeError:
            pass
        # Mirror rejected calls (401/429) into the verbose console — they
        # bypass _serve_json. Live-only; never break the request path.
        try:
            from urllib.parse import urlsplit, parse_qs
            split = urlsplit(handler.path or "")
            self._events("http_call", {
                "method": getattr(handler, "command", "?"),
                "path": split.path,
                "query": {k: v[0] for k, v in parse_qs(split.query).items()},
                "status": status,
                "summary": message,
                "body": message,
                "ip": handler.client_address[0] if handler.client_address else None,
            }, persist=False)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Request body / URL size clamps — applied BEFORE dispatching to handlers so a
# million-line POST can't DoS us.
# ---------------------------------------------------------------------------


class SizeLimits:
    """
    Cached thresholds pulled once from config for fast per-request checks.

    Rejection protocol: methods either succeed or RAISE HTTPReject after
    already having written the error response to the wire. Callers must NOT
    attempt another `send_response()` — just catch and return. Returning a
    None sentinel would invite "size rejected AND parse error" ambiguity in
    the JSON path, which in the old design produced double HTTP responses.
    """

    def __init__(self, cfg) -> None:
        self.max_body_bytes: int = cfg.security.max_body_bytes
        self.max_url_bytes: int = cfg.security.max_url_bytes

    def check_url(self, handler) -> None:
        if len(handler.path.encode("utf-8", errors="replace")) > self.max_url_bytes:
            self._reject(handler, 414, "URI too long")  # raises

    def read_body(self, handler) -> bytes:
        """
        Read at most `max_body_bytes` from the request body and return them.
        Raises HTTPReject (after writing the 4xx) on over-size or malformed
        Content-Length. Returns b'' for declared-zero-length bodies.
        """
        length_hdr = handler.headers.get("Content-Length") or "0"
        try:
            length = int(length_hdr)
        except ValueError:
            self._reject(handler, 400, "invalid Content-Length")  # raises
        if length < 0 or length > self.max_body_bytes:
            self._reject(handler, 413, "request body too large")  # raises
        return handler.rfile.read(length) if length > 0 else b""

    def _reject(self, handler, status: int, message: str) -> None:
        body = json.dumps({"error": message}).encode("utf-8")
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        if getattr(handler, "_cors_allowed", False):
            handler.send_header("Access-Control-Allow-Origin", "*")
        handler.end_headers()
        try:
            handler.wfile.write(body)
        except BrokenPipeError:
            pass
        raise HTTPReject()


# ---------------------------------------------------------------------------
# Constant-time string compare — prevents timing-based password discovery.
# ---------------------------------------------------------------------------

def _constant_time_eq(a: str, b: str) -> bool:
    try:
        import hmac
        return hmac.compare_digest(a, b)
    except Exception:
        # Absurd fallback; stdlib hmac is always available but belt-and-braces.
        if len(a) != len(b):
            return False
        diff = 0
        for x, y in zip(a, b):
            diff |= ord(x) ^ ord(y)
        return diff == 0
