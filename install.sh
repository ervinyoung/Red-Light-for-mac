#!/bin/zsh
# Red Light installer: builds the engine and the menu bar app from source, seeds a config, starts the agent.
# Requires: Apple silicon Mac, macOS 26 or later, Xcode Command Line Tools (xcode-select --install).
# Re-running it updates an install in place: config, learned adjustments and the master switch are kept.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$HOME/Library/Application Support/RedLight"
LABEL="com.ervinyoung.redlight"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="/Applications/Red Light.app"
# A standard (non-admin) account can't write to /Applications; say so now rather than halfway through a build.
if [ -e "$APP" ]; then W="$APP"; else W="${APP:h}"; fi
[ -w "$W" ] || { echo "$W isn't writable by this account: run ./install.sh from an administrator account"; exit 1; }
mkdir -p "$DIR/gui" "$HOME/Library/LaunchAgents"
# Builds before the switch moved into the engine said "off" by unloading the agent. Keep that off, as the app would,
# rather than quietly turning Red Light back on by loading the agent again. Decided now, before anything is replaced:
# once the new engine is in place, any `check` (the old app's wake or location check, mid-build) records "on".
CARRY_OFF=
if [ -f "$PLIST" ] && [ -f "$DIR/state.json" ] && ! grep -q '"disabled"' "$DIR/state.json" \
   && ! launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  CARRY_OFF=1
fi
echo "→ building the app, with the engine inside it"
cp "$HERE/engine/redlight.swift" "$DIR/redlight.swift"
cp -R "$HERE/app/." "$DIR/gui/"
chmod +x "$DIR/gui/build.sh"; "$DIR/gui/build.sh" "$APP"
echo "→ installing the engine"
# The app's own copy, byte for byte: the app replaces an engine that differs from the one inside it every time it
# starts, so one compiled separately was only replaced again — and if the app build failed, it was left running
# beside the old app. Copied beside and moved into place, so a check running right now never sees half a binary.
cp "$APP/Contents/Helpers/redlight" "$DIR/redlight.new"
mv -f "$DIR/redlight.new" "$DIR/redlight"
# A copy that is already running keeps the old build until it quits; and with two running, the new one exits.
if pgrep -x RedLight >/dev/null; then
  pkill -x RedLight || true
  for i in {1..20}; do pgrep -x RedLight >/dev/null || break; sleep 0.25; done
fi
# Earlier installers put the app in ~/Applications. Two copies with one bundle identifier confuse Launch at Login
# and Spotlight, and whichever starts first makes the other quit.
OLD="$HOME/Applications/Red Light.app"
if [ -d "$OLD" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$OLD/Contents/Info.plist" 2>/dev/null)" = "$LABEL" ]; then
  echo "→ removing the old copy in ~/Applications"
  rm -rf "$OLD"
fi
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
  "night": { "warmth": 0.45, "keyboardBrightness": 0.000074, "keyboardIdleDimSeconds": 30, "keyboardAutoBrightness": false, "shadeEnabled": false, "shadeLevel": 0.3 },
  "dayDefaults": { "warmth": 0, "keyboardBrightness": 0.3, "keyboardIdleDimSeconds": 300, "keyboardAutoBrightness": true },
  "learning": { "enabled": true, "minNights": 3, "lookbackDays": 14, "maxOffsetMinutes": 120 },
  "nightPresetName": "Night",
  "presets": [
    { "name": "Dusk",       "icon": "sunset.fill",   "settings": { "warmth": 0.6,  "keyboardBrightness": 0.01,  "keyboardIdleDimSeconds": 30, "shadeEnabled": false, "shadeLevel": 0.2 } },
    { "name": "Night",      "icon": "moon.fill",     "settings": { "warmth": 0.45, "keyboardBrightness": 0.000074, "keyboardIdleDimSeconds": 30, "shadeEnabled": false, "shadeLevel": 0.2 } },
    { "name": "Deep night", "icon": "moon.zzz.fill", "settings": { "warmth": 1.0,  "keyboardBrightness": 0.000074, "keyboardIdleDimSeconds": 5,  "shadeEnabled": true,  "shadeLevel": 0.4 } },
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
if [ -n "$CARRY_OFF" ]; then "$DIR/redlight" off || true; fi
# stdout goes nowhere: everything `check` prints is already in redlight.log, and launchd.out.log only ever grew.
# AbandonProcessGroup: launchd otherwise kills the osascript a check spawns for its "Adjusted…" notification.
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DIR/redlight</string><string>check</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$DIR/launchd.err.log</string>
</dict></plist>
PL
rm -f "$DIR/launchd.out.log"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns before the old job is gone, and bootstrap fails ("Input/output error") until it is.
for i in {1..20}; do launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break; sleep 0.25; done
launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || { echo "could not load the agent: launchctl bootstrap gui/$(id -u) \"$PLIST\""
     echo "(if Red Light is switched off in System Settings › General › Login Items › Allow in the Background, switch it on and run ./install.sh again)"; exit 1; }
open "$APP"
echo
echo "Red Light is installed. Look for the sunset icon in the menu bar."
echo "Terminal shortcut:  echo 'alias redlight=\"\$HOME/Library/Application\\ Support/RedLight/redlight\"' >> ~/.zshrc"
