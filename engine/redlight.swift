// redlight — eases the Mac into a warm, low-blue-light look after sunset and back again at sunrise,
// and quietly learns from manual adjustments.
// Usage: redlight check | night | day | pause <min>|sunrise | resume | set <field> <value> | preset … |
//        shade … | location <lat> <lon> [auto|manual] | reapply | status | suntimes | learned | forget |
//        on | off | hold <app> | release | room | curve
import Foundation
import IOKit

let appDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RedLight")
let configURL  = appDir.appendingPathComponent("config.json")
let stateURL   = appDir.appendingPathComponent("state.json")
let learnedURL = appDir.appendingPathComponent("learned.json")
let eventsURL  = appDir.appendingPathComponent("events.jsonl")
let logURL     = appDir.appendingPathComponent("redlight.log")
let shadeURL   = appDir.appendingPathComponent("shade.json")      // what the menu bar app should draw: shade overlay + gamma
let cmdURL     = appDir.appendingPathComponent("commanded.json")
let appProcessName = "RedLight"

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    print(s)
    // Every slider step is a line, so the log is capped: past 1 MB it becomes redlight.log.1 (replacing the last one).
    if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 1_000_000 {
        _ = rename(logURL.path, logURL.path + ".1")
    }
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}
func notify(_ msg: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    let esc = msg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    p.arguments = ["-e", "display notification \"\(esc)\" with title \"Red Light\""]
    try? p.run()
}

// MARK: - Models
struct Settings: Codable {
    var filterEnabled: Bool?            // advanced / legacy: driven by `warmth` when that is present
    var filterType: Int?
    var hue: Double?
    var intensity: Double?
    var keyboardBrightness: Double?
    var keyboardIdleDimSeconds: Double?
    var keyboardAutoBrightness: Bool?
    var shadeEnabled: Bool?
    var shadeLevel: Double?
    var warmth: Double?                 // 0-1, the unified control (see warmthCurve)
}
/// Rendered by the menu bar app. `gammaBlue`/`gammaGreen` are channel multipliers derived from `warmth`.
/// `warmth` is what is drawn; `base` what the schedule, a preset or the slider chose, before the room's lift (see `lifted`).
struct Shade: Codable { var enabled: Bool = false; var level: Double = 0.3; var warmth: Double? = 0; var gammaBlue: Double? = 1; var gammaGreen: Double? = 1; var base: Double? }
struct Commanded: Codable { var keyboardBrightness: Double? }
/// macOS's lowest keyboard level is 0.001, which drives the backlight's PWM at 54 of 960 ticks; every value up to about
/// 0.008 is that same level. The hardware goes down to 1 tick, and the menu bar app holds it there: a value between 0
/// and 0.001 means "this fraction of macOS's minimum", so the four extra-dim levels, 2, 4, 9 and 21 ticks, are
/// 2/54 … 21/54 of 0.001. The engine records them; the app drives the hardware.
let kbFloor = 0.001
func isExtraDim(_ v: Double?) -> Bool { guard let v = v else { return false }; return v > 0 && v < kbFloor }
let extraDimLevels = [2.0, 4, 9, 21].map { $0 / 54 * kbFloor }
/// PWM ticks of a stored level (see kbTicks in the app): 54 at macOS's minimum, 336 at full.
func kbTicksOf(_ v: Double) -> Double { v <= 0 ? 0 : v < kbFloor ? v / kbFloor * 54 : max(54, 51.5 + 284.5 * v) }
func loadCommanded() -> Commanded { (try? Data(contentsOf: cmdURL)).flatMap { try? JSONDecoder().decode(Commanded.self, from: $0) } ?? Commanded() }
func saveCommanded(_ c: Commanded) { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(c).write(to: cmdURL, options: .atomic) }
func loadShade() -> Shade { (try? Data(contentsOf: shadeURL)).flatMap { try? JSONDecoder().decode(Shade.self, from: $0) } ?? Shade() }
func saveShade(_ sh: Shade) { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(sh).write(to: shadeURL, options: .atomic) }
struct Learning: Codable {
    var enabled: Bool = true
    var minNights: Int = 3
    var lookbackDays: Int = 14
    var maxOffsetMinutes: Double = 120
    init() {}
    /// Lenient, as in the app: a hand-edited partial block ({"enabled": false}) failed the whole config and stopped
    /// the schedule while the pane looked fine. Missing or malformed fields take their defaults.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        minNights = (try? c.decode(Int.self, forKey: .minNights)) ?? 3
        lookbackDays = (try? c.decode(Int.self, forKey: .lookbackDays)) ?? 14
        maxOffsetMinutes = (try? c.decode(Double.self, forKey: .maxOffsetMinutes)) ?? 120
    }
}
struct Preset: Codable { var name: String; var icon: String; var settings: Settings }
/// Deepen the red in a dark room: a pitch-dark room takes Red Shift `strength` of the way to 100 % (1 was too red at
/// night). Lenient, like `Learning`.
struct RoomLight: Codable {
    var enabled = true
    var strength = 0.6
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        strength = max(0, min(1, (try? c.decode(Double.self, forKey: .strength)) ?? 0.6))
    }
}
struct Config: Codable {
    var latitude: Double
    var longitude: Double
    var locationSource: String?         // "auto" (from the Mac) | "manual" | "timezone" (a guess)
    var fadeMinutes: Double?            // length of the sunset / sunrise transition; 0 = instant
    var night: Settings
    var dayDefaults: Settings
    var learning: Learning?
    var presets: [Preset]?
    var nightPresetName: String?
    var shortcuts: JSONAny?
    var trueColor: JSONAny?             // owned by the app: which colour-critical apps get true colour
    var roomLight: RoomLight?
}
struct JSONAny: Codable {
    let value: Any
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let v = try? c.decode([String: JSONAny].self) { value = v.mapValues { $0.value } }
        else if let v = try? c.decode([JSONAny].self) { value = v.map { $0.value } }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else { value = NSNull() }
    }
    init(_ v: Any) { value = v }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch value {
        case let v as [String: Any]: try c.encode(v.mapValues { JSONAny($0) })
        case let v as [Any]: try c.encode(v.map { JSONAny($0) })
        case let v as String: try c.encode(v)
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        default: try c.encodeNil()
        }
    }
}
/// A transition in progress: settings ease from `from` to `to` over `seconds`, one step per check.
struct Ramp: Codable { var start: Date; var seconds: Double; var from: Settings; var to: Settings; var label: String }
struct State: Codable {
    var mode: String                    // "day" | "night" | "unset"
    var daySnapshot: Settings?
    var lastSeen: Settings?
    var lastNotified: Date?
    var ramp: Ramp?
    var pausedUntil: Date?
    /// The master switch. When true nothing is scheduled, nothing is learned, and `check` holds the display
    /// at its normal look — this, not whether the launchd agent happens to be loaded, is what "off" means.
    var disabled: Bool?
    /// True colour for a colour-critical app in front (e.g. "Figma"): the look is suspended, not changed.
    var heldFor: String?
    /// A tint set by hand (`set tint`) that was on when the hold began; Red Shift's own tint is recomputed instead.
    var customTintHeld: Bool?
    /// When `night`/`day` ("Turn On Now") overrode the schedule. The override stands until the schedule next turns.
    var forcedAt: Date?
    /// The room as last sensed: `darkness` eases toward `target` (see `senseRoom`). `lux` is -1 with no reading.
    var room: Room?
}
struct Room: Codable { var lux: Double; var target: Double; var darkness: Double; var at: Date }
struct Learned: Codable {
    var sunsetOffsetMinutes: Double = 0
    var sunriseOffsetMinutes: Double = 0
    var nightKeyboardBrightness: Double?
    var nightIdleDimSeconds: Double?
    var nightShadeLevel: Double?
    var nightWarmth: Double?
    var history: [String] = []
    /// Night levels are learned only from changes after this (set when a new sunset preset is chosen).
    var levelsSince: Date?
}
struct Event: Codable {
    var t: Date; var mode: String; var nightID: String
    var minsFromSunset: Double; var minsFromSunrise: Double
    var field: String; var from: Double; var to: Double
}

// MARK: - The unified warmth curve
// Two mechanisms, opposite strengths:
//  • Gamma-table channel scaling (what Night Shift and f.lux do) physically removes blue while every pixel keeps
//    its brightness ordering per channel, so text and UI stay crisp. Its limit: content that lives only in a
//    removed channel goes dark, and it cannot remove blue "beyond zero".
//  • Apple's Color Tint filter maps each pixel to its luminance and mixes toward red. Luminance is preserved,
//    so nothing disappears, but hue collapses — at high intensity everything is the same red.
// So: stage 1 (0–60 %) is pure channel scaling until blue is gone and green is trimmed. Stage 2 (60–100 %)
// holds blue at zero, eases green down further, and adds a modest luminance-preserving tint so that the green
// being removed photometrically comes back as red brightness instead of fading to black.
func warmthCurve(_ w: Double) -> (blue: Double, green: Double, tint: Double) {
    let w = max(0, min(1, w))
    if w <= 0.6 { let t = w / 0.6; return (1 - t, 1 - 0.40 * t, 0) }
    let t = (w - 0.6) / 0.4
    return (0, 0.60 - 0.25 * t, 0.50 * t)
}

