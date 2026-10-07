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
let scriptPath = Bundle.main.path(forResource: "cocaine", ofType: nil) ?? "/nonexistent/cocaine"
private let anyInput = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType

/// The UI language: the Mac's (the default; English when it isn't one of ours) or one picked in the panel.
enum Language {
    static let codes = ["en", "it", "zh-Hans", "zh-Hant", "es", "fr", "de", "ja"]
    private static var bundle = makeBundle(UserDefaults.standard.string(forKey: "language"))
    /// The language in use now (nil = the Mac's), also when it isn't saved (the render tools).
    private static var active = UserDefaults.standard.string(forKey: "language")

    /// nil = same as the Mac.
    static var chosen: String? { UserDefaults.standard.string(forKey: "language") }

    static func set(_ code: String?, persist: Bool = true) {
        if persist {
            if let code { UserDefaults.standard.set(code, forKey: "language") }
            else { UserDefaults.standard.removeObject(forKey: "language") }
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
    static let extraTables = ["Remote", "Agents", "Power", "Clipboard", "Updates", "Recovery", "Dialogs", "Design"]

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

@discardableResult
func run(_ path: String, _ args: [String]) -> Int32 {
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

// MARK: - Haptic feedback

/// A light tap on the trackpad (Force Touch) when you change something; nothing on a mouse. Can be turned off in the panel.
enum Haptic {
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
    let d = UserDefaults.standard
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
