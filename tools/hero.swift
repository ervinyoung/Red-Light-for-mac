import AppKit
let W: CGFloat = 1600, H: CGFloat = 800, scale: CGFloat = 2
let panel = NSImage(contentsOfFile: "/Users/ervinyoung/Documents/Claude/red-light-for-mac/docs/img/panel.png")!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W*scale), pixelsHigh: Int(H*scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!; NSGraphicsContext.current = ctx
let cg = ctx.cgContext
// pure black, with a red field rising from the bottom right
NSColor.black.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
let cs = CGColorSpaceCreateDeviceRGB()
let glow = CGGradient(colorsSpace: cs, colors: [NSColor(red: 1, green: 0, blue: 0, alpha: 0.55).cgColor, NSColor(red: 0.5, green: 0, blue: 0, alpha: 0.35).cgColor, NSColor(red: 0, green: 0, blue: 0, alpha: 0).cgColor] as CFArray, locations: [0, 0.4, 1])!
cg.drawRadialGradient(glow, startCenter: CGPoint(x: 1180, y: -80), startRadius: 0, endCenter: CGPoint(x: 1180, y: -80), endRadius: 760, options: [])
// type
// Same roles as the site: Display for the headline and large type, Text for reading sizes.
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: NSPoint, tracking: CGFloat = -1.5) {
    let family = size >= 20 ? "SF Pro Display" : "SF Pro Text"
    let font = NSFont(name: family, size: size).map { NSFontManager.shared.convert($0, toHaveTrait: weight == .bold ? .boldFontMask : []) } ?? NSFont.systemFont(ofSize: size, weight: weight)
    let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking]
    NSAttributedString(string: text, attributes: a).draw(at: p)
}
draw("Zero blue.", size: 104, weight: .bold, color: .white, at: NSPoint(x: 96, y: 520), tracking: -3)
draw("Sleep better.", size: 104, weight: .bold, color: NSColor(red: 1, green: 0, blue: 0, alpha: 1), at: NSPoint(x: 96, y: 408), tracking: -3)
draw("Blue light after sunset is the cheapest sleep loss you are still paying for.", size: 24, weight: .regular, color: NSColor(white: 0.65, alpha: 1), at: NSPoint(x: 100, y: 340), tracking: 0)
draw("Red Light drives your Mac to zero blue at sunset, in a native macOS 27 menu bar panel. Free.", size: 24, weight: .regular, color: NSColor(white: 0.65, alpha: 1), at: NSPoint(x: 100, y: 304), tracking: 0)
draw("ervinyoung.github.io/Red-Light-for-mac", size: 18, weight: .semibold, color: NSColor(white: 0.45, alpha: 1), at: NSPoint(x: 100, y: 96), tracking: 0.5)
// the panel, rounded, with a soft shadow, hanging from the top like a menu bar panel
let pw: CGFloat = 400, ph = pw * panel.size.height / panel.size.width
let pr = NSRect(x: W - pw - 120, y: H - 56 - ph, width: pw, height: ph)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -20), blur: 60, color: NSColor.black.withAlphaComponent(0.7).cgColor)
NSColor(white: 0.13, alpha: 1).setFill(); NSBezierPath(roundedRect: pr, xRadius: 32, yRadius: 32).fill()
cg.restoreGState()
cg.saveGState(); NSBezierPath(roundedRect: pr, xRadius: 32, yRadius: 32).addClip()
panel.draw(in: pr, from: .zero, operation: .sourceOver, fraction: 1)
cg.restoreGState()
NSColor(white: 1, alpha: 0.14).setStroke(); let b = NSBezierPath(roundedRect: pr.insetBy(dx: 0.5, dy: 0.5), xRadius: 32, yRadius: 32); b.lineWidth = 1; b.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/Users/ervinyoung/Documents/Claude/red-light-for-mac/docs/img/hero.png"))
print("wrote hero.png \(rep.pixelsWide)x\(rep.pixelsHigh)")
