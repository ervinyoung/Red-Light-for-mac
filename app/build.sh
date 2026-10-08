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
# Finder info and other extended attributes (a clone in iCloud Drive, a downloaded zip) make codesign refuse.
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "built $APP"
