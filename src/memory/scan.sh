#!/bin/bash
# memory/scan.sh — read-only discovery. Emits one variant record per line:
#   tool <TAB> container_path <TAB> store_ref <TAB> name <TAB> depth
# tool = claude|opencode. store_ref = host dashed dir (claude) or directory
# string (opencode). No mutation here.

# _mem_scan_claude [NAME] — emit claude variants (optionally filtered to NAME).
_mem_scan_claude() {
    local filter="${1:-}" d cwd name depth
    [ -d "$MEM_CLAUDE_PROJECTS" ] || return 0
    for d in "$MEM_CLAUDE_PROJECTS"/-*; do
        [ -d "$d" ] || continue
        if ! cwd="$(_mem_cwd_from_dir "$d")"; then
            _log_silent MEM WARNING "skip unreadable claude dir (no cwd in jsonl): $d"
            continue
        fi
        name="$(basename "$cwd")"
        [ -n "$filter" ] && [ "$name" != "$filter" ] && continue
        depth="$(_mem_depth "$cwd")"
        printf 'claude\t%s\t%s\t%s\t%s\n' "$cwd" "$d" "$name" "$depth"
    done
}

# _mem_oc_query SQL — run a query with a busy timeout. Empty on error.
# .timeout is a dot-command (no result row) — unlike `PRAGMA busy_timeout=N;`
# which emits a row that would pollute every SELECT.
_mem_oc_query() {
    command -v sqlite3 >/dev/null 2>&1 || return 1
    [ -f "$MEM_OC_DB" ] || return 1
    sqlite3 -batch -cmd ".timeout 4000" "$MEM_OC_DB" "$1" 2>/dev/null
}

# _mem_oc_columns — space-separated column names of the session table.
_mem_oc_columns() {
    _mem_oc_query "PRAGMA table_info(session);" | awk -F'|' '{print $2}' | tr '\n' ' '
}

# _mem_oc_has_col COL — true if the session table has column COL.
_mem_oc_has_col() {
    case " $(_mem_oc_columns) " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# _mem_scan_opencode [NAME] — emit opencode variants from the session table.
_mem_scan_opencode() {
    local filter="${1:-}" dir name depth
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        name="$(basename "$dir")"
        [ -n "$filter" ] && [ "$name" != "$filter" ] && continue
        depth="$(_mem_depth "$dir")"
        printf 'opencode\t%s\t%s\t%s\t%s\n' "$dir" "$dir" "$name" "$depth"
    done < <(_mem_oc_query "SELECT DISTINCT directory FROM session;")
}

# _mem_scan_all [NAME] — both tools.
_mem_scan_all() { _mem_scan_claude "${1:-}"; _mem_scan_opencode "${1:-}"; }
