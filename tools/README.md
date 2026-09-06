# tools

`hero.swift` builds `docs/img/hero.png`. It composites the app's own pixels over generated artwork:

1. `Red Light.app --snapshot panel-clear.png clear` exports the panel with a transparent backdrop.
2. The artwork is drawn from `rgb(r, g, 0)` only, so the background carries no blue at all.
3. The area behind the panel is Gaussian-blurred, its saturation lifted, and a dark scrim laid over it,
   which is what the system's glass does, so the panel really is translucent over the art.

    swiftc -O hero.swift -o hero && ./hero
