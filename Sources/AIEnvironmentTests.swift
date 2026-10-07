// Tests of the AI environments (part of --agents-test and --selftest through AgentTests.pure): the registry and its matrix,
// classifying hooks, processes and tab addresses, the detectors on generated fixtures (fake session files, process facts,
// browser answers), the board's one ingestion path (dedupe, precedence, liveness, app quit, sweeps), the focus plan's links,
// every hook installer in a temporary home, the strings and the docs' matrix.

import AppKit

enum AIEnvironmentTests {
    static func run(_ check: AgentTests.Check) {
        registry(check)
        detectors(check)
        ingest(check)
        hooks(check)
        strings(check)
    }

    // MARK: registry and classification

    static func registry(_ check: AgentTests.Check) {
        let all = AIEnvironments.all
        check("env: ids are unique", Set(all.map(\.id)).count == all.count)
        check("env: every matrix has six valid cells", all.allSatisfy { $0.matrix.count == 6 && $0.matrix.allSatisfy { "SPNU".contains($0) } })
        let hookIDs = Set(AIHooks.tools.map(\.id))
        check("env: every hook environment names a hook tool Cocaine installs", all.filter { $0.methods.contains(.hook) }.allSatisfy { $0.hookTool.map(hookIDs.contains) == true })
        check("env: every hook tool has an environment (first = its row in the card)", hookIDs.allSatisfy { id in all.contains { $0.hookTool == id } })
        check("env: web chats have hosts and can be gone back to (their tab)", all.filter { $0.kind == .web }.allSatisfy { !$0.hosts.isEmpty && $0.support(.goBack) == .supported })
        check("env: a web chat never claims to see processing, replies or requests",
              all.filter { $0.kind == .web }.allSatisfy { e in [AICap.working, .done, .needsYou].allSatisfy { e.support($0) == .none } })
        check("env: an app seen only as an app claims nothing beyond open/quit",
              all.filter { $0.methods == [.app] }.allSatisfy { e in [AICap.working, .done, .needsYou].allSatisfy { e.support($0) == .none } })

        typealias O = AgentOrigin
        check("env: Claude Code's hook in Claude Desktop is its Code tab, elsewhere the CLI",
              AIEnvironments.forHook(from: "Claude Code", origin: O(app: AIEnvironments.claudeDesktop)) == "claude-desktop-code"
              && AIEnvironments.forHook(from: "Claude Code", origin: O(app: AgentFocus.terminal)) == "claude-code"
              && AIEnvironments.forHook(from: "Claude Code", origin: nil) == "claude-code")
        check("env: Codex's hook from the ChatGPT app, an IDE or a terminal",
              AIEnvironments.forHook(from: "Codex", origin: O(app: AIEnvironments.codexApp)) == "codex-app"
              && AIEnvironments.forHook(from: "Codex", origin: O(app: "com.microsoft.VSCode")) == "codex-ide"
              && AIEnvironments.forHook(from: "Codex", origin: O(term: "Apple_Terminal")) == "codex-cli")
        check("env: Copilot in VS Code vs the CLI; an unknown name is 'other'",
              AIEnvironments.forHook(from: "GitHub Copilot", origin: O(app: "com.microsoft.VSCode")) == "copilot-vscode"
              && AIEnvironments.forHook(from: "GitHub Copilot", origin: nil) == "copilot-cli" && AIEnvironments.forHook(from: "My script", origin: nil) == "other")
        check("env: a CLI process by name; an app's embedded helper or another name isn't a session",
              AIEnvironments.forProcess(name: "codex", path: "/opt/homebrew/bin/codex") == "codex-cli"
              && AIEnvironments.forProcess(name: "codex", path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex") == nil
              && AIEnvironments.forProcess(name: "claude", path: "/Users/x/Library/Application Support/Claude/claude-code/2.1.289/claude") == nil
              && AIEnvironments.forProcess(name: "node", path: "/usr/local/bin/node") == nil)
        check("env: apps by bundle id, with prefixes", AIEnvironments.forBundle("com.jetbrains.intellij").map(\.id) == ["jetbrains"]
              && AIEnvironments.forBundle(AIEnvironments.claudeDesktop).map(\.id) == ["claude-desktop-code", "cowork", "claude-desktop"])

        // Tab addresses.
        check("web: chat addresses map to their site", AIEnvironments.forURL("https://chatgpt.com/c/6a4e-1") == "web-chatgpt"
              && AIEnvironments.forURL("https://claude.ai/chat/abc") == "web-claude" && AIEnvironments.forURL("https://github.com/copilot/c/12") == "web-copilot"
              && AIEnvironments.forURL("https://github.com/copilot") == "web-copilot")
        check("web: not http, not lookalike hosts, not other GitHub pages",
              AIEnvironments.forURL("http://chatgpt.com/c/1") == nil && AIEnvironments.forURL("https://chatgpt.com.evil.example/c/1") == nil
              && AIEnvironments.forURL("https://github.com/copilotx") == nil && AIEnvironments.forURL("https://github.com/features") == nil)
        check("web: an address that could break out of AppleScript is refused",
              AIEnvironments.safeChatURL("https://chatgpt.com/c/1\" & do shell script \"x") == nil && AIEnvironments.safeChatURL("https://chatgpt.com/c/1\\") == nil
              && AIEnvironments.safeChatURL("https://chatgpt.com/c/a b") == nil && AIEnvironments.safeChatURL("javascript:alert(1)") == nil)
        let uuid = "01a115e5-463f-7e80-a14b-3c6eb99b4da7"
        check("link: a Codex thread in the ChatGPT app opens by its documented link, only with a well-formed id",
              AIEnvironments.deepLink(env: "codex-app", session: uuid) == "codex://threads/" + uuid
              && AIEnvironments.deepLink(env: "codex-app", session: "x/../settings") == nil && AIEnvironments.deepLink(env: "codex-cli", session: uuid) == nil
              && AIEnvironments.safeChatURL("codex://settings") == nil)
        check("link: the ChatGPT app on this Mac registers codex:// (read-only LaunchServices lookup), when it is installed",
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: AIEnvironments.codexApp) == nil
              || NSWorkspace.shared.urlForApplication(toOpen: URL(string: "codex://threads/" + uuid)!) != nil)

        // The scan script and its answer.
        let script = AIEnvironments.scanScript(AIEnvironments.safari) ?? ""
        check("web: the scan asks only for chat-site addresses (the script filters, nothing else leaves the browser)",
              script.contains("u starts with \"https://chatgpt.com/\"") && script.contains("\"https://github.com/copilot\"") && !script.contains("name of t")
              && AIEnvironments.scanScript("com.example.browser") == nil)
        let parsed = AIEnvironments.parseScan("https://chatgpt.com/c/1\nhttps://example.com/x\nhttps://chatgpt.com/c/1\nhttps://claude.ai/chat/2\" & x\n  https://gemini.google.com/app/9  \n")
        check("web: a scan's answer keeps chat tabs once each, checked again", parsed.map(\.env) == ["web-chatgpt", "web-gemini"]
              && parsed.last?.url == "https://gemini.google.com/app/9")
        check("web: selecting a tab: Safari's and Chrome's own commands; nothing for an unknown browser or a non-chat address",
              AIEnvironments.tabScript(browser: AIEnvironments.safari, url: "https://claude.ai/chat/2")?.contains("set current tab of w to t") == true
              && AIEnvironments.tabScript(browser: "com.google.Chrome", url: "https://claude.ai/chat/2")?.contains("set active tab index of w to i") == true
              && AIEnvironments.tabScript(browser: "com.example", url: "https://claude.ai/chat/2") == nil
              && AIEnvironments.tabScript(browser: AIEnvironments.safari, url: "https://example.com/") == nil)

        // The focus plan with links.
        typealias S = AgentFocus.Step
        let web = AgentOrigin(url: "https://claude.ai/chat/2", browser: AIEnvironments.safari).sanitized()
        check("focus: a web chat → its tab, then the browser", AgentFocus.plan(web) == [S.browserTab(browser: AIEnvironments.safari, url: "https://claude.ai/chat/2"), .activate(app: AIEnvironments.safari)])
        let thread = AgentOrigin(app: AIEnvironments.codexApp, url: "codex://threads/" + uuid).sanitized()
        check("focus: a Codex thread → its link first, then the app", AgentFocus.plan(thread).first == .deepLink(url: "codex://threads/" + uuid, app: AIEnvironments.codexApp)
              && AgentFocus.plan(thread).contains(.activate(app: AIEnvironments.codexApp)))
        check("focus: an unsafe link or an unknown browser is dropped by the origin's cleaning",
              AgentOrigin(url: "https://evil.example/", browser: "com.evil").sanitized().url == nil
              && AgentOrigin(url: "https://claude.ai/x", browser: "com.evil").sanitized().browser == nil)

        // Card rows.
        let rows = AIEnvironments.cardRows(hookTools: [("claude", "Claude Code", true), ("codex", "Codex", true), ("gemini", "Gemini CLI", false)],
                                           installed: ["claude-desktop-code", "cowork", "claude-desktop", "codex-app", "zed"], running: ["cowork", "claude-desktop"])
        check("card: one row per installed hook tool with what it also covers; apps alike share a row; web chats last",
              rows.map(\.id) == ["hook-claude", "hook-codex", "app-cowork", "app-zed", "web"]
              && rows[0].also == ["Claude Desktop · Code"] && rows[1].also == ["ChatGPT · Codex"]
              && rows[2].title == "Claude Cowork / Claude Desktop (chat)" && rows[2].running && !rows[3].running)

        let md = AIEnvironments.markdownMatrix()
        check("docs: the matrix has a line per environment", md.split(separator: "\n").count == AIEnvironments.all.count + 2)
        for (file, italian) in [("docs/ai-integrations.en.md", false), ("docs/ai-integrations.it.md", true)]
        where FileManager.default.fileExists(atPath: file) {
            let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            check("docs: \(file) shows the code's matrix (--ai-environments matrix\(italian ? " --it" : ""))", text.contains(AIEnvironments.markdownMatrix(italian: italian)))
        }
    }

