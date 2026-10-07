// Customisable global shortcuts: the actions and their keys (Shortcut), the rules a new key must pass (ShortcutRules), how keys are
// named on this Mac's keyboard layout (ShortcutNames), registration with Carbon's RegisterEventHotKey, which needs no privacy
// permission (ShortcutRegistrar, its register function injected so tests can fake it), the settings (ShortcutStore) and the
// recorder the panel uses (ShortcutCenter, ShortcutRecorderButton). Strings: Localization/<lang>.lproj/Keys.strings.

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What a global shortcut can do.
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case toggle, panel, pause, island
    var id: String { rawValue }

    /// Carbon's hot-key id (1–3 as the fixed shortcuts had).
    var hotKeyID: UInt32 { UInt32((Self.allCases.firstIndex(of: self) ?? 0) + 1) }
    static func from(hotKeyID: UInt32) -> ShortcutAction? { allCases.first { $0.hotKeyID == hotKeyID } }

    var title: String {
        switch self {
        case .toggle: return L("Turn Cocaine on or off")
        case .panel: return L("Open the panel")
        case .pause: return L("Pause or resume alerts")
        case .island: return L("Open the island with the keyboard")
        }
    }

    /// ⌃⌥⌘C, ⌃⌥⌘O, ⌃⌥⌘P (the fixed shortcuts of 2.4 and before) and ⌃⌥⌘I. Key codes are positions on the keyboard: on other
    /// layouts the name shown is whatever that key types there (ShortcutNames).
    var defaultShortcut: Shortcut {
        switch self {
        case .toggle: return Shortcut(keyCode: UInt32(kVK_ANSI_C), mods: Shortcut.hyper)
        case .panel: return Shortcut(keyCode: UInt32(kVK_ANSI_O), mods: Shortcut.hyper)
        case .pause: return Shortcut(keyCode: UInt32(kVK_ANSI_P), mods: Shortcut.hyper)
        case .island: return Shortcut(keyCode: UInt32(kVK_ANSI_I), mods: Shortcut.hyper)
        }
    }
}

/// A key and its modifiers, in Carbon's terms (cmdKey, optionKey, controlKey, shiftKey).
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var mods: UInt32

    static let cmd = UInt32(cmdKey), opt = UInt32(optionKey), ctrl = UInt32(controlKey), shift = UInt32(shiftKey)
    static let hyper = ctrl | opt | cmd
    static let modifierMask = cmd | opt | ctrl | shift

    init(keyCode: UInt32, mods: UInt32) { self.keyCode = keyCode; self.mods = mods & Self.modifierMask }

    /// From a key press (NSEvent's modifier flags).
    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= Self.cmd }
        if flags.contains(.option) { m |= Self.opt }
        if flags.contains(.control) { m |= Self.ctrl }
        if flags.contains(.shift) { m |= Self.shift }
        self.init(keyCode: UInt32(keyCode), mods: m)
    }

    var glyphs: String { ShortcutNames.glyphs(self) }
    var spoken: String { ShortcutNames.spoken(self) }
}

// MARK: - Rules

enum ShortcutProblem: Equatable {
    case needsModifier            // a plain letter would fire while typing anywhere
    case shiftOnly                // ⇧ alone isn't enough either
    case reserved                 // macOS or every app uses it (⌘Q, ⌘Tab, screenshots…)
    case system                   // an enabled shortcut in System Settings → Keyboard → Keyboard Shortcuts
    case duplicate(ShortcutAction)
    case voiceOver                // ⌃⌥ without ⌘: VoiceOver's own keys (allowed, with a warning)

    /// A warning only: the shortcut is saved.
    var blocking: Bool { self != .voiceOver }

