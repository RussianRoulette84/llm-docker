#!/bin/bash

# --- ywizz Path (Directory Selection) ---

# Wrapper for ask_tui specifically for paths. $5=continuation, $6=last (optional).
ask_path_tui() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local prefix="${4:-$TREE_TOP}"
    local continuation="${5:-0}"
    local last_q="${6:-0}"
    
    ask_tui "$prompt" "$default" "$var_name" "$prefix" "$continuation" "$last_q"
}
