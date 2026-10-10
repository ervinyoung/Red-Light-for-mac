#!/bin/zsh
# tools/make-dmg.sh "dist/Red Light.app" dist/Red-Light.dmg
# A drag-to-install disk image: the app, an Applications shortcut, and a background that says what to do.
set -e
APP="$1"; OUT="$2"; HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d -t redlight-dmg)"; STAGE="$WORK/stage"; mkdir -p "$STAGE/.background"; DEV=""
# However this ends (a Finder timeout, a busy volume), the scratch image doesn't stay mounted and its folder goes.
trap '[ -n "$DEV" ] && hdiutil detach "$DEV" -force -quiet 2>/dev/null; rm -rf "$WORK"' EXIT
ditto "$APP" "$STAGE/Red Light.app"
ln -s /Applications "$STAGE/Applications"
swift "$HERE/dmg-background.swift" "$WORK/bg.png" "$WORK/bg@2x.png"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null
# Finder finds the disk by name: another "Red Light" (the released image, opened to try it) would get the layout,
# and this one would mount as "Red Light 1".
if [ -d "/Volumes/Red Light" ]; then
  hdiutil detach "/Volumes/Red Light" -quiet 2>/dev/null || { echo "eject the “Red Light” disk first; it's in use"; exit 1; }
fi
hdiutil create -quiet -volname "Red Light" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
ATTACHED="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg")"
DEV="$(print -r -- "$ATTACHED" | head -1 | awk '{print $1}')"
print -r -- "$ATTACHED" | grep -q "/Volumes/Red Light$" || { echo "the image didn't mount at /Volumes/Red Light"; exit 1; }
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
# Finder can hold on to the volume for a moment after closing its window.
hdiutil detach "$DEV" -quiet || { sleep 2; hdiutil detach "$DEV" -force -quiet; }
DEV=""
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -o "$OUT"
echo "built $OUT"
