// --ssh-test, end to end: the real relay (from the app bundle, run by /usr/bin/perl) behind a fake `ssh` that runs the remote
// command on this Mac with HOME set to a temporary folder. Every file is under one temporary folder, removed at the end.

import AppKit

extension SSHTests {
    /// The fake ssh: skips ssh's options, logs the host, and (unless FAKE_SSH_MODE says to fail like ssh would) runs the remote
    /// command with HOME=$FAKE_SSH_HOME.
    static let fakeSSH = """
    #!/bin/sh
    echo "ARGS $*" >> "$FAKE_SSH_HOME/../fake-ssh.log"
    while [ $# -gt 0 ]; do
      case "$1" in
        --) shift; break ;;
        -o|-p|-S|-e|-F|-i|-J|-l) shift 2 ;;
        *) shift ;;
      esac
    done
    dest="$1"; shift
    echo "$dest $FAKE_SSH_MODE" >> "$FAKE_SSH_HOME/../fake-ssh.log"
    case "$FAKE_SSH_MODE" in
      hostkeychanged)
        echo "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@" >&2
        echo "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @" >&2
        echo "Host key for $dest has changed and you have requested strict checking." >&2
        echo "Host key verification failed." >&2
        exit 255 ;;
      auth) echo "$dest: Permission denied (publickey)." >&2; exit 255 ;;
      noise) echo "Welcome to Ubuntu 24.04 LTS"; echo "Last login: Mon Oct  5 10:00:00 2026" ;;
    esac
    HOME="$FAKE_SSH_HOME"; export HOME
    exec /bin/sh -c "$1"
    """

    final class HookRun {
        let p = Process()
        private let lock = NSLock()
        private var data = Data()
        private(set) var finished = false
        var out: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }

        init(home: String, tool: String, kind: String, input: Data, env more: [String: String] = [:]) {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [home + "/.cocaine/bin/cocaine-relay", "hook", tool, kind]
            p.environment = ["HOME": home, "PATH": "/usr/bin:/bin", "COCAINE_HOOK_TIMEOUT": "20", "PWD": "/srv/api",
                             "SSH_CONNECTION": "10.0.0.5 51515 10.0.0.9 22", "TMUX_PANE": "%1"].merging(more) { $1 }
            let i = Pipe(), o = Pipe()
            p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
            o.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self else { return }
                self.lock.lock(); self.data.append(d); self.lock.unlock()
                if d.isEmpty { h.readabilityHandler = nil }
            }
            p.terminationHandler = { [weak self] _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { self?.lock.lock(); self?.finished = true; self?.lock.unlock() }
            }
            try? p.run()
            try? i.fileHandleForWriting.write(contentsOf: input)
            try? i.fileHandleForWriting.close()
        }
    }

    @discardableResult
    static func wait(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !cond() {
            if Date() > end { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    static func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? -1
    }

    static func servePID(_ home: String) -> pid_t? {
        (try? String(contentsOfFile: home + "/.cocaine/run/serve.pid", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func endToEnd(_ check: Check) {
        guard let relay = SSHHostManager.bundledRelay() else { check("e2e: the relay is in the app bundle (Contents/Resources/cocaine-relay)", false); return }
        var tpl = Array("/tmp/cocaine-ssh-XXXXXX".utf8CString)
        guard let made = mkdtemp(&tpl) else { check("e2e: a temporary folder", false); return }
        let root = String(cString: made)
        let home = root + "/home", support = root + "/support", bin = root + "/bin"
        let fm = FileManager.default
        for d in [home, support, bin] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let started = Date()
        defer {
            if let p = servePID(home) { kill(p, SIGCONT); kill(p, SIGKILL) }
            try? fm.removeItem(atPath: root)
        }
        try? fakeSSH.write(toFile: bin + "/ssh", atomically: true, encoding: .utf8)
        chmod(bin + "/ssh", 0o755)

        let m = SSHHostManager()
        let keys = SSHMemoryKeys()
        m.support = URL(fileURLWithPath: support, isDirectory: true)
        m.keys = keys
        m.sshPath = bin + "/ssh"
        var env = ["FAKE_SSH_HOME": home, "PATH": "/usr/bin:/bin", "LANG": "C", "COCAINE_RELAY_NO_LOGIN_SHELL": "1"]
        m.environment = env
        m.relayScript = relay
        m.watchSystem = false
        m.jitter = { 0 }
        m.tune = { $0.pingEvery = 0.5; $0.pingWait = 2 }
        var requests: [ApprovalRequest] = [], alerts: [(AlertParams, [String: Any]?)] = [], boards: [(String, String)] = [], gone: [String] = []
        var reach: [Bool] = []
        m.onRequest = { requests.append($0) }
        m.onAlert = { alerts.append(($0, $1)) }
        m.onBoard = { s, _, _, state, _ in boards.append((s, state)) }
        m.onGone = { gone.append($0) }
        m.onReachable = { _, ok in reach.append(ok) }
        m.start()
        defer { m.stop() }

        guard case .success(let h) = m.add(alias: "devbox", name: "Dev box") else { check("e2e: a host is added", false); return }
        check("e2e: a host is added, and kept in a private file", SSHHostStore.load(m.support).hosts.map(\.alias) == ["devbox"] && mode(SSHHostStore.file(m.support).path) == 0o600)
        check("e2e: a hostile name or a duplicate is refused", m.add(alias: "-oProxyCommand=x") == .failure(.invalid) && m.add(alias: "devbox") == .failure(.duplicate))
        check("e2e: nothing is connected before the relay is installed (the user's OK)", !m.isUp(h.id) && m.status[h.id]?.phase == .off)

        // Deployment
        var deployed: Bool?
        m.deploy(h.id) { deployed = $0 }
        wait(20) { deployed != nil }
        let base = home + "/.cocaine"
        let keyText = (try? String(contentsOfFile: base + "/relay.key", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        check("e2e: the relay is installed: ~/.cocaine 0700, the relay 0700, the key 0600 and the same as the Mac's",
              deployed == true && mode(base) == 0o700 && mode(base + "/bin/cocaine-relay") == 0o700 && mode(base + "/relay.key") == 0o600
              && keyText == keys.load(h.id)?.hex && fm.contents(atPath: base + "/bin/cocaine-relay") == relay)
        check("e2e: …and it connects at once (signed handshake, same relay)", wait(15) { m.isUp(h.id) } && m.status[h.id]?.hello?.sha == SSHWire.sha256(relay))
        if !m.isUp(h.id) { print("      status: \(String(describing: m.status[h.id]))") }
        let log = (try? String(contentsOfFile: root + "/fake-ssh.log", encoding: .utf8)) ?? ""
        check("e2e: the key never went through a command line (only stdin); the host came after --",
              log.contains("ARGS ") && !log.contains(keyText ?? "-") && log.contains(" -- devbox sh -c "))

        // News
        let stop = try! JSONSerialization.data(withJSONObject: ["session_id": "s-1", "hook_event_name": "Stop", "last_assistant_message": "Remote work done"])
        let ev = HookRun(home: home, tool: "claude", kind: "done", input: stop)
        wait(10) { !alerts.isEmpty && ev.done }
        let a = alerts.first
        check("e2e: a remote finish arrives as an alert of that host's session, with its text", a?.0.sessionKey == "ssh.\(h.id):s-1" && a?.0.event == "done"
              && a?.0.project == "api · Dev box" && a?.1?["message"] as? String == "Remote work done" && a?.0.origin.remoteHost == h.id)
        check("e2e: the hook printed nothing and ended", ev.done && ev.out.isEmpty)

        // A request, allowed from the "notch"
        let perm = try! JSONSerialization.data(withJSONObject: ["session_id": "s-1", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                                                "tool_input": ["command": "ls -la"]])
        let rq = HookRun(home: home, tool: "claude", kind: "approve", input: perm)
        wait(10) { requests.count == 1 }
        let r = requests.first
        check("e2e: a remote request reaches the review, owned by its host", r?.summary == "ls -la" && r?.session == "ssh.\(h.id):s-1" && r.map { m.owns($0.id) } == true)
        var sent: Bool?
        if let r { m.reply(r.id, decision: "allow", content: nil) { sent = $0 } }
        wait(10) { rq.done && sent != nil }
        check("e2e: the answer goes back signed and the remote hook prints the documented output",
              sent == true && rq.out.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)

        // A request handed back to the terminal
        let rq2 = HookRun(home: home, tool: "claude", kind: "approve", input: perm)
        wait(10) { requests.count == 2 }
        if requests.count == 2 { m.reply(requests[1].id, decision: "none", content: nil) }
        wait(10) { rq2.done }
        check("e2e: handed back: the hook prints nothing (the terminal asks)", rq2.done && rq2.out.isEmpty)
        check("e2e: a late second answer finds nothing", requests.count == 2 && !m.owns(requests[1].id))

        // A request whose hook goes away (the user answered in the terminal)
        let rq3 = HookRun(home: home, tool: "claude", kind: "approve", input: perm)
        wait(10) { requests.count == 3 }
        rq3.p.terminate()
        check("e2e: a hook that goes away is reported gone", wait(10) { requests.count == 3 && gone.contains(requests[2].id) })

        hookSideTests(check, root: root)
        installTests(check, m: m, h: h, home: home)

        // The backlog while turned off, caught up after
        m.setEnabled(h.id, false)
        wait(10) { !m.isUp(h.id) && servePID(home).map { kill($0, 0) != 0 } ?? true }
        check("e2e: turned off: disconnected, its sessions marked unreachable", !m.isUp(h.id) && reach.last == false)
        let open = try! JSONSerialization.data(withJSONObject: ["session_id": "s-late", "hook_event_name": "SessionStart"])
        let off = HookRun(home: home, tool: "claude", kind: "open", input: open)
        wait(10) { off.done }
        let backlog = (try? String(contentsOfFile: base + "/run/backlog", encoding: .utf8)) ?? ""
        check("e2e: news while away is kept there without any text", backlog.contains("s-late") && !backlog.contains("SessionStart") && off.out.isEmpty)
        m.setEnabled(h.id, true)
        check("e2e: back on: the backlog brings the list up to date (board only, no alert)",
              wait(15) { boards.contains { $0 == ("ssh.\(h.id):s-late", "idle") } } && !alerts.contains { $0.0.sessionKey == "ssh.\(h.id):s-late" })

        // A dropped connection: retried with backoff, reconnected
        let reachBefore = reach.count
        if let p = servePID(home) { kill(p, SIGKILL) }
        check("e2e: a dropped connection is noticed (sessions unreachable) and retried", wait(10) { reach.count > reachBefore && reach.last == false })
        check("e2e: …and reconnects after the backoff", wait(15) { m.isUp(h.id) })

        // A relay that stops answering: the keepalive ends the connection, then it reconnects
        if let p = servePID(home) { kill(p, SIGSTOP) }
        let stuck = servePID(home)
        check("e2e: a relay that stops answering is dropped by the keepalive", wait(15) { !m.isUp(h.id) })
        if let p = stuck { kill(p, SIGCONT); kill(p, SIGKILL) }
        check("e2e: …and a new connection is made", wait(20) { m.isUp(h.id) && servePID(home) != stuck })

        // An outdated relay is replaced on its own (the user installed it before)
        if let fh = FileHandle(forWritingAtPath: base + "/bin/cocaine-relay") { fh.seekToEndOfFile(); fh.write(Data("\n# older\n".utf8)); try? fh.close() }
        if let p = servePID(home) { kill(p, SIGKILL) }
        check("e2e: a different relay there is replaced by this app's and connects", wait(25) { m.isUp(h.id) && fm.contents(atPath: base + "/bin/cocaine-relay") == relay })

        // A relay with another key: refused
        try? (String(repeating: "ab", count: 32) + "\n").write(toFile: base + "/relay.key", atomically: true, encoding: .utf8)
        chmod(base + "/relay.key", 0o600)
        if let p = servePID(home) { kill(p, SIGKILL) }
        check("e2e: a relay signing with another key is refused (stopped, not retried)", wait(15) { m.status[h.id]?.phase == .stopped(.keyMismatch) })
        var again: Bool?
        m.deploy(h.id) { again = $0 }
        check("e2e: installing it again puts this Mac's key back and connects", wait(25) { again == true && m.isUp(h.id) })

        // A changed host key: stopped, never retried on its own
        env["FAKE_SSH_MODE"] = "hostkeychanged"; m.environment = env
        if let p = servePID(home) { kill(p, SIGKILL) }
        check("e2e: a changed host key stops it and says so", wait(15) { m.status[h.id]?.phase == .stopped(.hostKeyChanged) })
        let attempts = ((try? String(contentsOfFile: root + "/fake-ssh.log", encoding: .utf8)) ?? "").components(separatedBy: "hostkeychanged").count
        wait(4) { false }
        let later = ((try? String(contentsOfFile: root + "/fake-ssh.log", encoding: .utf8)) ?? "").components(separatedBy: "hostkeychanged").count
        check("e2e: …and doesn't try again by itself", attempts == later && m.status[h.id]?.phase == .stopped(.hostKeyChanged))

        // A login banner on stdout doesn't get in the way
        env["FAKE_SSH_MODE"] = "noise"; m.environment = env
        m.retry(h.id)
        check("e2e: a shell's banner before the relay is ignored", wait(15) { m.isUp(h.id) })
        env["FAKE_SSH_MODE"] = nil; m.environment = env

        // Removing the host and cleaning up there
        var removed: Bool?
        m.remove(h.id, cleanUp: true) { removed = $0 }
        wait(20) { removed != nil }
        let settings = (try? String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8)) ?? ""
        check("e2e: removed and cleaned up: no ~/.cocaine there, no Cocaine hooks there, the user's own hook kept",
              removed == true && !fm.fileExists(atPath: base) && !settings.contains("cocaine") && settings.contains("my-own-script.sh"))
        check("e2e: …the host is gone from the list, its key from the store", m.store.hosts.isEmpty && keys.keys.isEmpty)
        let audit = (try? String(contentsOfFile: SSHHostStore.folder(m.support).path + "/audit.log", encoding: .utf8)) ?? ""
        check("e2e: the audit log says what happened, never any content",
              audit.contains("relay installed") && audit.contains("request permission") && audit.contains("answer allow") && audit.contains("hooks added")
              && audit.contains("removed") && !audit.contains("ls -la") && !audit.contains("Remote work done") && !audit.contains("my-own-script"))
        check("e2e: audit log is private", mode(SSHHostStore.folder(m.support).path + "/audit.log") == 0o600)
        print("      (ssh end to end: \(Int(Date().timeIntervalSince(started))) s)")
    }

    /// The remote hook on its own, against a stand-in for the relay: only an answer signed over its own request counts.
    static func hookSideTests(_ check: Check, root: String) {
        let home = root + "/home2"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: home + "/.cocaine/run", withIntermediateDirectories: true)
        try? fm.copyItem(atPath: root + "/home/.cocaine/bin", toPath: home + "/.cocaine/bin")
        let key = Data(repeating: 0x42, count: 32)
        try? (key.hex + "\n").write(toFile: home + "/.cocaine/relay.key", atomically: true, encoding: .utf8)
        chmod(home + "/.cocaine/relay.key", 0o600)
        let sock = home + "/.cocaine/run/relay.sock"
        let input = try! JSONSerialization.data(withJSONObject: ["session_id": "x", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "id"]])

        func serveOnce(_ answer: @escaping (_ id: String, _ nonce: String, _ hookOK: Bool) -> String) -> Int32 {
            unlink(sock)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0, var addr = ApprovalServer.address(sock) else { return -1 }
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard ok == 0, listen(fd, 2) == 0 else { close(fd); return -1 }
            DispatchQueue.global().async {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                var line = Data(), b = [UInt8](repeating: 0, count: 65536)
                while !line.contains(0x0A) { let n = read(c, &b, b.count); if n <= 0 { break }; line.append(contentsOf: b[0..<n]) }
                let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
                let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
                let json = parts.count == 2 ? Data(parts[1].utf8) : Data()
                let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
                let hookOK = parts.count == 2 && parts[0] == SSHWire.hmac(key, Data("cocaine-ssh-hook-v1\n".utf8) + json)
                let reply = answer(o["id"] as? String ?? "", o["nonce"] as? String ?? "", hookOK) + "\n"
                _ = reply.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
            return fd
        }
        let out = Data("{\"ok\":1}".utf8).base64EncodedString()
        func answer(_ id: String, _ nonce: String, macKey: Data, out o: String = out) -> String {
            let mac = SSHWire.hmac(macKey, "cocaine-ssh-answer-v1\n\(id)\n\(nonce)\n\(o)")
            return String(decoding: try! JSONSerialization.data(withJSONObject: ["id": id, "out": o, "mac": mac]), as: UTF8.self)
        }
        var signedOK = false
        var fd = serveOnce { id, nonce, ok in signedOK = ok; return answer(id, nonce, macKey: key) }
        let good = HookRun(home: home, tool: "claude", kind: "approve", input: input)
        wait(10) { good.done }
        close(fd)
        check("hook: its line is signed with the host's key", signedOK)
        check("hook: an answer signed over its own id and nonce is printed", good.out.trimmingCharacters(in: .whitespacesAndNewlines) == "{\"ok\":1}")
        fd = serveOnce { id, nonce, _ in answer(id, nonce, macKey: Data(repeating: 1, count: 32)) }
        let forged = HookRun(home: home, tool: "claude", kind: "approve", input: input)
        wait(10) { forged.done }
        close(fd)
        check("hook: an answer with another key's signature prints nothing", forged.done && forged.out.isEmpty)
        fd = serveOnce { id, _, _ in answer(id, String(repeating: "0", count: 32), macKey: key) }
        let replay = HookRun(home: home, tool: "claude", kind: "approve", input: input)
        wait(10) { replay.done }
        close(fd)
        check("hook: an answer signed for another request (replayed) prints nothing", replay.done && replay.out.isEmpty)
        fd = serveOnce { _, nonce, _ in answer(String(repeating: "9", count: 32), nonce, macKey: key) }
        let other = HookRun(home: home, tool: "claude", kind: "approve", input: input)
        wait(10) { other.done }
        close(fd)
        check("hook: an answer for another id prints nothing", other.done && other.out.isEmpty)
        unlink(sock)
        let t0 = Date()
        let none = HookRun(home: home, tool: "claude", kind: "approve", input: input)
        wait(10) { none.done }
        check("hook: with no relay running it prints nothing and ends at once", none.done && none.out.isEmpty && Date().timeIntervalSince(t0) < 5)
        let tooBig = HookRun(home: home, tool: "claude", kind: "approve", input: Data(repeating: 0x20, count: 1_100_000))
        wait(15) { tooBig.done }
        check("hook: a request too long to send whole prints nothing (the terminal asks)", tooBig.done && tooBig.out.isEmpty)
        let bad = HookRun(home: home, tool: "rm -rf", kind: "approve", input: input)
        wait(10) { bad.done }
        check("hook: a bad tool name does nothing", bad.done && bad.out.isEmpty)
    }

    /// The remote hooks: reviewed, applied, rolled back when a write fails, idempotent, removed.
    static func installTests(_ check: Check, m: SSHHostManager, h: SSHHost, home: String) {
        let fm = FileManager.default
        let mine = "{\n  \"model\": \"opus\",\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"my-own-script.sh\"\n          }\n        ]\n      }\n    ]\n  }\n}\n"
        try? fm.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        try? mine.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        chmod(home + "/.claude/settings.json", 0o644)
        chmod(home + "/.codex", 0o500)                                   // its hooks.json can't be written: the first try fails
        try? fm.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try? "#!/bin/sh\necho '2.1.90 (Claude Code)'\n".write(toFile: home + "/.local/bin/claude", atomically: true, encoding: .utf8)
        chmod(home + "/.local/bin/claude", 0o755)                         // the relay reads this version: requests' hooks are added
        m.review = nil
        m.reviewHooks(h.id)
        wait(20) { m.review != nil }
        let plan = m.review?.plan
        check("install: the review lists each file's change before anything is written",
              plan?.changes.map(\.path) == [".claude/settings.json", ".codex/hooks.json"]
              && (try? String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8)) == mine)
        var ok: Bool?
        m.applyReview { ok = $0 }
        wait(20) { ok != nil }
        check("install: a write that fails undoes the ones before it (all or nothing)",
              ok == false && (try? String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8)) == mine && !fm.fileExists(atPath: home + "/.codex/hooks.json"))
        if ok != false || (try? String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8)) != mine { print("      ok=\(String(describing: ok)) note=\(m.status[h.id]?.note ?? "-") codex=\(fm.fileExists(atPath: home + "/.codex/hooks.json")) same=\((try? String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8)) == mine)") }
        chmod(home + "/.codex", 0o700)
        m.reviewHooks(h.id)
        wait(20) { m.review != nil }
        ok = nil
        m.applyReview { ok = $0 }
        wait(20) { ok != nil }
        let after = (try? String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8)) ?? ""
        let backups = (try? fm.contentsOfDirectory(atPath: home + "/.cocaine/backup")) ?? []
        check("install: applied: Cocaine's hooks there, the user's own kept, the file's permissions kept, a backup made",
              ok == true && after.contains("cocaine-relay\\\" hook claude done") && after.contains("cocaine-relay\\\" hook claude approve")
              && after.contains("my-own-script.sh") && mode(home + "/.claude/settings.json") == 0o644
              && backups.contains { $0.hasPrefix("_claude_settings_json.") })
        check("install: the host's status reads the hooks as on", wait(10) { m.status[h.id]?.hooksOn == ["claude", "codex"] } && m.store.hosts.first?.hooks == ["claude", "codex"])
        m.review = nil
        m.reviewHooks(h.id)
        wait(20) { m.review != nil }
        check("install: reviewing again finds nothing to change (idempotent)", m.review?.plan.isEmpty == true)
        m.review = nil
        var removed: Bool?
        m.removeHooks(h.id) { removed = $0 }
        wait(20) { removed != nil }
        let back = (try? String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8)) ?? ""
        check("install: removed: the user's file is as it was", removed == true && AIHooks.parse(back) == AIHooks.parse(mine) && !back.contains("cocaine"))
        // Put them back for the rest of the run (the final clean-up removes them again).
        m.reviewHooks(h.id)
        wait(20) { m.review != nil }
        ok = nil
        m.applyReview { ok = $0 }
        wait(20) { ok != nil }
    }
}
