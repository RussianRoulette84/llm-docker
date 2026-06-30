#!/bin/bash
# check-modules.sh — guard the Phase 5 module split so a future edit can't
# silently break it. Fails (exit 1) if:
#   1. modular setup.sh drops any expected function
#   2. the install.d steps don't concatenate into parseable bash
#   3. an install.d step CALLS a function first DEFINED in a later-sourced step
#   4. core setup.sh behavior (identity mount) drifts
# macOS bash 3.2-safe (no mapfile / associative arrays).
set -u
SRC="$(cd "$(dirname "$0")/../../src" && pwd)"
fail=0
_err() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; fail=1; }
_ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }

# Pinned contract: every function the launchers rely on from setup.sh.
EXPECTED="_compute_cap_flags _compute_workspace_mounts _count_apt_array _count_total_packages \
_dashed_session_dir _docker_format_line _docker_pretty _iterm_tag _iterm_untag \
_llm-docker_image_for_tool llm-docker_version _log _log_docker_exec _log_ensure_dir \
_log_file_size _log_rotate_if_needed _log_silent _log_write_file _lookup_terminal_session \
print_banner _project_docker_workdir _project_key _project_root _project_token _read_env_var \
_register_tmux_flip run_setup setup_dirs setup_env setup_image setup_image_incremental \
_source_all_config _spawn_api_bg _teardown_builder_api _terminal_id _tmux_nested_prompt \
_validate_workspace_paths _write_secret_handoff _maybe_start_api _ensure_docker_running spawn_multi_windows _set_tab_color"

echo "[1/4] modular setup.sh provides every expected function"
present="$(cd "$SRC" && SCRIPT_DIR="$SRC" bash -c 'source ./setup.sh >/dev/null 2>&1; declare -F | awk "{print \$3}"')"
miss=0
for f in $EXPECTED; do
    printf '%s\n' "$present" | grep -qx "$f" || { _err "missing function: $f"; miss=1; }
done
[ "$miss" -eq 0 ] && _ok "all $(echo $EXPECTED | wc -w | tr -d ' ') functions present"

echo "[2/4] install.d steps concatenate into parseable bash"
STEPS="01-docker 02-dirs 03-env 04-workspace 05-apikeys 06-ssh 07-builderapi 08-tmux 09-devpacks 10-image 11-link 99-complete"
catcmd=""
for s in $STEPS; do catcmd="$catcmd $SRC/install.d/$s.sh"; done
if cat $catcmd 2>/dev/null | bash -n; then _ok "install.d reconstruction parses"; else _err "install.d concat fails bash -n"; fi

echo "[3/4] no install.d forward-references"
i=0
for s in $STEPS; do
    i=$((i+1))
    for fn in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$SRC/install.d/$s.sh" 2>/dev/null | sed 's/()//'); do
        j=0
        for s2 in $STEPS; do
            j=$((j+1))
            [ "$j" -ge "$i" ] && break
            if grep -qE "(^|[^A-Za-z0-9_])${fn}([^A-Za-z0-9_]|$)" "$SRC/install.d/$s2.sh" 2>/dev/null; then
                _err "forward-ref: $s2 calls $fn() defined later in $s"
            fi
        done
    done
done
[ "$fail" -eq 0 ] && _ok "no forward references" || true

echo "[4/4] identity behavior unchanged through modular setup.sh"
out="$(cd "$SRC" && SCRIPT_DIR="$SRC" bash -c '
git() { case "$*" in *"rev-parse --show-toplevel"*) case "$2" in */foo*) echo "${2%%/foo*}/foo"; return 0;; esac; return 1;; *) return 1;; esac; }
source ./setup.sh >/dev/null 2>&1
a=""; _compute_workspace_mounts /h/Projects/ai/foo /h/Projects/ai /root/Projects true /root/Projects/ai 2>/dev/null; a="$_LLM_DOCKER_WORKDIR"
b=""; _compute_workspace_mounts /h/Projects/foo /h/Projects /root/Projects true /root/Projects/Projects 2>/dev/null; b="$_LLM_DOCKER_WORKDIR"
echo "$a|$b|${_LLM_MOUNT_ARGS[*]}"
')"
case "$out" in
    "/root/Projects/foo|/root/Projects/foo|"*":ro"*) _ok "ai vs Projects → same workdir, workspace :ro" ;;
    *) _err "identity drift: $out" ;;
esac

if [ "$fail" -ne 0 ]; then echo "check-modules: FAIL" >&2; exit 1; fi
echo "check-modules: clean ✓"
