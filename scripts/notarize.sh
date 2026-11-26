#!/bin/bash
# Notarizes a Developer ID signed .app or .dmg, then staples the ticket to it.
# Usage: scripts/notarize.sh <path>
#
# Environment (App Store Connect team API key):
#   NOTARY_API_KEY_P8_BASE64  content of AuthKey_<id>.p8, base64 encoded
#   NOTARY_API_KEY_ID         key ID
#   NOTARY_API_ISSUER_ID      issuer ID
# With none of the three set, the script does nothing and succeeds.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

TARGET=${1:-}
[ -n "$TARGET" ] && [ -e "$TARGET" ] || die "usage: notarize.sh <path to .app or .dmg>"

key=${NOTARY_API_KEY_P8_BASE64:-}
key_id=${NOTARY_API_KEY_ID:-}
issuer=${NOTARY_API_ISSUER_ID:-}
if [ -z "$key$key_id$issuer" ]; then
    log "Notarization skipped: no notary API key"
    exit 0
fi
[ -n "$key" ] && [ -n "$key_id" ] && [ -n "$issuer" ] ||
    die "set all of NOTARY_API_KEY_P8_BASE64, NOTARY_API_KEY_ID and NOTARY_API_ISSUER_ID, or none"
is_developer_id_signed "$TARGET" ||
    die "$TARGET is not signed with a Developer ID certificate: it cannot be notarized"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(umask 077 && printf '%s' "$key" | base64 --decode >"$work/key.p8")
auth=(--key "$work/key.p8" --key-id "$key_id" --issuer "$issuer")

case "$TARGET" in
    *.app)
        upload="$work/$(basename "$TARGET" .app).zip"
        ditto -c -k --keepParent "$TARGET" "$upload"
        ;;
    *.dmg) upload=$TARGET ;;
    *) die "unsupported file type: $TARGET" ;;
esac

log "Submitting $(basename "$upload") to the notary service"
retry_transient 4 "$NETWORK_ERRORS|abortedUpload" \
    xcrun notarytool submit "$upload" "${auth[@]}" --output-format json >"$work/submit.json" ||
    die "submission failed"
id=$(plutil -extract id raw -o - "$work/submit.json") || die "no submission ID returned"
log "Submission ID: $id"

# A lost connection while waiting does not cancel the submission: wait again for the same ID.
state=unknown
for attempt in 1 2 3 4; do
    xcrun notarytool wait "$id" "${auth[@]}" --timeout 15m >&2 ||
        log "Waiting was interrupted (attempt $attempt/4)"
    if xcrun notarytool info "$id" "${auth[@]}" --output-format json >"$work/info.json"; then
        state=$(plutil -extract status raw -o - "$work/info.json")
    fi
    case "$state" in
        Accepted | Invalid | Rejected) break ;;
    esac
    sleep $((attempt * RETRY_DELAY))
done

if [ "$state" != Accepted ]; then
    xcrun notarytool log "$id" "${auth[@]}" >&2 || true
    die "notarization did not succeed (status: $state, submission: $id)"
fi

# The ticket can take a moment to reach Apple's CDN (stapler error 65 or 68).
log "Stapling $TARGET"
retry_transient 6 "error (65|68)|could not retrieve|CloudKit|$NETWORK_ERRORS" \
    xcrun stapler staple "$TARGET" || die "stapling failed"
xcrun stapler validate "$TARGET"
