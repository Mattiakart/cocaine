// --keyboard-test: the keyboard-only clipboard (Sources/ClipKeyboard.swift) and the exact way back to agent sessions in desktop
// apps and terminals added with it (Sources/AgentFocus.swift, Sources/AIEnvironments.swift). Pure logic, a history in memory
// with a fake pasteboard, temporary folders; no window is shown, no key is sent, no app is driven.

import AppKit
import Carbon.HIToolbox

enum KeyboardTests {
    static func run() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  keyboard: " + name); if !ok { failed += 1 } }
        searchTests(check)
        historyTests(check)
        keyTests(check)
        placeTests(check)
        settingsTests(check)
        focusTests(check)
        desktopTests(check)
        stringsTests(check)
        print(failed == 0 ? "keyboard: all passed" : "keyboard: \(failed) failed")
        return failed
    }

    static func text(_ s: String, used: Int = 0, title: String? = nil) -> ClipItem {
        var c = ClipItem.text(s)
        if used > 0 { c.used = ["com.apple.TextEdit": used] }
        c.title = title
        return c
    }

    // MARK: search modes and order

    static func searchTests(_ check: (String, Bool) -> Void) {
        let items = [text("git push origin main"), text("Hello World"), text("gpm notes"), text("order 4242 shipped")]
        func names(_ l: [ClipItem]) -> [String] { l.map(\.text) }
        check("words: every word, any case", names(ClipSearch.run(items, words: ["WORLD"], mode: .words, order: .recent)) == ["Hello World"])
        check("words: no match, nothing", ClipSearch.run(items, words: ["gpm", "origin"], mode: .words, order: .recent).isEmpty)
        check("fuzzy: letters in order with gaps find the item", names(ClipSearch.run(items, words: ["gpom"], mode: .fuzzy, order: .recent)).contains("git push origin main"))
        let ranked = names(ClipSearch.run(items, words: ["gpm"], mode: .fuzzy, order: .recent))
        check("fuzzy: letters next to each other rank first", ranked.first == "gpm notes" && ranked.contains("git push origin main"))
        check("fuzzy: letters out of order don't match", ClipSearch.fuzzyScore("mpg", in: "gpm") == nil)
        check("fuzzy: accents and case don't matter", ClipSearch.fuzzyScore("cafe", in: "Un CAFÉ") != nil)
        check("fuzzy: a word start beats the middle of a word", (ClipSearch.fuzzyScore("w", in: "Hello World") ?? 0) > (ClipSearch.fuzzyScore("o", in: "Hello World") ?? 0))
        check("regex: a pattern matches", names(ClipSearch.run(items, words: ["\\d{4}"], mode: .regex, order: .recent)) == ["order 4242 shipped"])
        check("regex: an invalid pattern finds nothing (and doesn't crash)", ClipSearch.run(items, words: ["(unclosed"], mode: .regex, order: .recent).isEmpty
              && !ClipSearch.validRegex("(unclosed") && ClipSearch.validRegex("a+"))
        check("regex: a pattern too long is refused", !ClipSearch.validRegex(String(repeating: "a", count: ClipSearch.patternLimit + 1)))
        check("mixed: whole words first", names(ClipSearch.run(items, words: ["hello"], mode: .mixed, order: .recent)) == ["Hello World"])
        check("mixed: then a regular expression", names(ClipSearch.run(items, words: ["^order"], mode: .mixed, order: .recent)) == ["order 4242 shipped"])
        check("mixed: then letters in order", names(ClipSearch.run(items, words: ["hwrld"], mode: .mixed, order: .recent)) == ["Hello World"])
        check("nothing typed: every item, in the order chosen", ClipSearch.run(items, words: [], mode: .fuzzy, order: .recent).count == items.count)
        let used = [text("a", used: 1), text("b", used: 5), text("c"), text("d", used: 5)]
        check("order: most pasted first, ties keep the history's order", names(ClipSearch.sorted(used, .pasted)) == ["b", "d", "a", "c"])
        let named = [text("beta"), text("Alpha"), text("zeta", title: "10 notes"), text("x", title: "9 notes")]
        check("order: A–Z by name, numbers as numbers", names(ClipSearch.sorted(named, .name)) == ["x", "zeta", "Alpha", "beta"])
        check("order: newest keeps the history's order", names(ClipSearch.sorted(used, .recent)) == ["a", "b", "c", "d"])
        let big = text(String(repeating: "x", count: 300_000) + "needle")
        check("regex: only the first 100,000 characters of a long text are searched", ClipSearch.run([big], words: ["needle"], mode: .regex, order: .recent).isEmpty)
    }

    /// The island's list goes through the search mode and the order of the settings, after the filters.
    static func historyTests(_ check: (String, Bool) -> Void) {
        let d = MemoryDefaults()
        var s = ClipSettings(); s.maxAgeHours = 0; s.save(d)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-keyboard-\(getpid())")
        defer { try? FileManager.default.removeItem(at: root) }
        let h = ClipboardHistory(defaults: d, dir: root, keys: MemoryKeyStore(), board: FakePasteboard())
        h.add(ClipItem.text("https://example.com/page", source: "com.apple.Safari"))
        h.add(ClipItem.text("git push origin main", source: "com.apple.Terminal"))
        h.add(ClipItem.text("meeting notes", source: "com.apple.Notes"))
        func listed(_ q: String) -> [String] { h.query = q; return h.listed(board: nil, kind: nil).map(\.text) }
        check("history: words by default", listed("push") == ["git push origin main"])
        var n = h.settings; n.searchMode = "fuzzy"; h.update(n)
        check("history: fuzzy from the settings", listed("gpom") == ["git push origin main"])
        check("history: a filter still applies before the words (type:link)", listed("type:link exmpl") == ["https://example.com/page"])
        n.searchMode = "regex"; h.update(n)
        check("history: regex from the settings", listed("^meet") == ["meeting notes"])
        n.searchMode = "words"; n.sortOrder = "name"; h.update(n)
        check("history: the order from the settings", listed("") == ["git push origin main", "https://example.com/page", "meeting notes"])
        h.query = ""
    }

    // MARK: keys

    static func keyTests(_ check: (String, Bool) -> Void) {
        func k(_ code: Int, _ f: NSEvent.ModifierFlags = [], char: String? = nil, editing: Bool = false) -> ClipKeyCommand? {
            ClipKeyCommand.interpret(UInt16(code), flags: f, char: char, editing: editing)
        }
        check("⌥Return: the other action; ⌥⇧Return the other formatting too", k(kVK_Return, .option) == .otherAction(shift: false)
              && k(kVK_Return, [.option, .shift]) == .otherAction(shift: true) && k(kVK_ANSI_KeypadEnter, .option) == .otherAction(shift: false))
        check("Return alone stays the page's own (paste)", k(kVK_Return) == nil && k(kVK_Return, .shift) == nil)
        check("⌥P: Favorites; ⌘P: Pin to…", k(kVK_ANSI_P, .option, char: "p") == .toggleFavorite && k(kVK_ANSI_P, .command, char: "p") == .pinMenu)
        check("P found by what it types on the layout (AZERTY/Dvorak keep ⌘P on their P)", k(kVK_ANSI_R, .command, char: "p") == .pinMenu && k(kVK_ANSI_P, .command, char: "l") == nil)
        check("⌥⌫ deletes even while typing; ⌘⌫ only when not", k(kVK_Delete, .option, editing: true) == .deleteItem
              && k(kVK_Delete, .command, editing: true) == nil && k(kVK_Delete, .command) == .deleteItem)
        check("⌥⌘⌫ clears the history (asked first)", k(kVK_Delete, [.option, .command]) == .clearHistory)
        check("Home/End and ⌘↑/⌘↓: first and last", k(kVK_Home) == .first && k(kVK_End) == .last && k(kVK_UpArrow, .command) == .first && k(kVK_DownArrow, .command) == .last)
        check("Page Up/Down move a page", k(kVK_PageUp) == .page(-ClipKeyCommand.pageSize) && k(kVK_PageDown) == .page(ClipKeyCommand.pageSize))
        check("⌘Y: details, also while typing", k(kVK_ANSI_Y, .command, char: "y", editing: true) == .details)
        check("plain letters and arrows are left to typing and the list", k(kVK_ANSI_P, char: "p") == nil && k(kVK_UpArrow) == nil && k(kVK_ANSI_A, .command, char: "a") == nil)
    }

    // MARK: where the floating clipboard opens

    static func placeTests(_ check: (String, Bool) -> Void) {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 875), right = CGRect(x: 1440, y: -200, width: 1920, height: 1055)
        let size = ClipPopupGeometry.size, m = ClipPopupGeometry.margin
        func inside(_ r: CGRect, _ s: CGRect) -> Bool { s.insetBy(dx: m - 0.5, dy: m - 0.5).contains(r) }
        let p = ClipPopupGeometry.frame(.pointer, pointer: CGPoint(x: 700, y: 600), screens: [main, right], last: nil)
        check("pointer: its top-left corner at the pointer", abs(p.minX - 680) < 1 && abs(p.maxY - 612) < 1 && p.size == size)
        let corner = ClipPopupGeometry.frame(.pointer, pointer: CGPoint(x: 1430, y: 20), screens: [main, right], last: nil)
        check("pointer: near a corner it stays wholly on that screen", inside(corner, main))
        let other = ClipPopupGeometry.frame(.pointer, pointer: CGPoint(x: 2000, y: 300), screens: [main, right], last: nil)
        check("pointer: on the screen the pointer is on", inside(other, right))
        let c = ClipPopupGeometry.frame(.center, pointer: CGPoint(x: 2000, y: 300), screens: [main, right], last: nil)
        check("centre: the middle of the pointer's screen (a little above)", abs(c.midX - right.midX) < 1 && c.midY > right.midY && inside(c, right))
        let top = ClipPopupGeometry.frame(.island, pointer: CGPoint(x: 10, y: 10), screens: [main], last: nil)
        check("no island to show it: under the top of the screen, centred", abs(top.midX - main.midX) < 1 && abs(top.maxY - (main.maxY - m)) < 1)
        let last = ClipPopupGeometry.frame(.last, pointer: .zero, screens: [main, right], last: CGPoint(x: 1600, y: 100))
        check("last place: where it was left", last.origin == CGPoint(x: 1600, y: 100))
        let gone = ClipPopupGeometry.frame(.last, pointer: CGPoint(x: 100, y: 100), screens: [main], last: CGPoint(x: 5000, y: 100))
        check("last place on a screen that's gone: the middle instead", inside(gone, main) && abs(gone.midX - main.midX) < 1)
        let tiny = ClipPopupGeometry.frame(.pointer, pointer: CGPoint(x: 10, y: 10), screens: [CGRect(x: 0, y: 0, width: 300, height: 300)], last: nil)
        check("a screen smaller than the panel: from its top-left corner", tiny.minX == 0 && tiny.maxY == 300)
    }

    // MARK: settings and the global shortcut

    static func settingsTests(_ check: (String, Bool) -> Void) {
        let d = ClipSettings()
        check("defaults: no global open shortcut until chosen (2.9: ⌃⌘V is Office's Paste Special), in the island, words, newest, ⌘ numbers shown",
              d.openShortcut == nil && ClipSettings.defaultOpen == Shortcut(keyCode: UInt32(kVK_ANSI_V), mods: Shortcut.ctrl | Shortcut.cmd)
              && d.openPlace == "island" && d.searchMode == "words" && d.sortOrder == "recent" && d.numberHints)
        check("defaults: nothing of the clipboard's is registered globally by default", ClipHotKeys.wanted(settings: d, stackActive: false, boards: [], items: []).isEmpty)
        var s = d; s.openShortcut = ClipSettings.defaultOpen                // the user chose ⌃⌘V
        check("⌃⌘V passes the global shortcuts' rules", ShortcutRules.problem(ClipSettings.defaultOpen, for: .island, others: [:], system: []) == nil)
        var n = s; n.openShortcut = nil; n.pasteNext = nil; n.openPlace = "pointer"; n.searchMode = "mixed"; n.sortOrder = "pasted"; n.numberHints = false
        let back = (try? JSONEncoder().encode(n)).flatMap { try? JSONDecoder().decode(ClipSettings.self, from: $0) }
        check("a shortcut taken away stays away after a relaunch (explicit null), the other choices too", back == n)
        let old = Data(#"{"persist":false,"maxItems":50}"#.utf8)
        let fromOld = try? JSONDecoder().decode(ClipSettings.self, from: old)
        check("settings of 2.7 (no keyboard keys) get the defaults", fromOld != nil && fromOld?.openShortcut == nil && fromOld?.openPlace == "island")
        let junk = Data(#"{"openPlace":"moon","searchMode":"psychic","sortOrder":"random"}"#.utf8)
        let fixed = try? JSONDecoder().decode(ClipSettings.self, from: junk)
        check("unknown choices fall back to the defaults", fixed?.openPlace == "island" && fixed?.searchMode == "words" && fixed?.sortOrder == "recent")
        let wanted = ClipHotKeys.wanted(settings: s, stackActive: false, boards: [], items: [])
        check("the open shortcut is registered with the clipboard's own hot keys", wanted.count == 1 && wanted[0].0 == .open)
        check("…and not when it is taken away", ClipHotKeys.wanted(settings: n, stackActive: false, boards: [], items: []).isEmpty)
        var same = s; same.pasteNext = s.openShortcut
        check("one combination does one thing (the open shortcut wins)", ClipHotKeys.wanted(settings: same, stackActive: true, boards: [], items: []).map(\.0) == [.open])
        check("a pinboard can't take the open shortcut", ClipHotKeys.problem(ClipSettings.defaultOpen, for: .board(UUID()), settings: s, boards: [], items: [],
                                                                             appShortcuts: [], system: []) != nil)
        let fake = ClipHotKeys(register: { _, _ in (noErr, nil) }, unregister: { _ in })
        fake.apply(wanted)
        check("registering it (fake Carbon) reports it fine", fake.status[.open] == noErr)
    }

    // MARK: exact sessions in terminals and editors

    static func focusTests(_ check: (String, Bool) -> Void) {
        typealias S = AgentFocus.Step
        AgentFocus.rulesOverride = []
        defer { AgentFocus.rulesOverride = nil }
        check("Zed: the window with the session's folder",
              AgentFocus.plan(AgentOrigin(app: AgentFocus.zed, cwd: "/p")) == [S.openFolder(app: AgentFocus.zed, path: "/p"), .activate(app: AgentFocus.zed), .revealFolder("/p")])
        check("Zed's terminal ($TERM_PROGRAM=zed) is Zed", AgentFocus.appID(AgentOrigin(term: "zed")) == AgentFocus.zed)
        check("JetBrains IDEs (any): the project window by its folder", AgentFocus.plan(AgentOrigin(app: "com.jetbrains.pycharm", cwd: "/p")).first == .openFolder(app: "com.jetbrains.pycharm", path: "/p")
              && AgentFocus.plan(AgentOrigin(app: "com.jetbrains.intellij.ce", cwd: "/p")).first == .openFolder(app: "com.jetbrains.intellij.ce", path: "/p"))
        check("Android Studio too", AgentFocus.opensFolderWindow("com.google.android.studio") && !AgentFocus.opensFolderWindow("com.apple.Terminal"))
        check("WezTerm without $WEZTERM_PANE: its pane by tty",
              AgentFocus.plan(AgentOrigin(app: AgentFocus.wezterm, tty: "ttys004")).first == .weztermTTY("ttys004"))
        check("WezTerm with $WEZTERM_PANE: the pane id, not the tty",
              AgentFocus.plan(AgentOrigin(app: AgentFocus.wezterm, tty: "ttys004", weztermPane: "7")).first == .weztermPane("7"))
        check("inside tmux the tty is tmux's: no WezTerm tty step", !AgentFocus.plan(AgentOrigin(app: AgentFocus.wezterm, tty: "ttys004", tmuxPane: "%2")).contains(.weztermTTY("ttys004")))
        let list = Data(#"[{"window_id":0,"tab_id":0,"pane_id":3,"tty_name":"/dev/ttys002"},{"window_id":1,"tab_id":2,"pane_id":12,"tty_name":"/dev/ttys004"}]"#.utf8)
        check("wezterm cli list: the pane on that tty", AgentFocus.weztermPane(tty: "ttys004", listJSON: list) == "12")
        check("wezterm cli list: none for another tty, a bad tty or bad JSON", AgentFocus.weztermPane(tty: "ttys009", listJSON: list) == nil
              && AgentFocus.weztermPane(tty: "../ttys004", listJSON: list) == nil && AgentFocus.weztermPane(tty: "ttys004", listJSON: Data("x".utf8)) == nil)
        check("Warp and Alacritty: their app only (no documented way to pick a tab)",
              AgentFocus.plan(AgentOrigin(app: "dev.warp.Warp-Stable", tty: "ttys001", cwd: "/p")) == [.activate(app: "dev.warp.Warp-Stable"), .revealFolder("/p")]
              && AgentFocus.plan(AgentOrigin(app: "org.alacritty", tty: "ttys001")) == [.activate(app: "org.alacritty")])
    }

    // MARK: Claude Desktop's Code sessions

    static func desktopTests(_ check: (String, Bool) -> Void) {
        let cli = "5f0c2a1e-1111-4222-8333-944455556666", local = "local_0a1b2c3d-aaaa-bbbb-cccc-0123456789ab"
        let json = Data(#"{"sessionId":"\#(local)","cliSessionId":"\#(cli)","cwd":"/p","title":"x"}"#.utf8)
        check("desktop file: its id when it is that session's", ClaudeDesktopSessions.localID(json: json, cliSession: cli) == local)
        check("desktop file: nothing for another session", ClaudeDesktopSessions.localID(json: json, cliSession: "00000000-0000-0000-0000-000000000000") == nil)
        let bad = Data(#"{"sessionId":"local_x\" & do shell script","cliSessionId":"\#(cli)"}"#.utf8)
        check("desktop file: an id that isn't local_<letters, digits, dashes> is refused", ClaudeDesktopSessions.localID(json: bad, cliSession: cli) == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-desktop-\(getpid())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("acct/org")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? json.write(to: dir.appendingPathComponent(local + ".json"))
        try? Data("{}".utf8).write(to: dir.appendingPathComponent("local_other.json"))
        try? Data("not json".utf8).write(to: dir.appendingPathComponent("local_broken.json"))
        check("desktop files: found two folders deep among others", ClaudeDesktopSessions.find(cli, in: root) == local)
        check("desktop files: none when the folder isn't there", ClaudeDesktopSessions.find(cli, in: root.appendingPathComponent("nope")) == nil)
        let saved = ClaudeDesktopSessions.lookup
        var asked = 0
        ClaudeDesktopSessions.lookup = { id in asked += 1; return id == cli ? local : nil }
        ClaudeDesktopSessions.forget()
        defer { ClaudeDesktopSessions.lookup = saved; ClaudeDesktopSessions.forget() }
        let link = AIEnvironments.deepLink(env: "claude-desktop-code", session: cli)
        check("link: Claude Desktop's own (its Dock menu's) for that session", link == "claude://code/continue?session=" + local)
        _ = AIEnvironments.deepLink(env: "claude-desktop-code", session: cli)
        _ = AIEnvironments.deepLink(env: "claude-desktop-code", session: "00000000-0000-0000-0000-000000000000")
        _ = AIEnvironments.deepLink(env: "claude-desktop-code", session: "00000000-0000-0000-0000-000000000000")
        check("link: found once, a miss isn't looked for again at once", asked == 2)
        check("link: none for Claude Code in a terminal, none for a session id with odd characters",
              AIEnvironments.deepLink(env: "claude-code", session: cli) == nil && AIEnvironments.deepLink(env: "claude-desktop-code", session: "../x") == nil)
        check("link: only that exact shape is accepted as a safe link", AIEnvironments.safeChatURL("claude://code/continue?session=" + local) != nil
              && AIEnvironments.safeChatURL("claude://code/continue?session=last") == nil && AIEnvironments.safeChatURL("claude://claude.ai/new?q=rm") == nil)
        AgentFocus.rulesOverride = []
        defer { AgentFocus.rulesOverride = nil }
        let o = AgentOrigin(app: AIEnvironments.claudeDesktop, cwd: "/p", url: "claude://code/continue?session=" + local).sanitized()
        check("focus: Claude Desktop's session link first, then the app", AgentFocus.plan(o).first == .deepLink(url: "claude://code/continue?session=" + local, app: AIEnvironments.claudeDesktop)
              && AgentFocus.plan(o).contains(.activate(app: AIEnvironments.claudeDesktop)))
        check("environments: Open Island's other agents are known by their process", ["kimi", "droid", "qodercli", "codebuddy"].allSatisfy { AIEnvironments.forProcess(name: $0, path: "/usr/local/bin/" + $0) != nil }
              && Set(AIEnvironments.all.map(\.id)).count == AIEnvironments.all.count)
        check("environments: an app's helper with the same name isn't a session", AIEnvironments.forProcess(name: "droid", path: "/Applications/Factory.app/Contents/MacOS/droid") == nil)
    }

    // MARK: strings

    static func stringsTests(_ check: (String, Bool) -> Void) {
        check("the Keyboard table is one of the app's tables", Language.extraTables.contains("Keyboard"))
        let keys = [L("Open the clipboard"), L("Near the pointer"), L("Fuzzy"), L("Most pasted")]
        check("its strings resolve (not the missing marker)", keys.allSatisfy { !$0.isEmpty && !$0.contains("\u{0}") })
    }
}

/// `--keyboard-test`, run from main.swift.
func cliKeyboardTest() -> Never { exit(KeyboardTests.run() == 0 ? 0 : 1) }
