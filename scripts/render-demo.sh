#!/bin/bash
# Render the real interface with a fictional scene, without using live devices.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"
DEMO_APP="$PWD/build/demo/OneAct.app"
mkdir -p "$DEMO_APP/Contents/MacOS" "$DEMO_APP/Contents/Resources"
cp "$BIN_PATH/OneAct" "$DEMO_APP/Contents/MacOS/OneAct"
cp Info.plist "$DEMO_APP/Contents/Info.plist"
# Isolate fixture preferences and instance handling from the user's real app.
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.oneact.screenshot' "$DEMO_APP/Contents/Info.plist"
cp AppIcon.icns "$DEMO_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$DEMO_APP"
"$DEMO_APP/Contents/MacOS/OneAct" --layout-report "$PWD/website/assets/demo-camera.png" \
  --demo-scene "$PWD/Design/demo-camera-scene.png"
"$DEMO_APP/Contents/MacOS/OneAct" --layout-report "$PWD/website/assets/hero-demo.png" \
  --screen-mode --cutout --demo-scene "$PWD/Design/demo-scene.png"
"$DEMO_APP/Contents/MacOS/OneAct" --layout-report "$PWD/website/assets/demo-teleprompter.png" \
  --screen-mode --cutout --prompter --demo-scene "$PWD/Design/demo-scene.png"
for image in demo-camera hero-demo demo-teleprompter; do
  test -s "website/assets/$image.png"
  echo "Rendered website/assets/$image.png"
done