    var text: String {
        switch self {
        case .needsModifier: return L("Add ⌘, ⌃ or ⌥ (a plain key would fire while you type)")
        case .shiftOnly: return L("⇧ alone isn't enough: add ⌘, ⌃ or ⌥")
        case .reserved: return L("macOS uses this one")
        case .system: return L("A macOS shortcut already uses this (System Settings → Keyboard)")
        case .duplicate(let a): return String(format: L("Already used for “%@”"), a.title)
        case .voiceOver: return L("⌃⌥ is VoiceOver's key: it may not reach Cocaine while VoiceOver runs")
        }
    }
}

enum ShortcutRules {
    /// F1–F20: these may go without a modifier.
    static let functionKeys: Set<UInt32> = Set([kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                                                 kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].map { UInt32($0) })

    /// Shortcuts macOS (or every app) keeps for itself.
    static let reserved: Set<Shortcut> = {
        let c = Shortcut.cmd, o = Shortcut.opt, k = Shortcut.ctrl, s = Shortcut.shift
        var r: [Shortcut] = [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M, kVK_Tab, kVK_ANSI_Grave, kVK_Space].map { Shortcut(keyCode: UInt32($0), mods: c) }
        r += [Shortcut(keyCode: UInt32(kVK_Space), mods: k), Shortcut(keyCode: UInt32(kVK_Space), mods: k | c),
              Shortcut(keyCode: UInt32(kVK_ANSI_Q), mods: k | c), Shortcut(keyCode: UInt32(kVK_ANSI_F), mods: k | c),
              Shortcut(keyCode: UInt32(kVK_Escape), mods: o | c), Shortcut(keyCode: UInt32(kVK_ANSI_D), mods: o | c),
              Shortcut(keyCode: UInt32(kVK_Tab), mods: c | s)]
        r += [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6].map { Shortcut(keyCode: UInt32($0), mods: c | s) }
        r += [kVK_ANSI_3, kVK_ANSI_4].map { Shortcut(keyCode: UInt32($0), mods: c | s | k) }
        r += [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].map { Shortcut(keyCode: UInt32($0), mods: k) }
        return Set(r)
    }()

