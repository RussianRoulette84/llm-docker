"""
config.py — load the HOST builder-api config and resolve the per-project
view at boot.

Sources of truth, all host-owned (never bind-mounted into any container):

    ~/.llm-docker/builder-api.toml                  ← BASE
      defaults, [jobs.*], [language.*.jobs.*], [verb.*]
    ~/.llm-docker/projects/<name>.toml              ← PROJECT SHARD (optional)
      one [project.<name>] block per file

Override the base path with $BUILDER_API_CONFIG. Shards live in `projects/`
beside the base unless overridden via $BUILDER_API_PROJECTS_DIR.

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

import os
import re
import stat
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from jobs import Job, JobConfigError, parse_jobs


DEFAULT_HOST_CONFIG = Path.home() / ".llm-docker" / "api_config" / "builder-api.toml"
DEFAULT_PROJECTS_DIR = Path.home() / ".llm-docker" / "api_config"


# ---------------------------------------------------------------------------
# Dataclasses mirror the resolved per-project view. Other modules read typed
# attributes (cfg.runtime.start_command) instead of dict lookups.
# ---------------------------------------------------------------------------


@dataclass
class BuildCfg:
    """Queue-tuning knobs only. The legacy `[build].command` / single-build
    POST is gone; everything goes through `[jobs.<name>]`. These knobs apply
    to ALL jobs the queue runs (FIFO dedupe window, queue cap, default
    per-build timeout if a job doesn't set its own)."""
    timeout_s: int = 900
    max_pending: int = 32
    dedupe_window_s: float = 5.0


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
    request_timeout_s: int = 30


@dataclass
class VerbSpec:
    """Metadata for a generic verb declared in the base toml via [verb.X].

    Verbs are vocabulary, not implementations. Each project shard declares
    per-platform leaves under [project.<name>.jobs.X.platforms.<plat>] and
    the daemon dispatches POST /job/X?platform=<plat> to that leaf. The
    VerbSpec carries the allowed platform list and the required-param
    name so the dispatch layer can return early 400s with clear errors
    when a caller forgets the `?platform=…` query.
    """
    name: str
    description: str = ""
    platforms: tuple[str, ...] = ()
    required_param: Optional[str] = None

    def to_public(self) -> dict:
        out: dict = {
            "platforms": list(self.platforms),
            "required_param": self.required_param,
        }
        if self.description:
            out["description"] = self.description
        return out


@dataclass
class Config:
    name: str
    bind: str
    port: int
    password: str
    auth_reads: bool
    project_root: Path
    languages: tuple[str, ...]

    build: BuildCfg
    runtime: RuntimeCfg
    events: EventsCfg
    security: SecurityCfg

    log_aliases: dict[str, Path] = field(default_factory=dict)
    jobs: dict[str, Job] = field(default_factory=dict)
    verbs: dict[str, VerbSpec] = field(default_factory=dict)

    # Source files captured at boot for audit. config_path = the base toml;
    # shard_paths = every per-project file that contributed something to
    # this project's view. config_mtime is the max of all of them so a
    # stale-bundle warning could be added later without code changes.
    config_path: Optional[Path] = None
    config_mtime: float = 0.0
    shard_paths: tuple[Path, ...] = ()


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------


class ConfigError(SystemExit):
    """Raised-and-exited when config is missing, malformed, or unsafe."""

    def __init__(self, msg: str) -> None:
        sys.stderr.write(f"[builder-api] CONFIG ERROR: {msg}\n")
        super().__init__(2)


def load(project_name: str, config_path: Optional[Path] = None) -> Config:
    """Load the host config, resolve the per-project view, return a frozen
    Config. Exits non-zero on any violation.

    `project_name` matches a `[project.<name>]` block — typically the
    basename of the project directory; cld/ocd pass this at daemon launch.
    `config_path` defaults to ~/.llm-docker/builder-api.toml; override
    via env $BUILDER_API_CONFIG.

    Per-project shards under ~/.llm-docker/projects/<name>.toml are merged
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


def _default_config_path() -> Path:
    env = os.environ.get("BUILDER_API_CONFIG")
    return Path(env).expanduser() if env else DEFAULT_HOST_CONFIG


def _default_projects_dir(base_path: Path) -> Path:
    """Resolve the per-project shards directory. Default sits beside the
    base toml (`<base>/projects/`); override with $BUILDER_API_PROJECTS_DIR
    for unit tests / unusual layouts."""
    env = os.environ.get("BUILDER_API_PROJECTS_DIR")
    if env:
        return Path(env).expanduser()
    if base_path == DEFAULT_HOST_CONFIG:
        return DEFAULT_PROJECTS_DIR
    return base_path.parent / "projects"


# ---------------------------------------------------------------------------
# TOML parsing
# ---------------------------------------------------------------------------


def _read_toml(path: Path) -> dict:
    try:
        import tomllib  # 3.11+ stdlib
    except ImportError:
        raise ConfigError(
            "TOML config requires Python 3.11+ (tomllib). Upgrade Python."
        )
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        raise ConfigError(f"cannot read {path}: {e}")

    # Pre-scan for duplicate table headers and report ALL of them at once.
    # tomllib raises on the first duplicate and stops, which forces an
    # edit-retry-edit-retry loop when there are several. This scan groups
    # `[table.path]` occurrences by key and surfaces every collision in one
    # error so the user fixes the whole class in one pass.
    # NOTE: matches single-bracket `[x]` only (so `[[arrays.of.tables]]`,
    # which TOML explicitly allows to repeat, is skipped). Inline tables
    # like `x = { ... }` don't start with `[` at column 0, so they're skipped.
    header_pat = re.compile(r"^\s*\[([^\[\]]+)\]\s*$")
    seen: dict[str, list[int]] = {}
    for lineno, line in enumerate(text.splitlines(), start=1):
        m = header_pat.match(line)
        if m:
            key = m.group(1).strip()
            seen.setdefault(key, []).append(lineno)
    dupes = {k: v for k, v in seen.items() if len(v) > 1}
    if dupes:
        lines = ["duplicate table header(s) in TOML — fix all of these:"]
        for key, lns in sorted(dupes.items()):
            lines.append(f"  [{key}]  →  lines {lns}")
        lines.append("Delete the older / less-customized copy of each, then retry.")
        raise ConfigError(f"{path}: " + "\n".join(lines))

    try:
        return tomllib.loads(text)
    except Exception as e:
        raise ConfigError(f"TOML parse error in {path}: {e}")


# ---------------------------------------------------------------------------
# Per-project shard merging
# ---------------------------------------------------------------------------


# Conservative shard filename alphabet. Mirrors the project-name rules used
# in the resolver so a shard file can only contribute to a project whose
# name we'd accept anywhere else.
_PROJECT_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")

# Tables a shard is NOT allowed to declare. Everything host-wide belongs in
# the base toml; shards only ever add to `[project.<name>]`.
_SHARD_FORBIDDEN_TOP = frozenset({"defaults", "jobs", "language", "verb"})


def _merge_project_shards(raw: dict, shards_dir: Path) -> tuple[Path, ...]:
    """Glob `shards_dir/*.toml` and merge each shard's `[project.<name>]`
    block into `raw["project"]`. Returns the tuple of shard paths that
    actually contributed (sorted for deterministic audit).

    Refuses, with a ConfigError, if:
      - a shard is a symlink (could point outside the projects dir)
      - a shard is world-writable (anyone could rewrite the host's command surface)
      - a shard declares a forbidden top-level table ([jobs], [language],
        [verb], [defaults]) — those live ONLY in base
      - the filename `<name>.toml` doesn't match the `[project.<name>]`
        block inside (mismatch is almost always a copy-paste accident)
      - two shards both define the same `[project.<name>.jobs.<X>]`
      - a shard and the base both define the same job under that project

    Group-writable is warned, not rejected — local dev convenience without
    silently weakening the security posture.
    """
    if not shards_dir.exists():
        return ()
    if not shards_dir.is_dir():
        raise ConfigError(
            f"projects shard path is not a directory: {shards_dir}"
        )

    contributed: list[Path] = []
    project_table = raw.setdefault("project", {})
    if not isinstance(project_table, dict):
        raise ConfigError(
            "base toml's [project] is not a table (corrupt config)"
        )

    for shard_path in sorted(shards_dir.glob("*.toml")):
        # Skip the base toml — it lives in the same api_config/ directory
        # but is the host config, not a project shard. Identified by its
        # fixed filename `builder-api.toml`.
        if shard_path.name == "builder-api.toml":
            continue
        _check_shard_safety(shard_path)
        shard_name = shard_path.stem  # filename without .toml
        if not _PROJECT_NAME.match(shard_name):
            raise ConfigError(
                f"shard filename {shard_path.name!r} doesn't match "
                f"{_PROJECT_NAME.pattern} — rename it."
            )

        shard_raw = _read_toml(shard_path)

        # Reject every top-level table that the shard is not allowed to set.
        bad_top = _SHARD_FORBIDDEN_TOP & set(shard_raw.keys())
        if bad_top:
            raise ConfigError(
                f"{shard_path}: shards may only declare [project.<name>] "
                f"tables. Found forbidden top-level table(s): "
                f"{sorted(bad_top)!r}. Move those into the base toml at "
                f"{shards_dir.parent / 'builder-api.toml'}."
            )

        shard_project = shard_raw.get("project") or {}
        if not isinstance(shard_project, dict):
            raise ConfigError(
                f"{shard_path}: [project] must be a table"
            )
        if set(shard_project.keys()) != {shard_name}:
            raise ConfigError(
                f"{shard_path}: must contain exactly one [project.{shard_name}] "
                f"matching the filename. Found: {sorted(shard_project.keys())!r}."
            )

        existing = project_table.get(shard_name)
        shard_block = shard_project[shard_name]
        if existing is None:
            project_table[shard_name] = shard_block
        else:
            _merge_project_block(
                existing, shard_block, shard_name, shard_path
            )
        contributed.append(shard_path)

    return tuple(contributed)


def _check_shard_safety(shard_path: Path) -> None:
    """Refuse symlinks and world-writable shards; warn on group-writable.

    The base assumption is that nothing inside any container can write under
    `~/.llm-docker/projects/` because the directory is host-owned and not
    bind-mounted anywhere. The symlink + mode checks defend against the
    human-error case where someone accidentally drops a 0666 file or a
    link out of the directory."""
    if shard_path.is_symlink():
        raise ConfigError(
            f"{shard_path}: per-project shards must be regular files, "
            f"not symlinks. Move the real file into the projects dir or "
            f"copy its contents."
        )
    try:
        mode = shard_path.stat().st_mode
    except OSError as e:
        raise ConfigError(f"cannot stat {shard_path}: {e}")
    if mode & stat.S_IWOTH:
        raise ConfigError(
            f"{shard_path}: shard is world-writable (mode "
            f"{stat.filemode(mode)}). Tighten with `chmod 0644 {shard_path}` "
            f"before the daemon will load it."
        )
    if mode & stat.S_IWGRP:
        sys.stderr.write(
            f"[builder-api] CONFIG WARN: {shard_path} is group-writable "
            f"(mode {stat.filemode(mode)}); recommend `chmod 0644`.\n"
        )


def _merge_project_block(
    existing: dict, incoming: dict, project_name: str, shard_path: Path
) -> None:
    """Merge a shard's `[project.<name>]` block into an existing one.

    Top-level scalars (root, port, languages, description) prefer the
    shard when both exist (shard wins, base provides defaults).

    Job tables are union-with-dupe-detection: each job key may appear in
    at most one source. Two shards (or a shard + base) defining the same
    `[project.<name>.jobs.<X>]` → ConfigError naming both sources.
    """
    if not isinstance(incoming, dict):
        raise ConfigError(
            f"{shard_path}: [project.{project_name}] must be a table"
        )

    incoming_jobs = incoming.get("jobs") or {}
    existing_jobs = existing.get("jobs") or {}
    if incoming_jobs:
        if not isinstance(incoming_jobs, dict):
            raise ConfigError(
                f"{shard_path}: [project.{project_name}.jobs] must be a table"
            )
        dupes = set(existing_jobs.keys()) & set(incoming_jobs.keys())
        if dupes:
            raise ConfigError(
                f"{shard_path}: job(s) {sorted(dupes)!r} already declared "
                f"for [project.{project_name}] in another source (base "
                f"toml or earlier shard). Pick one location."
            )
        merged_jobs: dict = {}
        merged_jobs.update(existing_jobs)
        merged_jobs.update(incoming_jobs)
        existing["jobs"] = merged_jobs

    # Non-jobs scalars / sub-tables: shard wins where present.
    for key, value in incoming.items():
        if key == "jobs":
            continue
        existing[key] = value


# ---------------------------------------------------------------------------
# Project-view resolution
# ---------------------------------------------------------------------------


_ENV_INTERP = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")


def _expand_env(value: str) -> str:
    """Expand ${VAR} references from os.environ. Missing -> empty string."""
    return _ENV_INTERP.sub(lambda m: os.environ.get(m.group(1), ""), value)


def _parse_verbs(raw: dict, file_label: str) -> dict[str, VerbSpec]:
    """Parse the base toml's `[verb.*]` tables into VerbSpecs.

    Verbs are vocabulary, not implementations: each verb describes a
    well-known operation (`up`, `down`, `lint`, …), the platforms agents
    may target, and which query param the dispatcher requires. Projects
    implement verbs as hub jobs whose body is a `platforms` sub-table.
    Verb metadata flows back to clients via GET /jobs so MCP tools know
    which platforms a verb supports before they call it.
    """
    verbs_raw = raw.get("verb") or {}
    if not isinstance(verbs_raw, dict):
        raise ConfigError(f"{file_label}: [verb] must be a table")
    out: dict[str, VerbSpec] = {}
    for name_raw, body in verbs_raw.items():
        name = str(name_raw)
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", name):
            raise ConfigError(
                f"{file_label}: [verb.{name!r}] — verb name must match "
                f"[A-Za-z][A-Za-z0-9_-]*"
            )
        if not isinstance(body, dict):
            raise ConfigError(f"{file_label}: [verb.{name}] must be a table")
        plats_raw = body.get("platforms") or []
        if not isinstance(plats_raw, list) or not all(
            isinstance(x, str) for x in plats_raw
        ):
            raise ConfigError(
                f"{file_label}: [verb.{name}].platforms must be a list of strings"
            )
        seen: set[str] = set()
        plats: list[str] = []
        for p in plats_raw:
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", p):
                raise ConfigError(
                    f"{file_label}: [verb.{name}].platforms entry {p!r} must "
                    f"match [A-Za-z][A-Za-z0-9_-]*"
                )
            if p in seen:
                raise ConfigError(
                    f"{file_label}: [verb.{name}].platforms has duplicate {p!r}"
                )
            seen.add(p)
            plats.append(p)
        req = body.get("required_param")
        if req is not None and not isinstance(req, str):
            raise ConfigError(
                f"{file_label}: [verb.{name}].required_param must be a string"
            )
        out[name] = VerbSpec(
            name=name,
            description=str(body.get("description") or ""),
            platforms=tuple(plats),
            required_param=req,
        )
    return out


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


def _warn_stale_plugin(raw: dict, project_name: str, path: Path) -> None:
    """Emit a one-shot stderr WARN if `plugin = "..."` remnants from
    pre-v2.4 configs appear in the host toml. Plugin support was removed
    entirely; the daemon doesn't parse the field. Without this warning a
    user could copy-paste a stale block and never notice the plugin
    silently isn't loading."""
    hits: list[str] = []
    top = raw.get("plugin")
    if top:
        hits.append(f"[top-level] plugin = {top!r}")
    proj = (raw.get("project") or {}).get(project_name) or {}
    p = proj.get("plugin")
    if p:
        hits.append(f"[project.{project_name}] plugin = {p!r}")
    for hit in hits:
        sys.stderr.write(
            f"[builder-api] CONFIG WARN: stale `plugin` key found in "
            f"{path}: {hit}. Plugin support was removed in v2.4 — the "
            f"key is ignored. Delete it from your host toml.\n"
        )


def _resolve_in_root(rel: str, root: Path, *, context: str) -> Path:
    """Resolve `rel` against `root`, refuse paths that escape it. Follows
    symlinks so a `logs/build.log` -> /etc/passwd link gets caught."""
    p = (root / rel).resolve() if not Path(rel).is_absolute() else Path(rel).resolve()
    target = p if p.exists() else p.parent
    try:
        target.relative_to(root)
    except ValueError:
        raise ConfigError(f"{context}: path {p} escapes project root {root}")
    return p
