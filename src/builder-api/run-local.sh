#!/bin/bash
# run-local.sh — start the builder-api server in the given project directory.
#
# Usage:
#   run-local.sh [PROJECT_DIR]
#
# Called by:
#   - builder_api.applescript (opens a new macOS Terminal window and invokes this)
#   - cld / ocd when `--api` is passed on non-macOS hosts (backgrounded)
#
# What it does:
#   1. cd into PROJECT_DIR (default: current dir)
#   2. source the repo's llm-docker.conf (non-secret) then .env (secrets) so
#      BUILDER_API_PASSWORD etc. land in the environment the server reads
#   3. exec python3 server.py

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="${1:-$(pwd)}"
HANDOFF_PATH="${2:-}"

# --- secret handoff from cld/ocd ---
# If a handoff file was written by the parent (cld/ocd's _write_secret_handoff)
# and passed as $2, source it now so BUILDER_API_PASSWORD and project secrets
# land in env BEFORE the env-gorilla sentinel check below. AppleScript can't
# pass env into a freshly spawned iTerm shell directly, so this CLI-arg shape
# replaces the older `source ... ; rm -f ... ; bash ...` chain that some zsh
# setups mangle with a leading `?`.
if [ -n "$HANDOFF_PATH" ] && [ -f "$HANDOFF_PATH" ]; then
    # shellcheck disable=SC1090
    . "$HANDOFF_PATH"
    rm -f "$HANDOFF_PATH"
fi

# --- env-gorilla integration ---
# Goal: ZERO extra fingerprints when this script is launched from an already-
# env-gorilla'd shell (e.g. `cld -c -a` already loaded both llm-docker and
# project secrets and propagated them to the Terminal we're running in).
# Otherwise: chain two env-gorilla calls so llm-docker + project secrets both
# land in this process. Keychain TouchID caches across back-to-back invocations,
# so the chain typically fingerprints exactly once.
PROJECT_DIR_RAW="${1:-$(pwd)}"
PROJECT_NAME="$(basename "$(cd "$PROJECT_DIR_RAW" 2>/dev/null && pwd)" 2>/dev/null || basename "$PROJECT_DIR_RAW")"

# Skip the whole env-gorilla dance if the parent already loaded our secrets
# (e.g. `cld -c -a` env-gorilla'd the shell + Terminal). BUILDER_API_PASSWORD
# is the telltale — it only ends up in env via env-gorilla pulling
# ENV/llm-docker/.env. Project-specific secrets get inherited automatically.
if [ -n "${BUILDER_API_PASSWORD:-}" ]; then
    export LLM_DOCKER_ENV_GORILLA=1
    echo "[run-local] env already loaded by parent — skipping env-gorilla (no fingerprint)"
elif [ -z "${LLM_DOCKER_ENV_GORILLA:-}" ] \
     && command -v env-gorilla >/dev/null 2>&1 \
     && { [ "${USER:-}" = "yaro" ] || [ ! -f "$SCRIPT_DIR/../.env" ]; }; then
    export LLM_DOCKER_ENV_GORILLA=1

    # Single env-gorilla call with the comma syntax (v0.12+) — merges both
    # profiles into one chip-blob so exactly one fingerprint covers everything.
    if [ -n "$PROJECT_NAME" ] && [ "$PROJECT_NAME" != "llm-docker" ]; then
        _profiles="llm-docker,$PROJECT_NAME"
    else
        _profiles="llm-docker"
    fi
    echo "[run-local] env-gorilla: $_profiles"
    exec env-gorilla "$_profiles" -- bash "$0" "$@"
fi

if [ ! -d "$PROJECT_DIR" ]; then
    echo "run-local.sh: project directory not found: $PROJECT_DIR" >&2
    exit 1
fi
cd "$PROJECT_DIR"

# Plain-file fallbacks — the canonical way to inject secrets when env-gorilla
# isn't available (production server, other developers, CI).
# Order: llm-docker.conf (non-secret defaults) → llm-docker/.env (BUILDER_API_*
# etc.) → <project>/.env (MCP_BEARER_TOKEN_* etc.). Later files win on conflict.
#
# Per-line read instead of `source` because .env may contain multi-line
# values (e.g. an SSH key with literal newlines) — `source` chokes on those.
# Lines that aren't valid `KEY=value` are silently skipped.
for CONF_FILE in "$SCRIPT_DIR/../llm-docker.conf" "$SCRIPT_DIR/../.env" "./.env"; do
    [ -f "$CONF_FILE" ] || continue
    echo "[run-local] loading env: $CONF_FILE"
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
        export "$line"
    done < "$CONF_FILE"
done

echo "[builder-api/run-local] project: $PROJECT_DIR ($PROJECT_NAME)"
echo "[builder-api/run-local] config:  ${BUILDER_API_CONFIG:-~/.llm-docker/builder-api.toml}"
echo "[builder-api/run-local] starting server.py..."
exec python3 "$SCRIPT_DIR/server.py" --project "$PROJECT_NAME"
