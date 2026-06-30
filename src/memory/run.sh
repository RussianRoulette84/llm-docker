#!/bin/bash
# memory/run.sh — orchestrates scan → group → display → confirm → merge →
# reconcile → dispose. Public: _memory_merge_autorun, _memory_merge_manual.

# _mem_autorun_gate NAME CANON — fast yes/no: is there anything to merge?
_mem_autorun_gate() {
    local name="$1" canon="$2" cdash dsuf d
    cdash="$(_mem_dash "$canon")"
    dsuf="-$(printf '%s' "$name" | tr '/_.' '-')"
    if [ -d "$MEM_CLAUDE_PROJECTS" ]; then
        for d in "$MEM_CLAUDE_PROJECTS"/*"$dsuf"; do
            [ -d "$d" ] || continue
            [ "$(basename "$d")" = "$cdash" ] && continue
            return 0
        done
    fi
    [ "$(_mem_oc_query "SELECT count(*) FROM session WHERE directory LIKE '%/$(_mem_sql_lit "$name")' AND directory!='$(_mem_sql_lit "$canon")';" 2>/dev/null)" -gt 0 ] 2>/dev/null && return 0
    return 1
}

# _mem_process_group MODE NAME CANON_OVERRIDE RECORDS
_mem_process_group() {
    local mode="$1" name="$2" canon="$3" records="$4"
    local group noncanon gitname conf ans disp rundir
    group="$(printf '%s\n' "$records" | awk -F'\t' -v n="$name" '$4==n{print}')"
    [ -z "$group" ] && return 0
    [ -z "$canon" ] && canon="$(printf '%s\n' "$group" | sort -t"$(printf '\t')" -k5,5n | head -1 | cut -f2)"
    noncanon="$(printf '%s\n' "$group" | awk -F'\t' -v c="$canon" '$2!=c && $2!=""{print}')"
    [ -z "$noncanon" ] && { [ "$mode" != auto ] && _mem_row "'$name': already single — nothing to merge"; return 0; }

    gitname="$(_mem_git_name "$name")"
    if [ -n "$gitname" ]; then conf="✅ 100% match (git repo: $gitname). OK to merge?"; ans=y
    else conf="⚠ name match only (no git info). Merge?"; ans=n; fi

    printf '%s\n' "$group" | _mem_display_group "$name" "$canon" "$conf"

    if [ "$mode" = dry ]; then
        _MEM_DRY=1 _mem_do_merge "$name" "$canon" "$noncanon"
        return 0
    fi
    local CONFIRM=""
    ask_yes_no_tui "$conf" "$ans" CONFIRM 1 0
    [ "$CONFIRM" = y ] || { _log MEM "skipped '$name' (user declined)"; return 0; }

    rundir="$(_mem_new_backup_dir)"
    _MEM_DRY=0 _mem_do_merge "$name" "$canon" "$noncanon" "$rundir"

    local DISP=""
    select_tui "Old copies of '$name'?" "$(printf 'Move to backup\nKeep in place\nDelete (trash)')" \
        "" "" DISP 0 true 1 1
    _mem_dispose "$DISP" "$rundir" "$noncanon"
    _mem_ok "merged '$name' → $canon"
}

# _mem_do_merge NAME CANON NONCANON [RUNDIR] — copy/rewrite each variant in.
_mem_do_merge() {
    local name="$1" canon="$2" noncanon="$3" rundir="${4:-}"
    local tool cpath store n d dst tag
    dst="$MEM_CLAUDE_PROJECTS/$(_mem_dash "$canon")"
    while IFS=$'\t' read -r tool cpath store n d; do
        [ -n "$tool" ] || continue
        if [ "$tool" = claude ]; then
            tag="$(basename "$store")"; tag="${tag##*-}"
            _mem_merge_claude_variant "$store" "$dst" "$tag"
        else
            [ -n "$rundir" ] && _mem_oc_capture "$cpath" "$rundir"
            _mem_oc_rewrite "$cpath" "$canon"
        fi
    done <<< "$noncanon"
    _mem_reconcile_claude_tsv "$name" "$dst"
    _mem_reconcile_oc_tsv "$name" "$canon"
}

# _mem_dispose DISP RUNDIR NONCANON — handle the keep/backup/delete choice.
_mem_dispose() {
    local disp="$1" rundir="$2" noncanon="$3" tool cpath store n d
    while IFS=$'\t' read -r tool cpath store n d; do
        [ "$tool" = claude ] || continue
        case "$disp" in
            "Keep in place")   _log MEM "kept original $store (duplicate remains)" ;;
            "Delete (trash)")  _mem_trash "$store" ;;
            *)                 _mem_stash_claude "$store" "$rundir" ;;
        esac
    done <<< "$noncanon"
    [ "$disp" = "Keep in place" ] || _mem_row "backup: $rundir"
}

# _mem_run_pipeline MODE [NAME CANON] — scan + iterate groups.
_mem_run_pipeline() {
    local mode="$1" only="${2:-}" canon="${3:-}" records names name
    records="$(_mem_scan_all "$only")"
    [ -z "$records" ] && { [ "$mode" != auto ] && _mem_warn "no memory found"; return 0; }
    if [ -n "$only" ]; then names="$only"
    else names="$(printf '%s\n' "$records" | awk -F'\t' 'NF{print $4}' | sort -u)"; fi
    for name in $names; do
        _mem_process_group "$mode" "$name" "$canon" "$records"
    done
}

# ── public entries ──────────────────────────────────────────────────────────

# best-effort, on-launch, current project only. Never blocks/breaks a launch.
_memory_merge_autorun() {
    [ -t 0 ] && [ -t 1 ] || return 0           # no TTY → skip (would hang on prompt)
    command -v _project_docker_workdir >/dev/null 2>&1 || return 0
    local wd name
    wd="$(_project_docker_workdir "$CURRENT_DIR" "$WORKSPACE_DIR" "$DOCKER_DIR" \
        "$WORKSPACE_MOUNT_ACTIVE" "$DOCKER_WORKSPACE_TARGET")" || return 0
    name="$(basename "$wd")"
    _mem_autorun_gate "$name" "$wd" || return 0
    _mem_head "Duplicate memory detected for '$name' — let's tidy it up"
    _mem_run_pipeline auto "$name" "$wd"
}

# manual full scan. MODE: manual (interactive) | dry (preview only).
_memory_merge_manual() {
    local mode="${1:-manual}"
    _mem_head "Memory merge — scanning all projects (${mode})"
    _mem_run_pipeline "$mode"
    _mem_ok "scan complete"
}
