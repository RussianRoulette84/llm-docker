"""
jobs.py — `[jobs.<name>]` template parsing, parameter validation, argv
substitution, and command-file sha256 pinning.

Generic across projects: the daemon doesn't care whether you're driving
docker compose, PHPUnit, a Quake build, npm test, or a custom Make. Drop
your jobs into `~/.llm-docker/api_config/builder-api.toml`; the daemon serves them via
`POST /job/<name>` and exposes their schema via `GET /jobs` for
auto-generated MCP tools.

Security model is the same closed-whitelist as legacy `[build]`:
- one predefined `command` per job (resolved against project root or PATH)
- argv form (`args = ["--filter", "{test}"]`) — placeholders MUST be
  standalone array elements, never embedded text like `--filter={test}`
- per-placeholder regex + max_len enforced before execvp
- never `shell=True`; substitution lands directly in argv
- optional sha256 pin on the command file blocks tampering
"""
from __future__ import annotations

import hashlib
import shutil
from pathlib import Path
from typing import Optional

# Split into focused modules; this file keeps request-time validation +
# command resolution and RE-EXPORTS the public API so callers' `import jobs`
# / `from jobs import X` keep working unchanged.
from jobs_errors import (  # noqa: F401
    JobConfigError, ValidationError, UnknownJobError,
    CommandHashMismatch, CommandNotFound,
)
from jobs_models import (  # noqa: F401
    Placeholder, Job, DEFAULT_MAX_LEN,
    _PLACEHOLDER_REF, _STANDALONE_PLACEHOLDER, _RESERVED_TOKEN,
    _KNOWN_RESERVED_TOKENS, _PLACEHOLDER_NAME,
)
from jobs_parse import (  # noqa: F401
    parse_jobs, _parse_hub_job, _parse_one_job, _parse_one_placeholder,
)

# ---------------------------------------------------------------------------
# Request-time validation + substitution
# ---------------------------------------------------------------------------


def validate_and_substitute(
    job: Job, params: dict
) -> tuple[list[str], dict[str, str]]:
    """
    Validate `params` against `job.placeholders`, then substitute into
    `job.args_template`. Returns (resolved_argv, normalized_params).

    Raises ValidationError on the first failure.
    """
    if not isinstance(params, dict):
        raise ValidationError(
            field="params", reason="wrong_type", expected="object", value=params
        )

    # Reject unknown keys up front — typos like {tst} should fail loud, not
    # silently succeed by being ignored.
    declared = set(job.placeholders.keys())
    for key in params.keys():
        if key not in declared:
            raise ValidationError(
                field=str(key),
                reason="unknown_param",
                expected=sorted(declared),
            )

    normalized: dict[str, str] = {}
    for ph_name, ph in job.placeholders.items():
        if ph_name not in params:
            if ph.required:
                raise ValidationError(field=ph_name, reason="missing_required")
            continue
        value = params[ph_name]
        if not isinstance(value, str):
            raise ValidationError(
                field=ph_name,
                reason="wrong_type",
                expected="string",
                value=value,
            )
        if len(value) > ph.max_len:
            raise ValidationError(
                field=ph_name,
                reason="max_len_exceeded",
                expected=ph.max_len,
                value=value,
            )
        if not ph.pattern.fullmatch(value):
            raise ValidationError(
                field=ph_name,
                reason="regex_mismatch",
                expected=ph.regex_str,
                value=value,
            )
        normalized[ph_name] = value

    # Substitute. Optional missing placeholders cause that arg to be dropped
    # (so optional flags can be omitted cleanly).
    out: list[str] = []
    for arg in job.args_template:
        m = _STANDALONE_PLACEHOLDER.match(arg)
        if m:
            ref = m.group(1)
            if ref in normalized:
                out.append(normalized[ref])
            # else: optional placeholder not provided → drop this argv slot
        else:
            out.append(arg)
    return out, normalized


# ---------------------------------------------------------------------------
# Command resolution + sha256 pinning
# ---------------------------------------------------------------------------


# Cache: (resolved_path_str, mtime, size) -> hex digest. Avoids re-hashing
# big binaries (docker is ~100MB) on every enqueue. Bounded so a stream of
# distinct paths can't unbounded-grow it.
_HASH_CACHE: dict[tuple[str, float, int], str] = {}
_HASH_CACHE_CAP = 64


