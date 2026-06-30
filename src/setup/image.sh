# setup/image.sh — module of the split setup.sh (sourced by the setup.sh loader).

_llm-docker_image_for_tool() {
    local tool="${1:-both}"
    if [ "$tool" = "both" ]; then
        printf '%s' "llm-docker:latest"
        return 0
    fi
    if docker image inspect "llm-docker-${tool}:latest" >/dev/null 2>&1; then
        printf '%s' "llm-docker-${tool}:latest"
    elif docker image inspect "llm-docker:latest" >/dev/null 2>&1; then
        printf '%s' "llm-docker:latest"
    else
        printf '%s' "llm-docker-${tool}:latest"
    fi
}

setup_image() {
    # setup_image [TOOL] [--no-cache]
    #   TOOL = claude | opencode | both (default: both)
    # Tool-specific builds tag llm-docker-$TOOL:latest and only install that
    # CLI (see ARG TOOL in Dockerfile). "both" builds the combined image
    # (llm-docker:latest) — this is what install.sh uses.
    # After flipping INSTALL_* flags in llm-docker.conf, `docker rmi` the
    # relevant tag to force a rebuild.
    local tool="both"
    local build_args=()
    local force_rebuild=false

    while [ $# -gt 0 ]; do
        case "$1" in
            claude|opencode|both) tool="$1"; shift ;;
            --no-cache) force_rebuild=true; build_args+=(--no-cache); shift ;;
            *) shift ;;
        esac
    done

    local tag
    tag="$(_llm-docker_image_for_tool "$tool")"

    if [ "$force_rebuild" = false ] && docker image inspect "$tag" >/dev/null 2>&1; then
        _log_silent SETUP "Docker image $tag already built — skipping build"
        return 0
    fi

    # Build target tag = tool-specific for claude/opencode, llm-docker:latest for both.
    local build_tag="llm-docker:latest"
    [ "$tool" != "both" ] && build_tag="llm-docker-${tool}:latest"

    _log SETUP "Building Docker image $build_tag. For details run: tail logs/llm-docker.log"
    # --provenance/--sbom=false: stop buildx emitting a manifest-list image the
    # classic Docker store can't expose as a plain tag — otherwise the post-build
    # `docker image inspect "$build_tag"` check always misses and we rebuild every launch.
    _log_docker_exec docker build --provenance=false --sbom=false "${build_args[@]}" \
        --build-arg "TOOL=${tool}" \
        -t "$build_tag" "$SCRIPT_DIR"
}

# setup_image_incremental [TOOL] — smart rebuild that re-runs install_cli.sh
# and install_devpack.sh INSIDE an existing image, then `docker commit`s the
# result. Skips the heavy stuff that's already installed (Go binaries, cargo
# crates, ferox/nikto/codeman, npm globals) thanks to the idempotency guards
# in those scripts. Falls back to a full `setup_image` if the image is missing
# or the in-place run fails.
#
# Trade-off vs `setup_image`: layered commits accumulate cruft over many smart
# rebuilds (removed packages don't free disk). Periodically run --rebuild-force
# (cld/ocd) to start fresh.
setup_image_incremental() {
    local tool="${1:-both}"
    local build_tag="llm-docker:latest"
    [ "$tool" != "both" ] && build_tag="llm-docker-${tool}:latest"

    if ! docker image inspect "$build_tag" >/dev/null 2>&1; then
        _log SETUP "No existing $build_tag — falling back to full build."
        setup_image "$tool"
        return $?
    fi

    _log SETUP "Smart rebuild: updating $build_tag in place (skip-if-installed)."
    _log SETUP "For details run: tail logs/llm-docker.log"

    local container="llm-docker-update-$$"
    _log_ensure_dir
    # Best-effort cleanup if anything left behind.
    docker rm -f "$container" >/dev/null 2>&1 || true

    if ! docker run -d --name "$container" \
            --entrypoint sleep \
            -v "$SCRIPT_DIR:/build:ro" \
            "$build_tag" 1800 >/dev/null 2>&1; then
        _log SETUP ERROR "Failed to start update container — falling back to full build."
        setup_image "$tool"
        return $?
    fi

    # Run the install scripts inside the container, sourcing the latest
    # llm-docker.conf so updated INSTALL_* flags take effect. tee the live
    # output through _log_docker_exec's spinner just like a real build.
    if ! _log_docker_exec docker exec "$container" bash -c "
        set -e
        cp /build/llm-docker.conf /tmp/llm-docker.conf
        cp /build/docker/install_cli.sh /tmp/install_cli.sh
        cp /build/docker/install_devpack.sh /tmp/install_devpack.sh
        chmod +x /tmp/install_cli.sh /tmp/install_devpack.sh
        set -a; . /tmp/llm-docker.conf; set +a
        /tmp/install_cli.sh '$tool'
        /tmp/install_devpack.sh
        /bin/rm -f /tmp/llm-docker.conf /tmp/install_cli.sh /tmp/install_devpack.sh
    "; then
        _log SETUP ERROR "Smart rebuild failed; image left as-is."
        docker rm -f "$container" >/dev/null 2>&1 || true
        return 1
    fi

    # Commit in place. The container was started with `--entrypoint sleep`,
    # and docker commit inherits that override into the new image — so we
    # MUST restore the original ENTRYPOINT (and clear the stray `1800` CMD)
    # via --change, otherwise the next `cld`/`ocd` launch runs `sleep <args>`
    # and dies with `sleep: invalid time interval '<INIT_PROMPT>'`.
    if ! docker commit \
            --change 'ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]' \
            --change 'CMD []' \
            "$container" "$build_tag" >/dev/null; then
        _log SETUP ERROR "docker commit failed; image left as-is."
        docker rm -f "$container" >/dev/null 2>&1 || true
        return 1
    fi

    docker rm -f "$container" >/dev/null 2>&1 || true
    _log SETUP "Smart rebuild complete: $build_tag updated."
    return 0
}

