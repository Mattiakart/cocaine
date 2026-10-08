// Keep-awake profiles (the Amphetamine round, "Triggers" in Amphetamine's words): named sets of conditions (Wi-Fi network,
// Ethernet, hotspot, internet, IP address, DNS server, VPN, USB, Bluetooth, sound output, disk, processor, front app, a running
// app, idle time, downloads, power, battery, external display, mirroring, schedule), matched Any or All, each profile with its
// own settings (start and stop delays so a flapping reading never toggles, a longest run, display may sleep, keep awake or let
// the Mac sleep, notices) and a priority (the list's order: the first profile that holds decides).
// Pure logic here, every reading in one AwakeSnapshot (Sources/AwakeProfileProbe.swift reads the Mac, --triggers-test passes
// fixed ones: Sources/TriggersTests.swift). Sources/AwakeCenter.swift steps it every 5 s, AppDelegate combines it with the
// Smart Triggers, Sources/AwakeProfilesPanel.swift edits it.

import Foundation

// MARK: - Conditions

struct AwakeCondition: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case wifi, wifiConnected, ethernet, hotspot, internet, ipAddress, dns, vpn
        case usb, bluetooth, audio, volume
        case cpu, frontApp, appRunning, idle, downloads
        case power, battery, display, mirroring, schedule
    }

    var id = AwakeCondition.newID()
    var kind: Kind
    /// "is not": the reading must be false. A reading that can't be made (no Wi-Fi name without Location) is never met, either way.
    var negate = false
    /// Wi-Fi networks, IP addresses or ranges, DNS servers, USB/Bluetooth devices, sound outputs, disks, apps.
    var names: [String] = []
    /// CPU %, idle minutes, battery %.
    var number = 0
    /// CPU: for at least these minutes.
    var minutes = 0
    /// CPU above (or below), idle longer (or shorter) than, battery above (or below).
    var above = true
    /// Schedule: weekdays (1 = Sunday … 7) and minutes after midnight.
    var days: [Int] = [2, 3, 4, 5, 6]
    var start = 540
    var end = 1080

    static func newID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    /// A new condition of this kind with sensible values.
    static func make(_ kind: Kind) -> AwakeCondition {
        var c = AwakeCondition(kind: kind)
        switch kind {
        case .cpu: c.number = 50; c.minutes = 2; c.above = true
        case .idle: c.number = 10; c.above = false            // "idle for less than 10 min": awake while you're around
        case .battery: c.number = 30; c.above = true
        default: break
        }
        return c
    }

    /// Kinds whose value is a list of names (empty = can't be met yet).
    var usesNames: Bool { Self.nameKinds.contains(kind) }
    static let nameKinds: Set<Kind> = [.wifi, .ipAddress, .dns, .usb, .bluetooth, .audio, .volume, .frontApp, .appRunning]

    init(id: String = AwakeCondition.newID(), kind: Kind) { self.id = id; self.kind = kind }

    // Tolerant decoding: a missing field takes its default; an unknown kind fails this condition only (the list skips it).
    enum CodingKeys: String, CodingKey { case id, kind, negate, names, number, minutes, above, days, start, end }
    init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? Self.newID()
        negate = (try? c.decodeIfPresent(Bool.self, forKey: .negate)) ?? false
        names = (try? c.decodeIfPresent([String].self, forKey: .names)) ?? []
        number = (try? c.decodeIfPresent(Int.self, forKey: .number)) ?? 0
        minutes = (try? c.decodeIfPresent(Int.self, forKey: .minutes)) ?? 0
        above = (try? c.decodeIfPresent(Bool.self, forKey: .above)) ?? true
        days = (try? c.decodeIfPresent([Int].self, forKey: .days)) ?? [2, 3, 4, 5, 6]
        start = (try? c.decodeIfPresent(Int.self, forKey: .start)) ?? 540
        end = (try? c.decodeIfPresent(Int.self, forKey: .end)) ?? 1080
    }
}

