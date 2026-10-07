// --ssh-test: SSH hosts without any real remote machine. The pure parts with fixtures (host names, ~/.ssh/config, the wire,
// the state machine, ssh's messages, the remote installer's plans, the board, the jump's process tables), then the whole path
// end to end: a fake `ssh` (a shell script that ignores ssh's options and runs the remote command here, with HOME set to a
// temporary folder) and the real relay (relay/cocaine-relay from the app bundle, run by the Mac's perl) — deployment, the
// handshake, hooks' news and requests with their answers, the remote hooks' review/apply/rollback/removal, drops and
// reconnection, wrong keys and changed host keys, the backlog, uninstalling. Nothing of the user's is read or written: the
// keys are in memory, every folder is temporary, no network is used.

import AppKit

func cliSSHTest() { exit(SSHTests.run() == 0 ? 0 : 1) }

enum SSHTests {
    typealias Check = (String, Bool) -> Void

    static func run() -> Int {
        signal(SIGPIPE, SIG_IGN)
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  ssh: " + name); if !ok { failed += 1 } }
        aliasTests(check)
        configTests(check)
        wireTests(check)
        machineTests(check)
        classifyTests(check)
        eventTests(check)
        boardTests(check)
        installerTests(check)
        jumpTests(check)
        endToEnd(check)
        print(failed == 0 ? "ssh: all passed" : "ssh: \(failed) failed")
        return failed
    }

    // MARK: Host names

    static func aliasTests(_ check: Check) {
        let good = ["devbox", "user@host.example.com", "host:2222", "user@10.0.0.1:22", "fe80::1", "my_host-2.lan"]
        check("aliases: plain names, user@host and host:port are accepted", good.allSatisfy(SSHAlias.valid) && good.allSatisfy { SSHAlias.destination($0) != nil })
        let hostile = ["-oProxyCommand=touch /tmp/x", "host;rm -rf ~", "a b", "$(id)", "`id`", "host\nx", "", "@host", "user@", "a@b@c",
                       "host'", "host\"", "h/../x", "ho\u{202E}st", "hóst", String(repeating: "a", count: 256), "-p", "x|y", "x&y", "~root"]
        check("aliases: options, shell syntax, quotes, spaces, control and odd characters are refused", hostile.allSatisfy { !SSHAlias.valid($0) && SSHAlias.destination($0) == nil })
        check("aliases: a bad port is refused (0, 70000, 22x, 022)", ["h:0", "h:70000", "h:22x", "h:022", "h:"].allSatisfy { SSHAlias.destination($0) == nil })
        check("aliases: user@host:2222 → destination and port apart", SSHAlias.destination("user@host:2222")! == ("user@host", "2222"))
        check("aliases: an IPv6 address is given as it is", SSHAlias.destination("fe80::1")! == ("fe80::1", nil))

        let a = SSHCommand.arguments(alias: "user@host:2222", remote: SSHCommand.serve)!
        let i = a.firstIndex(of: "--")!
        check("ssh: the host comes after --, alone, then the remote command; the port is its own argument",
              a[i + 1] == "user@host" && a[i + 2] == SSHCommand.serve && a.count == i + 3 && a[a.firstIndex(of: "-p")! + 1] == "2222")
        let opts = Set(a)
        check("ssh: BatchMode, host keys checked, no agent/X11/port forwarding, no local or remote command from the config",
              ["BatchMode=yes", "StrictHostKeyChecking=yes", "ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes",
               "PermitLocalCommand=no", "RemoteCommand=none", "ControlMaster=no", "ServerAliveInterval=15", "-T", "-a", "-x"].allSatisfy(opts.contains))
        check("ssh: never StrictHostKeyChecking=no or accept-new", !a.contains { $0.lowercased().contains("stricthostkeychecking=no") || $0.lowercased().contains("accept-new") })
        let c = SSHCommand.arguments(alias: "devbox", remote: SSHCommand.serve, control: "/Users/x/Library/Application Support/Cocaine/ssh/c-abc123")!
        check("ssh: a master connection opened in Terminal is used through -S, a separate argument", c[c.firstIndex(of: "-S")! + 1].hasSuffix("c-abc123"))
        check("ssh: a hostile name gives no command at all", SSHCommand.arguments(alias: "-oProxyCommand=x", remote: SSHCommand.serve) == nil)
        check("ssh: the remote commands are constants without single quotes inside or backslashes",
              [SSHCommand.serve, SSHCommand.deploy].allSatisfy { $0.hasPrefix("sh -c '") && $0.hasSuffix("'") && $0.dropFirst(7).dropLast().allSatisfy { $0 != "'" && $0 != "\\" && $0 != "!" } })
        let script = SSHCommand.terminalScript(alias: "u@h:2200", control: "/tmp/c-x")!
        check("terminal login: ssh -M with the control path, the port and the host quoted", script.contains("exec /usr/bin/ssh -M -S '/tmp/c-x' -o ControlPersist=8h -p 2200 -- 'u@h'"))
        check("terminal login: refused for a control path with a quote", SSHCommand.terminalScript(alias: "h", control: "/tmp/it's") == nil)
    }

