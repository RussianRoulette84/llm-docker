"""build_helpers — id/fingerprint/container/kill/tail utilities (split from build_queue.py)."""
from __future__ import annotations
import hashlib
import os  # noqa: F401
import secrets
import signal  # noqa: F401
import subprocess
import time
from pathlib import Path
from typing import Optional  # noqa: F401

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


def _resolve_managed_container(project_name: str) -> str:
    """Return the container ID of the running container labelled
    `llm-docker-project=<project_name>`, or empty string if none found.
    cld/ocd set this label at `docker run` time so wrapper jobs can
    `docker exec {{container}} ...` without hardcoding the volatile
    `claude-<PID>` container name."""
    try:
        r = subprocess.run(
            [
                "docker", "ps",
                "--filter", f"label=llm-docker-project={project_name}",
                "-q",
            ],
            capture_output=True, text=True, timeout=5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""
    if r.returncode != 0:
        return ""
    ids = [ln.strip() for ln in r.stdout.split("\n") if ln.strip()]
    return ids[0] if ids else ""


def _kill_process_group(proc: subprocess.Popen, *, grace_s: Optional[int] = None) -> None:
    """Kill the whole process group we spawned; otherwise timed-out builds
    leave child processes running. `grace_s` is the SIGTERM→SIGKILL window
    (default 3s, configurable per-job via `[jobs.<name>].kill_after_s`)."""
    import signal
    grace = grace_s if grace_s and grace_s > 0 else 3
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    # Poll every 100 ms for `grace` seconds, then SIGKILL stragglers.
    for _ in range(int(grace * 10)):
        if proc.poll() is not None:
            return
        time.sleep(0.1)
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def _tail_text(path: Path, n: int, *, start_offset: int = 0) -> str:
    """Read the last `n` lines of `path` starting at `start_offset` bytes.

    `start_offset` scopes the tail to a per-build slice of a shared log
    file — _execute() captures the file size before launching each build,
    and _finalize() passes that offset back here so build N+1's log_tail
    can't leak the end of build N's output. Pass 0 (default) to read the
    whole file (matches the original behaviour).

    Small duplicate of logs._tail_text to avoid a circular import.
    """
    if not path.exists():
        return ""
    try:
        size = path.stat().st_size
    except OSError:
        return ""
    if size <= start_offset:
        return ""
    span = size - start_offset
    block = 65536
    data = bytearray()
    newlines = 0
    with path.open("rb") as f:
        pos = size
        # Read backwards but never cross the per-build start offset —
        # everything before it belongs to a prior build's output.
        while pos > start_offset and newlines <= n:
            read_size = block if (pos - start_offset) >= block else (pos - start_offset)
            pos -= read_size
            f.seek(pos)
            data[:0] = f.read(read_size)
            newlines = data.count(b"\n")
    lines = data.decode("utf-8", errors="replace").splitlines()
    if len(lines) > n:
        lines = lines[-n:]
    return "\n".join(lines)
