#!/bin/bash
# First-time setup for llm-docker
# Called automatically by cld/ocd when needed.
# Source of truth for dir/env/image setup — install.sh reuses these functions.

SCRIPT_DIR="$( cd "$( dirname "$( realpath "${BASH_SOURCE[0]}" )" )" && pwd )"

# --- Palette + banner (inlined from former src/ascii.sh). Single source of
# truth for colors lives in lib/ywizz/theme.sh; the legacy RST/GRN/STEP_COLOR
# names are preserved for backward compat with older callers.
_YWIZZ_THEME="$SCRIPT_DIR/lib/ywizz/theme.sh"
if [ -f "$_YWIZZ_THEME" ]; then
    # shellcheck disable=SC1090
    source "$_YWIZZ_THEME"
fi

RST="${RESET:-$'\033[0m'}"
GRN="${GREEN:-$'\033[38;5;82m'}"
STEP_COLOR="${C2:-$'\033[38;5;39m'}"

# ── Module loader ──────────────────────────────────────────────────────────
# setup.sh was split into focused modules under setup/ (≤500 lines each). These
# are all function definitions — order is irrelevant; nothing runs until a
# launcher calls one after sourcing. (setup/preflight.sh is sourced by the
# launchers directly, before this file.)
_SETUP_DIR="$SCRIPT_DIR/setup"
for _m in banner log docker_log config docker identity launcher image; do
    if [ ! -f "$_SETUP_DIR/$_m.sh" ]; then
        printf 'setup.sh: missing module %s/%s.sh — broken install?\n' "$_SETUP_DIR" "$_m" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$_SETUP_DIR/$_m.sh"
done
unset _m _SETUP_DIR

# Allow running directly (./setup.sh) — guard must live HERE in the loader so
# BASH_SOURCE[0] is setup.sh, not a module. When sourced by cld/ocd/install.sh,
# BASH_SOURCE[0] != $0 so this no-ops.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_setup
fi
