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

# Event rows are NOT column-aligned (no tabulation — the pane is narrow, every
# cell counts): "HH:MM:SS <emoji> subject message", single-spaced, message
# truncated to whatever width is left so the row never wraps.

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


# 256-color palette — mirrors lib/ywizz/theme.sh (blues → light-purple →
# purple → pink). No gray, no dark green: the theme is purple-accent + blue.
C1 = "\033[38;5;33m"    # blue
C2 = "\033[38;5;39m"    # blue
C3 = "\033[38;5;45m"    # cyan
C4 = "\033[38;5;81m"    # light cyan
C5 = "\033[38;5;117m"   # sky blue
C6 = "\033[38;5;147m"   # light purple
C7 = "\033[38;5;177m"   # purple — primary accent (frame, header glyphs)
C8 = "\033[38;5;213m"   # pink — project name highlight
C9 = "\033[38;5;201m"   # magenta
ORANGE = "\033[38;5;208m"
GREEN  = "\033[38;5;82m"    # bright — reserved for success status only
RED    = "\033[38;5;196m"
YELLOW = "\033[38;5;220m"
GREY   = "\033[38;5;103m"   # muted slate-purple — replaces gray (theme has none)
DIM    = "\033[2m"
BOLD   = "\033[1m"
RST    = "\033[0m"


def title_bar(text: str, bg: str, fg: str = "16") -> str:
    """Full-width panel title chip: bold `fg`-on-`bg` label with the background
    filled to the pane edge (\\033[K). bg/fg are 256-color indices (strings)."""
    return f"\033[48;5;{bg}m\033[38;5;{fg}m{BOLD} {text} \033[K{RST}\n"

# LLM stacked over DOCKER. Always rendered the same shape — narrow pane
# is the target, but the art also looks fine when the pane is wider.
_ASCII_LINES = [
    "╻  ╻  ┏┳┓   ╺┳┓┏━┓┏━╸╻┏ ┏━╸┏━┓",
    "┃  ┃  ┃┃┃╺━╸ ┃┃┃ ┃┃  ┣┻┓┣╸ ┣┳┛",
    "┗━╸┗━╸╹ ╹   ╺┻┛┗━┛┗━╸╹ ╹┗━╸╹┗╸",
    "            ┏━┓┏━┓╻",
    "            ┣━┫┣━┛┃",
    "            ╹ ╹╹  ╹",
]


