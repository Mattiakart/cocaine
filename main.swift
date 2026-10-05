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
import Combine
import CoreAudio
import EventKit
import Carbon.HIToolbox
import Darwin
import ImageIO
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
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

    /// Per-feature string tables (Localization/<lang>.lproj/<Table>.strings) looked up after the main one, so features can be
    /// developed side by side without editing the same file.
    static let extraTables = ["Remote", "Agents", "Power", "Clipboard", "Updates", "Recovery"]

    static func text(_ key: String) -> String {
        let miss = "\u{0}missing"
        let v = bundle.localizedString(forKey: key, value: miss, table: nil)
        if v != miss { return v }
        for t in extraTables {
            let w = bundle.localizedString(forKey: key, value: miss, table: t)
            if w != miss { return w }
        }
        return key
    }
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
        // Also the scheduled wake-ups for the iPhone (only `schedule wake` and `schedule cancel wake`, tagged "cocaine").
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, "
            + "/usr/bin/pmset schedule wake * cocaine, /usr/bin/pmset schedule cancel wake * cocaine, "
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
            let args: [UnsafeMutablePointer<CChar>?] = [strdup("-c"), strdup(reporting(command)), nil]
            defer { args.forEach { free($0) } }
            var pipe: UnsafeMutablePointer<FILE>?
            let rc = args.withUnsafeBufferPointer { execute(auth, "/bin/sh", [], $0.baseAddress!, &pipe) }
            guard rc == errAuthorizationSuccess, let pipe else { return false }
            var output = ""
            var buffer = [CChar](repeating: 0, count: 256)
            while fgets(&buffer, 256, pipe) != nil { output += String(cString: buffer) }
            fclose(pipe)
            return succeeded(output)
        }
    }

    /// Wraps `command` so its exit status is always reported: it runs in a subshell, because commands like the install
    /// one end with `exit`, which would otherwise end the shell before the report line is printed.
    static func reporting(_ command: String) -> String { "( \(command)\n); echo \"rc=$?\"" }

    /// True only when the report line says the command exited 0; no report (cancelled, crashed, killed) is a failure.
    static func succeeded(_ output: String) -> Bool {
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("rc=") }) else { return false }
        return line == "rc=0"
    }

    /// Runs `reporting(command)` in a plain shell (no privileges) and says whether it succeeded: self-test only.
    static func runPlain(_ command: String) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", reporting(command)]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return succeeded(String(decoding: data, as: UTF8.self))
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

// MARK: - Permissions

/// Everything macOS makes Cocaine ask for. Each one is checked, and asked for only when it is missing.
private enum Permission: String, CaseIterable, Identifiable {
    case accessibility, camera, calendar, automation, files
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accessibility: return L("Accessibility")
        case .camera: return L("Camera")
        case .calendar: return L("Calendar")
        case .automation: return L("Music and Spotify")
        case .files: return L("Files and folders")
        }
    }
    var reason: String {
        switch self {
        case .accessibility: return L("Stay active and the system HUD need it.")
        case .camera: return L("The Mirror page can't show the camera.")
        case .calendar: return L("The Calendar page can't show your events.")
        case .automation: return L("Music and Spotify can't be controlled.")
        case .files: return L("Downloads and screenshots can't be read.")
        }
    }
    var pane: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .camera: return "Privacy_Camera"
        case .calendar: return "Privacy_Calendars"
        case .automation: return "Privacy_Automation"
        case .files: return "Privacy_FilesAndFolders"
        }
    }
}

private enum Permissions {
    enum State { case granted, denied, notAsked }
    static let musicApps = ["com.apple.Music", "com.spotify.client"]

    /// Never blocks: Files and Music/Spotify can only be known by trying (a folder listing that waits for the user's answer while
    /// macOS asks; an Apple-event check that can wait on the other app), so those two come from `probe`, run off the main thread.
    static func state(_ p: Permission) -> State {
        switch p {
        case .accessibility:
            // Stay active posts events (PostEvent) and the HUD keys need an event tap (Accessibility): both are the one switch
            // under Privacy & Security → Accessibility, but they are checked separately, so both must be there.
            return AXIsProcessTrusted() && CGPreflightPostEventAccess() ? .granted : .denied
        case .camera: return cameraState(AVCaptureDevice.authorizationStatus(for: .video))
        case .calendar: return calendarState(EKEventStore.authorizationStatus(for: .event))
        case .automation: return automationState
        case .files: return filesState
        }
    }

    static func cameraState(_ s: AVAuthorizationStatus) -> State {
        switch s { case .authorized: return .granted; case .notDetermined: return .notAsked; default: return .denied }
    }
    /// Full access only: "add events only" (write-only) can't show your events, so it counts as refused.
    static func calendarState(_ s: EKAuthorizationStatus) -> State {
        switch s { case .fullAccess: return .granted; case .notDetermined: return .notAsked; default: return .denied }
    }
    /// The answers of AEDeterminePermissionToAutomateTarget for the running music apps: the worst one counts; an app that isn't
    /// running (-600) or any other error says nothing.
    static func automationState(_ codes: [OSStatus]) -> State {
        codes.contains(-1743) ? .denied : codes.contains(-1744) ? .notAsked : .granted
    }

    private(set) static var automationState = State.granted
    private(set) static var filesState = State.notAsked
    private static let probeQueue = DispatchQueue(label: "local.cocaine.permissions")
    private static var waiting: [(Bool) -> Void]?          // non-nil while a probe runs

    /// Re-checks Files (Downloads and the screenshots folder) and Music/Spotify off the main thread; `done` on the main queue,
    /// with true when something changed. Listing a folder the first time is also what makes macOS ask (once) for it: only
    /// called while the island, whose Files page reads them, is on. One probe at a time (one may wait for an answer); a call
    /// while one runs just waits for it.
    static func probe(files: Bool, done: @escaping (Bool) -> Void = { _ in }) {
        dispatchPrecondition(condition: .onQueue(.main))
        if waiting != nil { waiting?.append(done); return }
        waiting = [done]
        let apps = runningMusicApps()
        probeQueue.async {
            let auto = automationState(apps.map { automation($0, ask: false) })
            var f: State?
            if files { f = canList(FileShelf.downloadsFolder) && canList(FileShelf.screenshotsFolder) ? .granted : .denied }
            DispatchQueue.main.async {
                let changed = auto != automationState || (f != nil && f != filesState)
                automationState = auto; if let f { filesState = f }
                let w = waiting ?? []
                waiting = nil
                w.forEach { $0(changed) }
            }
        }
    }

    private static func canList(_ dir: URL) -> Bool {
        do { _ = try FileManager.default.contentsOfDirectory(atPath: dir.path); return true }
        catch let e as NSError { return !(e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError) && (e.underlyingErrorCode != Int(EPERM)) && (e.underlyingErrorCode != Int(EACCES)) }
    }

    static func runningMusicApps() -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return musicApps.filter { running.contains($0) }
    }

    /// 0 allowed, -1743 refused, -1744 not asked yet, -600 the app isn't running. Never on the main thread (it can block).
    static func automation(_ bundle: String, ask: Bool) -> OSStatus {
        guard let desc = NSAppleEventDescriptor(bundleIdentifier: bundle).aeDesc else { return -600 }
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    static func openPane(_ p: Permission) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(p.pane)") { NSWorkspace.shared.open(u) }
    }

    /// Kept alive while macOS asks: a store that goes away cancels its own request.
    private static var asking: EKEventStore?

    /// Asks for it the right way: the system's own question when it was never asked, the Settings pane when it was refused.
    /// `done` is called on the main queue once the answer is known (at once when nothing could be asked). `explicit`: the user
    /// pressed Allow, so Accessibility also opens its Settings pane (the system's dialog may not come up a second time).
    static func request(_ p: Permission, explicit: Bool = false, done: (() -> Void)? = nil) {
        let st = state(p)
        guard st != .granted else { done?(); return }
        switch p {
        case .accessibility:
            // The system's dialog (it also puts Cocaine in the Accessibility list, switched off), then the posting right if that
            // alone is missing. Settings opens too when the user asked.
            let ax = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            let post = ax ? CGRequestPostEventAccess() : CGPreflightPostEventAccess()
            if explicit && !(ax && post) { openPane(p) }
            done?()
        case .camera:
            if st == .notAsked {
                NSApp.activate()                                             // the question comes up in front
                AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async { done?() } }
            } else { openPane(p); done?() }
        case .calendar:
            if st == .notAsked {
                NSApp.activate()
                let store = EKEventStore()
                asking = store
                store.requestFullAccessToEvents { _, _ in DispatchQueue.main.async { asking = nil; done?() } }
            } else { openPane(p); done?() }
        case .automation:
            if st == .notAsked {
                NSApp.activate()
                let apps = runningMusicApps()
                probeQueue.async {
                    let codes = apps.map { automation($0, ask: true) }
                    DispatchQueue.main.async { automationState = automationState(codes); done?() }
                }
            } else { openPane(p); done?() }
        case .files:
            if st == .notAsked {                                             // listing them is the question
                probe(files: true) { _ in if filesState != .granted { openPane(p) }; done?() }
            } else { openPane(p); done?() }
        }
    }
}

private extension NSError {
    var underlyingErrorCode: Int { (userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0 }
}

// MARK: - Haptic feedback

/// A light tap on the trackpad (Force Touch) when you change something; nothing on a mouse. Can be turned off in the panel.
private enum Haptic {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
    static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
    /// Three quick taps: something finished.
    static func finished() {
        for i in 0..<3 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.14) { tap(.levelChange) } }
    }
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
    // Power, display and schedule triggers (Sources/Power.swift)
    static let powerMinimumChoices = [10, 20, 30, 50]
    var triggerPower: String { get { d.string(forKey: "triggerPower") ?? "" } nonmutating set { d.set(newValue, forKey: "triggerPower") } }   // "" | ac | battery
    var triggerPowerMin: Int { get { d.object(forKey: "triggerPowerMin") as? Int ?? 20 } nonmutating set { d.set(newValue, forKey: "triggerPowerMin") } }
    var triggerDisplay: String { get { d.string(forKey: "triggerDisplay") ?? "" } nonmutating set { d.set(newValue, forKey: "triggerDisplay") } }   // "" | connected | disconnected
    var triggerSchedule: Bool { get { flag("triggerSchedule", false) } nonmutating set { d.set(newValue, forKey: "triggerSchedule") } }
    var scheduleDays: [Int] { get { (d.array(forKey: "scheduleDays") as? [Int])?.filter { (1...7).contains($0) } ?? [2, 3, 4, 5, 6] } nonmutating set { d.set(newValue, forKey: "scheduleDays") } }
    var scheduleStart: Int { get { TimeWindow.clamp(d.object(forKey: "scheduleStart") as? Int ?? 540) } nonmutating set { d.set(TimeWindow.clamp(newValue), forKey: "scheduleStart") } }
    var scheduleEnd: Int { get { TimeWindow.clamp(d.object(forKey: "scheduleEnd") as? Int ?? 1080) } nonmutating set { d.set(TimeWindow.clamp(newValue), forKey: "scheduleEnd") } }
    var triggerAll: Bool { get { flag("triggerAll", false) } nonmutating set { d.set(newValue, forKey: "triggerAll") } }
    var schedule: TimeWindow { TimeWindow(days: Set(scheduleDays), start: scheduleStart, end: scheduleEnd) }
    /// "Dim the screen when idle" turns the displays off instead (the Mac keeps working).
    var screenOff: Bool { get { flag("screenOff", false) } nonmutating set { d.set(newValue, forKey: "screenOff") } }
    /// Shortcuts and cocaine:// links may turn Cocaine on and off without asking.
    var allowLinks: Bool { get { flag("allowLinks", false) } nonmutating set { d.set(newValue, forKey: "allowLinks") } }
    var hotkeys: Bool { get { flag("hotkeys", false) } nonmutating set { d.set(newValue, forKey: "hotkeys") } }
    var haptics: Bool { get { flag("haptics", true) } nonmutating set { d.set(newValue, forKey: "haptics") } }
    var stayActive: Bool { get { flag("stayActive", false) } nonmutating set { d.set(newValue, forKey: "stayActive") } }
    var stayActiveAlways: Bool { get { flag("stayActiveAlways", false) } nonmutating set { d.set(newValue, forKey: "stayActiveAlways") } }
    var stayActiveApps: [String] { get { d.stringArray(forKey: "stayActiveApps") ?? Presence.defaultApps } nonmutating set { d.set(newValue, forKey: "stayActiveApps") } }
    var replaceHUD: Bool { get { flag("replaceHUD", false) } nonmutating set { d.set(newValue, forKey: "replaceHUD") } }
    var island: Bool { get { flag("island", true) } nonmutating set { d.set(newValue, forKey: "island") } }
    var wakeForPhone: Bool { get { flag("wakeForPhone", false) } nonmutating set { d.set(newValue, forKey: "wakeForPhone") } }
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

// MARK: - Remote control through a relay: the phone publishes a command, the Mac (outbound connection only) runs and answers

/// One paired iPhone. The two topics are random secrets on the relay (ntfy): knowing them is what lets a phone in.
private struct Pairing: Codable, Equatable {
    var id: String
    var cmd: String        // the phone publishes commands here
    var reply: String      // the Mac publishes answers here
    var tier: String       // "basic" or "agents": what the commands may do (the gate in remote.zsh enforces it)
    var relay: String      // the server it was made for: later changes to the setting never move existing secrets
}

private enum PhoneLink {
    static let file = AgentBoard.directory.appendingPathComponent("phones.json")

    /// The relay server: ntfy.sh unless the `relayURL` default points to another (https) ntfy server.
    static var relay: String {
        let v = UserDefaults.standard.string(forKey: "relayURL") ?? ""
        return v.hasPrefix("https://") ? v.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : "https://ntfy.sh"
    }

