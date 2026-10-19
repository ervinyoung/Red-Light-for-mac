import SwiftUI
import AppKit
import Carbon
import CoreLocation
import ServiceManagement
import CryptoKit
import IOKit

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
/// True colour for colour-critical apps: ask, or remember per app (bundle identifiers).
struct TrueColor: Codable { var ask = true; var always: [String] = []; var never: [String] = [] }
/// Let the room's light set Red Shift at night: the level you last chose in each kind of room (the engine's `roomKind`).
struct RoomLight: Codable { var enabled = true; var levels = RoomLevels() }
struct RoomLevels: Codable { var dark = 0.65; var dim = 0.25; var lit = 0.0 }
struct Config: Codable {
    var latitude: Double; var longitude: Double; var locationSource: String?; var fadeMinutes: Double?
    var night: Settings; var dayDefaults: Settings
    var learning: Learning?; var shortcuts: Shortcuts?; var presets: [Preset]?; var nightPresetName: String?
    var trueColor: TrueColor?; var roomLight: RoomLight?
}
// A hand-edited block with a key left out (`"trueColor": {"always": [...]}`) must not make the whole file unreadable:
// the pane would show built-in defaults and refuse to save. What is missing or malformed takes its default.
extension Learning {
    init(from d: Decoder) throws {
        self.init(); guard let c = try? d.container(keyedBy: CodingKeys.self) else { return }
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? enabled
        minNights = (try? c.decodeIfPresent(Int.self, forKey: .minNights)) ?? minNights
        lookbackDays = (try? c.decodeIfPresent(Int.self, forKey: .lookbackDays)) ?? lookbackDays
        maxOffsetMinutes = (try? c.decodeIfPresent(Double.self, forKey: .maxOffsetMinutes)) ?? maxOffsetMinutes
    }
}
extension Shortcuts {
    init(from d: Decoder) throws {
        self.init(); guard let c = try? d.container(keyedBy: CodingKeys.self) else { return }
        toggleShade = (try? c.decodeIfPresent(Shortcut.self, forKey: .toggleShade)) ?? toggleShade
        shadeDown = (try? c.decodeIfPresent(Shortcut.self, forKey: .shadeDown)) ?? shadeDown
        shadeUp = (try? c.decodeIfPresent(Shortcut.self, forKey: .shadeUp)) ?? shadeUp
    }
}
extension RoomLight {
    init(from d: Decoder) throws {
        self.init(); guard let c = try? d.container(keyedBy: CodingKeys.self) else { return }
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? enabled
        levels = (try? c.decodeIfPresent(RoomLevels.self, forKey: .levels)) ?? levels
    }
}
extension RoomLevels {
    init(from d: Decoder) throws {
        self.init(); guard let c = try? d.container(keyedBy: CodingKeys.self) else { return }
        dark = (try? c.decodeIfPresent(Double.self, forKey: .dark)) ?? dark
        dim = (try? c.decodeIfPresent(Double.self, forKey: .dim)) ?? dim
        lit = (try? c.decodeIfPresent(Double.self, forKey: .lit)) ?? lit
    }
}
extension TrueColor {
    init(from d: Decoder) throws {
        self.init(); guard let c = try? d.container(keyedBy: CodingKeys.self) else { return }
        ask = (try? c.decodeIfPresent(Bool.self, forKey: .ask)) ?? ask
        always = (try? c.decodeIfPresent([String].self, forKey: .always)) ?? always
        never = (try? c.decodeIfPresent([String].self, forKey: .never)) ?? never
    }
}
struct Ramp: Codable { var start: Date; var seconds: Double; var from: Settings; var to: Settings; var label: String }
/// Written only by the engine. `disabled` is the master switch; `heldFor` names the app holding true colour.
struct ModeState: Codable { var mode: String; var daySnapshot: Settings?; var lastSeen: Settings?; var lastNotified: Date?; var ramp: Ramp?; var pausedUntil: Date?
    var disabled: Bool?; var heldFor: String?; var room: Room? }
/// The room as the engine last set it: its `kind` (dark, dim or lit) and that kind's level; `lux` is -1 with no reading.
struct Room: Codable { var lux: Double; var target: Double; var darkness: Double; var at: Date; var kind: String? }
struct Learned: Codable {
    var sunsetOffsetMinutes = 0.0; var sunriseOffsetMinutes = 0.0
    var nightKeyboardBrightness: Double?; var nightIdleDimSeconds: Double?; var nightShadeLevel: Double?; var nightWarmth: Double?
    var history: [String] = []
}
/// `warmth` is what is drawn; `base` the chosen warmth beneath a dark room's lift. `ease`/`easeAt`: draw this warmth
/// gradually (see Model.drawLook); `tintDeferred`: the tint leg too. Kept through every round trip here.
struct Shade: Codable { var enabled = false; var level = 0.3; var warmth: Double? = 0; var gammaBlue: Double? = 1; var gammaGreen: Double? = 1; var base: Double?
    var ease: Double?; var easeAt: Double?; var tintDeferred: Bool? }
/// The Color Tint leg of Red Shift, which the app draws while it eases a change (the engine sets it otherwise).
enum Tint {
    private static let ma = dlopen("/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility", RTLD_NOW)
    private static func sym<T>(_ n: String, _ t: T.Type) -> T? { ma.flatMap { dlsym($0, n) }.map { unsafeBitCast($0, to: t) } }
    private static let setEnabled = sym("MADisplayFilterPrefSetCategoryEnabled", (@convention(c) (Int, Bool) -> Void).self)
    private static let setIntensity = sym("MADisplayFilterPrefSetSingleColorIntensity", (@convention(c) (Double) -> Void).self)
    static func set(_ t: Double) { setIntensity?(t); setEnabled?(1, t > 0.001) }
}

/// Same curve as the engine, kept here only so a slider drag can paint the gamma legs without waiting on a process.
func warmthCurve(_ w: Double) -> (blue: Double, green: Double, tint: Double) {
    let w = max(0, min(1, w))
    if w <= 0.6 { let t = w / 0.6; return (1 - t, 1 - 0.40 * t, 0) }
    let t = (w - 0.6) / 0.4
    return (0, 0.60 - 0.25 * t, 0.50 * t)
}

/// A documentation render (`--snapshot`) is a second process; it must never touch the real display.
let isSnapshotRun = CommandLine.arguments.contains("--snapshot")

