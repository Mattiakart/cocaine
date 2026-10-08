import AppKit
import CryptoKit
import Foundation
import ImageIO
import Security

// The island's clipboard history: text (with its formatting), images and file references, searchable, with pinboards. The
// history is memory only by default; saving it on this Mac is optional and encrypted (key in the Keychain). Pinboards
// (Sources/Pinboards.swift) are always saved, encrypted with the same key, so what the user pins survives a restart even with
// a memory-only history. Nothing here ever leaves the Mac.
// The views are in IslandClipboard*.swift (the island's page) and PanelView.swift/PinboardsSettings.swift (its settings);
// pasting into the app in front is Sources/PasteEngine.swift, search filters and suggestions Sources/ClipboardSearch.swift.

// MARK: - Items and settings

enum ClipKind: String, Codable { case text, image, files }

/// A text item's formatted flavours, kept (bounded) so it can be pasted with its formatting; the plain text stays the item's
/// text and what search looks at. On disk it is its own encrypted file, like an image.
struct ClipRich: Codable, Equatable {
    var rtf: Data?
    var html: Data?
    var bytes: Int { (rtf?.count ?? 0) + (html?.count ?? 0) }
    var isEmpty: Bool { (rtf?.isEmpty ?? true) && (html?.isEmpty ?? true) }
    /// The most a rich item keeps, whatever the item size limit.
    static let maxBytes = 1_000_000

    /// Within `limit` bytes: both when they fit, else RTF alone (the most faithful), else HTML alone, else nothing.
    static func bounded(rtf: Data?, html: Data?, limit: Int) -> ClipRich? {
        let l = min(limit, maxBytes)
        let r = rtf.flatMap { $0.isEmpty ? nil : $0 }, h = html.flatMap { $0.isEmpty ? nil : $0 }
        if (r?.count ?? 0) + (h?.count ?? 0) <= l, r != nil || h != nil { return ClipRich(rtf: r, html: h) }
        if let r, r.count <= l { return ClipRich(rtf: r, html: nil) }
        if let h, h.count <= l { return ClipRich(rtf: nil, html: h) }
        return nil
    }
}

/// A pinboard item used as a snippet: pasted by its own global shortcut, with placeholders filled in (Sources/Snippets.swift).
struct SnippetInfo: Codable, Equatable {
    var hotkey: Shortcut?
}

struct ClipItem: Identifiable, Equatable, Codable {
    var id = UUID()
    var kind: ClipKind
    var text = ""                    // .text: the plain text, exactly as copied
    var paths: [String] = []         // .files: references (paths), never copies
    var width = 0, height = 0        // .image: pixels
    var bytes = 0                    // what the size limits count (text and its formatting, or the PNG)
    var digest = ""                  // the same content has the same digest: copying it again moves it to the top
    var date = Date()
    var boards: [UUID] = []          // the pinboards it is on (ClipBoard.favoritesID: the star); on any, it is kept for good
    var source: String?              // the app it came from (bundle id), or ClipRules.remoteSource (another device)
    // Schema 2 (all optional: an index of schema 1 loads as is).
    var title: String?               // the user's name for it, shown instead of its text
    var hasRich = false              // formatted flavours were kept (`rich` in memory, its own encrypted file on disk)
    var ocr: String?                 // .image: text recognised in it (on this Mac, secrets masked), for search and "Copy text"
    var used: [String: Int] = [:]    // pasted into (bundle id → times), for the suggestions by the app in front
    var lastUsed: Date?
    var snippet: SnippetInfo?        // a snippet: placeholders filled when pasted, maybe a global shortcut
    var payload: Data?               // .image: the PNG, in memory only (on disk it's its own encrypted file)
    var rich: ClipRich?              // .text: the formatted flavours, in memory only (likewise)

    static let maxTitle = 120
    static let maxOCR = 4_000
    static let maxUsedApps = 12

    init(id: UUID = UUID(), kind: ClipKind, text: String = "", paths: [String] = [], width: Int = 0, height: Int = 0, bytes: Int = 0,
         digest: String = "", date: Date = Date(), boards: [UUID] = [], source: String? = nil, payload: Data? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.paths = paths; self.width = width; self.height = height
        self.bytes = bytes; self.digest = digest; self.date = date; self.boards = boards; self.source = source; self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, text, paths, width, height, bytes, digest, date, pinned, boards, source, title, rich, ocr, used, lastUsed, snippet
    }

