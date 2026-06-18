#!/usr/bin/env bash
# End-to-end build: PyInstaller → codesign → notarize → staple → .dmg.
#
# Required env vars (set in your shell or a .env you source):
#   DEVELOPER_ID         e.g. "Developer ID Application: Alin Banuta (TEAMID12345)"
#   APPLE_ID             your Apple developer account email
#   APPLE_TEAM_ID        10-char team ID
#   APPLE_APP_PASSWORD   app-specific password from appleid.apple.com
#
# Run from the repo root:
#   scripts/build_dmg.sh

set -euo pipefail

cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?DEVELOPER_ID env var required}"
: "${APPLE_ID:?APPLE_ID env var required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID env var required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD env var required}"

APP_NAME="Keepers"
APP_BUNDLE="dist/${APP_NAME}.app"
VERSION="$(cat VERSION | tr -d '[:space:]')"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
PY="${PY:-./venv/bin/python}"

echo "==> 1/5 Cleaning prior build"
rm -rf build dist

echo "==> 2/5 Running PyInstaller"
"$PY" -m PyInstaller Keepers.spec --clean --noconfirm

echo "==> 3/5 Code signing with hardened runtime"
codesign --deep --force --options runtime \
    --entitlements Entitlements.plist \
    --sign "${DEVELOPER_ID}" \
    "${APP_BUNDLE}"
codesign --verify --deep --strict --verbose=4 "${APP_BUNDLE}"

echo "==> 4/5 Notarizing (will block until Apple responds)"
NOTARY_ZIP="dist/${APP_NAME}.zip"
NOTARY_LOG="dist/notary-submit.log"
ditto -c -k --keepParent "${APP_BUNDLE}" "${NOTARY_ZIP}"

set +e
xcrun notarytool submit "${NOTARY_ZIP}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_PASSWORD}" \
    --wait 2>&1 | tee "${NOTARY_LOG}"
NOTARY_EXIT=${PIPESTATUS[0]}
set -e

# Whether Apple accepted or rejected, fetch the detailed log so we can
# diagnose issues. notarytool prints "id: <uuid>" near the top of its output.
SUBMISSION_ID=$(grep -E '^[[:space:]]*id:' "${NOTARY_LOG}" | head -1 | awk '{print $2}')
if [[ -n "${SUBMISSION_ID}" ]]; then
    echo "==> Fetching Apple's notarization log for ${SUBMISSION_ID}"
    xcrun notarytool log "${SUBMISSION_ID}" \
        --apple-id "${APPLE_ID}" \
        --team-id "${APPLE_TEAM_ID}" \
        --password "${APPLE_APP_PASSWORD}" || true
fi

if [[ ${NOTARY_EXIT} -ne 0 ]]; then
    echo "Notarization failed with exit code ${NOTARY_EXIT}" >&2
    exit ${NOTARY_EXIT}
fi

xcrun stapler staple "${APP_BUNDLE}"
rm -f "${NOTARY_ZIP}" "${NOTARY_LOG}"

echo "==> 5/5 Building .dmg"
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg not installed. Install with: brew install create-dmg"
    exit 1
fi
rm -f "dist/${DMG_NAME}"
create-dmg \
    --volname "${APP_NAME}" \
    --window-size 600 400 \
    --icon-size 100 \
    --app-drop-link 450 200 \
    "dist/${DMG_NAME}" \
    "${APP_BUNDLE}"

codesign --force --sign "${DEVELOPER_ID}" "dist/${DMG_NAME}"
xcrun stapler staple "dist/${DMG_NAME}"

echo ""
echo "Done. Artifact: dist/${DMG_NAME}"
echo "Verify with: spctl --assess --type open --context context:primary-signature dist/${DMG_NAME}"