def _frame(lines, color):
    """ywizz-style box pinned to BOX_WIDTH. Top has a diamond + right
    corner; bottom is dashes flowing into a right corner only (no left
    connector, by design — leaves the box visually open on the left)."""
    width = min(_term_cols(), BOX_WIDTH)
    dashes = width - 3                       # "◆ " (2) + dashes + "╮" (1) = width
    content_w = width - 3                    # "│ " (2) + content + "│" (1) = width
    out = []
    out.append(f"{color}◆ {'─' * dashes}╮{RST}\n")
    for line in lines:
        pad = max(0, content_w - _visible_len(line))
        out.append(f"{color}│{RST} {line}{' ' * pad}{color}│{RST}\n")
    out.append(f"{color}{'─' * (width - 1)}╯{RST}\n")
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
    "tree":     ("util",   C4),
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
    "android":  ("android", C5),
    "angular":  ("angular", RED),
    "pt":       ("e2e",    C4),
    "db":       ("db",     C2),
    "sa":       ("sa",     YELLOW),
    # Code-quality + frontend ops — cool cyan family so it reads
    # as "checks/lint/build" rather than runtime/network/data.
    "lint":     ("lint",    C3),
    "format":   ("format",  C4),
    "preview":  ("preview", C6),
    "build":    ("build",   C5),
    # Test runners — orange, same as docker/compose, since their
    # green/red verdict is the visual eye-catch, not the family color.
    "e2e":      ("e2e",     ORANGE),
    "playwright": ("e2e",   ORANGE),
    "smoke":    ("test",    C4),
    "test":     ("test",    C4),
    # Database family — cool blue/cyan, distinct from `db-*` (C2).
    "pg":       ("pg",      C1),
    "mysql":    ("mysql",   C1),
    "redis":    ("redis",   RED),
    # Python/Django web framework — distinct cyan from pure python.
    "django":   ("django",  C6),
    # iOS / macOS toolchain — pink, same family as `ios`.
    "xcode":    ("xcode",   C8),
    "swift":    ("xcode",   C8),
    "pod":      ("xcode",   C8),
    # Long-lived sidecars / launchd-managed services.
    "lounge":   ("lounge",  YELLOW),
    "livekit":  ("livekit", C7),
    "uvicorn":  ("api",     C5),
    # Deploy / fab / envoy — pink so deploys jump out.
    "deploy":   ("deploy",  C8),
    "envoy":    ("deploy",  C8),
    "fab":      ("deploy",  C8),
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
    indent = ""
    sep = "  "
    avail = max(40, cols) - len(indent) - label_w - 2

    out = []
    for fam in order:
        col = colors[fam]
        label = f"{col}{_family_emoji(fam)} {fam:<{label_w}}{RST}"
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
    else:
        names = list(jobs_names)

    cols = _term_cols()

    # Center the ASCII block on the current pane width (recomputed every
    # render / WINCH resize). Pad each line by the same amount so the art's
    # internal alignment (the "API" under "DOCKER") is preserved.
    palette = [C1, C2, C3, C5, C6, C7]
    block_w = max((len(ln) for ln in _ASCII_LINES), default=0)
    pad = " " * max(0, (cols - block_w) // 2)
    art = []
    for i, line in enumerate(_ASCII_LINES):
        c = palette[min(i, len(palette) - 1)]
        art.append(f"{pad}{c}{line}{RST}\n")

    proj = f"{C8}{BOLD}{name}{RST}"
    listen = f"{C5}{bind}:{port}{RST}"
    status = [
        f"{C7}■{RST} {proj} {C6}·{RST} {listen}",
    ]

    sys.stderr.write(
        title_bar(f"BUILDER-API · {name}", "177")
        + "\n" + "".join(art) + "\n" + _frame(status, C7)
    )

    if names:
        sys.stderr.write(_render_jobs(names, cols))
    sys.stderr.flush()


# ── event tail ─────────────────────────────────────────────────────────

# Event styling. JOB rows take their emoji + name-color from the job's
# FAMILY (_classify) so the tail scans by category at a glance; the outcome
# text is tinted by STATUS (done=green/failed=red) independently. System
# rows get their own emoji here.
_FAMILY_EMOJI = {
    "verbs": "⚙️",  "util": "🧰",   "git": "🎸",     "python": "🐍",
    "django": "🕸️", "php": "🐘",    "node": "🟢",    "angular": "🅰️",
    "ios": "🍎",    "android": "🤖", "xcode": "🔨",   "compose": "🐳",
    "db": "🫙",     "pg": "🗄️",     "mysql": "🐬",   "redis": "🪫",
    "test": "🧪",   "e2e": "🎭",    "lint": "🥛",    "format": "🧹",
    "build": "🏗️",  "preview": "🔥", "deploy": "🚀",  "lounge": "🛋️",
    "livekit": "🎥", "api": "🔌",    "sa": "🧩",
}
_FAMILY_EMOJI_DEFAULT = "📦"

_SYS_STYLE = {  # system event type → (color, emoji)
    "server_started":       (GREEN,  "🟢"),
    "config_reloaded":      (C7,     "♻️"),
    "auth_failure_lockout": (RED,    "🚫"),
    "runtime_started":      (ORANGE, "▶️"),
    "runtime_stopped":      (YELLOW, "⏹️"),
    "runtime_exited":       (RED,    "🟥"),
}
_LOG_EMOJI = {"error": "‼️", "warning": "⚠️", "warn": "⚠️", "info": "ℹ️", "debug": "🔍"}


def _family_emoji(family: str) -> str:
    return _FAMILY_EMOJI.get(family, _FAMILY_EMOJI_DEFAULT)


def _status_color(rec: dict) -> str:
    t = rec.get("type")
    if t == "job_finished":
        return GREEN if rec.get("status") == "done" else RED
    if t == "job_cancelled":
        return YELLOW
    if t == "job_started":
        return ORANGE
    return GREY


def format_event_row(hms: str, color: str, glyph: str, typ: str, msg: str,
                      msg_color: str = "") -> str:
    """Canonical event-tail row, ONE line, NOT column-aligned:
        "HH:MM:SS <emoji> subject message"
    `color` tints the glyph + subject (the job's family color); `msg_color`
    tints the outcome, defaulting to grey. The message is truncated to whatever
    space is left after the (variable-width) prefix so the row never wraps."""
    cols = _term_cols()
    # Visible prefix = time(8) + " " + emoji(2 cells) + " " + subject + " ".
    prefix_vis = len(hms) + 1 + 2 + 1 + len(typ) + 1
    avail = max(8, cols - prefix_vis - 1)
    if len(msg) > avail:
        msg = msg[: max(0, avail - 1)] + "…"
    return (
        f"{GREY}{hms}{RST} {color}{glyph} {typ}{RST} "
        f"{msg_color or GREY}{msg}{RST}\n"
    )


def event_line(record: dict) -> None:
    """EventStore subscriber. Always single-line; message gets truncated
    rather than wrapped so the tail stays scannable."""
    typ = record.get("type", "?")
    # http_call is per-request traffic for the verbose console (cld-verbose),
    # NOT the api pane's state tail — skip it here or the tail floods.
    if typ == "http_call":
        return
    ts = record.get("ts", time.time())
    try:
        hms = time.strftime("%H:%M:%S", time.localtime(float(ts)))
    except (TypeError, ValueError):
        hms = "--:--:--"
    subject, msg = _event_view(record)
    if typ.startswith("job_"):
        # Emoji + name-color from the job's family; outcome tinted by status.
        family, color = _classify(record.get("job") or record.get("id") or "?")
        glyph = _family_emoji(family)
        msg_color = _status_color(record)
    elif typ.endswith("_log"):
        lvl = (record.get("level") or "info").lower()
        glyph = _LOG_EMOJI.get(lvl, "•")
        color = RED if lvl == "error" else YELLOW if lvl.startswith("warn") else GREY
        msg_color = color
    else:
        color, glyph = _SYS_STYLE.get(typ, (GREY, "•"))
        msg_color = GREY
    sys.stderr.write(format_event_row(hms, color, glyph, subject, msg, msg_color))
    sys.stderr.flush()


def _trailing_value(rec: dict) -> str:
    """The meaningful placeholder value — almost always the last non-flag
    argv element (`--filter DashCacheTest` → `DashCacheTest`, `-n 5` → `5`).
    What the operator scans for; the full argv is what `/events` is for."""
    for a in reversed(rec.get("args") or []):
        if isinstance(a, str) and a and not a.startswith("-"):
            return a
    return ""


def _event_view(rec: dict) -> tuple[str, str]:
    """(subject, message) for the event tail. SUBJECT is what the row is
    about — the job name for job events, a short label for system events —
    and goes in the prominent fixed column (NOT the redundant event type).
    MESSAGE is the plain-English outcome a human scans for. No id=/rc=/job=
    noise; `/events` carries the structured detail."""
    t = rec.get("type")
    job = rec.get("job") or rec.get("id") or "?"
    val = _trailing_value(rec)
    if t == "job_enqueued":
        return job, "queued" + (f"·{val}" if val else "")
    if t == "job_started":
        return job, "running" + (f"·{val}" if val else "")
    if t == "job_finished":
        el = rec.get("elapsed_s")
        if rec.get("status") == "done":
            return job, f"done·{el}s"
        bits = [rec.get("status") or "failed", f"rc={rec.get('returncode')}", f"{el}s"]
        if rec.get("reason"):
            bits.append(str(rec.get("reason")))
        return job, "·".join(bits)
    if t == "job_cancelled":
        return job, "cancelled"
    if t == "config_reloaded":
        return "config", f"reloaded·{len(rec.get('jobs', []))} jobs"
    if t == "server_started":
        return "server", f"{rec.get('bind')}:{rec.get('port')}"
    if t == "auth_failure_lockout":
        return "lockout", f"{rec.get('ip')}·locked {rec.get('lockout_s')}s"
    if t and t.endswith("_log"):
        return rec.get("level", "log"), (rec.get("message") or "")[:80]
    return t or "?", ""
