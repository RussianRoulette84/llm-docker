# ── 5. API keys & behavior ──────────────────────────────────────────────────
header_tui "5/11  API keys & behavior"
info "Press Enter on any token to keep its current value. Masked preview shown for existing tokens."

# Anthropic
CUR_ANT="$(_read_env_var ANTHROPIC_API_KEY "$SCRIPT_DIR/.env")"
if [ -n "$CUR_ANT" ]; then
    ask_tui "Anthropic API Key - don't set this and use /login if you have subscription" "$CUR_ANT" NEW_ANTHROPIC "$TREE_MID" 1 0 "" 0 "" "$(_mask_secret "$CUR_ANT")"
else
    ask_tui "Anthropic API Key - don't set this and use /login if you have subscription" "" NEW_ANTHROPIC "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
fi
[ -z "$NEW_ANTHROPIC" ] && NEW_ANTHROPIC="$CUR_ANT"

# OpenAI
CUR_OAI="$(_read_env_var OPENAI_API_KEY "$SCRIPT_DIR/.env")"
if [ -n "$CUR_OAI" ]; then
    ask_tui "OpenAI Key" "$CUR_OAI" NEW_OPENAI "$TREE_MID" 1 0 "" 0 "" "$(_mask_secret "$CUR_OAI")"
else
    ask_tui "OpenAI Key" "" NEW_OPENAI "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
fi
[ -z "$NEW_OPENAI" ] && NEW_OPENAI="$CUR_OAI"

# Z.AI
CUR_ZAI="$(_read_env_var ZAI_API_KEY "$SCRIPT_DIR/.env")"
if [ -n "$CUR_ZAI" ]; then
    ask_tui "Z.AI API Key" "$CUR_ZAI" NEW_ZAI "$TREE_MID" 1 0 "" 0 "" "$(_mask_secret "$CUR_ZAI")"
else
    ask_tui "Z.AI API Key" "" NEW_ZAI "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
fi
[ -z "$NEW_ZAI" ] && NEW_ZAI="$CUR_ZAI"

_update_env_var ANTHROPIC_API_KEY "$NEW_ANTHROPIC"
_update_env_var OPENAI_API_KEY    "$NEW_OPENAI"
_update_env_var ZAI_API_KEY       "$NEW_ZAI"

CUR_EXIT="$(_read_env_var EXIT_TO_DOCKER "$SCRIPT_DIR/llm-docker.conf")"
[ -z "$CUR_EXIT" ] && CUR_EXIT="false"
EXIT_PRESET="n"
[ "$CUR_EXIT" = "true" ] && EXIT_PRESET="y"
ask_yes_no_tui "Drop to container shell on Claude/OpenCode exit (EXIT_TO_DOCKER)?" "$EXIT_PRESET" EXIT_CHOICE 1 0
if [[ "$EXIT_CHOICE" =~ ^[Yy] ]]; then NEW_EXIT="true"; else NEW_EXIT="false"; fi
_update_conf_var EXIT_TO_DOCKER "$NEW_EXIT"
success "API keys + behavior saved"