// MARK: - Display color filter (MediaAccessibility.framework)
let colorCategory = 1
let ma = dlopen("/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility", RTLD_NOW)!
func maSym<T>(_ n: String, _ t: T.Type) -> T { unsafeBitCast(dlsym(ma, n)!, to: t) }
let maGetEnabled = maSym("MADisplayFilterPrefGetCategoryEnabled", (@convention(c) (Int) -> Bool).self)
let maSetEnabled = maSym("MADisplayFilterPrefSetCategoryEnabled", (@convention(c) (Int, Bool) -> Void).self)
let maGetType    = maSym("MADisplayFilterPrefGetType", (@convention(c) (Int) -> Int).self)
let maSetType    = maSym("MADisplayFilterPrefSetType", (@convention(c) (Int, Int) -> Void).self)
let maGetHue     = maSym("MADisplayFilterPrefGetSingleColorHue", (@convention(c) () -> Double).self)
let maSetHue     = maSym("MADisplayFilterPrefSetSingleColorHue", (@convention(c) (Double) -> Void).self)
let maGetInten   = maSym("MADisplayFilterPrefGetSingleColorIntensity", (@convention(c) () -> Double).self)
let maSetInten   = maSym("MADisplayFilterPrefSetSingleColorIntensity", (@convention(c) (Double) -> Void).self)

// MARK: - Keyboard backlight (CoreBrightness.framework, private)
_ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
let kbClient = (NSClassFromString("KeyboardBrightnessClient") as! NSObject.Type).init()
func kbIDs() -> [UInt64] { (kbClient.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeUnretainedValue() as? [NSNumber])?.map { $0.uint64Value } ?? [] }
func kbImp(_ sel: String) -> (IMP, Selector) { let s = NSSelectorFromString(sel); return (kbClient.method(for: s)!, s) }
func kbGetFloat(_ sel: String, _ id: UInt64) -> Float { let (imp, s) = kbImp(sel); return unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, UInt64) -> Float).self)(kbClient, s, id) }
func kbGetDouble(_ sel: String, _ id: UInt64) -> Double { let (imp, s) = kbImp(sel); return unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, UInt64) -> Double).self)(kbClient, s, id) }
func kbGetBool(_ sel: String, _ id: UInt64) -> Bool { let (imp, s) = kbImp(sel); return unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, UInt64) -> Bool).self)(kbClient, s, id) }
@discardableResult func kbSetBrightness(_ v: Float, _ id: UInt64) -> Bool { let (imp, s) = kbImp("setBrightness:forKeyboard:"); return unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, Float, UInt64) -> Bool).self)(kbClient, s, v, id) }
@discardableResult func kbSetIdleDim(_ v: Double, _ id: UInt64) -> Bool { let (imp, s) = kbImp("setIdleDimTime:forKeyboard:"); return unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, Double, UInt64) -> Bool).self)(kbClient, s, v, id) }
@discardableResult func kbSetAuto(_ v: Bool, _ id: UInt64) -> Bool { let (imp, s) = kbImp("enableAutoBrightness:forKeyboard:"); return unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool).self)(kbClient, s, v, id) }

// MARK: - Read / apply
/// The menu bar app has the keys dark for inactivity (its `keyboard-idle` marker). A marker left by an app that quit or
/// crashed counts for nothing: only while the app runs.
func appIdleKeys() -> Bool { FileManager.default.fileExists(atPath: appDir.appendingPathComponent("keyboard-idle").path) && runningApp() }
func readCurrent() -> Settings {
    var s = Settings(filterEnabled: maGetEnabled(colorCategory), filterType: maGetType(colorCategory), hue: maGetHue(), intensity: maGetInten())
    if let id = kbIDs().first {
        // The menu bar app runs idle-off itself while it sets the keys, and marks it: dark keys then aren't a change.
        let dimmed = kbGetBool("isBacklightDimmedOnKeyboard:", id) || kbGetBool("isBacklightSuppressedOnKeyboard:", id) || appIdleKeys()
        s.keyboardAutoBrightness = kbGetBool("isAutoBrightnessEnabledForKeyboard:", id)
        s.keyboardIdleDimSeconds = kbGetDouble("idleDimTimeForKeyboard:", id)
        if !dimmed && s.keyboardAutoBrightness == false {
            let v = Double(kbGetFloat("brightnessForKeyboard:", id))
            let known = loadCommanded().keyboardBrightness
            // An extra-dim level is the app's to hold, and on the way there the keys still show the old level: the
            // record stands. (The brightness keys during a hold are reported by the app itself.)
            if isExtraDim(known) { s.keyboardBrightness = known }
            else {
                s.keyboardBrightness = v
                if known == nil || abs(known! - v) > 0.0005 { saveCommanded(Commanded(keyboardBrightness: v)) }
            }
        } else if s.keyboardAutoBrightness == false {
            s.keyboardBrightness = loadCommanded().keyboardBrightness
        }
    }
    // The chosen warmth, not the drawn one: the room's lift is never a change of yours, nor a fade's starting point.
    let sh = loadShade(); s.shadeEnabled = sh.enabled; s.shadeLevel = sh.level; s.warmth = sh.base ?? sh.warmth ?? 0
    return s
}
/// Set while a colour-critical app holds true colour: everything is applied as usual except the tint stays off.
var holdTint = false
func apply(_ s: Settings, label: String, quiet: Bool = false) {
    if let w = s.warmth {
        // Warmth owns the color filter. The tint is one leg of the curve; the gamma legs go to the app.
        let shown = lifted(w), c = warmthCurve(shown)
        maSetType(colorCategory, 16); maSetHue(1.0)
        maSetInten(c.tint); maSetEnabled(colorCategory, !holdTint && c.tint > 0.001)
        var sh = loadShade(); sh.warmth = shown; sh.base = w; sh.gammaBlue = c.blue; sh.gammaGreen = c.green
        if let e = s.shadeEnabled { sh.enabled = e }
        if let l = s.shadeLevel { sh.level = l }
        saveShade(sh)
    } else {
        if let t = s.filterType { maSetType(colorCategory, t) }
        if let h = s.hue { maSetHue(h) }
        if let i = s.intensity { maSetInten(i) }
        if let e = s.filterEnabled { maSetEnabled(colorCategory, e && !holdTint) }   // `set tint` under a hold waits too
        if s.shadeEnabled != nil || s.shadeLevel != nil {
            var sh = loadShade()
            if let e = s.shadeEnabled { sh.enabled = e }
            if let l = s.shadeLevel { sh.level = l }
            saveShade(sh)
        }
    }
    for id in kbIDs() {
        if let d = s.keyboardIdleDimSeconds { kbSetIdleDim(d, id) }
        if let a = s.keyboardAutoBrightness { kbSetAuto(a, id) }
        // Extra-dim levels are the app's to hold. Keys the app has turned off for inactivity stay off: it lights them at the
        // next touch, at the level recorded here (a fade step each minute lit them for a moment).
        if let b = s.keyboardBrightness { if !isExtraDim(b) && !(b > 0 && appIdleKeys()) { kbSetBrightness(Float(b), id) }; saveCommanded(Commanded(keyboardBrightness: b)) }
    }
    if !quiet { log("applied \(label): \(describe(s))" + (s.warmth.map { abs(lifted($0) - $0) > 0.005 ? String(format: " (dark room: shown at %.2f)", lifted($0)) : "" } ?? "")) }
}
func describe(_ s: Settings) -> String {
    var p: [String] = []
    if let v = s.warmth { p.append(String(format: "warmth=%.2f", v)) }
    if let v = s.filterEnabled { p.append("filter=\(v ? "on" : "off")") }
    if let v = s.intensity { p.append(String(format: "tint=%.2f", v)) }
    if let v = s.keyboardBrightness { p.append(String(format: "kbBrightness=%.6f", v)) }
    if let v = s.keyboardIdleDimSeconds { p.append("kbIdleDim=\(Int(v))s") }
    if let v = s.keyboardAutoBrightness { p.append("kbAuto=\(v)") }
    if let v = s.shadeEnabled { p.append("shade=\(v ? "on" : "off")") }
    if let v = s.shadeLevel { p.append(String(format: "shadeLevel=%.2f", v)) }
    return p.joined(separator: " ")
}

