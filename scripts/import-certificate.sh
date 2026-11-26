#!/bin/bash
# CI only: imports the Developer ID certificate into a temporary keychain and exports
# SIGN_IDENTITY and SIGN_KEYCHAIN to the following GitHub Actions steps.
#
# Environment:
#   MACOS_CERTIFICATE_P12_BASE64  .p12 export of the certificate and its key, base64 encoded
#   MACOS_CERTIFICATE_PASSWORD    password of that .p12
# With none of the two set, the script does nothing and succeeds (ad-hoc build).

set -euo pipefail
source "$(dirname "$0")/lib.sh"

certificate=${MACOS_CERTIFICATE_P12_BASE64:-}
password=${MACOS_CERTIFICATE_PASSWORD:-}
if [ -z "$certificate$password" ]; then
    log "No signing certificate: the build will be signed ad-hoc"
    exit 0
fi
[ -n "$certificate" ] && [ -n "$password" ] ||
    die "set both MACOS_CERTIFICATE_P12_BASE64 and MACOS_CERTIFICATE_PASSWORD, or none"
# This changes the keychain search list: never run it on a personal Mac.
[ -n "${GITHUB_ENV:-}" ] && [ -n "${RUNNER_TEMP:-}" ] || die "meant for GitHub Actions only"

keychain="$RUNNER_TEMP/clamstop-signing.keychain-db"
keychain_password=$(openssl rand -hex 24)
p12="$RUNNER_TEMP/clamstop-certificate.p12"
trap 'rm -f "$p12"' EXIT
(umask 077 && printf '%s' "$certificate" | base64 --decode >"$p12")

echo "SIGN_KEYCHAIN=$keychain" >>"$GITHUB_ENV"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$p12" -k "$keychain" -P "$password" -f pkcs12 -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$keychain_password" "$keychain" >/dev/null
# Prepend to the search list, keeping the existing keychains.
existing=()
while IFS= read -r line; do
    line=${line#*\"}
    existing+=("${line%\"*}")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" ${existing[@]+"${existing[@]}"}

identity=$(security find-identity -v -p codesigning "$keychain" |
    awk '/"Developer ID Application: / { print $2; exit }')
[ -n "$identity" ] ||
    die "no valid 'Developer ID Application' identity in the .p12 (see docs/signing.md)"
echo "SIGN_IDENTITY=$identity" >>"$GITHUB_ENV"
log "Developer ID certificate imported"
