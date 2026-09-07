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

- `app/RedLightApp.swift` — SwiftUI menu bar pane (~900 lines, everything UI lives here)
- `engine/redlight.swift` — the CLI + launchd scheduler (~700 lines)
- `app/build.sh` — builds the app into `/Applications` (ad-hoc signed)
- `install.sh` — full install: engine, config seed, LaunchAgent, app
- `tools/` — documentation-image pipeline (`--snapshot` renders the pane off-screen to PNG;
  flags: `settings`, `daylight`, `light`, `clear`)

## Working on the UI

```sh
./app/build.sh                                            # rebuild into /Applications
kill "$(pgrep -x RedLight)"; open "/Applications/Red Light.app"
```

Verify changes with the snapshot pipeline before shipping:

```sh
"/Applications/Red Light.app/Contents/MacOS/RedLight" --snapshot out.png daylight        # daytime pane
```

Note: glass and vibrancy render as placeholders in off-screen snapshots (the visuallyAccessible
capture path cannot sample the backdrop). Geometry, typography, and spacing verify correctly in
snapshots; materials must be eyeballed in the running app.
