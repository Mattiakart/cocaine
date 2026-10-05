import AppKit
import CoreGraphics
import IOKit.ps

// Power: Smart Triggers on power, external displays and time windows; the "screen off" mode; control from Shortcuts
// and cocaine:// links. Pure logic here (tested by --power-test); main.swift wires it to the app and the panel.

// MARK: - Time windows

/// Days of the week plus a start and end time, read on the wall clock (so DST and time-zone changes just work: the
/// window follows local time). An end at or before the start runs past midnight; start == end is the whole day.
struct TimeWindow: Equatable {
    var days: Set<Int>      // Calendar weekdays: 1 = Sunday … 7 = Saturday; a window past midnight belongs to the day it starts
    var start: Int          // minutes after midnight, 0..<1440
    var end: Int

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard !days.isEmpty else { return false }
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wd = c.weekday, let h = c.hour, let mi = c.minute else { return false }
        let m = h * 60 + mi, s = Self.clamp(start), e = Self.clamp(end)
        let yesterday = wd == 1 ? 7 : wd - 1
        if s == e { return days.contains(wd) }
        if s < e { return days.contains(wd) && m >= s && m < e }
        return (days.contains(wd) && m >= s) || (days.contains(yesterday) && m < e)
    }

    static func clamp(_ m: Int) -> Int { min(max(m, 0), 1439) }
}

// MARK: - Triggers

enum TriggerKind: String, CaseIterable {
    case agents, apps, power, display, schedule

    /// How long Cocaine stays on after the reason goes away: agents and apps pause between steps, a cable can wiggle,
    /// and a schedule ends when it says.
    var grace: TimeInterval {
        switch self {
        case .agents, .apps: return 180
        case .power, .display: return 30
        case .schedule: return 0
        }
    }
}

/// Combines the enabled triggers into one "want it on" and says how long to wait once that ends.
/// Any: one reason is enough. All: every enabled one must hold (and at least one must be enabled).
struct TriggerArbiter {
    private(set) var lastTrue: Set<TriggerKind> = []

    mutating func evaluate(_ states: [TriggerKind: Bool], all: Bool, blocked: Bool = false) -> (active: Bool, grace: TimeInterval) {
        let trues = Set(states.filter { $0.value }.keys)
        let active = !blocked && (all ? (!states.isEmpty && trues.count == states.count) : !trues.isEmpty)
        if active { lastTrue = trues; return (true, 0) }
        if blocked { return (false, 0) }
        if all {   // ended by the first one that let go: its grace
            let gone = lastTrue.filter { states[$0] != true }
            return (false, gone.map(\.grace).min() ?? 0)
        }
        return (false, lastTrue.map(\.grace).max() ?? 0)
    }
}

