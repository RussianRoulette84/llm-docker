#!/bin/bash
# run-local.sh — start the builder-api server in the given project directory.
#
# Usage:
#   run-local.sh [PROJECT_DIR] [HANDOFF_PATH]
#
# Called by:
#   - builder_api.applescript (opens a new macOS Terminal window and invokes this)
#   - cld / ocd when `--api` is passed on non-macOS hosts (backgrounded)
#
# Boot output is ywizz-themed (purple diamond, dim bullets) so the
# builder-api side pane visually matches the cld/ocd launcher banners.

set -e

# Wipe the typed `bash run-local.sh …` line + any preceding zsh prompt so the
# ywizz banner below renders at the top of the pane. The AppleScript used to
# prepend `clear;` to the typed cmd, but some zsh setups glob-mangle the first
# pasted word (`?clear` → NOMATCH). Doing it here, AFTER bash has taken over,
# is unconditional and immune to that bug.
printf '\033[2J\033[H'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="${1:-$(pwd)}"
HANDOFF_PATH="${2:-}"

# ── ywizz palette ─────────────────────────────────────────────────────
PURPLE=$'\033[38;5;141m'
PINK=$'\033[38;5;213m'
DIM=$'\033[2m'
NC=$'\033[0m'

_head() { printf "${PURPLE}  ◆ %s${NC}  ${DIM}·${NC}  ${PINK}%s${NC}\n" "$1" "$2"; }
_row()  { printf "${DIM}  ·${NC} %-9s %s\n" "$1" "$2"; }

# --- secret handoff from cld/ocd (silent) ---
if [ -n "$HANDOFF_PATH" ] && [ -f "$HANDOFF_PATH" ]; then
    # shellcheck disable=SC1090
    . "$HANDOFF_PATH"
    rm -f "$HANDOFF_PATH"
fi

# --- env-gorilla integration ---
# Goal: ZERO extra fingerprints when launched from an already-env-gorilla'd
# shell. Otherwise: one chained env-gorilla call merges llm-docker + project
# profiles into a single keychain unlock.
PROJECT_DIR_RAW="${1:-$(pwd)}"
PROJECT_NAME="$(basename "$(cd "$PROJECT_DIR_RAW" 2>/dev/null && pwd)" 2>/dev/null || basename "$PROJECT_DIR_RAW")"

if [ -n "${BUILDER_API_PASSWORD:-}" ]; then
    export LLM_DOCKER_ENV_GORILLA=1
    ENV_SRC="parent"
elif [ -z "${LLM_DOCKER_ENV_GORILLA:-}" ] \
     && command -v env-gorilla >/dev/null 2>&1 \
     && { [ "${USER:-}" = "yaro" ] || [ ! -f "$SCRIPT_DIR/../.env" ]; }; then
    export LLM_DOCKER_ENV_GORILLA=1
    if [ -n "$PROJECT_NAME" ] && [ "$PROJECT_NAME" != "llm-docker" ]; then
        _profiles="llm-docker,$PROJECT_NAME"
    else
        _profiles="llm-docker"
    fi
    _head "env-gorilla" "$_profiles"
    exec env-gorilla "$_profiles" -- bash "$0" "$@"
else
    ENV_SRC=".env"
fi

if [ ! -d "$PROJECT_DIR" ]; then
    printf "${PURPLE}  ✗${NC} project not found: %s\n" "$PROJECT_DIR" >&2
    exit 1
fi
cd "$PROJECT_DIR"

# Plain-file fallbacks. Order: llm-docker.conf → llm-docker/.env → ./.env.
# Per-line read (not `source`) tolerates multi-line values like SSH keys.
LOADED=()
for CONF_FILE in "$SCRIPT_DIR/../llm-docker.conf" "$SCRIPT_DIR/../.env" "./.env"; do
    [ -f "$CONF_FILE" ] || continue
    LOADED+=("$(basename "$CONF_FILE")")
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
        export "$line"
    done < "$CONF_FILE"
done

CFG="${BUILDER_API_CONFIG:-$HOME/.llm-docker/builder-api.toml}"
CFG_SHORT="${CFG/#$HOME/~}"

_head "builder-api" "$PROJECT_NAME"
_row  "env"     "$ENV_SRC"
if [ ${#LOADED[@]} -gt 0 ]; then
    _row  "loaded"  "${LOADED[*]}"
fi
_row  "config"  "$CFG_SHORT"
_row  "starting" "server.py…"

exec python3 "$SCRIPT_DIR/server.py" --project "$PROJECT_NAME"
