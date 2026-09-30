// Cocaine — menu-bar front end for ~/bin/cocaine.
//
// Shows whether Cocaine is on (full baggie) or off (empty baggie) in the menu bar; clicking it opens a
// panel that stays open while you change things. It toggles Cocaine through the engine script bundled in
// Contents/Resources/cocaine, which owns the caffeinate -d display hold; the first time it needs to, the app
// asks for an admin password once to install a narrow sudo rule for `pmset -a disablesleep 1|0`. While Cocaine is
// on it restarts that display hold if it is missing (e.g. after a restart) and, after the chosen
// idle time, lowers the built-in display to the chosen minimum brightness (never below 1%, so the
// screen never goes off), restoring the previous brightness on the next keyboard/trackpad input.
// `cocaine://alert` URLs (from AI agents' hooks, which the "AI alerts" switch adds to Claude Code and Codex) wake and
// flash the screens when you're away.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Darwin
import ImageIO
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Security
import ServiceManagement
import SwiftUI
import os

private let log = Logger(subsystem: "local.cocaine.toggle", category: "app")
private let scriptPath = Bundle.main.path(forResource: "cocaine", ofType: nil) ?? "/nonexistent/cocaine"
private let anyInput = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType

/// The UI language: the Mac's (the default; English when it isn't one of ours) or one picked in the panel.
private enum Language {
    static let codes = ["en", "it", "zh-Hans", "zh-Hant", "es", "fr", "de", "ja"]
    private static var bundle = makeBundle(UserDefaults.standard.string(forKey: "language"))

    /// nil = same as the Mac.
    static var chosen: String? { UserDefaults.standard.string(forKey: "language") }

    static func set(_ code: String?, persist: Bool = true) {
        if persist {
            if let code { UserDefaults.standard.set(code, forKey: "language") }
            else { UserDefaults.standard.removeObject(forKey: "language") }
        }
        bundle = makeBundle(code)
    }

    private static func makeBundle(_ code: String?) -> Bundle {
        guard let code, let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path)
        else { return .main }                        // .main follows the Mac's languages, English as fallback
        return b
    }

    /// Flag shown on the language button; both Chinese scripts use China's flag (the menu tells them apart by name).
    static func flag(_ code: String) -> String {
        ["en": "🇬🇧", "it": "🇮🇹", "zh-Hans": "🇨🇳", "zh-Hant": "🇨🇳", "es": "🇪🇸", "fr": "🇫🇷", "de": "🇩🇪", "ja": "🇯🇵"][code] ?? "🌐"
    }

    /// The language actually in use when following the Mac (English if the Mac's isn't one of ours).
    static var system: String {
        let first = Bundle.main.preferredLocalizations.first ?? "en"
        return codes.contains(first) ? first : "en"
    }

    /// A language's name written in that language, e.g. "Deutsch", "日本語".
    static func nativeName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
    }

    static func text(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
}

/// The app's version as shown in the panel (CFBundleShortVersionString).
private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

/// UI text in the current language (Localization/*.lproj).
private func L(_ key: String) -> String { Language.text(key) }

@discardableResult
private func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// Runs the bundled engine (`on`, `off`, …) and returns its exit status: 0 ok, 2 not authorized yet.
@discardableResult
private func engine(_ arg: String) -> Int32 { run("/bin/zsh", [scriptPath, arg]) }

// MARK: - System state

private enum System {
    private static func rootDomainFlag(_ key: String) -> Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        return (IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }
    /// The pmset `disablesleep` flag the cocaine script sets.
    static var cocaineOn: Bool { rootDomainFlag("SleepDisabled") }
    static var lidClosed: Bool { rootDomainFlag("AppleClamshellState") }
    /// The script's display helper, matched by its exact argv just like the script does.
    static var displayHeld: Bool {
        let literal = scriptPath.replacingOccurrences(of: "([\\[\\]\\\\.^$*+?(){}|])", with: "\\\\$1",
                                                      options: .regularExpression)
        return run("/usr/bin/pgrep", ["-U", String(getuid()), "-xf", "/bin/zsh \(literal) hold"]) == 0
    }
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

// MARK: - One-time authorization (sudo rule)

private enum Authorization {
    static let rulePath = "/etc/sudoers.d/cocaine"

    /// Shell command that installs the NOPASSWD rule for `user` — validated with visudo before it is put in place,
    /// so a bad rule can never break sudo. `asRoot: false` + another `dest` is for the self-test only.
    static func installCommand(user: String, dest: String = rulePath, asRoot: Bool = true) -> String? {
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        // pmset on/off, plus removing this very rule, so uninstalling needs no password.
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, "
            + "/bin/rm -f \(rulePath)"
        let owner = asRoot ? "-o root -g wheel " : ""
        return "t=$(/usr/bin/mktemp /tmp/cocaine.XXXXXX) || exit 1; /usr/bin/printf '%s\\n' '\(rule)' > \"$t\"; "
            + "/usr/sbin/visudo -cf \"$t\" >/dev/null || { /bin/rm -f \"$t\"; exit 1; }; "
            + "/usr/bin/install -m 0440 \(owner)\"$t\" '\(dest)'; r=$?; /bin/rm -f \"$t\"; exit $r"
    }

    static func appleScript(for command: String, admin: Bool) -> String {   // only for --auth-selftest
        let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(quoted)\"" + (admin ? " with administrator privileges" : "")
    }

    /// Shows the standard macOS admin prompt ("Cocaine wants to make changes", Touch ID or password) and installs
    /// the rule. True on success.
    static func install() -> Bool {
        guard let cmd = installCommand(user: NSUserName()) else { return false }
        return runAsRoot(cmd, prompt: L("Cocaine needs your permission once, to keep your Mac awake."))
    }

    /// Removes the rule (used by the Homebrew uninstall when the rule predates self-removal).
    static func remove() -> Bool {
        runAsRoot("/bin/rm -f \(rulePath)", prompt: L("Cocaine is removing its permission."))
    }

    /// Asks for admin rights through Authorization Services; with `execute: false` it only shows the prompt.
    static func authorize(prompt: String, then body: (AuthorizationRef) -> Bool) -> Bool {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let auth = ref else { return false }
        defer { AuthorizationFree(auth, [.destroyRights]) }
        // Every C string handed to Authorization Services must stay alive for the whole call.
        let status: OSStatus = kAuthorizationRightExecute.withCString { right in
            kAuthorizationEnvironmentPrompt.withCString { promptKey in
                prompt.withCString { text in
                    var rightItem = AuthorizationItem(name: right, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(name: promptKey, valueLength: strlen(text),
                                                       value: UnsafeMutableRawPointer(mutating: text), flags: 0)
                    return withUnsafeMutablePointer(to: &rightItem) { rightPtr in
                        withUnsafeMutablePointer(to: &promptItem) { promptPtr in
                            var rights = AuthorizationRights(count: 1, items: rightPtr)
                            var env = AuthorizationEnvironment(count: 1, items: promptPtr)
                            return AuthorizationCopyRights(auth, &rights, &env,
                                                           [.interactionAllowed, .extendRights, .preAuthorize], nil)
                        }
                    }
                }
            }
        }
        return status == errAuthorizationSuccess && body(auth)
    }

    /// Runs `/bin/sh -c command` as root. AuthorizationExecuteWithPrivileges is deprecated and hidden from Swift,
    /// but it's still the only way to run one command as root without a paid-developer-signed helper.
    static func runAsRoot(_ command: String, prompt: String) -> Bool {
        typealias AEWP = @convention(c) (AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
                                         UnsafePointer<UnsafeMutablePointer<CChar>?>,
                                         UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?) -> OSStatus
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(security, "AuthorizationExecuteWithPrivileges") else { return false }
        let execute = unsafeBitCast(sym, to: AEWP.self)
        return authorize(prompt: prompt) { auth in
            // The command reports its own exit code on stdout, since AEWP doesn't hand back the child's status.
            let args: [UnsafeMutablePointer<CChar>?] = [strdup("-c"), strdup(command + "; echo \"rc=$?\""), nil]
            defer { args.forEach { free($0) } }
            var pipe: UnsafeMutablePointer<FILE>?
            let rc = args.withUnsafeBufferPointer { execute(auth, "/bin/sh", [], $0.baseAddress!, &pipe) }
            guard rc == errAuthorizationSuccess, let pipe else { return false }
            var output = ""
            var buffer = [CChar](repeating: 0, count: 256)
            while fgets(&buffer, 256, pipe) != nil { output += String(cString: buffer) }
            fclose(pipe)
            return output.contains("rc=0")
        }
    }
}

// MARK: - Screen dimming (every display)

/// Dims every screen. The built-in panel and Apple displays go through DisplayServices (the real backlight); any
/// other monitor is dimmed through its gamma table, which macOS restores by itself if the app quits or crashes.
private final class Screens {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    private var getFn: GetFn?, setFn: SetFn?, canFn: CanFn?

    init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        else { return }
        getFn = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        setFn = dlsym(h, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
        canFn = dlsym(h, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanFn.self) }
    }

    var online: [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n)))
    }

    func hasBacklight(_ d: CGDirectDisplayID) -> Bool { canFn?(d) ?? false }

    func brightness(_ d: CGDirectDisplayID) -> Float? {
        guard let get = getFn else { return nil }
        var b: Float = 0
        return get(d, &b) == 0 ? b : nil
    }

    /// Never below 1%: dimmed, not off.
    func setBrightness(_ d: CGDirectDisplayID, _ v: Float) { _ = setFn?(d, min(max(v, 0.01), 1)) }

    /// Software dimming for monitors without a controllable backlight: 1 = normal, lower = darker.
    func setGamma(_ d: CGDirectDisplayID, _ scale: Float) {
        CGSetDisplayTransferByFormula(d, 0, scale, 1, 0, scale, 1, 0, scale, 1)
    }

    func restoreGamma() { CGDisplayRestoreColorSyncSettings() }
}

/// What one dim changes on each screen, so it can be faded in and out and undone exactly.
private struct DimPlan {
    struct Backlit { let id: CGDirectDisplayID; let from: Float; let to: Float }
    var backlit: [Backlit] = []
    var gamma: [(id: CGDirectDisplayID, to: Float)] = []
    var displays: Set<CGDirectDisplayID> { Set(backlit.map(\.id) + gamma.map(\.id)) }
}

// MARK: - Settings

/// One alert, for the "Recent alerts" list.
private struct AlertRecord: Codable, Identifiable, Equatable {
    let from: String
    let message: String
    let project: String?
    let at: Date
    var id: Date { at }
}

private struct Settings {
    private let d = UserDefaults.standard
    static let delayChoices = [1, 2, 5, 10, 15, 30]   // minutes

    var dimEnabled: Bool {
        get { d.object(forKey: "dimEnabled") as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: "dimEnabled") }
    }
    /// 0.01…0.50; the default is about the lowest brightness-key step (1/16).
    var level: Float {
        get { Float(d.object(forKey: "dimLevel") as? Double ?? 0.06) }
        nonmutating set { d.set(Double(newValue), forKey: "dimLevel") }
    }
    /// Idle time before dimming, in seconds.
    var delay: Double {
        get { d.object(forKey: "dimDelaySeconds") as? Double ?? 120 }
        nonmutating set { d.set(newValue, forKey: "dimDelaySeconds") }
    }
    // AI alerts: what to announce and how.
    static let sounds = ["Glass", "Ping", "Hero", "Submarine", "Funk", "Purr", "Blow"]
    private func flag(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
    var alertDone: Bool { get { flag("alertDone", true) } nonmutating set { d.set(newValue, forKey: "alertDone") } }
    var alertInput: Bool { get { flag("alertInput", true) } nonmutating set { d.set(newValue, forKey: "alertInput") } }
    var alertFlash: Bool { get { flag("alertFlash", true) } nonmutating set { d.set(newValue, forKey: "alertFlash") } }
    var alertSpeak: Bool { get { flag("alertSpeak", false) } nonmutating set { d.set(newValue, forKey: "alertSpeak") } }
    /// The voice that reads alerts (an AVSpeechSynthesisVoice identifier); "" = the language's default.
    var alertVoice: String { get { d.string(forKey: "alertVoice") ?? "" } nonmutating set { d.set(newValue, forKey: "alertVoice") } }
    /// One alert per session: hold "finished" until the session's agents are done and it has been quiet a while.
    var alertPerSession: Bool { get { flag("alertPerSession", false) } nonmutating set { d.set(newValue, forKey: "alertPerSession") } }
    var alertWhenPresent: Bool { get { flag("alertWhenPresent", false) } nonmutating set { d.set(newValue, forKey: "alertWhenPresent") } }
    static let repeatChoices = [0, 2, 5, 10]          // minutes; 0 = never
    static let durationChoices: [Double] = [5, 15, 0]  // seconds on screen; 0 = until you're back
    /// Minutes between reminders while you're away (0 = none). 1.7.3 had an on/off "every 5 minutes".
    var alertRepeatMinutes: Int {
        get { d.object(forKey: "alertRepeatMinutes") as? Int ?? (flag("alertRepeat", false) ? 5 : 0) }
        nonmutating set { d.set(newValue, forKey: "alertRepeatMinutes") }
    }
    var alertDuration: Double {
        get { d.object(forKey: "alertDuration") as? Double ?? 5 }
        nonmutating set { d.set(newValue, forKey: "alertDuration") }
    }
    /// The latest alerts, newest first (at most 10).
    var alertHistory: [AlertRecord] {
        get { (d.data(forKey: "alertHistory")).flatMap { try? JSONDecoder().decode([AlertRecord].self, from: $0) } ?? [] }
        nonmutating set { d.set(try? JSONEncoder().encode(Array(newValue.prefix(10))), forKey: "alertHistory") }
    }
    /// A system sound's name; "" = silent.
    var alertSound: String {
        get { d.string(forKey: "alertSound") ?? "Glass" }
        nonmutating set { d.set(newValue, forKey: "alertSound") }
    }
    var alertsPausedUntil: Date? {
        get { (d.object(forKey: "alertsPausedUntil") as? Date).flatMap { $0 > Date() ? $0 : nil } }
        nonmutating set { d.set(newValue, forKey: "alertsPausedUntil") }
    }

    /// Brightness to put back, per display, if the app quit or crashed while screens were lowered.
    var savedBrightness: [CGDirectDisplayID: Float] {
        get {
            (d.dictionary(forKey: "savedBrightnesses") as? [String: Double] ?? [:]).reduce(into: [:]) { out, kv in
                if let id = CGDirectDisplayID(kv.key) { out[id] = Float(kv.value) }
            }
        }
        nonmutating set {
            if newValue.isEmpty { d.removeObject(forKey: "savedBrightnesses"); return }
            d.set(Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), Double($0.value)) }), forKey: "savedBrightnesses")
        }
    }
}

// MARK: - Automation: timer, battery guard, smart triggers, agent states, hotkeys, phone alerts

private extension Settings {
    static let timerChoices = [0, 30, 60, 120, 240, 480]        // minutes Cocaine stays on when turned on by hand; 0 = until turned off
    static let batteryChoices = [0, 10, 15, 20, 30]             // % at which to act on battery; 0 = off

    var timerMinutes: Int { get { d.object(forKey: "timerMinutes") as? Int ?? 0 } nonmutating set { d.set(newValue, forKey: "timerMinutes") } }
    /// When Cocaine turns itself off (also set by `cocaine remote on --for …`).
    var onUntil: Date? {
        get { let v = d.double(forKey: "onUntil"); return v > 0 ? Date(timeIntervalSince1970: v) : nil }
        nonmutating set { if let n = newValue { d.set(n.timeIntervalSince1970, forKey: "onUntil") } else { d.removeObject(forKey: "onUntil") } }
    }
    var batteryThreshold: Int { get { d.object(forKey: "batteryThreshold") as? Int ?? 0 } nonmutating set { d.set(newValue, forKey: "batteryThreshold") } }
    var batteryTurnsOff: Bool { get { flag("batteryTurnsOff", true) } nonmutating set { d.set(newValue, forKey: "batteryTurnsOff") } }
    var triggerAgents: Bool { get { flag("triggerAgents", false) } nonmutating set { d.set(newValue, forKey: "triggerAgents") } }
    var triggerApps: [String] { get { d.stringArray(forKey: "triggerApps") ?? [] } nonmutating set { d.set(newValue, forKey: "triggerApps") } }
    var hotkeys: Bool { get { flag("hotkeys", false) } nonmutating set { d.set(newValue, forKey: "hotkeys") } }
    /// A random value the app keeps for its own tools (`cocaine remote notify test`); URLs need it for `test=` flags.
    var testToken: String {
        if let t = d.string(forKey: "testToken") { return t }
        let t = UUID().uuidString
        d.set(t, forKey: "testToken")
        return t
    }
    var alertError: Bool { get { flag("alertError", true) } nonmutating set { d.set(newValue, forKey: "alertError") } }
    /// Phone alerts: a Shortcut to run (given the alert text) and/or an ntfy topic URL. Set with `cocaine remote notify`.
    var phoneShortcut: String { d.string(forKey: "phoneShortcut") ?? "" }
    var phoneNtfy: String { d.string(forKey: "phoneNtfy") ?? "" }
}

/// Battery Guard: fires once when the battery (on battery power) reaches the threshold, and re-arms when it recovers.
private struct BatteryGuard {
    var tripped = false

