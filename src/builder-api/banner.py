"""
banner.py — terminal aesthetics for the daemon. Boot banner + color-coded
event tail. Stdlib-only ANSI; no extra deps.

Wired in two places:
  1. server.main() prints `show_banner(...)` once at start.
  2. AppContext subscribes `event_line` to the EventStore so every
     append() surfaces as a colored one-liner on stderr.

Layout target: a tall-narrow side pane (~75 cols wide). The boot box is
hard-pinned to BOX_WIDTH so the look stays consistent regardless of pane
width; jobs + events flow into whatever extra width is available when
the user resizes the pane wider.
"""

from __future__ import annotations

import os
import re
import sys
import time

# Hard-pinned visual width of the boot box. Matches one full top edge:
#   "  ◆ ──── ... ────╮"  →  2 + 2 + 56 + 1 = 61 cells.
# Pane is rendered narrower if the terminal is genuinely smaller than this.
BOX_WIDTH = 61

# Fixed visible width of the event-row prefix:
#   "  HH:MM:SS  " (12) + "▸ " (2) + type padded to 22 (22) + "  " (2) = 38.
# Event/access-log message text is truncated to (cols - EV_PREFIX_W - 1).
EV_PREFIX_W = 38
EV_TYPE_W = 22

_ANSI_RE = re.compile(r"\033\[[0-9;]*m")


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


def _visible_len(s: str) -> int:
    return len(_ANSI_RE.sub("", s))


# 256-color palette — ywizz purple/cyan/pink + a few accent slots.
C1 = "\033[38;5;33m"
C2 = "\033[38;5;39m"
C3 = "\033[38;5;45m"
C4 = "\033[38;5;51m"
C5 = "\033[38;5;81m"
C6 = "\033[38;5;87m"
C7 = "\033[38;5;141m"   # purple — primary accent (frame, header glyphs)
C8 = "\033[38;5;213m"   # pink — project name highlight
ORANGE = "\033[38;5;208m"
GREEN  = "\033[38;5;82m"
RED    = "\033[38;5;196m"
YELLOW = "\033[38;5;220m"
GREY   = "\033[38;5;244m"
DIM    = "\033[2m"
BOLD   = "\033[1m"
RST    = "\033[0m"

# LLM stacked over DOCKER. Always rendered the same shape — narrow pane
# is the target, but the art also looks fine when the pane is wider.
_ASCII_LINES = [
    " ██     ██     ██▄  ▄██",
    " ██     ██     ██ ▀▀ ██",
    " ██████ ██████ ██    ██",
    " ▄▄▄▄   ▄▄▄   ▄▄▄▄ ▄▄ ▄▄ ▄▄▄▄▄ ▄▄▄▄",
    " ██▀██ ██▀██ ██▀▀▀ ██▄█▀ ██▄▄  ██▄█▄",
    " ████▀ ▀███▀ ▀████ ██ ██ ██▄▄▄ ██ ██",
    "             API",
]


def _frame(lines, color):
    """ywizz-style box pinned to BOX_WIDTH. Top has a diamond + right
    corner; bottom is dashes flowing into a right corner only (no left
    connector, by design — leaves the box visually open on the left)."""
    width = min(_term_cols(), BOX_WIDTH)
    dashes = width - 5                       # space for "  ◆ " + "╮"
    content_w = width - 6                    # space inside │  …  │
    out = []
    out.append(f"  {color}◆ {'─' * dashes}╮{RST}\n")
    for line in lines:
        pad = max(0, content_w - _visible_len(line))
        out.append(f"  {color}│{RST}  {line}{' ' * pad}{color}│{RST}\n")
    out.append(f"    {color}{'─' * (dashes - 0)}╯{RST}\n")
    return "".join(out)


