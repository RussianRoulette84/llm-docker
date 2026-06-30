#!/bin/bash
# no-rm.sh — fail if a runtime shell script uses a bare `rm`.
#
# After the ~/Projects wipe incident, deletes must go through `trash`
# (recoverable) or the in-container rm-guard. The only allowed literal removals
# are:
#   * `/bin/rm`   — explicit, intentional system delete (audited at the call site)
#   * `docker rm` — container lifecycle, not files
#   * `--rm`      — the `docker run --rm` flag
#
# Build-time image layers (install_devpack.sh, install_cli.sh, Dockerfile) and
# the shim itself (rm-guard.sh) are exempt — they run during image build / ARE
# the real rm. Runs on macOS bash 3.2 (no mapfile).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)/src"

violations="$(
  find "$ROOT" -type f \( -name '*.sh' -o -name 'cld' -o -name 'ocd' \) \
    ! -name 'rm-guard.sh' ! -name 'install_devpack.sh' ! -name 'install_cli.sh' -print0 \
  | while IFS= read -r -d '' f; do
      grep -HnE '(^|[^-/[:alnum:]])rm([[:space:]]|$)' "$f" 2>/dev/null
    done \
  | grep -vE 'docker rm|/bin/rm|--rm|trash' \
  | grep -vE ':[0-9]+:[[:space:]]*#'
)"

if [ -n "$violations" ]; then
  printf '%s\n' "$violations" >&2
  echo "" >&2
  echo "ERROR: bare 'rm' found above. Use 'trash' (recoverable) or '/bin/rm' (explicit)." >&2
  exit 1
fi
echo "no-rm: clean ✓ — no bare rm in runtime shell scripts"