    /// The first thing wrong with `s` for `action`, or nil. `others`: the other actions' shortcuts; `system`: the enabled
    /// shortcuts of System Settings (systemShortcuts()).
    static func problem(_ s: Shortcut, for action: ShortcutAction, others: [ShortcutAction: Shortcut], system: Set<Shortcut>) -> ShortcutProblem? {
        let strong = s.mods & (Shortcut.cmd | Shortcut.ctrl | Shortcut.opt)
        if strong == 0 && !functionKeys.contains(s.keyCode) { return s.mods & Shortcut.shift != 0 ? .shiftOnly : .needsModifier }
        if reserved.contains(s) { return .reserved }
        if system.contains(s) { return .system }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && others[$0] == s }) { return .duplicate(other) }
        if s.mods & (Shortcut.ctrl | Shortcut.opt) == Shortcut.ctrl | Shortcut.opt && s.mods & Shortcut.cmd == 0 { return .voiceOver }
        return nil
    }

    /// The enabled shortcuts in System Settings → Keyboard → Keyboard Shortcuts (Mission Control, Spotlight, screenshots…).
    static func systemShortcuts() -> Set<Shortcut> {
        var raw: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&raw) == noErr, let list = raw?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(list.compactMap { d in
            guard (d["kHISymbolicHotKeyEnabled"] as? Bool) ?? ((d["kHISymbolicHotKeyEnabled"] as? Int) == 1),
                  let code = (d["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value, code < 0xFFFF,
                  let mods = (d["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { return nil }
            return Shortcut(keyCode: code, mods: mods)
        })
    }
}

// MARK: - Names

/// What a key is called on the keyboard layout in use: ⌃⌥⌘C on a US Mac, ⌃⌥⌘J for the same key with Dvorak.
enum ShortcutNames {
    /// keyCode → what the key types with no modifier, or nil.
    typealias Translate = (UInt32) -> String?

    /// The current layout's translation (refreshed when the input source changes: ShortcutCenter).
    static var translate: Translate = layout(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())

    static func refresh() { translate = layout(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()) }

    /// A layout by its input-source id ("com.apple.keylayout.Dvorak"), for the tests.
    static func layout(id: String) -> Translate? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource], let src = list.first else { return nil }
        return layout(src)
    }

    static func layout(_ source: TISInputSource?) -> Translate {
        // Input methods (Japanese, Chinese) have no key layout of their own: the ASCII-capable layout under them names the keys.
        var src = source
        if let s = src, TISGetInputSourceProperty(s, kTISPropertyUnicodeKeyLayoutData) == nil {
            src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        }
        guard let s = src, let ptr = TISGetInputSourceProperty(s, kTISPropertyUnicodeKeyLayoutData) else { return { _ in nil } }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return { code in
            data.withUnsafeBytes { raw -> String? in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                guard st == noErr, length > 0 else { return nil }
                let s = String(utf16CodeUnits: chars, count: length)
                return s.trimmingCharacters(in: .controlCharacters).isEmpty ? nil : s
            }
        }
    }

    /// Keys that don't type a character, by glyph or name.
    static func special(_ code: UInt32) -> (glyph: String, spoken: String)? {
        switch Int(code) {
        case kVK_Space: return (L("Space"), L("Space"))
        case kVK_Return: return ("↩", L("Return"))
        case kVK_ANSI_KeypadEnter: return ("⌤", L("Enter"))
        case kVK_Tab: return ("⇥", L("Tab"))
        case kVK_Delete: return ("⌫", L("Delete"))
        case kVK_ForwardDelete: return ("⌦", L("Forward Delete"))
        case kVK_Escape: return ("⎋", L("Escape"))
        case kVK_LeftArrow: return ("←", L("Left Arrow"))
        case kVK_RightArrow: return ("→", L("Right Arrow"))
        case kVK_UpArrow: return ("↑", L("Up Arrow"))
        case kVK_DownArrow: return ("↓", L("Down Arrow"))
        case kVK_Home: return ("↖", L("Home"))
        case kVK_End: return ("↘", L("End"))
        case kVK_PageUp: return ("⇞", L("Page Up"))
        case kVK_PageDown: return ("⇟", L("Page Down"))
        default: break
        }
        let f: [Int: Int] = [kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
                             kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18,
                             kVK_F19: 19, kVK_F20: 20]
        if let n = f[Int(code)] { return ("F\(n)", "F\(n)") }
        return nil
    }

    /// The key alone: "C", "Space", "F5", "←".
    static func key(_ code: UInt32, translate: Translate = ShortcutNames.translate) -> String {
        if let s = special(code) { return s.glyph }
        if let t = translate(code) { return t.uppercased(with: Language.locale) }
        return "#\(code)"
    }

    /// ⌃⌥⇧⌘ in macOS's order, then the key.
    static func glyphs(_ s: Shortcut, translate: Translate = ShortcutNames.translate) -> String {
        var out = ""
        if s.mods & Shortcut.ctrl != 0 { out += "⌃" }
        if s.mods & Shortcut.opt != 0 { out += "⌥" }
        if s.mods & Shortcut.shift != 0 { out += "⇧" }
        if s.mods & Shortcut.cmd != 0 { out += "⌘" }
        return out + key(s.keyCode, translate: translate)
    }

    /// For VoiceOver: "Control Option Command C".
    static func spoken(_ s: Shortcut, translate: Translate = ShortcutNames.translate) -> String {
        var parts: [String] = []
        if s.mods & Shortcut.ctrl != 0 { parts.append(L("Control")) }
        if s.mods & Shortcut.opt != 0 { parts.append(L("Option")) }
        if s.mods & Shortcut.shift != 0 { parts.append(L("Shift")) }
        if s.mods & Shortcut.cmd != 0 { parts.append(L("Command")) }
        parts.append(special(s.keyCode)?.spoken ?? key(s.keyCode, translate: translate))
        return parts.joined(separator: " ")
    }
}