/// Everything the conditions read, taken once per step. nil = couldn't be read (never met, "is not" included).
struct AwakeSnapshot {
    var now = Date()
    var calendar = Calendar.autoupdatingCurrent
    var ssid: String?                     // nil: no Wi-Fi, or the name is hidden (Location Services)
    var wifiConnected = false
    var ethernet = false
    var expensive = false                 // a Personal Hotspot (or another network macOS marks as costly)
    var internet = false
    var addresses: [String] = []          // this Mac's IPv4/IPv6 addresses
    var dns: [String] = []
    var vpn = false
    var usb: [String] = []
    var bluetooth: [String]?              // connected Bluetooth devices; nil until first read
    var output: String?
    var volumes: [String] = []
    var front: String?                    // the app in front: its name
    var frontBundle: String?
    var running: Set<String> = []         // lowercased names of running programs
    var idle: Double = 0                  // seconds since the user's last input
    var downloading: Bool?
    var onAC = true
    var battery: Int?
    var externalDisplays = 0
    var mirroring = false
    var cpuTicks: CPUTicks?
    /// Per CPU condition (by id): the rule holds. Filled by ProfileEngine from cpuTicks.
    var cpuHolds: [String: Bool] = [:]
}

enum IPMatch {
    /// "192.168.1.0/24" (a range), "10.0." (a beginning), or a whole address; IPv6 by beginning or whole address.
    static func matches(_ pattern: String, _ addr: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces).lowercased(), a = addr.lowercased()
        guard !p.isEmpty else { return false }
        if let slash = p.firstIndex(of: "/") {
            guard let bits = Int(p[p.index(after: slash)...]), (0...32).contains(bits),
                  let net = v4(String(p[..<slash])), let ip = v4(a) else { return false }
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
            return net & mask == ip & mask
        }
        if p.hasSuffix(".") || p.hasSuffix(":") { return a.hasPrefix(p) }
        return a == p
    }

    static func v4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard p.count <= 3, let n = UInt32(p), n <= 255 else { return nil }
            v = v << 8 | n
        }
        return v
    }

    /// A pattern the user typed is one of the forms above.
    static func valid(_ pattern: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, p.count <= 45, p.allSatisfy({ $0.isHexDigit || ".:/".contains($0) }) else { return false }
        if let slash = p.firstIndex(of: "/") {
            guard let bits = Int(p[p.index(after: slash)...]), (0...32).contains(bits) else { return false }
            return v4(String(p[..<slash])) != nil
        }
        if p.hasSuffix(".") || p.hasSuffix(":") { return true }
        return v4(p) != nil || p.contains(":")
    }
}

enum ConditionEval {
    /// The reading itself (before "is not"); nil = unknown.
    static func reading(_ c: AwakeCondition, _ s: AwakeSnapshot) -> Bool? {
        func any(_ present: [String]) -> Bool { !c.names.isEmpty && AwakeLists.matches(c.names, present) }
        switch c.kind {
        case .wifi:
            guard let ssid = s.ssid else { return nil }
            return c.names.contains { $0.caseInsensitiveCompare(ssid) == .orderedSame }
        case .wifiConnected: return s.wifiConnected
        case .ethernet: return s.ethernet
        case .hotspot: return s.expensive
        case .internet: return s.internet
        case .ipAddress: return c.names.contains { p in s.addresses.contains { IPMatch.matches(p, $0) } }
        case .dns: return c.names.contains { p in s.dns.contains { IPMatch.matches(p, $0) } }
        case .vpn: return s.vpn
        case .usb: return any(s.usb)
        case .bluetooth: return s.bluetooth.map(any)
        case .audio: return s.output.map { any([$0]) }
        case .volume: return any(s.volumes)
        case .cpu: return s.cpuHolds[c.id]
        case .frontApp:
            guard s.front != nil || s.frontBundle != nil else { return false }
            return c.names.contains { n in
                [s.front, s.frontBundle].compactMap { $0 }.contains { $0.caseInsensitiveCompare(n) == .orderedSame }
            }
        case .appRunning: return c.names.contains { s.running.contains($0.lowercased()) }
        case .idle:
            let limit = Double(max(1, c.number)) * 60
            return c.above ? s.idle >= limit : s.idle < limit
        case .downloads: return s.downloading
        case .power: return s.onAC
        case .battery:
            guard let b = s.battery else { return nil }
            return c.above ? b >= c.number : b < c.number
        case .display: return s.externalDisplays > 0
        case .mirroring: return s.mirroring
        case .schedule: return TimeWindow(days: Set(c.days), start: c.start, end: c.end).contains(s.now, calendar: s.calendar)
        }
    }

