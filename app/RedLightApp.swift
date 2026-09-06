import SwiftUI
import AppKit
import Carbon
import CoreLocation
import ServiceManagement

// MARK: - Shared files (same as the redlight CLI)
let appDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RedLight")
let cliURL = appDir.appendingPathComponent("redlight")
let configURL = appDir.appendingPathComponent("config.json")
let stateURL = appDir.appendingPathComponent("state.json")
let learnedURL = appDir.appendingPathComponent("learned.json")
let shadeURL = appDir.appendingPathComponent("shade.json")
let agentLabel = "com.ervinyoung.redlight"

struct Settings: Codable {
    var filterEnabled: Bool?; var filterType: Int?; var hue: Double?; var intensity: Double?
    var keyboardBrightness: Double?; var keyboardIdleDimSeconds: Double?; var keyboardAutoBrightness: Bool?
    var shadeEnabled: Bool?; var shadeLevel: Double?; var warmth: Double?
}
struct Learning: Codable { var enabled = true; var minNights = 3; var lookbackDays = 14; var maxOffsetMinutes = 120.0 }
struct Shortcut: Codable, Equatable { var keyCode: Int; var modifiers: [String] }
struct Shortcuts: Codable {
    var toggleShade = Shortcut(keyCode: 1, modifiers: ["control", "option", "command"])
    var shadeDown   = Shortcut(keyCode: 125, modifiers: ["control", "option", "command"])
    var shadeUp     = Shortcut(keyCode: 126, modifiers: ["control", "option", "command"])
}
struct Preset: Codable, Identifiable { var name: String; var icon: String; var settings: Settings; var id: String { name } }
struct Config: Codable {
    var latitude: Double; var longitude: Double; var locationSource: String?; var fadeMinutes: Double?
    var night: Settings; var dayDefaults: Settings
    var learning: Learning?; var shortcuts: Shortcuts?; var presets: [Preset]?; var nightPresetName: String?
}
struct Ramp: Codable { var start: Date; var seconds: Double; var from: Settings; var to: Settings; var label: String }
struct ModeState: Codable { var mode: String; var daySnapshot: Settings?; var lastSeen: Settings?; var lastNotified: Date?; var ramp: Ramp?; var pausedUntil: Date? }
struct Learned: Codable {
    var sunsetOffsetMinutes = 0.0; var sunriseOffsetMinutes = 0.0
    var nightKeyboardBrightness: Double?; var nightIdleDimSeconds: Double?; var nightShadeLevel: Double?; var nightWarmth: Double?
    var history: [String] = []
}
struct Shade: Codable { var enabled = false; var level = 0.3; var warmth: Double? = 0; var gammaBlue: Double? = 1; var gammaGreen: Double? = 1 }

/// Same curve as the engine, kept here only so a slider drag can paint the gamma legs without waiting on a process.
func warmthCurve(_ w: Double) -> (blue: Double, green: Double, tint: Double) {
    let w = max(0, min(1, w))
    if w <= 0.6 { let t = w / 0.6; return (1 - t, 1 - 0.40 * t, 0) }
    let t = (w - 0.6) / 0.4
    return (0, 0.60 - 0.25 * t, 0.50 * t)
}

// MARK: - Gamma legs of warmth (channel scaling at the display's transfer table)
final class Gamma {
    private var cache: [CGDirectDisplayID: ([CGGammaValue], [CGGammaValue], [CGGammaValue], UInt32)] = [:]
    private(set) var blue: Double = 1, green: Double = 1
    init() {
        CGDisplayRestoreColorSyncSettings()
        let reapply: (Notification) -> Void = { [weak self] _ in
            guard let self = self else { return }
            self.cache = [:]; CGDisplayRestoreColorSyncSettings(); self.apply(blue: self.blue, green: self.green)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: reapply)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: reapply)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: reapply)
    }
    func apply(blue b: Double, green g: Double) {
        blue = max(0, min(1, b)); green = max(0, min(1, g))
        if blue >= 0.999 && green >= 0.999 { CGDisplayRestoreColorSyncSettings(); cache = [:]; return }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        for d in ids.prefix(Int(n)) {
            if cache[d] == nil {
                let cap = CGDisplayGammaTableCapacity(d)
                var r = [CGGammaValue](repeating: 0, count: Int(cap)), gg = r, bb = r; var got: UInt32 = 0
                guard CGGetDisplayTransferByTable(d, cap, &r, &gg, &bb, &got) == .success else { continue }
                cache[d] = (r, gg, bb, got)
            }
            let (r, gg, bb, got) = cache[d]!
            CGSetDisplayTransferByTable(d, got, r, gg.map { $0 * Float(green) }, bb.map { $0 * Float(blue) })
        }
    }
}

let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
let enc: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
func runStatus(_ exe: String, _ args: [String]) -> (out: String, ok: Bool) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    do { try p.run() } catch { return ("error: \(error)", false) }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus == 0)
}
@discardableResult func cli(_ args: String...) -> String { runStatus(cliURL.path, args).out }

// MARK: - Screen shade overlay
final class ShadeOverlay {
    private var windows: [NSWindow] = []
    private(set) var current = Shade()
    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild(); self?.apply(self?.current ?? Shade())
        }
    }
    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            w.isOpaque = false; w.hasShadow = false; w.ignoresMouseEvents = true; w.isReleasedWhenClosed = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.backgroundColor = .clear; w.setFrame(screen.frame, display: false)
            return w
        }
    }
    func apply(_ s: Shade) {
        current = s
        if windows.count != NSScreen.screens.count { rebuild() }
        let alpha = s.enabled ? max(0, min(0.9, s.level)) : 0
        for w in windows { w.backgroundColor = NSColor(white: 0, alpha: alpha); if alpha > 0 { w.orderFrontRegardless() } else { w.orderOut(nil) } }
    }
}

