"""build_models — queue status constants, QueueFull, BuildEntry + iso/elapsed helpers (split from build_queue.py)."""
from __future__ import annotations
import threading
import time
from collections import deque  # noqa: F401
from dataclasses import dataclass, field
from pathlib import Path  # noqa: F401
from typing import Optional

# Statuses form a simple lifecycle:
#   queued  → building → done | failed | cancelled
STATUS_QUEUED    = "queued"
STATUS_BUILDING  = "building"
STATUS_DONE      = "done"
STATUS_FAILED    = "failed"
STATUS_CANCELLED = "cancelled"
TERMINAL = {STATUS_DONE, STATUS_FAILED, STATUS_CANCELLED}

HISTORY_CAP = 20
LOG_TAIL_LINES = 40


class QueueFull(Exception):
    """Raised by BuildQueue.enqueue when the pending deque is at max_pending.
    server.py maps this to HTTP 429 so authed-but-abusive clients can't
    exhaust memory by spamming POST /build."""


@dataclass
class BuildEntry:
    id: str
    agent_id: str
    args: tuple[str, ...]
    status: str = STATUS_QUEUED
    returncode: Optional[int] = None
    queued_at: float = field(default_factory=time.time)
    started_at: Optional[float] = None
    finished_at: Optional[float] = None
    log_tail: str = ""
    # Per-entry command + timeout snapshot. Set at enqueue time so a
    # hot-reload of `.builder-api.toml` between enqueue and execute can't
    # change what's running. Legacy [build] callers fill these from
    # cfg.build; job callers fill them from the resolved Job.
    command: str = ""
    timeout_s: int = 0
    # SIGTERM→SIGKILL grace window (seconds). 0 = use the helper's default (3s).
    kill_after_s: int = 0
    # Subdir (relative to project_root) the subprocess runs in. "." = project
    # root. Snapshotted at enqueue time so a mid-flight hot-reload can't move
    # the goalposts on a building job.
    cwd: str = "."
    # Set when this entry came from POST /job/<name>; None for legacy /build.
    # Surfaces in to_public() so /queue and /build_status callers can tell
    # which job a build came from.
    job_name: Optional[str] = None
    # Echo of validated placeholder values (jobs only) — useful for audit
    # trail and debugging. None for legacy build.
    params: Optional[dict] = None
    # Stable fingerprint for the dedupe window. Derived from job_name+args
    # at enqueue time. Internal; not exposed in to_public().
    fingerprint: str = field(default="", repr=False)
    _done: threading.Event = field(default_factory=threading.Event, repr=False)
    # Live subprocess handle. Populated only while the entry is `building`.
    # Used by `BuildQueue.cancel_current()` to signal the running process
    # group from another thread. Never serialized.
    _proc: object = field(default=None, repr=False)
    # Byte offset into the shared build log file where THIS entry's output
    # starts. Captured before the subprocess is launched so the log-tail
    # render at _finalize() can be scoped to just this build instead of
    # leaking the tail of whatever previous build wrote into the same
    # file. 0 = read from start (used when the build never reached
    # subprocess launch — e.g. cwd-escape rejection in _execute()).
    log_start_offset: int = field(default=0, repr=False)
    # Why this entry reached its terminal state. Currently surfaces only
    # via `wait()` to disambiguate `build_timed_out` (subprocess hit its
    # own timeout_s) from `poll_timed_out` (the long-poll wait expired).
    # None until `_finalize()` runs.
    finished_reason: Optional[str] = None

    def to_public(self, *, include_log_tail: bool = True) -> dict:
        """Serialisable view. Built explicitly rather than via asdict()
        because asdict() deep-copies every field, and threading.Event
        contains a non-picklable Lock — it crashes before we get a chance
        to drop the field.

        `include_log_tail=False` is used by /queue's history view to keep
        per-poll responses tight (every history entry was carrying ~3 KB
        of log text; on a busy day /queue ballooned past 100 KB). The
        full log_tail is still available via /build_status?id=<id>.
        """
        d: dict = {
            "id": self.id,
            "agent_id": self.agent_id,
            "args": list(self.args),
            "status": self.status,
            "returncode": self.returncode,
            "queued_at": self.queued_at,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "command": self.command,
            "timeout_s": self.timeout_s,
            "elapsed_s": _elapsed(self),
            "queued_at_iso": _iso(self.queued_at),
            "started_at_iso": _iso(self.started_at),
            "finished_at_iso": _iso(self.finished_at),
        }
        if include_log_tail:
            d["log_tail"] = self.log_tail
        if self.job_name is not None:
            d["job_name"] = self.job_name
            d["params"] = self.params or {}
        return d



def _iso(ts: Optional[float]) -> Optional[str]:
    if ts is None:
        return None
    import datetime as _dt
    return _dt.datetime.fromtimestamp(ts, tz=_dt.timezone.utc).isoformat()


def _elapsed(entry: BuildEntry) -> Optional[float]:
    if entry.started_at is None:
        return None
    end = entry.finished_at if entry.finished_at is not None else time.time()
    return round(end - entry.started_at, 3)


