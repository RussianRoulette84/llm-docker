#!/bin/bash
# Configure and start sshd inside the container. Called by docker-entrypoint.sh
# ONLY when LLM_DOCKER_SSH_ENABLED=true in llm-docker.conf.
#
# Auth: public-key only (password auth disabled). Keys come from:
#   1. LLM_DOCKER_SSH_AUTHORIZED_KEYS env var (one or more lines, \n-separated)
#   2. /ssh/authorized_keys (bind-mount)
#   3. /run/secrets/ssh_authorized_keys (docker secret)
# Any combination of the above is merged into /root/.ssh/authorized_keys.

set -e

SSH_PORT="${LLM_DOCKER_SSH_PORT:-22}"
AUTH_KEYS="/root/.ssh/authorized_keys"

mkdir -p /root/.ssh
chmod 700 /root/.ssh
: > "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

# Source 1: env var (supports newline-separated multi-key via $'\n' in value).
if [ -n "${LLM_DOCKER_SSH_AUTHORIZED_KEYS:-}" ]; then
    # %b expands backslash escapes (literal \n from .env becomes real newline)
    printf '%b\n' "$LLM_DOCKER_SSH_AUTHORIZED_KEYS" >> "$AUTH_KEYS"
fi

# Source 2: bind-mounted file.
if [ -f /ssh/authorized_keys ]; then
    cat /ssh/authorized_keys >> "$AUTH_KEYS"
fi

# Source 3: docker secret.
if [ -f /run/secrets/ssh_authorized_keys ]; then
    cat /run/secrets/ssh_authorized_keys >> "$AUTH_KEYS"
fi

if [ ! -s "$AUTH_KEYS" ]; then
    echo "[SSH] WARNING: no authorized_keys configured — SSH will reject every login."
    echo "[SSH] Set LLM_DOCKER_SSH_AUTHORIZED_KEYS in llm-docker.conf, or bind-mount /ssh/authorized_keys."
fi

# Persist host keys across container rebuilds by keeping them in the
# bind-mounted /etc/ssh/keys/ (host: ~/.llm-docker/ssh/). Generate on first
# run; reuse thereafter — same fingerprint every time.
HOST_KEYS_DIR="/etc/ssh/keys"
mkdir -p "$HOST_KEYS_DIR"
chmod 700 "$HOST_KEYS_DIR"
for t in ed25519 rsa ecdsa; do
    f="$HOST_KEYS_DIR/ssh_host_${t}_key"
    if [ ! -f "$f" ]; then
        ssh-keygen -q -t "$t" -f "$f" -N "" -C "llm-docker-$(date +%s)"
    fi
done

# Minimal hardened sshd config. Root via key only; host keys from the
# persistent mount.
cat > /etc/ssh/sshd_config.d/llm-docker.conf <<EOF
Port $SSH_PORT
HostKey $HOST_KEYS_DIR/ssh_host_ed25519_key
HostKey $HOST_KEYS_DIR/ssh_host_rsa_key
HostKey $HOST_KEYS_DIR/ssh_host_ecdsa_key
PermitRootLogin prohibit-password
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
EOF

echo "[SSH] starting sshd on port $SSH_PORT"
/usr/sbin/sshd