    /// Any schema up to this one: what is missing takes its default. Schema 1's `pinned` puts the item on Favorites. Only an
    /// item without an id or with a kind this version doesn't know fails (and only that item is dropped).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ClipKind.self, forKey: .kind)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        paths = (try? c.decodeIfPresent([String].self, forKey: .paths)) ?? []
        width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? 0
        height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? 0
        bytes = (try? c.decodeIfPresent(Int.self, forKey: .bytes)) ?? 0
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date(timeIntervalSince1970: 0)
        source = (try? c.decodeIfPresent(String.self, forKey: .source)).flatMap { $0 }
        if let b = try? c.decodeIfPresent([UUID].self, forKey: .boards) { boards = b }
        else if (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) == true { boards = [ClipBoard.favoritesID] }
        title = (try? c.decodeIfPresent(String.self, forKey: .title)).flatMap { $0 }.map { String($0.prefix(Self.maxTitle)) }
        hasRich = (try? c.decodeIfPresent(Bool.self, forKey: .rich)) ?? false
        ocr = (try? c.decodeIfPresent(String.self, forKey: .ocr)).flatMap { $0 }.map { String($0.prefix(Self.maxOCR)) }
        used = (try? c.decodeIfPresent([String: Int].self, forKey: .used)) ?? [:]
        lastUsed = (try? c.decodeIfPresent(Date.self, forKey: .lastUsed)).flatMap { $0 }
        snippet = (try? c.decodeIfPresent(SnippetInfo.self, forKey: .snippet)).flatMap { $0 }
        let d = (try? c.decodeIfPresent(String.self, forKey: .digest)) ?? ""
        switch kind {                                        // a digest that is missing is worked out again where it can be
        case .text where d.isEmpty: digest = Self.digest(.text, Data(text.utf8))
        case .files where d.isEmpty: digest = Self.digest(.files, Data(paths.joined(separator: "\n").utf8))
        default: digest = d.isEmpty ? "id:" + id.uuidString : d
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind)
        if !text.isEmpty { try c.encode(text, forKey: .text) }
        if !paths.isEmpty { try c.encode(paths, forKey: .paths) }
        if kind == .image { try c.encode(width, forKey: .width); try c.encode(height, forKey: .height) }
        try c.encode(bytes, forKey: .bytes); try c.encode(digest, forKey: .digest); try c.encode(date, forKey: .date)
        if !boards.isEmpty { try c.encode(boards, forKey: .boards) }
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(title, forKey: .title)
        if hasRich { try c.encode(true, forKey: .rich) }
        try c.encodeIfPresent(ocr, forKey: .ocr)
        if !used.isEmpty { try c.encode(used, forKey: .used) }
        try c.encodeIfPresent(lastUsed, forKey: .lastUsed)
        try c.encodeIfPresent(snippet, forKey: .snippet)
    }

    /// On a pinboard (any): kept for good, saved even with a memory-only history. Setting it puts the item on Favorites (or
    /// takes it off every pinboard).
    var pinned: Bool {
        get { !boards.isEmpty }
        set { if newValue { if boards.isEmpty { boards = [ClipBoard.favoritesID] } } else { boards = [] } }
    }
    var isFavorite: Bool { boards.contains(ClipBoard.favoritesID) }
    var remote: Bool { source == ClipRules.remoteSource }
    var names: [String] { paths.map { ($0 as NSString).lastPathComponent } }

    static func digest(_ kind: ClipKind, _ data: Data) -> String {
        var h = SHA256()
        h.update(data: Data(kind.rawValue.utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func text(_ s: String, date: Date = Date(), source: String? = nil, rich: ClipRich? = nil) -> ClipItem {
        let d = Data(s.utf8)
        var i = ClipItem(kind: .text, text: s, bytes: d.count + (rich?.bytes ?? 0), digest: digest(.text, d), date: date, source: source)
        if let rich, !rich.isEmpty { i.rich = rich; i.hasRich = true }
        return i
    }
    static func files(_ paths: [String], date: Date = Date(), source: String? = nil) -> ClipItem {
        let d = Data(paths.joined(separator: "\n").utf8)
        return ClipItem(kind: .files, paths: paths, bytes: d.count, digest: digest(.files, d), date: date, source: source)
    }
    static func image(png: Data, width: Int, height: Int, date: Date = Date(), source: String? = nil) -> ClipItem {
        ClipItem(kind: .image, width: width, height: height, bytes: png.count, digest: digest(.image, png), date: date, source: source, payload: png)
    }
}

struct ClipSettings: Codable, Equatable {
    var persist = false              // off: memory only, as it always was (pinboards are saved either way)
    var maxItems = 50                // pinboard items don't count
    var maxAgeHours = 24 * 7         // 0: no limit
    var maxTotalMB = 50
    var maxItemMB = 10
    var skipSecrets = true           // card numbers, keys, tokens
    var excludedApps: [String] = []  // bundle ids, on top of the password managers (always excluded)
    var patterns: [String] = []      // the user's own regular expressions: matching text is skipped
    // 2.7: pasting, formatting, other devices, text in images, the command line.
    var directPaste = true           // Return / double-click paste into the app in front (Accessibility); off: copy only
    var pastePlain = false           // paste without formatting unless ⇧ is held (⇧ then keeps it)
    var includeRemote = true         // keep copies from another device (Universal Clipboard)
    var ocr = false                  // recognise the text in copied images (on this Mac), for search
    var separator = "newline"        // between items pasted or merged together (separatorChoices)
    var suggestions = true           // suggest items by the app in front
    var hideFromCapture = false      // the island isn't recorded or shared while it shows the clipboard
    var cliAccess = 0                // `cocaine clip`: 0 off, 1 add only, 2 add, read and paste
    var pasteNext: Shortcut? = ClipSettings.defaultPasteNext   // the Paste Stack's "paste the next one"
    // 2.8: the keyboard-only clipboard (Sources/ClipKeyboard.swift).
    var openShortcut: Shortcut? = ClipSettings.defaultOpen     // opens the clipboard with the keyboard in it, from any app
    var openPlace = "island"         // ClipPopupPlace: island, pointer, center, last
    var searchMode = "words"         // ClipSearchMode: words, fuzzy, regex, mixed
    var sortOrder = "recent"         // ClipSortOrder: recent, pasted, name
    var numberHints = true           // ⌘1…⌘9 shown on the first rows while the keyboard is in the clipboard

    static let itemChoices = [25, 50, 100, 200, 500]
    static let ageChoices = [1, 24, 24 * 7, 24 * 30, 0]
    static let totalChoices = [10, 50, 100, 250]
    static let itemSizeChoices = [1, 5, 10, 25]
    static let separatorChoices = ["newline", "blank", "space", "comma", "tab", "none"]
    static let defaultPasteNext = Shortcut(keyCode: 9, mods: Shortcut.hyper)       // ⌃⌥⌘V (the key of ANSI V)
    static let defaultOpen = Shortcut(keyCode: 9, mods: Shortcut.ctrl | Shortcut.cmd)  // ⌃⌘V
    static let key = "clipboardSettings"

    init() {}
    /// Missing keys (older or newer versions) take their default instead of losing every setting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? def }
        persist = v(.persist, d.persist); maxItems = v(.maxItems, d.maxItems); maxAgeHours = v(.maxAgeHours, d.maxAgeHours)
        maxTotalMB = v(.maxTotalMB, d.maxTotalMB); maxItemMB = v(.maxItemMB, d.maxItemMB); skipSecrets = v(.skipSecrets, d.skipSecrets)
        excludedApps = v(.excludedApps, d.excludedApps); patterns = v(.patterns, d.patterns)
        directPaste = v(.directPaste, d.directPaste); pastePlain = v(.pastePlain, d.pastePlain); includeRemote = v(.includeRemote, d.includeRemote)
        ocr = v(.ocr, d.ocr); suggestions = v(.suggestions, d.suggestions); hideFromCapture = v(.hideFromCapture, d.hideFromCapture)
        let sep = v(.separator, d.separator); separator = Self.separatorChoices.contains(sep) ? sep : d.separator
        cliAccess = min(2, max(0, v(.cliAccess, d.cliAccess)))
        if c.contains(.pasteNext) { pasteNext = (try? c.decodeNil(forKey: .pasteNext)) == true ? nil : (try? c.decode(Shortcut.self, forKey: .pasteNext)) ?? d.pasteNext }
        if c.contains(.openShortcut) { openShortcut = (try? c.decodeNil(forKey: .openShortcut)) == true ? nil : (try? c.decode(Shortcut.self, forKey: .openShortcut)) ?? d.openShortcut }
        let place = v(.openPlace, d.openPlace); openPlace = ClipPopupPlace(rawValue: place) != nil ? place : d.openPlace
        let mode = v(.searchMode, d.searchMode); searchMode = ClipSearchMode(rawValue: mode) != nil ? mode : d.searchMode
        let order = v(.sortOrder, d.sortOrder); sortOrder = ClipSortOrder(rawValue: order) != nil ? order : d.sortOrder
        numberHints = v(.numberHints, d.numberHints)
    }

    enum CodingKeys: String, CodingKey {
        case persist, maxItems, maxAgeHours, maxTotalMB, maxItemMB, skipSecrets, excludedApps, patterns, directPaste, pastePlain, includeRemote,
             ocr, separator, suggestions, hideFromCapture, cliAccess, pasteNext, openShortcut, openPlace, searchMode, sortOrder, numberHints
    }

    /// Every key, and a shortcut taken away as an explicit null (left out, it would come back as its default at the next launch).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(persist, forKey: .persist); try c.encode(maxItems, forKey: .maxItems); try c.encode(maxAgeHours, forKey: .maxAgeHours)
        try c.encode(maxTotalMB, forKey: .maxTotalMB); try c.encode(maxItemMB, forKey: .maxItemMB); try c.encode(skipSecrets, forKey: .skipSecrets)
        try c.encode(excludedApps, forKey: .excludedApps); try c.encode(patterns, forKey: .patterns); try c.encode(directPaste, forKey: .directPaste)
        try c.encode(pastePlain, forKey: .pastePlain); try c.encode(includeRemote, forKey: .includeRemote); try c.encode(ocr, forKey: .ocr)
        try c.encode(separator, forKey: .separator); try c.encode(suggestions, forKey: .suggestions); try c.encode(hideFromCapture, forKey: .hideFromCapture)
        try c.encode(cliAccess, forKey: .cliAccess)
        if let s = pasteNext { try c.encode(s, forKey: .pasteNext) } else { try c.encodeNil(forKey: .pasteNext) }
        if let s = openShortcut { try c.encode(s, forKey: .openShortcut) } else { try c.encodeNil(forKey: .openShortcut) }
        try c.encode(openPlace, forKey: .openPlace); try c.encode(searchMode, forKey: .searchMode); try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(numberHints, forKey: .numberHints)
    }

    var maxItemBytes: Int { max(1, maxItemMB) * 1_000_000 }
    var maxTotalBytes: Int { max(1, maxTotalMB) * 1_000_000 }

    /// The text put between items pasted or merged together.
    var separatorText: String { Self.separatorText(separator) }
    static func separatorText(_ id: String) -> String {
        switch id { case "blank": return "\n\n"; case "space": return " "; case "comma": return ", "; case "tab": return "\t"; case "none": return ""; default: return "\n" }
    }

    static func load(_ d: UserDefaults) -> ClipSettings {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(ClipSettings.self, from: data) else { return ClipSettings() }
        return s
    }
    func save(_ d: UserDefaults) { if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) } }
}

// MARK: - What is never kept

