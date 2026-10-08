// The keyboard-only clipboard (Maccy's way of working, in Cocaine's surfaces): one global shortcut (⌃⌘V by default, its own,
// recorded in Settings → Island → Clipboard) opens the clipboard with the keyboard in it, either in the island (its Clipboard
// page) or in a small floating panel of Cocaine's own near the pointer, in the middle of the screen or where it was last left.
// Typing searches at once (words, fuzzy, a regular expression, or mixed), ↑ ↓ pick, Return pastes into the app that was in front,
// ⇧Return without formatting, ⌥Return copies only, ⌘1…9 paste the first nine, ⌥P / ⌘P pin, ⌥⌫ deletes, ⌘Y shows the details,
// Esc clears the search, then closes. The floating panel never activates Cocaine (a non-activating panel, like the island), so
// the app in front stays the one ⌘V goes to; pasting needs Accessibility, and without it the item is only copied, said so.
// Pure parts (search modes, order, keys, placement) are tested by --keyboard-test (Sources/KeyboardTests.swift).

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - Settings' choices

enum ClipPopupPlace: String, CaseIterable {
    case island, pointer, center, last
    var title: String {
        switch self {
        case .island: return L("Island")
        case .pointer: return L("Pointer")
        case .center: return L("Centre")
        case .last: return L("Last place")
        }
    }
    var spoken: String {
        switch self {
        case .island: return L("In the island")
        case .pointer: return L("Near the pointer")
        case .center: return L("In the middle of the screen")
        case .last: return L("Where it was last left")
        }
    }
}

enum ClipSearchMode: String, CaseIterable {
    case words, fuzzy, regex, mixed
    var title: String {
        switch self {
        case .words: return L("Words")
        case .fuzzy: return L("Fuzzy")
        case .regex: return L("Regex")
        case .mixed: return L("Mixed")
        }
    }
    var spoken: String {
        switch self {
        case .words: return L("Every word, anywhere")
        case .fuzzy: return L("Letters in order, gaps allowed")
        case .regex: return L("A regular expression")
        case .mixed: return L("Words, then regular expression, then fuzzy")
        }
    }
}

enum ClipSortOrder: String, CaseIterable {
    case recent, pasted, name
    var title: String {
        switch self {
        case .recent: return L("Newest")
        case .pasted: return L("Most pasted")
        case .name: return L("A–Z")
        }
    }
}

// MARK: - Search modes and order (pure)

enum ClipSearch {
    /// The longest text a regular expression or the fuzzy match looks at, per item (a 1 MB text stays fast to type against).
    static let regexLimit = 100_000
    static let fuzzyLimit = 4_000
    static let patternLimit = 300

    /// `items` already passed the filters (type:, app:, board:…, the chips); `words` are the rest of what was typed.
    static func run(_ items: [ClipItem], words: [String], mode: ClipSearchMode, order: ClipSortOrder,
                    describe: (ClipItem) -> String = { _ in "" }) -> [ClipItem] {
        guard !words.isEmpty else { return sorted(items, order) }
        switch mode {
        case .words: return sorted(items.filter { ClipHistoryCore.matches($0, words: words, describe: describe) }, order)
        case .regex: return sorted(regex(items, words.joined(separator: " "), describe: describe) ?? [], order)
        case .fuzzy: return fuzzy(items, words.joined(), describe: describe)
        case .mixed:
            let exact = items.filter { ClipHistoryCore.matches($0, words: words, describe: describe) }
            if !exact.isEmpty { return sorted(exact, order) }
            if let r = regex(items, words.joined(separator: " "), describe: describe), !r.isEmpty { return sorted(r, order) }
            return fuzzy(items, words.joined(), describe: describe)
        }
    }

    /// Is `pattern` a regular expression that compiles (and isn't too long)? An invalid one finds nothing in Regex mode.
    static func validRegex(_ pattern: String) -> Bool { compile(pattern) != nil }