    mutating func check(percent: Int, onAC: Bool, threshold: Int) -> Bool {
        guard threshold > 0 else { tripped = false; return false }
        if onAC || percent > threshold + 3 { tripped = false; return false }
        if percent <= threshold && !tripped { tripped = true; return true }
        return false
    }
}

/// Smart Triggers: turns Cocaine on when something wants the Mac awake, and off again a while after it stops, but only
/// if the trigger (not the user) turned it on; a user who turns it off while a trigger is active is not overruled.
private struct AutoOn {
    enum Step { case none, turnOn, turnOff }
    var owned = false                  // Cocaine is on because a trigger turned it on
    var suppressed = false             // the user said no while a trigger was active
    var lastActive = Date.distantPast

    mutating func step(active: Bool, isOn: Bool, now: Date, grace: TimeInterval = 180) -> Step {
        if active {
            lastActive = now
            if !isOn && !suppressed { owned = true; return .turnOn }
            return .none
        }
        suppressed = false
        if owned {
            if !isOn { owned = false; return .none }
            if now.timeIntervalSince(lastActive) >= grace { owned = false; return .turnOff }
        }
        return .none
    }

    mutating func userToggled(to on: Bool, triggerActive: Bool) {
        owned = false
        if !on && triggerActive { suppressed = true }
    }
}

/// What the hooks say each AI session is doing: working, waiting for you, done, or failed. Written to a file the
/// `cocaine remote status` command reads.
private struct AgentEntry: Codable, Identifiable, Equatable {
    var id: String
    var from: String
    var project: String?
    var state: String            // working | waiting | done | error
    var since: Double
    var isLive: Bool { state == "working" || state == "waiting" }
}

private final class AgentBoard {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cocaine", isDirectory: true)
    static let file = directory.appendingPathComponent("state.json")
    private(set) var entries: [AgentEntry] = []

    /// Records a session's new state (its time restarts only when the state changes).
    func set(_ id: String, from: String, project: String?, state: String, now: Date = Date()) {
        if let i = entries.firstIndex(where: { $0.id == id }) {
            if entries[i].state != state { entries[i].since = now.timeIntervalSince1970 }
            entries[i].state = state; entries[i].from = from; entries[i].project = project
        } else {
            entries.append(AgentEntry(id: id, from: from, project: project, state: state, since: now.timeIntervalSince1970))
        }
        prune(now)
    }

    /// Finished and failed ones fade after 30 minutes; a "working" nobody has updated for 2 hours is stale.
    func prune(_ now: Date = Date()) {
        let t = now.timeIntervalSince1970
        entries.removeAll { t - $0.since > 6 * 3600 || (!$0.isLive && t - $0.since > 1800) || ($0.state == "working" && t - $0.since > 7200) }
        entries.sort { $0.since > $1.since }
    }

    /// Something is working or waiting for the user.
    func anyLive(_ now: Date = Date()) -> Bool { entries.contains { $0.isLive && now.timeIntervalSince1970 - $0.since < 7200 } }

    func write(cocaineOn: Bool, until: Date?) {
        struct Snapshot: Codable { var updated: Double; var cocaine: String; var until: Double?; var agents: [AgentEntry] }
        let snap = Snapshot(updated: Date().timeIntervalSince1970, cocaine: cocaineOn ? "ON" : "OFF",
                            until: until?.timeIntervalSince1970, agents: entries)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: Self.file, options: .atomic) }
    }
}

private extension System {
    /// Charge and power source of the internal battery; nil on a Mac without one.
    static var battery: (percent: Int, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (cur * 100 / max, (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }

    /// Names of every running process and app, lowercased (what a Smart Trigger matches against).
    static func runningNames() -> Set<String> {
        var names = Set<String>()
        let count = proc_listallpids(nil, 0)
        if count > 0 {
            var pids = [pid_t](repeating: 0, count: Int(count) + 64)
            let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            var buf = [CChar](repeating: 0, count: 256)
            for pid in pids.prefix(Int(n)) where pid > 0 {
                if proc_name(pid, &buf, UInt32(buf.count)) > 0 { names.insert(String(cString: buf).lowercased()) }
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            if let n = app.localizedName { names.insert(n.lowercased()) }
            if let n = app.bundleURL?.deletingPathExtension().lastPathComponent { names.insert(n.lowercased()) }
        }
        return names
    }

    /// Regular apps the user can pick as a trigger, by name.
    static func runningAppNames() -> [String] {
        Array(Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)))
            .filter { $0 != "Cocaine" }.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Whether anything is listening for SSH on this Mac (System Settings → General → Sharing → Remote Login).
    static var sshOn: Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(22).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }
}

// MARK: Global hotkeys (⌃⌥⌘ + letter): Carbon's RegisterEventHotKey needs no privacy permission

private var hotkeyHandler: ((UInt32) -> Void)?

private final class Hotkeys {
    static let keys: [(id: UInt32, code: UInt32, label: String)] = [(1, 8, "C"), (2, 31, "O"), (3, 35, "P")]   // toggle, panel, pause
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    func set(enabled: Bool, action: @escaping (UInt32) -> Void) {
        refs.forEach { if let r = $0 { UnregisterEventHotKey(r) } }
        refs = []
        guard enabled else { return }
        hotkeyHandler = action
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async { hotkeyHandler?(hk.id) }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        for k in Self.keys {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(k.code, UInt32(cmdKey | optionKey | controlKey), EventHotKeyID(signature: OSType(0x434F4341), id: k.id),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}

// MARK: - The iPhone Shortcut: a menu that runs Cocaine's remote commands over SSH

private enum PhoneShortcut {
    /// `MacBook-Pro-di-Mattia.local`: the name an iPhone on the same network (or VPN) reaches this Mac by.
    static var host: String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        p.arguments = ["--get", "LocalHostName"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var name = ""
        if (try? p.run()) != nil {
            name = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            p.waitUntilExit()
        }
        if name.isEmpty { name = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "") }
        return name + ".local"
    }

    /// The shortcut as an (unsigned) property list. Sign it before sharing: an iPhone refuses unsigned files.
    static func build(user: String, host: String, command: String) -> Data? {
        func uuid() -> String { UUID().uuidString }
        func action(_ id: String, _ params: [String: Any]) -> [String: Any] {
            ["WFWorkflowActionIdentifier": "is.workflow.actions.\(id)", "WFWorkflowActionParameters": params]
        }
        func token(_ output: String, _ name: String) -> [String: Any] {   // "the result of that action" as text
            ["Value": ["string": "\u{FFFC}", "attachmentsByRange": ["{0, 1}": ["OutputUUID": output, "Type": "ActionOutput", "OutputName": name]]],
             "WFSerializationType": "WFTextTokenString"]
        }
        let items: [(title: String, args: String)] = [
            (L("Status"), "status"), (L("Turn on"), "on"), (L("Turn off"), "off"), (L("Projects"), "projects"),
        ]
        let group = uuid()
        var actions: [[String: Any]] = [
            action("choosefrommenu", ["GroupingIdentifier": group, "WFControlFlowMode": 0, "WFMenuPrompt": "Cocaine",
                                      "WFMenuItems": items.map(\.title)]),
        ]
        for item in items {
            let ssh = uuid()
            actions.append(action("choosefrommenu", ["GroupingIdentifier": group, "WFControlFlowMode": 1, "WFMenuItemTitle": item.title]))
            actions.append(action("runsshscript", [
                "UUID": ssh, "WFSSHHost": host, "WFSSHPort": "22", "WFSSHUser": user, "WFSSHAuthenticationType": "Password",
                "WFSSHPassword": "", "WFSSHScript": "\(command) remote \(item.args)",
            ]))
            actions.append(action("showresult", ["Text": token(ssh, "Shell Script Result")]))
        }
        actions.append(action("choosefrommenu", ["GroupingIdentifier": group, "WFControlFlowMode": 2]))
        let plist: [String: Any] = [
            "WFWorkflowClientVersion": "900", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientRelease": 900,
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowActions": actions, "WFWorkflowInputContentItemClasses": [String](), "WFWorkflowTypes": [String](),
            "WFWorkflowImportQuestions": [Any](),
        ]
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    /// Builds and signs `Cocaine.shortcut` in a temporary folder; nil if signing fails (it needs to be online, and
    /// signed in to iCloud).
    static func signedFile() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-shortcut-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let raw = dir.appendingPathComponent("raw.shortcut"), out = dir.appendingPathComponent("Cocaine.shortcut")
        guard let data = build(user: NSUserName(), host: host, command: scriptPath), (try? data.write(to: raw)) != nil,
              run("/usr/bin/shortcuts", ["sign", "--mode", "people-who-know-me", "--input", raw.path, "--output", out.path]) == 0,
              FileManager.default.fileExists(atPath: out.path) else { return nil }
        try? FileManager.default.removeItem(at: raw)
        return out
    }
}

// MARK: Phone alerts: a Shortcut and/or an ntfy topic

private enum Phone {
    static var configured: Bool { let s = Settings(); return !s.phoneShortcut.isEmpty || !s.phoneNtfy.isEmpty }

    static var summary: String {
        let s = Settings()
        var parts: [String] = []
        if !s.phoneShortcut.isEmpty { parts.append("\(L("Shortcut")) “\(s.phoneShortcut)”") }
        if !s.phoneNtfy.isEmpty { parts.append("ntfy") }
        return parts.isEmpty ? L("Not set up") : parts.joined(separator: " + ")
    }

    /// Sends the alert text to the phone. The Shortcut runs with the text as its input (build one that messages you);
    /// ntfy posts it to the topic, so the text leaves the Mac: only used when the user set that topic.
    static func send(_ text: String) {
        let s = Settings()
        DispatchQueue.global().async {
            if !s.phoneShortcut.isEmpty {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-\(UUID().uuidString).txt")
                if (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil {
                    run("/usr/bin/shortcuts", ["run", s.phoneShortcut, "--input-path", file.path])
                    try? FileManager.default.removeItem(at: file)
                }
            }
            if s.phoneNtfy.hasPrefix("https://") {
                run("/usr/bin/curl", ["-sS", "-m", "10", "-H", "Title: Cocaine", "--data-raw", text, s.phoneNtfy])
            }
        }
    }
}

// MARK: - Baggie glyph

private enum Baggie {
    struct Palette {
        var outline: NSColor
        var fill: NSColor
        var powder: NSColor
        var powderEdge: NSColor?
    }

    /// Draws a see-through zip-lock baggie on an 18×18 grid scaled into `rect`. `level` (0…1) is how full
    /// it is: the powder heap grows from a small pile in the middle to fill the bottom. `pouring` adds a
    /// thin stream of powder falling from the top, used while it fills.
    static func draw(in rect: NSRect, level: CGFloat, pouring: Bool = false, palette: Palette) {
        let s = rect.width / 18
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * s, y: rect.minY + y * s) }

        // Bag: square-cut top, rounded bottom.
        let (l, r, b, t, rb, rt): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (2.9, 15.1, 1.4, 16.2, 2.6, 0.7)
        let bag = NSBezierPath()
        bag.move(to: p(l, t - rt))
        bag.line(to: p(l, b + rb))
        bag.curve(to: p(l + rb, b), controlPoint1: p(l, b + rb * 0.45), controlPoint2: p(l + rb * 0.45, b))
        bag.line(to: p(r - rb, b))
        bag.curve(to: p(r, b + rb), controlPoint1: p(r - rb * 0.45, b), controlPoint2: p(r, b + rb * 0.45))
        bag.line(to: p(r, t - rt))
        bag.curve(to: p(r - rt, t), controlPoint1: p(r, t - rt * 0.45), controlPoint2: p(r - rt * 0.45, t))
        bag.line(to: p(l + rt, t))
        bag.curve(to: p(l, t - rt), controlPoint1: p(l + rt * 0.45, t), controlPoint2: p(l, t - rt * 0.45))
        bag.close()
        palette.fill.setFill()
        bag.fill()
        palette.outline.setStroke()
        bag.lineWidth = 1.25 * s
        bag.lineJoinStyle = .round
        bag.stroke()

        // Zip seal: the double line that makes it read as a zip-lock bag.
        for y in [13.6, 11.9] as [CGFloat] {
            let zip = NSBezierPath()
            zip.move(to: p(l, y))
            zip.line(to: p(r, y))
            zip.lineWidth = 1.0 * s
            zip.stroke()
        }

        let level = min(max(level, 0), 1)
        guard level > 0.01 else { return }
        // Powder: a soft heap on the bottom, slumped a little to one side, scaled around the bottom centre.
        let base: CGFloat = 2.8, cx: CGFloat = 9
        let sx = 0.35 + 0.65 * level, sy = level
        func h(_ x: CGFloat, _ y: CGFloat) -> NSPoint { p(cx + (x - cx) * sx, base + (y - base) * sy) }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 4.3 * s, y: rect.minY + 2.8 * s, width: 9.4 * s, height: 8.0 * s),
                     xRadius: 1.5 * s, yRadius: 1.5 * s).addClip()
        let heap = NSBezierPath()
        heap.move(to: h(3, 0))
        heap.line(to: h(3, 7.3))
        heap.curve(to: h(8.2, 9.5), controlPoint1: h(4.6, 8.3), controlPoint2: h(6.4, 9.5))
        heap.curve(to: h(15, 6.1), controlPoint1: h(10.6, 9.5), controlPoint2: h(12.8, 7.1))
        heap.line(to: h(15, 0))
        heap.close()
        palette.powder.setFill()
        heap.fill()
        if let edge = palette.powderEdge {         // keeps white powder visible on a light bar
            edge.setStroke()
            heap.lineWidth = 0.8 * s
            heap.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        if pouring && level < 0.97 {
            let top = base + 6.7 * sy                // roughly the heap's peak
            let stream = NSBezierPath(rect: NSRect(x: rect.minX + 8.3 * s, y: rect.minY + top * s,
                                                   width: 0.9 * s, height: max(0, 11.2 - top) * s))
            palette.powder.setFill()
            stream.fill()
            if let edge = palette.powderEdge { edge.setStroke(); stream.lineWidth = 0.5 * s; stream.stroke() }
        }
    }

    /// Clear plastic bag with white powder, tuned for a light or a dark menu bar; no color.
    static func palette(dark: Bool) -> Palette {
        dark
            ? Palette(outline: NSColor.white.withAlphaComponent(0.78), fill: NSColor.white.withAlphaComponent(0.14),
                      powder: .white, powderEdge: nil)
            : Palette(outline: NSColor.black.withAlphaComponent(0.55), fill: NSColor.black.withAlphaComponent(0.07),
                      powder: .white, powderEdge: NSColor.black.withAlphaComponent(0.38))
    }

    /// Menu-bar glyph; it redraws for the bar's current (light/dark) appearance.
    static func image(level: CGFloat, pouring: Bool = false, size: CGFloat = 18) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            draw(in: rect, level: level, pouring: pouring, palette: palette(dark: dark))
            return true
        }
    }
}

// MARK: - Build-time assets (`Cocaine --render-assets <dir>`)

private enum Assets {
    static func png(_ w: Int, _ h: Int, _ draw: (NSRect) -> Void) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func appIcon(in r: NSRect) {
        let body = r.insetBy(dx: r.width * 0.1, dy: r.width * 0.1)
        let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
        NSGradient(starting: NSColor(white: 0.30, alpha: 1), ending: NSColor(white: 0.13, alpha: 1))!.draw(in: shape, angle: -90)
        let g = body.width * 0.64
        Baggie.draw(in: NSRect(x: body.midX - g / 2, y: body.midY - g / 2, width: g, height: g), level: 1,
                    palette: .init(outline: NSColor.white.withAlphaComponent(0.85), fill: NSColor.white.withAlphaComponent(0.14),
                                   powder: .white, powderEdge: nil))
    }

    /// Animated GIF for the README: the baggie filling and emptying, on a light and a dark background.
    static func renderDemoGIF(to url: URL) {
        let fps = 20.0
        var frames: [(level: CGFloat, pouring: Bool)] = []
        func hold(_ level: CGFloat, _ secs: Double) { for _ in 0..<Int(secs * fps) { frames.append((level, false)) } }
        func ramp(_ a: CGFloat, _ b: CGFloat, _ secs: Double, filling: Bool) {
            let n = Int(secs * fps)
            for i in 1...n {
                let f = CGFloat(i) / CGFloat(n), e = filling ? 1 - (1 - f) * (1 - f) : f * f   // same easing as the app
                frames.append((a + (b - a) * e, filling && i < n))
            }
        }
        hold(0, 0.7); ramp(0, 1, 1.4, filling: true); hold(1, 1.6); ramp(1, 0, 0.7, filling: false)

        let tile = 180, w = tile * 2, h = tile
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames.count, nil)
        else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in frames {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            for (i, dark) in [false, true].enumerated() {
                (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                let cell = NSRect(x: i * tile, y: 0, width: tile, height: tile)
                cell.fill()
                let g = CGFloat(tile) * 0.62
                Baggie.draw(in: NSRect(x: cell.midX - g / 2, y: cell.midY - g / 2, width: g, height: g),
                            level: frame.level, pouring: frame.pouring, palette: Baggie.palette(dark: dark))
            }
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(dest, rep.cgImage!,
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
    }

    static func render(to dir: URL) {
        let iconset = dir.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for pt in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
                try? png(pt * scale, pt * scale, appIcon).write(to: iconset.appendingPathComponent(name))
            }
        }
        // Menu-bar glyph preview: the fill animation at 18 pt @2x, on a light and a dark bar.
        let cell: CGFloat = 60
        let frames: [(CGFloat, Bool)] = [(0, false), (0.35, true), (0.7, true), (1, false)]
        let preview = png(Int(cell) * frames.count, Int(cell) * 2) { _ in
            for (row, bg) in [NSColor(white: 0.93, alpha: 1), NSColor(white: 0.12, alpha: 1)].enumerated() {
                bg.setFill()
                NSRect(x: 0, y: CGFloat(1 - row) * cell, width: cell * CGFloat(frames.count), height: cell).fill()
                for (col, (level, pouring)) in frames.enumerated() {
                    let px: CGFloat = 36
                    let x = CGFloat(col) * cell + (cell - px) / 2, y = CGFloat(1 - row) * cell + (cell - px) / 2
                    Baggie.draw(in: NSRect(x: x, y: y, width: px, height: px), level: level, pouring: pouring,
                                palette: Baggie.palette(dark: row == 1))
                }
            }
        }
        try? preview.write(to: dir.appendingPathComponent("menubar-preview.png"))
    }
}

