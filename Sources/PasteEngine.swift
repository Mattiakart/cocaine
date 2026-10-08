// Pasting from the clipboard history into the app in front (Paste's "direct paste"): the item goes on the clipboard, the island
// closes, and Cocaine sends ⌘V, which needs the Accessibility permission Cocaine already asks for (Stay active, the HUD keys).
// Without it, or with direct paste off, the item is only copied and the island says "press ⌘V". Cocaine sends ⌘V and nothing
// else, only to the app that was in front, and never watches keys (no event tap): the Paste Stack's "paste the next one" is
// Cocaine's own global shortcut. Also here: the text transformations, multi-selection and merging (pure, tested in
// Sources/PasteTests.swift with a fake pasteboard and a fake event poster: no real ⌘V is ever sent by the tests).

import AppKit
import Carbon.HIToolbox

/// Sends ⌘V to the frontmost app (the tests' fake records instead).
protocol PasteEventPoster: AnyObject {
    func postPaste(keyCode: CGKeyCode) -> Bool
}

final class CGPasteEventPoster: PasteEventPoster {
    func postPaste(keyCode: CGKeyCode) -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

final class PasteEngine: ObservableObject {
    static let shared = PasteEngine(history: .shared)

    enum Outcome: Equatable {
        case pasted(String)             // ⌘V sent to this app
        case copied(Reason)             // on the clipboard only, and why
        case failed                     // couldn't even be copied (a file that is gone, an image without its data)
    }
    enum Reason: Equatable { case directOff, noPermission, noTarget, targetChanged }

