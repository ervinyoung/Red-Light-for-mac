#!/bin/zsh
# tools/make-dmg.sh "dist/Red Light.app" dist/Red-Light.dmg
# A drag-to-install disk image: the app, an Applications shortcut, and a background that says what to do.
set -e
APP="$1"; OUT="$2"; HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d -t redlight-dmg)"; STAGE="$WORK/stage"; mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Red Light.app"
ln -s /Applications "$STAGE/Applications"
swift "$HERE/dmg-background.swift" "$WORK/bg.png" "$WORK/bg@2x.png"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null
hdiutil detach "/Volumes/Red Light" -quiet 2>/dev/null || true
hdiutil create -quiet -volname "Red Light" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$WORK/rw.dmg"
# Window layout is stored by Finder in the volume's .DS_Store. If Finder can't be scripted (no Automation
# permission), the image still works — just without the arranged window.
osascript <<'AS' || echo "note: Finder layout skipped"
tell application "Finder" to tell disk "Red Light"
  open
  set current view of container window to icon view
  set toolbar visible of container window to false
  set statusbar visible of container window to false
  set the bounds of container window to {200, 120, 860, 548}
  set o to the icon view options of container window
  set arrangement of o to not arranged
  set icon size of o to 128
  set text size of o to 13
  set background picture of o to file ".background:background.tiff"
  set position of item "Red Light.app" of container window to {170, 196}
  set position of item "Applications" of container window to {490, 196}
  update without registering applications
  delay 1
  close
end tell
AS
rm -rf "/Volumes/Red Light/.fseventsd"; sync
hdiutil detach "/Volumes/Red Light" -quiet
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -o "$OUT"
rm -rf "$WORK"
echo "built $OUT"
