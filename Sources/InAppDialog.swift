// In-app dialogs: questions, confirmations, messages, a text entry and the share list, drawn as a card inside Cocaine's own
// black surface (over the settings panel hanging from the notch, or inside the open island) instead of macOS alert windows.
//
// One dialog at a time; the others wait in a queue. Every request gets exactly one answer through its completion handler.
// Return presses the default button (for a question that grants a permission, the safe answer, never the one that grants);
// Esc, a click outside the card or outside the panel, and the panel or island closing all answer `.cancelled`, the same as
// the Cancel button. A dialog that can't be shown anywhere in the app (no screen, a headless launch) falls back to NSAlert.

import AppKit
import SwiftUI

/// Where a dialog shows: over the settings panel, or inside the open island.
enum DialogSurface: Equatable { case panel, island }

enum DialogButtonRole: Equatable { case normal, destructive, cancel }

struct DialogButton: Equatable {
    var id: String
    var title: String
    var role: DialogButtonRole = .normal
    /// Pressing it needs a valid text field (the field's `validate` says why not, under the field).
    var needsValidInput = false
}

struct DialogChoice: Identifiable {
    var id: String
    var title: String
    var symbol: String? = nil          // an SF Symbol…
    var image: NSImage? = nil          // …or an image (a sharing service's own icon)
    var destructive = false            // an action row that destroys: red ink
}

struct DialogField {
    var placeholder: String
    var text = ""
    /// nil = the text is fine; otherwise what is wrong with it.
    var validate: (String) -> String? = { _ in nil }
}

struct DialogSpec {
    enum ChoiceMode { case pick, act }
    var icon: String                   // SF Symbol in the title row, like a settings card's
    var title: String
    var message: String? = nil
    var critical = false               // the icon in the warning color (destructive confirmations, errors)
    var field: DialogField? = nil
    var choices: [DialogChoice] = []
    /// .pick: one row is selected (a check mark) and goes with the pressed button; .act: tapping a row is the answer.
    var choiceMode = ChoiceMode.pick
    var selected: String? = nil
    /// In the order of NSAlert's buttons (the fallback); the card orders them by role (DialogLogic.drawOrder).
    var buttons: [DialogButton]
    /// A question that grants a permission: Return (and the highlighted button) is the safe answer, the Cancel-role button.
    var safeDefault = false
    var surface = DialogSurface.panel
}

enum DialogResult: Equatable {
    case button(String, text: String, choice: String?)
    case choice(String)
    /// The Cancel-role button, Esc, a click elsewhere, the panel or island closing.
    case cancelled

    var buttonID: String? { if case .button(let id, _, _) = self { return id }; return nil }
}

/// The rules, without any UI: which button Return presses, what a press does.
enum DialogLogic {
    enum Outcome: Equatable { case finish(DialogResult), invalid(String), ignored }
    enum Key { case returnKey, escape }

    /// The button Return presses (and the one drawn highlighted). Never a destructive one; for a permission question the
    /// Cancel-role button; otherwise the first normal button, else Cancel.
    static func defaultButton(_ s: DialogSpec) -> String? {
        let cancel = s.buttons.first { $0.role == .cancel }?.id
        if s.safeDefault { return cancel }
        return s.buttons.first { $0.role == .normal }?.id ?? cancel
    }

    /// Left to right as the card draws them: Cancel, then destructive ones, then other normal ones, and the default always
    /// rightmost (macOS's place for it), so a destructive button sits left of a safe default and never takes its place.
    static func drawOrder(_ s: DialogSpec) -> [DialogButton] {
        let def = defaultButton(s)
        func rank(_ b: DialogButton) -> Int {
            if b.id == def { return 3 }
            switch b.role { case .cancel: return 0; case .destructive: return 1; case .normal: return 2 }
        }
        return s.buttons.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// How a button looks: the default is the one filled (accent) button; a destructive one has red ink; the rest are grey.
    static func kind(_ s: DialogSpec, _ b: DialogButton) -> CocaineButtonKind {
        if b.role == .destructive { return .destructive }
        return b.id == defaultButton(s) ? .primary : .secondary
    }

    static func press(_ s: DialogSpec, _ id: String, text: String, choice: String?) -> Outcome {
        guard let b = s.buttons.first(where: { $0.id == id }) else { return .ignored }
        if b.role == .cancel { return .finish(.cancelled) }
        if b.needsValidInput, let f = s.field, let problem = f.validate(text) { return .invalid(problem) }
        return .finish(.button(id, text: text, choice: s.choiceMode == .pick ? choice : nil))
    }

    static func key(_ s: DialogSpec, _ k: Key, text: String, choice: String?) -> Outcome {
        switch k {
        case .escape: return .finish(.cancelled)
        case .returnKey: return defaultButton(s).map { press(s, $0, text: text, choice: choice) } ?? .ignored
        }
    }
}

/// The queue and the dialog on screen; the views draw `current`.
final class DialogCenter: ObservableObject {
    static let shared = DialogCenter()