// MARK: - Easing between two looks
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
/// Brightness eases logarithmically (perceptually even); levels ease linearly. Discrete settings switch at the start.
func blend(_ from: Settings, _ to: Settings, _ t: Double) -> Settings {
    var s = to
    let t = max(0, min(1, t))
    if let a = from.warmth, let b = to.warmth { s.warmth = lerp(a, b, t) }
    if let b = to.keyboardBrightness {
        let a = from.keyboardBrightness ?? b
        if a > 0 && b > 0 { s.keyboardBrightness = exp(lerp(log(a), log(b), t)) } else { s.keyboardBrightness = lerp(a, b, t) }   // through the extra-dim levels too
    }
    if let b = to.shadeLevel, to.shadeEnabled == true {
        let a = (from.shadeEnabled == true ? from.shadeLevel : 0) ?? 0
        s.shadeLevel = lerp(a, b, t); s.shadeEnabled = true
    } else if to.shadeEnabled == false, from.shadeEnabled == true, let a = from.shadeLevel {
        s.shadeLevel = lerp(a, 0, t); s.shadeEnabled = t < 1   // fade the shade out, then switch it off
    }
    return s
}

// MARK: - Sunrise / sunset (NOAA)
func sunTimes(lat: Double, lon: Double, date: Date) -> (rise: Date?, set: Date?) {
    let cal = Calendar.current
    let startOfDay = cal.startOfDay(for: date)
    let jd = startOfDay.timeIntervalSince1970 / 86400.0 + 2440587.5
    func rad(_ d: Double) -> Double { d * .pi / 180 }
    func deg(_ r: Double) -> Double { r * 180 / .pi }
    func eventUTCMinutes(_ jday: Double, rise: Bool) -> Double? {
        let t = (jday - 2451545.0) / 36525.0
        let L0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let M = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let C = sin(rad(M)) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sin(rad(2*M)) * (0.019993 - 0.000101 * t) + sin(rad(3*M)) * 0.000289
        let omega = 125.04 - 1934.136 * t
        let lambda = L0 + C - 0.00569 - 0.00478 * sin(rad(omega))
        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(rad(omega))
        let decl = deg(asin(sin(rad(eps)) * sin(rad(lambda))))
        let y = tan(rad(eps / 2)) * tan(rad(eps / 2))
        let eqTime = 4 * deg(y * sin(2*rad(L0)) - 2*e*sin(rad(M)) + 4*e*y*sin(rad(M))*cos(2*rad(L0)) - 0.5*y*y*sin(4*rad(L0)) - 1.25*e*e*sin(2*rad(M)))
        let cosHA = (cos(rad(90.833)) / (cos(rad(lat)) * cos(rad(decl)))) - tan(rad(lat)) * tan(rad(decl))
        guard cosHA >= -1, cosHA <= 1 else { return nil }
        let ha = deg(acos(cosHA)) * (rise ? 1 : -1)
        return 720 - 4 * (lon + ha) - eqTime
    }
    func toDate(_ minutesUTC: Double?) -> Date? {
        guard let m = minutesUTC else { return nil }
        var utcCal = Calendar(identifier: .gregorian); utcCal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day], from: startOfDay)
        return utcCal.date(from: comps)!.addingTimeInterval(m * 60)
    }
    var rise = toDate(eventUTCMinutes(jd, rise: true))
    var set  = toDate(eventUTCMinutes(jd, rise: false))
    if let r = rise { rise = toDate(eventUTCMinutes(jd + r.timeIntervalSince(startOfDay)/86400, rise: true)) }
    if let s = set  { set  = toDate(eventUTCMinutes(jd + s.timeIntervalSince(startOfDay)/86400, rise: false)) }
    return (rise, set)
}
func effectiveSun(cfg: Config, learned: Learned, date: Date) -> (rise: Date?, set: Date?) {
    let (r, s) = sunTimes(lat: cfg.latitude, lon: cfg.longitude, date: date)
    return (r?.addingTimeInterval(learned.sunriseOffsetMinutes * 60), s?.addingTimeInterval(learned.sunsetOffsetMinutes * 60))
}
/// The same time on a neighbouring calendar day. (±86400 s skips or repeats a day around a DST change.)
func day(_ n: Int, from d: Date) -> Date { Calendar.current.date(byAdding: .day, value: n, to: d) ?? d.addingTimeInterval(Double(n) * 86400) }
/// Every switch near `now`, in order (`night` true for a sunset). Today's pair alone isn't enough: a learned offset
/// can push a sunset past midnight, and a location far from the Mac's time zone (travel, a manual location) puts
/// its sunset on the next local day — comparing against today's sunrise and sunset alone called those wrong.
func transitions(cfg: Config, learned: Learned, now: Date) -> [(at: Date, night: Bool)] {
    var out: [(at: Date, night: Bool)] = []
    for n in -1...1 {
        let (r, s) = effectiveSun(cfg: cfg, learned: learned, date: day(n, from: now))
        if let s = s { out.append((s, true)) }
        if let r = r, s.map({ r < $0 }) ?? true { out.append((r, false)) }   // offsets crossed on a very short day: night throughout
    }
    return out.sorted { $0.at < $1.at }
}
func isNight(cfg: Config, learned: Learned, now: Date) -> Bool {
    let ts = transitions(cfg: cfg, learned: learned, now: now)
    // A day with no sunrise or sunset is polar day or night throughout, whatever the switches around it say: the midnight
    // sun's last day is followed by a sunrise, and reading that as "night until then" kept the screen red all day.
    let today = sunTimes(lat: cfg.latitude, lon: cfg.longitude, date: now)
    if today.rise != nil || today.set != nil {
        if let last = ts.last(where: { $0.at <= now }) { return last.night }
        if let next = ts.first { return !next.night }   // a location far east of the Mac's zone: its day starts later
    }
    let m = Calendar.current.component(.month, from: now)   // polar day or night: no sunrise or sunset for days
    return cfg.latitude > 0 ? (m >= 10 || m <= 3) : (m >= 4 && m <= 9)
}
/// The transition that most recently began (for computing fade progress after a sleep).
func lastTransition(cfg: Config, learned: Learned, now: Date) -> Date? {
    transitions(cfg: cfg, learned: learned, now: now).last { $0.at <= now }?.at
}
func nextSunrise(cfg: Config, learned: Learned, now: Date) -> Date? {
    transitions(cfg: cfg, learned: learned, now: now).first { !$0.night && $0.at > now }?.at
}
func sunTimes(cfg: Config, learned: Learned, near now: Date) -> (rise: Date, set: Date) {
    let days = [-1, 0, 1].map { sunTimes(lat: cfg.latitude, lon: cfg.longitude, date: day($0, from: now)) }
    func nearest(_ times: [Date?]) -> Date { times.compactMap { $0 }.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) } ?? now }
    return (nearest(days.map { $0.rise }), nearest(days.map { $0.set }))
}
/// A coarse fallback so a fresh install has plausible sun times before the app resolves a real location.
func timezoneGuess() -> (Double, Double, String)? {
    let table: [String: (Double, Double)] = [
        "America/Los_Angeles": (34.05, -118.24), "America/Denver": (39.74, -104.99), "America/Phoenix": (33.45, -112.07),
        "America/Chicago": (41.88, -87.63), "America/New_York": (40.71, -74.01), "America/Toronto": (43.65, -79.38),
        "America/Vancouver": (49.28, -123.12), "America/Mexico_City": (19.43, -99.13), "America/Sao_Paulo": (-23.55, -46.63),
        "America/Anchorage": (61.22, -149.90), "Pacific/Honolulu": (21.31, -157.86), "Europe/London": (51.51, -0.13),
        "Europe/Paris": (48.86, 2.35), "Europe/Berlin": (52.52, 13.41), "Europe/Madrid": (40.42, -3.70), "Europe/Rome": (41.90, 12.50),
        "Europe/Amsterdam": (52.37, 4.90), "Europe/Stockholm": (59.33, 18.07), "Europe/Moscow": (55.76, 37.62), "Asia/Dubai": (25.20, 55.27),
        "Asia/Kolkata": (19.08, 72.88), "Asia/Singapore": (1.35, 103.82), "Asia/Hong_Kong": (22.32, 114.17), "Asia/Shanghai": (31.23, 121.47),
        "Asia/Tokyo": (35.68, 139.69), "Asia/Seoul": (37.57, 126.98), "Australia/Sydney": (-33.87, 151.21), "Australia/Melbourne": (-37.81, 144.96),
        "Pacific/Auckland": (-36.85, 174.76), "Africa/Johannesburg": (-26.20, 28.05), "Africa/Cairo": (30.04, 31.24)]
    let id = TimeZone.current.identifier
    if let c = table[id] { return (c.0, c.1, id) }
    return nil
}

