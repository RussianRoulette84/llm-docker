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

if [ ! -d "$PROJECT_DIR" ]; then
    echo "run-local.sh: project directory not found: $PROJECT_DIR" >&2
    exit 1
fi
cd "$PROJECT_DIR"

# Config + secrets both live one level up (alongside cld/ocd in src/).
# Order matters: conf first (defaults), .env second (wins on conflicts).
for CONF_FILE in "$SCRIPT_DIR/../llm-docker.conf" "$SCRIPT_DIR/../.env"; do
    if [ -f "$CONF_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        source <(grep -v '^#' "$CONF_FILE" | grep -v '^$' | sed 's/^/export /')
        set +a
    fi
done

echo "[builder-api/run-local] project: $PROJECT_DIR"
echo "[builder-api/run-local] starting server.py..."
exec python3 "$SCRIPT_DIR/server.py"