    struct Request: Identifiable {
        let id = UUID()
        var spec: DialogSpec
        let completion: (DialogResult) -> Void
    }

    @Published private(set) var current: Request?
    @Published var text = "" { didSet { if text != oldValue { problem = nil } } }
    @Published var choice: String?
    @Published private(set) var problem: String?       // the text field's validation message, after a press
    @Published var hovered: String?                     // the choice row under the pointer
    /// The card's height as last laid out: the panel grows to at least that (its card is drawn over it, not inside it).
    @Published var cardHeight: CGFloat = 0
    private(set) var queue: [Request] = []
    private var finishing = false

    /// Brings up a surface for a dialog that wants `surface`: the surface it really shows on (the island may be closed: then
    /// the panel), or nil when nothing can be shown (then NSAlert).
    var show: (DialogSurface) -> DialogSurface? = { _ in nil }
    /// After every change of the dialog on screen (keyboard focus for the island, the panel's scroll position).
    var changed: () -> Void = {}
    var fallback: (DialogSpec) -> DialogResult = DialogCenter.alert

    init() {}

    func present(_ spec: DialogSpec, _ completion: @escaping (DialogResult) -> Void) {
        queue.append(Request(spec: spec, completion: completion))
        if current == nil && !finishing { advance() }
    }

    var surface: DialogSurface? { current?.spec.surface }
    func isShowing(on s: DialogSurface) -> Bool { current?.spec.surface == s }

    private func advance() {
        while current == nil, !queue.isEmpty {
            var r = queue.removeFirst()
            text = r.spec.field?.text ?? ""
            choice = r.spec.choiceMode == .pick ? (r.spec.selected ?? r.spec.choices.first?.id) : nil
            problem = nil; hovered = nil
            guard let shownOn = show(r.spec.surface) else {          // nowhere in the app: the system's alert, as before
                finishing = true
                r.completion(fallback(r.spec))
                finishing = false
                continue
            }
            r.spec.surface = shownOn
            current = r
        }
        changed()
    }

    /// Ends the dialog on screen with `result` (once: later calls for it do nothing), then shows the next one.
    private func finish(_ result: DialogResult) {
        guard let r = current else { return }
        current = nil; problem = nil; hovered = nil
        finishing = true                       // what the completion presents waits behind what was already waiting
        r.completion(result)
        finishing = false
        advance()
    }

    func press(_ id: String) { apply(current.map { DialogLogic.press($0.spec, id, text: text, choice: choice) }) }

    func tapChoice(_ id: String) {
        guard let r = current else { return }
        if r.spec.choiceMode == .act { finish(.choice(id)) } else { choice = id }
    }

    func cancel() { finish(.cancelled) }

    /// The panel or the island went away (a click elsewhere, Esc, the pointer leaving): its dialog is cancelled. Dialogs still
    /// waiting are not: they show next (and bring the panel back), each is its own question.
    func surfaceClosed(_ s: DialogSurface) { if current?.spec.surface == s { cancel() } }

    /// Return and Esc for the dialog on screen; true when the key was used. Return while an input method is composing (Japanese,
    /// Chinese) belongs to the text field.
    func handleKey(_ e: NSEvent) -> Bool {
        guard current != nil else { return false }
        switch e.keyCode {
        case 53: return handle(.escape)
        case 36, 76:
            if let tv = e.window?.firstResponder as? NSTextView, tv.hasMarkedText() { return false }
            return handle(.returnKey)
        default: return false
        }
    }

    @discardableResult
    func handle(_ k: DialogLogic.Key) -> Bool {
        guard let r = current else { return false }
        apply(DialogLogic.key(r.spec, k, text: text, choice: choice))
        return true
    }

    private func apply(_ o: DialogLogic.Outcome?) {
        switch o {
        case .finish(let result)?: finish(result)
        case .invalid(let why)?: problem = why
        default: break
        }
    }

