#!/bin/bash
# setup/preflight.sh — env-gorilla secret injection, sourced at the very top of
# cld/ocd BEFORE the main setup.sh (which isn't available yet). The caller must
# set $_self_dir (the launcher's dir) first. This reads the caller's $@, may
# strip --refresh-env, and may `exec` the launcher again through env-gorilla so
# KeePassXC-backed secrets are in the environment. Tool-agnostic — both
# launchers source this identical file.
#
# Loads the `llm-docker` profile (cage-wide keys) AND, if the CWD's basename is
# a different name, that project's profile too — merged into one chip-blob so a
# single Touch ID covers everything. A missing project profile is non-fatal.

# --refresh-env: wipe env-gorilla's cached chip-blob before re-exec so
# newly-added KeePassXC entries propagate. Strip the flag from $@ either way.
_refresh_env=false
_new_args=()
for _a in "$@"; do
    case "$_a" in
        --refresh-env) _refresh_env=true ;;
        *) _new_args+=("$_a") ;;
    esac
done
set -- "${_new_args[@]}"
unset _new_args _a

# Explicit opt-in via llm-docker.conf (tiny grep — setup.sh isn't sourced yet).
# Underscores only; a hyphen in the key is dropped by the conf parser.
_gorilla_on=false
grep -q '^IS_S3C_GORILLA_ENABLED=true' "$_self_dir/llm-docker.conf" 2>/dev/null && _gorilla_on=true

# Continue/resume launches reuse a session and need no fresh secrets — used
# below to stay silent when the vault is opted-in but unavailable.
_is_continue=false
for _a in "$@"; do
    case "$_a" in -c|--continue|--resume) _is_continue=true; break ;; esac
done
unset _a

if [ -z "${LLM_DOCKER_ENV_GORILLA:-}" ] \
   && command -v env-gorilla >/dev/null 2>&1 \
   && { [ "${USER:-}" = "yaro" ] || [ ! -f "$_self_dir/.env" ] || [ "$_gorilla_on" = true ]; }; then
    _proj_dir=""
    for _a in "$@"; do
        case "$_a" in
            -*) ;;
            *) [ -d "$_a" ] && { _proj_dir="$(realpath "$_a")"; break; } ;;
        esac
    done
    [ -z "$_proj_dir" ] && _proj_dir="$(pwd)"
    _proj_name="$(basename "$_proj_dir")"
    unset _proj_dir _a

    if [ -n "$_proj_name" ] && [ "$_proj_name" != "llm-docker" ]; then
        _profiles="llm-docker,$_proj_name"
    else
        _profiles="llm-docker"
    fi
    if [ "$_refresh_env" = true ]; then
        env-gorilla --clear "$_profiles" >/dev/null 2>&1 || true
    fi
    export LLM_DOCKER_ENV_GORILLA=1
    exec env-gorilla "$_profiles" -- "$0" "$@"
fi

# Opted into the vault but env-gorilla isn't installed: fall back quietly to
# .env (or nothing). Warn ONCE, only when it could actually bite — fresh launch,
# no .env, and not a continue/resume (those reuse a logged-in session).
if [ "$_gorilla_on" = true ] && ! command -v env-gorilla >/dev/null 2>&1 \
   && [ ! -f "$_self_dir/.env" ] && [ "$_is_continue" = false ]; then
    printf '\033[2m[llm-docker] s3c-gorilla enabled but env-gorilla not found — launching without vault. Run its installer or set IS_S3C_GORILLA_ENABLED=false.\033[0m\n' >&2
fi
unset _proj_name _profiles _refresh_env _gorilla_on _is_continue
