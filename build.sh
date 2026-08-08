#!/usr/bin/env bash
#
# Builds Nocturne and installs it to /Applications.
#
# Requires xcodegen (brew install xcodegen) and Xcode. The .xcodeproj is
# generated rather than committed, so there is no project file to merge-conflict.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

echo "==> Generating project"
xcodegen generate

echo "==> Building (Release)"
xcodebuild \
  -project Nocturne.xcodeproj \
  -scheme Nocturne \
  -configuration Release \
  -derivedDataPath build \
  build \
  | grep -E "error:|warning: [A-Z]|BUILD" || true

APP="build/Build/Products/Release/Nocturne.app"
if [ ! -d "$APP" ]; then
  echo "Build did not produce $APP" >&2
  exit 1
fi

echo "==> Installing to /Applications"
# Quit any running copy first so it restores the clock before being replaced.
pkill -x Nocturne 2>/dev/null || true
sleep 2

rm -rf /Applications/Nocturne.app
cp -R "$APP" /Applications/Nocturne.app

echo
echo "Installed /Applications/Nocturne.app"
echo "Open it, then look for the clock icon in your menu bar."
echo
echo "It is ad-hoc signed, so the first launch needs a right click and Open."
