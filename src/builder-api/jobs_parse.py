"""jobs_parse — [jobs.*] config-time parsing (split from jobs.py)."""
from __future__ import annotations
import re  # noqa: F401
import sys
from jobs_errors import JobConfigError
from jobs_models import (
    Job, Placeholder, DEFAULT_MAX_LEN, _PLACEHOLDER_REF, _STANDALONE_PLACEHOLDER,
    _RESERVED_TOKEN, _KNOWN_RESERVED_TOKENS, _PLACEHOLDER_NAME,
)

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
