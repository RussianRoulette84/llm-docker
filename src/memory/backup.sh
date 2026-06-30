#!/bin/bash
# memory/backup.sh — safe backup, trash, and restore. NEVER uses rm.
# A "run dir" groups one merge invocation so it restores as a unit:
#   $MEM_BACKUP_ROOT/<timestamp>/{claude/<dashed-dir>, opencode/restore.sql}

# _mem_new_backup_dir — create & echo a unique run dir (-$$ on same-second clash).
_mem_new_backup_dir() {
    local ts base
    ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
    base="$MEM_BACKUP_ROOT/$ts"
    [ -e "$base" ] && base="$base-$$"
    mkdir -p "$base/claude" "$base/opencode"
    printf '%s' "$base"
}

# _mem_oc_capture OLD_DIR RUNDIR — record a reverse UPDATE (run BEFORE rewrite).
_mem_oc_capture() {
    local old="$1" rundir="$2" lit ids
    _mem_is_dry && { _log MEM "[DRY] would capture opencode rows for '$old'"; return 0; }
    lit="$(_mem_sql_lit "$old")"
    ids="$(_mem_oc_query "SELECT id FROM session WHERE directory='$lit';" \
        | awk 'NF{printf "%s'\''%s'\''", sep, $0; sep=","}')"
    [ -z "$ids" ] && return 0
    printf "UPDATE session SET directory='%s' WHERE id IN (%s);\n" "$old" "$ids" \
        >> "$rundir/opencode/restore.sql"
    _log_silent MEM "captured opencode restore for '$old'"
}

# _mem_stash_claude SRC_DIR RUNDIR — move a non-canonical dir into the backup.
_mem_stash_claude() {
    local src="$1" rundir="$2"
    [ -d "$src" ] || return 0
    _mem_is_dry && { _log MEM "[DRY] would back up $src → $rundir/claude/"; return 0; }
    mv "$src" "$rundir/claude/" && _log MEM "backed up $(basename "$src") → $rundir/claude/"
}

# _mem_trash PATH — trash (recoverable) or fall back to leaving it; never rm.
_mem_trash() {
    local p="$1"
    [ -e "$p" ] || return 0
    _mem_is_dry && { _log MEM "[DRY] would trash $p"; return 0; }
    if command -v trash >/dev/null 2>&1; then
        trash "$p" && _log MEM "trashed $(basename "$p")"
    else
        _log MEM WARNING "no 'trash' available — left $p in place (never rm)"
    fi
}

# _mem_restore — interactive: pick a backup run dir, undo it.
_mem_restore() {
    [ -d "$MEM_BACKUP_ROOT" ] || { _mem_warn "no backups under $MEM_BACKUP_ROOT"; return 0; }
    local runs choice d
    runs="$(ls -1 "$MEM_BACKUP_ROOT" 2>/dev/null)"
    [ -z "$runs" ] && { _mem_warn "no backups to restore"; return 0; }
    _mem_head "Restore memory from backup"
    select_tui "Pick a backup to restore" "$runs" "" "" choice 0 true 0 1 || return 0
    d="$MEM_BACKUP_ROOT/$choice"
    [ -d "$d" ] || { _mem_warn "no such backup: $choice"; return 0; }
    # Claude: move dashed dirs back (merge canonical keeps its copies).
    local sub base
    for sub in "$d"/claude/-*; do
        [ -d "$sub" ] || continue
        base="$(basename "$sub")"
        if [ -e "$MEM_CLAUDE_PROJECTS/$base" ]; then
            _log MEM WARNING "restore target exists, skipping $base"
        else
            mv "$sub" "$MEM_CLAUDE_PROJECTS/" && _log MEM "restored $base"
        fi
    done
    # OpenCode: replay reverse UPDATEs.
    if [ -f "$d/opencode/restore.sql" ]; then
        _mem_oc_query "$(cat "$d/opencode/restore.sql")" >/dev/null \
            && _log MEM "restored opencode directories"
    fi
    _mem_ok "restore complete from $choice"
}
