// Alerts ("an AI finished / needs you"): voices, feedback and help, the alert flash and the Alerter.

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

// MARK: - Voices

/// The Mac's voices for reading alerts aloud, in the panel's language.
enum Voices {
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

enum Feedback {
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

/// Drives the overlay's animation (SwiftUI's @State needs full Xcode's macros, which the command-line tools lack). The model is
/// two values: the card is shown, and how many times the flashes were asked for (the keyframes run on each new count, so a
/// second alert restarts them cleanly instead of overlapping delayed steps).
private final class AlertAnimation: ObservableObject {
    @Published var shown = false
    @Published var flashes = 0

    func start() {
        Motion.with(.appear) { shown = true }
        flashes += 1                                                     // two flashes (one soft tint with Reduce Motion)
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
            Color.white.keyframeAnimator(initialValue: 0.0, trigger: anim.flashes) { c, v in c.opacity(Motion.disabled ? 0 : v) } keyframes: { _ in
                let steps = Motion.flashSteps(reduce: Motion.reduce)
                let step = { (i: Int) in i < steps.count ? steps[i] : (value: 0.0, duration: 0.001) }
                CubicKeyframe(step(0).value, duration: step(0).duration)
                CubicKeyframe(step(1).value, duration: step(1).duration)
                CubicKeyframe(step(2).value, duration: step(2).duration)
                CubicKeyframe(step(3).value, duration: step(3).duration)
            }
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
            .modifier(MotionEnter(t: anim.shown ? 0 : 1, edge: nil, anchor: .center, reduce: Motion.reduce))
        }
        .ignoresSafeArea()
    }
}

final class Alerter {
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
            ctx.duration = Motion.disabled ? 0 : Motion.Duration.slow
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { closing.forEach { $0.orderOut(nil) } })
    }
}

// MARK: - Sounds per event, a sound file of your own, quiet hours

extension Settings {
    /// A sound per kind of alert: "" = the general Sound, "none" = silent, a system sound's name, or the path of a sound file
    /// the user picked (referenced where it is, never copied).
    func eventSound(_ kind: String) -> String { d.string(forKey: "sound." + kind) ?? "" }
    func setEventSound(_ kind: String, _ v: String) { d.set(v, forKey: "sound." + kind) }
    /// Quiet hours: no sound and no voice between these minutes of the day (an alert still shows and is kept in the list).
    var quietHours: Bool { get { flag("quietHours", false) } nonmutating set { d.set(newValue, forKey: "quietHours") } }
    var quietStart: Int { get { d.object(forKey: "quietStart") as? Int ?? 22 * 60 } nonmutating set { d.set(newValue, forKey: "quietStart") } }
    var quietEnd: Int { get { d.object(forKey: "quietEnd") as? Int ?? 8 * 60 } nonmutating set { d.set(newValue, forKey: "quietEnd") } }
}

enum AlertSounds {
    static let kinds = ["done", "input", "error"]
    static let fileTypes: Set<String> = ["aiff", "aif", "wav", "mp3", "m4a", "caf"]
    static let maxFileSize = 20 << 20

    /// A sound file the user picked that can be played: a regular file of a sound type, not too big.
    static func validFile(_ path: String) -> Bool {
        guard path.hasPrefix("/"), fileTypes.contains((path as NSString).pathExtension.lowercased()),
              let a = try? FileManager.default.attributesOfItem(atPath: path), a[.type] as? FileAttributeType == .typeRegular,
              (a[.size] as? Int ?? .max) <= maxFileSize else { return false }
        return true
    }

    /// What plays for an alert of this kind: its own choice, else the general one; nil = silence.
    static func resolve(kind: String, own: String, general: String) -> String? {
        let pick = own.isEmpty ? general : own
        if pick.isEmpty || pick == "none" { return nil }
        if pick.hasPrefix("/") { return validFile(pick) ? pick : general.isEmpty || general.hasPrefix("/") ? nil : general }
        return pick
    }

    /// Inside quiet hours now? (A span that crosses midnight, 22:00–08:00, works; equal ends mean all day.)
    static func isQuiet(on: Bool, start: Int, end: Int, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard on else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if start == end { return true }
        return start < end ? (m >= start && m < end) : (m >= start || m < end)
    }

    private static var playing: NSSound?
    static func play(_ id: String) {
        playing?.stop()
        let s = id.hasPrefix("/") ? NSSound(contentsOfFile: id, byReference: true) : NSSound(named: id)
        playing = s
        s?.play()
    }

    /// The name shown for a choice.
    static func title(_ id: String) -> String {
        switch id {
        case "": return L("Same as Sound")
        case "none": return L("No sound")
        default: return id.hasPrefix("/") ? (id as NSString).lastPathComponent : id
        }
    }
}

/// The AI settings added with the plan review and the limits, for the panel (one observable object, so PanelModel stays as it is).
final class AgentPrefs: ObservableObject {
    static let shared = AgentPrefs()
    private let s = Settings()

    @Published var preview: Bool { didSet { s.agentPreview = preview } }
    @Published var sounds: [String: String] { didSet { for (k, v) in sounds where s.eventSound(k) != v { s.setEventSound(k, v) } } }
    @Published var quietHours: Bool { didSet { s.quietHours = quietHours } }
    @Published var quietStart: Int { didSet { s.quietStart = quietStart } }
    @Published var quietEnd: Int { didSet { s.quietEnd = quietEnd } }
    /// The statusline wrapper for Claude's plan limits (Quotas.swift): read from Claude Code's settings, changed there.
    @Published private(set) var limits = false
    @Published private(set) var limitsBusy = false
    @Published var limitsError: String?
    @Published private(set) var jumpRules: JumpRules.Status = JumpRules.Status()