// MARK: - Panel

private final class PanelModel: ObservableObject {
    private let settings = Settings()
    static let magnets: [Double] = [1, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50]   // % the slider snaps to

    @Published var on = false
    @Published var holdMissing = false
    @Published var needsAuth = false
    @Published var loginEnabled = false
    @Published var previewing = false
    @Published var fillLevel: CGFloat = 0
    @Published var pouring = false
    @Published var ai = AIHooks.Status()   // the "AI alerts" row shows only on Macs with a supported AI tool
    @Published var settingAI = false
    @Published var aiExpanded = UserDefaults.standard.bool(forKey: "aiExpanded") {
        didSet { if persistLanguage { UserDefaults.standard.set(aiExpanded, forKey: "aiExpanded") } }
    }
    /// The open group of the AI alerts card ("" = none); only one at a time, so the panel stays short.
    @Published var aiGroup = UserDefaults.standard.string(forKey: "aiGroup") ?? "" {
        didSet { if persistLanguage { UserDefaults.standard.set(aiGroup, forKey: "aiGroup") } }
    }
    @Published var alertsPausedUntil: Date?
    @Published var history: [AlertRecord] = []       // newest first; kept by the app delegate
    // Automation: the panel's second section
    @Published var autoExpanded = UserDefaults.standard.bool(forKey: "autoExpanded") {
        didSet { if persistLanguage { UserDefaults.standard.set(autoExpanded, forKey: "autoExpanded") } }
    }
    @Published var autoGroup = UserDefaults.standard.string(forKey: "autoGroup") ?? "" {
        didSet { if persistLanguage { UserDefaults.standard.set(autoGroup, forKey: "autoGroup") } }
    }
    @Published var timerMinutes: Int { didSet { settings.timerMinutes = timerMinutes; timerChanged() } }
    @Published var onUntil: Date?                    // when Cocaine will turn itself off
    @Published var batteryThreshold: Int { didSet { settings.batteryThreshold = batteryThreshold } }
    @Published var batteryTurnsOff: Bool { didSet { settings.batteryTurnsOff = batteryTurnsOff } }
    @Published var triggerAgents: Bool { didSet { settings.triggerAgents = triggerAgents } }
    @Published var triggerApps: [String] { didSet { settings.triggerApps = triggerApps } }
    @Published var hotkeys: Bool { didSet { settings.hotkeys = hotkeys; hotkeysChanged() } }
    @Published var board: [AgentEntry] = []          // what each AI session is doing, from the hooks
    @Published var sshOn = false
    @Published var makingShortcut = false
    @Published var phone = ""                        // "" = not set up; else what alerts go to
    @Published var battery: String?                  // "80%" (nil = no battery)
    @Published var alertDone: Bool { didSet { settings.alertDone = alertDone } }
    @Published var alertInput: Bool { didSet { settings.alertInput = alertInput } }
    @Published var alertFlash: Bool { didSet { settings.alertFlash = alertFlash } }
    @Published var alertSpeak: Bool { didSet { settings.alertSpeak = alertSpeak } }
    @Published var alertVoice: String { didSet { settings.alertVoice = alertVoice; previewVoice() } }   // hear it
    @Published var alertPerSession: Bool { didSet { settings.alertPerSession = alertPerSession } }
    @Published var alertWhenPresent: Bool { didSet { settings.alertWhenPresent = alertWhenPresent } }
    @Published var alertRepeatMinutes: Int { didSet { settings.alertRepeatMinutes = alertRepeatMinutes } }
    @Published var alertDuration: Double { didSet { settings.alertDuration = alertDuration } }
    @Published var alertSound: String {
        didSet { settings.alertSound = alertSound; if !alertSound.isEmpty { NSSound(named: alertSound)?.play() } }   // hear it
    }
    @Published var dimEnabled: Bool { didSet { settings.dimEnabled = dimEnabled } }
    @Published private(set) var levelPercent: Double
    @Published var delayMinutes: Int { didSet { if delayMinutes > 0 { settings.delay = Double(delayMinutes * 60) } } }
    /// "" = same as the Mac, otherwise a code from Language.codes. Changes apply at once.
    @Published var language: String = Language.chosen ?? "" {
        didSet { Language.set(language.isEmpty ? nil : language, persist: persistLanguage); languageChanged() }
    }
    var persistLanguage = true
    var languageChanged: () -> Void = {}

    // wired up by AppDelegate
    var toggleCocaine: () -> Void = {}
    var preview: () -> Void = {}
    var setLogin: (Bool) -> Void = { _ in }
    var setAI: (_ id: String, _ on: Bool) -> Void = { _, _ in }
    var pauseAlerts: (Date?) -> Void = { _ in }       // nil = resume
    var testAlert: () -> Void = {}
    var clearHistory: () -> Void = {}
    var previewVoice: () -> Void = {}
    var timerChanged: () -> Void = {}
    var hotkeysChanged: () -> Void = {}
    var copyRemoteCommand: () -> Void = {}
    var testPhone: () -> Void = {}
    var sendShortcut: () -> Void = {}
    var quit: () -> Void = {}

    init() {
        dimEnabled = settings.dimEnabled
        levelPercent = Double((settings.level * 100).rounded())
        delayMinutes = Int(settings.delay) / 60
        alertDone = settings.alertDone
        alertInput = settings.alertInput
        alertFlash = settings.alertFlash
        alertSpeak = settings.alertSpeak
        alertVoice = settings.alertVoice
        alertPerSession = settings.alertPerSession
        alertWhenPresent = settings.alertWhenPresent
        alertRepeatMinutes = settings.alertRepeatMinutes
        alertDuration = settings.alertDuration
        alertSound = settings.alertSound
        alertsPausedUntil = settings.alertsPausedUntil
        history = settings.alertHistory
        timerMinutes = settings.timerMinutes
        onUntil = settings.onUntil
        batteryThreshold = settings.batteryThreshold
        batteryTurnsOff = settings.batteryTurnsOff
        triggerAgents = settings.triggerAgents
        triggerApps = settings.triggerApps
        hotkeys = settings.hotkeys
    }

    /// Free movement in whole percents, but values near a magnet snap to it, with a trackpad "click".
    func setLevel(_ raw: Double) {
        var v = raw.rounded()
        if let near = Self.magnets.min(by: { abs($0 - raw) < abs($1 - raw) }), abs(near - raw) <= 1.2 { v = near }
        guard v != levelPercent else { return }
        if Self.magnets.contains(v) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        levelPercent = v
        settings.level = Float(v) / 100
    }
}

/// Warnings: deep orange on a light panel, light orange on a dark one; both read at over 4.5:1 contrast.
private let warningColor = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 1.0, green: 0.72, blue: 0.30, alpha: 1)
        : NSColor(srgbRed: 0.63, green: 0.28, blue: 0.0, alpha: 1)
})

/// The panel's type scale and control sizes, so every row, icon and switch matches.
private enum UI {
    static let title = Font.system(size: 13)
    static let groupTitle = Font.system(size: 13, weight: .medium)
    static let value = Font.system(size: 12)                 // summaries, picked values
    static let detail = Font.system(size: 11)                // descriptions, status, secondary lines
    static let icon = Font.system(size: 12, weight: .medium)
    static let chevron = Font.system(size: 10, weight: .semibold)
    static let switchSize = CGSize(width: 38, height: 22)
}

/// Cocaine's one switch, the same size everywhere: grey track when off, accent color when on, a white knob. The main
/// one also shows a thin line of powder that pours in (and fades out) with the menu-bar baggie's fill level.
private struct CocaineSwitch: View {
    let on: Bool
    var powder: CGFloat? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    init(on: Bool, powder: CGFloat? = nil, action: @escaping () -> Void) {
        self.on = on; self.powder = powder; self.action = action
    }

    init(_ isOn: Binding<Bool>) {
        self.init(on: isOn.wrappedValue) { isOn.wrappedValue.toggle() }
    }

    var body: some View {
        let w = UI.switchSize.width, h = UI.switchSize.height
        Button(action: action) {
            ZStack {
                Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.16))
                if let powder { Canvas { g, size in PowderLine.draw(g, size, level: powder) } }
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.28), radius: 1.1, y: 0.6)
                    .padding(2)
                    .frame(width: h, height: h)
                    .offset(x: on ? (w - h) / 2 : -(w - h) / 2)
            }
            .frame(width: w, height: h)
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: on)
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .opacity(enabled ? 1 : 0.45)
        .accessibilityValue(on ? "1" : "0")
        .accessibilityAddTraits(.isToggle)
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum PowderLine {
    /// Grains along the track, left to right: position (0…1 of the line), vertical jitter, size, brightness.
    static let grains: [(x: CGFloat, dy: CGFloat, r: CGFloat, a: CGFloat)] = {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func rnd() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(seed >> 33) / CGFloat(UInt64(1) << 31)
        }
        return (0..<44).map { i in (CGFloat(i) / 43, (rnd() - 0.5) * 3, 0.4 + rnd() * 0.5, 0.6 + rnd() * 0.4) }
    }()

    /// The line runs from the track's left end to where the knob sits when on; `level` says how much of it is there.
    static func draw(_ g: GraphicsContext, _ size: CGSize, level: CGFloat) {
        let lvl = min(max(level, 0), 1)
        guard lvl > 0.01 else { return }
        let start: CGFloat = 6, end = size.width - size.height + 2, mid = size.height / 2
        for gr in grains where gr.x <= lvl {
            let x = start + gr.x * (end - start), r = gr.r
            g.fill(Path(ellipseIn: CGRect(x: x - r, y: mid + gr.dy - r, width: 2 * r, height: 2 * r)),
                   with: .color(.white.opacity(gr.a * (0.4 + 0.6 * lvl))))
        }
    }
}

private struct PanelView: View {
    @ObservedObject var m: PanelModel

    private static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
    static func timeString(_ d: Date) -> String { time.string(from: d) }

    // MARK: AI alerts section

    /// The closed section's summary: paused, nothing connected, or the first AI connected (+ how many more).
    private var aiSummary: String {
        if let until = m.alertsPausedUntil { return "⏸ " + String(format: L("until %@"), Self.time.string(from: until)) }
        return m.ai.connected.isEmpty ? L("Choose") : connectedSummary
    }

    /// "Claude Code", or "Claude Code +2": never cut off, however many are connected.
    private var connectedSummary: String {
        let on = m.ai.connected
        guard let first = on.first else { return L("None connected") }
        return on.count == 1 ? first.name : "\(first.name) +\(on.count - 1)"
    }

