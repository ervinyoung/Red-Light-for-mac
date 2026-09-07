#!/bin/zsh
# Builds Red Light.app into /Applications
set -e
cd "$(dirname "$0")"
APP="/Applications/Red Light.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -target arm64-apple-macos26.0 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk RedLightApp.swift -o "$APP/Contents/MacOS/RedLight"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
