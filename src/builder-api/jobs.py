"""
jobs.py — `[jobs.<name>]` template parsing, parameter validation, argv
substitution, and command-file sha256 pinning.

Generic across projects: the daemon doesn't care whether you're driving
docker compose, PHPUnit, a Quake build, npm test, or a custom Make. Drop
your jobs into `~/.llm-docker/builder-api.toml`; the daemon serves them via
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
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# Argv elements that contain a placeholder must match this exact form —
# `{name}` and nothing else. Nested or embedded placeholders are rejected
# at config-load so the substitution path can never see surprise text.
_PLACEHOLDER_REF = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
_STANDALONE_PLACEHOLDER = re.compile(r"^\{([A-Za-z_][A-Za-z0-9_]*)\}$")

# Reserved daemon-side substitution tokens — double-curly, distinct from
# single-curly user placeholders. Resolved at job-dispatch time by the
# build queue, never user-supplied. Not subject to the [placeholders]
# table check. Adding a new token: extend _KNOWN_RESERVED_TOKENS AND
# add the dispatch-time substitution branch in build_queue._execute.
_RESERVED_TOKEN = re.compile(r"^\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}$")
_KNOWN_RESERVED_TOKENS = frozenset({
    "{{container}}",   # resolves to ID of container labelled
                       # llm-docker-project=<this-project>
})
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
            "expected_hash": self.expected,
            "actual_hash": self.actual,
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
    # SIGTERM→SIGKILL grace window. 0 means "use the daemon's default" (3s).
    # Set higher for jobs that need extra time to clean up (large data
    # flushes, network teardown). Set lower (e.g. 1) for jobs that hang
    # forever and need a fast hard kill — chromium downloads, npm installs
    # behind a proxy, etc.
    kill_after_s: int = 0
    # Subdir (relative to project_root) where the subprocess runs. Default
    # "." = project root. Useful for monorepos: a frontend job that needs
    # to run from `angular/` so it sees `package.json`, while the rest of
    # the repo's jobs stay at root. Validated to stay under project_root
    # (no `..` escape) at config-load time in config.py.
    cwd: str = "."
    description: str = ""
    # File-integrity pin: hash the file at `command_hash_path` (relative to
    # project_root) and verify against `command_hash` (bare hex) before
    # every execvp. Both None = no pin. The path-explicit form lets wrapper
    # jobs (command = "docker", args = [..., "<script>"]) pin the SCRIPT
    # being executed inside the container, not the docker binary itself.
    command_hash: Optional[str] = None        # 64-char lowercase hex, or None
    command_hash_path: Optional[str] = None   # rel-to-project_root, or None
    # Write-in-place gate. When true, POST /job/<name> rejects with 428
    # unless the caller sends `X-Mutation-Confirmed: yes`. Stops carpet-test
    # patterns (POST + race-to-DELETE) from accidentally firing destructive
    # jobs like `prettier --write`, `pint` (no --test), `ruff format`, etc.
    # The cancel race is unwinnable for fast file mutators (Prettier finished
    # 326 files before SIGTERM landed), so the only safe fix is to refuse
    # the request unless the operator explicitly opted in.
    mutates_filesystem: bool = False
    placeholders: dict[str, Placeholder] = field(default_factory=dict)
    # Generic-verb hub mode. When non-empty, this Job is a router: it has
    # NO command/args/placeholders of its own; instead each entry maps a
    # platform name (e.g. "ios", "web") to a fully-validated leaf Job. The
    # daemon dispatches POST /job/<name>?platform=X to the matching leaf
    # and runs the leaf through the same security pipeline (placeholders,
    # command_hash, mutates_filesystem). Empty = ordinary leaf job.
    platforms: dict[str, "Job"] = field(default_factory=dict)

    @property
    def is_hub(self) -> bool:
        """A hub job dispatches to per-platform leaves and has no command
        of its own."""
        return bool(self.platforms)

    def to_public(self) -> dict:
        if self.is_hub:
            out: dict = {
                "platforms": {
                    plat: leaf.to_public() for plat, leaf in self.platforms.items()
                },
            }
            if self.description:
                out["description"] = self.description
            return out
        out = {
            "command": self.command,
            "args_template": list(self.args_template),
            "timeout_s": self.timeout_s,
            "kill_after_s": self.kill_after_s,
            "cwd": self.cwd,
            "command_hash_pinned": self.command_hash is not None,
            "command_hash_path": self.command_hash_path,
            "mutates_filesystem": self.mutates_filesystem,
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


# Platform names follow the same alphabet as job names. Kept conservative so
# downstream filters (events, log filenames) don't have to escape anything.
_PLATFORM_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")


def _parse_hub_job(name: str, raw: dict, *, file_label: str) -> Job:
    """Parse a `[jobs.<name>]` entry whose body is a `platforms` sub-table.

    Hub jobs route to per-platform leaves (`POST /job/<name>?platform=X`).
    They MUST NOT carry their own command/args/placeholders/hash/etc — all
    runtime fields live on the leaves. Description on the hub is allowed
    (shows up in GET /jobs as the verb's summary).
    """
    # The hub itself is only metadata. Reject leaf-only fields up top so a
    # silent typo can't accidentally make a hub appear to "have" a command
    # that the daemon never runs.
    forbidden = {
        "command", "args", "cwd", "timeout_s", "kill_after_s",
        "command_hash", "mutates_filesystem", "placeholders",
    }
    bad = forbidden & set(raw.keys())
    if bad:
        raise JobConfigError(
            f"{file_label}: [jobs.{name}] is a hub (has `platforms` sub-table), "
            f"so it CANNOT also declare {sorted(bad)!r}. Move those keys "
            f"inside [jobs.{name}.platforms.<platform>] instead."
        )
    platforms_raw = raw["platforms"]
    if not platforms_raw:
        raise JobConfigError(
            f"{file_label}: [jobs.{name}.platforms] must declare at least one "
            f"platform (e.g. [jobs.{name}.platforms.web])"
        )
    leaves: dict[str, Job] = {}
    for plat_raw, leaf_raw in platforms_raw.items():
        plat = str(plat_raw)
        if not _PLATFORM_NAME.match(plat):
            raise JobConfigError(
                f"{file_label}: [jobs.{name}.platforms.{plat!r}] — platform "
                f"name must match {_PLATFORM_NAME.pattern}"
            )
        if not isinstance(leaf_raw, dict):
            raise JobConfigError(
                f"{file_label}: [jobs.{name}.platforms.{plat}] must be a table"
            )
        # Recurse into the standard leaf parser. We pass a synthetic name
        # like "up@ios" so any nested error message points the operator at
        # the exact section to fix.
        leaf = _parse_one_job(
            f"{name}@{plat}", leaf_raw, file_label=file_label
        )
        if leaf.is_hub:
            raise JobConfigError(
                f"{file_label}: [jobs.{name}.platforms.{plat}] cannot itself "
                f"declare a `platforms` sub-table — nested hubs aren't allowed."
            )
        leaves[plat] = leaf
    return Job(
        name=name,
        command="",
        args_template=(),
        description=str(raw.get("description") or ""),
        platforms=leaves,
    )


def _parse_one_job(name: str, raw: dict, *, file_label: str) -> Job:
    # Hub mode: a job entry whose body is just a `platforms` sub-table
    # routes to per-platform leaves and has no command/args of its own.
    # The leaves are fully validated leaf jobs (regex, hash, mutation gate)
    # — only the dispatch layer is new.
    if isinstance(raw.get("platforms"), dict):
        return _parse_hub_job(name, raw, file_label=file_label)

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
    # Reserved daemon-side tokens (e.g. `{{container}}`) skip validation
    # entirely — they're not user placeholders, they get resolved at
    # job-dispatch time in build_queue._execute.
    referenced: set[str] = set()
    for i, arg in enumerate(args_raw):
        if _RESERVED_TOKEN.match(arg):
            if arg not in _KNOWN_RESERVED_TOKENS:
                raise JobConfigError(
                    f"{file_label}: [jobs.{name}].args[{i}]={arg!r} is an "
                    f"unknown reserved token. Known: "
                    f"{sorted(_KNOWN_RESERVED_TOKENS)}"
                )
            continue
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

    # `command_hash` is a table: { path = "<rel>", sha256 = "sha256:<hex>" }.
    # `path` is the file to hash, relative to project_root. Typically EQUAL
    # to `command` (pin the binary you run), but for wrapper-style jobs
    # (command = "docker" args = [..., "<script>"]) set path = "<script>"
    # to pin the wrapped target instead. ONE shape only — bare-string form
    # is gone.
    ch_raw = raw.get("command_hash")
    command_hash = None
    command_hash_path = None
    if ch_raw is not None:
        if not isinstance(ch_raw, dict):
            raise JobConfigError(
                f"{file_label}: [jobs.{name}].command_hash must be a table: "
                f"command_hash = {{ path = \"<rel-path>\", "
                f"sha256 = \"sha256:<64-char hex>\" }}"
            )
        p = ch_raw.get("path")
        s = ch_raw.get("sha256")
        if not isinstance(p, str) or not p:
            raise JobConfigError(
                f"{file_label}: [jobs.{name}].command_hash.path must be a "
                f"non-empty string (relative to project_root)"
            )
        if p.startswith("/") or ".." in p.split("/"):
            raise JobConfigError(
                f"{file_label}: [jobs.{name}].command_hash.path must be "
                f"relative and stay under project_root (got {p!r})"
            )
        if not isinstance(s, str):
            raise JobConfigError(
                f"{file_label}: [jobs.{name}].command_hash.sha256 must be a string"
            )
        s = s.strip().lower()
        m = re.fullmatch(r"sha256:([0-9a-f]{64})", s)
        if not m:
            raise JobConfigError(
                f"{file_label}: [jobs.{name}].command_hash.sha256 must be "
                f"`sha256:<64-char lowercase hex>` (got {s!r})"
            )
        command_hash_path = p
        command_hash = m.group(1)

    timeout_s = raw.get("timeout_s")
    timeout_s = int(timeout_s) if timeout_s is not None else 60
    if timeout_s < 1:
        raise JobConfigError(
            f"{file_label}: [jobs.{name}].timeout_s must be >= 1"
        )

    kill_after_s_raw = raw.get("kill_after_s")
    kill_after_s = int(kill_after_s_raw) if kill_after_s_raw is not None else 0
    if kill_after_s < 0:
        raise JobConfigError(
            f"{file_label}: [jobs.{name}].kill_after_s must be >= 0"
        )

    cwd_raw = raw.get("cwd")
    cwd = str(cwd_raw) if cwd_raw is not None else "."
    if cwd.startswith("/") or ".." in cwd.split("/"):
        # Absolute or parent-escape paths are out — cwd must resolve under
        # project_root. Final resolution happens in config.py with the
        # actual root in hand.
        raise JobConfigError(
            f"{file_label}: [jobs.{name}].cwd must be relative and stay "
            f"under project_root (got {cwd!r})"
        )

    mutates_raw = raw.get("mutates_filesystem")
    if mutates_raw is None:
        mutates_filesystem = False
    elif isinstance(mutates_raw, bool):
        mutates_filesystem = mutates_raw
    else:
        raise JobConfigError(
            f"{file_label}: [jobs.{name}].mutates_filesystem must be a boolean"
        )

    # WARN on unknown job fields so silent-ignore can't trip up users
    # again (the v2.4.x command_hash rename bit purpletech-claude this way).
    known = {
        "command", "args", "cwd", "timeout_s", "kill_after_s",
        "command_hash", "mutates_filesystem", "description", "placeholders",
    }
    unknown = set(raw.keys()) - known
    for k in sorted(unknown):
        sys.stderr.write(
            f"[builder-api] CONFIG WARN: [jobs.{name}].{k} = "
            f"{raw[k]!r} — unknown field, ignored. Known fields: "
            f"{sorted(known)}\n"
        )

    return Job(
        name=name,
        command=cmd,
        args_template=tuple(args_raw),
        timeout_s=timeout_s,
        kill_after_s=kill_after_s,
        cwd=cwd,
        description=str(raw.get("description") or ""),
        command_hash=command_hash,
        command_hash_path=command_hash_path,
        mutates_filesystem=mutates_filesystem,
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
