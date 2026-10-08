#!/bin/zsh
# Red Light installer: builds the engine and the menu bar app from source, seeds a config, starts the agent.
# Requires: Apple silicon Mac, macOS 26 or later, Xcode Command Line Tools (xcode-select --install).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$HOME/Library/Application Support/RedLight"
mkdir -p "$DIR/gui" "$HOME/Library/LaunchAgents"
echo "→ building engine"
cp "$HERE/engine/redlight.swift" "$DIR/redlight.swift"
swiftc -O "$DIR/redlight.swift" -o "$DIR/redlight"
echo "→ building app"
cp "$HERE/app/RedLightApp.swift" "$HERE/app/Info.plist" "$HERE/app/build.sh" "$DIR/gui/"
chmod +x "$DIR/gui/build.sh"; "$DIR/gui/build.sh"
if [ ! -f "$DIR/config.json" ]; then
  echo "→ writing default config (location will be resolved by the app; edit config.json to override)"
  # Until the app has a real fix, guess the sun from the time zone's own coordinates (zone.tab: ±DDMM[SS]±DDDMM[SS]).
  TZID="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  LATLON="$(LC_ALL=C awk -F'\t' -v z="$TZID" '
    function deg(s, n,  v) { v = substr(s, 2, n) + substr(s, n + 2, 2) / 60 + substr(s, n + 4, 2) / 3600; return substr(s, 1, 1) == "-" ? -v : v }
    z != "" && $3 == z { i = match(substr($2, 2), /[+-]/); printf "%.2f %.2f", deg(substr($2, 1, i), 2), deg(substr($2, i + 1), 3); exit }' \
    /usr/share/zoneinfo/zone.tab 2>/dev/null || true)"
  if [ -n "$LATLON" ]; then LAT="${LATLON% *}"; LON="${LATLON#* }"; else LAT=37.77; LON=-122.42; fi
  cat > "$DIR/config.json.new" <<JSON
{
  "latitude": $LAT, "longitude": $LON, "locationSource": "timezone", "fadeMinutes": 30,
  "night": { "warmth": 0.8, "keyboardBrightness": 0.003, "keyboardIdleDimSeconds": 5, "keyboardAutoBrightness": false, "shadeEnabled": false, "shadeLevel": 0.3 },
  "dayDefaults": { "warmth": 0, "keyboardBrightness": 0.3, "keyboardIdleDimSeconds": 300, "keyboardAutoBrightness": true },
  "learning": { "enabled": true, "minNights": 3, "lookbackDays": 14, "maxOffsetMinutes": 120 },
  "nightPresetName": "Night",
  "presets": [
    { "name": "Dusk",       "icon": "sunset.fill",   "settings": { "warmth": 0.6,  "keyboardBrightness": 0.01,  "keyboardIdleDimSeconds": 30, "shadeEnabled": false, "shadeLevel": 0.2 } },
    { "name": "Night",      "icon": "moon.fill",     "settings": { "warmth": 0.8,  "keyboardBrightness": 0.003, "keyboardIdleDimSeconds": 5,  "shadeEnabled": false, "shadeLevel": 0.2 } },
    { "name": "Deep night", "icon": "moon.zzz.fill", "settings": { "warmth": 1.0,  "keyboardBrightness": 0.001, "keyboardIdleDimSeconds": 5,  "shadeEnabled": true,  "shadeLevel": 0.4 } },
    { "name": "Movie",      "icon": "film.fill",     "settings": { "warmth": 0.6,  "keyboardBrightness": 0.0,   "keyboardIdleDimSeconds": 5,  "shadeEnabled": true,  "shadeLevel": 0.4 } }
  ],
  "shortcuts": {
    "toggleShade": { "keyCode": 1,   "modifiers": ["control", "option", "command"] },
    "shadeUp":     { "keyCode": 126, "modifiers": ["control", "option", "command"] },
    "shadeDown":   { "keyCode": 125, "modifiers": ["control", "option", "command"] }
  }
}
JSON
  mv -f "$DIR/config.json.new" "$DIR/config.json"
fi
echo "→ installing the sunrise/sunset agent"
PLIST="$HOME/Library/LaunchAgents/com.ervinyoung.redlight.plist"
# stdout goes nowhere: everything `check` prints is already in redlight.log, and launchd.out.log only ever grew.
# AbandonProcessGroup: launchd otherwise kills the osascript a check spawns for its "Adjusted…" notification.
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.ervinyoung.redlight</string>
  <key>ProgramArguments</key><array><string>$DIR/redlight</string><string>check</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$DIR/launchd.err.log</string>
</dict></plist>
PL
rm -f "$DIR/launchd.out.log"
launchctl bootout "gui/$(id -u)/com.ervinyoung.redlight" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
ln -sf "$DIR/redlight" "$DIR/sunmode"
open "/Applications/Red Light.app"
echo
echo "Red Light is installed. Look for the sunset icon in the menu bar."
echo "Terminal shortcut:  echo 'alias redlight=\"\$HOME/Library/Application\\ Support/RedLight/redlight\"' >> ~/.zshrc"
