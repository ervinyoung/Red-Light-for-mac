#!/bin/zsh
# Red Light installer: builds the engine and the menu bar app from source, seeds a config, starts the agent.
# Requires: Apple silicon Mac, macOS 26 or later, Xcode Command Line Tools (xcode-select --install).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$HOME/Library/Application Support/RedLight"
mkdir -p "$DIR/gui" "$HOME/Library/LaunchAgents" "$HOME/Applications"
echo "→ building engine"
cp "$HERE/engine/redlight.swift" "$DIR/redlight.swift"
swiftc -O "$DIR/redlight.swift" -o "$DIR/redlight"
echo "→ building app"
cp "$HERE/app/RedLightApp.swift" "$HERE/app/Info.plist" "$HERE/app/build.sh" "$DIR/gui/"
chmod +x "$DIR/gui/build.sh"; "$DIR/gui/build.sh"
if [ ! -f "$DIR/config.json" ]; then
  echo "→ writing default config (location will be resolved by the app; edit config.json to override)"
  cat > "$DIR/config.json" <<'JSON'
{
  "latitude": 37.77, "longitude": -122.42, "locationSource": "timezone", "fadeMinutes": 30,
  "night": { "warmth": 0.8, "keyboardBrightness": 0.003, "keyboardIdleDimSeconds": 5, "keyboardAutoBrightness": false, "shadeEnabled": false, "shadeLevel": 0.3 },
  "dayDefaults": { "warmth": 0, "keyboardBrightness": 0.3, "keyboardIdleDimSeconds": 300, "keyboardAutoBrightness": true },
  "learning": { "enabled": true, "minNights": 3, "lookbackDays": 14, "maxOffsetMinutes": 120 },
  "nightPresetName": "Night",
  "presets": [
    { "name": "Dusk",       "icon": "sunset.fill",   "settings": { "warmth": 0.45, "keyboardBrightness": 0.01,  "keyboardIdleDimSeconds": 30, "shadeEnabled": false, "shadeLevel": 0.2 } },
    { "name": "Night",      "icon": "moon.fill",     "settings": { "warmth": 0.8,  "keyboardBrightness": 0.003, "keyboardIdleDimSeconds": 5,  "shadeEnabled": false, "shadeLevel": 0.2 } },
    { "name": "Deep night", "icon": "moon.zzz.fill", "settings": { "warmth": 1.0,  "keyboardBrightness": 0.001, "keyboardIdleDimSeconds": 5,  "shadeEnabled": true,  "shadeLevel": 0.4 } },
    { "name": "Movie",      "icon": "film.fill",     "settings": { "warmth": 0.45, "keyboardBrightness": 0.0,   "keyboardIdleDimSeconds": 5,  "shadeEnabled": true,  "shadeLevel": 0.4 } }
  ],
  "shortcuts": {
    "toggleShade": { "keyCode": 1,   "modifiers": ["control", "option", "command"] },
    "shadeUp":     { "keyCode": 126, "modifiers": ["control", "option", "command"] },
    "shadeDown":   { "keyCode": 125, "modifiers": ["control", "option", "command"] }
  }
}
JSON
fi
echo "→ installing the sunrise/sunset agent"
PLIST="$HOME/Library/LaunchAgents/com.ervinyoung.redlight.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.ervinyoung.redlight</string>
  <key>ProgramArguments</key><array><string>$DIR/redlight</string><string>check</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$DIR/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$DIR/launchd.err.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/com.ervinyoung.redlight" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
ln -sf "$DIR/redlight" "$DIR/sunmode"
open "$HOME/Applications/Red Light.app"
echo
echo "Red Light is installed. Look for the sunset icon in the menu bar."
echo "Terminal shortcut:  echo 'alias redlight=\"\$HOME/Library/Application\\ Support/Red Light/redlight\"' >> ~/.zshrc"
