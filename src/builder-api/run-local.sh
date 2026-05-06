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

# --- env-gorilla integration: inject KeePassXC-backed secrets when .env is
# missing. The Terminal/iTerm window osascript spawns this script in does NOT
# inherit cld's env, so we re-check independently here. Same trigger as
# cld/ocd: USER=yaro always, OR .env missing for any user.
#
# We re-exec through `bash "$0"` (not bare "$0") because run-local.sh is
# intentionally non-executable (mode 0644) — the applescript invokes it as
# `bash run-local.sh ...` for the same reason. Handing the path straight to
# env-gorilla makes it `exec()` the file directly, which fails with
# `Permission denied` on a non-executable script.
if [ -z "${LLM_DOCKER_ENV_GORILLA:-}" ] \
   && command -v env-gorilla >/dev/null 2>&1 \
   && { [ "${USER:-}" = "yaro" ] || [ ! -f "$SCRIPT_DIR/../.env" ]; }; then
    export LLM_DOCKER_ENV_GORILLA=1
    exec env-gorilla llm-docker -- bash "$0" "$@"
fi

if [ ! -d "$PROJECT_DIR" ]; then
    echo "run-local.sh: project directory not found: $PROJECT_DIR" >&2
    exit 1
fi
cd "$PROJECT_DIR"

# Config + secrets both live one level up (alongside cld/ocd in src/).
# Order matters: conf first (defaults), .env second (wins on conflicts).
#
# Per-line read instead of `source` because .env may contain multi-line
# values (e.g. an SSH key pasted with literal newlines) — the old
# `source <(... | sed 's/^/export /')` choked on the second line of
# such values with `export: 'AAAAB3...': not a valid identifier`.
# Lines that aren't valid `KEY=value` are silently skipped.
for CONF_FILE in "$SCRIPT_DIR/../llm-docker.conf" "$SCRIPT_DIR/../.env"; do
    [ -f "$CONF_FILE" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
        export "$line"
    done < "$CONF_FILE"
done

echo "[builder-api/run-local] project: $PROJECT_DIR"
echo "[builder-api/run-local] starting server.py..."
exec python3 "$SCRIPT_DIR/server.py"
