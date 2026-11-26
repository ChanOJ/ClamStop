#!/bin/bash
# CI only: writes the SHA-256 of the DMG and publishes the GitHub Release of a tag.
# Safe to run again after a partial failure.
#
# Environment: TAG (e.g. v1.2.3), GH_TOKEN.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

TAG=${TAG:?TAG is required}
VERSION=${TAG#v}
dmg="$APP_NAME-$VERSION.dmg"
[ -f "$DIST/$dmg" ] || die "$DIST/$dmg not found"
cd "$DIST"
shasum -a 256 "$dmg" >"$dmg.sha256"
cat "$dmg.sha256"

# A stapled ticket is the proof that notarization happened.
if xcrun stapler validate "$dmg" >/dev/null 2>&1; then
    notes="Signed with Developer ID and notarized by Apple."
else
    notes="This build is **not notarized**: macOS blocks it at first launch. See \
[how to open it](https://github.com/${GITHUB_REPOSITORY:-ChanOJ/ClamStop}#opening-an-unsigned-build)."
fi
notes="$notes

SHA-256: \`$(cut -d ' ' -f 1 "$dmg.sha256")\`"

flags=()
case "$VERSION" in
    *-*) flags=(--prerelease) ;;
esac

# Create the release, or complete it when an earlier attempt already did.
publish() {
    if gh release view "$TAG" >/dev/null 2>&1; then
        gh release upload "$TAG" "$dmg" "$dmg.sha256" --clobber &&
            gh release edit "$TAG" --draft=false
    else
        gh release create "$TAG" "$dmg" "$dmg.sha256" --verify-tag \
            --title "$APP_NAME $VERSION" --notes "$notes" --generate-notes \
            ${flags[@]+"${flags[@]}"}
    fi
}
retry_transient 4 "$NETWORK_ERRORS|rate limit" publish
