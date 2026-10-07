// Keep-awake extras (the Lungo/Amphetamine round): "until a time", more Smart Triggers (VPN, CPU load, audio output, a
// mounted volume, a USB device), "keep awake while" a process runs or downloads are in progress, turn off when unplugged,
// pause while the screen is locked, turn on at launch, left-click toggles, menu-bar icon styles, start/stop notices.
// Pure logic here, every system reading behind AwakeProbe (tests give fixed values: --awake-test, Sources/AwakeTests.swift);
// Sources/AwakeCenter.swift wires it to the app, Sources/AwakePanel.swift draws its rows.
// Not built, on purpose: a Wi-Fi network trigger (macOS 14+ hides the network name from apps without Location Services) and
// a Bluetooth device trigger (IOBluetooth needs the Bluetooth permission); see docs/keep-awake.en.md.

import AppKit
import CoreAudio
import Darwin
import IOKit

// MARK: - Settings

extension Settings {
    var triggerVPN: Bool { get { flag("triggerVPN", false) } nonmutating set { d.set(newValue, forKey: "triggerVPN") } }
    /// "" (off) | "above" | "below": the CPU busier (or quieter) than `triggerCPUPercent` for `triggerCPUMinutes`.
    var triggerCPU: String { get { d.string(forKey: "triggerCPU") ?? "" } nonmutating set { d.set(newValue, forKey: "triggerCPU") } }
    var triggerCPUPercent: Int {
        get { CPURule.clampPercent(d.object(forKey: "triggerCPUPercent") as? Int ?? 50) }
        nonmutating set { d.set(CPURule.clampPercent(newValue), forKey: "triggerCPUPercent") }
    }
    var triggerCPUMinutes: Int {
        get { CPURule.clampMinutes(d.object(forKey: "triggerCPUMinutes") as? Int ?? 2) }
        nonmutating set { d.set(CPURule.clampMinutes(newValue), forKey: "triggerCPUMinutes") }
    }
    /// Audio outputs by name (part of it is enough: "AirPods"); on while the Mac's sound goes to one of them.
    var triggerAudio: [String] { get { AwakeLists.clean(d.stringArray(forKey: "triggerAudio")) } nonmutating set { d.set(AwakeLists.clean(newValue), forKey: "triggerAudio") } }
    var triggerVolumes: [String] { get { AwakeLists.clean(d.stringArray(forKey: "triggerVolumes")) } nonmutating set { d.set(AwakeLists.clean(newValue), forKey: "triggerVolumes") } }
    var triggerUSB: [String] { get { AwakeLists.clean(d.stringArray(forKey: "triggerUSB")) } nonmutating set { d.set(AwakeLists.clean(newValue), forKey: "triggerUSB") } }

    /// Turn Cocaine off when the charger is unplugged (also an ON made by hand): seconds after unplugging; 0 = never.
    var unplugOff: Int {
        get { UnplugGuard.choices.contains(d.object(forKey: "unplugOff") as? Int ?? 0) ? d.object(forKey: "unplugOff") as? Int ?? 0 : 0 }
        nonmutating set { d.set(UnplugGuard.choices.contains(newValue) ? newValue : 0, forKey: "unplugOff") }
    }
    /// Let the Mac sleep while the screen is locked; Cocaine comes back on at unlock (if its time isn't up).
    var lockPause: Bool { get { flag("lockPause", false) } nonmutating set { d.set(newValue, forKey: "lockPause") } }
    /// "always" (as before), "manual" (opened by hand, not as a login item) or "never".
    var launchTurnsOn: String {
        get { let v = d.string(forKey: "launchTurnsOn") ?? "always"; return LaunchPolicy.values.contains(v) ? v : "always" }
        nonmutating set { d.set(LaunchPolicy.values.contains(newValue) ? newValue : "always", forKey: "launchTurnsOn") }
    }
    /// A left click on the menu-bar icon turns Cocaine on or off; a right click (or ⌃-click) opens the panel.
    var leftClickToggles: Bool { get { flag("leftClickToggles", false) } nonmutating set { d.set(newValue, forKey: "leftClickToggles") } }
    var menuIcon: String {
        get { let v = d.string(forKey: "menuIcon") ?? "bag"; return MenuIconStyle.all.contains(v) ? v : "bag" }
        nonmutating set { d.set(MenuIconStyle.all.contains(newValue) ? newValue : "bag", forKey: "menuIcon") }
    }
    /// A short notice (island, VoiceOver) whenever Cocaine turns on or off by itself or from outside.
    var notifyChanges: Bool { get { flag("notifyChanges", false) } nonmutating set { d.set(newValue, forKey: "notifyChanges") } }
    /// "Keep awake while…": the process or the downloads being waited for (JSON of WhileTarget), kept across a restart.
    var whileTarget: WhileTarget? {
        get { d.data(forKey: "whileTarget").flatMap { try? JSONDecoder().decode(WhileTarget.self, from: $0) } }
        nonmutating set {
            if let v = newValue, let data = try? JSONEncoder().encode(v) { d.set(data, forKey: "whileTarget") } else { d.removeObject(forKey: "whileTarget") }
        }
    }

