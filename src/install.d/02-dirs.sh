# ── 2. Data directories ─────────────────────────────────────────────────────
header_tui "2/11  Creating data directories"
if [ -d "$HOME/.llm-docker" ] && [ -n "$(ls -A "$HOME/.llm-docker" 2>/dev/null)" ]; then
    info "~/.llm-docker already exists (sessions, auth, SSH keys may live there)."
    ask_yes_no_tui "Wipe and recreate? (No = merge — keep existing files)" "n" WIPE_DIRS 1 0
    if [[ "$WIPE_DIRS" =~ ^[Yy] ]]; then
        if command -v trash >/dev/null 2>&1; then
            trash "$HOME/.llm-docker" 2>/dev/null || true
        else
            mv "$HOME/.llm-docker" "$HOME/.llm-docker.bak.$(date +%Y%m%d%H%M%S)"
        fi
        setup_dirs >/dev/null
        success "~/.llm-docker wiped and recreated"
    else
        setup_dirs >/dev/null
        success "~/.llm-docker merged (existing files kept)"
    fi
else
    setup_dirs >/dev/null
    success "~/.llm-docker/  structure ready"
fi

