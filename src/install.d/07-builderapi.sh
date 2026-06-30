# ── 7. Builder API (optional) ───────────────────────────────────────────────
header_tui "7/11  Builder API (optional)"
info "Host-side daemon the container calls for build / run / logs / live streaming."
info "Features: ${secondary_accent}[jobs.*]${RESET} templates with regex-validated placeholders + sha256"
info "command pinning, queued builds with dedupe window, hot-reload of the toml,"
info "${secondary_accent}POST /job/<name>${RESET} + ${secondary_accent}GET /jobs${RESET} for MCP introspection, long-poll status,"
info "log tail by alias, runtime control, /ws live event stream, and a browser"
info "console tunnel. Per-stack examples in ${secondary_accent}src/builder-api/examples/${RESET} (quake,"
info "node, php-docker-compose). Full docs in ${secondary_accent}src/builder-api/README.md${RESET}."
info "Security: password-guarded, rate-limited, execvp-only (no shell), paths scoped to project root."

CUR_API_PW="$(_read_env_var BUILDER_API_PASSWORD "$SCRIPT_DIR/.env")"
API_PRESET="n"
[ -n "$CUR_API_PW" ] && API_PRESET="y"
ask_yes_no_tui "Enable Builder API?" "$API_PRESET" API_CHOICE 1 0

if [[ "$API_CHOICE" =~ ^[Yy] ]]; then
    if [ -n "$CUR_API_PW" ]; then
        ask_tui "BUILDER_API_PASSWORD" "$CUR_API_PW" NEW_API_PW "$TREE_MID" 1 0 "" 0 "" "$(_mask_secret "$CUR_API_PW")"
    else
        ask_tui "BUILDER_API_PASSWORD" "" NEW_API_PW "$TREE_MID" 1 0 "" 0 "(pick a strong shared password)"
    fi
    [ -z "$NEW_API_PW" ] && NEW_API_PW="$CUR_API_PW"
    if [ -z "$NEW_API_PW" ]; then
        warn "No password saved — Builder API clients will be rejected until you add one to .env."
    else
        _update_env_var BUILDER_API_PASSWORD "$NEW_API_PW"
        success "Builder API password saved to .env"
    fi

    CUR_API_AUTO="$(_read_env_var BUILDER_API_AUTOSTART "$SCRIPT_DIR/llm-docker.conf")"
    AUTO_PRESET="n"
    [[ "$(printf '%s' "$CUR_API_AUTO" | tr '[:upper:]' '[:lower:]')" =~ ^(true|yes|on|1)$ ]] && AUTO_PRESET="y"
    ask_yes_no_tui "Auto-start Builder API on every cld/ocd launch?" "$AUTO_PRESET" API_AUTO_CHOICE 1 0
    if [[ "$API_AUTO_CHOICE" =~ ^[Yy] ]]; then
        _update_conf_var BUILDER_API_AUTOSTART "true"
        success "Builder API will auto-start on each launch"
    else
        _update_conf_var BUILDER_API_AUTOSTART "false"
        success "Builder API auto-start disabled (pass -a to spawn manually)"
    fi
else
    _update_conf_var BUILDER_API_AUTOSTART "false"
    success "Builder API skipped"
fi