    /// The new triggers as one value (what AwakeTriggerSet reads).
    var awakeTriggers: AwakeTriggerConfig {
        AwakeTriggerConfig(vpn: triggerVPN, cpu: triggerCPU, cpuPercent: triggerCPUPercent, cpuMinutes: triggerCPUMinutes,
                           audio: triggerAudio, volumes: triggerVolumes, usb: triggerUSB)
    }
}

enum AwakeLists {
    /// Names kept short, without control characters, no empty or repeated ones, at most 20.
    static func clean(_ list: [String]?) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in list ?? [] {
            let s = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespaces)
            let v = String(s.prefix(80))
            guard !v.isEmpty, !seen.contains(v.lowercased()) else { continue }
            seen.insert(v.lowercased()); out.append(v)
            if out.count == 20 { break }
        }
        return out
    }

    /// A chosen name matches a present one: equal, or contained in it, ignoring case ("AirPods" matches "Mattia's AirPods Pro").
    static func matches(_ chosen: [String], _ present: [String]) -> Bool {
        let p = present.map { $0.lowercased() }
        return chosen.contains { c in let c = c.lowercased(); return p.contains { $0 == c || $0.contains(c) } }
    }
}

// MARK: - The new Smart Triggers

struct AwakeTriggerConfig: Equatable {
    var vpn = false
    var cpu = ""
    var cpuPercent = 50
    var cpuMinutes = 2
    var audio: [String] = []
    var volumes: [String] = []
    var usb: [String] = []

    /// How many are on (for "Any/All" and the panel).
    var count: Int { [vpn, !cpu.isEmpty, !audio.isEmpty, !volumes.isEmpty, !usb.isEmpty].filter { $0 }.count }
}

/// Everything the new triggers read from the Mac. The real one is SystemAwakeProbe; tests pass a fake.
protocol AwakeProbe {
    /// Network interfaces with their flags and addresses (getifaddrs).
    func interfaces() -> [NetInterface]
    /// The CPU's cumulative ticks (busy, total), or nil.
    func cpuTicks() -> CPUTicks?
    /// The default audio output's name, or nil.
    func defaultOutput() -> String?
    func mountedVolumes() -> [String]
    func usbDevices() -> [String]
}

struct NetInterface: Equatable {
    var name: String
    var up: Bool
    var ipv4: Bool              // has an IPv4 address
    var routableIPv6: Bool      // has an IPv6 address that isn't link-local (fe80::)
}

/// A VPN is connected: a tunnel interface (utun, ipsec, ppp, tun, tap, wg) that is up and has an address the Mac routes with.
/// macOS keeps a few utun interfaces of its own (iCloud Private Relay, Continuity…) with only link-local addresses: those don't count.
enum VPNRule {
    static let prefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]
    static func connected(_ list: [NetInterface]) -> Bool {
        list.contains { i in
            guard i.up, prefixes.contains(where: { i.name.hasPrefix($0) }) else { return false }
            let rest = i.name.drop(while: { $0.isLetter })
            return !rest.isEmpty && rest.allSatisfy(\.isNumber) && (i.ipv4 || i.routableIPv6)
        }
    }
}

struct CPUTicks: Equatable { var busy: UInt64; var total: UInt64 }

/// "CPU above (or below) X % for Y minutes": the load between samples, true once it has held that long without a break.
struct CPURule {
    static let percents = [10, 25, 50, 75]
    static let minutesChoices = [1, 2, 5, 10]
    static func clampPercent(_ p: Int) -> Int { min(95, max(5, p)) }
    static func clampMinutes(_ m: Int) -> Int { min(60, max(1, m)) }

    private(set) var last: CPUTicks?
    private(set) var since: Date?           // the start of the stretch that holds
    private(set) var load: Double?          // the last measured load, 0…1