    let history: ClipboardHistory
    var poster: PasteEventPoster = CGPasteEventPoster()
    /// May Cocaine send key events (Accessibility → Cocaine)?
    var trusted: () -> Bool = { CGPreflightPostEventAccess() }
    var frontApp: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var ownBundle: String? = Bundle.main.bundleIdentifier
    /// Waits, then runs (tests run it at once).
    var after: (TimeInterval, @escaping () -> Void) -> Void = { d, f in DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f) }
    /// Modifier keys still held (the shortcut that asked for the paste): ⌘V waits for them to be let go.
    var modifiersDown: () -> Bool = {
        !CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]).isEmpty
    }
    /// Closes the island and gives the keyboard back to the app in front (set by the island).
    var closeIsland: () -> Void = {}
    /// A short message under the notch (set by the island).
    var notify: (_ icon: String, _ text: String) -> Void = { _, _ in }

    /// The Paste Stack: what "Paste next" pastes, in order.
    @Published private(set) var stack = PasteStack()
    /// What the last paste did (the island's one-line state).
    @Published private(set) var last: Outcome?

    init(history: ClipboardHistory) { self.history = history }

    var canPasteDirectly: Bool { history.settings.directPaste && trusted() }

    /// Pastes `item` into the app in front (`target`: that app, as seen when the island opened). `plain`: without formatting
    /// (nil: as the settings say). `text`: this text instead of the item's (a transformation, a filled-in snippet, a merge).
    /// `direct`: paste even when Return only copies (⌥Return, Sources/ClipKeyboard.swift); nil: as the settings say.
    func paste(_ item: ClipItem, plain: Bool? = nil, text: String? = nil, target: String? = nil, direct: Bool? = nil, completion: ((Outcome) -> Void)? = nil) {
        let target = target ?? frontApp()
        guard history.copy(item, plain: plain, text: text) else { finish(.failed, item: item, completion) ; return }
        closeIsland()
        guard direct ?? history.settings.directPaste else { finish(.copied(.directOff), item: item, completion); return }
        guard trusted() else { finish(.copied(.noPermission), item: item, completion); return }
        guard let target, target != ownBundle else { finish(.copied(.noTarget), item: item, completion); return }
        // The island lets go of the keyboard first; the keys of the shortcut that asked are let go of; the app is still there.
        waitForKeys(tries: 20) { [weak self] in
            guard let self else { return }
            guard self.frontApp() == target else { self.finish(.copied(.targetChanged), item: item, completion); return }
            guard self.poster.postPaste(keyCode: Self.vKeyCode()) else { self.finish(.copied(.noPermission), item: item, completion); return }
            self.history.modify(item.id) { c in
                c.used[target, default: 0] += 1
                c.lastUsed = self.history.now()
                if c.used.count > ClipItem.maxUsedApps, let least = c.used.min(by: { $0.value < $1.value })?.key, least != target { c.used[least] = nil }
            }
            self.finish(.pasted(target), item: item, completion)
        }
    }

    private func waitForKeys(tries: Int, _ then: @escaping () -> Void) {
        after(tries == 20 ? 0.12 : 0.05) { [weak self] in
            guard let self else { return }
            if tries > 0 && self.modifiersDown() { self.waitForKeys(tries: tries - 1, then); return }
            then()
        }
    }

    private func finish(_ o: Outcome, item: ClipItem, _ completion: ((Outcome) -> Void)?) {
        last = o
        switch o {
        case .pasted: break
        case .copied(.noPermission): notify("doc.on.clipboard.fill", L("Copied: press ⌘V (allow Accessibility to paste directly)"))
        case .copied: notify("doc.on.clipboard.fill", L("Copied: press ⌘V to paste"))
        case .failed: notify("exclamationmark.triangle.fill", item.kind == .files ? L("The file is no longer there") : L("Can't copy it"))
        }
        completion?(o)
    }

    /// Several items as one text, in the order given, with the separator of the settings (images left out).
    func pasteTogether(_ items: [ClipItem], plain: Bool? = nil, completion: ((Outcome) -> Void)? = nil) {
        guard let first = items.first, let joined = ClipMerge.text(items, separator: history.settings.separatorText) else {
            if let first = items.first { paste(first, plain: plain, completion: completion) }
            return
        }
        paste(first, plain: true, text: joined, completion: completion)
    }

    // MARK: the Paste Stack

    /// Starts a stack with these items (in this order): each "Paste next" (its own shortcut) pastes the next one.
    func startStack(_ ids: [UUID]) {
        stack = PasteStack(queue: ids)
        closeIsland()
        let keys = history.settings.pasteNext?.glyphs ?? "—"
        notify("square.stack.3d.down.right.fill", String(format: L("Paste Stack: %d items, %@ pastes the next"), ids.count, keys))
        history.onBoardsChange()                       // registers "Paste next"
    }

    func clearStack() {
        guard !stack.isEmpty else { return }
        stack = PasteStack()
        history.onBoardsChange()
    }

    func reverseStack() { stack.reverse() }

    /// "Paste next": the next item of the stack (gone ones are skipped); the last one ends the stack.
    @discardableResult
    func pasteNext() -> Bool {
        while let id = stack.next() {
            guard let item = history.items.first(where: { $0.id == id }) else { continue }
            let left = stack.count
            SnippetPaste.paste(item, engine: self) { [weak self] _ in
                guard let self else { return }
                self.notify("square.stack.3d.down.right.fill", left > 0 ? String(format: L("%d left in the Paste Stack"), left) : L("Paste Stack done"))
                if left == 0 { self.history.onBoardsChange() }
            }
            return true
        }
        history.onBoardsChange()
        return false
    }

    /// The key that types "v" on the keyboard layout in use (⌘V is that key with ⌘), else ANSI V.
    static func vKeyCode(translate: ShortcutNames.Translate = ShortcutNames.translate) -> CGKeyCode {
        if translate(UInt32(kVK_ANSI_V))?.lowercased() == "v" { return CGKeyCode(kVK_ANSI_V) }
        for code in 0..<128 where translate(UInt32(code))?.lowercased() == "v" { return CGKeyCode(code) }
        return CGKeyCode(kVK_ANSI_V)
    }
}