    static func load() -> [Pairing] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Pairing].self, from: $0) } ?? []
    }

    @discardableResult
    static func save(_ list: [Pairing]) -> Bool {
        try? FileManager.default.createDirectory(at: AgentBoard.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(list), (try? data.write(to: file, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }

    private static func random(_ bytes: Int) -> String? {
        var b = [UInt8](repeating: 0, count: bytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes, &b) == errSecSuccess else { return nil }
        return b.map { String(format: "%02x", $0) }.joined()
    }

    /// 192 random bits per topic: unguessable. (ntfy topic names allow up to 64 characters.)
    static func newPairing(tier: String) -> Pairing? {
        guard let id = random(8), let c = random(24), let r = random(24) else { return nil }
        return Pairing(id: id, cmd: "cc" + c, reply: "cr" + r, tier: tier == "agents" ? "agents" : "basic", relay: relay)
    }

    /// Runs one command from a phone through the gate (the same allow-list as `cocaine remote gate`) and returns what
    /// to answer: its output, at most 3500 bytes (the relay's limit is 4096).
    static func execute(_ text: String, tier: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [scriptPath, "remote", "gate", "--tier=\(tier == "agents" ? "agents" : "basic")"]
        var env = ProcessInfo.processInfo.environment
        env["SSH_ORIGINAL_COMMAND"] = String(text.prefix(1000))
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        // Read what it prints as it comes and stop when the command ends (or after 25 s): a child that kept the pipe
        // open, such as an agent starting up, must not hold the answer back.
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var data = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            lock.lock(); if data.count < 8192 { data.append(chunk) }; lock.unlock()
        }
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return "cocaine: can't run" }
        if done.wait(timeout: .now() + 25) == .timedOut { p.terminate() }
        Thread.sleep(forTimeInterval: 0.2)               // the last bytes
        out.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let got = data; lock.unlock()
        let text = String(decoding: got.prefix(3500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "OK" : text
    }

    static func publish(_ text: String, to topic: String, relay: String, session: URLSession) async {
        guard let url = URL(string: "\(relay)/\(topic)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(text.utf8)
        req.setValue("Cocaine", forHTTPHeaderField: "Title")
        req.setValue("no", forHTTPHeaderField: "X-Firebase")       // keep it off Google's push service
        _ = try? await session.data(for: req)
    }
}

/// Keeps one outbound connection per paired phone to the relay and answers what arrives. Nothing listens on this Mac.
private final class PhoneListener {
    private var tasks: [String: (pairing: Pairing, task: Task<Void, Never>)] = [:]
    private var up = Set<String>()
    private var cursor: [String: Int] = [:]            // newest message time handled, per phone: a reconnect resumes there
    private var seenIds: [String: [String]] = [:]
    private let lock = NSLock()
    var onChange: ((Bool) -> Void)?                    // is at least one phone's connection up?
    /// How old a command may be and still run, in seconds: longer when the Mac wakes on a schedule to pick them up.
    var maxAge: () -> Double = { 120 }

    func sync(_ list: [Pairing]) {
        lock.lock(); defer { lock.unlock() }
        for (id, entry) in tasks where !list.contains(entry.pairing) { entry.task.cancel(); tasks[id] = nil; up.remove(id) }
        for p in list where tasks[p.id] == nil {
            if cursor[p.id] == nil { cursor[p.id] = Int(Date().timeIntervalSince1970) }
            tasks[p.id] = (p, spawn(p))
        }
        notify()
    }

    /// Drops the (stale, after sleep) connections and opens fresh ones, resuming where each phone left off.
    func reconnect() {
        lock.lock(); defer { lock.unlock() }
        for (id, entry) in tasks { entry.task.cancel(); tasks[id] = (entry.pairing, spawn(entry.pairing)); up.remove(id) }
        notify()
    }

    private func spawn(_ p: Pairing) -> Task<Void, Never> { Task.detached { [weak self] in await self?.run(p) } }

    private func set(_ id: String, _ connected: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard tasks[id] != nil else { return }
        if connected { up.insert(id) } else { up.remove(id) }
        notify()
    }

    private func resumePoint(_ id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return cursor[id] ?? Int(Date().timeIntervalSince1970)
    }

    private func advance(_ id: String, to time: Int) {
        lock.lock(); defer { lock.unlock() }
        cursor[id] = max(cursor[id] ?? 0, time)
    }

    /// Remembers the message id; true if it was already handled.
    private func isDuplicate(_ id: String, _ message: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let seen = seenIds[id, default: []]
        if seen.contains(message) { return true }
        seenIds[id] = Array((seen + [message]).suffix(100))
        return false
    }

    private func notify() {
        let any = !up.isEmpty
        DispatchQueue.main.async { self.onChange?(any) }
    }

    private func run(_ p: Pairing) async {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 150           // the relay sends a keepalive every 45 s
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var recent: [Date] = []
        var delay = 2.0
        while !Task.isCancelled {
            let since = resumePoint(p.id)
            if let url = URL(string: "\(p.relay)/\(p.cmd)/json?since=\(since)") {
                do {
                    let (bytes, response) = try await session.bytes(from: url)
                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                        delay = 2
                        set(p.id, true)
                        for try await line in bytes.lines {
                            guard line.utf8.count <= 16_384, let m = Self.message(line) else { continue }
                            if isDuplicate(p.id, m.id) { continue }
                            // Old messages (the Mac was asleep) are never run, nor are ones dated in the future, and
                            // no more than 20 a minute are.
                            let age = Date().timeIntervalSince1970 - Double(m.time)
                            guard age <= maxAge(), age >= -120 else { continue }
                            advance(p.id, to: m.time)
                            recent = recent.filter { $0.timeIntervalSinceNow > -60 }
                            guard recent.count < 20, m.text.count <= 1000 else { continue }
                            recent.append(Date())
                            log.notice("phone command received (\(m.text.count, privacy: .public) characters)")
                            DispatchQueue.main.async { WakeHold.extend(60) }     // stay awake while it runs and the answer goes out
                            let answer = await Task.detached { PhoneLink.execute(m.text, tier: p.tier) }.value
                            await PhoneLink.publish(answer, to: p.reply, relay: p.relay, session: session)
                        }
                    }
                } catch {}
            }
            if Task.isCancelled { break }
            set(p.id, false)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 2, 60)
        }
    }

    /// A relay event line → the message, or nil for keepalives and anything else.
    static func message(_ line: String) -> (id: String, time: Int, text: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              json["event"] as? String == "message", let id = json["id"] as? String,
              let time = json["time"] as? Int, let text = json["message"] as? String else { return nil }
        return (id, time, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Waking the Mac on a schedule, so a sleeping Mac still answers the phone within a few minutes

/// A sleeping Mac (lid closed or not) can't hear the relay. With this on, Cocaine schedules a short wake every
/// `minutes` minutes: on wake it reconnects, runs what the phone sent meanwhile, and lets the Mac sleep again.
/// `pmset schedule` needs root, so it goes through the narrow sudo rule Cocaine installs.
private enum WakeSchedule {
    static let minutes = 15
    static let owner = "cocaine"
    private static let key = "nextWake"

    /// How long a command may wait for the next wake before it's too old to run.
    static var maxCommandAge: Double { Double(minutes + 5) * 60 }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yy HH:mm:ss"
        return f.string(from: date)
    }

    private static func pmset(_ args: [String]) -> Bool { run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + args) == 0 }

    /// Replaces the scheduled wake with one `minutes` from now. False when sudo isn't allowed to (yet).
    @discardableResult
    static func arm() -> Bool {
        cancel()
        let date = Date().addingTimeInterval(Double(minutes) * 60)
        guard pmset(["schedule", "wake", format(date), owner]) else { return false }
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
        return true
    }

    static func cancel() {
        let t = UserDefaults.standard.double(forKey: key)
        guard t > 0 else { return }
        _ = pmset(["schedule", "cancel", "wake", format(Date(timeIntervalSince1970: t)), owner])
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Keeps the Mac awake a little after a wake-up, long enough to reconnect, run a command and answer.
private enum WakeHold {
    private static var assertion: IOPMAssertionID = 0
    private static var releaseAt = Date.distantPast

    static func extend(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        guard until > releaseAt else { return }
        releaseAt = until
        if assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Cocaine is answering your iPhone" as CFString, &assertion)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.5) {
            guard Date() >= releaseAt, assertion != 0 else { return }
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}

/// Tells us when the Mac is about to sleep and when it has woken (including the short "dark" wakes with the lid closed).
private final class SleepWatcher {
    var willSleep: (() -> Void)?
    var didWake: (() -> Void)?
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    fileprivate private(set) var root: io_connect_t = 0

    @discardableResult
    func start() -> Bool {
        guard root == 0 else { return true }
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { refcon, _, message, argument in
            guard let refcon else { return }
            let w = Unmanaged<SleepWatcher>.fromOpaque(refcon).takeUnretainedValue()
            switch message {
            case 0xE000_0270, 0xE000_0280:                 // may sleep / will sleep: answer, or sleep waits 30 s
                if message == 0xE000_0280 { w.willSleep?() }
                IOAllowPowerChange(w.root, Int(bitPattern: argument))
            case 0xE000_0300:                              // has powered on
                w.didWake?()
            default: break
            }
        }, &notifier)
        guard root != 0, let port else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        return true
    }
}

// MARK: - The iPhone Shortcut: a menu that sends Cocaine's remote commands through the relay and shows the answer

private enum PhoneShortcut {
    /// The shortcut as an (unsigned) property list. Sign it before sharing: an iPhone refuses unsigned files.
    static func build(_ pairing: Pairing) -> Data? {
        func uuid() -> String { UUID().uuidString }
        func action(_ id: String, _ params: [String: Any]) -> [String: Any] {
            ["WFWorkflowActionIdentifier": "is.workflow.actions.\(id)", "WFWorkflowActionParameters": params]
        }
        /// Text with the result of an earlier action at its end ("the prefix, then that output").
        func token(_ prefix: String, _ output: String, _ name: String) -> [String: Any] {
            ["Value": ["string": prefix + "\u{FFFC}",
                       "attachmentsByRange": ["{\((prefix as NSString).length), 1}": ["OutputUUID": output, "Type": "ActionOutput", "OutputName": name]]],
             "WFSerializationType": "WFTextTokenString"]
        }
        func get(_ url: Any, _ id: String? = nil) -> [String: Any] {
            var params: [String: Any] = ["WFURL": url, "WFHTTPMethod": "GET"]
            if let id { params["UUID"] = id }
            return action("downloadurl", params)
        }
        let relay = pairing.relay
        let send = "\(relay)/\(pairing.cmd)/publish?firebase=no&message="
        func read(_ since: String) -> String { "\(relay)/\(pairing.reply)/raw?poll=1&since=\(since)" }
        func show(_ since: String) -> [[String: Any]] {      // fetch what the Mac answered and show it
            let r = uuid()
            return [get(read(since), r), action("showresult", ["Text": token("", r, "Contents of URL")])]
        }
        func wait() -> [String: Any] { action("delay", ["WFDelayTime": 4]) }

        let fixed: [(title: String, command: String)] = [
            (L("Status"), "status"), (L("Turn on"), "on"), (L("Turn off"), "off"), (L("Projects"), "projects"),
        ]
        let titles = fixed.map(\.title) + [L("Command"), L("Last reply")]
        let group = uuid()
        var actions: [[String: Any]] = [
            action("choosefrommenu", ["GroupingIdentifier": group, "WFControlFlowMode": 0, "WFMenuPrompt": "Cocaine", "WFMenuItems": titles]),
        ]
        func item(_ title: String, _ body: [[String: Any]]) {
            actions.append(action("choosefrommenu", ["GroupingIdentifier": group, "WFControlFlowMode": 1, "WFMenuItemTitle": title]))
            actions += body
        }
        for f in fixed { item(f.title, [get(send + f.command), wait()] + show("20s")) }
        let ask = uuid(), encoded = uuid()
        item(L("Command"), [
            action("ask", ["UUID": ask, "WFAskActionPrompt": L("Command (for example: start claude my-project Fix the tests)"), "WFInputType": "Text"]),
            action("urlencode", ["UUID": encoded, "WFEncodeMode": "Encode",
                                 "WFInput": ["Value": ["OutputUUID": ask, "Type": "ActionOutput", "OutputName": "Provided Input"],
                                             "WFSerializationType": "WFTextTokenAttachment"]]),
            get(token(send, encoded, "URL Encoded Text")), wait(),
        ] + show("20s"))
        item(L("Last reply"), show("30m"))
        actions.append(action("choosefrommenu", ["GroupingIdentifier": group, "WFControlFlowMode": 2]))
        let plist: [String: Any] = [
            "WFWorkflowClientVersion": "900", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientRelease": 900,
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowActions": actions, "WFWorkflowInputContentItemClasses": [String](), "WFWorkflowTypes": [String](),
            "WFWorkflowImportQuestions": [Any](),
        ]
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    /// Builds and signs `Cocaine.shortcut` for that pairing in a temporary folder; nil if signing fails (it needs to be
    /// online, and signed in to iCloud).
    static func signedFile(_ pairing: Pairing) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-shortcut-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let raw = dir.appendingPathComponent("raw.shortcut"), out = dir.appendingPathComponent("Cocaine.shortcut")
        guard let data = build(pairing), (try? data.write(to: raw)) != nil,
              run("/usr/bin/shortcuts", ["sign", "--mode", "people-who-know-me", "--input", raw.path, "--output", out.path]) == 0,
              FileManager.default.fileExists(atPath: out.path) else { try? FileManager.default.removeItem(at: dir); return nil }
        try? FileManager.default.removeItem(at: raw)
        return out
    }
}

private enum RelayTest {
    static func curl(_ url: String) -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-sS", "-m", "10", url]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// With `pink`, the powder is pink: Cocaine itself is off but "Stay active" is working.
    static func palette(dark: Bool, pink: Bool = false) -> Palette {
        let rose = NSColor(red: 1.0, green: 0.50, blue: 0.72, alpha: 1)
        return dark
            ? Palette(outline: NSColor.white.withAlphaComponent(0.78), fill: NSColor.white.withAlphaComponent(0.14),
                      powder: pink ? rose : .white, powderEdge: nil)
            : Palette(outline: NSColor.black.withAlphaComponent(0.55), fill: NSColor.black.withAlphaComponent(0.07),
                      powder: pink ? rose : .white, powderEdge: NSColor.black.withAlphaComponent(0.38))
    }

    /// The same bag in its light-on-dark colors, for the black island and panel.
    static func imageOnDark(level: CGFloat, pouring: Bool = false, size: CGFloat = 18, pink: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, level: level, pouring: pouring, palette: palette(dark: true, pink: pink))
            return true
        }
    }

    /// Menu-bar glyph; it redraws for the bar's current (light/dark) appearance.
    static func image(level: CGFloat, pouring: Bool = false, size: CGFloat = 18, pink: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            draw(in: rect, level: level, pouring: pouring, palette: palette(dark: dark, pink: pink))
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
    /// Which page of the panel is open: "" = the home, else "ai", "timer", "battery", "triggers", "keys" or "remote".
    @Published var page = "" { didSet { if page != oldValue { pageChanged() } } }
    var pageChanged: () -> Void = {}
    @Published var alertsPausedUntil: Date?
    @Published var history: [AlertRecord] = []       // newest first; kept by the app delegate
    @Published var timerMinutes: Int { didSet { settings.timerMinutes = timerMinutes; timerChanged() } }
    @Published var onUntil: Date?                    // when Cocaine will turn itself off
    @Published var batteryThreshold: Int { didSet { settings.batteryThreshold = batteryThreshold } }
    @Published var batteryTurnsOff: Bool { didSet { settings.batteryTurnsOff = batteryTurnsOff } }
    @Published var triggerAgents: Bool { didSet { settings.triggerAgents = triggerAgents } }
    @Published var triggerApps: [String] { didSet { settings.triggerApps = triggerApps } }
    @Published var triggerPower: String { didSet { settings.triggerPower = triggerPower; triggersChanged() } }
    @Published var triggerPowerMin: Int { didSet { settings.triggerPowerMin = triggerPowerMin; triggersChanged() } }
    @Published var triggerDisplay: String { didSet { settings.triggerDisplay = triggerDisplay; triggersChanged() } }
    @Published var triggerSchedule: Bool { didSet { settings.triggerSchedule = triggerSchedule; triggersChanged() } }
    @Published var scheduleDays: [Int] { didSet { settings.scheduleDays = scheduleDays; triggersChanged() } }
    @Published var scheduleStart: Int { didSet { settings.scheduleStart = scheduleStart; triggersChanged() } }
    @Published var scheduleEnd: Int { didSet { settings.scheduleEnd = scheduleEnd; triggersChanged() } }
    @Published var triggerAll: Bool { didSet { settings.triggerAll = triggerAll; triggersChanged() } }
    @Published var screenOff: Bool { didSet { settings.screenOff = screenOff; screenModeChanged() } }
    @Published var allowLinks: Bool { didSet { settings.allowLinks = allowLinks } }
    /// How many Smart Triggers are set (the "Any / All" choice shows from two).
    var triggerCount: Int {
        [triggerAgents, !triggerApps.isEmpty, !triggerPower.isEmpty, !triggerDisplay.isEmpty, triggerSchedule].filter { $0 }.count
    }
    @Published var hotkeys: Bool { didSet { settings.hotkeys = hotkeys; hotkeysChanged() } }
    @Published var wakeForPhone: Bool { didSet { settings.wakeForPhone = wakeForPhone; wakeChanged() } }
    @Published var island: Bool { didSet { settings.island = island; islandChanged() } }
    @Published var haptics: Bool { didSet { settings.haptics = haptics } }
    @Published var stayActive: Bool { didSet { settings.stayActive = stayActive; presenceChanged() } }
    @Published var stayActiveAlways: Bool { didSet { settings.stayActiveAlways = stayActiveAlways } }
    @Published var stayActiveApps: [String] { didSet { settings.stayActiveApps = stayActiveApps } }
    @Published var replaceHUD: Bool { didSet { settings.replaceHUD = replaceHUD; hudReplaceChanged() } }
    @Published var presenceAccess = Presence.hasAccess
    @Published var permissionProblems: [Permission] = []
    /// Cocaine is off but Stay active is working: the bag is full of pink powder.
    /// The pink powder has its own fill, animated like the white one: it pours in when Cocaine is off and Stay active is on (whether
    /// or not a chat app is open), and empties when either changes.
    @Published var pinkLevel: CGFloat = 0
    @Published var pinkPouring = false
    var pinkTarget: CGFloat { (!on && (stayActive || presenceActive) && fillLevel < 0.05) ? 1 : 0 }
    var bagPink: Bool { pinkLevel > 0.01 && fillLevel < 0.05 }
    var bagLevel: CGFloat { bagPink ? pinkLevel : fillLevel }
    var bagPouring: Bool { bagPink ? pinkPouring : pouring }
    @Published var presenceActive = false
    @Published var board: [AgentEntry] = []          // what each AI session is doing, from the hooks
    @Published var makingShortcut = false
    @Published var phoneCount = 0                    // iPhones paired for remote control
    @Published var phoneLinkUp = false               // at least one is connected to the relay
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
    @Published var dimEnabled: Bool { didSet { settings.dimEnabled = dimEnabled; screenModeChanged() } }
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
    var triggersChanged: () -> Void = {}
    var screenModeChanged: () -> Void = {}
    var screenOffNow: () -> Void = {}
    var wakeChanged: () -> Void = {}
    var islandChanged: () -> Void = {}
    var presenceChanged: () -> Void = {}
    var hudReplaceChanged: () -> Void = {}
    var requestPresence: () -> Void = {}
    var requestPermission: (Permission) -> Void = { _ in }
    var testPhone: () -> Void = {}
    var sendShortcut: () -> Void = {}
    var revokePhones: () -> Void = {}
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
        triggerPower = settings.triggerPower
        triggerPowerMin = settings.triggerPowerMin
        triggerDisplay = settings.triggerDisplay
        triggerSchedule = settings.triggerSchedule
        scheduleDays = settings.scheduleDays
        scheduleStart = settings.scheduleStart
        scheduleEnd = settings.scheduleEnd
        triggerAll = settings.triggerAll
        screenOff = settings.screenOff
        allowLinks = settings.allowLinks
        hotkeys = settings.hotkeys
        wakeForPhone = settings.wakeForPhone
        island = settings.island
        haptics = settings.haptics
        stayActive = settings.stayActive
        stayActiveAlways = settings.stayActiveAlways
        stayActiveApps = settings.stayActiveApps
        replaceHUD = settings.replaceHUD
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
        Button(action: { Haptic.tap(.alignment); action() }) {
            ZStack {
                Capsule().fill(on ? Island.accent : Color.white.opacity(0.18))
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

private enum Layout {
    static let width: CGFloat = 440                          // the panel's width: one number, never taken from content
    static let overscan: CGFloat = 6                         // windows hanging from the notch start this far above the screen's top edge
    // Two vertical edges, everything on one of them: the frame edge (14 pt from the panel's sides) holds containers (cards,
    // tabs, dividers); the content edge (10 pt further in) holds every text, icon and control. Controls end on the
    // content edge, on the right; full-width controls span it.
}

private extension View {
    /// The soft rounded card that holds a group of settings.
    func panelCard() -> some View {
        self.background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
    }
}

/// A segmented control whose segments are all the same width and that fills the width it is given (the native one in
/// SwiftUI hugs its labels). A value that isn't in the list (a custom timer length) leaves no segment selected.
private struct EqualSegments<T: Hashable>: NSViewRepresentable {
    @Binding var selection: T
    let values: [T]
    let label: (T) -> String

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: values.map(label), trackingMode: .selectOne,
                                   target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        c.segmentDistribution = .fillEqually
        c.selectedSegmentBezelColor = NSColor(red: 0.40, green: 0.64, blue: 1.0, alpha: 1)      // the island's accent
        c.controlSize = .small
        c.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        c.setContentHuggingPriority(.defaultLow, for: .horizontal)
        c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return c
    }

    func updateNSView(_ c: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if c.segmentCount != values.count { c.segmentCount = values.count }
        for (i, v) in values.enumerated() { c.setLabel(label(v), forSegment: i); c.setWidth(0, forSegment: i) }
        c.selectedSegment = values.firstIndex(of: selection) ?? -1
        c.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView c: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? c.intrinsicContentSize.width, height: c.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: EqualSegments
        init(_ parent: EqualSegments) { self.parent = parent }
        @objc func changed(_ c: NSSegmentedControl) {
            guard c.selectedSegment >= 0, c.selectedSegment < parent.values.count else { return }
            Haptic.tap(.alignment)
            parent.selection = parent.values[c.selectedSegment]
        }
    }
}

private struct PanelView: View {
    @ObservedObject var m: PanelModel
    @ObservedObject var clip = ClipboardHistory.shared

    private static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
    static func timeString(_ d: Date) -> String { time.string(from: d) }

    // MARK: Building blocks

    /// A group of settings: an icon and a name (with an optional control on the right) over its rows, in a card.
    private func card<Trailing: View, Content: View>(_ icon: String, _ title: String, warning: Bool = false,
                                                     @ViewBuilder trailing: () -> Trailing,
                                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(UI.icon).foregroundStyle(Island.accent).frame(width: 16)
                Text(title).font(UI.groupTitle).lineLimit(1)
                if warning { Image(systemName: "exclamationmark.triangle.fill").font(UI.detail).foregroundStyle(warningColor) }
                Spacer(minLength: 8)
                trailing().fixedSize()
            }
            .frame(minHeight: 22)
            VStack(alignment: .leading, spacing: 6) { content() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 12))     // whatever it holds is cut at the card's edge, never drawn outside
        .panelCard()
    }

    private func card<Content: View>(_ icon: String, _ title: String, warning: Bool = false,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        card(icon, title, warning: warning, trailing: { EmptyView() }, content)
    }

    /// One row: its name on the left, its control on the right edge. Always one line for the control; the name wraps.
    private func row<Control: View>(_ title: String, detail: String? = nil, tip: String? = nil, warning: Bool = false,
                                    @ViewBuilder _ control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(UI.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(UI.detail).foregroundStyle(warning ? AnyShapeStyle(warningColor) : AnyShapeStyle(Color.white.opacity(0.7)))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()
        }
        .frame(minHeight: 22)
        .help(tip ?? detail ?? title)
    }

    /// A value you pick from a short list: the current value and a chevron, flush with the right edge.
    private func choice<T: Hashable>(_ title: String, _ selection: Binding<T>, _ values: [T],
                                     _ name: @escaping (T) -> String) -> some View {
        Menu {
            Picker(title, selection: selection) { ForEach(values, id: \.self) { Text(name($0)).tag($0) } }
                .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(name(selection.wrappedValue)).font(UI.value).lineLimit(1)
            }
            .frame(maxWidth: 190, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
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

    private func durationName(_ s: Double) -> String { s == 0 ? L("Until you're back") : String(format: L("%d s"), Int(s)) }
    private func repeatName(_ min: Int) -> String { min == 0 ? L("Never") : String(format: L("Every %d min"), min) }

    /// "∞" for no limit, else "45 min", "2 h" or "2 h 30 min": any length, not just the presets.
    private func durationLabel(_ minutes: Int) -> String {
        if minutes <= 0 { return "∞" }
        if minutes < 60 { return String(format: L("%d min"), minutes) }
        let h = String(format: L("%d h"), minutes / 60)
        return minutes % 60 == 0 ? h : "\(h) \(String(format: L("%d min"), minutes % 60))"
    }

    private var status: String {
        if m.needsAuth { return L("Admin password needed") }
        if m.on && m.holdMissing { return L("Keeping the screen on…") }
        var parts = [m.on ? L("Your Mac stays awake") : L("Your Mac sleeps as usual")]
        if m.on, let until = m.onUntil, until > Date() { parts.append(String(format: L("until %@"), Self.time.string(from: until))) }
        if let paused = m.alertsPausedUntil { parts.append("⏸ " + String(format: L("until %@"), Self.time.string(from: paused))) }
        return parts.joined(separator: " · ")
    }

    // MARK: General

    private func stepButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: { Haptic.tap(.alignment); action() }) {
            Image(systemName: symbol).font(UI.chevron).frame(width: 24, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Any length you like, in steps of 15 minutes (up to 24 hours): one unit, its readout as wide as the longest value.
    private var customTimer: some View {
        HStack(spacing: 0) {
            stepButton("minus", L("Shorter")) { m.timerMinutes = max(15, (m.timerMinutes <= 0 ? 60 : m.timerMinutes) - 15) }
            Divider().frame(height: 12)
            ZStack {
                Text(durationLabel(1425)).hidden()
                Text(durationLabel(m.timerMinutes))
            }
            .font(UI.value.monospacedDigit()).lineLimit(1).padding(.horizontal, 8)
            Divider().frame(height: 12)
            stepButton("plus", L("Longer")) { m.timerMinutes = min(1440, (m.timerMinutes <= 0 ? 60 : m.timerMinutes) + 15) }
        }
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
        .fixedSize()
        .onScrollSteps(every: 10) { m.timerMinutes = min(1440, max(15, (m.timerMinutes <= 0 ? 60 : m.timerMinutes) + 15 * $0)) }
        .help(L("Any length, in steps of 15 minutes"))
    }

    /// Scrolling over the presets moves through them (∞ · 30 min … 8 h).
    private func stepTimerPreset(_ n: Int) {
        let c = Settings.timerChoices
        let i = c.firstIndex(of: m.timerMinutes) ?? c.firstIndex { $0 >= m.timerMinutes } ?? 0
        m.timerMinutes = c[min(c.count - 1, max(0, i + n))]
    }

    private var timerCard: some View {
        card("timer", L("Stay on for"), trailing: { customTimer }) {
            EqualSegments(selection: $m.timerMinutes, values: Settings.timerChoices, label: durationLabel)
                .frame(maxWidth: .infinity)
                .onScrollSteps(every: 24) { n in stepTimerPreset(n) }
        }
        .help(L("Cocaine turns itself off when the time is up"))
    }

    private var screenCard: some View {
        card("sun.min", L("Dim the screen when idle"), trailing: { toggle(L("Dim the screen when idle"), $m.dimEnabled) }) {
            Group {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").font(UI.icon).foregroundStyle(.secondary).frame(width: 16)
                    Slider(value: Binding(get: { m.levelPercent }, set: { m.setLevel($0) }), in: 1...50)
                    Text("\(Int(m.levelPercent))%").font(UI.value.monospacedDigit()).frame(width: 34, alignment: .trailing)
                    Button(L("Preview")) { m.preview() }.controlSize(.small).disabled(m.previewing)
                        .help(L("Shows the minimum brightness for 3 seconds"))
                }
                .disabled(m.screenOff).opacity(m.screenOff ? 0.45 : 1)
                row(L("Turn the screen off instead"),
                    detail: L("The Mac keeps working with the screen off."),
                    tip: L("While Cocaine is on. Any key or click turns the screen back on. The Mac locks as set in Lock Screen settings.")) {
                    HStack(spacing: 6) {
                        Button(L("Now")) { m.screenOffNow() }.controlSize(.small).help(L("Turn the screens off now"))
                        toggle(L("Turn the screen off instead"), $m.screenOff)
                    }
                }
                HStack(spacing: 8) {
                    Text(L("After")).font(UI.title).fixedSize()
                    EqualSegments(selection: $m.delayMinutes, values: Settings.delayChoices) { String(format: L("%d min"), $0) }
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!m.dimEnabled)
            .opacity(m.dimEnabled ? 1 : 0.45)
        }
        .help(L("Goes back to normal as soon as you touch anything"))
    }

    /// Who is doing what: the AI sessions at work, or, when none is, the latest alerts.
    @ViewBuilder private var activityCard: some View {
        let now = Date().timeIntervalSince1970
        let shown = Array(m.board.filter { $0.isLive || now - $0.since < 600 }.prefix(4))
        if !shown.isEmpty {
            card("sparkles", L("Agents")) {
                ForEach(shown) { e in
                    activityRow(Self.stateIcon(e.state), Self.stateColor(e.state), e.from, Self.stateName(e.state), e.project, Self.age(e.since))
                }
            }
        } else if m.ai.available {
            card("bell", L("Recent alerts"), trailing: {
                if !m.history.isEmpty { Button(L("Clear")) { m.clearHistory() }.buttonStyle(.link).font(UI.detail) }
            }) {
                if m.history.isEmpty {
                    Text(L("Alerts you receive will show up here")).font(UI.detail).foregroundStyle(.tertiary)
                } else {
                    ForEach(m.history.prefix(3)) { r in
                        activityRow("bell.fill", Color.secondary, r.from, r.message, r.project, Self.time.string(from: r.at))
                    }
                }
            }
        }
    }

    /// An icon, who and what (the message gives way before the project), and when, on the right edge.
    private func activityRow(_ icon: String, _ color: Color, _ title: String, _ message: String, _ project: String?, _ when: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon).font(UI.icon).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(UI.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text(message).lineLimit(1)
                    if let project { Text("·"); Text(project).lineLimit(1).layoutPriority(1) }
                }
                .font(UI.detail).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(when).font(UI.detail.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
        }
    }

    private var appCard: some View {
        card("gearshape", "Cocaine") {
            row(L("Open at login")) {
                CocaineSwitch(on: m.loginEnabled) { m.setLogin(!m.loginEnabled) }.accessibilityLabel(L("Open at login"))
            }
            row(L("Island"), tip: L("Shows Cocaine and its tools in the notch, or at the top of the screen")) { toggle(L("Island"), $m.island) }
            row(L("Haptic feedback"), tip: L("A light tap on the trackpad when you change a timer, switch a page or toggle something")) { toggle(L("Haptic feedback"), $m.haptics) }
            row(L("Replace system HUD"), detail: L("Volume and brightness bars appear in the island, not on screen.")) {
                toggle(L("Replace system HUD"), $m.replaceHUD)
            }
            row(L("Language")) {
                let code = m.language.isEmpty ? Language.system : m.language
                Menu {
                    Picker(L("Language"), selection: $m.language) {
                        Text("\(L("Same as Mac"))  \(Language.flag(Language.system))").tag("")
                        ForEach(Language.codes, id: \.self) { Text("\(Language.flag($0))  \(Language.nativeName($0))").tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 4) {
                        Text("\(Language.flag(code))  \(Language.nativeName(code))").font(UI.value).lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .accessibilityLabel(L("Language"))
            }
        }
    }

    /// Only what is missing, with a button; one calm line when everything is in place.
    private var permissionsCard: some View {
        card("lock.shield", L("Permissions")) {
            if m.permissionProblems.isEmpty {
                row(L("Everything Cocaine needs is allowed")) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            } else {
                ForEach(m.permissionProblems) { p in
                    row(p.title, detail: p.reason, warning: true) { Button(L("Allow")) { m.requestPermission(p) }.controlSize(.small) }
                }
            }
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            timerCard
            screenCard
            activityCard
            permissionsCard
            appCard
            if m.island { clipboardCard }
        }
    }

    // MARK: Clipboard (the island's page; Sources/Clipboard.swift)

    private func clipSetting<T>(_ kp: WritableKeyPath<ClipSettings, T>) -> Binding<T> {
        Binding(get: { clip.settings[keyPath: kp] }, set: { var s = clip.settings; s[keyPath: kp] = $0; clip.update(s) })
    }

    private func ageName(_ hours: Int) -> String {
        switch hours {
        case 0: return L("No limit")
        case 1: return L("1 hour")
        case 24: return L("1 day")
        case 24 * 7: return L("1 week")
        default: return String(format: L("%d days"), hours / 24)
        }
    }

    private var clipboardCard: some View {
        let s = clip.settings
        return card("doc.on.clipboard", L("Clipboard"), warning: clip.problem != nil) {
            row(L("Save on this Mac"), detail: clip.problem ?? (s.persist ? L("Encrypted, with its key in your Keychain") : L("Off: kept in memory only, gone when Cocaine quits")),
                warning: clip.problem != nil) {
                CocaineSwitch(on: s.persist) { ClipboardUI.setPersist(clip, !s.persist) }.accessibilityLabel(L("Save on this Mac"))
            }
            row(L("Keep at most"), tip: L("Favorites don't count and are never removed")) {
                choice(L("Keep at most"), clipSetting(\.maxItems), ClipSettings.itemChoices) { String(format: L("%d items"), $0) }
            }
            row(L("Forget after")) { choice(L("Forget after"), clipSetting(\.maxAgeHours), ClipSettings.ageChoices, ageName) }
            row(L("Space in all")) { choice(L("Space in all"), clipSetting(\.maxTotalMB), ClipSettings.totalChoices) { "\($0) MB" } }
            row(L("Largest item"), tip: L("Bigger images and texts aren't kept")) {
                choice(L("Largest item"), clipSetting(\.maxItemMB), ClipSettings.itemSizeChoices) { "\($0) MB" }
            }
            row(L("Skip card numbers and keys"), tip: L("Card numbers, private keys, API keys and other tokens aren't kept")) {
                toggle(L("Skip card numbers and keys"), clipSetting(\.skipSecrets))
            }
            row(L("Excluded apps"), detail: L("Password managers are always excluded")) {
                Menu {
                    ForEach(s.excludedApps, id: \.self) { id in
                        Button { var n = s; n.excludedApps.removeAll { $0 == id }; clip.update(n) } label: {
                            Label(ClipboardHistory.appName(id) ?? id, systemImage: "checkmark")
                        }
                    }
                    if !s.excludedApps.isEmpty { Divider() }
                    Section(L("Open now")) {
                        ForEach(ClipboardUI.runningApps(excluding: s.excludedApps), id: \.id) { app in
                            Button(app.name) { var n = s; n.excludedApps.append(app.id); clip.update(n) }
                        }
                    }
                } label: {
                    Text(s.excludedApps.isEmpty ? L("None") : s.excludedApps.count == 1 ? (ClipboardHistory.appName(s.excludedApps[0]) ?? "1")
                         : "\(ClipboardHistory.appName(s.excludedApps[0]) ?? "") +\(s.excludedApps.count - 1)").font(UI.value).lineLimit(1)
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible).accessibilityLabel(L("Excluded apps"))
            }
            row(L("Excluded patterns"), tip: L("Text matching one of these regular expressions isn't kept")) {
                Menu {
                    ForEach(s.patterns, id: \.self) { p in
                        Button { var n = s; n.patterns.removeAll { $0 == p }; clip.update(n) } label: { Label(p, systemImage: "checkmark") }
                    }
                    if !s.patterns.isEmpty { Divider() }
                    Button(L("Add…")) { ClipboardUI.addPattern(clip) }
                } label: {
                    Text(s.patterns.isEmpty ? L("None") : "\(s.patterns.count)").font(UI.value).lineLimit(1)
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible).accessibilityLabel(L("Excluded patterns"))
            }
            row(L("Delete everything"), detail: L("History, favorites, saved files and their key")) {
                Button(L("Delete…")) { ClipboardUI.confirmDeleteEverything(clip) }.controlSize(.small)
            }
        }
    }

    // MARK: AI alerts

    private var aiTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            card("sparkles", L("Connected AIs"), warning: m.ai.codexNeedsTrust) {
                ForEach(m.ai.tools.filter(\.installed)) { t in
                    let untrusted = t.id == "codex" && m.ai.codexNeedsTrust
                    row(t.name, detail: untrusted ? L("Approve once in Settings → Hooks") : nil, tip: toolDetail(t.id), warning: untrusted) {
                        toggle(t.name, Binding(get: { t.on }, set: { m.setAI(t.id, $0) })).disabled(m.settingAI)
                    }
                }
                let others = m.ai.tools.filter { !$0.installed }.map(\.name)
                Button(L("Other apps and scripts…")) { NSWorkspace.shared.open(Feedback.alertsGuide) }
                    .buttonStyle(.link).font(UI.detail)
                    .help(others.isEmpty ? L("Other apps and scripts…") : String(format: L("Also supported: %@"), others.joined(separator: ", ")))
            }
            card("bell.badge", L("When")) {
                row(L("Finishes"), tip: L("When an AI completes its work")) { toggle(L("Finishes"), $m.alertDone) }
                row(L("Needs you"), tip: L("When it asks for a permission or an answer")) { toggle(L("Needs you"), $m.alertInput) }
                row(L("Also at the Mac"), tip: L("Otherwise only when you've been away for 20 seconds")) { toggle(L("Also at the Mac"), $m.alertWhenPresent) }
                row(L("One alert per session"),
                    tip: L("Not for every agent or task that finishes: only when the whole session has had nothing going on for a minute")) {
                    toggle(L("One alert per session"), $m.alertPerSession)
                }
                row(L("Pause"), tip: L("Silences every alert for a while")) {
                    Menu {
                        if m.alertsPausedUntil != nil {
                            Button(L("Resume")) { m.pauseAlerts(nil) }
                            Divider()
                        }
                        Button(String(format: L("%d min"), 30)) { m.pauseAlerts(Date().addingTimeInterval(1800)) }
                        Button(L("1 hour")) { m.pauseAlerts(Date().addingTimeInterval(3600)) }
                        Button(L("Until tomorrow")) {
                            let cal = Calendar.current
                            m.pauseAlerts(cal.date(bySettingHour: 8, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date())!))
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(m.alertsPausedUntil.map { String(format: L("until %@"), Self.time.string(from: $0)) } ?? L("Off")).font(UI.value).lineLimit(1)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .accessibilityLabel(L("Pause"))
                }
            }
            card("rays", L("How"), trailing: {
                Button(L("Test")) { m.testAlert() }.controlSize(.small).help(L("Shows an alert with these settings"))
            }) {
                row(L("Flash"), tip: L("Wakes the screens and flashes them")) { toggle(L("Flash"), $m.alertFlash) }
                row(L("Sound"), tip: L("Plays when the alert arrives")) {
                    choice(L("Sound"), $m.alertSound, [""] + Settings.sounds) { $0.isEmpty ? L("No sound") : $0 }
                }
                row(L("Voice"), tip: L("Reads out who's calling and the project")) { toggle(L("Voice"), $m.alertSpeak) }
                if m.alertSpeak {                               // which voice, only when there's one to choose
                    row(L("Voice type"), tip: L("The Mac's voices for your language; you hear it as you pick")) {
                        choice(L("Voice type"), $m.alertVoice, [""] + Voices.available.map(\.identifier), Voices.name)
                    }
                }
                row(L("On screen"), tip: L("How long the alert stays")) {
                    choice(L("On screen"), $m.alertDuration, Settings.durationChoices, durationName)
                }
                row(L("Repeat"), tip: L("While you're away, for up to 30 minutes")) {
                    choice(L("Repeat"), $m.alertRepeatMinutes, Settings.repeatChoices, repeatName)
                }
            }
        }
    }

    // MARK: Automation

    /// The schedule: the days (in the order this Mac's calendar starts its week) and the hours, on the wall clock.
    @ViewBuilder private var scheduleRows: some View {
        let cal = Calendar.autoupdatingCurrent
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: 4) {
            ForEach(order, id: \.self) { day in
                let on = m.scheduleDays.contains(day)
                Button {
                    Haptic.tap(.alignment)
                    if on { m.scheduleDays.removeAll { $0 == day } } else { m.scheduleDays = (m.scheduleDays + [day]).sorted() }
                } label: {
                    Text(cal.veryShortStandaloneWeekdaySymbols[day - 1]).font(UI.value)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Island.accent : Color.white.opacity(0.10)))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cal.standaloneWeekdaySymbols[day - 1])
                .accessibilityValue(on ? "1" : "0")
            }
        }
        row(L("Hours"), detail: m.scheduleEnd <= m.scheduleStart ? L("Ends the next day") : nil,
            tip: L("Local time; follows daylight saving and time-zone changes")) {
            HStack(spacing: 4) {
                minutePicker($m.scheduleStart)
                Text("–").font(UI.value)
                minutePicker($m.scheduleEnd)
            }
        }
    }

    /// A time of day (minutes after midnight) as an hour-and-minute field.
    private func minutePicker(_ minutes: Binding<Int>) -> some View {
        let cal = Calendar.autoupdatingCurrent
        let day = cal.startOfDay(for: Date())
        return DatePicker("", selection: Binding(
            get: { cal.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: day) ?? day },
            set: { let c = cal.dateComponents([.hour, .minute], from: $0); minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) }),
            displayedComponents: .hourAndMinute)
            .labelsHidden().datePickerStyle(.field).controlSize(.small)
    }

    private var automationTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            card("bolt.badge.automatic", L("Smart Triggers")) {
                row(L("An AI is at work"), tip: L("On while an AI works or waits for you; off 3 minutes after")) {
                    toggle(L("An AI is at work"), $m.triggerAgents)
                }
                row(L("These programs are open"), tip: L("On while any is running; off 3 minutes after")) {
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
                        HStack(spacing: 4) {
                            Text(m.triggerApps.isEmpty ? L("Choose")
                                 : (m.triggerApps.count == 1 ? m.triggerApps[0] : "\(m.triggerApps[0]) +\(m.triggerApps.count - 1)"))
                                .font(UI.value).lineLimit(1)
                        }
                        .frame(maxWidth: 190, alignment: .trailing)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                }
                row(L("Power"), tip: L("On while the Mac is on the charger, or on battery above a level; off 30 seconds after")) {
                    choice(L("Power"), $m.triggerPower, ["", "ac", "battery"]) {
                        $0 == "ac" ? L("On the charger") : $0 == "battery" ? L("On battery") : L("Off")
                    }
                }
                if m.triggerPower == "battery" {
                    row(L("Down to"), tip: L("Below this level the battery trigger lets go")) {
                        choice(L("Down to"), $m.triggerPowerMin, Settings.powerMinimumChoices) { "\($0)%" }
                    }
                }
                row(L("External display"), tip: L("On while a display is connected (or while none is); off 30 seconds after")) {
                    choice(L("External display"), $m.triggerDisplay, ["", "connected", "disconnected"]) {
                        $0 == "connected" ? L("Connected") : $0 == "disconnected" ? L("Not connected") : L("Off")
                    }
                }
                row(L("Schedule"), tip: L("On during these hours on the chosen days; off when they end")) {
                    toggle(L("Schedule"), $m.triggerSchedule)
                }
                if m.triggerSchedule {
                    scheduleRows
                }
                if m.triggerCount >= 2 {
                    row(L("Turn on when"), tip: L("Any: one reason is enough. All: every chosen one must hold.")) {
                        choice(L("Turn on when"), $m.triggerAll, [false, true]) { $0 ? L("All are true") : L("Any is true") }
                    }
                }
            }
            card("person.crop.circle.badge.checkmark", L("Stay active")) {
                row(L("Stay available in chat apps"), detail: L("While you're idle it sends an invisible mouse event so Teams and the like don't show you as away.")) {
                    toggle(L("Stay available in chat apps"), $m.stayActive)
                }
                row(L("When"), tip: L("Only while one of the chosen apps is open, or all the time")) {
                    choice(L("When"), $m.stayActiveAlways, [false, true]) { $0 ? L("Always") : L("While these apps are open") }
                }
                .disabled(!m.stayActive).opacity(m.stayActive ? 1 : 0.45)
                row(L("Apps"), tip: L("The chat apps to keep available")) {
                    Menu {
                        ForEach(Array(Set(Presence.defaultApps + m.stayActiveApps)).sorted(), id: \.self) { app in
                            Button { if m.stayActiveApps.contains(app) { m.stayActiveApps.removeAll { $0 == app } } else { m.stayActiveApps.append(app) } } label: {
                                if m.stayActiveApps.contains(app) { Label(app, systemImage: "checkmark") } else { Text(app) }
                            }
                        }
                        Section(L("Open now")) {
                            ForEach(System.runningAppNames().filter { n in !Presence.defaultApps.contains(n) && !m.stayActiveApps.contains(n) }, id: \.self) { app in
                                Button(app) { m.stayActiveApps.append(app) }
                            }
                        }
                    } label: {
                        Text(m.stayActiveApps.isEmpty ? L("Choose") : (m.stayActiveApps.count == 1 ? m.stayActiveApps[0] : "\(m.stayActiveApps[0]) +\(m.stayActiveApps.count - 1)")).font(UI.value).lineLimit(1)
                            .frame(maxWidth: 190, alignment: .trailing)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.visible)
                }
                .disabled(!m.stayActive).opacity(m.stayActive ? 1 : 0.45)
                if m.stayActive && !m.presenceAccess {
                    row(L("Needs permission to send input"), detail: L("Allow Cocaine in Privacy & Security → Accessibility"), warning: true) {
                        Button(L("Allow")) { m.requestPresence() }.controlSize(.small)
                    }
                }
            }
            card("battery.50", L("Battery Guard")) {
                row(L("When the battery reaches"), detail: m.battery.map { String(format: L("On battery only. Now %@"), $0) } ?? L("On battery only")) {
                    EmptyView()
                }
                EqualSegments(selection: $m.batteryThreshold, values: Settings.batteryChoices) { $0 == 0 ? L("Off") : "\($0)%" }
                    .frame(maxWidth: .infinity)
                row(L("Then"), tip: L("What Cocaine does at that level")) {
                    choice(L("Then"), $m.batteryTurnsOff, [true, false]) { $0 ? L("Turn Cocaine off") : L("Only warn me") }
                }
                .disabled(m.batteryThreshold == 0).opacity(m.batteryThreshold == 0 ? 0.45 : 1)
            }
            card("iphone.gen3", L("Remote work")) {
                row(L("iPhone"), detail: m.phoneCount == 0 ? L("Not set up: send it a Shortcut")
                    : "\(m.phoneCount) \(L("paired")) · \(m.phoneLinkUp ? L("Connected") : L("Connecting…"))") {
                    HStack(spacing: 6) {
                        Button(m.makingShortcut ? "…" : L("Send")) { m.sendShortcut() }.controlSize(.small).disabled(m.makingShortcut)
                            .help(L("Send the Shortcut to your iPhone"))
                        if m.phoneCount > 0 { Button(L("Revoke")) { m.revokePhones() }.controlSize(.small) }
                    }
                }
                row(L("Wake for iPhone"), tip: L("Every 15 minutes it wakes briefly, even with the lid closed, to answer your iPhone")) {
                    toggle(L("Wake for iPhone"), $m.wakeForPhone)
                }
                row(L("Phone alerts"), detail: m.phone.isEmpty ? L("Not set up: see the guide") : m.phone) {
                    Button(L("Test")) { m.testPhone() }.controlSize(.small).disabled(m.phone.isEmpty).help(L("Send a test to your phone"))
                }
                Button(L("Remote work guide…")) { NSWorkspace.shared.open(Feedback.remoteGuide) }
                    .buttonStyle(.link).font(UI.detail)
            }
            card("keyboard", L("Shortcuts")) {
                row(L("Global shortcuts"), tip: L("Work from any app")) { toggle(L("Global shortcuts"), $m.hotkeys) }
                Text("⌃⌥⌘C  \(L("on/off"))  ·  ⌃⌥⌘O  \(L("panel"))  ·  ⌃⌥⌘P  \(L("pause alerts"))").font(UI.detail).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .help("⌃⌥⌘C: " + L("Turn Cocaine on or off") + "\n⌃⌥⌘O: " + L("Open the panel") + "\n⌃⌥⌘P: " + L("Pause or resume alerts"))
                    .opacity(m.hotkeys ? 1 : 0.45)
                row(L("Shortcuts app and links"),
                    tip: L("Lets the Shortcuts app and cocaine:// links turn Cocaine on and off without asking. Off: Cocaine asks you first.")) {
                    toggle(L("Shortcuts app and links"), $m.allowLinks)
                }
            }
        }
    }

    // MARK: The panel

    private static func stateIcon(_ s: String) -> String {
        ["working": "gearshape.fill", "waiting": "hand.raised.fill", "done": "checkmark.circle.fill", "error": "exclamationmark.triangle.fill"][s] ?? "circle"
    }
    private static func stateColor(_ s: String) -> Color {
        s == "error" || s == "waiting" ? warningColor : s == "done" ? .green : Island.accent
    }
    private static func stateName(_ s: String) -> String {
        ["working": L("Working"), "waiting": L("Needs you"), "done": L("Done"), "error": L("Error")][s] ?? s
    }
    private static func age(_ since: Double) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: Language.chosen ?? Language.system)
        return Date().timeIntervalSince1970 - since < 45 ? L("now") : f.localizedString(for: Date(timeIntervalSince1970: since), relativeTo: Date())
    }

    private func tabTitle(_ id: String) -> String { id == "ai" ? L("AI alerts") : id == "auto" ? L("Automation") : L("General") }

    private var tabs: [String] { m.ai.available ? ["", "ai", "auto"] : ["", "auto"] }

    private func stripButton(_ icon: String, _ title: String, selected: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: { Haptic.tap(.alignment); action() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.16 : 0)).frame(width: 30, height: 26)
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(selected ? Color.white : Color.white.opacity(0.5))
            }
            .frame(width: 38, height: NotchGeometry.current()?.height ?? 32)              // the whole cell around the icon
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private func tabIcon(_ id: String) -> String { id == "ai" ? "sparkles" : id == "auto" ? "bolt.badge.automatic" : "house.fill" }

    /// The panel's top strip, like the island's: the tabs left of the notch, Feedback and Quit right of it.
    private func strip(_ g: NotchGeometry) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) { ForEach(tabs, id: \.self) { t in stripButton(tabIcon(t), tabTitle(t), selected: m.page == t) { m.page = t } } }
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: g.notchWidth)
            HStack(spacing: 0) {
                stripButton("envelope", L("Feedback or help") + " — " + Feedback.address) { Feedback.compose() }
                stripButton("power", L("Turns Cocaine off and quits")) { m.quit() }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: g.height)
    }

    private var header: some View {
        HStack(spacing: 10) {                                // header and footer sit on the content edge
            Image(nsImage: Baggie.imageOnDark(level: m.bagLevel, pouring: m.bagPouring, size: 28, pink: m.bagPink))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Cocaine").font(.headline)
                    Text(appVersion).font(UI.detail).foregroundStyle(.tertiary)   // e.g. "1.7"
                }
                Text(status).font(UI.detail).lineLimit(1)
                    .foregroundStyle(m.needsAuth || (m.on && m.holdMissing) ? AnyShapeStyle(warningColor) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 8)
            CocaineSwitch(on: m.on, powder: m.fillLevel) { m.toggleCocaine() }
                .help(m.on ? L("Turn Cocaine off") : L("Turn Cocaine on"))
                .accessibilityLabel("Cocaine")
        }
        .padding(.horizontal, 10)
    }

    var body: some View {
        let g = m.island ? NotchGeometry.current() : nil
        return VStack(alignment: .leading, spacing: 10) {
            if let g { strip(g) }
            header
            if g == nil {
                EqualSegments(selection: $m.page, values: tabs, label: tabTitle)
                    .frame(maxWidth: .infinity)
            }

            switch m.page {
            case "ai": aiTab
            case "auto": automationTab
            default: generalTab
            }

            if g == nil {
                HStack(spacing: 8) {
                    Button { Feedback.compose() } label: {
                        Label(L("Feedback"), systemImage: "envelope").font(UI.detail)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Feedback or help") + " — " + Feedback.address)
                    Spacer(minLength: 8)
                    Button(L("Quit")) { m.quit() }.controlSize(.small).fixedSize()
                        .help(L("Turns Cocaine off and quits"))
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, g == nil ? 14 : Layout.overscan)
        .frame(width: Layout.width, alignment: .topLeading)   // never centered, never wider: nothing can slide out sideways
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
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
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }     // exactly where we say, even above the screen
    /// The content scrolls when it is taller than the screen allows (the app sizes the window; see fitPanel).
    let scroll = NSScrollView()

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isMovable = false

        let fx = NSView()
        fx.wantsLayer = true
        fx.layer?.backgroundColor = NSColor.black.cgColor
        fx.layer?.cornerRadius = 12
        appearance = NSAppearance(named: .darkAqua)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none                 // content can never be dragged sideways
        scroll.usesPredominantAxisScrolling = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        fx.addSubview(scroll)
        NSLayoutConstraint.activate([      // the document is pinned to the top: the app sizes the window, top edge fixed
            scroll.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: fx.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalToConstant: Layout.width),     // required: the content is exactly as wide as the box
        ])
        fx.layer?.masksToBounds = true
        contentView = fx
    }

    /// Hanging from the top of the screen under the notch (flat top, round bottom, like the open island), or a floating menu.
    func attach(toTop: Bool) {
        guard let l = contentView?.layer else { return }
        l.cornerRadius = toTop ? 28 : 12
        l.maskedCorners = toTop ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
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

// MARK: - Island: the notch (or the top of any screen) as a live home for Cocaine and its tools

private enum Island {
    static let accent = Color(red: 0.40, green: 0.64, blue: 1.0)
    static let overscan = Layout.overscan
    static let openSize = CGSize(width: 640, height: 214)
    static let wing: CGFloat = 62                              // each side of the notch when something is live
    static let slack: CGFloat = 8                              // room around the open island for the spring's overshoot
    /// Opening: quick off the mark, with a touch of give at the end. Closing: a bit quicker, settling without a bounce.
    static let openSpring = Animation.spring(response: 0.4, dampingFraction: 0.78)
    static let closeSpring = Animation.spring(response: 0.32, dampingFraction: 0.9)
    static var forceExternal = false                           // the render tool: show the Monitors tab
    static var external: Bool { forceExternal || !DDCDisplays.externalNames.isEmpty }

    static func clamp(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
    static func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    static func smooth(_ x: CGFloat) -> CGFloat { let t = clamp(x); return t * t * (3 - 2 * t) }
    /// The morph's progress for an item that starts a little later: still 1 at p = 1, and it keeps the spring's overshoot.
    static func delayed(_ p: CGFloat, by d: CGFloat) -> CGFloat { p < 0 ? p : max(0, (p - d) / (1 - d)) }
    /// Cross-morph timing: what the closed island shows is gone by p 0.5, what replaces it arrives over p 0.15…0.6.
    static func meltOut(_ p: CGFloat) -> CGFloat { smooth(p / 0.5) }
    static func meltIn(_ p: CGFloat) -> CGFloat { smooth((p - 0.15) / 0.45) }
    /// id, symbol, title. The first half goes left of the notch, the rest right of it.
    static func tabs(external: Bool) -> [(id: String, icon: String, title: String)] {
        var t = [("home", "house.fill", L("Home")), ("music", "music.note", L("Music")), ("media", "play.rectangle.fill", L("Media")), ("calendar", "calendar", L("Calendar")), ("focus", "timer", L("Focus")),
                 ("files", "tray.full.fill", L("Files")), ("shelf", "tray.and.arrow.down.fill", L("Shelf")), ("clipboard", "doc.on.clipboard", L("Clipboard")),
                 ("status", "gauge.with.needle", L("Status")), ("mirror", "person.crop.square", L("Mirror"))]
        if external { t.append(("display", "display", L("Monitors"))) }
        return t
    }
}

/// Where the island sits: the real notch of a built-in display, or a slim pill at the top of any other screen.
private struct NotchGeometry: Equatable {
    var frame: CGRect          // the screen's frame
    var notchWidth: CGFloat
    var height: CGFloat
    var centerX: CGFloat       // the notch's middle, in screen coordinates
    var hasNotch: Bool

    static func current() -> NotchGeometry? {
        let screens = NSScreen.screens
        guard let s = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first else { return nil }
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return NotchGeometry(frame: s.frame, notchWidth: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top,
                                 centerX: s.frame.minX + l.width + (s.frame.width - l.width - r.width) / 2, hasNotch: true)
        }
        return NotchGeometry(frame: s.frame, notchWidth: 150, height: 24, centerX: s.frame.midX, hasNotch: false)
    }
}

/// One moment of the open/close morph. p runs from 0 (closed) to 1 (open) and a spring overshoots it a little past either end;
/// leftW/rightW are the closed island's wings. Everything that moves is a function of this, so the outline, the clip and every
/// icon stay in step whatever the spring does (and the render tool can draw any moment of it).
private struct IslandPose {
    var p: CGFloat
    var leftW: CGFloat
    var rightW: CGFloat
    var data: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(p, AnimatablePair(leftW, rightW)) }
        set { p = newValue.first; leftW = newValue.second.first; rightW = newValue.second.second }
    }
    /// 0 with the bag alone on the left, 1 while a flash message widens the left wing.
    var flash: CGFloat { Island.clamp((leftW - Island.wing) / (IslandModel.maxWing - Island.wing)) }
    /// 0 with nothing right of the notch, 1 with something live there.
    var wing: CGFloat { Island.clamp(rightW / Island.wing) }
}

