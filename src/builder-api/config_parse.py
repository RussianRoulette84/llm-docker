"""config_parse — toml read, shard merge, verb parse, path resolution (split from config.py)."""
from __future__ import annotations
import os
import re
import stat
import sys
from pathlib import Path
from typing import Optional  # noqa: F401

from jobs import Job  # noqa: F401
from config_models import ConfigError, VerbSpec  # noqa: F401

DEFAULT_HOST_CONFIG = Path.home() / ".llm-docker" / "api_config" / "builder-api.toml"
DEFAULT_PROJECTS_DIR = Path.home() / ".llm-docker" / "api_config"

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
    `~/.llm-docker/api_config/` because the directory is host-owned and not
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
