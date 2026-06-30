"""jobs_models — placeholder/job dataclasses + shared regex constants (split from jobs.py)."""
from __future__ import annotations
import re
from dataclasses import dataclass, field
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
