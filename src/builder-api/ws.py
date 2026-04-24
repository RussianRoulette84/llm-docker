"""
ws.py — RFC 6455 WebSocket handshake + frame codec + per-connection session
loop. Every /ws upgrade opens a single thread that:

  * subscribes to one `LogWatcher` per requested alias (query param `?logs=`)
  * pushes a periodic `status` heartbeat
  * exits cleanly on client close / socket error

No third-party deps — the handshake, mask, and frame framing are written
directly against the socket from BaseHTTPRequestHandler's raw connection.

Security: per the plan, `/ws` is ALWAYS auth'd regardless of `auth_reads`.
The server-side gate is applied BEFORE upgrading; this module trusts the
caller only invokes it post-auth.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import queue as _queue
import select
import socket
import struct
import threading
import time
from typing import Iterable, Optional

from logs import LogWatcher


WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# Frame opcodes we send. Client can send any of these; we only act on TEXT
# and CLOSE, and silently accept PING (we don't originate pings — a 5-second
# status heartbeat doubles as liveness).
OP_CONT = 0x0
OP_TEXT = 0x1
OP_BIN = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

# Upper bound on a single inbound WebSocket frame. A hostile client could
# declare a 2^64-byte payload in the length field; without this cap, the
# parser would wait forever for bytes that never come, while buffering
# whatever does arrive. Cap well above any legit message we'd expect
# (cmd requests are tiny).
MAX_INBOUND_FRAME_BYTES = 1 * 1024 * 1024   # 1 MB

# Outbound send-queue capacity per connection. Slow subscribers accumulate
# log / event frames here; once the queue is full we drop the oldest frame
# so the producer thread (events.append, log watchers) never blocks. This is
# the critical fix for the 4-containers-on-one-API scenario: one stuck
# client can't starve the other three.
SEND_QUEUE_SIZE = 512


def handle_ws_upgrade(
    handler,
    *,
    log_store,
    events_store,
    runtime,
    build_queue,
    query: dict,
) -> None:
    """
    Perform the HTTP-to-WebSocket upgrade on the handler's raw socket and
    then block running a per-connection session. The HTTP framework will
    see the `Connection: close` semantics after this returns.

    `query` is already parsed `?logs=engine,build&...` etc.
    """
    # --- 1. RFC 6455 handshake ---
    key = handler.headers.get("Sec-WebSocket-Key")
    if not key:
        handler.send_error(400, "missing Sec-WebSocket-Key")
        return
    accept = base64.b64encode(
        hashlib.sha1((key + WS_MAGIC).encode("ascii")).digest()
    ).decode("ascii")

    handler.send_response(101, "Switching Protocols")
    handler.send_header("Upgrade", "websocket")
    handler.send_header("Connection", "Upgrade")
    handler.send_header("Sec-WebSocket-Accept", accept)
    handler.end_headers()
    handler.wfile.flush()

    sock = handler.connection
    # Make reads interruptible without blocking the heartbeat.
    try:
        sock.setblocking(False)
    except OSError:
        pass

    # --- 2. Parse subscription list ---
    logs_param = query.get("logs") or [",".join(log_store.alias_names())]
    requested = [s for s in logs_param[0].split(",") if s]
    valid: list[str] = []
    for alias in requested:
        if alias in log_store.alias_names():
            valid.append(alias)

    # --- 3. Per-session state ---
    session = _WSSession(
        sock,
        requested_aliases=valid,
        log_store=log_store,
        events_store=events_store,
        runtime=runtime,
        build_queue=build_queue,
    )
    session.run()


class _WSSession:
    """
    One active WebSocket connection.

    Outbound I/O is decoupled from producers via a bounded queue + dedicated
    sender thread. Producers (log watchers, event subscribers, heartbeat)
    call _send_json → put on the queue. If the queue is full we drop the
    OLDEST frame, guaranteeing the producer never blocks even if the client
    stops reading. The sender thread drains the queue and does the actual
    sendall. This is load-bearing when several Docker containers subscribe
    to the same API — one stuck container can't wedge the others.
    """

    HEARTBEAT_S = 5.0

    # Sentinel placed on the queue by _teardown; sender thread exits when it
    # pops this. Saves a second "closed" check per loop iteration.
    _STOP = object()

    def __init__(
        self,
        sock: socket.socket,
        *,
        requested_aliases: list[str],
        log_store,
        events_store,
        runtime,
        build_queue,
    ) -> None:
        self._sock = sock
        self._closed = threading.Event()

        self._log_store = log_store
        self._events = events_store
        self._runtime = runtime
        self._queue = build_queue

        self._watchers: list[LogWatcher] = []
        self._watcher_threads: list[threading.Thread] = []
        self._requested_aliases = requested_aliases

        # Bounded outbound queue + sender thread. See class docstring.
        self._send_queue: "_queue.Queue[tuple[int, bytes] | object]" = \
            _queue.Queue(maxsize=SEND_QUEUE_SIZE)
        self._sender_thread: Optional[threading.Thread] = None
        self._dropped_frames = 0   # diagnostic counter; exposed in teardown log

    # ------------------------------------------------------------------

    def run(self) -> None:
        # Start the sender thread FIRST so the hello frame below goes through
        # the queue like every other send.
        self._sender_thread = threading.Thread(
            target=self._sender_loop, name="ws-sender", daemon=True
        )
        self._sender_thread.start()

        self._send_json({
            "type": "hello",
            "logs": list(self._requested_aliases),
            "heartbeat_s": self.HEARTBEAT_S,
        })

        # Subscribe to the event feed so every append() pushed to clients.
        # Registered before watchers start so we don't miss any events fired
        # during setup (e.g. if plugin hooks emit on connect).
        self._events.subscribe(self._emit_event)

        # Start one log watcher per requested alias. Each pushes lines
        # through _emit_log.
        for alias in self._requested_aliases:
            path = self._log_store.path_for(alias)
            w = LogWatcher(alias, path, self._emit_log)
            t = threading.Thread(
                target=w.run,
                name=f"ws-log-{alias}",
                daemon=True,
            )
            self._watchers.append(w)
            self._watcher_threads.append(t)
            t.start()

        # Heartbeat thread pushes /status every HEARTBEAT_S.
        hb = threading.Thread(target=self._heartbeat_loop, daemon=True)
        hb.start()

        try:
            self._recv_loop()
        finally:
            self._teardown()

    # ------------------------------------------------------------------
    # Inbound: read frames, dispatch commands
    # ------------------------------------------------------------------

    def _recv_loop(self) -> None:
        """
        Client frames we care about:
          {"cmd": "status"}                     → reply with /status
          {"cmd": "queue"}                      → reply with /queue snapshot
          {"cmd": "events", ...filter args...}  → reply with filtered events
          CLOSE frame                            → shut down
        """
        buf = bytearray()
        while not self._closed.is_set():
            try:
                ready, _, _ = select.select([self._sock], [], [], 0.5)
            except (ValueError, OSError):
                break
            if not ready:
                continue

            try:
                chunk = self._sock.recv(65536)
            except BlockingIOError:
                continue
            except (ConnectionResetError, OSError):
                break
            if not chunk:
                break
            buf.extend(chunk)

            while True:
                frame = _try_read_frame(buf)
                if frame is None:
                    break
                opcode, payload = frame
                if opcode == OP_CLOSE:
                    return
                if opcode == OP_PING:
                    self._send_frame(OP_PONG, payload)
                    continue
                if opcode != OP_TEXT:
                    continue
                try:
                    msg = json.loads(payload.decode("utf-8"))
                except Exception:
                    continue
                self._handle_cmd(msg)

    def _handle_cmd(self, msg: dict) -> None:
        cmd = msg.get("cmd")
        if cmd == "status":
            self._send_json({
                "type": "status",
                "runtime": self._runtime.status(),
                "current_build": (
                    self._queue.current().to_public() if self._queue.current() else None
                ),
            })
        elif cmd == "queue":
            self._send_json({"type": "queue", **self._queue.snapshot()})
        elif cmd == "events":
            res = self._events.query(
                type_=msg.get("type"),
                since=msg.get("since"),
                n=int(msg.get("n") or 200),
                pid=msg.get("pid"),
            )
            self._send_json({"type": "events", **res})
        else:
            self._send_json({"type": "error", "error": f"unknown cmd: {cmd!r}"})

    # ------------------------------------------------------------------
    # Outbound: serialise + frame
    # ------------------------------------------------------------------

    def _emit_log(self, alias: str, line: str) -> None:
        self._send_json({"type": "log", "file": alias, "line": line})

    def _emit_event(self, record: dict) -> None:
        """Called by EventStore._notify on every appended event."""
        self._send_json({"type": "event", "record": record})

    def _heartbeat_loop(self) -> None:
        while not self._closed.wait(self.HEARTBEAT_S):
            try:
                self._send_json({
                    "type": "status",
                    "runtime": self._runtime.status(),
                })
            except Exception:
                return

    def _send_json(self, obj: dict) -> None:
        payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self._send_frame(OP_TEXT, payload)

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        """
        Enqueue one frame for the sender thread. Never blocks the producer —
        if the outbound queue is full (slow / dead client), the OLDEST
        pending frame is evicted so this new one can enter.
        """
        if self._closed.is_set():
            return
        item: tuple[int, bytes] = (opcode, payload)
        try:
            self._send_queue.put_nowait(item)
        except _queue.Full:
            # Drop the oldest item so we can enqueue the newest. Old log
            # lines are less valuable than staying live.
            try:
                self._send_queue.get_nowait()
                self._dropped_frames += 1
            except _queue.Empty:
                pass
            try:
                self._send_queue.put_nowait(item)
            except _queue.Full:
                # Racy edge; just give up on this single frame.
                self._dropped_frames += 1

    def _sender_loop(self) -> None:
        """
        Drain self._send_queue → write frames to the socket. Exits when it
        pops the _STOP sentinel, or on socket error. The only place sendall
        is called, so no locking needed around writes.
        """
        while True:
            try:
                item = self._send_queue.get(timeout=0.5)
            except _queue.Empty:
                if self._closed.is_set():
                    return
                continue
            if item is self._STOP:
                return
            opcode, payload = item  # type: ignore[misc]
            frame = _encode_frame(opcode, payload)
            try:
                self._sock.sendall(frame)
            except (BrokenPipeError, ConnectionResetError, OSError):
                self._closed.set()
                return

    # ------------------------------------------------------------------

    def _teardown(self) -> None:
        # Unsubscribe BEFORE _closed flips so no new _emit_event calls race
        # with sender shutdown.
        try:
            self._events.unsubscribe(self._emit_event)
        except Exception:
            pass
        for w in self._watchers:
            w.stop()

        # Queue a CLOSE frame, then a STOP sentinel, so the sender thread
        # can flush the CLOSE before exiting. _send_frame honours _closed,
        # so enqueue CLOSE before setting it.
        try:
            self._send_frame(OP_CLOSE, b"")
        except Exception:
            pass
        self._closed.set()
        try:
            self._send_queue.put_nowait(self._STOP)
        except _queue.Full:
            # Queue was saturated with dropped frames; clear one slot.
            try:
                self._send_queue.get_nowait()
                self._send_queue.put_nowait(self._STOP)
            except (_queue.Empty, _queue.Full):
                pass

        if self._sender_thread is not None:
            self._sender_thread.join(timeout=1.0)

        if self._dropped_frames:
            # Surface under-load diagnostics on teardown; useful when a
            # client is genuinely slower than the event rate.
            import sys as _sys
            _sys.stderr.write(
                f"[builder-api/ws] session dropped {self._dropped_frames} frames\n"
            )

        try:
            self._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Frame codec — server->client frames never mask; client->server frames MUST
# mask per spec. We enforce the masking bit on inbound reads.
# ---------------------------------------------------------------------------


def _encode_frame(opcode: int, payload: bytes) -> bytes:
    header = bytearray()
    header.append(0x80 | (opcode & 0x0F))  # FIN=1
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header.extend(struct.pack(">H", length))
    else:
        header.append(127)
        header.extend(struct.pack(">Q", length))
    return bytes(header) + payload


def _try_read_frame(buf: bytearray) -> Optional[tuple[int, bytes]]:
    """
    Try to pull one complete frame out of `buf`. Returns (opcode, payload) and
    mutates buf (removes consumed bytes), or returns None if the frame is
    incomplete so far. Returns (OP_CLOSE, b"") to signal a protocol error that
    should terminate the session (payload bigger than MAX_INBOUND_FRAME_BYTES).
    """
    if len(buf) < 2:
        return None
    b0, b1 = buf[0], buf[1]
    opcode = b0 & 0x0F
    masked = bool(b1 & 0x80)
    length = b1 & 0x7F
    offset = 2
    if length == 126:
        if len(buf) < offset + 2:
            return None
        length = struct.unpack(">H", bytes(buf[offset:offset + 2]))[0]
        offset += 2
    elif length == 127:
        if len(buf) < offset + 8:
            return None
        length = struct.unpack(">Q", bytes(buf[offset:offset + 8]))[0]
        offset += 8

    # Refuse absurdly large frames before we buffer them — declared-huge
    # payloads would otherwise block the parser forever waiting for bytes.
    if length > MAX_INBOUND_FRAME_BYTES:
        buf.clear()  # discard whatever we had; session will be torn down
        return OP_CLOSE, b""

    mask = b""
    if masked:
        if len(buf) < offset + 4:
            return None
        mask = bytes(buf[offset:offset + 4])
        offset += 4

    if len(buf) < offset + length:
        return None

    payload = bytes(buf[offset:offset + length])
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    del buf[: offset + length]
    return opcode, payload
