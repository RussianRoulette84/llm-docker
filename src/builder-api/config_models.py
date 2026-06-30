"""config_models — typed dataclasses for the resolved per-project config view (split from config.py)."""
from __future__ import annotations
import sys  # noqa: F401
from dataclasses import dataclass, field
from typing import Optional

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


