# Nightfall
Warm light after dark. Nightfall eases your Mac into a low-blue-light look at sunset and back at sunrise,
dims the keyboard further than the slider allows, and quietly learns what you keep choosing.

Site: https://ervinyoung.github.io/nightfall — Install: `git clone https://github.com/ervinyoung/nightfall && cd nightfall && ./install.sh` (Apple silicon, macOS 26+, Xcode Command Line Tools). Everything then lives in `~/Library/Application Support/Nightfall`; the menu bar app is `~/Applications/Nightfall.app`.

## Terminal
Make a shortcut once:
    echo 'alias nightfall="$HOME/Library/Application\ Support/Nightfall/nightfall"' >> ~/.zshrc && source ~/.zshrc

    nightfall status              mode, fade progress, pause, sun times, current settings, location
    nightfall suntimes            today's sunrise / sunset and the effective switch times
    nightfall night | day         switch now (instant, no fade)
    nightfall pause 60            pause for 60 minutes (restores the day look, learns nothing meanwhile)
    nightfall pause sunrise       pause until the next sunrise
    nightfall resume
    nightfall set warmth 80       the unified control, 0–100 or off (see below)
    nightfall set keyboard 0.3    keyboard backlight in percent (0.1–30) or off
    nightfall set idle 30         keys off after N seconds of inactivity
    nightfall set shade 40        screen shade 0–90 or off
    nightfall preset list | apply "Night" | save "Reading" book.fill | night "Night" | delete "Reading"
    nightfall shade on|off|toggle|up|down|<0-90>
    nightfall location 37.43 -122.14 [manual|auto]
    nightfall learned | forget
    nightfall curve               print the warmth curve
`sunmode` still works as an alias of `nightfall`.

## Warmth: one slider, two mechanisms
Two ways to cut blue light have opposite strengths. Scaling the display's blue and green channels at the
gamma table (what Night Shift and f.lux do) physically removes blue while every pixel keeps its brightness
ordering, so text stays crisp — but it cannot go "beyond zero", and content that lives only in a removed
channel goes dark. Apple's Color Tint filter maps each pixel to its luminance and mixes toward red: nothing
disappears, but hue collapses, and at high intensity everything is the same red blob.

Nightfall's Warmth uses each where it is best:
    0–60 %    channel scaling only: blue 100 % → 0, green trimmed to 60 %. Maximum legibility.
    60–100 %  blue stays at zero; green eases to 35 % while a modest luminance-preserving tint (up to 50 %)
              folds the removed green back into red brightness instead of letting it fade to black.
80 % is the default at night. 60 % is the knee: no blue at all, no tint at all.
The gamma legs are drawn by the menu bar app and the tint leg by the engine; `shade.json` carries both.

## Sunset and sunrise
Location comes from the Mac (Location Services, only ever used for sun times, never leaves the machine).
Until permission is granted it is guessed from the time zone; you can also enter coordinates in Settings.
Transitions fade over 30 minutes by default (Settings › Transition; `fadeMinutes` in config.json). Warmth and
shade ease linearly, keyboard brightness logarithmically. If you adjust anything mid-fade, the fade stops and
leaves it where you set it. Waking from sleep triggers an immediate check; a fade that should have happened
while asleep is picked up at the point the clock says it should be.

## Learning
Every minute the engine compares the current settings with what it last saw; a difference is a manual change,
recorded in `events.jsonl`. It never fights a change in the moment. When the value you settle on at night is
about the same on 3 of the last 14 nights it becomes the night default, and when you switch warmth on or off
by hand near a transition on 3 nights, the transition moves (never more than 2 hours). One notification, at
most once a day. `learned.json` holds what it adopted and a dated history; `nightfall forget` clears it.

## Files
    config.json      night preset, day defaults, location + source, fade length, learning, presets, shortcuts
    state.json       mode, day snapshot, fade in progress, pause
    learned.json     adopted adjustments and history
    events.jsonl     observed manual changes (pruned past the lookback window)
    shade.json       what the app should draw: shade overlay, warmth, gamma multipliers
    commanded.json   the keyboard brightness last set (the hardware reports 0 once it idle-dims)
    nightfall.log    transitions, noticed changes, learned adjustments
    legacy/          the previous SunsetMode install, archived

## Menu bar app
Icon: the sun at the horizon — outline by day, filled at night, a pause badge while paused.
Panel: Warmth · Screen Shade · Keyboard Backlight · Turn Off After Inactivity (sliders snap to detents and
apply live) · Presets (tap to apply; right-click for Use at Sunset / Replace / Delete; + saves the current
look) · Pause · Settings. Global shortcuts: ⌃⌥⌘S toggles the shade, ⌃⌥⌘↑ / ⌃⌥⌘↓ adjust it.
Shade and warmth exist only while the app runs (macOS restores the gamma table when it exits).
Rebuild the engine: `swiftc -O nightfall.swift -o nightfall`. Rebuild the app: `gui/build.sh`.
Agent: `launchctl bootout gui/$(id -u)/com.ervinyoung.nightfall` / `bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ervinyoung.nightfall.plist`
