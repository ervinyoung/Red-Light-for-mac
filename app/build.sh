#!/bin/zsh
# Builds Red Light.app — the menu bar app with the engine inside it — into /Applications, or into the path given.
#   app/build.sh                      → /Applications/Red Light.app
#   app/build.sh "dist/Red Light.app" → a release build (release.sh)
set -e
APP="${1:-/Applications/Red Light.app}"; [[ "$APP" = /* ]] || APP="$PWD/$APP"    # relative to the caller, not app/
cd "$(dirname "$0")"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
[ "$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)" -ge 26 ] || { echo "Red Light needs the macOS 26 SDK or later (Xcode or Command Line Tools 26)"; exit 1; }
# The engine source sits beside app/ in the repo, and beside gui/ in an install.sh copy.
ENGINE=../engine/redlight.swift; [ -f "$ENGINE" ] || ENGINE=../redlight.swift
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macos26.0 -sdk "$SDK" RedLightApp.swift -o "$APP/Contents/MacOS/RedLight"
# Helpers/, not MacOS/: on a case-insensitive disk "redlight" and "RedLight" are the same file.
swiftc -O -target arm64-apple-macos26.0 -sdk "$SDK" "$ENGINE" -o "$APP/Contents/Helpers/redlight"
cp Info.plist "$APP/Contents/Info.plist"
# The Liquid Glass icon (Icon Composer document) needs Xcode's actool; with only the Command Line Tools the app
# still builds, just with the generic icon.
if ACTOOL="$(xcrun --find actool 2>/dev/null)"; then
  "$ACTOOL" AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon --output-partial-info-plist "$(mktemp -t redlight-icon)" >/dev/null
else
  echo "note: Xcode not found, building without the app icon"
fi
# Finder info and other extended attributes (a clone in iCloud Drive, a downloaded zip) make codesign refuse.
xattr -cr "$APP"
# Signing: Developer ID (notarizable) if present, else Apple Development, else ad-hoc. A real identity keeps the
# same designated requirement from build to build, so macOS remembers Location access across updates.
# Signed by certificate hash, not name: a renewed certificate beside the old one gives two identities with one name,
# and codesign refuses an ambiguous name.
IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
LINE="$(print -r -- "$IDS" | grep -m1 '"Developer ID Application: ' || print -r -- "$IDS" | grep -m1 '"Apple Development: ' || true)"
NAME="${SIGN_ID:-$(print -r -- "$LINE" | sed -n 's/^[^"]*"\(.*\)".*/\1/p')}"
ID="${SIGN_ID:-$(print -r -- "$LINE" | awk '{print $2}')}"
[ -n "$ID" ] || { ID="-"; NAME="ad-hoc"; }
OPTS=(); [[ "$NAME" == "Developer ID Application:"* ]] && OPTS=(--options runtime --timestamp)
codesign --force --sign "$ID" "${OPTS[@]}" "$APP/Contents/Helpers/redlight"
codesign --force --sign "$ID" "${OPTS[@]}" "$APP"
touch "$APP"     # Finder and the Dock pick up a changed icon
echo "built $APP (signed: $NAME)"
