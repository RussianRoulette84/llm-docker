# ── 3. .env ─────────────────────────────────────────────────────────────────
header_tui "3/11  Setting up .env (secrets)"

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
    GORILLA_ENABLED=true
    _update_conf_var IS_S3C_GORILLA_ENABLED "true"
    success "Vault mode on — .env kept as a fallback; you'll get a paste-ready block at the end"
else
    GORILLA_ENABLED=false
    _update_conf_var IS_S3C_GORILLA_ENABLED "false"
    success "Plain .env mode"
fi

if [ -f "$SCRIPT_DIR/.env" ]; then
    success ".env already exists"
else
    setup_env >/dev/null
    success "Seeded .env from template"
fi

