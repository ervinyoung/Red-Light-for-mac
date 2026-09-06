#!/bin/zsh
# Builds Nightfall.app into ~/Applications. Needs Xcode Command Line Tools with a macOS 26 SDK.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/Nightfall.app"
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | head -1)
[ -z "$SDK" ] && SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$APP/Contents/MacOS" "$HOME/Applications"
swiftc -O -parse-as-library -target arm64-apple-macos26.0 -sdk "$SDK" NightfallApp.swift -o "$APP/Contents/MacOS/Nightfall"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
