#!/usr/bin/env bash
# End-to-end build: prefetch models → py2app → codesign → notarize → staple → .dmg.
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

echo "==> 1.5/5 Pre-padding MediaPipe's libmediapipe.dylib headerpad"
# py2app's macholib rewrite refuses to extend the Mach-O load command
# section past `low_offset` (the file offset where the first segment
# begins). MediaPipe's libmediapipe.dylib has a tiny headerpad and
# py2app needs ~56 more bytes than it has room for.
#
# install_name_tool *can* extend load commands into headerpad reserved
# at link time. If MediaPipe was linked with -headerpad_max_install_names
# there's enough slack. If not, install_name_tool will refuse with the
# same error class and we'll know we need a different bundler.
MEDIAPIPE_DYLIB="$("$PY" -c 'import mediapipe, pathlib; print(pathlib.Path(mediapipe.__file__).parent / "tasks/c/libmediapipe.dylib")')"
if [[ ! -f "$MEDIAPIPE_DYLIB" ]]; then
    echo "ERROR: expected libmediapipe.dylib at $MEDIAPIPE_DYLIB but it isn't there." >&2
    exit 1
fi
CURRENT_ID="$(otool -D "$MEDIAPIPE_DYLIB" | tail -n 1)"
echo "    current LC_ID_DYLIB: $CURRENT_ID"
PAD_ID="${CURRENT_ID}/__keepers_headerpad_filler_so_macholib_has_room_to_rewrite_install_names__"
if ! install_name_tool -id "$PAD_ID" "$MEDIAPIPE_DYLIB" 2>install_name_tool.err; then
    echo "----------------------------------------------------------------" >&2
    echo "install_name_tool refused to extend the install name." >&2
    cat install_name_tool.err >&2
    echo "----------------------------------------------------------------" >&2
    echo "libmediapipe.dylib was not linked with sufficient -headerpad." >&2
    echo "Option A (pre-padding) is not viable — fall back to PyInstaller." >&2
    exit 1
fi
rm -f install_name_tool.err
install_name_tool -id "$CURRENT_ID" "$MEDIAPIPE_DYLIB"
echo "    headerpad expanded; original install_name restored"

echo "==> 2/5 Running py2app"
"$PY" setup.py py2app

echo "==> 3/5 Code signing with hardened runtime"
codesign --deep --force --options runtime \
    --entitlements Entitlements.plist \
    --sign "${DEVELOPER_ID}" \
    "${APP_BUNDLE}"
codesign --verify --deep --strict --verbose=4 "${APP_BUNDLE}"

echo "==> 4/5 Notarizing (will block until Apple responds)"
NOTARY_ZIP="dist/${APP_NAME}.zip"
ditto -c -k --keepParent "${APP_BUNDLE}" "${NOTARY_ZIP}"
xcrun notarytool submit "${NOTARY_ZIP}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_PASSWORD}" \
    --wait
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
