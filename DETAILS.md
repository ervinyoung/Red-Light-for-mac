# Red Light reference

This page covers the command line, how Red Shift works, scheduling, adopted defaults, and the files Red Light
stores. For an overview, see the [README](README.md).

## Updates

Red Light checks GitHub for a new version once a day. It installs only updates that are signed with the
project's key, and only while your screen isn't red.

To install updates yourself instead, in **Red Light Settings > Updates**, turn off **Update Automatically**.
Red Light still tells you when a new version is available.

## Uninstall Red Light

To remove Red Light, follow these steps:

1. In the Red Light panel, turn off the switch.
2. In **Red Light Settings**, click **Quit Red Light**.
3. Drag **Red Light** from the **Applications** folder to the Trash.
4. To stop the sunset scheduler, run the following command in Terminal:

   ```sh
   launchctl bootout gui/$(id -u)/com.ervinyoung.redlight; rm ~/Library/LaunchAgents/com.ervinyoung.redlight.plist
   ```

5. Optional: To delete your settings, run the following command:

   ```sh
   rm -r ~/Library/Application\ Support/RedLight
   ```

If you cloned the repository, `./uninstall.sh` does all of these steps. To include your settings, add `--all`.

## Build from source

To build Red Light from source, you need the Xcode Command Line Tools. To install them, run
`xcode-select --install`.

To build and install Red Light, run the following command:

```sh
git clone https://github.com/ervinyoung/Red-Light-for-mac && cd Red-Light-for-mac && ./install.sh
```

To update a source build, run `./install.sh` again. The installer keeps your settings, your adopted defaults,
and the state of the switch. A source build also updates itself from GitHub releases unless you turn off
automatic updates.

To publish a release, run `./release.sh --publish`. The script builds the disk image, the update archive, and
its signature in `dist/`, and then creates a GitHub release. Signing requires the update key in your login
Keychain. To build without publishing, run `./release.sh`.

## Control Red Light from Terminal

To create a `redlight` command, run the following once:

```sh
echo 'alias redlight="$HOME/Library/Application\ Support/RedLight/redlight"' >> ~/.zshrc && source ~/.zshrc
```

The following table lists the commands:

