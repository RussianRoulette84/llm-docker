"""
hot_reload.py — background watcher that re-loads `.builder-api.toml`
when its mtime changes, and applies the new config in-place without
restarting the daemon.

Hot-reloads:
  - `[jobs.*]` (new templates / placeholder edits visible on next /jobs)
  - `[build].allowed_args`, `[build].max_pending`, `[build].dedupe_window_s`,
    `[build].command`, `[build].timeout_s` (apply to NEW enqueues only;
    in-flight builds keep their snapshotted command + timeout)
  - `[logs]` aliases (new aliases reachable immediately)

Does NOT hot-reload (require a daemon restart):
  - `[runtime]`        — already-running process; reload would orphan it
  - `[security]`       — ratelimit/lockout state is in-memory and tied
                         to the existing AuthGate
  - `[events].path`    — opening a different jsonl midway corrupts ordering
  - `plugin = "..."`   — plugins can register arbitrary state at import
                         time; reload would need a teardown contract we
                         haven't promised

Design notes:
- Polls mtime every `poll_interval_s` (default 1.5s). Cheap stat() vs.
  pulling in inotify/FSEvents/kqueue (which would be a per-platform
  dance). On change: re-parse via config.load(), atomic-swap on success,
  log + keep old on parse failure.
- `Config.config_mtime` exposed via /jobs lets clients (e.g. the bundled
  MCP) detect when their cached schema is stale.
"""

from __future__ import annotations

import sys
import threading
import time
from typing import Callable, Optional

import config as _config


class ConfigWatcher:
    def __init__(
        self,
        *,
        on_reload: Callable[[object], None],
        poll_interval_s: float = 1.5,
    ) -> None:
        """
        on_reload: callback invoked with the new Config object after a
                   successful re-parse. Must be idempotent and threadsafe;
                   it runs on the watcher thread.
        """
        self._on_reload = on_reload
        self._poll_interval_s = poll_interval_s

        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._last_mtime: float = 0.0

    def start(self, current_cfg) -> None:
        if self._thread is not None:
            return
        # Seed `last_mtime` from the initial cfg so we don't fire a redundant
        # reload on the first poll just because we didn't track the load.
        self._last_mtime = current_cfg.config_mtime
        t = threading.Thread(
            target=self._run,
            args=(current_cfg.config_path,),
            name="config-watcher",
            daemon=True,
        )
        t.start()
        self._thread = t

    def stop(self) -> None:
        self._stop.set()

    def _run(self, path) -> None:
        while not self._stop.wait(self._poll_interval_s):
            if path is None:
                # No config path stamped at load time — should not happen
                # in normal flow. Bail out cleanly.
                return
            try:
                mtime = path.stat().st_mtime
            except OSError:
                # File transiently missing during an editor swap-write.
                # Skip this tick and retry on the next one.
                continue
            if mtime == self._last_mtime:
                continue
            # mtime changed — try to reload.
            try:
                new_cfg = _config.load(path.parent)
            except SystemExit:
                # config.ConfigError inherits SystemExit so the daemon dies
                # on bad initial configs. We DON'T want a hot-reload to kill
                # a healthy server, so we catch + keep the old cfg. The
                # ConfigError already printed to stderr.
                sys.stderr.write(
                    "[builder-api] hot-reload aborted — keeping previous "
                    f"config (last good mtime={self._last_mtime})\n"
                )
                # Bump _last_mtime to the bad-file mtime so we don't retry
                # every tick — only retry once the file changes again.
                self._last_mtime = mtime
                continue
            except Exception as e:
                sys.stderr.write(
                    f"[builder-api] hot-reload exception ({e!r}) — keeping "
                    "previous config\n"
                )
                self._last_mtime = mtime
                continue

            self._last_mtime = new_cfg.config_mtime
            sys.stderr.write(
                f"[builder-api] config reloaded ({new_cfg.config_path.name}) "
                f"— {len(new_cfg.jobs)} job(s), "
                f"{len(new_cfg.log_aliases)} log alias(es)\n"
            )
            try:
                self._on_reload(new_cfg)
            except Exception as e:
                sys.stderr.write(
                    f"[builder-api] hot-reload callback raised: {e!r}\n"
                )
