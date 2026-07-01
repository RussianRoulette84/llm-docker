#!/usr/bin/env python3
"""
builder-api — a project-agnostic HTTP daemon for build / run / logs /
events, designed to be called by the Docker container (Claude, OpenCode)
running on the host via host.docker.internal.

Boot flow (`python3 server.py --project <name>`):

    1. config.load(project)     → read ~/.llm-docker/api_config/builder-api.toml,
                                  resolve global + language + project view
    2. events.EventStore(...)   → open jsonl feed (or no-op if disabled)
    3. BuildQueue(...).start()  → spawn worker thread
    4. RuntimeManager(...)      → track /run process
    5. SizeLimits + AuthGate    → per-request clamps + auth
    6. ThreadingHTTPServer(...) → bind and serve_forever
    7. SIGINT/SIGTERM handler   → shut down queue + runtime, exit clean

The handler is intentionally flat: one `dispatch()` per method, one
small per-endpoint function. No decorators, no framework magic.
"""
from __future__ import annotations

import os
import signal
import sys
from http.server import ThreadingHTTPServer
from pathlib import Path
from typing import Optional

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import banner as _banner                   # noqa: E402
import config as _config                   # noqa: E402
from app_context import AppContext         # noqa: E402
from http_handler import BuilderHandler    # noqa: E402


def _parse_args(argv: list[str]) -> tuple[str, Optional[Path]]:
    """Returns (project_name, config_path_override). Tiny stdlib parser
    so we don't need argparse for two flags."""
    project: Optional[str] = None
    config_override: Optional[Path] = None
    it = iter(argv)
    for tok in it:
        if tok == "--project":
            project = next(it, None)
        elif tok.startswith("--project="):
            project = tok.split("=", 1)[1]
        elif tok == "--config":
            v = next(it, None)
            config_override = Path(v).expanduser() if v else None
        elif tok.startswith("--config="):
            config_override = Path(tok.split("=", 1)[1]).expanduser()
    if not project:
        # Fallback: basename of cwd, so old `python3 server.py` invocations
        # in a project root still work for one-off testing.
        project = Path.cwd().name
    return project, config_override


def main() -> int:
    project_name, config_override = _parse_args(sys.argv[1:])
    cfg = _config.load(project_name, config_path=config_override)

    app = AppContext(cfg)
    BuilderHandler.app = app
    # Request-read timeout (slowloris protection). Per-socket; doesn't bound
    # long-poll or WebSocket lifetime since those don't read from the socket
    # during their wait. Build subprocess timeout is [build].timeout_s.
    BuilderHandler.timeout = max(1, int(cfg.security.request_timeout_s))

    # Install signal handlers BEFORE binding so a fast Ctrl-C still cleans up.
    server_holder: dict = {}

    def _graceful_exit(signum, frame):  # type: ignore[no-untyped-def]
        # Signal handlers run on the main thread, which is also the thread
        # blocked in `serve_forever()`. Calling `server.shutdown()` here
        # deadlocks (shutdown waits for serve_forever to return, which can't
        # because the main thread is stuck in the signal handler). Same for
        # `app.shutdown()` if any subsystem joins on the main thread.
        # So: just `os._exit(0)` immediately. Daemon threads (build worker,
        # config watcher, runtime) die with the process; in-flight subprocs
        # were spawned with `start_new_session=True` so they're in their
        # own process group and survive briefly until docker compose / make
        # / etc. finish naturally.
        sys.stderr.write(f"\n[builder-api] received signal {signum}, exiting.\n")
        os._exit(0)

    signal.signal(signal.SIGINT, _graceful_exit)
    signal.signal(signal.SIGTERM, _graceful_exit)

    # Re-render the banner + recent event history when the iTerm pane is
    # resized. iTerm/Terminal deliver SIGWINCH to the foreground process
    # when columns/rows change; without a handler the boot banner stays
    # at the old width while the new event tail wraps at the new width
    # — visually inconsistent. We clear the screen, reprint the banner
    # at the new size, then REPLAY the last ~40 events through
    # banner.event_line so the user keeps their scroll history instead
    # of seeing a blank pane.
    def _winch_handler(_signum, _frame):  # type: ignore[no-untyped-def]
        try:
            sys.stderr.write("\033[2J\033[H")
            _banner.show_banner(
                cfg.name, cfg.bind, cfg.port, list(cfg.jobs.keys())
            )
            try:
                recent = app.events.query(n=40)
                for ev in recent.get("events") or []:
                    # Skip server_started — the banner above already
                    # represents the same "we're up" signal, and we
                    # don't want a stale-looking duplicate.
                    if ev.get("type") == "server_started":
                        continue
                    _banner.event_line(ev)
            except Exception:
                pass
        except Exception:
            # Signal handlers must NEVER raise — the user just resized
            # their pane, the daemon must not die for it. Silently absorb
            # any write/encoding failure.
            pass

    try:
        signal.signal(signal.SIGWINCH, _winch_handler)
    except (AttributeError, ValueError):
        # SIGWINCH doesn't exist on Windows, and signal.signal in a
        # non-main thread raises ValueError. We're in main, but the
        # belt-and-suspenders absorbs both cases for portability.
        pass

    try:
        server = ThreadingHTTPServer((cfg.bind, cfg.port), BuilderHandler)
    except OSError as e:
        sys.stderr.write(f"[builder-api] bind failed on {cfg.bind}:{cfg.port}: {e}\n")
        return 1
    server_holder["server"] = server

    # Banner first, then the event — otherwise `server_started` would
    # print on top of the ASCII art via the live subscription.
    _banner.show_banner(cfg.name, cfg.bind, cfg.port, list(cfg.jobs.keys()))
    app.events.append(
        "server_started",
        {
            "name": cfg.name,
            "bind": cfg.bind,
            "port": cfg.port,
            "auth_reads": cfg.auth_reads,
            "has_password": bool(cfg.password),
            "languages": list(cfg.languages),
        },
    )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        _graceful_exit(signal.SIGINT, None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
