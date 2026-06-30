# ── 9. Optional devpacks (build-time) ───────────────────────────────────────
header_tui "9/11  Optional devpacks (build-time)"
info "These flags bake extra tooling into the image. Flipping them only takes"
info "effect after ${secondary_accent}docker rmi llm-docker:latest${RESET} forces a rebuild."

DEVPACK_NAMES=(INSTALL_SECURITY INSTALL_RUBY INSTALL_CPP INSTALL_LLVM_CLANG INSTALL_NS INSTALL_MEDIA INSTALL_BROWSING)
DEVPACK_DESCS=(
  "pentest toolkit: nmap, sqlmap, nuclei, amass (go), nikto (git)"
  "Ruby stack: rbenv + ruby-build + cocoapods"
  "C/C++ basics: make + cmake + gcc"
  "LLVM/Clang toolchain (superset of CPP)"
  "NativeScript CLI + n (Node version manager)"
  "Media tools: ffmpeg + sox + yt-dlp + pipx"
  "Browsing: chromium-headless-shell + headful chromium + hyperframes skill"
)

# Defaults from current llm-docker.conf (only items currently set to "true").
DEVPACK_DEFAULTS=""
for i in "${!DEVPACK_NAMES[@]}"; do
    cur_val="$(_read_env_var "${DEVPACK_NAMES[$i]}" "$SCRIPT_DIR/llm-docker.conf")"
    if [ "$cur_val" = "true" ]; then
        [ -n "$DEVPACK_DEFAULTS" ] && DEVPACK_DEFAULTS+=","
        DEVPACK_DEFAULTS+="$i"
    fi
done

DEVPACK_OPTS=""
DEVPACK_DESCS_STR=""
for i in "${!DEVPACK_NAMES[@]}"; do
    [ -n "$DEVPACK_OPTS" ] && DEVPACK_OPTS+=$'\n'
    DEVPACK_OPTS+="${DEVPACK_NAMES[$i]}"
    [ -n "$DEVPACK_DESCS_STR" ] && DEVPACK_DESCS_STR+=$'\n'
    DEVPACK_DESCS_STR+="${DEVPACK_DESCS[$i]}"
done
DEVPACK_SKIP_IDX=${#DEVPACK_NAMES[@]}
DEVPACK_OPTS+=$'\n'"Skip (keep current values)"
DEVPACK_DESCS_STR+=$'\n'"Leave every INSTALL_* flag untouched"

checklist_tui "Select devpacks to bake in (Space toggles, Enter confirms)" "$DEVPACK_OPTS" "$DEVPACK_DESCS_STR" "" "$DEVPACK_DEFAULTS" DEVPACK true 1 0

DEVPACK_SKIP_CHOSEN="$(eval "echo \"\${DEVPACK_${DEVPACK_SKIP_IDX}:-false}\"")"
if [ "$DEVPACK_SKIP_CHOSEN" = "true" ]; then
    success "INSTALL_* flags unchanged"
else
    DEVPACK_CHANGED=0
    for i in "${!DEVPACK_NAMES[@]}"; do
        chosen="$(eval "echo \"\${DEVPACK_${i}:-false}\"")"
        new_val="false"
        [ "$chosen" = "true" ] && new_val="true"
        cur_val="$(_read_env_var "${DEVPACK_NAMES[$i]}" "$SCRIPT_DIR/llm-docker.conf")"
        if [ "$cur_val" != "$new_val" ]; then
            DEVPACK_CHANGED=1
        fi
        _update_conf_var "${DEVPACK_NAMES[$i]}" "$new_val"
    done
    if [ "$DEVPACK_CHANGED" = "1" ]; then
        _mark_rebuild_needed "INSTALL_* flags changed"
        success "Devpack flags saved"
    else
        success "Devpack flags saved (no changes)"
    fi
fi