/// The island's geometry in a fixed canvas: as wide as the open island plus room for the spring's overshoot, centred on the notch,
/// its top `overscan` above the screen's edge. The canvas never changes size, so resizing the window around it moves nothing.
private struct IslandLayout {
    let notch: CGFloat          // the notch's width
    let notchH: CGFloat         // and its height (the menu bar's)
    static let openBody = Island.openSize.width - 28        // the open island between its two top flares

    var size: CGSize { CGSize(width: max(Island.openSize.width + 2 * Island.slack, notch + 2 * IslandModel.maxWing + 20),
                              height: Island.openSize.height + Island.slack + Island.overscan) }
    var cx: CGFloat { size.width / 2 }
    var top: CGFloat { Island.overscan }
    var notchLeft: CGFloat { cx - notch / 2 }
    var notchRight: CGFloat { cx + notch / 2 }

    /// Height trails width a little: the island first runs along the screen's edge, then drops (and on closing, rises first).
    static func depth(_ p: CGFloat) -> CGFloat { p <= 0 ? p : p < 1 ? pow(p, 1.5) : 1 + 1.5 * (p - 1) }

    /// The outline: concave flares where it meets the screen's edge, straight sides, continuous ("squircle") bottom corners.
    /// Closed it is the real notch's silhouette plus its wings; every measure is interpolated, so it morphs along the same lines.
    func sides(_ s: IslandPose) -> (minX: CGFloat, maxX: CGFloat) {
        (min(Island.mix(notchLeft - s.leftW, cx - Self.openBody / 2, s.p), notchLeft),                 // never narrower than the notch
         max(Island.mix(notchRight + s.rightW, cx + Self.openBody / 2, s.p), notchRight))
    }
    func bodyWidth(_ s: IslandPose) -> CGFloat { let b = sides(s); return b.maxX - b.minX }

    func path(_ s: IslandPose) -> Path {
        let p = s.p, d = Self.depth(p)
        let (minX, maxX) = sides(s)
        let y0 = top, y1 = top + max(notchH, Island.mix(notchH, Island.openSize.height, d))
        let flare = max(0, Island.mix(6.5, 14, p))                                                  // how far the flare reaches out
        let flareH = min(max(0, Island.mix(7, 15, p)), (y1 - y0) * 0.4)                             // and down the side
        let corner = max(0, min(Island.mix(10, 24, d) * 1.35, y1 - y0 - flareH, (maxX - minX) / 2)) // span of a bottom corner
        let kf: CGFloat = 0.6, kc: CGFloat = 0.7          // handle lengths: long handles ease into the straight lines (no kink)
        var path = Path()
        path.move(to: CGPoint(x: minX - flare, y: 0))
        path.addLine(to: CGPoint(x: maxX + flare, y: 0))
        path.addLine(to: CGPoint(x: maxX + flare, y: y0))
        path.addCurve(to: CGPoint(x: maxX, y: y0 + flareH), control1: CGPoint(x: maxX + flare * (1 - kf), y: y0), control2: CGPoint(x: maxX, y: y0 + flareH * (1 - kf)))
        path.addLine(to: CGPoint(x: maxX, y: y1 - corner))
        path.addCurve(to: CGPoint(x: maxX - corner, y: y1), control1: CGPoint(x: maxX, y: y1 - corner * (1 - kc)), control2: CGPoint(x: maxX - corner * (1 - kc), y: y1))
        path.addLine(to: CGPoint(x: minX + corner, y: y1))
        path.addCurve(to: CGPoint(x: minX, y: y1 - corner), control1: CGPoint(x: minX + corner * (1 - kc), y: y1), control2: CGPoint(x: minX, y: y1 - corner * (1 - kc)))
        path.addLine(to: CGPoint(x: minX, y: y0 + flareH))
        path.addCurve(to: CGPoint(x: minX - flare, y: y0), control1: CGPoint(x: minX, y: y0 + flareH * (1 - kf)), control2: CGPoint(x: minX - flare * (1 - kf), y: y0))
        path.closeSubpath()
        return path
    }
}

/// The island's outline at a pose: filled black, and used again as the clip of everything inside it.
private struct IslandOutline: Shape {
    var pose: IslandPose
    let layout: IslandLayout
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> { get { pose.data } set { pose.data = newValue } }
    func path(in rect: CGRect) -> Path { layout.path(pose) }
}

/// Carries one item of the top strip along the morph, from where it is in the closed island (a wing, or tucked behind the notch)
/// to its cell in the open strip. Items leave in a short stagger, outermost first, so they come out of the notch like a train and
/// never cross; closing runs the same function backwards, so the innermost are home first.
private struct StripSlide: ViewModifier, Animatable {
    enum From { case leftWing, rightWing, gear, behindLeft, behindRight }
    enum Fade { case none, reveal, melt, gear }
    var pose: IslandPose
    let layout: IslandLayout
    let from: From
    let to: CGFloat             // the centre of its cell in the open strip
    let width: CGFloat
    let order: Int              // 0 = outermost
    let fade: Fade
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> { get { pose.data } set { pose.data = newValue } }

    func body(content: Content) -> some View {
        let l = layout, p = pose.p
        let start: CGFloat
        switch from {
        case .leftWing: start = l.notchLeft - pose.leftW / 2
        case .rightWing: start = l.notchRight + pose.rightW / 2
        case .behindLeft: start = l.notchLeft + width / 2
        case .behindRight: start = l.notchRight - width / 2
        case .gear: start = Island.mix(l.notchRight - width / 2, l.notchRight + pose.rightW / 2, pose.wing)    // where the live item is, if any
        }
        let t = Island.delayed(p, by: CGFloat(order) * 0.045)
        let x = Island.mix(start, to, t)
        // How much of it is out from behind the notch (the hardware hides the rest; without a notch it fades in the same way).
        let out = Island.clamp(x < l.cx ? (l.notchLeft - (x - width / 2)) / width : (x + width / 2 - l.notchRight) / width)
        var alpha: CGFloat = 1, scale: CGFloat = 1, blur: CGFloat = 0
        switch fade {
        case .none: break
        case .reveal:           // they fan out of the notch: small while still bunched up, full size once in their cells
            alpha = out * Island.smooth(t / 0.6); scale = Island.mix(0.45, 1, Island.clamp(t))
        case .melt:                                         // the closed island's live item, melting into the gear as it travels
            let m = Island.meltOut(p)
            alpha = (1 - m) * pose.wing; scale = 1 - 0.3 * m; blur = 3 * m
        case .gear:
            let a = Island.meltIn(p)
            alpha = Island.mix(out, a, pose.wing); scale = 0.6 + 0.4 * alpha; blur = 3 * (1 - a) * pose.wing
        }
        return content.scaleEffect(scale).blur(radius: blur).opacity(alpha)
            .offset(x: x - width / 2, y: l.top)
    }
}

/// Cross-morphs inside the bag's cell: the flash icon melts out as the bag melts in, and the Home highlight appears.
private struct CellMorph: ViewModifier, Animatable {
    enum Kind { case bag(dim: CGFloat), flashIcon, highlight }
    var pose: IslandPose
    let kind: Kind
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> { get { pose.data } set { pose.data = newValue } }

    func body(content: Content) -> some View {
        let p = pose.p
        var alpha: CGFloat = 1, scale: CGFloat = 1, blur: CGFloat = 0
        switch kind {
        case .bag(let dim):                                 // closed: full; open: like an unselected tab when Home isn't shown
            let a = Island.mix(1, Island.meltIn(p), pose.flash)
            alpha = a * Island.mix(1, dim, Island.clamp(p)); scale = Island.mix(1, 0.7 + 0.3 * a, pose.flash); blur = 3 * (1 - a)
        case .flashIcon:
            let m = Island.meltOut(p)
            alpha = 1 - m; scale = 1 - 0.3 * m; blur = 3 * m
        case .highlight: alpha = Island.clamp((p - 0.5) / 0.4)
        }
        return content.scaleEffect(scale).blur(radius: blur).opacity(alpha)
    }
}

/// The open page below the strip: it grows with the island's width (so it is never cut by the sides), fades in a beat after
/// the island starts to open, and goes first on closing.
private struct PageReveal: ViewModifier, Animatable {
    var pose: IslandPose
    let layout: IslandLayout
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> { get { pose.data } set { pose.data = newValue } }
    func body(content: Content) -> some View {
        let c = Island.smooth((pose.p - 0.35) / 0.55)
        let scale = min(1, max(0.5, layout.bodyWidth(pose) / IslandLayout.openBody))
        return content.opacity(c).scaleEffect(scale, anchor: .top).offset(y: -8 * (1 - c))
    }
}

// MARK: Island data

/// Focus / break timer: a minute ruler to set the length, a countdown shown in the closed island.
private final class FocusTimer: ObservableObject {
    @Published var focusMinutes = 25
    @Published var breakMinutes = 5
    @Published var isBreak = false
    @Published var endsAt: Date?
    @Published var pausedLeft: TimeInterval?
    @Published var tick = Date()
    var onFinish: ((Bool) -> Void)?                // true when a break just ended
    var onStart: ((Int) -> Void)?
    private var timer: Timer?

    var minutes: Int { get { isBreak ? breakMinutes : focusMinutes } set { if isBreak { breakMinutes = newValue } else { focusMinutes = newValue } } }
    var running: Bool { endsAt != nil }
    var active: Bool { endsAt != nil || pausedLeft != nil }
    var remaining: TimeInterval { endsAt.map { max(0, $0.timeIntervalSinceNow) } ?? pausedLeft ?? Double(minutes) * 60 }
    var text: String { let s = Int(remaining.rounded(.up)); return String(format: "%d:%02d", s / 60, s % 60) }

    func start() {
        Haptic.tap(.generic)
        let left = pausedLeft ?? Double(minutes) * 60
        endsAt = Date().addingTimeInterval(left); pausedLeft = nil
        if !isBreak { onStart?(Int((left / 60).rounded(.up)) + 1) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.step() }
    }
    func pause() { Haptic.tap(.alignment); pausedLeft = remaining; endsAt = nil; timer?.invalidate(); tick = Date() }
    func reset() { Haptic.tap(.alignment); endsAt = nil; pausedLeft = nil; timer?.invalidate(); tick = Date() }
    func setBreak(_ b: Bool) { reset(); isBreak = b }
    private func step() {
        tick = Date()
        guard let e = endsAt, e.timeIntervalSinceNow <= 0 else { return }
        let wasBreak = isBreak
        reset()
        NSSound(named: "Glass")?.play()
        Haptic.finished()
        isBreak.toggle()
        onFinish?(wasBreak)
    }
}

private struct BatteryItem: Identifiable {
    var id: String
    var name: String
    var icon: String
    var parts: [(label: String, percent: Int)]
    var charging = false
}

/// Charge of the Mac and of connected Bluetooth devices (AirPods, keyboard, mouse, trackpad).
private final class BatteryWatch: ObservableObject {
    @Published var items: [BatteryItem] = []
    private var busy = false

    func refresh() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global().async {
            var list: [BatteryItem] = []
            if let b = System.battery {
                list.append(BatteryItem(id: "mac", name: "Mac", icon: "laptopcomputer", parts: [("", b.percent)], charging: b.onAC))
            }
            list += Self.bluetooth()
            DispatchQueue.main.async { self.items = list; self.busy = false }
        }
    }

    private static func bluetooth() -> [BatteryItem] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let top = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = top["device_connected"] as? [[String: Any]] else { return [] }
        func pct(_ v: Any?) -> Int? { (v as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
        var items: [BatteryItem] = []
        for entry in connected {
            for (name, value) in entry {
                guard let d = value as? [String: Any] else { continue }
                var parts: [(String, Int)] = []
                for (key, label) in [("device_batteryLevelMain", ""), ("device_batteryLevelLeft", "L"), ("device_batteryLevelRight", "R"), ("device_batteryLevelCase", "↳")] {
                    if let v = pct(d[key]) { parts.append((label, v)) }
                }
                guard !parts.isEmpty else { continue }
                let kind = (d["device_minorType"] as? String ?? "").lowercased()
                let icon = kind.contains("head") || name.lowercased().contains("airpods") ? "airpodspro" : kind.contains("keyboard") ? "keyboard"
                    : kind.contains("mouse") ? "computermouse" : kind.contains("trackpad") ? "rectangle.and.hand.point.up.left" : "dot.radiowaves.left.and.right"
                items.append(BatteryItem(id: name, name: name, icon: icon, parts: parts))
            }
        }
        return items.sorted { $0.name < $1.name }
    }
}

/// Is something using the microphone right now? (CoreAudio's own "running somewhere" flag of the default input.)
private final class MicWatch: ObservableObject {
    @Published var active = false
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr, device != 0 else { return }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return }
        let now = running != 0
        if now != active { active = now }
    }
}

/// Usage of the AI coding tools, read from their own local files: Codex's rate limits, and Claude Code's token counts.
private final class UsageWatch: ObservableObject {
    struct Limit: Identifiable { var id: String; var name: String; var percent: Double; var resets: Date? }
    @Published var codex: [Limit] = []
    @Published var claudeFive = 0
    @Published var claudeWeek = 0
    @Published var loaded = false
    private var busy = false, last = Date.distantPast

    func refresh() {
        guard !busy, Date().timeIntervalSince(last) > 30 else { return }
        busy = true
        DispatchQueue.global().async {
            let c = Self.codexLimits(), t = Self.claudeTokens()
            DispatchQueue.main.async { self.codex = c; self.claudeFive = t.five; self.claudeWeek = t.week; self.loaded = true; self.busy = false; self.last = Date() }
        }
    }

    private static func codexLimits() -> [Limit] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var newest: (URL, Date)?
        for case let u as URL in en where u.pathExtension == "jsonl" {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if newest == nil || d > newest!.1 { newest = (u, d) }
        }
        guard let file = newest?.0, let h = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        guard let r = text.range(of: "\"rate_limits\":", options: .backwards) else { return [] }
        let tail = String(text[r.upperBound...].prefix(600))
        guard let re = try? NSRegularExpression(pattern: #""used_percent":([0-9.]+),"window_minutes":(\d+),"resets_at":(\d+)"#) else { return [] }
        return re.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).compactMap { m in
            guard let a = Range(m.range(at: 1), in: tail), let b = Range(m.range(at: 2), in: tail), let c = Range(m.range(at: 3), in: tail),
                  let pct = Double(tail[a]), let win = Int(tail[b]), let reset = Double(tail[c]) else { return nil }
            let name = win >= 10000 ? L("Week") : win >= 1440 ? L("Day") : String(format: L("%d h"), win / 60)
            return Limit(id: "codex\(win)", name: name, percent: pct, resets: Date(timeIntervalSince1970: reset))
        }
    }

    /// Input + output tokens of Claude Code's own conversations in the last 5 hours and 7 days (each message counted once).
    private static func claudeTokens() -> (five: Int, week: Int) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return (0, 0) }
        let now = Date(), weekAgo = now.addingTimeInterval(-7 * 86400), fiveAgo = now.addingTimeInterval(-5 * 3600)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date()
        var byID: [String: (Date, Int)] = [:]
        func number(_ key: String, in s: Substring) -> Int {
            guard let r = s.range(of: key) else { return 0 }
            return Int(s[r.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        for case let u as URL in en where u.pathExtension == "jsonl" {
            guard Date().timeIntervalSince(start) < 4 else { break }
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard (v?.contentModificationDate ?? .distantPast) > weekAgo, (v?.fileSize ?? 0) < 120_000_000, let data = try? Data(contentsOf: u) else { continue }
            for line in data.split(separator: 10) {
                guard line.count > 40, let s = String(data: line, encoding: .utf8), s.contains("\"output_tokens\":") else { continue }
                let sub = Substring(s)
                guard let tsR = sub.range(of: "\"timestamp\":\""), let ts = iso.date(from: String(sub[tsR.upperBound...].prefix(24))) else { continue }
                var id = "\(u.lastPathComponent)\(ts.timeIntervalSince1970)"
                if let idR = sub.range(of: "\"id\":\"msg_") { id = String(sub[idR.upperBound...].prefix { $0 != "\"" }) }
                let total = number("\"input_tokens\":", in: sub) + number("\"output_tokens\":", in: sub)
                if total > (byID[id]?.1 ?? 0) { byID[id] = (ts, total) }
            }
        }
        var five = 0, week = 0
        for (_, v) in byID where v.0 > weekAgo { week += v.1; if v.0 > fiveAgo { five += v.1 } }
        return (five, week)
    }
}

// MARK: Island, part 2: files and screenshots, clipboard, calendar

/// Recent downloads and screenshots, found by looking at the two folders every couple of seconds.
private final class FileShelf: ObservableObject {
    struct Item: Identifiable, Equatable {
        var url: URL
        var id: URL { url }
        var name: String { url.lastPathComponent }
        var date: Date
        var size: Int64
    }
    @Published var downloads: [Item] = []
    @Published var shots: [Item] = []
    var onNew: ((String, String) -> Void)?        // symbol, text: a file just arrived
    private var known = Set<URL>()
    private var primed = false
    private var timer: Timer?

    static var downloadsFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads") }
    static var screenshotsFolder: URL {
        if let p = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }
    private static let shotPrefixes = ["Screenshot", "Screen Shot", "Schermata", "Captura", "Capture", "Bildschirmfoto", "スクリーンショット", "截屏", "屏幕快照", "螢幕快照"]
    private static let partial: Set<String> = ["crdownload", "download", "part", "opdownload", "tmp"]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    func stop() { timer?.invalidate(); timer = nil; primed = false }

    private let queue = DispatchQueue(label: "local.cocaine.files")
    private var busy = false

    private func poll() {
        // One listing at a time: the first one can wait (macOS asking for the folder) and must not pile up threads behind it.
        guard !busy else { return }
        busy = true
        queue.async {
            defer { DispatchQueue.main.async { self.busy = false } }
            let dl = Self.list(Self.downloadsFolder) { !Self.partial.contains($0.pathExtension.lowercased()) }
            let shotDir = Self.screenshotsFolder
            let sh = Self.list(shotDir) { u in
                let n = u.lastPathComponent
                return ["png", "jpg", "jpeg", "heic", "mov"].contains(u.pathExtension.lowercased())
                    && (shotDir.path != Self.downloadsFolder.path) && Self.shotPrefixes.contains { n.hasPrefix($0) }
            }
            DispatchQueue.main.async {
                let all = Set((dl + sh).map(\.url))
                if self.primed {
                    for it in dl where !self.known.contains(it.url) && Date().timeIntervalSince(it.date) < 120 { self.onNew?("arrow.down.circle.fill", it.name) }
                    for it in sh where !self.known.contains(it.url) && Date().timeIntervalSince(it.date) < 120 { self.onNew?("camera.viewfinder", L("Screenshot")) }
                }
                self.known.formUnion(all); self.primed = true
                if dl != self.downloads { self.downloads = dl }
                if sh != self.shots { self.shots = sh }
            }
        }
    }

    private static func list(_ dir: URL, where keep: (URL) -> Bool) -> [Item] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { u -> Item? in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, keep(u) else { return nil }
            return Item(url: u, date: v.contentModificationDate ?? .distantPast, size: Int64(v.fileSize ?? 0))
        }.sorted { $0.date > $1.date }.prefix(6).map { $0 }
    }
}

