"""jobs_errors — exception types for the [jobs.*] subsystem (split from jobs.py)."""
from __future__ import annotations

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