def resolve_command(
    command: str, project_root: Path, cwd: str = "."
) -> Optional[Path]:
    """
    Resolve `command` to an absolute Path:
      - absolute path                          → use as-is (must exist)
      - contains a "/" (relative path)         → try project_root/cwd/command
                                                 first; fall back to
                                                 project_root/command
      - bare name                              → shutil.which() lookup on PATH

    The cwd-first lookup is what lets a monorepo job declare
    `command = "vendor/bin/phpunit"` + `cwd = "api"` and have the daemon
    find the binary at `<root>/api/vendor/bin/phpunit` — without it,
    callers had to wrap with `bash -c "cd api && exec vendor/bin/phpunit"`
    to dodge a 412 command_not_found at request time. Both lookups are
    resolve()d and constrained to stay under project_root (symlink-escape
    check) so a wayward `cwd` can't widen the surface.

    Returns the Path if found and is a regular file; None otherwise.
    """
    if not command:
        return None
    p = Path(command)
    if p.is_absolute():
        return p if p.is_file() else None
    if "/" in command:
        # Try cwd-relative first (covers the monorepo case), then
        # project-root-relative (covers the "binary at repo root" case).
        candidates = []
        if cwd and cwd not in ("", "."):
            candidates.append((project_root / cwd / command).resolve())
        candidates.append((project_root / command).resolve())
        for cand in candidates:
            try:
                cand.relative_to(project_root)
            except ValueError:
                continue  # escape attempt — skip, don't return
            if cand.is_file():
                return cand
        return None
    found = shutil.which(command)
    return Path(found) if found else None


def compute_command_sha256(path: Path) -> str:
    """Hex sha256 of the file at `path`. Memoised on (path, mtime, size)
    so repeated calls on a stable binary are O(1)."""
    st = path.stat()
    key = (str(path), st.st_mtime, st.st_size)
    cached = _HASH_CACHE.get(key)
    if cached is not None:
        return cached

    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    digest = h.hexdigest()

    # Crude FIFO eviction; we don't need true LRU — the working set is
    # one entry per declared command, ~tens at most.
    if len(_HASH_CACHE) >= _HASH_CACHE_CAP:
        _HASH_CACHE.pop(next(iter(_HASH_CACHE)))
    _HASH_CACHE[key] = digest
    return digest


def verify_command_hash(job: Job, project_root: Path) -> Path:
    """
    Resolve `job.command`, then (if `job.command_hash` is set) hash the
    file at `job.command_hash_path` (relative to project_root) and verify
    against `job.command_hash`. Returns the resolved command Path on success.

    `command_hash_path` decouples WHAT-WE-RUN from WHAT-WE-HASH: a wrapper
    job whose command is "docker exec llm-docker /path/to/script.sh" sets
    path = "<script.sh>" to pin the script (which lives in the bind-mount
    and is the actual attack surface), not the docker binary (which
    changes on every Docker Desktop update).

    Raises:
        CommandNotFound      — `command` resolution failed
        CommandHashMismatch  — hash declared but actual mismatches, OR
                               path escapes project_root, OR path missing
    """
    resolved = resolve_command(job.command, project_root, cwd=job.cwd)
    if resolved is None:
        raise CommandNotFound(job=job.name, command=job.command)
    if job.command_hash is not None:
        target = (project_root / job.command_hash_path).resolve()
        try:
            target.relative_to(project_root)
        except ValueError:
            raise CommandHashMismatch(
                job=job.name,
                command=str(resolved),
                expected=job.command_hash,
                actual=f"<path escapes project_root: {job.command_hash_path}>",
            )
        if not target.is_file():
            raise CommandHashMismatch(
                job=job.name,
                command=str(resolved),
                expected=job.command_hash,
                actual=f"<file not found: {job.command_hash_path}>",
            )
        actual = compute_command_sha256(target)
        if actual != job.command_hash:
            raise CommandHashMismatch(
                job=job.name,
                command=str(resolved),
                expected=job.command_hash,
                actual=actual,
            )
    return resolved
