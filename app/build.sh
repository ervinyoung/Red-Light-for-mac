#!/bin/zsh
# Builds Red Light.app into /Applications
set -e
cd "$(dirname "$0")"
APP="/Applications/Red Light.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -target arm64-apple-macos26.0 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk RedLightApp.swift -o "$APP/Contents/MacOS/RedLight"
cp Info.plist "$APP/Contents/Info.plist"
# The Liquid Glass icon (Icon Composer document) needs Xcode's actool; with only the Command Line Tools the app
# still builds, just with the generic icon.
mkdir -p "$APP/Contents/Resources"
if ACTOOL="$(xcrun --find actool 2>/dev/null)"; then
  "$ACTOOL" AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon --output-partial-info-plist "$(mktemp -t redlight-icon)" >/dev/null
else
  echo "note: Xcode not found, building without the app icon"
fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"     # Finder and the Dock pick up a changed icon
echo "built $APP"
