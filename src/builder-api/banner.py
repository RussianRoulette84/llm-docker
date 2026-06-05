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

import os
import sys
import time

# Threshold for "narrow" vs "wide" rendering. The default applescript
# spawn opens a 43-column iTerm window — below ~70 the single-line event
# format wraps badly, so we collapse to a 2-line compact view. Above ~70
# we keep the original spacious layout.
NARROW_COL_THRESHOLD = 70


def _term_cols(default: int = 80) -> int:
    """Best-effort terminal width. Reads stderr's tty; falls back to
    $COLUMNS, then to `default`. Never raises."""
    for fd in (sys.stderr, sys.stdout):
        try:
            return os.get_terminal_size(fd.fileno()).columns
        except (OSError, AttributeError, ValueError):
            continue
    try:
        return int(os.environ.get("COLUMNS", default))
    except ValueError:
        return default


def _is_narrow() -> bool:
    return _term_cols() < NARROW_COL_THRESHOLD

# 256-color palette mirroring install.sh's blue→purple gradient.
C1 = "\033[38;5;33m"
C2 = "\033[38;5;39m"
C3 = "\033[38;5;45m"
C4 = "\033[38;5;51m"
C5 = "\033[38;5;81m"
C6 = "\033[38;5;87m"
C7 = "\033[38;5;141m"   # purple — primary accent
C8 = "\033[38;5;213m"   # pink — project name highlight
ORANGE = "\033[38;5;208m"
GREEN  = "\033[38;5;82m"
RED    = "\033[38;5;196m"
YELLOW = "\033[38;5;220m"
GREY   = "\033[38;5;244m"
DIM    = "\033[2m"
BOLD   = "\033[1m"
RST    = "\033[0m"

# Wide ASCII glyph (LLM DOCKER + tagline). Eight rows, ≤65 cols — coloured
# row-by-row in the blue→purple gradient at boot time.
_ASCII_LINES_WIDE = [
    " ██     ██     ██▄  ▄██     ▄▄▄▄   ▄▄▄   ▄▄▄▄ ▄▄ ▄▄ ▄▄▄▄▄ ▄▄▄▄  ",
    " ██     ██     ██ ▀▀ ██ ▄▄▄ ██▀██ ██▀██ ██▀▀▀ ██▄█▀ ██▄▄  ██▄█▄ ",
    " ██████ ██████ ██    ██     ████▀ ▀███▀ ▀████ ██ ██ ██▄▄▄ ██ ██ ",
    "                      Builder API ",
]

# Narrow ASCII glyph (LLM + tagline). Used in the 43-col iTerm split where
# the wide art would wrap into garbage. The "LLM" letters are reused from
# the wide art so the look stays consistent across panes.
_ASCII_LINES_NARROW = [
    "       ██     ██     ██▄  ▄██",
    "       ██     ██     ██ ▀▀ ██",
    "       ██████ ██████ ██    ██",
    " ▄▄▄▄   ▄▄▄   ▄▄▄▄ ▄▄ ▄▄ ▄▄▄▄▄ ▄▄▄▄  ",
    " ██▀██ ██▀██ ██▀▀▀ ██▄█▀ ██▄▄  ██▄█▄ ",
    " ████▀ ▀███▀ ▀████ ██ ██ ██▄▄▄ ██ ██ ",
    " "
    "            Builder API",
]


def _frame(lines, color, inner_width):
    """ywizz-style framed box: `◆ ─╮ / │  content  │ / ├──╯`. Rounded
    right corners, straight verticals on the left, single accent colour.
    SGR escapes inside `lines` are tolerated — visible width is computed
    by stripping them so padding stays aligned."""
    import re
    strip = re.compile(r"\033\[[0-9;]*m")
    out = []
    top_dashes = "─" * max(0, inner_width)
    out.append(f"  {color}◆ {top_dashes}╮{RST}\n")
    for line in lines:
        visible = strip.sub("", line)
        pad = max(0, inner_width - 2 - len(visible))
        out.append(f"  {color}│{RST}  {line}{' ' * pad}{color}│{RST}\n")
    bot_dashes = "─" * (inner_width + 1)
    out.append(f"  {color}├{bot_dashes}╯{RST}\n")
    return "".join(out)


