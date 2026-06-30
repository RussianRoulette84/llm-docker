# setup/identity.sh — module of the split setup.sh (sourced by the setup.sh loader).

# ── Project identity + deletion-safe mounts ────────────────────────────────
# These exist to fix two real failure modes:
#   1. Data loss — the whole WORKSPACE_DIR used to be mounted read-WRITE, so an
#      `rm -rf /root/Projects` inside the container wiped the host. We now mount
#      the workspace READ-ONLY and overlay only the ACTIVE project read-write.
#   2. Lost sessions — the container workdir used to depend on
#      basename(WORKSPACE_DIR), so changing WORKSPACE_DIR (e.g. ~/Projects/ai →
#      ~/Projects) changed every project's path and Claude lost its history. We
#      now key the container path on a STABLE project token (git remote, else
#      folder name) independent of WORKSPACE_DIR.

# _project_root CWD WORKSPACE_DIR — the project root for CWD: the git toplevel
# if there is one, else the immediate child of WORKSPACE_DIR on the way to CWD,
# else CWD itself.
_project_root() {
    local cwd="$1" ws="$2" root
    root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
    if [ -n "$root" ]; then printf '%s' "$root"; return 0; fi
    if [ -n "$ws" ] && [ "$cwd" = "$ws" ]; then printf '%s' "$ws"; return 0; fi
    if [ -n "$ws" ] && [[ "$cwd" == "$ws"/* ]]; then
        local rel="${cwd#$ws/}"
        printf '%s' "$ws/${rel%%/*}"
        return 0
    fi
    printf '%s' "$cwd"
}

# _project_token PROJECT_ROOT — a stable, path-safe identity for a project that
# survives WORKSPACE_DIR changes. Keyed on the FOLDER NAME only: moving or
# renaming WORKSPACE_DIR never changes it. (git-remote keying was tried and
# reverted — it lost memory on folder move/rename and for remote-less repos.)
# Sanitized to [A-Za-z0-9._-].
_project_token() {
    local root="$1" name
    name="$(basename "$root")"
    name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')"
    name="${name#-}"; name="${name%-}"
    [ -z "$name" ] && name="project"
    printf '%s' "$name"
}

# _compute_workspace_mounts CWD WORKSPACE_DIR DOCKER_DIR WS_ACTIVE WS_TARGET
# Sets globals:
#   _LLM_PROJECT_ROOT   host dir mounted read-write (the active project)
#   _LLM_PROJECT_TOKEN  stable identity (used for session/slot keying)
#   _LLM_DOCKER_WORKDIR container working dir (pass to `docker run -w`)
#   _LLM_MOUNT_ARGS     array of `-v` args (workspace ro + project rw)
# Safety model: workspace is read-only; only the active project is writable, at
# a STABLE container path ($DOCKER_DIR/<token>). Launching AT the workspace root
# is the explicit escape hatch that makes the whole workspace writable.
_compute_workspace_mounts() {
    local cwd="$1" ws="$2" dd="$3" ws_active="$4" ws_target="$5"
    _LLM_MOUNT_ARGS=()
    _LLM_PROJECT_ROOT="$(_project_root "$cwd" "$ws")"
    _LLM_PROJECT_TOKEN="$(_project_token "$_LLM_PROJECT_ROOT")"

    local rel="${cwd#$_LLM_PROJECT_ROOT}"; rel="${rel#/}"
    local proj_target="$dd/$_LLM_PROJECT_TOKEN"

    if [ "$ws_active" = true ] && [ "$_LLM_PROJECT_ROOT" = "$ws" ]; then
        # Escape hatch: launched at the workspace root → whole workspace writable.
        _LLM_MOUNT_ARGS+=(-v "$ws:$ws_target")
        local wrel="${cwd#$ws}"; wrel="${wrel#/}"
        _LLM_DOCKER_WORKDIR="$ws_target${wrel:+/$wrel}"
    elif [ "$ws_active" = true ] && [[ "$cwd" == "$ws"/* ]]; then
        # Normal: read-only workspace mirror (browse siblings) + read-write
        # active project overlaid at a stable path. Docker honors the nested
        # rw mount over the ro parent for that subtree.
        _LLM_MOUNT_ARGS+=(-v "$ws:$ws_target:ro")
        _LLM_MOUNT_ARGS+=(-v "$_LLM_PROJECT_ROOT:$proj_target")
        _LLM_DOCKER_WORKDIR="${proj_target}${rel:+/$rel}"
        printf '\033[2m  workspace %s is READ-ONLY — only %s is writable (launch from the workspace root for full write)\033[0m\n' \
            "$ws" "$_LLM_PROJECT_TOKEN" >&2
    else
        # CWD outside the workspace (or workspace disabled): only the project,
        # read-write, at its stable path.
        _LLM_MOUNT_ARGS+=(-v "$_LLM_PROJECT_ROOT:$proj_target")
        _LLM_DOCKER_WORKDIR="${proj_target}${rel:+/$rel}"
    fi
}

# _session_token_dir CLAUDE_HOME TOKEN — Claude stores sessions under a dashed
# version of the container workdir. With the stable token the project dir is
# always $DOCKER_DIR/<token>, so the session dir is stable across WORKSPACE_DIR
# changes. Callers pass the already-computed container workdir.
_dashed_session_dir() {
    local claude_home="$1" docker_wd="$2"
    # Claude normalizes its on-disk project dir by replacing / _ . with - .
    # (e.g. /root/Projects/oc_docker -> -root-Projects-oc-docker). Match that
    # exactly or slot-restore silently misses for names containing _ or . .
    local dpath="${docker_wd#/}"; dpath="$(printf '%s' "$dpath" | tr '/_.' '-')"
    printf '%s/.claude/projects/-%s' "$claude_home" "$dpath"
}

# _project_key HOST_DIR — stable per-project key (token) for terminal-session
# tracking. Uses the global WORKSPACE_DIR. Shared by cld + ocd.
_project_key() {
    _project_token "$(_project_root "$1" "$WORKSPACE_DIR")"
}

# _project_docker_workdir CWD WS DD WS_ACTIVE WS_TARGET — prints ONLY the
# container workdir for CWD (no mounts), using the same stable-token logic as
# _compute_workspace_mounts. Single source of truth for session/sqlite lookups.
_project_docker_workdir() {
    local cwd="$1" ws="$2" dd="$3" ws_active="$4" ws_target="$5" root token rel
    root="$(_project_root "$cwd" "$ws")"
    if [ "$ws_active" = true ] && [ "$root" = "$ws" ]; then
        rel="${cwd#$ws}"; rel="${rel#/}"
        printf '%s' "$ws_target${rel:+/$rel}"
    else
        token="$(_project_token "$root")"
        rel="${cwd#$root}"; rel="${rel#/}"
        printf '%s' "$dd/$token${rel:+/$rel}"
    fi
}

