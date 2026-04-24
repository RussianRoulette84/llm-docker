"""
config.py — load `.builder-api.{toml,yml,yaml,json}` from the current
working directory, validate it, resolve every declared path against the
project root, and refuse to start on any violation.

Failing at boot is intentional: a silent-misconfig API is worse than one
that won't start. Every rule the security plan promised ("log paths must
sit under project_root", "non-loopback bind requires a password", etc.) is
enforced here, not deferred to runtime.
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


CONFIG_NAMES = [
    ".builder-api.toml",
    ".builder-api.yml",
    ".builder-api.yaml",
    ".builder-api.json",
]


# ---------------------------------------------------------------------------
# Dataclasses mirror the TOML schema 1:1 so the rest of the app reads typed
# attributes (cfg.build.command) instead of dict lookups.
# ---------------------------------------------------------------------------


@dataclass
class BuildCfg:
    command: str
    allowed_args: tuple[str, ...] = ()
    timeout_s: int = 900          # per-build subprocess kill deadline
    max_pending: int = 32         # deque cap; enqueue beyond returns 429


@dataclass
class RuntimeCfg:
    enabled: bool = False
    start_command: str = ""
    cwd: str = "."
    env: dict[str, str] = field(default_factory=dict)
    stop_signal: str = "SIGTERM"
    stop_timeout_s: int = 5


@dataclass
class EventsCfg:
    path: Optional[Path] = None
    max_bytes: int = 200 * 1024 * 1024   # 200 MB
    drop_bytes: int = 10 * 1024 * 1024   # ~10 MB


@dataclass
class SecurityCfg:
    auth_failures_per_min: int = 10
    lockout_s: int = 300
    max_body_bytes: int = 1024 * 1024       # 1 MB
    max_url_bytes: int = 8 * 1024           # 8 KB
    request_timeout_s: int = 30             # slowloris protection; tune up
                                            # if you ever post very large bodies
                                            # (distinct from build.timeout_s)


@dataclass
class Config:
    name: str
    bind: str
    port: int
    password: str
    auth_reads: bool
    project_root: Path

    build: BuildCfg
    runtime: RuntimeCfg
    events: EventsCfg
    security: SecurityCfg

    # Map of alias -> resolved absolute Path. Populated at load.
    log_aliases: dict[str, Path] = field(default_factory=dict)

    # Plugin file (absolute path) if declared; else None.
    plugin_path: Optional[Path] = None


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------


class ConfigError(SystemExit):
    """Raised-and-exited when a config is missing, malformed, or unsafe.

    Inherits from SystemExit so a bare `raise` aborts the daemon with a
    non-zero status instead of dumping a Python traceback at the operator.
    """

    def __init__(self, msg: str) -> None:
        sys.stderr.write(f"[builder-api] CONFIG ERROR: {msg}\n")
        super().__init__(2)


def load(project_root: Optional[Path] = None) -> Config:
    """
    Locate + parse the config file in `project_root` (default: cwd). Validate
    every field, resolve all paths under project_root, return a frozen Config.
    Exits non-zero on any violation.
    """
    root = (project_root or Path.cwd()).resolve()

    raw_path = _find_config_file(root)
    raw = _read_raw(raw_path)

    cfg = _build_config(raw, root, raw_path)
    return cfg


# ---------------------------------------------------------------------------
# File discovery + parsing
# ---------------------------------------------------------------------------


def _find_config_file(root: Path) -> Path:
    for name in CONFIG_NAMES:
        p = root / name
        if p.is_file():
            return p
    raise ConfigError(
        f"no config file found in {root}. Expected one of: "
        f"{', '.join(CONFIG_NAMES)} — see builder-api/examples/ for templates."
    )


def _read_raw(path: Path) -> dict:
    suffix = path.suffix.lower()
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        raise ConfigError(f"cannot read {path}: {e}")

    if suffix == ".toml":
        try:
            import tomllib  # 3.11+ stdlib
        except ImportError:
            raise ConfigError(
                "TOML config requires Python 3.11+ (tomllib). Upgrade Python "
                "or use a .json / .yml file instead."
            )
        try:
            return tomllib.loads(text)
        except Exception as e:
            raise ConfigError(f"TOML parse error in {path}: {e}")

    if suffix in (".yml", ".yaml"):
        try:
            import yaml  # type: ignore
        except ImportError:
            raise ConfigError(
                "YAML config requires the `pyyaml` package. Install it with "
                "`pip install pyyaml`, or use a .toml / .json file instead."
            )
        try:
            data = yaml.safe_load(text) or {}
        except Exception as e:
            raise ConfigError(f"YAML parse error in {path}: {e}")
        if not isinstance(data, dict):
            raise ConfigError(f"{path}: top-level must be a mapping")
        return data

    if suffix == ".json":
        try:
            return json.loads(text)
        except Exception as e:
            raise ConfigError(f"JSON parse error in {path}: {e}")

    raise ConfigError(f"unknown config format: {path.suffix}")


# ---------------------------------------------------------------------------
# Validation + path resolution
# ---------------------------------------------------------------------------


_ENV_INTERP = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")


def _expand_env(value: str) -> str:
    """Expand ${VAR} references from os.environ. Missing -> empty string."""
    return _ENV_INTERP.sub(lambda m: os.environ.get(m.group(1), ""), value)


def _build_config(raw: dict, root: Path, path: Path) -> Config:
    name = str(raw.get("name") or root.name)
    bind = str(raw.get("bind") or "127.0.0.1")
    port = int(raw.get("port") or 6666)

    password = _expand_env(str(raw.get("password") or ""))
    # auth_reads default: True if non-loopback, False on loopback. The plan
    # calls this out as a security default; allow explicit override.
    if "auth_reads" in raw:
        auth_reads = bool(raw["auth_reads"])
    else:
        auth_reads = bind not in ("127.0.0.1", "localhost", "::1")

    # Non-loopback binds MUST have a password. Otherwise the API becomes an
    # unauthenticated build-trigger machine on the LAN.
    if bind not in ("127.0.0.1", "localhost", "::1") and not password:
        raise ConfigError(
            f"{path.name}: bind={bind!r} is non-loopback but `password` is "
            "empty. Set `password = \"${BUILDER_API_PASSWORD}\"` (or similar) "
            "and export BUILDER_API_PASSWORD in your shell."
        )

    # --- build ---
    build_raw = raw.get("build") or {}
    command = build_raw.get("command")
    if not command or not isinstance(command, str):
        raise ConfigError(f"{path.name}: [build].command must be a non-empty string")
    allowed_args_raw = build_raw.get("allowed_args") or []
    if not isinstance(allowed_args_raw, list) or not all(
        isinstance(x, str) for x in allowed_args_raw
    ):
        raise ConfigError(
            f"{path.name}: [build].allowed_args must be a list of strings"
        )
    build = BuildCfg(
        command=command,
        allowed_args=tuple(allowed_args_raw),
        timeout_s=int(build_raw.get("timeout_s") or 900),
        max_pending=max(1, int(build_raw.get("max_pending") or 32)),
    )

    # --- runtime (optional) ---
    runtime_raw = raw.get("runtime") or {}
    runtime = RuntimeCfg(
        enabled=bool(runtime_raw.get("enabled", False)),
        start_command=str(runtime_raw.get("start_command") or ""),
        cwd=str(runtime_raw.get("cwd") or "."),
        env={str(k): str(v) for k, v in (runtime_raw.get("env") or {}).items()},
        stop_signal=str(runtime_raw.get("stop_signal") or "SIGTERM"),
        stop_timeout_s=int(runtime_raw.get("stop_timeout_s") or 5),
    )
    if runtime.enabled and not runtime.start_command:
        raise ConfigError(
            f"{path.name}: [runtime].enabled=true requires a non-empty "
            "start_command"
        )

    # --- events (optional) ---
    events_raw = raw.get("events") or {}
    events_path: Optional[Path] = None
    if events_raw.get("path"):
        events_path = _resolve_in_root(
            str(events_raw["path"]),
            root,
            context=f"[events].path in {path.name}",
            must_exist=False,
        )
    events = EventsCfg(
        path=events_path,
        max_bytes=int(events_raw.get("max_bytes") or 200 * 1024 * 1024),
        drop_bytes=int(events_raw.get("drop_bytes") or 10 * 1024 * 1024),
    )

    # --- security tuning (optional) ---
    sec_raw = raw.get("security") or {}
    security = SecurityCfg(
        auth_failures_per_min=int(sec_raw.get("auth_failures_per_min") or 10),
        lockout_s=int(sec_raw.get("lockout_s") or 300),
        max_body_bytes=int(sec_raw.get("max_body_bytes") or 1024 * 1024),
        max_url_bytes=int(sec_raw.get("max_url_bytes") or 8 * 1024),
        request_timeout_s=int(sec_raw.get("request_timeout_s") or 30),
    )

    # --- log aliases ---
    logs_raw = raw.get("logs") or {}
    if not isinstance(logs_raw, dict):
        raise ConfigError(f"{path.name}: [logs] must be a mapping of alias -> path")
    log_aliases: dict[str, Path] = {}
    for alias, rel in logs_raw.items():
        alias_s = str(alias)
        if not re.fullmatch(r"[A-Za-z0-9_-]+", alias_s):
            raise ConfigError(
                f"{path.name}: log alias {alias_s!r} must match [A-Za-z0-9_-]+"
            )
        log_aliases[alias_s] = _resolve_in_root(
            str(rel),
            root,
            context=f"[logs].{alias_s} in {path.name}",
            must_exist=False,
        )

    # --- plugin (optional) ---
    plugin_rel = raw.get("plugin")
    plugin_path: Optional[Path] = None
    if plugin_rel:
        plugin_path = _resolve_in_root(
            str(plugin_rel),
            root,
            context=f"plugin in {path.name}",
            must_exist=True,
        )

    return Config(
        name=name,
        bind=bind,
        port=port,
        password=password,
        auth_reads=auth_reads,
        project_root=root,
        build=build,
        runtime=runtime,
        events=events,
        security=security,
        log_aliases=log_aliases,
        plugin_path=plugin_path,
    )


def _resolve_in_root(rel: str, root: Path, *, context: str, must_exist: bool) -> Path:
    """
    Resolve `rel` against `root`, then assert the result lives under `root`.
    Uses Path.resolve() so symlinks are followed — defeats symlink-escape
    attacks where a config declares `logs/build.log` but that file links to
    /etc/passwd.
    """
    p = (root / rel).resolve() if not Path(rel).is_absolute() else Path(rel).resolve()

    # Parents must exist so resolve() gives a stable answer. If the file
    # itself doesn't exist yet, compare parent dirs; the containing dir has
    # to exist already in project root.
    target_for_check = p if p.exists() else p.parent
    try:
        target_for_check.relative_to(root)
    except ValueError:
        raise ConfigError(
            f"{context}: path {p} escapes project root {root}"
        )

    if must_exist and not p.exists():
        raise ConfigError(f"{context}: file does not exist: {p}")

    return p