// MARK: - Persistence
let enc: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
func loadConfig() -> Config? {
    guard let d = try? Data(contentsOf: configURL), let c = try? dec.decode(Config.self, from: d) else { log("ERROR: cannot read \(configURL.path)"); return nil }
    return c
}
func loadState() -> State? { (try? Data(contentsOf: stateURL)).flatMap { try? dec.decode(State.self, from: $0) } }
func saveConfig(_ c: Config) { try? enc.encode(c).write(to: configURL, options: .atomic) }
func saveState(_ s: State) { try? enc.encode(s).write(to: stateURL, options: .atomic) }
func loadLearned() -> Learned { (try? Data(contentsOf: learnedURL)).flatMap { try? dec.decode(Learned.self, from: $0) } ?? Learned() }
func saveLearned(_ l: Learned) { try? enc.encode(l).write(to: learnedURL, options: .atomic) }
func pruneEvents(olderThan cutoff: Date) {
    guard let text = try? String(contentsOf: eventsURL, encoding: .utf8) else { return }
    let keep = text.split(separator: "\n").filter { line in
        guard let e = try? dec.decode(Event.self, from: Data(line.utf8)) else { return false }
        return e.t >= cutoff
    }
    try? (keep.joined(separator: "\n") + (keep.isEmpty ? "" : "\n")).write(to: eventsURL, atomically: true, encoding: .utf8)
}
func appendEvent(_ e: Event) {
    let line = JSONEncoder(); line.dateEncodingStrategy = .iso8601
    guard var d = try? line.encode(e) else { return }
    d.append(0x0A)
    if let h = try? FileHandle(forWritingTo: eventsURL) { h.seekToEndOfFile(); h.write(d); h.closeFile() } else { try? d.write(to: eventsURL) }
}
func loadEvents(since: Date) -> [Event] {
    guard let text = try? String(contentsOf: eventsURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { try? dec.decode(Event.self, from: Data($0.utf8)) }.filter { $0.t >= since }
}

// MARK: - Observing manual changes
/// Returns the updated state and which fields were changed by hand since the last check. Changes are noticed even
/// with learning off — a fade must not run over them — and recorded for learning only when it is on.
func observe(cfg: Config, learned: Learned, state: State, now: Date) -> (State, Set<String>) {
    var st = state
    let cur = readCurrent()
    st.lastSeen = cur
    guard let prev = state.lastSeen else { return (st, []) }
    let record = cfg.learning?.enabled ?? true
    let (rise, set) = sunTimes(cfg: cfg, learned: learned, near: now)
    let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
    let todayRise = sunTimes(lat: cfg.latitude, lon: cfg.longitude, date: now).rise ?? now
    let nightID = dayFmt.string(from: now < todayRise ? day(-1, from: now) : now)
    var fields: Set<String> = []
    func changed(_ field: String, _ a: Double?, _ b: Double?, tol: Double, differ: ((Double, Double) -> Bool)? = nil) {
        guard let a = a, let b = b, differ?(a, b) ?? (abs(a - b) > tol) else { return }
        fields.insert(field)
        let ev = Event(t: now, mode: state.mode, nightID: nightID, minsFromSunset: now.timeIntervalSince(set) / 60,
                       minsFromSunrise: now.timeIntervalSince(rise) / 60, field: field, from: a, to: b)
        if record { appendEvent(ev) }
        log("noticed manual change: \(field) \(String(format: "%.3f", a)) -> \(String(format: "%.3f", b)) (\(state.mode), \(Int(ev.minsFromSunset)) min after sunset)")
    }
    changed("warmth", prev.warmth, cur.warmth, tol: 0.02)
    // The tint leg follows warmth across 60 %: easing red from 80 % to 50 % is one change, not also "switched the
    // filter off" — which the timing rules would read as turning red light off and move sunrise or sunset.
    if prev.warmth == cur.warmth { changed("filterEnabled", prev.filterEnabled.map { $0 ? 1 : 0 }, cur.filterEnabled.map { $0 ? 1 : 0 }, tol: 0.5) }
    // Below macOS's minimum every level is within 0.001 of the next, so a hand-set Starlight, Moonlight, Candlelight or
    // Firelight (or off) is told by its ticks as well: a fade used to carry on over it.
    changed("keyboardBrightness", prev.keyboardBrightness, cur.keyboardBrightness, tol: 0.005,
            differ: { abs($0 - $1) > 0.005 || abs(kbTicksOf($0) - kbTicksOf($1)) > 1.5 })
    // Under auto-brightness the level isn't read, so a keyboard slider (auto off) or the system's own switch (auto on)
    // went unseen and a fade turned it straight back. Not a lesson — one side has no level — but the fade must keep it.
    if let a = prev.keyboardAutoBrightness, let b = cur.keyboardAutoBrightness, a != b { fields.insert("keyboardBrightness") }
    changed("keyboardIdleDimSeconds", prev.keyboardIdleDimSeconds, cur.keyboardIdleDimSeconds, tol: 0.5)
    changed("shadeEnabled", prev.shadeEnabled.map { $0 ? 1 : 0 }, cur.shadeEnabled.map { $0 ? 1 : 0 }, tol: 0.5)
    changed("shadeLevel", prev.shadeLevel, cur.shadeLevel, tol: 0.02)
    return (st, fields)
}

// MARK: - Learning
func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.count % 2 == 1 ? s[s.count/2] : (s[s.count/2 - 1] + s[s.count/2]) / 2 }
func learn(cfg: Config, learned: Learned, state: inout State, now: Date) -> Learned {
    let L = cfg.learning ?? Learning()
    guard L.enabled else { return learned }
    let minNights = max(1, L.minNights)     // a hand-edited 0 let an empty set through to median(), which trapped on every check
    var new = learned
    let events = loadEvents(since: now.addingTimeInterval(-Double(L.lookbackDays) * 86400))
    guard !events.isEmpty else { return learned }
    var notes: [String] = []
    func settledNightValue(_ field: String, tol: Double) -> Double? {
        var lastPerNight: [String: Double] = [:]
        // Turning red off (before bed, at dawn) says when night should end, not how red it should be: counting it
        // here learned a night warmth of 0. And evidence from before a newly chosen sunset preset is stale.
        for e in events where e.field == field && e.mode == "night" && e.t >= (learned.levelsSince ?? .distantPast)
                               && !(field == "warmth" && e.to <= 0.02) { lastPerNight[e.nightID] = e.to }
        let vals = Array(lastPerNight.values)
        guard vals.count >= minNights else { return nil }
        let m = median(vals)
        return vals.filter { abs($0 - m) <= tol }.count >= minNights ? m : nil
    }
    if let v = settledNightValue("warmth", tol: 0.1) {
        let cur = learned.nightWarmth ?? cfg.night.warmth ?? 0
        if abs(v - cur) > 0.05 { new.nightWarmth = v; notes.append(String(format: "night red shift %.0f%%", v * 100)) }
    }
    if let v = settledNightValue("keyboardBrightness", tol: 0.05) {
        let cur = learned.nightKeyboardBrightness ?? cfg.night.keyboardBrightness ?? 0
        if abs(v - cur) > 0.01 { new.nightKeyboardBrightness = v; notes.append(String(format: "night keyboard brightness %.1f%%", v * 100)) }
    }
    if let v = settledNightValue("keyboardIdleDimSeconds", tol: 0.5) {
        let cur = learned.nightIdleDimSeconds ?? cfg.night.keyboardIdleDimSeconds ?? 0
        if abs(v - cur) > 0.5 { new.nightIdleDimSeconds = v; notes.append("keyboard idle-off \(Int(v))s at night") }
    }
    if cfg.night.shadeEnabled == true, let v = settledNightValue("shadeLevel", tol: 0.1) {
        let cur = learned.nightShadeLevel ?? cfg.night.shadeLevel ?? 0
        if abs(v - cur) > 0.05 { new.nightShadeLevel = v; notes.append(String(format: "night screen shade %.0f%%", v * 100)) }
    }
    // Timing: turning warmth on/off by hand near a transition moves that transition.
    func offsets(_ pred: (Event) -> Double?) -> Double? {
        var perNight: [String: Double] = [:]
        for e in events where e.field == "warmth" || e.field == "filterEnabled" { if let o = pred(e) { perNight[e.nightID] = o } }
        let vals = Array(perNight.values)
        guard vals.count >= minNights else { return nil }
        let m = median(vals)
        return vals.filter { abs($0 - m) <= 30 }.count >= minNights ? m : nil
    }
    func turnedOn(_ e: Event) -> Bool { e.from <= 0.02 && e.to > 0.02 }
    func turnedOff(_ e: Event) -> Bool { e.from > 0.02 && e.to <= 0.02 }
    let sunsetOff = offsets { e in
        // Windows reach to where the switch happens now, so a learned offset can be walked back as well as further
        // (with only the raw-sunset windows, an offset of -40 could never move later again) — and no further, so
        // switching off a "Turn On Now" in the afternoon isn't taken for a sunset time.
        let o = learned.sunsetOffsetMinutes
        if e.mode == "day", turnedOn(e), e.minsFromSunset > min(0, o) - 180, e.minsFromSunset < max(0, o) { return e.minsFromSunset }
        if e.mode == "night", turnedOff(e), e.minsFromSunset >= min(0, o), e.minsFromSunset < max(0, o) + 90 { return e.minsFromSunset }
        return nil
    }
    if let o = sunsetOff {
        let v = max(-L.maxOffsetMinutes, min(L.maxOffsetMinutes, (o / 5).rounded() * 5))
        if abs(v - learned.sunsetOffsetMinutes) >= 10 { new.sunsetOffsetMinutes = v; notes.append("night now begins \(Int(abs(v))) min \(v < 0 ? "before" : "after") sunset") }
    }
    let sunriseOff = offsets { e in
        let o = learned.sunriseOffsetMinutes
        if e.mode == "night", turnedOff(e), e.minsFromSunrise > min(0, o) - 180, e.minsFromSunrise < max(0, o) { return e.minsFromSunrise }
        if e.mode == "day", turnedOn(e), e.minsFromSunrise >= min(0, o), e.minsFromSunrise < max(0, o) + 90 { return e.minsFromSunrise }
        return nil
    }
    if let o = sunriseOff {
        let v = max(-L.maxOffsetMinutes, min(L.maxOffsetMinutes, (o / 5).rounded() * 5))
        if abs(v - learned.sunriseOffsetMinutes) >= 10 { new.sunriseOffsetMinutes = v; notes.append("night ends \(Int(abs(v))) min \(v < 0 ? "before" : "after") sunrise") }
    }
    guard !notes.isEmpty else { return learned }
    let stamp = DateFormatter(); stamp.dateStyle = .medium; stamp.timeStyle = .none
    for n in notes { new.history.append("\(stamp.string(from: now)): \(n)"); log("learned: \(n)") }
    if new.history.count > 40 { new.history.removeFirst(new.history.count - 40) }
    if state.lastNotified.map({ now.timeIntervalSince($0) > 86400 }) ?? true {
        notify("Adjusted: " + notes.joined(separator: "; ") + ". Undo with 'redlight forget'.")
        state.lastNotified = now
    }
    return new
}
func nightPreset(cfg: Config, learned: Learned) -> Settings {
    var s = cfg.night
    if let v = learned.nightKeyboardBrightness { s.keyboardBrightness = v }
    if let v = learned.nightIdleDimSeconds { s.keyboardIdleDimSeconds = v }
    if let v = learned.nightShadeLevel { s.shadeLevel = v }
    if let v = learned.nightWarmth { s.warmth = v }
    if s.warmth == nil { s.warmth = 0.8 }
    s.filterEnabled = nil; s.intensity = nil; s.filterType = nil; s.hue = nil   // warmth drives the filter
    s.keyboardAutoBrightness = false
    if s.shadeEnabled != true { s.shadeEnabled = nil; s.shadeLevel = nil }
    return s
}
func dayLook(cfg: Config, state: State?) -> Settings {
    var restore = cfg.dayDefaults
    restore.warmth = restore.warmth ?? 0
    restore.shadeEnabled = restore.shadeEnabled ?? false
    restore.filterEnabled = nil; restore.intensity = nil; restore.filterType = nil; restore.hue = nil
    // The snapshot brings back your daytime keyboard — not red shift or shade. It is taken at sunset, so it holds
    // whatever was turned on in the evening (the early start learning watches for, a "Wind down" or "Movie" preset),
    // and restoring that left the whole next day red or dimmed, sunset after sunset.
    if let snap = state?.daySnapshot {
        restore.keyboardBrightness = snap.keyboardBrightness ?? restore.keyboardBrightness
        restore.keyboardIdleDimSeconds = snap.keyboardIdleDimSeconds ?? restore.keyboardIdleDimSeconds
        restore.keyboardAutoBrightness = snap.keyboardAutoBrightness ?? restore.keyboardAutoBrightness
    }
    return restore
}