enum ClipRules {
    /// Marks what Cocaine itself puts on the clipboard, so copying an item again isn't captured as a new one.
    static let ownType = "local.cocaine.clipboard.own"
    /// What macOS adds to content that came from another device through Universal Clipboard (Handoff).
    static let remoteType = "com.apple.is-remote-clipboard"
    /// The `source` of such an item ("Another device"; never the app that happened to be in front).
    static let remoteSource = "device:remote"
    /// nspasteboard.org's markers (and the older ones it lists): passwords, one-time content, generated content.
    static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
        "Pasteboard generator type", "net.antelle.keeweb",
    ]
    /// Password managers, by a piece of their bundle id: always excluded, whatever the user's list says.
    static let passwordApps = ["1password", "onepassword", "bitwarden", "keepass", "lastpass", "dashlane", "enpass", "strongbox",
                               "nordpass", "protonpass", "proton.pass", "com.apple.keychainaccess", "com.apple.passwords"]

    static func isConcealed(_ types: [String]) -> Bool { types.contains { concealedTypes.contains($0) } }
    static func isRemote(_ types: [String]) -> Bool { types.contains(remoteType) }

    static func isPasswordApp(_ bundle: String?) -> Bool {
        guard let b = bundle?.lowercased(), !b.isEmpty else { return false }
        return passwordApps.contains { b.contains($0) }
    }

    static func isExcluded(source: String?, settings: ClipSettings) -> Bool {
        guard let s = source, !s.isEmpty, s != remoteSource else { return false }
        return isPasswordApp(s) || settings.excludedApps.contains { $0.caseInsensitiveCompare(s) == .orderedSame }
    }

    /// May this change be read at all? (Seen before any content is read: secrets and excluded apps aren't even read.) A copy
    /// from another device is judged by the "other devices" switch, never by the app that happens to be in front.
    static func allowed(types: [String], source: String?, front: String?, settings: ClipSettings) -> Bool {
        if isConcealed(types) { return false }
        if isRemote(types) { return settings.includeRemote }
        return !isExcluded(source: source ?? front, settings: settings)
    }

    /// The whole text is a card number (13–19 digits, spaces or dashes between, valid check digit).
    static func looksLikeCard(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 30, t.range(of: "^[0-9][0-9 -]*[0-9]$", options: .regularExpression) != nil else { return false }
        let digits = t.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() { let x = i % 2 == 1 ? d * 2 : d; sum += x > 9 ? x - 9 : x }
        return sum % 10 == 0
    }

    private static let tokenPrefixes = ["sk-", "sk_live_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "glpat-", "xoxb-", "xoxp-", "xapp-",
                                        "AKIA", "ASIA", "AIza", "ya29.", "npm_", "pypi-", "hf_"]

    /// One word that looks like a key or a token: a known prefix, a JWT, a private key block, or a long random-looking string
    /// (three kinds of characters, digits among them, and high entropy). Words, URLs, paths, e-mail addresses, hex hashes and
    /// UUIDs are not tokens.
    static func looksLikeSecret(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("-----BEGIN") && t.contains("PRIVATE KEY-----") { return true }
        guard (16...512).contains(t.count), t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        if tokenPrefixes.contains(where: { t.hasPrefix($0) }) && t.count >= 20 { return true }
        if t.hasPrefix("eyJ") && t.filter({ $0 == "." }).count == 2 { return true }                     // a JWT
        guard t.count >= 24, !t.contains("://"), !t.hasPrefix("/"), !t.hasPrefix("~"), !t.contains("@") else { return false }
        if t.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil { return false }
        let lower = t.contains { $0.isLowercase }, upper = t.contains { $0.isUppercase }, digit = t.contains { $0.isNumber }
        let symbol = t.contains { "-_+/=.".contains($0) }
        guard [lower, upper, digit, symbol].filter({ $0 }).count >= 3, digit else { return false }
        return entropy(t) >= 3.5
    }

    static func entropy(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        s.forEach { counts[$0, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { r, c in let p = Double(c) / n; return r - p * log2(p) }
    }

    /// Text with every word that looks like a key, a token or a card number masked (text recognised in a screenshot is
    /// searchable, its secrets are not).
    static func masked(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line in
            line.split(separator: " ", omittingEmptySubsequences: false).map { w -> String in
                let word = String(w)
                return looksLikeSecret(word) || looksLikeCard(word) ? "•••" : word
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// A pattern the user typed is valid when it compiles.
    static func validPattern(_ p: String) -> Bool { !p.isEmpty && (try? NSRegularExpression(pattern: p)) != nil }

    static func matchesUserPattern(_ s: String, _ patterns: [String]) -> Bool {
        let sample = s.count > 100_000 ? String(s.prefix(100_000)) : s
        let range = NSRange(sample.startIndex..., in: sample)
        return patterns.contains { p in
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return false }
            return re.firstMatch(in: sample, range: range) != nil
        }
    }

    enum Skip: Equatable { case own, concealed, excludedApp, remote, secret, pattern, tooBig, empty }
    enum Decision: Equatable { case keep(ClipItem), skip(Skip) }

    /// What to do with what is on the clipboard now. Files win over text (Finder also puts the names as text), text over images
    /// (spreadsheets also put a picture of the cells). Formatting that would make a text too big is dropped, not the text.
    static func decide(_ s: ClipSnapshot, settings: ClipSettings, now: Date = Date()) -> Decision {
        if s.ours { return .skip(.own) }
        if isConcealed(s.types) { return .skip(.concealed) }
        let remote = isRemote(s.types)
        if remote && !settings.includeRemote { return .skip(.remote) }
        let source = remote ? remoteSource : s.source
        if isExcluded(source: source, settings: settings) { return .skip(.excludedApp) }
        if !s.files.isEmpty {
            let item = ClipItem.files(s.files.map(\.path), date: now, source: source)
            return item.bytes > settings.maxItemBytes ? .skip(.tooBig) : .keep(item)
        }
        if let t = s.text {
            // Too big first: a huge copy isn't trimmed, scanned for secrets nor matched against patterns at every change.
            let plainBytes = t.utf8.count
            guard plainBytes <= settings.maxItemBytes else { return .skip(.tooBig) }
            guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .skip(.empty) }
            if settings.skipSecrets && (looksLikeCard(t) || looksLikeSecret(t)) { return .skip(.secret) }
            if !settings.patterns.isEmpty && matchesUserPattern(t, settings.patterns) { return .skip(.pattern) }
            let rich = s.rich.flatMap { ClipRich.bounded(rtf: $0.rtf, html: $0.html, limit: settings.maxItemBytes - plainBytes) }
            return .keep(.text(t, date: now, source: source, rich: rich))
        }
        if s.imageTooBig { return .skip(.tooBig) }
        if let png = s.image {
            guard png.count <= settings.maxItemBytes else { return .skip(.tooBig) }
            return .keep(.image(png: png, width: s.width, height: s.height, date: now, source: source))
        }
        return .skip(.empty)
    }
}

// MARK: - The list: duplicates, limits, search

struct ClipHistoryCore {
    var items: [ClipItem] = []           // newest first

    /// Adds an item; the same content again moves the existing one to the top (it keeps its id, pinboards, name and stored
    /// image). Returns the item as it is now in the list.
    @discardableResult
    mutating func add(_ item: ClipItem) -> ClipItem {
        if let i = items.firstIndex(where: { $0.digest == item.digest && $0.kind == item.kind }) {
            var old = items.remove(at: i)
            old.date = item.date
            old.source = item.source ?? old.source
            if old.payload == nil { old.payload = item.payload }
            if !old.hasRich, item.hasRich { old.rich = item.rich; old.hasRich = true; old.bytes = item.bytes }
            for b in item.boards where !old.boards.contains(b) { old.boards.append(b) }
            items.insert(old, at: 0)
            return old
        }
        items.insert(item, at: 0)
        return item
    }

    /// Applies the limits (age, count, total size) to what is on no pinboard, oldest first. Returns what was removed.
    @discardableResult
    mutating func prune(now: Date, settings: ClipSettings) -> [ClipItem] {
        var removed: [ClipItem] = []
        if settings.maxAgeHours > 0 {
            let limit = now.addingTimeInterval(-Double(settings.maxAgeHours) * 3600)
            removed += items.filter { !$0.pinned && $0.date < limit }
            items.removeAll { !$0.pinned && $0.date < limit }
        }
        func dropOldestUnpinned() -> Bool {
            guard let i = items.lastIndex(where: { !$0.pinned }) else { return false }
            removed.append(items.remove(at: i))
            return true
        }
        while items.filter({ !$0.pinned }).count > max(1, settings.maxItems), dropOldestUnpinned() {}
        while items.reduce(0, { $0 + ($1.pinned ? 0 : $1.bytes) }) > settings.maxTotalBytes, dropOldestUnpinned() {}
        return removed
    }

    /// What search looks at in an item: its name, text, file names and paths, image size and the text recognised in it.
    static func haystack(_ item: ClipItem) -> String {
        var hay: String
        switch item.kind {
        case .text: hay = item.text
        case .files: hay = (item.names + item.paths).joined(separator: "\n")
        case .image: hay = "\(item.width)×\(item.height) \(item.width)x\(item.height) png image"
        }
        if let t = item.title { hay += "\n" + t }
        if let o = item.ocr { hay += "\n" + o }
        return hay
    }

    /// Every word of the query must appear (any case, any accents) in the item's haystack or in what `describe` adds (kind,
    /// source app).
    static func matches(_ item: ClipItem, _ query: String, describe: (ClipItem) -> String = { _ in "" }) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return matches(item, words: words, describe: describe)
    }

    static func matches(_ item: ClipItem, words: [String], describe: (ClipItem) -> String = { _ in "" }) -> Bool {
        guard !words.isEmpty else { return true }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var extra: String?                                   // worked out only when the item's own text doesn't have the word
        return words.allSatisfy { w in
            switch item.kind {                               // no joined copy of a long text per item and per keystroke
            case .text: if item.text.range(of: w, options: opts) != nil { return true }
            case .files: if item.paths.contains(where: { $0.range(of: w, options: opts) != nil }) { return true }
            case .image: if haystack(item).range(of: w, options: opts) != nil { return true }
            }
            if let t = item.title, t.range(of: w, options: opts) != nil { return true }
            if let o = item.ocr, o.range(of: w, options: opts) != nil { return true }
            if extra == nil { extra = describe(item) }
            return extra!.range(of: w, options: opts) != nil
        }
    }

    /// `favoritesOnly`: only what is on a pinboard.
    func filtered(_ query: String, favoritesOnly: Bool, describe: (ClipItem) -> String = { _ in "" }) -> [ClipItem] {
        items.filter { (!favoritesOnly || $0.pinned) && Self.matches($0, query, describe: describe) }
    }
}

// MARK: - Encryption and its key

enum ClipCrypto {
    static let magic = Data("CCLP".utf8)
    static let version: UInt8 = 1
    enum Failure: Error { case notOurs, unreadable }

    /// AES-GCM; the header and what the data is (the index, or which item's image) are authenticated too, so files can't be
    /// swapped between items unnoticed.
    static func seal(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        let header = magic + Data([version])
        let box = try AES.GCM.seal(data, using: key, authenticating: header + Data(context.utf8))
        guard let combined = box.combined else { throw Failure.unreadable }
        return header + combined
    }

    static func open(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        let header = magic + Data([version])
        guard data.count >= header.count + 28, data.prefix(header.count) == header else { throw Failure.notOurs }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(header.count)))
            return try AES.GCM.open(box, using: key, authenticating: header + Data(context.utf8))
        } catch { throw Failure.unreadable }
    }
}

protocol ClipKeyStore: AnyObject {
    func load() throws -> Data?
    func save(_ key: Data) throws
    func delete() throws
}

/// Tests' stand-in for the Keychain.
final class MemoryKeyStore: ClipKeyStore {
    var key: Data?
    var failing = false
    func load() throws -> Data? { if failing { throw KeychainKeyStore.Failure(status: errSecInteractionNotAllowed) }; return key }
    func save(_ k: Data) throws { if failing { throw KeychainKeyStore.Failure(status: errSecInteractionNotAllowed) }; key = k }
    func delete() throws { key = nil }
}

/// The history's key: a random 256-bit key made on this Mac, in the login Keychain, for this device only and never synced.
/// Its access list names the app by its signature: with the stable local signing identity updates keep access; with an ad-hoc
/// signature macOS asks again after each update (or is refused, and then nothing is saved).
final class KeychainKeyStore: ClipKeyStore {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)" }
    }
    let service: String, account: String
    let keychain: AnyObject?          // a specific keychain file (tests use a temporary one); nil: the login keychain

    init(service: String = "local.cocaine.clipboard", account: String = "history-key", keychain: AnyObject? = nil) {
        self.service = service; self.account = account; self.keychain = keychain
    }

    private func query(search: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let keychain { q[search ? kSecMatchSearchList as String : kSecUseKeychain as String] = search ? [keychain] : keychain }
        return q
    }

    func load() throws -> Data? {
        var q = query(search: true)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let d = out as? Data else { throw Failure(status: st) }
        return d
    }

    func save(_ key: Data) throws {
        try delete()
        var q = query(search: false)
        q[kSecValueData as String] = key
        q[kSecAttrLabel as String] = "Cocaine clipboard history"
        q[kSecAttrDescription as String] = "Encrypts the clipboard history saved on this Mac"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw Failure(status: st) }
    }

    func delete() throws {
        let st = SecItemDelete(query(search: true) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw Failure(status: st) }
    }
}

