#!/usr/bin/env bash
# CI only: import the Developer ID certificate into a throwaway keychain.
#
# Required env: P12_BASE64, P12_PASSWORD, KEYCHAIN_PASSWORD, RUNNER_TEMP
# Delete it afterwards with:
#   security delete-keychain "$RUNNER_TEMP/build.keychain-db"

set -euo pipefail

: "${P12_BASE64:?}" "${P12_PASSWORD:?}" "${KEYCHAIN_PASSWORD:?}" "${RUNNER_TEMP:?}"

CERT_PATH="$RUNNER_TEMP/cert.p12"
KEYCHAIN_PATH="$RUNNER_TEMP/build.keychain-db"

echo "$P12_BASE64" | base64 --decode > "$CERT_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERT_PATH" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | tr -d '"')
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
rm "$CERT_PATH"