    static func met(_ c: AwakeCondition, _ s: AwakeSnapshot) -> Bool {
        guard let r = reading(c, s) else { return false }
        return c.negate ? !r : r
    }
}

// MARK: - Profiles

struct AwakeProfile: Codable, Equatable, Identifiable {
    enum Action: String, Codable { case keepAwake, letSleep }

    var id = AwakeCondition.newID()
    var name: String
    var enabled = true
    /// All conditions must hold (true) or one is enough.
    var matchAll = true
    var conditions: [AwakeCondition] = []
    /// Keep the Mac awake, or keep every trigger from turning Cocaine on ("Let the Mac sleep").
    var action = Action.keepAwake
    /// While this profile keeps the Mac awake the displays may sleep (the engine's screen-off hold: the Mac stays awake).
    var displaySleep = false
    /// Seconds the conditions must hold without a break before it starts, and fail without a break before it stops.
    var startAfter = 10
    var stopAfter = 60
    /// The longest it keeps the Mac awake in one go (minutes, 0 = as long as the conditions hold); then it waits until they break.
    var maxMinutes = 0
    /// A notice when it starts and stops.
    var notify = true

    static let startChoices = [0, 10, 30, 60, 300]
    static let stopChoices = [0, 30, 60, 300, 900]
    static let maxChoices = [0, 30, 60, 120, 240, 480]
    static let limit = 20
    static let conditionLimit = 12

    init(name: String, conditions: [AwakeCondition] = []) { self.name = name; self.conditions = conditions }

    enum CodingKeys: String, CodingKey { case id, name, enabled, matchAll, conditions, action, displaySleep, startAfter, stopAfter, maxMinutes, notify }
    init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? AwakeCondition.newID()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        matchAll = (try? c.decodeIfPresent(Bool.self, forKey: .matchAll)) ?? true
        conditions = ((try? c.decodeIfPresent([Lossy<AwakeCondition>].self, forKey: .conditions)) ?? []).compactMap(\.value)
        action = (try? c.decodeIfPresent(Action.self, forKey: .action)) ?? .keepAwake
        displaySleep = (try? c.decodeIfPresent(Bool.self, forKey: .displaySleep)) ?? false
        startAfter = (try? c.decodeIfPresent(Int.self, forKey: .startAfter)) ?? 10
        stopAfter = (try? c.decodeIfPresent(Int.self, forKey: .stopAfter)) ?? 60
        maxMinutes = (try? c.decodeIfPresent(Int.self, forKey: .maxMinutes)) ?? 0
        notify = (try? c.decodeIfPresent(Bool.self, forKey: .notify)) ?? true
    }

    /// The conditions hold now (before the delays). No condition: never.
    func holds(_ s: AwakeSnapshot) -> Bool {
        guard !conditions.isEmpty else { return false }
        return matchAll ? conditions.allSatisfy { ConditionEval.met($0, s) } : conditions.contains { ConditionEval.met($0, s) }
    }
}

/// One element of a list that may fail to decode on its own.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from dec: Decoder) throws { value = try? T(from: dec) }
}

