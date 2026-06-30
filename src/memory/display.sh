#!/bin/bash
# memory/display.sh — per-variant stats + the colored group table. Read-only.

# _mem_sql_lit S — single-quote-escape for inline SQL literals.
_mem_sql_lit() { printf '%s' "${1//\'/\'\'}"; }

# _mem_epoch_fmt EPOCH — YYYY-MM-DD (GNU or BSD date), or "?" .
_mem_epoch_fmt() {
    [ -n "$1" ] || { printf '?'; return; }
    date -d "@$1" '+%Y-%m-%d' 2>/dev/null || date -r "$1" '+%Y-%m-%d' 2>/dev/null || printf '?'
}

# ── claude variant stats ────────────────────────────────────────────────────
_mem_claude_sessions() { ls -1 "$1"/*.jsonl 2>/dev/null | wc -l | tr -d ' '; }
_mem_claude_size()     { du -sh "$1" 2>/dev/null | cut -f1; }

# slots pointing into this claude dir (slot's UUID has a .jsonl here).
_mem_claude_slots() {
    local dir="$1" sf id n=0
    for sf in "$MEM_DOT_CLAUDE"/slot_*.id; do
        [ -f "$sf" ] || continue
        id="$(tr -d '[:space:]' < "$sf")"
        [ -n "$id" ] && [ -f "$dir/$id.jsonl" ] && n=$((n+1))
    done
    printf '%s' "$n"
}

_mem_claude_dates() {
    local ts; ts="$(grep -h -o '"timestamp":"[^"]*"' "$1"/*.jsonl 2>/dev/null \
        | sed 's/"timestamp":"//;s/"//;s/T.*//' | sort)"
    [ -z "$ts" ] && { printf '? → ?'; return; }
    printf '%s → %s' "$(printf '%s\n' "$ts" | head -1)" "$(printf '%s\n' "$ts" | tail -1)"
}

_mem_claude_names() {
    grep -h '"type":"ai-title"' "$1"/*.jsonl 2>/dev/null \
        | grep -o '"aiTitle":"[^"]*"' | sed 's/"aiTitle":"//;s/"$//' | head -3 | paste -sd'; ' -
}

# ── opencode variant stats ──────────────────────────────────────────────────
_mem_oc_sessions() {
    _mem_oc_query "SELECT count(*) FROM session WHERE directory='$(_mem_sql_lit "$1")';"
}
_mem_oc_slots() {
    local dir="$1" sf id n=0
    for sf in "$MEM_OC_DIR"/slot_*.id; do
        [ -f "$sf" ] || continue
        id="$(tr -d '[:space:]' < "$sf")"
        [ -z "$id" ] && continue
        [ "$(_mem_oc_query "SELECT count(*) FROM session WHERE id='$(_mem_sql_lit "$id")' AND directory='$(_mem_sql_lit "$dir")';")" = "1" ] && n=$((n+1))
    done
    printf '%s' "$n"
}
_mem_oc_dates() {
    _mem_oc_has_col time_created || { printf '? → ?'; return; }
    local lit; lit="$(_mem_sql_lit "$1")"
    local lo hi
    lo="$(_mem_oc_query "SELECT min(time_created) FROM session WHERE directory='$lit';")"
    hi="$(_mem_oc_query "SELECT max(time_created) FROM session WHERE directory='$lit';")"
    printf '%s → %s' "$(_mem_epoch_fmt "$lo")" "$(_mem_epoch_fmt "$hi")"
}
_mem_oc_names() {
    local col="id"; _mem_oc_has_col title && col="title"
    _mem_oc_query "SELECT $col FROM session WHERE directory='$(_mem_sql_lit "$1")' LIMIT 3;" | paste -sd'; ' -
}

# _mem_display_group NAME CANONICAL GIT_CONF  (group records on stdin)
_mem_display_group() {
    local name="$1" canon="$2" conf="$3" tool cpath store n d sessions slots dates names tag
    _mem_head "Project '$name'  —  $conf"
    while IFS=$'\t' read -r tool cpath store n d; do
        [ -n "$tool" ] || continue
        if [ "$tool" = claude ]; then
            sessions="$(_mem_claude_sessions "$store")"; slots="$(_mem_claude_slots "$store")"
            dates="$(_mem_claude_dates "$store")"; names="$(_mem_claude_names "$store")"
            tag="$(_mem_claude_size "$store")"
        else
            sessions="$(_mem_oc_sessions "$store")"; slots="$(_mem_oc_slots "$store")"
            dates="$(_mem_oc_dates "$store")"; names="$(_mem_oc_names "$store")"; tag="db"
        fi
        if [ "$cpath" = "$canon" ]; then
            printf "  %b●%b %-8s %b%s%b  %b[canonical]%b\n" "$GREEN" "$RESET" "$tool" "$BOLD" "$cpath" "$RESET" "$GREEN" "$RESET" >&2
        else
            printf "  %b○%b %-8s %s  %b[merge in]%b\n" "$YELLOW" "$RESET" "$tool" "$cpath" "$YELLOW" "$RESET" >&2
        fi
        _mem_row "     $tag · ${sessions:-0} sess · ${slots:-0} slots · $dates"
        [ -n "$names" ] && _mem_row "     └ $names"
    done
}
