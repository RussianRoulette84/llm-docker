#!/bin/bash
# install_cli.sh TOOL — install claude-code and/or opencode-ai.
# TOOL = claude | opencode | both (default: both).
# Reads INSTALL_BROWSING from the env (Dockerfile sources llm-docker.conf
# before calling us) to decide whether to bake the hyperframes Claude skill.
#
# Idempotent: safe to re-run on a container that already has these tools.
# The smart-rebuild path (cld --build → setup_image_incremental) re-execs this
# inside the existing image, so `--build` is what BAKES a new CLI version in.
# That matters: claude's own in-app updater writes to /usr/local/lib, which is
# the container's throwaway layer — its "Restart to apply" never survives.
# Hence @latest rather than skip-if-present; npm is a near no-op when current.
set -e
TOOL="${1:-both}"

_is_true() {
    case "${1,,}" in
        true|yes|on|1) return 0 ;;
        *)             return 1 ;;
    esac
}

case "$TOOL" in
    opencode|both)
        if command -v opencode >/dev/null 2>&1; then
            echo "[CLI] opencode $(opencode --version 2>/dev/null | head -1) present — updating to latest"
        fi
        npm install -g opencode-ai@latest
        ;;
esac

case "$TOOL" in
    claude|both)
        if command -v claude >/dev/null 2>&1; then
            echo "[CLI] claude $(claude --version 2>/dev/null | head -1) present — updating to latest"
        fi
        npm install -g @anthropic-ai/claude-code@latest
        node /usr/local/lib/node_modules/@anthropic-ai/claude-code/install.cjs
        if _is_true "${INSTALL_BROWSING:-false}"; then
            # Marker-based idempotency: `npx skills add` re-downloads on every
            # run. Touch a stamp on first success so smart rebuilds skip it.
            if [ -f /root/.claude/skills/.hyperframes.stamp ]; then
                echo "[CLI] hyperframes skill already added — skipping"
            else
                npx --yes skills add heygen-com/hyperframes -g -y \
                    && mkdir -p /root/.claude/skills \
                    && touch /root/.claude/skills/.hyperframes.stamp
            fi
        fi
        ;;
esac
