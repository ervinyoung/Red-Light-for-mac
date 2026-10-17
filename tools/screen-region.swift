// screen-region <x> <y> <w> <h> <out.png>: the main display's region, as composited, without Claude's own windows.
import ScreenCaptureKit
import AppKit
let a = CommandLine.arguments
let rect = CGRect(x: Double(a[1])!, y: Double(a[2])!, width: Double(a[3])!, height: Double(a[4])!)
let sem = DispatchSemaphore(value: 0)
Task {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let display = content.displays.first { $0.displayID == CGMainDisplayID() }!
    let skip = content.windows.filter { ($0.owningApplication?.applicationName ?? "").contains("Claude") }
    let filter = SCContentFilter(display: display, excludingWindows: skip)
    let cfg = SCStreamConfiguration()
    cfg.sourceRect = rect; cfg.width = Int(rect.width * 2); cfg.height = Int(rect.height * 2)
    cfg.showsCursor = false; cfg.captureResolution = .best
    let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    let rep = NSBitmapImageRep(cgImage: img)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[5]))
    print("excluded \(skip.count) windows")
    sem.signal()
}
sem.wait()
