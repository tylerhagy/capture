#!/bin/bash
# Build Capture.app. Usage: ./build.sh [install]   (install copies it to ~/Applications and opens it)
set -euo pipefail
cd "$(dirname "$0")"
IDENTITY="${CAPTURE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)".*/\1/' || true)}"
IDENTITY="${IDENTITY:--}"     # no certificate: ad hoc (macOS permissions then reset on every rebuild)
swift build -c release --product Capture 2>&1 | grep -E "error|Compiling|Build" | tail -3
BIN=$(swift build -c release --show-bin-path)
APP="build/Capture.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN/Capture" "$APP/Contents/MacOS/Capture"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Fonts/InterVariable.ttf "$APP/Contents/Resources/Fonts/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R chrome-extension "$APP/Contents/Resources/chrome-extension"
codesign --force --options runtime --entitlements Resources/Capture.entitlements --sign "$IDENTITY" "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "built $APP (signed with: ${IDENTITY/-/ad hoc})"
if [ "${1:-}" = "install" ]; then
  osascript -e 'tell application id "com.tylerhagy.Capture" to quit' 2>/dev/null || true
  for _ in $(seq 1 50); do pgrep -f "Applications/Capture.app/Contents/MacOS/Capture" >/dev/null || break; sleep 0.1; done      # wait until it has really quit, or open just wakes the old one
  pkill -f "Applications/Capture.app/Contents/MacOS/Capture" 2>/dev/null || true
  mkdir -p "$HOME/Applications"; rm -rf "$HOME/Applications/Capture.app"; cp -R "$APP" "$HOME/Applications/Capture.app"
  open "$HOME/Applications/Capture.app"; echo "installed ~/Applications/Capture.app"
fi
