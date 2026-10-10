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
if [ "$1" = "--publish" ]; then
  # Signed out, `gh release view` fails too, and would pass for "no such release" until the upload fails at the end.
  gh auth status >/dev/null 2>&1 || { echo "gh isn't signed in to GitHub (gh auth login)"; exit 1; }
  if gh release view "$TAG" >/dev/null 2>&1; then echo "$TAG already exists; bump CFBundleShortVersionString in app/Info.plist"; exit 1; fi
fi
rm -rf dist; mkdir dist
echo "→ building Red Light $V"
./app/build.sh "$PWD/dist/Red Light.app"
echo "→ packaging"
ditto -c -k --keepParent "dist/Red Light.app" dist/Red-Light.zip
# Signed only with a key the app accepts: its built-in public key is passed along and checked against the Keychain's.
PUB="$(sed -n 's/.*static let publicKey = "\([^"]*\)".*/\1/p' app/RedLightApp.swift)"
swift tools/sign-update.swift dist/Red-Light.zip "$PUB" > dist/Red-Light.zip.sig || { rm -f dist/Red-Light.zip.sig; exit 1; }
tools/make-dmg.sh "dist/Red Light.app" dist/Red-Light.dmg
if codesign -dv "dist/Red Light.app" 2>&1 | grep -q "Authority=Developer ID Application" \
   && xcrun notarytool history --keychain-profile redlight >/dev/null 2>&1; then
  echo "→ notarizing"
  # By hash, as build.sh does: a renewed certificate leaves two identities with this name.
  AUTH="$(codesign -dv "dist/Red Light.app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p' | head -1)"
  codesign --force --sign "$(security find-identity -v -p codesigning | grep -m1 -F "\"$AUTH\"" | awk '{print $2}')" dist/Red-Light.dmg
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
