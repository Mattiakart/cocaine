// Core: logging, the UI language and L(), running the engine, system state, haptics, settings.

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

let log = Logger(subsystem: "local.cocaine.toggle", category: "app")
/// The engine: the bundle's, or the copy in Application Support once the bundle is gone (Sources/Recovery.swift).
var scriptPath: String { Recovery.enginePath }
private let anyInput = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType

/// The UI language: the Mac's (the default; English when it isn't one of ours) or one picked in the panel.
enum Language {
    static let codes = ["en", "it", "zh-Hans", "zh-Hant", "es", "fr", "de", "ja"]
    private static var bundle = makeBundle(AppDefaults.store.string(forKey: "language"))
    /// The language in use now (nil = the Mac's), also when it isn't saved (the render tools).
    private static var active = AppDefaults.store.string(forKey: "language")

    /// nil = same as the Mac.
    static var chosen: String? { AppDefaults.store.string(forKey: "language") }

    static func set(_ code: String?, persist: Bool = true) {
        if persist {
            if let code { AppDefaults.store.set(code, forKey: "language") }
            else { AppDefaults.store.removeObject(forKey: "language") }
        }
        bundle = makeBundle(code)
        active = code
    }

    /// Dates, times, numbers and sizes in the app's language (with the Mac's region, so a 24-hour Mac keeps its clock):
    /// never Italian month names in an English panel because the Mac is set to Italian.
    static var locale: Locale {
        let code = active ?? system
        if active == nil, Locale.current.language.languageCode?.identifier == Locale(identifier: code).language.languageCode?.identifier {
            return Locale.current
        }
        return Locale(identifier: code + (Locale.current.region.map { "_" + $0.identifier } ?? ""))
    }

    /// A calendar in that locale (weekday names, the first day of the week stays the Mac's).
    static var calendar: Calendar { var c = Calendar.autoupdatingCurrent; c.locale = locale; return c }

    private static func makeBundle(_ code: String?) -> Bundle {
        guard let code, let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path)
        else { return .main }                        // .main follows the Mac's languages, English as fallback
        return b
    }

    /// Flag shown on the language button (Traditional Chinese: the globe; the menu names each language).
    static func flag(_ code: String) -> String {
        ["en": "🇬🇧", "it": "🇮🇹", "zh-Hans": "🇨🇳", "zh-Hant": "🌐", "es": "🇪🇸", "fr": "🇫🇷", "de": "🇩🇪", "ja": "🇯🇵"][code] ?? "🌐"
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
    static let extraTables = ["Remote", "Agents", "Power", "Clipboard", "Updates", "Recovery", "Dialogs", "Design", "Keys", "Screens", "Calendar", "Paste"]

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
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

/// UI text in the current language (Localization/*.lproj).
func L(_ key: String) -> String { Language.text(key) }
/// L() under the name Sources/Agent*.swift use.
func agentsL(_ key: String) -> String { L(key) }
/// The app's language as a Locale, for formatters in Sources/.
func appLocale() -> Locale { Language.locale }
/// The same lookup for the updater and signature code in Sources/.
func updatesText(_ key: String) -> String { Language.text(key) }

/// Runs a program and returns its exit status (-1: it couldn't start, or ran past `timeout` and was stopped). See Proc.
@discardableResult
func run(_ path: String, _ args: [String], timeout: TimeInterval = 120) -> Int32 { Proc.run(path, args, timeout: timeout).status }

/// Runs the bundled engine (`on`, `off`, …) and returns its exit status: 0 ok, 2 not authorized yet.
@discardableResult
func engine(_ arg: String) -> Int32 { run("/bin/zsh", [scriptPath, arg]) }

// MARK: - System state

enum System {
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
    /// The engine's display-hold helper runs: it holds hold.lock (an fcntl lock) for its whole life, whichever copy of the
    /// engine started it. A lock test, no process spawned (this runs every few seconds).
    static var displayHeld: Bool { holdLockOwner() != nil }

    /// The pid holding `$SUPPORT/hold.lock`, if any (F_GETLK reports it without taking the lock).
    static func holdLockOwner(_ path: String = Recovery.directory + "/hold.lock") -> pid_t? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var fl = flock()
        fl.l_type = Int16(F_WRLCK); fl.l_whence = Int16(SEEK_SET); fl.l_start = 0; fl.l_len = 0
        guard fcntl(fd, F_GETLK, &fl) == 0, fl.l_type != Int16(F_UNLCK) else { return nil }
        return fl.l_pid
    }
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

// MARK: - Haptic feedback

/// Where a haptic tap goes: the trackpad in the app, a counter in the tests.
protocol HapticSink: AnyObject {
    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern)
}

/// The Force Touch trackpad (nothing happens on a mouse).
final class TrackpadHaptics: HapticSink {
    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

/// A light tap on the trackpad (Force Touch) when you change something; nothing on a mouse. Can be turned off in the panel.
///
/// One feedback per action, never two (the "double tap" of 2.5.0 had two causes):
/// - A click on a Force Touch trackpad is itself a tap: the trackpad has no real switch, its Taptic Engine plays the click.
///   A tap of ours on top of it, in the button's action a few milliseconds later, was felt as a second click. So a tap asked for
///   while a pointer click is being handled is not played (`clickInProgress`): that click already said it. Taps that come with
///   no click (dragging the ruler or a slider onto a magnet, two-finger scroll steps, the island opening under the pointer, the
///   keyboard) are played as before.
/// - Some actions tapped twice in code (the time stepper's scroll steps: once in ScrollSteps, once in its step function; the
///   strip's back button: once in the button, once when the island reopened). Each control kind now taps in one place, and
///   `tap` drops the same pattern asked for again within `coalesce` seconds as a safety net.
enum Haptic {
    static var enabled: Bool { AppDefaults.store.object(forKey: "haptics") as? Bool ?? true }
    /// Replaced in the tests by a counter.
    static var sink: HapticSink = TrackpadHaptics()
    static var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Is a pointer click (mouse or trackpad button, down or up) being handled right now? The tests set it.
    static var clickInProgress: () -> Bool = { Haptic.isClick(NSApp?.currentEvent, now: ProcessInfo.processInfo.systemUptime) }
    static let coalesce: TimeInterval = 0.06
    private static var last: (pattern: Int, at: TimeInterval)?

