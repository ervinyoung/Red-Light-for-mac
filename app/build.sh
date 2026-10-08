#!/bin/zsh
# Builds Red Light.app into /Applications
set -e
cd "$(dirname "$0")"
APP="/Applications/Red Light.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
[ "$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)" -ge 26 ] || { echo "Red Light needs the macOS 26 SDK or later (Xcode or Command Line Tools 26)"; exit 1; }
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -target arm64-apple-macos26.0 -sdk "$SDK" RedLightApp.swift -o "$APP/Contents/MacOS/RedLight"
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
# Finder info and other extended attributes (a clone in iCloud Drive, a downloaded zip) make codesign refuse.
xattr -cr "$APP"
codesign --force --sign - "$APP"
touch "$APP"     # Finder and the Dock pick up a changed icon
echo "built $APP"
