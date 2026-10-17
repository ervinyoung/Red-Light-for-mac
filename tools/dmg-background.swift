// Draws the disk image window's background: black, the sun's glow below a faint horizon, and the arrow drawn as the
// sun's own path — a brushed arc that rises from the app and sets into Applications. Below it, the one instruction
// an unnotarized download needs. Writes 1x and 2x PNGs; make-dmg.sh joins them into one TIFF.
import AppKit
let W: CGFloat = 660, H: CGFloat = 400
let iconY = H - 196                                     // icon centres, as make-dmg.sh places them (from the top)
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

/// A stroke that swells and tapers like a brush: the outline of a quadratic curve at half-width `w(t)`.
func brush(_ p0: NSPoint, _ c: NSPoint, _ p1: NSPoint, width w: (CGFloat) -> CGFloat) -> NSBezierPath {
    func at(_ t: CGFloat) -> NSPoint {
        let u = 1 - t
        return NSPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
    }
    func tangent(_ t: CGFloat) -> CGVector {
        let dx = 2 * (1 - t) * (c.x - p0.x) + 2 * t * (p1.x - c.x), dy = 2 * (1 - t) * (c.y - p0.y) + 2 * t * (p1.y - c.y)
        let l = max(0.0001, hypot(dx, dy)); return CGVector(dx: dx / l, dy: dy / l)
    }
    let n = 120
    var left: [NSPoint] = [], right: [NSPoint] = []
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n), p = at(t), d = tangent(t), h = w(t)
        left.append(NSPoint(x: p.x - d.dy * h, y: p.y + d.dx * h)); right.append(NSPoint(x: p.x + d.dy * h, y: p.y - d.dx * h))
    }
    let path = NSBezierPath(); path.move(to: left[0])
    for q in left.dropFirst() { path.line(to: q) }
    for q in right.reversed() { path.line(to: q) }
    path.close(); return path
}

func draw(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    rgb(0.02, 0, 0).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

    // The sun just below the horizon: a wide, low glow, and the horizon itself as a hairline that fades at both ends.
    let horizon: CGFloat = 94
    NSGradient(colors: [rgb(0.8, 0.06, 0.02, 0.5), rgb(0.35, 0.01, 0, 0.16), .clear], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(fromCenter: NSPoint(x: W / 2, y: horizon - 150), radius: 0, toCenter: NSPoint(x: W / 2, y: horizon - 150), radius: 420, options: [])
    NSGradient(colors: [.clear, rgb(1, 0.3, 0.2, 0.32), .clear], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: 40, y: horizon, width: W - 80, height: 0.75), angle: 0)

    // Label plates: Finder draws icon names black in Light Mode and white in Dark Mode; a dim plate reads under both.
    let plate = NSColor(white: 0.43, alpha: 1)
    for x in [170.0, 490.0] { plate.setFill(); NSBezierPath(roundedRect: NSRect(x: x - 58, y: H - 291, width: 116, height: 22), xRadius: 11, yRadius: 11).fill() }

    // The arrow: the sun's path, rising off the app and setting into Applications. Thin where it leaves, fullest at
    // its height, and drawn fine again into a slender, open arrowhead.
    let p0 = NSPoint(x: 256, y: iconY + 6), c = NSPoint(x: 330, y: iconY + 74), p1 = NSPoint(x: 400, y: iconY + 4)
    let arc = brush(p0, c, p1) { t in 0.4 + 2.7 * pow(sin(.pi * min(1, t * 1.08)), 1.3) + 0.7 * t }
    let dir = CGVector(dx: p1.x - c.x, dy: p1.y - c.y), dl = hypot(dir.dx, dir.dy)
    let ux = dir.dx / dl, uy = dir.dy / dl
    let tip = NSPoint(x: p1.x + ux * 1.5, y: p1.y + uy * 1.5)          // just past the stroke's end, on its line
    func barb(_ angle: CGFloat) -> NSBezierPath {
        let ca = cos(angle), sa = sin(angle), bx = -(ux * ca - uy * sa), by = -(ux * sa + uy * ca)
        let end = NSPoint(x: tip.x + bx * 19, y: tip.y + by * 19), mid = NSPoint(x: (tip.x + end.x) / 2, y: (tip.y + end.y) / 2)
        return brush(tip, mid, end) { t in 1.9 - 1.5 * t }
    }
    // Each piece filled on its own: joined into one path, overlapping outlines of opposite direction cancel and leave
    // a notch at the tip.
    let pieces = [arc, barb(0.48), barb(-0.48), NSBezierPath(ovalIn: NSRect(x: tip.x - 1.9, y: tip.y - 1.9, width: 3.8, height: 3.8))]
    let bounds = pieces.reduce(NSRect.null) { $0.union($1.bounds) }.insetBy(dx: -4, dy: -4)
    let warm = NSGradient(colors: [rgb(0.55, 0.03, 0.02), rgb(0.92, 0.1, 0.05), rgb(1, 0.36, 0.2)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    // glow first, in one layer so the pieces' glows don't stack where they meet; then the strokes over it
    let cg = NSGraphicsContext.current!.cgContext
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow(); glow.shadowColor = rgb(1, 0.12, 0.05, 0.75); glow.shadowBlurRadius = 14; glow.shadowOffset = .zero; glow.set()
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    rgb(0.9, 0.08, 0.04, 0.55).setFill(); pieces.forEach { $0.fill() }
    cg.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
    for piece in pieces { NSGraphicsContext.saveGraphicsState(); piece.addClip(); warm.draw(in: bounds, angle: 0); NSGraphicsContext.restoreGraphicsState() }

    // The sun itself, small, on the rise of the arc: the one point of light.
    let sunT: CGFloat = 0.3, u = 1 - sunT
    let sun = NSPoint(x: u * u * p0.x + 2 * u * sunT * c.x + sunT * sunT * p1.x, y: u * u * p0.y + 2 * u * sunT * c.y + sunT * sunT * p1.y)
    NSGradient(colors: [rgb(1, 0.55, 0.4, 0.9), rgb(1, 0.15, 0.05, 0.35), .clear], atLocations: [0, 0.35, 1], colorSpace: .sRGB)!
        .draw(fromCenter: sun, radius: 0, toCenter: sun, radius: 11, options: [])
    rgb(1, 0.82, 0.74).setFill(); NSBezierPath(ovalIn: NSRect(x: sun.x - 2.6, y: sun.y - 2.6, width: 5.2, height: 5.2)).fill()

    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ y: CGFloat, lines: CGFloat = 1, kern: CGFloat = 0) {
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineSpacing = 2
        (s as NSString).draw(in: NSRect(x: 30, y: y, width: W - 60, height: size * 1.5 * lines),
                             withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p, .kern: kern])
    }
    text("Drag Red Light to Applications", 17, .semibold, .white, 56)
    text("Then open it from Applications. The first time, macOS asks you to confirm in\nSystem Settings › Privacy & Security › Open Anyway.", 11.5, .regular, NSColor(white: 0.6, alpha: 1), 12, lines: 2)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
draw(scale: 1, to: CommandLine.arguments[1]); draw(scale: 2, to: CommandLine.arguments[2])
