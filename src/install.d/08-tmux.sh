# ── 8. Tmux helpers (optional) ──────────────────────────────────────────────
header_tui "8/11  Tmux helpers (optional)"
info "Pick which tmux modes you want for ${secondary_accent}cld${RESET} / ${secondary_accent}ocd${RESET}."
info "Each ticked box bakes its bits into the image. Unticked = not installed."

ask_yes_no_tui "Enable tmux integrations?" "y" TMUX_ENABLE 1 0

# Vanilla tmux is implicit — enabling integrations always bakes `apt tmux` into
# the image. The checklist only surfaces the additive layers on top.
TMUX_CHOICE_FLAGS=(INSTALL_TMUX_TEAM INSTALL_TMUX_RECON INSTALL_TMUX_CODEMAN INSTALL_TMUX_CLAUDE)
TMUX_ALL_FLAGS=(INSTALL_TMUX_VANILLA "${TMUX_CHOICE_FLAGS[@]}")

if [[ "$TMUX_ENABLE" =~ ^[Yy] ]]; then
    TMUX_OPT_LABELS=(
      "tmux team (-tt)       multi-pane team layout (our custom)"
      "recon (-tr)           gavraz/recon dashboard"
      "codeman (-tc)         Ark0N/Codeman web UI on :3000"
      "claude-tmux (-tcl)    nielsgroen/claude-tmux popup (cld only)"
    )
    TMUX_OPT_DESCS=(
      "apt tmux + helper scripts; lead + peers + haiku runner pane"
      "Rust binary — cargo build during image rebuild"
      "Node helper + container auto-publishes :3000"
      "Rust binary + popup bound to Ctrl+b Ctrl+c"
    )

    cur_vanilla="$(_read_env_var INSTALL_TMUX_VANILLA "$SCRIPT_DIR/llm-docker.conf")"
    [ "$cur_vanilla" != "true" ] && _mark_rebuild_needed "INSTALL_TMUX_VANILLA=true"
    _update_conf_var INSTALL_TMUX_VANILLA "true"

    # Pre-tick what's already enabled in conf; default-tick team on fresh install.
    TMUX_DEFAULTS=""
    _any_set=false
    for i in "${!TMUX_CHOICE_FLAGS[@]}"; do
        if [ "$(_read_env_var "${TMUX_CHOICE_FLAGS[$i]}" "$SCRIPT_DIR/llm-docker.conf")" = "true" ]; then
            [ -n "$TMUX_DEFAULTS" ] && TMUX_DEFAULTS+=","
            TMUX_DEFAULTS+="$i"
            _any_set=true
        fi
    done
    [ "$_any_set" = false ] && TMUX_DEFAULTS="0"
    unset _any_set

    TMUX_OPTS=""
    TMUX_DESCS=""
    for i in "${!TMUX_OPT_LABELS[@]}"; do
        [ -n "$TMUX_OPTS" ]  && TMUX_OPTS+=$'\n'
        TMUX_OPTS+="${TMUX_OPT_LABELS[$i]}"
        [ -n "$TMUX_DESCS" ] && TMUX_DESCS+=$'\n'
        TMUX_DESCS+="${TMUX_OPT_DESCS[$i]}"
    done

    checklist_tui "Tmux setups (Space toggles, Enter confirms)" "$TMUX_OPTS" "$TMUX_DESCS" "" "$TMUX_DEFAULTS" TMUX_SEL true 1 0

    CODEMAN_SELECTED="false"
    for idx in "${!TMUX_CHOICE_FLAGS[@]}"; do
        flag_name="${TMUX_CHOICE_FLAGS[$idx]}"
        chosen="$(eval "echo \"\${TMUX_SEL_${idx}:-false}\"")"
        new_val="false"
        [ "$chosen" = "true" ] && new_val="true"
        [ "$flag_name" = "INSTALL_TMUX_CODEMAN" ] && CODEMAN_SELECTED="$new_val"
        cur_val="$(_read_env_var "$flag_name" "$SCRIPT_DIR/llm-docker.conf")"
        if [ "$cur_val" != "$new_val" ]; then
            _mark_rebuild_needed "$flag_name=$new_val"
        fi
        _update_conf_var "$flag_name" "$new_val"
    done
    success "Tmux helpers saved (vanilla tmux included by default)"

    # Codeman web UI is password-guarded — prompt only when it's actually selected.
    if [ "$CODEMAN_SELECTED" = "true" ]; then
        CUR_CODEMAN_PW="$(_read_env_var CODEMAN_PASSWORD "$SCRIPT_DIR/.env")"
        if [ -n "$CUR_CODEMAN_PW" ]; then
            ask_tui "CODEMAN_PASSWORD" "$CUR_CODEMAN_PW" NEW_CODEMAN_PW "$TREE_MID" 1 0 "" 0 "" "$(_mask_secret "$CUR_CODEMAN_PW")"
        else
            ask_tui "CODEMAN_PASSWORD" "" NEW_CODEMAN_PW "$TREE_MID" 1 0 "" 0 "(login password for the Codeman web UI on :3000)"
        fi
        [ -z "$NEW_CODEMAN_PW" ] && NEW_CODEMAN_PW="$CUR_CODEMAN_PW"
        if [ -z "$NEW_CODEMAN_PW" ]; then
            warn "No password saved — the Codeman web UI will reject logins until you add CODEMAN_PASSWORD to .env."
        else
            _update_env_var CODEMAN_PASSWORD "$NEW_CODEMAN_PW"
            success "Codeman password saved to .env"
        fi
    fi
else
    for flag_name in "${TMUX_ALL_FLAGS[@]}"; do
        cur_val="$(_read_env_var "$flag_name" "$SCRIPT_DIR/llm-docker.conf")"
        if [ "$cur_val" = "true" ]; then
            _mark_rebuild_needed "$flag_name=false"
        fi
        _update_conf_var "$flag_name" "false"
    done
    success "Tmux integrations skipped — image will not include tmux or any helpers"
fi

