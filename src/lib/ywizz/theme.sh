#!/bin/bash

# --- TUI Theme for Clawfather ---

# Base Palette (use $'...' so \033 is the ESC character, not literal \033)
C1=$'\033[38;5;33m'   # Blue
C2=$'\033[38;5;39m'   # Blue
C3=$'\033[38;5;45m'  # Cyan
C4=$'\033[38;5;81m'  # Light Cyan
C5=$'\033[38;5;117m' # Sky Blue
C6=$'\033[38;5;147m' # Light Purple
C7=$'\033[38;5;177m' # Purple
C8=$'\033[38;5;213m' # Pink
C9=$'\033[38;5;201m' # Magenta
NC=$'\033[0m'
BOLD=$'\033[1m'
NORMAL=$'\033[22m'   # Normal intensity (no bold)
DIM=$'\033[2m'
RESET=$'\033[0m'
BLUE="$C2"
GREEN=$'\033[32m'
RED=$'\033[31m'
YELLOW=$'\033[33m'
CYAN=$'\033[36m'
ORANGE=$'\033[38;5;208m'
