"""
build_queue.py — FIFO build queue with long-poll status and log_tail on
completion.

Runs the config-defined `command` (execvp style) with a whitelisted subset
of `allowed_args`. One worker thread drains the queue sequentially. The
handler can long-poll an entry's state via `wait(queue_id, wait_s)` which
blocks on a per-entry Event instead of sleep-looping.
"""

from __future__ import annotations

import os
import secrets
import subprocess
import threading
import time
from collections import deque
from dataclasses import dataclass, field, asdict
from pathlib import Path
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

    def to_public(self) -> dict:
        """Serialisable view. Built explicitly rather than via asdict()
        because asdict() deep-copies every field, and threading.Event
        contains a non-picklable Lock — it crashes before we get a chance
        to drop the field."""
        d: dict = {
            "id": self.id,
            "agent_id": self.agent_id,
            "args": list(self.args),
            "status": self.status,
            "returncode": self.returncode,
            "queued_at": self.queued_at,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "log_tail": self.log_tail,
            "command": self.command,
            "timeout_s": self.timeout_s,
            "elapsed_s": _elapsed(self),
            "queued_at_iso": _iso(self.queued_at),
            "started_at_iso": _iso(self.started_at),
            "finished_at_iso": _iso(self.finished_at),
        }
        if self.job_name is not None:
            d["job_name"] = self.job_name
            d["params"] = self.params or {}
        return d