// MARK: - Settings

/// Saved as "shortcuts.v1": JSON {action: shortcut or null}. A missing action has its default; null means none. With no
/// "shortcuts.v1" at all (2.4 and before) every action has its default, i.e. the old fixed ⌃⌥⌘C / O / P, plus ⌃⌥⌘I.
enum ShortcutStore {
    static let key = "shortcuts.v1"

    static func load(_ d: UserDefaults) -> [ShortcutAction: Shortcut] {
        let saved = d.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Shortcut?].self, from: $0) } ?? [:]
        var out: [ShortcutAction: Shortcut] = [:]
        for a in ShortcutAction.allCases {
            if let entry = saved[a.rawValue] { if let s = entry { out[a] = s } }       // present: that shortcut, or none
            else { out[a] = a.defaultShortcut }
        }
        return out
    }

    static func save(_ map: [ShortcutAction: Shortcut], to d: UserDefaults) {
        var json: [String: Shortcut?] = [:]
        for a in ShortcutAction.allCases { json[a.rawValue] = map[a] }
        if let data = try? JSONEncoder().encode(json) { d.set(data, forKey: key) }
    }

    static func reset(_ d: UserDefaults) { d.removeObject(forKey: key) }
}

// MARK: - Registration

/// Registers one Carbon hot key per action and remembers how each went (eventHotKeyExistsErr, -9878: another app, or this one,
/// already has that combination). The register and unregister functions are injected so tests can fake them.
final class ShortcutRegistrar {
    typealias Register = (Shortcut, UInt32) -> (status: OSStatus, ref: EventHotKeyRef?)
    typealias Unregister = (EventHotKeyRef) -> Void
    static let taken: OSStatus = -9878     // eventHotKeyExistsErr

    private let register: Register
    private let unregister: Unregister
    private var refs: [ShortcutAction: EventHotKeyRef] = [:]
    private(set) var status: [ShortcutAction: OSStatus] = [:]
    var registeredCount: Int { refs.count }

    init(register: @escaping Register = ShortcutRegistrar.carbonRegister, unregister: @escaping Unregister = { UnregisterEventHotKey($0) }) {
        self.register = register
        self.unregister = unregister
    }

    /// Unregisters everything, then registers `map` (none when nil: shortcuts off, or paused while one is being recorded).
    func apply(_ map: [ShortcutAction: Shortcut]?) {
        unregisterAll()
        guard let map else { return }
        for a in ShortcutAction.allCases {
            guard let s = map[a] else { continue }
            let r = register(s, a.hotKeyID)
            status[a] = r.status
            if r.status == noErr, let ref = r.ref { refs[a] = ref }
            if r.status != noErr { log.notice("shortcut \(a.rawValue, privacy: .public) not registered: \(r.status, privacy: .public)") }
        }
    }

    func unregisterAll() {
        for ref in refs.values { unregister(ref) }
        refs = [:]
        status = [:]
    }

    static func carbonRegister(_ s: Shortcut, _ id: UInt32) -> (status: OSStatus, ref: EventHotKeyRef?) {
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(s.keyCode, s.mods, EventHotKeyID(signature: OSType(0x434F4341), id: id), GetApplicationEventTarget(), 0, &ref)
        return (st, ref)
    }
}

private var shortcutHandler: ((UInt32) -> Void)?
private var shortcutHandlerInstalled = false

/// Carbon's hot-key event handler, installed once: it hands the action's id to `handler` on the main queue.
private func installShortcutHandler(_ handler: @escaping (UInt32) -> Void) {
    shortcutHandler = handler
    guard !shortcutHandlerInstalled else { return }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var hk = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hk)
        guard hk.signature == OSType(0x434F4341) else { return OSStatus(eventNotHandledErr) }
        DispatchQueue.main.async { shortcutHandler?(hk.id) }
        return noErr
    }, 1, &spec, nil, nil)
    shortcutHandlerInstalled = true
}

