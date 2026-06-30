"""app_context — AppContext: wires every subsystem; attached to the handler class."""
from __future__ import annotations
import sys
import threading
import time
from pathlib import Path
from typing import Optional

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import banner as _banner                   # noqa: E402
import config as _config                   # noqa: E402
from build_queue import BuildQueue         # noqa: E402
from events import EventStore              # noqa: E402
from logs import LogStore                  # noqa: E402
from runtime import RuntimeManager         # noqa: E402
from security import AuthGate, SizeLimits  # noqa: E402


def _noop(*_args, **_kwargs) -> None:
    return None


class AppContext:
    def __init__(self, cfg) -> None:
        self.cfg = cfg
        self.start_ts = time.time()

        self.events = EventStore(
            cfg.events.path,
            max_bytes=cfg.events.max_bytes,
            drop_bytes=cfg.events.drop_bytes,
        )
        self.log_store = LogStore(cfg.log_aliases)
        self.size_limits = SizeLimits(cfg)
        self.auth = AuthGate(cfg, self.events.append)

        self.runtime = RuntimeManager(
            cfg, self.events,
            on_run_start=_noop, on_run_exit=_noop,
        )
        self.build_queue = BuildQueue(
            cfg, self.events,
            on_build_start=_noop, on_build_finish=_noop,
        )
        self.build_queue.start()

        # Live event tail: every EventStore.append() surfaces as one
        # colored line on stderr. Subscribed BEFORE the first event so
        # `server_started` lands in the user's view too.
        self.events.subscribe(_banner.event_line)

        # Hot-reload of host config (re-added in v2.9). Watches the
        # api_config directory mtimes; on change, reloads the project
        # view, emits a `config_reloaded` event listing job-set deltas,
        # and reprints the banner. Two safety properties preserved:
        #
        #   (a) audit visibility — every reload emits an event and a
        #       banner reprint, so the surface change is never silent.
        #       This was the v2.4.x concern when ConfigWatcher was
        #       removed; it's addressed here by making the reload LOUD.
        #   (b) host-owned scope — ~/.llm-docker/api_config/ lives on
        #       the host filesystem and is NOT bind-mounted into any
        #       container. A container-side agent can't trigger a
        #       reload by writing files; only Yaro (or the llm-docker
        #       project itself) edits these files.
        self._watch_thread: Optional[threading.Thread] = None
        self._watch_stop = threading.Event()
        self._start_config_watch()

    def shutdown(self) -> None:
        self._watch_stop.set()
        if self._watch_thread is not None:
            self._watch_thread.join(timeout=2.0)
        self.build_queue.shutdown()
        self.runtime.shutdown()

    # ------------------------------------------------------------------
    # Config hot-reload
    # ------------------------------------------------------------------

    def _start_config_watch(self) -> None:
        """Start a daemon thread that polls api_config file mtimes every
        ~1.5s. Polling is good enough — these are host-side hand-edits,
        not high-frequency. inotify/FSEvents would add a platform-
        dependent dep we don't want for one timer."""
        watch_paths: list[Path] = []
        if self.cfg.config_path is not None:
            watch_paths.append(self.cfg.config_path)
        watch_paths.extend(self.cfg.shard_paths)
        if not watch_paths:
            return

        snapshot = {p: self._safe_mtime(p) for p in watch_paths}

        def _watch() -> None:
            while not self._watch_stop.wait(1.5):
                # Re-walk the projects directory too — new shards can
                # appear (a `tomlify.sh slav-ai` after the daemon
                # started). Removed shards drop out of the snapshot
                # the next time around.
                current_paths = [self.cfg.config_path] if self.cfg.config_path else []
                projects_dir = self.cfg.config_path.parent if self.cfg.config_path else None
                if projects_dir and projects_dir.is_dir():
                    for p in sorted(projects_dir.glob("*.toml")):
                        if p not in current_paths:
                            current_paths.append(p)
                changed = False
                fresh: dict[Path, float] = {}
                for p in current_paths:
                    m = self._safe_mtime(p)
                    fresh[p] = m
                    if snapshot.get(p) != m:
                        changed = True
                if set(fresh.keys()) != set(snapshot.keys()):
                    changed = True
                if not changed:
                    continue
                snapshot.clear()
                snapshot.update(fresh)
                self._reload_config()

        t = threading.Thread(target=_watch, name="config-watch", daemon=True)
        t.start()
        self._watch_thread = t

    @staticmethod
    def _safe_mtime(p: Path) -> float:
        try:
            return p.stat().st_mtime
        except OSError:
            return 0.0

    def _reload_config(self) -> None:
        """Re-load the host config + shards. On parse / validation error,
        keep the old config in place and emit a `config_reload_failed`
        event with the error — the daemon stays serving the previous
        good state instead of crashing because a hand-edit dropped a
        comma."""
        old_jobs = set(self.cfg.jobs.keys())
        old_verbs = {
            (name, tuple(sorted(j.platforms.keys())))
            for name, j in self.cfg.jobs.items() if j.is_hub
        }
        try:
            new_cfg = _config.load(self.cfg.name, self.cfg.config_path)
        except SystemExit as e:
            # ConfigError subclasses SystemExit; capture and report.
            self.events.append(
                "config_reload_failed",
                {"project": self.cfg.name, "code": int(e.code or 1)},
            )
            return
        self.cfg = new_cfg
        self.build_queue.update_cfg(new_cfg)
        new_jobs = set(new_cfg.jobs.keys())
        added = sorted(new_jobs - old_jobs)
        removed = sorted(old_jobs - new_jobs)
        new_verbs = {
            (name, tuple(sorted(j.platforms.keys())))
            for name, j in new_cfg.jobs.items() if j.is_hub
        }
        verb_changes = sorted({n for n, _ in (new_verbs ^ old_verbs)})
        self.events.append(
            "config_reloaded",
            {
                "project": new_cfg.name,
                "added": added,
                "removed": removed,
                "verbs_changed": verb_changes,
                "total_jobs": len(new_jobs),
            },
        )
        # Reprint the banner so the operator sees the new job set.
        try:
            sys.stderr.write("\033[2J\033[H")
            _banner.show_banner(
                new_cfg.name, new_cfg.bind, new_cfg.port,
                list(new_cfg.jobs.keys()),
            )
        except Exception:
            pass


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

