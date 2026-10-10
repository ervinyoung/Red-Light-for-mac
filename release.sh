#!/bin/zsh
# Builds a release from app/Info.plist's version:
#   dist/Red-Light.dmg      what people download (drag to Applications)
#   dist/Red-Light.zip      what the app's updater downloads
#   dist/Red-Light.zip.sig  its Ed25519 signature (key: "Red Light update signing key" in the login Keychain)
# ./release.sh             build only
# ./release.sh --publish   build, then create GitHub release v<version> with those three files
# If the app is signed with a Developer ID and a notarytool profile named "redlight" exists
# (xcrun notarytool store-credentials redlight …), the disk image is notarized and stapled too.
set -e
cd "$(dirname "$0")"
V="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' app/Info.plist)"
TAG="v$V"
if [ "$1" = "--publish" ] && gh release view "$TAG" >/dev/null 2>&1; then echo "$TAG already exists; bump CFBundleShortVersionString in app/Info.plist"; exit 1; fi
rm -rf dist; mkdir dist
echo "→ building Red Light $V"
./app/build.sh "$PWD/dist/Red Light.app"
echo "→ packaging"
ditto -c -k --keepParent "dist/Red Light.app" dist/Red-Light.zip
swift tools/sign-update.swift dist/Red-Light.zip > dist/Red-Light.zip.sig
tools/make-dmg.sh "dist/Red Light.app" dist/Red-Light.dmg
if codesign -dv "dist/Red Light.app" 2>&1 | grep -q "Authority=Developer ID Application" \
   && xcrun notarytool history --keychain-profile redlight >/dev/null 2>&1; then
  echo "→ notarizing"
  codesign --force --sign "$(codesign -dv "dist/Red Light.app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p' | head -1)" dist/Red-Light.dmg
  xcrun notarytool submit dist/Red-Light.dmg --keychain-profile redlight --wait
  xcrun stapler staple dist/Red-Light.dmg
else
  echo "note: not notarized (needs a Developer ID certificate); first open needs Open Anyway in Privacy & Security"
fi
ls -lh dist
if [ "$1" = "--publish" ]; then
  echo "→ publishing $TAG"
  gh release create "$TAG" dist/Red-Light.dmg dist/Red-Light.zip dist/Red-Light.zip.sig --title "Red Light $V" --notes-file - <<NOTES
**Download [Red-Light.dmg](https://github.com/ervinyoung/Red-Light-for-mac/releases/download/$TAG/Red-Light.dmg)**, open it, and drag Red Light to Applications. Apple silicon, macOS 26 or later.

The first time you open it, macOS asks you to confirm: **System Settings › Privacy & Security › Open Anyway**. After that, Red Light sets itself up and keeps itself up to date.

Red-Light.zip and its signature are for the built-in updater.
NOTES
fi
