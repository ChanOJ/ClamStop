# shellcheck shell=bash
# Shared by the packaging scripts; source it, do not run it.
# Compatible with the bash 3.2 shipped with macOS.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIST="$ROOT/dist"
APP_NAME=ClamStop
DAEMON_NAME=ClamStopDaemon
MIN_MACOS=14.0

# Base delay between two attempts of retry_transient, in seconds.
RETRY_DELAY=${RETRY_DELAY:-10}

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Reads one identifier from Identifiers.swift, the single source of truth.
identifier() {
    local value
    value=$(sed -n "s/.*static let $1 = \"\([^\"]*\)\".*/\1/p" \
        "$ROOT/Sources/ClamStopShared/Identifiers.swift")
    [ -n "$value" ] || die "identifier $1 not found in Identifiers.swift"
    printf '%s\n' "$value"
}

# True when SIGN_IDENTITY names a real certificate (otherwise: ad-hoc signature).
has_signing_identity() {
    [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]
}

# True when the file or bundle carries a Developer ID signature.
is_developer_id_signed() {
    local details
    details=$(codesign --display --verbose=2 "$1" 2>&1) || return 1
    case "$details" in
        *"Authority=Developer ID Application"*) return 0 ;;
        *) return 1 ;;
    esac
}

# retry_transient <attempts> <regex> <command...>
# Retries only when the command fails AND its output matches the regex (network hiccup,
# busy disk...). Any other failure is reported at once.
retry_transient() {
    local attempts=$1 pattern=$2
    shift 2
    local attempt=1 status out err
    out=$(mktemp)
    err=$(mktemp)
    while true; do
        status=0
        "$@" >"$out" 2>"$err" || status=$?
        if [ "$status" -eq 0 ] || [ "$attempt" -ge "$attempts" ] ||
            ! grep -Eqi -- "$pattern" "$out" "$err"; then
            cat "$out"
            cat "$err" >&2
            rm -f "$out" "$err"
            return "$status"
        fi
        cat "$out" "$err" >&2
        log "Transient failure (attempt $attempt/$attempts), retrying in $((attempt * RETRY_DELAY)) s"
        sleep $((attempt * RETRY_DELAY))
        attempt=$((attempt + 1))
    done
}

NETWORK_ERRORS='timed? ?out|could not connect|connection (was )?(lost|reset|refused|closed)|network|offline|NSURLErrorDomain|internal ?server ?error|service (is )?(temporarily )?unavailable|HTTP( status code:)? ?5[0-9][0-9]|TLS handshake|EOF'

# sign <path> [codesign options...]
# Developer ID (hardened runtime, secure timestamp) when SIGN_IDENTITY is set, else ad-hoc.
sign() {
    local target=$1
    shift
    if has_signing_identity; then
        retry_transient 5 "timestamp|$NETWORK_ERRORS" \
            codesign --force --sign "$SIGN_IDENTITY" --timestamp "$@" "$target"
    else
        codesign --force --sign - "$@" "$target"
    fi
}
