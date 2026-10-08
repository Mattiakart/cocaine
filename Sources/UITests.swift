// --ui-test: the Settings panel's round-7 checks. The rows' layout (FitRow: no row drawn over the next), the settings search
// (index, concepts in every language, matching in 8 languages with typos and synonyms, ranking, the embeddings' graceful
// fallback, speed), every row and card the panel draws being findable, the keyboard-only focus ring, the panel's and the
// dialog layer's entrance and exit. Offscreen renders with memory-only settings (main.swift isolates the flag).

import AppKit
import SwiftUI

enum UITests {
    private static var failed = 0
    private static func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }

    static func run() -> Int32 {
        _ = NSApplication.shared
        precondition(AppDefaults.isolated, "--ui-test runs with memory-only settings (main.swift)")
        Motion.disabled = true
        fitRow()
        index()
        engine()
        coverage()
        keyboard()
        motion()
        return failed == 0 ? 0 : 1
    }

    // MARK: FitRow

    /// Lays a view out the way the panel does (a fixed width, its own height) and returns its height.
    private static func height<V: View>(_ v: V, width: CGFloat = 412) -> CGFloat {
        let host = NSHostingView(rootView: v.frame(width: width).fixedSize(horizontal: false, vertical: true))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private struct Measured: PreferenceKey {
        static let defaultValue: [String: CGFloat] = [:]
        static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { a, _ in a } }
    }

    private static func fitRow() {
        check("FitRow: side by side when title + gap + control fit", FitRow.sideBySide(title: 100, control: 200, gap: 10, width: 320))
        check("FitRow: stacked when they don't", !FitRow.sideBySide(title: 200, control: 200, gap: 10, width: 400))
        // The row the user saw drawn over the next one: a title with a detail line and three segments too wide to sit beside it.
        var sel = "battery"
        let binding = Binding(get: { sel }, set: { sel = $0 })
        let title = VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Alimentazione").font(UI.title)
            Text("Finché la batteria non scende al 20%").font(UI.detail).lineLimit(4).fixedSize(horizontal: false, vertical: true)
        }
        let seg = Segments(selection: binding, values: ["", "ac", "battery"], name: "Power") { $0 == "ac" ? "In carica" : $0 == "battery" ? "A batteria" : "Spento" }
        let titleH = height(title, width: 300), segH = height(seg, width: 300)
        var measured: [String: CGFloat] = [:]
        let stack = VStack(alignment: .leading, spacing: Space.s) {
            FitRow { title; seg }
                .background(GeometryReader { r in Color.clear.preference(key: Measured.self, value: ["row": r.size.height]) })
            Text("External display")
        }
        .onPreferenceChange(Measured.self) { measured = $0 }
        let host = NSHostingView(rootView: stack.frame(width: 300).fixedSize(horizontal: false, vertical: true))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let row = measured["row"] ?? 0
        let need = titleH + Space.s + segH
        check("FitRow: a row whose control goes under its title is as tall as both (\(String(format: "%.1f", row)) ≥ \(String(format: "%.1f", need)) pt)",
              row >= need - 0.5)
        let side = height(FitRow { Text("VPN"); Text("Off") })
        check("FitRow: a short row keeps the one-line height (\(side) pt)", abs(side - 22) < 0.5)

        // The panel itself, drawn by the render tool exactly as --render-panel draws it (a child process per picture, so each
        // starts clean): every tab in every language, in the state the user had (Power on battery with its detail line, both
        // rows true now) and with every optional row shown. Each row's control must lie inside its row and no row may start
        // before the one above it ends. On 2.8.0 the Power row reported 22 pt while its segments were drawn on a second line,
        // over External display: this check fails there (control 246–270 outside row 225–247 in Italian).
        let states: [[String]] = [
            ["--auto", "none", "--all-rows"],
            ["--auto", "ai", "--ai-on", "--all-rows"],
            ["--auto", "auto", "--trigger-power", "battery", "--trigger-display", "connected", "--live", "power,display"],
            ["--auto", "auto", "--all-rows", "--trigger-power", "ac", "--trigger-display", "disconnected", "--live", "power,display,apps"],
            ["--auto", "island", "--all-rows"],
        ]
        for lang in Language.codes {
            var problems: [String] = []
            var rows = 0
            for args in states {
                let f = renderedFrames(["--lang", lang, "--no-island"] + args)
                if f.isEmpty { problems.append("no frames for \(args)"); continue }
                for (k, c) in f where k.hasSuffix(SettingsSearch.controlSuffix) {
                    let rowKey = String(k.dropLast(SettingsSearch.controlSuffix.count))
                    guard let r = f[rowKey] else { problems.append("\(rowKey): no row frame"); continue }
                    rows += 1
                    if !r.insetBy(dx: -1, dy: -1).contains(c) { problems.append("\(rowKey): control \(Int(c.minY))–\(Int(c.maxY)) outside row \(Int(r.minY))–\(Int(r.maxY))") }
                }
                var byCard: [String: [CGRect]] = [:]
                for (k, r) in f where !k.hasSuffix("|") && !k.hasSuffix(SettingsSearch.controlSuffix) {
                    byCard[String(k.split(separator: "|", maxSplits: 1).first ?? ""), default: []].append(r)
                }
                for (card, rs) in byCard {
                    let sorted = rs.sorted { $0.minY < $1.minY }
                    for (a, b) in zip(sorted, sorted.dropFirst()) where b.minY < a.maxY - 0.5 {
                        problems.append("\(card): rows at \(Int(a.minY)) and \(Int(b.minY)) overlap")
                    }
                }
            }
            check("layout (\(lang)): \(rows) rows on every tab, each control inside its row, no row over another" + (problems.isEmpty ? "" : " — \(problems.sorted().prefix(6))"), problems.isEmpty && rows > 60)
        }
    }

    /// The anchors' frames of one --render-panel picture (its --dump-frames lines), by key.
    static func renderedFrames(_ args: [String]) -> [String: CGRect] {
        guard let exe = Bundle.main.executablePath else { return [:] }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cocaine-ui-test-\(getpid()).png")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--render-panel", out.path] + args + ["--dump-frames"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var f: [String: CGRect] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("frame ") {
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: false)
            guard parts.count == 6, let x = Double(parts[1]), let y = Double(parts[2]), let w = Double(parts[3]), let h = Double(parts[4]) else { continue }
            f[String(parts[5])] = CGRect(x: x, y: y, width: w, height: h)
        }
        return f
    }

    /// Optional rows on: the schedule, Stay active, a paired phone, a voice, quiet hours, Power on battery (its detail line).
    private static func fullState(_ m: PanelModel, _ page: String) {
        m.triggerSchedule = true; m.stayActive = true; m.phoneCount = 1; m.phone = "Shortcut"
        m.triggerApps = ["Xcode"]; m.triggerPower = "battery"; m.triggerDisplay = "connected"; m.liveTriggers = ["power", "display", "apps"]
        m.alertSpeak = true; m.dimEnabled = true; m.batteryThreshold = 20; m.battery = "80%"
        AgentPrefs.shared.quietHours = true
    }

    // MARK: The index and its concepts

    private static func strictText(_ key: String, _ lang: String) -> String? {
        guard let p = Bundle.main.path(forResource: lang, ofType: "lproj"), let b = Bundle(path: p) else { return nil }
        let miss = "\u{0}missing"
        for t in [nil] + Language.extraTables.map(Optional.some) {
            let v = b.localizedString(forKey: key, value: miss, table: t)
            if v != miss { return v }
        }
        return nil
    }

    private static func index() {
        let entries = SettingsIndex.entries
        check("index: \(entries.count) settings indexed", entries.count >= 150)
        check("index: no setting twice", Set(entries.map(\.id)).count == entries.count)
        var missing: [String] = []
        for e in entries {
            for k in [e.card, e.row, e.detail].compactMap({ $0 }) where k != "Cocaine" {
                for l in Language.codes where strictText(k, l) == nil { missing.append("\(l): \(k)") }
            }
        }
        check("index: every title, card and detail is a translated string key" + (missing.isEmpty ? "" : " — missing \(missing.prefix(8))"), missing.isEmpty)
        check("index: tabs are the panel's", Set(entries.map(\.tab)).isSubset(of: Set(PanelTabs.order)))
        var thin: [String] = []
        for c in SettingsIndex.concepts.sorted() {
            for l in Language.codes {
                guard let p = Bundle.main.path(forResource: l, ofType: "lproj"), let b = Bundle(path: p) else { thin.append("\(l) bundle"); continue }
                let words = b.localizedString(forKey: c, value: "", table: "SearchIndex").split(separator: ",")
                if words.count < 2 { thin.append("\(l): \(c)") }
            }
        }
        check("concepts: each of \(SettingsIndex.concepts.count) has words in all 8 languages" + (thin.isEmpty ? "" : " — \(thin.prefix(8))"), thin.isEmpty)
    }

    // MARK: Matching

    private static func engine() {
        check("fold: case, accents and widths", SearchText.fold("LuMiNoSiTà") == "luminosita" && SearchText.fold("Ｗｉ‑Ｆｉ").contains("wi"))
        check("words: punctuation separates, CJK runs stay whole", SearchText.words("wi-fi, 画面の明るさ") == ["wi", "fi", "画面の明るさ"])
        check("distance: a swap is one typo", SearchText.distance(Array("batetry"), Array("battery"), limit: 2) == 1)
        check("distance: stops past its limit", SearchText.distance(Array("abcdef"), Array("uvwxyz"), limit: 2) == 3)
        check("tokens: stopwords go, unless nothing else is left", SearchEngine.tokens("the battery of my Mac") == ["battery", "mac"] && SearchEngine.tokens("the") == ["the"])

        // What the user asked for, and more: (language of the app, query, the setting that must be among the first results).
        let cases: [(String, String, String, Int)] = [
            ("it", "luminosità", "When idle|", 3),
            ("it", "luminosita", "When idle|", 3),
            ("en", "dim screen", "When idle|", 3),
            ("en", "wifi", "Profiles|", 3),
            ("it", "wi-fi", "Profiles|", 3),
            ("it", "incollare", "Clipboard|Paste with Return and double-click", 5),
            ("it", "batteria", "Battery Guard|", 3),
            ("en", "agent", "Agents|", 5),
            ("en", "batery", "Battery Guard|", 3),
            ("en", "clipbaord", "Clipboard|", 3),
            ("en", "shortcts", "Keyboard shortcuts|", 3),
            ("en", "lang", "Cocaine|Language", 1),
            ("it", "lingua", "Cocaine|Language", 1),
            ("en", "upd", "Cocaine|Updates", 2),
            ("de", "Helligkeit", "When idle|", 3),
            ("de", "zwischenablage", "Clipboard|", 3),
            ("ja", "明るさ", "When idle|", 3),
            ("ja", "クリップボード", "Clipboard|", 3),
            ("zh-Hans", "剪贴板", "Clipboard|", 3),
            ("zh-Hant", "剪貼板", "Clipboard|", 3),
            ("es", "portapapeles", "Clipboard|", 3),
            ("fr", "presse-papiers", "Clipboard|", 3),
            ("fr", "raccourci clavier", "Keyboard shortcuts|", 3),
            ("en", "charger", "Smart Triggers|Power", 5),
            ("it", "caricatore", "Smart Triggers|Power", 5),
            ("en", "external monitor", "Smart Triggers|External display", 2),
            ("it", "monitor esterno", "Smart Triggers|External display", 1),
            ("en", "start at login", "Cocaine|Open at login", 2),
            ("it", "avvio automatico", "Cocaine|Open at login", 3),
            ("en", "password", "Clipboard|Excluded apps", 6),
            ("en", "teams", "Stay active|", 3),
            ("en", "notification sound", "How|Sound", 4),
            ("it", "vibrazione", "Cocaine|Haptic feedback", 2),
            ("en", "camera size", "Notch|Size", 3),
            ("it", "fotocamera", "Notch|Size", 3),
            ("en", "screen sharing", "Clipboard|Hide from screen sharing", 2),
            ("en", "Power", "Smart Triggers|Power", 1),
            ("it", "Alimentazione", "Smart Triggers|Power", 1),
            ("en", "battery smart triggers", "Smart Triggers|Power", 3),     // three words: one may miss
            ("it", "apunti", "Clipboard|", 3),                                 // the examples of docs/settings-search.it.md
            ("it", "bateria", "Battery Guard|", 3),
            ("it", "lingu", "Cocaine|Language", 1),
            ("it", "agg", "Cocaine|Updates", 2),
        ]
        var engines: [String: SearchEngine] = [:]
        for (lang, q, want, top) in cases {
            Language.set(lang, persist: false)
            let e = engines[lang] ?? SettingsSearch.testEngine(lang: lang, semantic: false)
            engines[lang] = e
            let hits = e.search(q)
            let rank = hits.firstIndex { want.hasSuffix("|") ? $0.entry.id.hasPrefix(want) : $0.entry.id == want }   // "Card|": the card or one of its rows
            check("search (\(lang)) “\(q)” → \(want) in the first \(top) (rank \(rank.map { String($0 + 1) } ?? "none"); first: \(hits.first?.entry.id ?? "-"))",
                  rank.map { $0 < top } ?? false)
        }
        Language.set("en", persist: false)
        let en = engines["en"] ?? SettingsSearch.testEngine(lang: "en", semantic: false)
        check("search: nonsense finds nothing", en.search("zqxjvw").isEmpty)
        check("search: an empty query finds nothing", en.search("   ").isEmpty)
        let lim = en.search("a")
        check("search: one letter is a prefix search, capped at 30 results", lim.count <= 30)
        let t0 = Date()
        for q in ["luminosità", "wifi", "clipbaord", "screen sharing", "明るさ", "start at login", "notification sound", "x"] { for _ in 0..<12 { _ = en.search(q) } }
        let ms = Date().timeIntervalSince(t0) * 1000 / 96
        check("search: fast enough to run on every key (\(String(format: "%.1f", ms)) ms a query)", ms < 25)

        // The related-words layer: stubbed (deterministic), then the real one degrading gracefully.
        var stub = SettingsSearch.testEngine(lang: "en", semantic: false)
        stub.related = { $0 == "luminance" ? ["brightness"] : [] }
        check("related words: a word the table doesn't know reaches a setting through a related one",
              stub.search("luminance").prefix(5).contains { $0.entry.id.hasPrefix("When idle|") })
        check("related words: …at a lower score than a direct match",
              (stub.search("luminance").first?.score ?? 9) < (stub.search("brightness").first?.score ?? 0))
        let available = SearchSemantics.available.count
        print("info  on-device word embeddings available here: \(available) of 5 languages")
        let r = SearchSemantics.related("qqqzzzxx")
        check("embeddings: an unknown word gives nothing and doesn't fail", r.isEmpty)
        SearchSemantics.enabled = false
        check("embeddings: off, related() is empty", SearchSemantics.related("brightness").isEmpty)
        SearchSemantics.enabled = true
        let sem = SettingsSearch.testEngine(lang: "en", semantic: true)
        check("embeddings on: the direct results are the same", sem.search("battery").first?.entry.id == en.search("battery").first?.entry.id)

        // The state object: results follow the query, ↑↓ stay in range, the place line.
        let s = SettingsSearch.shared
        s.tabs = PanelTabs.list(ai: true, island: false)
        s.query = "clipboard"
        check("state: results for a query (island off: its settings still listed)", s.results.contains { $0.entry.tab == "island" })
        s.query = ""
        check("state: no query, no results", s.results.isEmpty)
        check("place: tab › card", SettingsSearch.place(SettingsEntry(tab: "auto", card: "Smart Triggers", row: "Power")) == L("Automation") + " › " + L("Smart Triggers"))
    }

    // MARK: Every row is findable

    private static func panelModel(lang: String, page: String, island: Bool = true) -> PanelModel {
        Language.set(lang, persist: false)
        let m = PanelModel()
        m.persistLanguage = false
        m.language = lang
        m.ai = AIHooks.Status(tools: AIHooks.tools.enumerated().map { i, t in AIHooks.Entry(id: t.id, name: t.name, installed: i < 3, on: i < 2) }, codexNeedsTrust: false)
        m.history = []
        m.island = island
        m.page = page
        return m
    }

    /// The panel drawn offscreen the way the app hosts it (an NSHostingView sized by its intrinsic size, in a window resized to
    /// it once its content has settled, as fitPanel does); the anchors it reported (row and card frames by "card|row").
    private static func frames(_ m: PanelModel) -> [String: CGRect] {
        SettingsSearch.shared.frames = [:]
        let host = NSHostingView(rootView: AnyView(PanelView(m: m).overlay(alignment: .top) { PanelDialogOverlay(m: m) }.background(Color.black)))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        w.setContentSize(host.fittingSize)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }   // drawn: its last layout pass
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let f = SettingsSearch.shared.frames
        w.contentView = nil                                   // this panel stops reporting before the next one is drawn
        w.close()
        return f
    }

    private static func coverage() {
        AwakeModel.shared.fillSample(rows: true)
        for lang in ["en", "it", "de", "ja"] {
            var unindexed: [String] = []
            var cards = 0
            for page in PanelTabs.order {
                let m = panelModel(lang: lang, page: page)
                fullState(m, page)
                let f = frames(m).filter { !$0.key.hasSuffix(SettingsSearch.controlSuffix) }
                let known = Set(SettingsIndex.entries.filter { $0.tab == page }.map { L($0.card) + "|" + ($0.row.map(L) ?? "") })
                for k in f.keys where !known.contains(k) && !SettingsIndex.notIndexed.contains(where: { k.hasSuffix("|" + L($0)) }) { unindexed.append(k) }
                cards += f.keys.filter { $0.hasSuffix("|") }.count
            }
            check("coverage (\(lang)): every row and card the panel draws is in the search index (\(cards) cards)" + (unindexed.isEmpty ? "" : " — not indexed: \(unindexed.sorted().prefix(10))"), unindexed.isEmpty)
        }
        Language.set(nil, persist: false)
    }

    // MARK: Keyboard focus

    private static func keyboard() {
        let k = KeyboardNav()
        check("focus ring: hidden when the panel opens", !k.active)
        k.note(.key)
        check("focus ring: typing doesn't show it", !k.active)
        k.note(.tab)
        check("focus ring: Tab shows it", k.active)
        k.note(.key)
        check("focus ring: …it stays while moving with keys", k.active)
        k.note(.pointer)
        check("focus ring: a click hides it", !k.active)
        k.note(.tab); k.reset()
        check("focus ring: the panel opening again hides it", !k.active)
    }

    // MARK: Motion of the panel and its dialog layer

    private static func motion() {
        let f = NSRect(x: 500, y: 300, width: 440, height: 600)
        let drop = MenuPanel.entrance(to: f, fromNotch: true, reduce: false, disabled: false)
        check("panel from the notch: starts as the notch strip, top edge fixed, opaque", drop.start.maxY == f.maxY && drop.start.height == MenuPanel.dropStart && drop.startAlpha == 1 && drop.duration > 0.2)
        let menu = MenuPanel.entrance(to: f, fromNotch: false, reduce: false, disabled: false)
        check("panel under the icon: slides down a few points as it fades in", menu.start.minY > f.minY && menu.start.height == f.height && menu.startAlpha == 0 && menu.duration > 0)
        let reduced = MenuPanel.entrance(to: f, fromNotch: true, reduce: true, disabled: false)
        check("panel with Reduce Motion: a short fade in place", reduced.start == f && reduced.startAlpha == 0 && reduced.duration <= Motion.Duration.quick)
        check("panel in tests (motion off): at once", MenuPanel.entrance(to: f, fromNotch: true, reduce: false, disabled: true).duration == 0)
        let out = MenuPanel.exit(from: f, toNotch: true, reduce: false, disabled: false)
        check("panel closing into the notch: back up and out, quicker than it came", out.start.maxY == f.maxY && out.startAlpha == 0 && out.duration < drop.duration)
        check("panel closing with Reduce Motion: a fade", MenuPanel.exit(from: f, toNotch: true, reduce: true, disabled: false).start == f)
        check("dialog layer: stays until the card's exit has run", MenuPanel.overlayHideDelay(reduce: false, disabled: false) >= 0.3
              && MenuPanel.overlayHideDelay(reduce: true, disabled: false) > 0 && MenuPanel.overlayHideDelay(reduce: false, disabled: true) == 0)
    }
}

/// `--ui-test`, run from main.swift.
func cliUITest() { exit(UITests.run()) }
