#!/bin/bash
# Build, sign (Developer ID), notarize and zip Cee for GitHub Releases.
# Requires: Developer ID Application cert in keychain, notarytool profile (default: cee-notary).
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-cee-notary}"
DERIVED="build/release"
APP="$DERIVED/Build/Products/Release/Cee.app"

xcodegen generate
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Release \
    -derivedDataPath "$DERIVED" clean build

codesign --verify --deep --strict --verbose=2 "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p dist
SUBMIT_ZIP="dist/Cee-$VERSION-notarize.zip"
FINAL_ZIP="dist/Cee-$VERSION.zip"

ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
OUT=$(xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)
if ! grep -q "status: Accepted" <<<"$OUT"; then
    echo "Notarization did not return Accepted" >&2
    exit 1
fi

xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$FINAL_ZIP"
rm -f "$SUBMIT_ZIP"
echo "Done: $FINAL_ZIP"