// MARK: - Global hotkeys
final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false
    static let shared = HotKeys()
    static func carbonMods(_ mods: [String]) -> UInt32 {
        var m: UInt32 = 0
        for s in mods { switch s { case "command": m |= UInt32(cmdKey); case "option": m |= UInt32(optionKey); case "control": m |= UInt32(controlKey); case "shift": m |= UInt32(shiftKey); default: break } }
        return m
    }
    func register(_ list: [(Shortcut, () -> Void)]) {
        for r in refs { if let r = r { UnregisterEventHotKey(r) } }
        refs = []; handlers = [:]
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                HotKeys.shared.handlers[id.id]?()
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        for (i, (sc, fn)) in list.enumerated() {
            let id = EventHotKeyID(signature: OSType(0x4E464C4C /* NFLL */), id: UInt32(i + 1))
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(sc.keyCode), HotKeys.carbonMods(sc.modifiers), id, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref); handlers[UInt32(i + 1)] = fn
        }
    }
}
func keyName(_ code: Int) -> String {
    let special: [Int: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        115: "Home", 119: "End", 116: "PgUp", 121: "PgDn", 117: "⌦"]
    if let s = special[code] { return s }
    let letters: [Int: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
        18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",
        37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",50:"`"]
    return letters[code] ?? "key \(code)"
}
func describe(_ sc: Shortcut) -> String {
    var s = ""
    if sc.modifiers.contains("control") { s += "⌃" }; if sc.modifiers.contains("option") { s += "⌥" }
    if sc.modifiers.contains("shift") { s += "⇧" }; if sc.modifiers.contains("command") { s += "⌘" }
    return s + keyName(sc.keyCode)
}

// MARK: - Location (only ever used to compute sunrise and sunset; stays on this Mac)
final class Locator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onFix: ((Double, Double) -> Void)?
    var onDenied: (() -> Void)?
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers }
    func request() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways: manager.requestLocation()
        default: onDenied?()
        }
    }
    var status: CLAuthorizationStatus { manager.authorizationStatus }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorized || m.authorizationStatus == .authorizedAlways { m.requestLocation() }
        else if m.authorizationStatus == .denied || m.authorizationStatus == .restricted { onDenied?() }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        onFix?(l.coordinate.latitude, l.coordinate.longitude)
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { NSLog("location: \(error.localizedDescription)") }
}

// MARK: - Model
final class Model: ObservableObject {
    @Published var config = Config(latitude: 34.05, longitude: -118.24, locationSource: nil, fadeMinutes: 30, night: Settings(), dayDefaults: Settings(), learning: Learning(), shortcuts: Shortcuts())
    @Published var state: ModeState?
    @Published var learned = Learned()
    @Published var shade = Shade()
    @Published var sunLine = ""
    @Published var agentRunning = false
    @Published var enabled = false          // what the switch shows; set optimistically, then confirmed
    private var enabledPending = false
    @Published var launchAtLogin = false
    @Published var recording: String? = nil
    @Published var live = Settings()
    @Published var locationDenied = false
    var snapshotMode = false
    var snapshotDaylight = false      // --snapshot … daylight, to capture the daytime state
    let overlay = ShadeOverlay()
    let gamma = Gamma()
    let locator = Locator()
    let liveQueue = DispatchQueue(label: "redlight.live")
    private var source: DispatchSourceFileSystemObject?
    private var monitor: Any?
    private var refreshWork: DispatchWorkItem?
    var lastKeyboard: Double? = nil

    init() {
        refresh()
        let fd = open(appDir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleRefresh() }
            src.setCancelHandler { close(fd) }
            src.resume(); source = src
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        registerHotkeys()
        // Waking up: run a check right away so the lid opening at 11 PM never shows 60 s of daylight look.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.runCLI(["check"]); self?.locateIfAuto()
            }
        }
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in self?.locateIfAuto() }
        locator.onFix = { [weak self] la, lo in
            guard let self = self else { return }
            self.locationDenied = false
            self.runCLI(["location", String(format: "%.4f", la), String(format: "%.4f", lo), "auto"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runCLI(["check"]) }
        }
        locator.onDenied = { [weak self] in self?.locationDenied = true }
        locateIfAuto()
    }
    func locateIfAuto() { if config.locationSource != "manual" { locator.request() } }
    func useMyLocation() { config.locationSource = "auto"; saveConfig(reapply: false); locator.request() }

    func scheduleRefresh(after delay: TimeInterval = 0.12) {
        refreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    func refresh() {
        if let d = try? Data(contentsOf: configURL), let c = try? dec.decode(Config.self, from: d) {
            let hk = c.shortcuts ?? Shortcuts(), old = config.shortcuts ?? Shortcuts()
            config = c
            if hk.toggleShade != old.toggleShade || hk.shadeDown != old.shadeDown || hk.shadeUp != old.shadeUp { registerHotkeys() }
        }
        state = (try? Data(contentsOf: stateURL)).flatMap { try? dec.decode(ModeState.self, from: $0) }
        learned = (try? Data(contentsOf: learnedURL)).flatMap { try? dec.decode(Learned.self, from: $0) } ?? Learned()
        shade = (try? Data(contentsOf: shadeURL)).flatMap { try? dec.decode(Shade.self, from: $0) } ?? Shade()
        overlay.apply(shade)
        gamma.apply(blue: shade.gammaBlue ?? 1, green: shade.gammaGreen ?? 1)
        if #available(macOS 13, *) { launchAtLogin = SMAppService.mainApp.status == .enabled }
        liveQueue.async { [weak self] in
            let sun = cli("suntimes").trimmingCharacters(in: .whitespacesAndNewlines)
            let status = cli("status")
            let running = runStatus("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"]).ok
            DispatchQueue.main.async { guard let self = self else { return }; self.sunLine = sun; self.parseLive(status); self.agentRunning = running
                if !self.enabledPending { self.enabled = running } }
        }
    }
    var isNight: Bool { state?.mode == "night" }
    var isPaused: Bool { if let u = state?.pausedUntil { return u > Date() }; return false }
    var isFading: Bool { state?.ramp != nil }
    var sunriseText: String { switchTime(0) }
    var sunsetText: String { switchTime(1) }
    private func switchTime(_ i: Int) -> String {
        let parts = sunLine.components(separatedBy: "   ")
        guard parts.count > i else { return "" }
        return parts[i].components(separatedBy: "switch ").last?.replacingOccurrences(of: ")", with: "") ?? ""
    }

    func saveConfig(reapply: Bool = true) {
        try? enc.encode(config).write(to: configURL, options: .atomic)
        if reapply && isNight { runCLI(["reapply"]) } else { scheduleRefresh(after: 0.05) }
    }
    func runCLI(_ args: [String]) {
        liveQueue.async { [weak self] in
            _ = runStatus(cliURL.path, args)
            DispatchQueue.main.async { self?.scheduleRefresh(after: 0.05) }
        }
    }
    func force(_ mode: String) { runCLI([mode]) }
    func pause(_ arg: String) { runCLI(["pause", arg]) }
    func resume() { runCLI(["resume"]) }
    func forget() { runCLI(["forget"]) }
    func setShade(enabled: Bool? = nil, level: Double? = nil) {
        var s = shade
        if let e = enabled { s.enabled = e }
        if let l = level { s.level = max(0, min(0.9, l)); if l > 0 && enabled == nil { s.enabled = true } }
        shade = s; overlay.apply(s)
        try? enc.encode(s).write(to: shadeURL, options: .atomic)
    }
    /// Warmth: paint the gamma legs now for immediate feedback; the engine applies the tint leg and records it.
    func setWarmth(_ w: Double, final: Bool) {
        let c = warmthCurve(w)
        shade.warmth = w; shade.gammaBlue = c.blue; shade.gammaGreen = c.green
        gamma.apply(blue: c.blue, green: c.green)
        set("warmth", w <= 0 ? "off" : String(format: "%.1f", w * 100), final: final)
    }
    func setAgent(_ on: Bool) {
        enabled = on                        // the switch moves under the finger, not a second later
        enabledPending = true
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist").path
        liveQueue.async { [weak self] in
            guard let self = self else { return }
            if on {
                _ = runStatus("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist])
                _ = runStatus(cliURL.path, ["resume"])      // clears any pause and applies the look this hour calls for
            } else {
                _ = runStatus("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
                _ = runStatus(cliURL.path, ["day"])         // hand the normal display back straight away
            }
            let ok = runStatus("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"]).ok
            DispatchQueue.main.async {
                self.agentRunning = ok; self.enabled = ok; self.enabledPending = false
                self.scheduleRefresh(after: 0.05)
            }
        }
    }
    func setLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13, *) else { return }
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSLog("login item: \(error)") }
        refresh()
    }
    func registerHotkeys() {
        let hk = config.shortcuts ?? Shortcuts()
        HotKeys.shared.register([
            (hk.toggleShade, { [weak self] in guard let s = self else { return }; s.setShade(enabled: !s.shade.enabled) }),
            (hk.shadeDown, { [weak self] in guard let s = self else { return }
                let l = ((s.shade.enabled ? s.shade.level : 0) - 0.1).rounded(toPlaces: 2)
                if l <= 0 { s.setShade(enabled: false, level: 0) } else { s.setShade(enabled: true, level: l) } }),
            (hk.shadeUp, { [weak self] in guard let s = self else { return }
                s.setShade(enabled: true, level: ((s.shade.enabled ? s.shade.level : 0) + 0.1).rounded(toPlaces: 2)) }),
        ])
    }
    func startRecording(_ which: String) {
        stopRecording(); recording = which
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self else { return ev }
            if ev.keyCode == 53 { self.stopRecording(); return nil }
            var mods: [String] = []
            if ev.modifierFlags.contains(.control) { mods.append("control") }
            if ev.modifierFlags.contains(.option) { mods.append("option") }
            if ev.modifierFlags.contains(.shift) { mods.append("shift") }
            if ev.modifierFlags.contains(.command) { mods.append("command") }
            guard !mods.isEmpty else { NSSound.beep(); return nil }
            var hk = self.config.shortcuts ?? Shortcuts()
            let sc = Shortcut(keyCode: Int(ev.keyCode), modifiers: mods)
            switch which { case "toggleShade": hk.toggleShade = sc; case "shadeDown": hk.shadeDown = sc; default: hk.shadeUp = sc }
            self.config.shortcuts = hk; self.saveConfig(reapply: false); self.registerHotkeys(); self.stopRecording()
            return nil
        }
    }
    func stopRecording() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil; recording = nil }

    func parseLive(_ out: String) {
        guard let line = out.components(separatedBy: "\n").first(where: { $0.hasPrefix("current:") }) else { return }
        var l = Settings()
        for tok in line.dropFirst(8).split(separator: " ") {
            let kv = tok.split(separator: "=", maxSplits: 1).map(String.init); guard kv.count == 2 else { continue }
            switch kv[0] {
            case "warmth": l.warmth = Double(kv[1])
            case "kbBrightness": l.keyboardBrightness = Double(kv[1])
            case "kbIdleDim": l.keyboardIdleDimSeconds = Double(kv[1].replacingOccurrences(of: "s", with: ""))
            case "shade": l.shadeEnabled = kv[1] == "on"
            case "shadeLevel": l.shadeLevel = Double(kv[1])
            default: break
            }
        }
        if let v = l.keyboardBrightness { lastKeyboard = v } else { l.keyboardBrightness = lastKeyboard ?? live.keyboardBrightness }
        live = l
        if ProcessInfo.processInfo.environment["MIDNIGHT_DEBUG"] != nil {
            let line = "\(Date()) live warmth=\(l.warmth ?? -1) kb=\(l.keyboardBrightness ?? -1) idle=\(l.keyboardIdleDimSeconds ?? -1) shade=\(shade.enabled)/\(shade.level) | status: \(line)\n"
            if let h = try? FileHandle(forWritingTo: appDir.appendingPathComponent("debug-live.log")) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
            else { try? line.write(to: appDir.appendingPathComponent("debug-live.log"), atomically: true, encoding: .utf8) }
        }
    }
    func set(_ field: String, _ value: String, final: Bool = true) {
        switch field {
        case "keyboard": let v = value == "off" ? 0 : (Double(value) ?? 0) / 100; live.keyboardBrightness = v; lastKeyboard = v
        case "idle": live.keyboardIdleDimSeconds = Double(value)
        case "warmth": live.warmth = value == "off" ? 0 : (Double(value) ?? 0) / 100
        default: break
        }
        liveQueue.async { [weak self] in
            _ = cli("set", field, value)
            if final { DispatchQueue.main.async { self?.scheduleRefresh(after: 0.05) } }
        }
    }
    func applyPreset(_ p: Preset) { runCLI(["preset", "apply", p.name]) }
    func useAtNight(_ p: Preset) { runCLI(["preset", "night", p.name]) }
    func deletePreset(_ p: Preset) { runCLI(["preset", "delete", p.name]) }
    func saveCurrentAsPreset(_ name: String, icon: String) { runCLI(["preset", "save", name, icon]) }
    var nightPresetName: String? { config.nightPresetName }
}
extension Double { func rounded(toPlaces p: Int) -> Double { let m = pow(10.0, Double(p)); return (self * m).rounded() / m } }

// MARK: - Control Center design language (measured from the Battery panel at 2x)
enum CC {
    static let side: CGFloat = 12
    // macOS text styles, verbatim: .headline is 13 pt bold, .body 13 pt regular, .subheadline 11 pt regular.
    // A Control Center section header ("Output", "Energy Mode") is the subheadline size in semibold secondary.
    static let title    = Font.system(size: 13, weight: .bold)      // .headline
    static let row      = Font.system(size: 13)                     // .body
    static let small    = Font.system(size: 13)                     // .body
    static let subtitle = Font.system(size: 11)                     // .subheadline
    static let header   = Font.system(size: 11, weight: .semibold)  // section header
    static let value    = Font.system(size: 11, weight: .semibold)  // its right-hand value, same treatment
    // System colours, not opacities of our own choosing. labelColor is 84.7 % black, never pure black.
    static let label     = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let sep       = Color(nsColor: .separatorColor)
    static let circle    = Color(nsColor: .quaternaryLabelColor)
    static let symbol    = Color(nsColor: .secondaryLabelColor)
    /// The panel's own surface, used to wash out the controls behind the daylight notice.
    static let scrim = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.13, alpha: 0.86) : NSColor(white: 0.97, alpha: 0.86)
    })
}
struct Step: Identifiable { let label: String; let value: Double?; var id: String { label } }
// Denser above the 60 % knee, where blue is already gone and each step is a different feel of red.
let warmSteps  = [Step(label: "Off", value: nil), Step(label: "15%", value: 0.15), Step(label: "30%", value: 0.3), Step(label: "45%", value: 0.45),
                  Step(label: "60%", value: 0.6), Step(label: "70%", value: 0.7), Step(label: "80%", value: 0.8), Step(label: "90%", value: 0.9), Step(label: "100%", value: 1.0)]
// 0.1 % is the practical floor: the keyboard's PWM table bottoms out just beneath it and anything lower looks the same.
let keySteps   = [Step(label: "Off", value: nil), Step(label: "0.1%", value: 0.001), Step(label: "0.3%", value: 0.003), Step(label: "1%", value: 0.01), Step(label: "5%", value: 0.05), Step(label: "30%", value: 0.3)]
let shadeSteps = [Step(label: "Off", value: nil), Step(label: "20%", value: 0.2), Step(label: "40%", value: 0.4), Step(label: "60%", value: 0.6), Step(label: "80%", value: 0.8)]
let idleSteps  = [Step(label: "5 s", value: 5), Step(label: "10 s", value: 10), Step(label: "30 s", value: 30), Step(label: "1 min", value: 60), Step(label: "5 min", value: 300)]
func fmtSeconds(_ v: Double?) -> String {
    guard let v = v, v > 0 else { return "Off" }
    if v < 60 { return "\(Int(v)) s" }
    let m = v / 60; return m == m.rounded() ? "\(Int(m)) min" : String(format: "%.1f min", m)
}
func fmtPct(_ v: Double?) -> String { guard let v = v else { return "Off" }; let p = v * 100; return p < 0.1 ? String(format: "%.2f%%", p) : p < 1 ? String(format: "%.1f%%", p) : "\(Int(p.rounded()))%" }

struct Line: View { var body: some View { Rectangle().fill(CC.sep).frame(height: 1) } }
struct TitleBlock<Trailing: View>: View {
    let title: String; let subtitle: String; @ViewBuilder let trailing: () -> Trailing
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(title).font(CC.title).foregroundStyle(CC.label); Spacer(); trailing() }.frame(height: 32).padding(.top, 5)
            HStack { Text(subtitle).font(CC.subtitle).foregroundStyle(CC.secondary); Spacer() }.frame(height: 17)
            Line().padding(.top, 4.5)
        }
    }
}
struct Header: View {
    let text: String; var value: String? = nil
    var body: some View {
        HStack { Text(text).font(CC.header).foregroundStyle(CC.secondary); Spacer(); if let v = value { Text(v).font(CC.value).foregroundStyle(CC.secondary) } }
            .frame(height: 21).padding(.top, 8)
    }
}
struct IconRow: View {
    let icon: String; let label: String; var trailing: String? = nil; var active = false
    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(active ? Color(nsColor: .controlAccentColor) : CC.circle).frame(width: 26, height: 26)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(active ? Color.white : CC.symbol)
            }
            Text(label).font(CC.row).foregroundStyle(CC.label)
            Spacer()
            if let t = trailing { Text(t).font(CC.small).foregroundStyle(CC.secondary) }
        }
        .frame(height: 32).contentShape(Rectangle())
    }
}
struct GlassSlider: View {
    let minIcon: String; let maxIcon: String; let steps: [Step]; let current: Double?; let isOn: Bool
    let onChange: (Step, Bool) -> Void
    // The thumb is *derived* from `current` on every render. Only while the user is actually moving it does a
    // local override take over, and that override can never get stuck: it ends on AppKit's editing callback, or
    // half a second after the last movement, whichever comes first.
    @State private var dragIdx: Double? = nil
    @State private var lastSent = -1
    @State private var settle: DispatchWorkItem? = nil
    private var offIndex: Double { Double(steps.firstIndex { $0.value == nil } ?? 0) }
    private var useLog: Bool {
        let v = steps.compactMap { $0.value }.filter { $0 > 0 }
        guard let lo = v.min(), let hi = v.max(), lo > 0 else { return false }
        return hi / lo > 20
    }
    private var truePosition: Double {
        guard isOn, let v = current, v > 0 else { return offIndex }
        let marks: [(Double, Double)] = steps.enumerated().compactMap { i, s in s.value.map { (Double(i), $0) } }
        guard let first = marks.first, let last = marks.last else { return offIndex }
        if v <= first.1 { return offIndex + (first.0 - offIndex) * max(0, min(1, v / first.1)) }
        if v >= last.1 { return last.0 }
        for k in 0..<(marks.count - 1) {
            let (i0, v0) = marks[k], (i1, v1) = marks[k + 1]
            if v >= v0 && v <= v1 {
                let t = useLog ? (log(v) - log(v0)) / (log(v1) - log(v0)) : (v - v0) / (v1 - v0)
                return i0 + (i1 - i0) * t
            }
        }
        return last.0
    }
    private func finish() {
        settle?.cancel(); settle = nil
        guard let v = dragIdx else { return }
        let i = Int(v.rounded())
        dragIdx = nil; lastSent = -1
        onChange(steps[i], true)
    }
    var body: some View {
        let position = Binding<Double>(
            get: { dragIdx ?? truePosition },
            set: { v in
                dragIdx = v
                let i = Int(v.rounded())
                if i != lastSent { lastSent = i; onChange(steps[i], false) }
                settle?.cancel()
                let w = DispatchWorkItem { finish() }
                settle = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
            })
        HStack(spacing: 10) {
            Image(systemName: minIcon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
            Slider(value: position, in: 0...Double(max(1, steps.count - 1))) { editing in if !editing { finish() } }
                .controlSize(.large)
            Image(systemName: maxIcon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
        }
    }
}
struct SliderRow: View {
    let minIcon: String; let maxIcon: String; let steps: [Step]; let current: Double?; let isOn: Bool
    let onChange: (Step, Bool) -> Void
    var body: some View { GlassSlider(minIcon: minIcon, maxIcon: maxIcon, steps: steps, current: current, isOn: isOn, onChange: onChange).frame(height: 32) }
}
struct SectionEnd: View { var body: some View { Line().padding(.top, 5.5) } }
struct TextRow: View {
    let text: String; var secondary = false
    var body: some View {
        if secondary {
            // explanatory line: .subheadline secondary, wrapping to as many lines as it needs
            HStack(alignment: .top) {
                Text(text).font(CC.subtitle).foregroundStyle(CC.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.vertical, 5)
        } else {
            HStack { Text(text).font(CC.small).foregroundStyle(CC.label); Spacer() }.frame(height: 33).contentShape(Rectangle())
        }
    }
}
struct SettingsRow: View {
    let text: String
    var body: some View { HStack { Text(text).font(CC.small).foregroundStyle(CC.label); Spacer() }.frame(height: 30).padding(.bottom, 1.5).contentShape(Rectangle()) }
}
/// The system switch, or — only while exporting a documentation image — an identical drawing of it.
struct SwitchView: View {
    let isOn: Binding<Bool>; var small = false; var drawn = false
    var body: some View {
        if drawn {
            let w: CGFloat = small ? 32 : 38, h: CGFloat = small ? 18 : 22
            ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                Capsule().fill(isOn.wrappedValue ? Color.accentColor : Color.primary.opacity(0.18)).frame(width: w, height: h)
                Circle().fill(.white).frame(width: h - 4, height: h - 4).shadow(color: .black.opacity(0.25), radius: 1, y: 1).padding(2)
            }
        } else if small {
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        } else {
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}
struct PillButton: View {
    let title: String; var prominent = false; var drawn = false; let action: () -> Void
    var body: some View {
        if drawn {
            Text(title).font(CC.small).foregroundStyle(prominent ? Color.white : .primary)
                .padding(.horizontal, 12).frame(height: 26)
                .background(Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.14)))
        } else if prominent {
            Button(title) { action() }.buttonStyle(.glassProminent).controlSize(.small)
        } else {
            Button(title) { action() }.buttonStyle(.glass).controlSize(.small)
        }
    }
}
struct ToggleRow: View {
    let label: String; let isOn: Binding<Bool>; var drawn = false
    var body: some View { HStack { Text(label).font(CC.row).foregroundStyle(CC.label); Spacer(); SwitchView(isOn: isOn, small: true, drawn: drawn) }.frame(height: 32) }
}

// MARK: - Main panel
struct Panel: View {
    @ObservedObject var m: Model
    @State private var page = "main"
    var body: some View {
        GlassEffectContainer(spacing: 12) {
            Group { if page == "main" { mainPage } else { SettingsPage(m: m, back: { page = "main" }) } }
        }
        .frame(width: 303)
        .onAppear { m.refresh() }
    }
    // Daylight: the controls are behind glass, because nothing is being applied until the sun goes down.
    // The title and its switch stay live so the app can still be turned off; one tap clears the glass.
    @State private var overlayDismissed = false
    var daylight: Bool { m.snapshotDaylight || (!m.isNight && !overlayDismissed && !m.snapshotMode) }

    var mainPage: some View {
        VStack(spacing: 0) {
            TitleBlock(title: "Red Light", subtitle: subtitle) {
                SwitchView(isOn: Binding(get: { m.enabled }, set: { m.setAgent($0) }), drawn: m.snapshotMode)
            }
            ZStack {
                controls
                    .blur(radius: daylight ? 9 : 0)
                    .opacity(daylight ? 0.4 : 1)
                    .allowsHitTesting(!daylight)
                if daylight { daylightNotice }
            }
            .animation(.easeInOut(duration: 0.18), value: daylight)
        }
        .padding(.horizontal, CC.side)
        .onChange(of: m.isNight) { night in if night { overlayDismissed = false } }
    }

    var daylightNotice: some View {
        VStack(spacing: 3) {
            Text("Waiting for sunset").font(CC.title).foregroundStyle(CC.label)
            Text(m.enabled ? (m.sunsetText.isEmpty ? "Red Light starts at sunset" : "Red Light starts at \(m.sunsetText)")
                           : "Turn on above to start at sunset")
                .font(CC.subtitle).foregroundStyle(CC.secondary)
            Text("Tap to use it anyway").font(CC.subtitle).foregroundStyle(Color(nsColor: .tertiaryLabelColor)).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CC.scrim)
        .contentShape(Rectangle())
        .onTapGesture { overlayDismissed = true }
    }

    @ViewBuilder var controls: some View {
        VStack(spacing: 0) {
            Header(text: "Red Shift", value: (m.live.warmth ?? 0) > 0.001 ? fmtPct(m.live.warmth) : "Off")
            SliderRow(minIcon: "sun.max", maxIcon: "moon.fill", steps: warmSteps, current: m.live.warmth, isOn: (m.live.warmth ?? 0) > 0.001) { s, final in
                m.setWarmth(s.value ?? 0, final: final) }
            SectionEnd()

            Header(text: "Screen Shade", value: m.shade.enabled ? fmtPct(m.shade.level) : "Off")
            SliderRow(minIcon: "sun.max", maxIcon: "circle.lefthalf.filled", steps: shadeSteps, current: m.shade.level, isOn: m.shade.enabled) { s, _ in
                if let v = s.value { m.setShade(enabled: true, level: v) } else { m.setShade(enabled: false) } }
            SectionEnd()

            Header(text: "Keyboard Backlight", value: (m.live.keyboardBrightness ?? 0) > 0 ? fmtPct(m.live.keyboardBrightness) : "Off")
            SliderRow(minIcon: "light.min", maxIcon: "light.max", steps: keySteps, current: m.live.keyboardBrightness, isOn: (m.live.keyboardBrightness ?? 0) > 0) { s, final in
                m.set("keyboard", s.value.map { String($0 * 100) } ?? "off", final: final) }
            Header(text: "Turn Off After Inactivity", value: fmtSeconds(m.live.keyboardIdleDimSeconds))
            SliderRow(minIcon: "timer", maxIcon: "clock", steps: idleSteps, current: m.live.keyboardIdleDimSeconds, isOn: true) { s, final in
                m.set("idle", String(Int(s.value ?? 5)), final: final) }
            SectionEnd()

            Header(text: "Presets")
            let list = m.config.presets ?? []
            if list.isEmpty { TextRow(text: "No presets yet", secondary: true) }
            ForEach(list) { p in
                IconRow(icon: p.icon, label: p.name, trailing: m.nightPresetName == p.name ? "At sunset" : nil, active: isCurrent(p))
                    .onTapGesture { m.applyPreset(p) }
                    .contextMenu {
                        Button("Apply") { m.applyPreset(p) }
                        Button("Use at Sunset") { m.useAtNight(p) }.disabled(m.nightPresetName == p.name)
                        Button("Replace with Current Look") { m.saveCurrentAsPreset(p.name, icon: p.icon) }
                        Divider()
                        Button("Delete") { m.deletePreset(p) }
                    }
            }
            saveRow.padding(.top, 4)
            SectionEnd()

            if m.enabled {
                Header(text: m.isPaused ? "Paused" : "Pause")
                if m.isPaused {
                    IconRow(icon: "play.fill", label: "Resume Red Light").onTapGesture { m.resume() }
                } else {
                    IconRow(icon: "pause.fill", label: "For an Hour").onTapGesture { m.pause("60") }
                    IconRow(icon: "sunrise.fill", label: "Until Sunrise").onTapGesture { m.pause("sunrise") }
                }
                SectionEnd()
            }

            SettingsRow(text: "Red Light Settings…").onTapGesture { page = "settings" }
        }
    }
    var subtitle: String {
        if m.isPaused && !m.snapshotMode, let u = m.state?.pausedUntil {
            let f = DateFormatter(); f.timeStyle = .short; return "Paused until \(f.string(from: u))"
        }
        guard m.agentRunning else { return "Manual" }
        if m.isFading { return m.isNight ? "Sunset in progress" : "Sunrise in progress" }
        if m.isNight { return m.sunriseText.isEmpty ? "Night" : "Night · Sunrise at \(m.sunriseText)" }
        return m.sunsetText.isEmpty ? "Day" : "Day · Sunset at \(m.sunsetText)"
    }
    func isCurrent(_ p: Preset) -> Bool {
        let s = p.settings
        let kbOK = abs((s.keyboardBrightness ?? 0) - (m.live.keyboardBrightness ?? 0)) < 0.0015
        let shadeOK = (s.shadeEnabled ?? false) == m.shade.enabled && (!m.shade.enabled || abs((s.shadeLevel ?? 0) - m.shade.level) < 0.02)
        let warmOK = abs((s.warmth ?? 0) - (m.live.warmth ?? 0)) < 0.03
        return kbOK && shadeOK && warmOK
    }
    @State private var newName = ""
    @State private var saving = false
    var saveRow: some View {
        Group {
            if saving {
                HStack(spacing: 9) {
                    ZStack { Circle().fill(CC.circle).frame(width: 26, height: 26); Image(systemName: "plus").font(.system(size: 13, weight: .medium)) }
                    TextField("Name", text: $newName).textFieldStyle(.plain).font(CC.row).onSubmit { commitSave() }
                    Button("Save") { commitSave() }.buttonStyle(.glassProminent).controlSize(.small).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button { saving = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }.frame(height: 32)
            } else {
                IconRow(icon: "plus", label: "Save Current Look…").onTapGesture { saving = true; newName = "" }
            }
        }
    }
    func commitSave() { let n = newName.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }; m.saveCurrentAsPreset(n, icon: "star.fill"); saving = false }
}

// MARK: - Settings page
struct SettingsPage: View {
    @ObservedObject var m: Model
    let back: () -> Void
    @State private var lat = ""; @State private var lon = ""
    @State private var editingLocation = false
    let fades: [(String, Double)] = [("Instant", 0), ("10 min", 10), ("20 min", 20), ("30 min", 30), ("45 min", 45), ("1 hr", 60)]
    var body: some View {
        VStack(spacing: 0) {
            TitleBlock(title: "Red Light Settings", subtitle: "Sunrise \(m.sunriseText) · Sunset \(m.sunsetText)") {
                PillButton(title: "Done", drawn: m.snapshotMode) { back() }
            }

            Header(text: "Sun")
            ToggleRow(label: "Switch at Sunset and Sunrise", isOn: Binding(get: { m.agentRunning }, set: { m.setAgent($0) }), drawn: m.snapshotMode)
            HStack {
                Text("Location").font(CC.row).foregroundStyle(CC.label); Spacer()
                Text(locationLabel).font(CC.small).foregroundStyle(.secondary)
            }.frame(height: 32)
            if m.locationDenied && m.config.locationSource != "manual" {
                TextRow(text: "Location access is off. Allow it in System Settings › Privacy & Security › Location Services, or enter coordinates.", secondary: true)
            }
            HStack(spacing: 8) {
                PillButton(title: "Use My Location", drawn: m.snapshotMode) { m.useMyLocation() }
                PillButton(title: editingLocation ? "Cancel" : "Enter Manually…", drawn: m.snapshotMode) { editingLocation.toggle() }
                Spacer()
            }.frame(height: 32)
            if editingLocation {
                HStack(spacing: 8) {
                    TextField("Latitude", text: $lat); TextField("Longitude", text: $lon)
                    Button("Set") {
                        if let a = Double(lat), let o = Double(lon) { m.runCLI(["location", String(a), String(o), "manual"]); m.runCLI(["check"]); editingLocation = false }
                    }.buttonStyle(.glassProminent)
                }.textFieldStyle(.roundedBorder).controlSize(.small).frame(height: 32)
            }
            HStack {
                Text("Transition").font(CC.row).foregroundStyle(CC.label); Spacer()
                Picker("", selection: Binding(get: { m.config.fadeMinutes ?? 30 }, set: { m.config.fadeMinutes = $0; m.saveConfig(reapply: false) })) {
                    ForEach(fades, id: \.1) { Text($0.0).tag($0.1) }
                }.labelsHidden().controlSize(.small).frame(width: 96)
            }.frame(height: 32)
            TextRow(text: m.nightPresetName.map { "Sunset eases into “\($0)”" } ?? "Sunset eases into a custom mix", secondary: true)
            Line()

            Header(text: "Learning")
            ToggleRow(label: "Adapt to My Adjustments", isOn: Binding(get: { m.config.learning?.enabled ?? true }, set: { var l = m.config.learning ?? Learning(); l.enabled = $0; m.config.learning = l; m.saveConfig(reapply: false) }), drawn: m.snapshotMode)
            if m.learned.history.isEmpty {
                TextRow(text: "Adopts what you keep choosing after three similar nights", secondary: true)
            } else {
                ForEach(m.learned.history.suffix(3).reversed(), id: \.self) { TextRow(text: $0, secondary: true) }
                TextRow(text: "Forget Everything Learned").onTapGesture { m.forget() }
            }
            Line()

            Header(text: "Keyboard Shortcuts")
            shortcutRow("Toggle Shade", "toggleShade", (m.config.shortcuts ?? Shortcuts()).toggleShade)
            shortcutRow("Shade Darker", "shadeUp", (m.config.shortcuts ?? Shortcuts()).shadeUp)
            shortcutRow("Shade Lighter", "shadeDown", (m.config.shortcuts ?? Shortcuts()).shadeDown)
            if m.recording != nil { TextRow(text: "Press a key combination. Esc cancels.", secondary: true) }
            SectionEnd()

            Header(text: "General")
            ToggleRow(label: "Open at Login", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }), drawn: m.snapshotMode)
            SectionEnd()
            TextRow(text: "Show Files in Finder").onTapGesture { NSWorkspace.shared.open(appDir) }
            Line()
            TextRow(text: "View Log").onTapGesture { NSWorkspace.shared.open(appDir.appendingPathComponent("redlight.log")) }
            Line()
            SettingsRow(text: "Quit Red Light").onTapGesture { NSApp.terminate(nil) }
        }
        .padding(.horizontal, CC.side)
        .onAppear { lat = String(m.config.latitude); lon = String(m.config.longitude) }
        .onDisappear { m.stopRecording() }
    }
    var locationLabel: String {
        let c = String(format: "%.2f, %.2f", m.config.latitude, m.config.longitude)
        switch m.config.locationSource { case "auto": return "\(c) · from this Mac"; case "manual": return "\(c) · manual"; default: return "\(c) · guessed from time zone" }
    }
    func shortcutRow(_ label: String, _ key: String, _ sc: Shortcut) -> some View {
        HStack { Text(label).font(CC.row).foregroundStyle(CC.label); Spacer()
            PillButton(title: m.recording == key ? "Recording…" : describe(sc), drawn: m.snapshotMode) { m.recording == key ? m.stopRecording() : m.startRecording(key) }
        }.frame(height: 32)
    }
}

// MARK: - App
func enforceSingleInstance() {
    let me = NSRunningApplication.current
    let others = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == me.bundleIdentifier && $0.processIdentifier != me.processIdentifier }
    if !others.isEmpty { NSApp.terminate(nil); exit(0) }
}
/// `Red Light --snapshot out.png [settings]` renders the panel to a PNG for documentation, off-screen, in dark
/// appearance, on a dark backdrop. No screen-recording grant is needed; system glass is not part of the view.
func snapshotIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
    let out = URL(fileURLWithPath: args[i + 1])
    let page = args.contains("settings") ? "settings" : "main"
    let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
    let model = Model(); model.snapshotMode = true; model.snapshotDaylight = args.contains("daylight")
    // Let the live values (read through the engine, off the main thread) land before the view first appears,
    // so every slider and switch is created already showing the real state.
    model.refresh()
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        model.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let ap = NSAppearance(named: args.contains("light") ? .aqua : .darkAqua)
            let host = NSHostingView(rootView: SnapshotRoot(m: model, page: page, light: args.contains("light")))
            host.appearance = ap
            host.frame = NSRect(x: 0, y: 0, width: 303, height: 10)
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.appearance = ap
            win.isOpaque = false; win.backgroundColor = .clear; win.contentView = host; win.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let size = host.fittingSize
                host.frame = NSRect(origin: .zero, size: size); win.setContentSize(size)
                host.layoutSubtreeIfNeeded(); host.display(); win.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))   // let AppKit controls settle on their values
                host.display()
                let scale: CGFloat = 2
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
                print("wrote \(out.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
                exit(0)
            }
        }
    }
    app.run()
}
struct SnapshotRoot: View {
    @ObservedObject var m: Model; let page: String; var light = false
    var body: some View {
        Group { if page == "main" { Panel(m: m) } else { SettingsPage(m: m, back: {}) .frame(width: 303) } }
            .fixedSize(horizontal: false, vertical: true)
            // stands in for the system glass in the export, at the tone each appearance shows through it
            .background(light ? Color(white: 0.96) : Color(white: 0.13))
    }
}

@main
struct RedLightApp: App {
    @StateObject var model = Model()
    init() { snapshotIfRequested(); enforceSingleInstance() }
    var body: some Scene {
        MenuBarExtra {
            Panel(m: model)
        } label: {
            // The sun slipping below the horizon — what the app is named for.
            Image(systemName: model.isPaused ? "pause.circle" : (model.isNight ? "sunset.fill" : "sunset"))
        }
        .menuBarExtraStyle(.window)
    }
}
