#!/bin/bash
# Writes dist/appcast.xml, the Sparkle feed announcing one release, with the EdDSA signature
# of its DMG, then signs the feed itself with the same key. The feed is published as an asset of each GitHub Release; the app reads it from
# https://github.com/ChanOJ/ClamStop/releases/latest/download/appcast.xml (SUFeedURL), which
# always points to the newest non-pre-release.
#
# Usage: scripts/make-appcast.sh [path/to/ClamStop-x.y.z.dmg]
# Environment:
#   SPARKLE_ED_PRIVATE_KEY  private EdDSA key (as printed by Sparkle's `generate_keys -x`);
#                           without it the script writes nothing and exits 0 (updates off)
#   DOWNLOAD_URL            URL of the DMG (default: the GitHub Release asset of the version)
#   APPCAST_ANY_SIGNATURE=1 local tests only: also write the feed for an app that is not
#                           Developer ID signed (see below)

set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

APP="$DIST/$APP_NAME.app"
info="$APP/Contents/Info.plist"
[ -f "$info" ] || die "$APP not found (run scripts/build-app.sh first)"
short_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info")
VERSION=${VERSION:-$short_version}
VERSION=${VERSION#v}
dmg=${1:-$DIST/$APP_NAME-$VERSION.dmg}
[ -f "$dmg" ] || die "$dmg not found (run scripts/make-dmg.sh first)"

if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    echo "::warning::SPARKLE_ED_PRIVATE_KEY is not set: no appcast, the app will not see this release as an update (see docs/updates.md)."
    exit 0
fi
# Sparkle only installs an update whose code signature satisfies the installed app's designated
# requirement. An ad-hoc requirement is the exact cdhash of that build, so ad-hoc builds can
# never update each other: announcing them would only show users an error.
if ! is_developer_id_signed "$APP" && [ "${APPCAST_ANY_SIGNATURE:-}" != 1 ]; then
    echo "::warning::The app is not signed with Developer ID: no appcast (Sparkle cannot update ad-hoc builds, see docs/updates.md)."
    exit 0
fi
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$info" >/dev/null 2>&1 ||
    die "the app has no SUPublicEDKey (Resources/sparkle-public-ed-key.txt): it would refuse this update"

sign_update="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$sign_update" ] || swift package resolve >/dev/null
[ -x "$sign_update" ] || die "$sign_update not found"

repo=${GITHUB_REPOSITORY:-ChanOJ/ClamStop}
url=${DOWNLOAD_URL:-https://github.com/$repo/releases/download/v$VERSION/$(basename "$dmg")}
# The private key must match the public key built into the app, or the app refuses the update.
public_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$info")
derived=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | swift "$ROOT/scripts/sparkle-key.swift" public) ||
    die "SPARKLE_ED_PRIVATE_KEY is not a Sparkle EdDSA private key"
[ "$derived" = "$public_key" ] ||
    die "SPARKLE_ED_PRIVATE_KEY does not match SUPublicEDKey ($public_key)"
# Prints: sparkle:edSignature="…" length="…"
attributes=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$dmg")
[[ $attributes == *edSignature=*length=* ]] || die "sign_update failed: $attributes"

pub_date=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
cat >"$DIST/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <link>https://github.com/$repo</link>
    <item>
      <title>$APP_NAME $VERSION</title>
      <pubDate>$pub_date</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$short_version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$repo/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<p>What's new: <a href="https://github.com/$repo/releases/tag/v$VERSION">release notes on GitHub</a>.</p>]]></description>
      <enclosure url="$url" type="application/octet-stream" $attributes />
    </item>
  </channel>
</rss>
EOF
# The app requires a signed feed (SURequireSignedFeed): sign_update writes the signature into
# the file, so nothing may change it afterwards.
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$DIST/appcast.xml" >/dev/null ||
    die "could not sign appcast.xml"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sign_update" --verify --ed-key-file - "$DIST/appcast.xml" ||
    die "the signature of appcast.xml does not verify"
xmllint --noout "$DIST/appcast.xml"
log "Wrote $DIST/appcast.xml ($short_version, build $build, public key ${public_key:0:8}…)"
