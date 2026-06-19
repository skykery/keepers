#!/usr/bin/env bash
# Local one-shot release: build_and_sign → submit_notarization → finalize_release.
#
# Blocks until Apple finishes notarization (1-4 hours typical on this account).
# If you'd rather not hold a terminal open for hours, run the three scripts
# individually — submit, walk away, run finalize_release.sh with the
# captured submission ID once `notarytool history` shows Accepted.
#
# Required env:
#   DEVELOPER_ID, APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD

set -euo pipefail

cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?DEVELOPER_ID env var required}"
: "${APPLE_ID:?APPLE_ID env var required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID env var required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD env var required}"

scripts/build_and_sign.sh

SUBMISSION_ID="$(scripts/submit_notarization.sh)"

SUBMISSION_ID="${SUBMISSION_ID}" \
    NOTARY_TIMEOUT_SECONDS="${NOTARY_TIMEOUT_SECONDS:-21600}" \
    scripts/finalize_release.sh
