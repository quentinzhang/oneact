#!/bin/bash
# Assembles and signs the .app bundle. Use this instead of hand-run commands:
# the icon step is easy to forget by hand, and a bundle without
# Contents/Resources/AppIcon.icns silently falls back to the generic app icon.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="OneAct"
IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
# One fixed path, overwritten every time. Versioned paths made macOS treat each
# build as a separate app, so old and new instances ran side by side sharing one
# preferences domain and one script file. Pass --archive to keep a copy.
APP="build/${NAME}.app"

swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "${BIN_PATH}/${NAME}" "$APP/Contents/MacOS/${NAME}"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

SIGN_OPTIONS=(--options runtime)
if [ "$IDENTITY" != "-" ]; then SIGN_OPTIONS+=(--timestamp); fi
codesign --force "${SIGN_OPTIONS[@]}" \
  --entitlements Entitlements.plist --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# A bundle that passes codesign but lost its icon is the failure this script exists to prevent.
test -f "$APP/Contents/Resources/AppIcon.icns" || { echo "FAIL: icon missing"; exit 1; }

if [ "${1:-}" = "--archive" ]; then
  ARCHIVE="build/archive/${NAME}-v${VERSION}.app"
  mkdir -p build/archive
  rm -rf "$ARCHIVE"
  cp -R "$APP" "$ARCHIVE"
  echo "archived $PWD/$ARCHIVE"
fi
echo "packaged $PWD/$APP (v${VERSION})"
