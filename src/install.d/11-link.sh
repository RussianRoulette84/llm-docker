# ── 11. Link cld / ocd ──────────────────────────────────────────────────────
header_tui "11/11  Linking cld + ocd to /usr/local/bin"
NEED_SUDO=false
[ ! -w /usr/local/bin ] && NEED_SUDO=true

# If sudo is needed, draw the head-ascii accompaniment + friendly heads-up
# so the user knows WHY macOS is about to ask for their password.
if [ "$NEED_SUDO" = true ] && command -v ywizz_ascii_secondary >/dev/null 2>&1; then
    printf "\n"
    ywizz_ascii_secondary
    printf "\n  ${secondary_accent}🔒 sudo needed${RESET} ${DIM}to symlink ${secondary_accent}cld${RESET}${DIM} and ${secondary_accent}ocd${RESET}${DIM} into /usr/local/bin${RESET}\n"
    # Prime sudo once — subsequent link_cmd calls inherit the timestamp cache.
    sudo -v || { error "sudo required — aborting"; exit 1; }
fi

link_cmd() {
    local CMD="$1"
    local SRC="$SCRIPT_DIR/$CMD"
    local DST="/usr/local/bin/$CMD"
    chmod +x "$SRC"
    if [ "$NEED_SUDO" = true ]; then
        sudo ln -sf "$SRC" "$DST"
    else
        ln -sf "$SRC" "$DST"
    fi
    success "$CMD → $DST"
}
link_cmd cld
link_cmd ocd

# The SSH smoke test is no longer a separate prompt — it runs inside the
# post-install health check below (install_test.sh) when SSH is enabled.