enum AwakeProfiles {
    /// Bounded, valid values: at most 20 profiles of 12 conditions, unique ids, names cleaned, numbers in range.
    static func clean(_ list: [AwakeProfile]) -> [AwakeProfile] {
        var ids = Set<String>(), out: [AwakeProfile] = []
        for var p in list.prefix(AwakeProfile.limit) {
            if p.id.isEmpty || p.id.count > 40 || ids.contains(p.id) { p.id = AwakeCondition.newID() }
            ids.insert(p.id)
            p.name = cleanName(p.name, fallback: String(format: L("Profile %d"), out.count + 1))
            p.startAfter = min(3600, max(0, p.startAfter))
            p.stopAfter = min(3600, max(0, p.stopAfter))
            p.maxMinutes = min(1440, max(0, p.maxMinutes))
            var cids = Set<String>()
            p.conditions = p.conditions.prefix(AwakeProfile.conditionLimit).map { c0 in
                var c = c0
                if c.id.isEmpty || c.id.count > 40 || cids.contains(c.id) { c.id = AwakeCondition.newID() }
                cids.insert(c.id)
                c.names = c.usesNames ? AwakeLists.clean(c.names) : []
                if c.kind == .ipAddress || c.kind == .dns { c.names = c.names.filter(IPMatch.valid) }
                switch c.kind {
                case .cpu: c.number = CPURule.clampPercent(c.number); c.minutes = CPURule.clampMinutes(c.minutes)
                case .idle: c.number = min(240, max(1, c.number))
                case .battery: c.number = min(100, max(5, c.number))
                default: c.number = 0
                }
                if c.kind != .cpu { c.minutes = 0 }
                c.days = Array(Set(c.days.filter { (1...7).contains($0) })).sorted()
                c.start = TimeWindow.clamp(c.start); c.end = TimeWindow.clamp(c.end)
                return c
            }
            out.append(p)
        }
        return out
    }

    static func cleanName(_ s: String, fallback: String) -> String {
        let v = String(String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespaces).prefix(40))
        return v.isEmpty ? fallback : v
    }

    static func decode(_ data: Data?) -> [AwakeProfile] {
        guard let data, let list = try? JSONDecoder().decode([Lossy<AwakeProfile>].self, from: data) else { return [] }
        return clean(list.compactMap(\.value))
    }

    static func encode(_ list: [AwakeProfile]) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(clean(list))
    }

    /// What the enabled profiles read (so nothing else is read: Bluetooth and Downloads only when asked for).
    static func needs(_ list: [AwakeProfile]) -> Set<AwakeCondition.Kind> {
        Set(list.filter(\.enabled).flatMap { $0.conditions.map(\.kind) })
    }

    /// A profile by name (case-insensitive) or id.
    static func find(_ key: String, in list: [AwakeProfile]) -> AwakeProfile? {
        list.first { $0.id == key } ?? list.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// Ready-made starting points for "New profile".
    static func template(_ id: String) -> AwakeProfile? {
        func c(_ k: AwakeCondition.Kind, _ f: (inout AwakeCondition) -> Void = { _ in }) -> AwakeCondition { var x = AwakeCondition.make(k); f(&x); return x }
        switch id {
        case "empty": return AwakeProfile(name: L("New profile"))
        case "office":
            var p = AwakeProfile(name: L("At the office"), conditions: [c(.wifi), c(.power)])
            p.stopAfter = 300
            return p
        case "desk":
            return AwakeProfile(name: L("At the desk"), conditions: [c(.display), c(.power)])
        case "present":
            var p = AwakeProfile(name: L("Presenting"), conditions: [c(.mirroring), c(.frontApp) { $0.names = ["Keynote"] }])
            p.matchAll = false
            return p
        case "backup":
            var p = AwakeProfile(name: L("Backup disk"), conditions: [c(.volume), c(.power)])
            p.displaySleep = true
            return p
        case "download":
            var p = AwakeProfile(name: L("Big downloads"), conditions: [c(.downloads)])
            p.displaySleep = true; p.stopAfter = 120
            return p
        case "lowbattery":
            var p = AwakeProfile(name: L("Low battery"), conditions: [c(.power) { $0.negate = true }, c(.battery) { $0.above = false; $0.number = 20 }])
            p.action = .letSleep; p.startAfter = 0; p.stopAfter = 30
            return p
        default: return nil
        }
    }
    static let templates = ["empty", "office", "desk", "present", "backup", "download", "lowbattery"]
}

extension Settings {
    var awakeProfiles: [AwakeProfile] {
        get { AwakeProfiles.decode(d.data(forKey: "awakeProfiles")) }
        nonmutating set { if let data = AwakeProfiles.encode(newValue) { d.set(data, forKey: "awakeProfiles") } }
    }
}

