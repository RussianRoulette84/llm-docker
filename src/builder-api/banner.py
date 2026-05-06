"""
banner.py — terminal aesthetics for the daemon. Boot banner + color-coded
event tail. Stdlib-only ANSI; no extra deps.

Wired in two places:
  1. server.main() prints `show_banner(...)` once at start.
  2. AppContext subscribes `event_line` to the EventStore so every
     append() surfaces as a colored one-liner on stderr.

Stays out of the way otherwise: HTTP access logs are dimmed (handlers
already produce them through BaseHTTPRequestHandler.log_message), and
nothing here writes to stdout — the banner + event tail go to stderr,
matching where Python servers normally chatter.
"""

from __future__ import annotations

import sys
import time

# 256-color palette mirroring install.sh's blue→purple gradient.
C1 = "\033[38;5;33m"
C2 = "\033[38;5;39m"
C3 = "\033[38;5;45m"
C4 = "\033[38;5;51m"
C5 = "\033[38;5;81m"
C6 = "\033[38;5;87m"
C7 = "\033[38;5;141m"   # purple — primary accent
ORANGE = "\033[38;5;208m"
GREEN  = "\033[38;5;82m"
RED    = "\033[38;5;196m"
YELLOW = "\033[38;5;220m"
GREY   = "\033[38;5;244m"
DIM    = "\033[2m"
BOLD   = "\033[1m"
RST    = "\033[0m"

# Compact ASCII glyph. Eight rows, ≤62 cols — fits a default-width
# terminal without wrapping. Coloured row-by-row in the blue→purple
# gradient at boot time.
_ASCII_LINES = [
    " ███████ ███   ███ ███ ███      ███████  ███████ ███ ",
    " ███   ███████ ██████ ██████    ███   ███████   ████ ",
    " ███████ ███   ███ ██  ███      ███████  ███████ ███ ",
    " ███   ███   █████  █████   ▄▄▄ ███   ███████   ████ ",
    " ███████ ███   ███████ ███ ▀▀▀▀ ███   ███████   ████ ",
]


def show_banner(name: str, bind: str, port: int, jobs_count: int) -> None:
    """Print the boot banner + status header to stderr. Called once
    from server.main()."""
    palette = [C1, C2, C3, C5, C6, C7]
    out = ["\n"]
    for i, line in enumerate(_ASCII_LINES):
        c = palette[min(i, len(palette) - 1)]
        out.append(f"  {c}{line}{RST}\n")
    out.append(
        f"\n  {C7}{BOLD}■{RST} {name!r}  "
        f"{DIM}listening{RST} {C5}{bind}:{port}{RST}  "
        f"{DIM}·  jobs={C7}{jobs_count}{RST}{DIM}  ·  "
        f"v0.2  ·  events live below{RST}\n"
        f"  {DIM}{'─' * 58}{RST}\n"
    )
    sys.stderr.write("".join(out))
    sys.stderr.flush()


# event_type → (color, glyph). Unmapped types fall through to (GREY, "·").
_EVENT_STYLE: dict[str, tuple[str, str]] = {
    "server_started":           (C7,     "▲"),
    "config_reloaded":          (C7,     "↻"),
    "build_enqueued":           (C5,     "+"),
    "build_started":            (ORANGE, "▸"),
    "build_finished":           (GREEN,  "✓"),  # → RED below if failed
    "build_cancelled":          (YELLOW, "⊘"),
    "runtime_started":          (ORANGE, "▶"),
    "runtime_stopped":          (YELLOW, "■"),
    "runtime_exited":           (RED,    "▣"),
    "auth_failure_lockout":     (RED,    "✗"),
}


def event_line(record: dict) -> None:
    """EventStore subscriber. Renders one colored line per event."""
    typ = record.get("type", "?")
    color, glyph = _EVENT_STYLE.get(typ, (GREY, "·"))
    # Special case: build_finished with non-zero rc paints red instead of green.
    if typ == "build_finished" and record.get("status") != "done":
        color, glyph = RED, "✗"
    ts = record.get("ts", time.time())
    try:
        hms = time.strftime("%H:%M:%S", time.localtime(float(ts)))
    except (TypeError, ValueError):
        hms = "--:--:--"
    msg = _summarize(record)
    sys.stderr.write(
        f"  {DIM}{hms}{RST}  {color}{glyph} "
        f"{typ:<22}{RST}  {GREY}{msg}{RST}\n"
    )
    sys.stderr.flush()


def _summarize(rec: dict) -> str:
    """One-liner per common event type. Keep tight — anything verbose
    belongs in /events or /ws."""
    t = rec.get("type")
    if t == "build_enqueued":
        return (
            f"id={rec.get('id')}  "
            f"job={rec.get('job', '-')}  "
            f"args={rec.get('args')}"
        )
    if t == "build_started":
        return f"id={rec.get('id')}  args={rec.get('args')}"
    if t == "build_finished":
        return (
            f"id={rec.get('id')}  rc={rec.get('returncode')}  "
            f"elapsed={rec.get('elapsed_s')}s  status={rec.get('status')}"
            + (f"  reason={rec['reason']}" if rec.get("reason") else "")
        )
    if t == "build_cancelled":
        return f"id={rec.get('id')}"
    if t == "config_reloaded":
        return (
            f"jobs={len(rec.get('jobs', []))}  "
            f"aliases={len(rec.get('log_aliases', []))}"
        )
    if t == "server_started":
        return f"{rec.get('bind')}:{rec.get('port')}  auth_reads={rec.get('auth_reads')}"
    if t == "auth_failure_lockout":
        return f"ip={rec.get('ip')}  for={rec.get('seconds')}s"
    if t and t.endswith("_log"):
        lvl = rec.get("level", "?")
        msg = (rec.get("message") or "")[:80]
        return f"{lvl}  {msg}"
    return ""