# ── job classification ─────────────────────────────────────────────────
# Curated family map: maps either an exact job name or a "<prefix>-..."
# left-side to a (family-label, color) pair. First match wins.
#
# Order matters only in that EXACT match beats prefix match. The render
# order of families is: verbs first, then whatever-came-up next in the
# job list (preserves the host config's intent).
_EXACT_FAMILY = {
    # verb dispatchers (declared in [verb.*])
    "up":       ("verbs",  C7),
    "down":     ("verbs",  C7),
    "restart":  ("verbs",  C7),
    "build":    ("verbs",  C7),
    "lint":     ("verbs",  C7),
    "test":     ("verbs",  C7),
    "logs":     ("verbs",  C7),
    "status":   ("verbs",  C7),
    "deploy":   ("verbs",  C7),
    "tree":     ("util",   GREEN),
    # PHP single-word tools
    "pint":     ("php",    C8),
    "phpstan":  ("php",    C8),
    "psalm":    ("php",    C8),
    "phpcs":    ("php",    C8),
}

_PREFIX_FAMILY = {
    "git":      ("git",    C3),
    "pytest":   ("python", C5),
    "ruff":     ("python", C5),
    "mypy":     ("python", C5),
    "pip":      ("python", C5),
    "phpunit":  ("php",    C8),
    "composer": ("php",    C8),
    "artisan":  ("php",    C8),
    "pint":     ("php",    C8),
    "phpstan":  ("php",    C8),
    "npm":      ("node",   C6),
    "pnpm":     ("node",   C6),
    "yarn":     ("node",   C6),
    "node":     ("node",   C6),
    "tsc":      ("node",   C6),
    "jest":     ("node",   C6),
    "vite":     ("node",   C6),
    "eslint":   ("node",   C6),
    "prettier": ("node",   C6),
    "docker":   ("compose", ORANGE),
    "compose":  ("compose", ORANGE),
    "ios":      ("ios",    C8),
    "android":  ("android", GREEN),
    "angular":  ("angular", RED),
    "pt":       ("e2e",    C4),
    "db":       ("db",     C2),
    "sa":       ("sa",     YELLOW),
}


def _classify(name: str):
    hit = _EXACT_FAMILY.get(name)
    if hit:
        return hit
    pfx = name.split("-", 1)[0]
    hit = _PREFIX_FAMILY.get(pfx)
    if hit:
        return hit
    return (pfx if "-" in name else "misc", GREY)


def _render_jobs(names, cols: int) -> str:
    """Group jobs by family; print each family on its own indented row,
    family label colored, jobs in same color. Verbs section first; other
    families in first-seen order. Long family rows wrap at terminal width
    (not BOX_WIDTH) so a wider pane shows more per line."""
    groups: dict[str, list[str]] = {}
    colors: dict[str, str] = {}
    order: list[str] = []
    for n in names:
        fam, col = _classify(n)
        if fam not in groups:
            groups[fam] = []
            colors[fam] = col
            order.append(fam)
        groups[fam].append(n)

    if "verbs" in order:
        order.remove("verbs")
        order.insert(0, "verbs")

    label_w = max((len(f) for f in order), default=4)
    label_w = max(label_w, 6)
    indent = "    "
    sep = "  "
    avail = max(40, cols) - len(indent) - label_w - 2

    out = [f"  {DIM}jobs{RST}\n"]
    for fam in order:
        col = colors[fam]
        label = f"{col}▸ {fam:<{label_w}}{RST}"
        line = ""
        width_used = 0
        for j in groups[fam]:
            piece = f"{col}{j}{RST}"
            need = len(j) + len(sep)
            if line and width_used + need > avail:
                out.append(f"{indent}{label}  {line.rstrip()}\n")
                label = f"{' ' * (len(fam) + 2)}{' ' * (label_w - len(fam))}"
                line = ""
                width_used = 0
            line += piece + sep
            width_used += need
        if line:
            out.append(f"{indent}{label}  {line.rstrip()}\n")
    return "".join(out)


# ── public banner ──────────────────────────────────────────────────────


