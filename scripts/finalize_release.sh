#!/usr/bin/env bash
# Given an already-signed dist/Keepers.app and a notarization submission ID:
# poll Apple until the verdict, staple the ticket, build the .dmg, sign it,
# staple the .dmg.
#
# Required env:
#   SUBMISSION_ID
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#   DEVELOPER_ID
# Optional env:
#   NOTARY_TIMEOUT_SECONDS   default 3600 (1h). Bump for the all-in-one local flow.
#
# Output: dist/Keepers-<version>.dmg, signed + stapled.

set -euo pipefail

cd "$(dirname "$0")/.."

: "${SUBMISSION_ID:?SUBMISSION_ID env var required}"
: "${APPLE_ID:?APPLE_ID env var required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID env var required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD env var required}"
: "${DEVELOPER_ID:?DEVELOPER_ID env var required}"

APP_NAME="Keepers"
APP_BUNDLE="dist/${APP_NAME}.app"
# Honor an externally-set VERSION (e.g. from the finalize workflow when main
# has moved past the release tag). Fall back to the in-tree VERSION file.
VERSION="${VERSION:-$(cat VERSION | tr -d '[:space:]')}"
# ARCH suffixes the .dmg name (e.g. Keepers-1.3.2-arm64.dmg). Empty for
# the single-arch local case.
ARCH="${ARCH:-}"
DMG_NAME="${APP_NAME}-${VERSION}${ARCH:+-${ARCH}}.dmg"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "Missing ${APP_BUNDLE}. Restore the signed bundle before finalizing." >&2
    exit 1
fi

NOTARY_TIMEOUT_SECONDS="${NOTARY_TIMEOUT_SECONDS:-3600}"
DEADLINE=$(($(date +%s) + NOTARY_TIMEOUT_SECONDS))
SLEEP=15

echo "==> 1/3 Confirming notarization for ${SUBMISSION_ID}"
echo "    timeout in ${NOTARY_TIMEOUT_SECONDS}s"
while true; do
    if [[ "$(date +%s)" -gt "${DEADLINE}" ]]; then
        echo "Submission ${SUBMISSION_ID} still pending after ${NOTARY_TIMEOUT_SECONDS}s." >&2
        echo "Re-run with a longer NOTARY_TIMEOUT_SECONDS or wait and retry." >&2
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
            SLEEP=$((SLEEP < 120 ? SLEEP * 2 : 120))
            ;;
    esac
done

echo "==> 2/3 Stapling ticket to ${APP_BUNDLE}"
xcrun stapler staple "${APP_BUNDLE}"

echo "==> 3/3 Building .dmg"
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg not installed. Install with: brew install create-dmg" >&2
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

# Apple's strict flow is to also notarize+staple the .dmg itself (a second
# submission round). On this account each round takes 1-4h, so by default
# we skip that step. The .app inside is fully notarized and stapled, so
# Gatekeeper only does a brief online check when the user first opens the
# .dmg; once the .app is in /Applications it's fully offline-verified.
# Set STAPLE_DMG=1 to opt into the strict path.
if [[ "${STAPLE_DMG:-0}" == "1" ]]; then
    echo "==> Submitting .dmg for its own notarization round"
    DMG_SUBMIT_OUT="$(xcrun notarytool submit "dist/${DMG_NAME}" \
        --apple-id "${APPLE_ID}" \
        --team-id "${APPLE_TEAM_ID}" \
        --password "${APPLE_APP_PASSWORD}" \
        --output-format json)"
    echo "${DMG_SUBMIT_OUT}"
    DMG_SUBMISSION_ID="$(echo "${DMG_SUBMIT_OUT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

    DMG_DEADLINE=$(($(date +%s) + NOTARY_TIMEOUT_SECONDS))
    SLEEP=15
    while true; do
        if [[ "$(date +%s)" -gt "${DMG_DEADLINE}" ]]; then
            echo ".dmg notarization still pending after ${NOTARY_TIMEOUT_SECONDS}s." >&2
            exit 1
        fi
        DMG_INFO="$(xcrun notarytool info "${DMG_SUBMISSION_ID}" \
            --apple-id "${APPLE_ID}" \
            --team-id "${APPLE_TEAM_ID}" \
            --password "${APPLE_APP_PASSWORD}" \
            --output-format json 2>/dev/null || echo '{}')"
        DMG_STATUS="$(echo "${DMG_INFO}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "?")"
        echo "  $(date -u +%H:%M:%SZ) dmg status=${DMG_STATUS}"
        case "${DMG_STATUS}" in
            Accepted) break ;;
            Invalid|Rejected)
                xcrun notarytool log "${DMG_SUBMISSION_ID}" \
                    --apple-id "${APPLE_ID}" \
                    --team-id "${APPLE_TEAM_ID}" \
                    --password "${APPLE_APP_PASSWORD}" || true
                exit 1
                ;;
            *)
                sleep "${SLEEP}"
                SLEEP=$((SLEEP < 120 ? SLEEP * 2 : 120))
                ;;
        esac
    done
    xcrun stapler staple "dist/${DMG_NAME}"
fi

echo ""
echo "Done. Artifact: dist/${DMG_NAME}"
echo "Verify with: spctl --assess --type open --context context:primary-signature dist/${DMG_NAME}"