def show_banner(name: str, bind: str, port: int, jobs_names) -> None:
    """Print the boot banner + status header to stderr. Called once
    from server.main(). Wide terminals get the full LLM DOCKER art;
    narrow panes get the slim LLM-only variant. Both modes wrap the
    status lines in a ywizz-style accent frame, with the project name
    highlighted in pink so it pops against the blue/purple gradient.

    `jobs_names` is either a list of job names (preferred — printed
    underneath the frame) or an int (legacy: just shown as a count)."""
    if isinstance(jobs_names, int):
        names = []
        jobs_count = jobs_names
    else:
        names = sorted(jobs_names)
        jobs_count = len(names)

    cols = _term_cols()
    narrow = cols < NARROW_COL_THRESHOLD

    ascii_lines = _ASCII_LINES_NARROW if narrow else _ASCII_LINES_WIDE
    inner_width = (min(cols, 44) if narrow else 60) - 4

    palette = [C1, C2, C3, C5, C6, C7]
    art = []
    for i, line in enumerate(ascii_lines):
        c = palette[min(i, len(palette) - 1)]
        art.append(f"  {c}{line}{RST}\n")

    proj = f"{C8}{BOLD}{name!r}{RST}"
    listen = f"{C5}{bind}:{port}{RST}"
    jobs = f"{DIM}jobs={RST}{C7}{jobs_count}{RST}"
    if narrow:
        status = [
            f"{C7}■{RST} {proj}",
            f"{DIM}↳{RST} {listen}",
            f"{jobs}  {DIM}· events ↓{RST}",
        ]
    else:
        status = [
            f"{C7}■{RST} {proj}  {DIM}listening{RST} {listen}",
            f"{jobs}  {DIM}·  events live below{RST}",
        ]

    sys.stderr.write("\n" + "".join(art) + "\n" + _frame(status, C7, inner_width))

    # Job list under the frame. Two visual rules:
    #   1. Color by prefix group — every "<prefix>-..." cluster (db-*, sa-*,
    #      django-*, lounge-*, etc.) gets its own color cycled from the
    #      palette, so eyes can pick out related jobs at a glance.
    #   2. Hard cap of 2 jobs per row (even when more would fit), so the
    #      list never devolves into a 3-4 column wall that's hard to scan
    #      in a 43-col iTerm pane. Long single names still get their own row.
    if names:
        group_palette = [C2, C3, C5, C6, C7, C8]
        prefix_color: dict[str, str] = {}

        def _color_for(n: str) -> str:
            pfx = n.split("-", 1)[0] if "-" in n else n
            if pfx not in prefix_color:
                prefix_color[pfx] = group_palette[
                    len(prefix_color) % len(group_palette)
                ]
            return prefix_color[pfx]

        max_width = max(40, cols - 4)
        line = "    "
        visible = 4
        on_line = 0
        out: list[str] = []
        for n in names:
            need = len(n) + 2
            wrap_for_width = visible + need > max_width
            wrap_for_cap = on_line >= 2
            if (wrap_for_width or wrap_for_cap) and line.strip():
                out.append(line.rstrip())
                line = "    "
                visible = 4
                on_line = 0
            line += f"{_color_for(n)}{n}{RST}  "
            visible += need
            on_line += 1
        if line.strip():
            out.append(line.rstrip())
        sys.stderr.write(f"  {DIM}jobs:{RST}\n" + "\n".join(out) + "\n")

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
    """EventStore subscriber. Renders one event in wide or compact mode
    depending on the terminal width detected at write time. Wide = single
    line (~85 chars). Compact = 2 lines (header + indented summary)."""
    typ = record.get("type", "?")
    color, glyph = _EVENT_STYLE.get(typ, (GREY, "·"))
    if typ == "build_finished" and record.get("status") != "done":
        color, glyph = RED, "✗"
    ts = record.get("ts", time.time())
    try:
        hms = time.strftime("%H:%M:%S", time.localtime(float(ts)))
    except (TypeError, ValueError):
        hms = "--:--:--"
    msg = _summarize(record)

    if _is_narrow():
        # 2-line compact: short timestamp + glyph + type; message indented.
        # Skip the message line entirely if there's nothing to say.
        hm = hms[:5]   # HH:MM
        sys.stderr.write(f"{DIM}{hm}{RST} {color}{glyph} {typ}{RST}\n")
        if msg:
            sys.stderr.write(f"  {GREY}{msg}{RST}\n")
    else:
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