    /// One group of the AI alerts card: a line with its summary that opens (one group at a time) onto its options.
    private func group<Content: View>(_ id: String, _ icon: String, _ title: String, _ summary: String, warning: Bool = false,
                                      key: ReferenceWritableKeyPath<PanelModel, String> = \.aiGroup,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        let open = m[keyPath: key] == id
        return VStack(alignment: .leading, spacing: 9) {
            Button { m[keyPath: key] = open ? "" : id } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon).font(UI.icon).foregroundStyle(Color.accentColor)
                        .frame(width: 16)
                    Text(title).font(UI.groupTitle).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 6)
                    if warning {
                        Image(systemName: "exclamationmark.triangle.fill").font(UI.detail).foregroundStyle(warningColor)
                    }
                    if !open { Text(summary).font(UI.value).foregroundStyle(.secondary).lineLimit(1) }
                    Image(systemName: "chevron.right").font(UI.chevron).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(summary)
            if open {
                VStack(alignment: .leading, spacing: 9) { content() }
                    .padding(.leading, 23)                      // under the title, past the icon
            }
        }
    }

    /// A row of options: what it is, one line on what it does, and its control on the right.
    private func option<Control: View>(_ title: String, _ detail: String, warning: Bool = false,
                                       @ViewBuilder _ control: () -> Control) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(UI.title).lineLimit(1)
                Text(detail).font(UI.detail).foregroundStyle(warning ? AnyShapeStyle(warningColor) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            control().fixedSize()                               // controls keep their size; the text wraps instead
        }
    }

    /// A value you pick from a short list, shown as just the current value with a chevron (as wide as that value).
    private func choice<T: Hashable>(_ title: String, _ selection: Binding<T>, _ values: [T],
                                     _ name: @escaping (T) -> String) -> some View {
        Menu {
            Picker(title, selection: selection) { ForEach(values, id: \.self) { Text(name($0)).tag($0) } }
                .pickerStyle(.inline).labelsHidden()
        } label: {
            Text(name(selection.wrappedValue))
        }
        .menuStyle(.borderlessButton)
        .font(UI.value)
        .accessibilityLabel(title)
    }

    private func toggle(_ title: String, _ on: Binding<Bool>) -> some View {
        CocaineSwitch(on).accessibilityLabel(title)
    }

    /// What each AI reports, from what its hooks can see.
    private func toolDetail(_ id: String) -> String {
        switch id {
        case "claude", "opencode": return L("Finishes, or asks permission or a question")
        case "codex": return L("Finishes, or asks for approval")
        case "cursor": return L("Finishes (approvals aren't reported)")
        case "copilot": return L("Finishes, or asks permission (CLI and VS Code)")
        case "windsurf": return L("After each reply")
        default: return L("Finishes, or asks permission")
        }
    }

    private var whenSummary: String {
        let on = [m.alertDone ? L("Finishes") : nil, m.alertInput ? L("Needs you") : nil].compactMap { $0 }
        return on.isEmpty ? L("Never") : on.joined(separator: ", ")
    }

    private var howSummary: String {
        let on = [m.alertFlash ? L("Flash") : nil, m.alertSound.isEmpty ? nil : m.alertSound, m.alertSpeak ? L("Voice") : nil]
        let text = on.compactMap { $0 }.joined(separator: ", ")
        return text.isEmpty ? L("Silent") : text
    }

    private func durationName(_ s: Double) -> String { s == 0 ? L("Until you're back") : String(format: L("%d s"), Int(s)) }
    private func repeatName(_ min: Int) -> String { min == 0 ? L("Never") : String(format: L("Every %d min"), min) }

    /// Which AIs, when, how, pause: four lines, one of them open.
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            group("ai", "sparkles", L("Connected AIs"), connectedSummary, warning: m.ai.codexNeedsTrust) {
                ForEach(m.ai.tools.filter(\.installed)) { t in
                    let untrusted = t.id == "codex" && m.ai.codexNeedsTrust
                    option(t.name, untrusted ? L("Approve once in Settings → Hooks") : toolDetail(t.id), warning: untrusted) {
                        toggle(t.name, Binding(get: { t.on }, set: { m.setAI(t.id, $0) })).disabled(m.settingAI)
                    }
                }
                let others = m.ai.tools.filter { !$0.installed }.map(\.name)
                VStack(alignment: .leading, spacing: 2) {
                    if !others.isEmpty {
                        Text(String(format: L("Also supported: %@"), others.joined(separator: ", ")))
                            .font(UI.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Button(L("Other apps and scripts…")) { NSWorkspace.shared.open(Feedback.alertsGuide) }
                        .buttonStyle(.link).font(UI.detail)
                }
            }
            Divider().padding(.vertical, 8)
            group("when", "bell.badge", L("When"), whenSummary) {
                option(L("Finishes"), L("When an AI completes its work")) { toggle(L("Finishes"), $m.alertDone) }
                option(L("Needs you"), L("When it asks for a permission or an answer")) { toggle(L("Needs you"), $m.alertInput) }
                option(L("Also at the Mac"), L("Otherwise only when you've been away for 20 seconds")) {
                    toggle(L("Also at the Mac"), $m.alertWhenPresent)
                }
                option(L("One alert per session"),
                       L("Not for every agent or task that finishes: only when the whole session has had nothing going on for a minute")) {
                    toggle(L("One alert per session"), $m.alertPerSession)
                }
            }
            Divider().padding(.vertical, 8)
            group("how", "rays", L("How"), howSummary) {
                option(L("Flash"), L("Wakes the screens and flashes them")) { toggle(L("Flash"), $m.alertFlash) }
                option(L("Sound"), L("Plays when the alert arrives")) {
                    choice(L("Sound"), $m.alertSound, [""] + Settings.sounds) { $0.isEmpty ? L("No sound") : $0 }
                }
                option(L("Voice"), L("Reads out who's calling and the project")) { toggle(L("Voice"), $m.alertSpeak) }
                if m.alertSpeak {                               // which voice, only when there's one to choose
                    option(L("Voice type"), L("The Mac's voices for your language; you hear it as you pick")) {
                        choice(L("Voice type"), $m.alertVoice, [""] + Voices.available.map(\.identifier), Voices.name)
                    }
                }
                option(L("On screen"), L("How long the alert stays")) {
                    choice(L("On screen"), $m.alertDuration, Settings.durationChoices, durationName)
                }
                option(L("Repeat"), L("While you're away, for up to 30 minutes")) {
                    choice(L("Repeat"), $m.alertRepeatMinutes, Settings.repeatChoices, repeatName)
                }
                option(L("Try it"), L("Shows an alert with these settings")) {
                    Button(L("Test")) { m.testAlert() }.controlSize(.small)
                }
            }
            Divider().padding(.vertical, 8)
            group("pause", "pause.circle", L("Pause"),
                  m.alertsPausedUntil.map { String(format: L("until %@"), Self.time.string(from: $0)) } ?? L("Active")) {
                if let until = m.alertsPausedUntil {
                    option(String(format: L("Paused until %@"), Self.time.string(from: until)), L("No alerts until then")) {
                        Button(L("Resume")) { m.pauseAlerts(nil) }.controlSize(.small)
                    }
                } else {
                    Text(L("Silences every alert for a while")).font(UI.detail).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Button(String(format: L("%d min"), 30)) { m.pauseAlerts(Date().addingTimeInterval(1800)) }
                        Button(L("1 hour")) { m.pauseAlerts(Date().addingTimeInterval(3600)) }
                        Button(L("Until tomorrow")) {
                            let cal = Calendar.current
                            m.pauseAlerts(cal.date(bySettingHour: 8, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date())!))
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    /// Not a setting, so it sits apart, under the card: the latest alerts, newest first.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(L("Recent alerts")).font(UI.detail.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if !m.history.isEmpty {
                    Button(L("Clear")) { m.clearHistory() }.buttonStyle(.link).font(UI.detail)
                }
            }
            if m.history.isEmpty {
                Text(L("Alerts you receive will show up here")).font(UI.detail).foregroundStyle(.tertiary)
            } else {
                ForEach(m.history.prefix(3)) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(Self.time.string(from: r.at)).font(UI.detail.monospacedDigit()).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.from).font(UI.title).lineLimit(1)
                            Text([r.message, r.project].compactMap { $0 }.joined(separator: " · "))
                                .font(UI.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)                               // lined up with the card's contents
    }

    // MARK: Automation section

    private func timerName(_ minutes: Int) -> String {
        minutes == 0 ? L("Until I turn it off") : minutes < 60 ? String(format: L("%d min"), minutes) : String(format: L("%d h"), minutes / 60)
    }
    private func batteryName(_ pct: Int) -> String { pct == 0 ? L("Off") : "\(pct)%" }

    private var timerSummary: String {
        if m.on, let until = m.onUntil, until > Date() { return String(format: L("until %@"), Self.time.string(from: until)) }
        return timerName(m.timerMinutes)
    }
    private var triggersSummary: String {
        var parts: [String] = []
        if m.triggerAgents { parts.append(L("AI at work")) }
        if let first = m.triggerApps.first { parts.append(m.triggerApps.count == 1 ? first : "\(first) +\(m.triggerApps.count - 1)") }
        return parts.isEmpty ? L("Off") : parts.joined(separator: ", ")
    }
    private var autoSummary: String {
        let on = [m.timerMinutes > 0 ? L("Timer") : nil, m.batteryThreshold > 0 ? L("Battery") : nil,
                  m.triggerAgents || !m.triggerApps.isEmpty ? L("Triggers") : nil, m.hotkeys ? L("Keys") : nil].compactMap { $0 }
        return on.isEmpty ? L("Off") : on.joined(separator: ", ")
    }

    private var automationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            group("timer", "timer", L("Timer"), timerSummary, key: \.autoGroup) {
                option(L("Stay on for"), L("Cocaine turns itself off when the time is up")) {
                    choice(L("Stay on for"), $m.timerMinutes, Settings.timerChoices, timerName)
                }
            }
            Divider().padding(.vertical, 8)
            group("battery", "battery.50", L("Battery Guard"),
                  m.batteryThreshold == 0 ? L("Off") : "≤ \(m.batteryThreshold)%", key: \.autoGroup) {
                option(L("When the battery reaches"), m.battery.map { String(format: L("On battery only. Now %@"), $0) } ?? L("On battery only")) {
                    choice(L("Battery"), $m.batteryThreshold, Settings.batteryChoices, batteryName)
                }
                option(L("Then"), L("What Cocaine does at that level")) {
                    choice(L("Then"), $m.batteryTurnsOff, [true, false]) { $0 ? L("Turn Cocaine off") : L("Only warn me") }
                }
                .disabled(m.batteryThreshold == 0).opacity(m.batteryThreshold == 0 ? 0.45 : 1)
            }
            Divider().padding(.vertical, 8)
            group("triggers", "bolt.badge.automatic", L("Smart Triggers"), triggersSummary, key: \.autoGroup) {
                option(L("An AI is at work"), L("On while an AI works or waits for you; off 3 minutes after")) {
                    toggle(L("An AI is at work"), $m.triggerAgents)
                }
                option(L("These programs are open"), L("On while any is running; off 3 minutes after")) {
                    Menu {
                        ForEach(m.triggerApps, id: \.self) { app in
                            Button { m.triggerApps.removeAll { $0 == app } } label: { Label(app, systemImage: "checkmark") }
                        }
                        if !m.triggerApps.isEmpty { Divider() }
                        Section(L("Open now")) {
                            ForEach(System.runningAppNames().filter { n in !m.triggerApps.contains(n) }, id: \.self) { app in
                                Button(app) { m.triggerApps.append(app) }
                            }
                        }
                    } label: {
                        Text(m.triggerApps.isEmpty ? L("Choose") : "\(m.triggerApps.count)")
                    }
                    .menuStyle(.borderlessButton).font(UI.value)
                }
            }
            Divider().padding(.vertical, 8)
            group("keys", "keyboard", L("Shortcuts"), m.hotkeys ? "⌃⌥⌘" : L("Off"), key: \.autoGroup) {
                option(L("Global shortcuts"), L("Work from any app")) { toggle(L("Global shortcuts"), $m.hotkeys) }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach([("C", L("Turn Cocaine on or off")), ("O", L("Open the panel")), ("P", L("Pause or resume alerts"))], id: \.0) { k in
                        HStack(spacing: 8) {
                            Text("⌃⌥⌘\(k.0)").font(UI.detail.monospaced()).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                            Text(k.1).font(UI.detail)
                        }
                    }
                }
                .opacity(m.hotkeys ? 1 : 0.45)
            }
            Divider().padding(.vertical, 8)
            group("remote", "iphone.gen3", L("Remote work"), m.sshOn ? L("Ready") : L("SSH off"),
                  warning: !m.sshOn, key: \.autoGroup) {
                option(L("Remote Login"), m.sshOn ? L("On: you can reach this Mac over SSH") : L("Off: turn it on to reach this Mac"),
                       warning: !m.sshOn) {
                    Button(L("Open")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!) }
                        .controlSize(.small)
                }
                option(L("iPhone"), L("Sends you a ready Shortcut: AirDrop, Messages…")) {
                    Button(m.makingShortcut ? "…" : L("Send")) { m.sendShortcut() }.controlSize(.small).disabled(m.makingShortcut)
                        .help(L("Send the Shortcut to your iPhone"))
                }
                option(L("Command"), L("Copies the SSH command to run from your phone")) {
                    Button(L("Copy")) { m.copyRemoteCommand() }.controlSize(.small).help(L("Copy the SSH command"))
                }
                option(L("Phone alerts"), m.phone.isEmpty ? L("Not set up: see the guide") : m.phone) {
                    Button(L("Test")) { m.testPhone() }.controlSize(.small).disabled(m.phone.isEmpty).help(L("Send a test to your phone"))
                }
                Button(L("Remote work guide…")) { NSWorkspace.shared.open(Feedback.remoteGuide) }
                    .buttonStyle(.link).font(UI.detail)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    /// What each AI session is doing right now, from its hooks.
    private var agentsSection: some View {
        let now = Date().timeIntervalSince1970
        let shown = m.board.filter { $0.isLive || now - $0.since < 600 }.prefix(4)
        return VStack(alignment: .leading, spacing: 6) {
            if !shown.isEmpty {
                Text(L("Agents")).font(UI.detail.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(shown)) { e in
                    HStack(spacing: 8) {
                        Image(systemName: Self.stateIcon(e.state)).font(UI.icon).foregroundStyle(Self.stateColor(e.state))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(e.from).font(UI.title).lineLimit(1)
                            Text([Self.stateName(e.state), e.project].compactMap { $0 }.joined(separator: " · "))
                                .font(UI.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Text(Self.age(e.since)).font(UI.detail.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private static func stateIcon(_ s: String) -> String {
        ["working": "gearshape.fill", "waiting": "hand.raised.fill", "done": "checkmark.circle.fill", "error": "exclamationmark.triangle.fill"][s] ?? "circle"
    }
    private static func stateColor(_ s: String) -> Color {
        s == "error" || s == "waiting" ? warningColor : s == "done" ? .green : Color.accentColor
    }
    private static func stateName(_ s: String) -> String {
        ["working": L("Working"), "waiting": L("Needs you"), "done": L("Done"), "error": L("Error")][s] ?? s
    }
    private static let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f }()
    private static func age(_ since: Double) -> String {
        Date().timeIntervalSince1970 - since < 45 ? L("now") : relative.localizedString(for: Date(timeIntervalSince1970: since), relativeTo: Date())
    }

    private var status: String {
        if m.needsAuth { return L("Admin password needed") }
        if m.on && m.holdMissing { return L("Keeping the screen on…") }
        return m.on ? L("Your Mac stays awake") : L("Your Mac sleeps as usual")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: Baggie.image(level: m.fillLevel, pouring: m.pouring, size: 28))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Cocaine").font(.headline)
                        Text(appVersion).font(UI.detail).foregroundStyle(.tertiary)   // e.g. "1.7"
                        Button { Feedback.compose() } label: {
                            Image(systemName: "envelope").font(UI.detail).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(L("Feedback or help") + " — " + Feedback.address)
                    }
                    Text(status).font(UI.detail).lineLimit(1)
                        .foregroundStyle(m.needsAuth || (m.on && m.holdMissing) ? AnyShapeStyle(warningColor) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 6)
                CocaineSwitch(on: m.on, powder: m.fillLevel) { m.toggleCocaine() }
                    .help(m.on ? L("Turn Cocaine off") : L("Turn Cocaine on"))
                    .accessibilityLabel("Cocaine")
            }

            if m.on {                                  // brightness options exist only while Cocaine is on
                Divider()

                HStack {
                    Text(L("Dim the screen when idle")).lineLimit(1)
                    Spacer(minLength: 6)
                    CocaineSwitch($m.dimEnabled).accessibilityLabel(L("Dim the screen when idle"))
                }
                .help(L("Goes back to normal as soon as you touch anything"))
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { m.levelPercent }, set: { m.setLevel($0) }), in: 1...50)
                        Text("\(Int(m.levelPercent))%").monospacedDigit().frame(width: 32, alignment: .trailing)
                        Button(L("Preview")) { m.preview() }.controlSize(.small).disabled(m.previewing)
                            .help(L("Shows the minimum brightness for 3 seconds"))
                    }
                    HStack(spacing: 6) {
                        Text(L("After")).fixedSize()
                        Picker(L("After"), selection: $m.delayMinutes) {
                            ForEach(Settings.delayChoices, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                        Text(L("min")).fixedSize()
                    }
                }
                .disabled(!m.dimEnabled)
                .opacity(m.dimEnabled ? 1 : 0.45)
            }

            Divider()

            if !m.board.isEmpty { agentsSection }

            if m.ai.available {
                VStack(alignment: .leading, spacing: 8) {
                    Button { m.aiExpanded.toggle() } label: {  // the whole row opens and closes the section
                        HStack(spacing: 6) {
                            Text(L("AI alerts")).lineLimit(1)
                            Spacer(minLength: 6)
                            if !m.aiExpanded { Text(aiSummary).font(UI.value).foregroundStyle(.secondary).lineLimit(1) }
                            Image(systemName: "chevron.right").font(UI.chevron)
                                .foregroundStyle(.tertiary).rotationEffect(.degrees(m.aiExpanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Flashes the screen when an AI finishes or needs you"))
                    if m.ai.codexNeedsTrust && !m.aiExpanded {   // open, the Codex row itself says so
                        Label(L("Codex: approve them once in Settings → Hooks"), systemImage: "exclamationmark.triangle.fill")
                            .font(UI.detail.weight(.medium)).foregroundStyle(warningColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if m.aiExpanded {
                        aiSection
                        recentSection.padding(.top, 6)           // history, not a setting: apart from the card
                    }
                }
                if m.aiExpanded { Divider() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Button { m.autoExpanded.toggle() } label: {   // timer, battery, triggers, shortcuts, remote work
                    HStack(spacing: 6) {
                        Text(L("Automation")).lineLimit(1)
                        Spacer(minLength: 6)
                        if !m.autoExpanded { Text(autoSummary).font(UI.value).foregroundStyle(.secondary).lineLimit(1) }
                        Image(systemName: "chevron.right").font(UI.chevron)
                            .foregroundStyle(.tertiary).rotationEffect(.degrees(m.autoExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Timer, battery, smart triggers, shortcuts and remote work"))
                if m.autoExpanded { automationSection }
            }
            if m.autoExpanded { Divider() }

            HStack(spacing: 0) {                       // two groups and one flexible gap, no wasted spacing
                HStack(spacing: 6) {
                    Text(L("Open at login")).lineLimit(1)
                    CocaineSwitch(on: m.loginEnabled) { m.setLogin(!m.loginEnabled) }
                        .accessibilityLabel(L("Open at login"))
                }
                .layoutPriority(1)                     // text first, empty space last
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    Menu {
                        Picker(L("Language"), selection: $m.language) {
                            Text("\(L("Same as Mac"))  \(Language.flag(Language.system))").tag("")
                            ForEach(Language.codes, id: \.self) { Text("\(Language.flag($0))  \(Language.nativeName($0))").tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(Language.flag(m.language.isEmpty ? Language.system : m.language))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 22)                  // just the flag, no invisible padding
                    .help(L("Language"))
                    Button(L("Quit")) { m.quit() }.controlSize(.small).fixedSize()
                        .help(L("Turns Cocaine off and quits"))
                }
                .layoutPriority(2)                     // never truncated
            }
        }
        .padding(14)
        .frame(width: 312, alignment: .topLeading)     // never centered, so nothing can slide out sideways
        .fixedSize(horizontal: false, vertical: true)
        .focusEffectDisabled()
    }
}

// MARK: - Voices

/// The Mac's voices for reading alerts aloud, in the panel's language.
private enum Voices {
    /// The speech language for the UI language, e.g. "it-IT".
    static var language: String {
        ["it": "it-IT", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "es": "es-ES", "fr": "fr-FR", "de": "de-DE",
         "ja": "ja-JP"][Language.chosen ?? Language.system] ?? "en-US"
    }

    /// Voices that speak that language (any region), best quality first, then by name.
    static var available: [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }.sorted {
            $0.quality != $1.quality ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name
        }
    }

    /// The chosen voice if it's still installed, else the language's default.
    static func voice(_ id: String) -> AVSpeechSynthesisVoice? {
        (id.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: id)) ?? AVSpeechSynthesisVoice(language: language)
    }

    static func name(_ id: String) -> String {
        guard !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) else { return L("Automatic") }
        switch v.quality {
        case .premium: return "\(v.name) · Premium"
        case .enhanced: return "\(v.name) · \(L("Enhanced"))"
        default: return v.name
        }
    }
}

// MARK: - Feedback and help

private enum Feedback {
    static let address = "mattia.lorenzo@twou.lu"

    /// What helps with support: versions, the Mac's model, the UI language.
    static var details: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Cocaine \(appVersion) · macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) · "
            + "\(String(cString: model)) · \(Language.chosen ?? Language.system)"
    }

    /// The ✉︎ button: a new email to the author in the user's mail app, with those details at the bottom.
    static func compose() {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        c.queryItems = [URLQueryItem(name: "subject", value: "Cocaine \(appVersion) – " + L("Feedback")),
                        URLQueryItem(name: "body", value: "\n\n\n— \(details)")]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    /// The README's section on remote work.
    static var remoteGuide: URL {
        (Language.chosen ?? Language.system) == "it"
            ? URL(string: "https://github.com/Mattiakart/cocaine/blob/main/README.it.md#lavoro-da-remoto")!
            : URL(string: "https://github.com/Mattiakart/cocaine#remote-work")!
    }

    /// The README's section on alerts, in Italian for Italian users.
    static var alertsGuide: URL {
        (Language.chosen ?? Language.system) == "it"
            ? URL(string: "https://github.com/Mattiakart/cocaine/blob/main/README.it.md#avvisi-quando-unai-finisce")!
            : URL(string: "https://github.com/Mattiakart/cocaine#alerts-when-an-ai-finishes")!
    }
}

// MARK: - Alerts ("an AI finished / needs you")

/// Drives the overlay's animation (SwiftUI's @State needs full Xcode's macros, which the command-line tools lack).
private final class AlertAnimation: ObservableObject {
    @Published var tint = 0.0
    @Published var shown = false

    func start() {
        withAnimation(.easeOut(duration: 0.25)) { shown = true }
        for (i, value) in [0.55, 0, 0.55, 0].enumerated() {     // two flashes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(i)) {
                withAnimation(.easeInOut(duration: 0.18)) { self.tint = value }
            }
        }
    }
}

/// Full-screen overlay on every screen: two quick flashes, then a card with the message for a few seconds.
private struct AlertView: View {
    let title: String
    let message: String
    let detail: String?                  // the project (folder) the agent was working in
    @ObservedObject var anim: AlertAnimation

    var body: some View {
        ZStack {
            Color.white.opacity(anim.tint)
            VStack(spacing: 10) {
                Image(nsImage: Baggie.image(level: 1, size: 64))
                Text(title).font(.system(size: 28, weight: .bold))
                Text(message).font(.system(size: 20))
                if let detail {
                    Label(detail, systemImage: "folder").font(.system(size: 16)).foregroundStyle(.white.opacity(0.75))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 36).padding(.vertical, 26)
            .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 22))
            .opacity(anim.shown ? 1 : 0)
            .scaleEffect(anim.shown ? 1 : 0.92)
        }
        .ignoresSafeArea()
    }
}

private final class Alerter {
    private var windows: [NSWindow] = []
    private(set) var shownAt: Date?

    var isShowing: Bool { !windows.isEmpty }

    func show(title: String, message: String, detail: String? = nil, seconds: Double = 5) {
        close(animated: false)
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size), styleMask: .borderless,
                             backing: .buffered, defer: false, screen: screen)
            w.level = .screenSaver                           // above the menu bar, the Dock and full-screen apps
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let anim = AlertAnimation()
            let host = NSHostingView(rootView: AlertView(title: title, message: message, detail: detail, anim: anim))
            host.sizingOptions = []                          // the window sets the size; SwiftUI must not move it
            host.appearance = NSAppearance(named: .darkAqua)    // light baggie on the dark card
            w.contentView = host
            w.setFrame(screen.frame, display: true)
            log.notice("alert window at \(w.frame.debugDescription, privacy: .public) for screen \(screen.frame.debugDescription, privacy: .public)")
            w.orderFrontRegardless()
            windows.append(w)
            DispatchQueue.main.async { anim.start() }
        }
        shownAt = Date()
        guard seconds > 0 else { return }                // 0 = until the user is back (the tick closes it then)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if let at = self?.shownAt, Date().timeIntervalSince(at) >= seconds - 0.1 { self?.close(animated: true) }
        }
    }

    func close(animated: Bool) {
        let closing = windows
        windows = []
        shownAt = nil
        guard animated else { closing.forEach { $0.orderOut(nil) }; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { closing.forEach { $0.orderOut(nil) } })
    }
}

// MARK: - AI alerts (hooks in Claude Code and Codex)

/// Just enough JSON to edit another app's config file without reordering its keys or rewriting its values: strings
/// and numbers keep their exact text; only the indentation is redone (2 spaces, as both apps write it).
private enum JSONValue: Equatable {
    case object([Member])
    case array([JSONValue])
    case scalar(String)              // a string with its quotes, a number, true, false or null, exactly as written

    struct Member: Equatable {
        var key: String              // the raw text between the quotes
        var value: JSONValue
    }

    static func string(_ s: String) -> JSONValue {
        let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return .scalar(String(decoding: data, as: UTF8.self))
    }

    /// nil unless `text` is valid JSON (Foundation checks it first, so the scanner below can trust the syntax).
    static func parse(_ text: String) -> JSONValue? {
        let b = Array(text.utf8)
        guard (try? JSONSerialization.jsonObject(with: Data(b), options: [.fragmentsAllowed])) != nil else { return nil }
        var i = 0
        func space() { while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 } }
        func token() -> String {
            let start = i
            if b[i] == UInt8(ascii: "\"") {
                i += 1
                while b[i] != UInt8(ascii: "\"") { i += b[i] == UInt8(ascii: "\\") ? 2 : 1 }
                i += 1
            } else {
                while i < b.count, !",]} \t\r\n".utf8.contains(b[i]) { i += 1 }
            }
            return String(decoding: b[start..<i], as: UTF8.self)
        }
        func value() -> JSONValue {
            space()
            let open = b[i]
            guard open == UInt8(ascii: "{") || open == UInt8(ascii: "[") else { return .scalar(token()) }
            let close = open == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
            var members: [Member] = [], items: [JSONValue] = []
            i += 1
            space()
            while b[i] != close {
                if open == UInt8(ascii: "{") {
                    let key = token()
                    space()
                    i += 1                                       // ':'
                    members.append(Member(key: String(key.dropFirst().dropLast()), value: value()))
                } else {
                    items.append(value())
                }
                space()
                if b[i] == UInt8(ascii: ",") { i += 1; space() }
            }
            i += 1
            return open == UInt8(ascii: "{") ? .object(members) : .array(items)
        }
        return value()
    }

    func render(_ indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .scalar(let s):
            return s
        case .array(let items):
            return items.isEmpty ? "[]" : "[\n" + items.map { inner + $0.render(inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .object(let members):
            return members.isEmpty ? "{}"
                : "{\n" + members.map { "\(inner)\"\($0.key)\": " + $0.value.render(inner) }.joined(separator: ",\n") + "\n\(indent)}"
        }
    }

    var items: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var members: [Member]? { if case .object(let m) = self { return m }; return nil }

    subscript(key: String) -> JSONValue? {
        get { members?.first { $0.key == key }?.value }
        set {
            guard var m = members else { return }
            if let i = m.firstIndex(where: { $0.key == key }) {
                if let newValue { m[i].value = newValue } else { m.remove(at: i) }
            } else if let newValue {
                m.append(Member(key: key, value: newValue))
            }
            self = .object(m)
        }
    }
}

/// "AI alerts": hooks that make AI agents open cocaine://alert when they finish or need you. They live in each tool's
/// own config file; turning one off removes only Cocaine's hooks there, every other hook and setting stays as it was.
private enum AIHooks {
    /// How a tool's config lists the commands for an event.
    enum Layout {
        case grouped      // "Event": [{ "matcher"?, "hooks": [{ "type": "command", "command": … }] }]  (Claude Code, Codex, …)
        case flat         // "event": [{ "command": … }]                                                 (Cursor, Windsurf)
        case ownFile      // a file of Cocaine's own in the tool's hooks/plugins folder                 (Copilot, OpenCode)
    }

    struct Event {
        let name: String
        let kind: String                                  // the alert: "done" or "input"
        var matcher: String? = nil
        var minVersion: [Int]? = nil                      // only for tools new enough to know this event (Claude Code)
    }

    struct Tool {
        let id: String                                    // stable, for the CLI and the menu
        let name: String                                  // also the alert's title
        let folder: String                                // the tool's config folder: it's installed if this exists
        let file: String
        var layout = Layout.grouped
        var events: [Event] = []
        var handler: (_ command: String, _ kind: String) -> [JSONValue.Member] = AIHooks.typed(timeout: "10")
        var top: [JSONValue.Member] = []                  // top-level keys the file must have (Cursor's "version": 1)
        var contents: ((Tool) -> String)? = nil           // .ownFile: the whole file
        var skipIf: String? = nil                         // an env variable set by another tool that runs these hooks too
        var activeEvents: [Event] { events.filter { $0.minVersion.map { AIHooks.claudeVersion(atLeast: $0) } ?? true } }
        var installed: ((Tool) -> Bool)? = nil            // when the folder alone doesn't tell
    }

    static var home = NSHomeDirectory()                   // `--ai-alerts … --home <dir>` works on a copy
    static let marker = "cocaine://alert"

    /// `{"type": "command", "command": …, "timeout": …}`: Claude Code, Codex and Qwen Code (seconds).
    private static func typed(timeout: String) -> (String, String) -> [JSONValue.Member] {
        { command, _ in [.init(key: "type", value: .string("command")), .init(key: "command", value: .string(command)),
                         .init(key: "timeout", value: .scalar(timeout))] }
    }

    /// The supported tools, most used first. Formats from each tool's hooks reference (checked September 2026).
    static var tools: [Tool] {
        [Tool(id: "claude", name: "Claude Code", folder: home + "/.claude", file: home + "/.claude/settings.json",
              events: [.init(name: "Stop", kind: "done"),
                       .init(name: "Notification", kind: "input", matcher: "permission_prompt|elicitation_dialog"),
                       .init(name: "SubagentStart", kind: "agentstart"), .init(name: "SubagentStop", kind: "agentstop"),
                       .init(name: "UserPromptSubmit", kind: "start"),
                       .init(name: "StopFailure", kind: "error", minVersion: [2, 1, 78])],
              skipIf: "CURSOR_VERSION"),               // Cursor runs Claude Code's hooks as well; it has its own below
         Tool(id: "codex", name: "Codex", folder: home + "/.codex", file: home + "/.codex/hooks.json",
              events: [.init(name: "Stop", kind: "done"), .init(name: "PermissionRequest", kind: "input"),
                       .init(name: "SubagentStart", kind: "agentstart"), .init(name: "SubagentStop", kind: "agentstop"),
                       .init(name: "UserPromptSubmit", kind: "start")]),
         Tool(id: "cursor", name: "Cursor", folder: home + "/.cursor", file: home + "/.cursor/hooks.json", layout: .flat,
              events: [.init(name: "stop", kind: "done"),   // Cursor has no hook for "waiting for you"
                       .init(name: "subagentStart", kind: "agentstart"), .init(name: "subagentStop", kind: "agentstop"),
                       .init(name: "beforeSubmitPrompt", kind: "start")],
              handler: { command, _ in [.init(key: "command", value: .string(command)), .init(key: "timeout", value: .scalar("10"))] },
              top: [.init(key: "version", value: .scalar("1"))]),
         Tool(id: "copilot", name: "GitHub Copilot", folder: home + "/.copilot", file: home + "/.copilot/hooks/cocaine.json",
              layout: .ownFile, contents: copilotFile),  // Copilot CLI and VS Code's Copilot agent both read it
         Tool(id: "gemini", name: "Gemini CLI", folder: home + "/.gemini", file: home + "/.gemini/settings.json",
              events: [.init(name: "AfterAgent", kind: "done"), .init(name: "Notification", kind: "input"),
                       .init(name: "BeforeAgent", kind: "start")],
              handler: { command, kind in                // milliseconds; a name, so it can be disabled by name
                  [.init(key: "name", value: .string("cocaine-\(kind)")), .init(key: "type", value: .string("command")),
                   .init(key: "command", value: .string(command)), .init(key: "timeout", value: .scalar("10000"))] },
              installed: { t in                          // Google Antigravity keeps its things in ~/.gemini/antigravity too
                  let items = (try? FileManager.default.contentsOfDirectory(atPath: t.folder)) ?? []
                  return items.contains { !["antigravity", ".DS_Store"].contains($0) } }),
         Tool(id: "windsurf", name: "Windsurf", folder: home + "/.codeium/windsurf", file: home + "/.codeium/windsurf/hooks.json",
              layout: .flat, events: [.init(name: "post_cascade_response", kind: "done")],
              handler: { command, _ in [.init(key: "command", value: .string(command)), .init(key: "show_output", value: .scalar("false"))] }),
         Tool(id: "qwen", name: "Qwen Code", folder: home + "/.qwen", file: home + "/.qwen/settings.json",
              events: [.init(name: "Stop", kind: "done"), .init(name: "Notification", kind: "input", matcher: "permission_prompt"),
                       .init(name: "UserPromptSubmit", kind: "start")]),
         Tool(id: "opencode", name: "OpenCode", folder: home + "/.config/opencode", file: home + "/.config/opencode/plugins/cocaine.js",
              layout: .ownFile, contents: openCodeFile)]
    }
    /// Claude Code's version, asked once (a login shell finds it like Terminal does); nil if it can't be read.
    private static var claudeVersionCache: [Int]??
    static func claudeVersion(atLeast need: [Int]) -> Bool {
        if claudeVersionCache == nil {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "claude --version"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var parsed: [Int]?
            if (try? p.run()) != nil {
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                if let r = out.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) { parsed = out[r].split(separator: ".").compactMap { Int($0) } }
            }
            claudeVersionCache = .some(parsed)
        }
        guard let have = claudeVersionCache ?? nil else { return false }
        return have.lexicographicallyPrecedes(need) == false
    }
    static var present: [Tool] { tools.filter(isInstalled) }
    static func tool(_ id: String) -> Tool? { tools.first { $0.id == id } }
    static func isInstalled(_ t: Tool) -> Bool {
        FileManager.default.fileExists(atPath: t.folder) && (t.installed?(t) ?? true)
    }

    /// ~/.copilot/hooks/cocaine.json: GitHub Copilot's own hooks format.
    private static func copilotFile(_ t: Tool) -> String {
        func hook(_ kind: String, matcher: String? = nil) -> JSONValue {
            .object([.init(key: "type", value: .string("command"))]
                    + (matcher.map { [.init(key: "matcher", value: .string($0))] } ?? [])
                    + [.init(key: "bash", value: .string(command(t, kind))), .init(key: "timeoutSec", value: .scalar("10"))])
        }
        return JSONValue.object([
            .init(key: "version", value: .scalar("1")),
            .init(key: "hooks", value: .object([
                .init(key: "agentStop", value: .array([hook("done")])),
                .init(key: "notification", value: .array([hook("input", matcher: "permission_prompt|elicitation_dialog")])),
            ])),
        ]).render() + "\n"
    }

    /// ~/.config/opencode/plugins/cocaine.js: an OpenCode plugin (run by Bun) that listens for its events.
    private static func openCodeFile(_ t: Tool) -> String {
        guard case .scalar(let done) = JSONValue.string(command(t, "done")),
              case .scalar(let input) = JSONValue.string(command(t, "input")) else { return "" }
        return """
        // Added by Cocaine ("AI alerts" in its menu-bar panel), which also removes it: it flashes the screen when
        // OpenCode finishes or needs you. https://github.com/Mattiakart/cocaine
        const done = \(done)
        const input = \(input)

        export const Cocaine = async ({ $, client }) => ({
          event: async ({ event }) => {
            try {
              if (event.type === "session.idle") {
                const s = await client?.session?.get({ path: { id: event.properties?.sessionID } }).catch(() => null)
                if (s?.data?.parentID) return            // a subagent finished, not the session
                await $`sh -c ${done} < /dev/null`.quiet().nothrow()
              } else if (event.type === "permission.asked" || event.type === "question.asked") {
                await $`sh -c ${input} < /dev/null`.quiet().nothrow()
              }
            } catch {}
          },
        })

        """
    }

    /// Does nothing while Cocaine is closed, so a closed Cocaine stays closed. `project` is the folder the agent runs
    /// in, URL-encoded by the perl that comes with macOS. Change it only when needed: Codex asks to trust a hook again
    /// whenever its command changes.
    static func command(_ tool: Tool, _ kind: String) -> String {
        let from = tool.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? tool.name
        let project = #"$(printf %s "$PWD" | /usr/bin/perl -pe 's|.*/||; s/([^A-Za-z0-9._~-])/sprintf("%%%02X", ord $1)/ge')"#
        // From the JSON the tool sends on stdin (read with the perl and JSON::PP every Mac has): the session, so a
        // session's agents make one alert, and how much of its work is still in flight (Claude Code's background_tasks
        // and session_crons), so a session paused waiting for it isn't "done". Prints "<session> <count>", the count
        // empty when the tool sends no such list; gives up after 2 s if a tool never closes stdin.
        let info = #"$(/usr/bin/perl -MJSON::PP -e 'alarm 2; local $/; my $j = eval { decode_json(<STDIN> // "") } || {}; my $s = $j->{session_id} // $j->{sessionId} // $j->{conversation_id} // $j->{conversationId} // $j->{trajectory_id} // ""; $s =~ s/[^A-Za-z0-9._:-]//g; my $n; for my $k ("background_tasks", "session_crons") { $n += @{$j->{$k}} if ref $j->{$k} eq "ARRAY" } print "$s ", $n // ""' 2>/dev/null)"#
        let skip = tool.skipIf.map { "[ -z \"$\($0)\" ] && " } ?? ""
        return skip + "pgrep -qx Cocaine && { j=\(info); open -g \"cocaine://alert?from=\(from)&event=\(kind)"
            + "&session=${j% *}&running=${j#* }&project=\(project)\"; }; true"
    }

    /// What goes in an event's list: a group holding our handler (with the event's matcher), or the handler itself.
    private static func entry(_ tool: Tool, _ event: Event) -> JSONValue {
        let handler = JSONValue.object(tool.handler(command(tool, event.kind), event.kind))
        guard tool.layout == .grouped else { return handler }
        return .object((event.matcher.map { [.init(key: "matcher", value: .string($0))] } ?? [])
                       + [.init(key: "hooks", value: .array([handler]))])
    }

    private static func isOurs(_ handler: JSONValue) -> Bool {
        guard case .scalar(let s)? = handler["command"] else { return false }
        return s.contains(marker) || s.contains("cocaine:\\/\\/alert")
    }
    private static func hasOurs(_ group: JSONValue) -> Bool { group["hooks"]?.items?.contains(where: isOurs) ?? false }

    /// The file's JSON: {} if it doesn't exist or is empty; nil if it isn't a JSON object this code can round-trip.
    static func load(_ path: String) -> JSONValue? {
        guard FileManager.default.fileExists(atPath: path) else { return .object([]) }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .object([]) }
        guard let v = JSONValue.parse(text), v.members != nil,
              let a = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary,
              let b = try? JSONSerialization.jsonObject(with: Data(v.render().utf8)) as? NSDictionary, a == b
        else { return nil }
        return v
    }

    static func installed(_ root: JSONValue) -> Bool {
        root["hooks"]?.members?.contains { $0.value.items?.contains { isOurs($0) || hasOurs($0) } ?? false } ?? false
    }

    /// `root` with our hooks added or removed. Ones already there are updated where they are, so Codex's trust
    /// (keyed by position) survives; groups, events and "hooks" left empty by a removal go too. nil = hands off.
    static func edited(_ root: JSONValue, for tool: Tool, on: Bool) -> JSONValue? {
        let before = root["hooks"]
        guard let events = (before ?? .object([])).members else { return nil }
        var wanted = on ? Dictionary(uniqueKeysWithValues: tool.activeEvents.map { ($0.name, entry(tool, $0)) }) : [:]
        var result: [JSONValue.Member] = []
        for var event in events {
            guard let entries = event.value.items else { wanted[event.key] = nil; result.append(event); continue }
            var out: [JSONValue] = []
            for e in entries {
                if tool.layout == .flat {
                    guard isOurs(e) else { out.append(e); continue }
                    if let w = wanted.removeValue(forKey: event.key) { out.append(w) }   // same place; drop repeats
                    continue
                }
                guard hasOurs(e) else { out.append(e); continue }
                if e["hooks"]?.items?.allSatisfy(isOurs) == true, let w = wanted.removeValue(forKey: event.key) {
                    out.append(w)
                    continue
                }
                let kept = (e["hooks"]?.items ?? []).filter { !isOurs($0) }   // ours inside someone else's group
                if !kept.isEmpty { var e = e; e["hooks"] = .array(kept); out.append(e) }
            }
            if let w = wanted.removeValue(forKey: event.key) { out.append(w) }
            if out.isEmpty && !entries.isEmpty { continue }
            event.value = .array(out)
            result.append(event)
        }
        for e in tool.activeEvents { if let w = wanted.removeValue(forKey: e.name) { result.append(.init(key: e.name, value: .array([w]))) } }
        var root = root
        if !result.isEmpty { root["hooks"] = .object(result) }
        else if before?.members?.isEmpty == false { root["hooks"] = nil }
        if on, var members = root.members {                   // e.g. Cursor's "version": 1, first like its docs
            for m in tool.top.reversed() where root[m.key] == nil { members.insert(m, at: 0) }
            root = .object(members)
        }
        return root
    }

    /// Writes through symlinks (dotfile setups) and keeps the file's permissions.
    private static func write(_ text: String, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch { return false }
        if let perms { try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
        return true
    }

    /// Whether Cocaine's hooks are in this tool's config.
    static func isOn(_ t: Tool) -> Bool {
        guard t.layout != .ownFile else { return (try? String(contentsOfFile: t.file, encoding: .utf8))?.contains(marker) ?? false }
        return load(t.file).map(installed) ?? false
    }

    /// Adds or removes the hooks in every tool on this Mac (or just `only`); returns the files it couldn't update.
    @discardableResult
    static func set(_ on: Bool, only: [Tool]? = nil) -> [String] {
        var failed: [String] = []
        for tool in only ?? present {
            if tool.layout == .ownFile, let contents = tool.contents {
                let current = try? String(contentsOfFile: tool.file, encoding: .utf8)
                if on {
                    let want = contents(tool)
                    guard current != want else { continue }
                    if let current, !current.contains(marker) { failed.append(tool.file); continue }   // not ours: hands off
                    try? FileManager.default.createDirectory(atPath: (tool.file as NSString).deletingLastPathComponent,
                                                             withIntermediateDirectories: true)
                    if !write(want, to: tool.file) { failed.append(tool.file) }
                } else if let current, current.contains(marker) {
                    do { try FileManager.default.removeItem(atPath: tool.file) } catch { failed.append(tool.file) }
                }
                continue
            }
            guard let root = load(tool.file), let new = edited(root, for: tool, on: on) else { failed.append(tool.file); continue }
            if new != root && !write(new.render() + "\n", to: tool.file) { failed.append(tool.file) }
        }
        return failed
    }

    /// At launch: brings hooks written by an older Cocaine (or by hand) up to date, only where they already are.
    static func update() {
        let tools = present.filter(isOn)
        if !tools.isEmpty { set(true, only: tools) }
    }

    /// Codex runs a new hook only after the user trusts it once (/hooks, or Settings → Hooks in the ChatGPT app);
    /// it then keeps `trusted_hash` under [hooks.state."<file>:<event>:<group>:<handler>"] in its config.toml.
    static func codexNeedsTrust() -> Bool {
        guard let codex = tool("codex"), FileManager.default.fileExists(atPath: codex.folder),
              let events = load(codex.file)?["hooks"]?.members else { return false }
        let config = (try? String(contentsOfFile: codex.folder + "/config.toml", encoding: .utf8)) ?? ""
        for event in events {
            let snake = event.key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
            for (g, group) in (event.value.items ?? []).enumerated() {
                for (h, handler) in (group["hooks"]?.items ?? []).enumerated() where isOurs(handler) {
                    if !trusted("\(codex.file):\(snake):\(g):\(h)", in: config) { return true }
                }
            }
        }
        return false
    }

    private static func trusted(_ key: String, in config: String) -> Bool {
        guard let r = config.range(of: "\"\(key)\"") else { return false }
        let rest = config[r.upperBound...]
        let lineEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
        let lineStart = config[..<r.lowerBound].lastIndex(of: "\n").map { config.index(after: $0) } ?? config.startIndex
        guard config[lineStart...].hasPrefix("[") else { return rest[..<lineEnd].contains("trusted_hash") }  // inline table
        let body = rest[lineEnd...]                                                  // [hooks.state."…"] table
        return body[..<(body.range(of: "\n[")?.lowerBound ?? body.endIndex)].contains("trusted_hash")
    }

    struct Entry: Equatable, Identifiable {
        let id: String
        let name: String
        var installed = false
        var on = false
    }

    struct Status: Equatable {
        var tools: [Entry] = []
        var codexNeedsTrust = false
        var available: Bool { tools.contains(where: \.installed) }
        var connected: [Entry] { tools.filter(\.on) }
    }

    static func status() -> Status {
        var s = Status(tools: tools.map { t in
            let installed = isInstalled(t)
            return Entry(id: t.id, name: t.name, installed: installed, on: installed && isOn(t))
        })
        s.codexNeedsTrust = s.tools.contains { $0.id == "codex" && $0.on } && codexNeedsTrust()
        return s
    }
}

// MARK: - App

/// Tells the app when the SwiftUI content's size changes (e.g. the brightness section appears).
private final class PanelHostingView: NSHostingView<PanelView> {
    var onSizeChange: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}

/// Borderless panel shown under the menu-bar icon. It can take clicks without activating the app, never
/// resizes while open, and closes only when you click elsewhere, press Esc or click the icon again.
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isMovable = false

        let fx = NSVisualEffectView()
        fx.material = .menu
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = MenuPanel.roundedMask(radius: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(content)
        NSLayoutConstraint.activate([      // pinned to the top only: the app sizes the window, top edge fixed
            content.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            content.topAnchor.constraint(equalTo: fx.topAnchor),
        ])
        contentView = fx
    }

    private static func roundedMask(radius r: CGFloat) -> NSImage {
        let edge = 2 * r + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}


/// A menu item that runs a closure.
private final class ClosureItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let model = PanelModel()
    private var statusItem: NSStatusItem!
    private var panel: MenuPanel!
    private var hostView: PanelHostingView!
    private var panelTop: CGFloat = 0
    private var wantOn: Bool?        // what the user last asked for, until the script has applied it
    private var applying = false
    private var panelMonitors: [Any] = []
    private var ticker: Timer?
    private var fadeTimer: Timer?
    private var sigterm: DispatchSourceSignal?
    private var ticks = 0
    private var lastOn: Bool?
    private var lastIdle = 0.0
    private let screens = Screens()
    private var dimPlan: DimPlan?       // screens lowered after idle time; nil when not lowered
    private var previewPlan: DimPlan?   // same, during "Preview"
    private var dimT: Float = 0         // how far the current plan is applied (0 = normal, 1 = fully dimmed)
    private var supervising = false
    private let launchedAt = Date()
    private let alerter = Alerter()
    private var brightUntil = Date.distantPast   // after an alert, don't dim again right away
    private var didFinishLaunching = false
    private var launchedForAlert = false         // started only to show an alert: don't turn Cocaine on
    private var repeatTimer: Timer?
    private let speech = AVSpeechSynthesizer()
    private let board = AgentBoard()                 // what each AI session is doing, from the hooks
    private var batteryGuard = BatteryGuard()
    private var autoOn = AutoOn()
    private var triggerActive = false
    private let hotkeys = Hotkeys()
    private var pendingCommands: [URL] = []          // cocaine://on|off|… that arrived while the app was still starting
    private var iconLevel: CGFloat = -1   // -1 = not drawn yet
    private var iconAnim: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        model.toggleCocaine = { [weak self] in self?.toggleCocaine() }
        model.preview = { [weak self] in self?.preview() }
        model.setLogin = { [weak self] in self?.setLogin($0) }
        model.setAI = { [weak self] in self?.setAI($0, $1) }
        model.pauseAlerts = { [weak self] in self?.pauseAlerts(until: $0) }
        model.testAlert = { [weak self] in
            self?.hidePanel()
            self?.alert(Notice(from: "Cocaine", message: L("This is a test"), project: nil), away: true, test: true)
        }
        model.previewVoice = { [weak self] in self?.speak("Claude Code, " + L("has finished")) }
        model.clearHistory = { [weak self] in
            self?.settings.alertHistory = []
            self?.model.history = []
        }
        model.timerChanged = { [weak self] in self?.timerChanged() }
        model.hotkeysChanged = { [weak self] in self?.applyHotkeys() }
        model.copyRemoteCommand = { [weak self] in self?.copyRemoteCommand() }
        model.sendShortcut = { [weak self] in self?.sendShortcutToPhone() }
        model.testPhone = { Phone.send(L("This is a test")) }
        model.quit = { NSApp.terminate(nil) }
        model.languageChanged = { [weak self] in self?.refreshIcon(on: System.cocaineOn, animate: false) }
        hostView = PanelHostingView(rootView: PanelView(m: model))
        hostView.sizingOptions = [.intrinsicContentSize]
        hostView.onSizeChange = { [weak self] in DispatchQueue.main.async { self?.fitPanel(animated: true) } }
        panel = MenuPanel(content: hostView)

        for (id, saved) in settings.savedBrightness {   // quit or crashed while screens were lowered
            if let cur = screens.brightness(id), cur < saved { screens.setBrightness(id, saved) }
        }
        settings.savedBrightness = [:]
        UserDefaults.standard.removeObject(forKey: "savedBrightness")   // pre-1.6 single-display key

        signal(SIGTERM, SIG_IGN)                     // quit cleanly (restoring brightness) on kill/pkill
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }
        sigterm?.resume()

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        tick()
        didFinishLaunching = true
        applyHotkeys()
        model.phone = Phone.configured ? Phone.summary : ""
        if launchedForAlert {                        // `open cocaine://…` started us: show it, then go away again
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
            return
        }
        if !System.cocaineOn { toggleCocaine() }     // opening the app turns Cocaine on
        pendingCommands.forEach(command)             // then whatever was asked for while it started
        pendingCommands = []
        DispatchQueue.global().async {
            AIHooks.update()
            let ai = AIHooks.status()
            DispatchQueue.main.async { self.model.ai = ai }   // ready before the panel first opens
        }
    }

    /// `cocaine://alert?from=Claude%20Code&event=done|input|error|start|agentstart|agentstop&session=<id>&project=<folder>`
    /// (or `&message=…`) from an AI agent's hook or any script; and control commands: `cocaine://on|off|toggle|panel`,
    /// `cocaine://timer?minutes=90`, `cocaine://pause?minutes=60`, `cocaine://resume` (for Shortcuts, scripts, hotkeys).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "cocaine" {
            guard url.host == "alert" else {
                if didFinishLaunching { command(url) } else { pendingCommands.append(url) }
                continue
            }
            if !didFinishLaunching { launchedForAlert = true }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            // Anything can open a cocaine:// URL: keep values short and free of control characters.
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value.flatMap { raw in
                    let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : $0 }))
                    let clean = String(cleaned.prefix(name == "message" ? 200 : 80)).trimmingCharacters(in: .whitespaces)
                    return clean.isEmpty ? nil : clean
                }
            }
            let trusted = value("token") == settings.testToken                  // only the app's own tools know it
            let from = value("from") ?? "Cocaine"
            let project = value("project").flatMap { $0 == "/" || $0 == NSUserName() ? nil : $0 }   // not a real project
            let session = value("session") ?? "\(from)|\(project ?? "")"   // tools that don't say: one per AI and folder
            let event = value("event") ?? "done"
            if trusted && value("test") == "phone" { Phone.send(value("message") ?? L("This is a test")); continue }
            if let running = value("running").flatMap(Int.init) {    // the tool's own list of work still in flight
                var s = sessions[session] ?? SessionState()
                s.inFlight = running
                sessions[session] = s
            }
            let isTest = trusted && value("test") != nil
            if event == "error" {                                    // an agent stopped with an error
                if !isTest { boardSet(session, from, project, "error") }
                if settings.alertError { alert(Notice(from: from, message: value("message") ?? L("stopped with an error"), project: project),
                                                away: trusted && value("test") == "away" ? true : nil) }
                continue
            }
            if event != "done" && event != "input" {                 // silent signs of life: prompts, agents and tasks
                if !isTest, ["start", "agentstart", "taskstart"].contains(event) { boardSet(session, from, project, "working") }
                activity(session, event)
                continue
            }
            let input = event == "input"
            if value("message") == nil && !(input ? settings.alertInput : settings.alertDone) {   // alerts of this kind are off
                if !isTest { boardSet(session, from, project, input ? "waiting" : "done") }
                continue
            }
            let message = value("message") ?? (input ? L("needs your input") : L("has finished"))
            let notice = Notice(from: from, message: message, project: project)
            if value("message") == nil && !input && settings.alertPerSession && !isTest {
                boardSet(session, from, project, "working")        // still counts as at work until it stays quiet
                holdUntilQuiet(session, notice)                    // one alert when the whole session is done
                continue
            }
            if !isTest { boardSet(session, from, project, input ? "waiting" : "done") }
            if input, var s = sessions[session] {                 // it needs you now; "done" will come again later
                s.timer?.cancel(); s.notice = nil; sessions[session] = s
            }
            alert(notice, away: trusted && value("test") == "away" ? true : nil)
        }
    }

    /// The control commands above.
    private func command(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let minutes = items.first { $0.name == "minutes" }?.value.flatMap(Int.init).map { min(max($0, 1), 1440) }
        log.notice("command \(url.host ?? "", privacy: .public)")
        switch url.host {
        case "on": autoOn.userToggled(to: true, triggerActive: triggerActive); setCocaine(true)
        case "off": autoOn.userToggled(to: false, triggerActive: triggerActive); setCocaine(false)
        case "toggle": toggleCocaine()
        case "timer": autoOn.userToggled(to: true, triggerActive: triggerActive); setCocaine(true, forMinutes: minutes ?? (settings.timerMinutes > 0 ? settings.timerMinutes : 60))
        case "pause": pauseAlerts(until: Date().addingTimeInterval(Double(minutes ?? 60) * 60))
        case "resume": pauseAlerts(until: nil)
        case "panel": if !panel.isVisible { showPanel(fromClick: false) }
        default: break
        }
    }

    private func boardSet(_ session: String, _ from: String, _ project: String?, _ state: String) {
        board.set(session, from: from, project: project, state: state)
        writeBoard()
    }

    private func writeBoard() {
        board.prune()
        model.board = board.entries
        board.write(cocaineOn: System.cocaineOn, until: settings.onUntil)
    }

    /// Per session: agents and tasks still running, its last sign of life, and a "finished" on hold. `inFlight` is the
    /// tool's own count of work still in flight (Claude Code sends it); when known, it replaces counting agents.
    private struct SessionState {
        var agents = 0, tasks = 0
        var inFlight: Int?
        var touched = Date()
        var notice: Notice?
        var timer: DispatchWorkItem?
        var busy: Bool { inFlight.map { $0 > 0 } ?? (agents + tasks > 0) }
        /// With the tool's own count a short wait is enough; by counting agents alone, wait out the ~30 s gaps an
        /// active session has between steps.
        var quietSeconds: Double { inFlight == nil ? 60 : 20 }
    }
    private var sessions: [String: SessionState] = [:]

    /// Agents or tasks starting and ending: counted, and (like any sign of life) they push a held "finished" back.
    private func activity(_ key: String, _ event: String) {
        var s = sessions[key] ?? SessionState()
        switch event {
        case "agentstart": s.agents += 1
        case "agentstop": s.agents = max(0, s.agents - 1)
        case "taskstart": s.tasks += 1
        case "taskstop": s.tasks = max(0, s.tasks - 1)
        default: break
        }
        s.touched = Date()
        sessions[key] = s
        log.notice("session \(key, privacy: .public) \(event, privacy: .public): \(s.agents, privacy: .public) agent(s), \(s.tasks, privacy: .public) task(s)")
        if s.notice != nil { rearm(key) }
    }

    /// Holds a session's "finished": it's shown once nothing of that session is running and it has had no sign of
    /// life for `quietSeconds`; every new event starts the wait again.
    private func holdUntilQuiet(_ key: String, _ n: Notice) {
        sessions = sessions.filter { Date().timeIntervalSince($0.value.touched) < 6 * 3600 }   // forget old sessions
        var s = sessions[key] ?? SessionState()
        s.notice = n
        s.touched = Date()
        sessions[key] = s
        rearm(key)
    }

    private func rearm(_ key: String) {
        guard var s = sessions[key] else { return }
        s.timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let s = self.sessions[key], let n = s.notice else { return }
            let quiet = Date().timeIntervalSince(s.touched)
            let busy = s.busy && quiet < 1800                   // a count stuck by a lost "ended" gives up after 30 min
            if quiet < s.quietSeconds - 0.5 || busy {
                log.notice("session \(key, privacy: .public) still working (in flight: \(s.inFlight.map(String.init) ?? "?", privacy: .public), agents: \(s.agents, privacy: .public)): holding")
                self.rearm(key)
                return
            }
            self.sessions[key] = nil
            self.boardSet(key, n.from, n.project, "done")
            self.alert(n)
        }
        s.timer = work
        sessions[key] = s
        DispatchQueue.main.asyncAfter(deadline: .now() + s.quietSeconds, execute: work)
    }

    struct Notice { let from: String, message: String, project: String? }

    /// Away from the Mac (idle 20 s, or screens dimmed), or always if the user wants: wake the screens, restore the
    /// brightness, flash them with the message, play the sound, read it aloud. At the Mac: just refill the baggie.
    private func alert(_ a: Notice, away forced: Bool? = nil, repeated: Bool = false, test: Bool = false) {
        if let until = settings.alertsPausedUntil, forced == nil {
            log.notice("alert from \(a.from, privacy: .public) muted until \(until, privacy: .public)")
            return
        }
        let away = forced ?? (System.idleSeconds >= 20 || dimPlan != nil)
        log.notice("alert from \(a.from, privacy: .public) project \(a.project ?? "-", privacy: .public) (away: \(away, privacy: .public), repeated: \(repeated, privacy: .public))")
        if !repeated && !test {                          // "Recent alerts"
            settings.alertHistory = [AlertRecord(from: a.from, message: a.message, project: a.project, at: Date())]
                + settings.alertHistory
            model.history = settings.alertHistory
        }
        pulseIcon()
        if away && !repeated && !test && Phone.configured {
            Phone.send([a.from, a.message, a.project].compactMap { $0 }.joined(separator: " · "))
        }
        guard away || settings.alertWhenPresent else { return }
        if settings.alertFlash {
            var activity: IOPMAssertionID = 0            // wakes a sleeping display
            IOPMAssertionDeclareUserActivity("Cocaine alert" as CFString, kIOPMUserActiveLocal, &activity)
            restore()
            brightUntil = Date().addingTimeInterval(max(settings.delay, 60))
            alerter.show(title: a.from, message: a.message, detail: a.project, seconds: settings.alertDuration)
        }
        if !settings.alertSound.isEmpty { NSSound(named: settings.alertSound)?.play() }
        if settings.alertSpeak { speak([a.from, a.message, a.project].compactMap { $0 }.joined(separator: ", ")) }
        if away && settings.alertRepeatMinutes > 0 && !repeated && !test { repeatUntilBack(a) }
    }

    /// Every few minutes (the user's choice), for up to 30 minutes, as long as nobody has touched the Mac since.
    private func repeatUntilBack(_ a: Notice) {
        repeatTimer?.invalidate()
        let minutes = settings.alertRepeatMinutes
        var count = 0
        let t = Timer(timeInterval: Double(minutes * 60), repeats: true) { [weak self] t in
            count += 1
            guard let self, count * minutes <= 30, System.idleSeconds >= Double(minutes * 60 - 10),
                  self.settings.alertRepeatMinutes == minutes else { t.invalidate(); return }
            self.alert(a, away: true, repeated: true)
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    private func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = Voices.voice(settings.alertVoice)
        speech.stopSpeaking(at: .immediate)                 // a new alert (or preview) replaces the one being read
        speech.speak(u)
    }

    private func pauseAlerts(until: Date?) {
        settings.alertsPausedUntil = until
        model.alertsPausedUntil = settings.alertsPausedUntil
        if until != nil { repeatTimer?.invalidate() }
    }

    /// The fill animation again, as a small "something happened" in the menu bar.
    private func pulseIcon() {
        guard System.cocaineOn else { return }
        iconLevel = 0.2
        refreshIcon(on: true)
    }

    /// Quitting (Quit button, ⌘Q, logout, shutdown) turns Cocaine off, just as opening the app turns it on.
    func applicationWillTerminate(_ n: Notification) {
        fadeTimer?.invalidate()
        if let plan = dimPlan ?? previewPlan { apply(plan, 0); if !plan.gamma.isEmpty { screens.restoreGamma() } }
        settings.savedBrightness = [:]
        if System.cocaineOn && !launchedForAlert { engine("off") }
    }

    /// Opening Cocaine again (e.g. from Spotlight) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // An `open` right after launch (Homebrew reopening the app after an upgrade) isn't a request for the panel.
        guard Date().timeIntervalSince(launchedAt) > 5 else { return false }
        if !panel.isVisible { showPanel(fromClick: false) }
        return false
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel(fromClick: true) }
    }

    /// Opens the panel under the icon that was clicked. With several screens the icon is in every screen's menu bar,
    /// so the click position, not the icon's own window, says which one.
    private func showPanel(fromClick: Bool) {
        refreshPanelState()
        let mouse = NSEvent.mouseLocation
        let clicked = fromClick ? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } : nil
        var screen = clicked ?? NSScreen.main
        var anchorX = mouse.x
        if let button = statusItem.button, let bar = button.window {
            let icon = bar.convertToScreen(button.convert(button.bounds, to: nil))
            if clicked == nil || clicked == bar.screen { screen = bar.screen ?? screen; anchorX = icon.midX }
        }
        guard let screen else { return }
        panelTop = (screen.visibleFrame.maxY - 6).rounded()          // just under that screen's menu bar
        fitPanel(animated: false, centeredOn: anchorX, screen: screen)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        // Clicks elsewhere close it; a click on the icon itself (which also arrives here on macOS 27) toggles instead.
        let iconZone = NSRect(x: anchorX - 18, y: screen.frame.maxY - 44, width: 36, height: 44)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            if !iconZone.contains(NSEvent.mouseLocation) { self?.hidePanel() }
        }) { panelMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { self?.hidePanel(); return nil }   // Esc
            return e
        }) { panelMonitors.append(m) }
    }

    /// Sizes the panel to its content with the top edge fixed under the icon, so it only grows or shrinks downward.
    private func fitPanel(animated: Bool, centeredOn midX: CGFloat? = nil, screen: NSScreen? = nil) {
        guard panel.isVisible || midX != nil else { return }
        hostView.layoutSubtreeIfNeeded()
        let size = hostView.fittingSize
        guard size.height > 0 else { return }
        var frame = NSRect(x: panel.frame.minX, y: panelTop - size.height, width: size.width, height: size.height)
        if let midX {
            frame = Self.panelFrame(size: size, anchorX: midX, top: panelTop,
                                    visible: (screen ?? NSScreen.main)?.visibleFrame ?? .zero)
        }
        guard frame != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// Centred under the icon, kept 8 pt inside the screen it opens on.
    static func panelFrame(size: NSSize, anchorX: CGFloat, top: CGFloat, visible: NSRect) -> NSRect {
        let x = min(max(anchorX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8).rounded()
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    private func hidePanel() {
        panelMonitors.forEach(NSEvent.removeMonitor)
        panelMonitors.removeAll()
        panel.orderOut(nil)
        NSCursor.arrow.set()                                // in case it closed with the pointer on the mirror
        statusItem.button?.highlight(false)
    }

    private func refreshPanelState() {
        let login = SMAppService.mainApp.status == .enabled
        if model.loginEnabled != login { model.loginEnabled = login }
        let on = System.cocaineOn
        DispatchQueue.global().async {
            let missing = on && !System.displayHeld
            let ai = AIHooks.status()
            let ssh = System.sshOn
            DispatchQueue.main.async {
                if self.model.holdMissing != missing { self.model.holdMissing = missing }
                if missing { self.superviseHold() }
                if !self.model.settingAI && self.model.ai != ai { self.model.ai = ai }
                let paused = self.settings.alertsPausedUntil   // a pause ends by itself
                if self.model.alertsPausedUntil != paused { self.model.alertsPausedUntil = paused }
                if self.model.sshOn != ssh { self.model.sshOn = ssh }
                let phone = Phone.configured ? Phone.summary : ""
                if self.model.phone != phone { self.model.phone = phone }
                self.model.battery = System.battery.map { "\($0.percent)%" }
            }
        }
    }

    /// Connects or disconnects one AI tool (adds or removes its hooks); its tick flips at once.
    private func setAI(_ id: String, _ enable: Bool) {
        guard !model.settingAI, let tool = AIHooks.tool(id) else { return }
        model.settingAI = true
        if let i = model.ai.tools.firstIndex(where: { $0.id == id }) { model.ai.tools[i].on = enable }
        DispatchQueue.global().async {
            let failed = AIHooks.set(enable, only: [tool])
            let ai = AIHooks.status()
            DispatchQueue.main.async {
                self.model.settingAI = false
                self.model.ai = ai
                log.notice("AI alerts for \(id, privacy: .public) \(enable ? "on" : "off", privacy: .public), failed: \(failed.count, privacy: .public)")
                guard !failed.isEmpty else { return }
                self.hidePanel()
                NSApp.activate()
                let a = NSAlert()
                a.messageText = L("Can't change AI alerts")
                a.informativeText = failed.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: "\n")
                a.runModal()
            }
        }
    }

    // MARK: State

    private func tick() {
        ticks += 1
        let on = System.cocaineOn
        if on != lastOn {
            lastOn = on
            refreshIcon(on: on)
            if on { superviseHold() }
        } else if on && ticks % 20 == 0 {
            superviseHold()                          // every 10 s
        }
        if wantOn == nil && model.on != on { model.on = on }   // don't fight a switch the user just flipped
        if panel.isVisible && ticks % 4 == 0 { refreshPanelState() }
        if alerter.isShowing, let at = alerter.shownAt, Date().timeIntervalSince(at) > 1.5, System.idleSeconds < 0.6 {
            alerter.close(animated: true)            // the user is back
        }
        updateDimming(on: on)
        if ticks % 4 == 0 { checkTimer(on) }                     // every 2 s
        if ticks % 10 == 0 { evaluateTriggers(on) }              // every 5 s
        if ticks % 20 == 0 { checkBattery(on); writeBoard() }    // every 10 s
    }

    // MARK: Timer, Battery Guard, Smart Triggers, hotkeys

    /// Turns Cocaine off when its time is up (a timer from the panel, `cocaine://timer` or `cocaine remote on --for`).
    private func checkTimer(_ on: Bool) {
        let until = settings.onUntil
        if model.onUntil != until { model.onUntil = until }
        guard wantOn == nil else { return }
        if on, let until, Date() >= until {
            settings.onUntil = nil
            model.onUntil = nil
            autoOn.userToggled(to: false, triggerActive: triggerActive)     // a trigger doesn't undo it at once
            setCocaine(false, auto: true)
            log.notice("timer over: Cocaine off")
            alert(Notice(from: "Cocaine", message: L("Timer over: Cocaine is off"), project: nil), away: true)
        } else if !on && until != nil {
            settings.onUntil = nil                               // a deadline with nothing to end
            model.onUntil = nil
        }
    }

    /// On battery power, at the chosen level: turn Cocaine off (or just warn), once until the battery recovers.
    private func checkBattery(_ on: Bool) {
        let b = System.battery
        model.battery = b.map { "\($0.percent)%" }
        guard let b else { return }
        guard batteryGuard.check(percent: b.percent, onAC: b.onAC, threshold: settings.batteryThreshold), on else { return }
        log.notice("battery at \(b.percent, privacy: .public)%")
        if settings.batteryTurnsOff {
            autoOn.userToggled(to: false, triggerActive: triggerActive)
            setCocaine(false, auto: true)
            alert(Notice(from: "Cocaine", message: String(format: L("Battery at %d%%: Cocaine is off"), b.percent), project: nil), away: true)
        } else {
            alert(Notice(from: "Cocaine", message: String(format: L("Battery at %d%%"), b.percent), project: nil), away: true)
        }
    }

    /// Smart Triggers: an AI at work (from the hooks), or a chosen program running, keeps Cocaine on.
    private func evaluateTriggers(_ on: Bool) {
        var active = settings.triggerAgents && board.anyLive()
        let apps = settings.triggerApps.map { $0.lowercased() }
        if !active && !apps.isEmpty {
            let names = System.runningNames()
            active = apps.contains { names.contains($0) }
        }
        triggerActive = active
        switch autoOn.step(active: active, isOn: wantOn ?? on, now: Date()) {
        case .turnOn: log.notice("smart trigger: on"); setCocaine(true, auto: true)
        case .turnOff: log.notice("smart trigger: off"); setCocaine(false, auto: true)
        case .none: break
        }
    }

    private func timerChanged() {
        guard System.cocaineOn || model.on else { return }
        let minutes = settings.timerMinutes
        settings.onUntil = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil    // applies to now
        model.onUntil = settings.onUntil
    }

    /// ⌃⌥⌘C toggles Cocaine, ⌃⌥⌘O opens the panel, ⌃⌥⌘P pauses (or resumes) alerts.
    private func applyHotkeys() {
        hotkeys.set(enabled: settings.hotkeys) { [weak self] id in
            guard let self else { return }
            switch id {
            case 1: self.toggleCocaine()
            case 2: if self.panel.isVisible { self.hidePanel() } else { self.showPanel(fromClick: false) }
            case 3: self.pauseAlerts(until: self.settings.alertsPausedUntil == nil ? Date().addingTimeInterval(3600) : nil)
            default: break
            }
        }
    }

    /// Builds the iPhone Shortcut and opens the share sheet (AirDrop, Messages, Mail…) on it.
    private func sendShortcutToPhone() {
        model.makingShortcut = true
        DispatchQueue.global().async {
            let file = PhoneShortcut.signedFile()
            DispatchQueue.main.async {
                self.model.makingShortcut = false
                guard let file else {
                    self.hidePanel(); NSApp.activate()
                    let a = NSAlert()
                    a.messageText = L("Can't make the Shortcut")
                    a.informativeText = L("Signing it needs an internet connection and iCloud (sign in to it in System Settings).")
                    a.runModal()
                    return
                }
                self.presentShare(file)
                log.notice("shortcut ready to share: \(file.lastPathComponent, privacy: .public)")
            }
        }
    }

    /// A menu of the ways to share the file (AirDrop, Messages, Mail, Notes…) plus "Show in Finder". The panel closes and
    /// the app becomes active first: the sharing windows (AirDrop's, Notes') can't open from a panel that isn't.
    private var shareServices: [NSSharingService] = []
    private func presentShare(_ file: URL) {
        hidePanel()
        NSApp.activate()
        shareServices = NSSharingService.sharingServices(forItems: [file])
        let menu = NSMenu()
        for service in shareServices {
            let item = ClosureItem(title: service.title) { service.perform(withItems: [file]) }
            item.image = service.image
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureItem(title: L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([file]) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The command to run from a phone (a terminal or Shortcuts' "Run Script Over SSH").
    private func copyRemoteCommand() {
        let host = (Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        let local = ProcessInfo.processInfo.hostName.hasSuffix(".local") ? ProcessInfo.processInfo.hostName : "\(host.replacingOccurrences(of: " ", with: "-")).local"
        let text = "ssh \(NSUserName())@\(local) '\(scriptPath) remote status'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Fills the baggie gradually when Cocaine turns on, empties it when it turns off.
    private func refreshIcon(on: Bool, animate: Bool = true) {
        guard let b = statusItem.button else { return }
        b.toolTip = on ? L("Cocaine is on") : L("Cocaine is off")
        b.setAccessibilityLabel(b.toolTip)
        guard animate else { return }
        let target: CGFloat = on ? 1 : 0
        iconAnim?.invalidate()
        guard iconLevel >= 0 else { setIconLevel(target, pouring: false); return }   // first draw: no animation
        let start = iconLevel, duration = on ? 1.4 : 0.7
        let began = Date()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let f = min(1, CGFloat(Date().timeIntervalSince(began) / duration))
            let eased = on ? 1 - (1 - f) * (1 - f) : f * f                 // ease-out filling, ease-in emptying
            self.setIconLevel(start + (target - start) * eased, pouring: on && f < 1)
            if f >= 1 { t.invalidate(); self.iconAnim = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        iconAnim = t
    }

    private func setIconLevel(_ level: CGFloat, pouring: Bool) {
        iconLevel = level
        statusItem.button?.image = Baggie.image(level: level, pouring: pouring)
        model.fillLevel = level
        if model.pouring != pouring { model.pouring = pouring }
    }

    /// While Cocaine is on, make sure the script's display helper runs (it doesn't after a restart).
    private func superviseHold() {
        guard !supervising else { return }
        supervising = true
        DispatchQueue.global().async {
            let missing = System.cocaineOn && !System.displayHeld
            if missing { engine("on") }
            DispatchQueue.main.async {
                self.supervising = false
                if missing { log.notice("display hold was missing; restarted it") }
                if self.panel.isVisible { self.refreshPanelState() }
            }
        }
    }

    /// Flips the switch at once and applies it in the background; clicks made meanwhile are never lost.
    private func toggleCocaine() {
        let target = !(wantOn ?? model.on)
        autoOn.userToggled(to: target, triggerActive: triggerActive)
        setCocaine(target)
    }

    /// Sets Cocaine on or off. By hand it also starts the chosen timer (or `forMinutes`); a trigger, the timer itself or
    /// the battery guard (`auto`) leaves the deadline alone.
    private func setCocaine(_ target: Bool, auto: Bool = false, forMinutes: Int? = nil) {
        wantOn = target
        model.on = target
        if !auto {
            let minutes = forMinutes ?? settings.timerMinutes
            settings.onUntil = target && minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
            model.onUntil = settings.onUntil
        }
        applyWanted()
    }

    private func applyWanted() {
        guard !applying, let target = wantOn else { return }
        applying = true
        DispatchQueue.global().async {
            let arg = target ? "on" : "off"
            var status = engine(arg)
            if status == 2, Authorization.install() {   // first run on this Mac: ask for the admin password once
                log.notice("sudo rule installed")
                status = engine(arg)
            }
            DispatchQueue.main.async {
                self.applying = false
                self.model.needsAuth = status == 2
                if self.wantOn == target { self.wantOn = nil }
                self.tick()                          // shows the real state (reverts the switch if it failed)
                self.refreshPanelState()
                self.applyWanted()                   // the user changed their mind while this was running
            }
        }
    }

    // MARK: Dimming

    private func updateDimming(on: Bool) {
        guard previewPlan == nil else { return }
        let idle = System.idleSeconds
        defer { lastIdle = idle }
        if let plan = dimPlan {
            let unplugged = !plan.displays.isSubset(of: Set(screens.online))
            if idle < lastIdle || !on || !settings.dimEnabled || unplugged { restore(); return }   // input since last tick
            // automatic brightness can creep back up while the screen is lowered
            if ticks % 10 == 0, fadeTimer == nil {
                for b in plan.backlit where (screens.brightness(b.id) ?? 0) > b.to + 0.02 { screens.setBrightness(b.id, b.to) }
            }
        } else if on, settings.dimEnabled, idle >= settings.delay, Date() > brightUntil {
            dim(afterIdle: idle)
        }
    }

    /// Every screen that's on: the built-in panel is skipped only with the lid shut (it's off anyway).
    private func makePlan(level: Float) -> DimPlan {
        var plan = DimPlan()
        let lidClosed = System.lidClosed
        for d in screens.online {
            if CGDisplayIsBuiltin(d) != 0 && lidClosed { continue }
            if screens.hasBacklight(d) {
                if let cur = screens.brightness(d), cur > level { plan.backlit.append(.init(id: d, from: cur, to: level)) }
            } else {
                plan.gamma.append((d, 0.12 + 0.88 * level))           // software: dimmed, never black
            }
        }
        return plan
    }

    private func dim(afterIdle idle: Double) {
        let plan = makePlan(level: settings.level)
        dimPlan = plan                                              // even if empty, so we don't retry every tick
        settings.savedBrightness = Dictionary(uniqueKeysWithValues: plan.backlit.map { ($0.id, $0.from) })
        log.notice("dim \(plan.backlit.count, privacy: .public) backlit + \(plan.gamma.count, privacy: .public) gamma screens after \(Int(idle), privacy: .public)s idle")
        fade(plan, to: 1, over: 1.5)
    }

    private func restore() {
        guard let plan = dimPlan else { return }
        dimPlan = nil
        settings.savedBrightness = [:]
        log.notice("restore \(plan.displays.count, privacy: .public) screens")
        fade(plan, to: 0, over: 0.25) { if !plan.gamma.isEmpty { self.screens.restoreGamma() } }
    }

    /// Puts every screen in `plan` at `t` (0 = as it was, 1 = fully dimmed).
    private func apply(_ plan: DimPlan, _ t: Float) {
        dimT = t
        for b in plan.backlit { screens.setBrightness(b.id, b.from + (b.to - b.from) * t) }
        for g in plan.gamma { screens.setGamma(g.id, 1 + (g.to - 1) * t) }
    }

    private func fade(_ plan: DimPlan, to target: Float, over seconds: Double, then done: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        let start = dimT
        let steps = max(1, Int(seconds / 0.025))
        var i = 0
        let t = Timer(timeInterval: seconds / Double(steps), repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            i += 1
            let f = Float(i) / Float(steps)
            self.apply(plan, start + (target - start) * f * f * (3 - 2 * f))   // smoothstep
            if i >= steps { t.invalidate(); self.fadeTimer = nil; done?() }
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    private func preview() {
        guard previewPlan == nil, dimPlan == nil else { return }
        let plan = makePlan(level: settings.level)
        previewPlan = plan
        settings.savedBrightness = Dictionary(uniqueKeysWithValues: plan.backlit.map { ($0.id, $0.from) })
        model.previewing = true
        fade(plan, to: 1, over: 0.6) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.fade(plan, to: 0, over: 0.4) {
                    if !plan.gamma.isEmpty { self.screens.restoreGamma() }
                    self.previewPlan = nil
                    self.settings.savedBrightness = [:]
                    self.model.previewing = false
                }
            }
        }
    }

    private func setLogin(_ enable: Bool) {
        let svc = SMAppService.mainApp
        do {
            if enable { try svc.register() } else { try svc.unregister() }
            if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            hidePanel()
            NSApp.activate()
            let a = NSAlert()
            a.messageText = L("Can't change Open at Login")
            a.informativeText = "\(error.localizedDescription)\n\n" + L("You can add Cocaine manually in System Settings → General → Login Items.")
            a.runModal()
        }
        model.loginEnabled = svc.status == .enabled
    }
}

// MARK: - Entry point

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--auth-selftest" {
    // Runs the exact install pipeline (AppleScript quoting, printf, visudo, install) without admin rights,
    // writing the rule to the given file instead of /etc/sudoers.d.
    let cmd = Authorization.installCommand(user: NSUserName(), dest: CommandLine.arguments[2], asRoot: false)!
    exit(run("/usr/bin/osascript", ["-e", Authorization.appleScript(for: cmd, admin: false)]))
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--layout-test" {
    // Where the panel lands for a click on the icon of each screen, for two-monitor layouts.
    let size = NSSize(width: 312, height: 198)
    let layouts: [(String, NSRect, CGFloat)] = [   // name, visible frame (below its menu bar), click x
        ("MacBook, icon near right edge", NSRect(x: 0, y: 0, width: 1512, height: 945), 1460),
        ("external on the right",         NSRect(x: 1512, y: -200, width: 2560, height: 1415), 3900),
        ("external on the left",          NSRect(x: -1920, y: 0, width: 1920, height: 1055), -60),
        ("external above",                NSRect(x: 0, y: 982, width: 1920, height: 1055), 1850),
    ]
    for (name, vis, x) in layouts {
        let f = AppDelegate.panelFrame(size: size, anchorX: x, top: vis.maxY - 6, visible: vis)
        print("\(name): panel \(f.debugDescription)  inside that screen: \(vis.contains(f))")
    }
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--gamma-test" {
    // Software dimming on the main screen for a moment (what non-Apple monitors get), then restored.
    let d = CGMainDisplayID(), screens = Screens()
    func maxRed() -> Float {
        var rMin: CGGammaValue = 0, rMax: CGGammaValue = 0, rG: CGGammaValue = 0, gMin: CGGammaValue = 0, gMax: CGGammaValue = 0
        var gG: CGGammaValue = 0, bMin: CGGammaValue = 0, bMax: CGGammaValue = 0, bG: CGGammaValue = 0
        CGGetDisplayTransferByFormula(d, &rMin, &rMax, &rG, &gMin, &gMax, &gG, &bMin, &bMax, &bG)
        return rMax
    }
    print("before: \(maxRed())")
    screens.setGamma(d, 0.4); usleep(800_000); print("dimmed: \(maxRed())")
    screens.restoreGamma(); usleep(200_000); print("restored: \(maxRed())")
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--auth-preview" {
    // Shows the admin prompt without running anything (to check how it looks).
    _ = NSApplication.shared
    exit(Authorization.authorize(prompt: L("Cocaine needs your permission once, to keep your Mac awake.")) { _ in true } ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--remove-rule" {
    _ = NSApplication.shared
    exit(Authorization.remove() ? 0 : 1)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--share-test" {
    // Activates the app and performs a sharing service ("airdrop" or "notes") on the signed shortcut, then reports the
    // windows that appear (for tests).
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let file = PhoneShortcut.signedFile() else { print("could not sign"); exit(1) }
    app.activate()
    let services = NSSharingService.sharingServices(forItems: [file])
    print("services: " + services.map(\.title).joined(separator: ", "))
    guard let service = services.first(where: { $0.title.lowercased().contains(CommandLine.arguments[2]) }) else { print("no such service"); exit(1) }
    service.perform(withItems: [file])
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
        let windows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
            
        print("windows: \(windows.filter { ($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0 > 100 }.map { "\($0[kCGWindowOwnerName as String] ?? "")/\($0[kCGWindowName as String] ?? "")" })")
        exit(0)
    }
    app.run()
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--make-shortcut" {
    // Builds and signs the iPhone Shortcut, copies it to the given path (for tests).
    guard let f = PhoneShortcut.signedFile() else { print("could not sign"); exit(1) }
    try? FileManager.default.removeItem(atPath: CommandLine.arguments[2])
    try? FileManager.default.copyItem(at: f, to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("ok \(PhoneShortcut.host)")
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--selftest" {
    // The pure automation logic: battery guard, smart triggers, agent board. Prints PASS/FAIL lines.
    var failed = 0
    func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
    var g = BatteryGuard()
    check("battery: off threshold never fires", !g.check(percent: 5, onAC: false, threshold: 0))
    check("battery: above threshold is quiet", !g.check(percent: 40, onAC: false, threshold: 20))
    check("battery: fires at the threshold", g.check(percent: 20, onAC: false, threshold: 20))
    check("battery: fires only once while it stays low", !g.check(percent: 15, onAC: false, threshold: 20))
    check("battery: not re-armed by a small recovery", !g.check(percent: 22, onAC: false, threshold: 20) && !g.check(percent: 19, onAC: false, threshold: 20))
    check("battery: plugging in re-arms it", !g.check(percent: 19, onAC: true, threshold: 20) && g.check(percent: 19, onAC: false, threshold: 20))
    check("battery: never fires on power", { var x = BatteryGuard(); return !x.check(percent: 3, onAC: true, threshold: 30) }())
    var a = AutoOn(); let t0 = Date()
    check("trigger: nothing active, nothing to do", a.step(active: false, isOn: false, now: t0) == .none)
    check("trigger: active and off → turn on", a.step(active: true, isOn: false, now: t0) == .turnOn)
    check("trigger: stays on while active", a.step(active: true, isOn: true, now: t0 + 60) == .none)
    check("trigger: waits out the grace period", a.step(active: false, isOn: true, now: t0 + 120) == .none)
    check("trigger: off after 3 quiet minutes", a.step(active: false, isOn: true, now: t0 + 61 + 180) == .turnOff)
    var b = AutoOn()
    _ = b.step(active: true, isOn: false, now: t0)
    b.userToggled(to: false, triggerActive: true)
    check("trigger: user's OFF is respected while active", b.step(active: true, isOn: false, now: t0 + 10) == .none)
    check("trigger: …until the trigger has gone away", b.step(active: false, isOn: false, now: t0 + 20) == .none && b.step(active: true, isOn: false, now: t0 + 30) == .turnOn)
    var c = AutoOn()
    check("trigger: a manual ON is never turned off by it", { _ = c.step(active: true, isOn: true, now: t0); return c.step(active: false, isOn: true, now: t0 + 999) == .none }())
    var d = AutoOn()
    _ = d.step(active: true, isOn: false, now: t0)
    d.userToggled(to: true, triggerActive: true)
    check("trigger: user takes over an auto-on", d.step(active: false, isOn: true, now: t0 + 999) == .none)
    let board = AgentBoard(); let now = Date()
    board.set("s1", from: "Claude Code", project: "x", state: "working", now: now)
    board.set("s2", from: "Codex", project: nil, state: "waiting", now: now)
    check("board: working and waiting are live", board.anyLive(now))
    board.set("s1", from: "Claude Code", project: "x", state: "done", now: now)
    board.set("s2", from: "Codex", project: nil, state: "done", now: now)
    check("board: nothing live when all are done", !board.anyLive(now))
    board.prune(now.addingTimeInterval(1900))
    check("board: finished sessions fade after 30 minutes", board.entries.isEmpty)
    board.set("s3", from: "Gemini CLI", project: nil, state: "working", now: now)
    board.prune(now.addingTimeInterval(7300))
    check("board: a 'working' nobody updated for 2 hours is dropped", board.entries.isEmpty)
    exit(failed == 0 ? 0 : 1)
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--ai-alerts" {
    // `on|off|status [tool ids…] [--home <dir>]` for the AI alerts hooks: every tool on this Mac unless ids are given.
    // The Homebrew uninstall runs `off`; --home works on a copy, for tests.
    var args = Array(CommandLine.arguments.dropFirst(3))
    if let i = args.firstIndex(of: "--home"), i + 1 < args.count { AIHooks.home = args[i + 1]; args.removeSubrange(i...i + 1) }
    switch CommandLine.arguments[2] {
    case "on", "off":
        let tools = args.isEmpty ? AIHooks.present : args.compactMap(AIHooks.tool)
        let failed = AIHooks.set(CommandLine.arguments[2] == "on", only: tools)
        failed.forEach { print("could not update \($0)") }
        exit(failed.isEmpty ? 0 : 1)
    default:
        let s = AIHooks.status()
        for t in s.tools { print("\(t.id): \(t.installed ? (t.on ? "on" : "off") : "not installed")") }
        print("codex needs trust: \(s.codexNeedsTrust)")
        exit(0)
    }
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-panel" {
    // Draws the panel offscreen to a PNG, in the language picked by -AppleLanguages, to check translations fit.
    _ = NSApplication.shared
    let model = PanelModel()
    model.persistLanguage = false
    let langArg = CommandLine.arguments.firstIndex(of: "--lang").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
    model.language = langArg ?? ""                  // never the user's saved choice: "" = same as the Mac
    model.on = !CommandLine.arguments.contains("--off")
    model.fillLevel = model.on ? 1 : 0
    model.needsAuth = CommandLine.arguments.contains("--needs-auth")
    model.holdMissing = CommandLine.arguments.contains("--hold-missing")
    // --ai-on connects the first two tools, --codex-trust shows the Codex reminder, --no-ai hides the row.
    model.ai = AIHooks.Status(tools: AIHooks.tools.enumerated().map { i, t in
        AIHooks.Entry(id: t.id, name: t.name, installed: !CommandLine.arguments.contains("--no-ai") && i < 3,
                      on: CommandLine.arguments.contains("--ai-on") && i < 2)
    }, codexNeedsTrust: CommandLine.arguments.contains("--codex-trust"))
    if CommandLine.arguments.contains("--paused") { model.alertsPausedUntil = Date().addingTimeInterval(3600) }
    model.aiExpanded = CommandLine.arguments.contains("--ai-open")
    if CommandLine.arguments.contains("--last") {                  // a sample "Recent alerts" list
        model.history = [("Claude Code", "has finished", "Cocaine", 0.0), ("Codex", "needs your input", "PneuSuperStore", 900),
                         ("Cursor", "has finished", "Gestionale", 4000)]
            .map { AlertRecord(from: $0.0, message: L($0.1), project: $0.2, at: Date().addingTimeInterval(-$0.3)) }
    }
    if let i = CommandLine.arguments.firstIndex(of: "--auto"), i + 1 < CommandLine.arguments.count {   // open a group of Automation
        model.autoExpanded = true
        model.autoGroup = CommandLine.arguments[i + 1] == "none" ? "" : CommandLine.arguments[i + 1]
        model.triggerAgents = true; model.triggerApps = ["Xcode"]; model.timerMinutes = 120; model.batteryThreshold = 20
        model.sshOn = !CommandLine.arguments.contains("--no-ssh"); model.battery = "80%"
        model.phone = "Comando Rapido “Avvisa iPhone”"
    }
    if CommandLine.arguments.contains("--agents") {
        let t = Date().timeIntervalSince1970
        model.board = [AgentEntry(id: "1", from: "Claude Code", project: "canonical-com", state: "working", since: t - 400),
                       AgentEntry(id: "2", from: "Codex", project: "PneuSuperStore", state: "waiting", since: t - 90),
                       AgentEntry(id: "3", from: "Cursor", project: "Gestionale", state: "error", since: t - 30)]
    }
    if let i = CommandLine.arguments.firstIndex(of: "--group"), i + 1 < CommandLine.arguments.count {
        model.aiGroup = CommandLine.arguments[i + 1]
    }
    let host = NSHostingView(rootView: PanelView(m: model).background(Color(nsColor: .windowBackgroundColor)))
    let size = host.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    if CommandLine.arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
    if CommandLine.arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    for key in ["timerMinutes", "batteryThreshold", "batteryTurnsOff", "triggerAgents", "triggerApps", "hotkeys", "onUntil"] {
        UserDefaults.standard.removeObject(forKey: key)     // the sample values above must not stay in the real settings
    }
    print(Bundle.main.preferredLocalizations.first ?? "?")
    exit(0)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-demo-gif" {
    Assets.renderDemoGIF(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-assets" {
    Assets.render(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