    /// One sample (every few seconds). nil = not enabled.
    mutating func step(rule: String, percent: Int, minutes: Int, ticks: CPUTicks?, now: Date) -> Bool? {
        guard rule == "above" || rule == "below" else { last = nil; since = nil; return nil }
        guard let t = ticks else { since = nil; return false }
        defer { last = t }
        guard let l = last, t.total > l.total, t.busy >= l.busy else { return since.map { now.timeIntervalSince($0) >= Double(minutes) * 60 } ?? false }
        let v = Double(t.busy - l.busy) / Double(t.total - l.total)
        load = v
        let holds = rule == "above" ? v * 100 >= Double(percent) : v * 100 < Double(percent)
        if !holds { since = nil; return false }
        if since == nil { since = now }
        return now.timeIntervalSince(since!) >= Double(Self.clampMinutes(minutes)) * 60
    }
}

/// The new triggers' states for the arbiter (only the enabled ones), from one reading of the probe.
struct AwakeTriggerSet {
    var cpu = CPURule()

    mutating func states(_ c: AwakeTriggerConfig, probe: AwakeProbe, now: Date) -> [TriggerKind: Bool] {
        var s: [TriggerKind: Bool] = [:]
        if c.vpn { s[.vpn] = VPNRule.connected(probe.interfaces()) }
        if let v = cpu.step(rule: c.cpu, percent: c.cpuPercent, minutes: c.cpuMinutes, ticks: c.cpu.isEmpty ? nil : probe.cpuTicks(), now: now) { s[.cpu] = v }
        if !c.audio.isEmpty { s[.audio] = probe.defaultOutput().map { AwakeLists.matches(c.audio, [$0]) } ?? false }
        if !c.volumes.isEmpty { s[.volume] = AwakeLists.matches(c.volumes, probe.mountedVolumes()) }
        if !c.usb.isEmpty { s[.usb] = AwakeLists.matches(c.usb, probe.usbDevices()) }
        return s
    }

    /// The words for "Turned on by …" (the original triggers' words come from TriggerWords).
    static func words(_ states: [TriggerKind: Bool], _ c: AwakeTriggerConfig, probe: AwakeProbe?) -> [String] {
        var out: [String] = []
        if states[.vpn] == true { out.append(L("VPN")) }
        if states[.cpu] == true { out.append(c.cpu == "below" ? L("CPU quiet") : L("CPU busy")) }
        if states[.audio] == true { out.append(probe?.defaultOutput() ?? L("Audio output")) }
        if states[.volume] == true { out.append(c.volumes.first ?? L("Volume")) }
        if states[.usb] == true { out.append(c.usb.first ?? L("USB device")) }
        return out
    }
}

// MARK: - Keep awake while a process runs, or while downloads are in progress

/// What "keep awake while…" waits for. A process is known by its pid AND its start time, so a pid reused by another program
/// after the first one ended never keeps the Mac awake. `name` is what the panel shows.
struct WhileTarget: Codable, Equatable {
    enum Kind: String, Codable { case process, downloads }
    var kind: Kind
    var pid: Int32 = 0
    var started: UInt64 = 0          // the process's start (µs since 1970), from the kernel
    var name: String = ""
}

/// The session: ends `grace` after what it waits for is gone (a process: a moment, in case of a restart under the same pid…
/// not: a new pid never counts; downloads: a minute, between one file and the next).
struct WhileWatch {
    enum Step: Equatable { case none, end }
    private(set) var quietSince: Date?

    static func grace(_ k: WhileTarget.Kind) -> TimeInterval { k == .process ? 2 : 60 }

    mutating func step(alive: Bool, kind: WhileTarget.Kind, now: Date) -> Step {
        if alive { quietSince = nil; return .none }
        if quietSince == nil { quietSince = now }
        return now.timeIntervalSince(quietSince!) >= Self.grace(kind) ? .end : .none
    }

    mutating func reset() { quietSince = nil }
}

/// Downloads in progress in a folder: a partial file of a browser (.crdownload, .download, .part, .opdownload) or a file
/// that grew since the last look.
struct DownloadActivity {
    static let partial: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]
    private(set) var sizes: [String: Int64] = [:]

    struct Entry: Equatable { var name: String; var size: Int64 }

    /// One look at the folder (nil: it couldn't be read). True while something is downloading.
    mutating func sample(_ entries: [Entry]?) -> Bool? {
        guard let entries else { return nil }
        var grew = false, partialFound = false
        var next: [String: Int64] = [:]
        for e in entries.prefix(5000) {
            next[e.name] = e.size
            if Self.partial.contains((e.name as NSString).pathExtension.lowercased()) { partialFound = true }
            if let was = sizes[e.name], e.size > was { grew = true }
        }
        sizes = next
        return partialFound || grew
    }
}

