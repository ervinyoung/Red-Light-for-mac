#!/bin/zsh
# Red Light uninstaller: restores the normal display, unloads the agent, removes the app and the engine.
# Your settings and what it learned (config.json, learned.json, events.jsonl, redlight.log) stay in
# ~/Library/Application Support/RedLight for a later install. `./uninstall.sh --all` deletes them too.
set -e
case "$1" in ""|--all) ;; *) echo "usage: ./uninstall.sh [--all]"; exit 2 ;; esac
DIR="$HOME/Library/Application Support/RedLight"
LABEL="com.ervinyoung.redlight"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# Off first: the colour tint and the keyboard backlight settings are system preferences and would outlive the app.
if [ -x "$DIR/redlight" ]; then "$DIR/redlight" off >/dev/null || true; fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
pkill -x RedLight 2>/dev/null || true          # quitting hands the gamma table and the shade back to macOS
for app in "/Applications/Red Light.app" "$HOME/Applications/Red Light.app"; do
  if [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" = "$LABEL" ]; then rm -rf "$app"; fi
done
if [ "$1" = "--all" ]; then
  rm -rf "$DIR"
  echo "Red Light is removed, with its settings and everything it learned."
else
  rm -rf "$DIR/gui"
  rm -f "$DIR/redlight" "$DIR/redlight.new" "$DIR/redlight.swift" "$DIR/sunmode" "$DIR/.lock" \
        "$DIR/state.json" "$DIR/shade.json" "$DIR/commanded.json" "$DIR/launchd.out.log" "$DIR/launchd.err.log"
  echo "Red Light is removed. Your settings and what it learned are kept in $DIR (./uninstall.sh --all deletes them)."
fi
echo "If you added the redlight alias to ~/.zshrc, remove that line too."