def show_banner(name: str, bind: str, port: int, jobs_names) -> None:
    """Print the boot banner + status header to stderr. The box is
    pinned to BOX_WIDTH (or the terminal width, whichever is smaller).
    Jobs flow to the actual terminal width below the box."""
    if isinstance(jobs_names, int):
        names: list[str] = []
        jobs_count = jobs_names
    else:
        names = list(jobs_names)
        jobs_count = len(names)

    cols = _term_cols()

    palette = [C1, C2, C3, C5, C6, C7]
    art = []
    for i, line in enumerate(_ASCII_LINES):
        c = palette[min(i, len(palette) - 1)]
        art.append(f"  {c}{line}{RST}\n")

    proj = f"{C8}{BOLD}{name}{RST}"
    listen = f"{C5}{bind}:{port}{RST}"
    jobs = f"{DIM}jobs{RST} {C7}{jobs_count}{RST}"
    status = [
        f"{C7}■{RST} {proj}  {DIM}·{RST}  {listen}",
        f"{jobs}  {DIM}·  events live below{RST}",
    ]

    sys.stderr.write("\n" + "".join(art) + "\n" + _frame(status, C7))

    if names:
        sys.stderr.write(_render_jobs(names, cols))
    sys.stderr.flush()


# ── event tail ─────────────────────────────────────────────────────────

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


def format_event_row(hms: str, color: str, glyph: str, typ: str, msg: str) -> str:
    """Canonical event-tail row. Always ONE line:
        "  HH:MM:SS  ▸ type<EV_TYPE_W>  message"
    Message is truncated to fit (cols - EV_PREFIX_W - 1) so the row never
    spills onto a second line, regardless of pane width. Shared by
    `event_line()` and the HTTP access-log handler so events + access logs
    align column-for-column."""
    cols = _term_cols()
    avail = max(20, cols - EV_PREFIX_W - 1)
    if len(msg) > avail:
        msg = msg[: max(0, avail - 1)] + "…"
    short_typ = (typ if len(typ) <= EV_TYPE_W else typ[: EV_TYPE_W - 1] + "…")
    return (
        f"  {DIM}{hms}{RST}  {color}{glyph} "
        f"{short_typ:<{EV_TYPE_W}}{RST}  {GREY}{msg}{RST}\n"
    )


def event_line(record: dict) -> None:
    """EventStore subscriber. Always single-line; message gets truncated
    rather than wrapped so the tail stays scannable."""
    typ = record.get("type", "?")
    color, glyph = _EVENT_STYLE.get(typ, (GREY, "·"))
    if typ == "build_finished" and record.get("status") != "done":
        color, glyph = RED, "✗"
    ts = record.get("ts", time.time())
    try:
        hms = time.strftime("%H:%M:%S", time.localtime(float(ts)))
    except (TypeError, ValueError):
        hms = "--:--:--"
    sys.stderr.write(format_event_row(hms, color, glyph, typ, _summarize(record)))
    sys.stderr.flush()


def _build_summary(rec: dict) -> str:
    """Short one-liner for build_* events. Show id + job + the trailing
    placeholder VALUE (almost always the last argv element — e.g.
    `--filter DashCacheTest` → `DashCacheTest`). Never dumps the full
    resolved argv: that's what `/events` is for."""
    bits = [f"id={rec.get('id')}"]
    job = rec.get("job")
    if job:
        bits.append(f"job={job}")
    args = rec.get("args") or []
    for a in reversed(args):
        if isinstance(a, str) and a and not a.startswith("-"):
            bits.append(a)
            break
    return "  ".join(bits)


def _summarize(rec: dict) -> str:
    """One-liner per event type. Output is bounded — format_event_row
    truncates anyway, but we still keep messages tight here so the
    truncated suffix carries actual information rather than ellipsis."""
    t = rec.get("type")
    if t in ("build_enqueued", "build_started"):
        return _build_summary(rec)
    if t == "build_finished":
        bits = [f"id={rec.get('id')}"]
        job = rec.get("job")
        if job:
            bits.append(f"job={job}")
        bits.append(f"rc={rec.get('returncode')}")
        bits.append(f"{rec.get('elapsed_s')}s")
        status = rec.get("status")
        if status and status != "done":
            bits.append(status)
        reason = rec.get("reason")
        if reason:
            bits.append(f"({reason})")
        return "  ".join(bits)
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