// MARK: - Transitions
/// Begin (or instantly complete) a transition. `fade` = 0 applies the target at once.
func startTransition(to mode: String, cfg: Config, learned: Learned, state: State?, now: Date, fade: Double, since: Date? = nil) -> State {
    var st = state ?? blank()
    let target: Settings
    if mode == "night" {
        switch st.mode {
        // mid-sunrise (woken at night): where it was going, not a half-faded frame. One a preset took first wins.
        case "day": st.daySnapshot = st.daySnapshot ?? st.ramp?.to ?? readCurrent()
        case "night": break
        default: st.daySnapshot = nil
        }
        target = nightPreset(cfg: cfg, learned: learned)
    } else {
        target = dayLook(cfg: cfg, state: st)
    }
    var from = readCurrent()
    // Under auto-brightness readCurrent has no level, and a fade from nothing snapped the keyboard to night at once.
    // The hardware does report what auto chose (unless idle-dimmed, when it says 0), so ease from that.
    if from.keyboardBrightness == nil, let id = kbIDs().first,
       !kbGetBool("isBacklightDimmedOnKeyboard:", id), !kbGetBool("isBacklightSuppressedOnKeyboard:", id) {
        from.keyboardBrightness = Double(kbGetFloat("brightnessForKeyboard:", id))
    }
    st.mode = mode
    st.ramp = nil
    roomNightness = nightness(st, now: now)
    // If we woke up mid-transition, pick the fade up where the clock says it should be.
    let began = since ?? now
    let elapsed = now.timeIntervalSince(began)
    if fade > 0 && elapsed < fade * 60 {
        let ramp = Ramp(start: began, seconds: fade * 60, from: from, to: target, label: mode.uppercased())
        st.ramp = ramp; roomNightness = nightness(st, now: now)
        let t = elapsed / ramp.seconds
        apply(blend(from, target, t), label: "\(ramp.label) \(Int(t * 100))%")
    } else {
        apply(target, label: mode.uppercased())
    }
    if mode == "day" { st.daySnapshot = nil }
    st.lastSeen = readCurrent()
    return st
}
/// Fixes the hand-changed fields of a fade at their current values; the rest carry on easing.
func pin(_ r: inout Ramp, _ fields: Set<String>, at cur: Settings) {
    if fields.contains("warmth") { r.from.warmth = cur.warmth; r.to.warmth = cur.warmth }
    if fields.contains("keyboardBrightness") {
        r.from.keyboardBrightness = cur.keyboardBrightness; r.to.keyboardBrightness = cur.keyboardBrightness
        r.to.keyboardAutoBrightness = cur.keyboardAutoBrightness
    }
    if fields.contains("keyboardIdleDimSeconds") { r.to.keyboardIdleDimSeconds = cur.keyboardIdleDimSeconds }
    if fields.contains("shadeEnabled") || fields.contains("shadeLevel") {
        r.from.shadeEnabled = cur.shadeEnabled; r.from.shadeLevel = cur.shadeLevel
        r.to.shadeEnabled = cur.shadeEnabled; r.to.shadeLevel = cur.shadeLevel
    }
}
func stepRamp(_ st: inout State, now: Date) {
    guard let r = st.ramp else { return }
    let t = now.timeIntervalSince(r.start) / r.seconds
    roomNightness = nightness(st, now: now)
    if t >= 1 { apply(r.to, label: "\(r.label) 100%"); st.ramp = nil }
    else { apply(blend(r.from, r.to, t), label: "\(r.label) \(Int(t * 100))%", quiet: true) }
    st.lastSeen = readCurrent()
}
func runningApp() -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-x", appProcessName]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    do { try p.run() } catch { return false }
    p.waitUntilExit(); return p.terminationStatus == 0
}
extension Double { func rounded(toPlaces p: Int) -> Double { let m = pow(10.0, Double(p)); return (self * m).rounded() / m } }

// MARK: - Off, and true colour
/// The normal display: the day look with no red shift and no shade, whatever the snapshot remembered.
func offLook(cfg: Config, state: State?) -> Settings {
    var s = dayLook(cfg: cfg, state: state)
    s.warmth = 0; s.shadeEnabled = false
    return s
}
/// Is anything Red Light draws still on screen? (Our tint is Color Tint, type 16; other filters are the user's.)
func anythingRed() -> Bool {
    let sh = loadShade()
    let ourTint = maGetEnabled(colorCategory) && maGetType(colorCategory) == 16 && maGetInten() > 0.001
    return ourTint || (sh.warmth ?? 0) > 0.001 || sh.enabled
}
func turnOff(_ st: inout State, cfg: Config, reason: String) {
    st.disabled = true; st.pausedUntil = nil; st.ramp = nil; st.heldFor = nil; st.customTintHeld = nil; st.forcedAt = nil
    apply(offLook(cfg: cfg, state: st), label: "OFF (\(reason))")
    st.mode = "day"; st.daySnapshot = nil
    st.lastSeen = readCurrent()
}
/// Suspends only the tint leg; the app sees `heldFor` and draws neither gamma nor shade meanwhile.
func suppressTint() { if maGetType(colorCategory) == 16 { maSetEnabled(colorCategory, false) } }
/// Brings back the tint underneath — the curve's or a custom `set tint` — from the filter prefs, which apply keeps
/// current under a hold. Recomputing it from warmth replaced a custom tint, and forced type 16 over a filter of your own.
/// After a hold: Red Shift's tint leg as the current warmth calls for it (a fade may have run underneath), or a
/// hand-set tint that was on before. Never "intensity > 0": macOS keeps the last intensity even when the tint is
/// off, so that test switched a 0.25 tint back on at Red Shift 38 %, where the curve has no tint at all.
func restoreTint(custom: Bool) {
    guard maGetType(colorCategory) == 16 else { return }
    let c = warmthCurve(loadShade().warmth ?? 0)
    if custom { maSetEnabled(colorCategory, true) }
    else { maSetHue(1.0); maSetInten(c.tint); maSetEnabled(colorCategory, c.tint > 0.001) }
}
/// The switch is recorded as on (`false`), never left nil: the app reads a missing `disabled` as a build from before
/// the switch, which said "off" by unloading the agent, and would turn Red Light off whenever it found the agent unloaded.
func blank() -> State { var s = State(mode: "unset", daySnapshot: nil, lastSeen: nil, lastNotified: nil, ramp: nil, pausedUntil: nil); s.disabled = false; return s }
func refuseIfOff() {
    if loadState()?.disabled == true { print("Red Light is off. Turn it on first: redlight on"); exit(1) }
}
/// Direct edits (set, preset, reapply) while an app holds true colour change the look underneath; the tint still waits.
func honourHold() { holdTint = loadState()?.heldFor != nil }

