#!/bin/bash
# install_cli.sh TOOL — install claude-code and/or opencode-ai.
# TOOL = claude | opencode | both (default: both).
set -e
TOOL="${1:-both}"

case "$TOOL" in
    opencode|both)
        npm install -g opencode-ai
        ;;
esac

case "$TOOL" in
    claude|both)
        npm install -g @anthropic-ai/claude-code
        node /usr/local/lib/node_modules/@anthropic-ai/claude-code/install.cjs
        npx --yes skills add heygen-com/hyperframes
        ;;
esac