    /// The last resort when no surface of the app can be shown: a plain NSAlert with the same buttons (and field, and choices
    /// as a pop-up menu), answered synchronously.
    static func alert(_ s: DialogSpec) -> DialogResult {
        let a = NSAlert()
        a.alertStyle = s.critical ? .critical : .informational
        a.messageText = s.title
        a.informativeText = s.message ?? ""
        var field: NSTextField?, popup: NSPopUpButton?
        if let f = s.field {
            let t = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            t.stringValue = f.text; t.placeholderString = f.placeholder
            a.accessoryView = t; field = t
        } else if !s.choices.isEmpty {
            let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
            p.addItems(withTitles: s.choices.map(\.title))
            if let sel = s.selected, let i = s.choices.firstIndex(where: { $0.id == sel }) { p.selectItem(at: i) }
            a.accessoryView = p; popup = p
        }
        for b in s.buttons { a.addButton(withTitle: b.title) }
        let def = DialogLogic.defaultButton(s)
        for (i, b) in s.buttons.enumerated() { a.buttons[i].keyEquivalent = b.id == def ? "\r" : (b.role == .cancel ? "\u{1b}" : "") }
        NSApp.activate()
        let i = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard i >= 0, i < s.buttons.count else { return .cancelled }
        let text = field?.stringValue ?? ""
        let choice = popup.map { s.choices[max(0, $0.indexOfSelectedItem)].id }
        if s.choiceMode == .act, let choice, s.buttons[i].role != .cancel { return .choice(choice) }
        switch DialogLogic.press(s, s.buttons[i].id, text: text, choice: choice) {
        case .finish(let r): return r
        case .invalid, .ignored: return .cancelled
        }
    }
}

// MARK: - The card

/// The panel's type scale and colors, handed in by main.swift (they are private there).
struct DialogStyle {
    var title: Font
    var body: Font
    var row: Font
    var detail: Font
    var icon: Font
    var accent: Color
    var warning: Color
}

/// The dialog as a card: an icon and a title like a settings card's, the message, the field or the choices, the buttons.
struct InAppDialogCard: View {
    @ObservedObject var center: DialogCenter
    let style: DialogStyle

    var body: some View {
        if let r = center.current { card(r.spec).id(r.id) }
    }

    private func card(_ s: DialogSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: s.icon).font(style.icon).foregroundStyle(s.critical ? style.warning : style.accent).frame(width: UI.iconColumn)
                Text(s.title).font(style.title).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 22)
            if let m = s.message, !m.isEmpty {
                Text(m).font(style.body).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let f = s.field {
                DialogTextField(text: $center.text, placeholder: f.placeholder)
                    .frame(height: 24).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: CTL.radius).strokeBorder(center.problem == nil ? Color.clear : style.warning.opacity(0.8), lineWidth: 1))
                if let p = center.problem {
                    Label(p, systemImage: "exclamationmark.triangle.fill").font(style.detail).foregroundStyle(style.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !s.choices.isEmpty { choices(s) }
            buttons(s)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))          // opaque over the dimmed page
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func choices(_ s: DialogSpec) -> some View {
        let cols = s.choiceMode == .act && s.choices.count > 3 ? [GridItem(.flexible(), spacing: 6), GridItem(.flexible())] : [GridItem(.flexible())]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: Space.s) {         // the same gap both ways
            ForEach(s.choices) { c in
                let picked = s.choiceMode == .pick && center.choice == c.id
                let lead: ChoiceRow.Leading = c.image.map { .image($0) } ?? c.symbol.map { .symbol($0) } ?? .none
                ChoiceRow(title: c.title, leading: lead, checked: picked, showsCheckColumn: s.choiceMode == .pick,
                          highlighted: picked || center.hovered == c.id, destructive: c.destructive, lines: 2, font: style.row, iconFont: style.icon,
                          action: { center.tapChoice(c.id) },
                          hover: { inside in if inside { center.hovered = c.id } else if center.hovered == c.id { center.hovered = nil } })
            }
        }
    }

    private func buttons(_ s: DialogSpec) -> some View {
        let ordered = DialogLogic.drawOrder(s)                  // the default rightmost
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                ForEach(ordered, id: \.id) { b in button(s, b).fixedSize() }
            }
            VStack(alignment: .trailing, spacing: Space.s) {       // long labels (German): one under the other, the default at the bottom
                ForEach(ordered, id: \.id) { b in button(s, b, wide: true) }
            }
        }
        .padding(.top, 2)
    }

    private func button(_ s: DialogSpec, _ b: DialogButton, wide: Bool = false) -> some View {
        Button(b.title) { center.press(b.id) }
            .buttonStyle(CocaineButtonStyle(kind: DialogLogic.kind(s, b), height: CTL.hDialog, wide: wide))
    }
}

