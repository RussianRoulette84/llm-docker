"""
logs.py — alias-based log tailing for `/logs?file=<alias>&n=<lines>`.

Only aliases that were resolved + validated at config load are readable.
The handler never lets a client name an arbitrary filesystem path; they can
only name a key from the config. This is one of the anti-exfiltration
guarantees the security contract promised.
"""

from __future__ import annotations

import io
import os
from pathlib import Path
from typing import Iterable


class LogStore:
    """
    Wraps the `cfg.log_aliases` dict with a safe tail helper.

    Callers use `store.tail(alias, n)` — which either returns text or raises
    `KeyError` (alias not declared) / `FileNotFoundError` (file gone since
    config load).
    """

    def __init__(self, aliases: dict[str, Path]) -> None:
        self._aliases = dict(aliases)  # copy so external mutation can't sneak in

    # ------------------------------------------------------------------

    def alias_names(self) -> Iterable[str]:
        return self._aliases.keys()

    def update_aliases(self, aliases: dict[str, Path]) -> None:
        """Swap the alias map at hot-reload. New aliases are visible
        immediately; removed aliases start returning KeyError on next call."""
        self._aliases = dict(aliases)

    def path_for(self, alias: str) -> Path:
        if alias not in self._aliases:
            raise KeyError(alias)
        return self._aliases[alias]

    def tail(self, alias: str, n: int) -> str:
        """
        Return the last `n` lines of the aliased file. Returns '' if the
        file doesn't exist yet (common: logs/build.log before the first
        build has run). Clamps n >= 1, caps at 10_000 to avoid giant reads.
        """
        if alias not in self._aliases:
            raise KeyError(alias)
        path = self._aliases[alias]
        if not path.exists():
            return ""
        n = max(1, min(int(n), 10_000))
        return _tail_text(path, n)


# ---------------------------------------------------------------------------
# Efficient tail-N-lines: seek from end in 64 KB chunks and scan backward for
# newlines. Avoids loading a 200 MB log file to read its last 20 lines.
# ---------------------------------------------------------------------------


def _tail_text(path: Path, n: int) -> str:
    try:
        size = path.stat().st_size
    except OSError:
        return ""
    if size == 0:
        return ""

    block = 65536
    data = bytearray()
    newlines_found = 0
    with path.open("rb") as f:
        pos = size
        while pos > 0 and newlines_found <= n:
            read_size = block if pos >= block else pos
            pos -= read_size
            f.seek(pos)
            chunk = f.read(read_size)
            data[:0] = chunk  # prepend
            newlines_found = data.count(b"\n")

    # If the file ends with a newline, drop it so we don't count a phantom
    # empty final line.
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    if len(lines) > n:
        lines = lines[-n:]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# LogWatcher — single thread per file that polls for new lines and pushes
# them to a callback. Used by ws.py to stream live log frames to clients.
# Lifted from the reference implementation's _start_master_log loop style.
# ---------------------------------------------------------------------------


class LogWatcher:
    """
    Tails a single file and calls `sink(alias, line)` for every new line.

    Designed for many-clients-one-file by keeping state internal and driven by
    a single polling loop. The WS session spins one watcher per alias it's
    subscribed to; the watcher is cheap (one fd, one thread, 0.25s poll).
    """

    POLL_INTERVAL_S = 0.25

    def __init__(self, alias: str, path: Path, sink) -> None:
        self._alias = alias
        self._path = path
        self._sink = sink  # callable(alias: str, line: str)
        self._stop = False
        self._offset = 0

        # Skip existing content: we only want NEW lines after watcher start.
        try:
            self._offset = path.stat().st_size if path.exists() else 0
        except OSError:
            self._offset = 0

    def stop(self) -> None:
        self._stop = True

    def run(self) -> None:
        """Run the tail loop on the current thread until stop() is called."""
        import time
        buf = b""
        while not self._stop:
            try:
                size = self._path.stat().st_size if self._path.exists() else 0
            except OSError:
                size = 0

            # Handle truncation (log rotation upstream): reset offset.
            if size < self._offset:
                self._offset = 0
                buf = b""

            if size > self._offset and self._path.exists():
                try:
                    with self._path.open("rb") as f:
                        f.seek(self._offset)
                        new_data = f.read(size - self._offset)
                    self._offset = size
                    buf += new_data
                    # Split on newlines; keep any trailing partial.
                    *complete, tail = buf.split(b"\n")
                    buf = tail
                    for raw in complete:
                        try:
                            line = raw.decode("utf-8", errors="replace")
                        except Exception:
                            continue
                        try:
                            self._sink(self._alias, line)
                        except Exception:
                            # Never let a slow subscriber kill the watcher.
                            pass
                except OSError:
                    pass
            time.sleep(self.POLL_INTERVAL_S)
