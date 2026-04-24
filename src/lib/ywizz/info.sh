#!/bin/bash

# --- ywizz Info (Status & Progress) ---

# Status messages go to stderr so they appear immediately (stdout can be buffered, e.g. during docker pull)
info() {
    printf "%b%s %b[INFO]%b %s\n" "$(get_accent)" "$TREE_MID" "$CYAN" "$RESET" "$1" >&2
}

success() {
    printf "%b%s %b[ OK ]%b %b%s%b\n" "$(get_accent)" "$TREE_MID" "$GREEN" "$RESET" "$GREEN" "$1" "$RESET" >&2
}

warn() {
    printf "%b%s %b[WARN]%b %b%s%b\n" "$(get_accent)" "$TREE_MID" "$YELLOW" "$RESET" "$YELLOW" "$1" "$RESET" >&2
}

error() {
    printf "%b%s %b[FAIL]%b %b%s%b\n" "$(get_accent)" "$TREE_MID" "$RED" "$RESET" "$RED" "$1" "$RESET" >&2
}
