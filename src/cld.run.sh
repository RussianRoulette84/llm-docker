#!/bin/bash
# cld.run.sh — run_claude_container, sourced by cld. Tool-specific (watchdog +
# UUID session tracking); uses globals the launcher sets before the call.

run_claude_container() {
    local WORKDIR="$1"
    shift
    cd "$SCRIPT_DIR"

    _tmux_nested_prompt

    CONTAINER_NAME="claude-$$"

    _iterm_tag "Claude" "$WORKDIR"

    # Cleanup on exit: kill watchdog, stop container
    cleanup_container() {
        [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        _teardown_builder_api
        _iterm_untag
    }
    trap cleanup_container EXIT INT TERM HUP

    # Build claude flags + optional initial-prompt positional.
    # Positional prompt (claude "query") starts interactive + sends it as the
    # first user message, so Claude responds immediately. --append-system-prompt
    # only modifies behavior — it doesn't trigger a turn. See claude CLI docs.
    CLAUDE_FLAGS=()
    INIT_PROMPT=()
    if [ -n "$RESUME_SESSION" ]; then
        CLAUDE_FLAGS=(--resume "$RESUME_SESSION")
    elif [ "$CONTINUE_SESSION" = true ]; then
        CLAUDE_FLAGS=(--continue)
    elif [ -f "$WORKDIR/BOOT.md" ]; then
        INIT_PROMPT=("$(cat "$WORKDIR/BOOT.md")")
    elif [ -f "$WORKDIR/CLAUDE.md" ]; then
        INIT_PROMPT=("Read ./CLAUDE.md in full and follow its instructions.")
    fi

    # Deletion-safe mounts + stable identity (see setup.sh). Mounts the
    # workspace READ-ONLY and only the active project READ-WRITE, at a stable
    # container path keyed on the project's git remote / folder name — so an
    # agent can't wipe sibling projects and sessions survive WORKSPACE_DIR
    # changes. Sets _LLM_DOCKER_WORKDIR + the _LLM_MOUNT_ARGS array.
    _compute_workspace_mounts "$WORKDIR" "$WORKSPACE_DIR" "$DOCKER_DIR" \
        "$WORKSPACE_MOUNT_ACTIVE" "$DOCKER_WORKSPACE_TARGET"
    if ! _validate_workspace_paths "$_LLM_PROJECT_ROOT" "$DOCKER_DIR/$_LLM_PROJECT_TOKEN"; then
        _log CLD ERROR "Launch cld from inside a specific project folder and try again."
        exit 1
    fi
    DOCKER_WORKDIR="$_LLM_DOCKER_WORKDIR"

    # Background watchdog: survives CMD+Q / crashes
    # - Periodically finds active session via lsof inside the container (process-specific, no race)
    # - If parent shell dies, kills the container
    WATCHDOG_PID=""
    DOCKER_SESSION_DIR="/root/.claude/projects/$(echo "$DOCKER_WORKDIR" | sed 's|[/_.]|-|g')"
    (
        set +e
        PARENT_PID=$$
        sleep 10
        while kill -0 "$PARENT_PID" 2>/dev/null; do
            if [ -n "$SLOT" ]; then
                # Find which .jsonl the claude process has open via /proc (unique to THIS container)
                SID=$(docker exec "$CONTAINER_NAME" sh -c \
                    "for f in /proc/*/fd/*; do readlink \"\$f\" 2>/dev/null; done | grep '$DOCKER_SESSION_DIR/.*\.jsonl' | sort -u | tail -1" \
                    2>/dev/null)
                if [ -n "$SID" ]; then
                    basename "$SID" .jsonl > "$CLAUDE_HOME/.claude/slot_${SLOT}.id"
                fi
            fi
            sleep 5
        done
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    ) &
    WATCHDOG_PID=$!
    disown "$WATCHDOG_PID"

    if [ -n "$SLOT" ]; then
        if [ -n "$RESUME_SESSION" ]; then
            _status "${GRN}[restore]${RST}" "slot ${CYN}$SLOT${RST}  session ${DIM}${RESUME_SESSION:0:8}...${RST}"
        else
            _status "${C2}[new]${RST}" "slot ${CYN}$SLOT${RST}"
        fi
        _status ">" "$DOCKER_WORKDIR"
        printf "\n"
        sleep 0.3
        # Clear screen right before Claude takes over
        clear
    fi


    # Forward terminal environment variables
    if command -v stty > /dev/null 2>&1; then
        TERM_SIZE=$(stty size 2>/dev/null || echo "24 80")
        export LINES=$(echo $TERM_SIZE | cut -d' ' -f1)
        export COLUMNS=$(echo $TERM_SIZE | cut -d' ' -f2)
    fi

    export TERM=${TERM:-xterm-256color}

    # Load llm-docker.conf (non-secret config) then .env (secrets + overrides).
    # Order matters: .env wins when a var is set in both. See setup.sh.
    ENV_FILES=""
    SANDBOX_ENABLED="true"
    INTERNET_ACCESS="true"
    NETWORK_MODE="host"

    _source_all_config
    SANDBOX_ENABLED=${SANDBOX_ENABLED:-true}
    INTERNET_ACCESS=${INTERNET_ACCESS:-true}
    [ -f "$SCRIPT_DIR/llm-docker.conf" ] && ENV_FILES="$ENV_FILES --env-file $SCRIPT_DIR/llm-docker.conf"
    [ -f "$SCRIPT_DIR/.env" ]            && ENV_FILES="$ENV_FILES --env-file $SCRIPT_DIR/.env"

    # Single source of truth for cap/security flags (see setup.sh).
    _compute_cap_flags "$SANDBOX_ENABLED" "$INTERNET_ACCESS" "${LLM_DOCKER_SSH_ENABLED:-false}" CAP_DROP CAP_ADD SECURITY_OPT

    # SSH port publish requires bridge networking (`-p` can't be used with host).
    # With SLOT: offset host port by (SLOT - 1) → slot 1=8884, slot 2=8885, etc.
    # Without SLOT: start at base port and auto-bump upward if it's taken (so
    # a second `cld` without --slot just works instead of erroring on bind).
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
                    _log CLD ERROR "No free SSH port in $_SSH_BASE-$_SSH_MAX. Stop some containers or pass --slot N."
                    exit 1
                fi
            done
            if [ "$_SSH_HOST_PORT" != "$_SSH_BASE" ]; then
                _log CLD "SSH port $_SSH_BASE busy — using $_SSH_HOST_PORT (ssh -p $_SSH_HOST_PORT root@localhost)"
            fi
        fi
        SSH_PORT_MAPPING="-p ${_SSH_HOST_PORT}:${_SSH_CONTAINER}"
        SSH_HOST_KEY_MOUNT="-v $HOME/.llm-docker/ssh:/etc/ssh/keys"
    fi

    # Codeman exposes its web UI on port 3000 — needs bridge networking to
    # publish with `-p`. In host mode the port is already reachable on localhost.
    CODEMAN_PORT_MAPPING=""
    if [ "$TMUX_CODEMAN" = true ]; then
        CODEMAN_PORT_MAPPING="-p 3000:3000"
    fi

    if [ "$INTERNET_ACCESS" = "false" ] || [ -n "$SSH_PORT_MAPPING" ] || [ -n "$CODEMAN_PORT_MAPPING" ]; then
        NETWORK_MODE="bridge"
    else
        NETWORK_MODE="host"
    fi

    PORT_MAPPING="$SSH_PORT_MAPPING $CODEMAN_PORT_MAPPING"

    # SLOT env var tells the entrypoint to save session ID on exit
    # SLOT_RESUME_ID tells it which session was resumed (so it can identify THIS container's session)
    SLOT_ENV=""
    if [ -n "$SLOT" ]; then
        SLOT_ENV="-e SLOT=$SLOT"
        if [ -n "$RESUME_SESSION" ]; then
            SLOT_ENV="$SLOT_ENV -e SLOT_RESUME_ID=$RESUME_SESSION"
        fi
    fi

    # Fresh-session detector: if we're NOT continuing or resuming, tell the
    # entrypoint to re-seed /root/.claude/settings.local.json from the
    # repo-bundled defaults. Resuming keeps whatever permissions the user
    # accumulated in-session.
    NEW_CLAUDE_SESSION="true"
    [ -n "$RESUME_SESSION" ] && NEW_CLAUDE_SESSION="false"
    [ "$CONTINUE_SESSION" = true ] && NEW_CLAUDE_SESSION="false"

    # Workspace + project mounts were built into _LLM_MOUNT_ARGS by
    # _compute_workspace_mounts above (workspace :ro, active project :rw at a
    # stable path). Used as "${_LLM_MOUNT_ARGS[@]}" in the docker run below.

    TMUX_CONF_MOUNT=""
    [ -f "$HOME/.tmux.conf" ] && TMUX_CONF_MOUNT="-v $HOME/.tmux.conf:/root/.tmux.conf:ro"

    P10K_MOUNT=""
    [ -f "$HOME/.p10k.zsh" ] && P10K_MOUNT="-v $HOME/.p10k.zsh:/root/.p10k.zsh:ro"

    # Resolve image tag: prefer the claude-only image, fall back to the
    # combined llm-docker:latest if that's what install.sh produced.
    IMAGE_TAG="$(_llm-docker_image_for_tool claude)"

    # Forward every env var into the container. Tiny blocklist: only vars
    # that would BREAK the container if a Mac value leaked in (PATH points
    # at /Users/yaro/..., HOME points at a path that doesn't exist, loader
    # hijack via LD_/DYLD_, etc.) plus the env-gorilla re-exec guard.
    EXTRA_ENV=""
    _ENV_BLOCK='^(PATH|HOME|TMPDIR|PWD|OLDPWD|SHELL|USER|LOGNAME|HOSTNAME|SHLVL|LD_.+|DYLD_.+|LLM_DOCKER_ENV_GORILLA)$'
    while IFS='=' read -r _ename _; do
        [ -z "$_ename" ] && continue
        [[ "$_ename" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [[ "$_ename" =~ $_ENV_BLOCK ]] && continue
        EXTRA_ENV="$EXTRA_ENV -e $_ename"
    done < <(env)
    unset _ename _ENV_BLOCK

    docker run --rm -it \
        --label com.docker.compose.project=llm-docker \
        --label "llm-docker-project=$_LLM_PROJECT_TOKEN" \
        --hostname llm-docker \
        --name "$CONTAINER_NAME" \
        -w "$DOCKER_WORKDIR" \
        "${_LLM_MOUNT_ARGS[@]}" \
        $TMUX_CONF_MOUNT \
        $P10K_MOUNT \
        -v ~/.llm-docker/claude/.claude:/root/.claude \
        -v ~/.llm-docker/claude/.config:/root/.config \
        -v ~/.llm-docker/claude/.claude.json:/root/.claude.json \
        -v "$SCRIPT_DIR/docker/docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro" \
        -v "$SCRIPT_DIR/docker/entrypoint-lib.sh:/usr/local/bin/entrypoint-lib.sh:ro" \
        -v "$SCRIPT_DIR/docker/rm-guard.sh:/usr/local/bin/rm:ro" \
        -v "$SCRIPT_DIR/../README.md:/opt/llm-docker/README.md:ro" \
        -v "$SCRIPT_DIR/ascii/llm-docker.txt:/opt/llm-docker/ascii.txt:ro" \
        -v "$SCRIPT_DIR/docker/colorize.sh:/opt/llm-docker/colorize.sh:ro" \
        -v "$SCRIPT_DIR/llm-container-claude-settings.json:/opt/llm-docker/templates/claude-settings.json:ro" \
        $SSH_HOST_KEY_MOUNT \
        --network "$NETWORK_MODE" \
        $PORT_MAPPING \
        $CAP_DROP \
        $CAP_ADD \
        $SECURITY_OPT \
        -e TERM \
        -e COLUMNS \
        -e LINES \
        -e COLORTERM=truecolor \
        -e TOOL=claude \
        -e NEW_CLAUDE_SESSION="$NEW_CLAUDE_SESSION" \
        -e USE_TMUX="$USE_TMUX" \
        -e TMUX_TEAM="$TMUX_TEAM" \
        -e TMUX_TEAM_SIZE="$TMUX_TEAM_SIZE" \
        -e TMUX_RECON="$TMUX_RECON" \
        -e TMUX_CODEMAN="$TMUX_CODEMAN" \
        -e TMUX_CLAUDE="$TMUX_CLAUDE" \
        -e DANGER_MODE="$DANGER_MODE" \
        $SLOT_ENV \
        $ENV_FILES \
        $EXTRA_ENV \
        "$IMAGE_TAG" "${CLAUDE_FLAGS[@]}" "$@" "${INIT_PROMPT[@]}"

    # Save THIS terminal's claude session UUID so a subsequent `cld -c`
    # in the same pane resumes here, not whichever session was most
    # recent globally. Non-blocking: silently no-ops on any error.
    _save_terminal_session "$(_terminal_id)" "$(_project_key "$WORKDIR")" "$(_claude_session_dir "$WORKDIR")" 2>/dev/null || true
}