// MARK: - Recording

/// What a key press does while a shortcut is being recorded (pure: --selftest checks it).
enum RecorderKey: Equatable {
    case cancel                   // Esc: keep the old one
    case clear                    // Delete: no shortcut for this action
    case commit(Shortcut)

    static func interpret(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> RecorderKey {
        let mods = flags.intersection([.command, .option, .control, .shift])
        if mods.isEmpty && keyCode == UInt16(kVK_Escape) { return .cancel }
        if mods.isEmpty && (keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete)) { return .clear }
        return .commit(Shortcut(keyCode: keyCode, flags: flags))
    }
}

/// The shortcuts in use: settings, registration, the recorder and what a press of one does.
final class ShortcutCenter: ObservableObject {
    static let shared = ShortcutCenter()

    @Published private(set) var map: [ShortcutAction: Shortcut]
    @Published private(set) var status: [ShortcutAction: OSStatus] = [:]
    @Published private(set) var recording: ShortcutAction?
    /// Why the last key typed in the recorder wasn't taken (or a warning about the one that was), per action.
    @Published private(set) var note: [ShortcutAction: ShortcutProblem] = [:]
    /// Bumped when the keyboard layout changes, so the names are drawn again.
    @Published private(set) var layoutGeneration = 0
    private(set) var enabled = false
    /// What a shortcut does (set by the app).
    var perform: (ShortcutAction) -> Void = { _ in }
    var systemShortcuts: () -> Set<Shortcut> = ShortcutRules.systemShortcuts
    private let defaults: UserDefaults
    private let registrar: ShortcutRegistrar
    private var observing = false

    init(defaults: UserDefaults = .standard, registrar: ShortcutRegistrar = ShortcutRegistrar()) {
        self.defaults = defaults
        self.registrar = registrar
        map = ShortcutStore.load(defaults)
    }

    /// Turns the shortcuts on or off (the panel's switch), registering them with Carbon.
    func setEnabled(_ on: Bool) {
        enabled = on
        if on && !observing {
            observing = true
            installShortcutHandler { [weak self] id in
                guard let self, self.recording == nil, let a = ShortcutAction.from(hotKeyID: id) else { return }
                self.perform(a)
            }
            DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                                                object: nil, queue: .main) { [weak self] _ in
                ShortcutNames.refresh()
                self?.layoutGeneration += 1
            }
        }
        if !on { recording = nil }
        register()
    }

    private func register() {
        registrar.apply(enabled && recording == nil ? map : nil)
        if status != registrar.status { status = registrar.status }
    }

    /// The row's state, in words (nil when all is well).
    func detail(_ a: ShortcutAction) -> (text: String, warning: Bool)? {
        if recording == a { return (note[a].map { $0.text } ?? L("Type the new shortcut. Esc cancels, Delete removes it."), note[a]?.blocking ?? false) }
        if let n = note[a] { return (n.text, n.blocking) }
        guard enabled, map[a] != nil else { return nil }
        switch status[a] {
        case nil, noErr?: return nil
        case ShortcutRegistrar.taken?: return (L("Used by another app: pick another"), true)
        case let s?: return (String(format: L("Couldn't be set (error %d)"), Int(s)), true)
        }
    }

    func beginRecording(_ a: ShortcutAction) {
        if recording == a { cancelRecording(); return }
        recording = a
        note[a] = nil
        register()                                              // none while recording: the old combination can be typed again
        A11y.announce(L("Type the new shortcut. Esc cancels, Delete removes it."))
    }

    func cancelRecording() {
        guard let a = recording else { return }
        recording = nil
        if note[a]?.blocking == true { note[a] = nil }
        register()
    }

    /// A key typed while recording; true when it was used (the panel's key handling stops there).
    func handleRecorderKey(_ e: NSEvent) -> Bool {
        guard let a = recording else { return false }
        if e.isARepeat { return true }
        switch RecorderKey.interpret(keyCode: e.keyCode, flags: e.modifierFlags) {
        case .cancel:
            cancelRecording()
            A11y.announce(L("Unchanged"))
        case .clear:
            set(nil, for: a)
            A11y.announce(String(format: L("%@: no shortcut"), a.title))
        case .commit(let s):
            if let p = ShortcutRules.problem(s, for: a, others: map, system: systemShortcuts()), p.blocking {
                note[a] = p                                     // still recording: try another
                A11y.announce(p.text)
                return true
            }
            set(s, for: a)
            A11y.announce(String(format: L("%@: %@"), a.title, s.spoken))
        }
        return true
    }

    /// Saves (nil = none) and registers again; ends recording.
    func set(_ s: Shortcut?, for a: ShortcutAction) {
        var m = map
        m[a] = s
        map = m
        ShortcutStore.save(m, to: defaults)
        recording = nil
        if let s, let p = ShortcutRules.problem(s, for: a, others: m, system: []), !p.blocking { note[a] = p } else { note[a] = nil }
        register()
    }

    func resetToDefaults() {
        ShortcutStore.reset(defaults)
        map = ShortcutStore.load(defaults)
        recording = nil
        note = [:]
        register()
        A11y.announce(L("Shortcuts reset to their defaults"))
    }

    var isDefault: Bool { ShortcutAction.allCases.allSatisfy { map[$0] == $0.defaultShortcut } }
}

