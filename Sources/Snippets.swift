// Snippets: a pinboard item marked as a snippet gets placeholders filled when it is pasted ({clipboard}, {date}, {time},
// {datetime}, {date:yyyy-MM-dd}, {input:Name} asks for a value) and may have its own global shortcut that pastes it. There is
// no abbreviation expansion: that would mean watching every key typed in every app (an Input Monitoring event tap, which is
// what a keylogger does), so it is deliberately not built. The clipboard's global shortcuts (a snippet's, a pinboard's,
// "Paste next" of the Paste Stack) are Carbon hot keys of their own (no permission), registered next to Sources/Shortcuts.swift's.

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Placeholders

enum SnippetExpander {
    struct Context {
        var clipboard: String? = nil
        var now = Date()
        var locale = Locale(identifier: "en")
        var inputs: [String: String] = [:]
    }

    static let maxResult = 1_000_000
    static let maxValue = 200_000            // what one placeholder may put in
    static let maxInputs = 5
    static let maxName = 40

    /// The {input:Name} placeholders, in order, each once (at most maxInputs; a name is at most maxName characters).
    static func inputs(in template: String) -> [String] {
        var out: [String] = []
        for token in tokens(template) {
            guard case .placeholder(let p) = token, p.hasPrefix("input:") else { continue }
            let name = String(p.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= maxName, !out.contains(name) else { continue }
            out.append(name)
            if out.count == maxInputs { break }
        }
        return out
    }

    /// The text with its placeholders filled in, in one pass: what a placeholder puts in is never read again (a {date} that
    /// comes from the clipboard stays as it is). Unknown placeholders stay as typed; {{ and }} are literal braces.
    static func expand(_ template: String, _ c: Context) -> String {
        var out = ""
        for token in tokens(template) {
            switch token {
            case .text(let t): out += t
            case .placeholder(let p): out += value(p, c) ?? "{" + p + "}"
            }
            if out.count > maxResult { return String(out.prefix(maxResult)) }
        }
        return out
    }

    private static func value(_ p: String, _ c: Context) -> String? {
        func fmt(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> String {
            let f = DateFormatter(); f.locale = c.locale; f.dateStyle = date; f.timeStyle = time
            return f.string(from: c.now)
        }
        switch p {
        case "clipboard": return String((c.clipboard ?? "").prefix(maxValue))
        case "date": return fmt(.medium, .none)
        case "time": return fmt(.none, .short)
        case "datetime": return fmt(.medium, .short)
        default:
            if p.hasPrefix("date:") {
                let pattern = String(p.dropFirst(5))
                guard !pattern.isEmpty, pattern.count <= 40 else { return nil }
                let f = DateFormatter(); f.locale = c.locale; f.dateFormat = pattern
                return f.string(from: c.now)
            }
            if p.hasPrefix("input:") {
                let name = String(p.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                return c.inputs[name].map { String($0.prefix(maxValue)) }
            }
            return nil
        }
    }

    enum Token: Equatable { case text(String), placeholder(String) }

    /// The template cut into text and {placeholders}. A brace that isn't closed on the same line, or a placeholder longer
    /// than 60 characters, is plain text.
    static func tokens(_ s: String) -> [Token] {
        var out: [Token] = [], buf = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "{" && i + 1 < chars.count && chars[i + 1] == "{" { buf.append("{"); i += 2; continue }
            if ch == "}" && i + 1 < chars.count && chars[i + 1] == "}" { buf.append("}"); i += 2; continue }
            if ch == "{" {
                var j = i + 1, name = ""
                while j < chars.count, chars[j] != "}", chars[j] != "{", chars[j] != "\n", name.count <= 60 { name.append(chars[j]); j += 1 }
                if j < chars.count, chars[j] == "}", !name.isEmpty, name.count <= 60 {
                    if !buf.isEmpty { out.append(.text(buf)); buf = "" }
                    out.append(.placeholder(name))
                    i = j + 1
                    continue
                }
            }
            buf.append(ch)
            i += 1
        }
        if !buf.isEmpty { out.append(.text(buf)) }
        return out
    }
}

/// Pasting an item that may be a snippet: its placeholders filled (asking for {input:…} values in the island), then pasted.
enum SnippetPaste {
    /// Asks for the values of {input:…} placeholders (nil: cancelled). The app asks in the island; tests answer at once.
    static var ask: (_ names: [String], _ done: @escaping ([String: String]?) -> Void) -> Void = askInIsland

    static func paste(_ item: ClipItem, engine: PasteEngine, plain: Bool? = nil, target: String? = nil, completion: ((PasteEngine.Outcome) -> Void)? = nil) {
        guard item.snippet != nil, item.kind == .text else { engine.paste(item, plain: plain, target: target, completion: completion); return }
        let target = target ?? engine.frontApp()
        let names = SnippetExpander.inputs(in: item.text)
        let go: ([String: String]) -> Void = { inputs in
            let c = SnippetExpander.Context(clipboard: engine.history.board.currentText(), now: engine.history.now(), locale: Language.locale, inputs: inputs)
            engine.paste(item, plain: true, text: SnippetExpander.expand(item.text, c), target: target, completion: completion)
        }
        if names.isEmpty { go([:]); return }
        ask(names) { answers in if let answers { go(answers) } }
    }

    /// One in-app question per name, in order (Esc cancels the paste).
    private static func askInIsland(_ names: [String], _ done: @escaping ([String: String]?) -> Void) {
        var answers: [String: String] = [:]
        func next(_ i: Int) {
            guard i < names.count else { done(answers); return }
            let spec = DialogSpec(icon: "text.cursor", title: String(format: L("Value for “%@”"), names[i]),
                                  field: DialogField(placeholder: names[i]),
                                  buttons: [DialogButton(id: "ok", title: i == names.count - 1 ? L("Paste") : L("Next")), Dialogs.cancel], surface: .island)
            DialogCenter.shared.present(spec) { r in
                guard case .button("ok", let text, _) = r else { done(nil); return }
                answers[names[i]] = String(text.prefix(SnippetExpander.maxValue))
                next(i + 1)
            }
        }
        next(0)
    }
}

// MARK: - The clipboard's global shortcuts

/// What one of the clipboard's global shortcuts does.
enum ClipHotKeyTarget: Hashable {
    case pasteNext
    case board(UUID)
    case snippet(UUID)
}

/// Registers the clipboard's own Carbon hot keys (signature 'CCLP', so they never mix with Sources/Shortcuts.swift's) and runs
/// them. The register function is injected so tests can fake it.
final class ClipHotKeys: ObservableObject {
    static let shared = ClipHotKeys()
    static let signature = OSType(0x43434C50)          // 'CCLP'

    typealias Register = (Shortcut, UInt32) -> (status: OSStatus, ref: EventHotKeyRef?)
    private let register: Register
    private let unregister: (EventHotKeyRef) -> Void
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private(set) var targets: [UInt32: ClipHotKeyTarget] = [:]
    @Published private(set) var status: [ClipHotKeyTarget: OSStatus] = [:]
    /// What a press does (set by the island's wiring).
    var perform: (ClipHotKeyTarget) -> Void = { _ in }
    private var installed = false

    init(register: @escaping Register = ClipHotKeys.carbonRegister, unregister: @escaping (EventHotKeyRef) -> Void = { UnregisterEventHotKey($0) }) {
        self.register = register
        self.unregister = unregister
    }

    /// The shortcuts wanted now: "Paste next" while a stack waits, each pinboard's and each snippet's.
    static func wanted(settings: ClipSettings, stackActive: Bool, boards: [ClipBoard], items: [ClipItem]) -> [(ClipHotKeyTarget, Shortcut)] {
        var out: [(ClipHotKeyTarget, Shortcut)] = []
        if stackActive, let s = settings.pasteNext { out.append((.pasteNext, s)) }
        for b in boards { if let s = b.hotkey { out.append((.board(b.id), s)) } }
        for i in items where i.pinned { if let s = i.snippet?.hotkey { out.append((.snippet(i.id), s)) } }
        var seen = Set<Shortcut>()
        return out.filter { seen.insert($0.1).inserted }                  // one action per combination
    }

    /// Unregisters everything, then registers `list` (ids from 1 in order).
    func apply(_ list: [(ClipHotKeyTarget, Shortcut)]) {
        for r in refs.values { unregister(r) }
        refs = [:]; targets = [:]
        var st: [ClipHotKeyTarget: OSStatus] = [:]
        if !list.isEmpty { installHandler() }
        for (n, (t, s)) in list.enumerated() {
            let id = UInt32(n + 1)
            let r = register(s, id)
            st[t] = r.status
            if r.status == noErr, let ref = r.ref { refs[id] = ref; targets[id] = t }
        }
        if st != status { status = st }
    }

    var registeredCount: Int { refs.count }

    func fire(_ id: UInt32) { if let t = targets[id] { perform(t) } }

    static func carbonRegister(_ s: Shortcut, _ id: UInt32) -> (status: OSStatus, ref: EventHotKeyRef?) {
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(s.keyCode, s.mods, EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &ref)
        return (st, ref)
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard hk.signature == ClipHotKeys.signature else { return OSStatus(eventNotHandledErr) }   // Shortcuts.swift's own
            let id = hk.id
            DispatchQueue.main.async { ClipHotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Why `s` can't be used for `target` (nil: fine): the global shortcuts' rules, the app's own shortcuts, the others here.
    static func problem(_ s: Shortcut, for target: ClipHotKeyTarget, settings: ClipSettings, boards: [ClipBoard], items: [ClipItem],
                        appShortcuts: [Shortcut], system: Set<Shortcut>) -> String? {
        if let p = ShortcutRules.problem(s, for: .toggle, others: [:], system: system), p.blocking { return p.text }
        if appShortcuts.contains(s) { return L("Cocaine already uses this shortcut") }
        let others = wanted(settings: settings, stackActive: true, boards: boards, items: items).filter { $0.0 != target }.map(\.1)
        if others.contains(s) { return L("Cocaine already uses this shortcut") }
        return nil
    }
}

/// Records a clipboard shortcut (the panel's and the island's key handling hand it keys while it records).
final class ClipShortcutRecorder: ObservableObject {
    static let shared = ClipShortcutRecorder()
    @Published private(set) var recording: ClipHotKeyTarget?
    @Published private(set) var note: String?
    /// Saves a recorded (or cleared) shortcut.
    var save: (ClipHotKeyTarget, Shortcut?) -> Void = { _, _ in }
    /// Why a shortcut can't be used (nil: fine).
    var check: (ClipHotKeyTarget, Shortcut) -> String? = { _, _ in nil }

    func begin(_ t: ClipHotKeyTarget) {
        if recording == t { cancel(); return }
        recording = t
        note = nil
        ClipHotKeys.shared.apply([])                       // none while recording: the old combination can be typed again
        A11y.announce(L("Type the new shortcut. Esc cancels, Delete removes it."))
    }

    func cancel() {
        guard recording != nil else { return }
        recording = nil
        note = nil
        ClipboardHistory.shared.onBoardsChange()
    }

    /// A key typed while recording: true when it was used.
    @discardableResult
    func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard let t = recording else { return false }
        switch RecorderKey.interpret(keyCode: keyCode, flags: flags) {
        case .cancel: cancel(); A11y.announce(L("Unchanged"))
        case .clear:
            recording = nil; note = nil
            save(t, nil)
            A11y.announce(L("No shortcut"))
        case .commit(let s):
            if let p = check(t, s) { note = p; A11y.announce(p); return true }
            recording = nil; note = nil
            save(t, s)
            A11y.announce(s.spoken)
        }
        return true
    }
}

/// A clipboard shortcut's button: the keys, or "Type…" while recording (same look as the global shortcuts' recorder).
struct ClipShortcutButton: View {
    let target: ClipHotKeyTarget
    let shortcut: Shortcut?
    let label: String
    var onBegin: () -> Void = {}
    @ObservedObject var rec = ClipShortcutRecorder.shared
    @ObservedObject var keys = ClipHotKeys.shared
    @StateObject private var hover = HoverState()

    var body: some View {
        let recording = rec.recording == target
        let taken = keys.status[target].map { $0 != noErr } ?? false
        return Button { Haptic.tap(.alignment); onBegin(); rec.begin(target) } label: {
            Text(recording ? L("Type…") : shortcut?.glyphs ?? L("None"))
                .font(UI.value.monospacedDigit())
                .foregroundStyle(recording ? CTL.accent : taken ? warningColor : shortcut == nil ? UI.hint : UI.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minWidth: 76, minHeight: CTL.h, maxHeight: CTL.h)
                .background(Capsule().fill(recording ? CTL.accent.opacity(0.18) : hover.on ? CTL.fillHover : CTL.fill))
                .overlay(Capsule().strokeBorder(recording ? CTL.accent : UI.boundary, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScale))
        .onHover { hover.on = $0 }
        .help(recording ? (rec.note ?? L("Type the new shortcut. Esc cancels, Delete removes it.")) : taken ? L("Used by another app: pick another") : L("Press, then type the new shortcut; Escape cancels"))
        .accessibilityLabel(String(format: L("Shortcut for %@"), label))
        .accessibilityValue(recording ? L("Recording") : shortcut?.spoken ?? L("None"))
        .accessibilityHint(L("Press, then type the new shortcut; Escape cancels"))
    }
}
