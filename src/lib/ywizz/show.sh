#!/bin/bash

# --- ywizz_show: Unified Declarative Dispatcher ---
# Single entry point: ywizz_show type=confirm|path|input|select|checklist|header|security|ascii|banner ...
# Params: type=, title=, out=, default=, options=, subtitles=, descriptions=, initial=, which=, password=

# Requires: confirm, select, input, path, checklist, header, security, ascii, banner
_show_ensure_loaded() {
    : "${YWIZZ_DIR:=$(dirname "${BASH_SOURCE[0]}")}"
    [ -f "$YWIZZ_DIR/ascii.sh" ] && source "$YWIZZ_DIR/ascii.sh" 2>/dev/null || true
}

# Convert | to newline for options string
_show_options_to_lines() {
    local opts="$1"
    echo "${opts//|/$'\n'}"
}

ywizz_show() {
    local type="" title="" out="" default="" options="" subtitles="" descriptions="" initial="" which="" password=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            type=*)       type="${1#*=}"; shift ;;
            title=*)      title="${1#*=}"; shift ;;
            out=*)        out="${1#*=}"; shift ;;
            default=*)    default="${1#*=}"; shift ;;
            options=*)    options="${1#*=}"; shift ;;
            subtitles=*)  subtitles="${1#*=}"; shift ;;
            descriptions=*) descriptions="${1#*=}"; shift ;;
            initial=*)   initial="${1#*=}"; shift ;;
            which=*)      which="${1#*=}"; shift ;;
            password=*)   password="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done

    case "$type" in
        confirm)
            ask_yes_no_tui "$title" "${default:-y}" "$out" 1 0
            ;;
        path)
            ask_path_tui "$title" "$default" "$out" "$TREE_TOP" 1 0
            ;;
        input)
            ask_tui "$title" "$default" "$out" "$TREE_TOP" 1 0
            ;;
        select)
            local opts_lines
            opts_lines=$(_show_options_to_lines "$options")
            select_tui "$title" "$opts_lines" "$descriptions" "$subtitles" "$out" "${default:-0}" "true" 1 0
            ;;
        checklist)
            local opts_lines desc_lines sub_lines
            opts_lines=$(_show_options_to_lines "$options")
            desc_lines=$(_show_options_to_lines "$descriptions")
            sub_lines=$(_show_options_to_lines "$subtitles")
            checklist_tui "$title" "$opts_lines" "$desc_lines" "$sub_lines" "${initial:-}" "$out" "true" 1 0
            ;;
        header)
            header_tui "$title" "" "1"
            ;;
        security)
            style_security_warning 1
            ;;
        ascii)
            _show_ensure_loaded
            if [ "$which" = "primary" ]; then
                ywizz_ascii_primary
            else
                ywizz_ascii_secondary
            fi
            ;;
        banner)
            _show_ensure_loaded
            if [ "$which" = "primary" ]; then
                ywizz_ascii_primary
            else
                show_banner_combined
            fi
            ;;
        *)
            echo "ywizz_show: unknown type=$type" >&2
            return 1
            ;;
    esac
}
