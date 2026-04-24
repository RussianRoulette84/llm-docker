"""
runtime.py — /run, /stop, /status for the long-lived `start_command`.

Semantics the plan pinned down:
  * /run     — always produce a freshly-started process. If one exists,
                 stop it first (stop_signal → stop_timeout_s → SIGKILL),
                 then start.
  * /stop    — stop if running, leave down.
  * /status  — poll PID with kill(pid, 0); if the child died on its own,
                 we notice without having to be told.
  * daemon shutdown (SIGINT/SIGTERM on the SERVER) kills the runtime
                 process group before exit, so no orphans.

Subprocess is spawned with `start_new_session=True` so signalling the
process group (negative PID) reaches children spawned by the start_command.
"""

from __future__ import annotations

import os
import shlex
import signal
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional


class RuntimeManager:
    """
    One instance per daemon. All state is behind `self._lock`; the only thing
    the HTTP handler touches is `status()` / `run()` / `stop()`.
    """

    def __init__(self, cfg, events, on_run_start=None, on_run_exit=None) -> None:
        self._rt_cfg = cfg.runtime
        self._project_root = cfg.project_root
        self._events = events
        self._on_run_start = on_run_start or (lambda pid: None)
        self._on_run_exit = on_run_exit or (lambda pid, signal_name: None)

        self._lock = threading.Lock()
        self._proc: Optional[subprocess.Popen] = None
        self._started_at: Optional[float] = None

    # ------------------------------------------------------------------
    # Status
    # ------------------------------------------------------------------

    def status(self) -> dict:
        """
        Returns `{enabled, running, pid, uptime_s}`. Calls kill(pid, 0) to
        detect external death — otherwise `_proc.poll()` alone is enough,
        but polling across threads can race, so both checks live here.
        """
        with self._lock:
            if self._proc is None:
                return {
                    "enabled": self._rt_cfg.enabled,
                    "running": False,
                    "pid": None,
                    "uptime_s": None,
                }
            # poll() reaps if the child died; kill(pid, 0) handles weird cases.
            if self._proc.poll() is not None or not _pid_alive(self._proc.pid):
                pid = self._proc.pid
                rc = self._proc.returncode
                self._proc = None
                self._started_at = None
                self._events.append(
                    "runtime_exited",
                    {"pid": pid, "returncode": rc, "cause": "self_exit"},
                )
                try:
                    self._on_run_exit(pid, "self_exit")
                except Exception:
                    pass
                return {
                    "enabled": self._rt_cfg.enabled,
                    "running": False,
                    "pid": None,
                    "uptime_s": None,
                }
            return {
                "enabled": self._rt_cfg.enabled,
                "running": True,
                "pid": self._proc.pid,
                "uptime_s": round(time.time() - (self._started_at or 0), 3),
            }

    # ------------------------------------------------------------------
    # Run / stop
    # ------------------------------------------------------------------

    def run(self) -> dict:
        """
        Restart semantic: stop any existing process, then start fresh.
        Returns a dict suitable for the HTTP response.
        """
        if not self._rt_cfg.enabled:
            return {"ok": False, "error": "runtime disabled in config"}
        if not self._rt_cfg.start_command:
            return {"ok": False, "error": "runtime.start_command is empty"}

        with self._lock:
            if self._proc is not None and self._proc.poll() is None:
                self._stop_locked(cause="restart")
            try:
                proc = self._spawn_locked()
            except (FileNotFoundError, OSError) as e:
                return {"ok": False, "error": f"launch failed: {e}"}
            self._proc = proc
            self._started_at = time.time()

        self._events.append("runtime_started", {"pid": proc.pid})
        try:
            self._on_run_start(proc.pid)
        except Exception:
            pass
        return {"ok": True, "pid": proc.pid}

    def stop(self) -> dict:
        """
        Stop if running; returns the final state. Idempotent: calling /stop
        when nothing's running is a 200 with ok=True.
        """
        with self._lock:
            if self._proc is None or self._proc.poll() is not None:
                self._proc = None
                self._started_at = None
                return {"ok": True, "running": False}
            self._stop_locked(cause="api_stop")
        return {"ok": True, "running": False}

    # ------------------------------------------------------------------
    # Daemon shutdown hook — kill our runtime before exiting so no orphans.
    # ------------------------------------------------------------------

    def shutdown(self) -> None:
        with self._lock:
            if self._proc is not None and self._proc.poll() is None:
                self._stop_locked(cause="daemon_shutdown")

    # ------------------------------------------------------------------
    # Internals (all assume self._lock is held by the caller)
    # ------------------------------------------------------------------

    def _spawn_locked(self) -> subprocess.Popen:
        # Config's `cwd` is declared relative-to-project-root in toml; if the
        # user wrote an absolute path that still needs to sit inside the
        # project, we just trust them since this is their own config file.
        cwd = Path(self._rt_cfg.cwd)
        if not cwd.is_absolute():
            cwd = self._project_root / cwd

        argv = shlex.split(self._rt_cfg.start_command)
        env = os.environ.copy()
        env.update(self._rt_cfg.env)
        proc = subprocess.Popen(
            argv,
            cwd=str(cwd),
            env=env,
            shell=False,
            start_new_session=True,  # so we can killpg without hitting self
        )
        return proc

    def _stop_locked(self, *, cause: str) -> None:
        if self._proc is None:
            return
        pid = self._proc.pid
        sig = _signal_by_name(self._rt_cfg.stop_signal)

        try:
            os.killpg(os.getpgid(pid), sig)
        except ProcessLookupError:
            self._proc = None
            self._started_at = None
            return
        except PermissionError:
            pass

        deadline = time.time() + max(0.5, float(self._rt_cfg.stop_timeout_s))
        while time.time() < deadline:
            if self._proc.poll() is not None:
                break
            time.sleep(0.1)

        if self._proc.poll() is None:
            # Graceful window expired — SIGKILL the whole group.
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            self._proc.wait(timeout=2.0)

        rc = self._proc.returncode
        self._proc = None
        self._started_at = None
        self._events.append(
            "runtime_stopped",
            {"pid": pid, "returncode": rc, "cause": cause},
        )
        try:
            self._on_run_exit(pid, cause)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _signal_by_name(name: str):
    n = (name or "").upper().strip()
    if not n.startswith("SIG"):
        n = "SIG" + n
    return getattr(signal, n, signal.SIGTERM)


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Exists but we can't signal it — alive from our POV.
        return True
    return True
