#!/bin/bash
# Renders the UI mockups (Sources/ClamStop/Mockups) to PNG files and a contact sheet:
# tmp/mockups/index.html. Open it once in a browser, then refresh after each run.
# Debug build, no app bundle, no background service: mock data only.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

OUT="$ROOT/tmp/mockups"
swift build --product ClamStop
BIN=$(swift build --show-bin-path)
rm -rf "$OUT"
"$BIN/ClamStop" --mockups "$OUT" --icon "$ROOT/Resources/AppIcon.icns"
log "Contact sheet: $OUT/index.html"
