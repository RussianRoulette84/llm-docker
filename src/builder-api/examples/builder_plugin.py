"""
Example builder-api plugin.

Every function in this file is OPTIONAL. Delete any you don't need and the
server will still load the plugin. If the plugin can't import at all, the
server refuses to start — better to fail loud than silently run without
the custom endpoints the user was expecting.

Enable by adding `plugin = "builder_plugin.py"` to .builder-api.toml.

WARNING: this file runs unrestricted in the server process. Don't copy a
plugin from someone you don't trust and enable it — it has the same access
as the server itself.
"""

from __future__ import annotations

import time


# ---------------------------------------------------------------------------
# Lifecycle hooks. All are fire-and-forget: exceptions here are logged and
# swallowed so a broken plugin can't corrupt the build queue.
# ---------------------------------------------------------------------------


def on_build_start(entry) -> None:
    """Called when a queued build transitions to `building`."""
    print(f"[plugin] build starting: {entry.id} args={list(entry.args)}")


def on_build_finish(entry) -> None:
    """Called when a build enters a terminal state (done/failed/cancelled)."""
    print(
        f"[plugin] build finished: {entry.id} status={entry.status} "
        f"rc={entry.returncode}"
    )


def on_run_start(pid: int) -> None:
    print(f"[plugin] runtime started pid={pid}")


def on_run_exit(pid: int, cause: str) -> None:
    """cause is one of: api_stop, restart, self_exit, daemon_shutdown."""
    print(f"[plugin] runtime exited pid={pid} cause={cause}")


# ---------------------------------------------------------------------------
# Custom HTTP endpoints. Return {path: {METHOD: fn}, ...}.
#
# Each handler receives (body_dict_or_None, http_handler, query=parsed_dict)
# and must return a JSON-serialisable dict. Exceptions become HTTP 500 with
# the exception text.
#
# Authentication: by default all plugin endpoints require the API password.
# Mark an individual function with `fn.open = True` to make it unauthed
# (only advisable for loopback binds).
# ---------------------------------------------------------------------------


def handlers():
    return {
        "/plugin/hello":   {"GET": _hello},
        "/plugin/echo":    {"POST": _echo},
    }


def _hello(body, handler, query=None):
    return {
        "plugin": "example",
        "msg": "hello from the example plugin",
        "now": time.time(),
    }


def _echo(body, handler, query=None):
    """POST back whatever you sent. Useful for smoke-testing auth + body path."""
    return {"echo": body or {}}
