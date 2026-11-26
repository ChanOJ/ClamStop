#!/bin/bash
# Builds the universal (arm64 + x86_64) ClamStop.app into dist/ and signs it.
# Works with the Command Line Tools alone; Xcode is not required.
#
# Optional environment:
#   VERSION        marketing version, e.g. 1.2.3 or 1.2.3-rc.1 (default: latest v* tag, else 0.0.0)
#   BUILD_NUMBER   CFBundleVersion (default: number of commits)
#   SIGN_IDENTITY  "Developer ID Application" certificate name or SHA-1 (default: ad-hoc)

set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

if [ -z "${VERSION:-}" ]; then
    VERSION=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo 0.0.0)
fi
VERSION=${VERSION#v}
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] ||
    die "invalid VERSION '$VERSION' (expected x.y.z or x.y.z-suffix)"
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
[[ $BUILD_NUMBER =~ ^[0-9]+$ ]] || die "invalid BUILD_NUMBER '$BUILD_NUMBER'"

APP_ID=$(identifier appBundleID)
DAEMON_ID=$(identifier daemonLabel)
DAEMON_PLIST=$(identifier daemonPlistName)

build_flags=(-c release --arch arm64 --arch x86_64)
log "Building $APP_NAME $VERSION ($BUILD_NUMBER), arm64 + x86_64"
swift build "${build_flags[@]}"
BIN=$(swift build "${build_flags[@]}" --show-bin-path)

APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Library/LaunchDaemons"

SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
for name in "$APP_NAME" "$DAEMON_NAME"; do
    binary="$CONTENTS/MacOS/$name"
    cp "$BIN/$name" "$binary"
    # Some Command Line Tools releases record the deployment target as the SDK version, which
    # makes macOS run the app in compatibility mode (old look). Restore the real SDK version.
    recorded=$(vtool -show-build "$binary" | awk '$1 == "sdk" { print $2 }' | sort -u)
    if [ "$recorded" = "$MIN_MACOS" ] && [ "$SDK_VERSION" != "$MIN_MACOS" ]; then
        log "Setting the SDK version of $name to $SDK_VERSION"
        vtool -set-build-version macos "$MIN_MACOS" "$SDK_VERSION" -replace \
            -output "$binary.tmp" "$binary"
        mv "$binary.tmp" "$binary"
        chmod 755 "$binary"
    fi
done

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/$DAEMON_PLIST" "$CONTENTS/Library/LaunchDaemons/$DAEMON_PLIST"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
# Images shown in the app (also used by README.md).
cp "$ROOT"/Resources/Images/*.png "$CONTENTS/Resources/"
printf 'APPL????' >"$CONTENTS/PkgInfo"

# Localizations of the main bundle (app strings, then packaging ones such as
# InfoPlist.strings), then any SwiftPM resource bundle, which Bundle.module looks up in
# Contents/Resources.
shopt -s nullglob
for lproj in "$ROOT/Sources/$APP_NAME/Localization"/*.lproj "$ROOT"/Resources/*.lproj; do
    ditto "$lproj" "$CONTENTS/Resources/$(basename "$lproj")"
done
for bundle in "$BIN"/*.bundle; do
    log "Adding resource bundle $(basename "$bundle")"
    cp -R "$bundle" "$CONTENTS/Resources/"
done
shopt -u nullglob

plist="$CONTENTS/Info.plist"
# CFBundleShortVersionString only accepts numbers: drop any pre-release suffix.
plutil -replace CFBundleShortVersionString -string "${VERSION%%-*}" "$plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$plist"
# Without this list, macOS keeps the resource bundles in the development language.
languages=$(find "$CONTENTS/Resources" -type d -name '*.lproj' ! -name 'Base.lproj' \
    -exec basename {} .lproj \; | sort -u)
if [ -n "$languages" ]; then
    json=$(printf '%s\n' "$languages" | sed 's/.*/"&"/' | paste -sd, -)
    plutil -replace CFBundleLocalizations -json "[$json]" "$plist"
fi

# Extended attributes (quarantine, Finder info) break code signatures.
xattr -cr "$APP"

if has_signing_identity; then
    log "Signing with Developer ID"
    options=(--options runtime)
else
    log "Signing ad-hoc (SIGN_IDENTITY not set)"
    options=()
fi
# Inside out: the daemon first, then the bundle (which signs the app executable).
sign "$CONTENTS/MacOS/$DAEMON_NAME" --identifier "$DAEMON_ID" ${options[@]+"${options[@]}"}
sign "$APP" --identifier "$APP_ID" ${options[@]+"${options[@]}"}

log "Built $APP"
