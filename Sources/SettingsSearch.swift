// Settings search (docs/settings-search.en.md): one field at the top of the panel finds any setting from what the user
// types, in any of the app's 8 languages, with typos, synonyms and related words; the result opens its tab, scrolls to its
// row (or card) and lights it up. All offline: the index (Sources/SettingsIndex.swift), a curated table of concepts and their
// words in every language (Localization/<lang>.lproj/SearchIndex.strings), fuzzy matching, and — when macOS has them —
// Apple's on-device word embeddings for words the table doesn't know (NaturalLanguage; nothing is ever sent anywhere).
//
// Pieces: SearchText (folding and words), SearchEngine (pure: build, match, rank; --ui-test checks it), SettingsSearch (the
// panel's state: query, results, keyboard, the jump), SettingsAnchor (rows and cards report where they are, and light up),
// SettingsSearchField and SettingsSearchResults (the views). Strings: Localization/<lang>.lproj/Search.strings.

import AppKit
import NaturalLanguage
import SwiftUI

// MARK: - Text

enum SearchText {
    /// Case, accents, widths and compatibility forms folded away; "Wi‑Fi", "wi fi" and "WIFI" all become "wi fi"/"wifi".
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "ß", with: "ss")
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            (0x3040...0x30FF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) || (0x4E00...0x9FFF).contains(s.value)
                || (0xF900...0xFAFF).contains(s.value) || (0xFF66...0xFF9F).contains(s.value)
        }
    }

    /// The words of a folded text: letters and digits; everything else separates. A run of CJK characters is one word (and the
    /// whole text is also searched as one string, see `joined`).
    static func words(_ folded: String) -> [String] {
        var out: [String] = [], cur = ""
        for c in folded {
            if c.isLetter || c.isNumber { cur.append(c) } else if !cur.isEmpty { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The folded text without separators: "wi-fi" → "wifi", "画面 の 明るさ" → "画面の明るさ".
    static func joined(_ folded: String) -> String { words(folded).joined() }

    /// Words that carry no meaning in a query, in the app's languages (folded).
    static let stopwords: Set<String> = [
        "the", "a", "an", "of", "to", "for", "and", "or", "in", "on", "my", "is", "how", "do", "i", "when", "with", "settings", "setting",
        "il", "lo", "la", "gli", "le", "un", "uno", "una", "di", "del", "della", "da", "per", "e", "o", "come", "con", "mio", "impostazioni", "impostazione",
        "el", "los", "las", "de", "y", "en", "mi", "ajustes", "ajuste", "configuracion",
        "les", "des", "du", "et", "ou", "mon", "ma", "avec", "pour", "reglages", "parametres",
        "der", "die", "das", "den", "ein", "eine", "und", "oder", "mit", "fur", "mein", "einstellungen", "einstellung",
    ]

    /// Damerau–Levenshtein distance (adjacent swaps count once), stopping early past `limit`.
    static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { cur[j] = min(cur[j], prev2[j - 2] + 1) }
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[b.count]
    }

    /// How many typos a word of this length may have: none up to 3 letters, 1 up to 6, then 2.
    static func typos(_ n: Int) -> Int { n <= 3 ? 0 : n <= 6 ? 1 : 2 }
}

// MARK: - The engine (pure)

/// One setting in the index: where it is (tab, card, row) and what it is about. Titles are the panel's own string keys (the
/// English text), so every language's words come from the string tables; `concepts` name entries of SearchIndex.strings.
struct SettingsEntry: Equatable {
    let tab: String                 // PanelTabs: "", "ai", "auto", "island"
    let card: String                // the card's title key
    let row: String?                // the row's title key (nil: the card itself)
    var detail: String? = nil       // its detail or tooltip key: searched too, weighed less
    var concepts: [String] = []
    var icon: String = "gearshape"
    /// The card's concepts, for a row: searched a little less than its own.
    var cardConcepts: [String] = []

    var id: String { card + "|" + (row ?? "") }
}

/// A match, ready to show: the entry, its score, and what matched (for the result's second line).
struct SearchHit: Equatable {
    let entry: SettingsEntry
    let score: Double
    var via: String? = nil          // a synonym or related word that matched, shown as "≈ word"
}

struct SearchEngine {
    /// A searchable text (folded): its words (as indexes into the vocabulary) and its joined form. Equal texts are stored once
    /// (the concept lists are shared by many settings), and every distinct word is compared with a query word once.
    struct Field {
        let words: [Int]
        let joined: String
        let original: String
    }
    struct Ref { let field: Int; let weight: Double }
    struct Doc {
        let entry: SettingsEntry
        let refs: [Ref]               // refs[0]: its own title in the app's language
        let titleNow: String          // folded, in the app's language (a prefix of it ranks first)
    }

    private(set) var vocab: [String] = []
    private(set) var fields: [Field] = []
    let docs: [Doc]
    /// Related words for a query word the index doesn't know (embeddings), injectable for tests; nil: none.
    var related: ((String) -> [String])?

    /// Builds the index. `text(key, lang)` looks a string key up in one language; `concepts(id)` gives a concept's words in all
    /// languages; `lang` is the app's language now (its title weighs most).
    init(entries: [SettingsEntry], languages: [String], lang: String,
         text: (String, String) -> String?, concepts: (String) -> [String], related: ((String) -> [String])? = nil) {
        self.related = related
        var vocab: [String] = [], wordID: [String: Int] = [:]
        var fields: [Field] = [], fieldID: [String: Int] = [:]
        func field(_ t: String) -> Int {
            let f = SearchText.fold(t)
            if let i = fieldID[f] { return i }
            let ws = SearchText.words(f).map { w -> Int in
                if let i = wordID[w] { return i }
                vocab.append(w); wordID[w] = vocab.count - 1
                return vocab.count - 1
            }
            fields.append(Field(words: ws, joined: SearchText.joined(f), original: t))
            fieldID[f] = fields.count - 1
            return fields.count - 1
        }
        var conceptFields: [String: [Int]] = [:]
        func conceptIDs(_ c: String) -> [Int] {
            if let ids = conceptFields[c] { return ids }
            let ids = concepts(c).map(field)
            conceptFields[c] = ids
            return ids
        }
        var docs: [Doc] = []
        for e in entries {
            var refs: [Ref] = []
            func add(_ key: String?, _ wNow: Double, _ wOther: Double) {
                guard let key else { return }
                var seen = Set<String>()
                for l in [lang] + languages {
                    guard let t = text(key, l), !t.isEmpty, seen.insert(t).inserted else { continue }
                    refs.append(Ref(field: field(t), weight: l == lang ? wNow : wOther))
                }
            }
            add(e.row ?? e.card, 1.0, 0.9)               // the setting's name, in every language
            if e.row != nil { add(e.card, 0.55, 0.5) }   // its card
            add(e.detail, 0.45, 0.35)                    // what it does
            for c in e.concepts { refs += conceptIDs(c).map { Ref(field: $0, weight: 0.8) } }
            for c in e.cardConcepts where !e.concepts.contains(c) {     // the card's subject, a little less
                refs += conceptIDs(c).map { Ref(field: $0, weight: 0.6) }
            }
            docs.append(Doc(entry: e, refs: refs, titleNow: SearchText.fold(text(e.row ?? e.card, lang) ?? (e.row ?? e.card))))
        }
        self.vocab = vocab; self.fields = fields; self.docs = docs
    }

    /// The query's meaningful words (folded; stopwords dropped unless that leaves nothing).
    static func tokens(_ query: String) -> [String] {
        let w = SearchText.words(SearchText.fold(query))
        let kept = w.filter { !SearchText.stopwords.contains($0) }
        return kept.isEmpty ? w : kept
    }

    /// How well a query word matches one word of the index (0 = not at all).
    static func matchWord(_ token: String, _ tc: [Character], cjk: Bool, _ w: String) -> Double {
        if w == token { return 1.0 }
        if w.hasPrefix(token) { return token.count >= 2 || cjk ? 0.88 : 0 }
        if token.count >= 3 && w.count > token.count && w.contains(token) { return 0.62 }
        guard !cjk else { return 0 }
        let k = SearchText.typos(token.count)
        guard k > 0, w.count >= token.count - k else { return 0 }
        let wc = Array(w)
        if abs(wc.count - tc.count) <= k, SearchText.distance(tc, wc, limit: k) <= k { return 0.66 }
        if wc.count > tc.count, SearchText.distance(tc, Array(wc.prefix(tc.count)), limit: k) <= k { return 0.56 }
        return 0
    }

    /// How well a query word matches each distinct field (one pass over the vocabulary, then over the fields).
    func fieldScores(_ token: String) -> [Double] {
        let cjk = token.contains(where: SearchText.isCJK), tc = Array(token)
        let ws = vocab.map { Self.matchWord(token, tc, cjk: cjk, $0) }
        return fields.map { f in
            var best = 0.0
            for w in f.words where ws[w] > best { best = ws[w] }
            // Across separators ("wifi" in "wi-fi") and inside CJK runs ("明るさ" in "画面の明るさ").
            if best < 0.7, token.count >= (cjk ? 1 : 4), f.joined.contains(token) { best = max(best, cjk ? 0.85 : 0.7) }
            return best
        }
    }

    /// The best weighted match of a query word in a document, and the field's text when it isn't the title.
    private func best(_ scores: [Double], _ d: Doc) -> (Double, String?) {
        var top = 0.0, via: String?
        for (i, r) in d.refs.enumerated() {
            let s = scores[r.field] * r.weight
            if s > top { top = s; via = i == 0 ? nil : fields[r.field].original }
        }
        return (top, via)
    }

    /// Ranked results, best first (at most `limit`). Every word must match something (a word nothing matches well is looked up
    /// through `related`, at half weight); for a query of three words or more, one may miss.
    func search(_ query: String, limit: Int = 30, allowed: (SettingsEntry) -> Bool = { _ in true }) -> [SearchHit] {
        let tokens = Self.tokens(query)
        guard !tokens.isEmpty else { return [] }
        let phrase = SearchText.fold(query).trimmingCharacters(in: .whitespaces)
        let scores = tokens.map(fieldScores)
        var relatedScores: [[[Double]]] = tokens.map { _ in [] }
        if let related {
            for (i, t) in tokens.enumerated() where (scores[i].max() ?? 0) < 0.6 {
                relatedScores[i] = related(t).prefix(10).map(fieldScores)
            }
        }
        var hits: [SearchHit] = []
        for (n, d) in docs.enumerated() where allowed(d.entry) {
            var total = 0.0, misses = 0, via: String?
            for i in tokens.indices {
                var (s, v) = best(scores[i], d)
                for rs in relatedScores[i] {
                    let (r, rv) = best(rs, d)
                    if r * 0.5 > s { s = r * 0.5; v = rv ?? v }
                }
                if s < 0.3 { misses += 1 } else { total += s; if via == nil { via = v } }
            }
            guard misses == 0 || (tokens.count >= 3 && misses == 1) else { continue }
            var score = total / Double(tokens.count) - Double(misses) * 0.2
            if !phrase.isEmpty && d.titleNow.hasPrefix(phrase) { score += 0.5 }
            else if phrase.count >= 3 && d.titleNow.contains(phrase) { score += 0.25 }
            if d.entry.row == nil { score -= 0.02 }                 // a row before its own card on a tie
            score -= Double(n) * 1e-6                               // equal scores keep the index's order
            hits.append(SearchHit(entry: d.entry, score: score, via: via))
        }
        // Only what is close to the best: a strong match doesn't drown in everything that shares one loose word with it.
        let sorted = hits.sorted { $0.score > $1.score }
        let floor = max(0.3, (sorted.first?.score ?? 0) * Self.relativeFloor)
        return Array(sorted.prefix { $0.score >= floor }.prefix(limit))
    }
    /// Results below this share of the best one's score are left out.
    static let relativeFloor = 0.55
}

// MARK: - Strings in every language, concepts, embeddings

enum SearchStrings {
    private static var bundles: [String: Bundle] = [:]
    private static func bundle(_ lang: String) -> Bundle? {
        if let b = bundles[lang] { return b }
        guard let p = Bundle.main.path(forResource: lang, ofType: "lproj"), let b = Bundle(path: p) else { return nil }
        bundles[lang] = b
        return b
    }

    /// A string key in one language, from any of the app's tables (nil when no table has it).
    static func text(_ key: String, _ lang: String) -> String? {
        guard let b = bundle(lang) else { return lang == "en" ? key : nil }
        let miss = "\u{0}missing"
        for t in [nil] + Language.extraTables.map(Optional.some) {
            let v = b.localizedString(forKey: key, value: miss, table: t)
            if v != miss { return v }
        }
        return lang == "en" ? key : nil
    }

    /// A concept's words in every language (SearchIndex.strings: comma-separated).
    static func concept(_ id: String) -> [String] {
        var out: [String] = []
        for l in Language.codes {
            guard let b = bundle(l) else { continue }
            let v = b.localizedString(forKey: id, value: "", table: "SearchIndex")
            out += v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return out
    }
}

/// Related words from Apple's on-device word embeddings (NaturalLanguage), for a word neither the index nor the concept table
/// knows ("lumière" → "lumineux"…). Only what macOS ships; when a language has none, or the framework says no, it is skipped
/// and the search works the same without it. Off in tests unless asked for (--ui-test checks it degrades gracefully).
enum SearchSemantics {
    static var enabled = true
    private static var embeddings: [NLEmbedding]?
    private static var cache: [String: [String]] = [:]

    static var available: [NLEmbedding] {
        if let e = embeddings { return e }
        let langs: [NLLanguage] = [.english, .italian, .spanish, .french, .german]
        let e = langs.compactMap { NLEmbedding.wordEmbedding(for: $0) }
        embeddings = e
        return e
    }

    static func related(_ word: String) -> [String] {
        guard enabled, word.count >= 3, !word.contains(where: SearchText.isCJK) else { return [] }
        if let c = cache[word] { return c }
        var out: [String] = []
        for e in available where e.contains(word) {
            for (w, d) in e.neighbors(for: word, maximumCount: 8) where d < 1.05 { out.append(SearchText.fold(w)) }
        }
        // The word's dictionary form ("batterie" → "batteria", "pasting" → "paste").
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        if let lemma = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma).0?.rawValue, lemma.lowercased() != word { out.append(SearchText.fold(lemma)) }
        cache[word] = out
        return out
    }
}

// MARK: - The panel's search state

final class SettingsSearch: ObservableObject {
    static let shared = SettingsSearch()

    @Published var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published private(set) var results: [SearchHit] = []
    @Published var selected = 0
    /// The row or card lit up after a jump (its anchor key), fading out by itself.
    private(set) var lit: String? {
        get { SearchLight.shared.key }
        set { SearchLight.shared.key = newValue }
    }
    /// The field has the keyboard (the results list then follows ↑↓).
    @Published var editing = false

    /// The key suffix of a row's control frame (SettingsControlAnchor).
    static let controlSuffix = "|◇"
    /// Where each anchored row and card is in the panel's page (SettingsAnchor), by key "card|row".
    var frames: [String: CGRect] = [:]
    /// Scrolls the panel's page so a rect of it is in view (set by the app).
    var reveal: (CGRect) -> Void = { _ in }
    /// Focuses the field (set by the field's view).
    var focusField: () -> Void = {}
    /// The tabs the panel has now, and the island's switch (set by PanelView each time it draws).
    var tabs: [String] = PanelTabs.list(ai: true, island: true)
    var openTab: (String) -> Void = { _ in }
    private var engine: SearchEngine?
    private var engineLang = ""
    private var litGeneration = MotionGeneration()

    /// Rebuilds the index for the app's language now (cheap: a few hundred strings).
    private func currentEngine() -> SearchEngine {
        let lang = Language.current
        if let e = engine, engineLang == lang { return e }
        let e = Self.testEngine(lang: lang, semantic: SearchSemantics.enabled)
        engine = e; engineLang = lang
        return e
    }

    func refresh() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tabs = self.tabs
        // Island settings stay findable while the island is off: the result says how to show them (the switch).
        results = q.isEmpty ? [] : currentEngine().search(q) { e in tabs.contains(e.tab) || e.tab == "island" }
        selected = 0
        announce()
    }

    private var announceWork: DispatchWorkItem?
    /// VoiceOver hears how many settings match, once the typing pauses.
    private func announce() {
        announceWork?.cancel()
        guard !query.isEmpty else { return }
        let n = results.count
        let w = DispatchWorkItem { A11y.announce(n == 0 ? L("No settings found") : String(format: L("%d settings found"), n)) }
        announceWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// The panel opened: no query, the field not in use.
    func reset() {
        if !query.isEmpty { query = "" }
        if editing { editing = false }
    }

    /// Lights a row or card up at once (render tool: --lit "Card|Row", in English keys).
    func light(card: String, row: String?) { lit = L(card) + "|" + (row.map(L) ?? "") }

    /// The anchor key a hit jumps to: its row when the row reported a frame, else its card.
    func target(_ e: SettingsEntry) -> String {
        let card = L(e.card)
        if let r = e.row { let k = card + "|" + L(r); if frames[k] != nil { return k } }
        return card + "|"
    }

    /// Opens a result: its tab, then (once the page is laid out) scrolls to it and lights it up for a moment.
    func open(_ hit: SearchHit) {
        var e = hit.entry
        if e.tab == "island" && !tabs.contains("island") {            // the island is off: its switch, in General → Cocaine
            e = SettingsEntry(tab: "", card: "Cocaine", row: (NotchGeometry.current()?.hasNotch ?? true) ? "Show in the notch" : "Show at the top of the screen")
        }
        query = ""
        editing = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        openTab(e.tab)
        let g = litGeneration.begin()
        // Twice: after the page change has laid out, and again once its slide has settled (a card's height may change).
        for delay in [0.06, Motion.reduce ? 0.12 : 0.42] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.litGeneration.isCurrent(g) else { return }
                let key = self.target(e)
                if let r = self.frames[key] { self.reveal(r.insetBy(dx: 0, dy: -Space.l)) }
                if self.lit != key { Motion.with(.notice) { self.lit = key } }
                A11y.announce(e.row.map(L) ?? L(e.card))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, self.litGeneration.isCurrent(g) else { return }
            Motion.with(.crossfade) { self.lit = nil }
        }
    }

    /// The panel's keys, before anything else sees them (AppDelegate's panel monitor): ⌘F focuses the field; while there is a
    /// query, ↑↓ move through the results, Return opens one, Esc clears the query (a second Esc closes the panel as before);
    /// typing a letter anywhere in the panel starts a search. True when the key was used.
    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .control, .option])
        if flags == .command, e.charactersIgnoringModifiers?.lowercased() == "f" { focusField(); return true }
        if let tv = e.window?.firstResponder as? NSTextView, tv.hasMarkedText() { return false }   // an input method composing
        let inField = editing && e.window?.firstResponder is NSTextView      // the field's editor has the keyboard now
        if !query.isEmpty || inField {
            switch e.keyCode {
            case 125: if !results.isEmpty { selected = min(results.count - 1, selected + 1); speakSelected() }; return true
            case 126: if !results.isEmpty { selected = max(0, selected - 1); speakSelected() }; return true
            case 36, 76: if results.indices.contains(selected) { open(results[selected]) }; return !query.isEmpty || inField
            case 53:
                if !query.isEmpty { query = ""; return true }
                if inField { editing = false; e.window?.makeFirstResponder(nil); return true }
            default: break
            }
        }
        // Type to search: a printable key while nothing else takes typing (no field, no recorder) goes to the field.
        if !inField, flags.isEmpty, !(e.window?.firstResponder is NSText),
           let c = e.characters, c.count == 1, let ch = c.first, ch.isLetter || ch.isNumber {
            focusField()
            query += c
            return true
        }
        return false
    }

    private func speakSelected() {
        guard results.indices.contains(selected) else { return }
        let e = results[selected].entry
        A11y.announce((e.row.map(L) ?? L(e.card)) + ", " + SettingsSearch.place(e))
    }

    /// "Automation › Smart Triggers": where a setting is.
    static func place(_ e: SettingsEntry) -> String {
        let tab: String
        switch e.tab { case "ai": tab = L("AI alerts"); case "auto": tab = L("Automation"); case "island": tab = L("Island"); default: tab = L("General") }
        let card = L(e.card)
        return e.row == nil || card == tab ? tab : tab + " › " + card      // never "Island › Island"
    }

    /// Tests: a fresh engine with these settings.
    static func testEngine(lang: String, semantic: Bool) -> SearchEngine {
        SearchEngine(entries: SettingsIndex.entries, languages: Language.codes, lang: lang, text: SearchStrings.text,
                     concepts: SearchStrings.concept, related: semantic ? SearchSemantics.related : nil)
    }
}