// MARK: - Start and stop without flapping

/// One profile over time: it starts once its conditions held `startAfter` seconds without a break, stops once they failed
/// `stopAfter` seconds without a break, and after `maxMinutes` it stops and waits until the conditions break before it can
/// start again.
struct ProfileLatch: Equatable {
    private(set) var engaged = false
    private(set) var trueSince: Date?
    private(set) var falseSince: Date?
    private(set) var engagedAt: Date?
    /// Its longest run ended it: it waits for the conditions to break.
    private(set) var spent = false

    enum Change: Equatable { case none, started, stopped, spent }

    mutating func step(holds: Bool, profile p: AwakeProfile, now: Date) -> Change {
        if holds {
            falseSince = nil
            if trueSince == nil { trueSince = now }
            if engaged, p.maxMinutes > 0, let at = engagedAt, now.timeIntervalSince(at) >= Double(p.maxMinutes) * 60 {
                engaged = false; engagedAt = nil; spent = true
                return .spent
            }
            if !engaged && !spent && now.timeIntervalSince(trueSince!) >= Double(p.startAfter) {
                engaged = true; engagedAt = now
                return .started
            }
            return .none
        }
        trueSince = nil
        spent = false
        if falseSince == nil { falseSince = now }
        if engaged && now.timeIntervalSince(falseSince!) >= Double(p.stopAfter) {
            engaged = false; engagedAt = nil
            return .stopped
        }
        return .none
    }
}

/// What the profiles decide in one step.
struct ProfileOutcome: Equatable {
    /// Engaged profiles' ids, in priority order.
    var engaged: [String] = []
    /// Profiles whose conditions hold right now (before the delays).
    var holding: Set<String> = []
    /// The first engaged profile: it decides.
    var lead: AwakeProfile?
    var started: [AwakeProfile] = []
    var stopped: [AwakeProfile] = []

    /// Keep the Mac awake (the lead keeps it awake).
    var keepAwake: Bool { lead?.action == .keepAwake }
    /// Hold every trigger back (the lead lets the Mac sleep).
    var block: Bool { lead?.action == .letSleep }
    /// The displays may sleep while the lead keeps the Mac awake.
    var displaySleep: Bool { keepAwake && lead?.displaySleep == true }
}

struct ProfileEngine {
    private(set) var latches: [String: ProfileLatch] = [:]
    private var cpu: [String: CPURule] = [:]

    /// One step over the profiles in priority order. Disabled profiles are reset (their latch forgets).
    mutating func step(_ profiles: [AwakeProfile], snapshot s0: AwakeSnapshot) -> ProfileOutcome {
        var s = s0
        let live = profiles.filter(\.enabled)
        // The processor rules keep their own stretch per condition.
        let cpuIDs = Set(live.flatMap { $0.conditions.filter { $0.kind == .cpu } }.map(\.id))
        cpu = cpu.filter { cpuIDs.contains($0.key) }
        for p in live { for c in p.conditions where c.kind == .cpu {
            var r = cpu[c.id] ?? CPURule()
            s.cpuHolds[c.id] = r.step(rule: c.above ? "above" : "below", percent: c.number, minutes: c.minutes, ticks: s.cpuTicks, now: s.now)
            cpu[c.id] = r
        } }
        latches = latches.filter { id, _ in live.contains { $0.id == id } }
        var out = ProfileOutcome()
        for p in live {
            let holds = p.holds(s)
            if holds { out.holding.insert(p.id) }
            var l = latches[p.id] ?? ProfileLatch()
            switch l.step(holds: holds, profile: p, now: s.now) {
            case .started: out.started.append(p)
            case .stopped, .spent: out.stopped.append(p)
            case .none: break
            }
            latches[p.id] = l
            if l.engaged { out.engaged.append(p.id) }
        }
        out.lead = live.first { out.engaged.contains($0.id) }
        return out
    }

    mutating func reset() { latches = [:]; cpu = [:] }
}

// MARK: - Words

