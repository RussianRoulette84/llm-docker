#!/bin/bash
# ocd.run.sh — run_opencode_container, sourced by ocd. Tool-specific (sqlite
# session tracking); uses globals the launcher sets before the call.

run_opencode_container() {
    local WORKDIR="$1"
    shift
    cd "$SCRIPT_DIR"

    _tmux_nested_prompt

    # Deletion-safe mounts + stable identity (see setup.sh): workspace :ro, only
    # the active project :rw at a stable container path keyed on git remote /
    # folder name. Sets _LLM_DOCKER_WORKDIR + the _LLM_MOUNT_ARGS array.
    _compute_workspace_mounts "$WORKDIR" "$WORKSPACE_DIR" "$DOCKER_DIR" \
        "$WORKSPACE_MOUNT_ACTIVE" "$DOCKER_WORKSPACE_TARGET"
    if ! _validate_workspace_paths "$_LLM_PROJECT_ROOT" "$DOCKER_DIR/$_LLM_PROJECT_TOKEN"; then
        _log OCD ERROR "Launch ocd from inside a specific project folder and try again."
        exit 1
    fi
    DOCKER_WORKDIR="$_LLM_DOCKER_WORKDIR"

    _log OCD "Starting OpenCode sandbox in $DOCKER_WORKDIR..."

    # Forward terminal environment variables for proper mouse reporting and scrolling
    if command -v stty > /dev/null 2>&1; then
        TERM_SIZE=$(stty size 2>/dev/null || echo "24 80")
        export LINES=$(echo $TERM_SIZE | cut -d' ' -f1)
        export COLUMNS=$(echo $TERM_SIZE | cut -d' ' -f2)
    fi

    export TERM=${TERM:-xterm-256color}

    # Load llm-docker.conf (config) + .env (secrets) into shell env.
    # Order: conf first, .env second — .env wins on conflicts.
    _source_all_config

    # SSH port publish requires bridge networking.
    # Slot N → 8884 + (N - 1). No slot → base port with auto-bump when taken.
    # See cld for the same logic.
    SSH_PORT_MAPPING=""
    SSH_HOST_KEY_MOUNT=""
    if [ "${LLM_DOCKER_SSH_ENABLED:-false}" = "true" ]; then
        _SSH_BASE="${LLM_DOCKER_SSH_HOST_PORT:-8884}"
        _SSH_CONTAINER="${LLM_DOCKER_SSH_PORT:-22}"
        if [ -n "$SLOT" ]; then
            _SSH_HOST_PORT=$(( _SSH_BASE + SLOT - 1 ))
        else
            _SSH_HOST_PORT="$_SSH_BASE"
            _SSH_MAX=$(( _SSH_BASE + 50 ))
            while (timeout 1 bash -c "</dev/tcp/127.0.0.1/$_SSH_HOST_PORT") 2>/dev/null; do
                _SSH_HOST_PORT=$(( _SSH_HOST_PORT + 1 ))
                if [ "$_SSH_HOST_PORT" -gt "$_SSH_MAX" ]; then
                    _log OCD ERROR "No free SSH port in $_SSH_BASE-$_SSH_MAX. Stop some containers or pass --slot N."
                    exit 1
                fi
            done
            if [ "$_SSH_HOST_PORT" != "$_SSH_BASE" ]; then
                _log OCD "SSH port $_SSH_BASE busy — using $_SSH_HOST_PORT (ssh -p $_SSH_HOST_PORT root@localhost)"
            fi
        fi
        SSH_PORT_MAPPING="-p ${_SSH_HOST_PORT}:${_SSH_CONTAINER}"
        SSH_HOST_KEY_MOUNT="-v $HOME/.llm-docker/ssh:/etc/ssh/keys"
    fi

    # Session restore resolution:
    #   -c <UUID>     → RESUME_SESSION (direct)
    #   -c -s N       → read slot file, fall into RESUME_SESSION
    # Whatever ends up in RESUME_SESSION is forwarded as SLOT_RESUME_ID.
    if [ -z "$RESUME_SESSION" ] && [ -n "$SLOT" ] && [ "$CONTINUE_SESSION" = true ]; then
        local SLOT_FILE="$HOME/.llm-docker/opencode/.local/share/opencode/slot_${SLOT}.id"
        [ -f "$SLOT_FILE" ] && RESUME_SESSION="$(cat "$SLOT_FILE")"
    fi

    # Per-terminal continue: if `-c` was used without --slot and without
    # an explicit UUID, and we've saved a session for THIS iTerm pane in
    # this project, resume that specific session.
    if [ "$CONTINUE_SESSION" = true ] && [ -z "$RESUME_SESSION" ] && [ -z "$SLOT" ]; then
        local _TS_TID _TS_SAVED
        _TS_TID=$(_terminal_id)
        _TS_SAVED=$(_lookup_terminal_session "$_TS_TID" "$_LLM_PROJECT_TOKEN")
        [ -n "$_TS_SAVED" ] && RESUME_SESSION="$_TS_SAVED"
    fi

    SLOT_ENV=""
    [ -n "$SLOT" ]           && SLOT_ENV="$SLOT_ENV -e SLOT=$SLOT"
    [ -n "$RESUME_SESSION" ] && SLOT_ENV="$SLOT_ENV -e SLOT_RESUME_ID=$RESUME_SESSION"

    # Fresh session only → entrypoint injects --prompt. Prefer BOOT.md contents, fall back to CLAUDE.md default.
    export OPENCODE_INIT_PROMPT=""
    if [ -z "$RESUME_SESSION" ] && [ "$CONTINUE_SESSION" != true ]; then
        if [ -f "$WORKDIR/BOOT.md" ]; then
            export OPENCODE_INIT_PROMPT="$(cat "$WORKDIR/BOOT.md")"
        elif [ -f "$WORKDIR/CLAUDE.md" ]; then
            export OPENCODE_INIT_PROMPT="Read ./CLAUDE.md in full and follow its BOOT steps before anything else."
        fi
    fi

    # Codeman web UI on port 3000 needs bridge networking to publish with `-p`.
    CODEMAN_PORT_MAPPING=""
    [ "$TMUX_CODEMAN" = true ] && CODEMAN_PORT_MAPPING="-p 3000:3000"

    if [ "${INTERNET_ACCESS:-true}" = "false" ] || [ -n "$SSH_PORT_MAPPING" ] || [ -n "$CODEMAN_PORT_MAPPING" ]; then
        export NETWORK_MODE=bridge
    else
        export NETWORK_MODE=host
    fi

    # Cap/security flags from the same source-of-truth cld uses.
    _compute_cap_flags "${SANDBOX_ENABLED:-true}" "${INTERNET_ACCESS:-true}" "${LLM_DOCKER_SSH_ENABLED:-false}" CAP_DROP CAP_ADD SECURITY_OPT

    # Forward both config files into the container as env. Docker accepts
    # multiple --env-file flags; conf first so .env can still override.
    ENV_FILES=""
    [ -f "$SCRIPT_DIR/llm-docker.conf" ] && ENV_FILES="$ENV_FILES --env-file $SCRIPT_DIR/llm-docker.conf"
    [ -f "$SCRIPT_DIR/.env" ]            && ENV_FILES="$ENV_FILES --env-file $SCRIPT_DIR/.env"

    # Workspace + project mounts were built into _LLM_MOUNT_ARGS by
    # _compute_workspace_mounts above (workspace :ro, active project :rw).

    TMUX_CONF_MOUNT_ARG=()
    [ -f "$HOME/.tmux.conf" ] && TMUX_CONF_MOUNT_ARG=(-v "$HOME/.tmux.conf:/root/.tmux.conf:ro")

    P10K_MOUNT_ARG=()
    [ -f "$HOME/.p10k.zsh" ] && P10K_MOUNT_ARG=(-v "$HOME/.p10k.zsh:/root/.p10k.zsh:ro")

    # CAP_* / SECURITY_OPT are unquoted on purpose — they word-split into
    # multiple --cap-add / --cap-drop / --security-opt args.
    local CONTAINER_NAME="llm-docker-opencode-$$"

    _iterm_tag "OpenCode" "$WORKDIR"
    trap '_teardown_builder_api; _iterm_untag' EXIT INT TERM HUP

    # Resolve image tag: prefer the opencode-only image, fall back to the
    # combined llm-docker:latest if that's what install.sh produced.
    local IMAGE_TAG
    IMAGE_TAG="$(_llm-docker_image_for_tool opencode)"

    # Forward every env var into the container. Tiny blocklist: only vars
    # that would BREAK the container if a Mac value leaked in (PATH points
    # at /Users/yaro/..., HOME points at a path that doesn't exist, loader
    # hijack via LD_/DYLD_, etc.) plus the env-gorilla re-exec guard.
    local EXTRA_ENV=""
    local _ENV_BLOCK _ename
    _ENV_BLOCK='^(PATH|HOME|TMPDIR|PWD|OLDPWD|SHELL|USER|LOGNAME|HOSTNAME|SHLVL|LD_.+|DYLD_.+|LLM_DOCKER_ENV_GORILLA)$'
    while IFS='=' read -r _ename _; do
        [ -z "$_ename" ] && continue
        [[ "$_ename" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [[ "$_ename" =~ $_ENV_BLOCK ]] && continue
        EXTRA_ENV="$EXTRA_ENV -e $_ename"
    done < <(env)

    docker run --rm -it \
        --label com.docker.compose.project=llm-docker \
        --label "llm-docker-project=$_LLM_PROJECT_TOKEN" \
        --hostname llm-docker \
        --name "$CONTAINER_NAME" \
        -w "$DOCKER_WORKDIR" \
        --network "$NETWORK_MODE" \
        $SSH_PORT_MAPPING \
        $CODEMAN_PORT_MAPPING \
        $CAP_DROP \
        $CAP_ADD \
        $SECURITY_OPT \
        "${_LLM_MOUNT_ARGS[@]}" \
        "${TMUX_CONF_MOUNT_ARG[@]}" \
        "${P10K_MOUNT_ARG[@]}" \
        -v "$HOME/.llm-docker/opencode/.config/opencode:/root/.config/opencode" \
        -v "$HOME/.llm-docker/opencode/.local/share/opencode:/root/.local/share/opencode" \
        -v "$HOME/.llm-docker/opencode/.cache/opencode:/root/.cache/opencode" \
        -v "$SCRIPT_DIR/llm-container-opencode-config.jsonc:/opt/llm-docker/templates/opencode.config.jsonc:ro" \
        -v "$SCRIPT_DIR/docker/docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro" \
        -v "$SCRIPT_DIR/docker/entrypoint-lib.sh:/usr/local/bin/entrypoint-lib.sh:ro" \
        -v "$SCRIPT_DIR/docker/rm-guard.sh:/usr/local/bin/rm:ro" \
        -v "$SCRIPT_DIR/../README.md:/opt/llm-docker/README.md:ro" \
        -v "$SCRIPT_DIR/ascii/llm-docker.txt:/opt/llm-docker/ascii.txt:ro" \
        -v "$SCRIPT_DIR/docker/colorize.sh:/opt/llm-docker/colorize.sh:ro" \
        $SSH_HOST_KEY_MOUNT \
        -e NODE_ENV="${NODE_ENV:-production}" \
        -e SANDBOX_ENABLED="${SANDBOX_ENABLED:-true}" \
        -e INTERNET_ACCESS="${INTERNET_ACCESS:-true}" \
        -e TERM \
        -e COLUMNS \
        -e LINES \
        -e COLORTERM=truecolor \
        -e TOOL=opencode \
        -e USE_TMUX="$USE_TMUX" \
        -e TMUX_TEAM="$TMUX_TEAM" \
        -e TMUX_TEAM_SIZE="$TMUX_TEAM_SIZE" \
        -e TMUX_CODEMAN="$TMUX_CODEMAN" \
        -e BUILDER_API_HOST="${BUILDER_API_HOST:-host.docker.internal}" \
        -e BUILDER_API_PORT="${BUILDER_API_PORT:-6666}" \
        -e CONTINUE_SESSION="$CONTINUE_SESSION" \
        -e OPENCODE_INIT_PROMPT \
        $SLOT_ENV \
        $ENV_FILES \
        $EXTRA_ENV \
        "$IMAGE_TAG" "$@"

    # Save THIS terminal's opencode session ID so a subsequent `ocd -c`
    # in the same pane resumes here, not whichever session was most
    # recent globally. Non-blocking: silently no-ops on any error.
    _save_terminal_session "$(_terminal_id)" "$_LLM_PROJECT_TOKEN" "$DOCKER_WORKDIR" 2>/dev/null || true
}
