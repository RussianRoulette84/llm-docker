#!/bin/bash
# memory/memory.sh — loader + shared constants for the duplicate-memory merge
# tool. Sourced by src/cld and src/ocd after setup.sh. Public entries:
#   _memory_merge_autorun        best-effort on-launch merge for the CURRENT project
#   _memory_merge_manual MODE    interactive full scan (MODE: manual|dry)
#   _mem_restore                 undo a previous merge from a backup
#
# Keying is folder-name only (see setup/identity.sh). Duplicates arise when the
# same folder name was recorded under two container paths (e.g. the old
# WORKSPACE_DIR bug: /root/Projects/ai/slav-ai vs /root/Projects/slav-ai).

MEM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── storage roots (override MEM_HOME for tests) ─────────────────────────────
MEM_HOME="${MEM_HOME:-$HOME/.llm-docker}"
MEM_DOT_CLAUDE="$MEM_HOME/claude/.claude"
MEM_CLAUDE_PROJECTS="$MEM_DOT_CLAUDE/projects"
MEM_CLAUDE_TSV="$MEM_DOT_CLAUDE/terminal-sessions.tsv"
MEM_OC_DIR="$MEM_HOME/opencode/.local/share/opencode"
MEM_OC_DB="$MEM_OC_DIR/opencode.db"
MEM_OC_TSV="$MEM_OC_DIR/terminal-sessions.tsv"
MEM_BACKUP_ROOT="$MEM_HOME/.memory-backup"

# ── dependency back-fill (so the module also runs standalone in tests) ───────
if ! command -v _log >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    [ -f "$MEM_LIB_DIR/../setup/log.sh" ] && SCRIPT_DIR="${SCRIPT_DIR:-$MEM_LIB_DIR/..}" \
        source "$MEM_LIB_DIR/../setup/log.sh"
fi
if [ -z "${_MEM_YWIZZ:-}" ]; then
    # shellcheck disable=SC1090
    [ -f "$MEM_LIB_DIR/../lib/ywizz/ywizz.sh" ] && source "$MEM_LIB_DIR/../lib/ywizz/ywizz.sh"
    _MEM_YWIZZ=1
fi
accent_color="${accent_color:-$C7}"   # purple house accent

# Glyph helpers (replicated from install_test.sh:24-26 — they're inline there).
_mem_ok()   { printf "  %b✔%b %s\n"  "$GREEN"  "$RESET" "$1" >&2; }
_mem_warn() { printf "  %b!%b %s\n"  "$YELLOW" "$RESET" "$1" >&2; }
_mem_row()  { printf "  %b%s%b\n"    "$DIM"    "$1"     "$RESET" >&2; }
_mem_head() { printf "\n%b◆ %s%b\n"  "$C7"     "$1"     "$RESET" >&2; }

# ── tiny shared utilities ───────────────────────────────────────────────────

# _mem_dash CONTAINER_PATH — Claude's on-disk dir name (/ _ . -> -, leading -).
_mem_dash() {
    local p="${1#/}"
    printf -- '-%s' "$(printf '%s' "$p" | tr '/_.' '-')"
}

# _mem_depth PATH — number of '/' segments (for canonical election: fewest wins).
_mem_depth() { local p="${1#/}"; printf '%s' "${p//[!\/]/}" | wc -c | tr -d ' '; }

# _mem_cwd_from_dir HOSTDIR — authoritative container cwd from any jsonl inside.
_mem_cwd_from_dir() {
    local d="$1" f cwd
    f="$(ls -1 "$d"/*.jsonl 2>/dev/null | head -1)"
    [ -z "$f" ] && return 1
    cwd="$(grep -o '"cwd":"[^"]*"' "$f" 2>/dev/null | head -1)"
    cwd="${cwd#\"cwd\":\"}"; cwd="${cwd%\"}"
    [ -z "$cwd" ] && return 1
    printf '%s' "$cwd"
}

# _mem_git_name NAME — bare repo name (e.g. "llm-docker") for the LIVE project
# at $WORKSPACE_DIR/NAME, else empty. Compares names only, never owner/name.
_mem_git_name() {
    local name="$1" dir url
    dir="${WORKSPACE_DIR:+$WORKSPACE_DIR/$name}"
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    url="$(git -C "$dir" remote get-url origin 2>/dev/null)" || return 0
    url="${url%.git}"; printf '%s' "${url##*/}"
}

# shellcheck source=/dev/null
source "$MEM_LIB_DIR/scan.sh"
# shellcheck source=/dev/null
source "$MEM_LIB_DIR/display.sh"
# shellcheck source=/dev/null
source "$MEM_LIB_DIR/merge.sh"
# shellcheck source=/dev/null
source "$MEM_LIB_DIR/backup.sh"
# shellcheck source=/dev/null
source "$MEM_LIB_DIR/run.sh"
