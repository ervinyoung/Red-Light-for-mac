<p align="center">
  <img src="docs/img/icon.png" width="128" height="128" alt="Red Light app icon">
</p>

<h1 align="center">Red Light</h1>

<p align="center">
  <b>Zero blue. Sleep better.</b><br>
  Red Light is a menu bar app that removes blue light from your Mac's display after sunset.<br>
  It fades in over 30 minutes, offers presets for the evening, and adopts the settings you keep choosing.
</p>

<p align="center">
  <a href="https://github.com/ervinyoung/Red-Light-for-mac/releases/latest/download/Red-Light.dmg"><img src="https://img.shields.io/badge/Download_for_Mac-ff1a0f?style=for-the-badge&logo=apple&logoColor=white" alt="Download for Mac" height="36"></a>
  &nbsp;
  <a href="https://ervinyoung.github.io/Red-Light-for-mac/"><picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://img.shields.io/badge/Visit_the_website-ffffff?style=for-the-badge&logo=safari&logoColor=ff1a0f">
    <img src="https://img.shields.io/badge/Visit_the_website-111111?style=for-the-badge&logo=safari&logoColor=ff1a0f" alt="Visit the Red Light website" height="36">
  </picture></a>
</p>
<p align="center">
  <sub>Free and open source · Apple silicon · macOS 26 or later</sub>
</p>

<p align="center">
  <a href="https://ervinyoung.github.io/Red-Light-for-mac/"><img src="docs/img/hero.png" alt="The Red Light panel open from the macOS menu bar at night" width="100%"></a>
</p>

<p align="center">
  <b>See Red Light in action at <a href="https://ervinyoung.github.io/Red-Light-for-mac/">ervinyoung.github.io/Red-Light-for-mac</a>.</b>
</p>

## Features

Red Light gives you the following:

- **A native panel.** Red Light opens from the menu bar as a Control Center panel built from the system's own
  controls, type, and colors. Sliders apply your changes as you drag them.
- **A gradual transition.** Starting at sunset, Red Light fades your display, screen shade, and keyboard
  backlight from your daytime settings to your night settings over 30 minutes, and reverses the fade at sunrise.
- **Presets for the evening.** Choose **Dusk** to ease in, **Night** to settle, **Movie** to dim the whole screen,
  or **Deep night** for the last hour. Each preset sets the display, the keyboard, and the screen shade together.
- **Settings that adapt to you.** When you choose about the same setting on 3 of the last 14 nights, Red Light
  makes it your new default, including when the transition starts. Your changes always take effect immediately.
- **True color for design work.** When you open Figma, Sketch, or Photoshop at night, Red Light offers to show
  true color while that app is in front, and restores the red when you switch to another app.

## The science

Controlled human studies support reducing blue light in the evening. Each finding links to its paper:

- Reading on a light-emitting screen instead of paper reduced evening melatonin by **55%**, delayed the
  circadian clock by **1.5 hours**, and reduced alertness the next morning. Chang, Aeschbach, Duffy, and
  Czeisler, [PNAS, 2015](https://www.pnas.org/doi/10.1073/pnas.1418490112).
- Ordinary room light before bed delayed melatonin onset in **99%** of participants and shortened melatonin
  duration by about **90 minutes**. Gooley et al., [Journal of Clinical Endocrinology & Metabolism, 2011](https://doi.org/10.1210/jc.2010-2098), n = 116.
- The **blue content** of a display, not its brightness or color, predicted melatonin suppression and the time
  it took to fall asleep. Schöllhorn et al., [Communications Biology, 2023](https://doi.org/10.1038/s42003-023-04598-4), n = 72.
- The retinal cells that set the body clock are most sensitive near **480 nm**, which is in a display's blue
  range. Berson, Dunn, and Takao, [Science, 2002](https://doi.org/10.1126/science.1067262).

Red Light for Mac isn't a medical device and makes no medical claims.

## Install Red Light

Red Light requires a Mac with Apple silicon and macOS 26 or later.

To install Red Light, follow these steps:

1. Download [Red-Light.dmg](https://github.com/ervinyoung/Red-Light-for-mac/releases/latest/download/Red-Light.dmg).
2. Open the disk image, and then drag **Red Light** to the **Applications** folder.
3. In the **Applications** folder, open **Red Light**.
4. The first time you open Red Light, macOS blocks it because the app isn't notarized. In **System Settings >
   Privacy & Security**, click **Open Anyway**.

Red Light then sets itself up. It installs the sunset scheduler, asks for your location to calculate sunrise
and sunset times, and adds the default presets.

### Updates

Red Light checks GitHub for a new version once a day. It installs only updates that are signed with the
project's key, and only while your screen isn't red.

To install updates yourself instead, in **Red Light Settings > Updates**, turn off **Update Automatically**.
Red Light still tells you when a new version is available.

### Uninstall Red Light

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

### Build from source

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
| `redlight set keyboard 0.3` | Set the keyboard backlight in percent, from 0.1 to 30, or `off`. |
| `redlight set idle 30` | Turn the keyboard backlight off after the given number of seconds of inactivity. |
| `redlight set shade 40` | Set the screen shade from 0 to 90, or `off`. |
| `redlight preset list` | List presets. Other subcommands are `apply "Night"`, `save "Reading" book.fill`, `night "Night"`, and `delete "Reading"`. |
| `redlight shade on` | Control the screen shade. Other arguments are `off`, `toggle`, `up`, `down`, and a level from 0 to 90. |
| `redlight location 37.43 -122.14` | Set the location manually. Add `auto` to let Location Services update it. |
| `redlight learned`, `redlight forget` | Show or clear the defaults that Red Light adopted. |
| `redlight hold Figma` | Show true color while a color-sensitive app is in front. |
| `redlight release` | Restore the red after a hold. |
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
| `state.json` | The master switch, mode, day snapshot, current transition, pause, and true-color hold. |
| `learned.json` | Adopted defaults and their history. |
| `events.jsonl` | Recorded manual changes, removed after the lookback window. |
| `shade.json` | What the app draws: the screen shade, Red Shift, and gamma multipliers. |
| `commanded.json` | The last keyboard brightness that Red Light set. The hardware reports 0 after the backlight dims. |
| `redlight` | The engine. The app installs it from its own bundle every time it opens. |
| `redlight.log` | Transitions, recorded changes, and adopted defaults. At 1 MB, it moves to `redlight.log.1`. |
| `launchd.err.log` | Any error output from the scheduler. |

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