// MARK: - Anchors: where rows and cards are, and the light after a jump

private struct SettingsCardKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    /// The title of the card a row is in (set by the panel's cards), so equal row names in two cards stay apart.
    var settingsCard: String {
        get { self[SettingsCardKey.self] }
        set { self[SettingsCardKey.self] = newValue }
    }
}

struct SettingsFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { a, _ in a } }
}

/// The lit row, in an object of its own: the anchors (one per row and card) watch only this, so a keystroke or an arrow press
/// in the search doesn't redraw all of them.
final class SearchLight: ObservableObject {
    static let shared = SearchLight()
    @Published var key: String?
}

/// Reports a row's (or, with `row` nil, a card's) frame in the panel's page, and draws the light after a search jump.
struct SettingsAnchor: ViewModifier {
    let row: String?
    var card: String? = nil
    @Environment(\.settingsCard) private var envCard
    @ObservedObject private var light = SearchLight.shared

    func body(content: Content) -> some View {
        let key = (card ?? envCard) + "|" + (row ?? "")
        let on = light.key == key
        return content
            .background(GeometryReader { r in
                Color.clear.preference(key: SettingsFrames.self, value: [key: r.frame(in: .named(PickerCenter.space))])
            })
            .overlay {
                RoundedRectangle(cornerRadius: row == nil ? CTL.cardRadius : CTL.innerRadius)
                    .strokeBorder(CTL.accent, lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: row == nil ? CTL.cardRadius : CTL.innerRadius).fill(CTL.accent.opacity(0.12)))
                    .padding(row == nil ? 0 : -Space.xs)
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// Reports where a row's control is drawn (key "card|row|◇"): --ui-test checks every control lies inside its row, the defect
/// of round 7 (a row reporting one line while its control was drawn on a second one, over the next row).
struct SettingsControlAnchor: ViewModifier {
    let row: String
    @Environment(\.settingsCard) private var card
    func body(content: Content) -> some View {
        content.background(GeometryReader { r in
            Color.clear.preference(key: SettingsFrames.self, value: [card + "|" + row + SettingsSearch.controlSuffix: r.frame(in: .named(PickerCenter.space))])
        })
    }
}

extension View {
    /// Where a row's control is (SettingsControlAnchor).
    func settingsControl(_ row: String) -> some View { modifier(SettingsControlAnchor(row: row)) }

    /// A row the search can jump to (its title as shown); inside a card that set `settingsCard`.
    func settingsAnchor(_ row: String) -> some View { modifier(SettingsAnchor(row: row)) }
    /// A whole card the search can jump to (its title as shown).
    func settingsCardAnchor(_ card: String) -> some View { modifier(SettingsAnchor(row: nil, card: card)).environment(\.settingsCard, card) }
}

// MARK: - The field

/// The search field under the panel's header: AppKit's text field (no @FocusState in the command-line build), ⌘F.
struct SettingsSearchField: View {
    @ObservedObject var search = SettingsSearch.shared

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(UI.hint)   // a glyph
                .accessibilityHidden(true)
            SearchFieldBox(text: $search.query, placeholder: L("Search settings"))
                .frame(height: CTL.h)
            if !search.query.isEmpty {
                Button { search.query = ""; search.focusField() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(UI.hint)
                        .frame(width: 20, height: CTL.h).contentShape(Rectangle())
                }
                .buttonStyle(MotionGlyphStyle())
                .help(L("Clear the search"))
                .accessibilityLabel(L("Clear the search"))
                .transition(.opacity)
            } else {
                Text("⌘F").font(UI.detail.monospacedDigit()).foregroundStyle(UI.hint).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Space.m)
        .frame(height: CTL.h + 4)
        .background(RoundedRectangle(cornerRadius: CTL.radius + 2).fill(CTL.track))
        .overlay(RoundedRectangle(cornerRadius: CTL.radius + 2).strokeBorder(search.editing ? CTL.accent.opacity(0.9) : UI.boundary.opacity(0.5), lineWidth: 1))
        .animation(Motion.animation(.hover), value: search.editing)
        .animation(Motion.animation(.crossfade), value: search.query.isEmpty)
        .help(L("Finds any setting: type what you're looking for, in your words"))
    }
}

/// The NSTextField itself: tells SettingsSearch when it has the keyboard, and lets the panel's keys (↑↓, Return, Esc) through.
private struct SearchFieldBox: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let f = FocusReportingField()
        f.isBordered = false; f.drawsBackground = false; f.isBezeled = false
        f.focusRingType = .none                                   // the box's own accent edge shows the focus
        f.font = .systemFont(ofSize: 12)
        f.textColor = .white
        f.placeholderAttributedString = placeholderText
        f.cell?.isScrollable = true; f.cell?.wraps = false; f.lineBreakMode = .byClipping
        f.delegate = context.coordinator
        f.setAccessibilityLabel(placeholder)
        f.stringValue = text
        f.onFocus = { SettingsSearch.shared.editing = $0 }
        SettingsSearch.shared.focusField = { [weak f] in
            guard let f, let w = f.window else { return }
            w.makeKey()
            w.makeFirstResponder(f)
            (f.currentEditor() as? NSTextView)?.moveToEndOfDocument(nil)
        }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text {
            f.stringValue = text
            (f.currentEditor() as? NSTextView)?.moveToEndOfDocument(nil)
        }
        let look = placeholder + (DisplayOptions.contrast ? "|contrast" : "")
        if context.coordinator.placeholderLook != look {             // the language or the contrast changed (not on every keystroke)
            context.coordinator.placeholderLook = look
            f.placeholderAttributedString = placeholderText
            f.setAccessibilityLabel(placeholder)
        }
    }

    private var placeholderText: NSAttributedString {
        NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(DisplayOptions.contrast ? 0.72 : 0.5), .font: NSFont.systemFont(ofSize: 12)])
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchFieldBox
        var placeholderLook: String?                                 // what the field shows now (makeNSView's own is the first)
        init(_ p: SearchFieldBox) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField, parent.text != f.stringValue { parent.text = f.stringValue }
        }
        func controlTextDidEndEditing(_ obj: Notification) { SettingsSearch.shared.editing = false }
    }
}

