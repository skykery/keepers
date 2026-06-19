#!/usr/bin/env bash
# Zip the signed Keepers.app and submit it to Apple for notarization.
# Does NOT poll or staple — that's finalize_release.sh's job.
#
# Required env:
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#
# Stdout: the bare submission ID (one line). All progress logs go to stderr,
# so callers can capture the ID with $(scripts/submit_notarization.sh).

set -euo pipefail

cd "$(dirname "$0")/.."

: "${APPLE_ID:?APPLE_ID env var required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID env var required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD env var required}"

APP_NAME="Keepers"
APP_BUNDLE="dist/${APP_NAME}.app"
NOTARY_ZIP="dist/${APP_NAME}.zip"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "Missing ${APP_BUNDLE}. Run scripts/build_and_sign.sh first." >&2
    exit 1
fi

echo "==> Zipping ${APP_BUNDLE} for submission" >&2
ditto -c -k --keepParent "${APP_BUNDLE}" "${NOTARY_ZIP}"

echo "==> Submitting to Apple" >&2
SUBMIT_OUT="$(xcrun notarytool submit "${NOTARY_ZIP}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_PASSWORD}" \
    --output-format json)"
echo "${SUBMIT_OUT}" >&2

SUBMISSION_ID="$(echo "${SUBMIT_OUT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
rm -f "${NOTARY_ZIP}"

echo "Submission ID: ${SUBMISSION_ID}" >&2
echo "${SUBMISSION_ID}"
