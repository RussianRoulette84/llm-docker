#!/bin/bash
# ocd.run.sh — run_opencode_container, sourced by ocd. Tool-specific (sqlite
# session tracking); uses globals the launcher sets before the call.

# Session id still in opencode's index? Old chats get pruned, so a remembered id
# can outlive the chat it points at. The sqlite DB itself lives on a Docker
# volume we can't read from the host — the index file next to it is the stand-in.
# No index yet → treat as alive; docker-entrypoint.sh re-checks against the real
# DB and degrades to fresh there.
_opencode_session_alive() {
    local idx="$HOME/.llm-docker/opencode/.local/share/opencode/sessions-index.tsv"
    [ -f "$idx" ] || return 0
    awk -F'\t' -v s="$1" '$1==s {f=1} END{exit !f}' "$idx"
}

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
    if [ "${LLM_D0CKER_SHH_EN4BLED:-false}" = "true" ]; then
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
    fi

    # SSH host keys + outbound keys come from the env-gorilla vault at
    # container start (see docker-entrypoint.sh + setup-ssh.sh). Keys live
    # in the ssh-agent's memory only, never on disk.

    # Session restore resolution:
    #   -c <UUID>     → RESUME_SESSION (direct)
    #   -c -s N       → read slot file, fall into RESUME_SESSION
    # Whatever ends up in RESUME_SESSION is forwarded as SLOT_RESUME_ID.
    if [ -z "$RESUME_SESSION" ] && [ -n "$SLOT" ] && [ "$CONTINUE_SESSION" = true ]; then
        local SLOT_FILE="$HOME/.llm-docker/opencode/.local/share/opencode/slot_${SLOT}.id"
        [ -f "$SLOT_FILE" ] && RESUME_SESSION="$(cat "$SLOT_FILE")"
    fi

    # Per-terminal continue: `-c` without --slot/UUID reopens THIS tab's own
    # chat; with no row for this tab, the project's most recently saved chat.
    # Dead ids are skipped on the way down. Nothing left alive → fresh.
    if [ "$CONTINUE_SESSION" = true ] && [ -z "$RESUME_SESSION" ] && [ -z "$SLOT" ]; then
        local _TS_TID
        _TS_TID=$(_terminal_id)
        RESUME_SESSION=$(_lookup_terminal_session "$_TS_TID" "$_LLM_PROJECT_TOKEN" \
            _opencode_session_alive)
        if [ -n "$RESUME_SESSION" ]; then
            echo "[OCD][terminal] tab ${_TS_TID%%:*} -> ${RESUME_SESSION:0:24}"
        else
            # Must be explicit: bare `opencode` reopens the newest chat on its
            # own, so leaving -c on here is what made every tab land in the
            # same chat. The fresh-launch branch below sends --prompt instead.
            CONTINUE_SESSION=false
            echo "[OCD][terminal] no remembered chat for this project — starting fresh"
        fi
    fi

    SLOT_ENV=""
    [ -n "$SLOT" ]           && SLOT_ENV="$SLOT_ENV -e SLOT=$SLOT"
    [ -n "$RESUME_SESSION" ] && SLOT_ENV="$SLOT_ENV -e SLOT_RESUME_ID=$RESUME_SESSION"

    # Fresh session only → entrypoint injects --prompt. Prefer BOOT.md contents, fall back to CLAUDE.md default.
    export OPENCODE_INIT_PROMPT=""
    if [ -z "$RESUME_SESSION" ] && [ "$CONTINUE_SESSION" != true ] && [ -z "${DB_MAINTAIN:-}" ]; then
        if [ -f "$WORKDIR/BOOT.md" ]; then
            export OPENCODE_INIT_PROMPT="$(cat "$WORKDIR/BOOT.md")"
        elif [ -f "$WORKDIR/CLAUDE.md" ]; then
            export OPENCODE_INIT_PROMPT="Read ./CLAUDE.md in full and follow its BOOT steps before anything else."
        fi
    fi

    # Codeman web UI on port 3000 needs bridge networking to publish with `-p`.
    CODEMAN_PORT_MAPPING=""
    [ "$TMUX_CODEMAN" = true ] && CODEMAN_PORT_MAPPING="-p 3000:3000"

    # Extra ports published container -> host, from PUBLISH_PORTS in
    # llm-docker.conf. Space-separated "HOST:CONTAINER" (or a bare port for
    # both sides), e.g. PUBLISH_PORTS="8100:8100 5173".
    #
    # Docker Desktop runs containers inside a Linux VM. `--network host`
    # joins THAT VM's network namespace, not macOS's — so a port merely
    # bound inside the container is invisible to your Mac's browser. Only
    # `-p` published ports cross the VM boundary, and `-p` requires bridge
    # networking (see the NETWORK_MODE decision below).
    APP_PORT_MAPPING=""
    if [ -n "${PUBLISH_PORTS:-}" ]; then
        for _pp in $PUBLISH_PORTS; do
            case "$_pp" in
                *:*) ;;
                *)   _pp="${_pp}:${_pp}" ;;
            esac
            if printf '%s' "$_pp" | grep -qE '^[0-9]{1,5}:[0-9]{1,5}$'; then
                # Host side auto-bumps when taken, so a second container for
                # another project doesn't fail to start on a busy port (same
                # rule as the SSH port above). Container side never moves —
                # the app inside still binds what it was told to.
                _pp_want="${_pp%%:*}"
                _pp_host="$_pp_want"
                _pp_cont="${_pp##*:}"
                _pp_max=$(( _pp_want + 20 ))
                while (timeout 1 bash -c "</dev/tcp/127.0.0.1/$_pp_host") 2>/dev/null; do
                    _pp_host=$(( _pp_host + 1 ))
                    [ "$_pp_host" -le "$_pp_max" ] || break
                done
                if [ "$_pp_host" -gt "$_pp_max" ]; then
                    _log OCD WARNING "ports $_pp_want-$_pp_max all busy — not publishing $_pp_cont this time."
                else
                    [ "$_pp_host" = "$_pp_want" ] || \
                        _log OCD "port $_pp_want busy — publishing container $_pp_cont on $_pp_host instead"
                    APP_PORT_MAPPING="$APP_PORT_MAPPING -p ${_pp_host}:${_pp_cont}"
                fi
            else
                _log OCD ERROR "PUBLISH_PORTS: ignoring malformed entry '$_pp' (want HOST:CONTAINER, e.g. 8100:8100)"
            fi
        done
        unset _pp _pp_want _pp_host _pp_cont _pp_max
    fi

    if [ "${INTERNET_ACCESS:-true}" = "false" ] || [ -n "$SSH_PORT_MAPPING" ] || [ -n "$CODEMAN_PORT_MAPPING" ] || [ -n "$APP_PORT_MAPPING" ]; then
        export NETWORK_MODE=bridge
    else
        export NETWORK_MODE=host
    fi

    # Cap/security flags from the same source-of-truth cld uses.
    _compute_cap_flags "${SANDBOX_ENABLED:-true}" "${INTERNET_ACCESS:-true}" "${LLM_D0CKER_SHH_EN4BLED:-false}" CAP_DROP CAP_ADD SECURITY_OPT

    # RAM / shm / pids / cpu caps from llm-docker.conf — one container can't
    # starve the shared Docker VM.
    _compute_limit_flags OCD LIMIT_FLAGS

    # Forward both config files into the container as env. Docker accepts
    # multiple --env-file flags; conf first so .env can still override.
    ENV_FILES=""
    [ -f "$SCRIPT_DIR/llm-docker.conf" ] && ENV_FILES="$ENV_FILES --env-file $SCRIPT_DIR/llm-docker.conf"
    # The plain secrets file is the fallback for machines WITHOUT env-gorilla.
    # If the tool is installed, the vault is the only source — even when a key
    # is missing from it. Handing the file over too lets an empty key in it
    # overwrite a real value.
    if ! command -v env-gorilla >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/.env" ]; then
        ENV_FILES="$ENV_FILES --env-file $SCRIPT_DIR/.env"
    fi

    # Workspace + project mounts were built into _LLM_MOUNT_ARGS by
    # _compute_workspace_mounts above (workspace :ro, active project :rw).

    TMUX_CONF_MOUNT_ARG=()
    [ -f "$HOME/.tmux.conf" ] && TMUX_CONF_MOUNT_ARG=(-v "$HOME/.tmux.conf:/root/.tmux.conf:ro")

    P10K_MOUNT_ARG=()
    [ -f "$HOME/.p10k.zsh" ] && P10K_MOUNT_ARG=(-v "$HOME/.p10k.zsh:/root/.p10k.zsh:ro")

    # CAP_* / SECURITY_OPT are unquoted on purpose — they word-split into
    # multiple --cap-add / --cap-drop / --security-opt args.
    local CONTAINER_NAME="llm-docker-opencode-$$"
    export CONTAINER_NAME

    _iterm_tag "OpenCode" "$WORKDIR"
    # The save lives in the trap so it also fires when the tab is closed or
    # CMD+Q'd (HUP → trap → exit, which never reaches the code below the docker
    # run). Idempotent: rows are keyed by tab + project.
    # These are locals of this function and gone by the time an EXIT trap runs
    # on the normal path, so the save reads global snapshots instead.
    _TS_PANE_FILE="$HOME/.llm-docker/opencode/.local/share/opencode/pane-${CONTAINER_NAME}.session"
    _TS_WORKDIR="$DOCKER_WORKDIR"
    _ocd_on_exit() {
        _save_terminal_session "$(_terminal_id)" "$_LLM_PROJECT_TOKEN" "$_TS_WORKDIR" \
            "$_TS_BASELINE" "$RESUME_SESSION" "$_TS_PANE_FILE" 2>/dev/null || true
        _teardown_builder_api
        _iterm_untag
    }
    trap _ocd_on_exit EXIT INT TERM HUP

    # Resolve image tag: prefer the opencode-only image, fall back to the
    # combined llm-docker:latest if that's what install.sh produced.
    local IMAGE_TAG
    IMAGE_TAG="$(_llm-docker_image_for_tool opencode)"

    # Forward every env var into the container. Tiny blocklist: only vars
    # that would BREAK the container if a Mac value leaked in (PATH points
    # at ~/... on the host (HOME points at a path that doesn't exist in the container, loader
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

    # Per-terminal session tracking: baseline = highest session time_UPDATED
    # before this launch, so the exit-side save binds the session you last
    # chatted in (switches included), never stale ones.
    _TS_BASELINE=0
    local _ts_idx="$HOME/.llm-docker/opencode/.local/share/opencode/sessions-index.tsv"
    [ -f "$_ts_idx" ] && _TS_BASELINE="$(awk -F'\t' 'NF>=4 {b=$4} END{print b+0}' "$_ts_idx")"

    docker run --rm -it \
        --label com.docker.compose.project=llm-docker \
        --label "llm-docker-project=$_LLM_PROJECT_TOKEN" \
        --label "llm-docker-tool=opencode" \
        --hostname llm-docker \
        --name "$CONTAINER_NAME" \
        -w "$DOCKER_WORKDIR" \
        --network "$NETWORK_MODE" \
        $SSH_PORT_MAPPING \
        $CODEMAN_PORT_MAPPING \
        $APP_PORT_MAPPING \
        $CAP_DROP \
        $CAP_ADD \
        $SECURITY_OPT \
        $LIMIT_FLAGS \
        "${_LLM_MOUNT_ARGS[@]}" \
        "${TMUX_CONF_MOUNT_ARG[@]}" \
        "${P10K_MOUNT_ARG[@]}" \
        -v "$HOME/.llm-docker/opencode/.config/opencode:/root/.config/opencode" \
        -v llm-docker-opencode-data:/root/.local/share/opencode \
        -v "$HOME/.llm-docker/opencode/.local/share/opencode:/mnt/opencode-mirror" \
        -v "$HOME/.llm-docker/opencode/.cache/opencode:/root/.cache/opencode" \
        -v "$SCRIPT_DIR/llm-container-opencode-config.jsonc:/opt/llm-docker/templates/opencode.config.jsonc:ro" \
        -v "$SCRIPT_DIR/docker/docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro" \
        -v "$SCRIPT_DIR/docker/entrypoint-lib.sh:/usr/local/bin/entrypoint-lib.sh:ro" \
        -v "$SCRIPT_DIR/docker/opencode-db.sh:/usr/local/bin/opencode-db.sh:ro" \
        -v "$SCRIPT_DIR/docker/opencode-pane-session.js:/root/.config/opencode/plugins/pane-session.js:ro" \
        -v "$SCRIPT_DIR/../scripts/ocd_db_restore.sh:/usr/local/bin/ocd-db-maintain.sh:ro" \
        -v "$SCRIPT_DIR/docker/rm-guard.sh:/usr/local/bin/rm:ro" \
        -v "$SCRIPT_DIR/../README.md:/opt/llm-docker/README.md:ro" \
        -v "$SCRIPT_DIR/ascii/llm-docker.txt:/opt/llm-docker/ascii.txt:ro" \
        -v "$SCRIPT_DIR/docker/colorize.sh:/opt/llm-docker/colorize.sh:ro" \
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

}