/// What the power and display triggers look at.
enum PowerState {
    /// On the charger (a Mac without a battery always is).
    static var onAC: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPSACPowerValue
    }

    /// Displays other than the built-in one (an external monitor, a TV, AirPlay or Sidecar); asleep ones count too.
    static var externalDisplays: Int {
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &n) == .success, n > 0 else { return 0 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetOnlineDisplayList(n, &ids, &n) == .success else { return 0 }
        return ids.prefix(Int(n)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    /// Every display is asleep (or none is on): input sent now would light them up.
    static var displaysAsleep: Bool {
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &n) == .success, n > 0 else { return true }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetOnlineDisplayList(n, &ids, &n) == .success else { return false }
        return ids.prefix(Int(n)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }

    /// Turns every display off now (no admin rights needed). Input, an alert or a wake lights them again.
    @discardableResult
    static func sleepDisplays() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// The power trigger: on the charger, or on battery while above a level.
enum PowerRule {
    static func met(rule: String, onAC: Bool, battery: Int?, minimum: Int) -> Bool? {
        switch rule {
        case "ac": return onAC
        case "battery": guard let battery else { return false }; return !onAC && battery > minimum
        default: return nil                      // not enabled
        }
    }
}

enum DisplayRule {
    static func met(rule: String, external: Int) -> Bool? {
        switch rule {
        case "connected": return external > 0
        case "disconnected": return external == 0
        default: return nil
        }
    }
}

// MARK: - Idle time that ignores Cocaine's own nudges

/// "Stay active" posts an invisible mouse event now and then, which restarts the system's idle clock. Dimming and the
/// screen-off mode must count from the user's last real input, so input that lands right on one of those nudges is ignored.
struct RealIdle {
    private(set) var lastInput: Date?
    var lastNudge = Date.distantPast

    mutating func update(systemIdle: Double, now: Date) -> Double {
        let input = now.addingTimeInterval(-systemIdle)
        let ours = input >= lastNudge.addingTimeInterval(-0.5) && input <= lastNudge.addingTimeInterval(1.5)
        if let last = lastInput {
            if !ours && input > last.addingTimeInterval(0.5) { lastInput = input }
        } else {
            lastInput = input
        }
        return max(0, now.timeIntervalSince(lastInput ?? input))
    }
}

/// Screen-off mode: once per idle stretch, after the delay, turn the displays off.
struct ScreenOffGate {
    private(set) var fired = false

    mutating func step(idle: Double, delay: Double, enabled: Bool, on: Bool, allowed: Bool = true, asleep: Bool) -> Bool {
        guard enabled, on, idle >= delay else { fired = false; return false }
        guard allowed, !fired else { return false }
        fired = true
        return !asleep
    }
}

/// Lid closed, on battery, and the Mac getting hot (in a bag): turn Cocaine off, once until that clears.
struct HeatGuard {
    private(set) var tripped = false

    mutating func check(lidClosed: Bool, onAC: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        let hot = lidClosed && !onAC && (thermal == .serious || thermal == .critical)
        if !hot { tripped = false; return false }
        if tripped { return false }
        tripped = true
        return true
    }
}

// MARK: - cocaine:// control links (Shortcuts "Open URLs" / "Open X-Callback URL", scripts)

enum ControlAction: Equatable {
    case on(minutes: Int?), off, toggle, timer(minutes: Int?), pause(minutes: Int?), resume, panel, status

    /// Changes what the Mac does (or silences alerts): needs the user's OK.
    var guarded: Bool {
        switch self {
        case .panel, .status: return false
        default: return true
        }
    }
}

struct ControlRequest: Equatable {
    var action: ControlAction
    var success: URL?        // x-callback-url targets, only ever shortcuts://
    var failure: URL?
}

enum ControlURL {
    static let minutes = 1...1440

    enum Failure: Error, Equatable { case notOurs, unknown(String), badMinutes }

    /// `cocaine://on?minutes=90`, `cocaine://x-callback-url/status?x-success=shortcuts://…`, …
    static func parse(_ url: URL) -> Result<ControlRequest, Failure> {
        guard url.scheme?.lowercased() == "cocaine" else { return .failure(.notOurs) }
        let host = (url.host ?? "").lowercased()
        let name = host == "x-callback-url" ? (url.pathComponents.dropFirst().first ?? "").lowercased() : host
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ k: String) -> String? { items.first { $0.name == k }?.value }
        let success = value("x-success").flatMap(callback), failure = value("x-error").flatMap(callback)
        var mins: Int?
        if let raw = value("minutes") {
            guard raw.range(of: "^[0-9]{1,4}$", options: .regularExpression) != nil, let n = Int(raw), minutes.contains(n) else {
                return .failure(.badMinutes)
            }
            mins = n
        }
        let action: ControlAction
        switch name {
        case "on": action = .on(minutes: mins)
        case "off": action = .off
        case "toggle": action = .toggle
        case "timer": action = .timer(minutes: mins)
        case "pause": action = .pause(minutes: mins)
        case "resume": action = .resume
        case "panel": action = .panel
        case "status": action = .status
        default: return .failure(.unknown(String(name.prefix(20))))
        }
        return .success(ControlRequest(action: action, success: success, failure: failure))
    }

    /// Shortcuts' own commands that DO something: a callback must never be one of them, or a link from a web page could make
    /// Cocaine's answer run a named shortcut (`shortcuts://x-callback-url/run-shortcut?name=…`).
    static let shortcutsCommands: Set<String> = ["run-shortcut", "run", "open-shortcut", "create-shortcut", "import-shortcut",
                                                 "open-gallery", "gallery", "search", "x-callback-url"]

    /// Only Shortcuts' own answer address may be called back (`shortcuts://x-callback-url/<reply>`, never one of its commands):
    /// a web page can't get the answer, or bounce the user anywhere, or run a shortcut.
    static func callback(_ s: String) -> URL? {
        guard let u = URL(string: s), u.scheme?.lowercased() == "shortcuts",
              (u.host ?? "").lowercased() == "x-callback-url" else { return nil }
        let first = (u.pathComponents.dropFirst().first ?? "").lowercased()
        guard !first.isEmpty, !shortcutsCommands.contains(first) else { return nil }
        return u
    }

    /// The callback with our values added as properly encoded query items.
    static func reply(_ base: URL, _ values: [(String, String)]) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = (c.queryItems ?? []) + values.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url
    }

    /// What "status" answers: state, the deadline and minutes left (empty when none), and the screen mode.
    static func status(on: Bool, until: Date?, now: Date, screenOff: Bool, trigger: Bool) -> [(String, String)] {
        let left = on ? until.flatMap { $0 > now ? Int(($0.timeIntervalSince(now) / 60).rounded(.up)) : nil } : nil
        let iso = ISO8601DateFormatter()
        return [("state", on ? "on" : "off"),
                ("until", on ? (until.map { iso.string(from: $0) } ?? "") : ""),
                ("remaining_minutes", left.map(String.init) ?? ""),
                ("screen_off_mode", screenOff ? "1" : "0"),
                ("trigger_active", trigger ? "1" : "0")]
    }
}