# Run all setup steps. Called from cld/ocd at launch for first-time-ish
# bootstrap (missing dirs, missing image). `.env` is intentionally NOT checked
# here — it's user-managed and may legitimately be absent (e.g. when secrets
# come from env-gorilla / KeePassXC). install.sh handles initial .env seeding
# as its own explicit wizard step; cld/ocd never regenerate .env on launch.
run_setup() {
    # run_setup [TOOL] — TOOL = claude | opencode | both (default: both).
    # Tool-specific invocations only build llm-docker-<tool>:latest if
    # neither that nor the combined llm-docker:latest image exists.
    local tool="${1:-both}"
    local NEEDS_SETUP=false

    # Seed .env from template even when the rest of setup is satisfied —
    # users who skipped install.sh (fresh clone → cld directly) still need
    # a .env for `--env-file` to load. Idempotent.
    setup_env

    # Check what's missing — list each narrow-mount target so an upgrade from
    # an older (broad-mount) install triggers setup_dirs to create them.
    [ ! -d "$HOME/.llm-docker/claude/.claude" ] && NEEDS_SETUP=true
    [ ! -d "$HOME/.llm-docker/claude/.config" ] && NEEDS_SETUP=true
    [ ! -e "$HOME/.llm-docker/claude/.claude.json" ] && NEEDS_SETUP=true
    [ ! -d "$HOME/.llm-docker/opencode/.config/opencode" ] && NEEDS_SETUP=true
    [ ! -d "$HOME/.llm-docker/opencode/.local/share/opencode" ] && NEEDS_SETUP=true
    [ ! -d "$HOME/.llm-docker/opencode/.cache/opencode" ] && NEEDS_SETUP=true
    [ ! -f "$SCRIPT_DIR/llm-docker.conf" ] && NEEDS_SETUP=true

    # Image check: either the tool-specific image OR the combined one is fine.
    if [ "$tool" = "both" ]; then
        docker image inspect llm-docker:latest >/dev/null 2>&1 || NEEDS_SETUP=true
    else
        if ! docker image inspect "llm-docker-${tool}:latest" >/dev/null 2>&1 \
           && ! docker image inspect llm-docker:latest >/dev/null 2>&1; then
            NEEDS_SETUP=true
        fi
    fi

    if [ "$NEEDS_SETUP" = false ]; then
        return 0
    fi

    # If persistent dirs already exist, the user has run llm-docker before —
    # we're rebuilding a missing image, not setting up from scratch.
    local _subtitle="first-time setup"
    if [ -d "$HOME/.llm-docker/claude/.claude" ] \
    || [ -d "$HOME/.llm-docker/opencode/.local/share/opencode" ]; then
        _subtitle="re-building"
    fi

    print_banner "$_subtitle"
    setup_dirs
    setup_image "$tool"
    echo ""
    echo "Setup complete."
    echo ""
}
# (The `./setup.sh` run-directly guard lives in the setup.sh loader, not here —
# moving it into a module broke it, since BASH_SOURCE[0] would be this module.)
