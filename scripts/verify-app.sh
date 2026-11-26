#!/bin/bash
# Checks that an assembled ClamStop.app follows the bundle contract (see CLAUDE.md).
# Usage: scripts/verify-app.sh [path/to/ClamStop.app]

set -euo pipefail
source "$(dirname "$0")/lib.sh"

APP=${1:-$DIST/$APP_NAME.app}
CONTENTS="$APP/Contents"
[ -d "$APP" ] || die "$APP not found (run scripts/build-app.sh first)"

APP_ID=$(identifier appBundleID)
DAEMON_ID=$(identifier daemonLabel)
DAEMON_PLIST=$(identifier daemonPlistName)
MACH_SERVICE=$(identifier machServiceName)

# expect <plist> <key path> <value>
expect() {
    local actual
    actual=$(/usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null) ||
        die "$1: missing key $2"
    [ "$actual" = "$3" ] || die "$1: $2 is '$actual', expected '$3'"
}

info="$CONTENTS/Info.plist"
daemon="$CONTENTS/Library/LaunchDaemons/$DAEMON_PLIST"

log "Property lists"
plutil -lint "$info" "$daemon"
expect "$info" CFBundleIdentifier "$APP_ID"
expect "$info" CFBundleExecutable "$APP_NAME"
expect "$info" LSUIElement true
expect "$info" LSMinimumSystemVersion "$MIN_MACOS"
expect "$daemon" Label "$DAEMON_ID"
expect "$daemon" BundleProgram "Contents/MacOS/$DAEMON_NAME"
expect "$daemon" "MachServices:$MACH_SERVICE" true
expect "$daemon" AssociatedBundleIdentifiers:0 "$APP_ID"
[ -f "$CONTENTS/Resources/AppIcon.icns" ] || die "missing AppIcon.icns"
plutil -lint -s "$CONTENTS/Resources/PrivacyInfo.xcprivacy" || die "missing or invalid PrivacyInfo.xcprivacy"

log "Localizations"
for lproj in "$ROOT/Sources/$APP_NAME/Localization"/*.lproj "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    for source in "$lproj"/*; do
        [ -f "$source" ] || continue
        packaged="$CONTENTS/Resources/$(basename "$lproj")/$(basename "$source")"
        [ -f "$packaged" ] || die "missing $packaged"
        plutil -lint -s "$packaged" || die "invalid localization file $packaged"
    done
done

log "Executables"
for name in "$APP_NAME" "$DAEMON_NAME"; do
    binary="$CONTENTS/MacOS/$name"
    [ -x "$binary" ] || die "missing executable $binary"
    for arch in arm64 x86_64; do
        lipo "$binary" -verify_arch "$arch" || die "$name: missing $arch slice"
        minos=$(vtool -arch "$arch" -show-build "$binary" | awk '$1 == "minos" { print $2 }')
        [ "$minos" = "$MIN_MACOS" ] ||
            die "$name ($arch): deployment target '$minos', expected $MIN_MACOS"
    done
    echo "$name: $(lipo -archs "$binary"), macOS $MIN_MACOS+"
done

log "Signatures"
codesign --verify --deep --strict --verbose=2 "$APP"
daemon_details=$(codesign --display --verbose=2 "$CONTENTS/MacOS/$DAEMON_NAME" 2>&1)
grep -qx "Identifier=$DAEMON_ID" <<<"$daemon_details" ||
    die "daemon signed with the wrong identifier"
if is_developer_id_signed "$APP"; then
    for target in "$APP" "$CONTENTS/MacOS/$DAEMON_NAME"; do
        details=$(codesign --display --verbose=2 "$target" 2>&1)
        grep -q 'flags=.*runtime' <<<"$details" || die "$target: hardened runtime missing"
        grep -q '^Timestamp=' <<<"$details" || die "$target: secure timestamp missing"
    done
    echo "Developer ID signature, hardened runtime, secure timestamp"
else
    echo "Ad-hoc signature (not notarizable)"
fi

log "$APP is valid"