/// A small image for a file, made off the main thread.
private final class Thumb: ObservableObject {
    @Published var image: NSImage?
    private static var cache: [URL: NSImage] = [:]
    func load(_ url: URL, side: CGFloat) {
        if let c = Self.cache[url] { image = c; return }
        DispatchQueue.global().async {
            var img: NSImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side * 2] as CFDictionary) {
                img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
            } else {
                img = NSWorkspace.shared.icon(forFile: url.path)
            }
            DispatchQueue.main.async { if let img { Self.cache[url] = img }; self.image = img }
        }
    }
}

private struct FileThumb: View {
    let url: URL
    let side: CGFloat
    @StateObject private var thumb = Thumb()
    var body: some View {
        Group {
            if let i = thumb.image { Image(nsImage: i).resizable().aspectRatio(contentMode: .fill) } else { Color.white.opacity(0.08) }
        }
        .frame(width: side * 1.5, height: side).clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { thumb.load(url, side: side) }
    }
}

/// The clipboard history lives in Sources/Clipboard.swift; its text comes from the Clipboard string table.
func clipboardL(_ key: String) -> String { L(key) }

/// Today and the next events (up to two weeks ahead) from the Calendar app, with the user's permission.
private final class CalendarWatch: ObservableObject {
    struct Ev: Identifiable { var id: String; var title: String; var start: Date; var end: Date; var allDay: Bool; var color: Color }
    @Published var events: [Ev] = []
    @Published var access = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published var asked = EKEventStore.authorizationStatus(for: .event) != .notDetermined
    private var store = EKEventStore()
    private var storeHasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess

    func refresh() {
        access = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard access else { return }
        if !storeHasAccess { store = EKEventStore(); storeHasAccess = true }     // a store made before the permission sees no events
        let now = Date(), end = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
        let found = store.events(matching: store.predicateForEvents(withStart: Calendar.current.startOfDay(for: now), end: end, calendars: nil))
            .filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }.prefix(6)
        events = found.map { e in Ev(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                                     color: Color(nsColor: e.calendar.color ?? .systemBlue)) }
    }

    func requestAccess() {
        Permissions.request(.calendar) { [weak self] in self?.asked = true; self?.refresh() }
    }
}

/// The island's clipboard page: search, favorites, pause, and the history itself (Sources/Clipboard.swift).
private struct ClipboardPage: View {
    @ObservedObject var h: ClipboardHistory
    let flash: (String, String) -> Void
    let keyable: (Bool) -> Void

    var body: some View {
        let list = h.visible
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    TextField(L("Search"), text: $h.query).textFieldStyle(.plain).font(.system(size: 12))
                        .onExitCommand { h.query = "" }
                    if !h.query.isEmpty {
                        Button { h.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)) }
                            .buttonStyle(.plain).help(L("Clear search"))
                    }
                }
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                tool(h.favoritesOnly ? "star.fill" : "star", on: h.favoritesOnly, L("Favorites only")) { h.favoritesOnly.toggle() }
                tool(h.paused ? "play.fill" : "pause.fill", on: h.paused, h.paused ? L("Resume") : L("Pause")) { h.paused.toggle() }
                Menu {
                    Button(L("Clear history (keeps favorites)")) { h.clearHistory() }
                    Button(L("Delete everything…"), role: .destructive) { ClipboardUI.confirmDeleteEverything(h) }
                } label: {
                    Image(systemName: "trash").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 24).help(L("Clear"))
            }
            if list.isEmpty {
                Text(h.items.isEmpty ? L("What you copy will show up here") : h.favoritesOnly && h.query.isEmpty ? L("No favorites yet") : L("Nothing matches"))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], alignment: .leading, spacing: 7) {
                    ForEach(list) { c in row(c) }
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .onAppear { keyable(true) }
        .onDisappear { keyable(false); h.hovered = nil }
    }

    /// A small square button of the toolbar, highlighted while its mode is on (like the selected tab).
    private func tool(_ icon: String, on: Bool, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptic.tap(.alignment); action() } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(on ? Island.accent : .white.opacity(0.5))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(on ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private func row(_ c: ClipItem) -> some View {
        let gone = h.missing.contains(c.id), hover = h.hovered == c.id
        return HStack(spacing: 7) {
            Button { copy(c) } label: {
                HStack(spacing: 7) {
                    leading(c)
                    Text(title(c)).font(.system(size: 12)).lineLimit(1).truncationMode(c.kind == .files ? .middle : .tail)
                        .foregroundStyle(gone ? Color.white.opacity(0.4) : Color.white)
                    if gone { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(warningColor) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hover {
                Button { h.remove(c.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).frame(width: 14, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L("Delete")).accessibilityLabel(L("Delete"))
            }
            Button { Haptic.tap(.alignment); h.togglePin(c.id) } label: {
                Image(systemName: c.pinned ? "star.fill" : "star").font(.system(size: 10))
                    .foregroundStyle(c.pinned ? Island.accent : Color.white.opacity(hover ? 0.5 : 0.18)).frame(width: 14, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(c.pinned ? L("Remove from favorites") : L("Add to favorites"))
            .accessibilityLabel(c.pinned ? L("Remove from favorites") : L("Add to favorites"))
        }
        .padding(.leading, 10).padding(.trailing, 6).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
        .onHover { inside in if inside { h.hovered = c.id } else if h.hovered == c.id { h.hovered = nil } }
        .help(gone ? L("The file is no longer there") : tip(c))
        .contextMenu {
            Button(L("Copy")) { copy(c) }
            Button(c.pinned ? L("Remove from favorites") : L("Add to favorites")) { h.togglePin(c.id) }
            if c.kind == .files, !gone { Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(c.paths.map { URL(fileURLWithPath: $0) }) } }
            Divider()
            Button(L("Delete")) { h.remove(c.id) }
        }
    }

    @ViewBuilder private func leading(_ c: ClipItem) -> some View {
        switch c.kind {
        case .text: EmptyView()
        case .image:
            Group {
                if let t = h.thumbnail(c) { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) } else { Color.white.opacity(0.1) }
            }
            .frame(width: 22, height: 16).clipShape(RoundedRectangle(cornerRadius: 3))
        case .files:
            Image(nsImage: NSWorkspace.shared.icon(forFile: c.paths.first ?? "/")).resizable().frame(width: 16, height: 16)
        }
    }

    private func title(_ c: ClipItem) -> String {
        switch c.kind {
        case .text: return c.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        case .image: return L("Image") + " · \(c.width)×\(c.height)"
        case .files: return (c.names.first ?? "") + (c.names.count > 1 ? " +\(c.names.count - 1)" : "")
        }
    }

    private func tip(_ c: ClipItem) -> String {
        var parts: [String] = []
        switch c.kind {
        case .text: parts.append(String(c.text.prefix(300)))
        case .image: parts.append(L("Image") + " · \(c.width)×\(c.height) · " + ByteCountFormatter.string(fromByteCount: Int64(c.bytes), countStyle: .file))
        case .files: parts.append(c.paths.prefix(5).joined(separator: "\n"))
        }
        if let app = ClipboardHistory.appName(c.source) { parts.append(app) }
        parts.append(c.date.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: "\n")
    }

    private func copy(_ c: ClipItem) {
        if h.copy(c) {
            Haptic.tap(.generic)
            flash("doc.on.clipboard.fill", L("Copied"))
        } else {
            flash("exclamationmark.triangle.fill", c.kind == .files ? L("The file is no longer there") : L("Can't copy it"))
        }
    }

    /// Where the history is kept, said plainly; a problem (no Keychain, unreadable file) takes its place.
    @ViewBuilder private var footer: some View {
        if let p = h.problem {
            Label(p, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(warningColor).lineLimit(1).help(p)
        } else if h.paused {
            Label(L("Paused: what you copy now isn't kept."), systemImage: "pause.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
        } else if h.saving {
            Label(L("Saved on this Mac, encrypted. Never from password managers."), systemImage: "lock.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
        } else {
            Text(L("Kept only in memory, never from password managers. Click to copy again.")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
        }
    }
}

/// The clipboard's confirmations and its little editors (alerts, centred on the screen, with the panel out of the way).
private enum ClipboardUI {
    static var beforeAlert: () -> Void = {}

    static func setPersist(_ h: ClipboardHistory, _ on: Bool) {
        if on { h.setPersist(true); return }
        beforeAlert()
        let a = NSAlert()
        a.messageText = L("Stop saving the clipboard history?")
        a.informativeText = L("The saved copy can be deleted now, with its Keychain key, or kept encrypted on this Mac for the next time you turn this on.")
        a.addButton(withTitle: L("Delete it"))
        a.addButton(withTitle: L("Keep it"))
        a.addButton(withTitle: L("Cancel"))
        switch a.runModal() {
        case .alertFirstButtonReturn: h.setPersist(false, wipe: true)
        case .alertSecondButtonReturn: h.setPersist(false, wipe: false)
        default: break
        }
    }

    static func confirmDeleteEverything(_ h: ClipboardHistory) {
        beforeAlert()
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = L("Delete the whole clipboard history?")
        a.informativeText = L("Everything, favorites included, plus the saved files and their Keychain key. It can't be undone.")
        a.addButton(withTitle: L("Delete everything"))
        a.addButton(withTitle: L("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if !h.deleteEverything() {
            let e = NSAlert()
            e.messageText = L("Some of it couldn't be deleted")
            e.informativeText = ClipStore.defaultDir.path
            e.runModal()
        }
    }

    static func addPattern(_ h: ClipboardHistory) {
        beforeAlert()
        let a = NSAlert()
        a.messageText = L("Exclude text matching a pattern")
        a.informativeText = L("A regular expression, e.g. ^IBAN or \\bconfidential\\b. Matching text isn't kept.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        a.accessoryView = field
        a.window.initialFirstResponder = field
        a.addButton(withTitle: L("Add"))
        a.addButton(withTitle: L("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let p = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard ClipRules.validPattern(p) else {
            let e = NSAlert(); e.messageText = L("That isn't a valid pattern"); e.informativeText = p; e.runModal()
            return
        }
        var s = h.settings
        if !s.patterns.contains(p) { s.patterns.append(p) }
        h.update(s)
    }

    /// Apps that are open now and could be excluded: name and bundle id.
    static func runningApps(excluding: [String]) -> [(name: String, id: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { (a.localizedName ?? $0, $0) } }
            .filter { app in !excluding.contains(app.1) && !ClipRules.isPasswordApp(app.1) && app.1 != Bundle.main.bundleIdentifier }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            .map { (name: $0.0, id: $0.1) }
    }
}

extension IslandView {
    // MARK: files

    fileprivate var filesTab: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Downloads")).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                if files.downloads.isEmpty { Text(L("Nothing here yet")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)) }
                ScrollView(.vertical, showsIndicators: false) { VStack(alignment: .leading, spacing: 8) { ForEach(files.downloads) { it in
                    Button { NSWorkspace.shared.activateFileViewerSelecting([it.url]) } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: it.url.path)).resizable().frame(width: 20, height: 20)
                            Text(it.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(ByteCountFormatter.string(fromByteCount: it.size, countStyle: .file)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onDrag { NSItemProvider(object: it.url as NSURL) }
                } } }.frame(maxHeight: 112)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Screenshots")).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                if files.shots.isEmpty { Text(L("Nothing here yet")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)) }
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) {
                    ForEach(files.shots) { it in
                        FileThumb(url: it.url, side: 62)
                            .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([it.url]) }
                            .onDrag { NSItemProvider(object: it.url as NSURL) }
                            .help(it.name)
                    }
                } }
                .mask(HStack(spacing: 0) { Rectangle(); LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 22) })
                Text(L("Drag a file out to drop it anywhere")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                Spacer(minLength: 0)
            }
            .frame(width: 250, alignment: .leading)
        }
    }

    // MARK: clipboard

    fileprivate var clipboardTab: some View {
        ClipboardPage(h: clipboard, flash: { model.flashNotice($0, $1) }, keyable: model.setKeyable)
    }

    // MARK: calendar

    fileprivate var calendarTab: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date().formatted(.dateTime.weekday(.wide)).capitalized).font(.system(size: 12, weight: .medium)).foregroundStyle(Island.accent)
                Text(Date().formatted(.dateTime.day())).font(.system(size: 54, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(Date().formatted(.dateTime.month(.wide).year())).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            .frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                if !calendar.access {
                    Text(L("Show your next events here")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    if calendar.asked {
                        Text(L("Allow it in System Settings → Privacy & Security → Calendars")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    } else {
                        Button { calendar.requestAccess() } label: {
                            Text(L("Allow Calendar")).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Capsule().fill(Island.accent)).foregroundStyle(.black)
                        }.buttonStyle(.plain)
                    }
                } else if calendar.events.isEmpty {
                    Text(L("No events in the next two weeks")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                } else {
                    ScrollView(.vertical, showsIndicators: false) { VStack(alignment: .leading, spacing: 8) { ForEach(calendar.events) { e in
                        HStack(spacing: 9) {
                            Capsule().fill(e.color).frame(width: 3, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(e.allDay ? e.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " · " + L("All day")
                                     : e.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer(minLength: 0)
                        }
                    } } }.frame(maxHeight: 124)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if Permissions.state(.calendar) == .notAsked { calendar.requestAccess() }          // asked the first time the page is opened
            calendar.refresh()
        }
    }
}

// MARK: Island, part 3: music with lyrics, volume/brightness HUDs, camera mirror, external monitors

/// Apple Music and Spotify, through their own scripting: title, artwork, a scrubber and the transport buttons, and (only if
/// switched on) synced lyrics looked up on lrclib.net by title and artist.
private final class MusicWatch: ObservableObject {
    struct Track: Equatable { var id: String; var title: String; var artist: String; var album: String; var duration: Double; var app: String }
    struct Line { var time: Double; var text: String }
    @Published var track: Track?
    @Published var playing = false
    @Published var shuffle = false
    @Published var artwork: NSImage?
    @Published var lyrics: [Line] = []
    @Published var denied = false
    @Published var lyricsOn = UserDefaults.standard.bool(forKey: "islandLyrics")
    private(set) var position = 0.0
    private(set) var fetched = Date()
    private var timer: Timer?
    private let queue = DispatchQueue(label: "local.cocaine.music")
    private var busy = false
    private var lyricsFor = ""

    private static let apps: [(name: String, bundle: String)] = [("Music", "com.apple.Music"), ("Spotify", "com.spotify.client")]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    func stop() { timer?.invalidate(); timer = nil; track = nil; playing = false }

    /// Where the song is now, in seconds (the scripting value, carried on by the clock between polls).
    var now: Double { min(track?.duration ?? 0, position + (playing ? Date().timeIntervalSince(fetched) : 0)) }

    var currentLine: String? {
        guard lyricsOn, !lyrics.isEmpty else { return nil }
        let t = now + 0.2
        return lyrics.last(where: { $0.time <= t })?.text
    }

    func setLyrics(_ on: Bool) {
        lyricsOn = on
        UserDefaults.standard.set(on, forKey: "islandLyrics")
        lyricsFor = ""
        if on, let t = track { loadLyrics(t) } else { lyrics = [] }
    }

    private func script(_ source: String) -> String? {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        let refused = (err?[NSAppleScript.errorNumber] as? Int) == -1743
        if refused || (err == nil && denied) { DispatchQueue.main.async { if self.denied != refused { self.denied = refused } } }   // allowed later: back
        return r?.stringValue
    }

    func setSample(title: String, artist: String, album: String) {
        track = Track(id: "x", title: title, artist: artist, album: album, duration: 200, app: "Music"); playing = true; position = 74; lyricsOn = true
        lyrics = [Line(time: 70, text: "I'm running out of time")]
    }

    private var askedAutomation = Set<String>()

    private func poll() {
        guard !busy else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = Self.apps.filter { running.contains($0.bundle) }
        guard !candidates.isEmpty else { if track != nil { track = nil; playing = false; artwork = nil; lyrics = [] }; return }
        busy = true
        queue.async {
            var found: (Track, Bool, Double, Bool)?
            for a in candidates {
                if !self.askedAutomation.contains(a.bundle) {                         // the first time this app is seen running: check, and ask if needed
                    self.askedAutomation.insert(a.bundle)
                    if Permissions.automation(a.bundle, ask: false) == -1744 {         // never asked: the question, in front
                        DispatchQueue.main.sync { NSApp.activate() }
                        _ = Permissions.automation(a.bundle, ask: true)
                    }
                }
                let isSpotify = a.name == "Spotify"
                let extra = isSpotify
                    ? "set dur to (duration of t) / 1000\n  set shuf to (shuffling as text)\n  set tid to (id of t)"
                    : "set dur to (duration of t)\n  set shuf to (shuffle enabled as text)\n  set tid to ((database ID of t) as text)"
                let src = """
                tell application "\(a.name)"
                  if player state is stopped then return ""
                  set t to current track
                  set pstate to (player state as text)
                  \(extra)
                  return pstate & "\\t" & (name of t) & "\\t" & (artist of t) & "\\t" & (album of t) & "\\t" & dur & "\\t" & (player position) & "\\t" & shuf & "\\t" & tid
                end tell
                """
                guard let out = self.script(src), !out.isEmpty else { continue }
                let f = out.components(separatedBy: "\t")
                guard f.count >= 8 else { continue }
                func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
                let playing = f[0].lowercased().contains("play")
                let t = Track(id: a.name + f[7], title: f[1], artist: f[2], album: f[3], duration: num(f[4]), app: a.name)
                if found == nil || playing { found = (t, playing, num(f[5]), f[6].lowercased() == "true") }
                if playing { break }
            }
            DispatchQueue.main.async {
                self.busy = false
                guard let (t, playing, pos, shuffle) = found else { self.track = nil; self.playing = false; return }
                self.position = pos; self.fetched = Date()
                if self.playing != playing { self.playing = playing }
                if self.shuffle != shuffle { self.shuffle = shuffle }
                if self.track != t {
                    self.track = t; self.artwork = nil; self.lyrics = []
                    self.loadArtwork(t)
                    if self.lyricsOn { self.loadLyrics(t) }
                }
            }
        }
    }

    private func loadArtwork(_ t: Track) {
        queue.async {
            var image: NSImage?
            if t.app == "Spotify" {
                if let u = self.script("tell application \"Spotify\" to return artwork url of current track"), let url = URL(string: u),
                   let d = try? Data(contentsOf: url) { image = NSImage(data: d) }
            } else {
                var err: NSDictionary?
                let r = NSAppleScript(source: "tell application \"Music\" to return raw data of artwork 1 of current track")?.executeAndReturnError(&err)
                if let d = r?.data, d.count > 100 { image = NSImage(data: d) }
            }
            DispatchQueue.main.async { if self.track == t { self.artwork = image } }
        }
    }

    private func loadLyrics(_ t: Track) {
        guard lyricsFor != t.id else { return }
        lyricsFor = t.id
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [URLQueryItem(name: "artist_name", value: t.artist), URLQueryItem(name: "track_name", value: t.title),
                        URLQueryItem(name: "album_name", value: t.album), URLQueryItem(name: "duration", value: String(Int(t.duration.rounded())))]
        guard let url = c.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Cocaine (github.com/Mattiakart/cocaine)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let synced = json["syncedLyrics"] as? String else { return }
            let re = try? NSRegularExpression(pattern: #"^\[(\d+):(\d+(?:\.\d+)?)\]\s*(.*)$"#)
            let lines: [Line] = synced.components(separatedBy: "\n").compactMap { l in
                guard let m = re?.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let a = Range(m.range(at: 1), in: l), let b = Range(m.range(at: 2), in: l),
                      let c = Range(m.range(at: 3), in: l), let min = Double(l[a]), let sec = Double(l[b]) else { return nil }
                return Line(time: min * 60 + sec, text: String(l[c]))
            }
            DispatchQueue.main.async { if self.track == t { self.lyrics = lines } }
        }.resume()
    }

    // transport
    func playPause() { Haptic.tap(.generic); run("playpause") }
    func next() { Haptic.tap(.alignment); run("next track") }
    func previous() { Haptic.tap(.alignment); run("previous track") }
    func seek(_ seconds: Double) { Haptic.tap(.alignment); position = seconds; fetched = Date(); run("set player position to \(Int(seconds))") }
    func toggleShuffle() { run(track?.app == "Spotify" ? "set shuffling to not shuffling" : "set shuffle enabled to not shuffle enabled"); shuffle.toggle() }
    private func run(_ command: String) {
        guard let app = track?.app else { return }
        queue.async { _ = self.script("tell application \"\(app)\" to \(command)") }
        if command == "playpause" { playing.toggle(); position = now; fetched = Date() }
    }
}

/// Volume and brightness changes (the keys, the menu bar, Control Center) as a message in the island, the instant they happen:
/// CoreAudio tells us about the volume itself; the brightness is read forty times a second (a few microseconds each).
private final class HUDWatch {
    var onChange: ((String, String, Double) -> Void)?
    var suppressBrightness: () -> Bool = { false }
    private var timer: Timer?
    private var started = false
    private var lastVolume: Float?, lastMute: Bool?, lastBrightness: Float?
    private let screens = Screens()
    private var device = AudioDeviceID(0)
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private static let volumeSelector: AudioObjectPropertySelector = 0x766D_7663       // 'vmvc': the virtual main volume

    func start() {
        guard !started else { return }
        started = true
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.bind() }
        systemListener = l
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, l)
        bind()
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in self?.pollBrightness() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.invalidate(); timer = nil
        if let l = systemListener {
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, l)
        }
        systemListener = nil
        unbind()
        lastVolume = nil; lastMute = nil; lastBrightness = nil
    }

    private func addresses() -> [AudioObjectPropertyAddress] {
        [AudioObjectPropertyAddress(mSelector: Self.volumeSelector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
         AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)]
    }

    private func unbind() {
        if device != 0, let l = deviceListener { for var a in addresses() { AudioObjectRemovePropertyListenerBlock(device, &a, .main, l) } }
        deviceListener = nil; device = 0
    }

    /// Follows the current output device (headphones in, a speaker out…).
    private func bind() {
        unbind()
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var d = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &d) == noErr, d != 0 else { return }
        device = d
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.volumeChanged() }
        deviceListener = l
        for var addr in addresses() { AudioObjectAddPropertyListenerBlock(d, &addr, .main, l) }
        lastVolume = nil; lastMute = nil
        readVolume(report: false)
    }

    private func volumeChanged() { readVolume(report: true) }

    private func readVolume(report: Bool) {
        guard device != 0 else { return }
        var va = addresses()[0], ma = addresses()[1]
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &va, 0, nil, &size, &v) == noErr else { return }
        var mute: UInt32 = 0, msize = UInt32(MemoryLayout<UInt32>.size)
        let muted = AudioObjectGetPropertyData(device, &ma, 0, nil, &msize, &mute) == noErr && mute != 0
        if report, lastVolume != nil, abs((lastVolume ?? v) - v) > 0.001 || (lastMute != nil && lastMute != muted) {
            let icon = muted || v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            onChange?(icon, L("Volume"), muted ? 0 : Double(v))
        }
        lastVolume = v; lastMute = muted
    }

    private func pollBrightness() {
        guard let id = screens.online.first(where: { CGDisplayIsBuiltin($0) != 0 }), let b = screens.brightness(id) else { return }
        if let l = lastBrightness, abs(l - b) > 0.002, !suppressBrightness() { onChange?("sun.max.fill", L("Brightness"), Double(b)) }
        lastBrightness = b
    }
}

/// macOS draws its volume and brightness HUD in a helper process, OSDUIHelper. While *Replace system HUD* is on, that helper is
/// kept started but frozen, so it never draws anything; when the option is turned off (or Cocaine quits) the helper is simply ended
/// and macOS starts a fresh one the next time it needs it.
private final class SystemHUD {
    private var timer: Timer?
    private var lastKick = Date.distantPast
    private(set) var active = false

    func enable() {
        guard !active else { return }
        active = true
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func disable() {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        for pid in Self.helperPIDs() { kill(pid, SIGKILL) }
    }

    /// After a crash the helper could be left frozen: end any frozen one at launch.
    static func cleanup() { for pid in helperPIDs() where isStopped(pid) { kill(pid, SIGKILL) } }

    private func tick() {
        let pids = Self.helperPIDs()
        if pids.isEmpty {
            if Date().timeIntervalSince(lastKick) > 3 {                           // start it now, so the first HUD can't flash
                lastKick = Date()
                DispatchQueue.global().async { run("/bin/launchctl", ["kickstart", "gui/\(getuid())/com.apple.OSDUIHelper"]) }
            }
            return
        }
        for pid in pids where !Self.isStopped(pid) { kill(pid, SIGSTOP) }
    }

    static func helperPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 2048)
        let n = Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))) / MemoryLayout<pid_t>.size
        var found: [pid_t] = []
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(n) where pid > 0 {
            if proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "OSDUIHelper" { found.append(pid) }
        }
        return found
    }

    static func isStopped(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return r > 0 && info.pbi_status == 4                                     // SSTOP
    }
}

/// A live view of the front camera, mirrored like a mirror. The camera runs only while it is on screen.
private final class MirrorController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Camera: Identifiable, Equatable { var id: String; var name: String }
    @Published var denied = false
    @Published var hasFrames = false
    @Published var stalled = false
    @Published var cameras: [Camera] = []
    @Published var selected = ""
    @Published var flip = UserDefaults.standard.object(forKey: "mirrorFlip") as? Bool ?? true { didSet { UserDefaults.standard.set(flip, forKey: "mirrorFlip") } }
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "local.cocaine.mirror")
    private var gotFrame = false
    private var generation = 0

    /// Checks the camera permission, asks for it if it was never asked, then starts the camera.
    func start() {
        denied = false; hasFrames = false; stalled = false
        wanted = true
        switch Permissions.state(.camera) {
        case .granted: run()
        case .notAsked:
            Permissions.request(.camera) { [weak self] in
                guard let self else { return }
                if Permissions.state(.camera) != .granted { self.denied = true }
                else if self.wanted { self.run() }               // the page may have closed while macOS asked
            }
        case .denied: denied = true
        }
    }
    private var wanted = false

    private func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }

    private func run() {
        let devices = discover()
        cameras = devices.map { Camera(id: $0.uniqueID, name: $0.localizedName) }
        // The Mac's own camera first: the "default" can be an iPhone that isn't ready.
        let builtIn = devices.first { $0.deviceType == .builtInWideAngleCamera }?.uniqueID
        if selected.isEmpty || !cameras.contains(where: { $0.id == selected }) { selected = builtIn ?? cameras.first?.id ?? "" }
        configure(selected)
    }

    /// Points the session at that camera (replacing the previous one) and starts it; watches that pictures really arrive.
    func configure(_ id: String) {
        selected = id
        generation += 1
        let mine = generation
        gotFrame = false; hasFrames = false; stalled = false
        queue.async {
            guard let cam = AVCaptureDevice(uniqueID: id) ?? self.discover().first, let input = try? AVCaptureDeviceInput(device: cam) else {
                DispatchQueue.main.async { self.stalled = true }
                return
            }
            self.session.beginConfiguration()
            for old in self.session.inputs { self.session.removeInput(old) }
            if self.session.canAddInput(input) { self.session.addInput(input) }
            if !self.session.outputs.contains(self.output), self.session.canAddOutput(self.output) {
                self.output.setSampleBufferDelegate(self, queue: self.queue)
                self.session.addOutput(self.output)
            }
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == mine, !self.hasFrames else { return }
            self.stalled = true
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !gotFrame else { return }
        gotFrame = true
        DispatchQueue.main.async { self.hasFrames = true; self.stalled = false }
    }

    func stop() {
        generation += 1
        wanted = false
        hasFrames = false; stalled = false
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }
}

/// The camera's picture, live. `flip` turns it into a mirror (left and right swapped, as in a real one).
private struct MirrorPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let flip: Bool

    final class PreviewView: NSView {
        let preview: AVCaptureVideoPreviewLayer
        init(session: AVCaptureSession) {
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            wantsLayer = true
            preview.videoGravity = .resizeAspectFill
            layer?.addSublayer(preview)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ v: PreviewView, context: Context) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        v.preview.setAffineTransform(CGAffineTransform(scaleX: flip ? -1 : 1, y: 1))
        CATransaction.commit()
    }
}