// MARK: - Gamma legs of warmth (channel scaling at the display's transfer table)
final class Gamma {
    private var cache: [CGDirectDisplayID: ([CGGammaValue], [CGGammaValue], [CGGammaValue], UInt32)] = [:]
    /// Displays with no transfer table to scale (Sidecar, AirPlay, some adapters). Without this they never get a cache
    /// entry, so every apply restored ColorSync on all displays and verify() redrew every 2 s: a flicker while warm.
    private var noTable: Set<CGDirectDisplayID> = []
    private(set) var blue: Double = 1, green: Double = 1
    init() {
        guard !isSnapshotRun else { return }
        CGDisplayRestoreColorSyncSettings()
        // No restore of its own here: by day it wiped other apps' and calibrators' tables at every wake. While warm,
        // apply() restores anyway before it reads a fresh baseline, since the emptied cache has none.
        let reapply: (Notification) -> Void = { [weak self] _ in
            guard let self = self else { return }
            self.cache = [:]; self.noTable = []; self.apply(blue: self.blue, green: self.green)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: reapply)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: reapply)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: reapply)
    }
    func apply(blue b: Double, green g: Double) {
        guard !isSnapshotRun else { return }
        blue = max(0, min(1, b)); green = max(0, min(1, g))
        if blue >= 0.999 && green >= 0.999 {
            // Undo only what we did. Restoring on every refresh all day long would wipe any other app's (or a
            // calibrator's) tables once a minute; the cache is non-empty exactly while our tables are on screen.
            if !cache.isEmpty { CGDisplayRestoreColorSyncSettings(); cache = [:] }
            return
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        // The baseline must be the display's own ColorSync table, never whatever is on it now: reading a table
        // that already carries a scaling (ours from before, or a process that just quit) applied red twice.
        let displays = ids.prefix(Int(n)).filter { !noTable.contains($0) }
        if displays.contains(where: { cache[$0] == nil }) { CGDisplayRestoreColorSyncSettings() }
        for d in displays {
            if cache[d] == nil {
                let cap = CGDisplayGammaTableCapacity(d)
                var r = [CGGammaValue](repeating: 0, count: Int(cap)), gg = r, bb = r; var got: UInt32 = 0
                guard CGGetDisplayTransferByTable(d, cap, &r, &gg, &bb, &got) == .success, got > 0 else { noTable.insert(d); continue }
                cache[d] = (r, gg, bb, got)
            }
            let (r, gg, bb, got) = cache[d]!
            CGSetDisplayTransferByTable(d, got, r, gg.map { $0 * Float(green) }, bb.map { $0 * Float(blue) })
        }
    }
    /// Something else can put the tables back — a process that used them quitting, ColorSync, a display waking —
    /// without any notification. Every couple of seconds, check the top of each table is what we last set.
    func verify() {
        guard !isSnapshotRun, blue < 0.999 || green < 0.999 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        for d in ids.prefix(Int(n)) where !noTable.contains(d) {
            guard let (_, gg, bb, got) = cache[d], got > 0 else { apply(blue: blue, green: green); return }
            let cap = CGDisplayGammaTableCapacity(d)
            var r = [CGGammaValue](repeating: 0, count: Int(cap)), g2 = r, b2 = r; var now: UInt32 = 0
            guard CGGetDisplayTransferByTable(d, cap, &r, &g2, &b2, &now) == .success, now == got else { continue }
            let i = Int(got) - 1
            if abs(g2[i] - gg[i] * Float(green)) > 0.004 || abs(b2[i] - bb[i] * Float(blue)) > 0.004 {
                cache = [:]; apply(blue: blue, green: green); return
            }
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
/// Runs `body` holding the engine's own lock (flock on .lock), for a read-modify-write of a file the engine writes too.
/// Bounded the way the engine bounds its wait, so a hung engine run can't wedge the app.
func withEngineLock(_ body: () -> Void) {
    let fd = open(appDir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
    var waited = 0
    while fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 && waited < 500 { usleep(20_000); waited += 1 }
    body()
    if fd >= 0 { close(fd) }                // closing releases the lock
}

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
        guard !isSnapshotRun else { return }
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

// MARK: - True colour for colour-critical apps
/// Where colour is the work. Anything that files itself under graphics & design or photography counts too; "video"
/// does not, because players and Zoom file themselves there, and a movie at night should stay red.
let colorCriticalPrefixes = ["com.figma.", "com.bohemiancoding.sketch", "com.adobe.Photoshop", "com.adobe.illustrator",
    "com.adobe.InDesign", "com.adobe.Lightroom", "com.adobe.lightroom", "com.adobe.AfterEffects", "com.adobe.PremierePro",
    "com.adobe.xd", "com.seriflabs.affinity", "com.canva.affinity", "com.pixelmatorteam.pixelmator", "com.apple.FinalCut",
    "com.apple.motionapp", "com.blackmagic-design.DaVinciResolve", "com.captureone.", "com.phaseone.captureone",
    "org.blenderfoundation.blender", "com.framer.", "com.apple.ColorSyncUtility", "com.apple.DigitalColorMeter",
    "com.linearity.curve", "com.kiwi.Kiwi", "com.spline.", "design.penpot", "com.lunacy."]
let colorCriticalCategories = ["public.app-category.graphics-design", "public.app-category.photography"]
/// Apps that file themselves that way but are for looking, not for colour work.
let colorCriticalExceptions = ["com.apple.Photos", "com.apple.Preview", "com.apple.QuickTimePlayerX", "com.apple.TV", "com.apple.PhotoBooth", "com.apple.Image_Capture"]

func isColorCritical(_ app: NSRunningApplication) -> Bool {
    guard let id = app.bundleIdentifier, !colorCriticalExceptions.contains(id) else { return false }
    if colorCriticalPrefixes.contains(where: { id.hasPrefix($0) }) { return true }
    guard let url = app.bundleURL, let info = Bundle(url: url)?.infoDictionary,
          let cat = info["LSApplicationCategoryType"] as? String else { return false }
    return colorCriticalCategories.contains(cat)
}

/// Watches the frontmost app. In a colour-critical app at night it asks — once a night per app — whether to show
/// true colour while that app is in front, remembers the answer if asked to, and gives the red back when you leave.
final class TrueColorWatcher {
    struct Remembered { let id: String; let name: String; let always: Bool }
    private unowned let m: Model
    private var askedTonight: Set<String> = []
    private var declinedHere: String?          // "Bring Red Light Back" pressed while this app stays in front
    private var lastFront: String?             // the last app in front other than this one (opening the pane activates us)
    private var releaseWork: DispatchWorkItem?
    private var askedNight: Date?              // the evening askedTonight belongs to
    private var promptFor: String?             // the app the card on screen is asking about
    private let prompt = TrueColorPrompt()
    init(model: Model) {
        m = model
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.consider(app)
        }
    }
    private var policy: TrueColor { m.config.trueColor ?? TrueColor() }
    var remembered: [Remembered] {
        let p = policy
        func name(_ id: String) -> String {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return (p.always.map { Remembered(id: $0, name: name($0), always: true) } + p.never.map { Remembered(id: $0, name: name($0), always: false) })
            .sorted { $0.name < $1.name }
    }
    func remember(_ id: String, always: Bool) {
        var t = policy
        t.always.removeAll { $0 == id }; t.never.removeAll { $0 == id }
        if always { t.always.append(id) } else { t.never.append(id) }
        m.config.trueColor = t; m.saveConfig(reapply: false)
    }
    func forget(_ id: String) {
        var t = policy; t.always.removeAll { $0 == id }; t.never.removeAll { $0 == id }
        m.config.trueColor = t; m.saveConfig(reapply: false)
    }
    /// Called on every refresh: a new night clears the once-a-night memory, and if red light has just begun
    /// while a colour-critical app is already in front, that app gets the same treatment as if it had just opened.
    /// A night is the evening's date (1 AM still belongs to the night before), not a change of mode: a pause or
    /// off-and-on mid-evening goes through "day" and asked again, and a lid shut from 1 AM until the next evening
    /// never sees "day" at all, so it never asked again.
    func reconsider() {
        guard !m.snapshotMode else { return }
        let night = Calendar.current.startOfDay(for: Date().addingTimeInterval(-12 * 3600))
        if night != askedNight { askedTonight = []; askedNight = night }
        if let app = NSWorkspace.shared.frontmostApplication { consider(app) }
    }
    /// The pane's button is pressed with the pane in front, so the app being declined is the one that was in front
    /// before it — not the frontmost app, which is this one.
    func bringBack() {
        declinedHere = m.heldFor.flatMap { _ in lastFront ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        m.release()
    }
    private func consider(_ app: NSRunningApplication) {
        guard !m.snapshotMode, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }   // opening this pane changes nothing
        lastFront = id
        if declinedHere != nil && declinedHere != id { declinedHere = nil }
        guard isColorCritical(app) else {
            prompt.hide()
            guard m.heldFor != nil else { return }
            // A glance at a message shouldn't flash the room red and back: give it a moment.
            releaseWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self = self, let front = NSWorkspace.shared.frontmostApplication,
                      front.bundleIdentifier == Bundle.main.bundleIdentifier || !isColorCritical(front) else { return }
                if self.m.heldFor != nil { self.m.release() }
            }
            releaseWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
            return
        }
        releaseWork?.cancel()
        // Straight from one colour app to another inside the card's 20 s: the card is about the app you left, and
        // answering it would do nothing (the hold needs its app in front). Take it down and ask about this one.
        if prompt.isShowing, promptFor != id { prompt.hide() }
        let name = app.localizedName ?? "This app"
        guard m.enabled, !m.isPaused, m.isTinting || m.heldFor != nil, declinedHere != id else { return }
        let p = policy
        // Straight from one colour app to another the hold passes along — unless this one was told to keep red.
        if p.never.contains(id) { if m.heldFor != nil { m.release() }; return }
        if m.heldFor != nil { if m.heldFor != name { m.hold(name) }; return }
        if p.always.contains(id) { m.hold(name); return }
        guard p.ask, !askedTonight.contains(id), !prompt.isShowing else { return }
        askedTonight.insert(id); promptFor = id
        prompt.show(name: name, icon: app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "")) { [weak self] trueColor, rememberIt in
            guard let self = self else { return }
            if rememberIt { self.remember(id, always: trueColor) }
            // The card waits up to 20 s; Red Light may have been switched off or paused under it meanwhile.
            if trueColor, self.m.enabled, !self.m.isPaused, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id { self.m.hold(name) }
        }
    }
}

/// A Liquid Glass card under the menu bar icon. It never takes focus from the app you are working in.
final class TrueColorPrompt {
    private var panel: NSPanel?
    private var timeout: DispatchWorkItem?
    var isShowing: Bool { panel?.isVisible ?? false }
    func show(name: String, icon: NSImage, choose: @escaping (_ trueColor: Bool, _ remember: Bool) -> Void) {
        hide()
        let view = TrueColorPromptView(name: name, icon: icon) { [weak self] tc, rem in self?.hide(); choose(tc, rem) }
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.isFloatingPanel = true; p.becomesKeyOnlyIfNeeded = true; p.hidesOnDeactivate = false
        p.level = .statusBar                    // after isFloatingPanel, which resets the level to .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = host
        // Under the menu bar item, the way its own pane opens; the menu bar's right end if it can't be found.
        // With several displays each menu bar carries its own copy of the item: use the one where you are working.
        let items = NSApp.windows.filter { String(describing: type(of: $0)).contains("NSStatusBarWindow") }
        let item = (items.first { w in NSScreen.main.map { $0.frame.intersects(w.frame) } ?? false } ?? items.first)?.frame
        let screen = NSScreen.screens.first { sc in item.map { sc.frame.intersects($0) } ?? false } ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame, size = host.fittingSize
        var x = (item?.midX ?? vis.maxX - size.width / 2 - 8) - size.width / 2
        x = max(vis.minX + 8, min(x, vis.maxX - size.width - 8))
        p.setFrameOrigin(NSPoint(x: x, y: vis.maxY - size.height - 6))
        p.alphaValue = 0; p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        panel = p
        let w = DispatchWorkItem { [weak self] in self?.hide() }      // no answer is "not now"
        timeout = w; DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
    }
    func hide() {
        timeout?.cancel(); timeout = nil
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }
}
struct TrueColorPromptView: View {
    let name: String; let icon: NSImage
    let choose: (Bool, Bool) -> Void
    @State private var rememberIt = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(name) is open").font(CC.title).foregroundStyle(CC.label)
                    Text("Colors aren’t accurate under Red Light. Show true color while \(name) is in front? Red Light comes back when you switch away.")
                        .font(CC.subtitle).foregroundStyle(CC.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 12)
            ToggleRow(label: "Remember for \(name)", isOn: $rememberIt, drawn: isSnapshotRun).padding(.top, 6)
            HStack(spacing: 8) {
                Spacer()
                Button("Keep Red Light") { choose(false, rememberIt) }.buttonStyle(.glass).controlSize(.small)
                Button("Show True Color") { choose(true, rememberIt) }.buttonStyle(.glassProminent).controlSize(.small)
            }
            .padding(.top, 4).padding(.bottom, 12)
        }
        .padding(.horizontal, CC.side)
        .frame(width: 303)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

// MARK: - First launch: everything install.sh used to do, from inside the app
/// A copy dragged to Applications has never seen Terminal. On every launch it makes sure the engine it carries
/// (Contents/Helpers/redlight) is the one installed, that there is a config, and that the sunrise/sunset agent
/// exists. Updating the app therefore updates the engine too. Files the user owns are never overwritten.
enum Setup {
    static var bundledEngine: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/redlight") }
    static var plistURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist") }
    static func ensure() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The engine: replaced beside and renamed into place, so a check running right now never sees half a file.
        if let new = try? Data(contentsOf: bundledEngine), (try? Data(contentsOf: cliURL)) != new {
            let tmp = appDir.appendingPathComponent("redlight.new")
            if (try? new.write(to: tmp)) != nil {
                _ = try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
                _ = rename(tmp.path, cliURL.path)
            }
        }
        if !fm.fileExists(atPath: configURL.path) { writeDefaultConfig() }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(agentLabel)</string>
          <key>ProgramArguments</key><array><string>\(cliURL.path)</string><string>check</string></array>
          <key>RunAtLoad</key><true/>
          <key>StartInterval</key><integer>60</integer>
          <key>AbandonProcessGroup</key><true/>
          <key>StandardOutPath</key><string>/dev/null</string>
          <key>StandardErrorPath</key><string>\(appDir.appendingPathComponent("launchd.err.log").path)</string>
        </dict></plist>

        """
        // Missing, or written by an older installer (one before AbandonProcessGroup killed the agent's notifications and
        // logged stdout to an ever-growing file). Compared as plists, so install.sh's own copy is left alone.
        func dict(_ d: Data?) -> NSDictionary? { d.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary } }
        let old = fm.contents(atPath: plistURL.path)
        if dict(old) != dict(plist.data(using: .utf8)) {
            do { try plist.write(to: plistURL, atomically: true, encoding: .utf8) } catch { NSLog("Red Light: can’t write \(plistURL.path): \(error)"); return }
            try? fm.removeItem(at: appDir.appendingPathComponent("launchd.out.log"))
            // A loaded agent keeps the old definition until reloaded. It was loaded, so Red Light was on: ensureAgent's
            // one-time carry-over (which reads an unloaded agent as a pre-switch "off") has nothing to carry.
            let job = "gui/\(getuid())/\(agentLabel)"
            if old != nil, runStatus("/bin/launchctl", ["print", job]).ok {
                UserDefaults.standard.set(true, forKey: "switchCarriedOver")
                _ = runStatus("/bin/launchctl", ["bootout", job])
                // bootout returns before the job is gone, and bootstrap fails until it is (as in install.sh).
                for _ in 0..<20 { if runStatus("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path]).ok { break }; usleep(250_000) }
            }
        }
    }
    /// Until Location Services answers, the sun is guessed from the time zone's own coordinates (zone.tab).
    /// Opened straight from the disk image, or from the read-only copy macOS makes of a quarantined download (App
    /// Translocation), the app can't update itself and a login item would point at a path about to vanish. Offer to
    /// copy it to Applications and start it from there. Nothing is ejected or deleted.
    static func offerMoveToApplications() {
        guard Updater.cannotReplaceHere != nil, !Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: "dontOfferMove") else { return }
        let fm = FileManager.default, here = Bundle.main.bundleURL, dest = URL(fileURLWithPath: "/Applications/Red Light.app")
        let there = fm.fileExists(atPath: dest.path) ? Bundle(url: dest)?.infoDictionary : nil
        let a = NSAlert()
        a.messageText = "Move Red Light to Applications?"
        a.informativeText = "Red Light is running from the disk image or a temporary copy, where it can’t keep itself up to date or open at login."
        a.addButton(withTitle: "Move to Applications"); a.addButton(withTitle: "Not Now")
        a.showsSuppressionButton = true
        NSApp.activate()
        let answer = a.runModal()
        // "Don't ask again" belongs to Not Now: ticked beside Move to Applications, a failed copy would otherwise never be offered again.
        if a.suppressionButton?.state == .on, answer != .alertFirstButtonReturn { UserDefaults.standard.set(true, forKey: "dontOfferMove") }
        guard answer == .alertFirstButtonReturn else { return }
        // Already there and at least as new (an old disk image opened again): start that one rather than downgrade it.
        if there?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
           let v = there?["CFBundleShortVersionString"] as? String, !Updater.newer(Updater.current, than: v) { Updater.relaunch(dest); return }
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".Red Light.app.moving")
        try? fm.removeItem(at: tmp)
        // Another app that happens to be called Red Light is never replaced.
        if there == nil || there?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier, runStatus("/usr/bin/ditto", [here.path, tmp.path]).ok {
            // Copied by ditto, not Finder: left quarantined it would be translocated again. This copy is already approved.
            _ = runStatus("/usr/bin/xattr", ["-dr", "com.apple.quarantine", tmp.path])
            do {
                if there != nil { _ = try fm.replaceItemAt(dest, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: dest) }
                Updater.relaunch(dest); return
            } catch { NSLog("move: \(error)") }
        }
        try? fm.removeItem(at: tmp)
        let f = NSAlert(); f.messageText = "Couldn’t move Red Light"
        f.informativeText = "Drag Red Light from the disk image to the Applications folder, then open it from there."
        f.runModal()
    }
    /// An old name (Asia/Calcutta, Europe/Kiev) isn't in zone.tab, but its zoneinfo file is a copy of its new name's.
    /// A bare offset (UTC, Etc/GMT+5) has no place at all: then at least the longitude follows the offset, so sunset
    /// lands in the evening rather than at San Francisco's sunset hour.
    static func timezoneCoordinates() -> (Double, Double) {
        let tz = TimeZone.current, dir = "/usr/share/zoneinfo/"
        var id = tz.identifier
        let byOffset = (37.77, Double(tz.secondsFromGMT() - Int(tz.daylightSavingTimeOffset())) / 240)
        guard let tab = try? String(contentsOfFile: dir + "zone.tab", encoding: .utf8) else { return byOffset }
        let rows = tab.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t") }.filter { $0.count >= 3 }
        if !rows.contains(where: { $0[2] == id }), let mine = FileManager.default.contents(atPath: dir + id),
           let same = rows.first(where: { FileManager.default.contents(atPath: dir + $0[2]) == mine }) { id = String(same[2]) }
        for f in rows where f[2] == id {
            let c = String(f[1]); guard let split = c.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { break }
            func deg(_ s: Substring, _ n: Int) -> Double {
                let sign: Double = s.first == "-" ? -1 : 1, d = Array(s.dropFirst())
                func num(_ a: Int, _ b: Int) -> Double { b <= d.count ? Double(String(d[a..<b])) ?? 0 : 0 }
                return sign * (num(0, n) + num(n, n + 2) / 60 + num(n + 2, n + 4) / 3600)
            }
            return (deg(c[c.startIndex..<split], 2), deg(c[split...], 3))
        }
        return byOffset
    }
    static func writeDefaultConfig() {
        let (la, lo) = timezoneCoordinates()
        let json = """
        {
          "latitude": \(String(format: "%.2f", la)), "longitude": \(String(format: "%.2f", lo)), "locationSource": "timezone", "fadeMinutes": 30,
          "night": { "warmth": 0.8, "keyboardBrightness": 0.003, "keyboardIdleDimSeconds": 5, "keyboardAutoBrightness": false, "shadeEnabled": false, "shadeLevel": 0.3 },
          "dayDefaults": { "warmth": 0, "keyboardBrightness": 0.3, "keyboardIdleDimSeconds": 300, "keyboardAutoBrightness": true },
          "learning": { "enabled": true, "minNights": 3, "lookbackDays": 14, "maxOffsetMinutes": 120 },
          "nightPresetName": "Night",
          "presets": [
            { "name": "Dusk",       "icon": "sunset.fill",   "settings": { "warmth": 0.6, "keyboardBrightness": 0.01,  "keyboardIdleDimSeconds": 30, "shadeEnabled": false, "shadeLevel": 0.2 } },
            { "name": "Night",      "icon": "moon.fill",     "settings": { "warmth": 0.8, "keyboardBrightness": 0.003, "keyboardIdleDimSeconds": 5,  "shadeEnabled": false, "shadeLevel": 0.2 } },
            { "name": "Deep night", "icon": "moon.zzz.fill", "settings": { "warmth": 1.0, "keyboardBrightness": 0.000074, "keyboardIdleDimSeconds": 5,  "shadeEnabled": true,  "shadeLevel": 0.4 } },
            { "name": "Movie",      "icon": "film.fill",     "settings": { "warmth": 0.6, "keyboardBrightness": 0.0,   "keyboardIdleDimSeconds": 5,  "shadeEnabled": true,  "shadeLevel": 0.4 } }
          ],
          "shortcuts": {
            "toggleShade": { "keyCode": 1,   "modifiers": ["control", "option", "command"] },
            "shadeUp":     { "keyCode": 126, "modifiers": ["control", "option", "command"] },
            "shadeDown":   { "keyCode": 125, "modifiers": ["control", "option", "command"] }
          }
        }

        """
        let tmp = appDir.appendingPathComponent("config.json.new")
        if (try? json.write(to: tmp, atomically: true, encoding: .utf8)) != nil { _ = rename(tmp.path, configURL.path) }
    }
}

// MARK: - Updates
/// Looks at the latest GitHub release once a day. A release carries `Red-Light.zip` and `Red-Light.zip.sig`, an
/// Ed25519 signature made with a key that only the publisher holds; nothing unsigned is ever installed. Updates
/// install themselves only while no red is on screen, because restarting the app hands the display back to
/// macOS for a moment and a flash of daylight at midnight is exactly what this app exists to prevent.
final class Updater: ObservableObject {
    static let publicKey = "1IXQjjlRtoOiXOK+teUPVQ86g4G99H1gyPQMlN6rbXY="
    static let feed = URL(string: ProcessInfo.processInfo.environment["REDLIGHT_UPDATE_FEED"]
        ?? "https://api.github.com/repos/ervinyoung/Red-Light-for-mac/releases/latest")!
    struct Release { let version: String; let zip: URL; let sig: URL }
    @Published var available: Release?
    @Published var status = ""
    @Published var busy = false
    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate"); objectWillChange.send() }
    }
    /// A version that can't be installed from here (no write access, a swap that failed) isn't tried again on its
    /// own; it stays offered, with the reason, for a manual Install. A newer version is tried afresh.
    var blocked: String? {
        get { UserDefaults.standard.string(forKey: "updateBlocked") }
        set { UserDefaults.standard.set(newValue, forKey: "updateBlocked") }
    }
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    /// Each dotted part counts by its leading digits, so "2.4-beta" is 2.4 (not 2.0) and "2.4.0-rc1" is 2.4.0.
    static func newer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isASCII && $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) { let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0; if p != q { return p > q } }
        return false
    }
    /// Called every minute by the model. Checks at most daily; installs when allowed and the screen is plain.
    func tick(screenIsPlain: Bool) {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 86400 { check(userInitiated: false) }
        // Not while the panel (or the true-colour prompt) is open: the restart would pull it out from under the pointer.
        mayInstallNow = automatic && screenIsPlain && NSApp.keyWindow?.isVisible != true
        if mayInstallNow, let r = available, r.version != blocked, !busy { install(automatic: true) }
    }
    /// As of the last tick. A download can outlast sunset, so an automatic install asks again before it swaps.
    private var mayInstallNow = false
    /// Where this copy can't be replaced: a disk image, the read-only copy macOS runs a quarantined download from
    /// (App Translocation), or a folder this user can't write to. Checked before downloading, so a doomed install
    /// isn't fetched again every minute.
    static var cannotReplaceHere: String? {
        let here = Bundle.main.bundleURL
        let readOnly = (try? here.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        if readOnly || here.path.contains("/AppTranslocation/") { return "Move Red Light to Applications to update" }
        // A standard (non-admin) account and an app an administrator put in /Applications.
        if !FileManager.default.isWritableFile(atPath: here.deletingLastPathComponent().path) { return "An administrator needs to install this update" }
        return nil
    }
    func check(userInitiated: Bool) {
        guard !busy else { return }
        busy = true; if userInitiated { status = "Checking…" }
        var req = URLRequest(url: Self.feed); req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                guard let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = j["tag_name"] as? String, let assets = j["assets"] as? [[String: Any]] else {
                    // Offline at wake, or a rate limit: look again in an hour, not tomorrow.
                    UserDefaults.standard.set(Date().addingTimeInterval(3600 - 86400), forKey: "lastUpdateCheck")
                    if userInitiated { self.status = "Couldn’t reach GitHub" }; return }
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                func url(_ name: String) -> URL? { assets.first { $0["name"] as? String == name }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init) } }
                let v = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if Self.newer(v, than: Self.current), let z = url("Red-Light.zip"), let s = url("Red-Light.zip.sig") {
                    self.available = Release(version: v, zip: z, sig: s)
                    self.status = v == self.blocked ? (Self.cannotReplaceHere ?? "Couldn’t install \(v) automatically") : ""
                } else { self.available = nil; self.status = userInitiated ? "Up to Date" : "" }
            }
        }.resume()
    }
    func install(automatic auto: Bool = false) {
        guard let r = available, !busy else { return }
        if let why = Self.cannotReplaceHere { status = why; blocked = r.version; return }
        busy = true; status = "Downloading \(r.version)…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.download(r)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                // A failed download clears `available` (try again tomorrow): kept, the next tick would fetch it all again.
                // A failed swap won't go better tomorrow: that version is blocked from automatic installs instead.
                switch result {
                case .success(let staged):
                    // Sunset came during the download (or the panel opened): the staged copy goes, the next quiet tick tries again.
                    if auto && !self.mayInstallNow { try? FileManager.default.removeItem(at: staged.dir); self.status = ""; return }
                    self.status = "Restarting…"
                    if let e = Self.replaceAndRelaunch(with: staged) { self.status = e.localizedDescription; self.blocked = r.version }
                case .failure(let e):
                    self.status = e.localizedDescription
                    // A code signature that fails for this copy's own team fails the same way tomorrow: no daily re-download.
                    if (e as? Failure)?.permanent == true { self.blocked = r.version } else { self.available = nil }
                }
            }
        }
    }
    struct Failure: LocalizedError { let errorDescription: String?; var permanent = false }
    /// A GET with a deadline, on a background queue. Only a 200 counts: a 404 page or a rate-limit notice is no zip.
    private static func fetch(_ u: URL) -> Data? {
        var out: Data?; let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: URLRequest(url: u, timeoutInterval: 30)) { d, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { out = d }; done.signal() }
        task.resume()
        if done.wait(timeout: .now() + 300) == .timedOut { task.cancel(); return nil }
        return out
    }
    /// The signed zip, unpacked into a folder on the same volume as this app (so the swap is a rename) and checked.
    /// On failure the folder is removed; on success it is the caller's to remove.
    private static func download(_ r: Release) -> Result<(app: URL, dir: URL), Error> {
        guard let zip = fetch(r.zip), let sigText = fetch(r.sig).flatMap({ String(data: $0, encoding: .utf8) }),
              let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .failure(Failure(errorDescription: "Download failed")) }
        guard let keyData = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(sig, for: zip) else { return .failure(Failure(errorDescription: "Update signature didn’t match; not installed")) }
        let fm = FileManager.default
        let dir = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true))
            ?? fm.temporaryDirectory.appendingPathComponent("RedLightUpdate-\(UUID().uuidString)")
        func fail(_ s: String, permanent: Bool = false) -> Result<(app: URL, dir: URL), Error> {
            try? fm.removeItem(at: dir); return .failure(Failure(errorDescription: s, permanent: permanent)) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("Red-Light.zip")
        guard (try? zip.write(to: zipURL)) != nil, runStatus("/usr/bin/ditto", ["-x", "-k", zipURL.path, dir.path]).ok else { return fail("Couldn’t unpack the update") }
        let app = dir.appendingPathComponent("Red Light.app")
        guard let info = Bundle(url: app)?.infoDictionary, info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let v = info["CFBundleShortVersionString"] as? String, newer(v, than: current) else { return fail("The update wasn’t a newer Red Light") }
        guard codeSignatureMatches(app) else { return fail("The update’s code signature didn’t check out; not installed", permanent: true) }
        _ = runStatus("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return .success((app, dir))
    }
    /// The new app's code signature must be intact (a broken one is killed at launch, leaving nothing running) and, if
    /// this copy is signed by a team, made by the same team: a different signer would also cost the Location grant.
    static func codeSignatureMatches(_ app: URL) -> Bool {
        func team(_ u: URL) -> (valid: Bool, team: String?) {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(u as CFURL, [], &code) == errSecSuccess, let code = code else { return (false, nil) }
            let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess
            var info: CFDictionary?
            _ = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            return (valid, (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String)
        }
        let new = team(app)
        guard new.valid else { return false }
        if let mine = team(Bundle.main.bundleURL).team { return new.team == mine }
        return true
    }
    /// Swap the bundle in place (one rename), then start the new copy once this one has gone. Returns why it couldn't.
    private static func replaceAndRelaunch(with staged: (app: URL, dir: URL)) -> Error? {
        let dest: URL
        do { dest = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: staged.app) ?? Bundle.main.bundleURL }
        catch { NSLog("update: \(error)"); try? FileManager.default.removeItem(at: staged.dir); return Failure(errorDescription: "Couldn’t replace Red Light; not updated") }
        // Before relaunching: terminate() exits the process, so nothing after it (a defer included) ever runs.
        try? FileManager.default.removeItem(at: staged.dir)
        return relaunch(dest) ? nil : Failure(errorDescription: "Updated; quit and reopen Red Light to finish")
    }
    /// Starts `app` once this process has exited (two copies can't run at once). The path is an argument to the
    /// script, never part of it, so a quote or a `$` in it stays a path; a failed `open` is tried once more.
    @discardableResult static func relaunch(_ app: URL) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\" || { sleep 2; /usr/bin/open \"$2\"; }",
                       "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        do { try p.run() } catch { NSLog("relaunch: \(error)"); return false }    // stay running rather than vanish
        NSApp.terminate(nil)
        return true
    }
}

// MARK: - Keyboard backlight, including below macOS's minimum
/// The backlight is a PWM with a 960-tick period. macOS's levels run from 54 ticks (its minimum, every value up to
/// about 0.008) to 336 (full), but the hardware goes down to 1: macOS only passes through those levels while it fades.
/// The four extra-dim levels are 2, 4, 9 and 21 ticks; the engine stores them as that fraction of macOS's 0.001.
let kbMinTicks = 54.0, kbMaxTicks = 336.0
let kbDimTicks: [Double] = [2, 4, 9, 21]
/// Ticks for a stored value, measured on this hardware: 0.01 → 55, 0.1 → 80, 0.5 → 194, 1 → 336.
func kbTicks(_ v: Double?) -> Double {
    guard let v = v, v > 0 else { return 0 }
    return v < 0.001 ? v / 0.001 * kbMinTicks : max(kbMinTicks, 51.5 + 284.5 * v)
}
func kbValue(_ ticks: Double) -> Double {
    if ticks <= 0 { return 0 }
    if ticks < kbMinTicks { return ticks / kbMinTicks * 0.001 }
    return ticks < kbMinTicks + 1 ? 0.001 : min(1, (ticks - 51.5) / 284.5)
}
/// The four levels below macOS's minimum are named, dimmest first, after light you would still read by at night.
let kbDimNames = ["Extra Dim 1", "Extra Dim 2", "Extra Dim 3", "Extra Dim 4"]     // dimmest first, as `set keyboard dim1`–`dim4`
/// Off, a named extra-dim level, or a percentage of macOS's own range, where 1% is its minimum and 100% is full.
func fmtKeyboard(_ v: Double?) -> String {
    let t = kbTicks(v); guard t > 0 else { return "Off" }
    if t < kbMinTicks - 0.5 { let i = kbDimTicks.indices.min { abs(kbDimTicks[$0] - t) < abs(kbDimTicks[$1] - t) }!; return kbDimNames[i] }
    let f = (log(t) - log(kbMinTicks)) / (log(kbMaxTicks) - log(kbMinTicks))
    return "\(Int((1 + 99 * max(0, min(1, f))).rounded()))%"
}

/// Runs the keyboard backlight whenever Red Light sets it (auto-brightness off). macOS's own idle-off counts typing
/// only and, once it has dimmed the keys, ignores every brightness request, so a slider moved with the trackpad
/// could leave the keys stuck. So while Red Light runs the keys, macOS's idle-dimming is suspended and this does it:
/// the keys go off after the idle time without typing or touching the pointer, and come back at the next key,
/// movement, click or scroll, at any level.
///
/// The named levels below macOS's minimum are held: macOS restarts a fade from wherever the light is and drops a
/// request whose target equals the running one, so a slow fade toward off, re-aimed and restarted every half second,
/// long before it can move a tick, keeps the light where it is; a quick fade up corrects the occasional slip.
/// The ambient light sensor, read in-process (the engine reads it too, and owns what is done with it). Private API:
/// on Apple Silicon an IOHIDEventSystem service, usage page 0xff00, usage 4. Nil with the lid closed.
@_silgen_name("IOHIDEventSystemClientCreate") func hidClientCreate(_ a: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching") func hidSetMatching(_ c: AnyObject, _ m: CFDictionary)
@_silgen_name("IOHIDEventSystemClientCopyServices") func hidCopyServices(_ c: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyEvent") func hidCopyEvent(_ s: AnyObject, _ type: Int64, _ opts: Int32, _ ts: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") func hidFloat(_ e: AnyObject, _ field: Int32) -> Double
final class RoomSensor {
    private lazy var service: AnyObject? = {
        guard let c = hidClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        hidSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 4] as CFDictionary)
        client = c
        return (hidCopyServices(c)?.takeRetainedValue() as? [AnyObject])?.first
    }()
    private var client: AnyObject?
    func lux() -> Double? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        let closed = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
        IOObjectRelease(root)
        guard closed != true, let s = service, let e = hidCopyEvent(s, 12, 0, 0)?.takeRetainedValue() else { return nil }
        return hidFloat(e, 12 << 16)
    }
}
final class KeyboardHold {
    enum Want: Equatable { case none, off, level(Double), hold(Int) }      // none: auto-brightness, macOS's to run
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SuspendFn = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
    private let q = DispatchQueue(label: "redlight.keyboard")
    private var timer: DispatchSourceTimer?
    private var client: NSObject?, id: UInt64 = 0
    private var setFn: SetFn?, getFn: GetFn?, suspendFn: SuspendFn?
    private let setSel = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:"), getSel = NSSelectorFromString("brightnessForKeyboard:")
    private let suspendSel = NSSelectorFromString("suspendIdleDimming:forKeyboard:")
    private var backlight: io_service_t = 0
    // q only
    private var want = Want.none, idle = 5.0, asleep = false, lit = true, suspended = false
    private var up = false, fastDown = false, lastKeep = Date.distantPast, lastCheck = Date.distantPast
    private var lastTick = -1, lastMove = Date.distantPast       // a requested fade that isn't moving gets asked again
    /// The brightness keys or Control Center set a new level: it becomes the level.
    var onOverride: ((Double) -> Void)?
    init() {
        guard !isSnapshotRun else { return }
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return }
        let c = cls.init(); client = c
        id = ((c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeUnretainedValue() as? [NSNumber])?.first?.uint64Value) ?? 0
        if c.responds(to: setSel) { setFn = unsafeBitCast(c.method(for: setSel), to: SetFn.self) }
        if c.responds(to: getSel) { getFn = unsafeBitCast(c.method(for: getSel), to: GetFn.self) }
        if c.responds(to: suspendSel) { suspendFn = unsafeBitCast(c.method(for: suspendSel), to: SuspendFn.self) }
        backlight = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("kbd-backlight"))
        markIdle(false)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.q.sync { self?.shutdown() } }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            nc.addObserver(forName: n, object: nil, queue: nil) { [weak self] _ in self?.q.async { self?.asleep = true; self?.schedule() } } }
        for n in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            nc.addObserver(forName: n, object: nil, queue: nil) { [weak self] _ in self?.q.async { guard let k = self else { return }
                k.asleep = false; k.lit = false
                switch k.want { case .level, .hold: k.markIdle(true); default: break }     // dark until a touch: say so, as for idle-off
                k.schedule() } } }
    }
    /// Quitting (or the updater relaunching) must not leave the "keys are idle" marker behind, which the engine would read
    /// as dimmed keys and ignore every manual change, nor the idle-dimming suspended, nor a held level's slow fade toward
    /// off still running in macOS with nobody left to restart it.
    private func shutdown() {
        timer?.cancel(); timer = nil
        switch want {
        case .hold: send(0.001, 250)                                     // macOS's own minimum, rather than creeping to off
        case .level(let v): if !lit { send(Float(v), 250) }              // quit while the keys were off for inactivity
        default: break
        }
        markIdle(false); setSuspended(false)
    }
    func update(_ w: Want, idleSeconds: Double) {
        q.async { [self] in
            idle = idleSeconds
            guard w != want else { return }
            var was = false, now = false
            switch want { case .level, .hold: was = true; default: break }
            switch w { case .level, .hold: now = true; default: break }
            // A new level that comes from the engine (each minute of a sunset fade, a preset, the command line) must not
            // light keys that went dark for inactivity: the next touch lights them at the new level. A touch that is
            // happening now (the slider) lights them at once.
            let wake = !(was && now) || lit || idleTime() < 0.5
            want = w; up = false; fastDown = false; lastKeep = .distantPast; lastMove = Date()
            setSuspended(w != .none)
            if wake { markIdle(false) }
            switch w {
            case .off: send(0, 250)
            case .level(let v): if wake { lit = true; send(Float(v), 250) }          // immediately, whatever macOS thought of the keys
            case .hold: if wake { lit = true }
            case .none: break
            }
            schedule()
        }
    }
    /// While the keys are off for inactivity the engine must not read the dark keys as "keyboard off"; this file is
    /// the app's equivalent of macOS's own "dimmed" flag, which the engine already respects.
    private let idleMarker = appDir.appendingPathComponent("keyboard-idle")
    private func markIdle(_ on: Bool) {
        if on { FileManager.default.createFile(atPath: idleMarker.path, contents: nil) } else { try? FileManager.default.removeItem(at: idleMarker) }
    }
    private var lastValue: Float = -1
    /// macOS drops a request whose target equals the fade already running: re-aim it for an instant first.
    private func send(_ v: Float, _ ms: Int32) {
        guard let f = setFn, let c = client else { return }
        if v == lastValue { _ = f(c, setSel, v == 0 ? 0.001 : 0, 60000, false, id) }
        _ = f(c, setSel, v, ms, false, id); lastValue = v
    }
    private func setSuspended(_ on: Bool) {
        if on != suspended, let f = suspendFn, let c = client { _ = f(c, suspendSel, on, id); suspended = on }
    }
    private func reg(_ key: String) -> NSNumber? { IORegistryEntryCreateCFProperty(backlight, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber }
    private func tick() -> Int { (reg("enabled")?.boolValue ?? false) ? (reg("high-period")?.intValue ?? 0) : 0 }
    /// Seconds since the last keypress, pointer movement, click or scroll: the keys light as soon as you reach for the
    /// trackpad, so at night you can find them without pressing one.
    private func idleTime() -> Double {
        let kinds: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown,
                                    .leftMouseDragged, .rightMouseDragged, .scrollWheel, .otherMouseDown,
                                    CGEventType(rawValue: 14)!]        // system-defined: the brightness and media keys
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }
    private func schedule() {
        let active: Bool
        switch want { case .level, .hold: active = setFn != nil && backlight != 0; default: active = false }
        if !active || asleep { timer?.cancel(); timer = nil; return }
        var fast = false; if case .hold = want, lit { fast = true }
        if timer == nil { let t = DispatchSource.makeTimerSource(queue: q); t.setEventHandler { [weak self] in self?.step() }; timer = t; t.resume() }
        timer?.schedule(deadline: .now(), repeating: fast ? .milliseconds(15) : .milliseconds(100), leeway: .milliseconds(5))
    }
    private func step() {
        let now = Date()
        let t = tick()
        if t != lastTick { lastTick = t; lastMove = now }
        let stalled = now.timeIntervalSince(lastMove) > 0.4
        if !lit {                                                       // off after inactivity: wait for a touch
            if idleTime() < 0.5 || idle <= 0 || idleTime() + 0.5 < idle {     // a touch, or the idle time raised past how long you've been away
                lit = true; up = false; fastDown = false; lastMove = now; markIdle(false)
                if case .level(let v) = want { send(Float(v), 250) }
                schedule()
            } else if t > 0 && stalled { send(0, 500); lastMove = now }    // something lit them meanwhile
            return
        }
        if idle > 0 && idleTime() >= idle { markIdle(true); send(0, 500); lit = false; lastMove = now; schedule(); return }
        // The brightness keys or Control Center: macOS reports a level we didn't ask for. It becomes the level.
        if now.timeIntervalSince(lastCheck) > 0.25, let g = getFn, let c = client {
            lastCheck = now
            let v = Double(g(c, getSel, id))
            var ours: Double = 0
            if case .level(let l) = want { ours = l }
            if v > 0.0015, abs(v - ours) > 0.002, Float(v) != lastValue {
                want = .level(v); lastValue = Float(v); up = false; fastDown = false; schedule()
                let cb = onOverride; DispatchQueue.main.async { cb?(v) }; return
            }
        }
        switch want {
        case .level(let v):
            // Keep the level: if something left the light elsewhere (macOS's own fades), ask again.
            if abs(Double(t) - kbTicks(v)) > 3 && stalled { send(Float(v), 250); lastMove = now }
        case .hold(let T):
            // Turning a fade around costs a step on the way up, so ride an upward fade one past the target and turn there.
            if up { if t >= T + 1 { send(0, 900); up = false; fastDown = true; lastMove = now } else if stalled { send(0.001, 900); lastMove = now }; return }
            if t < T { send(0.001, 900); up = true; fastDown = false; lastMove = now; return }   // in from off, or a slip
            if t > T { if !fastDown || stalled { send(0, 900); fastDown = true; lastMove = now }; return }   // down from macOS's levels
            if fastDown || now.timeIntervalSince(lastKeep) > 0.5 { send(0, 60000); fastDown = false; lastKeep = now }
        default: break
        }
    }
}

// MARK: - Model
final class Model: ObservableObject {
    @Published var config = Config(latitude: 34.05, longitude: -118.24, locationSource: nil, fadeMinutes: 30, night: Settings(), dayDefaults: Settings(), learning: Learning(), shortcuts: Shortcuts())
    @Published var state: ModeState?
    @Published var learned = Learned()
    @Published var shade = Shade()
    @Published var sunLine = ""
    /// What the switch shows: the engine's persisted switch (state.json), set optimistically under the finger.
    /// It is never inferred from launchd — the agent stays loaded and the engine itself honours "off".
    @Published var enabled = true
    private var switchesInFlight = 0        // `on`/`off` sent to the engine and not yet answered: a count, not a flag,
                                            // so a quick off-on-off can't hand the switch back to a half-way state
    @Published var launchAtLogin = false
    @Published var recording: String? = nil
    @Published var live = Settings()
    @Published var locationDenied = false
    var snapshotMode = isSnapshotRun
    var snapshotDaylight = false      // --snapshot … daylight, to capture the daytime state
    var snapshotDemo = false          // --snapshot … demo: a fixed night look for marketing images, not this Mac's state
    let overlay = ShadeOverlay()
    let gamma = Gamma()
    let locator = Locator()
    lazy var trueColor = TrueColorWatcher(model: self)
    let keyboardHold = KeyboardHold()
    let updater = Updater()
    let liveQueue = DispatchQueue(label: "redlight.live")
    private var source: DispatchSourceFileSystemObject?
    private var monitor: Any?
    private var refreshWork: DispatchWorkItem?
    var lastKeyboard: Double? = nil
    /// Slider steps queued for the engine and not yet applied. While any are, what the engine reports is a step
    /// behind the finger, and reading it back would snap the thumb, the header and the screen back to that step.
    private var setsInFlight = 0
    private var shadesInFlight = 0          // shade on/off and level queued for shade.json and not yet written
    private var hotkeysLive: Bool?          // whether the shortcuts were last registered for on (true) or off (false)

    init() {
        // A documentation snapshot is a second process beside the running app: it only reads. Gamma and the shade
        // windows keep off the display themselves (isSnapshotRun); here: no hotkeys, no engine commands, no location
        // prompt, and no true-colour watching that could send `hold`.
        guard !snapshotMode else { refresh(); return }
        Setup.ensure()
        DispatchQueue.main.async { Setup.offerMoveToApplications() }     // after launch, not inside the scene's setup
        ensureAgent()
        keyboardHold.onOverride = { [weak self] v in self?.set("keyboard", String(format: "%.6f", v * 100)) }   // the brightness keys: record the new level
        refresh()
        watchFolder()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.source == nil { self.watchFolder() }       // the folder was missing last time: try again
            self.refresh()
            self.updater.tick(screenIsPlain: self.isOff || !self.isTinting)
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.gamma.verify() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.watchRoom() }
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
        _ = trueColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self = self else { return }
            self.updater.tick(screenIsPlain: self.isOff || !self.isTinting) }
    }
    /// Night, Red Shift 80 %, keys at 0.3 % with a 5 s timeout — the "Night" preset, as shipped.
    func demoLook() {
        if let d = try? Data(contentsOf: configURL), let c = try? dec.decode(Config.self, from: d) { config = c }
        state = ModeState(mode: "night", daySnapshot: nil, lastSeen: nil, lastNotified: nil, ramp: nil, pausedUntil: nil, disabled: false, heldFor: nil)
        let c = warmthCurve(0.8)
        shade = Shade(enabled: false, level: 0.2, warmth: 0.8, gammaBlue: c.blue, gammaGreen: c.green)
        live = Settings(keyboardBrightness: ProcessInfo.processInfo.environment["REDLIGHT_DEMO_KB"].flatMap(Double.init) ?? 0.003, keyboardIdleDimSeconds: 5, shadeEnabled: false, shadeLevel: 0.2, warmth: 0.8)
        enabled = true
        sunLine = "sunrise 7:11 AM (switch 7:11 AM)   sunset 6:39 PM (switch 6:39 PM)   now 11:58 PM -> night"
    }
    var plistPath: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist").path }
    /// The agent is always loaded now. Builds before this one expressed "off" by unloading it, so an unloaded
    /// agent with no recorded switch is carried over as off before it is loaded again.
    /// Once only, on this build's first launch. The engine now records "on" as `disabled: false`, so a missing key
    /// should mean a pre-switch state — but the first engine with the switch wrote "on" as no key, and its state.json
    /// stays that way until the new engine next runs. Read later, an unloaded agent (a login-order race, Background
    /// Items switched off in System Settings) beside such a file would switch Red Light off by itself.
    func ensureAgent() {
        let migrate = !UserDefaults.standard.bool(forKey: "switchCarriedOver")
        UserDefaults.standard.set(true, forKey: "switchCarriedOver")
        let label = "gui/\(getuid())/\(agentLabel)"
        guard FileManager.default.fileExists(atPath: plistPath), !runStatus("/bin/launchctl", ["print", label]).ok else { return }
        let st = (try? Data(contentsOf: stateURL)).flatMap { try? dec.decode(ModeState.self, from: $0) }
        if migrate, let st = st, st.disabled == nil { _ = runStatus(cliURL.path, ["off"]) }
        _ = runStatus("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath])
    }
    /// Every engine write is an atomic rename inside the folder, which the folder's own descriptor sees as a write.
    /// If the folder itself is moved or deleted (a reinstall), that descriptor watches nothing ever again, so the
    /// watch is opened afresh on the new folder — or on the minute timer, if it isn't back yet.
    private func watchFolder() {
        source?.cancel(); source = nil
        let fd = open(appDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self = self else { return }
            if let ev = src?.data, !ev.isDisjoint(with: [.rename, .delete]) { self.watchFolder() }
            self.scheduleRefresh()
        }
        src.setCancelHandler { close(fd) }
        src.resume(); source = src
    }
    func locateIfAuto() { if config.locationSource != "manual" { locator.request() } }
    func useMyLocation() { config.locationSource = "auto"; saveConfig(reapply: false); locator.request() }

    func scheduleRefresh(after delay: TimeInterval = 0.12) {
        refreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    /// The room's light. At night a room is dark, dim or lit — in a dark room the sensor mostly sees the screen's own
    /// light coming back, swinging between 0 and 5 lux as the page changes, so a level that tracked lux swung with it.
    /// The reading is filtered the way True Tone and auto-brightness filter theirs: every half second, kept as a quick
    /// (2 s) and a slow (8 s) average; a new kind only when both are past its margin (the same as the engine's
    /// `roomKind`: wide, so only a lamp going on or off crosses one), and have stayed past it for 5 s (brighter) or
    /// 12 s (darker). Then `room <kind> <lux>` sets that kind's level, drawn over 10–40 s (see drawLook); while it plays
    /// out, and for 5 s after, the screen's own changing light can't start another.
    private let roomSensor = RoomSensor()
    private var roomInFlight = false
    private var luxFast: Double?, luxSlow: Double?
    private var roomPending: String?, roomPendingSince = Date.distantPast, roomQuietUntil = Date.distantPast
    static func roomKind(lux: Double, was: String?) -> String {
        switch was {
        case "dark": return lux > 30 ? "lit" : lux > 8 ? "dim" : "dark"
        case "dim":  return lux > 22 ? "lit" : lux < 4 ? "dark" : "dim"
        case "lit":  return lux < 4 ? "dark" : lux < 15 ? "dim" : "lit"
        default:     return lux < 5 ? "dark" : lux < 20 ? "dim" : "lit"
        }
    }
    func watchRoom() {
        guard !roomInFlight, !isOff, !isPaused, config.roomLight?.enabled ?? true,
              isNight || isFading || (shade.warmth ?? 0) > 0.001 else { luxFast = nil; luxSlow = nil; roomPending = nil; return }
        let was = state?.room?.kind
        guard let lux = roomSensor.lux() else {
            luxFast = nil; luxSlow = nil; roomPending = nil
            if was != nil { sendRoom(["none"]) }                     // lid closed: back to the schedule's own level
            return
        }
        let x = log10(lux + 3)
        luxFast = luxFast.map { $0 + (x - $0) * (1 - exp(-0.5 / 2)) } ?? x
        luxSlow = luxSlow.map { $0 + (x - $0) * (1 - exp(-0.5 / 8)) } ?? x
        let fast = pow(10, luxFast!) - 3, slow = pow(10, luxSlow!) - 3
        guard let current = was else { sendRoom([Self.roomKind(lux: lux, was: nil), String(format: "%.1f", lux)]); return }
        guard Date() >= roomQuietUntil else { roomPending = nil; return }
        let a = Self.roomKind(lux: fast, was: current), b = Self.roomKind(lux: slow, was: current)
        guard a == b, a != current else { roomPending = nil; return }
        if roomPending != a { roomPending = a; roomPendingSince = Date(); return }
        let order = ["dark", "dim", "lit"], brighter = order.firstIndex(of: a)! > order.firstIndex(of: current)!
        guard Date().timeIntervalSince(roomPendingSince) >= (brighter ? 5 : 12) else { return }
        roomPending = nil
        sendRoom([a, String(format: "%.1f", slow)])
    }
    private func sendRoom(_ args: [String]) {
        roomInFlight = true
        liveQueue.async { [weak self] in
            _ = runStatus(cliURL.path, ["room"] + args)
            DispatchQueue.main.async { guard let self = self else { return }
                self.roomInFlight = false; self.refresh()
                self.roomQuietUntil = Date().addingTimeInterval((self.shade.ease ?? 0) + 5) }
        }
    }
    func refresh() {
        if snapshotDemo { demoLook(); return }
        var keysChanged = false
        if configsInFlight == 0, let d = try? Data(contentsOf: configURL), let c = try? dec.decode(Config.self, from: d) {
            let hk = c.shortcuts ?? Shortcuts(), old = config.shortcuts ?? Shortcuts()
            config = c; diskConfig = c
            keysChanged = hk.toggleShade != old.toggleShade || hk.shadeDown != old.shadeDown || hk.shadeUp != old.shadeUp
        }
        state = (try? Data(contentsOf: stateURL)).flatMap { try? dec.decode(ModeState.self, from: $0) }
        learned = (try? Data(contentsOf: learnedURL)).flatMap { try? dec.decode(Learned.self, from: $0) } ?? Learned()
        var sh = (try? Data(contentsOf: shadeURL)).flatMap { try? dec.decode(Shade.self, from: $0) } ?? Shade()
        if setsInFlight > 0 { sh.warmth = shade.warmth; sh.gammaBlue = shade.gammaBlue; sh.gammaGreen = shade.gammaGreen; sh.ease = nil; sh.easeAt = nil }
        if shadesInFlight > 0 { sh.enabled = shade.enabled; sh.level = shade.level }     // likewise for setShade()
        shade = sh
        if switchesInFlight == 0 { enabled = !(state?.disabled ?? false) }
        if keysChanged || hotkeysLive != !isOff { registerHotkeys() }
        drawLook()
        trueColor.reconsider()
        if #available(macOS 13, *) { launchAtLogin = SMAppService.mainApp.status == .enabled }
        liveQueue.async { [weak self] in
            let sun = cli("suntimes").trimmingCharacters(in: .whitespacesAndNewlines)
            let status = cli("status")
            // Steps queued after this status (the queue is serial) make it stale; the final step refreshes again.
            DispatchQueue.main.async { guard let self = self else { return }; self.sunLine = sun; if self.setsInFlight == 0 { self.parseLive(status) } }
        }
    }
    /// Off and true colour both mean the display is drawn exactly as macOS would draw it, whatever shade.json says.
    /// Off is what the switch shows as well as what the engine has recorded: while an `off` is on its way, a refresh
    /// for some other reason must not paint the old red back under a switch that already says Off.
    var isOff: Bool { !enabled || state?.disabled == true }
    var heldFor: String? { heldPending ?? state?.heldFor }
    /// `hold`/`release` sent and not yet recorded: like the switch, the screen and pane follow at once, and a refresh
    /// in between neither paints the red back over a hold nor sends the same hold again.
    private var heldPending: String?? = nil
    private var holdsInFlight = 0
    var isTinting: Bool { !isOff && ((shade.warmth ?? 0) > 0.001 || shade.enabled) }
    func drawLook() {
        if isOff || heldFor != nil { stopEase(finish: false); drawnWarmth = nil; overlay.apply(Shade()); gamma.apply(blue: 1, green: 1); return }
        overlay.apply(shade)
        let target = shade.warmth ?? 0
        // A change the engine marked as gradual (the room, a fade step) is drawn from what is on screen now, continuously,
        // over the time it gave. Anything else — a slider, a preset, the switch — is drawn at once.
        if let len = shade.ease, len > 0, let key = shade.easeAt {
            if key == easeKey && easeTimer != nil { return }          // already on its way there
            if key != easeKey {
                easeKey = key
                let elapsed = Date().timeIntervalSince1970 - key
                if let from = drawnWarmth, abs(from - target) > 0.002, elapsed < len {
                    easeFrom = from; easeTo = target; easeStart = Date(); easeLen = max(2, len - max(0, elapsed))
                    easeTint = shade.tintDeferred == true
                    easeTimer?.invalidate()
                    easeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.easeStep() }
                    return
                }
            }
        }
        stopEase()
        drawnWarmth = target
        gamma.apply(blue: shade.gammaBlue ?? 1, green: shade.gammaGreen ?? 1)
    }
    private var drawnWarmth: Double?                   // the warmth on screen now
    private var easeTimer: Timer?, easeKey: Double?, easeTint = false, tintDrawn: Double?
    private var easeFrom = 0.0, easeTo = 0.0, easeStart = Date(), easeLen = 1.0
    /// One frame: ease-in, ease-out (a sine), so a change starts and ends too gently to see. The tint leg is written only
    /// when it has moved a visible amount, about every few frames at most.
    private func easeStep() {
        let t = min(1, Date().timeIntervalSince(easeStart) / easeLen), e = 0.5 - 0.5 * cos(.pi * t)
        let w = easeFrom + (easeTo - easeFrom) * e, c = warmthCurve(w)
        drawnWarmth = w
        gamma.apply(blue: c.blue, green: c.green)
        if easeTint && (tintDrawn.map { abs($0 - c.tint) >= 0.004 } ?? true || t >= 1) { Tint.set(c.tint); tintDrawn = c.tint }
        if t >= 1 { stopEase() }
    }
    private func stopEase(finish: Bool = true) {
        // An ease cut short leaves the tint leg where the engine meant it to end, not part-way — unless it was cut short
        // by off or true colour, whose tint is the engine's (none).
        if finish && easeTimer != nil && easeTint && shade.tintDeferred == true { Tint.set(warmthCurve(easeTo).tint) }
        easeTimer?.invalidate(); easeTimer = nil; tintDrawn = nil
    }
    var isNight: Bool { state?.mode == "night" }
    /// The kind of room the red is set for now, while Match Room Light has one.
    var roomKindNow: String? { (config.roomLight?.enabled ?? true) ? state?.room?.kind : nil }
    var isPaused: Bool { if let u = state?.pausedUntil { return u > Date() }; return false }
    var isFading: Bool { state?.ramp != nil }
    var sunriseText: String { switchTime(0) }
    var sunsetText: String { switchTime(1) }
    private func switchTime(_ i: Int) -> String {
        let parts = sunLine.components(separatedBy: "   ")
        guard parts.count > i else { return "" }
        return parts[i].components(separatedBy: "switch ").last?.replacingOccurrences(of: ")", with: "") ?? ""
    }

    /// config.json as last read. The engine writes the same file (location, presets), so saving writes back only the
    /// top-level keys changed here since that read, onto what is on disk now — never a stale whole copy over the
    /// engine's write, and never this model's placeholder defaults over a file it could not read.
    private var diskConfig: Config?
    private var configsInFlight = 0
    func saveConfig(reapply: Bool = true) {
        func obj(_ d: Data?) -> [String: Any]? { d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        if let base = diskConfig, let was = obj(try? enc.encode(base)), let mine = obj(try? enc.encode(config)) {
            // Under the engine's lock, off the main thread: an engine run that loaded config.json before this
            // (`location`, `preset save`) would save its whole copy over the change, or this over its. Until it is
            // written, refresh() keeps this model's config rather than reading the old file back.
            configsInFlight += 1
            diskConfig = config            // what the file will hold for these keys: the next save diffs against it, so a change
                                           // and its undo before the first lands are two writes, not "no change" beside a stale file
            liveQueue.async { [weak self] in
                withEngineLock {
                    guard var disk = obj(try? Data(contentsOf: configURL)) else { NSLog("Red Light: config.json unreadable; not saving over it"); return }
                    for k in Set(was.keys).union(mine.keys) where !NSArray(array: [was[k] ?? NSNull()]).isEqual(to: [mine[k] ?? NSNull()]) { disk[k] = mine[k] }
                    if let d = try? JSONSerialization.data(withJSONObject: disk), let merged = try? dec.decode(Config.self, from: d) {
                        try? enc.encode(merged).write(to: configURL, options: .atomic)
                    }
                }
                DispatchQueue.main.async { guard let self = self else { return }; self.configsInFlight -= 1; self.scheduleRefresh(after: 0.05) }
            }
        } else { NSLog("Red Light: config.json unreadable; not saving over it") }
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
        guard !isOff else { return }
        bringBackIfHeld()
        func change(_ s: inout Shade) {
            if let e = enabled { s.enabled = e }
            if let l = level { s.level = max(0, min(0.9, l)); if l > 0 && enabled == nil { s.enabled = true } }
        }
        var s = shade; change(&s)
        shade = s; drawLook()
        // The engine read-modify-writes shade.json under its lock (every fade step, `set`, a preset). Written beside
        // it, this could put back the warmth it had just written, or be lost under its save. So: under the same lock,
        // onto what is on disk then, only these two fields — queued behind any slider steps, like them.
        shadesInFlight += 1
        liveQueue.async { [weak self] in
            withEngineLock {
                var d = (try? Data(contentsOf: shadeURL)).flatMap { try? dec.decode(Shade.self, from: $0) } ?? s
                change(&d)
                try? enc.encode(d).write(to: shadeURL, options: .atomic)
            }
            DispatchQueue.main.async { guard let self = self else { return }; self.shadesInFlight -= 1; self.scheduleRefresh(after: 0.05) }
        }
    }
    /// Touching the look during true colour means you want to see it: that is "Bring Red Light Back", first. Otherwise
    /// the change would be saved but invisible — and the engine's `set` would turn the tint leg on under a hold
    /// while the gamma legs and shade stay off. `release` is queued ahead of the change, so the engine sees it first.
    private func bringBackIfHeld() { if heldFor != nil { trueColor.bringBack() } }
    /// Warmth: paint the gamma legs now for immediate feedback; the engine applies the tint leg and records it.
    func setWarmth(_ w: Double, final: Bool) {
        guard !isOff else { return }
        bringBackIfHeld()
        let c = warmthCurve(w)
        shade.warmth = w; shade.gammaBlue = c.blue; shade.gammaGreen = c.green; shade.ease = nil; shade.easeAt = nil
        drawLook()
        set("warmth", w <= 0 ? "off" : String(format: "%.1f", w * 100), final: final)
    }
    /// The master switch. One engine command, persisted; the screen follows at once, before the engine replies.
    func setEnabled(_ on: Bool) {
        enabled = on                        // the switch moves under the finger, not a second later
        // Off gives the keys back before the engine restores the day level, or a held level pulls it down again.
        if !on { keyboardHold.update(.none, idleSeconds: live.keyboardIdleDimSeconds ?? 5) }
        switchesInFlight += 1
        if hotkeysLive != !isOff { registerHotkeys() }
        drawLook()                          // off: the normal display now; on: still normal until the engine is on
        liveQueue.async { [weak self] in
            guard let self = self else { return }
            // The switch first, then the agent: loading it runs a `check` at once, which must find the switch
            // already recorded rather than race the command and save state from before it.
            _ = runStatus(cliURL.path, [on ? "on" : "off"])
            self.ensureAgent()
            DispatchQueue.main.async { self.switchesInFlight -= 1; self.refresh() }
        }
    }
    func hold(_ app: String) { sendHold(app, ["hold", app]) }
    func release() { sendHold(nil, ["release"]) }
    private func sendHold(_ app: String?, _ args: [String]) {
        objectWillChange.send()
        heldPending = .some(app); holdsInFlight += 1
        drawLook()
        liveQueue.async { [weak self] in
            _ = runStatus(cliURL.path, args)
            DispatchQueue.main.async { guard let self = self else { return }
                self.holdsInFlight -= 1
                if self.holdsInFlight == 0 { self.heldPending = nil }
                self.refresh() }
        }
    }
    func setLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13, *) else { return }
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSLog("login item: \(error)") }
        refresh()
    }
    func registerHotkeys() {
        guard !snapshotMode else { return }     // refresh() calls this when the file's shortcuts differ from the defaults
        let hk = config.shortcuts ?? Shortcuts()
        // Off, the shade keys can do nothing, so they are given back rather than swallowed (⌃⌥⌘↑ belongs to
        // whatever app would otherwise get it). refresh() and setEnabled() re-register when that changes.
        hotkeysLive = !isOff
        HotKeys.shared.register(isOff ? [] : [
            // "Lighter" all the way down leaves the level at 0; switching on at nothing would look like a dead key.
            (hk.toggleShade, { [weak self] in guard let s = self else { return }
                let on = !s.shade.enabled
                s.setShade(enabled: on, level: on && s.shade.level < 0.05 ? shadeSteps[1].value : nil) }),
            (hk.shadeDown, { [weak self] in guard let s = self else { return }
                let l = ((s.shade.enabled ? s.shade.level : 0) - 0.1).rounded(toPlaces: 2)
                if l <= 0 { s.setShade(enabled: false, level: 0) } else { s.setShade(enabled: true, level: l) } }),
            (hk.shadeUp, { [weak self] in guard let s = self else { return }
                s.setShade(enabled: true, level: ((s.shade.enabled ? s.shade.level : 0) + 0.1).rounded(toPlaces: 2)) }),
        ])
    }
    func startRecording(_ which: String) {
        stopRecording(); recording = which
        HotKeys.shared.register([])             // while recording, the current shortcuts are keys to capture, not to act on
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self else { return ev }
            if ev.keyCode == 53 { self.stopRecording(); return nil }
            var mods: [String] = []
            if ev.modifierFlags.contains(.control) { mods.append("control") }
            if ev.modifierFlags.contains(.option) { mods.append("option") }
            if ev.modifierFlags.contains(.shift) { mods.append("shift") }
            if ev.modifierFlags.contains(.command) { mods.append("command") }
            // Shift or Option alone would swallow ordinary typing (capitals, ø å ∆) in every app, and macOS won't register them.
            guard mods.contains("control") || mods.contains("command") else { NSSound.beep(); return nil }
            var hk = self.config.shortcuts ?? Shortcuts()
            let sc = Shortcut(keyCode: Int(ev.keyCode), modifiers: mods)
            switch which { case "toggleShade": hk.toggleShade = sc; case "shadeDown": hk.shadeDown = sc; default: hk.shadeUp = sc }
            self.config.shortcuts = hk; self.saveConfig(reapply: false); self.registerHotkeys(); self.stopRecording()
            return nil
        }
    }
    func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil
        if recording != nil { recording = nil; registerHotkeys() }
    }

    func parseLive(_ out: String) {
        guard let line = out.components(separatedBy: "\n").first(where: { $0.hasPrefix("current:") }) else { return }
        var l = Settings()
        for tok in line.dropFirst(8).split(separator: " ") {
            let kv = tok.split(separator: "=", maxSplits: 1).map(String.init); guard kv.count == 2 else { continue }
            switch kv[0] {
            case "warmth": l.warmth = Double(kv[1])
            case "kbBrightness": l.keyboardBrightness = Double(kv[1])
            case "kbIdleDim": l.keyboardIdleDimSeconds = Double(kv[1].replacingOccurrences(of: "s", with: ""))
            case "kbAuto": l.keyboardAutoBrightness = kv[1] == "true"
            case "shade": l.shadeEnabled = kv[1] == "on"
            case "shadeLevel": l.shadeLevel = Double(kv[1])
            default: break
            }
        }
        if let v = l.keyboardBrightness { lastKeyboard = v } else { l.keyboardBrightness = lastKeyboard ?? live.keyboardBrightness }
        live = l
        syncKeyboardHold()
        if ProcessInfo.processInfo.environment["MIDNIGHT_DEBUG"] != nil {
            let line = "\(Date()) live warmth=\(l.warmth ?? -1) kb=\(l.keyboardBrightness ?? -1) idle=\(l.keyboardIdleDimSeconds ?? -1) shade=\(shade.enabled)/\(shade.level) | status: \(line)\n"
            if let h = try? FileHandle(forWritingTo: appDir.appendingPathComponent("debug-live.log")) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
            else { try? line.write(to: appDir.appendingPathComponent("debug-live.log"), atomically: true, encoding: .utf8) }
        }
    }
    /// What the keyboard should do: macOS runs it under auto-brightness (and with the switch off); otherwise Red Light
    /// does, holding a named level or keeping a level of macOS's range, with its own idle-off.
    func keyboardWant(_ v: Double?) -> KeyboardHold.Want {
        if isOff || live.keyboardAutoBrightness == true { return .none }
        guard let v = v else { return .none }
        if v <= 0 { return .off }
        if v >= 0.001 { return .level(v) }
        // A fade passes through every value below macOS's minimum: one that rounds to its 54 ticks is that level, and one
        // under half a tick still lights the lowest.
        let t = Int(kbTicks(v).rounded())
        return t >= Int(kbMinTicks) ? .level(0.001) : .hold(max(1, t))
    }
    func syncKeyboardHold() {
        guard !snapshotMode else { return }
        keyboardHold.update(keyboardWant(live.keyboardBrightness), idleSeconds: live.keyboardIdleDimSeconds ?? 5)
    }
    /// The keyboard slider: the change shows at once on the keys; the engine records it when you let go.
    func setKeyboard(ticks: Double, final: Bool) {
        let v = kbValue(ticks)
        live.keyboardBrightness = v; lastKeyboard = v; live.keyboardAutoBrightness = false
        keyboardHold.update(keyboardWant(v), idleSeconds: live.keyboardIdleDimSeconds ?? 5)
        if final { set("keyboard", v > 0 ? String(format: "%.6f", v * 100) : "off") }
    }
    func set(_ field: String, _ value: String, final: Bool = true) {
        switch field {
        case "keyboard": let v = value == "off" ? 0 : (Double(value) ?? 0) / 100; live.keyboardBrightness = v; lastKeyboard = v
        case "idle": live.keyboardIdleDimSeconds = Double(value)
        case "warmth": live.warmth = value == "off" ? 0 : (Double(value) ?? 0) / 100
        default: break
        }
        setsInFlight += 1
        liveQueue.async { [weak self] in
            _ = cli("set", field, value)
            DispatchQueue.main.async { guard let self = self else { return }
                self.setsInFlight -= 1
                if final { self.scheduleRefresh(after: 0.05) } }
        }
    }
    func applyPreset(_ p: Preset) { bringBackIfHeld(); runCLI(["preset", "apply", p.name]) }
    func useAtNight(_ p: Preset) { if isNight { bringBackIfHeld() }; runCLI(["preset", "night", p.name]) }   // at night it applies now
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
    // Only for documentation renders, where AppKit draws inactive controls without their glass or fill:
    // the active accent and the empty track, sampled from the running app on macOS 27 (dark).
    static let accentDrawn = Color(red: 57 / 255, green: 124 / 255, blue: 248 / 255)
    static let trackDrawn  = Color(red: 52 / 255, green: 52 / 255, blue: 52 / 255)
}
struct Step: Identifiable { let label: String; let value: Double?; var id: String { label } }
// Denser above the 60 % knee, where blue is already gone and each step is a different feel of red.
let warmSteps  = [Step(label: "Off", value: nil), Step(label: "15%", value: 0.15), Step(label: "30%", value: 0.3), Step(label: "45%", value: 0.45),
                  Step(label: "60%", value: 0.6), Step(label: "70%", value: 0.7), Step(label: "80%", value: 0.8), Step(label: "90%", value: 0.9), Step(label: "100%", value: 1.0)]
// 0.1 % is the practical floor: the keyboard's PWM table bottoms out just beneath it and anything lower looks the same.
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
/// Where a real value sits on a detented track, interpolated between stops, so a value that arrived from the
/// engine between two detents still puts the thumb in the right place.
func trackPosition(_ steps: [Step], value: Double?, isOn: Bool) -> Double {
    let offIndex = Double(steps.firstIndex { $0.value == nil } ?? 0)
    let vs = steps.compactMap { $0.value }.filter { $0 > 0 }
    let useLog = (vs.max() ?? 1) / (vs.min() ?? 1) > 20
    guard isOn, let v = value, v > 0 else { return offIndex }
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

struct GlassSlider: View {
    let minIcon: String; let maxIcon: String; let steps: [Step]; let current: Double?; let isOn: Bool
    let onChange: (Step, Bool) -> Void
    // The thumb is *derived* from `current` on every render. Only while the user is actually moving it does a
    // local override take over, and that override can never get stuck: it ends on AppKit's editing callback, or
    // half a second after the last movement, whichever comes first.
    @State private var dragIdx: Double? = nil
    @State private var lastSent = -1
    @State private var settle: DispatchWorkItem? = nil
    private var truePosition: Double { trackPosition(steps, value: current, isOn: isOn) }
    private func finish() {
        settle?.cancel(); settle = nil
        guard let v = dragIdx else { return }
        let i = Int(v.rounded())
        dragIdx = nil; lastSent = -1
        onChange(steps[i], true)
    }
    /// A mark under the track at every detent: one tick per stop the thumb can come to rest on, so the scale
    /// is legible before you touch it and every mark is somewhere the slider will actually go.
    private var tickMarks: some View {
        GeometryReader { geo in
            let knob: CGFloat = 20                        // the .regular knob; the track insets by half of it
            let span = max(1, geo.size.width - knob)
            let last = CGFloat(max(1, steps.count - 1))
            ForEach(steps.indices, id: \.self) { i in
                Capsule()
                    .fill(Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 2, height: 4)
                    .position(x: knob / 2 + span * CGFloat(i) / last, y: geo.size.height + 3.5)
            }
        }
    }
    /// The slider as it looks active on screen (a 6 pt track, the accent fill up to the knob, a 20 x 16 pt knob),
    /// drawn into the real control's frame for documentation renders only.
    private func drawnSlider(_ v: Double) -> some View {
        GeometryReader { geo in
            let knob = CGSize(width: 20, height: 16), span = max(1, geo.size.width - knob.width)
            let x = knob.width / 2 + span * CGFloat(v / Double(max(1, steps.count - 1))), mid = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(CC.trackDrawn).frame(width: geo.size.width, height: 6).position(x: geo.size.width / 2, y: mid)
                Capsule().fill(CC.accentDrawn).frame(width: x, height: 6).position(x: x / 2, y: mid)
                Capsule().fill(.white).frame(width: knob.width, height: knob.height)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5).position(x: x, y: mid)
            }
        }
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
            Image(systemName: minIcon).font(.system(size: 13)).foregroundStyle(CC.label).frame(width: 18)
            Slider(value: position, in: 0...Double(max(1, steps.count - 1))) { editing in if !editing { finish() } }
                .controlSize(.regular)      // Control Center's knob is 20 pt; .large draws 24
                .opacity(isSnapshotRun ? 0 : 1)
                .overlay { if isSnapshotRun { drawnSlider(position.wrappedValue) } }
                .overlay(alignment: .bottom) { tickMarks }
            Image(systemName: maxIcon).font(.system(size: 13)).foregroundStyle(CC.label).frame(width: 18)
        }
    }
}
/// Keyboard Backlight: off and the four named extra-dim levels on the left half, snapping, then all of macOS's range on
/// the right half, continuous and perceptually even (a log scale of light output). Marks sit only where something is: each extra-dim level and the
/// point where macOS's own minimum begins.
struct KeyboardSlider: View {
    let current: Double?
    let onChange: (Double, Bool) -> Void          // ticks, final
    static let zone = 0.5                                                       // half the track: off and the four named levels
    static let stops: [Double] = [0, 0.1, 0.2, 0.3, 0.4, 0.5]                  // off, the four levels, macOS's minimum
    static let stopTicks: [Double] = [0] + kbDimTicks + [kbMinTicks]
    static func position(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t < kbMinTicks {
            for k in 0..<(stopTicks.count - 1) where t <= stopTicks[k + 1] {
                return stops[k] + (stops[k + 1] - stops[k]) * (t - stopTicks[k]) / (stopTicks[k + 1] - stopTicks[k]) }
        }
        return zone + (1 - zone) * (log(max(t, kbMinTicks)) - log(kbMinTicks)) / (log(kbMaxTicks) - log(kbMinTicks))
    }
    /// Snaps on the left; continuous past macOS's minimum.
    static func snap(_ p: Double) -> (position: Double, ticks: Double) {
        if p < zone + 0.002 { let i = stops.indices.min { abs(stops[$0] - p) < abs(stops[$1] - p) }!; return (stops[i], stopTicks[i]) }
        let f = (p - zone) / (1 - zone)
        return (p, exp(log(kbMinTicks) + f * (log(kbMaxTicks) - log(kbMinTicks))).rounded())
    }
    @State private var drag: Double? = nil
    @State private var lastTicks = -1.0
    @State private var settle: DispatchWorkItem? = nil
    private func finish() {
        settle?.cancel(); settle = nil
        guard let p = drag else { return }
        drag = nil; lastTicks = -1
        onChange(Self.snap(p).ticks, true)
    }
    private var marks: some View {
        GeometryReader { geo in
            let knob: CGFloat = 20, span = max(1, geo.size.width - knob)
            ForEach(1..<Self.stops.count, id: \.self) { i in
                Capsule().fill(Color(nsColor: i == Self.stops.count - 1 ? .secondaryLabelColor : .tertiaryLabelColor))
                    .frame(width: 2, height: i == Self.stops.count - 1 ? 6 : 4)
                    .position(x: knob / 2 + span * CGFloat(Self.stops[i]), y: geo.size.height + (i == Self.stops.count - 1 ? 4.5 : 3.5))
            }
        }
    }
    private func drawn(_ p: Double) -> some View {
        GeometryReader { geo in
            let knob = CGSize(width: 20, height: 16), span = max(1, geo.size.width - knob.width)
            let x = knob.width / 2 + span * CGFloat(p), mid = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(CC.trackDrawn).frame(width: geo.size.width, height: 6).position(x: geo.size.width / 2, y: mid)
                Capsule().fill(CC.accentDrawn).frame(width: x, height: 6).position(x: x / 2, y: mid)
                Capsule().fill(.white).frame(width: knob.width, height: knob.height)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5).position(x: x, y: mid)
            }
        }
    }
    var body: some View {
        let position = Binding<Double>(
            get: { drag ?? Self.position(kbTicks(current)) },
            set: { p in
                let s = Self.snap(p)
                drag = s.position
                if s.ticks != lastTicks { lastTicks = s.ticks; onChange(s.ticks, false) }
                settle?.cancel()
                let w = DispatchWorkItem { finish() }
                settle = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
            })
        HStack(spacing: 10) {
            Image(systemName: "light.min").font(.system(size: 13)).foregroundStyle(CC.label).frame(width: 18)
            Slider(value: position, in: 0...1) { editing in if !editing { finish() } }
                .controlSize(.regular)
                .opacity(isSnapshotRun ? 0 : 1)
                .overlay { if isSnapshotRun { drawn(position.wrappedValue) } }
                .overlay(alignment: .bottom) { marks }
            Image(systemName: "light.max").font(.system(size: 13)).foregroundStyle(CC.label).frame(width: 18)
        }
        .frame(height: 32)
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
            // Measured from the running switch on macOS 27 at 2x: a 54 x 24 pt track and a 32 x 20 pt capsule knob
            // inset 2 pt (the Liquid Glass switch's knob is a pill, not a circle). Small scales by the system's 0.8.
            let k: CGFloat = small ? 0.8 : 1, w = 54 * k, h = 24 * k, kw = 32 * k, kh = 20 * k
            ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                Capsule().fill(isOn.wrappedValue ? CC.accentDrawn : CC.trackDrawn).frame(width: w, height: h)
                Capsule().fill(.white).frame(width: kw, height: kh).shadow(color: .black.opacity(0.22), radius: 1, y: 0.5).padding(2 * k)
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
    // Daylight: a Control Center state row at the top of the pane says what the scheduler is doing
    // ("Waiting for sunset" + when, the way the Focus pane says "Do Not Disturb · off"), and the pane's
    // controls stay live underneath — nothing is dimmed, nothing is hidden behind glass.
    // A pause is not daylight: the engine pauses by switching to day, and "Waiting for sunset" at 11 PM hid the
    // only way back, the Paused section's Resume row.
    var waiting: Bool { m.snapshotDaylight ? true : (m.enabled && !m.isNight && !m.isPaused && m.heldFor == nil) }

    var mainPage: some View {
        VStack(spacing: 0) {
            TitleBlock(title: "Red Light", subtitle: subtitle) {
                SwitchView(isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) }), drawn: m.snapshotMode)
            }
            if !m.enabled {
                // Off is off: like Wi-Fi or Bluetooth switched off, the pane keeps only its switch and its settings.
                SettingsRow(text: "Red Light Settings…").onTapGesture { page = "settings" }
            } else {
                if let app = m.heldFor {
                    IconRow(icon: "eyedropper.halffull", label: "True Color for \(app)", trailing: nil, active: true)
                    IconRow(icon: "sun.horizon.fill", label: "Bring Red Light Back").onTapGesture { m.trueColor.bringBack() }
                    SectionEnd()
                } else if waiting {
                    IconRow(icon: "sun.horizon", label: "Waiting for sunset",
                            trailing: m.sunsetText.isEmpty ? nil : m.sunsetText)
                    IconRow(icon: "sun.horizon.fill", label: "Turn On Now").onTapGesture { m.force("night") }
                    SectionEnd()
                }
                controls
            }
        }
        .padding(.horizontal, CC.side)
        .animation(.easeInOut(duration: 0.18), value: waiting)
        .animation(.easeInOut(duration: 0.18), value: m.enabled)
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

            Header(text: "Keyboard Backlight", value: fmtKeyboard(m.live.keyboardBrightness))
            KeyboardSlider(current: m.live.keyboardBrightness) { t, final in m.setKeyboard(ticks: t, final: final) }
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

            if !waiting {
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
        guard m.enabled else { return "Off" }
        if let app = m.heldFor { return "True color while \(app) is in front" }
        if m.isFading { return m.isNight ? "Sunset in progress" : "Sunrise in progress" }
        if m.isNight && !m.snapshotDaylight {                         // the daytime documentation image says Day, too
            let room = m.roomKindNow.map { " · \($0.capitalized) room" } ?? ""
            return m.sunriseText.isEmpty ? "Night\(room)" : "Night\(room) · Sunrise at \(m.sunriseText)"
        }
        return m.sunsetText.isEmpty ? "Day" : "Day · Sunset at \(m.sunsetText)"
    }
    /// What applying it would change nothing of. A preset without a keyboard or shade value leaves those alone when
    /// applied (only warmth defaults, to 0), so a missing one matches whatever is there rather than counting as off.
    func isCurrent(_ p: Preset) -> Bool {
        let s = p.settings
        let kbOK = s.keyboardBrightness.map { abs(kbTicks($0) - kbTicks(m.live.keyboardBrightness)) < 1 } ?? true
        let shadeOK = (s.shadeEnabled ?? m.shade.enabled) == m.shade.enabled
            && (!m.shade.enabled || s.shadeLevel.map { abs($0 - m.shade.level) < 0.02 } ?? true)
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

/// Version, automatic updates, and a manual install when one is waiting (a Control Center row with a trailing value).
struct UpdatesSection: View {
    @ObservedObject var u: Updater; var drawn = false
    var body: some View {
        VStack(spacing: 0) {
            Header(text: "Updates")
            ToggleRow(label: "Update Automatically", isOn: Binding(get: { u.automatic }, set: { u.automatic = $0 }), drawn: drawn)
            if let r = u.available {
                HStack { Text("Install Version \(r.version)").font(CC.row).foregroundStyle(CC.label); Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(CC.secondary) }
                    .frame(height: 33).contentShape(Rectangle()).onTapGesture { u.install() }
            } else {
                HStack { Text("Check for Updates").font(CC.row).foregroundStyle(CC.label); Spacer() }
                    .frame(height: 33).contentShape(Rectangle()).onTapGesture { u.check(userInitiated: true) }
            }
            TextRow(text: u.status.isEmpty ? "Version \(Updater.current)" + (u.automatic && u.available != nil ? " · installs when the screen isn’t red" : "")
                                           : "Version \(Updater.current) · \(u.status)", secondary: true)
            SectionEnd()
        }
    }
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
            ToggleRow(label: "Switch at Sunset and Sunrise", isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) }), drawn: m.snapshotMode)
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
            ToggleRow(label: "Match Room Light", isOn: Binding(get: { m.config.roomLight?.enabled ?? true }, set: {
                var r = m.config.roomLight ?? RoomLight(); r.enabled = $0; m.config.roomLight = r
                m.saveConfig(reapply: false); m.runCLI(["room"])           // queued behind the save: on eases to the room, off draws your level
            }), drawn: m.snapshotMode)
            TextRow(text: roomLevelsText, secondary: true)
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

            Header(text: "True Color")
            ToggleRow(label: "Ask in Color-Sensitive Apps", isOn: Binding(get: { m.config.trueColor?.ask ?? true },
                set: { var t = m.config.trueColor ?? TrueColor(); t.ask = $0; m.config.trueColor = t; m.saveConfig(reapply: false) }), drawn: m.snapshotMode)
            ForEach(m.trueColor.remembered, id: \.id) { r in
                ToggleRow(label: "\(r.name) in True Color", isOn: Binding(get: { r.always }, set: { m.trueColor.remember(r.id, always: $0) }), drawn: m.snapshotMode)
                    .contextMenu { Button("Forget Choice") { m.trueColor.forget(r.id) } }
            }
            TextRow(text: "Figma, Sketch, Photoshop, Lightroom, video editors and other design and photo apps can show true color while they are in front. Red Light comes back when you switch away.", secondary: true)
            Line()

            UpdatesSection(u: m.updater, drawn: m.snapshotMode)

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
    /// The level each kind of room has: what you last chose there, at night.
    var roomLevelsText: String {
        let l = (m.config.roomLight ?? RoomLight()).levels
        func f(_ v: Double) -> String { v > 0.001 ? "\(Int((v * 100).rounded()))%" : "off" }
        return "Remembers your Red Shift for each kind of room: dark \(f(l.dark)), dim \(f(l.dim)), lit \(f(l.lit))"
    }
    var locationLabel: String {
        let c = String(format: "%.2f, %.2f", m.config.latitude, m.config.longitude)
        switch m.config.locationSource { case "auto": return "\(c) · from this Mac"; case "manual": return "\(c) · manual"; default: return "\(c) · guessed from time zone" }
    }
}

// MARK: - App
/// One copy runs. A Mac can hold two (an old ~/Applications copy beside the one dragged from the disk image), and
/// whichever started first used to make the other quit — so the old build could win at every login. Now the newer
/// build survives and quits the older; between equal builds the one already running stays.
func isNewerBuild(_ a: [String: Any]?, than b: [String: Any]?) -> Bool {
    func v(_ i: [String: Any]?, _ k: String) -> String { i?[k] as? String ?? "0" }
    let (sa, sb) = (v(a, "CFBundleShortVersionString"), v(b, "CFBundleShortVersionString"))
    if Updater.newer(sa, than: sb) || Updater.newer(sb, than: sa) { return Updater.newer(sa, than: sb) }
    return Updater.newer(v(a, "CFBundleVersion"), than: v(b, "CFBundleVersion"))
}
func enforceSingleInstance() {
    let me = NSRunningApplication.current
    let others = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == me.bundleIdentifier && $0.processIdentifier != me.processIdentifier }
    let older = others.filter { o in isNewerBuild(Bundle.main.infoDictionary, than: o.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }) }
    if older.count < others.count { NSApp.terminate(nil); exit(0) }      // an equal or newer copy is already running
    older.forEach { $0.terminate() }
}
/// `Red Light --snapshot out.png [settings]` renders the panel to a PNG for documentation, off-screen, in dark
/// appearance, on a dark backdrop. No screen-recording grant is needed; system glass is not part of the view.
func snapshotIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
    let out = URL(fileURLWithPath: args[i + 1])
    let page = args.contains("settings") ? "settings" : args.contains("prompt") ? "prompt" : "main"
    let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
    let model = Model(); model.snapshotMode = true; model.snapshotDaylight = args.contains("daylight")
    model.snapshotDemo = args.contains("demo")
    // Let the live values (read through the engine, off the main thread) land before the view first appears,
    // so every slider and switch is created already showing the real state.
    model.refresh()
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        model.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let ap = NSAppearance(named: args.contains("light") ? .aqua : .darkAqua)
            let host = NSHostingView(rootView: SnapshotRoot(m: model, page: page, light: args.contains("light"), clear: args.contains("clear")))
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
    @ObservedObject var m: Model; let page: String; var light = false; var clear = false
    var body: some View {
        Group {
            if page == "main" { Panel(m: m) }
            else if page == "prompt" {
                let figma = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.figma.Desktop")
                TrueColorPromptView(name: "Figma", icon: figma.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(named: NSImage.applicationIconName)!) { _, _ in }
            }
            else { SettingsPage(m: m, back: {}) .frame(width: 303) }
        }
            .fixedSize(horizontal: false, vertical: true)
            // stands in for the system glass in the export; `clear` leaves it out so the panel can be
            // composited over real artwork with a real blurred backdrop
            .background(clear ? Color.clear : (light ? Color(white: 0.96) : Color(white: 0.13)))
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
            // The sun slipping below the horizon — what the app is named for. One symbol family carries every
            // state, the way native extras do: outline while waiting for sunset, filled when warming the
            // display, dimmed when paused or switched off at the master switch.
            Image(systemName: model.isNight ? "sun.horizon.fill" : "sun.horizon")
                .opacity(model.isPaused || !model.enabled ? 0.55 : 1)
        }
        .menuBarExtraStyle(.window)
    }
}
