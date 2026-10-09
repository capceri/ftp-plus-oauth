#!/bin/bash
# Builds a signed, notarized and stapled "Dual Recorder" DMG, ready to share.
#
#   scripts/release.sh 1.2.0
#
# Needs full Xcode, a "Developer ID Application" certificate in the keychain, and notarization
# credentials in one of these forms (see RELEASING.md):
#   NOTARY_PROFILE=name                         a profile saved with `xcrun notarytool store-credentials`
#   APPLE_ID, APPLE_APP_PASSWORD [, APPLE_TEAM_ID]  Apple ID with an app-specific password
#   NOTARY_API_KEY (contents of the .p8), NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID
# SIGN_IDENTITY selects the certificate; by default the first Developer ID Application one is used.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${VERSION:-}}"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "Usage: scripts/release.sh VERSION   (e.g. 1.2.0)" >&2
    exit 1
fi

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "No \"Developer ID Application\" certificate found in the keychain. See RELEASING.md." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NOTARY_AUTH=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_API_KEY:-}" ]]; then
    printf '%s\n' "$NOTARY_API_KEY" > "$WORK/AuthKey.p8"
    NOTARY_AUTH=(--key "$WORK/AuthKey.p8" --key-id "${NOTARY_API_KEY_ID:?}" --issuer "${NOTARY_API_ISSUER_ID:?}")
elif [[ -n "${APPLE_ID:-}" ]]; then
    # The team ID defaults to the one in brackets at the end of the certificate name.
    TEAM_ID="${APPLE_TEAM_ID:-$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$SIGN_IDENTITY")}"
    NOTARY_AUTH=(--apple-id "$APPLE_ID" --password "${APPLE_APP_PASSWORD:?}" --team-id "${TEAM_ID:?Set APPLE_TEAM_ID}")
else
    echo "No notarization credentials. Set NOTARY_PROFILE, APPLE_ID/APPLE_APP_PASSWORD/APPLE_TEAM_ID or NOTARY_API_KEY/… (see RELEASING.md)." >&2
    exit 1
fi

# Uploads a file to Apple's notary service, waits for the verdict and prints the log if rejected.
notarize() {
    local file="$1"
    echo "▸ Notarizing $(basename "$file") (usually a few minutes)…"
    xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --output-format json > "$WORK/notary.json" || true
    local status id
    status="$(plutil -extract status raw -o - "$WORK/notary.json" 2>/dev/null || echo "unknown")"
    id="$(plutil -extract id raw -o - "$WORK/notary.json" 2>/dev/null || echo "")"
    if [[ "$status" != "Accepted" ]]; then
        echo "Notarization failed (status: $status)." >&2
        cat "$WORK/notary.json" >&2 || true
        [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
        exit 1
    fi
    echo "  Accepted ($id)"
}

APP="build/Dual Recorder.app"
DMG="build/Dual-Recorder-$VERSION.dmg"

UNIVERSAL=1 VERSION="$VERSION" BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}" SIGN_IDENTITY="$SIGN_IDENTITY" \
    ./build.sh --no-install
echo "  Architectures: $(lipo -archs "$APP/Contents/MacOS/DualRecorder")"

# Notarize the app itself and staple the ticket to it, so it also opens cleanly when offline.
ditto -c -k --keepParent "$APP" "$WORK/app.zip"
notarize "$WORK/app.zip"
xcrun stapler staple "$APP"

scripts/make_dmg.sh "$APP" "$DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "▸ Checking with Gatekeeper…"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"
xcrun stapler validate "$DMG"

echo "✓ $DMG is signed, notarized and ready to share."
