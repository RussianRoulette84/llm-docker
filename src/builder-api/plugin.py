"""
plugin.py — optional Python plugin loader.

A plugin is a single `.py` file the user references from their config
(`plugin = "builder_plugin.py"`). We load it once at boot using importlib;
after that, the server just calls whatever hooks + handlers it defined.

This module deliberately offers NO runtime reload, NO eval of arbitrary
strings, and NO fallback "search path" that might pick up a different file.
The plugin path was validated at config-load time (exists + inside
project_root); this file just imports it.

Plugin API (every symbol is optional):

    def on_build_start(entry):       ...
    def on_build_finish(entry):      ...
    def on_run_start(pid):           ...
    def on_run_exit(pid, cause):     ...

    def handlers() -> dict:
        # Return {path: {METHOD: fn}, ...}
        # fn(req: dict, handler) -> dict  (returned dict is JSON-encoded)
        return {}

Handlers defined here run inside the plugin author's trust boundary — they
are unrestricted Python in the server's process. See README.md for the
threat-model note.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any, Callable, Optional


class Plugin:
    """
    Normalised view of a loaded plugin. Missing hooks become no-ops so
    callers never have to `if hasattr(...)`.
    """

    def __init__(self, mod: Optional[ModuleType]) -> None:
        self._mod = mod

    @property
    def loaded(self) -> bool:
        return self._mod is not None

    # ---- lifecycle hooks ---------------------------------------------

    def on_build_start(self, entry) -> None:
        self._safe_call("on_build_start", entry)

    def on_build_finish(self, entry) -> None:
        self._safe_call("on_build_finish", entry)

    def on_run_start(self, pid: int) -> None:
        self._safe_call("on_run_start", pid)

    def on_run_exit(self, pid: int, cause: str) -> None:
        self._safe_call("on_run_exit", pid, cause)

    # ---- handlers() ---------------------------------------------------

    def handlers(self) -> dict[str, dict[str, Callable[..., Any]]]:
        """
        Return the plugin's handler registry (path -> method -> fn).
        Any non-dict result is logged and ignored.
        """
        if self._mod is None:
            return {}
        fn = getattr(self._mod, "handlers", None)
        if fn is None:
            return {}
        try:
            result = fn()
        except Exception as e:
            _warn(f"plugin.handlers() raised: {e!r}")
            return {}
        if not isinstance(result, dict):
            _warn("plugin.handlers() must return a dict")
            return {}

        # Validate shape: {str: {METHOD: callable}}
        sanitised: dict[str, dict[str, Callable[..., Any]]] = {}
        for path, method_map in result.items():
            if not isinstance(path, str) or not path.startswith("/"):
                _warn(f"plugin handler path {path!r} must be a string starting with /")
                continue
            if not isinstance(method_map, dict):
                _warn(f"plugin handler entry for {path!r} must be a dict")
                continue
            inner: dict[str, Callable[..., Any]] = {}
            for method, handler_fn in method_map.items():
                if not isinstance(method, str):
                    continue
                if not callable(handler_fn):
                    continue
                inner[method.upper()] = handler_fn
            if inner:
                sanitised[path] = inner
        return sanitised

    # ---- internals ----------------------------------------------------

    def _safe_call(self, attr: str, *args) -> None:
        if self._mod is None:
            return
        fn = getattr(self._mod, attr, None)
        if fn is None:
            return
        try:
            fn(*args)
        except Exception as e:
            _warn(f"plugin.{attr}() raised: {e!r}")


# ---------------------------------------------------------------------------
# Loader — called once by server.py at startup.
# ---------------------------------------------------------------------------

def load(plugin_path: Optional[Path]) -> Plugin:
    """
    Load `plugin_path` as a Python module. Returns an empty Plugin if no
    path is set. Loading errors are fatal (we exit) — a plugin file that
    can't import is almost certainly a deployment mistake; silently running
    without it would mask that.
    """
    if plugin_path is None:
        return Plugin(None)

    try:
        spec = importlib.util.spec_from_file_location(
            f"builder_plugin_{plugin_path.stem}",
            str(plugin_path),
        )
        if spec is None or spec.loader is None:
            raise ImportError(f"could not build spec for {plugin_path}")
        mod = importlib.util.module_from_spec(spec)
        # Register in sys.modules so `inspect` / `logging` inside the plugin
        # doesn't fall over on self-references.
        sys.modules[spec.name] = mod
        spec.loader.exec_module(mod)
    except Exception as e:
        sys.stderr.write(
            f"[builder-api] PLUGIN ERROR: failed to load {plugin_path}: {e!r}\n"
        )
        raise SystemExit(2)

    sys.stderr.write(f"[builder-api] plugin loaded: {plugin_path}\n")
    return Plugin(mod)


def _warn(msg: str) -> None:
    sys.stderr.write(f"[builder-api] plugin warning: {msg}\n")
    sys.stderr.flush()
