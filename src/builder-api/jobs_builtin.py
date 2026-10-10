"""
jobs_builtin.py — the jobs every project gets for free, without config.

These used to live in a shared host toml as [jobs.*]. They are code now, so a
project's own file is the only config the daemon reads. A project can still
replace any of them by declaring a job with the same name — the project's
version wins (see config._resolve_project_view).

Kept as raw TOML-shaped tables rather than pre-built Job objects so they go
through the same parse_jobs() validation as user config: one code path, same
regex compilation, and a malformed constant fails at first parse instead of at
first request.
"""

from __future__ import annotations

from typing import Optional

from jobs import Job, parse_jobs

BUILTIN_JOBS_RAW: dict[str, dict] = {
    "git-status": {
        "command": "git",
        "args": ["status", "--short", "--porcelain"],
        "timeout_s": 10,
        "description": "Show working tree status (porcelain)",
    },
    "git-log": {
        "command": "git",
        "args": ["log", "--oneline", "-n", "{n}"],
        "timeout_s": 10,
        "description": "Last N commits, oneline format",
        "placeholders": {
            "n": {
                "regex": "^[1-9][0-9]?$",
                "max_len": 2,
                "required": True,
                "description": "Number of commits to show (1..99)",
            },
        },
    },
    "tree": {
        "command": "tree",
        "args": ["-L", "{depth}", "-a", "--gitignore"],
        "timeout_s": 10,
        "description": "Filesystem tree, N levels deep, respecting .gitignore",
        "placeholders": {
            "depth": {
                "regex": "^[1-5]$",
                "required": True,
                "description": "Tree depth 1..5",
            },
        },
    },
    # Host-side trash — the in-container rm-guard routes deletes here so files
    # land in the host trash (recoverable) instead of being destroyed through
    # the bind-mount. {path} is relative to project root (cwd=project_root);
    # the regex forbids a leading / and "..". execvp, no shell.
    #
    # `mutates_filesystem` is deliberately NOT set: rm-guard posts to /job/trash
    # without a confirmation header (src/docker/rm-guard.sh), so marking this as
    # mutating would make every delete inside a container fail. Leave it alone.
    "trash": {
        "command": "trash",
        "args": ["{path}"],
        "timeout_s": 20,
        "description": (
            "Move a path (relative to project root) to the host trash — recoverable"
        ),
        "placeholders": {
            "path": {
                "regex": "^(?!/)(?!.*\\.\\.)[A-Za-z0-9._/ @+-]+$",
                "max_len": 512,
                "required": True,
                "description": "Path relative to project root (no leading /, no ..)",
            },
        },
    },
}

_CACHE: Optional[dict[str, Job]] = None


def builtin_jobs() -> dict[str, Job]:
    """Parsed built-ins, validated once. Returns a fresh dict each call so a
    caller merging project jobs over it never mutates the cache."""
    global _CACHE
    if _CACHE is None:
        _CACHE = parse_jobs(BUILTIN_JOBS_RAW, file_label="<built-in>")
    return dict(_CACHE)
