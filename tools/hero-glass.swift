import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

let W: CGFloat = 1600, H: CGFloat = 800, S: CGFloat = 2      // points, then 2× for the export
let panelPNG = NSImage(contentsOfFile: "panel-clear.png")!   // the app's own pixels, transparent behind them

// ── The artwork: black, and red with no blue in it ──────────────────────────────────────
// Everything below is drawn from rgb(r,g,0): the same constraint the app puts on your screen.
func drawArt(_ cg: CGContext) {
    let cs = CGColorSpaceCreateDeviceRGB()
    func c(_ r: CGFloat, _ g: CGFloat, _ a: CGFloat) -> CGColor { CGColor(colorSpace: cs, components: [r, g, 0, a])! }
    cg.setFillColor(c(0, 0, 1)); cg.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // deep glows, low on the canvas, like light pooling under a horizon
    for (x, y, rad, r, g, a) in [(1180.0, -140.0, 900.0, 1.00, 0.04, 0.85),
                                 (1460.0,  120.0, 620.0, 0.92, 0.08, 0.55),
                                 ( 620.0, -220.0, 780.0, 0.62, 0.00, 0.55),
                                 ( 180.0,  760.0, 520.0, 0.45, 0.00, 0.30)] {
        let grad = CGGradient(colorsSpace: cs, colors: [c(r, g, a), c(r * 0.5, g * 0.4, a * 0.35), c(0, 0, 0)] as CFArray, locations: [0, 0.45, 1])!
        cg.drawRadialGradient(grad, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: rad, options: [])
    }
    // ribbons: long sweeping bands, each a gradient along its own length
    func ribbon(_ pts: [CGPoint], width: CGFloat, r: CGFloat, g: CGFloat, a: CGFloat) {
        let p = CGMutablePath()
        p.move(to: pts[0])
        var i = 1
        while i + 2 < pts.count { p.addCurve(to: pts[i+2], control1: pts[i], control2: pts[i+1]); i += 3 }
        cg.saveGState()
        cg.addPath(p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
        cg.clip()
        let grad = CGGradient(colorsSpace: cs, colors: [c(r, g, 0), c(r, g, a), c(r * 0.7, g, a * 0.5), c(r, g, 0)] as CFArray, locations: [0, 0.35, 0.7, 1])!
        cg.drawLinearGradient(grad, start: pts.first!, end: pts.last!, options: [])
        cg.restoreGState()
    }
    ribbon([CGPoint(x: -120, y: 250), CGPoint(x: 300, y: 620), CGPoint(x: 760, y: 60), CGPoint(x: 1080, y: 330),
            CGPoint(x: 1320, y: 520), CGPoint(x: 1560, y: 180), CGPoint(x: 1760, y: 420)], width: 130, r: 1.0, g: 0.05, a: 0.55)
    ribbon([CGPoint(x: -80, y: 620), CGPoint(x: 380, y: 200), CGPoint(x: 820, y: 700), CGPoint(x: 1180, y: 470),
            CGPoint(x: 1420, y: 300), CGPoint(x: 1680, y: 640), CGPoint(x: 1820, y: 300)], width: 76, r: 0.85, g: 0.00, a: 0.45)
    ribbon([CGPoint(x: 200, y: 820), CGPoint(x: 560, y: 420), CGPoint(x: 980, y: 860), CGPoint(x: 1300, y: 620),
            CGPoint(x: 1500, y: 480), CGPoint(x: 1720, y: 820), CGPoint(x: 1860, y: 560)], width: 40, r: 1.0, g: 0.12, a: 0.35)
    // a few thin arcs, the last light of something
    for (cx, cy, rr, a) in [(1180.0, -60.0, 520.0, 0.30), (1180.0, -60.0, 660.0, 0.20), (1180.0, -60.0, 810.0, 0.13)] {
        cg.setStrokeColor(c(1.0, 0.10, a)); cg.setLineWidth(1.6)
        cg.addArc(center: CGPoint(x: cx, y: cy), radius: rr, startAngle: 0.15, endAngle: .pi - 0.15, clockwise: false)
        cg.strokePath()
    }
}

// ── Canvas ──────────────────────────────────────────────────────────────────────────────
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W*S), pixelsHigh: Int(H*S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
let saved = NSGraphicsContext.current
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
drawArt(NSGraphicsContext.current!.cgContext)
NSGraphicsContext.current = saved
print("art drawn")
guard let artCG = rep.cgImage else { fatalError("no cgImage from rep") }
let ci = CIImage(cgImage: artCG)

// ── The glass: blur what is behind the panel, lift its saturation, then lay a dark scrim over it ──
let pw: CGFloat = 344, ph = pw * panelPNG.size.height / panelPNG.size.width
let panelRect = CGRect(x: W - pw - 130, y: (H - ph) / 2, width: pw, height: ph)   // the whole panel, in frame
let blur = CIFilter.gaussianBlur(); blur.inputImage = ci; blur.radius = Float(34 * S)
let sat = CIFilter.colorControls(); sat.inputImage = blur.outputImage; sat.saturation = 1.9; sat.brightness = 0.02
let ctx = CIContext()
guard let out = sat.outputImage, let glassCG = ctx.createCGImage(out.clampedToExtent(), from: CGRect(x: 0, y: 0, width: W*S, height: H*S)) else { fatalError("no glass image") }
print("glass built")

NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let g = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }
let radius: CGFloat = 19
let clip = CGPath(roundedRect: panelRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -14), blur: 46, color: CGColor(gray: 0, alpha: 0.75))
g.addPath(clip); g.setFillColor(CGColor(gray: 0, alpha: 1)); g.fillPath()      // shadow caster
g.restoreGState()
g.saveGState()
g.addPath(clip); g.clip()
g.draw(glassCG, in: CGRect(x: 0, y: 0, width: W, height: H))                    // the blurred backdrop
g.setFillColor(CGColor(gray: 0.10, alpha: 0.62)); g.fill(panelRect)             // the scrim the panel adds
panelPNG.draw(in: panelRect, from: .zero, operation: .sourceOver, fraction: 1)  // the app's own pixels
g.restoreGState()
// the hairline the system draws around a glass pane
g.addPath(CGPath(roundedRect: panelRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
g.setStrokeColor(CGColor(gray: 1, alpha: 0.20)); g.setLineWidth(1); g.strokePath()

// ── Type ────────────────────────────────────────────────────────────────────────────────
func draw(_ t: String, _ size: CGFloat, _ w: NSFont.Weight, _ col: NSColor, _ p: NSPoint, _ track: CGFloat) {
    let fam = size >= 20 ? "SF Pro Display" : "SF Pro Text"
    let f = NSFont(name: fam, size: size).map { NSFontManager.shared.convert($0, toHaveTrait: w == .bold ? .boldFontMask : []) } ?? NSFont.systemFont(ofSize: size, weight: w)
    NSAttributedString(string: t, attributes: [.font: f, .foregroundColor: col, .kern: track]).draw(at: p)
}
draw("Zero blue.", 104, .bold, .white, NSPoint(x: 96, y: 520), -3)
draw("Sleep better.", 104, .bold, NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), NSPoint(x: 96, y: 408), -3)
let grey = NSColor(white: 0.66, alpha: 1)
draw("Blue light after sunset is the cheapest sleep loss you are still paying for.", 24, .regular, grey, NSPoint(x: 100, y: 340), 0)
draw("Red Light drives your Mac to zero blue at sunset, in a native macOS 27 menu bar panel. Free.", 24, .regular, grey, NSPoint(x: 100, y: 304), 0)
draw("ervinyoung.github.io/Red-Light-for-mac", 18, .semibold, NSColor(white: 0.46, alpha: 1), NSPoint(x: 100, y: 96), 0.5)
NSGraphicsContext.current = saved
print("composited")
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/Users/ervinyoung/Documents/Claude/red-light-for-mac/docs/img/hero.png"))
print("wrote hero.png \(rep.pixelsWide)x\(rep.pixelsHigh)  panel \(Int(pw))×\(Int(ph)) pt")