    // MARK: ~/.ssh/config and known_hosts

    static func configTests(_ check: Check) {
        let files: [String: String] = [
            "/h/.ssh/config": """
            # mine
            Host devbox gpu-box  *.corp !bad
              HostName 10.0.0.2
            Host=build
            Host "quoted"
            Include conf.d/*
            Include ~/.ssh/extra
            Match host foo exec "true"
              User x
            Host dup devbox
            Host -oProxyCommand=x a;b
            """,
            "/h/.ssh/conf.d/a": "Host work-a\nInclude /h/.ssh/config\n",
            "/h/.ssh/conf.d/b": "Host  work-b   # comment\n  Host ignored?x\n",
            "/h/.ssh/extra": "HOST Extra1\n",
        ]
        let glob: (String) -> [String] = { p in
            if p == "/h/.ssh/conf.d/*" { return ["/h/.ssh/conf.d/b", "/h/.ssh/conf.d/a"] }
            return files[p] != nil ? [p] : []
        }
        var visited: Set<String> = ["/h/.ssh/config"]
        let names = SSHConfigScan.hosts(config: files["/h/.ssh/config"]!, sshDir: "/h/.ssh", home: "/h", read: { files[$0] }, glob: glob, visited: &visited)
        check("config: Host names in order, several per line, Include (globs, ~), Host=, quotes; no wildcards, negations, Match, junk or loops",
              names == ["devbox", "gpu-box", "build", "quoted", "work-a", "work-b", "Extra1", "dup"])
        let known = """
        github.com,140.82.121.4 ssh-ed25519 AAAA
        |1|abc=|def= ssh-ed25519 AAAA
        [git.example.com]:2222 ssh-rsa AAAA
        [plain.example.com]:22 ssh-rsa AAAA
        @cert-authority *.example.com ssh-rsa AAAA
        *.wild ssh-rsa AAAA
        # comment
        bad;name ssh-rsa AAAA
        """
        check("known_hosts: plain names and [host]:port only (hashed, markers, patterns and junk skipped)",
              SSHConfigScan.knownHosts(known) == ["github.com", "140.82.121.4", "git.example.com:2222", "plain.example.com"])
        check("config: tokens of Keyword=value and quoted arguments", SSHConfigScan.tokens("  Host = \"a b\" c # x") == ["Host", "a b", "c"])
    }

    // MARK: The wire

