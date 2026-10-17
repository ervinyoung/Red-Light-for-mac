// backdrop <image> <x> <y> <w> <h>: a borderless full-screen window, black, with the image drawn "cover" (top-aligned)
// into the given rect (top-left screen points). Behind the menu bar too, so the bar sits on the wallpaper.
import AppKit
let a = CommandLine.arguments
let img = NSImage(contentsOfFile: a[1])!
let r = (x: Double(a[2])!, y: Double(a[3])!, w: Double(a[4])!, h: Double(a[5])!)
final class V: NSView {
    override func draw(_ d: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        let s = max(r.w / img.size.width, r.h / img.size.height), dw = img.size.width * s, dh = img.size.height * s
        let top = bounds.height - r.y
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: r.x, y: top - r.h, width: r.w, height: r.h)).addClip()
        img.draw(in: NSRect(x: r.x + (r.w - dw) / 2, y: top - dh, width: dw, height: dh))
        NSGraphicsContext.restoreGraphicsState()
    }
}
final class W: NSWindow { override func constrainFrameRect(_ f: NSRect, to s: NSScreen?) -> NSRect { f } }
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let sf = NSScreen.main!.frame
let w = W(contentRect: sf, styleMask: .borderless, backing: .buffered, defer: false)
w.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
w.contentView = V(frame: NSRect(origin: .zero, size: sf.size)); w.setFrame(sf, display: true)
w.ignoresMouseEvents = true; w.collectionBehavior = [.canJoinAllSpaces, .stationary]
w.orderFrontRegardless()
app.run()