/// A process the user can pick: its pid, name, start time.
struct ProcessPick: Equatable {
    var pid: Int32
    var name: String
    var started: UInt64
}

enum ProcessInfoReader {
    /// pid → (name, start time in µs) from the kernel; nil when there is no such process (or it can't be read).
    static func info(_ pid: Int32) -> ProcessPick? {
        guard pid > 0 else { return nil }
        var bsd = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard n == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        let name = withUnsafePointer(to: &bsd.pbi_name) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) * 2) { String(cString: $0) }
        }
        let comm = withUnsafePointer(to: &bsd.pbi_comm) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return ProcessPick(pid: pid, name: name.isEmpty ? comm : name, started: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec)
    }

    /// The same process still runs: same pid and same start time.
    static func alive(_ t: WhileTarget, lookup: (Int32) -> ProcessPick? = info) -> Bool {
        guard t.kind == .process, let p = lookup(t.pid) else { return false }
        return p.started == t.started
    }

    /// This user's processes, apps first (by name), for the picker. At most 200.
    static func pickable() -> [ProcessPick] {
        let me = getuid(), own = getpid()
        var out: [ProcessPick] = []
        for (pid, _) in ProcessList.all() where pid != own {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
                  bsd.pbi_uid == me, let p = info(pid) else { continue }
            out.append(p)
        }
        let apps = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        return Array(out.sorted { a, b in
            let (x, y) = (apps.contains(a.pid), apps.contains(b.pid))
            return x != y ? x : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }.prefix(200))
    }
}

// MARK: - Turn off when unplugged, pause while locked, launch, clicks, icons

/// "Turn off when the charger is unplugged": once per unplugging, `delay` seconds after it (a wiggled cable doesn't count),
/// whoever turned Cocaine on. A Mac already on battery when Cocaine starts saw no unplugging: nothing happens until it is
/// plugged in and out again. Turning Cocaine back on while still on battery is respected.
struct UnplugGuard {
    static let choices = [0, 10, 300, 900]   // 0 = off; 10 s = at once
    private(set) var lastAC: Bool?
    private(set) var unpluggedAt: Date?
    private(set) var fired = false

    mutating func step(delay: Int, onAC: Bool, on: Bool, now: Date) -> Bool {
        defer { lastAC = onAC }
        if onAC { unpluggedAt = nil; fired = false; return false }
        if lastAC == true { unpluggedAt = now; fired = false }      // just unplugged
        guard delay > 0, let at = unpluggedAt, !fired, now.timeIntervalSince(at) >= Double(delay) else { return false }
        fired = true
        return on
    }
}

/// "Pause while the screen is locked": at the lock Cocaine lets the Mac sleep, and no trigger turns it on while locked; at the
/// unlock an ON made by hand comes back (with what was left of its timer; not when that has run out meanwhile). An ON a trigger
/// made is the trigger's again: it comes back by itself if the trigger still holds.
struct LockPause {
    private(set) var locked = false
    private(set) var resumeOn = false
    private(set) var until: Date?

    enum Act: Equatable { case none, turnOff, turnOn(until: Date?) }

    mutating func lock(enabled: Bool, on: Bool, triggerOwned: Bool, until: Date?) -> Act {
        guard enabled, !locked else { return .none }
        locked = true
        resumeOn = on && !triggerOwned
        self.until = until
        return on ? .turnOff : .none
    }

    mutating func unlock(now: Date) -> Act {
        guard locked else { return .none }
        locked = false
        defer { resumeOn = false; until = nil }
        guard resumeOn else { return .none }
        if let u = until, u <= now { return .none }
        return .turnOn(until: until)
    }

    /// Cocaine was turned on or off from outside while locked (the iPhone, `cocaine on`): that wins, nothing comes back later.
    mutating func userChanged() { resumeOn = false; until = nil }

    /// Triggers wait while it is locked.
    var blocksTriggers: Bool { locked }
}

/// Whether opening the app turns Cocaine on.
enum LaunchPolicy {
    static let values = ["always", "manual", "never"]
    static func turnOn(_ policy: String, atLogin: Bool, alreadyOn: Bool, pendingLinks: Bool) -> Bool {
        guard !alreadyOn, !pendingLinks else { return false }     // a link that started the app decides by itself
        switch policy {
        case "never": return false
        case "manual": return !atLogin
        default: return true
        }
    }

