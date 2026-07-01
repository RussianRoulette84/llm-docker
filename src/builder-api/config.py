"""
config.py — load the HOST builder-api config and resolve the per-project
view at boot.

Sources of truth, all host-owned (never bind-mounted into any container):

    ~/.llm-docker/api_config/builder-api.toml       ← BASE
      defaults, [jobs.*], [language.*.jobs.*], [verb.*]
    ~/.llm-docker/api_config/<name>.toml            ← PROJECT SHARD (optional)
      one [project.<name>] block per file

Override the base path with $BUILDER_API_CONFIG. Shards live in the same
`api_config/` dir as the base unless overridden via $BUILDER_API_PROJECTS_DIR.

Resolution for a daemon launched as `--project <name>`:

    1. [jobs.<name>]                       — global, every project sees it
    2. [language.<lang>.jobs.<name>]       — per opted-in language pack
    3. [project.<name>.jobs.<name>]        — explicit project override

Later layers replace earlier ones by job name. The composed table is the
only thing exposed via GET /jobs and the only commands the daemon will
ever execvp.

Generic verbs (`up` / `down` / `restart` / `build` / `lint` / …) declared
in the base via `[verb.X]` carry only metadata (description, allowed
platforms, required_param). Implementations live in the project shards as
`[project.<name>.jobs.X.platforms.<plat>]` — POST /job/X?platform=ios
dispatches to that leaf. The base verbs are vocabulary; the leaves are
the only thing that ever runs.

Failing at boot is intentional: a silent-misconfig API is worse than one
that won't start.
"""
from __future__ import annotations

import os  # noqa: F401
import re
import sys  # noqa: F401
from pathlib import Path  # noqa: F401
from typing import Optional  # noqa: F401

from jobs import Job, JobConfigError, parse_jobs  # noqa: F401
from config_models import (  # noqa: F401
    BuildCfg, RuntimeCfg, EventsCfg, SecurityCfg, VerbSpec, Config, ConfigError,
)
from config_parse import (  # noqa: F401
    DEFAULT_HOST_CONFIG, DEFAULT_PROJECTS_DIR, _read_toml, _merge_project_shards,
    _check_shard_safety, _merge_project_block, _expand_env, _parse_verbs,
    _warn_stale_plugin, _resolve_in_root, _default_config_path, _default_projects_dir,
)

def load(project_name: str, config_path: Optional[Path] = None) -> Config:
    """Load the host config, resolve the per-project view, return a frozen
    Config. Exits non-zero on any violation.

    `project_name` matches a `[project.<name>]` block — typically the
    basename of the project directory; cld/ocd pass this at daemon launch.
    `config_path` defaults to ~/.llm-docker/api_config/builder-api.toml; override
    via env $BUILDER_API_CONFIG.

    Per-project shards under ~/.llm-docker/api_config/<name>.toml are merged
    into the base before resolution. Shards may ONLY add to the
    [project.<name>] namespace — they cannot redeclare [jobs.*],
    [language.*], [verb.*], or [defaults] (the daemon rejects shards that
    try). Shards must be regular files under the projects directory; the
    daemon refuses symlinks or world-writable files."""
    path = config_path or _default_config_path()
    if not path.is_file():
        raise ConfigError(
            f"host config not found: {path}\n"
            f"  copy src/builder-api/builder-api.host.toml.example to {path} "
            f"and edit it for your projects."
        )

    raw = _read_toml(path)
    shards_dir = _default_projects_dir(path)
    shard_paths = _merge_project_shards(raw, shards_dir)
    return _resolve_project_view(raw, project_name, path, shard_paths)



