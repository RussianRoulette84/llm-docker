#!/usr/bin/env bash
# smoke_test.sh — verify SSH end-to-end against the built llm-docker image.
# Runs on macOS bash 3.2 (no homebrew bash required).
# Starts an ephemeral container with sshd on an auto-picked free host port,
# probes the TCP listener, tries key-based `ssh root@localhost whoami`, tears
# down. Invoked standalone or from install_test.sh's health check.
#
# Usage:  ./src/smoke_test.sh
# Exit:   0 = SSH login works; 1 = any check failed; skipped if SSH disabled.

set -u
SCRIPT_DIR="$( cd "$( dirname "$( realpath "${BASH_SOURCE[0]}" )" )" && pwd )"

RESET=$'\033[0m'; DIM=$'\033[2m'; BOLD=$'\033[1m'
GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'
PURPLE=$'\033[38;5;177m'

_ok()   { printf "  ${GREEN}✔${RESET} %s\n" "$1"; }
_fail() { printf "  ${RED}✗${RESET} %s\n" "$1"; }
_info() { printf "  ${DIM}· %s${RESET}\n" "$1"; }
_warn() { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }

if [ ! -f "$SCRIPT_DIR/llm-docker.conf" ]; then
    echo "${RED}llm-docker.conf not found — run install.sh first.${RESET}" >&2
    exit 1
fi
if ! docker image inspect llm-docker:latest >/dev/null 2>&1; then
    echo "${RED}llm-docker:latest image missing — run install.sh first.${RESET}" >&2
    exit 1
fi

_read_conf() { grep "^$1=" "$SCRIPT_DIR/llm-docker.conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"; }
SSH_ENABLED=$(_read_conf LLM_DOCKER_SSH_ENABLED)
SSH_PORT=$(_read_conf LLM_DOCKER_SSH_PORT)
SSH_HOST_PORT=$(_read_conf LLM_DOCKER_SSH_HOST_PORT)
: "${SSH_PORT:=22}"
: "${SSH_HOST_PORT:=8884}"

if [ "$SSH_ENABLED" != "true" ]; then
    printf "\n${YELLOW}SSH is disabled in llm-docker.conf — nothing to smoke test.${RESET}\n"
    exit 0
fi

# Pick a free host port for the ephemeral test container. Prefer the configured
# port; if it's taken (e.g. a real cld/ocd container is already running on it),
# auto-advance to the next free port instead of failing. The test spins up its
# OWN container, so any free port validates that sshd binds + key login works.
_port_busy() { (timeout 1 bash -c "</dev/tcp/127.0.0.1/$1") 2>/dev/null; }
TEST_HOST_PORT="$SSH_HOST_PORT"
if _port_busy "$TEST_HOST_PORT"; then
    _orig="$TEST_HOST_PORT"
    for _p in $(seq $((SSH_HOST_PORT + 1)) $((SSH_HOST_PORT + 20))); do
        if ! _port_busy "$_p"; then TEST_HOST_PORT="$_p"; break; fi
    done
    if [ "$TEST_HOST_PORT" = "$_orig" ]; then
        _fail "no free host port in ${_orig}-$((_orig + 20)) — stop some containers and rerun."
        exit 1
    fi
    _warn "port $_orig in use (cld/ocd running?) — testing on free port $TEST_HOST_PORT instead."
    unset _orig _p
fi

printf "\n${BOLD}${PURPLE}llm-docker · SSH smoke test${RESET}\n"
printf "${DIM}────────────────────────────────────────────${RESET}\n"
_info "image:         llm-docker:latest"
_info "host port:     $TEST_HOST_PORT  →  container $SSH_PORT"

CNAME="llm-docker-smoke-$$"
cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

# Start an ephemeral container. Entrypoint is bypassed so we don't spawn claude
# or opencode — just run setup-ssh.sh and idle long enough for the probe.
# Mounts mirror cld's SSH setup: authorized_keys comes from env-file, host keys
# from ~/.llm-docker/ssh to keep fingerprints stable.
docker run -d --rm \
    --name "$CNAME" \
    --hostname llm-docker-smoke \
    --network bridge \
    -p "${TEST_HOST_PORT}:${SSH_PORT}" \
    --env-file "$SCRIPT_DIR/llm-docker.conf" \
    --env-file "$SCRIPT_DIR/.env" \
    -v "$HOME/.llm-docker/ssh:/etc/ssh/keys" \
    --entrypoint bash \
    llm-docker:latest -c '/setup-ssh.sh && sleep 60' >/dev/null || {
        _fail "docker run failed"; exit 1;
    }
_ok "container started ($CNAME)"

# Wait up to 15s for sshd to bind the published port.
for i in $(seq 1 15); do
    if (timeout 1 bash -c "</dev/tcp/127.0.0.1/$TEST_HOST_PORT") 2>/dev/null; then
        _ok "sshd listening on 127.0.0.1:$TEST_HOST_PORT"
        break
    fi
    sleep 1
    [ "$i" = "15" ] && { _fail "sshd did not bind within 15s"; docker logs "$CNAME" 2>&1 | tail -20 | sed 's/^/    /'; exit 1; }
done

# Key-based login. BatchMode=yes disables password fallback, so if the key
# the installer saved doesn't match /etc/ssh/keys we fail loud.
SSH_ERR=$(mktemp)
if ssh -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o BatchMode=yes \
       -o ConnectTimeout=5 \
       -o LogLevel=ERROR \
       -p "$TEST_HOST_PORT" root@localhost 'whoami; hostname' >"$SSH_ERR.out" 2>"$SSH_ERR"; then
    _ok "ssh login succeeded"
    _info "remote whoami: $(head -1 "$SSH_ERR.out")"
    _info "remote host:   $(sed -n '2p' "$SSH_ERR.out")"
    printf "\n${GREEN}SSH smoke test passed.${RESET}\n"
    rc=0
else
    _fail "ssh login failed"
    if [ -s "$SSH_ERR" ]; then
        _info "stderr:"
        sed 's/^/    /' "$SSH_ERR"
    else
        _info "stderr was empty (BatchMode+LogLevel=ERROR silenced it) — rerunning with -vv for diagnostics:"
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o BatchMode=yes \
            -o ConnectTimeout=5 \
            -vv -p "$TEST_HOST_PORT" root@localhost true 2>&1 | \
            grep -iE 'offering|authentications|permission|identity|host key|accepted|rejected|closed|method|userauth|pubkey|algorithm' | \
            sed 's/^/    /'
    fi
    _info "container authorized_keys (first 100 chars):"
    docker exec "$CNAME" bash -c 'head -c 100 /root/.ssh/authorized_keys; echo' 2>/dev/null | sed 's/^/    /'
    _info "ssh-agent keys on host:"
    ssh-add -l 2>&1 | sed 's/^/    /'
    printf "\n${RED}SSH smoke test failed.${RESET}\n"
    rc=1
fi

exit "$rc"
