// Going back to a session: from an agent row or an alert, bring forward the exact terminal tab (Terminal, iTerm2, tmux,
// WezTerm, Ghostty, kitty, cmux, Zellij) or IDE window (VS Code and its forks) it runs in, or what a jump rule of the user's
// opens; else its app; else its folder in Finder. Every outcome comes back with what was and wasn't possible, for the app
// to say it (never a silent failure). Warp, Alacritty, Hyper, Tabby: their app only (no safe way to pick a tab from outside).

import AppKit

enum AgentFocus {
    static let terminal = "com.apple.Terminal"
    static let iterm = "com.googlecode.iterm2"
    static let wezterm = "com.github.wez.wezterm"
    static let ghostty = "com.mitchellh.ghostty"
    static let kitty = "net.kovidgoyal.kitty"
    /// Opening a folder with these brings forward the window that has it open.
    static let vscodeFamily: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
                                            "com.exafunction.windsurf", "com.vscodium", "com.visualstudio.code.oss", "com.trae.app",
                                            "com.google.antigravity", "dev.kiro.desktop"]
    /// $TERM_PROGRAM → bundle id, for when the hook didn't get __CFBundleIdentifier (tmux, ssh, …).
    static let termPrograms = ["Apple_Terminal": terminal, "iTerm.app": iterm, "WezTerm": wezterm, "ghostty": ghostty,
                               "WarpTerminal": "dev.warp.Warp-Stable", "Hyper": "co.zeit.hyper", "Tabby": "org.tabby", "kitty": "net.kovidgoyal.kitty"]

    static func appID(_ o: AgentOrigin) -> String? { o.app ?? o.term.flatMap { termPrograms[$0] } ?? (o.kittyWindow != nil ? kitty : nil) }

    /// The user's jump rules (Application Support/Cocaine/jump-rules.json), read when the plan is made; tests set their own.
    static var rules: [JumpRules.Rule] { rulesOverride ?? JumpRules.load().rules }
    static var rulesOverride: [JumpRules.Rule]?

    /// Ghostty: its terminal with this id, else the one in this folder (ids and folders are checked before they get here).
    static func ghosttyScript(id: String?, cwd: String?) -> String? {
        var tests: [String] = []
        if let id, id.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil { tests.append("(id of s as text) is \"\(id)\"") }
        if let cwd, cwd.hasPrefix("/"), !cwd.contains("\""), !cwd.contains("\\"), cwd.count <= 1024,
           !cwd.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { tests.append("(working directory of s as text) is \"\(cwd)\"") }
        guard !tests.isEmpty else { return nil }
        // The id first, in its own pass: a folder can be open in several terminals.
        let passes = tests.map { test in """
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in terminals of t
                            if \(test) then
                                activate window w
                                select tab t
                                focus s
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
        """ }.joined(separator: "\n")
        return "tell application id \"\(ghostty)\"\n" + passes + "\nend tell\nreturn \"missing\""
    }

    /// The id of Ghostty's focused terminal, to remember for a session that starts there. Only when Cocaine is already allowed
    /// to control Ghostty (never a permission question that nobody asked for); nil otherwise.
    static func ghosttyFocusedTerminal() -> String? {
        guard running(ghostty) != nil, automation(ghostty, ask: false) == 0 else { return nil }
        var err: NSDictionary?
        let r = NSAppleScript(source: "tell application id \"\(ghostty)\" to return (id of focused terminal of selected tab of front window) as text")?
            .executeAndReturnError(&err)
        guard err == nil, let v = r?.stringValue, v.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        return v
    }

    enum Step: Equatable {
        case tmux(socket: String?, pane: String)          // select its window and pane, then the terminal its client runs in
        case terminalTab(tty: String)                     // Terminal: the tab on that tty
        case itermSession(tty: String?, uuid: String?)    // iTerm2: the session on that tty / with that id
        case weztermPane(String)
        case ghosttyTerminal(id: String?, cwd: String?)   // Ghostty ≥ 1.3: the terminal with that id (or that folder)
        case kittyWindow(listen: String, window: String)  // kitty's remote control: `kitten @ focus-window`
        case cmuxSurface(socket: String, workspace: String?, surface: String)
        case zellijPane(session: String, pane: String)
        case custom(url: String, app: String)             // a jump rule of the user's (JumpRules)
        case openFolder(app: String, path: String)        // VS Code family: the window with that folder
        case browserTab(browser: String, url: String)     // a web chat: its tab in that browser
        case deepLink(url: String, app: String)           // the app's documented link to that session (codex://threads/<id>)
        case activate(app: String)
        case revealFolder(String)
    }

    /// The ways to get there, best first. Pure: what is possible is decided by the executor.
    static func plan(_ o: AgentOrigin) -> [Step] {
        var steps: [Step] = []
        if let url = o.url, url.hasPrefix("https://"), let b = o.browser {          // a web chat
            return [.browserTab(browser: b, url: url), .activate(app: b)]
        }
        let app = appID(o)
        if let app, let url = rules.first(where: { $0.app == app }).flatMap({ $0.url(for: o) }) { steps.append(.custom(url: url, app: app)) }
        if let url = o.url, url.hasPrefix("codex://") { steps.append(.deepLink(url: url, app: AIEnvironments.codexApp)) }
        if let pane = o.tmuxPane { steps.append(.tmux(socket: o.tmuxSocket, pane: pane)) }
        if let s = o.zellijSession, let p = o.zellijPane, o.tmuxPane == nil { steps.append(.zellijPane(session: s, pane: p)) }
        if o.tmuxPane == nil && o.zellijPane == nil {                // inside a multiplexer the tty is its, not the terminal's
            if let surface = o.cmuxSurface { steps.append(.cmuxSurface(socket: o.cmuxSocket ?? "/tmp/cmux.sock", workspace: o.cmuxWorkspace, surface: surface)) }
            else if app == ghostty || o.term == "ghostty" { steps.append(.ghosttyTerminal(id: o.ghosttyTerminal, cwd: o.cwd)) }
            if app == terminal, let t = o.tty { steps.append(.terminalTab(tty: t)) }
            if app == iterm, o.tty != nil || o.termSession != nil { steps.append(.itermSession(tty: o.tty, uuid: o.termSession)) }
            if app == wezterm, let p = o.weztermPane { steps.append(.weztermPane(p)) }
            if let w = o.kittyWindow, let l = o.kittyListen { steps.append(.kittyWindow(listen: l, window: w)) }
        }
        if let app, vscodeFamily.contains(app), let cwd = o.cwd { steps.append(.openFolder(app: app, path: cwd)) }
        if let app { steps.append(.activate(app: app)) }
        if let cwd = o.cwd { steps.append(.revealFolder(cwd)) }
        return steps
    }

    /// AppleScript that selects the tab on `tty` (validated: /dev/ttysNNN only) and brings its window forward.
    static func terminalScript(tty: String) -> String? {
        guard tty.range(of: #"^ttys[0-9]{1,4}$"#, options: .regularExpression) != nil else { return nil }
        return """
        tell application id "\(terminal)"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    static func itermScript(tty: String?, uuid: String?) -> String? {
        var tests: [String] = []
        if let tty, tty.range(of: #"^ttys[0-9]{1,4}$"#, options: .regularExpression) != nil { tests.append("tty of s is \"/dev/\(tty)\"") }
        if let uuid, uuid.range(of: #"^[A-Za-z0-9-]{8,64}$"#, options: .regularExpression) != nil { tests.append("unique id of s is \"\(uuid)\"") }
        guard !tests.isEmpty else { return nil }
        return """
        tell application id "\(iterm)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if \(tests.joined(separator: " or ")) then
                            tell w to select
                            tell t to select
                            tell s to select
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    enum Level: Int, Comparable {
        case none, folder, app, window, exact
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    /// Why it didn't get further than `level`.
    /// noDeepLink: the app came forward, but it can't be told from outside which conversation to show.
    /// kittyRemoteOff: kitty came forward, but its remote control (allow_remote_control, listen_on) is off.
    enum Note: Equatable { case none, automationDenied, tabNotFound, appNotRunning, noInfo, noDeepLink, kittyRemoteOff }
    struct Result: Equatable { var level: Level; var appName: String?; var note: Note }

    // MARK: running it

    static func running(_ id: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first { !$0.isTerminated }
    }

    /// 0 allowed, -1743 refused, -1744 not asked, -600 not running. Asks (the system's own question) only when `ask`.
    static func automation(_ bundle: String, ask: Bool) -> OSStatus {
        guard let desc = NSAppleEventDescriptor(bundleIdentifier: bundle).aeDesc else { return -600 }
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    private static let queue = DispatchQueue(label: "local.cocaine.focus")   // Apple events can wait on the other app

    /// Runs the plan off the main thread (a user's click: asking for Automation is expected then); `done` on main.
    static func go(_ o: AgentOrigin, done: @escaping (Result) -> Void) {
        let steps = plan(o)
        queue.async {
            let r = execute(steps, appID: appID(o))
            DispatchQueue.main.async { done(r) }
        }
    }

    private static func runScript(_ source: String, app: String) -> (ok: Bool, denied: Bool) {
        let perm = automation(app, ask: true)
        if perm == -1743 || perm == -1744 { return (false, true) }
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if (err?[NSAppleScript.errorNumber] as? Int) == -1743 { return (false, true) }
        return (r?.stringValue == "ok", false)
    }

    /// A plain folder, safe to open: not an app, bundle or package (anything can send a `cwd`: opening
    /// /Applications/X.app or a downloaded .prefPane "as a folder" would launch or install it).
    static func isPlainFolder(_ path: String) -> Bool {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { return false }
        if NSWorkspace.shared.isFilePackage(atPath: real) { return false }
        let ext = (real as NSString).pathExtension.lowercased()
        return !["app", "bundle", "prefpane", "saver", "plugin", "kext", "pkg", "mpkg", "framework", "appex", "qlgenerator", "mdimporter", "workflow", "action"].contains(ext)
    }

    private static func onMain<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }

    private static func activate(_ id: String) -> Bool {
        guard let a = running(id) else { return false }
        return onMain { a.activate() }
    }

    static func zellijBinary() -> String? {
        ["/opt/homebrew/bin/zellij", "/usr/local/bin/zellij", "/opt/local/bin/zellij"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A Unix socket of this user's (kitty's and cmux's control sockets; /tmp is shared, so who owns it matters).
    static func ownSocket(_ path: String) -> Bool {
        var st = stat()
        return path.hasPrefix("/") && lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK && st.st_uid == getuid()
    }

    /// One newline-delimited JSON request to a control socket (cmux); true when the answer isn't an error. 2 s at most.
    static func rpc(_ path: String, _ body: [String: Any]) -> Bool {
        let fd = ApprovalServer.connect(path)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var d = try? JSONSerialization.data(withJSONObject: body) else { return false }
        d.append(0x0A)
        guard d.withUnsafeBytes({ ApprovalServer.writeAll(fd, $0) }) else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 2000) > 0 else { return false }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buf, buf.count)
        guard n > 0, let o = (try? JSONSerialization.jsonObject(with: Data(buf[0..<n]).split(separator: 0x0A).first ?? Data())) as? [String: Any] else { return false }
        return o["error"] == nil || o["error"] is NSNull
    }

    static func tmuxBinary() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func runTool(_ path: String, _ args: [String], timeout: Double = 3) -> (status: Int32, out: String) {
        let r = Proc.run(path, args, timeout: timeout, capture: true, limit: 256 * 1024)     // drained as it runs: no 64 KB pipe stall
        return r.timedOut ? (-1, "") : (r.status, r.text)
    }

    /// tmux: select the pane's window and the pane; returns the tty of a terminal attached to its session, if any.
    private static func tmux(socket: String?, pane: String) -> (ok: Bool, clientTTY: String?) {
        guard let bin = tmuxBinary() else { return (false, nil) }
        var base: [String] = []
        if let s = socket {
            var st = stat()
            guard lstat(s, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { return (false, nil) }
            base = ["-S", s]
        }
        guard runTool(bin, base + ["select-window", "-t", pane]).status == 0 else { return (false, nil) }
        runTool(bin, base + ["select-pane", "-t", pane])
        let session = runTool(bin, base + ["display-message", "-p", "-t", pane, "#{session_name}"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let clients = runTool(bin, base + ["list-clients", "-t", session, "-F", "#{client_tty}"]).out
        let tty = clients.split(separator: "\n").map { $0.replacingOccurrences(of: "/dev/", with: "") }
            .first { $0.range(of: #"^ttys[0-9]{1,4}$"#, options: .regularExpression) != nil }
        return (true, tty)
    }

    private static func appName(_ id: String?) -> String? {
        guard let id else { return nil }
        if let a = running(id), let n = a.localizedName { return n }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    static func execute(_ steps: [Step], appID: String?) -> Result {
        let name = appName(appID)
        guard !steps.isEmpty else { return Result(level: .none, appName: name, note: .noInfo) }
        var note = Note.none
        var tmuxDone = false
        let exactTried = steps.contains { if case .activate = $0 { return false }; if case .openFolder = $0 { return false }; if case .revealFolder = $0 { return false }; return true }
        func exact() -> Result { Result(level: .exact, appName: name, note: .none) }
        for step in steps {
            switch step {
            case .tmux(let socket, let pane):
                let r = tmux(socket: socket, pane: pane)
                guard r.ok else { note = .tabNotFound; continue }
                tmuxDone = true
                // The terminal that shows that tmux session: its exact tab if it is Terminal or iTerm2.
                if let tty = r.clientTTY, let app = appID {
                    if app == terminal, let s = terminalScript(tty: tty), running(app) != nil {
                        let x = runScript(s, app: app); if x.ok { return Result(level: .exact, appName: name, note: .none) }; if x.denied { note = .automationDenied }
                    }
                    if app == iterm, let s = itermScript(tty: tty, uuid: nil), running(app) != nil {
                        let x = runScript(s, app: app); if x.ok { return Result(level: .exact, appName: name, note: .none) }; if x.denied { note = .automationDenied }
                    }
                }
            case .terminalTab(let tty):
                guard running(terminal) != nil else { note = .appNotRunning; continue }
                guard let s = terminalScript(tty: tty) else { continue }
                let x = runScript(s, app: terminal)
                if x.ok { return Result(level: .exact, appName: name, note: .none) }
                note = x.denied ? .automationDenied : .tabNotFound
            case .itermSession(let tty, let uuid):
                guard running(iterm) != nil else { note = .appNotRunning; continue }
                guard let s = itermScript(tty: tty, uuid: uuid) else { continue }
                let x = runScript(s, app: iterm)
                if x.ok { return Result(level: .exact, appName: name, note: .none) }
                note = x.denied ? .automationDenied : .tabNotFound
            case .weztermPane(let pane):
                guard let a = running(wezterm), let url = a.bundleURL else { note = .appNotRunning; continue }
                let bin = url.appendingPathComponent("Contents/MacOS/wezterm").path
                if FileManager.default.isExecutableFile(atPath: bin), runTool(bin, ["cli", "activate-pane", "--pane-id", pane]).status == 0, activate(wezterm) {
                    return Result(level: .exact, appName: name, note: .none)
                }
                note = .tabNotFound
            case .ghosttyTerminal(let id, let cwd):
                guard running(ghostty) != nil else { note = .appNotRunning; continue }
                guard let s = ghosttyScript(id: id, cwd: cwd) else { continue }
                let x = runScript(s, app: ghostty)
                if x.ok { return exact() }
                note = x.denied ? .automationDenied : .tabNotFound
            case .kittyWindow(let listen, let window):
                guard let a = running(kitty), let url = a.bundleURL else { note = .appNotRunning; continue }
                let kitten = url.appendingPathComponent("Contents/MacOS/kitten").path
                let sock = String(listen.dropFirst("unix:".count))
                guard FileManager.default.isExecutableFile(atPath: kitten), ownSocket(sock) else { note = .kittyRemoteOff; continue }
                if runTool(kitten, ["@", "--to", listen, "focus-window", "--match", "id:" + window]).status == 0, activate(kitty) { return exact() }
                note = .kittyRemoteOff
            case .cmuxSurface(let socket, let workspace, let surface):
                guard ownSocket(socket) else { note = .tabNotFound; continue }
                if let w = workspace { _ = rpc(socket, ["id": "ws", "method": "workspace.select", "params": ["workspace_id": w]]) }
                if rpc(socket, ["id": "focus", "method": "surface.focus", "params": ["surface_id": surface]]) {
                    if let app = appID, activate(app) { return exact() }
                    return exact()
                }
                note = .tabNotFound
            case .zellijPane(let session, let pane):
                guard let bin = zellijBinary() else { note = .tabNotFound; continue }
                if runTool(bin, ["--session", session, "action", "focus-pane-id", pane]).status == 0 {
                    tmuxDone = true                                    // the pane is selected; the terminal comes forward below
                } else { note = .tabNotFound }
            case .custom(let url, let app):
                guard let link = URL(string: url), JumpRules.allowed(link, app: app) else { continue }
                let sem = DispatchSemaphore(value: 0)
                var ok = false
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.open(link, configuration: cfg) { a, err in ok = a != nil && err == nil; sem.signal() }
                _ = sem.wait(timeout: .now() + 5)
                if ok { return exact() }
            case .openFolder(let app, let path):
                guard let a = running(app), let appURL = a.bundleURL, isPlainFolder(path) else { if running(app) == nil { note = .appNotRunning }; continue }
                let sem = DispatchSemaphore(value: 0)
                var ok = false
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: appURL, configuration: cfg) { app, err in
                    ok = app != nil && err == nil; sem.signal()
                }
                _ = sem.wait(timeout: .now() + 5)
                if ok { return Result(level: tmuxDone ? .exact : .window, appName: name, note: note) }
            case .browserTab(let browser, let url):
                guard running(browser) != nil else { note = .appNotRunning; continue }
                guard let s = AIEnvironments.tabScript(browser: browser, url: url) else { continue }
                let x = runScript(s, app: browser)
                if x.ok { return Result(level: .exact, appName: name, note: .none) }
                note = x.denied ? .automationDenied : .tabNotFound
            case .deepLink(let url, let app):
                guard let link = URL(string: url), let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app),
                      NSWorkspace.shared.urlForApplication(toOpen: link)?.standardizedFileURL == appURL.standardizedFileURL else { continue }
                let sem = DispatchSemaphore(value: 0)
                var ok = false
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: cfg) { a, err in ok = a != nil && err == nil; sem.signal() }
                _ = sem.wait(timeout: .now() + 5)
                if ok { return Result(level: .exact, appName: name, note: .none) }
            case .activate(let app):
                if activate(app) {
                    let why: Note = note != .none ? note : (exactTried ? .tabNotFound : .noDeepLink)
                    return Result(level: tmuxDone ? .exact : .app, appName: name, note: tmuxDone ? .none : why)
                }
                note = .appNotRunning
            case .revealFolder(let path):
                guard isPlainFolder(path) else { continue }
                if onMain({ NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true)) }) {
                    return Result(level: .folder, appName: name, note: note == .none ? .appNotRunning : note)
                }
            }
        }
        return Result(level: tmuxDone ? .exact : .none, appName: name, note: note == .none ? .noInfo : note)
    }
}