/// A shortcut's button in the panel: shows the keys; pressed, it records the next combination typed (the panel's key monitor
/// hands keys to ShortcutCenter.handleRecorderKey). VoiceOver: "Shortcut for Turn Cocaine on or off, Control Option Command C".
struct ShortcutRecorderButton: View {
    let action: ShortcutAction
    @ObservedObject var center = ShortcutCenter.shared
    @StateObject private var hover = HoverState()

    var body: some View {
        _ = center.layoutGeneration
        let recording = center.recording == action
        let s = center.map[action]
        return Button { Haptic.tap(.alignment); center.beginRecording(action) } label: {
            Text(recording ? L("Type…") : s?.glyphs ?? L("None"))
                .font(UI.value.monospacedDigit())
                .foregroundStyle(recording ? CTL.accent : s == nil ? UI.hint : UI.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minWidth: 76, minHeight: CTL.h, maxHeight: CTL.h)
                .background(Capsule().fill(recording ? CTL.accent.opacity(0.18) : hover.on ? CTL.fillHover : CTL.fill))
                .overlay(Capsule().strokeBorder(recording ? CTL.accent : UI.boundary, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScale))
        .onHover { hover.on = $0 }
        .help(L("Press, then type the new shortcut; Escape cancels"))
        .accessibilityLabel(String(format: L("Shortcut for %@"), action.title))
        .accessibilityValue(recording ? L("Recording") : s?.spoken ?? L("None"))
        .accessibilityHint(L("Press, then type the new shortcut; Escape cancels"))
    }
}

// MARK: - Tests (part of --selftest)

enum ShortcutTests {
    static func run(_ check: (String, Bool) -> Void) {
        let c = Shortcut.cmd, o = Shortcut.opt, k = Shortcut.ctrl, sh = Shortcut.shift
        func sc(_ code: Int, _ m: UInt32) -> Shortcut { Shortcut(keyCode: UInt32(code), mods: m) }
        let none: [ShortcutAction: Shortcut] = [:]
        func p(_ s: Shortcut, _ a: ShortcutAction = .toggle, others: [ShortcutAction: Shortcut] = [:], system: Set<Shortcut> = []) -> ShortcutProblem? {
            ShortcutRules.problem(s, for: a, others: others, system: system)
        }
        // Validation.
        check("shortcuts: the defaults pass the rules", ShortcutAction.allCases.allSatisfy { p($0.defaultShortcut, $0, others: none) == nil })
        check("shortcuts: a plain letter needs a modifier", p(sc(kVK_ANSI_C, 0)) == .needsModifier)
        check("shortcuts: ⇧ alone isn't enough", p(sc(kVK_ANSI_C, sh)) == .shiftOnly)
        check("shortcuts: F-keys may go alone", p(sc(kVK_F5, 0)) == nil && p(sc(kVK_F19, 0)) == nil)
        check("shortcuts: ⌘Q, ⌘Tab, ⌘Space, ⌃Space, ⌘⇧4, ⌃⌘Q, ⌥⌘Esc, ⌃→ are macOS's",
              [sc(kVK_ANSI_Q, c), sc(kVK_Tab, c), sc(kVK_Space, c), sc(kVK_Space, k), sc(kVK_ANSI_4, c | sh), sc(kVK_ANSI_Q, k | c),
               sc(kVK_Escape, o | c), sc(kVK_RightArrow, k)].allSatisfy { p($0) == .reserved })
        check("shortcuts: an enabled System Settings shortcut is refused", p(sc(kVK_ANSI_K, k | o | c), system: [sc(kVK_ANSI_K, k | o | c)]) == .system)
        check("shortcuts: the same keys for two actions are refused, naming the other",
              p(sc(kVK_ANSI_O, Shortcut.hyper), .toggle, others: [.panel: sc(kVK_ANSI_O, Shortcut.hyper)]) == .duplicate(.panel))
        check("shortcuts: …but an action may keep its own", p(sc(kVK_ANSI_O, Shortcut.hyper), .panel, others: [.panel: sc(kVK_ANSI_O, Shortcut.hyper)]) == nil)
        check("shortcuts: ⌃⌥ without ⌘ is allowed with a VoiceOver warning", p(sc(kVK_ANSI_C, k | o)) == .voiceOver && !ShortcutProblem.voiceOver.blocking)
        check("shortcuts: the live System Settings list is read (\(ShortcutRules.systemShortcuts().count) enabled)", !ShortcutRules.systemShortcuts().isEmpty)

        // Settings: migration from the fixed shortcuts, none, reset.
        let d = UserDefaults(suiteName: "local.cocaine.shortcut-test-\(getpid())")!
        defer { d.removePersistentDomain(forName: "local.cocaine.shortcut-test-\(getpid())") }
        let old = ShortcutStore.load(d)
        check("shortcuts: with nothing saved (2.4 and before) toggle, panel, pause are the old ⌃⌥⌘C, ⌃⌥⌘O, ⌃⌥⌘P",
              old[.toggle] == sc(8, Shortcut.hyper) && old[.panel] == sc(31, Shortcut.hyper) && old[.pause] == sc(35, Shortcut.hyper))
        check("shortcuts: …and the new island action is ⌃⌥⌘I", old[.island] == sc(kVK_ANSI_I, Shortcut.hyper))
        var m = old; m[.pause] = nil; m[.toggle] = sc(kVK_F6, 0)
        ShortcutStore.save(m, to: d)
        let back = ShortcutStore.load(d)
        check("shortcuts: a changed one and a removed one are saved as such", back[.toggle] == sc(kVK_F6, 0) && back[.pause] == nil && back[.panel] == old[.panel])
        ShortcutStore.reset(d)
        check("shortcuts: Reset to defaults brings the defaults back", ShortcutStore.load(d) == old)

        // Names on a given layout.
        check("shortcuts: names (glyphs) in macOS's modifier order", ShortcutNames.glyphs(sc(kVK_ANSI_C, c | sh | k | o), translate: { _ in "c" }) == "⌃⌥⇧⌘C")
        check("shortcuts: special keys by glyph or name", ShortcutNames.key(UInt32(kVK_F5), translate: { _ in nil }) == "F5"
              && ShortcutNames.key(UInt32(kVK_LeftArrow), translate: { _ in nil }) == "←" && ShortcutNames.key(UInt32(kVK_Space), translate: { _ in nil }) == L("Space"))
        check("shortcuts: spoken for VoiceOver", ShortcutNames.spoken(sc(kVK_ANSI_C, Shortcut.hyper), translate: { _ in "c" })
              == [L("Control"), L("Option"), L("Command"), "C"].joined(separator: " "))
        if let dvorak = ShortcutNames.layout(id: "com.apple.keylayout.Dvorak") {
            check("shortcuts: on Dvorak the key of ANSI C (code 8) is named J", ShortcutNames.key(8, translate: dvorak) == "J")
        }
        if let us = ShortcutNames.layout(id: "com.apple.keylayout.US") {
            check("shortcuts: on US the same key is C", ShortcutNames.key(8, translate: us) == "C")
        }

        // The recorder's keys.
        check("recorder: Esc cancels, Delete clears, anything else is taken",
              RecorderKey.interpret(keyCode: UInt16(kVK_Escape), flags: []) == .cancel
              && RecorderKey.interpret(keyCode: UInt16(kVK_Delete), flags: []) == .clear
              && RecorderKey.interpret(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .option]) == .commit(sc(kVK_ANSI_K, c | o))
              && RecorderKey.interpret(keyCode: UInt16(kVK_Escape), flags: [.command]) == .commit(sc(kVK_Escape, c)))

