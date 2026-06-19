#!/usr/bin/env bash
# Build and code-sign Keepers.app. Stops short of notarization.
#
# Required env:
#   DEVELOPER_ID         e.g. "Developer ID Application: Alin Banuta (TEAMID12345)"
# Optional env:
#   PY                   python interpreter (default: ./venv/bin/python)
#
# Output: dist/Keepers.app (signed, hardened runtime).

set -euo pipefail

cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?DEVELOPER_ID env var required}"

APP_NAME="Keepers"
APP_BUNDLE="dist/${APP_NAME}.app"
PY="${PY:-./venv/bin/python}"

echo "==> 1/3 Cleaning prior build"
rm -rf build dist

echo "==> 2/3 Running PyInstaller"
"$PY" -m PyInstaller Keepers.spec --clean --noconfirm

echo "==> 3/3 Code signing with hardened runtime"
codesign --deep --force --options runtime \
    --entitlements Entitlements.plist \
    --sign "${DEVELOPER_ID}" \
    "${APP_BUNDLE}"
codesign --verify --deep --strict --verbose=4 "${APP_BUNDLE}"

echo ""
echo "Signed bundle ready: ${APP_BUNDLE}"