    private init() {
        let st = Settings()
        preview = st.agentPreview
        sounds = Dictionary(uniqueKeysWithValues: AlertSounds.kinds.map { ($0, st.eventSound($0)) })
        quietHours = st.quietHours; quietStart = st.quietStart; quietEnd = st.quietEnd
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let on = StatusLineHook.isOn()
            let rules = JumpRules.status()
            DispatchQueue.main.async { self.limits = on; self.jumpRules = rules }
        }
    }

    func setLimits(_ on: Bool) {
        guard !limitsBusy else { return }
        limitsBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = StatusLineHook.set(on)
            let now = StatusLineHook.isOn()
            DispatchQueue.main.async {
                self.limitsBusy = false
                self.limits = now
                self.limitsError = ok ? nil : (AIHooks.binary == nil ? L("Only from the app in Applications") : L("Couldn't change ~/.claude/settings.json"))
            }
        }
    }

    /// The picker's choices for one kind: the general sound, none, the system ones, the file picked, "Choose a file…".
    func soundSpec(_ kind: String, title: String) -> PickerSpec {
        var items = [PickerItem(id: "", title: L("Same as Sound"), symbol: "arrow.uturn.backward"),
                     PickerItem(id: "none", title: L("No sound"), symbol: "speaker.slash")]
            + Settings.sounds.map { PickerItem(id: $0, title: $0, symbol: "speaker.wave.2") }
        if let cur = sounds[kind], cur.hasPrefix("/") { items.append(PickerItem(id: cur, title: AlertSounds.title(cur), symbol: "music.note")) }
        items.append(PickerItem(id: "choose", title: L("Choose a sound file…"), symbol: "folder", section: 1))
        return PickerSpec(id: "sound." + kind, title: title, items: items, mode: .single(sounds[kind] ?? ""))
    }

    func pickSound(_ kind: String, _ id: String) {
        guard id == "choose" else {
            sounds[kind] = id
            if let play = AlertSounds.resolve(kind: kind, own: id, general: s.alertSound) { AlertSounds.play(play) }   // hear it
            return
        }
        let panel = NSOpenPanel()                    // the system's own file chooser is the point here
        panel.allowedContentTypes = AlertSounds.fileTypes.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("A sound file: it is played from where it is, never copied")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, AlertSounds.validFile(url.path) else { return }
        sounds[kind] = url.path
        AlertSounds.play(url.path)
    }

    /// What plays for an alert of `kind` now: nil in quiet hours or when silent.
    func soundNow(_ kind: String, now: Date = Date()) -> String? {
        if AlertSounds.isQuiet(on: quietHours, start: quietStart, end: quietEnd, now: now) { return nil }
        return AlertSounds.resolve(kind: kind, own: sounds[kind] ?? "", general: s.alertSound)
    }

    var quietNow: Bool { AlertSounds.isQuiet(on: quietHours, start: quietStart, end: quietEnd, now: Date()) }
}

// MARK: - Tests (part of --agents-test)

enum AlertSoundTests {
    static func run(_ check: (String, Bool) -> Void) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        func at(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: h, minute: m))! }
        check("sounds: quiet hours across midnight (22:00–08:00)", AlertSounds.isQuiet(on: true, start: 1320, end: 480, now: at(23, 30), calendar: cal)
              && AlertSounds.isQuiet(on: true, start: 1320, end: 480, now: at(7, 59), calendar: cal)
              && !AlertSounds.isQuiet(on: true, start: 1320, end: 480, now: at(8, 0), calendar: cal)
              && !AlertSounds.isQuiet(on: true, start: 1320, end: 480, now: at(12, 0), calendar: cal))
        check("sounds: quiet hours within a day, and off means never", AlertSounds.isQuiet(on: true, start: 780, end: 840, now: at(13, 30), calendar: cal)
              && !AlertSounds.isQuiet(on: true, start: 780, end: 840, now: at(14, 0), calendar: cal)
              && !AlertSounds.isQuiet(on: false, start: 0, end: 0, now: at(1, 0), calendar: cal))
        check("sounds: per event, else the general one; none is silent",
              AlertSounds.resolve(kind: "done", own: "", general: "Glass") == "Glass" && AlertSounds.resolve(kind: "done", own: "Ping", general: "Glass") == "Ping"
              && AlertSounds.resolve(kind: "done", own: "none", general: "Glass") == nil && AlertSounds.resolve(kind: "done", own: "", general: "") == nil)
        let dir = AgentTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = dir.appendingPathComponent("ding.wav"), bad = dir.appendingPathComponent("evil.app"), gone = dir.appendingPathComponent("gone.mp3")
        try? Data(repeating: 0, count: 64).write(to: ok); try? Data(repeating: 0, count: 64).write(to: bad)
        check("sounds: a picked file is used where it is, if it is a sound file that exists",
              AlertSounds.resolve(kind: "error", own: ok.path, general: "Glass") == ok.path
              && AlertSounds.resolve(kind: "error", own: bad.path, general: "Glass") == "Glass"
              && AlertSounds.resolve(kind: "error", own: gone.path, general: "Glass") == "Glass"
              && !AlertSounds.validFile(dir.path) && !AlertSounds.validFile("relative.wav"))
    }
}
