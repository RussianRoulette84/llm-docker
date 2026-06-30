# ── Optional: post-install health check ─────────────────────────────────────
if [ -x "$SCRIPT_DIR/install_test.sh" ]; then
    ask_yes_no_tui "Run post-install health check? (mounts, tools, sandbox, devpacks)" "y" RUN_HEALTH 0 1
    if [[ "$RUN_HEALTH" =~ ^[Yy] ]]; then
        "$SCRIPT_DIR/install_test.sh" || warn "Health check reported issues — review output above."
    fi
fi

# ── Optional: s3c-gorilla onboarding + installer (only if vault mode chosen) ──
if [ "${GORILLA_ENABLED:-false}" = true ]; then
    printf "\n"
    printf "  ${secondary_accent}── s3c-gorilla: load your secrets into the vault ──${RESET}\n\n"
    printf "  ${C2}How it works:${RESET} cld/ocd re-exec through ${secondary_accent}env-gorilla llm-docker -- …${RESET}\n"
    printf "  which unlocks your KeePassXC database (Touch ID, or password on a Hackintosh),\n"
    printf "  reads the ${secondary_accent}.env${RESET} file ${C2}attached${RESET} to the entry named ${C5}llm-docker${RESET}, and injects\n"
    printf "  those vars into memory for the launch. Nothing is written to disk.\n\n"
    printf "  ${C2}Do this once:${RESET}\n"
    printf "    1. Open KeePassXC → create (or open) an entry titled ${C5}llm-docker${RESET}\n"
    printf "    2. Advanced → Attachments → add a file named ${secondary_accent}.env${RESET} with the block below\n"
    printf "    3. Per-project secrets: make another entry titled like the ${DIM}project folder${RESET}\n\n"

    # Paste-ready block, sourced from what we just saved to .env (only non-empty keys).
    printf "  ${DIM}┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ copy into the .env attachment ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄${RESET}\n"
    for _k in ANTHROPIC_API_KEY OPENAI_API_KEY ZAI_API_KEY BUILDER_API_PASSWORD CODEMAN_USERNAME CODEMAN_PASSWORD; do
        _v="$(_read_env_var "$_k" "$SCRIPT_DIR/.env")"
        [ -n "$_v" ] && printf "  ${C2}%s=%s${RESET}\n" "$_k" "$_v"
    done
    unset _k _v
    printf "  ${DIM}┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄${RESET}\n\n"
    warn "Keep this terminal until you've pasted the block — it isn't stored anywhere else."
    printf "\n"

    if ! command -v env-gorilla >/dev/null 2>&1; then
        ask_yes_no_tui "Install s3c-gorilla now? (downloads + runs its installer, needs sudo once)" "y" RUN_GORILLA 0 1
        if [[ "$RUN_GORILLA" =~ ^[Yy] ]]; then
            info "Launching the s3c-gorilla installer (its own wizard takes over)…"
            bash <(curl -fsSL https://raw.githubusercontent.com/RussianRoulette84/s3c-gorilla/master/src/install.sh) \
                || warn "s3c-gorilla installer reported a failure — install it manually, then relaunch cld."
        else
            info "Skipped. Install later: ${secondary_accent}bash <(curl -fsSL https://raw.githubusercontent.com/RussianRoulette84/s3c-gorilla/master/src/install.sh)${RESET}"
        fi
    else
        success "env-gorilla already installed — you're set once the vault entry is populated."
    fi
fi

# ── Completion (printed LAST, after health check + gorilla onboarding) ───────
# %-Ns pads the PLAIN command text to a fixed visible width; color codes sit
# OUTSIDE the %s so they don't throw off the alignment.
_u() { printf "  ${C2}%-21s${RESET}${DIM}%-14s${RESET}${C2}%-21s${RESET}${DIM}%s${RESET}\n" "$1" "$2" "$3" "$4"; }
printf "\n"
center_ascii "${secondary_accent}╔══════════════════════════════════════════╗${RESET}" 46
center_ascii "${secondary_accent}║${RESET}     ${C5}(^_^)/  Installation complete!${RESET}       ${secondary_accent}║${RESET}" 46
center_ascii "${secondary_accent}╚══════════════════════════════════════════╝${RESET}" 46
printf "\n"

printf "  ${C2}Usage:${RESET}\n\n"
printf "  ${C4}%-21s%-14s%-21s%s${RESET}\n" "Claude Code" "" "OpenCode" ""

printf "  ${DIM}Sessions${RESET}\n"
_u "cld"             "new"          "ocd"             "new"
_u "cld -c"          "continue"     "ocd -c"          "continue"
_u "cld -c <uuid>"   "resume"       "ocd -c <uuid>"   "resume"
_u "cld --slot N"    "slot N"       "ocd --slot N"    "slot N"
_u "cld -c --slot N" "restore slot" "ocd -c --slot N" "restore slot"
_u "cld 4"           "4 windows"    "ocd 4"           "4 windows"
_u "cld 4 -c"        "4 + restore"  "ocd 4 -c"        "4 + restore"
_u "cld --delay S"   "window gap"   "ocd --delay S"   "window gap"

printf "  ${DIM}Builder API & vault${RESET}\n"
_u "cld -a"          "builder-api"  "ocd -a"          "builder-api"
_u "cld --refresh-env" "reload vault" "ocd --refresh-env" "reload vault"

printf "  ${DIM}Tmux modes${RESET}\n"
_u "cld -t"          "tmux wrap"    "ocd -t"          "tmux wrap"
_u "cld -tt [N]"     "team panes"   "ocd -tt [N]"     "team panes"
_u "cld -tr"         "recon dash"   "ocd -tr"         "recon dash"
_u "cld -tc"         "codeman web"  "ocd -tc"         "codeman web"
_u "cld -tcl"        "claude-tmux"  ""                "(cld only)"

printf "  ${DIM}Build & maintenance${RESET}\n"
_u "cld --clean"        "clean stale"  "ocd --clean"        "clean stale"
_u "cld --build"        "smart rebuild" "ocd --build"       "smart rebuild"
_u "cld --rebuild-force" "full rebuild" "ocd --rebuild-force" "full rebuild"

printf "  ${DIM}Modes${RESET}\n"
_u "cld --safe"        "perms prompt" "ocd --safe"        "perms prompt"
_u "cld -- <args>"     "passthrough"  "ocd -- <args>"     "passthrough"
_u "cld -h"            "help"         "ocd -h"            "help"
printf "\n"

printf "  ${C2}Where data lives:${RESET}\n"
printf "    ${secondary_accent}~/.llm-docker/claude/.claude${RESET}         Sessions, slots, auth\n"
printf "    ${secondary_accent}~/.llm-docker/claude/.config${RESET}         Secondary Claude config\n"
printf "    ${secondary_accent}~/.llm-docker/claude/.claude.json${RESET}    Top-level user config\n"
printf "    ${secondary_accent}~/.llm-docker/opencode/${RESET}              OpenCode config + sessions + cache\n"
printf "    ${secondary_accent}~/.llm-docker/ssh/${RESET}                   SSH host keys (persist across rebuilds)\n"
printf "\n"

if [ -n "$NEW_WS" ] && [ -n "$NEW_DD" ]; then
    printf "  ${C2}Workspace:${RESET}  persistent mirror ${C5}${NEW_WS}${RESET} ↔ ${secondary_accent}${NEW_DD}${RESET}\n"
else
    printf "  ${C2}Workspace:${RESET}  per-invocation only (${DIM}cd FOO && cld → /root/FOO${RESET})\n"
fi
printf "  ${C2}Security:${RESET}   cap_drop ALL · no-new-privileges · narrow mounts\n"
printf "              toggle via ${secondary_accent}SANDBOX_ENABLED${RESET} / ${secondary_accent}INTERNET_ACCESS${RESET} in llm-docker.conf\n"
printf "\n"

# Clickable guide for wiring a project to the Builder API (+ s3c-gorilla).
# OSC-8 file:// hyperlink with the path as visible text — clickable in iTerm,
# Cmd-clickable in Terminal.app; opens the markdown in the default handler.
_guide="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)/docs/SETUP-PROJECT-API.md"
if [ -f "$_guide" ]; then
    printf "  ${C2}Builder API guide:${RESET}  set up a project (+ s3c-gorilla) →\n"
    printf '    \033]8;;file://%s\033\\%s\033]8;;\033\\\n' "$_guide" "$_guide"
    printf "\n"
fi
unset _guide

if [ ! -f "$SCRIPT_DIR/.env" ] || ! grep -q "^ANTHROPIC_API_KEY=" "$SCRIPT_DIR/.env" 2>/dev/null; then
    warn "Don't forget to add your API keys to .env (or use 'cld' then '/login')"
    printf "\n"
fi
