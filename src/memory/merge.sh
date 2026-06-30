#!/bin/bash
# memory/merge.sh — the actual merge into the canonical drawer + slot/tsv
# reconcile. Honors $_MEM_DRY (1 = preview, no mutation).

_mem_is_dry() { [ "${_MEM_DRY:-0}" = 1 ]; }

# _mem_merge_claude_variant SRC_DIR DST_DIR SRCTAG — copy sessions into canonical.
# Slot pointers (UUID files) stay valid because the filename is preserved.
_mem_merge_claude_variant() {
    local src="$1" dst="$2" tag="$3" f base target sub
    [ -d "$src" ] || return 0
    if _mem_is_dry; then
        _log MEM "[DRY] would copy $(_mem_claude_sessions "$src") session(s) from $src → $dst"
        return 0
    fi
    mkdir -p "$dst"
    for f in "$src"/*.jsonl; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"; target="$dst/$base"
        if [ -e "$target" ]; then
            target="$dst/${base%.jsonl}.dup-$tag.jsonl"
            _log MEM WARNING "uuid collision: $base kept as $(basename "$target")"
        fi
        cp -p "$f" "$target" && _log_silent MEM "copied $f → $target"
    done
    for sub in subagents memory; do
        if [ -d "$src/$sub" ]; then
            mkdir -p "$dst/$sub"
            cp -pn "$src/$sub"/* "$dst/$sub"/ 2>/dev/null || true
            _log_silent MEM "merged $src/$sub → $dst/$sub"
        fi
    done
}

# _mem_oc_aux_tables — tables (besides session) that carry a directory column.
_mem_oc_aux_tables() {
    local t
    for t in $(_mem_oc_query "SELECT name FROM sqlite_master WHERE type='table' AND name!='session';"); do
        _mem_oc_query "PRAGMA table_info($t);" | awk -F'|' '{print $2}' | grep -qx directory && printf '%s\n' "$t"
    done
}

# _mem_oc_rewrite OLD_DIR NEW_DIR — transactional UPDATE of directory across
# session + any aux tables with a directory column. Idempotent.
_mem_oc_rewrite() {
    local old="$(_mem_sql_lit "$1")" new="$(_mem_sql_lit "$2")" t sql
    if _mem_is_dry; then
        _log MEM "[DRY] would UPDATE opencode directory '$1' → '$2'"
        return 0
    fi
    sql="BEGIN; UPDATE session SET directory='$new' WHERE directory='$old';"
    for t in $(_mem_oc_aux_tables); do
        sql="$sql UPDATE $t SET directory='$new' WHERE directory='$old';"
    done
    sql="$sql COMMIT;"
    if _mem_oc_query "$sql" >/dev/null; then
        _log MEM "opencode: directory '$1' → '$2'"
    else
        _mem_oc_query "ROLLBACK;" >/dev/null 2>&1
        _log MEM WARNING "opencode rewrite failed (db locked?) for '$1' — left in place"
    fi
}

# _mem_tsv_set_key TSV NAME — set project_key=NAME for rows whose session ref
# (col3) is on stdin (one uuid/id per line); dedupe (tid,key) keeping last.
# No 'rm': the mktemp output file is consumed by mv (project no-rm rule).
_mem_tsv_set_key() {
    local tsv="$1" name="$2" tmp
    [ -f "$tsv" ] || return 0
    if _mem_is_dry; then _log MEM "[DRY] would re-key terminal-sessions for '$name'"; return 0; fi
    tmp="$(mktemp)"
    awk -F'\t' -v OFS='\t' -v name="$name" '
        NR==FNR { if ($1!="") ids[$1]=1; next }
        { if ($3 in ids) $2=name; line[$1 SUBSEP $2]=$0 }
        END { for (k in line) print line[k] }
    ' /dev/stdin "$tsv" > "$tmp" && mv "$tmp" "$tsv"
    _log_silent MEM "re-keyed $tsv rows → $name"
}

# _mem_reconcile_claude_tsv NAME CANON_DIR — re-key claude tsv to canonical uuids.
_mem_reconcile_claude_tsv() {
    local name="$1" dir="$2"
    ls -1 "$dir"/*.jsonl 2>/dev/null | while read -r f; do basename "$f" .jsonl; done \
        | _mem_tsv_set_key "$MEM_CLAUDE_TSV" "$name"
}

# _mem_reconcile_oc_tsv NAME CANON_DIR_STRING — re-key opencode tsv.
_mem_reconcile_oc_tsv() {
    local name="$1" dir="$2"
    _mem_oc_query "SELECT id FROM session WHERE directory='$(_mem_sql_lit "$dir")';" \
        | _mem_tsv_set_key "$MEM_OC_TSV" "$name"
}
