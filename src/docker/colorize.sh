#!/usr/bin/env zsh
# colorize.sh — smooth gradient (blue → light blue → white, top to bottom).
# Used by docker-entrypoint.sh to color the LLM-DOCKER ASCII banner.
#
# Usage:
#   cat art.txt | colorize.sh
#   cat art.txt | colorize.sh -a          # animated (line by line)
#   cat art.txt | colorize.sh -v          # vertical gradient (original behavior)
#   cat art.txt | colorize.sh -s 11 -e 18

ANIMATED=false
VERTICAL=true
GRAD_START=0
GRAD_END=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--animated) ANIMATED=true ;;
        -v|--vertical) VERTICAL=true ;;
        -s|--start)    GRAD_START="$2"; shift ;;
        -e|--end)      GRAD_END="$2";   shift ;;
    esac
    shift
done

RESET=$'\033[0m'

gradient_color() {
    local t=$1        # 0–1000 — 0 = blue (top), 500 = light blue (mid), 1000 = white (bottom)
    local r g b
    if (( t <= 500 )); then
        # blue (30,100,255) → light blue (135,206,250)
        local s=$(( t * 2 ))
        r=$(( 30  + (135 - 30)  * s / 1000 ))
        g=$(( 100 + (206 - 100) * s / 1000 ))
        b=$(( 255 + (250 - 255) * s / 1000 ))
    else
        # light blue (135,206,250) → white (255,255,255)
        local s=$(( (t - 500) * 2 ))
        r=$(( 135 + (255 - 135) * s / 1000 ))
        g=$(( 206 + (255 - 206) * s / 1000 ))
        b=$(( 250 + (255 - 250) * s / 1000 ))
    fi
    printf '\033[38;2;%d;%d;%dm' $r $g $b
}

lines=()
# `|| [[ -n $line ]]` catches a final line without a trailing newline —
# otherwise the last ASCII row gets silently dropped.
while IFS= read -r line || [[ -n $line ]]; do
    lines+=("$line")
done
total=${#lines[@]}
[[ $total -eq 0 ]] && exit 0

if [[ $GRAD_START -gt 0 && $GRAD_END -gt 0 ]]; then
    pin_start=$GRAD_START
    pin_end=$GRAD_END
else
    pin_start=1
    pin_end=$total
fi
pin_range=$(( pin_end - pin_start ))
[[ $pin_range -lt 1 ]] && pin_range=1

if $VERTICAL; then
    for (( row=1; row<=total; row++ )); do
        if (( row < pin_start )); then
            t=0
        elif (( row > pin_end )); then
            t=1000
        else
            t=$(( (row - pin_start) * 1000 / pin_range ))
        fi
        printf "%b%s%b\n" "$(gradient_color $t)" "${lines[$row]}" "$RESET"
        $ANIMATED && sleep 0.04
    done
else
    for (( row=1; row<=total; row++ )); do
        line="${lines[$row]}"
        len=${#line}
        if (( len == 0 )); then
            echo ""
            $ANIMATED && sleep 0.04
            continue
        fi
        out=""
        for (( col=0; col<len; col++ )); do
            t=$(( col * 1000 / (len > 1 ? len - 1 : 1) ))
            char="${line[$((col+1))]}"
            out+="$(gradient_color $t)${char}"
        done
        printf "%s%b\n" "$out" "$RESET"
        $ANIMATED && sleep 0.04
    done
fi