/// The dialog's text field: AppKit's, so it takes the keyboard as soon as it appears (SwiftUI's focus needs @FocusState, which
/// the command-line build can't use) and leaves Return to the dialog.
struct DialogTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none; f.isBezeled = false
        f.font = .systemFont(ofSize: 12)
        f.textColor = .white
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.35),
                                                                                             .font: NSFont.systemFont(ofSize: 12)])
        f.cell?.isScrollable = true; f.cell?.wraps = false; f.lineBreakMode = .byClipping
        f.delegate = context.coordinator
        f.stringValue = text
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text && f.currentEditor() == nil { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DialogTextField
        init(_ p: DialogTextField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }
    }
}

/// A surface that can hold a dialog: while one is on it, what is under the card is dimmed and disabled (a click there is Cancel),
/// and the card sits on top, at the top. The card may be taller than the page: the surface grows (the panel) to hold it.
struct DialogHost: ViewModifier {
    @ObservedObject var center: DialogCenter
    let surface: DialogSurface
    let style: DialogStyle
    var maxWidth: CGFloat = .infinity
    var inset = EdgeInsets()

    func body(content: Content) -> some View {
        let on = center.isShowing(on: surface)
        return ZStack(alignment: .top) {
            content.disabled(on).opacity(on ? 0.4 : 1)
                .overlay { if on { Color.black.opacity(0.45).contentShape(Rectangle()).onTapGesture { center.cancel() } } }
            if on { InAppDialogCard(center: center, style: style).frame(maxWidth: maxWidth).padding(inset).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: center.current?.id)
    }
}

extension View {
    func dialogHost(_ center: DialogCenter, _ surface: DialogSurface, _ style: DialogStyle, maxWidth: CGFloat = .infinity, inset: EdgeInsets = EdgeInsets()) -> some View {
        modifier(DialogHost(center: center, surface: surface, style: style, maxWidth: maxWidth, inset: inset))
    }
}

// MARK: - Tests (--dialogs-test, part of --selftest)

enum DialogTests {
    static func info(_ surface: DialogSurface = .panel) -> DialogSpec {
        DialogSpec(icon: "info.circle", title: "Info", buttons: [DialogButton(id: "ok", title: "OK")], surface: surface)
    }