| Command | Description |
| --- | --- |
| `redlight on`, `redlight off` | Turn the master switch on or off. Off restores your normal display, and nothing happens at sunset. |
| `redlight status` | Show the mode, fade progress, pause, sun times, current settings, and location. |
| `redlight suntimes` | Show today's sunrise and sunset and the times Red Light switches. |
| `redlight night`, `redlight day` | Switch immediately, without a fade. `night` also turns the switch on. |
| `redlight pause 60` | Pause for 60 minutes. Red Light restores the day look and records nothing while paused. |
| `redlight pause sunrise` | Pause until the next sunrise. |
| `redlight resume` | End a pause and turn the switch on. |
| `redlight set warmth 80` | Set Red Shift from 0 to 100, or `off`. For details, see [Red Shift](#red-shift). |
| `redlight set keyboard 30` | Set the keyboard backlight in percent of macOS's range, from 0.1 to 100, or `off`. Use `dim1` to `dim4` for Starlight, Moonlight, Candlelight, and Firelight. |
| `redlight set idle 30` | Turn the keyboard backlight off after the given number of seconds of inactivity. |
| `redlight set shade 40` | Set the screen shade from 0 to 90, or `off`. |
| `redlight preset list` | List presets. Other subcommands are `apply "Night"`, `save "Reading" book.fill`, `night "Night"`, and `delete "Reading"`. |
| `redlight shade on` | Control the screen shade. Other arguments are `off`, `toggle`, `up`, `down`, and a level from 0 to 90. |
| `redlight location 37.43 -122.14` | Set the location manually. Add `auto` to let Location Services update it. |
| `redlight learned`, `redlight forget` | Show or clear the defaults that Red Light adopted. |
| `redlight hold Figma` | Show true color while a color-sensitive app is in front. |
| `redlight release` | Restore the red after a hold. |
| `redlight room` | Read the light sensor and ease Red Shift toward the room's level. The app runs this while the light changes. |
| `redlight curve` | Print the Red Shift curve. |

While the switch is off, the `pause`, `set`, `preset apply`, and `shade` commands return an error. Turn the
switch on first.

## Red Shift

Red Shift is a single slider that combines two ways of removing blue light, because each has a different
strength:

- **Channel scaling** reduces the display's blue and green channels in the gamma table, which is what Night
  Shift and f.lux do. Text stays sharp because every pixel keeps its brightness, but scaling can't remove more
  than all of the blue, and content that only uses a removed channel turns dark.
- **Color Tint**, a macOS accessibility filter, maps each pixel to its brightness and mixes it toward red.
  Nothing disappears, but colors merge, and at high intensity the whole screen becomes one shade of red.

Red Shift uses each method where it works best:

| Red Shift | What changes |
| --- | --- |
| 0–60% | Channel scaling only. Blue goes from 100% to 0%, and green goes down to 60%. Text is most legible in this range. |
| 60–100% | Blue stays at 0%. Green goes down to 35%, and a brightness-preserving tint of up to 50% adds the removed green back as red brightness. |

At 60%, the display shows no blue and no tint. The default at night is 80%. In the configuration and the
command line, Red Shift is called `warmth`. The menu bar app draws the gamma table, and the engine sets the
tint; `shade.json` stores both.

### Room light

At night, Red Light reads your Mac's ambient light sensor and sets Red Shift from your room's light:

| Room light | Red Shift |
| --- | --- |
| 20 lux or more, a lit room | Off |
| 10 lux, a dim lamp | 22% |
| 2 lux | 45% |
| Dark | 60% |

A change eases in at about 1% a second, so a hand passing over the sensor doesn't flicker the screen. The
level follows the sunset and sunrise fades, so it never jumps at a transition. By day, while paused, and with
the lid closed, Red Shift is your own level.

The slider shows the level you see. Moving it shifts the room's curve for the rest of the night: above the
room's level by the difference, and below it in proportion, so 0 is off in any room. Red Light learns from
these shifts. For example, if you raise the level by 10% on three nights, the curve starts 10% higher.

To turn room light off, in **Red Light Settings**, turn off **Match Room Light**, or set
`roomLight.enabled` to `false` in `config.json`. To scale the room's levels, set `roomLight.strength` from 0
to 1. The default is 1.

## Sunset and sunrise

Red Light uses Location Services only to calculate sunrise and sunset, and your location never leaves your
Mac. Until you grant permission, Red Light estimates your location from your time zone. You can also enter
coordinates in **Red Light Settings**.

Transitions take 30 minutes by default. To change the length, in **Red Light Settings**, choose a
**Transition** value, or set `fadeMinutes` in `config.json`. Red Shift and the screen shade change at a steady
rate, and the keyboard backlight changes on a logarithmic scale so that each step looks even.

If you change a setting during a transition, that setting stays where you put it, and the rest of the
transition continues. When your Mac wakes from sleep, Red Light checks the time immediately and continues any
transition from the point where it should be.

## Adopted defaults

Every minute, the engine compares the current settings with the settings it last recorded. A difference
counts as a manual change, and the engine records it in `events.jsonl`. Your changes always take effect
immediately.

The engine uses these records in two ways:

- When the value that you choose at night is about the same on 3 of the last 14 nights, that value becomes the
  night default.
- When you turn Red Shift on or off by hand near a transition on 3 nights, the transition moves to match, by up
  to 2 hours.

Red Light shows at most one notification a day about an adopted change. `learned.json` stores the adopted
values and their history. To clear them, run `redlight forget`.

## Files

Red Light stores its files in `~/Library/Application Support/RedLight`:

| File | Contents |
| --- | --- |
| `config.json` | The night preset, day defaults, location and its source, fade length, learning settings, presets, and shortcuts. |
| `state.json` | The master switch, mode, day snapshot, current transition, pause, true-color hold, and room light. |
| `learned.json` | Adopted defaults and their history. |
| `events.jsonl` | Recorded manual changes, removed after the lookback window. |
| `shade.json` | What the app draws: the screen shade, Red Shift, and gamma multipliers. |
| `commanded.json` | The last keyboard brightness that Red Light set. The hardware reports 0 after the backlight dims. |
| `redlight` | The engine. The app installs it from its own bundle every time it opens. |
| `redlight.log` | Transitions, recorded changes, and adopted defaults. At 1 MB, it moves to `redlight.log.1`. |
| `launchd.err.log` | Any error output from the scheduler. |

## Keyboard backlight below the minimum

The keyboard backlight is driven by a PWM signal with a 960-step cycle. macOS's levels run from 54 steps (its
minimum) to 336 (full), but the hardware can go down to 1 step: macOS only passes through those levels while it
fades the keys off. Red Light adds four named levels below macOS's minimum:

| Level | Steps | Share of macOS's minimum |
| --- | --- | --- |
| Starlight | 2 | 1/27 |
| Moonlight | 4 | 1/14 |
| Candlelight | 9 | 1/6 |
| Firelight | 21 | 2/5 |

To hold one of these levels, the menu bar app keeps restarting a slow fade before it can move a step.

Whenever Red Light sets the keyboard (auto-brightness off), it also runs the idle-off instead of macOS, at every
level: the keys turn off after your **Turn Off After Inactivity** time, and back on as soon as you type, move the
pointer, click, or scroll, so you can find the keys at night without pressing one. (macOS's own idle-off counts
typing only, and once it has dimmed the keys it ignores brightness changes.) The named levels work only while the app is open. If you change the brightness
with the keyboard's brightness keys or Control Center, Red Light releases the backlight at the new level.

The left half of the **Keyboard Backlight** slider holds **Off** and the four named levels, and snaps to them. The
taller mark shows where macOS's range starts; from there the slider moves continuously, from 1% (macOS's
minimum) to 100%.

## The menu bar app

The menu bar icon is a sun on the horizon. It's an outline while Red Light waits for sunset, filled at night,
and dimmed while Red Light is paused or off.

The panel contains the following sections:

- **Red Shift**, **Screen Shade**, **Keyboard Backlight**, and **Turn Off After Inactivity** sliders. Each slider
  snaps to fixed stops, applies changes as you drag, and shows a mark under the track for each saved preset.
- **Presets**. To apply a preset, click it. To use a preset at sunset, replace it, or delete it, Control-click
  it. To save the current settings as a preset, click **Save Current Look**.
- **Pause**, and **Red Light Settings**.

To control the screen shade from any app, use the following keyboard shortcuts:

- To turn the shade on or off, press Control-Option-Command-S.
- To make the shade darker or lighter, press Control-Option-Command-Up Arrow or Control-Option-Command-Down Arrow.

The switch at the top right of the panel works like the Wi-Fi switch. When it's off, Red Light restores your
normal display and does nothing at sunset. When it's on, Red Light follows the sun again and ends any pause.
During the day, the panel shows a **Waiting for sunset** row with the start time, and a **Turn On Now** row that
applies the night settings immediately. All controls stay available.

The screen shade and the gamma part of Red Shift work only while the app is open, because macOS restores the
gamma table when the app quits.

To rebuild everything from the repository, run `./install.sh`. To rebuild only the app, which includes the
engine, run `app/build.sh`.

The scheduler (`~/Library/LaunchAgents/com.ervinyoung.redlight.plist`, which runs `redlight check` every minute)
stays loaded at all times. To turn Red Light off, use the switch or `redlight off`; don't unload the scheduler.
