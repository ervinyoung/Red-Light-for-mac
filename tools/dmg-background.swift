// Draws the disk image window's background: black, a low red glow, an arrow from the app to Applications, and the
// one instruction an unnotarized download needs. Writes 1x and 2x PNGs; make-dmg.sh joins them into one TIFF.
import AppKit
let W: CGFloat = 660, H: CGFloat = 400
func draw(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    // the sun below the horizon: a soft red glow rising from the bottom edge
    NSGradient(colors: [NSColor(red: 0.75, green: 0.04, blue: 0.02, alpha: 0.55), NSColor(red: 0.3, green: 0, blue: 0, alpha: 0.18), .clear],
               atLocations: [0, 0.45, 1], colorSpace: .deviceRGB)!
        .draw(fromCenter: NSPoint(x: W / 2, y: -60), radius: 0, toCenter: NSPoint(x: W / 2, y: -60), radius: 360, options: [])
    // label plates: Finder draws icon names black in Light Mode and white in Dark Mode; mid grey reads under both
    let plate = NSColor(white: 0.43, alpha: 1)
    for x in [170.0, 490.0] { plate.setFill(); NSBezierPath(roundedRect: NSRect(x: x - 58, y: H - 296, width: 116, height: 22), xRadius: 11, yRadius: 11).fill() }
    // arrow
    let red = NSColor(red: 1, green: 0.16, blue: 0.1, alpha: 1)
    let a = NSBezierPath(); a.lineWidth = 5; a.lineCapStyle = .round; a.lineJoinStyle = .round
    let y = H - 200
    a.move(to: NSPoint(x: 268, y: y)); a.line(to: NSPoint(x: 388, y: y))
    a.move(to: NSPoint(x: 370, y: y + 16)); a.line(to: NSPoint(x: 390, y: y)); a.line(to: NSPoint(x: 370, y: y - 16))
    red.setStroke(); a.stroke()
    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ y: CGFloat, lines: CGFloat = 1) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        (s as NSString).draw(in: NSRect(x: 30, y: y, width: W - 60, height: size * 1.45 * lines),
                             withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p])
    }
    text("Drag Red Light to Applications", 17, .semibold, .white, 58)
    text("Then open it from Applications. The first time, macOS asks you to confirm in\nSystem Settings › Privacy & Security › Open Anyway.", 11.5, .regular, NSColor(white: 0.62, alpha: 1), 14, lines: 2)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
draw(scale: 1, to: CommandLine.arguments[1]); draw(scale: 2, to: CommandLine.arguments[2])
