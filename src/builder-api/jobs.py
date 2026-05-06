"""
jobs.py — `[jobs.<name>]` template parsing, parameter validation, argv
substitution, and command-file sha256 pinning.

Generic across projects: the daemon doesn't care whether you're driving
docker compose, PHPUnit, a Quake build, npm test, or a custom Make. Drop
your jobs into `.builder-api.toml`; the daemon serves them via
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
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# Argv elements that contain a placeholder must match this exact form —
# `{name}` and nothing else. Nested or embedded placeholders are rejected
# at config-load so the substitution path can never see surprise text.
_PLACEHOLDER_REF = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
_STANDALONE_PLACEHOLDER = re.compile(r"^\{([A-Za-z_][A-Za-z0-9_]*)\}$")
_PLACEHOLDER_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# Default cap for placeholder values. Override per-placeholder via max_len.
# Generous enough for typical args (test names, file paths, service names),
# tight enough that an unbounded value can't be passed in by accident.
DEFAULT_MAX_LEN = 200


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class JobConfigError(Exception):
    """Raised by parse_jobs() when a `[jobs.*]` block fails validation at
    config-load. Caller maps to ConfigError → daemon refuses to start."""


class ValidationError(Exception):
    """Raised when a request's params fail placeholder validation. Carries
    the structured fields the locked 400 response shape exposes."""

    def __init__(
        self,
        *,
        field: str,
        reason: str,
        expected: object = None,
        value: object = None,
    ) -> None:
        self.field = field
        self.reason = reason
        self.expected = expected
        self.value = value
        super().__init__(f"{field}: {reason}")

    def to_response(self, endpoint: str) -> dict:
        out = {
            "error": "validation_failed",
            "endpoint": endpoint,
            "field": self.field,
            "reason": self.reason,
        }
        if self.expected is not None:
            out["expected"] = self.expected
        # Reflect a bounded preview of the offending value (truncated repr)
        # rather than the raw bytes — keeps the response compact and avoids
        # echoing arbitrarily large attacker-controlled blobs.
        if self.value is not None:
            preview = repr(self.value)
            if len(preview) > 64:
                preview = preview[:61] + "..."
            out["value_preview"] = preview
        return out


class UnknownJobError(KeyError):
    """Raised by Catalog.get() when the job name isn't declared. Caller
    maps to 404 with `{error: unknown_job, name, available: [...]}`."""


class CommandHashMismatch(Exception):
    """Raised when a job has `sha256` set but the resolved command file's
    actual hash differs. Caller maps to 412 Precondition Failed."""

    def __init__(
        self,
        *,
        job: str,
        command: str,
        expected: str,
        actual: str,
    ) -> None:
        self.job = job
        self.command = command
        self.expected = expected
        self.actual = actual
        super().__init__(f"{job}: command hash mismatch")

    def to_response(self) -> dict:
        return {
            "error": "command_hash_mismatch",
            "job": self.job,
            "command": self.command,
            "expected_sha256": self.expected,
            "actual_sha256": self.actual,
        }


class CommandNotFound(Exception):
    """Raised when a job's `command` cannot be resolved (not on PATH and not
    a file under project_root). Caller maps to 412 — the integrity check
    can't run because the binary isn't there."""

    def __init__(self, *, job: str, command: str) -> None:
        self.job = job
        self.command = command
        super().__init__(f"{job}: command not found: {command}")

    def to_response(self) -> dict:
        return {
            "error": "command_not_found",
            "job": self.job,
            "command": self.command,
        }


# ---------------------------------------------------------------------------
# Dataclasses
# ---------------------------------------------------------------------------


@dataclass
class Placeholder:
    name: str
    regex_str: str
    pattern: re.Pattern
    max_len: int = DEFAULT_MAX_LEN
    required: bool = True
    description: str = ""

    def to_public(self) -> dict:
        out: dict = {
            "regex": self.regex_str,
            "max_len": self.max_len,
            "required": self.required,
        }
        if self.description:
            out["description"] = self.description
        return out


@dataclass
class Job:
    name: str
    command: str
    args_template: tuple[str, ...]
    timeout_s: int = 60
    description: str = ""
    sha256: Optional[str] = None  # lowercase hex digest, or None
    placeholders: dict[str, Placeholder] = field(default_factory=dict)

    def to_public(self) -> dict:
        out = {
            "command": self.command,
            "args_template": list(self.args_template),
            "timeout_s": self.timeout_s,
            "sha256_pinned": self.sha256 is not None,
            "placeholders": {
                n: p.to_public() for n, p in self.placeholders.items()
            },
        }
        if self.description:
            out["description"] = self.description
        return out


# ---------------------------------------------------------------------------
# Config-time parsing (called from config.py)
# ---------------------------------------------------------------------------


def parse_jobs(jobs_raw: object, *, file_label: str) -> dict[str, Job]:
    """
    Validate a `[jobs.*]` table and return name -> Job. Raises JobConfigError
    on any structural problem. Compiles every regex up-front so a bad pattern
    is caught at boot, not at first request.

    `jobs_raw` is whatever the toml parser handed back for the `jobs` key —
    usually a dict. None / empty are fine: jobs are optional.
    """
    if jobs_raw is None:
        return {}
    if not isinstance(jobs_raw, dict):
        raise JobConfigError(f"{file_label}: [jobs] must be a table")

    out: dict[str, Job] = {}
    for raw_name, raw_job in jobs_raw.items():
        name = str(raw_name)
        if not _PLACEHOLDER_NAME.match(name) and not re.fullmatch(
            r"[A-Za-z_][A-Za-z0-9_-]*", name
        ):
            raise JobConfigError(
                f"{file_label}: job name {name!r} must match "
                f"[A-Za-z_][A-Za-z0-9_-]*"
            )
        if not isinstance(raw_job, dict):
            raise JobConfigError(
                f"{file_label}: [jobs.{name}] must be a table"
            )
        out[name] = _parse_one_job(name, raw_job, file_label=file_label)
    return out


def _parse_one_job(name: str, raw: dict, *, file_label: str) -> Job:
    cmd = raw.get("command")
    if not isinstance(cmd, str) or not cmd:
        raise JobConfigError(
            f"{file_label}: [jobs.{name}].command must be a non-empty string"
        )

    args_raw = raw.get("args") or []
    if not isinstance(args_raw, list) or not all(isinstance(a, str) for a in args_raw):
        raise JobConfigError(
            f"{file_label}: [jobs.{name}].args must be a list of strings"
        )

    placeholders_raw = raw.get("placeholders") or {}
    if not isinstance(placeholders_raw, dict):
        raise JobConfigError(
            f"{file_label}: [jobs.{name}].placeholders must be a table"
        )

    placeholders: dict[str, Placeholder] = {}
    for ph_name, ph_raw in placeholders_raw.items():
        ph_name_s = str(ph_name)
        if not _PLACEHOLDER_NAME.match(ph_name_s):
            raise JobConfigError(
                f"{file_label}: [jobs.{name}].placeholders.{ph_name_s!r} — "
                "placeholder name must match [A-Za-z_][A-Za-z0-9_]*"
            )
        if not isinstance(ph_raw, dict):
            raise JobConfigError(
                f"{file_label}: [jobs.{name}].placeholders.{ph_name_s} "
                "must be a table"
            )
        placeholders[ph_name_s] = _parse_one_placeholder(
            job_name=name,
            ph_name=ph_name_s,
            raw=ph_raw,
            file_label=file_label,
        )

    # Verify every {placeholder} reference in args_template exists in
    # placeholders, AND every reference is a standalone array element.
    # Also verify every declared placeholder is referenced (warn-by-error
    # so dead placeholders don't sit around polluting the schema).
    referenced: set[str] = set()
    for i, arg in enumerate(args_raw):
        m = _STANDALONE_PLACEHOLDER.match(arg)
        if m:
            ref = m.group(1)
            if ref not in placeholders:
                raise JobConfigError(
                    f"{file_label}: [jobs.{name}].args[{i}] references "
                    f"undeclared placeholder {{{ref}}}. Add a "
                    f"[jobs.{name}.placeholders.{ref}] block, or remove "
                    f"the reference."
                )
            referenced.add(ref)
        else:
            # No standalone placeholder. Reject embedded forms like
            # "--filter={test}" or "prefix-{test}-suffix" outright — those
            # would force string substitution / shell interpolation, which
            # we don't do. Argv form only.
            inner = list(_PLACEHOLDER_REF.finditer(arg))
            if inner:
                raise JobConfigError(
                    f"{file_label}: [jobs.{name}].args[{i}]={arg!r} embeds "
                    f"a placeholder. Placeholders must be standalone array "
                    f"elements (e.g. args = [\"--filter\", \"{{test}}\"]), "
                    f"never substrings of an arg."
                )

    unused = set(placeholders.keys()) - referenced
    if unused:
        raise JobConfigError(
            f"{file_label}: [jobs.{name}] declares placeholder(s) "
            f"{sorted(unused)!r} that aren't referenced in `args`. Remove "
            f"the block or wire it into `args`."
        )

    sha256 = raw.get("sha256")
    if sha256 is not None:
        if not isinstance(sha256, str):
            raise JobConfigError(
                f"{file_label}: [jobs.{name}].sha256 must be a hex string"
            )
        sha256 = sha256.strip().lower()
        if not re.fullmatch(r"[0-9a-f]{64}", sha256):
            raise JobConfigError(
                f"{file_label}: [jobs.{name}].sha256 must be a 64-char "
                f"lowercase hex sha256 digest (got {sha256!r})"
            )

    timeout_s = raw.get("timeout_s")
    timeout_s = int(timeout_s) if timeout_s is not None else 60
    if timeout_s < 1:
        raise JobConfigError(
            f"{file_label}: [jobs.{name}].timeout_s must be >= 1"
        )

    return Job(
        name=name,
        command=cmd,
        args_template=tuple(args_raw),
        timeout_s=timeout_s,
        description=str(raw.get("description") or ""),
        sha256=sha256,
        placeholders=placeholders,
    )


def _parse_one_placeholder(
    *, job_name: str, ph_name: str, raw: dict, file_label: str
) -> Placeholder:
    regex_str = raw.get("regex")
    if not isinstance(regex_str, str) or not regex_str:
        raise JobConfigError(
            f"{file_label}: [jobs.{job_name}.placeholders.{ph_name}].regex "
            f"must be a non-empty string"
        )
    try:
        pattern = re.compile(regex_str)
    except re.error as e:
        raise JobConfigError(
            f"{file_label}: [jobs.{job_name}.placeholders.{ph_name}].regex "
            f"is not a valid Python regex: {e}"
        )

    max_len = raw.get("max_len")
    if max_len is None:
        max_len_i = DEFAULT_MAX_LEN
    else:
        try:
            max_len_i = int(max_len)
        except (TypeError, ValueError):
            raise JobConfigError(
                f"{file_label}: [jobs.{job_name}.placeholders.{ph_name}]"
                f".max_len must be an integer"
            )
        if max_len_i < 1:
            raise JobConfigError(
                f"{file_label}: [jobs.{job_name}.placeholders.{ph_name}]"
                f".max_len must be >= 1"
            )

    required = bool(raw.get("required", True))
    description = str(raw.get("description") or "")

    return Placeholder(
        name=ph_name,
        regex_str=regex_str,
        pattern=pattern,
        max_len=max_len_i,
        required=required,
        description=description,
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


def resolve_command(command: str, project_root: Path) -> Optional[Path]:
    """
    Resolve `command` to an absolute Path:
      - absolute path  → use as-is (must exist)
      - starts with ./ or ../ or contains a /  → relative to project_root
      - bare name      → shutil.which() lookup on PATH

    Returns the Path if found and is a regular file; None otherwise.
    """
    if not command:
        return None
    p = Path(command)
    if p.is_absolute():
        return p if p.is_file() else None
    if "/" in command:
        candidate = (project_root / command).resolve()
        return candidate if candidate.is_file() else None
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
    Resolve `job.command` and (if `job.sha256` is set) check the file hash
    against it. Returns the resolved Path on success.

    Raises:
        CommandNotFound      — resolution failed
        CommandHashMismatch  — sha256 declared but actual differs
    """
    resolved = resolve_command(job.command, project_root)
    if resolved is None:
        raise CommandNotFound(job=job.name, command=job.command)
    if job.sha256 is not None:
        actual = compute_command_sha256(resolved)
        if actual != job.sha256:
            raise CommandHashMismatch(
                job=job.name,
                command=str(resolved),
                expected=job.sha256,
                actual=actual,
            )
    return resolved
