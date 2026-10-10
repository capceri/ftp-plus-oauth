#!/bin/bash
# GitHub Actions only: imports the Developer ID certificate from secrets into a temporary keychain
# and exports SIGN_IDENTITY for later steps.
#   env: MACOS_CERTIFICATE_P12 (base64 of the .p12), MACOS_CERTIFICATE_PASSWORD
set -euo pipefail

if [[ -z "${MACOS_CERTIFICATE_P12:-}" ]]; then
    echo "::error::The MACOS_CERTIFICATE_P12 secret isn't set. See fit-studio/RELEASING.md."
    exit 1
fi

KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
CERT="$RUNNER_TEMP/certificate.p12"

printf '%s' "$MACOS_CERTIFICATE_P12" | base64 --decode > "$CERT"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERT" -k "$KEYCHAIN" -P "${MACOS_CERTIFICATE_PASSWORD:-}" -f pkcs12 -A -T /usr/bin/codesign
rm -f "$CERT"

# Apple's Developer ID intermediate certificates, so codesign can build the full chain.
for ca in DeveloperIDG2CA.cer DeveloperIDCA.cer; do
    curl -fsSL "https://www.apple.com/certificateauthority/$ca" -o "$RUNNER_TEMP/$ca"
    security import "$RUNNER_TEMP/$ca" -k "$KEYCHAIN" >/dev/null 2>&1 || true
done

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# Put the temporary keychain first in the search list (keeping the existing ones).
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
if [[ -z "$IDENTITY" ]]; then
    echo "::error::No \"Developer ID Application\" identity in the certificate. Export that certificate (with its private key) as the .p12."
    security find-identity -v -p codesigning "$KEYCHAIN"
    exit 1
fi
echo "Signing as: $IDENTITY"
echo "SIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
echo "SIGNING_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"
