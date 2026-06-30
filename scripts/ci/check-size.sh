#!/bin/bash
# check-size.sh — ADVISORY (always exit 0) line-count report for runtime source.
# Sweet spot 200, hard cap 500. Known-pending offenders are annotated so NEW
# growth is visible without blocking the still-open 5C / run-container splits.
# macOS bash 3.2-safe.
set -u
SRC="$(cd "$(dirname "$0")/../../src" && pwd)"
CAP=500
# Files we already know exceed the cap (split is planned / accepted):
KNOWN="cld ocd server.py jobs.py docker_log.sh"

echo "── runtime files over $CAP lines ──"
over=0
# shell launchers + setup modules + install driver/steps + builder-api python
find "$SRC" -type f \( -name '*.sh' -o -name 'cld' -o -name 'ocd' -o -name '*.py' \) \
    ! -path '*/lib/ywizz/*' ! -name 'install_devpack.sh' ! -name 'install_cli.sh' -print0 \
  | while IFS= read -r -d '' f; do
        n=$(wc -l < "$f" | tr -d ' ')
        [ "$n" -le "$CAP" ] && continue
        base="$(basename "$f")"
        tag="NEW — split me"
        for k in $KNOWN; do [ "$base" = "$k" ] && tag="known/pending"; done
        printf '  %4d  %-26s [%s]\n' "$n" "${f#$SRC/}" "$tag"
    done
echo "(advisory only — does not fail CI)"
exit 0