class BuildQueue:
    """
    A tiny FIFO + worker. The worker thread is started by `start()` and
    daemonized so it dies with the process; tests can stop it via `shutdown()`
    for clean lifecycle.
    """

    def __init__(self, cfg, events, on_build_start=None, on_build_finish=None) -> None:
        self._cfg = cfg
        self._build_cfg = cfg.build
        self._events = events
        self._on_start = on_build_start or (lambda e: None)
        self._on_finish = on_build_finish or (lambda e: None)

        self._lock = threading.Lock()
        self._pending: deque[BuildEntry] = deque()
        self._current: Optional[BuildEntry] = None
        self._history: deque[BuildEntry] = deque(maxlen=HISTORY_CAP)
        self._by_id: dict[str, BuildEntry] = {}

        self._signal = threading.Event()
        self._shutdown = False

        # Log file for build output. Allow the user to declare `build` under
        # [logs] — if they did, we reuse that path so `/logs?file=build` works.
        # Otherwise default to <project_root>/logs/build.log.
        self._build_log = cfg.log_aliases.get("build")
        if self._build_log is None:
            self._build_log = cfg.project_root / "logs" / "build.log"

        self._worker: Optional[threading.Thread] = None

    # ------------------------------------------------------------------
    # Public surface
    # ------------------------------------------------------------------

    def start(self) -> None:
        t = threading.Thread(target=self._run, name="build-queue", daemon=True)
        t.start()
        self._worker = t

    def shutdown(self) -> None:
        self._shutdown = True
        self._signal.set()

    def update_cfg(self, new_cfg) -> None:
        """Swap the queue's cfg reference at hot-reload. New cfg's
        `[build]` settings (allowed_args, max_pending, dedupe_window_s,
        command) apply to subsequent enqueues. In-flight entries keep
        their snapshotted command + timeout — they're not retroactively
        re-validated."""
        with self._lock:
            self._cfg = new_cfg
            self._build_cfg = new_cfg.build

    def enqueue(self, *, args: list[str], agent_id: str) -> BuildEntry:
        """
        Validate args against the legacy `[build].allowed_args` whitelist,
        add the entry to the queue, return it.

        Use `enqueue_job()` for `[jobs.<name>]` templates instead — the two
        paths share a queue but validate differently.

        Raises:
            ValueError  — whitelist violation (caller maps to HTTP 400)
            QueueFull   — pending deque at build.max_pending (caller → 429)
        """
        validated = self._validate_args(args)
        fp = _fingerprint(job_name=None, args=validated)
        return self._enqueue_internal(
            args=tuple(validated),
            command=self._build_cfg.command,
            timeout_s=self._build_cfg.timeout_s,
            agent_id=str(agent_id or ""),
            job_name=None,
            params=None,
            fingerprint=fp,
        )

    def enqueue_job(
        self,
        *,
        args: list[str],
        command: str,
        timeout_s: int,
        job_name: str,
        params: dict,
        agent_id: str,
    ) -> BuildEntry:
        """
        Add a [jobs.<name>] entry to the queue. Caller is responsible for
        having already validated `params` against the Job's placeholders
        and substituted them into `args` (see jobs.validate_and_substitute).
        Caller is also responsible for sha256 verification (see
        jobs.verify_command_hash) — those failures map to 412, not to a
        queue entry.

        Raises:
            QueueFull — pending deque at build.max_pending (caller → 429)
        """
        fp = _fingerprint(job_name=job_name, args=args)
        return self._enqueue_internal(
            args=tuple(args),
            command=command,
            timeout_s=timeout_s,
            agent_id=str(agent_id or ""),
            job_name=job_name,
            params=dict(params) if params else {},
            fingerprint=fp,
        )

    def _enqueue_internal(
        self,
        *,
        args: tuple[str, ...],
        command: str,
        timeout_s: int,
        agent_id: str,
        job_name: Optional[str],
        params: Optional[dict],
        fingerprint: str,
    ) -> BuildEntry:
        with self._lock:
            # Dedupe window: an in-flight or recently-enqueued entry with
            # the same fingerprint reuses its queue_id instead of stacking
            # a duplicate. Defends against AI clients retrying on a flaky
            # poll and accidentally double-running a long build.
            existing = self._find_dedupe(fingerprint)
            if existing is not None:
                return existing

            if len(self._pending) >= self._build_cfg.max_pending:
                raise QueueFull(
                    f"pending queue at capacity ({self._build_cfg.max_pending})"
                )

            entry = BuildEntry(
                id=_short_id(),
                agent_id=agent_id,
                args=args,
                command=command,
                timeout_s=timeout_s,
                job_name=job_name,
                params=params,
                fingerprint=fingerprint,
            )
            self._pending.append(entry)
            self._by_id[entry.id] = entry

        self._signal.set()
        event_payload = {
            "id": entry.id,
            "agent_id": entry.agent_id,
            "args": list(entry.args),
        }
        if job_name is not None:
            event_payload["job"] = job_name
        self._events.append("build_enqueued", event_payload)
        return entry

    def _find_dedupe(self, fingerprint: str) -> Optional[BuildEntry]:
        """Locate any pending/current/recent-history entry with the same
        fingerprint inside the dedupe window. Caller must hold _lock."""
        if not fingerprint:
            return None
        window = self._build_cfg.dedupe_window_s
        if window <= 0:
            return None
        now = time.time()
        # Check pending (always candidates regardless of window — they
        # haven't run yet).
        for e in self._pending:
            if e.fingerprint == fingerprint:
                return e
        # Check the currently-running build.
        if self._current is not None and self._current.fingerprint == fingerprint:
            return self._current
        # Check recent history within the window. If the same args finished
        # less than `window` seconds ago, return that finished entry — the
        # caller will see status=done|failed and not re-run.
        for e in self._history:
            if e.fingerprint != fingerprint:
                continue
            stamp = e.finished_at or e.queued_at
            if stamp and (now - stamp) <= window:
                return e
        return None

    def cancel(self, build_id: str) -> bool:
        """
        Cancel a pending (not-yet-started) build. Returns True on success,
        False if the id wasn't pending (already running, finished, unknown).
        """
        with self._lock:
            for entry in self._pending:
                if entry.id == build_id:
                    self._pending.remove(entry)
                    entry.status = STATUS_CANCELLED
                    entry.finished_at = time.time()
                    entry._done.set()
                    self._history.appendleft(entry)
                    self._events.append(
                        "build_cancelled",
                        {"id": entry.id, "agent_id": entry.agent_id},
                    )
                    return True
        return False

    def wait(self, build_id: str, wait_s: float) -> dict:
        """
        Long-poll a build's status. Blocks up to `wait_s` or until the entry
        reaches a terminal state, whichever comes first. Returns the public
        dict representation with an extra `timed_out` key.
        """
        entry = self._get(build_id)
        if entry is None:
            return {"id": build_id, "status": "gone", "timed_out": False}

        if entry.status not in TERMINAL and wait_s > 0:
            entry._done.wait(timeout=min(wait_s, 60.0))

        out = entry.to_public()
        out["timed_out"] = entry.status not in TERMINAL
        return out

    def snapshot(self) -> dict:
        """Current queue state for the `/queue` endpoint."""
        with self._lock:
            return {
                "current": self._current.to_public() if self._current else None,
                "pending": [e.to_public() for e in self._pending],
                "history": [e.to_public() for e in self._history],
            }

    def current(self) -> Optional[BuildEntry]:
        with self._lock:
            return self._current

    # ------------------------------------------------------------------
    # Worker loop
    # ------------------------------------------------------------------

    def _run(self) -> None:
        while not self._shutdown:
            entry = self._pop_next()
            if entry is None:
                self._signal.wait(timeout=1.0)
                self._signal.clear()
                continue
            if entry.status == STATUS_CANCELLED:
                continue
            self._execute(entry)

    def _pop_next(self) -> Optional[BuildEntry]:
        with self._lock:
            if self._current is not None:
                return None
            if not self._pending:
                return None
            entry = self._pending.popleft()
            self._current = entry
            return entry

    def _execute(self, entry: BuildEntry) -> None:
        entry.status = STATUS_BUILDING
        entry.started_at = time.time()
        try:
            self._on_start(entry)
        except Exception:
            pass
        self._events.append(
            "build_started",
            {"id": entry.id, "agent_id": entry.agent_id, "args": list(entry.args)},
        )

        # Snapshot at enqueue time. We never re-resolve at execute time, so
        # a hot-reload of `.builder-api.toml` between enqueue and execute
        # can't change what's already in flight.
        cmd = [entry.command or self._build_cfg.command, *entry.args]
        timeout = entry.timeout_s or self._build_cfg.timeout_s

        # Open the build log for append; subprocess writes stdout+stderr there.
        self._build_log.parent.mkdir(parents=True, exist_ok=True)
        log_header = (
            f"\n=== build {entry.id} agent={entry.agent_id or '?'} "
            f"args={list(entry.args)} start={_iso(entry.started_at)} ===\n"
        )
        try:
            with self._build_log.open("ab") as log_f:
                log_f.write(log_header.encode("utf-8"))
                log_f.flush()
                proc = subprocess.Popen(
                    cmd,
                    cwd=str(self._cfg.project_root),
                    stdout=log_f,
                    stderr=subprocess.STDOUT,
                    shell=False,                 # execvp, never /bin/sh -c
                    start_new_session=True,     # new pg so timeout kills children
                    env=os.environ.copy(),
                )
        except FileNotFoundError:
            self._finalize(entry, returncode=127, reason="command not found")
            return
        except OSError as e:
            self._finalize(entry, returncode=126, reason=f"launch failed: {e}")
            return

        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_process_group(proc)
            rc = -1
            self._finalize(entry, returncode=rc, reason="timeout")
            return

        self._finalize(entry, returncode=rc, reason=None)

    def _finalize(
        self,
        entry: BuildEntry,
        *,
        returncode: int,
        reason: Optional[str],
    ) -> None:
        entry.returncode = returncode
        entry.finished_at = time.time()
        entry.status = STATUS_DONE if returncode == 0 else STATUS_FAILED
        entry.log_tail = _tail_text(self._build_log, LOG_TAIL_LINES)

        with self._lock:
            self._history.appendleft(entry)
            self._current = None

        entry._done.set()
        self._signal.set()

        try:
            self._on_finish(entry)
        except Exception:
            pass

        event_payload = {
            "id": entry.id,
            "agent_id": entry.agent_id,
            "status": entry.status,
            "returncode": returncode,
            "elapsed_s": _elapsed(entry),
        }
        if reason:
            event_payload["reason"] = reason
        self._events.append("build_finished", event_payload)

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _get(self, build_id: str) -> Optional[BuildEntry]:
        with self._lock:
            return self._by_id.get(build_id)

    def _validate_args(self, args) -> list[str]:
        if args is None:
            return []
        if not isinstance(args, (list, tuple)):
            raise ValueError("args must be a list of strings")
        allowed = set(self._build_cfg.allowed_args)
        out: list[str] = []
        for a in args:
            if not isinstance(a, str):
                raise ValueError("args must be strings")
            # Strict whitelist: empty `allowed_args = []` means NO args
            # allowed (not "any args allowed"). This is the safer default
            # — projects that want unrestricted args should use [jobs.*]
            # with explicit placeholder regexes instead.
            if a not in allowed:
                raise ValueError(
                    f"arg {a!r} not in whitelist. Allowed: "
                    f"{sorted(allowed) or '[]'}"
                )
            out.append(a)
        return out


# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------


def _short_id() -> str:
    # 8 hex chars is plenty for "recent build" cardinality; avoids full uuids.
    return secrets.token_hex(4)


def _fingerprint(*, job_name: Optional[str], args) -> str:
    """Stable hash of the request shape, used as the dedupe key. We hash
    rather than concatenate so the key length is bounded regardless of how
    long the args end up. agent_id is intentionally excluded — two agents
    racing to enqueue the same operation should collapse onto one queue_id,
    not run twice."""
    import hashlib
    h = hashlib.sha256()
    h.update((job_name or "__build__").encode("utf-8"))
    h.update(b"\0")
    for a in args:
        h.update(a.encode("utf-8"))
        h.update(b"\0")
    return h.hexdigest()[:16]


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


def _kill_process_group(proc: subprocess.Popen) -> None:
    """Kill the whole process group we spawned; otherwise timed-out builds
    leave child processes running."""
    import signal
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    # Give the tree a few seconds to shut down, then SIGKILL survivors.
    for _ in range(30):
        if proc.poll() is not None:
            return
        time.sleep(0.1)
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def _tail_text(path: Path, n: int) -> str:
    """Small dup of logs._tail_text to avoid a circular import."""
    if not path.exists():
        return ""
    try:
        size = path.stat().st_size
    except OSError:
        return ""
    if size == 0:
        return ""
    block = 65536
    data = bytearray()
    newlines = 0
    with path.open("rb") as f:
        pos = size
        while pos > 0 and newlines <= n:
            read_size = block if pos >= block else pos
            pos -= read_size
            f.seek(pos)
            data[:0] = f.read(read_size)
            newlines = data.count(b"\n")
    lines = data.decode("utf-8", errors="replace").splitlines()
    if len(lines) > n:
        lines = lines[-n:]
    return "\n".join(lines)
