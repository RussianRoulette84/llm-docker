"""
client.py — minimal Python HTTP helper for the DOCKER side to call builder-api.

Mount this file into the container (e.g. via the bind mount already in place
for `docker-entrypoint.sh`) and import it from Claude Code / OpenCode:

    from client import api, build, wait_build, logs, events, ws

Defaults read from env vars the cld / ocd wrappers already forward:
    BUILDER_API_HOST      (host.docker.internal)
    BUILDER_API_PORT      (6666)
    BUILDER_API_PASSWORD  (matches what the daemon expects)

The helper wraps the long-poll pattern (`?wait=N` + `timed_out`) so callers
don't have to sleep-loop; `wait_build()` blocks up to `max_total_wait_s` and
returns the final dict (or raises on timeout).

Transport is stdlib urllib — no pip deps in the container.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from typing import Any, Optional


DEFAULT_HOST = os.environ.get("BUILDER_API_HOST", "host.docker.internal")
DEFAULT_PORT = int(os.environ.get("BUILDER_API_PORT", "6666") or 6666)
DEFAULT_PASSWORD = os.environ.get("BUILDER_API_PASSWORD", "") or None
DEFAULT_AGENT_ID = os.environ.get("BUILDER_AGENT_ID", "") or None


def _base_url() -> str:
    return f"http://{DEFAULT_HOST}:{DEFAULT_PORT}"


class BuilderAPIError(RuntimeError):
    """Raised when the server returns a non-2xx status."""

    def __init__(self, status: int, body: Any) -> None:
        self.status = status
        self.body = body
        super().__init__(f"HTTP {status}: {body!r}")


# ---------------------------------------------------------------------------
# Core request primitive
# ---------------------------------------------------------------------------


def api(
    method: str,
    path: str,
    body: Optional[dict] = None,
    *,
    timeout: float = 65.0,
    agent_id: Optional[str] = None,
    password: Optional[str] = None,
    retries: int = 3,
    retry_delay_s: float = 1.0,
) -> Any:
    """
    Send one request. Returns parsed JSON on success, raises
    `BuilderAPIError` on HTTP error, `urllib.error.URLError` on connection
    error. Retries transient connection failures up to `retries` times.

    `timeout` should be > the server's max long-poll (60s) by a few seconds
    so `?wait=60` isn't cut off client-side.
    """
    url = f"{_base_url()}{path}"
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    aid = agent_id or DEFAULT_AGENT_ID
    if aid:
        headers["X-Agent-ID"] = aid
    pwd = password if password is not None else DEFAULT_PASSWORD
    if pwd:
        headers["X-Builder-API-Password"] = pwd

    req = urllib.request.Request(url, data=data, method=method, headers=headers)

    last_exc: Optional[Exception] = None
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
                try:
                    return json.loads(raw) if raw else {}
                except Exception:
                    return {"_raw": raw.decode("utf-8", errors="replace")}
        except urllib.error.HTTPError as e:
            try:
                payload = json.loads(e.read() or b"null")
            except Exception:
                payload = None
            raise BuilderAPIError(e.code, payload)
        except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
            last_exc = e
            if attempt >= retries:
                break
            time.sleep(retry_delay_s)
    assert last_exc is not None
    raise last_exc


# ---------------------------------------------------------------------------
# Convenience wrappers matching the most common call sites
# ---------------------------------------------------------------------------


def status() -> dict:
    return api("GET", "/status")


def build(args: Optional[list[str]] = None, *, agent_id: Optional[str] = None) -> dict:
    """Enqueue a build. Returns the queue entry (has `queue_id`)."""
    return api("POST", "/build", {"args": args or []}, agent_id=agent_id)


def build_status(queue_id: str, *, wait_s: float = 0) -> dict:
    """One-shot call, optionally long-polling up to `wait_s`."""
    return api(
        "GET",
        f"/build_status?id={queue_id}&wait={int(wait_s)}",
        timeout=max(wait_s, 5) + 5,
    )


def wait_build(queue_id: str, *, max_total_wait_s: float = 900.0) -> dict:
    """
    Block until the build reaches a terminal state. Uses 30s long-poll
    windows so a long build doesn't wedge on one HTTP call.

    Returns the final status dict (contains `log_tail` on completion).
    Raises TimeoutError if `max_total_wait_s` elapses without a terminal
    state.
    """
    deadline = time.monotonic() + max_total_wait_s
    while time.monotonic() < deadline:
        res = build_status(queue_id, wait_s=30)
        if not res.get("timed_out"):
            return res
    raise TimeoutError(f"build {queue_id} did not finish in {max_total_wait_s}s")


def cancel_build(queue_id: str) -> dict:
    return api("DELETE", f"/queue/{queue_id}")


def queue() -> dict:
    return api("GET", "/queue")


def logs(alias: str, n: int = 200) -> str:
    res = api("GET", f"/logs?file={alias}&n={int(n)}")
    return res.get("text", "") if isinstance(res, dict) else ""


def events(
    *,
    type_: Optional[str] = None,
    since: Optional[float] = None,
    n: int = 200,
    pid: Optional[int] = None,
) -> dict:
    parts = [f"n={int(n)}"]
    if type_ is not None:
        parts.append(f"type={type_}")
    if since is not None:
        parts.append(f"since={since}")
    if pid is not None:
        parts.append(f"pid={pid}")
    return api("GET", "/events?" + "&".join(parts))


def run() -> dict:
    return api("POST", "/run")


def stop() -> dict:
    return api("POST", "/stop")


# ---------------------------------------------------------------------------
# WebSocket — tiny client suitable for "watch logs for N seconds" usage.
# Kept here so containers don't need an extra `websockets` dep.
# ---------------------------------------------------------------------------


def ws(
    *,
    logs_aliases: Optional[list[str]] = None,
    duration_s: float = 60.0,
    on_message=None,
) -> None:
    """
    Connect to /ws with password auth, subscribe to the given aliases, and
    invoke `on_message(obj)` for each received JSON frame until `duration_s`
    elapses or the connection drops.

    `on_message` default: print line-by-line log frames, skip others.
    """
    import base64
    import os as _os
    import socket
    import struct
    from urllib.parse import urlencode

    # Reject pathologically large inbound frames; a malicious/broken server
    # could otherwise declare a 2^64-byte payload and make us buffer forever.
    MAX_FRAME = 1 * 1024 * 1024

    aliases = ",".join(logs_aliases or [])
    path = "/ws" + ("?" + urlencode({"logs": aliases}) if aliases else "")

    sock = socket.create_connection((DEFAULT_HOST, DEFAULT_PORT), timeout=10.0)
    key = base64.b64encode(_os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {DEFAULT_HOST}:{DEFAULT_PORT}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
    )
    if DEFAULT_PASSWORD:
        req += f"X-Builder-API-Password: {DEFAULT_PASSWORD}\r\n"
    req += "\r\n"
    sock.sendall(req.encode())

    # Read response headers up to \r\n\r\n
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            raise BuilderAPIError(0, "connection closed during handshake")
        resp += chunk
    if b"101" not in resp.split(b"\r\n", 1)[0]:
        raise BuilderAPIError(0, f"upgrade failed: {resp.splitlines()[0]!r}")

    def _on_msg_default(obj):
        if obj.get("type") == "log":
            print(f"[{obj.get('file')}] {obj.get('line')}", flush=True)

    cb = on_message or _on_msg_default
    buf = bytearray(resp.split(b"\r\n\r\n", 1)[1])

    deadline = time.monotonic() + duration_s
    sock.settimeout(1.0)
    try:
        while time.monotonic() < deadline:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                break
            buf.extend(chunk)
            while True:
                if len(buf) < 2:
                    break
                b0, b1 = buf[0], buf[1]
                length = b1 & 0x7F
                offset = 2
                if length == 126:
                    if len(buf) < offset + 2:
                        break
                    length = struct.unpack(">H", bytes(buf[offset:offset + 2]))[0]
                    offset += 2
                elif length == 127:
                    if len(buf) < offset + 8:
                        break
                    length = struct.unpack(">Q", bytes(buf[offset:offset + 8]))[0]
                    offset += 8
                if length > MAX_FRAME:
                    # Server is misbehaving — stop before we OOM.
                    return
                if len(buf) < offset + length:
                    break
                payload = bytes(buf[offset:offset + length])
                del buf[: offset + length]
                if (b0 & 0x0F) != 0x1:
                    continue
                try:
                    cb(json.loads(payload.decode("utf-8")))
                except Exception:
                    pass
    finally:
        try:
            sock.close()
        except OSError:
            pass
