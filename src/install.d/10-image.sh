# ── 10. Build image ─────────────────────────────────────────────────────────
header_tui "10/11  Building Docker image"
if docker image inspect llm-docker:latest >/dev/null 2>&1; then
    if [ "$BUILD_CONF_CHANGED" = "1" ]; then
        info "Build-time settings changed ($BUILD_CONF_REASONS) — existing image doesn't reflect them yet."
        ask_yes_no_tui "Rebuild the image now?" "y" REBUILD_CHOICE 1 0
        if [[ "$REBUILD_CHOICE" =~ ^[Yy] ]]; then
            info "Rebuilding — may take a few minutes..."
            setup_image --no-cache
            printf "\033[2J\033[H"
            show_llm-docker_banner
            header_tui "10/11  Building Docker image"
            success "Docker rebuild done"
        else
            warn "Skipped rebuild — image and config are now out of sync. Run ${secondary_accent}docker rmi llm-docker:latest${RESET} and re-run to apply."
        fi
    else
        success "Image already built (delete with 'docker rmi llm-docker:latest' to rebuild)"
    fi
else
    info "First-time build — may take a few minutes..."
    setup_image --no-cache
    printf "\033[2J\033[H"
    show_llm-docker_banner
    header_tui "10/11  Building Docker image"
    success "Docker build done"
fi

