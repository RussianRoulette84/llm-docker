# ── 3. .env ─────────────────────────────────────────────────────────────────
header_tui "3/12  Setting up .env (secrets)"

# TODO(s3c-gorilla-tag): s3c-gorilla has no tags yet (checked 2026-07-20). Pin to a git tag
# (e.g. "v1.0.0") once it does one so a compromised master branch can't inject.
_S3C_GORILLA_REF="master"

# Secrets source: KeePassXC vault (s3c-gorilla) or a plain .env file. With the
# vault on, cld/ocd re-exec through env-gorilla and .env becomes a fallback. We
# still collect the secrets below and, at the end, print a paste-ready block for
# the KeePassXC entry.
CUR_GORILLA="$(_read_env_var IS_S3C_GORILLA_ENABLED "$SCRIPT_DIR/llm-docker.conf")"
GORILLA_PRESET="y"
[ "$CUR_GORILLA" = "false" ] && GORILLA_PRESET="n"
info "s3c-gorilla injects secrets from an encrypted KeePassXC vault at launch —"
info "no plaintext .env on disk. Password-only mode works without Touch ID."
ask_yes_no_tui "Use s3c-gorilla (KeePassXC vault) for secrets instead of a plain .env?" "$GORILLA_PRESET" GORILLA_CHOICE 1 0
if [[ "$GORILLA_CHOICE" =~ ^[Yy] ]]; then
    # Probe: is env-gorilla actually installed? Public users may not have it.
    if ! command -v env-gorilla >/dev/null 2>&1; then
        warn "env-gorilla is not installed on this Mac."
        info "You can install s3c-gorilla now (needs sudo once), or fall back to plain .env."
        ask_yes_no_tui "Install s3c-gorilla now?" "y" INSTALL_GORILLA 1 0
        if [[ "$INSTALL_GORILLA" =~ ^[Yy] ]]; then
            info "Launching the s3c-gorilla installer (its own wizard takes over)…"
            if bash <(curl -fsSL "https://raw.githubusercontent.com/RussianRoulette84/s3c-gorilla/${_S3C_GORILLA_REF}/src/install.sh"); then
                success "s3c-gorilla installed — vault mode on"
                GORILLA_ENABLED=true
                _update_conf_var IS_S3C_GORILLA_ENABLED "true"
            else
                warn "s3c-gorilla install failed — falling back to plain .env"
                GORILLA_ENABLED=false
                _update_conf_var IS_S3C_GORILLA_ENABLED "false"
            fi
        else
            info "Skipped — using plain .env mode instead"
            GORILLA_ENABLED=false
            _update_conf_var IS_S3C_GORILLA_ENABLED "false"
        fi
    else
        GORILLA_ENABLED=true
        _update_conf_var IS_S3C_GORILLA_ENABLED "true"
        success "Vault mode on — .env kept as a fallback; you'll get a paste-ready block at the end"
    fi
else
    GORILLA_ENABLED=false
    _update_conf_var IS_S3C_GORILLA_ENABLED "false"
    success "Plain .env mode"
fi

# With env-gorilla installed, secrets stay off disk entirely — seeding a template
# full of empty keys is how a blank value ended up overriding a real one.
if command -v env-gorilla >/dev/null 2>&1; then
    success "Vault mode — no .env file"
elif [ -f "$SCRIPT_DIR/.env" ]; then
    success ".env already exists"
else
    setup_env >/dev/null
    success "Seeded .env from template"
fi

# Vault re-exec: NOW that the user opted into vault mode AND env-gorilla is
# installed, re-launch the installer WRAPPED through env-gorilla so the
# remaining steps (5 API keys, 6a host keys, 7 builder-api pw, 8 codeman pw)
# can pre-fill from the vault. Sentinel prevents infinite re-exec loops.
if [ "$GORILLA_ENABLED" = "true" ] \
   && [ -z "${LLM_DOCKER_ENV_GORILLA:-}" ] \
   && command -v env-gorilla >/dev/null 2>&1; then
    export LLM_DOCKER_ENV_GORILLA=1
    info "Vault mode is on — re-launching installer through env-gorilla so remaining prompts pre-fill from your vault."
    exec env-gorilla llm-docker -- bash "$SCRIPT_DIR/install.sh" "$@"
fi