/// External monitors' own controls over DDC/CI (brightness, contrast, volume, input), written straight to the display's I2C
/// bus. Apple silicon only; the monitor has to support DDC/CI. Nothing here can read a value back, so sliders start at 50.
private final class DDCDisplays: ObservableObject {
    struct Monitor: Identifiable { var id: Int; var name: String; var service: UnsafeMutableRawPointer }
    @Published var monitors: [Monitor] = []
    @Published var values: [String: Double] = [:]
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private var create: CreateFn?, write: WriteFn?

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return }
        create = dlsym(h, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
        write = dlsym(h, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: WriteFn.self) }
    }

    var available: Bool { create != nil && write != nil }
    static var externalNames: [String] { NSScreen.screens.filter { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) == 0 } ?? false }.map(\.localizedName) }

    func refresh() {
        guard available else { return }
        var found: [Monitor] = []
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        let names = Self.externalNames
        var svc = IOIteratorNext(it)
        while svc != 0 {
            let loc = IORegistryEntryCreateCFProperty(svc, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if loc == "External", let ref = create?(kCFAllocatorDefault, svc) {
                let i = found.count
                found.append(Monitor(id: i, name: i < names.count ? names[i] : "Monitor \(i + 1)", service: Unmanaged.passRetained(ref.takeRetainedValue()).toOpaque()))
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(it)
        }
        monitors = found
    }

    /// VCP codes: 0x10 brightness, 0x12 contrast, 0x62 volume, 0x60 input source.
    func set(_ m: Monitor, code: UInt8, value: Int) {
        guard let write else { return }
        var d: [UInt8] = [0x84, 0x03, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF), 0]
        d[5] = 0x6E ^ 0x51 ^ d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[4]
        let ref = Unmanaged<CFTypeRef>.fromOpaque(m.service).takeUnretainedValue()
        DispatchQueue.global().async { for _ in 0..<2 { _ = write(ref, 0x37, 0x51, &d, 6); usleep(15_000) } }
    }
}

extension IslandView {
    // MARK: music

    fileprivate var musicTab: some View {
        let mu = model.music
        return HStack(alignment: .top, spacing: 18) {
            Group {
                if let a = mu.artwork { Image(nsImage: a).resizable().aspectRatio(contentMode: .fill) }
                else { ZStack { Color.white.opacity(0.08); Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.white.opacity(0.35)) } }
            }
            .frame(width: 128, height: 128).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                if let t = mu.track {
                    Text(t.title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                    Text(t.artist + (t.album.isEmpty ? "" : " — " + t.album)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        VStack(spacing: 2) {
                            Scrubber(value: mu.now, total: max(1, t.duration)) { mu.seek($0) }
                            HStack { Text(Self.clock(mu.now)); Spacer(); Text("-" + Self.clock(max(0, t.duration - mu.now))) }
                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    HStack(spacing: 20) {
                        Button { mu.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(mu.shuffle ? Island.accent : .white.opacity(0.5)) }
                        Button { mu.previous() } label: { Image(systemName: "backward.fill") }
                        Button { mu.playPause() } label: { Image(systemName: mu.playing ? "pause.fill" : "play.fill").font(.system(size: 20)) }
                        Button { mu.next() } label: { Image(systemName: "forward.fill") }
                        Spacer(minLength: 0)
                        Button { mu.setLyrics(!mu.lyricsOn) } label: { Image(systemName: "quote.bubble").foregroundStyle(mu.lyricsOn ? Island.accent : .white.opacity(0.5)) }
                            .help(mu.lyricsOn ? L("Hide lyrics") : L("Show lyrics (looks up the title and artist on lrclib.net)"))
                    }
                    .buttonStyle(.plain).font(.system(size: 14))
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(mu.currentLine ?? (mu.lyricsOn ? (mu.lyrics.isEmpty ? L("No synced lyrics found") : "♪") : ""))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Island.accent).lineLimit(1)
                    }
                } else {
                    Text(mu.denied ? L("Allow Cocaine to control Music and Spotify in System Settings → Privacy & Security → Automation") : L("Play something in Music or Spotify"))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    fileprivate static func clock(_ s: Double) -> String { let i = Int(s); return String(format: "%d:%02d", i / 60, i % 60) }

    // MARK: mirror

    fileprivate var mirrorTab: some View {
        let mr = model.mirror
        return HStack(alignment: .top, spacing: 18) {
            ZStack {
                Color.white.opacity(0.08)
                if mr.denied {
                    VStack(spacing: 8) {
                        Text(L("Allow the camera in System Settings → Privacy & Security → Camera")).font(.system(size: 11)).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.6))
                        Button { Permissions.request(.camera) { mr.start() } } label: {
                            Text(L("Allow")).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(Island.accent)).foregroundStyle(.black)
                        }.buttonStyle(.plain)
                    }.padding(12)
                } else {
                    MirrorPreview(session: mr.session, flip: mr.flip)
                    if !mr.hasFrames {
                        Text(mr.stalled ? L("No picture from the camera. Is another app using it?") : L("Starting the camera…"))
                            .font(.system(size: 11)).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.55)).padding(12)
                    }
                }
            }
            .frame(width: 290, height: 146).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill").font(.system(size: 12)).foregroundStyle(mr.flip ? Island.accent : .white.opacity(0.5)).frame(width: 18)
                    Text(L("Mirror")).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 4)
                    CocaineSwitch(on: mr.flip) { mr.flip.toggle() }.accessibilityLabel(L("Mirror"))
                }
                .help(L("On: like a mirror (left and right swapped). Off: as others see you."))
                if mr.cameras.count > 1 {
                    Menu {
                        ForEach(mr.cameras) { c in Button { mr.configure(c.id) } label: { if c.id == mr.selected { Label(c.name, systemImage: "checkmark") } else { Text(c.name) } } }
                    } label: { Label(mr.cameras.first { $0.id == mr.selected }?.name ?? L("Camera"), systemImage: "camera").font(.system(size: 11)).lineLimit(1) }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Text(L("The camera runs only while this page is open.")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { mr.start() }
        .onDisappear { mr.stop() }
    }

    // MARK: external monitors

    fileprivate var displayTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.ddc.monitors.isEmpty {
                Text(L("No external monitor found, or it doesn't support DDC/CI")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            ForEach(model.ddc.monitors.prefix(2)) { mon in
                HStack(spacing: 14) {
                    Text(mon.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(width: 130, alignment: .leading)
                    ForEach([("sun.max.fill", UInt8(0x10), "b"), ("circle.lefthalf.filled", UInt8(0x12), "c"), ("speaker.wave.2.fill", UInt8(0x62), "v")], id: \.1) { k in
                        HStack(spacing: 6) {
                            Image(systemName: k.0).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).frame(width: 14)
                            Slider(value: Binding(get: { model.ddc.values["\(mon.id)\(k.2)"] ?? 50 },
                                                  set: { model.ddc.values["\(mon.id)\(k.2)"] = $0; model.ddc.set(mon, code: k.1, value: Int($0)) }), in: 0...100)
                                .controlSize(.mini).frame(width: 80)
                        }
                    }
                    Menu {
                        ForEach([("HDMI 1", 0x11), ("HDMI 2", 0x12), ("DisplayPort 1", 0x0F), ("DisplayPort 2", 0x10), ("USB-C", 0x1B)], id: \.1) { i in
                            Button(i.0) { model.ddc.set(mon, code: 0x60, value: i.1) }
                        }
                    } label: { Label(L("Input"), systemImage: "cable.connector").font(.system(size: 11)) }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            Text(L("Controls the monitor itself, over DDC/CI. Values start at 50 because monitors can't be read back.")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            Spacer(minLength: 0)
        }
        .onAppear { model.ddc.refresh() }
    }
}

/// A thin scrubber: drag or click to seek.
private struct Scrubber: View {
    let value: Double, total: Double
    let seek: (Double) -> Void
    var body: some View {
        GeometryReader { r in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15)).frame(height: 4)
                Capsule().fill(Color.white.opacity(0.85)).frame(width: r.size.width * min(1, value / total), height: 4)
                Circle().fill(.white).frame(width: 9, height: 9).offset(x: max(0, r.size.width * min(1, value / total) - 4.5))
            }
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { g in seek(min(total, max(0, g.location.x / r.size.width * total))) })
        }
        .frame(height: 12)
    }
}

/// Four bars that dance while music plays (a little, not a spectrum).
private struct Visualizer: View {
    let playing: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(Island.accent).frame(width: 2.5, height: playing ? 5 + 9 * abs(sin(t * (3 + Double(i) * 1.3) + Double(i))) : 4)
                }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Stay active: chat apps (Teams, Slack, Zoom…) keep showing you as available

/// Teams and similar apps mark you "Away" from the system's idle time. While you are idle this sends an invisible mouse event
/// (no movement) now and then, which resets that clock. Sending input needs the Accessibility permission.
private enum Presence {
    static let defaultApps = ["Microsoft Teams", "Teams", "Slack", "zoom.us", "Webex", "Skype"]
    static var hasAccess: Bool { CGPreflightPostEventAccess() }

    static func requestAccess() {
        if !CGRequestPostEventAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    /// An event as if the mouse "moved" by zero: the cursor stays put, the idle time restarts.
    @discardableResult
    static func nudge() -> Bool {
        guard hasAccess else { return false }
        let here = CGEvent(source: nil)?.location ?? .zero
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: here, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventDeltaX, value: 0)
        e?.setIntegerValueField(.mouseEventDeltaY, value: 0)
        e?.post(tap: .cghidEventTap)
        return e != nil
    }

    /// Is any of the named apps running? (Matched on a part of the name, ignoring case.)
    static func anyRunning(_ names: [String]) -> Bool {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        return names.contains { n in running.contains { $0.lowercased().contains(n.lowercased()) } }
    }
}

// MARK: - The macOS volume and brightness keys, shown in the island instead of macOS's own HUD

/// Intercepts the volume, mute and brightness keys (needs Accessibility), applies them itself and shows the island's bar.
private final class MediaKeys {
    var onStep: ((Int, Bool) -> Bool)?             // key code, fine step (⌥⇧): return true when it was handled
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// NX_KEYTYPE_*: 0 volume up, 1 volume down, 2 brightness up, 3 brightness down, 7 mute.
    static func decode(data1: Int) -> (key: Int, down: Bool)? {
        let key = (data1 & 0xFFFF0000) >> 16, flags = data1 & 0x0000FFFF
        guard [0, 1, 2, 3, 7].contains(key) else { return nil }
        return (key, ((flags & 0xFF00) >> 8) == 0xA)
    }

    var running: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil, AXIsProcessTrusted() else { return tap != nil }
        let mask: CGEventMask = 1 << 14                                    // NX_SYSDEFINED
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MediaKeys>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }; return Unmanaged.passUnretained(event) }
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8, let k = MediaKeys.decode(data1: ns.data1) else { return Unmanaged.passUnretained(event) }
            if !k.down { return me.onStep == nil ? Unmanaged.passUnretained(event) : nil }   // swallow the release of a key we handled
            let fine = ns.modifierFlags.contains([.option, .shift])
            return (me.onStep?(k.key, fine) ?? false) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }

    // MARK: acting on the keys

    private static func outputDevice() -> AudioDeviceID? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var d = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &d) == noErr && d != 0 ? d : nil
    }

    /// Volume up/down/mute. Returns the new level and whether it's muted, or nil when this output has no volume control.
    static func changeVolume(key: Int, fine: Bool) -> (level: Float, muted: Bool)? {
        guard let dev = outputDevice() else { return nil }
        var va = AudioObjectPropertyAddress(mSelector: 0x766D_7663, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var ma = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &va, 0, nil, &size, &v) == noErr else { return nil }
        var mute: UInt32 = 0, msize = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectGetPropertyData(dev, &ma, 0, nil, &msize, &mute) == noErr
        let step: Float32 = fine ? 1.0 / 64 : 1.0 / 16
        if key == 7 {
            guard hasMute else { return nil }
            mute = mute == 0 ? 1 : 0
            AudioObjectSetPropertyData(dev, &ma, 0, nil, msize, &mute)
            return (v, mute != 0)
        }
        v = min(1, max(0, v + (key == 0 ? step : -step)))
        AudioObjectSetPropertyData(dev, &va, 0, nil, size, &v)
        if hasMute && mute != 0 && key == 0 { mute = 0; AudioObjectSetPropertyData(dev, &ma, 0, nil, msize, &mute) }
        return (v, mute != 0 && key != 0)
    }
}

// MARK: Island, part 4: a shelf for files, and the charging activity

/// Files dropped on the island, held (as references, never copied) until you drag them out, AirDrop them or clear the shelf.
private final class ShelfStore: ObservableObject {
    @Published var urls: [URL] = []
    func add(_ u: URL) { if !urls.contains(u) { urls.append(u) } }
    func remove(_ u: URL) { urls.removeAll { $0 == u } }
    func clear() { urls = [] }
}

extension IslandView {
    fileprivate var shelfTab: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Shelf")).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                if model.shelf.urls.isEmpty {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])).foregroundStyle(.white.opacity(0.25))
                        .overlay(Text(L("Drag files onto the notch, then drop them here")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center).padding(.horizontal, 12))
                        .frame(height: 96)
                } else {
                    ScrollView(.vertical, showsIndicators: false) { LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 10), count: 5), alignment: .leading, spacing: 8) {
                        ForEach(model.shelf.urls, id: \.self) { u in
                            VStack(spacing: 3) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 40, height: 40)
                                Text(u.lastPathComponent).font(.system(size: 10)).lineLimit(1).truncationMode(.middle).foregroundStyle(.white.opacity(0.75))
                            }
                            .frame(width: 84)
                            .overlay(alignment: .topTrailing) {
                                Button { model.shelf.remove(u) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)) }
                                    .buttonStyle(.plain).accessibilityLabel(L("Remove"))
                            }
                            .onDrag { NSItemProvider(object: u as NSURL) }
                            .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                        }
                    } }.frame(maxHeight: 118)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                Button { model.airDrop(model.shelf.urls) } label: {
                    Label("AirDrop", systemImage: "airplayaudio").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Island.accent)).foregroundStyle(.black)
                }
                .buttonStyle(.plain).disabled(model.shelf.urls.isEmpty).opacity(model.shelf.urls.isEmpty ? 0.4 : 1)
                Button { model.shelf.clear() } label: {
                    Text(L("Clear")).font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 6).background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain).disabled(model.shelf.urls.isEmpty).opacity(model.shelf.urls.isEmpty ? 0.4 : 1)
                Spacer(minLength: 0)
            }
            .frame(width: 110)
        }
    }
}

// MARK: Island, part 5: media launchers

/// A music or video service: opened as its app when it is installed, else as its website in the default browser.
private struct MediaApp: Identifiable {
    var id: String
    var name: String
    var symbol: String
    var color: Color
    var bundles: [String]
    var apps: [String]                 // file names to look for in the Applications folders
    var url: String

    static let all: [MediaApp] = [
        MediaApp(id: "music", name: "Apple Music", symbol: "music.note", color: Color(red: 0.98, green: 0.25, blue: 0.35), bundles: ["com.apple.Music"], apps: ["Music.app"], url: "https://music.apple.com"),
        MediaApp(id: "spotify", name: "Spotify", symbol: "waveform", color: Color(red: 0.12, green: 0.73, blue: 0.33), bundles: ["com.spotify.client"], apps: ["Spotify.app"], url: "https://open.spotify.com"),
        MediaApp(id: "ytmusic", name: "YouTube Music", symbol: "music.quarternote.3", color: Color(red: 0.95, green: 0.2, blue: 0.2), bundles: [], apps: ["YouTube Music.app"], url: "https://music.youtube.com"),
        MediaApp(id: "netflix", name: "Netflix", symbol: "play.rectangle.fill", color: Color(red: 0.88, green: 0.08, blue: 0.14), bundles: ["com.netflix.Netflix"], apps: ["Netflix.app"], url: "https://www.netflix.com"),
        MediaApp(id: "prime", name: "Prime Video", symbol: "play.tv.fill", color: Color(red: 0.0, green: 0.6, blue: 0.9), bundles: [], apps: ["Prime Video.app", "Amazon Prime Video.app"], url: "https://www.primevideo.com"),
        MediaApp(id: "youtube", name: "YouTube", symbol: "play.rectangle.on.rectangle.fill", color: Color(red: 1.0, green: 0.1, blue: 0.1), bundles: [], apps: ["YouTube.app"], url: "https://www.youtube.com"),
        MediaApp(id: "disney", name: "Disney+", symbol: "sparkles.tv.fill", color: Color(red: 0.2, green: 0.35, blue: 0.85), bundles: [], apps: ["Disney+.app", "Disney Plus.app"], url: "https://www.disneyplus.com"),
        MediaApp(id: "appletv", name: "Apple TV", symbol: "appletv.fill", color: Color(red: 0.7, green: 0.7, blue: 0.75), bundles: ["com.apple.TV"], apps: ["TV.app"], url: "https://tv.apple.com"),
        MediaApp(id: "twitch", name: "Twitch", symbol: "dot.radiowaves.left.and.right", color: Color(red: 0.57, green: 0.27, blue: 1.0), bundles: [], apps: ["Twitch.app"], url: "https://www.twitch.tv"),
        MediaApp(id: "dazn", name: "DAZN", symbol: "sportscourt.fill", color: Color(red: 0.9, green: 0.9, blue: 0.2), bundles: [], apps: ["DAZN.app"], url: "https://www.dazn.com"),
    ]

    /// Where the app is, if it's installed.
    var installedURL: URL? {
        for b in bundles { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { return u } }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in ["/Applications", home + "/Applications", "/System/Applications"] {
            for a in apps where FileManager.default.fileExists(atPath: dir + "/" + a) { return URL(fileURLWithPath: dir + "/" + a) }
        }
        return nil
    }

    func open() {
        if let app = installedURL { NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) }
        else if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

extension IslandView {
    fileprivate var mediaTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 8), count: 5), alignment: .leading, spacing: 8) {
                ForEach(MediaApp.all) { app in
                    let url = app.installedURL
                    Button { Haptic.tap(.generic); app.open() } label: {
                        VStack(spacing: 5) {
                            ZStack(alignment: .bottomTrailing) {
                                if let url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 38, height: 38) }
                                else {
                                    RoundedRectangle(cornerRadius: 9).fill(app.color.opacity(0.9)).frame(width: 38, height: 38)
                                        .overlay(Image(systemName: app.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))
                                    Image(systemName: "globe").font(.system(size: 9, weight: .bold)).padding(2).background(Circle().fill(.black)).foregroundStyle(.white).offset(x: 3, y: 3)
                                }
                            }
                            Text(app.name).font(.system(size: 11)).lineLimit(1).foregroundStyle(.white.opacity(0.85))
                        }
                        .frame(width: 104, height: 66)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(url == nil ? String(format: L("Opens %@ on the web"), app.name) : String(format: L("Opens %@"), app.name))
                }
            }
            Text(L("Opens the app, or the website if it isn't installed.")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
        }
    }
}

// MARK: Island model and controller

private final class IslandModel: ObservableObject {
    @Published var open = false
    @Published var tab = "home"
    @Published var geometry = NotchGeometry.current() ?? NotchGeometry(frame: .zero, notchWidth: 150, height: 24, centerX: 0, hasNotch: false)
    /// The render tool only: draw this moment of the open/close morph (0…1) instead of following `open`.
    var renderProgress: CGFloat?
    weak var pm: PanelModel?
    let focus = FocusTimer()
    let batteries = BatteryWatch()
    let mic = MicWatch()
    let usage = UsageWatch()
    let files = FileShelf()
    let clipboard = ClipboardHistory.shared
    let shelf = ShelfStore()
    var airDrop: ([URL]) -> Void = { _ in }
    var dropTargeted: (Bool) -> Void = { _ in }
    let calendar = CalendarWatch()
    let music = MusicWatch()
    let mirror = MirrorController()
    let ddc = DDCDisplays()
    let hud = HUDWatch()
    @Published var flash: (icon: String, text: String, level: Double?)?
    private var forwards: [AnyCancellable] = []
    private var flashWork: DispatchWorkItem?

    init() {
        forwards = [files.objectWillChange, clipboard.objectWillChange, shelf.objectWillChange, calendar.objectWillChange, focus.objectWillChange, mic.objectWillChange,
                    music.objectWillChange, mirror.objectWillChange, ddc.objectWillChange]
            .map { $0.sink { [weak self] _ in self?.objectWillChange.send() } }
    }

    /// A short message in the closed island: "Downloaded", "Copied"…
    func flashNotice(_ icon: String, _ text: String, level: Double? = nil) {
        flash = (icon, text, level)
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flash = nil }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (level == nil ? 3.2 : 1.6), execute: w)
    }
    static let maxWing: CGFloat = 130
    var relayoutNow: () -> Void = {}
    /// Is something worth a mark right of the notch? (The bag on the left is always there.)
    var rightActive: Bool {
        flash != nil || focus.active || mic.active || music.playing || (pm?.on ?? false) || (pm?.stayActive ?? false) || (pm?.presenceActive ?? false)
            || (pm?.board.contains { $0.state == "waiting" || $0.state == "error" || $0.state == "working" } ?? false)
    }
    var leftW: CGFloat { flash != nil ? 130 : Island.wing }
    var rightW: CGFloat { rightActive ? (flash != nil ? 130 : Island.wing) : 0 }
    var hover: (Bool) -> Void = { _ in }
    var toggleOpen: () -> Void = {}
    var showSettings: () -> Void = {}
    /// The clipboard page's search field needs the keyboard: the panel may take it while that page is shown.
    var setKeyable: (Bool) -> Void = { _ in }
}

private final class IslandPanel: NSPanel {
    /// Only while the clipboard page is shown, for its search field (the panel never activates the app).
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }     // exactly where we say, even above the screen
}

private final class IslandController {
    let model = IslandModel()
    private var panel: IslandPanel?
    private var host: NSHostingView<IslandView>?
    private var openTimer: Timer?, closeTimer: Timer?, watchTimer: Timer?
    private var panelModel: PanelModel?
    private var enabled = false
    private var ticks = 0

    func start(panelModel: PanelModel, enabled: Bool, showSettings: @escaping () -> Void) {
        self.panelModel = panelModel
        model.pm = panelModel
        model.showSettings = showSettings
        model.hover = { [weak self] inside in self?.hover(inside) }
        model.toggleOpen = { [weak self] in self?.setOpen(!(self?.model.open ?? false)) }
        model.relayoutNow = { [weak self] in self?.relayout() }
        model.setKeyable = { [weak self] on in
            guard let p = self?.panel else { return }
            p.keyable = on
            if !on, p.isKeyWindow { p.orderOut(nil); p.orderFrontRegardless() }     // gives the keyboard back to the app in front
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.relayout() }
        model.mic.start()
        startPointerMonitors()
        model.files.onNew = { [weak model] icon, text in model?.flashNotice(icon, text) }
        model.airDrop = { urls in
            guard !urls.isEmpty else { return }
            NSApp.activate()
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        }
        model.dropTargeted = { [weak self] t in
            guard t, let self else { return }
            self.model.tab = "shelf"
            self.setOpen(true)
        }
        model.hud.onChange = { [weak model] icon, text, level in DispatchQueue.main.async { model?.flashNotice(icon, text, level: level) } }
        setEnabled(enabled)
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        guard on else { panel?.orderOut(nil); watchTimer?.invalidate(); watchTimer = nil; model.files.stop(); model.clipboard.stop(); model.music.stop(); model.hud.stop(); return }
        model.files.start(); model.clipboard.start(); model.music.start()
        syncHUD(panelModel?.replaceHUD ?? false)
        if panel == nil, let pm = panelModel {
            let p = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.hidesOnDeactivate = false; p.isMovable = false
            p.appearance = NSAppearance(named: .darkAqua)
            let h = NSHostingView(rootView: IslandView(model: model, m: pm, focus: model.focus, batteries: model.batteries, mic: model.mic, usage: model.usage))
            h.sizingOptions = []
            p.contentView = h
            panel = p; host = h
        }
        missed = 0
        relayout()
        panel?.orderFrontRegardless()
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.watch() }
    }

    /// Size and place the window: just the closed island, or the open one (with a little room for the spring's overshoot).
    /// The SwiftUI canvas inside is fixed and centred on the notch, so these instant resizes never move what is drawn.
    func relayout() {
        guard enabled, let g = NotchGeometry.current(), let panel else { return }
        if g != model.geometry { model.geometry = g }
        panel.ignoresMouseEvents = !model.open
        let f = Self.windowFrame(g, open: model.open)
        if panel.frame != f { panel.setFrame(f, display: true) }
    }

    /// The window: closed, wide enough for the widest wings and never changing (the shape animates inside it); it ignores the
    /// mouse then, so it never blocks the menu bar below it. Open, the open island plus room for the spring's overshoot.
    /// Its top is `overscan` above the screen's edge, like the canvas's (see IslandView: the canvas hangs from the window's top).
    static func windowFrame(_ g: NotchGeometry, open: Bool) -> NSRect {
        let full = open ? CGSize(width: Island.openSize.width + 2 * Island.slack, height: Island.openSize.height + Island.slack)
                        : CGSize(width: g.notchWidth + 2 * IslandModel.maxWing + 20, height: g.height)
        return NSRect(x: g.centerX - full.width / 2, y: g.frame.maxY - full.height, width: full.width, height: full.height + Island.overscan)
    }

    /// The open island itself (the window has some empty room around it).
    private func openRect(_ g: NotchGeometry) -> NSRect {
        NSRect(x: g.centerX - Island.openSize.width / 2, y: g.frame.maxY - Island.openSize.height, width: Island.openSize.width, height: Island.openSize.height + Island.overscan)
    }

    func setOpen(_ open: Bool) {
        openTimer?.invalidate(); closeTimer?.invalidate()
        guard model.open != open else { return }
        if open {
            Haptic.tap(.alignment)
            model.open = true
            relayout()
        } else {
            model.open = false
            panel?.ignoresMouseEvents = true
            closingUntil = Date().addingTimeInterval(0.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in     // after the morph (and not under a later one)
                guard let self, !self.model.open, Date() >= self.closingUntil.addingTimeInterval(-0.02) else { return }
                self.relayout()
            }
        }
    }

    private var hovering = false
    private var suspended = false
    private var closingUntil = Date.distantPast
    private var pointerMonitors: [Any] = []

    /// Watches the pointer itself (in every app, and over the island), so it opens as soon as you touch the notch.
    private func startPointerMonitors() {
        guard pointerMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in self?.pointerMoved(e) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { pointerMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in handler(e); return e }) { pointerMonitors.append(l) }
    }

    /// The settings panel hangs from the same notch: while it is open the island is out of the way (not opening behind it).
    /// The island's own volume/brightness bars only run while *Replace system HUD* is on.
    func syncHUD(_ on: Bool) { if enabled && on { model.hud.start() } else { model.hud.stop() } }

    func setSuspended(_ s: Bool) {
        suspended = s
        if s {
            setOpen(false); hovering = false
            panel?.orderOut(nil)
        } else if enabled {
            panel?.orderFrontRegardless()
        }
    }

    private func pointerMoved(_ e: NSEvent) {
        guard enabled, !suspended, let panel, panel.isVisible else { return }
        let p = NSEvent.mouseLocation, g = model.geometry
        // Open: the open island. Closed: just what is drawn (the notch and its wings), and the very top edge of the screen.
        let f: NSRect = model.open ? openRect(g)
            : NSRect(x: g.centerX - g.notchWidth / 2 - model.leftW, y: g.frame.maxY - g.height - 2, width: g.notchWidth + model.leftW + model.rightW, height: g.height + 14)
        let margin: CGFloat = model.open ? 8 : 3
        let inside = p.x >= f.minX - margin && p.x <= f.maxX + margin && p.y >= f.minY - (model.open ? margin : 0) && p.y <= f.maxY + 2
        if inside != hovering {
            hovering = inside
            // Dragging files over the notch: open straight on the shelf.
            if inside, e.type == .leftMouseDragged, NSPasteboard(name: .drag).types?.contains(.fileURL) == true { model.tab = "shelf" }
            hover(inside)
        }
    }

    private func hover(_ inside: Bool) {
        openTimer?.invalidate(); closeTimer?.invalidate()
        setOpen(inside)                                    // no delay either way: as fast out as in
    }

    /// Once a second: hide during full-screen video and games, follow the screen, keep the closed width in step.
    /// The failsafe too: whatever happened, an island that should be on screen is put back (closed, in place, in front); if it
    /// can't be (no screen, or the window server won't show it), `onShowing(false)` brings the menu-bar icon back.
    private func watch() {
        guard enabled, let panel else { return }
        ticks += 1
        if suspended && !settingsOpen() { setSuspended(false) }         // never left hidden behind a settings panel that is gone
        if ticks % 4 == 0 {
            let g = NotchGeometry.current()
            let covered = g.map { Self.fullScreenCovers($0.frame) } ?? false
            if covered || g == nil {
                if panel.isVisible { panel.orderOut(nil) }
                missed = 0
            } else if !suspended {
                if !panel.isVisible || panel.alphaValue < 1 || !Self.onScreen(panel.windowNumber) {
                    missed += 1
                    if missed > 1 {                                       // a moment to settle first (just ordered in, a morph)
                        log.notice("island was not on screen: shown again")
                        if !model.open { closingUntil = .distantPast }
                        panel.alphaValue = 1
                        relayout()
                        panel.orderFrontRegardless()
                    }
                } else { missed = 0 }
            }
            setShowing(g != nil && missed < 6)                            // ~7 s of failed repairs: the icon comes back
        }
        if !model.open && Date() >= closingUntil { relayout() }        // never shrink the window under a closing morph
    }
    private var missed = 0
    private(set) var showing = true
    var onShowing: (Bool) -> Void = { _ in }
    var settingsOpen: () -> Bool = { false }
    private func setShowing(_ s: Bool) {
        guard s != showing else { return }
        showing = s
        onShowing(s)
    }

    /// Is the window really on screen, as the window server says (not just ordered in, as AppKit says)?
    private static func onScreen(_ number: Int) -> Bool {
        guard number > 0, let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]], let w = info.first else { return false }
        return (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    private static func fullScreenCovers(_ frame: CGRect) -> Bool {
        let list = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 && (w[kCGWindowOwnerName as String] as? String) != "Cocaine" {
            guard let b = w[kCGWindowBounds as String] as? [String: Any], let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            if r.width >= frame.width - 1 && r.height >= frame.height - 1 { return true }
        }
        return false
    }
}

