#!/bin/bash
# Packs dist/ClamStop.app and an Applications link into dist/ClamStop-<version>.dmg.
# Prints the DMG path on standard output.
#
# Optional environment:
#   VERSION        used in the file name (default: the version of the app)
#   SIGN_IDENTITY  signs the DMG with this Developer ID certificate

set -euo pipefail
source "$(dirname "$0")/lib.sh"

APP="$DIST/$APP_NAME.app"
[ -d "$APP" ] || die "$APP not found (run scripts/build-app.sh first)"
if [ -z "${VERSION:-}" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP/Contents/Info.plist")
fi
VERSION=${VERSION#v}
DMG="$DIST/$APP_NAME-$VERSION.dmg"

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$APP" "$staging/$APP_NAME.app"
ln -s /Applications "$staging/Applications"

log "Creating $DMG"
# "Resource busy" happens now and then on CI runners.
retry_transient 5 'resource busy|resource temporarily unavailable' \
    hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -fs HFS+ -format UDZO \
    -ov "$DMG" >&2

if has_signing_identity; then
    log "Signing the DMG"
    sign "$DMG" >&2
fi
hdiutil verify -quiet "$DMG"

echo "$DMG"
