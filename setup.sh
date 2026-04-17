#!/bin/bash
# First-time setup for llm_docker
# Called automatically by cld/ocd when needed

SCRIPT_DIR="$( cd "$( dirname "$( realpath "${BASH_SOURCE[0]}" )" )" && pwd )"

setup_dirs() {
    mkdir -p "$HOME/.llm_docker/claude"
    mkdir -p "$HOME/.llm_docker/opencode"
    echo "Data directories ready"
}

setup_env() {
    if [ -f "$SCRIPT_DIR/.env" ]; then
        return 0
    fi

    echo "Creating .env from template..."
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    echo ""
    echo "  Edit $SCRIPT_DIR/.env to add your API keys"
    echo ""
}

setup_image() {
    if docker image inspect llm-docker:latest >/dev/null 2>&1; then
        return 0
    fi

    echo "Building Docker image (first time, may take a few minutes)..."
    docker build -t llm-docker:latest "$SCRIPT_DIR"
}

# Run all setup steps
run_setup() {
    local NEEDS_SETUP=false

    # Check what's missing
    [ ! -d "$HOME/.llm_docker/claude" ] && NEEDS_SETUP=true
    [ ! -f "$SCRIPT_DIR/.env" ] && NEEDS_SETUP=true
    ! docker image inspect llm-docker:latest >/dev/null 2>&1 && NEEDS_SETUP=true

    if [ "$NEEDS_SETUP" = false ]; then
        return 0
    fi

    echo "=== llm_docker first-time setup ==="
    echo ""
    setup_dirs
    setup_env
    setup_image
    echo ""
    echo "=== Setup complete ==="
    echo ""
}

# Allow running directly: ./setup.sh
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_setup
fi
