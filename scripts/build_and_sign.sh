#!/usr/bin/env bash
# Build the universal (arm64 + x86_64) Keepers.app and code-sign it.
# Stops short of notarization.
#
# Required env:
#   DEVELOPER_ID         e.g. "Developer ID Application: Alin Banuta (TEAMID12345)"
#                        Use "-" for an ad-hoc signed local build.
#
# Output: dist/Keepers.app (signed, hardened runtime).

set -euo pipefail

cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?DEVELOPER_ID env var required}"

APP_NAME="Keepers"
APP_BUNDLE="dist/${APP_NAME}.app"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"

echo "==> 1/4 Cleaning prior build"
rm -rf build dist

echo "==> 2/4 Generating Xcode project"
xcodegen generate --quiet

echo "==> 3/4 Building ${VERSION} for arm64 + x86_64"
xcodebuild \
    -project Keepers.xcodeproj \
    -scheme Keepers \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${VERSION}" \
    CODE_SIGNING_ALLOWED=NO \
    build | tail -n 5

mkdir -p dist
ditto "build/DerivedData/Build/Products/Release/${APP_NAME}.app" "${APP_BUNDLE}"

# Every Mach-O in the bundle must carry both slices, or Intel or Apple
# Silicon users get a crash at launch.
while IFS= read -r -d '' file; do
    if file -b "$file" | grep -q "Mach-O"; then
        archs="$(lipo -archs "$file")"
        if [[ "$archs" != *arm64* || "$archs" != *x86_64* ]]; then
            echo "Not universal: $file ($archs)" >&2
            exit 1
        fi
    fi
done < <(find "${APP_BUNDLE}" -type f -print0)

echo "==> 4/4 Code signing with hardened runtime"
TIMESTAMP_FLAG="--timestamp"
[[ "${DEVELOPER_ID}" == "-" ]] && TIMESTAMP_FLAG=""
codesign --force --options runtime ${TIMESTAMP_FLAG} \
    --sign "${DEVELOPER_ID}" \
    "${APP_BUNDLE}"
codesign --verify --strict --verbose=2 "${APP_BUNDLE}"

echo ""
echo "Signed universal bundle ready: ${APP_BUNDLE} ($(lipo -archs "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"))"