// MARK: - On disk

/// <dir>/index.ccl holds the history (texts and paths included), <dir>/boards.ccl the pinboards and their items, <dir>/<id>.img
/// each image and <dir>/<id>.rich each formatted text: all encrypted, 0600 in a 0700 folder, written atomically. An index or
/// boards file that can't be read (damaged, another key, a newer Cocaine) is set aside, never deleted; a bad item doesn't lose
/// the others. Index schema 2 adds optional fields (names, formatting, text in images, pinboards): schema 1 loads as is.
final class ClipStore {
    static let schema = 2
    static let boardsSchema = 1
    let dir: URL
    let keys: ClipKeyStore
    private var key: SymmetricKey?
    var index: URL { dir.appendingPathComponent("index.ccl") }
    var boardsFile: URL { dir.appendingPathComponent("boards.ccl") }

    enum Blob: String, CaseIterable { case image = "img", rich = "rich" }

    static var defaultDir: URL {
        if let base = ProcessInfo.processInfo.environment["COCAINE_SUPPORT"], !base.isEmpty {
            return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("clipboard", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cocaine/clipboard", isDirectory: true)
    }

    init(dir: URL, keys: ClipKeyStore) { self.dir = dir; self.keys = keys }

    var unlocked: Bool { key != nil }

    /// Loads the key from the Keychain, or makes one. Throws when the Keychain can't be used: then nothing is written.
    func unlock() throws {
        if key != nil { return }
        if let d = try keys.load(), d.count == 32 { key = SymmetricKey(data: d); return }
        let k = SymmetricKey(size: .bits256)
        try keys.save(k.withUnsafeBytes { Data($0) })
        key = k
    }

    /// Forgets the key in memory (nothing saved any more; files kept for next time).
    func lock() { key = nil }

    struct Lossy: Codable {
        var item: ClipItem?
        init(_ i: ClipItem) { item = i }
        init(from decoder: Decoder) throws { item = try? ClipItem(from: decoder) }
        func encode(to encoder: Encoder) throws { try item?.encode(to: encoder) }
    }
    struct LossyBoard: Codable {
        var board: ClipBoard?
        init(_ b: ClipBoard) { board = b }
        init(from decoder: Decoder) throws { board = try? ClipBoard(from: decoder) }
        func encode(to encoder: Encoder) throws { try board?.encode(to: encoder) }
    }
    struct Index: Codable {
        var v: Int
        var items: [Lossy]
    }
    struct BoardsDoc: Codable {
        var v: Int
        var boards: [LossyBoard]
        var items: [Lossy]
    }

    enum LoadProblem: Equatable { case none, unreadableIndex, unusable, droppedItems(Int) }

    var hasIndex: Bool { exists(index) }
    var hasBoards: Bool { exists(boardsFile) }
    private func exists(_ u: URL) -> Bool { !(access(u.path, F_OK) != 0 && errno == ENOENT) }

    /// The saved history (images and formatting not read yet), and whether something had to be dropped. `keeping`: items saved
    /// elsewhere (the pinboards) whose files must stay; `cleanOrphans` false when the pinboards couldn't be read (their files
    /// can't be told from strays then, so none is removed).
    func load(keeping: Set<UUID> = [], cleanOrphans: Bool = true) -> (items: [ClipItem], problem: LoadProblem) {
        guard let key else { return ([], .none) }
        guard let raw = try? Data(contentsOf: index) else {
            // No history yet: leftovers of one go. There but unreadable (permissions, I/O): kept, like a damaged one.
            if !exists(index) { if cleanOrphans { removeOrphans(keeping: keeping) }; return ([], .none) }
            return setAside(index, keeping: keeping) ? ([], .unreadableIndex) : ([], .unusable)
        }
        guard let plain = try? ClipCrypto.open(raw, key: key, context: "index"),
              let idx = try? JSONDecoder().decode(Index.self, from: plain), (1...Self.schema).contains(idx.v) else {
            // Damaged, from another key (the Keychain item was deleted, another Mac), or from a newer version: set it aside
            // with its files (nothing deleted: the right key or version can still read them), start empty.
            return setAside(index, keeping: keeping) ? ([], .unreadableIndex) : ([], .unusable)
        }
        let (items, dropped) = present(idx.items)
        if cleanOrphans { removeOrphans(keeping: Set(items.map(\.id)).union(keeping)) }
        return (items, dropped > 0 ? .droppedItems(dropped) : .none)
    }

    /// The saved pinboards and their items. nil boards: no file yet. A file that can't be read is set aside (alone: its images
    /// stay where they are, and `.unreadableIndex` says to remove no stray file this time).
    func loadBoards() -> (boards: [ClipBoard]?, items: [ClipItem], problem: LoadProblem) {
        guard let key else { return (nil, [], .none) }
        guard let raw = try? Data(contentsOf: boardsFile) else {
            if !exists(boardsFile) { return (nil, [], .none) }
            return setAside(boardsFile, keeping: nil) ? (nil, [], .unreadableIndex) : (nil, [], .unusable)
        }
        guard let plain = try? ClipCrypto.open(raw, key: key, context: "boards"),
              let doc = try? JSONDecoder().decode(BoardsDoc.self, from: plain), (1...Self.boardsSchema).contains(doc.v) else {
            return setAside(boardsFile, keeping: nil) ? (nil, [], .unreadableIndex) : (nil, [], .unusable)
        }
        let boards = PinboardRules.normalized(doc.boards.compactMap(\.board))
        var (items, dropped) = present(doc.items)
        dropped += doc.boards.filter { $0.board == nil }.count
        var core = ClipHistoryCore(items: items)
        core.dropUnknownBoards(Set(boards.map(\.id)))
        items = core.items
        return (boards, items, dropped > 0 ? .droppedItems(dropped) : .none)
    }

    /// The items that can be shown: decoded, and an image only with its file.
    private func present(_ list: [Lossy]) -> ([ClipItem], Int) {
        var items: [ClipItem] = [], dropped = list.filter { $0.item == nil }.count
        for case let i? in list.map(\.item) {
            if i.kind == .image && !FileManager.default.fileExists(atPath: blob(i.id).path) { dropped += 1; continue }
            var i = i
            if i.hasRich && !FileManager.default.fileExists(atPath: blob(i.id, .rich).path) { i.hasRich = false }   // just the plain text
            items.append(i)
        }
        return (items, dropped)
    }

    func saveIndex(_ items: [ClipItem]) throws {
        guard let key else { return }
        let data = try JSONEncoder().encode(Index(v: Self.schema, items: items.map(Lossy.init)))
        try write(try ClipCrypto.seal(data, key: key, context: "index"), to: index)
    }

    func saveBoards(_ boards: [ClipBoard], items: [ClipItem]) throws {
        guard let key else { return }
        let data = try JSONEncoder().encode(BoardsDoc(v: Self.boardsSchema, boards: boards.map(LossyBoard.init), items: items.map(Lossy.init)))
        try write(try ClipCrypto.seal(data, key: key, context: "boards"), to: boardsFile)
    }

    func removeBoardsFile() { try? FileManager.default.removeItem(at: boardsFile) }

    private func context(_ id: UUID, _ kind: Blob) -> String { (kind == .image ? "image:" : "rich:") + id.uuidString }

    func writeBlob(_ id: UUID, _ kind: Blob, _ data: Data) throws {
        guard let key else { return }
        try write(try ClipCrypto.seal(data, key: key, context: context(id, kind)), to: blob(id, kind))
    }

    func readBlob(_ id: UUID, _ kind: Blob) -> Data? {
        guard let key, let raw = try? Data(contentsOf: blob(id, kind)) else { return nil }
        return try? ClipCrypto.open(raw, key: key, context: context(id, kind))
    }

    func writeImage(_ id: UUID, _ png: Data) throws { try writeBlob(id, .image, png) }
    func readImage(_ id: UUID) -> Data? { readBlob(id, .image) }
    func removeImage(_ id: UUID) { removeBlobs(id) }

    func writeRich(_ id: UUID, _ rich: ClipRich) throws { try writeBlob(id, .rich, try JSONEncoder().encode(rich)) }
    func readRich(_ id: UUID) -> ClipRich? { readBlob(id, .rich).flatMap { try? JSONDecoder().decode(ClipRich.self, from: $0) } }

    func removeBlobs(_ id: UUID) {
        for k in Blob.allCases { try? FileManager.default.removeItem(at: blob(id, k)) }
    }

    func hasBlob(_ id: UUID, _ kind: Blob) -> Bool { FileManager.default.fileExists(atPath: blob(id, kind).path) }

    /// Removes the folder and the Keychain key. Everything in it was encrypted with that key, so whatever the disk still keeps
    /// of those files is unreadable once the key is gone (overwriting in place isn't reliable on SSDs and APFS).
    func wipe() throws {
        key = nil
        var firstError: Error?
        if FileManager.default.fileExists(atPath: dir.path) {
            do { try FileManager.default.removeItem(at: dir) } catch { firstError = error }
        }
        do { try keys.delete() } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }

    /// The saved history only (the index and the files of items not in `keeping`); the pinboards, their files and the key stay.
    func wipeHistory(keeping: Set<UUID>) {
        try? FileManager.default.removeItem(at: index)
        removeOrphans(keeping: keeping)
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where n.hasPrefix("unreadable-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    func blob(_ id: UUID, _ kind: Blob = .image) -> URL { dir.appendingPathComponent(id.uuidString + "." + kind.rawValue) }

    private static func blobID(_ name: String) -> UUID? {
        for k in Blob.allCases where name.hasSuffix("." + k.rawValue) { return UUID(uuidString: String(name.dropLast(k.rawValue.count + 1))) }
        return nil
    }

    /// Moves `file` (and, with `keeping`, every item file not in it) into a new `unreadable-<time>` folder. False: it couldn't.
    private func setAside(_ file: URL, keeping: Set<UUID>?) -> Bool {
        let fm = FileManager.default
        var aside = dir.appendingPathComponent("unreadable-\(Int(Date().timeIntervalSince1970))")
        if fm.fileExists(atPath: aside.path) { aside = dir.appendingPathComponent("unreadable-" + UUID().uuidString) }
        guard (try? fm.createDirectory(at: aside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil,
              (try? fm.moveItem(at: file, to: aside.appendingPathComponent(file.lastPathComponent))) != nil else { return false }
        if let keeping {
            for n in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                guard let id = Self.blobID(n), !keeping.contains(id) else { continue }
                try? fm.moveItem(at: dir.appendingPathComponent(n), to: aside.appendingPathComponent(n))
            }
        }
        return true
    }

    func removeOrphans(keeping ids: Set<UUID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in names {
            if n.hasPrefix(".tmp-") { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)); continue }
            guard let id = Self.blobID(n), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    /// A private folder, a temp file that is 0600 from the start, synced, then renamed over the old one.
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        guard SafeFile.writePrivate(data, to: url) else { throw CocoaError(.fileWriteUnknown) }
    }
}

// MARK: - The clipboard itself

/// What was on the clipboard at one change.
struct ClipSnapshot {
    var changeCount = 0
    var types: [String] = []
    var source: String?
    var ours = false
    var text: String?
    var rich: ClipRich?
    var files: [URL] = []
    var image: Data?
    var width = 0, height = 0
    var imageTooBig = false
    var stale = false                 // it changed while being read
    var hasContent: Bool { text != nil || !files.isEmpty || image != nil || imageTooBig }
    var remote: Bool { ClipRules.isRemote(types) }
}

protocol ClipPasteboard: AnyObject {
    var changeCount: Int { get }
    /// Reads it (may be slow: call it off the main thread). `allowed` sees the types and source first: secrets aren't even read.
    func snapshot(maxImageBytes: Int, allowed: ([String], String?) -> Bool) -> ClipSnapshot
    /// Puts an item back, with the right types (`rich`: its formatting too; nil: plain text only); returns the new change
    /// count, or nil.
    func write(_ item: ClipItem, payload: Data?, rich: ClipRich?) -> Int?
    /// The plain text on it now (a snippet's {clipboard}).
    func currentText() -> String?
}

extension ClipPasteboard {
    func write(_ item: ClipItem, payload: Data?) -> Int? { write(item, payload: payload, rich: nil) }
}

final class SystemPasteboard: ClipPasteboard {
    let pb: NSPasteboard
    init(_ pb: NSPasteboard) { self.pb = pb }
    var changeCount: Int { pb.changeCount }

    func snapshot(maxImageBytes: Int, allowed: ([String], String?) -> Bool) -> ClipSnapshot {
        var s = ClipSnapshot()
        s.changeCount = pb.changeCount
        s.types = pb.types?.map(\.rawValue) ?? []
        if s.types.contains(ClipRules.ownType) { s.ours = true; return s }
        if s.types.contains("org.nspasteboard.source") { s.source = pb.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")) }
        guard allowed(s.types, s.source) else { return s }
        let has = { (t: NSPasteboard.PasteboardType) in s.types.contains(t.rawValue) }
        let richLimit = min(maxImageBytes, ClipRich.maxBytes)
        func richData(_ t: NSPasteboard.PasteboardType) -> Data? {
            guard has(t), let d = pb.data(forType: t), d.count <= richLimit else { return nil }
            return d
        }
        if has(.fileURL), let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            s.files = urls
        } else if has(.string), let t = pb.string(forType: .string) {
            s.text = t
            s.rich = ClipRich.bounded(rtf: richData(.rtf), html: richData(.html), limit: richLimit)     // its formatting, bounded
        } else if has(.rtf), let d = pb.data(forType: .rtf), let a = NSAttributedString(rtf: d, documentAttributes: nil) {
            s.text = a.string                                            // rich text only: its plain text, and the RTF itself
            s.rich = ClipRich.bounded(rtf: d, html: richData(.html), limit: richLimit)
        } else if has(.png) || has(.tiff) {
            // Image data only (promised files aren't fetched). TIFF is uncompressed, so it may be far bigger than its PNG.
            if has(.png), let d = pb.data(forType: .png) {
                if d.count > maxImageBytes { s.imageTooBig = true } else { s.image = d }
            } else if let d = pb.data(forType: .tiff) {
                if d.count > maxImageBytes * 8 { s.imageTooBig = true }
                else if let png = NSBitmapImageRep(data: d)?.representation(using: .png, properties: [:]) {
                    if png.count > maxImageBytes { s.imageTooBig = true } else { s.image = png }
                }
            }
            if let d = s.image, let src = CGImageSourceCreateWithData(d as CFData, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                s.width = p[kCGImagePropertyPixelWidth] as? Int ?? 0
                s.height = p[kCGImagePropertyPixelHeight] as? Int ?? 0
            } else if s.image != nil { s.image = nil }                  // not an image after all
        }
        s.stale = pb.changeCount != s.changeCount
        return s
    }

    func write(_ item: ClipItem, payload: Data?, rich: ClipRich?) -> Int? {
        let own = NSPasteboard.PasteboardType(ClipRules.ownType)
        switch item.kind {
        case .text:
            pb.clearContents()
            let it = NSPasteboardItem()
            it.setString(item.text, forType: .string)
            if let r = rich?.rtf { it.setData(r, forType: .rtf) }
            if let h = rich?.html { it.setData(h, forType: .html) }
            it.setData(Data(), forType: own)
            guard pb.writeObjects([it]) else { return nil }
        case .image:
            guard let png = payload, let rep = NSBitmapImageRep(data: png) else { return nil }
            pb.clearContents()
            let it = NSPasteboardItem()
            it.setData(png, forType: .png)
            if rep.pixelsWide * rep.pixelsHigh <= 12_000_000, let tiff = rep.tiffRepresentation { it.setData(tiff, forType: .tiff) }   // apps that read only TIFF
            it.setData(Data(), forType: own)
            guard pb.writeObjects([it]) else { return nil }
        case .files:
            let urls = item.paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return nil }
            pb.clearContents()
            guard pb.writeObjects(urls as [NSURL]) else { return nil }
            pb.setData(Data(), forType: own)
        }
        return pb.changeCount
    }

    func currentText() -> String? {
        guard let types = pb.types?.map(\.rawValue), !ClipRules.isConcealed(types) else { return nil }
        return pb.string(forType: .string)
    }
}

// MARK: - The history the island shows

final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory(defaults: AppDefaults.store, dir: ClipStore.defaultDir, keys: KeychainKeyStore(), board: SystemPasteboard(.general))

    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var settings: ClipSettings
    /// The pinboards, in the user's order (Favorites always among them).
    @Published private(set) var boards: [ClipBoard] = [.favorites]
    @Published var paused = false {
        didSet {
            if paused != oldValue { seen = board.changeCount }                                       // nothing copied meanwhile is kept
            if !paused { pausedUntil = nil }
        }
    }
    /// A timed pause ends by itself then (nil: until resumed).
    @Published private(set) var pausedUntil: Date?
    @Published var query = ""
    @Published var favoritesOnly = false
    @Published var hovered: UUID?                        // the island row under the pointer, or the keyboard's
    @Published private(set) var saving = false          // persistence on and working: the history is on disk
    /// The pinboards' file is open (its key at hand): what is pinned is saved, also with a memory-only history.
    @Published private(set) var boardsOpen = false
    @Published private(set) var problem: String?        // why it isn't saved, or what had to be dropped
    @Published private(set) var missing: Set<UUID> = []  // file references whose files are gone
    @Published private(set) var thumbs: [UUID: NSImage] = [:]
    /// What was just deleted, for Undo (a few seconds; its images and formatting read back into memory first).
    @Published private(set) var undo: (items: [ClipItem], until: Date)?

    var now: () -> Date = Date.init
    var frontApp: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    /// The pinboards or their shortcuts changed (the global shortcuts are registered again: Sources/Snippets.swift).
    var onBoardsChange: () -> Void = {}
    /// An image was captured (text recognition, when on: Sources/ClipboardOCR.swift).
    var onImage: (ClipItem) -> Void = { _ in }

    let board: ClipPasteboard
    let store: ClipStore
    private let defaults: UserDefaults
    var core = ClipHistoryCore()                         // the list (Sources/Pinboards.swift, PasteEngine.swift extend it)
    private var seen: Int
    private var reading = false
    private var timer: Timer?
    private var ticks = 0
    private var saveWork: DispatchWorkItem?
    private var thumbsLoading: Set<UUID> = []
    private var undoWork: DispatchWorkItem?
    private let reader = DispatchQueue(label: "local.cocaine.clipboard.read", qos: .utility)
    let io = DispatchQueue(label: "local.cocaine.clipboard.io", qos: .utility)

    init(defaults: UserDefaults, dir: URL, keys: ClipKeyStore, board: ClipPasteboard) {
        self.defaults = defaults
        self.board = board
        store = ClipStore(dir: dir, keys: keys)
        settings = ClipSettings.load(defaults)
        seen = board.changeCount
    }

    var visible: [ClipItem] { core.filtered(query, favoritesOnly: favoritesOnly, describe: describe) }
    var running: Bool { wanted }

    /// Is this item on disk (saved history, or on a pinboard whose file is open)?
    func durable(_ i: ClipItem) -> Bool { (saving && !keepOffDisk(i)) || (boardsOpen && i.pinned) }
    /// Items the saved history never holds (Universal Clipboard copies, when the user says so: Sources/ClipSync.swift);
    /// they stay in memory, and on disk only once pinned.
    var keepOffDisk: (ClipItem) -> Bool = { _ in false }

    // MARK: watching

    func start() {
        guard timer == nil else { return }
        seen = board.changeCount
        if settings.persist && !saving { openStore(atLaunch: true) }
        else if !boardsOpen && !settings.persist && store.hasBoards { openBoards(atLaunch: true) }
        schedule()
        if powerToken == nil {
            // Screens asleep, the Mac asleep, another user on screen: nobody copies anything, the timer rests (a change made
            // meanwhile is read at once on the way back).
            powerToken = PowerAwareness.shared.subscribe { [weak self] paused in
                guard let self, self.wanted else { return }
                if paused { self.timer?.invalidate(); self.timer = nil } else { self.schedule(); self.poll() }
            }
        }
        refreshMissing()
        onBoardsChange()
    }

    private var wanted = false
    private var powerToken: UUID?

    private func schedule() {
        wanted = true
        guard timer == nil, !PowerAwareness.shared.paused else { return }
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in self?.poll() }   // changeCount is cheap; the tolerance lets macOS batch wake-ups
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// With the island off: a memory-only history is forgotten (what is pinned and saved stays), a saved one stays on disk.
    func stop() {
        wanted = false
        timer?.invalidate(); timer = nil
        if saving { flush(); return }
        flush()
        let kept = core.items.filter { boardsOpen && $0.pinned }
        replace(kept)
    }

    func poll() {
        ticks += 1
        if ticks % 86 == 0 { expire() }                           // about once a minute
        if let u = pausedUntil, now() >= u { paused = false }
        guard !paused else { seen = board.changeCount; return }
        guard !reading else { return }
        let c = board.changeCount
        guard c != seen else { return }
        seen = c
        read(attempt: 0)
    }

    /// Pauses for a while (nil: until resumed by hand).
    func pause(until: Date?) {
        paused = true
        pausedUntil = until
    }

    /// Reads off the main thread (huge or slow pasteboards don't freeze the island). Content still arriving (types declared,
    /// data not yet there) is read again twice, a little later.
    private func read(attempt: Int, sync: Bool = false) {
        reading = true
        let s = settings, front = frontApp()
        let job = { [board] () -> ClipSnapshot in
            board.snapshot(maxImageBytes: s.maxItemBytes) { types, source in
                ClipRules.allowed(types: types, source: source, front: front, settings: s)
            }
        }
        let finish = { [weak self] (snap: ClipSnapshot) in
            guard let self else { return }
            self.reading = false
            var snap = snap
            if snap.source == nil && !snap.remote { snap.source = front }      // another device's copy is never the front app's
            guard !snap.stale, !self.paused else { return }               // a newer change is next in line
            if !snap.hasContent, !snap.ours, !snap.types.isEmpty, attempt < 2,
               ClipRules.allowed(types: snap.types, source: snap.source, front: front, settings: s) {
                if sync { self.read(attempt: attempt + 1, sync: true); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, !self.reading, self.board.changeCount == snap.changeCount else { return }
                    self.read(attempt: attempt + 1)
                }
                return
            }
            self.take(snap)
        }
        if sync { finish(reader.sync(execute: job)) }
        else { reader.async { let snap = job(); DispatchQueue.main.async { finish(snap) } } }
    }

    /// Tests: read the (fake or private) pasteboard now, synchronously.
    func captureNow() {
        let c = board.changeCount
        guard c != seen, !paused else { return }
        seen = c
        read(attempt: 0, sync: true)
    }

    func take(_ snap: ClipSnapshot) {
        guard case .keep(let item) = ClipRules.decide(snap, settings: settings, now: now()) else { return }
        add(item)
    }

    func add(_ item: ClipItem) {
        let before = Set(core.items.map(\.id))
        let kept = core.add(item)
        let removed = core.prune(now: now(), settings: settings)
        let isNew = !before.contains(kept.id), stays = !removed.contains(where: { $0.id == kept.id })
        if isNew, stays, durable(kept) { writeBlobs(kept) }
        forget(removed)
        if saving || (boardsOpen && kept.pinned) { scheduleSave() }
        publish()
        if isNew, stays, kept.kind == .image { onImage(kept) }
    }

    // MARK: actions

    /// Puts it back on the clipboard (not captured again) and moves it to the top. `plain`: without its formatting (nil: as
    /// the settings say). `text`: this text instead of the item's (a transformation or a filled-in snippet; plain).
    @discardableResult
    func copy(_ item: ClipItem, plain: Bool? = nil, text: String? = nil) -> Bool {
        let payload = item.kind == .image ? imageData(item) : nil
        var out = item
        var rich: ClipRich?
        if let text { out = .text(text) }
        else if item.kind == .text, item.hasRich, !(plain ?? settings.pastePlain) { rich = richData(item) }
        guard let c = board.write(out, payload: payload, rich: rich) else { return false }
        seen = c
        guard let i = core.items.firstIndex(where: { $0.id == item.id }) else { publish(); return true }
        var moved = core.items.remove(at: i)
        moved.date = now()
        if moved.payload == nil, payload != nil, !durable(moved) { moved.payload = payload }
        core.items.insert(moved, at: 0)
        if durable(moved) { scheduleSave() }
        publish()
        return true
    }

    /// The keyboard on the island's Clipboard page: ↓/↑ move the highlight (the row the pointer would be on) through `list`.
    func step(_ n: Int, in list: [ClipItem]? = nil) {
        let list = list ?? visible
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == hovered }
        let j = i.map { min(list.count - 1, max(0, $0 + n)) } ?? (n > 0 ? 0 : list.count - 1)
        hovered = list[j].id
        A11y.announce(spokenTitle(list[j]))
    }

    /// What VoiceOver says for an item: its name, else the start of its text, else what it is.
    func spokenTitle(_ c: ClipItem) -> String {
        if let t = c.title, !t.isEmpty { return t }
        switch c.kind {
        case .text: return String(c.text.prefix(120))
        case .image: return L("Image") + " \(c.width)×\(c.height)"
        case .files: return c.names.first ?? ""
        }
    }

    /// Writes an item's image and formatting to their encrypted files; once there the copies in memory go (they are read back
    /// from the files when needed). A failure is said where the history's problems are, not swallowed.
    func writeBlobs(_ item: ClipItem) {
        let png = item.kind == .image ? item.payload : nil, rich = item.hasRich ? item.rich : nil
        guard png != nil || rich != nil else { return }
        io.async { [weak self, store] in
            do {
                if let png { try store.writeImage(item.id, png) }
                if let rich { try store.writeRich(item.id, rich) }
                DispatchQueue.main.async { self?.dropPayload(item.id) }
            } catch {
                log.error("clipboard: item file not saved: \(String(describing: error), privacy: .public)")
                DispatchQueue.main.async { self?.problem = L("Couldn't save the history.") + " " + error.localizedDescription }
            }
        }
    }

    /// With the item on disk, its image and formatting stay on disk only (the file is the copy that counts).
    private func dropPayload(_ id: UUID) {
        guard let i = core.items.firstIndex(where: { $0.id == id }), durable(core.items[i]) else { return }
        if core.items[i].payload != nil, store.hasBlob(id, .image) { core.items[i].payload = nil }
        if core.items[i].rich != nil, store.hasBlob(id, .rich) { core.items[i].rich = nil }
    }

    /// Whether an item is saved changed (pinned or unpinned with a memory-only history): its files are written, or read back
    /// into memory and removed.
    private func syncDurability(_ ids: [UUID], wasDurable: [UUID: Bool]) {
        for id in ids {
            guard let i = core.items.firstIndex(where: { $0.id == id }) else { continue }
            let now = durable(core.items[i]), before = wasDurable[id] ?? now
            if now && !before { writeBlobs(core.items[i]) }
            if !now && before {
                loadPayloads(i)
                io.async { [store] in store.removeBlobs(id) }
            }
        }
    }

    /// Reads an item's image and formatting back into memory (before its files go).
    private func loadPayloads(_ i: Int) {
        let id = core.items[i].id
        if core.items[i].kind == .image, core.items[i].payload == nil { core.items[i].payload = io.sync { [store] in store.readImage(id) } }
        if core.items[i].hasRich, core.items[i].rich == nil { core.items[i].rich = io.sync { [store] in store.readRich(id) } }
    }

    /// The star: on Favorites, or off it.
    func togglePin(_ id: UUID) {
        guard let c = core.items.first(where: { $0.id == id }) else { return }
        if c.isFavorite { unpin([id], from: ClipBoard.favoritesID) } else { pin([id], to: ClipBoard.favoritesID) }
    }

    /// Puts items on a pinboard: kept for good and saved (encrypted) from now on.
    func pin(_ ids: [UUID], to boardID: UUID) {
        guard boards.contains(where: { $0.id == boardID }) else { return }
        let was = durability(ids)
        core.assign(ids, to: boardID)
        boardsChanged(ids, was: was)
    }

    func unpin(_ ids: [UUID], from boardID: UUID) {
        let was = durability(ids)
        core.unassign(ids, from: boardID)
        boardsChanged(ids, was: was)
    }

    /// From one pinboard to another (dragged onto a chip). `from` nil: just added to `to`.
    func move(_ ids: [UUID], from: UUID?, to: UUID) {
        guard boards.contains(where: { $0.id == to }) else { return }
        let was = durability(ids)
        core.move(ids, from: from, to: to)
        boardsChanged(ids, was: was)
    }

    private func durability(_ ids: [UUID]) -> [UUID: Bool] {
        var m: [UUID: Bool] = [:]
        for c in core.items where ids.contains(c.id) { m[c.id] = durable(c) }
        return m
    }

    /// After items moved between pinboards: the pinboards' file is opened if this is the first pin, files follow, the limits
    /// apply again to what is on no pinboard.
    private func boardsChanged(_ ids: [UUID], was: [UUID: Bool]) {
        if !boardsOpen, core.items.contains(where: { ids.contains($0.id) && $0.pinned }) { openBoards() }
        syncDurability(ids, wasDurable: was)
        forget(core.prune(now: now(), settings: settings))              // unpinning may put it over a limit
        scheduleSave()
        publish()
    }

    // MARK: pinboards themselves

    /// Changes the pinboards with `change` (create, rename, recolour, reorder…); saved (encrypted) at once.
    @discardableResult
    func editBoards(_ change: (inout [ClipBoard]) -> Bool) -> Bool {
        var b = boards
        guard change(&b) else { return false }
        boards = PinboardRules.normalized(b)
        if !boardsOpen { openBoards() }
        scheduleSave()
        onBoardsChange()
        return true
    }

    @discardableResult
    func createBoard(_ name: String, color: Int? = nil, icon: String? = nil) -> ClipBoard? {
        var made: ClipBoard?
        editBoards { b in made = PinboardRules.create(&b, name: name, color: color, icon: icon); return made != nil }
        return made
    }

    /// Deletes a pinboard (never Favorites). Its items stay in the history; those on no other pinboard are subject to the
    /// limits again.
    func deleteBoard(_ id: UUID) {
        guard id != ClipBoard.favoritesID, boards.contains(where: { $0.id == id }) else { return }
        let ids = core.items.filter { $0.boards.contains(id) }.map(\.id)
        let was = durability(ids)
        boards.removeAll { $0.id == id }
        core.forgetBoard(id)
        boardsChanged(ids, was: was)
        onBoardsChange()
    }

    func remove(_ id: UUID) { remove([id]) }

    /// Deletes items; Undo brings them back for a few seconds (their images and formatting are read back into memory first).
    func remove(_ ids: [UUID], undoable: Bool = true) {
        var gone: [ClipItem] = []
        for id in ids {
            guard let i = core.items.firstIndex(where: { $0.id == id }) else { continue }
            if undoable && durable(core.items[i]) { loadPayloads(i) }
            gone.append(core.items.remove(at: i))
        }
        guard !gone.isEmpty else { return }
        forget(gone)
        if undoable { offerUndo(gone) }
        scheduleSave()
        publish()
    }

    private func offerUndo(_ gone: [ClipItem]) {
        undoWork?.cancel()
        undo = (gone, now().addingTimeInterval(8))
        let w = DispatchWorkItem { [weak self] in self?.undo = nil }
        undoWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    /// Brings back what was just deleted (where it was in time, with its pinboards and name).
    @discardableResult
    func undoRemove() -> Int {
        guard let u = undo else { return 0 }
        undo = nil; undoWork?.cancel()
        for var c in u.items where !core.items.contains(where: { $0.id == c.id || ($0.digest == c.digest && $0.kind == c.kind) }) {
            c.boards.removeAll { b in !boards.contains { $0.id == b } }
            core.items.append(c)
            if durable(c) { writeBlobs(c) }
        }
        core.items.sort { $0.date > $1.date }
        scheduleSave()
        publish()
        return u.items.count
    }

    /// Everything that is on no pinboard.
    func clearHistory() {
        for i in core.items.indices where !core.items[i].pinned && durable(core.items[i]) { loadPayloads(i) }   // for Undo
        let gone = core.items.filter { !$0.pinned }
        core.items.removeAll { !$0.pinned }
        forget(gone)
        if !gone.isEmpty { offerUndo(gone) }
        scheduleSave()
        publish()
    }

    /// Everything, pinboards included, plus the saved files and the Keychain key (also what is left from a time persistence
    /// was on). Persistence stays as it was: if on, it starts again with a new key. Returns false when something stayed.
    @discardableResult
    func deleteEverything() -> Bool {
        saveWork?.cancel(); saveWork = nil
        undo = nil
        core.items = []
        boards = [.favorites]
        boardsOpen = false
        thumbs = [:]
        query = ""
        var ok = true
        io.sync { [store] in do { try store.wipe() } catch { ok = false } }
        if saving {
            do { try io.sync { [store] in try store.unlock() }; boardsOpen = true }
            catch { saving = false; settings.persist = false; settings.save(defaults); problem = keychainProblem(error) }
        }
        publish()
        onBoardsChange()
        return ok
    }

    /// Edits a text item: `replace` changes it in place (same id, pinboards, name; formatting dropped: it no longer matches),
    /// otherwise a new item is added at the top. Nil: not a text, or empty.
    @discardableResult
    func edit(_ id: UUID, text: String, replace: Bool) -> ClipItem? {
        let t = text
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, t.utf8.count <= settings.maxItemBytes,
              let i = core.items.firstIndex(where: { $0.id == id }), core.items[i].kind == .text else { return nil }
        if !replace {
            var n = ClipItem.text(t, date: now(), source: core.items[i].source)
            n.boards = []
            add(n)
            return core.items.first { $0.digest == n.digest && $0.kind == .text }
        }
        var c = core.items[i]
        let d = Data(t.utf8)
        let digest = ClipItem.digest(.text, d)
        if let other = core.items.firstIndex(where: { $0.id != id && $0.kind == .text && $0.digest == digest }) {
            // The edit made it the same as another item: one item, with both's pinboards and the newer date.
            for b in core.items[other].boards where !c.boards.contains(b) { c.boards.append(b) }
            c.title = c.title ?? core.items[other].title
            let gone = core.items.remove(at: other)
            forget([gone])
        }
        let j = core.items.firstIndex { $0.id == id }!
        c.text = t; c.digest = digest; c.bytes = d.count; c.hasRich = false; c.rich = nil
        core.items[j] = c
        io.async { [store] in try? FileManager.default.removeItem(at: store.blob(id, .rich)) }
        scheduleSave()
        publish()
        return c
    }

    /// Names an item (nil or empty: its own text again).
    func rename(_ id: UUID, _ title: String?) {
        guard let i = core.items.firstIndex(where: { $0.id == id }) else { return }
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        core.items[i].title = (t?.isEmpty ?? true) ? nil : String(t!.prefix(ClipItem.maxTitle))
        scheduleSave()
        publish()
    }

    /// Changes one item in place (snippet settings, recognised text, how often it was pasted where). Saved if it is on disk.
    func modify(_ id: UUID, _ change: (inout ClipItem) -> Void) {
        guard let i = core.items.firstIndex(where: { $0.id == id }) else { return }
        change(&core.items[i])
        if durable(core.items[i]) { scheduleSave() }
        publish()
    }

    func update(_ new: ClipSettings) {
        let old = settings
        var s = new
        s.persist = old.persist                                       // only through setPersist
        settings = s
        s.save(defaults)
        if s.excludedApps != old.excludedApps {                       // an app excluded now: its unpinned copies go (what the
            let gone = core.items.filter { !$0.pinned && ClipRules.isExcluded(source: $0.source, settings: s) }   // user pinned stays,
            core.items.removeAll { !$0.pinned && ClipRules.isExcluded(source: $0.source, settings: s) }           // as for other devices)
            forget(gone)
        }
        if !s.includeRemote && old.includeRemote {                    // other devices excluded now: their unpinned copies go
            let gone = core.items.filter { $0.remote && !$0.pinned }
            core.items.removeAll { $0.remote && !$0.pinned }
            forget(gone)
        }
        forget(core.prune(now: now(), settings: s))
        scheduleSave()
        publish()
        if s.pasteNext != old.pasteNext || s.openShortcut != old.openShortcut { onBoardsChange() }
    }

    /// On: opens (or makes) the encrypted store and merges what is in memory with what was saved. Off: stops saving the
    /// history (the pinboards stay saved); `wipe` also deletes the history's files (and the key when nothing is pinned),
    /// otherwise they stay (encrypted) for the next time it's turned on.
    func setPersist(_ on: Bool, wipe: Bool = false) {
        if on {
            settings.persist = true
            settings.save(defaults)
            openStore()
            return
        }
        saveWork?.cancel(); saveWork = nil
        if saving {
            flush()
            for i in core.items.indices where !core.items[i].pinned || !boardsOpen { loadPayloads(i) }   // stays usable from memory
        }
        core.items.removeAll { $0.kind == .image && $0.payload == nil && !(boardsOpen && $0.pinned) }
        saving = false
        settings.persist = false
        settings.save(defaults)
        problem = nil
        let keepBoards = boardsOpen && (PinboardRules.isCustomized(boards) || core.items.contains { $0.pinned })
        if wipe {
            if keepBoards { io.sync { [store, core] in store.wipeHistory(keeping: Set(core.items.filter(\.pinned).map(\.id))) } }
            else { io.sync { [store] in try? store.wipe() }; boardsOpen = false }
        } else if !keepBoards {
            io.sync { [store] in store.lock() }
            boardsOpen = false
        }
        if keepBoards { saveNow() }
        publish()
    }

    /// `atLaunch`: a Keychain that says no now (locked, a prompt refused) leaves the choice on for the next launch; turning
    /// it on by hand and failing turns it back off.
    private func openStore(atLaunch: Bool = false) {
        do {
            try io.sync { [store] in try store.unlock() }
        } catch {
            // Never a silent fallback to plain files: without the key nothing is written.
            saving = false
            if !atLaunch {
                settings.persist = false
                settings.save(defaults)
            }
            problem = keychainProblem(error)
            return
        }
        var problems: [ClipStore.LoadProblem] = []
        var boardIDs = Set<UUID>(), boardsReadable = true
        if !boardsOpen {
            let b = io.sync { [store] in store.loadBoards() }
            problems.append(b.problem)
            boardsReadable = b.problem != .unreadableIndex && b.problem != .unusable
            if let loaded = b.boards { mergeBoards(loaded) }
            merge(b.items)
            boardIDs = Set(b.items.map(\.id))
            boardsOpen = b.problem != .unusable                        // set aside: a new file; unusable: never written over
        }
        boardIDs.formUnion(core.items.filter(\.pinned).map(\.id))
        let loaded = io.sync { [store] in store.load(keeping: boardIDs, cleanOrphans: boardsReadable) }
        problems.append(loaded.problem)
        if loaded.problem == .unusable {                               // can't be read nor set aside: never written over
            saving = false
            problem = L("The saved history can't be read: nothing is saved until it can.")
            publish()
            return
        }
        say(problems)
        merge(loaded.items)
        saving = true
        afterOpen()
    }

    /// Opens only the pinboards' file (a memory-only history with something pinned): at launch when there is one, or at the
    /// first pin or pinboard. A Keychain that says no keeps them in memory only, said plainly.
    @discardableResult
    func openBoards(atLaunch: Bool = false) -> Bool {
        if boardsOpen { return true }
        do { try io.sync { [store] in try store.unlock() } }
        catch { problem = String(format: L("Can't use the Keychain (%@): pinboards stay in memory only."), "\(error)"); return false }
        let b = io.sync { [store] in store.loadBoards() }
        if b.problem == .unusable { problem = L("The saved pinboards can't be read: nothing is saved until they can."); return false }
        say([b.problem])
        if let loaded = b.boards { mergeBoards(loaded) }
        merge(b.items)
        boardsOpen = true
        if b.problem == .none, !store.hasIndex {                       // no saved history either: leftovers of one go
            let keep = Set(core.items.filter(\.pinned).map(\.id))
            io.sync { [store] in store.removeOrphans(keeping: keep) }
        }
        afterOpen()
        return true
    }

    private func say(_ problems: [ClipStore.LoadProblem]) {
        var msgs: [String] = [], dropped = 0
        for p in problems {
            switch p {
            case .none, .unusable: break
            case .unreadableIndex: msgs.append(L("The saved history couldn't be read and was set aside."))
            case .droppedItems(let n): dropped += n
            }
        }
        if dropped > 0 { msgs.append(String(format: L("%d saved items couldn't be read."), dropped)) }
        problem = msgs.isEmpty ? nil : msgs.joined(separator: " ")
    }

    /// The loaded pinboards first, in their saved order; ones made in memory meanwhile follow.
    private func mergeBoards(_ loaded: [ClipBoard]) {
        var out = loaded
        for b in boards where !out.contains(where: { $0.id == b.id }) { out.append(b) }
        boards = PinboardRules.normalized(out)
    }

    /// Saved items joined with those in memory: the same item (id or content) once, with every pinboard either side had, its
    /// name and the newer date; newest first.
    private func merge(_ loaded: [ClipItem]) {
        for l in loaded {
            if let i = core.items.firstIndex(where: { $0.id == l.id || ($0.digest == l.digest && $0.kind == l.kind) }) {
                var m = core.items[i]
                for b in l.boards where !m.boards.contains(b) { m.boards.append(b) }
                m.title = m.title ?? l.title
                m.ocr = m.ocr ?? l.ocr
                if l.date > m.date { m.date = l.date }
                for (k, v) in l.used { m.used[k] = max(m.used[k] ?? 0, v) }
                m.snippet = m.snippet ?? l.snippet
                core.items[i] = m
            } else {
                core.items.append(l)
            }
        }
        core.items.sort { $0.date > $1.date }
    }

    /// After opening: limits, files of what is now on disk, one save, the views.
    private func afterOpen() {
        forget(core.prune(now: now(), settings: settings))
        for i in core.items where durable(i) && (i.payload != nil || i.rich != nil) {
            if (i.payload == nil || store.hasBlob(i.id, .image)) && (i.rich == nil || store.hasBlob(i.id, .rich)) { dropPayload(i.id) }
            else { writeBlobs(i) }
        }
        saveNow()
        publish()
        refreshMissing()
        onBoardsChange()
    }

    private func keychainProblem(_ error: Error) -> String {
        String(format: L("Can't use the Keychain (%@): the history stays in memory only."), "\(error)")
    }

    // MARK: limits, missing files, images

    /// Limits apply even when nothing new is copied (the age one above all).
    func expire() {
        let removed = core.prune(now: now(), settings: settings)
        if !removed.isEmpty {
            forget(removed)
            if saving { scheduleSave() }
            publish()
        }
        refreshMissing()
    }

    func refreshMissing() {
        let refs = core.items.filter { $0.kind == .files }.map { ($0.id, $0.paths) }
        guard !refs.isEmpty else { if !missing.isEmpty { missing = [] }; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let gone = Set(refs.filter { _, paths in paths.contains { !FileManager.default.fileExists(atPath: $0) } }.map(\.0))
            DispatchQueue.main.async { if let self, self.missing != gone { self.missing = gone } }
        }
    }

    /// Tests: the same, synchronously.
    func refreshMissingNow() {
        missing = Set(core.items.filter { $0.kind == .files && $0.paths.contains { !FileManager.default.fileExists(atPath: $0) } }.map(\.id))
    }

    /// The PNG, from memory or from its encrypted file.
    func imageData(_ item: ClipItem) -> Data? {
        if let p = core.items.first(where: { $0.id == item.id })?.payload ?? item.payload { return p }
        return store.unlocked ? io.sync { [store] in store.readImage(item.id) } : nil
    }

    /// A text's formatting, from memory or from its encrypted file.
    func richData(_ item: ClipItem) -> ClipRich? {
        guard item.hasRich else { return nil }
        if let r = core.items.first(where: { $0.id == item.id })?.rich ?? item.rich { return r }
        return store.unlocked ? io.sync { [store] in store.readRich(item.id) } : nil
    }

    /// A small picture for the row, made once, off the main thread.
    func thumbnail(_ item: ClipItem) -> NSImage? {
        if let t = thumbs[item.id] { return t }
        guard item.kind == .image, !thumbsLoading.contains(item.id) else { return nil }
        thumbsLoading.insert(item.id)
        let payload = core.items.first(where: { $0.id == item.id })?.payload ?? item.payload
        let unlocked = store.unlocked
        io.async { [weak self, store] in
            let data = payload ?? (unlocked ? store.readImage(item.id) : nil)
            var img: NSImage?
            if let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 96,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbsLoading.remove(item.id)
                if let img, self.core.items.contains(where: { $0.id == item.id }) { self.thumbs[item.id] = img }
            }
        }
        return nil
    }

    private static var appNames: [String: String] = [:]
    static func appName(_ bundle: String?) -> String? {
        guard let b = bundle, !b.isEmpty else { return nil }
        if b == ClipRules.remoteSource { return L("Another device") }
        if b == "device:iphone" { return "iPhone" }                                   // Cocaine's iPhone sync (ClipSync.swift)
        if let n = appNames[b] { return n }
        let n = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map { FileManager.default.displayName(atPath: $0.path) } ?? b
        let name = n.hasSuffix(".app") ? String(n.dropLast(4)) : n
        appNames[b] = name
        return name
    }

    /// What search also looks at: the kind's name and the source app.
    func describe(_ item: ClipItem) -> String {
        let kind = item.kind == .image ? L("Image") : item.kind == .files ? L("File") : ""
        return [kind, Self.appName(item.source) ?? ""].joined(separator: " ")
    }

    func board(_ id: UUID) -> ClipBoard? { boards.first { $0.id == id } }

    // MARK: saving

    func publish() { items = core.items }

    /// Items gone from the list: their thumbnails, and their files when they were on disk (a history kept on disk while not
    /// saved any more keeps its files: they belong to that saved copy).
    func forget(_ removed: [ClipItem]) {
        for r in removed {
            thumbs[r.id] = nil
            if store.unlocked && durable(r) { io.async { [store] in store.removeBlobs(r.id) } }
        }
    }

    func scheduleSave() {
        guard saving || boardsOpen else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    /// The history (what is on no pinboard) into the index when it is saved; the pinboards and their items into theirs when
    /// that file is open (and removed when there is nothing left worth keeping).
    private func saveNow() {
        saveWork = nil
        guard saving || boardsOpen else { return }
        let saveHistory = saving, saveBoards = boardsOpen
        // Without the pinboards' file (it can't be read nor set aside), pinned items stay in the history's index.
        let offDisk = keepOffDisk
        let history = (saveBoards ? core.items.filter { !$0.pinned } : core.items).filter { $0.pinned || !offDisk($0) }
        let pinned = core.items.filter(\.pinned), b = boards
        io.async { [weak self, store] in
            do {
                if saveHistory { try store.saveIndex(history) }
                if saveBoards {
                    if pinned.isEmpty && !PinboardRules.isCustomized(b) { store.removeBoardsFile() }
                    else { try store.saveBoards(b, items: pinned) }
                }
            } catch {
                DispatchQueue.main.async { self?.problem = L("Couldn't save the history.") + " " + error.localizedDescription }
            }
        }
    }

    /// Writes what's pending and waits for it (quit, tests).
    func flush() {
        if saveWork != nil { saveWork?.cancel(); saveNow() }
        io.sync {}
    }

    /// Tests and the render tool: a ready-made list, nothing captured or saved.
    func replace(_ list: [ClipItem]) {
        core.items = list
        thumbs = [:]
        publish()
    }

    /// The render tool: ready-made pinboards (nothing saved).
    func replaceBoards(_ list: [ClipBoard]) { boards = PinboardRules.normalized(list) }
}
