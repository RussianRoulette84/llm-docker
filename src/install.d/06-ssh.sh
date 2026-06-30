# ── 6. SSH access ───────────────────────────────────────────────────────────
header_tui "6/11  SSH access (optional)"
info "Public-key auth only. Enabling forces bridge networking (docker -p)."

CUR_SSH_EN="$(_read_env_var LLM_DOCKER_SSH_ENABLED "$SCRIPT_DIR/llm-docker.conf")"
SSH_PRESET="n"
[ "$CUR_SSH_EN" = "true" ] && SSH_PRESET="y"
ask_yes_no_tui "Enable SSH?" "$SSH_PRESET" SSH_CHOICE 1 0

if [[ "$SSH_CHOICE" =~ ^[Yy] ]]; then
    CUR_HOST_PORT="$(_read_env_var LLM_DOCKER_SSH_HOST_PORT "$SCRIPT_DIR/llm-docker.conf")"
    [ -z "$CUR_HOST_PORT" ] && CUR_HOST_PORT="8884"
    ask_tui "Host port (LLM_DOCKER_SSH_HOST_PORT)" "$CUR_HOST_PORT" NEW_HOST_PORT "$TREE_MID" 1 0

    # Discover all ~/.ssh/*.pub files, present as a multi-select checklist.
    PUB_FILES=()
    for f in "$HOME"/.ssh/*.pub; do
        [ -f "$f" ] && PUB_FILES+=("$f")
    done

    NEW_KEY=""
    if [ ${#PUB_FILES[@]} -eq 0 ]; then
        warn "No ~/.ssh/*.pub files found."
        ask_tui "Paste public key" "" PASTE_KEY "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
        NEW_KEY="$PASTE_KEY"
    else
        opts=""
        descs=""
        default_idx=""
        idx=0
        for f in "${PUB_FILES[@]}"; do
            fname="$(basename "$f")"
            key_line="$(cat "$f")"
            key_type="$(printf '%s' "$key_line" | awk '{print $1}')"
            key_cmt="$(printf '%s' "$key_line" | awk '{print $NF}')"
            [ "$key_cmt" = "$key_type" ] && key_cmt="(no comment)"
            [ -n "$opts" ] && opts+=$'\n'
            opts+="$fname"
            [ -n "$descs" ] && descs+=$'\n'
            descs+="${key_type} — ${key_cmt}"
            # Default-check ed25519 first, else first file.
            if [ "$fname" = "id_ed25519.pub" ] && [ -z "$default_idx" ]; then
                default_idx="$idx"
            fi
            idx=$((idx + 1))
        done
        [ -z "$default_idx" ] && default_idx="0"

        checklist_tui "Select public keys to authorize" "$opts" "$descs" "" "$default_idx" SSH_PUBS true 1 0

        # Concatenate selected keys with literal \n (setup-ssh.sh expands via printf %b).
        # checklist_tui writes "true"/"false" into SSH_PUBS_<i>.
        for i in "${!PUB_FILES[@]}"; do
            chosen="$(eval "echo \"\${SSH_PUBS_${i}:-false}\"")"
            if [ "$chosen" = "true" ]; then
                key_content="$(cat "${PUB_FILES[$i]}")"
                [ -n "$NEW_KEY" ] && NEW_KEY="${NEW_KEY}\\n"
                NEW_KEY="${NEW_KEY}${key_content}"
            fi
        done

        ask_tui "Paste an additional public key (optional)" "" PASTE_KEY "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
        if [ -n "$PASTE_KEY" ]; then
            [ -n "$NEW_KEY" ] && NEW_KEY="${NEW_KEY}\\n"
            NEW_KEY="${NEW_KEY}${PASTE_KEY}"
        fi
    fi

    _update_conf_var LLM_DOCKER_SSH_ENABLED      "true"
    _update_conf_var LLM_DOCKER_SSH_HOST_PORT    "$NEW_HOST_PORT"
    _update_conf_var LLM_DOCKER_SSH_PORT         "22"
    _update_env_var  LLM_DOCKER_SSH_AUTHORIZED_KEYS "$NEW_KEY"

    # openssh-server is apt-installed at build time only (install_devpack.sh).
    # Transitioning false→true on an existing image needs a rebuild.
    [ "$CUR_SSH_EN" != "true" ] && _mark_rebuild_needed "SSH enabled (needs openssh-server baked in)"

    if [ -z "$NEW_KEY" ]; then
        warn "No public key saved — SSH will reject every login until you add one."
    fi
    success "SSH enabled — connect with: ${secondary_accent}ssh -p $NEW_HOST_PORT root@localhost${RESET}"

    # Offer the hostname alias so the user can `ssh root@llm-docker` instead.
    if ! grep -qE '^[0-9.]+[[:space:]]+llm-docker(\s|$)' /etc/hosts 2>/dev/null; then
        info "Optional: add ${secondary_accent}llm-docker${RESET} as a hostname alias on your Mac so you can ${secondary_accent}ssh -p $NEW_HOST_PORT root@llm-docker${RESET}"
        info "Run this once (requires sudo):"
        printf "    %becho \"127.0.0.1    llm-docker\" | sudo tee -a /etc/hosts%b\n" "$secondary_accent" "$RESET"
    else
        success "/etc/hosts already has an ${secondary_accent}llm-docker${RESET} entry — you can use ${secondary_accent}ssh root@llm-docker${RESET}"
    fi
else
    _update_conf_var LLM_DOCKER_SSH_ENABLED "false"
    success "SSH disabled"
fi