    // MARK: detectors on fixtures

    static func detectors(_ check: AgentTests.Check) {
        let dir = AgentTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ json: String) { try? Data(json.utf8).write(to: dir.appendingPathComponent(name)) }
        // Generated files in the shape seen on Claude Code 2.1.292 (the values are made up).
        write("4001.json", #"{"pid":4001,"sessionId":"aaaa-1","cwd":"/Users/x/proj","status":"busy","statusUpdatedAt":1,"kind":"interactive","entrypoint":"cli","procStart":"Wed Oct  7 08:51:59 2026","name":"SECRET TITLE","version":"2.1.292"}"#)
        write("4002.json", #"{"pid":4002,"sessionId":"bbbb-2","cwd":"/Users/x/other","status":"idle","entrypoint":"claude-desktop","procStart":"Wed Oct  7 08:51:07 2026"}"#)
        write("4003.json", #"{"pid":4003,"sessionId":"cccc-3","status":"busy","procStart":"Wed Oct  7 08:00:00 2026"}"#)
        write("4999.json", #"{"pid":4004,"sessionId":"dddd-4","status":"busy"}"#)            // name and pid disagree
        write("4005.json", #"{"pid":4005,"sessionId":"bad id; rm","status":"busy"}"#)
        write("notes.txt", "x")
        let start1 = ClaudeSessionFiles.parseStart("Wed Oct  7 08:51:59 2026")!
        let start2 = ClaudeSessionFiles.parseStart("Wed Oct 7 08:51:07 2026")!
        check("claude files: the process start is read as UTC", start1 == 1_791_363_119)
        let info: (pid_t) -> AgentProcess.Info? = { pid in
            switch pid {
            case 4001: return AgentProcess.Info(ppid: 1, start: start1 + 0.4, tty: "ttys001", uid: getuid(), name: "claude")
            case 4002: return AgentProcess.Info(ppid: 1, start: start2, tty: nil, uid: getuid(), name: "claude")
            case 4003: return AgentProcess.Info(ppid: 1, start: start1, tty: nil, uid: getuid(), name: "claude")   // pid reused
            default: return nil
            }
        }
        let sig = ClaudeSessionFiles.scan(dir, info: info, complete: { $0 }).sorted { ($0.session ?? "") < ($1.session ?? "") }
        check("claude files: one signal per valid file (a mismatched name or a bad id is skipped)", sig.map { $0.session ?? "" } == ["aaaa-1", "bbbb-2", "cccc-3"])
        check("claude files: busy → working, with the folder and the process", sig[0].state == .working && sig[0].project == "proj"
              && sig[0].origin?.pid == 4001 && sig[0].origin?.pidStart == start1 + 0.4 && sig[0].env == "claude-code" && sig[0].source == .stateFile)
        check("claude files: idle → open; the desktop app's entry point is its Code tab", sig[1].state == .open && sig[1].env == "claude-desktop-code")
        check("claude files: a file whose process is gone (or reused) says the session ended", sig[2].state == .ended)
        check("claude files: the conversation-derived name is never read", !String(describing: ClaudeSessionFiles.parse(Data(#"{"pid":5,"sessionId":"a","name":"SECRET"}"#.utf8))!).contains("SECRET"))
        check("claude files: statuses", ClaudeSessionFiles.state("busy") == .working && ClaudeSessionFiles.state("idle") == .open
              && ClaudeSessionFiles.state("waiting_for_permission") == .waiting && ClaudeSessionFiles.state("something-new") == .open && ClaudeSessionFiles.state(nil) == .open)

        typealias F = ProcessDetector.Fact
        let codex = F(pid: 900, name: "codex", path: "/opt/homebrew/bin/codex", parentName: "zsh", tty: "ttys004", start: 10, cwd: "/Users/x/api")
        let s = ProcessDetector.signal(codex)
        check("processes: Codex started from a shell on a terminal is an open session", s?.env == "codex-cli" && s?.state == .open
              && s?.origin?.tty == "ttys004" && s?.origin?.pid == 900 && s?.project == "api")
        var mcp = codex; mcp.parentName = "claude"
        var bg = codex; bg.tty = nil
        var app = codex; app.path = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"; app.parentName = "zsh"
        check("processes: not when another agent started it (an MCP server), without a terminal, or inside an app",
              ProcessDetector.signal(mcp) == nil && ProcessDetector.signal(bg) == nil && ProcessDetector.signal(app) == nil)

        // A browser's answer, without a browser.
        let tabs = BrowserTabs.scan(AIEnvironments.safari) { script, _ in
            script.contains("chatgpt.com") ? "https://chatgpt.com/c/1\nhttps://bank.example/\n" : nil
        }
        check("browser: tabs become open web-chat sessions with their address and browser",
              tabs?.count == 1 && tabs?.first?.env == "web-chatgpt" && tabs?.first?.origin?.url == "https://chatgpt.com/c/1" && tabs?.first?.origin?.browser == AIEnvironments.safari)
        check("browser: a browser that can't be asked gives nothing (not 'every tab closed')", BrowserTabs.scan(AIEnvironments.safari) { _, _ in nil } == nil)
    }

    // MARK: the one ingestion path

    static func ingest(_ check: AgentTests.Check) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let unknown: (AgentEntry) -> Bool? = { _ in nil }
        func board() -> AgentBoard { AgentBoard(file: AgentTests.tempDir().appendingPathComponent("state.json")) }
        func sig(_ env: String, _ source: AgentSignal.Source, _ state: AgentSignal.State, session: String? = nil, pid: Int32? = nil,
                 url: String? = nil, app: String? = nil) -> AgentSignal {
            AgentSignal(env: env, from: AIEnvironments.env(env)?.name ?? env, source: source, state: state, session: session, project: "p",
                        origin: AgentOrigin(app: app, pid: pid, pidStart: pid.map { _ in 100 }, url: url, browser: url.map { _ in AIEnvironments.safari }))
        }

        var b = board()
        b.ingest(sig("claude-code", .hook, .working, session: "S", pid: 77), now: now, alive: unknown)
        b.ingest(sig("claude-code", .stateFile, .working, session: "S", pid: 77), now: now.addingTimeInterval(5), alive: unknown)
        check("ingest: a session seen by its hook and its session file is one row", b.entries.count == 1 && b.entries[0].id == "S" && b.entries[0].src == AgentSignal.Source.hook.rawValue)
        b.ingest(sig("claude-code", .stateFile, .open, session: "S", pid: 77), now: now.addingTimeInterval(30), alive: unknown)
        check("ingest: the file's 'idle' doesn't override a fresh hook (its Stop is held until the session is quiet)", b.entries[0].state == "working")
        b.ingest(sig("claude-code", .stateFile, .open, session: "S", pid: 77), now: now.addingTimeInterval(700), alive: unknown)
        check("ingest: …but after 10 minutes of silence from the hook, idle after work means the reply is complete", b.entries[0].state == "done")
        b.ingest(sig("claude-code", .stateFile, .open, session: "S", pid: 77), now: now.addingTimeInterval(800), alive: unknown)
        check("ingest: 'open' never downgrades a finished row", b.entries[0].state == "done")

        b = board()
        b.ingest(sig("claude-code", .stateFile, .working, session: "A", pid: 50), now: now, alive: unknown)
        b.ingest(sig("claude-code", .stateFile, .open, session: "B", pid: 50), now: now.addingTimeInterval(10), alive: unknown)
        check("ingest: a new session in the same process (/clear) moves the row, no duplicate", b.entries.map(\.id) == ["B"] && b.entries[0].state == "done")
        b = board()
        b.ingest(sig("claude-code", .hook, .working, session: "H", pid: 51), now: now, alive: unknown)
        b.ingest(sig("claude-code", .stateFile, .working, session: "Z", pid: 51), now: now.addingTimeInterval(5), alive: unknown)
        b.ingest(sig("claude-code", .stateFile, .working, session: "Z", pid: 51), now: now.addingTimeInterval(10), alive: unknown)
        check("ingest: a less trusted source with another id joins the hook's row (no flapping, no second row)", b.entries.map(\.id) == ["H"])

        b = board()
        b.ingest(sig("codex-cli", .process, .open, pid: 900), now: now, alive: unknown)
        check("ingest: a CLI process without a hook is an open session", b.entries.map(\.id) == ["codex-cli|pid:900"] && b.entries[0].state == "idle")
        check("ingest: an open session doesn't keep the Mac awake", !b.anyLive(now, alive: unknown))
        b.ingest(sig("codex-cli", .hook, .working, session: "T", pid: 900), now: now.addingTimeInterval(5), alive: unknown)
        check("ingest: its hook later names the session: same row, now under its id", b.entries.map(\.id) == ["T"] && b.entries[0].state == "working")
        b.ingest(sig("codex-cli", .process, .open, pid: 900), now: now.addingTimeInterval(10), alive: unknown)
        check("ingest: the process seen again changes nothing", b.entries.count == 1 && b.entries[0].state == "working")
        b.ingest(sig("codex-cli", .process, .ended, pid: 900), now: now.addingTimeInterval(20), alive: unknown)
        check("ingest: the process gone ends a working session at once (no 2-hour 'working')", b.entries.isEmpty)
        b.ingest(sig("codex-cli", .hook, .done, session: "D", pid: 901), now: now, alive: unknown)
        b.ingest(sig("codex-cli", .hook, .ended, session: "D", pid: 901), now: now.addingTimeInterval(1), alive: unknown)
        check("ingest: …but a finished one stays to be seen, and fades as usual", b.entries.map(\.state) == ["done"])

        b = board()
        b.ingest(sig("codex-cli", .process, .open, pid: 1), now: now, alive: unknown)
        b.ingest(sig("codex-cli", .hook, .working, session: "keep", pid: 2), now: now, alive: unknown)
        b.sweep(source: .process, envs: ["codex-cli"], seen: [])
        check("ingest: a scan that no longer sees a process row ends it; a hook's row isn't the scan's", b.entries.map(\.id) == ["keep"])

        b = board()
        b.ingest(sig("codex-app", .hook, .working, session: "01a115e5-463f-7e80-a14b-3c6eb99b4da7", app: AIEnvironments.codexApp), now: now, alive: unknown)
        check("ingest: a ChatGPT-app thread carries its link back", b.entries[0].origin?.url == "codex://threads/01a115e5-463f-7e80-a14b-3c6eb99b4da7")
        b.ingest(sig("claude-code", .hook, .working, session: "term", pid: 3, app: AgentFocus.terminal), now: now, alive: unknown)
        let gone = b.appQuit(AIEnvironments.codexApp, alive: { $0.origin?.pid == 3 ? true : nil })
        check("ingest: quitting the app ends the threads that ran in it (they stayed 'working'), not others", gone.count == 1 && b.entries.map(\.id) == ["term"])

        b = board()
        let tab = "https://chatgpt.com/c/1"
        b.ingest(sig("web-chatgpt", .browser, .open, url: tab), now: now, alive: unknown)
        b.ingest(sig("web-chatgpt", .browser, .open, url: tab), now: now.addingTimeInterval(15), alive: unknown)
        check("ingest: the same tab twice is one row", b.entries.count == 1 && b.entries[0].origin?.url == tab)
        let snapshot = b.entries
        b.ingest(sig("web-chatgpt", .browser, .open, url: tab), now: now.addingTimeInterval(30), alive: unknown)
        check("ingest: seen again within a minute: the board doesn't change (no rewrite of state.json, no redraw)", b.entries == snapshot)
        b.sweep(source: .browser, envs: ["web-chatgpt"], seen: [])
        check("ingest: the tab closed: the row goes", b.entries.isEmpty)

        // Open (idle) rows and finished ones whose session is still open.
        b = board()
        b.ingest(sig("codex-cli", .hook, .done, session: "F", pid: 10), now: now, alive: unknown)
        b.prune(now.addingTimeInterval(1900), alive: { _ in true })
        check("prune: a finished session whose process still runs becomes 'open' instead of vanishing", b.entries.first?.state == "idle")
        b.prune(now.addingTimeInterval(4 * 3600), alive: { _ in true })
        check("prune: an open session stays while its process runs", b.entries.count == 1)
        b.prune(now.addingTimeInterval(4 * 3600), alive: { _ in false })
        check("prune: …and goes with it", b.entries.isEmpty)
        b.ingest(sig("web-claude", .browser, .open, url: "https://claude.ai/chat/1"), now: now, alive: unknown)
        b.prune(now.addingTimeInterval(1700), alive: unknown)
        let kept = b.entries.count
        b.prune(now.addingTimeInterval(1900), alive: unknown)
        check("prune: an open row nobody can check goes 30 minutes after it was last seen", kept == 1 && b.entries.isEmpty)

        // Restored rows and the saved file.
        b = board()
        b.ingest(sig("claude-code", .stateFile, .working, session: "R", pid: 60), now: now, alive: unknown)
        b.write(cocaineOn: true, until: nil, now: now)
        let r = AgentBoard(file: b.file)
        r.restore(now: now.addingTimeInterval(60), alive: unknown)
        check("restore: the new fields survive a restart", r.entries.first.map { $0.env == "claude-code" && $0.src == 4 && $0.origin?.pid == 60 } == true)
        r.ingest(sig("claude-code", .process, .open, pid: 60), now: now.addingTimeInterval(70), alive: unknown)
        check("restore: a restored row is taken up by the first detector that sees it", r.entries.first?.restored == nil)
    }

    // MARK: every hook installer, in a temporary home

    static func hooks(_ check: AgentTests.Check) {
        let savedHome = AIHooks.home, savedBinary = AIHooks.binary
        let home = AgentTests.tempDir()
        defer { AIHooks.home = savedHome; AIHooks.binary = savedBinary; try? FileManager.default.removeItem(at: home) }
        AIHooks.home = home.path
        AIHooks.binary = "/Applications/Cocaine.app/Contents/MacOS/Cocaine"
        AIHooks.assumeClaudeVersion([2, 1, 100])
        for t in AIHooks.tools {
            try? FileManager.default.createDirectory(atPath: t.folder, withIntermediateDirectories: true)
            if t.id == "gemini" { FileManager.default.createFile(atPath: t.folder + "/installation_id", contents: Data("x".utf8)) }
        }
        func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
        for t in AIHooks.tools {
            check("hooks \(t.id): installed in the temporary home", AIHooks.isInstalled(t) && t.folder.hasPrefix(home.path))
            let failed = AIHooks.set(true, only: [t])
            let once = text(t.file)
            check("hooks \(t.id): on", failed.isEmpty && AIHooks.isOn(t) && once.contains("cocaine:"))
            _ = AIHooks.set(true, only: [t])
            check("hooks \(t.id): on twice changes nothing", text(t.file) == once)
            _ = AIHooks.set(false, only: [t])
            let off = text(t.file)
            check("hooks \(t.id): off removes them", !AIHooks.isOn(t) && !off.contains(AIHooks.marker))
            _ = AIHooks.set(false, only: [t])
            check("hooks \(t.id): off twice changes nothing", text(t.file) == off)
        }
        _ = AIHooks.set(true, only: AIHooks.tools)
        let claude = text(home.path + "/.claude/settings.json")
        check("hooks: Claude Code reports a session's start (not on compact) and end",
              claude.contains("\"SessionStart\"") && claude.contains("startup|resume|clear") && claude.contains("event=open") && claude.contains("\"SessionEnd\"") && claude.contains("event=end"))
        check("hooks: Codex, Cursor and Gemini CLI report start and end too",
              text(home.path + "/.codex/hooks.json").contains("\"SessionEnd\"") && text(home.path + "/.cursor/hooks.json").contains("\"sessionEnd\"")
              && text(home.path + "/.gemini/settings.json").contains("\"SessionStart\""))
        let copilot = text(home.path + "/.copilot/hooks/cocaine.json")
        check("hooks: Copilot CLI: prompt, error, start and end", ["userPromptSubmitted", "errorOccurred", "sessionStart", "sessionEnd"].allSatisfy { copilot.contains("\"\($0)\"") })
        check("hooks: Windsurf: a prompt starts work", text(home.path + "/.codeium/windsurf/hooks.json").contains("\"pre_user_prompt\""))
        check("hooks: OpenCode: a session error alerts", text(home.path + "/.config/opencode/plugins/cocaine.js").contains("session.error"))
        _ = AIHooks.set(false, only: AIHooks.tools)
    }

    // MARK: strings

    static func strings(_ check: AgentTests.Check) {
        let keys = AICap.allCases.map(\.title) + [AISupport.supported, .partial, .none, .unverified].map(\.word)
        for lang in ["en", "it", "es", "fr", "de", "ja", "zh-Hans", "zh-Hant"] {
            let path = Bundle.main.path(forResource: "Agents", ofType: "strings", inDirectory: nil, forLocalization: lang)
                ?? Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang)
            let tables = ["Agents", "Localizable"].compactMap { Bundle.main.path(forResource: $0, ofType: "strings", inDirectory: nil, forLocalization: lang) }
                .compactMap { NSDictionary(contentsOfFile: $0) as? [String: String] }
            guard path != nil, !tables.isEmpty else { continue }      // a bare binary (no bundle): checked by --l10n-check instead
            let missing = keys.filter { k in !tables.contains { $0[k] != nil } }
            check("strings: the capability names and levels are translated (\(lang))\(missing.isEmpty ? "" : ": " + missing.joined(separator: ", "))", missing.isEmpty)
        }
    }
}
