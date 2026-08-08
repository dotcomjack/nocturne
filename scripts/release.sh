#!/usr/bin/env bash
#
# Cuts a signed, notarized, stapled release of Nocturne.
#
# Requires:
#   - A "Developer ID Application" certificate in the login keychain
#   - A notarytool keychain profile (default "nocturne"), created with:
#       xcrun notarytool store-credentials "nocturne" \
#         --key <AuthKey.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>
#
# The app is NOT sandboxed and needs no entitlements. It only uses public API:
# CFPreferences against Apple's clock domain, NSRunningApplication to restart
# Control Center, and CGWindowListCopyWindowInfo for window geometry. Hardened
# runtime is on, which is all notarization requires.
set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-nocturne}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
# Read the version from the one place it is actually declared. PlistBuddy would
# return the literal "$(MARKETING_VERSION)", since the plist is templated.
VERSION="$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' project.yml)"
[ -n "$VERSION" ] || { echo "could not read MARKETING_VERSION from project.yml" >&2; exit 1; }

DIST="dist"
APP="$DIST/Nocturne.app"
ZIP="$DIST/Nocturne-$VERSION.zip"
DMG="$DIST/Nocturne-$VERSION.dmg"
LOG="$DIST/build.log"

echo "==> Version $VERSION"

rm -rf "$DIST" build Nocturne.xcodeproj
mkdir -p "$DIST"

echo "==> Generating project"
xcodegen generate >/dev/null

echo "==> Building (Release, Developer ID, universal)"
# 'generic/platform=macOS' is what makes this universal. Without it the
# destination narrows to the host and ships an arm64-only binary, which would
# not run on the Intel Macs the README promises support for.
set +e
xcodebuild -project Nocturne.xcodeproj -scheme Nocturne -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=PPL4MU9B6A \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  build > "$LOG" 2>&1
BUILD_STATUS=$?
set -e
grep -E "error:|BUILD" "$LOG" || true
[ "$BUILD_STATUS" -eq 0 ] || { echo "BUILD FAILED, see $LOG" >&2; exit 1; }

cp -R build/Build/Products/Release/Nocturne.app "$APP"

# A bundle can be signed, verified and notarized with an EMPTY MacOS directory.
# Every one of those gates passes. Check for the binary explicitly.
test -x "$APP/Contents/MacOS/Nocturne" \
  || { echo "no executable inside the bundle" >&2; exit 1; }

echo "==> Architectures"
lipo -info "$APP/Contents/MacOS/Nocturne"
lipo -info "$APP/Contents/MacOS/Nocturne" | grep -q "x86_64" \
  || echo "WARNING: not universal, Intel Macs will not run this" >&2

echo "==> Signing"
# No --deep: it is deprecated by Apple and this bundle has no nested code.
# Re-signing without --entitlements also strips the get-task-allow that
# xcodebuild injects, which notarization rejects. Do not add --entitlements here.
codesign --force --timestamp --options=runtime --sign "$IDENTITY" "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Submitting to Apple for notarization"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper assessment"
# The real test: what a downloading user's Mac will decide.
spctl --assess --type execute --verbose=4 "$APP"

echo "==> Repacking stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Building the disk image"
# The zip is what Homebrew installs. The DMG is for the person who clicks
# Download on the site and expects to drag the app onto Applications.
DMG_STAGE="$DIST/dmg"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
# Copy the STAPLED app, not the build product. The ticket lives inside the
# bundle, so a DMG assembled before stapling ships an app that has to ask
# Apple on first launch, and refuses to open on a machine that is offline.
ditto "$APP" "$DMG_STAGE/Nocturne.app"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Nocturne" -srcfolder "$DMG_STAGE" \
  -ov -format UDZO -quiet "$DMG"
rm -rf "$DMG_STAGE"

echo "==> Signing the disk image"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing the disk image"
# The DMG needs its own ticket. Stapling the app does not staple the
# container, and Gatekeeper assesses the container that was downloaded.
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper assessment of the disk image"
# -t open is the check that matters for a DMG. -t exec assesses an
# executable and reports "rejected" on a disk image that is perfectly fine.
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

echo
echo "Done."
echo "  Homebrew: $ZIP"
echo "  Humans:   $DMG"
