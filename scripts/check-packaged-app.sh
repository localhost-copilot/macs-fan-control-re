#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
staging=$(mktemp -d "${TMPDIR:-/tmp}/mfc-check.XXXXXX")
cleanup() {
    if [[ -d "$staging/build" ]]; then mv "$staging/build" .build; fi
    rm -rf "$staging"
}
trap cleanup EXIT
ditto "dist/Macs Fan Control.app" "$staging/Macs Fan Control.app"
# A release must work without SwiftPM's build-time resource fallback.
if [[ -d .build ]]; then mv .build "$staging/build"; fi
for executable in FanControl FanHelper; do
    "$staging/Macs Fan Control.app/Contents/MacOS/$executable" --check-resources
done