    private static func compile(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty, pattern.count <= patternLimit else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func regex(_ items: [ClipItem], _ pattern: String, describe: (ClipItem) -> String) -> [ClipItem]? {
        guard let re = compile(pattern) else { return nil }
        return items.filter { c in
            let s = haystack(c, limit: regexLimit, describe: describe)
            return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
    }

    /// Best first; equal scores keep the history's order.
    static func fuzzy(_ items: [ClipItem], _ pattern: String, describe: (ClipItem) -> String) -> [ClipItem] {
        let scored = items.enumerated().compactMap { i, c -> (Int, Int, ClipItem)? in
            guard let s = fuzzyScore(pattern, in: haystack(c, limit: fuzzyLimit, describe: describe)) else { return nil }
            return (s, i, c)
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map(\.2)
    }

    /// The pattern's letters in order in `text` (any case and accents; spaces in the pattern ignored), or nil. Higher is better:
    /// letters next to each other and letters starting a word count more, a match that starts early a little more.
    static func fuzzyScore(_ pattern: String, in text: String) -> Int? {
        let fold: (String) -> [Character] = { Array($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
        let p = fold(pattern).filter { !$0.isWhitespace }
        guard !p.isEmpty else { return 0 }
        let t = fold(text)
        var score = 0, pi = 0, last = -2, first = -1
        for (i, ch) in t.enumerated() where pi < p.count {
            guard ch == p[pi] else { continue }
            if first < 0 { first = i }
            score += 1
            if last == i - 1 { score += 5 }                                       // next to the previous letter
            if i == 0 || !(t[i - 1].isLetter || t[i - 1].isNumber) { score += 3 } // at the start of a word
            last = i; pi += 1
        }
        guard pi == p.count else { return nil }
        return score + max(0, 10 - first / 10)
    }

    /// What the search looks through: the item's text (or file names and folders, or an image's size), its name, the text in it,
    /// and what `describe` adds (kind, source app).
    static func haystack(_ c: ClipItem, limit: Int, describe: (ClipItem) -> String) -> String {
        var s = ClipHistoryCore.haystack(c)
        if s.count > limit { s = String(s.prefix(limit)) }
        let extra = describe(c)
        return extra.isEmpty ? s : s + "\n" + extra
    }

    static func sorted(_ items: [ClipItem], _ order: ClipSortOrder) -> [ClipItem] {
        switch order {
        case .recent: return items
        case .pasted:
            return items.enumerated().sorted { a, b in
                let x = a.element.used.values.reduce(0, +), y = b.element.used.values.reduce(0, +)
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
        case .name:
            return items.enumerated().sorted { a, b in
                let o = sortName(a.element).localizedStandardCompare(sortName(b.element))
                return o != .orderedSame ? o == .orderedAscending : a.offset < b.offset
            }.map(\.element)
        }
    }

    static func sortName(_ c: ClipItem) -> String {
        if let t = c.title, !t.isEmpty { return t }
        switch c.kind {
        case .text: return String(c.text.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        case .files: return c.names.first ?? ""
        case .image: return "\u{10FFFF}"                                    // images after the names
        }
    }
}

// MARK: - The extra keys (pure: what a key does on the clipboard's list)

enum ClipKeyCommand: Equatable {
    case otherAction(shift: Bool)     // ⌥Return: copy only (or paste, when Return copies); ⇧ for the other formatting
    case toggleFavorite               // ⌥P (Maccy's pin)
    case pinMenu                      // ⌘P: Pin to…
    case deleteItem                   // ⌥⌫ (also while typing), ⌘⌫ (not while typing)
    case clearHistory                 // ⌥⌘⌫
    case first, last                  // Home / ⌘↑, End / ⌘↓
    case page(Int)                    // Page Up / Page Down
    case details                      // ⌘Y (also while typing)

    /// `char`: what the key types on the layout in use (letters are found by what they type, not where they are).
    static func interpret(_ code: UInt16, flags: NSEvent.ModifierFlags, char: String?, editing: Bool) -> ClipKeyCommand? {
        let mods = flags.intersection([.command, .option, .control, .shift])
        let c = Int(code)
        let letter = char?.lowercased()
        switch c {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mods == .option { return .otherAction(shift: false) }
            if mods == [.option, .shift] { return .otherAction(shift: true) }
        case kVK_Delete, kVK_ForwardDelete:
            if mods == [.option, .command] { return .clearHistory }
            if mods == .option { return .deleteItem }
            if mods == .command && !editing { return .deleteItem }
        case kVK_Home where mods.isEmpty: return .first
        case kVK_End where mods.isEmpty: return .last
        case kVK_UpArrow where mods == .command: return .first
        case kVK_DownArrow where mods == .command: return .last
        case kVK_PageUp where mods.isEmpty: return .page(-pageSize)
        case kVK_PageDown where mods.isEmpty: return .page(pageSize)
        default: break
        }
        let isP = letter.map { $0 == "p" } ?? (c == kVK_ANSI_P), isY = letter.map { $0 == "y" } ?? (c == kVK_ANSI_Y)
        if isP && mods == .option { return .toggleFavorite }
        if isP && mods == .command { return .pinMenu }
        if isY && mods == .command { return .details }
        return nil
    }

    static let pageSize = 8
}

// MARK: - Placing the floating clipboard (pure)

enum ClipPopupGeometry {
    static let size = CGSize(width: 440, height: 480)       // one column, like a menu (its box says under 400: ClipPopupView)
    static let margin: CGFloat = 8

    /// Where the panel goes: `screens` are the screens' visible frames (AppKit coordinates), the first the main one.
    static func frame(_ place: ClipPopupPlace, pointer: CGPoint, screens: [CGRect], size: CGSize = size, last: CGPoint?) -> CGRect {
        guard let screen = screens.first(where: { $0.insetBy(dx: -1, dy: -1).contains(pointer) }) ?? screens.first else {
            return CGRect(origin: .zero, size: size)
        }
        var r: CGRect
        switch place {
        case .pointer: r = CGRect(x: pointer.x - 20, y: pointer.y - size.height + 12, width: size.width, height: size.height)
        case .center: r = CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2 + screen.height * 0.08, width: size.width, height: size.height)
        case .island: r = CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - margin, width: size.width, height: size.height)
        case .last:
            if let o = last, let s = screens.first(where: { $0.contains(CGRect(origin: o, size: size)) }) {
                return clamp(CGRect(origin: o, size: size), to: s)
            }
            return frame(.center, pointer: pointer, screens: screens, size: size, last: nil)
        }
        r = clamp(r, to: screen)
        return r
    }

    /// Kept wholly on `screen` (with a margin); a screen smaller than the panel gets it from its top-left corner.
    static func clamp(_ r: CGRect, to screen: CGRect) -> CGRect {
        var o = r.origin
        o.x = min(max(o.x, screen.minX + margin), screen.maxX - r.width - margin)
        o.y = min(max(o.y, screen.minY + margin), screen.maxY - r.height - margin)
        if r.width + 2 * margin > screen.width { o.x = screen.minX }
        if r.height + 2 * margin > screen.height { o.y = screen.maxY - r.height }
        return CGRect(origin: o, size: r.size)
    }
}

// MARK: - Opening it

enum ClipKeyboard {
    /// The open shortcut: the island's Clipboard page with the keyboard in it, or the floating panel (the setting, or when the
    /// island can't show the clipboard: turned off, or no screen holds the Clipboard module). Pressed again: closes.
    static func open(model: IslandModel?, openKeyboard: () -> Void) {
        let h = ClipboardHistory.shared
        let place = ClipPopupPlace(rawValue: h.settings.openPlace) ?? .island
        if ClipPopup.shared.isOpen { ClipPopup.shared.close(restore: true); return }
        if place == .island, let model, islandHoldsClipboard(model) {
            if model.open && model.keyboard && model.shows("clipboard") { openKeyboard(); return }      // pressed again: closes
            prepare()
            model.tab = "clipboard"
            if !(model.open && model.keyboard) { openKeyboard() }
            ClipPageState.shared.keyboardHints = true
            announce()
            return
        }
        ClipPopup.shared.show(place == .island ? .island : place)
    }

    /// Is there a screen with the Clipboard module (the island is on whenever its model's tabs exist)?
    static func islandHoldsClipboard(_ model: IslandModel) -> Bool {
        model.screens.layout.screens.contains { s in s.visible && s.modules.contains { $0.kind == "clipboard" } }
    }

    /// A fresh start, like Maccy: no search, nothing picked, the newest item highlighted (so Return pastes it).
    static func prepare() {
        let h = ClipboardHistory.shared, ui = ClipPageState.shared
        h.query = ""
        ui.selection.clear()
        if ui.detail != nil { ui.closeDetail() }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        ui.target = front == Bundle.main.bundleIdentifier ? nil : front
        h.hovered = (ui.suggested(h) + ui.list(h)).first?.id
    }

    static func announce() {
        let h = ClipboardHistory.shared
        A11y.announce(String(format: L("Clipboard, %d items. Type to search, arrows to pick, Return pastes, Escape closes."), h.items.count))
    }

    /// Pasting can't reach the app (no Accessibility): said once per opening, honestly, with where to allow it.
    static var copyOnly: Bool { ClipboardHistory.shared.settings.directPaste && !PasteEngine.shared.trusted() }
}

// MARK: - The floating panel

private final class ClipPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ClipPopup: ObservableObject {
    static let shared = ClipPopup()
    @Published private(set) var isOpen = false
    private var panel: ClipPopupPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var dialogsWired = false
    private static let lastKey = "clipPopupOrigin"

    func show(_ place: ClipPopupPlace) {
        wireDialogs()
        ClipKeyboard.prepare()
        let p = panel ?? makePanel()
        panel = p
        let screens = NSScreen.screens.map(\.visibleFrame)
        let last = (AppDefaults.store.array(forKey: Self.lastKey) as? [Double]).flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        p.setFrame(ClipPopupGeometry.frame(place, pointer: NSEvent.mouseLocation, screens: screens, last: last), display: false)
        isOpen = true
        ClipPageState.shared.keyboardHints = true
        p.alphaValue = 1
        p.orderFrontRegardless()
        p.makeKey()
        startMonitors(p)
        DispatchQueue.main.async { [weak self] in        // the search field has the keyboard at once (IME, ⌫ and selection work as usual)
            guard let self, self.isOpen, let p = self.panel else { return }
            if let field = Self.textField(in: p.contentView) { p.makeFirstResponder(field) }
            A11y.layoutChanged(p)
            ClipKeyboard.announce()
        }
    }

    /// `restore`: closed without pasting (Esc, a click elsewhere): nothing else to do; pasting closes it first, then sends ⌘V.
    func close(restore: Bool) {
        guard isOpen, let p = panel else { return }
        isOpen = false
        AppDefaults.store.set([Double(p.frame.minX), Double(p.frame.minY)], forKey: Self.lastKey)
        DialogCenter.shared.surfaceClosed(.popup)
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        let ui = ClipPageState.shared
        if ui.editing { ui.editing = false }
        ui.keyboardHints = false
        ClipboardHistory.shared.hovered = nil
        p.makeFirstResponder(nil)
        p.orderOut(nil)                                  // the app in front gets its keyboard back (Cocaine was never activated)
    }

    /// The clipboard's editor and recorder ask for the keyboard: the panel has it already.
    func keyable(_ on: Bool) { if on { panel?.makeKey() } }

    var window: NSWindow? { panel }

    private func makePanel() -> ClipPopupPanel {
        let p = ClipPopupPanel(contentRect: CGRect(origin: .zero, size: ClipPopupGeometry.size), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true            // dragged elsewhere, "Last place" opens it there next time
        p.isReleasedWhenClosed = false
        p.animationBehavior = .utilityWindow
        p.contentView = NSHostingView(rootView: ClipPopupView())
        p.setAccessibilityLabel(L("Clipboard"))
        p.setAccessibilityRole(.window)
        p.setAccessibilitySubrole(.floatingWindow)
        return p
    }

    private func startMonitors(_ p: NSPanel) {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, self.isOpen, e.window === self.panel else { return e }
            return self.key(e) ? nil : e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.close(restore: true)                   // a click in another app
        }) { monitors.append(m) }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            guard let self, self.isOpen else { return }
            if DialogCenter.shared.isShowing(on: .popup) { return }
            self.close(restore: true)                    // ⌘Tab, another window took the keyboard
        })
    }

    /// The panel's keys: a dialog in it first, then the clipboard's (Sources/IslandClipboard.swift), then Esc.
    private func key(_ e: NSEvent) -> Bool {
        if DialogCenter.shared.isShowing(on: .popup) { return DialogCenter.shared.handleKey(e) }
        if ClipboardKeys.composing() { return false }                  // Esc, ↑↓, Return: the input method's while it composes
        let editing = panel?.firstResponder is NSTextView
        if ClipboardKeys.handle(e.keyCode, flags: e.modifierFlags, editing: editing, model: nil) { return true }
        guard e.keyCode == UInt16(kVK_Escape), e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        let h = ClipboardHistory.shared
        if !h.query.isEmpty { h.query = ""; return true }                                   // Esc: the search first, then the panel
        close(restore: true)
        return true
    }

    /// Dialogs asked from the clipboard (Pin to…, Rename, Paste as…, Clear) show in this panel while it is open.
    private func wireDialogs() {
        guard !dialogsWired else { return }
        dialogsWired = true
        let center = DialogCenter.shared
        let show = center.show, window = center.window
        center.show = { [weak self] want in
            if want == .island || want == .popup, let self, self.isOpen { self.panel?.makeKey(); return .popup }
            return show(want == .popup ? .island : want)
        }
        center.window = { [weak self] s in s == .popup ? self?.panel : window(s) }
    }

    static func textField(in v: NSView?) -> NSTextField? {
        guard let v else { return nil }
        if let f = v as? NSTextField, f.isEditable { return f }
        for s in v.subviews { if let f = textField(in: s) { return f } }
        return nil
    }
}

/// The panel's content: the clipboard page at its L size, black like the island, its dialogs drawn inside it.
private struct ClipPopupView: View {
    @ObservedObject var dialogs = DialogCenter.shared
    @ObservedObject var h = ClipboardHistory.shared

    var body: some View {
        let s = ClipPopupGeometry.size, pad = Space.l
        VStack(alignment: .leading, spacing: Space.s) {
            header
            ClipboardPopupContent(box: ModuleBox(size: .l, width: min(s.width - 2 * pad, 399), height: s.height - 2 * pad - 24), keyable: { ClipPopup.shared.keyable($0) })
        }
        .padding(pad)
        .frame(width: s.width, height: s.height, alignment: .topLeading)
        .dialogHost(dialogs, .popup, UI.dialog, maxWidth: s.width - 28, inset: EdgeInsets(top: 4, leading: 14, bottom: 8, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Clipboard"))
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "doc.on.clipboard").font(UI.icon).foregroundStyle(UI.secondary).accessibilityHidden(true)
            Text(L("Clipboard")).font(UI.groupTitle).foregroundStyle(UI.primary).lineLimit(1).accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.s)
            ViewThatFits(in: .horizontal) {
                Text(L("↑↓ pick · ↩ paste · ⇧↩ plain · ⌥↩ copy · ⌘1–9 · esc")).font(UI.detail).foregroundStyle(UI.hint).lineLimit(1)
                Text(L("↩ paste · ⇧↩ plain · esc")).font(UI.detail).foregroundStyle(UI.hint).lineLimit(1)
                EmptyView()
            }
            .accessibilityHidden(true)
            Button { ClipPopup.shared.close(restore: true) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.hint)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(MotionGlyphStyle()).help(L("Close (Esc)")).accessibilityLabel(L("Close"))
        }
        .frame(height: 24)
    }
}

// MARK: - Render (checking translations fit; sample items only, never the user's history)

/// `--render-clip-popup <out.png> [--lang de] [--noaccess] [--query text] [--dialog trash]`, run from main.swift: the floating
/// clipboard as opened from the keyboard, drawn offscreen with the clipboard fixtures (Sources/ClipboardFixtures.swift).
func cliRenderClipPopup() -> Never {
    _ = NSApplication.shared
    precondition(AppDefaults.isolated, "renders run with memory-only settings (main.swift): their samples never reach the real ones")
    Motion.disabled = true
    let args = CommandLine.arguments
    let pm = PanelModel()
    pm.persistLanguage = false
    pm.language = args.firstIndex(of: "--lang").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
    ClipboardFixtures.apply(["--clipboard-fixture", args.contains("--noaccess") ? "noaccess" : "list"], nil)
    let h = ClipboardHistory.shared, ui = ClipPageState.shared
    h.hovered = h.items.dropFirst().first?.id
    ui.keyboardHints = true
    if let i = args.firstIndex(of: "--query"), i + 1 < args.count { h.query = args[i + 1] }
    if args.contains("--dialog") {                                   // Clear's question, inside the panel
        DialogCenter.shared.show = { _ in .popup }
        var spec = IslandChoices.spec(L("Clear"), icon: "trash", IslandChoices.clipboardTrash)
        spec.surface = .popup
        DialogCenter.shared.present(spec) { _ in }
    }
    let s = ClipPopupGeometry.size
    let view = ZStack {
        LinearGradient(colors: [Color(red: 0.55, green: 0.7, blue: 0.9), Color(red: 0.8, green: 0.6, blue: 0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        ClipPopupView()
    }.frame(width: s.width + 40, height: s.height + 40)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}
