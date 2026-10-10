# Red Light for Mac — agent notes

## The design rule (never violate this)

Every visual aspect of this app — typography, spacing, colors, materials, iconography, control
dimensions, and transitions — must match **native macOS Control Center menu bar panes exactly**.
There should not be a single aspect of the app that differs from the design language and spacing
of native macOS Control Center.

Conformance target: macOS 27's Control Center (Liquid Glass generation). Local verification happens
on macOS 26 with the macOS 26 SDK; if a future point release changes spacing or materials, the `CC`
enum is the one place to update.

How to uphold the rule in code:

- The `CC` enum in `app/RedLightApp.swift` is the single source of truth for panel metrics.
  Its values are **measured from Control Center (the Battery pane at 2x)** or taken from system
  APIs — they are never chosen. Use it; extend it only with measured or system-derived values.
- Prefer system-rendered things over recreated things: `.glassEffect`, `Toggle(...).toggleStyle(.switch)`,
  SF Symbols, semantic colors (`.labelColor`, `secondaryLabelColor`), macOS text styles
  (`.headline`, `.subheadline`). Recreate only what the system cannot be made to render.
- Interactive affordances follow Control Center patterns: a switch, a glass button, or a row with a
  trailing `chevron.right`. Never use label-style text as a button.
- Menu bar icon: one SF Symbol family carries all states; fill and opacity dimming express state
  changes. Template rendering only — the system handles dark/light menu bars and selection.
- Known intentional deviation: the detent ticks under the four sliders. Native Control Center
  sliders are tickless; these were requested to make the snap stops legible.

## Repo layout

- `app/RedLightApp.swift` — SwiftUI menu bar pane, plus first-launch setup (`enum Setup`) and the signed
  updater (`Updater`) (~1,400 lines, everything UI lives here)
- `engine/redlight.swift` — the CLI + launchd scheduler (~900 lines)
- `app/build.sh` — builds the app into `/Applications` (or the path given) with the engine inside it at
  `Contents/Helpers/redlight`; signs with Developer ID, else Apple Development, else ad-hoc
- `install.sh` — install from source: builds the app, installs its engine, config seed, LaunchAgent (re-run to
  update; keeps settings)
- `uninstall.sh` — turns Red Light off, removes agent, app and engine; `--all` also deletes settings
- `release.sh` — builds `dist/Red-Light.dmg`, `dist/Red-Light.zip` and its Ed25519 signature; `--publish` makes
  the GitHub release the updater reads. `publish.sh` — one-time repo, Pages and first-release setup
- Shared files live in `~/Library/Application Support/RedLight`. The engine serialises itself with `flock` on
  `.lock`; the app writes config.json by merging only the keys it changed, never a whole stale copy
- Every launch of the app (not a `--snapshot` run) copies its bundled engine over the installed `redlight` in that
  folder if they differ, seeds config.json if missing, and writes the LaunchAgent plist if missing. Whichever build
  you launch last owns the installed engine: one built there by hand lasts only until the next app launch
- `tools/` — documentation images (`--snapshot` renders the pane off-screen to PNG; flags: `settings`, `daylight`,
  `light`, `clear`), the disk image (`make-dmg.sh`, `dmg-background.swift`) and update signing (`sign-update.swift`)

## Working on the UI

```sh
./app/build.sh                                            # rebuild into /Applications (engine included)
kill "$(pgrep -x RedLight)"; open "/Applications/Red Light.app"   # relaunching also installs its engine
```

A build carries `CFBundleShortVersionString` from `app/Info.plist`; once a newer release exists on GitHub, the
running app replaces itself with it (Settings › Updates turns that off while you work). `REDLIGHT_UPDATE_FEED`
points the updater at another releases URL for testing.

Verify changes with the snapshot pipeline before shipping:

```sh
"/Applications/Red Light.app/Contents/MacOS/RedLight" --snapshot out.png daylight        # daytime pane
```

Note: glass and vibrancy render as placeholders in off-screen snapshots (the visuallyAccessible
capture path cannot sample the backdrop). Geometry, typography, and spacing verify correctly in
snapshots; materials must be eyeballed in the running app.