        // Registration with a fake register function: what it reports, and that it lets go.
        var registered: [UInt32: Shortcut] = [:], unregistered = 0
        let fake = ShortcutRegistrar(register: { s, id in
            if s == sc(kVK_ANSI_O, Shortcut.hyper) { return (ShortcutRegistrar.taken, nil) }       // another app holds it
            registered[id] = s
            return (noErr, OpaquePointer(bitPattern: Int(id) * 16))
        }, unregister: { _ in unregistered += 1 })
        fake.apply(old)
        check("registrar: each action registered with its id, a taken one reported (-9878)",
              registered[ShortcutAction.toggle.hotKeyID] == old[.toggle] && fake.status[.panel] == ShortcutRegistrar.taken
              && fake.status[.toggle] == noErr && fake.registeredCount == 3)
        fake.apply(nil)
        check("registrar: off (or recording) unregisters every one", unregistered == 3 && fake.registeredCount == 0 && fake.status.isEmpty)

        let center = ShortcutCenter(defaults: d, registrar: fake)
        center.systemShortcuts = { [] }
        center.setEnabled(true)
        check("center: the taken one's row says so", center.detail(.panel)?.text == L("Used by another app: pick another") && center.detail(.toggle) == nil)
        center.beginRecording(.toggle)
        check("center: recording lets go of every shortcut", fake.registeredCount == 0 && center.recording == .toggle)
        center.cancelRecording()
        check("center: …and takes them back when it ends", fake.registeredCount == 3 && center.recording == nil)
        center.set(nil, for: .island)
        check("center: a removed one isn't registered", fake.registeredCount == 2 && ShortcutStore.load(d)[.island] == nil)
        center.resetToDefaults()
        center.setEnabled(false)
        check("center: off unregisters all", fake.registeredCount == 0)

        // The real Carbon registration: the same combination twice in one process is refused with -9878.
        let real = ShortcutRegistrar(), twice = ShortcutRegistrar()
        let probe = sc(kVK_F17, Shortcut.hyper | sh)
        real.apply([.toggle: probe]); twice.apply([.toggle: probe])
        check("registrar: Carbon refuses a combination already registered (\(twice.status[.toggle] ?? 0))",
              real.status[.toggle] == noErr && twice.status[.toggle] == ShortcutRegistrar.taken)
        real.apply(nil); twice.apply(nil)
    }
}