/// What "Paste next" pastes, in order (pure).
struct PasteStack: Equatable {
    private(set) var queue: [UUID] = []
    var count: Int { queue.count }
    var isEmpty: Bool { queue.isEmpty }
    init(queue: [UUID] = []) {
        var seen = Set<UUID>()
        self.queue = queue.filter { seen.insert($0).inserted }
    }
    mutating func next() -> UUID? { queue.isEmpty ? nil : queue.removeFirst() }
    mutating func reverse() { queue.reverse() }
    mutating func remove(_ id: UUID) { queue.removeAll { $0 == id } }
}

// MARK: - Several items at once

/// The island's multi-selection (⌘-click, ⇧-click, ⌘A, ⇧↑↓), in the order things were picked (pure).
struct ClipSelection: Equatable {
    private(set) var ids: [UUID] = []
    private(set) var anchor: UUID?
    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// A plain click: just this one.
    mutating func only(_ id: UUID) { ids = [id]; anchor = id }
    /// ⌘-click: in or out.
    mutating func toggle(_ id: UUID) {
        if let i = ids.firstIndex(of: id) { ids.remove(at: i); if anchor == id { anchor = ids.last } } else { ids.append(id); anchor = id }
    }
    /// ⇧-click: everything from the anchor to here, in the list's order (as Finder does).
    mutating func extend(to id: UUID, in list: [UUID]) {
        guard let a = anchor, let i = list.firstIndex(of: a), let j = list.firstIndex(of: id) else { only(id); return }
        ids = Array(list[min(i, j)...max(i, j)])
        anchor = a
    }
    /// ⇧↓ / ⇧↑ from `current` (the highlighted row): the range grows to the next row. Returns the row now highlighted.
    mutating func step(_ n: Int, from current: UUID?, in list: [UUID]) -> UUID? {
        guard !list.isEmpty else { return nil }
        guard let cur = current, let i = list.firstIndex(of: cur) else {
            let f = n > 0 ? list[0] : list[list.count - 1]
            only(f)
            return f
        }
        if anchor == nil || !contains(cur) { only(cur) }
        let j = min(list.count - 1, max(0, i + n))
        extend(to: list[j], in: list)
        return list[j]
    }
    mutating func selectAll(_ list: [UUID]) { ids = list; anchor = list.first }
    mutating func clear() { ids = []; anchor = nil }
    /// Items gone from the list leave the selection.
    mutating func keep(_ valid: Set<UUID>) { ids.removeAll { !valid.contains($0) }; if let a = anchor, !valid.contains(a) { anchor = ids.last } }
    /// In the list's order (top to bottom), for "paste together" when order of picking isn't wanted.
    func ordered(in list: [UUID]) -> [UUID] { list.filter { ids.contains($0) } }
}

enum ClipMerge {
    /// The text of several items joined by `separator`: texts as they are, files as their paths; images are left out. Nil when
    /// there is no text at all. At most `limit` characters.
    static func text(_ items: [ClipItem], separator: String, limit: Int = 2_000_000) -> String? {
        let parts: [String] = items.compactMap { c in
            switch c.kind {
            case .text: return c.text
            case .files: return c.paths.joined(separator: "\n")
            case .image: return nil
            }
        }
        guard !parts.isEmpty else { return nil }
        let s = parts.joined(separator: separator)
        return s.count > limit ? String(s.prefix(limit)) : s
    }
}

extension ClipboardHistory {
    /// Merges items into one new text item at the top (the originals stay). Nil when there is no text in them.
    @discardableResult
    func merge(_ ids: [UUID]) -> ClipItem? {
        let chosen = ids.compactMap { id in items.first { $0.id == id } }
        guard chosen.count >= 2, let t = ClipMerge.text(chosen, separator: settings.separatorText),
              t.utf8.count <= settings.maxItemBytes else { return nil }
        let n = ClipItem.text(t, date: now(), source: nil)
        add(n)
        return items.first { $0.kind == .text && $0.digest == n.digest }
    }
}

// MARK: - Transformations

/// Safe, local changes to a text before pasting it (none of them touches the network or runs anything).
enum ClipTransform: String, CaseIterable, Identifiable {
    case upper, lower, title, trim, singleLine, sortLines, uniqueLines, jsonPretty, jsonMinify, urlDecode, urlEncode, base64Encode, base64Decode, stripTracking
    var id: String { rawValue }

