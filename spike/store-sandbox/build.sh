#!/bin/bash
# Builds two ad-hoc signed, sandboxed test bundles into spike/store-sandbox/build/:
#   StoreSpike.app   app-sandbox only (what App Review accepts without discussion)
#   StoreSpikeX.app  app-sandbox + temporary-exception.iokit-user-client-class RootDomainUserClient
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build
swiftc -O -target arm64-apple-macos14 main.swift -o build/StoreSpike-bin
make_app() { # name bundle-id entitlements
  local app="build/$1.app"
  mkdir -p "$app/Contents/MacOS"
  cp build/StoreSpike-bin "$app/Contents/MacOS/StoreSpike"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>StoreSpike</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
  codesign --force --sign - --entitlements "$3" "$app"
  codesign -d --entitlements - "$app" 2>/dev/null | grep -o 'com.apple.security[a-z.-]*' | tr '\n' ' '; echo " <- $1"
}
make_app StoreSpike io.github.chanoj.clamstop.storespike sandbox.entitlements
make_app StoreSpikeX io.github.chanoj.clamstop.storespikex sandbox-exception.entitlements
rm build/StoreSpike-bin
