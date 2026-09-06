# tools

`hero.swift` builds `docs/img/hero.png`: the app's own panel screenshot on a black-and-red field.

    swiftc -O hero.swift -o hero && ./hero

`hero-glass.swift` is an alternative that composites the panel over generated artwork with a real
blurred backdrop, so the pane is genuinely translucent. It needs a transparent panel export first:

    "Red Light.app/Contents/MacOS/RedLight" --snapshot panel-clear.png clear

Both draw every background colour from `rgb(r, g, 0)`, so the artwork carries no blue at all.