enum ProfileWords {
    static func kindTitle(_ k: AwakeCondition.Kind) -> String {
        switch k {
        case .wifi: return L("Wi-Fi network")
        case .wifiConnected: return L("Wi-Fi is connected")
        case .ethernet: return L("Ethernet is connected")
        case .hotspot: return L("Personal Hotspot")
        case .internet: return L("Internet is reachable")
        case .ipAddress: return L("IP address")
        case .dns: return L("DNS server")
        case .vpn: return L("A VPN is connected")
        case .usb: return L("A USB device is connected")
        case .bluetooth: return L("A Bluetooth device is connected")
        case .audio: return L("Sound plays through")
        case .volume: return L("A disk is connected")
        case .cpu: return L("Processor")
        case .frontApp: return L("App in front")
        case .appRunning: return L("App is running")
        case .idle: return L("Idle time")
        case .downloads: return L("Downloads are in progress")
        case .power: return L("On the charger")
        case .battery: return L("Battery level")
        case .display: return L("External display")
        case .mirroring: return L("Screen mirroring")
        case .schedule: return L("Schedule")
        }
    }

    static func symbol(_ k: AwakeCondition.Kind) -> String {
        switch k {
        case .wifi, .wifiConnected: return "wifi"
        case .ethernet: return "cable.connector.horizontal"
        case .hotspot: return "personalhotspot"
        case .internet: return "globe"
        case .ipAddress, .dns: return "network"
        case .vpn: return "lock.shield"
        case .usb: return "cable.connector"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .audio: return "speaker.wave.2"
        case .volume: return "externaldrive"
        case .cpu: return "cpu"
        case .frontApp: return "macwindow"
        case .appRunning: return "app.badge"
        case .idle: return "hourglass"
        case .downloads: return "arrow.down.circle"
        case .power: return "powerplug"
        case .battery: return "battery.50"
        case .display: return "display"
        case .mirroring: return "rectangle.on.rectangle"
        case .schedule: return "calendar"
        }
    }

    /// One line about a condition's value: "Office, Office-5G", "Above 50% for 2 min", "Not: on the charger".
    static func value(_ c: AwakeCondition) -> String {
        let base: String
        switch c.kind {
        case .cpu:
            base = String(format: c.above ? L("Above %@ for %@") : L("Below %@ for %@"), "\(c.number)%", Dur.short(minutes: c.minutes))
        case .idle:
            base = String(format: c.above ? L("Idle for %@ or more") : L("Idle for less than %@"), Dur.short(minutes: c.number))
        case .battery:
            base = String(format: c.above ? L("At least %@") : L("Below %@"), "\(c.number)%")
        case .schedule:
            base = "\(days(c.days)) \(clock(c.start))–\(clock(c.end))"
        default:
            base = c.usesNames ? AwakeRowKit.listValue(c.names) : L("Yes")
        }
        return c.negate ? String(format: L("Not: %@"), base) : base
    }

    static func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }

    /// Weekdays, short, Monday first: "Mon Tue Wed" in the app's language.
    static func days(_ list: [Int]) -> String {
        let f = DateFormatter()
        f.locale = appLocale()
        let names = f.shortWeekdaySymbols ?? []
        return [2, 3, 4, 5, 6, 7, 1].filter { list.contains($0) && $0 <= names.count }.map { names[$0 - 1] }.joined(separator: " ")
    }

    /// "Wi-Fi network: Office · On the charger" (the first three).
    static func summary(_ p: AwakeProfile) -> String {
        guard !p.conditions.isEmpty else { return L("No conditions yet") }
        let parts = p.conditions.prefix(3).map { c -> String in
            c.usesNames || [.cpu, .idle, .battery, .schedule].contains(c.kind) ? kindTitle(c.kind) + ": " + value(c)
                : (c.negate ? String(format: L("Not: %@"), kindTitle(c.kind)) : kindTitle(c.kind))
        }
        let more = p.conditions.count > 3 ? " +\(p.conditions.count - 3)" : ""
        return parts.joined(separator: p.matchAll ? " · " : " | ") + more
    }

    static func seconds(_ s: Int) -> String {
        s <= 0 ? L("At once") : s < 60 ? String(format: L("%d s"), s) : Dur.short(minutes: s / 60)
    }
}
