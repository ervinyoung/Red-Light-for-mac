# tools

The landing page and README images are screenshots of the real app, not mockups. To retake them:

1. Show the site's wallpaper behind the menu bar, in the region you'll capture (top-left screen points). The
   example puts the region against the right edge of a 1710-point-wide screen:

       swiftc -O backdrop.swift -o backdrop && ./backdrop ../docs/img/wallpaper.jpg 678 0 1032 742 &

2. Click Red Light in the menu bar, so its panel is open and in focus (an unfocused panel draws gray controls).
3. Capture the region as the display composites it, Liquid Glass included:

       swiftc -O screen-region.swift -o screen-region
       ./screen-region 678 0 1032 466 hero-shot.png     # docs/img/hero-shot.jpg, the landing page
       ./screen-region 678 0 1032 742 hero.png          # docs/img/hero.jpg, the README

   It leaves out Claude's windows, so a screen-control overlay doesn't end up in the picture.
4. Convert to JPEG: `sips -s format jpeg -s formatOptions 90 hero.png --out ../docs/img/hero.jpg`.

`poster-wallpaper.swift` builds `docs/img/wallpaper.jpg` from the poster artwork. `dmg-background.swift` and
`make-dmg.sh` build the disk image, and `sign-update.swift` signs update archives.
