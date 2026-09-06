// nightfall — eases the Mac into a warm, low-blue-light look after sunset and back again at sunrise,
// and quietly learns from manual adjustments.
// Usage: nightfall check | night | day | pause <min>|sunrise | resume | set <field> <value> | preset … |
//        shade … | location <lat> <lon> [auto|manual] | reapply | status | suntimes | learned | forget
import Foundation

let appDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nightfall")
let configURL  = appDir.appendingPathComponent("config.json")
let stateURL   = appDir.appendingPathComponent("state.json")
let learnedURL = appDir.appendingPathComponent("learned.json")
let eventsURL  = appDir.appendingPathComponent("events.jsonl")
let logURL     = appDir.appendingPathComponent("nightfall.log")
let shadeURL   = appDir.appendingPathComponent("shade.json")      // what the menu bar app should draw: shade overlay + gamma
let cmdURL     = appDir.appendingPathComponent("commanded.json")
let appProcessName = "Nightfall"

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    print(s)
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}
func notify(_ msg: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    let esc = msg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    p.arguments = ["-e", "display notification \"\(esc)\" with title \"Nightfall\""]
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
struct Shade: Codable { var enabled: Bool = false; var level: Double = 0.3; var warmth: Double? = 0; var gammaBlue: Double? = 1; var gammaGreen: Double? = 1 }
struct Commanded: Codable { var keyboardBrightness: Double? }
func loadCommanded() -> Commanded { (try? Data(contentsOf: cmdURL)).flatMap { try? JSONDecoder().decode(Commanded.self, from: $0) } ?? Commanded() }
func saveCommanded(_ c: Commanded) { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(c).write(to: cmdURL, options: .atomic) }
func loadShade() -> Shade { (try? Data(contentsOf: shadeURL)).flatMap { try? JSONDecoder().decode(Shade.self, from: $0) } ?? Shade() }
func saveShade(_ sh: Shade) { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(sh).write(to: shadeURL, options: .atomic) }
struct Learning: Codable {
    var enabled: Bool = true
    var minNights: Int = 3
    var lookbackDays: Int = 14
    var maxOffsetMinutes: Double = 120
}
struct Preset: Codable { var name: String; var icon: String; var settings: Settings }
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
}
struct Learned: Codable {
    var sunsetOffsetMinutes: Double = 0
    var sunriseOffsetMinutes: Double = 0
    var nightKeyboardBrightness: Double?
    var nightIdleDimSeconds: Double?
    var nightShadeLevel: Double?
    var nightWarmth: Double?
    var history: [String] = []
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
func readCurrent() -> Settings {
    var s = Settings(filterEnabled: maGetEnabled(colorCategory), filterType: maGetType(colorCategory), hue: maGetHue(), intensity: maGetInten())
    if let id = kbIDs().first {
        let dimmed = kbGetBool("isBacklightDimmedOnKeyboard:", id) || kbGetBool("isBacklightSuppressedOnKeyboard:", id)
        s.keyboardAutoBrightness = kbGetBool("isAutoBrightnessEnabledForKeyboard:", id)
        s.keyboardIdleDimSeconds = kbGetDouble("idleDimTimeForKeyboard:", id)
        if !dimmed && s.keyboardAutoBrightness == false {
            let v = Double(kbGetFloat("brightnessForKeyboard:", id))
            s.keyboardBrightness = v
            let known = loadCommanded().keyboardBrightness
            if known == nil || abs(known! - v) > 0.0005 { saveCommanded(Commanded(keyboardBrightness: v)) }
        } else if s.keyboardAutoBrightness == false {
            s.keyboardBrightness = loadCommanded().keyboardBrightness
        }
    }
    let sh = loadShade(); s.shadeEnabled = sh.enabled; s.shadeLevel = sh.level; s.warmth = sh.warmth ?? 0
    return s
}
func apply(_ s: Settings, label: String, quiet: Bool = false) {
    if let w = s.warmth {
        // Warmth owns the color filter. The tint is one leg of the curve; the gamma legs go to the app.
        let c = warmthCurve(w)
        maSetType(colorCategory, 16); maSetHue(1.0)
        maSetInten(c.tint); maSetEnabled(colorCategory, c.tint > 0.001)
        var sh = loadShade(); sh.warmth = w; sh.gammaBlue = c.blue; sh.gammaGreen = c.green
        if let e = s.shadeEnabled { sh.enabled = e }
        if let l = s.shadeLevel { sh.level = l }
        saveShade(sh)
    } else {
        if let t = s.filterType { maSetType(colorCategory, t) }
        if let h = s.hue { maSetHue(h) }
        if let i = s.intensity { maSetInten(i) }
        if let e = s.filterEnabled { maSetEnabled(colorCategory, e) }
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
        if let b = s.keyboardBrightness { kbSetBrightness(Float(b), id); saveCommanded(Commanded(keyboardBrightness: b)) }
    }
    if !quiet { log("applied \(label): \(describe(s))") }
}
func describe(_ s: Settings) -> String {
    var p: [String] = []
    if let v = s.warmth { p.append(String(format: "warmth=%.2f", v)) }
    if let v = s.filterEnabled { p.append("filter=\(v ? "on" : "off")") }
    if let v = s.intensity { p.append(String(format: "tint=%.2f", v)) }
    if let v = s.keyboardBrightness { p.append(String(format: "kbBrightness=%.3f", v)) }
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
        if a > 0.0005 && b > 0.0005 { s.keyboardBrightness = exp(lerp(log(a), log(b), t)) } else { s.keyboardBrightness = lerp(a, b, t) }
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
func isNight(cfg: Config, learned: Learned, now: Date) -> Bool {
    let (rise, set) = effectiveSun(cfg: cfg, learned: learned, date: now)
    guard let r = rise, let s = set else {
        let m = Calendar.current.component(.month, from: now)
        return cfg.latitude > 0 ? (m >= 10 || m <= 3) : (m >= 4 && m <= 9)
    }
    return now < r || now >= s
}
/// The transition that most recently began (for computing fade progress after a sleep).
func lastTransition(cfg: Config, learned: Learned, now: Date) -> Date? {
    let days = [-86400.0, 0].map { effectiveSun(cfg: cfg, learned: learned, date: now.addingTimeInterval($0)) }
    return days.flatMap { [$0.rise, $0.set] }.compactMap { $0 }.filter { $0 <= now }.max()
}
func nextSunrise(cfg: Config, learned: Learned, now: Date) -> Date? {
    [0.0, 86400].compactMap { effectiveSun(cfg: cfg, learned: learned, date: now.addingTimeInterval($0)).rise }.first { $0 > now }
}
func sunTimes(cfg: Config, learned: Learned, near now: Date) -> (rise: Date, set: Date) {
    let days = [-86400.0, 0, 86400].map { sunTimes(lat: cfg.latitude, lon: cfg.longitude, date: now.addingTimeInterval($0)) }
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
func loadConfig() -> Config {
    guard let d = try? Data(contentsOf: configURL), let c = try? dec.decode(Config.self, from: d) else { log("ERROR: cannot read \(configURL.path)"); exit(1) }
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
/// Returns the updated state and how many manual changes were noticed since the last check.
func observe(cfg: Config, learned: Learned, state: State, now: Date) -> (State, Int) {
    var st = state
    let cur = readCurrent()
    st.lastSeen = cur
    guard cfg.learning?.enabled ?? true, let prev = state.lastSeen else { return (st, 0) }
    let (rise, set) = sunTimes(cfg: cfg, learned: learned, near: now)
    let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
    let todayRise = sunTimes(lat: cfg.latitude, lon: cfg.longitude, date: now).rise ?? now
    let nightID = dayFmt.string(from: now < todayRise ? now.addingTimeInterval(-86400) : now)
    var count = 0
    func changed(_ field: String, _ a: Double?, _ b: Double?, tol: Double) {
        guard let a = a, let b = b, abs(a - b) > tol else { return }
        let ev = Event(t: now, mode: state.mode, nightID: nightID, minsFromSunset: now.timeIntervalSince(set) / 60,
                       minsFromSunrise: now.timeIntervalSince(rise) / 60, field: field, from: a, to: b)
        appendEvent(ev); count += 1
        log("noticed manual change: \(field) \(String(format: "%.3f", a)) -> \(String(format: "%.3f", b)) (\(state.mode), \(Int(ev.minsFromSunset)) min after sunset)")
    }
    changed("warmth", prev.warmth, cur.warmth, tol: 0.02)
    changed("filterEnabled", prev.filterEnabled.map { $0 ? 1 : 0 }, cur.filterEnabled.map { $0 ? 1 : 0 }, tol: 0.5)
    changed("keyboardBrightness", prev.keyboardBrightness, cur.keyboardBrightness, tol: 0.005)
    changed("keyboardIdleDimSeconds", prev.keyboardIdleDimSeconds, cur.keyboardIdleDimSeconds, tol: 0.5)
    changed("shadeEnabled", prev.shadeEnabled.map { $0 ? 1 : 0 }, cur.shadeEnabled.map { $0 ? 1 : 0 }, tol: 0.5)
    changed("shadeLevel", prev.shadeLevel, cur.shadeLevel, tol: 0.02)
    return (st, count)
}

// MARK: - Learning
func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.count % 2 == 1 ? s[s.count/2] : (s[s.count/2 - 1] + s[s.count/2]) / 2 }
func learn(cfg: Config, learned: Learned, state: inout State, now: Date) -> Learned {
    let L = cfg.learning ?? Learning()
    guard L.enabled else { return learned }
    var new = learned
    let events = loadEvents(since: now.addingTimeInterval(-Double(L.lookbackDays) * 86400))
    guard !events.isEmpty else { return learned }
    var notes: [String] = []
    func settledNightValue(_ field: String, tol: Double) -> Double? {
        var lastPerNight: [String: Double] = [:]
        for e in events where e.field == field && e.mode == "night" { lastPerNight[e.nightID] = e.to }
        let vals = Array(lastPerNight.values)
        guard vals.count >= L.minNights else { return nil }
        let m = median(vals)
        return vals.filter { abs($0 - m) <= tol }.count >= L.minNights ? m : nil
    }
    if let v = settledNightValue("warmth", tol: 0.1) {
        let cur = learned.nightWarmth ?? cfg.night.warmth ?? 0
        if abs(v - cur) > 0.05 { new.nightWarmth = v; notes.append(String(format: "night warmth %.0f%%", v * 100)) }
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
        guard vals.count >= L.minNights else { return nil }
        let m = median(vals)
        return vals.filter { abs($0 - m) <= 30 }.count >= L.minNights ? m : nil
    }
    func turnedOn(_ e: Event) -> Bool { e.from <= 0.02 && e.to > 0.02 }
    func turnedOff(_ e: Event) -> Bool { e.from > 0.02 && e.to <= 0.02 }
    let sunsetOff = offsets { e in
        if e.mode == "day", turnedOn(e), e.minsFromSunset > -180, e.minsFromSunset < 0 { return e.minsFromSunset }
        if e.mode == "night", turnedOff(e), e.minsFromSunset >= 0, e.minsFromSunset < 90 { return e.minsFromSunset }
        return nil
    }
    if let o = sunsetOff {
        let v = max(-L.maxOffsetMinutes, min(L.maxOffsetMinutes, (o / 5).rounded() * 5))
        if abs(v - learned.sunsetOffsetMinutes) >= 10 { new.sunsetOffsetMinutes = v; notes.append("nightfall now begins \(Int(abs(v))) min \(v < 0 ? "before" : "after") sunset") }
    }
    let sunriseOff = offsets { e in
        if e.mode == "night", turnedOff(e), e.minsFromSunrise > -180, e.minsFromSunrise < 0 { return e.minsFromSunrise }
        if e.mode == "day", turnedOn(e), e.minsFromSunrise >= 0, e.minsFromSunrise < 90 { return e.minsFromSunrise }
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
        notify("Adjusted: " + notes.joined(separator: "; ") + ". Undo with 'nightfall forget'.")
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
    restore.filterEnabled = nil; restore.intensity = nil; restore.filterType = nil; restore.hue = nil
    if let snap = state?.daySnapshot {
        restore.keyboardBrightness = snap.keyboardBrightness ?? restore.keyboardBrightness
        restore.keyboardIdleDimSeconds = snap.keyboardIdleDimSeconds ?? restore.keyboardIdleDimSeconds
        restore.keyboardAutoBrightness = snap.keyboardAutoBrightness ?? restore.keyboardAutoBrightness
        restore.shadeEnabled = snap.shadeEnabled ?? false
        restore.shadeLevel = snap.shadeLevel ?? restore.shadeLevel
        restore.warmth = snap.warmth ?? 0
    }
    return restore
}

// MARK: - Transitions
/// Begin (or instantly complete) a transition. `fade` = 0 applies the target at once.
func startTransition(to mode: String, cfg: Config, learned: Learned, state: State?, now: Date, fade: Double, since: Date? = nil) -> State {
    var st = state ?? State(mode: "unset", daySnapshot: nil, lastSeen: nil, lastNotified: nil, ramp: nil, pausedUntil: nil)
    let target: Settings
    if mode == "night" {
        switch st.mode {
        case "day": st.daySnapshot = readCurrent()
        case "night": break
        default: st.daySnapshot = nil
        }
        target = nightPreset(cfg: cfg, learned: learned)
    } else {
        target = dayLook(cfg: cfg, state: st)
    }
    let from = readCurrent()
    st.mode = mode
    st.ramp = nil
    // If we woke up mid-transition, pick the fade up where the clock says it should be.
    let began = since ?? now
    let elapsed = now.timeIntervalSince(began)
    if fade > 0 && elapsed < fade * 60 {
        let ramp = Ramp(start: began, seconds: fade * 60, from: from, to: target, label: mode.uppercased())
        st.ramp = ramp
        let t = elapsed / ramp.seconds
        apply(blend(from, target, t), label: "\(ramp.label) \(Int(t * 100))%")
    } else {
        apply(target, label: mode.uppercased())
    }
    if mode == "day" { st.daySnapshot = nil }
    st.lastSeen = readCurrent()
    return st
}
func stepRamp(_ st: inout State, now: Date) {
    guard let r = st.ramp else { return }
    let t = now.timeIntervalSince(r.start) / r.seconds
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

// MARK: - Main
let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "check"
let cfg = loadConfig()
var learned = loadLearned()
let now = Date()
let fmt = DateFormatter(); fmt.dateStyle = .none; fmt.timeStyle = .short
let fadeMinutes = cfg.fadeMinutes ?? 30

switch cmd {
case "check":
    var st = loadState() ?? State(mode: "unset", daySnapshot: nil, lastSeen: nil, lastNotified: nil, ramp: nil, pausedUntil: nil)
    if let until = st.pausedUntil {
        if now < until { saveState(st); exit(0) }       // paused: leave everything alone, learn nothing
        st.pausedUntil = nil; log("pause ended")
    }
    let (observed, changes) = observe(cfg: cfg, learned: learned, state: st, now: now)
    st = observed
    pruneEvents(olderThan: now.addingTimeInterval(-Double((cfg.learning ?? Learning()).lookbackDays + 7) * 86400))
    let newLearned = learn(cfg: cfg, learned: learned, state: &st, now: now)
    if (try? enc.encode(newLearned)) != (try? enc.encode(learned)) { saveLearned(newLearned); learned = newLearned }
    let want = isNight(cfg: cfg, learned: learned, now: now) ? "night" : "day"
    if st.mode != want {
        log("transition \(st.mode) -> \(want)")
        st = startTransition(to: want, cfg: cfg, learned: learned, state: st, now: now, fade: fadeMinutes, since: lastTransition(cfg: cfg, learned: learned, now: now))
    } else if st.ramp != nil {
        if changes > 0 { log("you adjusted something mid-transition; leaving it as you set it"); st.ramp = nil }
        else { stepRamp(&st, now: now) }
    }
    saveState(st)
case "night", "day":
    var st = loadState()
    st?.pausedUntil = nil
    saveState(startTransition(to: cmd, cfg: cfg, learned: learned, state: st, now: now, fade: 0))
case "pause":
    // nightfall pause <minutes> | sunrise
    var st = loadState() ?? State(mode: "unset", daySnapshot: nil, lastSeen: nil, lastNotified: nil, ramp: nil, pausedUntil: nil)
    let arg = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "60"
    let until: Date
    if arg == "sunrise" { until = nextSunrise(cfg: cfg, learned: learned, now: now) ?? now.addingTimeInterval(8 * 3600) }
    else if let m = Double(arg), m > 0 { until = now.addingTimeInterval(m * 60) }
    else { print("usage: nightfall pause <minutes>|sunrise"); exit(2) }
    if st.mode == "night" { st = startTransition(to: "day", cfg: cfg, learned: learned, state: st, now: now, fade: 0) }
    st.pausedUntil = until
    saveState(st); log("paused until \(fmt.string(from: until))"); print("paused until \(fmt.string(from: until))")
case "resume":
    var st = loadState() ?? State(mode: "unset", daySnapshot: nil, lastSeen: nil, lastNotified: nil, ramp: nil, pausedUntil: nil)
    st.pausedUntil = nil
    let want = isNight(cfg: cfg, learned: learned, now: now) ? "night" : "day"
    if st.mode != want { st = startTransition(to: want, cfg: cfg, learned: learned, state: st, now: now, fade: 0) }
    saveState(st); log("resumed"); print("resumed (\(want))")
case "location":
    // nightfall location <lat> <lon> [auto|manual]
    guard CommandLine.arguments.count > 3, let la = Double(CommandLine.arguments[2]), let lo = Double(CommandLine.arguments[3]),
          abs(la) <= 90, abs(lo) <= 180 else { print("usage: nightfall location <lat> <lon> [auto|manual]"); exit(2) }
    var c = cfg
    let source = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "manual"
    if source == "auto" && c.locationSource == "manual" { print("location is set manually; not overriding"); exit(0) }
    let moved = abs(c.latitude - la) > 0.05 || abs(c.longitude - lo) > 0.05
    c.latitude = la; c.longitude = lo; c.locationSource = source
    saveConfig(c)
    if moved { log(String(format: "location updated to %.3f, %.3f (%@)", la, lo, source)) }
    print(String(format: "location %.3f, %.3f (%@)", la, lo, source))
case "set":
    guard CommandLine.arguments.count > 3 else { print("usage: nightfall set warmth|keyboard|idle|shade|tint <value|off>"); exit(2) }
    let field = CommandLine.arguments[2], raw = CommandLine.arguments[3]
    let off = (raw == "off")
    guard off || Double(raw) != nil else { print("'\(raw)' is not a number or 'off'"); exit(2) }
    let num = Double(raw) ?? 0
    var s = Settings()
    switch field {
    case "warmth": s.warmth = off ? 0 : max(0, min(1, num / 100))
    case "keyboard": s.keyboardAutoBrightness = false; s.keyboardBrightness = off ? 0 : max(0, min(1, num / 100))
    case "idle":
        guard !off, num >= 1 else { print("idle needs a number of seconds (1 or more)"); exit(2) }
        s.keyboardIdleDimSeconds = num
    case "shade": if off { s.shadeEnabled = false } else { s.shadeEnabled = num > 0; s.shadeLevel = max(0, min(0.9, num / 100)) }
    case "tint":   // advanced: drive the color filter directly, outside the warmth curve
        if off { s.filterEnabled = false } else { s.filterEnabled = true; s.filterType = 16; s.hue = 1.0; s.intensity = max(0, min(1, num / 100)) }
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
        var s = p.settings
        if s.warmth == nil { s.warmth = 0 }
        if s.keyboardBrightness != nil { s.keyboardAutoBrightness = false }
        apply(s, label: "PRESET \(p.name)")
    case "save":
        guard !name.isEmpty else { print("usage: nightfall preset save <name> [sf-symbol]"); exit(2) }
        var cur = readCurrent()
        cur.filterType = nil; cur.hue = nil; cur.keyboardAutoBrightness = nil; cur.filterEnabled = nil; cur.intensity = nil
        if cur.keyboardBrightness == nil { cur.keyboardBrightness = cfg.night.keyboardBrightness }
        let icon = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "star.fill"
        presets.removeAll { $0.name.lowercased() == name.lowercased() }
        presets.append(Preset(name: name, icon: icon, settings: cur))
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
        var l = learned; l.nightKeyboardBrightness = nil; l.nightIdleDimSeconds = nil; l.nightShadeLevel = nil; l.nightWarmth = nil; saveLearned(l)
        log("sunset preset is now '\(p.name)'")
        if var st = loadState(), st.mode == "night", st.pausedUntil == nil { st.ramp = nil; apply(nightPreset(cfg: c, learned: l), label: "NIGHT (preset changed)"); st.lastSeen = readCurrent(); saveState(st) }
    case "delete":
        guard find() != nil else { print("no preset named \(name)"); exit(1) }
        presets.removeAll { $0.name.lowercased() == name.lowercased() }
        if c.nightPresetName?.lowercased() == name.lowercased() { c.nightPresetName = nil }
        c.presets = presets; saveConfig(c); print("deleted \(name)")
    default: print("usage: nightfall preset list|apply|save|night|delete <name>"); exit(2)
    }
case "shade":
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
        else { print("usage: nightfall shade on|off|toggle|up|down|<0-100>"); exit(2) }
    }
    saveShade(sh)
    print("shade \(sh.enabled ? "on" : "off") \(Int((sh.level * 100).rounded()))%")
case "reapply":
    if var st = loadState(), st.mode == "night", st.pausedUntil == nil {
        st.ramp = nil
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
    var head = "mode: \(st?.mode ?? "unset")"
    if let u = st?.pausedUntil, u > now { head += "   paused until \(fmt.string(from: u))" }
    if let r = st?.ramp { head += "   fading \(Int(min(1, now.timeIntervalSince(r.start) / r.seconds) * 100))%" }
    head += "   switches: day at \(eff.rise.map(fmt.string) ?? "-"), night at \(eff.set.map(fmt.string) ?? "-")"
    print(head)
    print("current: \(describe(readCurrent()))\(runningApp() ? "" : "   [menu bar app not running: shade and warmth are not applied]")")
    print("night preset: \(describe(nightPreset(cfg: cfg, learned: learned)))")
    if let snap = st?.daySnapshot { print("saved day settings: \(describe(snap))") }
    print(String(format: "location: %.3f, %.3f (%@)   fade: %.0f min", cfg.latitude, cfg.longitude, cfg.locationSource ?? "unknown", fadeMinutes))
case "learned":
    print("sunset offset: \(Int(learned.sunsetOffsetMinutes)) min   sunrise offset: \(Int(learned.sunriseOffsetMinutes)) min")
    if let v = learned.nightWarmth { print(String(format: "night warmth: %.0f%%", v * 100)) }
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
    print("usage: nightfall check|night|day|pause|resume|location|set|preset|shade|reapply|status|suntimes|learned|forget"); exit(2)
}