    var title: String {
        switch self {
        case .upper: return L("UPPERCASE")
        case .lower: return L("lowercase")
        case .title: return L("Title Case")
        case .trim: return L("Trim spaces")
        case .singleLine: return L("Join lines")
        case .sortLines: return L("Sort lines")
        case .uniqueLines: return L("Remove duplicate lines")
        case .jsonPretty: return L("Format JSON")
        case .jsonMinify: return L("Compact JSON")
        case .urlDecode: return L("URL decode")
        case .urlEncode: return L("URL encode")
        case .base64Encode: return L("Base64 encode")
        case .base64Decode: return L("Base64 decode")
        case .stripTracking: return L("Remove link tracking")
        }
    }

    var symbol: String {
        switch self {
        case .upper, .lower, .title: return "textformat"
        case .trim, .singleLine: return "text.alignleft"
        case .sortLines, .uniqueLines: return "arrow.up.arrow.down"
        case .jsonPretty, .jsonMinify: return "curlybraces"
        case .urlDecode, .urlEncode, .stripTracking: return "link"
        case .base64Encode, .base64Decode: return "number"
        }
    }

    static let maxInput = 1_000_000

    /// The changed text, or nil when it doesn't apply (not JSON, not Base64, too big, nothing to change).
    func apply(_ s: String) -> String? {
        guard s.utf8.count <= Self.maxInput else { return nil }
        let out: String?
        switch self {
        case .upper: out = s.uppercased(with: Language.locale)
        case .lower: out = s.lowercased(with: Language.locale)
        case .title: out = s.capitalized(with: Language.locale)
        case .trim: out = s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        case .singleLine: out = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        case .sortLines: out = s.components(separatedBy: "\n").sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
        case .uniqueLines:
            var seen = Set<String>()
            out = s.components(separatedBy: "\n").filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .jsonPretty, .jsonMinify:
            guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
                  let back = try? JSONSerialization.data(withJSONObject: o, options: self == .jsonPretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed] : [.withoutEscapingSlashes, .fragmentsAllowed])
            else { return nil }
            out = String(data: back, encoding: .utf8)
        case .urlDecode: out = s.removingPercentEncoding
        case .urlEncode: out = s.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)
        case .base64Encode: out = Data(s.utf8).base64EncodedString()
        case .base64Decode:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let d = Data(base64Encoded: t, options: .ignoreUnknownCharacters), !d.isEmpty, let str = String(data: d, encoding: .utf8) else { return nil }
            out = str
        case .stripTracking: out = Self.stripTracking(s)
        }
        guard let o = out, o != s else { return nil }
        return o
    }

    /// Links in the text without their tracking parameters (utm_*, fbclid, gclid, mc_eid…).
    static func stripTracking(_ s: String) -> String {
        let tracking: (String) -> Bool = { n in
            let k = n.lowercased()
            return k.hasPrefix("utm_") || ["fbclid", "gclid", "dclid", "msclkid", "mc_eid", "mc_cid", "igshid", "yclid", "_hsenc", "_hsmi", "ref_src"].contains(k)
        }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return s }
        var out = s
        let ns = s as NSString
        for m in det.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let url = m.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let q = c.queryItems, q.contains(where: { tracking($0.name) }) else { continue }
            let kept = q.filter { !tracking($0.name) }
            c.queryItems = kept.isEmpty ? nil : kept
            guard let clean = c.string, let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: clean)
        }
        return out
    }

    /// The transformations that change this text (so the list offers only those).
    static func applicable(to s: String) -> [ClipTransform] { allCases.filter { $0.apply(s) != nil } }
}

extension CharacterSet {
    /// What may stay as it is in a URL query value (RFC 3986 unreserved).
    static let urlQueryValueAllowed: CharacterSet = {
        var c = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        c.insert(charactersIn: "-._~")
        return c
    }()
}