/// A text field that says when it gets and loses the keyboard.
private final class FocusReportingField: NSTextField {
    var onFocus: (Bool) -> Void = { _ in }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus(true) }
        return ok
    }
}

// MARK: - The results

/// What the page shows while there is a query: the matching settings, best first, each with where it is; a click (or Return
/// on the highlighted one) goes there.
struct SettingsSearchResults: View {
    @ObservedObject var search = SettingsSearch.shared
    let islandOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if search.results.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(String(format: L("No settings match “%@”"), search.query.trimmingCharacters(in: .whitespaces))).font(UI.title)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("Try another word, or fewer words")).font(UI.detail).foregroundStyle(UI.secondary)
                }
                .padding(Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(search.results.enumerated()), id: \.element.entry.id) { i, hit in
                    resultRow(hit, selected: i == search.selected)
                }
            }
        }
        .padding(Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CTL.cardRadius).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: CTL.cardRadius).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Search results"))
    }

    private func resultRow(_ hit: SearchHit, selected: Bool) -> some View {
        let e = hit.entry
        let needsIsland = e.tab == "island" && !islandOn
        var second = SettingsSearch.place(e)
        // Why it matched, when the title doesn't say it (a synonym, another language): never the very word typed.
        if let via = hit.via, via.count <= 40, SearchText.fold(via) != SearchText.fold(search.query.trimmingCharacters(in: .whitespaces)) { second += " · ≈ " + via }
        let hint = needsIsland ? String(format: L("Turn on “%@” first"), (NotchGeometry.current()?.hasNotch ?? true) ? L("Show in the notch") : L("Show at the top of the screen")) : nil
        return Button { search.open(hit) } label: {
            HStack(spacing: Space.m) {
                Image(systemName: e.icon).font(UI.icon).foregroundStyle(Island.accent).frame(width: UI.iconColumn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.row.map(L) ?? L(e.card)).font(UI.title).lineLimit(1)
                    Text(second).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1).truncationMode(.middle)
                    if let hint { Text(hint).font(UI.detail).foregroundStyle(warningColor).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: Space.s)
                Image(systemName: "arrow.turn.down.left").font(UI.chevron).foregroundStyle(UI.hint).opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.xs + 1)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: CTL.innerRadius).fill(Color.white.opacity(selected ? 0.10 : 0)))
            .contentShape(Rectangle())
            .animation(Motion.animation(.hover), value: selected)
        }
        .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScaleRow))
        .onHover { inside in if inside, let i = search.results.firstIndex(of: hit) { search.selected = i } }
        .accessibilityLabel(e.row.map(L) ?? L(e.card))
        .accessibilityValue(hint.map { second + ". " + $0 } ?? second)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(L("Opens this setting"))
    }
}