    static func pure(_ check: (String, Bool) -> Void) {
        // Default-button rules.
        let confirm = DialogSpec(icon: "trash", title: "Delete?", buttons: [DialogButton(id: "delete", title: "Delete", role: .destructive),
                                                                          DialogButton(id: "cancel", title: "Cancel", role: .cancel)])
        check("dialogs: Return never presses a destructive button (Cancel is the default)", DialogLogic.defaultButton(confirm) == "cancel")
        check("dialogs: an information's only button is the default", DialogLogic.defaultButton(info()) == "ok")
        var grant = DialogSpec(icon: "link", title: "Allow?", buttons: [DialogButton(id: "allow", title: "Allow"),
                                                                       DialogButton(id: "deny", title: "Don't Allow", role: .cancel)])
        check("dialogs: an ordinary question defaults to its first normal button", DialogLogic.defaultButton(grant) == "allow")
        grant.safeDefault = true
        check("dialogs: a permission question defaults to the safe answer", DialogLogic.defaultButton(grant) == "deny")
        check("dialogs: …so Return answers it with a refusal", DialogLogic.key(grant, .returnKey, text: "", choice: nil) == .finish(.cancelled))
        check("dialogs: Esc is Cancel", DialogLogic.key(confirm, .escape, text: "", choice: nil) == .finish(.cancelled))
        check("dialogs: a delete confirmation draws [Delete] [Cancel]: the default rightmost, the destructive left of it",
              DialogLogic.drawOrder(confirm).map(\.id) == ["delete", "cancel"])
        check("dialogs: …only the default is filled; the destructive one is red ink, never a second filled button",
              DialogLogic.kind(confirm, confirm.buttons[1]) == .primary && DialogLogic.kind(confirm, confirm.buttons[0]) == .destructive)
        let three = DialogSpec(icon: "lock", title: "Keep?", buttons: [DialogButton(id: "keep", title: "Keep"), DialogButton(id: "delete", title: "Delete", role: .destructive),
                                                                      DialogButton(id: "cancel", title: "Cancel", role: .cancel)])
        check("dialogs: Cancel · Delete · Keep (default) left to right", DialogLogic.drawOrder(three).map(\.id) == ["cancel", "delete", "keep"])

        // Text validation.
        let field = DialogSpec(icon: "textformat", title: "Pattern", field: DialogField(placeholder: "", validate: { $0.isEmpty ? "empty" : $0 == "([" ? "bad" : nil }),
                               buttons: [DialogButton(id: "add", title: "Add", needsValidInput: true), DialogButton(id: "cancel", title: "Cancel", role: .cancel)])
        check("dialogs: an invalid text keeps the dialog open with the reason", DialogLogic.press(field, "add", text: "([", choice: nil) == .invalid("bad")
              && DialogLogic.key(field, .returnKey, text: "", choice: nil) == .invalid("empty"))
        check("dialogs: a valid text is handed back with the button", DialogLogic.press(field, "add", text: "^IBAN", choice: nil) == .finish(.button("add", text: "^IBAN", choice: nil)))
        check("dialogs: Cancel never validates", DialogLogic.press(field, "cancel", text: "([", choice: nil) == .finish(.cancelled))

        // The queue, exactly one answer each, dismissal = cancel.
        let c = DialogCenter()
        var shown: [DialogSurface] = []
        c.show = { s in shown.append(s); return s }
        var answers: [String] = []
        c.present(info()) { answers.append("A:\($0.buttonID ?? "cancel")") }
        c.present(info()) { answers.append("B:\($0.buttonID ?? "cancel")") }
        check("dialogs: one at a time, the second waits", c.current != nil && c.queue.count == 1 && shown.count == 1)
        c.press("ok"); c.press("ok"); c.cancel()
        check("dialogs: each answered exactly once, in order", answers == ["A:ok", "B:ok"] && c.current == nil && c.queue.isEmpty)
        c.press("ok"); c.cancel()
        check("dialogs: presses with nothing on screen do nothing", answers.count == 2)

        answers = []
        c.present(info()) { answers.append("A:\($0.buttonID ?? "cancel")") }
        c.present(info()) { answers.append("B:\($0.buttonID ?? "cancel")") }
        c.surfaceClosed(.island)
        check("dialogs: the island closing leaves a panel dialog alone", answers.isEmpty && c.current != nil)
        c.surfaceClosed(.panel)
        check("dialogs: the panel closing cancels its dialog; the next one shows", answers == ["A:cancel"] && c.current != nil)
        _ = c.handle(.escape)
        check("dialogs: Esc cancels", answers == ["A:cancel", "B:cancel"] && c.current == nil)

        answers = []
        c.present(info()) { _ in
            answers.append("A")
            c.present(info()) { _ in answers.append("C") }        // asked from a completion: behind what already waits
        }
        c.present(info()) { _ in answers.append("B") }
        c.press("ok"); c.press("ok"); c.press("ok")
        check("dialogs: a dialog asked from a completion waits its turn", answers == ["A", "B", "C"])

        // Choices.
        let pick = DialogSpec(icon: "iphone", title: "Pair", choices: [DialogChoice(id: "basic", title: "Basic"), DialogChoice(id: "agents", title: "Agents")],
                              buttons: [DialogButton(id: "send", title: "Send"), DialogButton(id: "cancel", title: "Cancel", role: .cancel)])
        var got: DialogResult?
        c.present(pick) { got = $0 }
        check("dialogs: a pick list starts on its first row", c.choice == "basic")
        c.tapChoice("agents")
        check("dialogs: tapping a row of a pick list only selects it", got == nil && c.choice == "agents")
        _ = c.handle(.returnKey)
        check("dialogs: …and the selection goes with the button", got == .button("send", text: "", choice: "agents"))
        var share = pick; share.choiceMode = .act; share.buttons = [DialogButton(id: "cancel", title: "Cancel", role: .cancel)]
        got = nil
        c.present(share) { got = $0 }
        c.tapChoice("agents")
        check("dialogs: tapping a row of the share list is the answer", got == .choice("agents") && c.current == nil)

        // Island → panel when the island isn't open; nowhere at all → the fallback, answered once.
        c.show = { _ in .panel }
        c.present(info(.island)) { _ in }
        check("dialogs: an island dialog with the island closed shows over the panel", c.surface == .panel)
        c.cancel()
        c.show = { _ in nil }
        var fell = 0, done = 0
        c.fallback = { _ in fell += 1; return .button("ok", text: "", choice: nil) }
        c.present(info()) { r in if r.buttonID == "ok" { done += 1 } }
        check("dialogs: with no surface at all the system alert answers (once)", fell == 1 && done == 1 && c.current == nil)

        // Text typed in the field is what a press hands back; a new text clears the old message.
        c.show = { s in s }
        var typed: DialogResult?
        c.present(field) { typed = $0 }
        c.text = "(["; c.press("add")
        check("dialogs: the field's message shows after an invalid press", c.problem == "bad" && typed == nil)
        c.text = "^IBAN"
        check("dialogs: …and goes away when the text changes", c.problem == nil)
        c.press("add")
        check("dialogs: the typed text is handed back", typed == .button("add", text: "^IBAN", choice: nil))
    }
}