def _resolve_project_view(
    raw: dict,
    project_name: str,
    path: Path,
    shard_paths: tuple[Path, ...] = (),
) -> Config:
    defaults = raw.get("defaults") or {}
    proj_block = (raw.get("project") or {}).get(project_name)
    if proj_block is None:
        available = sorted((raw.get("project") or {}).keys())
        raise ConfigError(
            f"no [project.{project_name}] in {path}. Known projects: "
            f"{available or '(none)'}. Add a block for this project or "
            f"check the basename matches your project directory."
        )

    # Plugin support was removed in v2.4 (was a host-exec escape path).
    # Warn loudly if any `plugin = "..."` remnant shows up in a stale copy-
    # paste so users notice instead of silently misconfiguring.
    _warn_stale_plugin(raw, project_name, path)

    # --- bind / port / password (project may override defaults) ---
    bind = str(proj_block.get("bind") or defaults.get("bind") or "127.0.0.1")
    port = int(proj_block.get("port") or 0)
    if port <= 0:
        raise ConfigError(
            f"[project.{project_name}].port missing or invalid in {path}"
        )
    password = _expand_env(str(
        proj_block.get("password") or defaults.get("password") or ""
    ))
    if "auth_reads" in proj_block:
        auth_reads = bool(proj_block["auth_reads"])
    elif "auth_reads" in defaults:
        auth_reads = bool(defaults["auth_reads"])
    else:
        auth_reads = bind not in ("127.0.0.1", "localhost", "::1")
    if bind not in ("127.0.0.1", "localhost", "::1") and not password:
        raise ConfigError(
            f"[project.{project_name}].bind={bind!r} is non-loopback but "
            f"password is empty. Set [defaults].password = "
            f"\"${{BUILDER_API_PASSWORD}}\" or a project-specific one."
        )

    # --- project root ---
    root_raw = proj_block.get("root")
    if not root_raw:
        raise ConfigError(
            f"[project.{project_name}].root is required (path to project)"
        )
    root = Path(str(root_raw)).expanduser().resolve()
    if not root.is_dir():
        raise ConfigError(
            f"[project.{project_name}].root does not exist: {root}"
        )

    # --- languages ---
    languages_raw = proj_block.get("languages") or []
    if not isinstance(languages_raw, list) or not all(
        isinstance(x, str) for x in languages_raw
    ):
        raise ConfigError(
            f"[project.{project_name}].languages must be a list of strings"
        )
    languages = tuple(languages_raw)

    # --- compose effective jobs: global → languages → project (last wins) ---
    raw_jobs_table: dict[str, dict] = {}
    for name, j in (raw.get("jobs") or {}).items():
        raw_jobs_table[str(name)] = j
    for lang in languages:
        lang_block = (raw.get("language") or {}).get(lang) or {}
        for name, j in (lang_block.get("jobs") or {}).items():
            raw_jobs_table[str(name)] = j
    for name, j in (proj_block.get("jobs") or {}).items():
        raw_jobs_table[str(name)] = j

    try:
        jobs_table = parse_jobs(raw_jobs_table, file_label=str(path))
    except JobConfigError as e:
        raise ConfigError(str(e))

    # --- build (queue tuning; project may override defaults) ---
    build_src = {**(defaults.get("build") or {}),
                 **(proj_block.get("build") or {})}
    try:
        dedupe_window_s = float(build_src.get("dedupe_window_s", 5.0))
    except (TypeError, ValueError):
        raise ConfigError("build.dedupe_window_s must be a number")
    build = BuildCfg(
        timeout_s=int(build_src.get("timeout_s") or 900),
        max_pending=max(1, int(build_src.get("max_pending") or 32)),
        dedupe_window_s=max(0.0, dedupe_window_s),
    )

    # --- runtime (project-scoped only) ---
    runtime_raw = proj_block.get("runtime") or {}
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
            f"[project.{project_name}.runtime].enabled=true requires a "
            "non-empty start_command"
        )

    # --- logs (project-scoped) ---
    log_aliases: dict[str, Path] = {}
    log_dir_raw = proj_block.get("log_dir") or defaults.get("log_dir")
    if log_dir_raw:
        log_dir = Path(str(log_dir_raw)).expanduser() / project_name
        log_dir.mkdir(parents=True, exist_ok=True)
        log_aliases["build"] = log_dir / "build.log"
        log_aliases["runtime"] = log_dir / "runtime.log"
        log_aliases["events"] = log_dir / "events.log"

    for alias, rel in (proj_block.get("logs") or {}).items():
        alias_s = str(alias)
        if not re.fullmatch(r"[A-Za-z0-9_-]+", alias_s):
            raise ConfigError(
                f"log alias {alias_s!r} must match [A-Za-z0-9_-]+"
            )
        log_aliases[alias_s] = _resolve_in_root(
            str(rel), root, context=f"[project.{project_name}.logs].{alias_s}"
        )

    # --- events (project-scoped, optional) ---
    events_raw = proj_block.get("events") or {}
    events_path: Optional[Path] = None
    if events_raw.get("path"):
        events_path = _resolve_in_root(
            str(events_raw["path"]), root,
            context=f"[project.{project_name}.events].path",
        )
    elif log_aliases.get("events"):
        events_path = log_aliases["events"]
    events = EventsCfg(
        path=events_path,
        max_bytes=int(events_raw.get("max_bytes") or 200 * 1024 * 1024),
        drop_bytes=int(events_raw.get("drop_bytes") or 10 * 1024 * 1024),
    )

    # --- security tuning (defaults may set; project may override) ---
    sec_src = {**(defaults.get("security") or {}),
               **(proj_block.get("security") or {})}
    security = SecurityCfg(
        auth_failures_per_min=int(sec_src.get("auth_failures_per_min") or 10),
        lockout_s=int(sec_src.get("lockout_s") or 300),
        max_body_bytes=int(sec_src.get("max_body_bytes") or 1024 * 1024),
        max_url_bytes=int(sec_src.get("max_url_bytes") or 8 * 1024),
        request_timeout_s=int(sec_src.get("request_timeout_s") or 30),
    )

    # Take the latest mtime across base + every shard so future audit code
    # can detect a stale bundle without re-walking the directory.
    mtimes: list[float] = []
    for p in (path, *shard_paths):
        try:
            mtimes.append(p.stat().st_mtime)
        except OSError:
            continue
    mtime = max(mtimes) if mtimes else 0.0

    verbs = _parse_verbs(raw, file_label=str(path))

    return Config(
        name=project_name,
        bind=bind,
        port=port,
        password=password,
        auth_reads=auth_reads,
        project_root=root,
        languages=languages,
        build=build,
        runtime=runtime,
        events=events,
        security=security,
        log_aliases=log_aliases,
        jobs=jobs_table,
        verbs=verbs,
        config_path=path,
        config_mtime=mtime,
        shard_paths=shard_paths,
    )


