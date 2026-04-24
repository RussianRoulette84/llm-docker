#!/bin/bash

# --- ywizz: Modular TUI Library for Shell Scripts ---
# This loader pulls in all ywizz components. 
YWIZZ_DIR="$(dirname "${BASH_SOURCE[0]}")"

# 1. Base Logic & Theme
source "$YWIZZ_DIR/core.sh"

# 2. Interaction Components
source "$YWIZZ_DIR/header.sh"
source "$YWIZZ_DIR/confirm.sh"
source "$YWIZZ_DIR/select.sh"
source "$YWIZZ_DIR/checklist.sh"
source "$YWIZZ_DIR/input.sh"
source "$YWIZZ_DIR/path.sh"

# 3. Visual & Status Components
source "$YWIZZ_DIR/ascii.sh"
source "$YWIZZ_DIR/info.sh"
source "$YWIZZ_DIR/banner.sh"
source "$YWIZZ_DIR/security.sh"
source "$YWIZZ_DIR/progress_bar.sh"
source "$YWIZZ_DIR/task.sh"

# 4. Unified dispatcher
source "$YWIZZ_DIR/show.sh"