    static func wireTests(_ check: Check) {
        let key = Data(repeating: 7, count: 32), other = Data(repeating: 8, count: 32), ch = String(repeating: "a", count: 32)
        func frame(_ seq: Int, _ type: String, _ rest: String, key k: Data = key) -> Data {
            let mac = SSHWire.hmac(k, "cocaine-ssh-frame-v1\n\(ch)\n\(seq)\n\(type)\n\(rest)")
            return Data("@@CR1 \(mac) \(seq) \(type) \(rest)".utf8)
        }
        if case .success(let f) = SSHWire.frame(frame(0, "pong", #"{"n":1}"#), key: key, challenge: ch, lastSeq: -1) {
            check("wire: a signed frame is read", f.type == "pong" && f.json?["n"] as? Int == 1)
        } else { check("wire: a signed frame is read", false) }
        check("wire: another key's frame is refused", SSHWire.frame(frame(0, "pong", "{}", key: other), key: key, challenge: ch, lastSeq: -1) == .failure(.badSignature))
        check("wire: an older or repeated sequence number is refused (replay)", SSHWire.frame(frame(3, "pong", "{}"), key: key, challenge: ch, lastSeq: 3) == .failure(.replay))
        check("wire: a frame signed for another connection's challenge is refused",
              SSHWire.frame(frame(0, "pong", "{}"), key: key, challenge: String(repeating: "b", count: 32), lastSeq: -1) == .failure(.badSignature))
        check("wire: a login banner is noise, not an error", SSHWire.frame(Data("Welcome to Ubuntu".utf8), key: key, challenge: ch, lastSeq: -1) == .failure(.noise))
        check("wire: an over-long line is refused", SSHWire.frame(Data(count: SSHWire.maxLine + 1), key: key, challenge: ch, lastSeq: -1) == .failure(.tooLong))
        var tampered = frame(0, "pong", #"{"n":1}"#); tampered[tampered.count - 2] = UInt8(ascii: "2")
        check("wire: a changed byte breaks the signature", SSHWire.frame(tampered, key: key, challenge: ch, lastSeq: -1) == .failure(.badSignature))

        let cmd = String(decoding: SSHWire.command("ping", ["n": 1], key: key, challenge: ch, seq: 4)!, as: UTF8.self)
        let parts = cmd.dropLast().split(separator: " ", maxSplits: 3).map(String.init)
        check("wire: a command is `<mac> <seq> <type> <json>`, signed over the challenge and its sequence",
              parts.count == 4 && parts[1] == "4" && parts[2] == "ping" && parts[0] == SSHWire.hmac(key, "cocaine-ssh-cmd-v1\n\(ch)\n4\nping\n\(parts[3])"))
        check("wire: a command type that isn't a plain word is refused", SSHWire.command("pi ng", [:], key: key, challenge: ch, seq: 0) == nil)

        let id = String(repeating: "1", count: 32), nonce = String(repeating: "2", count: 32)
        let msg: [String: Any] = ["v": 1, "t": "req", "id": id, "nonce": nonce, "ts": 100, "tool": "claude", "kind": "approve", "sid": "abc",
                                  "env": ["PWD": "/srv/api", "SSH_CONNECTION": "1.2.3.4 50000 5.6.7.8 22", "EVIL": "x"], "pid": 4242,
                                  "in": Data(#"{"a":1}"#.utf8).base64EncodedString()]
        let json = try! JSONSerialization.data(withJSONObject: msg, options: [.sortedKeys])
        let hm = SSHWire.hmac(key, Data("cocaine-ssh-hook-v1\n".utf8) + json)
        let m = SSHWire.hook(Data("5 \(hm) ".utf8) + json, key: key)
        check("hook line: read with its own signature; only the expected environment variables are kept",
              m?.conn == 5 && m?.request == true && m?.pid == 4242 && m?.env["EVIL"] == nil && m?.env["PWD"] == "/srv/api" && m?.input == Data(#"{"a":1}"#.utf8))
        check("hook line: another key's signature is refused", SSHWire.hook(Data("5 \(SSHWire.hmac(other, Data("cocaine-ssh-hook-v1\n".utf8) + json)) ".utf8) + json, key: key) == nil)
        var bad = msg; bad["kind"] = "done"
        let badJSON = try! JSONSerialization.data(withJSONObject: bad)
        check("hook line: a request must be an approval (and news never is)", SSHWire.message(badJSON, conn: 1) == nil)
        var badID = msg; badID["id"] = "../../x"
        check("hook line: ids of the wrong shape are refused", SSHWire.message(try! JSONSerialization.data(withJSONObject: badID), conn: 1) == nil)
        var badTool = msg; badTool["tool"] = "rm"
        check("hook line: an unknown tool is refused", SSHWire.message(try! JSONSerialization.data(withJSONObject: badTool), conn: 1) == nil)

        let ans = SSHWire.answer(key: key, conn: 5, id: id, nonce: nonce, output: "{\"x\":1}")
        check("answer: the hook's output in base64, signed over the hook's own id and nonce",
              ans["out"] as? String == Data("{\"x\":1}".utf8).base64EncodedString()
              && ans["mac"] as? String == SSHWire.hmac(key, "cocaine-ssh-answer-v1\n\(id)\n\(nonce)\n\(ans["out"] as! String)"))
        let plan: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "ExitPlanMode", "tool_input": ["plan": "# P\n1. a"]]
        let out = SSHWire.hookOutput(decision: "approve", content: nil, id: id, nonce: nonce, tool: "claude", input: plan)
        check("answer: an approved plan prints the same hook output as on this Mac (the plan echoed)",
              out == ##"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"plan":"# P\n1. a"}}}"##)
        check("answer: \"none\" prints nothing", SSHWire.hookOutput(decision: "none", content: nil, id: id, nonce: nonce, tool: "claude", input: plan) == nil)

        var g = SSHGuard(burst: 3, perSecond: 1, now: Date(timeIntervalSince1970: 0))
        let t0 = Date(timeIntervalSince1970: 0)
        check("flood: a burst is allowed, then refused, then allowed again with time",
              g.allow(now: t0) && g.allow(now: t0) && g.allow(now: t0) && !g.allow(now: t0) && g.allow(now: t0.addingTimeInterval(1.1)))
        var r = SSHGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        check("replay: a hook id is taken once", r.fresh(id: "a", ts: 1_000_000, offset: 0, now: now) && !r.fresh(id: "a", ts: 1_000_000, offset: 0, now: now))
        check("replay: a message from far outside the relay's clock is refused", !r.fresh(id: "b", ts: 1_000_000 - 3600, offset: 0, now: now))
        check("replay: the relay's own clock offset is taken into account", r.fresh(id: "c", ts: 1_000_000 + 3600, offset: 3600, now: now))
    }

    // MARK: The state machine

    static func machineTests(_ check: Check) {
        let t = Date(timeIntervalSince1970: 1000)
        var m = SSHLinkMachine()
        check("machine: enabling connects", m.handle(.enable, now: t) == [.connect] && m.phase == .connecting)
        check("machine: the relay's hello makes it connected (sessions reachable)", m.handle(.up, now: t) == [.reachable] && m.phase == .connected)
        let fx = m.handle(.down(.dropped), now: t.addingTimeInterval(5))
        check("machine: a drop marks sessions unreachable and retries after 2 s", fx == [.unreachable, .schedule(t.addingTimeInterval(7))])
        check("machine: not before its time", m.handle(.tick, now: t.addingTimeInterval(6)) == [] && m.handle(.tick, now: t.addingTimeInterval(7)) == [.connect])
        var delays: [TimeInterval] = []
        for i in 0..<10 {
            let now = t.addingTimeInterval(Double(100 * (i + 1)))
            if case .retrying(let at) = m.phase { _ = m.handle(.tick, now: at) }
            _ = m.handle(.down(.network("refused")), now: now)
            if case .retrying(let at) = m.phase { delays.append(at.timeIntervalSince(now)) }
        }
        check("machine: the backoff doubles up to 5 minutes", delays == [4, 8, 16, 32, 64, 128, 256, 300, 300, 300])
        check("machine: jitter stays within ±20 %", (0..<50).allSatisfy { _ in
            let j = Double.random(in: -1...1)
            let d = SSHLinkMachine.backoff(3, jitter: j)
            return d >= 6.4 - 0.0001 && d <= 9.6 + 0.0001 })
        check("machine: a wake or a network change retries at once", m.handle(.wake, now: t.addingTimeInterval(2000)) == [.connect])
        _ = m.handle(.up, now: t.addingTimeInterval(2000))
        _ = m.handle(.down(.dropped), now: t.addingTimeInterval(2000 + 61))
        if case .retrying(let at) = m.phase { check("machine: after a stable connection the backoff starts again from 2 s", at.timeIntervalSince(t.addingTimeInterval(2061)) == 2) }
        else { check("machine: after a stable connection the backoff starts again from 2 s", false) }

        var k = SSHLinkMachine()
        _ = k.handle(.enable, now: t)
        check("machine: a changed host key stops it (no retry)", k.handle(.down(.hostKeyChanged), now: t) == [.unreachable] && k.phase == .stopped(.hostKeyChanged))
        check("machine: …not on a tick, a wake or a network change", k.handle(.tick, now: t.addingTimeInterval(9999)) == [] && k.handle(.wake, now: t) == [] && k.handle(.network, now: t) == [])
        check("machine: …only when the user retries", k.handle(.retry, now: t) == [.connect])
        var a = SSHLinkMachine()
        _ = a.handle(.enable, now: t); _ = a.handle(.down(.auth), now: t)
        check("machine: a refused login waits, and is tried again after a wake (an agent unlocked)", a.handle(.tick, now: t.addingTimeInterval(9999)) == [] && a.handle(.wake, now: t) == [.connect])
        check("machine: turning it off closes the connection; nothing happens while off",
              a.handle(.disable, now: t) == [.disconnect, .unreachable] && a.handle(.wake, now: t) == [] && a.handle(.down(.dropped), now: t) == [] && a.phase == .off)
        var c = SSHLinkMachine()
        _ = c.handle(.enable, now: t); _ = c.handle(.up, now: t)
        check("machine: a wake while connected checks the connection (ping)", c.handle(.wake, now: t) == [.ping])
    }

    // MARK: ssh's own words

    static func classifyTests(_ check: Check) {
        let changed = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
        Host key for devbox has changed and you have requested strict checking.
        Host key verification failed.
        """
        check("stderr: a changed host key", SSHFailure.classify(stderr: changed, status: 255) == .hostKeyChanged)
        check("stderr: an unknown host key", SSHFailure.classify(stderr: "No ED25519 host key is known for devbox and you have requested strict checking.\nHost key verification failed.\n", status: 255) == .hostKeyUnknown)
        check("stderr: a refused login", SSHFailure.classify(stderr: "user@devbox: Permission denied (publickey,password).\n", status: 255) == .auth)
        check("stderr: no relay there", SSHFailure.classify(stderr: "sh: 1: exec: /home/u/.cocaine/bin/cocaine-relay: not found\n", status: 127) == .relayMissing)
        check("stderr: no perl there", SSHFailure.classify(stderr: "/usr/bin/env: 'perl': No such file or directory\n", status: 127) == .noPerl)
        check("stderr: perl without JSON::PP", SSHFailure.classify(stderr: "Can't locate JSON/PP.pm in @INC (you may need to install the JSON::PP module)\n", status: 2) == .noPerl)
        check("stderr: no key there", SSHFailure.classify(stderr: "cocaine-relay: no key\n", status: 3) == .keyMismatch)
        check("stderr: an unknown name (DNS)", SSHFailure.classify(stderr: "ssh: Could not resolve hostname devbox: nodename nor servname provided\n", status: 255) == .network("dns"))
        let refused = SSHFailure.classify(stderr: "ssh: connect to host devbox port 22: Connection refused\n", status: 255)
        check("stderr: a refused connection is a network problem, tried again", refused.retryable && { if case .network = refused { return true }; return false }())
    }

    // MARK: From a remote hook to the app

    static let host = SSHHost(id: "a1b2c3", alias: "devbox", name: "Dev box", deployed: true)

    static func hook(_ kind: String, _ input: [String: Any], request: Bool = false, env: [String: String] = ["PWD": "/srv/api", "SSH_CONNECTION": "10.0.0.5 51515 10.0.0.9 22", "TMUX_PANE": "%3", "TMUX": "/tmp/tmux-1000/default,1234,0"]) -> SSHWire.HookMessage {
        SSHWire.HookMessage(conn: 3, id: String(repeating: "c", count: 32), nonce: String(repeating: "d", count: 32), request: request, ts: 0, tool: "claude",
                            kind: kind, sid: input["session_id"] as? String, env: env, pid: 777,
                            input: try? JSONSerialization.data(withJSONObject: input), cut: false)
    }

    static func eventTests(_ check: Check) {
        let input: [String: Any] = ["session_id": "sess-1", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "ls"], "cwd": "/srv/api"]
        let r = SSHEvents.request(hook("approve", input, request: true), input: input, host: host, now: Date())
        check("request: shown like a local one, its session keyed by host, the project tagged with the host's name",
              r?.session == "ssh.a1b2c3:sess-1" && r?.project == "api · Dev box" && r?.summary == "ls" && r?.choices.count == 2)
        check("request: its origin names only remote things (no folder, process or terminal of this Mac)",
              r?.origin.remoteHost == "a1b2c3" && r?.origin.cwd == nil && r?.origin.pid == nil && r?.origin.tty == nil && r?.origin.remotePid == 777
              && r?.origin.remoteCwd == "/srv/api" && r?.origin.sshConnection == "10.0.0.5 51515 10.0.0.9 22" && r?.origin.remoteTmuxPane == "%3"
              && r?.origin.remoteTmuxSocket == "/tmp/tmux-1000/default")
        let stop: [String: Any] = ["session_id": "sess-1", "hook_event_name": "Stop", "last_assistant_message": "All done"]
        let a = SSHEvents.alert(hook("done", stop), input: stop, host: host)
        check("news: a finish is an alert of that remote session, with its text for the card",
              a?.params.event == "done" && a?.params.sessionKey == "ssh.a1b2c3:sess-1" && a?.params.from == "Claude Code" && a?.extra?["message"] as? String == "All done")
        let idle: [String: Any] = ["session_id": "s", "notification_type": "idle_prompt"]
        check("news: an idle reminder is not a \"needs you\"", SSHEvents.alert(hook("input", idle), input: idle, host: host) == nil)
        let perm: [String: Any] = ["session_id": "s", "notification_type": "permission_prompt"]
        check("news: a permission prompt is", SSHEvents.alert(hook("input", perm), input: perm, host: host)?.params.event == "input")
        let local = AlertParams()
        check("news: a remote key never equals a local one", SSHEvents.sessionKey(host: host, sid: "x", tool: "claude", project: nil) != local.sessionKey)
        check("news: a hostile session id keeps only safe characters, and fits",
              SSHEvents.sessionKey(host: host, sid: "a;b$(c)" + String(repeating: "z", count: 200), tool: "claude", project: nil).count <= 80)
        var late = [hook("start", ["session_id": "s1"]), hook("done", ["session_id": "s1"]), hook("open", ["session_id": "s2"])]
        late[0].ts = 1; late[1].ts = 2; late[2].ts = 3
        let l = SSHEvents.late(late, host: host)
        check("backlog: only each session's latest state, no alert", l.map(\.session) == ["ssh.a1b2c3:s1", "ssh.a1b2c3:s2"] && l.map(\.state) == ["done", "idle"])
    }

    // MARK: The board

    static func boardTests(_ check: Check) {
        var o = AgentOrigin(app: "com.apple.Terminal", tty: "ttys001", cwd: "/Users/x", pid: 123)
        o.remoteHost = "a1b2c3"; o.remotePid = 55; o.remoteCwd = "/srv"
        let s = o.sanitized()
        check("origin: a remote one drops every local field", s.app == nil && s.tty == nil && s.cwd == nil && s.pid == nil && s.remotePid == 55 && s.remoteCwd == "/srv")
        var hostile = AgentOrigin()
        hostile.remoteHost = "zzz;rm"; hostile.remoteTmuxPane = "%3; rm"; hostile.sshConnection = "1.2.3.4 5 $(x) 22"
        let h = hostile.sanitized()
        check("origin: hostile remote values are dropped", h.remoteHost == nil && h.remoteTmuxPane == nil && h.sshConnection == nil)
        check("origin: a remote origin is never completed from this Mac's processes", AgentProcess.complete(s) == s)
        check("focus: no local step for a remote origin (no folder opened, no app activated)", AgentFocus.plan(s).isEmpty)

        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ssh-board-\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let b = AgentBoard(file: file)
        let now = Date()
        b.ingest(AgentSignal(env: "claude-code", from: "Claude Code", source: .hook, state: .working, session: "ssh.a1b2c3:s1", project: "api · Dev box", origin: s), now: now)
        b.ingest(AgentSignal(env: "claude-code", from: "Claude Code", source: .hook, state: .working, session: "s1", project: "api", origin: AgentOrigin(cwd: "/tmp")), now: now)
        check("board: a remote session and a local one with the same tool id are two rows", b.entries.count == 2)
        check("board: the relay is asked about the remote processes", b.remotePids(host: "a1b2c3") == [55])
        check("board: a dropped connection marks its sessions unreachable (not the local ones)",
              b.setReachable(host: "a1b2c3", false) && b.entry("ssh.a1b2c3:s1")?.unreachable == true && b.entry("s1")?.unreachable == nil)
        let saved = AgentBoard.remoteLiveness
        defer { AgentBoard.remoteLiveness = saved }
        AgentBoard.remoteLiveness = { e in e.unreachable == true ? true : nil }
        b.prune(now.addingTimeInterval(3 * 3600))
        check("board: an unreachable working session is kept past the usual 2 hours", b.entry("ssh.a1b2c3:s1") != nil && b.entry("s1") == nil)
        b.ingest(AgentSignal(env: "claude-code", from: "Claude Code", source: .hook, state: .waiting, session: "ssh.a1b2c3:s1", origin: s), now: now.addingTimeInterval(3 * 3600))
        check("board: news from it clears the mark", b.entry("ssh.a1b2c3:s1")?.unreachable == nil && b.entry("ssh.a1b2c3:s1")?.state == "waiting")
        AgentBoard.remoteLiveness = { _ in false }
        b.prune(now.addingTimeInterval(3 * 3600))
        check("board: once its relay says the process ended, the session goes", b.entry("ssh.a1b2c3:s1") == nil)
        AgentBoard.remoteLiveness = { _ in nil }
        b.ingest(AgentSignal(env: "claude-code", from: "Claude Code", source: .hook, state: .working, session: "ssh.a1b2c3:s9", origin: s), now: now)
        check("board: removing a host removes its sessions", b.removeHost("a1b2c3") == ["ssh.a1b2c3:s9"] && b.entries.isEmpty)
    }

    // MARK: The remote installer

    static func installerTests(_ check: Check) {
        let tools = SSHInstaller.tools(present: ["claude", "codex"], claudeVersion: "2.1.90")
        check("installer: the remote tools present, with their files relative to the remote home",
              SSHInstaller.paths(tools) == [".claude/settings.json", ".codex/hooks.json"])
        let mine = #"""
        {
          "model": "opus",
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "my-own-script.sh"
                  }
                ]
              }
            ]
          }
        }

        """#
        let files = [".claude/settings.json": SSHRemoteFile(path: ".claude/settings.json", exists: true, text: mine, sha: SSHWire.sha256(Data(mine.utf8))),
                     ".codex/hooks.json": SSHRemoteFile(path: ".codex/hooks.json", exists: false, text: nil, sha: "")]
        let p = SSHInstaller.plan(on: true, tools: tools, files: files)
        let claude = p.changes.first { $0.tool == "claude" }
        check("installer: the user's own hook and settings stay, Cocaine's are added", claude?.after.contains("my-own-script.sh") == true
              && claude?.after.contains("\"model\": \"opus\"") == true && (claude?.removed ?? 9) <= 1 && (claude?.added ?? 0) > 10)
        check("installer: every command runs the relay there and carries the marker",
              claude?.after.contains(#"\"$HOME/.cocaine/bin/cocaine-relay\" hook claude done >/dev/null 2>&1; true # cocaine://alert"#) == true
              && claude?.after.contains(#"hook claude approve 2>/dev/null; true # cocaine://alert"#) == true)
        check("installer: requests get the long timeout (the notch can hold them for 2 minutes)", claude?.after.contains("\"timeout\": 150") == true)
        check("installer: a missing file is created", p.changes.first { $0.tool == "codex" }?.before == nil)
        let shown = SSHInstaller.shown(claude!.diff)
        check("installer: the shown diff keeps two lines around the changes and folds the rest",
              shown.first == DiffLine(kind: .header, text: "…") && shown.count < claude!.diff.count && shown.filter { $0.kind == .add }.count == claude!.added)

        let applied = files.mapValues { f -> SSHRemoteFile in
            guard let c = p.changes.first(where: { $0.path == f.path }) else { return f }
            return SSHRemoteFile(path: f.path, exists: true, text: c.after, sha: SSHWire.sha256(Data(c.after.utf8)))
        }
        check("installer: running it again changes nothing", SSHInstaller.plan(on: true, tools: tools, files: applied).isEmpty)
        check("installer: the hooks read as on", SSHInstaller.hooksOn(files: applied) == ["claude", "codex"])
        let off = SSHInstaller.plan(on: false, tools: SSHInstaller.tools(present: Set(AIHooks.remoteIDs), claudeVersion: nil), files: applied)
        let back = off.changes.first { $0.tool == "claude" }
        check("installer: removing gives back the user's file as it was", back.map { AIHooks.parse($0.after) == AIHooks.parse(mine) } == true)

        let old = SSHInstaller.plan(on: true, tools: SSHInstaller.tools(present: ["claude"], claudeVersion: nil), files: files)
        check("installer: without a known Claude Code version, only the events every version has (no requests)",
              old.changes.first.map { !$0.after.contains("approve") && $0.after.contains("hook claude done") } == true)
        let localMac = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/Applications/Cocaine.app/Contents/MacOS/Cocaine' --agent-event claude done 2>/dev/null || true # cocaine://alert"}]}]}}"#
        let lp = SSHInstaller.plan(on: true, tools: tools, files: [".claude/settings.json": SSHRemoteFile(path: ".claude/settings.json", exists: true, text: localMac, sha: "x")])
        check("installer: a machine that runs Cocaine itself is left alone", lp.problems.map(\.reason) == ["local", "unread"] && lp.changes.isEmpty)
        let junk = SSHInstaller.plan(on: true, tools: tools, files: [".claude/settings.json": SSHRemoteFile(path: ".claude/settings.json", exists: true, text: "{ not json", sha: "x"),
                                                                     ".codex/hooks.json": SSHRemoteFile(path: ".codex/hooks.json", exists: true, text: nil, sha: "y")])
        check("installer: a file that isn't JSON (or not UTF-8) is never touched", junk.problems.map(\.reason) == ["format", "format"] && junk.changes.isEmpty)
        let w = SSHInstaller.writes(p)
        check("installer: each write names the content it replaces; its undo puts the old file back (or deletes a new one)",
              w.count == 2 && w[0].apply.old == files[".claude/settings.json"]!.sha && w[0].undo.data == mine && w[1].undo.delete && w[1].apply.old == "")
        check("installer: the relay's reply is checked against its own hash",
              SSHInstaller.file(["ok": true, "path": "a", "exists": true, "data": Data("x".utf8).base64EncodedString(), "sha": "00"]) == nil)
    }

    // MARK: Jump

    static func jumpTests(_ check: Check) {
        let lsof = """
        p501
        f3
        n192.168.1.20:51515->203.0.113.9:22
        p502
        f3
        n192.168.1.20:52000->198.51.100.7:2222
        p503
        f4
        n[2001:db8::2]:53000->[2001:db8::9]:22
        p900
        f3
        n192.168.1.20:54000->203.0.113.9:22
        """
        let sockets = SSHJump.parseLsof(lsof)
        check("jump: lsof's IPv4 and IPv6 sockets are read", sockets.count == 4 && sockets[2] == SSHJump.Socket(pid: 503, localPort: 53000, remoteIP: "2001:db8::9", remotePort: 22))
        let ps = SSHJump.parsePS("""
          501     1 ttys001 ssh devbox
          502     1 ttys002 ssh -p 2222 me@build
          503     1 ttys003 /usr/bin/ssh v6host
          900   77 ??      /usr/bin/ssh -T -- devbox sh -c exec
          950     1 ttys004 vim notes
        """)
        let own: Int32 = 77
        check("jump: the client port finds the ssh process", SSHJump.match(SSHJump.connection("192.168.1.20 51515 203.0.113.9 22")!, alias: "devbox", sockets: sockets, ps: ps, own: own) == 501)
        check("jump: behind NAT (another port), the one ssh to that server address",
              SSHJump.match(SSHJump.connection("198.18.0.1 60000 198.51.100.7 2222")!, alias: "build", sockets: sockets, ps: ps, own: own) == 502)
        check("jump: Cocaine's own background connection is never the answer",
              SSHJump.match(SSHJump.connection("1.1.1.1 54000 9.9.9.9 99")!, alias: "nomatch", sockets: sockets, ps: ps, own: own) == nil)
        check("jump: else the one interactive ssh naming that host", SSHJump.byAlias("me@build:2222", ps: ps, own: own) == 502 && SSHJump.byAlias("devbox", ps: ps, own: own) == 501)
        let two = SSHJump.parsePS("  1 1 ttys001 ssh devbox\n  2 1 ttys002 ssh devbox\n")
        check("jump: two candidates are not guessed between", SSHJump.byAlias("devbox", ps: two, own: own) == nil)
        check("jump: IPv6 with a zone and IPv4-mapped addresses compare equal", SSHJump.normal("FE80::1%en0") == "fe80::1" && SSHJump.normal("::ffff:10.0.0.1") == "10.0.0.1")
        check("jump: a malformed SSH_CONNECTION is ignored", SSHJump.connection("1.2.3.4 x 5.6.7.8 22") == nil && SSHJump.connection(nil) == nil)
        check("jump: the message says it wasn't the exact tab", AppDelegate.focusMessage(AgentFocus.Result(level: .app, appName: "Terminal", note: .sshTabNotFound), "x")?.contains("Terminal") == true)
    }
}