// MARK: - Room light
// The ambient light sensor: on Apple Silicon an IOHIDEventSystem service (usage page 0xff00, usage 4). Private API.
@_silgen_name("IOHIDEventSystemClientCreate") func hidClientCreate(_ a: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching") func hidSetMatching(_ c: AnyObject, _ m: CFDictionary)
@_silgen_name("IOHIDEventSystemClientCopyServices") func hidCopyServices(_ c: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyEvent") func hidCopyEvent(_ s: AnyObject, _ type: Int64, _ opts: Int32, _ ts: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") func hidFloat(_ e: AnyObject, _ field: Int32) -> Double
/// Lux, or nil with no sensor — or with the lid closed, when it sees only the inside of the lid.
func roomLux() -> Double? {
    if let v = ProcessInfo.processInfo.environment["REDLIGHT_LUX"] { return Double(v) }     // testing: a room of your choosing
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    let closed = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    IOObjectRelease(root)
    if closed == true { return nil }
    guard let c = hidClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
    hidSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 4] as CFDictionary)
    guard let s = (hidCopyServices(c)?.takeRetainedValue() as? [AnyObject])?.first,
          let e = hidCopyEvent(s, 12, 0, 0)?.takeRetainedValue() else { return nil }
    return hidFloat(e, 12 << 16)
}
/// 0 in a lit room, 1 in a dark one, on a log scale: from 150 lux (a lit living room) down to 2 (a lamp off, the
/// screen the only light), eased at both ends.
func darkness(lux: Double) -> Double {
    let t = max(0, min(1, (log10(150) - log10(max(0, lux) + 1)) / (log10(150) - log10(3))))
    return t * t * (3 - 2 * t)
}
var roomDarkness = 0.0, roomStrength = 0.0, roomNightness = 0.0
func setRoomContext(cfg: Config, state: State?, now: Date) {
    let r = cfg.roomLight ?? RoomLight()
    roomStrength = r.enabled ? r.strength : 0
    roomDarkness = roomStrength > 0 ? (state?.room?.darkness ?? 0) : 0
    roomNightness = nightness(state, now: now)
}
/// How far into night the schedule is: 0 by day, 1 at night, and the fade's progress in between, so a dark room's
/// lift rides the sunset fade in and the sunrise fade out rather than jumping at either.
func nightness(_ st: State?, now: Date) -> Double {
    guard let st = st else { return 0 }
    let t = st.ramp.map { max(0, min(1, now.timeIntervalSince($0.start) / $0.seconds)) }
    switch st.mode { case "night": return t ?? 1; case "day": return t.map { 1 - $0 } ?? 0; default: return 0 }
}
/// The warmth drawn for a chosen one: lifted toward 100 % as the room darkens, at night. Nothing at 0 — Red Shift
/// turned all the way down stays off in any room — and full from 10 % up.
func lifted(_ w: Double) -> Double {
    let w = max(0, min(1, w))
    return w + (1 - w) * roomDarkness * roomStrength * roomNightness * min(1, w / 0.1)
}
/// The chosen warmth that is drawn as `x` in this room: what the slider sets, so it moves the curve, not the room.
func unlifted(_ x: Double) -> Double {
    var lo = 0.0, hi = 1.0
    for _ in 0..<40 { let mid = (lo + hi) / 2; if lifted(mid) < x { lo = mid } else { hi = mid } }
    return hi
}
/// Eases the room's darkness toward what the sensor reads, by at most 1/45 a second: lights going out bring the red in
/// over about 45 s, and a hand over the sensor is a flicker of a percent. True if the drawn warmth is now out of date.
func senseRoom(_ st: inout State, now: Date) -> Bool {
    if roomStrength <= 0 { st.room = nil; roomDarkness = 0 }
    else {
        let lux = roomLux(), target = lux.map { darkness(lux: $0) } ?? 0      // no reading: no lift
        let was = st.room?.darkness ?? 0
        let step = st.room.map { max(0, now.timeIntervalSince($0.at)) / 45 } ?? 1 / 45
        let d = target > was ? min(target, was + step) : max(target, was - step)
        st.room = Room(lux: lux ?? -1, target: target, darkness: d, at: now)
        roomDarkness = d
        if d == target && abs(was - target) > 0.001 {
            let sh = loadShade()
            log(String(format: "room at %.0f lux: red shift shown at %.0f%%", lux ?? 0, lifted(sh.base ?? sh.warmth ?? 0) * 100))
        }
    }
    let sh = loadShade()
    return abs(lifted(sh.base ?? sh.warmth ?? 0) - (sh.warmth ?? 0)) > 0.003
}
/// Redraws the chosen warmth for the room. The tint leg can switch across 60 %, which is not a change of yours.
func reliftWarmth(_ st: inout State) {
    let sh = loadShade(); var s = Settings(); s.warmth = sh.base ?? sh.warmth ?? 0
    apply(s, label: "ROOM", quiet: true)
    st.lastSeen?.filterEnabled = maGetEnabled(colorCategory)
}