// MARK: Island views

private struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var m: PanelModel
    @ObservedObject var focus: FocusTimer
    @ObservedObject var batteries: BatteryWatch
    @ObservedObject var mic: MicWatch
    @ObservedObject var usage: UsageWatch

    private var g: NotchGeometry { model.geometry }
    fileprivate var files: FileShelf { model.files }
    fileprivate var clipboard: ClipboardHistory { model.clipboard }
    fileprivate var calendar: CalendarWatch { model.calendar }
    private var waiting: AgentEntry? { m.board.first { $0.state == "waiting" || $0.state == "error" } }
    private var working: Bool { m.board.contains { $0.state == "working" } }

    /// Closed and open are one view: a single progress (0 closed … 1 open, sprung) drives the outline, its clip and every icon,
    /// so the bag, the live item and the tabs travel and change into each other instead of fading between two layouts.
    var body: some View {
        let open = model.open
        let pose = IslandPose(p: model.renderProgress ?? (open ? 1 : 0), leftW: model.leftW, rightW: model.rightW)
        let l = IslandLayout(notch: g.notchWidth, notchH: g.height)
        ZStack(alignment: .topLeading) {
            IslandOutline(pose: pose, layout: l).fill(Color.black)                  // reaches above the screen's edge
            ZStack(alignment: .topLeading) {
                strip(pose, l)
                VStack(spacing: 0) {
                    Color.clear.frame(height: l.top + g.height)
                    if open {
                        page.modifier(PageReveal(pose: IslandPose(p: model.renderProgress ?? 1, leftW: pose.leftW, rightW: pose.rightW), layout: l))
                            .transition(.modifier(active: PageReveal(pose: IslandPose(p: 0, leftW: model.leftW, rightW: model.rightW), layout: l),
                                                  identity: PageReveal(pose: IslandPose(p: 1, leftW: model.leftW, rightW: model.rightW), layout: l)))
                    }
                }
                .frame(width: l.size.width, height: l.size.height, alignment: .top)
            }
            .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
            .mask(IslandOutline(pose: pose, layout: l))                            // nothing ever shows outside the black
        }
        .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: Binding(get: { false }, set: { model.dropTargeted($0) })) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { DispatchQueue.main.async { Haptic.tap(.generic); model.shelf.add(u) } }
                }
            }
            return true
        }
        // Exactly the window's size, the canvas hanging from its top and centred on the notch whatever that size is. (Without the
        // zero minimums this frame takes the canvas's size, 656×228, and the hosting view centres that in the 38 pt closed window:
        // the closed island ended up 95 pt above the window, i.e. invisible. --island-selfcheck guards it.)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .animation(open ? Island.openSpring : Island.closeSpring, value: open)
        .animation(.spring(response: 0.3, dampingFraction: 0.84), value: model.leftW)
        .animation(.spring(response: 0.3, dampingFraction: 0.84), value: model.rightW)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    // MARK: the strip: the closed island's wings, and the open island's tabs

    /// Every item of the top strip, closed or open. Left: the bag (it becomes the Home tab), the tabs, the microphone. Right: what is
    /// live (it melts into the gear), the tabs and the gear. Tabs wait behind the notch while closed and slide out of it on opening.
    @ViewBuilder private func strip(_ s: IslandPose, _ l: IslandLayout) -> some View {
        let tabs = Island.tabs(external: Island.external), half = (tabs.count + 1) / 2, cell = cellWidth
        let left0 = l.cx - IslandLayout.openBody / 2 + 16, right1 = l.cx + IslandLayout.openBody / 2 - 16
        let leftTabs = Array(tabs.prefix(half).enumerated()), rightTabs = Array(tabs.dropFirst(half).enumerated()), nRight = tabs.count - half
        ForEach(leftTabs, id: \.element.id) { i, t in
            Group { if i == 0 { homeButton(t, s) } else { tabButton(t) } }
                .modifier(StripSlide(pose: s, layout: l, from: i == 0 ? .leftWing : .behindLeft, to: left0 + cell * (CGFloat(i) + 0.5),
                                     width: cell, order: i, fade: i == 0 ? .none : .reveal))
        }
        if mic.active {
            Image(systemName: "mic.fill").font(.system(size: 12)).foregroundStyle(.orange).frame(width: 24, height: g.height).help(L("Microphone in use"))
                .modifier(StripSlide(pose: s, layout: l, from: .behindLeft, to: left0 + cell * CGFloat(half) + 12, width: 24, order: half, fade: .reveal))
                .transition(.opacity)
        }
        rightWing.frame(width: max(1, model.rightW), height: g.height).allowsHitTesting(false).accessibilityHidden(model.open)
            .modifier(StripSlide(pose: s, layout: l, from: .rightWing, to: right1 - cell / 2, width: max(1, model.rightW), order: 0, fade: .melt))
        ForEach(rightTabs, id: \.element.id) { j, t in
            tabButton(t).modifier(StripSlide(pose: s, layout: l, from: .behindRight, to: right1 - cell * (CGFloat(nRight - j) + 0.5),
                                             width: cell, order: nRight - j, fade: .reveal))
        }
        Button { model.showSettings() } label: {
            Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                .frame(width: cell, height: g.height).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(L("Settings")).accessibilityLabel(L("Settings"))
        .allowsHitTesting(model.open).accessibilityHidden(!model.open)
        .modifier(StripSlide(pose: s, layout: l, from: .gear, to: right1 - cell / 2, width: cell, order: 0, fade: .gear))
    }

    /// The Home tab is the bag itself: closed it sits left of the notch (or a flash icon does), open it is the first tab.
    private func homeButton(_ t: (id: String, icon: String, title: String), _ s: IslandPose) -> some View {
        let selected = model.tab == t.id
        return Button { Haptic.tap(.alignment); model.tab = t.id } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.16 : 0)).frame(width: 30, height: 26)
                    .modifier(CellMorph(pose: s, kind: .highlight))
                Image(nsImage: Self.bag(level: m.bagLevel, pouring: m.bagPouring, pink: m.bagPink)).frame(width: 20, height: 20)
                    .modifier(CellMorph(pose: s, kind: .bag(dim: selected ? 1 : 0.6)))
                if let f = model.flash {
                    Image(systemName: f.icon).foregroundStyle(Island.accent).modifier(CellMorph(pose: s, kind: .flashIcon))
                }
            }
            .frame(width: cellWidth, height: g.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(t.title).accessibilityLabel(t.title)
        .allowsHitTesting(model.open).accessibilityHidden(!model.open)
    }

    /// The menu-bar bag, always in its light-on-dark colors (the island is black).
    private static func bag(level: CGFloat, pouring: Bool, pink: Bool) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            Baggie.draw(in: rect, level: level, pouring: pouring, palette: Baggie.palette(dark: true, pink: pink))
            return true
        }
    }

    /// Right of the notch: what is going on, by importance.
    @ViewBuilder private var rightWing: some View {
        if let f = model.flash {
            if let l = f.level {
                Capsule().fill(Color.white.opacity(0.2)).frame(width: 78, height: 5)
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 78 * min(1, max(0, l)), height: 5) }
            } else {
                Text(f.text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle).padding(.horizontal, 8)
            }
        }
        else if focus.running { Text(focus.text).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white) }
        else if waiting != nil { Image(systemName: "hand.raised.fill").foregroundStyle(warningColor) }
        else if mic.active { Image(systemName: "mic.fill").foregroundStyle(.orange) }
        else if working { ProgressView().controlSize(.mini).tint(.white) }
        else if model.music.playing { Visualizer(playing: true) }
        else if m.on { Text(m.onUntil.map { Self.remaining($0) } ?? "∞").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75)) }
        else if m.stayActive || m.presenceActive { Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Color(red: 1, green: 0.5, blue: 0.72)) }
    }

    private static func remaining(_ until: Date) -> String {
        let s = Int(until.timeIntervalSinceNow)
        guard s > 0 else { return "∞" }
        return s >= 3600 ? "\(s / 3600)h" : "\(max(1, s / 60))m"
    }

    // MARK: open

    /// The selected tab's page, below the strip. Only there while open: it is inserted once and unfolds (see PageReveal).
    private var page: some View {
        Group {
            switch model.tab {
            case "focus": focusTab
            case "calendar": calendarTab
            case "music": musicTab
            case "media": mediaTab
            case "mirror": mirrorTab
            case "display": displayTab
            case "files": filesTab
            case "shelf": shelfTab
            case "clipboard": clipboardTab
            case "status": statusTab
            default: homeTab
            }
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
        .frame(width: IslandLayout.openBody, height: Island.openSize.height - g.height, alignment: .top)
    }

    private var cellWidth: CGFloat { Island.tabs(external: Island.external).count >= 11 ? 28 : 31 }     // 11: room for the mic too

    private func tabButton(_ t: (id: String, icon: String, title: String)) -> some View {
        Button { Haptic.tap(.alignment); model.tab = t.id } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(model.tab == t.id ? 0.16 : 0)).frame(width: 30, height: 26)
                Image(systemName: t.icon).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.tab == t.id ? Color.white : Color.white.opacity(0.5))
            }
            .frame(width: cellWidth, height: g.height)            // the whole cell, the full height of the strip
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(t.title).accessibilityLabel(t.title)
        .allowsHitTesting(model.open).accessibilityHidden(!model.open)
    }

    // MARK: home: Cocaine and what the AIs are doing

    private var statusText: String {
        guard m.on else { return L("Your Mac sleeps as usual") }
        if let u = m.onUntil, u > Date() { return L("Your Mac stays awake") + " · " + String(format: L("until %@"), PanelView.timeString(u)) }
        return L("Your Mac stays awake")
    }

    private var homeTab: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cocaine").font(.system(size: 17, weight: .bold))
                        Text(statusText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    CocaineSwitch(on: m.on, powder: m.fillLevel) { m.toggleCocaine() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Stay on for")).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    EqualSegments(selection: $m.timerMinutes, values: Settings.timerChoices) { $0 == 0 ? "∞" : ($0 < 60 ? "\($0)m" : "\($0 / 60)h") }
                        .onScrollSteps(every: 24) { n in
                            let c = Settings.timerChoices
                            let i = c.firstIndex(of: m.timerMinutes) ?? c.firstIndex { $0 >= m.timerMinutes } ?? 0
                            m.timerMinutes = c[min(c.count - 1, max(0, i + n))]
                        }
                }
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 12)).foregroundStyle(m.presenceActive ? Island.accent : .white.opacity(0.5))
                    Text(L("Stay active")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    Spacer(minLength: 4)
                    CocaineSwitch($m.stayActive)
                }
                .help(L("While you're idle it sends an invisible mouse event so Teams and the like don't show you as away."))
            }
            .frame(width: 250)
            VStack(alignment: .leading, spacing: 8) {
                let shown = Array(m.board.filter { $0.isLive || Date().timeIntervalSince1970 - $0.since < 600 }.prefix(3))
                Text(L("Agents")).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                if shown.isEmpty {
                    Text(m.ai.available ? L("No AI at work") : L("No AI tool found")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                } else {
                    ForEach(shown) { e in
                        HStack(spacing: 9) {
                            Image(systemName: Self.icon(e.state)).font(.system(size: 12, weight: .medium)).foregroundStyle(Self.color(e.state)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(e.from).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text([Self.name(e.state), e.project].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func icon(_ s: String) -> String { ["working": "gearshape.fill", "waiting": "hand.raised.fill", "done": "checkmark.circle.fill", "error": "exclamationmark.triangle.fill"][s] ?? "circle" }
    private static func color(_ s: String) -> Color { s == "error" || s == "waiting" ? warningColor : s == "done" ? .green : Island.accent }
    private static func name(_ s: String) -> String { ["working": L("Working"), "waiting": L("Needs you"), "done": L("Done"), "error": L("Error")][s] ?? s }

    // MARK: focus

    private var focusTab: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach([(false, L("Focus")), (true, L("Break"))], id: \.0) { b in
                        Button { focus.setBreak(b.0) } label: {
                            Text(b.1).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(focus.isBreak == b.0 ? 0.18 : 0.06)))
                                .foregroundStyle(focus.isBreak == b.0 ? Color.white : Color.white.opacity(0.55))
                        }.buttonStyle(.plain)
                    }
                }
                Text(focus.text).font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                HStack(spacing: 8) {
                    Button { focus.running ? focus.pause() : focus.start() } label: {
                        Label(focus.running ? L("Pause") : L("Start"), systemImage: focus.running ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(Island.accent)).foregroundStyle(.black)
                    }.buttonStyle(.plain)
                    if focus.active {
                        Button { focus.reset() } label: {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .semibold)).padding(7)
                                .background(Circle().fill(Color.white.opacity(0.12)))
                        }.buttonStyle(.plain).help(L("Reset")).accessibilityLabel(L("Reset"))
                    }
                }
            }
            .frame(width: 250, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Minutes")).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                MinuteRuler(minutes: Binding(get: { focus.minutes }, set: { if !focus.active { focus.minutes = $0 } }))
                    .opacity(focus.active ? 0.4 : 1)
                Text(L("Drag the ruler to set the length. Cocaine keeps the Mac awake while a focus runs."))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: batteries

    private var batteryTab: some View {
        VStack(alignment: .leading, spacing: 9) {
            if batteries.items.isEmpty {
                Text(L("No devices")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            }
            let cols = [GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                ForEach(batteries.items.prefix(4)) { item in
                    HStack(spacing: 9) {
                        Image(systemName: item.icon).font(.system(size: 14)).foregroundStyle(.white.opacity(0.75)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                if item.charging { Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.green) }
                                Spacer(minLength: 0)
                                Text(item.parts.map { ($0.label.isEmpty ? "" : $0.label + " ") + "\($0.percent)%" }.joined(separator: "  "))
                                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                            }
                            Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
                                .overlay(alignment: .leading) {
                                    GeometryReader { r in Capsule().fill(Self.level(item.parts.map(\.percent).min() ?? 0)).frame(width: r.size.width * CGFloat(item.parts.map(\.percent).min() ?? 0) / 100) }
                                }
                        }
                    }
                }
            }
        }
        .onAppear { batteries.refresh() }
    }

    private static func level(_ p: Int) -> Color { p <= 15 ? .red : p <= 30 ? .orange : .green }

    // MARK: usage

    /// Batteries on the left, the AI tools' usage on the right.
    private var statusTab: some View {
        HStack(alignment: .top, spacing: 24) {
            batteryTab.frame(width: 250, alignment: .topLeading)
            usageTab.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var usageTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Codex").font(.system(size: 13, weight: .semibold))
                    if usage.codex.isEmpty {
                        Text(usage.loaded ? L("Nothing found") : "…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                    }
                    ForEach(usage.codex) { l in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(l.name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)); Spacer()
                                Text("\(Int(l.percent))%").font(.system(size: 11, weight: .medium).monospacedDigit()) }
                            Capsule().fill(Color.white.opacity(0.12)).frame(height: 5)
                                .overlay(alignment: .leading) { GeometryReader { r in Capsule().fill(Island.accent).frame(width: r.size.width * min(1, l.percent / 100)) } }
                            if let d = l.resets { Text(String(format: L("Resets %@"), d.formatted(date: .abbreviated, time: .shortened))).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Code").font(.system(size: 13, weight: .semibold))
                    tokenRow(L("Last 5 hours"), usage.claudeFive)
                    tokenRow(L("Last 7 days"), usage.claudeWeek)
                    Text(L("Tokens in your conversations on this Mac")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { usage.refresh() }
    }

    private func tokenRow(_ label: String, _ n: Int) -> some View {
        HStack { Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)); Spacer()
            Text(n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)").font(.system(size: 13, weight: .semibold).monospacedDigit()) }
    }
}

private final class RulerDrag: ObservableObject { var start: Int? }

/// Two-finger scrolling (or the mouse wheel) over a control: calls `perform` with whole steps, positive = more (swipe left or up).
private struct ScrollSteps: NSViewRepresentable {
    let threshold: CGFloat
    let perform: (Int) -> Void
    func makeNSView(context: Context) -> NSView { let v = Catcher(); v.threshold = threshold; v.perform = perform; return v }
    func updateNSView(_ v: NSView, context: Context) { (v as? Catcher)?.threshold = threshold; (v as? Catcher)?.perform = perform }

    final class Catcher: NSView {
        var threshold: CGFloat = 10
        var perform: (Int) -> Void = { _ in }
        private var acc: CGFloat = 0
        private var monitor: Any?

        /// Looks at every scroll event of the app and takes those that land on this view (SwiftUI's own hit testing would
        /// never hand them to a background view).
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                self.handle(e)
                return nil                                       // used here: the panel behind doesn't scroll as well
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

        private func handle(_ e: NSEvent) {
            if e.phase == .began || e.phase == .mayBegin { acc = 0 }
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
            let dx = e.scrollingDeltaX * k, dy = e.scrollingDeltaY * k
            acc += abs(dx) > abs(dy) ? -dx : -dy
            let n = Int(acc / threshold)
            if n != 0 { acc -= CGFloat(n) * threshold; Haptic.tap(.alignment); perform(n) }
        }
    }
}

private extension View {
    func onScrollSteps(every points: CGFloat = 12, _ perform: @escaping (Int) -> Void) -> some View { background(ScrollSteps(threshold: points, perform: perform)) }
}

/// A horizontal ruler of minutes: drag it to set a length from 5 to 120 minutes.
private struct MinuteRuler: View {
    @Binding var minutes: Int
    @StateObject private var drag = RulerDrag()
    private let step: CGFloat = 5          // points per minute

    var body: some View {
        GeometryReader { r in
            let mid = r.size.width / 2
            Canvas { g, size in
                for v in max(0, minutes - 60)...(minutes + 60) where v >= 5 && v <= 120 {
                    let x = mid + CGFloat(v - minutes) * step
                    guard x > 0, x < size.width else { continue }
                    let big = v % 10 == 0, mid5 = v % 5 == 0
                    let h: CGFloat = big ? 20 : mid5 ? 14 : 8
                    g.fill(Path(CGRect(x: x - 0.5, y: size.height - h - 14, width: 1, height: h)), with: .color(.white.opacity(big ? 0.7 : 0.3)))
                    if big { g.draw(Text("\(v)").font(.system(size: 9)).foregroundColor(.white.opacity(0.5)), at: CGPoint(x: x, y: size.height - 5)) }
                }
            }
            RoundedRectangle(cornerRadius: 1.5).fill(Island.accent).frame(width: 3, height: 34).position(x: mid, y: 22)
            Text("\(minutes)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Island.accent).position(x: mid, y: -4)
        }
        .frame(height: 52)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            if drag.start == nil { drag.start = minutes }
            let new = min(120, max(5, (drag.start ?? minutes) - Int((v.translation.width / step).rounded())))
            if new != minutes { Haptic.tap(new % 5 == 0 ? .levelChange : .alignment) }              // a firmer tick on every fifth minute
            minutes = new
        }.onEnded { _ in drag.start = nil })
        .onScrollSteps(every: 5) { minutes = min(120, max(5, minutes + $0)) }       // (the tap comes from the scroll itself)
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
    }
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
    private var dimQuiet = Date.distantPast   // the island ignores brightness changes until then (they are Cocaine's own)
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
    private let island = IslandController()
    private let systemHUD = SystemHUD()
    private let mediaKeys = MediaKeys()
    private var autoAsked = Set<Permission>()
    private var presenceAssertion: IOPMAssertionID = 0
    private var lastOnAC: Bool?
    private let board = AgentBoard()                 // what each AI session is doing, from the hooks
    private var batteryGuard = BatteryGuard()
    private var autoOn = AutoOn()
    private var triggerActive = false
    private var arbiter = TriggerArbiter()
    private var triggerGrace: TimeInterval = 180
    private var requestedOn: Bool?                   // what Cocaine itself last applied; any other change came from outside
    private var realIdle = RealIdle()
    private var idleNow = 0.0                        // the user's idle time, Stay active's nudges left out
    private var screenGate = ScreenOffGate()
    private var heatGuard = HeatGuard()
    private var asking = false                       // the "allow links" question is on screen
    private var linksRefusedUntil = Date.distantPast
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
        model.triggersChanged = { [weak self] in self?.evaluateTriggers(System.cocaineOn) }
        model.screenModeChanged = { [weak self] in self?.syncScreenMode() }
        model.screenOffNow = { [weak self] in
            self?.hidePanel()
            DispatchQueue.global().async { PowerState.sleepDisplays() }
        }
        syncScreenMode()
        // Triggers look again at once after a wake, a clock or time-zone change, or a display coming or going.
        let recheck: (Notification) -> Void = { [weak self] n in
            if n.name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.evaluateTriggers(System.cocaineOn) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: recheck)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: recheck)
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, NSApplication.didChangeScreenParametersNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: recheck)
        }
        model.wakeChanged = { [weak self] in self?.applyWake(ask: true) }
        model.islandChanged = { [weak self] in
            guard let self else { return }
            self.island.setEnabled(self.settings.island)
            self.statusItem.isVisible = !self.settings.island || !self.island.showing    // the island replaces the menu-bar icon
        }
        statusItem.isVisible = !settings.island
        // …unless it can't be shown: Cocaine is never left without a sign on screen.
        island.onShowing = { [weak self] shown in
            guard let self else { return }
            log.notice("island \(shown ? "on screen" : "can't be shown: menu-bar icon back", privacy: .public)")
            self.statusItem.isVisible = !self.settings.island || !shown
        }
        island.settingsOpen = { [weak self] in self?.panel?.isVisible ?? false }
        island.start(panelModel: model, enabled: settings.island) { [weak self] in
            self?.island.setOpen(false)
            self?.showPanel(fromClick: false)
        }
        ClipboardUI.beforeAlert = { [weak self] in self?.hidePanel(); self?.island.setOpen(false); NSApp.activate() }
        model.presenceChanged = { [weak self] in
            guard let self else { return }
            self.updatePink()                                                // the pink powder pours in (or out) with the switch
            self.autoAsked.remove(.accessibility)           // turning it on asks again, if it's still missing
            self.refreshPermissions(askMissing: true)
            if !self.model.permissionProblems.isEmpty { self.watchPermissions() }
            self.presenceTick()
        }
        model.requestPresence = { [weak self] in self?.model.requestPermission(.accessibility) }
        model.requestPermission = { [weak self] p in
            Permissions.request(p, explicit: true) { self?.refreshPermissions() }
            self?.watchPermissions()
        }
        mediaKeys.onStep = { [weak self] key, fine in self?.handleMediaKey(key, fine: fine) ?? false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in      // at launch: ask for what an enabled feature lacks
            guard let self else { return }
            self.refreshPermissions(askMissing: true)
            if !self.model.permissionProblems.isEmpty { self.watchPermissions() }
        }
        // Back from System Settings (or anywhere): look again at once.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPermissions()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.systempreferences", let self else { return }
            self.refreshPermissions()
            if !self.model.permissionProblems.isEmpty { self.watchPermissions() }      // a switch flipped there can take a moment
        }
        model.hudReplaceChanged = { [weak self] in self?.applyHUDReplacement() }
        if !settings.replaceHUD { SystemHUD.cleanup() }
        applyHUDReplacement(atLaunch: true)
        island.model.hud.suppressBrightness = { [weak self] in
            guard let self else { return false }
            return self.dimPlan != nil || self.previewPlan != nil || self.fadeTimer != nil || Date() < self.dimQuiet
        }
        island.model.focus.onStart = { [weak self] minutes in
            guard let self, !System.cocaineOn else { return }
            self.setCocaine(true, forMinutes: minutes)
        }
        model.sendShortcut = { [weak self] in self?.sendShortcutToPhone() }
        model.revokePhones = { [weak self] in self?.revokePhones() }
        model.testPhone = { Phone.send(L("This is a test")) }
        syncPhones()
        model.quit = { NSApp.terminate(nil) }
        model.languageChanged = { [weak self] in self?.refreshIcon(on: System.cocaineOn, animate: false) }
        hostView = PanelHostingView(rootView: PanelView(m: model))
        hostView.sizingOptions = [.intrinsicContentSize]
        hostView.onSizeChange = { [weak self] in DispatchQueue.main.async { self?.fitPanel(animated: true) } }
        panel = MenuPanel(content: hostView)
        model.pageChanged = { [weak self] in                     // a new page starts at its top
            guard let scroll = self?.panel.scroll else { return }
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

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
            pendingCommands.forEach(command)         // (a status question is answered first)
            pendingCommands = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
            return
        }
        // Opening the app turns Cocaine on; a link that started it decides by itself (cocaine://off must not turn it on first).
        if !System.cocaineOn && pendingCommands.isEmpty { toggleCocaine() }
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
                if didFinishLaunching { command(url); continue }
                pendingCommands.append(url)
                // Started only to answer "status" (or show an alert): answer, then go away again. Anything else keeps it running.
                launchedForAlert = !pendingNeedsApp
                continue
            }
            if !didFinishLaunching { launchedForAlert = !pendingNeedsApp }
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

    /// A pending link that needs the app to keep running (anything but "status").
    private var pendingNeedsApp: Bool {
        pendingCommands.contains { if case .success(let r) = ControlURL.parse($0) { return r.action != .status }; return false }
    }

    /// The control commands above. Anything can open a cocaine:// link (a web page too), so what changes the Mac's sleep
    /// needs the "Shortcuts app and links" switch, or the user's OK when it's off. Bad values are refused, not guessed.
    private func command(_ url: URL) {
        let req: ControlRequest
        switch ControlURL.parse(url) {
        case .success(let r): req = r
        case .failure(let f):
            log.notice("command refused: \(String(describing: f), privacy: .public)")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let e = items.first(where: { $0.name == "x-error" })?.value.flatMap(ControlURL.callback),
               let r = ControlURL.reply(e, [("errorMessage", f == .badMinutes ? "minutes must be 1 to 1440" : "unknown command")]) {
                NSWorkspace.shared.open(r)
            }
            return
        }
        log.notice("command \(String(describing: req.action), privacy: .public)")
        guard !req.action.guarded || linksAllowed(url) else {
            if let e = req.failure, let r = ControlURL.reply(e, [("errorMessage", "not allowed")]) { NSWorkspace.shared.open(r) }
            return
        }
        switch req.action {
        case .on(let minutes): autoOn.userToggled(to: true, triggerActive: triggerActive); setCocaine(true, forMinutes: minutes)
        case .off: autoOn.userToggled(to: false, triggerActive: triggerActive); setCocaine(false)
        case .toggle: toggleCocaine()
        case .timer(let minutes): autoOn.userToggled(to: true, triggerActive: triggerActive); setCocaine(true, forMinutes: minutes ?? (settings.timerMinutes > 0 ? settings.timerMinutes : 60))
        case .pause(let minutes): pauseAlerts(until: Date().addingTimeInterval(Double(minutes ?? 60) * 60))
        case .resume: pauseAlerts(until: nil)
        case .panel: if !panel.isVisible { showPanel(fromClick: false) }
        case .status: break
        }
        guard let s = req.success else { return }
        // Answer with what was asked for (a change is applied in the background: report the target, not the old state).
        let on = wantOn ?? System.cocaineOn
        if let r = ControlURL.reply(s, ControlURL.status(on: on, until: settings.onUntil, now: Date(),
                                                         screenOff: screenOffMode, trigger: triggerActive)) {
            NSWorkspace.shared.open(r)
        }
    }

    /// Links may change things when the switch is on; otherwise ask (one question at a time, and after a "Don't Allow"
    /// links are ignored for 10 minutes, so a page can't flood the screen with questions).
    private func linksAllowed(_ url: URL) -> Bool {
        if settings.allowLinks { return true }
        guard !asking, Date() >= linksRefusedUntil else { return false }
        asking = true
        defer { asking = false }
        hidePanel()
        NSApp.activate()
        let a = NSAlert()
        a.messageText = L("Allow Shortcuts and links to control Cocaine?")
        let shown = String(url.absoluteString.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        a.informativeText = String(format: L("Something opened “%@”. If it wasn't you, choose Don't Allow. You can change this in Automation → Shortcuts."), shown)
        a.addButton(withTitle: L("Allow"))
        a.addButton(withTitle: L("Don't Allow"))
        guard a.runModal() == .alertFirstButtonReturn else {
            linksRefusedUntil = Date().addingTimeInterval(600)
            return false
        }
        settings.allowLinks = true
        model.allowLinks = true
        return true
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
        let away = forced ?? (idleNow >= 20 || dimPlan != nil || (screenOffMode && screenGate.fired))
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
            guard let self, count * minutes <= 30, self.idleNow >= Double(minutes * 60 - 10),
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
        systemHUD.disable()                      // macOS draws its own volume and brightness HUD again
        mediaKeys.stop()
        ClipboardHistory.shared.flush()          // a saved history gets its last change
        WakeSchedule.cancel()                    // nothing would be listening at that wake
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
        refreshPermissions()
        let mouse = NSEvent.mouseLocation
        let clicked = fromClick ? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } : nil
        var screen = clicked ?? NSScreen.main
        var anchorX = mouse.x
        if settings.island, let g = NotchGeometry.current() {
            screen = NSScreen.screens.first { $0.frame == g.frame } ?? screen       // under the notch, where the island is
            anchorX = g.centerX
        } else if let button = statusItem.button, let bar = button.window {
            let icon = bar.convertToScreen(button.convert(button.bounds, to: nil))
            if clicked == nil || clicked == bar.screen { screen = bar.screen ?? screen; anchorX = icon.midX }
        }
        guard let screen else { return }
        panelTop = settings.island ? screen.frame.maxY : (screen.visibleFrame.maxY - 6).rounded()   // from the notch, or under the menu bar
        panel.attach(toTop: settings.island)
        model.page = ""                                              // always opens on the home
        fitPanel(animated: false, centeredOn: anchorX, screen: screen)
        panel.makeKeyAndOrderFront(nil)
        if settings.island { island.setSuspended(true) }
        statusItem.button?.highlight(true)
        // Clicks elsewhere close it; a click on the icon itself (which also arrives here on macOS 27) toggles instead.
        let iconZone = NSRect(x: anchorX - 18, y: screen.frame.maxY - 44, width: 36, height: 44)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            if !iconZone.contains(NSEvent.mouseLocation) { self?.hidePanel() }
        }) { panelMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 {                                   // Esc: back from a page first, then close
                self?.hidePanel()
                return nil
            }
            return e
        }) { panelMonitors.append(m) }
    }

    /// Sizes the panel to its content with the top edge fixed under the icon, so it only grows or shrinks downward.
    private func fitPanel(animated: Bool, centeredOn midX: CGFloat? = nil, screen: NSScreen? = nil) {
        guard panel.isVisible || midX != nil else { return }
        hostView.layoutSubtreeIfNeeded()
        let natural = hostView.fittingSize
        guard natural.height > 0 else { return }
        // Never taller than the screen it's on (below the menu bar, 8 pt from the bottom): the rest scrolls.
        let visible = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var limit = max(240, panelTop - visible.minY - 8)
        let test = UserDefaults.standard.double(forKey: "testMaxHeight")        // tests: pretend the screen is small
        if test > 0 { limit = test }
        let size = NSSize(width: Layout.width, height: min(natural.height, limit))
        let top = panelTop + (settings.island ? Layout.overscan : 0)        // hanging from the notch: starts above the screen's top edge
        var frame = NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height)
        if let midX {
            frame = Self.panelFrame(size: size, anchorX: midX, top: top,
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
        island.setSuspended(false)
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
            DispatchQueue.main.async {
                if self.model.holdMissing != missing { self.model.holdMissing = missing }
                if missing { self.superviseHold() }
                if !self.model.settingAI && self.model.ai != ai { self.model.ai = ai }
                let paused = self.settings.alertsPausedUntil   // a pause ends by itself
                if self.model.alertsPausedUntil != paused { self.model.alertsPausedUntil = paused }
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
        idleNow = realIdle.update(systemIdle: System.idleSeconds, now: Date())
        if on != lastOn {
            // Turned on or off from outside (`cocaine on|off`, `cocaine remote`, another tool): that's the user's choice,
            // just like the switch, so a Smart Trigger doesn't undo it at once.
            if Self.isOutsideChange(last: lastOn, now: on, requested: requestedOn, pending: wantOn) {
                log.notice("turned \(on ? "on" : "off", privacy: .public) from outside")
                autoOn.userToggled(to: on, triggerActive: triggerActive)
                requestedOn = on
            }
            lastOn = on
            refreshIcon(on: on)
            if on { superviseHold() }
        } else if on && ticks % 20 == 0 {
            superviseHold()                          // every 10 s
        }
        if wantOn == nil && model.on != on { model.on = on }   // don't fight a switch the user just flipped
        if panel.isVisible && ticks % 4 == 0 { refreshPanelState() }
        if alerter.isShowing, let at = alerter.shownAt, Date().timeIntervalSince(at) > 1.5, idleNow < 0.6 {
            alerter.close(animated: true)            // the user is back
        }
        updateDimming(on: on)
        if ticks % 4 == 0 { checkTimer(on) }                     // every 2 s
        if ticks % 10 == 0 { evaluateTriggers(on) }              // every 5 s
        if ticks % 20 == 0 { checkBattery(on); checkHeat(on); writeBoard(); presenceTick() }    // every 10 s
        if ticks % 4 == 0 { watchPower() }                       // every 2 s
    }

    // MARK: Permissions

    /// What the features that are on need.
    private func neededPermissions() -> [Permission] {
        var n: [Permission] = []
        if settings.stayActive || settings.replaceHUD { n.append(.accessibility) }
        return n
    }

    /// Checks everything. With `askMissing`, asks (once per launch each) for what an enabled feature needs and lacks; the rest is
    /// asked when you use it (camera, calendar, music) and listed under Permissions if it was refused.
    /// Never blocks: Files and Music/Spotify are re-checked off the main thread and land here again when they change.
    private func refreshPermissions(askMissing: Bool = false) {
        let problems = Self.permissionProblems(needed: neededPermissions(), island: settings.island, state: Permissions.state)
        for p in problems where askMissing && !autoAsked.contains(p) && neededPermissions().contains(p) {
            autoAsked.insert(p); Permissions.request(p)
        }
        if model.permissionProblems != problems { model.permissionProblems = problems }
        let access = Presence.hasAccess
        if model.presenceAccess != access { model.presenceAccess = access }
        // A permission just given: start what was waiting for it.
        if settings.replaceHUD && !mediaKeys.running && AXIsProcessTrusted() { mediaKeys.start() }
        Permissions.probe(files: settings.island) { [weak self] changed in if changed { self?.refreshPermissions() } }
    }

    /// What the Permissions card lists: what an enabled feature needs and lacks, and (with the island on) what was refused.
    static func permissionProblems(needed: [Permission], island: Bool, state: (Permission) -> Permissions.State) -> [Permission] {
        var problems = needed.filter { state($0) != .granted }
        if island { problems += [Permission.camera, .calendar, .automation, .files].filter { !problems.contains($0) && state($0) == .denied } }
        return problems
    }

    /// After asking (or sending you to Settings), look again every second for a minute, and whenever Cocaine comes to the front.
    private var permissionWatch: Timer?
    private func watchPermissions() {
        permissionWatch?.invalidate()
        var n = 0
        permissionWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            n += 1
            guard let self, n <= 60 else { t.invalidate(); return }
            self.refreshPermissions()
            if self.model.permissionProblems.isEmpty { t.invalidate() }
        }
    }

    // MARK: Stay active, charging, the HUD keys

    /// While a chat app is open (or always) and you are idle, keeps the idle clock from running out; holds the display awake.
    private func presenceTick() {
        let want = settings.stayActive && (settings.stayActiveAlways || Presence.anyRunning(settings.stayActiveApps))
        refreshPermissions()                                    // (also starts the HUD keys once their permission is given)
        if want != model.presenceActive {
            model.presenceActive = want
            updatePink()                                           // the pink powder follows
        }
        // In screen-off mode (Cocaine on) the displays are meant to go dark: no display hold, and never input to a
        // sleeping display, which would light it up again (chat apps may then show you away).
        let dark = screenOffMode && System.cocaineOn
        if want {
            if dark, presenceAssertion != 0 { IOPMAssertionRelease(presenceAssertion); presenceAssertion = 0 }
            if !dark && presenceAssertion == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "Cocaine keeps you available in chat apps" as CFString, &presenceAssertion)
            }
            if System.idleSeconds > 45 && !PowerState.displaysAsleep && !(dark && screenGate.fired) && Presence.nudge() {
                realIdle.lastNudge = Date()
            }
        } else if presenceAssertion != 0 {
            IOPMAssertionRelease(presenceAssertion); presenceAssertion = 0
        }
    }

    /// A message in the island when the charger is plugged in or out.
    private func watchPower() {
        guard let b = System.battery else { return }
        if let last = lastOnAC, last != b.onAC {
            island.model.flashNotice(b.onAC ? "bolt.fill" : "battery.50", (b.onAC ? L("Charging") : L("On battery")) + " \(b.percent)%")
        }
        lastOnAC = b.onAC
    }

    /// Volume, mute and brightness keys: applied here, shown in the island. False leaves the key to macOS.
    private func handleMediaKey(_ key: Int, fine: Bool) -> Bool {
        if key == 0 || key == 1 || key == 7 {
            guard let r = MediaKeys.changeVolume(key: key, fine: fine) else { return false }
            let icon = r.muted || r.level == 0 ? "speaker.slash.fill" : r.level < 0.34 ? "speaker.wave.1.fill" : r.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            island.model.flashNotice(icon, L("Volume"), level: r.muted ? 0 : Double(r.level))
            return true
        }
        guard dimPlan == nil, previewPlan == nil, let id = screens.online.first(where: { CGDisplayIsBuiltin($0) != 0 }), let b = screens.brightness(id) else { return false }
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        let new = min(1, max(0, b + (key == 2 ? step : -step)))
        dimQuiet = Date().addingTimeInterval(1)
        screens.setBrightness(id, new)
        island.model.flashNotice("sun.max.fill", L("Brightness"), level: Double(new))
        return true
    }

    private func applyHUDReplacement(atLaunch: Bool = false) {
        island.syncHUD(settings.replaceHUD)
        if settings.replaceHUD {
            systemHUD.enable()
            if !atLaunch {                                        // just turned on: ask if it's missing (at launch: 3 s later, once)
                autoAsked.remove(.accessibility)
                refreshPermissions(askMissing: true)
                if !model.permissionProblems.isEmpty { watchPermissions() }
            }
            if AXIsProcessTrusted() { mediaKeys.start() }
        } else {
            systemHUD.disable()
            mediaKeys.stop()
        }
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

    /// Lid closed, on battery, getting hot (a Mac in a bag): turn Cocaine off so it can sleep and cool down.
    private func checkHeat(_ on: Bool) {
        let onAC = PowerState.onAC
        guard heatGuard.check(lidClosed: System.lidClosed, onAC: onAC, thermal: ProcessInfo.processInfo.thermalState), on else { return }
        log.notice("hot with the lid closed on battery: Cocaine off")
        autoOn.userToggled(to: false, triggerActive: triggerActive)
        setCocaine(false, auto: true)
        alert(Notice(from: "Cocaine", message: L("Too hot with the lid closed: Cocaine is off"), project: nil), away: true)
    }

    /// The Battery Guard has turned Cocaine off for a low battery: no trigger turns it back on until it recovers.
    private var lowBattery: Bool { settings.batteryTurnsOff && batteryGuard.tripped }

    /// Smart Triggers: an AI at work (from the hooks), a chosen program, the power source, an external display or the
    /// schedule keeps Cocaine on; "Any" or "All" of them, as chosen.
    private func evaluateTriggers(_ on: Bool) {
        guard !launchedForAlert else { return }                 // started only to show an alert: change nothing
        var states: [TriggerKind: Bool] = [:]
        if settings.triggerAgents { states[.agents] = board.anyLive() }
        let apps = settings.triggerApps.map { $0.lowercased() }
        if !apps.isEmpty {
            let names = System.runningNames()
            states[.apps] = apps.contains { names.contains($0) }
        }
        let b = System.battery
        states[.power] = PowerRule.met(rule: settings.triggerPower, onAC: b?.onAC ?? PowerState.onAC, battery: b?.percent,
                                       minimum: settings.triggerPowerMin)
        states[.display] = DisplayRule.met(rule: settings.triggerDisplay, external: PowerState.externalDisplays)
        if settings.triggerSchedule { states[.schedule] = settings.schedule.contains(Date(), calendar: .autoupdatingCurrent) }
        let (active, grace) = arbiter.evaluate(states, all: settings.triggerAll, blocked: lowBattery || heatGuard.tripped)
        if !active { triggerGrace = grace }
        triggerActive = active
        switch autoOn.step(active: active, isOn: wantOn ?? on, now: Date(), grace: triggerGrace) {
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

    private let phoneListener = PhoneListener()
    private let sleepWatcher = SleepWatcher()

    /// Applies the "Wake for iPhone" option: schedules the next wake (asking, when the user just turned it on, for the
    /// one-time permission) or cancels it.
    private func applyWake(ask: Bool) {
        phoneListener.maxAge = { [weak self] in (self?.settings.wakeForPhone ?? false) ? WakeSchedule.maxCommandAge : 120 }
        guard settings.wakeForPhone else { WakeSchedule.cancel(); return }
        sleepWatcher.willSleep = { [weak self] in self?.armWake() }
        sleepWatcher.didWake = { [weak self] in
            WakeHold.extend(90)                      // long enough to reconnect and answer
            self?.phoneListener.reconnect()
            self?.armWake()
        }
        sleepWatcher.start()
        var ok = WakeSchedule.arm()
        if !ok && ask {
            hidePanel(); NSApp.activate()
            if let cmd = Authorization.installCommand(user: NSUserName()),
               Authorization.runAsRoot(cmd, prompt: L("Cocaine needs your permission once, to wake your Mac for your iPhone.")) { ok = WakeSchedule.arm() }
            if !ok {
                settings.wakeForPhone = false
                model.wakeForPhone = false
                let e = NSAlert(); e.messageText = L("Couldn't turn on the wake-ups"); e.runModal()
                return
            }
        }
        if model.phoneCount == 0 { WakeSchedule.cancel() }
    }

    /// Schedules the next wake just before sleeping and just after waking (so there is always one ahead), unless the
    /// battery is low and unplugged.
    private func armWake() {
        guard settings.wakeForPhone, model.phoneCount > 0 else { return }
        if let b = System.battery, !b.onAC, b.percent <= 20 { WakeSchedule.cancel(); return }
        WakeSchedule.arm()
    }

    /// Starts listening for the paired phones (at launch and whenever the list changes).
    private func syncPhones(_ given: [Pairing]? = nil) {
        let list = given ?? PhoneLink.load()
        model.phoneCount = list.count
        phoneListener.onChange = { [weak self] up in self?.model.phoneLinkUp = up }
        phoneListener.sync(list)
        applyWake(ask: false)
    }

    /// Pairs a new iPhone: asks what it may do, makes a Shortcut carrying its own secret topics, and opens the share
    /// sheet (AirDrop, Messages, Mail…) on it.
    private func sendShortcutToPhone() {
        hidePanel(); NSApp.activate()
        let a = NSAlert()
        a.messageText = L("Pair an iPhone")
        a.informativeText = L("The Shortcut carries a secret that lets whoever has it control this Mac, within the level you choose. Send it only to your own devices.")
        let level = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        level.addItems(withTitles: [L("Status, on/off and projects"), L("Also start and steer AI agents")])
        a.accessoryView = level
        a.addButton(withTitle: L("Send"))
        a.addButton(withTitle: L("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let pairing = PhoneLink.newPairing(tier: level.indexOfSelectedItem == 1 ? "agents" : "basic") else { return }
        model.makingShortcut = true
        DispatchQueue.global().async {
            let file = PhoneShortcut.signedFile(pairing)
            DispatchQueue.main.async {
                self.model.makingShortcut = false
                guard let file else {
                    NSApp.activate()
                    let e = NSAlert()
                    e.messageText = L("Can't make the Shortcut")
                    e.informativeText = L("Signing it needs an internet connection and iCloud (sign in to it in System Settings).")
                    e.runModal()
                    return
                }
                guard PhoneLink.save(PhoneLink.load() + [pairing]) else {
                    NSApp.activate()
                    let e = NSAlert(); e.messageText = L("Can't make the Shortcut"); e.runModal()
                    return
                }
                self.syncPhones()
                self.presentShare(file)
                log.notice("shortcut ready to share: \(file.lastPathComponent, privacy: .public)")
                // It holds a secret: don't leave the file lying around.
                DispatchQueue.main.asyncAfter(deadline: .now() + 600) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            }
        }
    }

    private func revokePhones() {
        hidePanel(); NSApp.activate()
        let a = NSAlert()
        a.messageText = L("Remove every paired iPhone?")
        a.informativeText = L("They stop working until you send a new Shortcut.")
        a.addButton(withTitle: L("Revoke"))
        a.addButton(withTitle: L("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if !PhoneLink.save([]) {                          // couldn't write: still stop answering now
            let e = NSAlert(); e.messageText = L("Can't make the Shortcut"); e.runModal()
        }
        syncPhones([])
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
        model.fillLevel = level
        if model.pouring != pouring { model.pouring = pouring }
        redrawStatusItem()
        updatePink()
    }

    private var pinkTimer: Timer?
    private var pinkHeading: CGFloat = -1

    /// Animates the pink powder toward where it should be (full or empty), the way the white one fills and empties.
    private func updatePink() {
        let target = model.pinkTarget
        guard target != pinkHeading else { return }
        pinkHeading = target
        pinkTimer?.invalidate()
        let start = model.pinkLevel, filling = target > start, duration = filling ? 1.4 : 0.6, began = Date()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let f = min(1, CGFloat(Date().timeIntervalSince(began) / duration))
            let eased = filling ? 1 - (1 - f) * (1 - f) : f * f                        // ease-out filling, ease-in emptying
            self.model.pinkLevel = start + (target - start) * eased
            let pouring = filling && f < 1
            if self.model.pinkPouring != pouring { self.model.pinkPouring = pouring }
            self.redrawStatusItem()
            if f >= 1 { t.invalidate(); self.pinkTimer = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        pinkTimer = t
    }

    private func redrawStatusItem() {
        statusItem.button?.image = Baggie.image(level: model.bagLevel, pouring: model.bagPouring, pink: model.bagPink)
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

    /// A change of state Cocaine didn't make: not the first reading, nothing of ours in flight, and not what we last applied.
    static func isOutsideChange(last: Bool?, now: Bool, requested: Bool?, pending: Bool?) -> Bool {
        guard let last, last != now, pending == nil else { return false }
        return requested != now
    }

    private func applyWanted() {
        guard !applying, let target = wantOn else { return }
        applying = true
        requestedOn = target
        DispatchQueue.global().async {
            let arg = target ? "on" : "off"
            var status = engine(arg)
            if status == 2, Authorization.install() {   // first run on this Mac: ask for the admin password once
                log.notice("sudo rule installed")
                status = engine(arg)
            }
            DispatchQueue.main.async {
                self.applying = false
                self.requestedOn = System.cocaineOn       // what our apply really left (a failed one changed nothing)
                self.model.needsAuth = status == 2
                if self.wantOn == target { self.wantOn = nil }
                self.tick()                          // shows the real state (reverts the switch if it failed)
                self.refreshPanelState()
                self.applyWanted()                   // the user changed their mind while this was running
            }
        }
    }

    // MARK: Dimming

    /// "Turn the screen off instead" is chosen (it applies while Cocaine is on).
    private var screenOffMode: Bool { settings.dimEnabled && settings.screenOff }

    /// Tells the engine's display helper whether to keep the displays on (normal) or let them sleep (screen off).
    private func syncScreenMode() {
        let mode = screenOffMode ? "screen-off" : "normal"
        if screenOffMode, dimPlan != nil { restore() }            // switching over while dimmed: back to normal first
        DispatchQueue.global().async { run("/bin/zsh", [scriptPath, "mode", mode]) }
    }

    private func updateDimming(on: Bool) {
        guard previewPlan == nil else { return }
        let idle = idleNow                                         // Stay active's own nudges don't count as you
        defer { lastIdle = idle }
        if screenOffMode {
            // Once per idle stretch, after the delay: displays off. The Mac keeps running (disablesleep); input wakes them.
            if screenGate.step(idle: idle, delay: settings.delay, enabled: true, on: on, allowed: Date() > brightUntil,
                               asleep: PowerState.displaysAsleep) {
                log.notice("screens off after \(Int(idle), privacy: .public)s idle")
                DispatchQueue.global().async { PowerState.sleepDisplays() }
            }
            return
        }
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
        dimQuiet = Date().addingTimeInterval(3)
        fade(plan, to: 1, over: 1.5)
    }

    private func restore() {
        guard let plan = dimPlan else { return }
        dimPlan = nil
        dimQuiet = Date().addingTimeInterval(3)
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

/// Smart Triggers on power, displays and schedules; screen-off mode; control links (part of --selftest).
private func powerSelfTest(_ check: (String, Bool) -> Void) {
    func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    var rome = Calendar(identifier: .gregorian); rome.timeZone = TimeZone(identifier: "Europe/Rome")!
    var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let work = TimeWindow(days: [2, 3, 4, 5, 6], start: 9 * 60, end: 18 * 60)
    check("schedule: Monday 10:00 is inside 9–18 on weekdays", work.contains(at("2026-10-05T08:00:00Z"), calendar: rome))
    check("schedule: the end time itself is outside", !work.contains(at("2026-10-05T16:00:00Z"), calendar: rome))
    check("schedule: one minute before the start is outside", !work.contains(at("2026-10-05T06:59:00Z"), calendar: rome))
    check("schedule: Saturday is outside", !work.contains(at("2026-10-10T08:00:00Z"), calendar: rome))
    let night = TimeWindow(days: [6], start: 22 * 60, end: 6 * 60)       // Friday night
    check("schedule: past midnight, Friday 23:00 is inside", night.contains(at("2026-10-09T21:00:00Z"), calendar: rome))
    check("schedule: past midnight, Saturday 02:00 still belongs to Friday", night.contains(at("2026-10-10T00:00:00Z"), calendar: rome))
    check("schedule: past midnight, Saturday 23:00 is outside", !night.contains(at("2026-10-10T21:00:00Z"), calendar: rome))
    check("schedule: past midnight, Friday 02:00 belongs to Thursday (not chosen)", !night.contains(at("2026-10-09T00:00:00Z"), calendar: rome))
    check("schedule: start == end is the whole day", TimeWindow(days: [2], start: 600, end: 600).contains(at("2026-10-05T02:00:00Z"), calendar: rome))
    check("schedule: no day chosen, never", !TimeWindow(days: [], start: 0, end: 600).contains(at("2026-10-05T02:00:00Z"), calendar: rome))
    // DST in Rome: 29 March 2026 02:00 → 03:00, 25 October 2026 03:00 → 02:00.
    let early = TimeWindow(days: [1], start: 150, end: 240)                 // Sunday 02:30–04:00
    check("schedule: DST spring forward, a window starting in the skipped hour still runs (03:10)", early.contains(at("2026-03-29T01:10:00Z"), calendar: rome))
    check("schedule: DST spring forward, 01:59 is before it", !early.contains(at("2026-03-29T00:59:00Z"), calendar: rome))
    let fall = TimeWindow(days: [1], start: 120, end: 180)                  // Sunday 02:00–03:00
    check("schedule: DST fall back, 02:30 summer time is inside", fall.contains(at("2026-10-25T00:30:00Z"), calendar: rome))
    check("schedule: DST fall back, 02:30 winter time (the repeated hour) is inside too", fall.contains(at("2026-10-25T01:30:00Z"), calendar: rome))
    check("schedule: DST fall back, 03:05 winter time is outside", !fall.contains(at("2026-10-25T02:05:00Z"), calendar: rome))
    check("schedule: read on the local wall clock (time zone)", work.contains(at("2026-10-05T10:00:00Z"), calendar: rome)
          && !work.contains(at("2026-10-05T10:00:00Z"), calendar: tokyo))

    var arb = TriggerArbiter()
    check("arbiter: any, one is enough", arb.evaluate([.agents: false, .schedule: true], all: false).active)
    check("arbiter: all, one false is not enough", !arb.evaluate([.agents: false, .schedule: true], all: true).active)
    check("arbiter: all, every one true", arb.evaluate([.agents: true, .schedule: true], all: true).active)
    check("arbiter: nothing enabled is never active", !arb.evaluate([:], all: true).active && !arb.evaluate([:], all: false).active)
    var g1 = TriggerArbiter(); _ = g1.evaluate([.apps: true, .schedule: true], all: false)
    check("arbiter: any, the longest grace of what was holding it", g1.evaluate([.apps: false, .schedule: false], all: false).grace == 180)
    var g2 = TriggerArbiter(); _ = g2.evaluate([.apps: true, .schedule: true], all: true)
    check("arbiter: all, a schedule ending ends it at once", g2.evaluate([.apps: true, .schedule: false], all: true).grace == 0)
    var g3 = TriggerArbiter(); _ = g3.evaluate([.apps: true, .schedule: true], all: true)
    check("arbiter: all, an app closing gets its grace", g3.evaluate([.apps: false, .schedule: true], all: true).grace == 180)
    var g4 = TriggerArbiter()
    let blocked = g4.evaluate([.power: true], all: false, blocked: true)
    check("arbiter: a low battery blocks every trigger", !blocked.active && blocked.grace == 0)
    // A schedule turns Cocaine on and off on time; the user's OFF wins until the window ends.
    var s = AutoOn(); let t0 = Date()
    check("schedule trigger: on at the start", s.step(active: true, isOn: false, now: t0, grace: 0) == .turnOn)
    check("schedule trigger: off right at the end", s.step(active: false, isOn: true, now: t0 + 3600, grace: 0) == .turnOff)
    var u = AutoOn()
    _ = u.step(active: true, isOn: false, now: t0, grace: 0)
    u.userToggled(to: false, triggerActive: true)
    check("schedule trigger: the user's OFF holds for the rest of the window", u.step(active: true, isOn: false, now: t0 + 60, grace: 0) == .none)
    check("schedule trigger: …and the next window turns it on again", u.step(active: false, isOn: false, now: t0 + 3600, grace: 0) == .none
          && u.step(active: true, isOn: false, now: t0 + 86400, grace: 0) == .turnOn)
    // Turned off from outside (`cocaine off`, `cocaine remote off`) while a trigger holds it: counts as the user's OFF.
    check("outside change: an OFF Cocaine didn't make is seen", AppDelegate.isOutsideChange(last: true, now: false, requested: true, pending: nil))
    check("outside change: our own OFF is not", !AppDelegate.isOutsideChange(last: true, now: false, requested: false, pending: nil)
          && !AppDelegate.isOutsideChange(last: true, now: false, requested: true, pending: false))
    check("outside change: the first reading is not a change", !AppDelegate.isOutsideChange(last: nil, now: true, requested: nil, pending: nil))
    var x = AutoOn()
    _ = x.step(active: true, isOn: false, now: t0)
    if AppDelegate.isOutsideChange(last: true, now: false, requested: true, pending: nil) { x.userToggled(to: false, triggerActive: true) }
    check("outside change: a trigger doesn't turn it back on at once", x.step(active: true, isOn: false, now: t0 + 5) == .none)

    check("power: on the charger", PowerRule.met(rule: "ac", onAC: true, battery: 50, minimum: 20) == true
          && PowerRule.met(rule: "ac", onAC: false, battery: 50, minimum: 20) == false)
    check("power: on battery above the level", PowerRule.met(rule: "battery", onAC: false, battery: 50, minimum: 20) == true)
    check("power: on battery at or below the level lets go", PowerRule.met(rule: "battery", onAC: false, battery: 20, minimum: 20) == false)
    check("power: on battery, but plugged in, or no battery", PowerRule.met(rule: "battery", onAC: true, battery: 90, minimum: 20) == false
          && PowerRule.met(rule: "battery", onAC: true, battery: nil, minimum: 20) == false)
    check("power: off is not a trigger", PowerRule.met(rule: "", onAC: true, battery: 50, minimum: 20) == nil)
    check("display: connected / not connected", DisplayRule.met(rule: "connected", external: 1) == true && DisplayRule.met(rule: "connected", external: 0) == false
          && DisplayRule.met(rule: "disconnected", external: 0) == true && DisplayRule.met(rule: "", external: 2) == nil)

    // Stay active nudges every ~10 s after 45 s idle: the system idle never passes ~55 s, so a 1-minute dim never came.
    var ri = RealIdle(); var sysLast = t0; var maxSys = 0.0, real = 0.0
    for sec in stride(from: 0.0, through: 300, by: 1) {
        let now = t0 + sec
        var sys = now.timeIntervalSince(sysLast)
        if sys > 45 && Int(sec) % 10 == 0 { sysLast = now; ri.lastNudge = now; sys = 0 }
        maxSys = max(maxSys, sys)
        real = ri.update(systemIdle: sys, now: now)
    }
    check("idle: with Stay active the system idle stays under a minute (the old dimming never fired)", maxSys < 60)
    check("idle: the user's own idle keeps counting through the nudges", real >= 299)
    check("idle: real input starts it again", ri.update(systemIdle: 0, now: t0 + 400) < 1)

    var gate = ScreenOffGate()
    check("screen off: not before the delay", !gate.step(idle: 50, delay: 60, enabled: true, on: true, asleep: false))
    check("screen off: at the delay, once", gate.step(idle: 60, delay: 60, enabled: true, on: true, asleep: false)
          && !gate.step(idle: 90, delay: 60, enabled: true, on: true, asleep: false))
    check("screen off: again after the user came back and left", !gate.step(idle: 1, delay: 60, enabled: true, on: true, asleep: false)
          && gate.step(idle: 61, delay: 60, enabled: true, on: true, asleep: false))
    var gate2 = ScreenOffGate()
    check("screen off: only while Cocaine is on", !gate2.step(idle: 999, delay: 60, enabled: true, on: false, asleep: false))
    check("screen off: waits while an alert keeps the screen lit", !gate2.step(idle: 999, delay: 60, enabled: true, on: true, allowed: false, asleep: false)
          && gate2.step(idle: 999, delay: 60, enabled: true, on: true, allowed: true, asleep: false))
    var gate3 = ScreenOffGate()
    check("screen off: displays already asleep are left alone", !gate3.step(idle: 99, delay: 60, enabled: true, on: true, asleep: true) && gate3.fired)

    var heat = HeatGuard()
    check("heat: lid closed, on battery, serious → off, once", heat.check(lidClosed: true, onAC: false, thermal: .serious)
          && !heat.check(lidClosed: true, onAC: false, thermal: .critical))
    check("heat: lid open or on the charger is left alone", { var h = HeatGuard(); return !h.check(lidClosed: false, onAC: false, thermal: .critical)
        && !h.check(lidClosed: true, onAC: true, thermal: .critical) && !h.check(lidClosed: true, onAC: false, thermal: .fair) }())

    func parse(_ s: String) -> Result<ControlRequest, ControlURL.Failure> { ControlURL.parse(URL(string: s)!) }
    check("link: on for 90 minutes", (try? parse("cocaine://on?minutes=90").get())?.action == .on(minutes: 90))
    check("link: off, toggle and status", (try? parse("cocaine://off").get())?.action == .off && (try? parse("cocaine://TOGGLE").get())?.action == .toggle
          && (try? parse("cocaine://status").get())?.action == .status)
    check("link: minutes out of range or not a number are refused", [0, 1441, 99999].allSatisfy { parse("cocaine://on?minutes=\($0)") == .failure(.badMinutes) }
          && parse("cocaine://timer?minutes=abc") == .failure(.badMinutes) && parse("cocaine://timer?minutes=-5") == .failure(.badMinutes)
          && parse("cocaine://timer?minutes=1e3") == .failure(.badMinutes))
    check("link: unknown commands and other schemes are refused", parse("cocaine://sleepnow") == .failure(.unknown("sleepnow"))
          && parse("http://on") == .failure(.notOurs))
    check("link: x-callback-url status with a Shortcuts callback",
          (try? parse("cocaine://x-callback-url/status?x-success=shortcuts%3A%2F%2Fx-callback-url%2Fic-success%3Fid%3D1").get())?.success?.scheme == "shortcuts")
    check("link: a callback to anything but Shortcuts is dropped",
          (try? parse("cocaine://x-callback-url/status?x-success=https%3A%2F%2Fevil.example%2F&x-error=javascript:alert(1)").get()).map { $0.success == nil && $0.failure == nil } == true)
    check("link: changing commands need permission, status and panel don't",
          ControlAction.on(minutes: nil).guarded && ControlAction.off.guarded && ControlAction.pause(minutes: nil).guarded
          && !ControlAction.status.guarded && !ControlAction.panel.guarded)
    let reply = ControlURL.reply(URL(string: "shortcuts://x-callback-url/ic-success?id=1")!, [("state", "on&evil=1")])
    check("link: reply values are encoded, never spliced", URLComponents(url: reply!, resolvingAgainstBaseURL: false)?.queryItems?.count == 2
          && URLComponents(url: reply!, resolvingAgainstBaseURL: false)?.queryItems?.last?.value == "on&evil=1")
    let st = Dictionary(uniqueKeysWithValues: ControlURL.status(on: true, until: t0 + 90.5 * 60, now: t0, screenOff: true, trigger: false))
    check("link: status says on, minutes left (rounded up) and the mode", st["state"] == "on" && st["remaining_minutes"] == "91" && st["screen_off_mode"] == "1")
    let off = Dictionary(uniqueKeysWithValues: ControlURL.status(on: false, until: t0 + 600, now: t0, screenOff: false, trigger: false))
    check("link: status when off has no deadline", off["state"] == "off" && off["remaining_minutes"] == "" && off["until"] == "")
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
    let size = NSSize(width: Layout.width, height: 198)
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
    guard let file = PhoneShortcut.signedFile(PhoneLink.newPairing(tier: "basic")!) else { print("could not sign"); exit(1) }
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
    guard let f = PhoneShortcut.signedFile(PhoneLink.newPairing(tier: "basic")!) else { print("could not sign"); exit(1) }
    try? FileManager.default.removeItem(atPath: CommandLine.arguments[2])
    try? FileManager.default.copyItem(at: f, to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("ok")
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--relay-test" {
    // A real round trip through the relay with throwaway topics: sends an unknown command ("ping-test"), which the gate
    // refuses, and expects that refusal back on the reply topic. Nothing about this Mac leaves it.
    let pairing = PhoneLink.newPairing(tier: "basic")!
    let listener = PhoneListener()
    listener.sync([pairing])
    Thread.sleep(forTimeInterval: 4)
    _ = RelayTest.curl("\(PhoneLink.relay)/\(pairing.cmd)/publish?message=ping-test")
    var answer = ""
    for _ in 0..<12 where answer.isEmpty {
        Thread.sleep(forTimeInterval: 1.5)
        answer = RelayTest.curl("\(PhoneLink.relay)/\(pairing.reply)/raw?poll=1&since=60s")
    }
    let first = answer.contains("not allowed")
    print(first ? "PASS  relay round trip: \(answer)" : "FAIL  relay round trip: '\(answer)'")
    // What a sleeping Mac does: the connection is gone, a command arrives meanwhile, and the next wake picks it up.
    listener.sync([])
    Thread.sleep(forTimeInterval: 1)
    _ = RelayTest.curl("\(PhoneLink.relay)/\(pairing.cmd)/publish?message=ping-while-asleep")
    Thread.sleep(forTimeInterval: 2)
    listener.maxAge = { WakeSchedule.maxCommandAge }
    listener.sync([pairing])
    var count = 0
    for _ in 0..<12 where count < 2 {
        Thread.sleep(forTimeInterval: 1.5)
        count = RelayTest.curl("\(PhoneLink.relay)/\(pairing.reply)/raw?poll=1&since=60s").split(separator: "\n").count
    }
    print(count == 2 ? "PASS  command sent while disconnected is answered after reconnect (once)" : "FAIL  after reconnect: \(count) answers")
    Thread.sleep(forTimeInterval: 4)
    listener.reconnect()                                    // the wake-up path: no repeat of what was already handled
    Thread.sleep(forTimeInterval: 6)
    let total = RelayTest.curl("\(PhoneLink.relay)/\(pairing.reply)/raw?poll=1&since=90s").split(separator: "\n").count
    print(total == 2 ? "PASS  reconnect doesn't run old commands again" : "FAIL  reconnect repeated a command: \(total) answers")
    exit(first && count == 2 && total == 2 ? 0 : 1)
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
    powerSelfTest(check)
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
    check("hud: this process is not mistaken for the system helper", !SystemHUD.helperPIDs().contains(getpid()))
    check("hud: volume-up key down is decoded", MediaKeys.decode(data1: (0 << 16) | (0xA << 8))?.down == true)
    check("hud: brightness-down key up is decoded", { let k = MediaKeys.decode(data1: (3 << 16) | (0xB << 8)); return k?.key == 3 && k?.down == false }())
    check("hud: other keys are ignored", MediaKeys.decode(data1: (16 << 16) | (0xA << 8)) == nil)
    check("wake: date in pmset's format", WakeSchedule.format(Date(timeIntervalSince1970: 1_790_000_000)).range(of: "^\\d\\d/\\d\\d/\\d\\d \\d\\d:\\d\\d:\\d\\d$", options: .regularExpression) != nil)
    check("wake: the sudo rule allows only schedule wake/cancel wake, tagged cocaine",
          Authorization.installCommand(user: "u")?.contains("/usr/bin/pmset schedule wake * cocaine, /usr/bin/pmset schedule cancel wake * cocaine,") == true)
    do {   // the one-time authorization: how its outcome is read (the old code never saw the "rc=" line after `exit`)
        let dir = NSTemporaryDirectory() + "cocaine-auth-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dest = dir + "/rule"
        let cmd = Authorization.installCommand(user: NSUserName(), dest: dest, asRoot: false)!
        check("auth: the install command ends with exit (the case the old report missed)", cmd.hasSuffix("exit $r"))
        check("auth: a successful install is reported as success", Authorization.runPlain(cmd) && FileManager.default.fileExists(atPath: dest))
        check("auth: a failing install is reported as failure", !Authorization.runPlain("exit 3"))
        check("auth: a failure inside the install (bad destination) is reported as failure",
              !Authorization.runPlain(Authorization.installCommand(user: NSUserName(), dest: dir + "/no/such/dir/rule", asRoot: false)!))
        check("auth: no report line (cancelled, killed) is a failure", !Authorization.succeeded("") && !Authorization.succeeded("garbage\n"))
        check("auth: only rc=0 is success", Authorization.succeeded("rc=0\n") && !Authorization.succeeded("rc=1\n") && !Authorization.succeeded("rc=10\n"))
        check("auth: noise before the report is ignored", Authorization.succeeded("warning\nrc=0\n"))
        try? FileManager.default.removeItem(atPath: dest)
        check("auth: retry after a failure works", Authorization.runPlain(cmd) && FileManager.default.fileExists(atPath: dest))
        check("auth: a user name with shell characters is refused", Authorization.installCommand(user: "a; rm -rf /") == nil)
    }
    check("wake: sleep/wake notifications can be registered", SleepWatcher().start())
    check("relay: a message event is read", PhoneListener.message(#"{"id":"a","time":1790000000,"event":"message","message":" status "}"#)?.text == "status")
    check("relay: keepalives and open events are ignored", PhoneListener.message(#"{"id":"a","time":1,"event":"keepalive"}"#) == nil
          && PhoneListener.message(#"{"id":"a","time":1,"event":"open"}"#) == nil && PhoneListener.message("garbage") == nil)
    check("permissions: camera states", Permissions.cameraState(.authorized) == .granted && Permissions.cameraState(.notDetermined) == .notAsked
          && Permissions.cameraState(.denied) == .denied && Permissions.cameraState(.restricted) == .denied)
    check("permissions: calendar needs full access (write-only counts as refused)", Permissions.calendarState(.fullAccess) == .granted
          && Permissions.calendarState(.writeOnly) == .denied && Permissions.calendarState(.notDetermined) == .notAsked && Permissions.calendarState(.denied) == .denied)
    check("permissions: music apps, the worst answer counts", Permissions.automationState([]) == .granted && Permissions.automationState([0, -600]) == .granted
          && Permissions.automationState([0, -1744]) == .notAsked && Permissions.automationState([-1744, -1743]) == .denied)
    do {
        func st(_ m: [Permission: Permissions.State]) -> (Permission) -> Permissions.State { { m[$0] ?? .granted } }
        check("permissions: nothing listed when all is allowed", AppDelegate.permissionProblems(needed: [.accessibility], island: true, state: st([:])).isEmpty)
        check("permissions: a needed one that is missing is listed", AppDelegate.permissionProblems(needed: [.accessibility], island: false, state: st([.accessibility: .denied])) == [.accessibility])
        check("permissions: page permissions only when refused, only with the island",
              AppDelegate.permissionProblems(needed: [], island: true, state: st([.camera: .denied, .calendar: .notAsked, .files: .denied])) == [.camera, .files]
              && AppDelegate.permissionProblems(needed: [], island: false, state: st([.camera: .denied])).isEmpty)
    }
    if ClipboardTests.run() != 0 { failed += 1 }           // the clipboard history (its own PASS/FAIL lines; temp folders, fake Keychain)
    _ = NSApplication.shared
    if IslandCheck.run() != 0 { failed += 1 }              // the island as the live window holds it (its own PASS/FAIL lines)
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
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--permissions" {
    // The state of every permission for this app, without asking for any (Files: listing the folders is the only check, and it
    // makes macOS ask if it never did; given 3 s, else "notAsked (macOS is asking)"). Then the raw values behind them.
    _ = NSApplication.shared
    var probed = false
    Permissions.probe(files: true) { _ in probed = true }
    let until = Date().addingTimeInterval(3)
    while !probed && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    for p in Permission.allCases {
        print("\(p.rawValue):", p == .files && !probed ? "notAsked (macOS is asking)" : "\(Permissions.state(p))")
    }
    let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: 1 << 14,
                                callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil)
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    print("raw: AXIsProcessTrusted \(AXIsProcessTrusted()), post events \(CGPreflightPostEventAccess()), listen events (Input Monitoring) \(CGPreflightListenEventAccess()),",
          "HUD-key tap \(tap != nil ? "ok" : "refused"), camera \(AVCaptureDevice.authorizationStatus(for: .video).rawValue), calendar \(EKEventStore.authorizationStatus(for: .event).rawValue),",
          "music apps \(Permissions.runningMusicApps().map { "\($0)=\(Permissions.automation($0, ask: false))" })")
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--camera-test" {
    // The camera permission state of this app, and (if allowed) whether frames arrive. Never asks for the permission.
    let st = AVCaptureDevice.authorizationStatus(for: .video)
    print("camera authorization:", st.rawValue, "(0 not asked, 1 restricted, 2 denied, 3 allowed)")
    if st == .authorized {
        let session = AVCaptureSession(), out = AVCaptureVideoDataOutput()
        final class Counter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
            var frames = 0
            func captureOutput(_ o: AVCaptureOutput, didOutput b: CMSampleBuffer, from c: AVCaptureConnection) { frames += 1 }
        }
        let counter = Counter()
        if let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
            session.addInput(input)
            out.setSampleBufferDelegate(counter, queue: DispatchQueue(label: "camtest"))
            if session.canAddOutput(out) { session.addOutput(out) }
            session.startRunning()
            Thread.sleep(forTimeInterval: 3)
            session.stopRunning()
        }
        print("frames in 3 s:", counter.frames)
    }
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--presence-test" {
    // Does a presence nudge reset the system idle time? Prints the permission state and the idle time before and after.
    print("post-event access:", Presence.hasAccess, " accessibility:", AXIsProcessTrusted())
    Thread.sleep(forTimeInterval: 3)
    let before = System.idleSeconds
    let sent = Presence.nudge()
    Thread.sleep(forTimeInterval: 0.3)
    let after = System.idleSeconds
    print(String(format: "idle before %.1f s, nudge sent: %@, idle after %.1f s", before, sent ? "yes" : "no", after))
    print(sent && after < before ? "PASS  the nudge resets the idle time" : "FAIL  no effect (permission missing?)")
    exit(0)
}
/// The render tools fill a PanelModel with sample values, which writes some into the real settings: this puts back exactly what
/// was there (removing them instead wiped the user's own Stay active, HUD and timer choices).
private struct SavedSettings {
    static let keys = ["timerMinutes", "batteryThreshold", "batteryTurnsOff", "triggerAgents", "triggerApps", "hotkeys", "onUntil", "wakeForPhone", "island",
                       "stayActive", "stayActiveAlways", "stayActiveApps", "replaceHUD", "haptics", "alertDone", "alertInput", "alertFlash", "alertSpeak", "alertVoice",
                       "alertPerSession", "alertWhenPresent", "alertRepeatMinutes", "alertDuration", "alertSound", "language"]
    let values: [String: Any] = Dictionary(uniqueKeysWithValues: keys.compactMap { k in UserDefaults.standard.object(forKey: k).map { (k, $0) } })
    func restore() {
        for k in Self.keys { if let v = values[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        UserDefaults.standard.synchronize()
    }
}

/// Offscreen checks of the island exactly as the live window holds it: the real IslandView in a hosting view of the real window
/// frame (IslandController.windowFrame), so a canvas that ends up outside the window shows up as missing pixels.
private enum IslandCheck {
    static func render(_ im: IslandModel, _ pm: PanelModel, frame: NSRect) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: IslandView(model: im, m: pm, focus: im.focus, batteries: im.batteries, mic: im.mic, usage: im.usage))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: frame.size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels in a box (points, from the top left) that are clearly not black: (bright, pinkish).
    static func count(_ rep: NSBitmapImageRep, _ box: NSRect, pointWidth: CGFloat) -> (bright: Int, pink: Int) {
        let s = CGFloat(rep.pixelsWide) / pointWidth
        var bright = 0, pink = 0
        for y in max(0, Int(box.minY * s))..<min(rep.pixelsHigh, Int(box.maxY * s)) {
            for x in max(0, Int(box.minX * s))..<min(rep.pixelsWide, Int(box.maxX * s)) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.3 else { continue }
                if max(c.redComponent, c.greenComponent, c.blueComponent) > 0.35 { bright += 1 }
                if c.redComponent > 0.6 && c.redComponent - c.greenComponent > 0.2 { pink += 1 }
            }
        }
        return (bright, pink)
    }

    static func alpha(_ rep: NSBitmapImageRep, _ pt: CGPoint, pointWidth: CGFloat) -> CGFloat {
        let s = CGFloat(rep.pixelsWide) / pointWidth
        return rep.colorAt(x: min(rep.pixelsWide - 1, Int(pt.x * s)), y: min(rep.pixelsHigh - 1, Int(pt.y * s)))?.alphaComponent ?? 0
    }

    static func run() -> Int32 {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
        let saved = SavedSettings()
        defer { saved.restore() }                                  // the checks must not leave anything in the real settings
        UserDefaults.standard.set(false, forKey: "stayActive")     // the states below are the ones named, whatever the user has on
        let g = NotchGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 185, height: 32, centerX: 756, hasNotch: true)
        let closed = IslandController.windowFrame(g, open: false), opened = IslandController.windowFrame(g, open: true)
        check("island: the closed window holds both wings", closed.minX <= g.centerX - g.notchWidth / 2 - IslandModel.maxWing
              && closed.maxX >= g.centerX + g.notchWidth / 2 + IslandModel.maxWing)
        check("island: the window hangs from the top edge", closed.maxY == g.frame.maxY + Island.overscan && opened.maxY == g.frame.maxY + Island.overscan)
        // The bag's box in the closed window (from its top left): left of the notch, in the middle of the menu bar's height.
        let bagX = closed.width / 2 - g.notchWidth / 2 - Island.wing / 2, midY = Island.overscan + g.height / 2
        let bagBox = NSRect(x: bagX - 11, y: midY - 11, width: 22, height: 22)
        var offBright = 0
        for state in ["off", "on", "pink"] {
            let pm = PanelModel()
            pm.persistLanguage = false
            pm.on = state == "on"; pm.fillLevel = pm.on ? 1 : 0; pm.stayActive = state == "pink"; pm.pinkLevel = state == "pink" ? 1 : 0        // Stay active alone, with no chat app open
            let im = IslandModel()
            im.pm = pm; im.geometry = g                 // renderProgress nil: the live path, driven by `open` alone
            let rep = render(im, pm, frame: closed)
            let bag = count(rep, bagBox, pointWidth: closed.width)
            check("pink powder (\(state)): it heads for \(pm.pinkTarget)", pm.pinkTarget == (state == "pink" ? 1 : 0))
            check("island closed (\(state)): the bag is drawn left of the notch (\(bag.bright) px)", bag.bright > 20)
            if state == "off" { offBright = bag.bright }
            if state == "on" { check("island closed (on): the bag is full of powder (\(bag.bright) > \(offBright) px)", bag.bright > offBright) }
            if state == "pink" { check("island closed (Stay active only): the bag is pink (\(bag.pink) px)", bag.pink > 20) }
            check("island closed (\(state)): the notch is filled black", alpha(rep, CGPoint(x: closed.width / 2, y: midY), pointWidth: closed.width) > 0.9)
            let right = count(rep, NSRect(x: closed.width / 2 + g.notchWidth / 2 + 4, y: midY - 10, width: Island.wing - 8, height: 20), pointWidth: closed.width)
            check("island closed (\(state)): the right wing shows what is live only when something is (\(right.bright) px)", state != "off" ? right.bright > 10 : right.bright == 0)
        }
        // Open: the bag has become the Home tab, the page is there.
        let pm = PanelModel()
        pm.persistLanguage = false
        pm.on = true; pm.fillLevel = 1
        let im = IslandModel()
        im.pm = pm; im.geometry = g; im.open = true
        let rep = render(im, pm, frame: opened)
        let l = IslandLayout(notch: g.notchWidth, notchH: g.height)
        let cell: CGFloat = Island.tabs(external: Island.external).count >= 11 ? 28 : 31
        let homeX = opened.width / 2 - IslandLayout.openBody / 2 + 16 + cell / 2
        let home = count(rep, NSRect(x: homeX - 11, y: midY - 11, width: 22, height: 22), pointWidth: opened.width)
        check("island open: the Home tab is in the strip (\(home.bright) px)", home.bright > 20)
        let page = count(rep, NSRect(x: opened.width / 2 - IslandLayout.openBody / 2, y: l.top + g.height + 8, width: IslandLayout.openBody, height: 150), pointWidth: opened.width)
        check("island open: the page is drawn (\(page.bright) px)", page.bright > 300)
        return failed == 0 ? 0 : 1
    }
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--clipboard-test" {
    exit(ClipboardTests.run() == 0 ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--island-selfcheck" {
    _ = NSApplication.shared
    exit(IslandCheck.run())
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-island" {
    // Draws the island offscreen to a PNG: --open, --tab <id>, --lang <code>, --focus (a running focus), --mic, --agents.
    _ = NSApplication.shared
    let sampleSettings = SavedSettings()
    let args = CommandLine.arguments
    let pm = PanelModel()
    pm.persistLanguage = false
    pm.language = args.firstIndex(of: "--lang").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
    pm.on = !args.contains("--off"); pm.fillLevel = pm.on ? 1 : 0
    pm.ai = AIHooks.Status(tools: AIHooks.tools.enumerated().map { i, t in AIHooks.Entry(id: t.id, name: t.name, installed: i < 3, on: i < 2) }, codexNeedsTrust: false)
    if args.contains("--agents") {
        let t = Date().timeIntervalSince1970
        pm.board = [AgentEntry(id: "1", from: "Claude Code", project: "canonical-com", state: "working", since: t - 400),
                    AgentEntry(id: "2", from: "Codex", project: "PneuSuperStore", state: "waiting", since: t - 90)]
    }
    pm.timerMinutes = 120; pm.onUntil = Date().addingTimeInterval(7000)
    if args.contains("--presence") { pm.presenceActive = true; pm.pinkLevel = 1 }
    if let i = args.firstIndex(of: "--pink-level"), i + 1 < args.count, let v = Double(args[i + 1]) { pm.pinkLevel = CGFloat(v); pm.pinkPouring = v < 1 }        // a frame of the pink powder filling
    let im = IslandModel()
    im.pm = pm
    im.geometry = NotchGeometry(frame: .zero, notchWidth: 185, height: 32, centerX: 0, hasNotch: true)
    im.open = args.contains("--open")
    if let i = args.firstIndex(of: "--tab"), i + 1 < args.count { im.tab = args[i + 1] }
    if args.contains("--focus") { im.focus.start() }
    if args.contains("--mic") { im.mic.active = true }
    im.batteries.items = [BatteryItem(id: "mac", name: "MacBook Pro", icon: "laptopcomputer", parts: [("", 80)], charging: true),
                          BatteryItem(id: "a", name: "AirPods Pro", icon: "airpodspro", parts: [("L", 71), ("R", 64), ("↳", 90)]),
                          BatteryItem(id: "k", name: "Magic Keyboard", icon: "keyboard", parts: [("", 22)])]
    im.usage.codex = [UsageWatch.Limit(id: "w", name: L("Week"), percent: 5, resets: Date().addingTimeInterval(86400 * 5))]
    im.files.downloads = [FileShelf.Item(url: URL(fileURLWithPath: "/Applications/Cocaine.app"), date: Date(), size: 5_200_000),
                          FileShelf.Item(url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), date: Date(), size: 120_000_000)]
    im.files.shots = (0..<5).map { FileShelf.Item(url: URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic").deletingLastPathComponent().appendingPathComponent("shot\($0).png"), date: Date(), size: 1) }
    im.clipboard.replace([ClipItem.text("brew upgrade --cask cocaine"), {
                              var f = ClipItem.files(["/System/Library/CoreServices/Finder.app"]); f.pinned = true; return f }(),
                          ClipItem.text("https://github.com/Mattiakart/cocaine"), ClipItem.text("Ciao Mario, ti mando il file domani mattina"),
                          ClipItem.files(["/tmp/cocaine-no-such-file.pdf"])])
    im.music.setSample(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
    if args.contains("--shelf") { im.shelf.urls = [URL(fileURLWithPath: "/Applications/Cocaine.app"), URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")] }
    im.usage.claudeFive = 412_000; im.usage.claudeWeek = 8_600_000; im.usage.loaded = true
    // The morph: --progress 0.3 (or a list, 0,0.15,0.3…, drawn one under the other) draws those moments of opening; closing runs
    // the same frames backwards. --flash "text" / --level 0.6 shows a flash message, --pink the pink bag, --external the Monitors tab,
    // --notch covers the notch like the hardware does (what you really see), --xray shows it in translucent red instead.
    let progress = args.firstIndex(of: "--progress").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }?
        .split(separator: ",").compactMap { Double($0).map { CGFloat($0) } }
    if let i = args.firstIndex(of: "--flash"), i + 1 < args.count {
        let level = args.firstIndex(of: "--level").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
        im.flash = (level == nil ? "arrow.down.circle.fill" : "speaker.wave.2.fill", args[i + 1], level)
    }
    if args.contains("--pink") { pm.on = false; pm.fillLevel = 0; pm.presenceActive = true; pm.pinkLevel = 1 }        // Stay active alone: the pink bag
    Island.forceExternal = args.contains("--external")
    if args.contains("--live-window") {
        // What the real window shows: the IslandView alone in a hosting view of the live window's size (closed: 465×38 on a
        // 185 pt notch), not the roomy canvas above. --island-selfcheck runs the same thing and checks the pixels.
        let g = NotchGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 185, height: 32, centerX: 756, hasNotch: true)
        im.geometry = g
        if let p = progress?.first { im.renderProgress = p; im.open = p > 0 }
        let rep = IslandCheck.render(im, pm, frame: IslandController.windowFrame(g, open: im.open))
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
        sampleSettings.restore()
        exit(0)
    }
    let notch = args.contains("--notch") ? Color.black : args.contains("--xray") ? Color.red.opacity(0.45) : nil
    func frame(_ p: CGFloat?) -> NSBitmapImageRep {
        if let p { im.renderProgress = p; im.open = p > 0 }
        let l = IslandLayout(notch: 185, notchH: 32)
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.55, green: 0.7, blue: 0.9), Color(red: 0.8, green: 0.6, blue: 0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
            IslandView(model: im, m: pm, focus: im.focus, batteries: im.batteries, mic: im.mic, usage: im.usage)
            if let notch {
                IslandOutline(pose: IslandPose(p: 0, leftW: 0, rightW: 0), layout: l).fill(notch).frame(width: l.size.width, height: l.size.height)
            }
        }.frame(width: 760, height: im.open || progress != nil ? 250 : 70, alignment: .top).clipped()
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
    var reps = progress.map { $0.map { frame($0) } } ?? [frame(nil)]
    if reps.count > 1 {                     // a contact sheet, labelled with each frame's progress
        let w = reps[0].size.width, h = reps[0].size.height, sheet = NSImage(size: NSSize(width: w, height: h * CGFloat(reps.count)))
        sheet.lockFocus()
        for (i, r) in reps.enumerated() {
            r.draw(in: NSRect(x: 0, y: h * CGFloat(reps.count - 1 - i), width: w, height: h))
            NSString(string: String(format: "p %.2f", progress![i])).draw(at: NSPoint(x: 8, y: h * CGFloat(reps.count - 1 - i) + 8),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.black])
        }
        sheet.unlockFocus()
        reps = [NSBitmapImageRep(data: sheet.tiffRepresentation!)!]
    }
    try? reps[0].representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
    sampleSettings.restore()
    exit(0)
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-panel" {
    // Draws the panel offscreen to a PNG, in the language picked by -AppleLanguages, to check translations fit.
    _ = NSApplication.shared
    let sampleSettings = SavedSettings()
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
    if CommandLine.arguments.contains("--ai-open") { model.page = "ai" }
    if CommandLine.arguments.contains("--last") {                  // a sample "Recent alerts" list
        model.history = [("Claude Code", "has finished", "Cocaine", 0.0), ("Codex", "needs your input", "PneuSuperStore", 900),
                         ("Cursor", "has finished", "Gestionale", 4000)]
            .map { AlertRecord(from: $0.0, message: L($0.1), project: $0.2, at: Date().addingTimeInterval(-$0.3)) }
    }
    if let i = CommandLine.arguments.firstIndex(of: "--auto"), i + 1 < CommandLine.arguments.count {   // open a group of Automation
        let wanted = CommandLine.arguments[i + 1]
        model.page = wanted == "none" || wanted == "timer" ? "" : (wanted == "ai" ? "ai" : "auto")
        model.triggerAgents = true; model.triggerApps = ["Xcode"]; model.timerMinutes = 120; model.batteryThreshold = 20
        model.phoneCount = CommandLine.arguments.contains("--no-phone") ? 0 : 1; model.phoneLinkUp = true; model.battery = "80%"
        model.phone = "Comando Rapido “Avvisa iPhone”"
    }
    if CommandLine.arguments.contains("--agents") {
        let t = Date().timeIntervalSince1970
        model.board = [AgentEntry(id: "1", from: "Claude Code", project: "canonical-com", state: "working", since: t - 400),
                       AgentEntry(id: "2", from: "Codex", project: "PneuSuperStore", state: "waiting", since: t - 90),
                       AgentEntry(id: "3", from: "Cursor", project: "Gestionale", state: "error", since: t - 30)]
    }
    if CommandLine.arguments.contains("--speak") {                  // the longest voice name: the widest thing a row can hold
        model.alertSpeak = true
        model.alertVoice = Voices.available.map(\.identifier).max { Voices.name($0).count < Voices.name($1).count } ?? ""
    }
    if CommandLine.arguments.contains("--longsound") { model.alertDuration = 0; model.alertRepeatMinutes = 10 }
    if let i = CommandLine.arguments.firstIndex(of: "--timer"), i + 1 < CommandLine.arguments.count { model.timerMinutes = Int(CommandLine.arguments[i + 1]) ?? 0 }
    let checkOverflow = CommandLine.arguments.contains("--overflow-check")
    let host = checkOverflow ? NSHostingView(rootView: PanelView(m: model).frame(width: Layout.width + 260, alignment: .topLeading))
                             : NSHostingView(rootView: PanelView(m: model).background(Color.black))
    let size = host.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    if CommandLine.arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
    if CommandLine.arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    if checkOverflow {      // the rightmost painted pixel must stay inside the 14 pt margin
        var maxX = 0
        outer: for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { maxX = x; break outer }
        }
        let right = CGFloat(maxX + 1) * host.bounds.width / CGFloat(rep.pixelsWide)
        let ok = right <= Layout.width - 14 + 0.5
        print("\(ok ? "PASS" : "FAIL")  rightmost painted \(String(format: "%.1f", right)) pt (limit \(Layout.width - 14))")
    }
    sampleSettings.restore()                                // the sample values above must not stay in the real settings
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