    /// The launch Apple event says "opened as a login item".
    static func launchedAtLogin(_ e: NSAppleEventDescriptor?) -> Bool {
        guard let e, e.eventID == kAEOpenApplication else { return false }
        return e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// A click on the menu-bar icon.
enum StatusClick {
    enum Act: Equatable { case toggle, panel }
    static func act(leftToggles: Bool, right: Bool, control: Bool, panelOpen: Bool) -> Act {
        guard leftToggles, !right, !control, !panelOpen else { return .panel }   // an open panel: the click closes it
        return .toggle
    }
}

/// The menu-bar icon: the baggie (default) or a plain symbol, outline when off and filled when on. The island is unaffected.
enum MenuIconStyle {
    static let all = ["bag", "cup", "bolt", "eye", "dot"]
    static func symbol(_ style: String, on: Bool) -> String? {
        switch style {
        case "cup": return on ? "cup.and.saucer.fill" : "cup.and.saucer"
        case "bolt": return on ? "bolt.fill" : "bolt.slash"
        case "eye": return on ? "eye.fill" : "eye.slash"
        case "dot": return on ? "circle.fill" : "circle"
        default: return nil
        }
    }

    static func name(_ style: String) -> String {
        switch style {
        case "cup": return L("Cup")
        case "bolt": return L("Bolt")
        case "eye": return L("Eye")
        case "dot": return L("Dot")
        default: return L("Baggie")
        }
    }

    static func image(_ style: String, on: Bool) -> NSImage? {
        guard let s = symbol(style, on: on),
              let i = NSImage(systemSymbolName: s, accessibilityDescription: on ? L("Cocaine is on") : L("Cocaine is off"))?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) else { return nil }
        i.isTemplate = true
        return i
    }
}

/// When a change of state gets a notice: only with the option on, never for the first reading.
enum ChangeNotice {
    static func text(on: Bool, reason: String?) -> String {
        let base = on ? L("Cocaine is on") : L("Cocaine is off")
        guard let reason, !reason.isEmpty else { return base }
        return base + " · " + reason
    }
}

// MARK: - The real readings

struct SystemAwakeProbe: AwakeProbe {
    func interfaces() -> [NetInterface] {
        var list: [String: NetInterface] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            let name = String(cString: a.pointee.ifa_name)
            let flags = Int32(a.pointee.ifa_flags)
            var i = list[name] ?? NetInterface(name: name, up: (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0, ipv4: false, routableIPv6: false)
            if let sa = a.pointee.ifa_addr {
                if sa.pointee.sa_family == UInt8(AF_INET) { i.ipv4 = true }
                if sa.pointee.sa_family == UInt8(AF_INET6) {
                    let linkLocal = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s6 -> Bool in
                        let b = s6.pointee.sin6_addr.__u6_addr.__u6_addr8
                        return b.0 == 0xfe && (b.1 & 0xc0) == 0x80
                    }
                    if !linkLocal { i.routableIPv6 = true }
                }
            }
            list[name] = i
            p = a.pointee.ifa_next
        }
        return Array(list.values)
    }

    func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks   // user, system, idle, nice
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        return CPUTicks(busy: busy, total: busy + UInt64(t.2))
    }

    func defaultOutput() -> String? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return Self.deviceName(id)
    }

    /// Every output device's name (for the picker).
    static func outputNames() -> [String] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                               mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr && s > 0
        }.compactMap(deviceName)
    }

    static func deviceName(_ id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() else { return nil }
        return n as String
    }

    func mountedVolumes() -> [String] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeIsRootFileSystemKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: [.volumeNameKey, .volumeIsRootFileSystemKey])
            return v?.volumeIsRootFileSystem == true ? nil : v?.volumeName
        }
    }

    func usbDevices() -> [String] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [String] = []
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            if let n = IORegistryEntryCreateCFProperty(s, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                out.append(n)
            } else {
                var buf = [CChar](repeating: 0, count: 128)
                if IORegistryEntryGetName(s, &buf) == KERN_SUCCESS { out.append(String(cString: buf)) }
            }
            if out.count >= 100 { break }
        }
        return Array(Set(out)).sorted()
    }

    /// One look at ~/Downloads (its top level). nil when it can't be read (Files permission).
    static func downloads(_ dir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) -> [DownloadActivity.Entry]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.prefix(5000).map { n in
            let a = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path)
            return DownloadActivity.Entry(name: n, size: (a?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}
