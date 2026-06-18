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

echo "==> 4/5 Notarizing"
NOTARY_ZIP="dist/${APP_NAME}.zip"
ditto -c -k --keepParent "${APP_BUNDLE}" "${NOTARY_ZIP}"

# Submit without --wait so we get the submission ID immediately and can poll
# on our own schedule. notarytool's built-in --wait stops printing intermediate
# state after a while and proved unreliable on long submissions in CI.
echo "==> Submitting to Apple"
SUBMIT_OUT="$(xcrun notarytool submit "${NOTARY_ZIP}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_PASSWORD}" \
    --output-format json)"
echo "${SUBMIT_OUT}"
SUBMISSION_ID="$(echo "${SUBMIT_OUT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
echo "Submission ID: ${SUBMISSION_ID}"

# Apple takes 1-3 hours per submission on this account, in practice. Cap at 4h
# and exponentially back off polling so we don't hammer the API.
NOTARY_TIMEOUT_SECONDS="${NOTARY_TIMEOUT_SECONDS:-14400}"
DEADLINE=$(($(date +%s) + NOTARY_TIMEOUT_SECONDS))
SLEEP=30
echo "==> Polling notarytool info (timeout in ${NOTARY_TIMEOUT_SECONDS}s)"
while true; do
    if [[ "$(date +%s)" -gt "${DEADLINE}" ]]; then
        echo "Notarization timed out. Submission ${SUBMISSION_ID} is still pending." >&2
        echo "Use the notary-status workflow to check it later." >&2
        exit 1
    fi
    INFO_JSON="$(xcrun notarytool info "${SUBMISSION_ID}" \
        --apple-id "${APPLE_ID}" \
        --team-id "${APPLE_TEAM_ID}" \
        --password "${APPLE_APP_PASSWORD}" \
        --output-format json 2>/dev/null || echo '{}')"
    STATUS="$(echo "${INFO_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "?")"
    echo "  $(date -u +%H:%M:%SZ) status=${STATUS}"
    case "${STATUS}" in
        Accepted) break ;;
        Invalid|Rejected)
            echo "==> Fetching Apple's notarization log"
            xcrun notarytool log "${SUBMISSION_ID}" \
                --apple-id "${APPLE_ID}" \
                --team-id "${APPLE_TEAM_ID}" \
                --password "${APPLE_APP_PASSWORD}" || true
            exit 1
            ;;
        *)
            sleep "${SLEEP}"
            # Back off: 30s -> 60s -> 120s -> ... cap at 5 min.
            SLEEP=$((SLEEP < 300 ? SLEEP * 2 : 300))
            ;;
    esac
done

xcrun stapler staple "${APP_BUNDLE}"
rm -f "${NOTARY_ZIP}"

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
