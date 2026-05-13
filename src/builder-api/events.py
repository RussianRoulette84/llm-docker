"""
events.py — JSON-lines structured event feed with cap-and-drop rotation.

Two consumers:
  - The HTTP handler calls `store.query(...)` to answer `/events?type=&...`.
  - `security.py` (and future plugin code) call `store.append(type, payload)`
    to record notable events like `auth_failure_lockout`, build lifecycle, etc.

External producers (a build subprocess emitting its own JSON lines) can write
to the same file directly — we only need a read-side filter here. The
rotation is triggered on append; external writers don't get the cap-and-drop
behavior, which is fine because they typically batch small records.
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path
from typing import Optional


class EventStore:
    """
    Append + query a JSONL file. Thread-safe on the writer side; readers open
    their own fd and stream-scan, so they don't block writers.

    Record shape on append:
        {"ts": <unix seconds float>, "type": <str>, "pid": <int or null>, **payload}

    External writers are free to add extra keys; the filter only looks at
    `ts`, `type`, and `pid`.

    Live subscribers: ws.py registers one callback per WebSocket session so
    events propagate to open clients without polling. Callbacks run INLINE
    from append(); they're expected to be fast (push onto the session's send
    queue and return). Slow subscribers throttle append — see _notify().
    """

    def __init__(
        self,
        path: Optional[Path],
        *,
        max_bytes: int,
        drop_bytes: int,
    ) -> None:
        self._path = path
        self._max_bytes = max_bytes
        self._drop_bytes = drop_bytes
        self._lock = threading.Lock()
        self._sub_lock = threading.Lock()
        self._subscribers: list = []   # list[Callable[[dict], None]]

    # ------------------------------------------------------------------
    # Live subscription (used by WebSocket sessions)
    # ------------------------------------------------------------------

    def subscribe(self, callback) -> None:
        """Register a callback that will receive every future appended record."""
        with self._sub_lock:
            self._subscribers.append(callback)

    def unsubscribe(self, callback) -> None:
        """Idempotent — safe to call even if never subscribed (e.g. early teardown)."""
        with self._sub_lock:
            try:
                self._subscribers.remove(callback)
            except ValueError:
                pass

    def _notify(self, record: dict) -> None:
        """Fan out `record` to all subscribers. Snapshot the list first so a
        callback that unsubscribes during iteration doesn't mutate the cursor."""
        with self._sub_lock:
            subs = list(self._subscribers)
        for cb in subs:
            try:
                cb(record)
            except Exception:
                # Never let a subscriber fault break the producer — appends
                # must succeed even if every client has a broken socket.
                pass

    # ------------------------------------------------------------------
    # Write side
    # ------------------------------------------------------------------

    def append(self, type_: str, payload: Optional[dict] = None) -> None:
        """
        Append one event. Fans out to live subscribers regardless of whether
        a persistence path is configured (so /ws tunneling still works even
        with events.path unset). File write is skipped if path is None.
        Triggers rotation on file when appended bytes would exceed max_bytes.
        """
        record = {"ts": time.time(), "type": str(type_)}
        if payload:
            # payload keys may shadow ts/type on the client's say-so; we
            # prefer our own for the base fields but merge the rest.
            for k, v in payload.items():
                if k in ("ts", "type"):
                    continue
                record[k] = v

        # Persist (if configured).
        if self._path is not None:
            line = json.dumps(record, ensure_ascii=False, default=_json_safe) + "\n"
            data = line.encode("utf-8")
            with self._lock:
                self._rotate_if_needed(extra=len(data))
                try:
                    # "ab" is safe across processes on POSIX thanks to O_APPEND;
                    # each write is atomic up to PIPE_BUF (4 KB on macOS). Event
                    # records are tiny so this is fine.
                    self._path.parent.mkdir(parents=True, exist_ok=True)
                    with self._path.open("ab") as f:
                        f.write(data)
                except OSError:
                    # Event logging must never break the request path.
                    pass

        # Notify live subscribers AFTER the file write so anyone who sees the
        # event and then queries /events won't get a "not there yet" surprise.
        self._notify(record)

    def _rotate_if_needed(self, *, extra: int) -> None:
        """
        If appending `extra` bytes would push us over max_bytes, drop the
        oldest ~drop_bytes from the file. Keeps the stream "rolling" without
        moving files aside or risking mid-rotation gaps for external tailers.
        """
        if self._path is None or not self._path.exists():
            return
        try:
            size = self._path.stat().st_size
        except OSError:
            return
        if size + extra <= self._max_bytes:
            return

        drop = min(self._drop_bytes, size)
        try:
            with self._path.open("rb") as f:
                f.seek(drop)
                # Align to the next full line so queries don't see a half-line.
                first_nl = f.read(256 * 1024).find(b"\n")
                if first_nl >= 0:
                    f.seek(drop + first_nl + 1)
                else:
                    f.seek(drop)  # no newline in the first 256 KB — just cut
                remaining = f.read()
            self._path.write_bytes(remaining)
        except OSError:
            pass

    # ------------------------------------------------------------------
    # Read side
    # ------------------------------------------------------------------

    def query(
        self,
        *,
        type_: Optional[str] = None,
        since: Optional[float] = None,
        n: int = 200,
        pid: Optional[int] = None,
    ) -> dict:
        """
        Scan the file and return the last `n` matching events. Matching
        predicate: (type matches if given) AND (ts >= since if given)
        AND (pid == pid if given).

        Response: {"events": [...], "count": <matched kept>, "total": <lines scanned>}
        """
        n = max(1, min(int(n), 10_000))

        if self._path is None or not self._path.exists():
            return {"events": [], "count": 0, "total": 0}

        events: list[dict] = []
        total = 0
        try:
            with self._path.open("r", encoding="utf-8", errors="replace") as f:
                for raw in f:
                    total += 1
                    line = raw.rstrip("\n")
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if type_ is not None and rec.get("type") != type_:
                        continue
                    if since is not None:
                        ts = rec.get("ts")
                        if not isinstance(ts, (int, float)) or ts < since:
                            continue
                    if pid is not None and rec.get("pid") != pid:
                        continue
                    events.append(rec)
        except OSError:
            return {"events": [], "count": 0, "total": total}

        if len(events) > n:
            events = events[-n:]
        return {"events": events, "count": len(events), "total": total}


# ---------------------------------------------------------------------------
# json.dumps safety valve — convert Path / bytes / non-serialisable objects
# to str rather than raising and losing a whole event record.
# ---------------------------------------------------------------------------

def _json_safe(o):
    if isinstance(o, Path):
        return str(o)
    if isinstance(o, bytes):
        return o.decode("utf-8", errors="replace")
    return str(o)