// MARK: - Main
let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "check"
// One engine at a time. launchd's minute check, the app's wake check, a slider's `set` and the switch all
// read-modify-write state.json, shade.json and config.json; two overlapping runs would snapshot each other's
// half-applied look as "your day settings" and log it as a manual change, and a check that loaded state just before
// `off` would save "on" back over it and step its fade onto a screen that was just cleared.
if !["status", "suntimes", "learned", "curve"].contains(cmd) {
    let fd = open(appDir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
    var waited = 0                                          // released when the process exits; bounded (10 s) so a
    while fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 && waited < 500 { usleep(20_000); waited += 1 }   // hung run can't wedge the rest
}
// A config.json that won't parse stops the schedule (no location), but never the switch: off, true colour, and an
// off check need nothing from it but the day defaults, and the plain normal look will do for those. Sliders (`set`),
// the shade keys, `forget` and `curve` read nothing from it at all, and refusing them left the pane's controls dead.
// (Never `location` or `preset`: they save the config back, and would write this placeholder over the real one.)
let needsNoSun = ["off", "hold", "release", "set", "shade", "forget", "curve"].contains(cmd) || (cmd == "check" && loadState()?.disabled == true)
guard let cfg = loadConfig() ?? (needsNoSun ? Config(latitude: 0, longitude: 0, night: Settings(), dayDefaults: Settings()) : nil) else { exit(1) }
var learned = loadLearned()
let now = Date()
let fmt = DateFormatter(); fmt.dateStyle = .none; fmt.timeStyle = .short
let fadeMinutes = cfg.fadeMinutes ?? 30
setRoomContext(cfg: cfg, state: loadState(), now: now)

switch cmd {
case "check":
    var st = loadState() ?? blank()
    if st.disabled == true {
        // Off means off: if anything — a stale filter pref, a half-finished fade, an old build — left red on
        // screen, take it away. Never schedules, never learns.
        if anythingRed() { apply(offLook(cfg: cfg, state: st), label: "OFF (held)"); st.lastSeen = readCurrent() }
        saveState(st); exit(0)
    }
    st.disabled = false                 // on, and now recorded as on (see blank())
    if let until = st.pausedUntil {
        if now < until { saveState(st); exit(0) }       // paused: leave everything alone, learn nothing
        st.pausedUntil = nil; log("pause ended")
        st.lastSeen = nil               // what was changed while paused is not a lesson, nor a mid-fade adjustment
    }
    let held = st.heldFor != nil
    holdTint = held                     // transitions and fades carry on underneath a hold; only the tint waits
    let (observed, changes) = observe(cfg: cfg, learned: learned, state: st, now: now)
    st = observed
    pruneEvents(olderThan: now.addingTimeInterval(-Double((cfg.learning ?? Learning()).lookbackDays + 7) * 86400))
    let newLearned = learn(cfg: cfg, learned: learned, state: &st, now: now)
    if (try? enc.encode(newLearned)) != (try? enc.encode(learned)) { saveLearned(newLearned); learned = newLearned }
    let roomMoved = senseRoom(&st, now: now)      // before any fade step, which then draws for the room as it is
    var redrawn = false
    var want = isNight(cfg: cfg, learned: learned, now: now) ? "night" : "day"
    if let f = st.forcedAt {
        // "Turn On Now" by day (or `day` by night) holds until the next sunset or sunrise, not until the next minute.
        if (lastTransition(cfg: cfg, learned: learned, now: now) ?? .distantPast) <= f && now.timeIntervalSince(f) < 86400 { want = st.mode }
        else { st.forcedAt = nil }
    }
    if st.mode != want {
        log("transition \(st.mode) -> \(want)")
        st = startTransition(to: want, cfg: cfg, learned: learned, state: st, now: now, fade: fadeMinutes, since: lastTransition(cfg: cfg, learned: learned, now: now))
        redrawn = true
    } else if var r = st.ramp {
        if changes.contains("filterEnabled") { log("you switched the tint mid-transition; leaving it as you set it"); st.ramp = nil }
        else {
            if !changes.isEmpty, let cur = st.lastSeen {
                // Only what you touched stays where you put it. Cancelling the whole fade for a keyboard nudge left
                // the screen stuck part-way to red for the rest of the night.
                log("you adjusted \(changes.sorted().joined(separator: ", ")) mid-transition; leaving that as you set it")
                pin(&r, changes, at: cur); st.ramp = r
            }
            stepRamp(&st, now: now); redrawn = true
        }
    }
    if roomMoved && !redrawn { reliftWarmth(&st) }
    saveState(st)
case "room":
    // The app's call while the room's light is changing; the minute check does the same.
    var st = loadState() ?? blank()
    if st.disabled == true || (st.pausedUntil.map { now < $0 } ?? false) { exit(0) }
    holdTint = st.heldFor != nil
    if senseRoom(&st, now: now) { reliftWarmth(&st) }
    saveState(st)
case "night", "day":
    var st = loadState()
    st?.pausedUntil = nil
    if cmd == "night" { st?.disabled = false }      // "Turn On Now" is, plainly, on
    st?.heldFor = nil; st?.customTintHeld = nil
    var next = startTransition(to: cmd, cfg: cfg, learned: learned, state: st, now: now, fade: 0)
    next.forcedAt = now                         // otherwise the next check puts the schedule straight back
    saveState(next)
case "on":
    var st = loadState() ?? blank()
    st.disabled = false; st.pausedUntil = nil; st.heldFor = nil; st.customTintHeld = nil; st.forcedAt = nil
    let want = isNight(cfg: cfg, learned: learned, now: now) ? "night" : "day"
    // Always apply, even if the mode already matches: "on" must leave the screen in the state the switch shows.
    st = startTransition(to: want, cfg: cfg, learned: learned, state: st, now: now, fade: 0)
    saveState(st); log("turned on (\(want))"); print("on (\(want))")
case "off":
    var st = loadState() ?? blank()
    turnOff(&st, cfg: cfg, reason: "switch")
    saveState(st); log("turned off"); print("off")
case "hold":
    // redlight hold <app name>: true colour while a colour-critical app is in front
    var st = loadState() ?? blank()
    // Not while paused either: nothing is red to hold, and a hold left over when the pause ran out kept the tint off.
    guard st.disabled != true, st.pausedUntil.map({ now >= $0 }) ?? true, CommandLine.arguments.count > 2 else { exit(0) }
    st.heldFor = CommandLine.arguments[2]
    // Only the tint flag is ours to re-read: a whole fresh lastSeen swallowed a slider or shade change made in the
    // minute before, so the fade's next step ran straight over it (the app writes the shade before its release lands).
    if st.customTintHeld == nil {   // first hold of a run; a hold passed from one app to the next keeps it
        st.customTintHeld = maGetEnabled(colorCategory) && maGetType(colorCategory) == 16 && warmthCurve(loadShade().warmth ?? 0).tint <= 0.001
    }
    suppressTint(); st.lastSeen?.filterEnabled = maGetEnabled(colorCategory)
    saveState(st); log("true colour for \(st.heldFor!)")
case "release":
    var st = loadState() ?? blank()
    guard let who = st.heldFor else { exit(0) }
    st.heldFor = nil
    if st.disabled != true { restoreTint(custom: st.customTintHeld == true) }
    st.customTintHeld = nil
    st.lastSeen?.filterEnabled = maGetEnabled(colorCategory)   // as in hold: the tint flag only
    saveState(st); log("red light back after \(who)")
case "pause":
    // redlight pause <minutes> | sunrise
    refuseIfOff()
    var st = loadState() ?? blank()
    st.heldFor = nil; st.customTintHeld = nil; st.forcedAt = nil
    let arg = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "60"
    let until: Date
    if arg == "sunrise" { until = nextSunrise(cfg: cfg, learned: learned, now: now) ?? now.addingTimeInterval(8 * 3600) }
    else if let m = Double(arg), m > 0 { until = now.addingTimeInterval(m * 60) }
    else { print("usage: redlight pause <minutes>|sunrise"); exit(2) }
    if st.mode == "night" { st = startTransition(to: "day", cfg: cfg, learned: learned, state: st, now: now, fade: 0) }
    else if st.ramp != nil { stepRamp(&st, now: .distantFuture) }   // mid-sunrise: finish it, don't freeze half red
    else if anythingRed() {
        // By day too: a preset applied before sunset stayed red through the pause — and with a hold just cleared
        // above, the app drew back the red it had been hiding. Red and shade only; the keyboard is yours by day.
        let d = dayLook(cfg: cfg, state: st); var s = Settings(); s.warmth = d.warmth; s.shadeEnabled = d.shadeEnabled
        apply(s, label: "DAY (paused)"); st.lastSeen = readCurrent()
    }
    st.pausedUntil = until
    saveState(st); log("paused until \(fmt.string(from: until))"); print("paused until \(fmt.string(from: until))")
case "resume":
    var st = loadState() ?? blank()
    let wasHeld = st.heldFor != nil, customHeld = st.customTintHeld == true
    st.pausedUntil = nil; st.disabled = false; st.heldFor = nil; st.customTintHeld = nil; st.forcedAt = nil
    let want = isNight(cfg: cfg, learned: learned, now: now) ? "night" : "day"
    if st.mode != want { st = startTransition(to: want, cfg: cfg, learned: learned, state: st, now: now, fade: 0) }
    else {
        if wasHeld { restoreTint(custom: customHeld) }      // the hold is ended here too: nothing else would bring the tint back
        st.lastSeen = readCurrent()                         // as when a pause runs out: changes made while paused aren't learned
    }
    saveState(st); log("resumed"); print("resumed (\(want))")
case "location":
    // redlight location <lat> <lon> [auto|manual]
    guard CommandLine.arguments.count > 3, let la = Double(CommandLine.arguments[2]), let lo = Double(CommandLine.arguments[3]),
          abs(la) <= 90, abs(lo) <= 180 else { print("usage: redlight location <lat> <lon> [auto|manual]"); exit(2) }
    var c = cfg
    let source = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "manual"
    if source == "auto" && c.locationSource == "manual" { print("location is set manually; not overriding"); exit(0) }
    let moved = abs(c.latitude - la) > 0.05 || abs(c.longitude - lo) > 0.05
    c.latitude = la; c.longitude = lo; c.locationSource = source
    saveConfig(c)
    if moved { log(String(format: "location updated to %.3f, %.3f (%@)", la, lo, source)) }
    print(String(format: "location %.3f, %.3f (%@)", la, lo, source))
case "set":
    guard CommandLine.arguments.count > 3 else { print("usage: redlight set warmth|keyboard|idle|shade|tint <value|off>"); exit(2) }
    let field = CommandLine.arguments[2], raw = CommandLine.arguments[3]
    let off = (raw == "off")
    let dim = field == "keyboard" ? ["dim1", "dim2", "dim3", "dim4"].firstIndex(of: raw.lowercased()) : nil
    guard off || dim != nil || Double(raw) != nil else { print("'\(raw)' is not a number or 'off'"); exit(2) }
    let num = dim.map { extraDimLevels[$0] * 100 } ?? Double(raw) ?? 0
    refuseIfOff(); honourHold()
    var s = Settings()
    switch field {
    case "warmth": s.warmth = off ? 0 : unlifted(max(0, min(1, num / 100)))     // what you see is what you set
    case "keyboard": s.keyboardAutoBrightness = false; s.keyboardBrightness = off ? 0 : max(0, min(1, num / 100))
    case "idle":
        guard !off, num >= 1 else { print("idle needs a number of seconds (1 or more)"); exit(2) }
        s.keyboardIdleDimSeconds = num
    case "shade": if off { s.shadeEnabled = false } else { s.shadeEnabled = num > 0; s.shadeLevel = max(0, min(0.9, num / 100)) }
    case "tint":   // advanced: drive the color filter directly, outside the warmth curve
        // off zeroes the intensity too, so a release doesn't read it as a tint to bring back
        if off { s.filterEnabled = false; s.intensity = 0 } else { s.filterEnabled = true; s.filterType = 16; s.hue = 1.0; s.intensity = max(0, min(1, num / 100)) }
    default: print("unknown field '\(field)' — use warmth, keyboard, idle, shade or tint"); exit(2)
    }
    apply(s, label: "SET \(field)")
case "preset":
    var c = cfg
    var presets = c.presets ?? []
    let sub = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "list"
    let name = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
    func find() -> Preset? { presets.first { $0.name.lowercased() == name.lowercased() } }
    switch sub {
    case "list":
        for p in presets { print("\(p.name)\(c.nightPresetName?.lowercased() == p.name.lowercased() ? "  (at sunset)" : ""): \(describe(p.settings))") }
    case "apply":
        guard let p = find() else { print("no preset named \(name)"); exit(1) }
        refuseIfOff(); honourHold()
        // A preset by day is an evening look put on early: keep the day keyboard from before it for sunrise to bring
        // back, not the preset's 0.3 % the sunset snapshot would find. (The snapshot is always empty in day mode.)
        if var st = loadState(), st.mode == "day", st.daySnapshot == nil { st.daySnapshot = st.ramp?.to ?? readCurrent(); saveState(st) }
        var s = p.settings
        if s.warmth == nil { s.warmth = 0 }
        if s.keyboardBrightness != nil { s.keyboardAutoBrightness = false }
        apply(s, label: "PRESET \(p.name)")
    case "save":
        guard !name.isEmpty else { print("usage: redlight preset save <name> [sf-symbol]"); exit(2) }
        var cur = readCurrent()
        cur.filterType = nil; cur.hue = nil; cur.keyboardAutoBrightness = nil; cur.filterEnabled = nil; cur.intensity = nil
        if cur.keyboardBrightness == nil { cur.keyboardBrightness = cfg.night.keyboardBrightness }
        let icon = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "star.fill"
        // Replacing keeps the preset where it was in the list (the pane and the slider marks follow that order).
        let at = presets.firstIndex { $0.name.lowercased() == name.lowercased() } ?? presets.count
        presets.removeAll { $0.name.lowercased() == name.lowercased() }
        presets.insert(Preset(name: name, icon: icon, settings: cur), at: min(at, presets.count))
        c.presets = presets
        if c.nightPresetName?.lowercased() == name.lowercased() { c.nightPresetName = nil }
        saveConfig(c); print("saved preset \(name): \(describe(cur))")
    case "night":
        guard let p = find() else { print("no preset named \(name)"); exit(1) }
        c.night.warmth = p.settings.warmth ?? 0
        c.night.keyboardBrightness = p.settings.keyboardBrightness ?? c.night.keyboardBrightness
        c.night.keyboardIdleDimSeconds = p.settings.keyboardIdleDimSeconds ?? c.night.keyboardIdleDimSeconds
        c.night.shadeEnabled = p.settings.shadeEnabled ?? false
        c.night.shadeLevel = p.settings.shadeLevel ?? c.night.shadeLevel
        c.night.filterEnabled = nil; c.night.intensity = nil; c.night.filterType = nil; c.night.hue = nil
        c.nightPresetName = p.name
        saveConfig(c)
        var l = learned; l.nightKeyboardBrightness = nil; l.nightIdleDimSeconds = nil; l.nightShadeLevel = nil; l.nightWarmth = nil; l.levelsSince = now; saveLearned(l)
        log("sunset preset is now '\(p.name)'")
        if var st = loadState(), st.mode == "night", st.pausedUntil == nil, st.disabled != true { st.ramp = nil; holdTint = st.heldFor != nil; apply(nightPreset(cfg: c, learned: l), label: "NIGHT (preset changed)"); st.lastSeen = readCurrent(); saveState(st) }
    case "delete":
        guard find() != nil else { print("no preset named \(name)"); exit(1) }
        presets.removeAll { $0.name.lowercased() == name.lowercased() }
        if c.nightPresetName?.lowercased() == name.lowercased() { c.nightPresetName = nil }
        c.presets = presets; saveConfig(c); print("deleted \(name)")
    default: print("usage: redlight preset list|apply|save|night|delete <name>"); exit(2)
    }
case "shade":
    refuseIfOff()
    var sh = loadShade()
    let arg = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "toggle"
    switch arg {
    case "on": sh.enabled = true
    case "off": sh.enabled = false
    case "toggle": sh.enabled.toggle()
    case "up": sh.level = min(0.9, (sh.level + 0.1).rounded(toPlaces: 2)); sh.enabled = true
    case "down": sh.level = max(0, (sh.level - 0.1).rounded(toPlaces: 2)); if sh.level == 0 { sh.enabled = false }
    default:
        if let pct = Double(arg) { sh.level = max(0, min(0.9, pct / 100)); sh.enabled = sh.level > 0 }
        else { print("usage: redlight shade on|off|toggle|up|down|<0-90>"); exit(2) }
    }
    saveShade(sh)
    print("shade \(sh.enabled ? "on" : "off") \(Int((sh.level * 100).rounded()))%")
case "reapply":
    if var st = loadState(), st.mode == "night", st.pausedUntil == nil, st.disabled != true {
        st.ramp = nil; holdTint = st.heldFor != nil
        apply(nightPreset(cfg: cfg, learned: learned), label: "NIGHT (preset edited)")
        st.lastSeen = readCurrent(); saveState(st)
    }
case "suntimes":
    let raw = sunTimes(lat: cfg.latitude, lon: cfg.longitude, date: now)
    let eff = effectiveSun(cfg: cfg, learned: learned, date: now)
    print("sunrise \(raw.rise.map(fmt.string) ?? "-") (switch \(eff.rise.map(fmt.string) ?? "-"))   sunset \(raw.set.map(fmt.string) ?? "-") (switch \(eff.set.map(fmt.string) ?? "-"))   now \(fmt.string(from: now)) -> \(isNight(cfg: cfg, learned: learned, now: now) ? "night" : "day")")
case "status":
    let st = loadState()
    let eff = effectiveSun(cfg: cfg, learned: learned, date: now)
    var head = st?.disabled == true ? "mode: off" : "mode: \(st?.mode ?? "unset")"
    if let h = st?.heldFor { head += "   true colour for \(h)" }
    if let u = st?.pausedUntil, u > now { head += "   paused until \(fmt.string(from: u))" }
    if let r = st?.ramp { head += "   fading \(Int(min(1, now.timeIntervalSince(r.start) / r.seconds) * 100))%" }
    head += "   switches: day at \(eff.rise.map(fmt.string) ?? "-"), night at \(eff.set.map(fmt.string) ?? "-")"
    print(head)
    var cur = readCurrent(); let base = cur.warmth; let sh = loadShade(); cur.warmth = sh.warmth ?? base
    // `warmth` as drawn (the slider shows it); `planned` the chosen warmth beneath a dark room's lift.
    let roomNote = (base.map { abs((sh.warmth ?? $0) - $0) > 0.005 ? String(format: " planned=%.2f", $0) : "" } ?? "")
        + (st?.room.map { $0.lux >= 0 ? String(format: " room=%.0flux", $0.lux) : "" } ?? "")
    print("current: \(describe(cur))\(roomNote)\(runningApp() ? "" : "   [menu bar app not running: shade and warmth are not applied]")")
    print("night preset: \(describe(nightPreset(cfg: cfg, learned: learned)))")
    if let snap = st?.daySnapshot { print("saved day settings: \(describe(snap))") }
    print(String(format: "location: %.3f, %.3f (%@)   fade: %.0f min", cfg.latitude, cfg.longitude, cfg.locationSource ?? "unknown", fadeMinutes))
case "learned":
    print("sunset offset: \(Int(learned.sunsetOffsetMinutes)) min   sunrise offset: \(Int(learned.sunriseOffsetMinutes)) min")
    if let v = learned.nightWarmth { print(String(format: "night red shift: %.0f%%", v * 100)) }
    if let v = learned.nightKeyboardBrightness { print(String(format: "night keyboard brightness: %.3f", v)) }
    if let v = learned.nightIdleDimSeconds { print("night idle-off: \(Int(v))s") }
    if let v = learned.nightShadeLevel { print(String(format: "night screen shade: %.0f%%", v * 100)) }
    let L = cfg.learning ?? Learning()
    print("manual changes observed in last \(L.lookbackDays) days: \(loadEvents(since: now.addingTimeInterval(-Double(L.lookbackDays) * 86400)).count)")
    print(learned.history.isEmpty ? "nothing learned yet" : "history:\n  " + learned.history.joined(separator: "\n  "))
case "forget":
    try? FileManager.default.removeItem(at: learnedURL)
    try? FileManager.default.removeItem(at: eventsURL)
    log("forgot all learned adjustments and observations")
case "curve":
    for w in stride(from: 0.0, through: 1.0, by: 0.1) { let c = warmthCurve(w); print(String(format: "warmth %3.0f%%  blue %.2f  green %.2f  tint %.2f", w * 100, c.blue, c.green, c.tint)) }
default:
    print("usage: redlight on|off|check|night|day|pause|resume|hold|release|location|set|preset|shade|reapply|room|status|suntimes|learned|forget|curve"); exit(2)
}
