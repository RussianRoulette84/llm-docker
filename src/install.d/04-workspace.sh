# ── 4. Workspace mount ──────────────────────────────────────────────────────
header_tui "4/11  Workspace mirror (optional)"
info "Per-invocation mounts always work: cd into a folder, run cld/ocd, that folder mounts."
info "Enable the persistent mirror to auto-mount WORKSPACE_DIR on every launch."

CURRENT_WS="$(_read_env_var WORKSPACE_DIR "$SCRIPT_DIR/llm-docker.conf")"
DOCKER_DIR_CONF="$(_read_env_var DOCKER_DIR "$SCRIPT_DIR/llm-docker.conf")"
[ -z "$DOCKER_DIR_CONF" ] && DOCKER_DIR_CONF="/root"
[ -z "$CURRENT_WS" ] && CURRENT_WS_PRESET="n" || CURRENT_WS_PRESET="y"

ask_yes_no_tui "Enable the persistent workspace mirror?" "$CURRENT_WS_PRESET" MOUNT_CHOICE 1 0

if [[ "$MOUNT_CHOICE" =~ ^[Yy] ]]; then
    DEFAULT_WS="${CURRENT_WS:-$HOME/Projects}"
    while true; do
        ask_path_tui "Host folder (WORKSPACE_DIR)" "$DEFAULT_WS" NEW_WS "$TREE_MID" 1 0
        EXPANDED_WS="${NEW_WS/#\~/$HOME}"
        NEW_DD="$DOCKER_DIR_CONF/$(basename "$EXPANDED_WS")"
        if [ -z "$NEW_WS" ]; then
            warn "WORKSPACE_DIR required when enabling mirror."
            continue
        fi
        if _validate_workspace_paths "$EXPANDED_WS" "$NEW_DD"; then
            break
        fi
        warn "Try a different path."
        DEFAULT_WS="$NEW_WS"
    done
    _update_conf_var WORKSPACE_DIR "$NEW_WS"
    success "Persistent mirror: ${C5}${NEW_WS}${RESET} ↔ ${secondary_accent}${NEW_DD}${RESET}"
else
    _update_conf_var WORKSPACE_DIR ""
    NEW_WS=""; NEW_DD=""
    success "Per-invocation mode only"
fi