    /// A click event handled within the last moment (NSApp.currentEvent stays the last event after it is handled: its age counts).
    static func isClick(_ e: NSEvent?, now: TimeInterval) -> Bool {
        guard let e else { return false }
        let clicks: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .pressure]
        return clicks.contains(e.type) && now - e.timestamp < 0.25
    }

    static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard enabled, !clickInProgress() else { return }
        play(pattern)
    }

    /// Plays it unless the same pattern was just played (the coalescing safety net).
    private static func play(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        let now = clock()
        if let l = last, l.pattern == pattern.rawValue, now - l.at < coalesce { return }
        last = (pattern.rawValue, now)
        sink.perform(pattern)
    }

    /// Three quick taps: something finished (a timer; never during a click, and spaced well apart from coalescing).
    static func finished() {
        for i in 0..<3 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.14) { if enabled { play(.levelChange) } } }
    }

    /// The tests: forget the last tap.
    static func resetForTests() { last = nil }
}

// MARK: - Settings

/// The one place the app's settings live. The app uses its preferences domain (UserDefaults.standard, local.cocaine.toggle);
/// every test and render flag points it at memory first (main.swift), so a test never writes, and a crash in the middle of
/// one never leaves, a value in the domain the running app reads every few seconds. Everything that keeps an app setting
/// (Settings, Language, Haptic, the updater, the island's options, the phone, the clipboard) goes through `store`.
enum AppDefaults {
    private(set) static var store: UserDefaults = .standard
    private(set) static var isolated = false

    /// Flags that act for real (hooks run by AI tools, the watchdog, Homebrew, release tooling) keep the real store; every
    /// other `--…` flag is a test or a render and gets memory-only settings.
    static let realFlags: Set<String> = ["--agent-request", "--ai-alerts", "--recover-after", "--recover-hud", "--prepare-update",
                                         "--uninstall-cleanup", "--boot-check", "--remove-rule"]

    static func isolateIfTestFlag(_ args: [String]) {
        guard args.count >= 2, args[1].hasPrefix("--"), !realFlags.contains(args[1]) else { return }
        isolate()
    }

    static func isolate(_ d: UserDefaults = MemoryDefaults()) { store = d; isolated = true }
}

/// UserDefaults that live in memory only: nothing is read from or written to a preferences domain. Every accessor is
/// overridden, so none can fall through to the real domain.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    init() { super.init(suiteName: nil)! }
    override func object(forKey k: String) -> Any? { values[k] ?? registered[k] }
    override func set(_ v: Any?, forKey k: String) { values[k] = v }
    override func removeObject(forKey k: String) { values[k] = nil }
    override func register(defaults: [String: Any]) { registered.merge(defaults) { $1 } }
    override func string(forKey k: String) -> String? { object(forKey: k) as? String }
    override func array(forKey k: String) -> [Any]? { object(forKey: k) as? [Any] }
    override func dictionary(forKey k: String) -> [String: Any]? { object(forKey: k) as? [String: Any] }
    override func data(forKey k: String) -> Data? { object(forKey: k) as? Data }
    override func stringArray(forKey k: String) -> [String]? { object(forKey: k) as? [String] }
    override func integer(forKey k: String) -> Int { (object(forKey: k) as? NSNumber)?.intValue ?? Int((object(forKey: k) as? String) ?? "") ?? 0 }
    override func float(forKey k: String) -> Float { (object(forKey: k) as? NSNumber)?.floatValue ?? Float((object(forKey: k) as? String) ?? "") ?? 0 }
    override func double(forKey k: String) -> Double { (object(forKey: k) as? NSNumber)?.doubleValue ?? Double((object(forKey: k) as? String) ?? "") ?? 0 }
    override func bool(forKey k: String) -> Bool { (object(forKey: k) as? NSNumber)?.boolValue ?? ["yes", "true", "1"].contains((object(forKey: k) as? String)?.lowercased() ?? "") }
    override func url(forKey k: String) -> URL? { object(forKey: k) as? URL ?? (object(forKey: k) as? String).map { URL(fileURLWithPath: $0) } }
    override func set(_ v: Int, forKey k: String) { values[k] = v }
    override func set(_ v: Float, forKey k: String) { values[k] = v }
    override func set(_ v: Double, forKey k: String) { values[k] = v }
    override func set(_ v: Bool, forKey k: String) { values[k] = v }
    override func set(_ v: URL?, forKey k: String) { values[k] = v }
    override func dictionaryRepresentation() -> [String: Any] { registered.merging(values) { $1 } }
    override func synchronize() -> Bool { true }
    override func removePersistentDomain(forName domainName: String) {}
    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {}
}

/// One alert, for the "Recent alerts" list.
struct AlertRecord: Codable, Identifiable, Equatable {
    let from: String
    let message: String
    let project: String?
    let at: Date
    var session: String? = nil          // the board's key and where it ran: a click goes back there
    var origin: AgentOrigin? = nil
    var id: Date { at }
}

struct Settings {
    var d: UserDefaults { AppDefaults.store }
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
    func flag(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
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
