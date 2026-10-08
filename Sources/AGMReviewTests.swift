// --agm-review-test: regression tests for the defects found in the round-7 review of the AI agents and the island's information
// modules (each fails on the code before its fix). Temporary homes and folders, fakes and the real relay behind a fake ssh
// only: never ~/.claude, EventKit, a player, the network or the user's settings.

import AppKit

func cliAGMReviewTest() { exit(AGMReviewTests.run() == 0 ? 0 : 1) }

enum AGMReviewTests {
    typealias Check = (String, Bool) -> Void

    static func run() -> Int {
        _ = NSApplication.shared
        signal(SIGPIPE, SIG_IGN)
        precondition(AppDefaults.isolated, "tests run with memory-only settings (main.swift)")
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  agm: " + name); if !ok { failed += 1 } }
        hooksUnknownVersion(check)
        claudeLookup(check)
        extras(check)
        reminders(check)
        pearLateReply(check)
        relayProtocol(check)
        print(failed == 0 ? "agm: all passed" : "agm: \(failed) failed")
        return failed
    }

    static func spin(_ seconds: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done() { if Date() > end { return false }; RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return true
    }

    // MARK: Claude Code's version unknown: the request hooks already there stay

    /// Before: when `claude --version` timed out (a slow login shell) or wasn't found by a login shell (nvm set up in .zshrc),
    /// the launch's update removed Cocaine's PermissionRequest, Elicitation, PreToolUse and StopFailure hooks.
    static func hooksUnknownVersion(_ check: Check) {
        let home = AgentTests.tempDir()
        let savedHome = AIHooks.home, savedBinary = AIHooks.binary, savedLookup = AIHooks.claudeVersionLookup
        defer {
            AIHooks.home = savedHome; AIHooks.binary = savedBinary; AIHooks.claudeVersionLookup = savedLookup
            AIHooks.assumeClaudeVersion([2, 1, 100])
            try? FileManager.default.removeItem(at: home)
        }
        AIHooks.home = home.path
        AIHooks.binary = "/Applications/Cocaine.app/Contents/MacOS/Cocaine"
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let settings = home.appendingPathComponent(".claude/settings.json").path
        let claude = AIHooks.tool("claude")!
        func events() -> Set<String> { Set(AIHooks.load(settings)?["hooks"]?.members?.map(\.key) ?? []) }
        let versioned: Set<String> = ["PermissionRequest", "Elicitation", "PreToolUse", "StopFailure"]

        AIHooks.assumeClaudeVersion([2, 1, 100])
        _ = AIHooks.set(true, only: [claude])
        check("hooks: a known recent Claude Code gets the request hooks", versioned.isSubset(of: events()))
        let before = (try? String(contentsOfFile: settings, encoding: .utf8)) ?? ""

        var asked = 0
        AIHooks.forgetClaudeVersion()
        AIHooks.claudeVersionLookup = { asked += 1; return nil }          // `claude --version` timed out
        AIHooks.update()
        let after = (try? String(contentsOfFile: settings, encoding: .utf8)) ?? ""
        check("hooks: version timed out at launch: the request hooks stay (the file is unchanged)", versioned.isSubset(of: events()) && after == before)
        check("hooks: …and a timed-out version is asked again later (never cached)", { _ = AIHooks.tool("claude")!.activeEvents; return asked >= 2 }())

        AIHooks.forgetClaudeVersion()
        AIHooks.claudeVersionLookup = { .some(nil) }                      // not found anywhere
        AIHooks.update()
        check("hooks: version not found: the request hooks already there stay", versioned.isSubset(of: events()))

        try? FileManager.default.removeItem(atPath: settings)
        _ = AIHooks.set(true, only: [claude])
        check("hooks: version unknown on a fresh file: the alerts go in, no request hook is guessed",
              events().contains("Stop") && events().isDisjoint(with: versioned))

        AIHooks.assumeClaudeVersion([2, 1, 100])
        _ = AIHooks.set(true, only: [claude])
        AIHooks.assumeClaudeVersion([2, 0, 0])
        _ = AIHooks.set(true, only: [claude])
        check("hooks: a Claude Code known to be older still loses the hooks it doesn't know", events().isDisjoint(with: versioned) && events().contains("Stop"))
        AIHooks.claudeVersionLookup = { .some(nil) }
        AIHooks.forgetClaudeVersion()
        _ = AIHooks.set(false, only: [claude])
        check("hooks: off with the version unknown still removes every hook of Cocaine's", AIHooks.load(settings).map(AIHooks.installed) == false)
    }

    /// Where Claude Code is looked for when a login shell doesn't find it, and the native installer's versions folder.
    static func claudeLookup(_ check: Check) {
        let home = AgentTests.tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        for v in ["v18.20.4", "v22.11.0"] { try? fm.createDirectory(atPath: home.path + "/.nvm/versions/node/\(v)/bin", withIntermediateDirectories: true) }
        let c = AIHooks.claudeCandidates(home: home.path)
        check("lookup: the native installer, the old local install, Homebrew, then nvm's newest node first",
              c.first == home.path + "/.local/bin/claude" && c.contains(home.path + "/.claude/local/claude") && c.contains("/opt/homebrew/bin/claude")
              && (c.firstIndex(of: home.path + "/.nvm/versions/node/v22.11.0/bin/claude") ?? 99) < (c.firstIndex(of: home.path + "/.nvm/versions/node/v18.20.4/bin/claude") ?? 0))
        try? fm.createDirectory(atPath: home.path + "/.local/share/claude/versions", withIntermediateDirectories: true)
        for v in ["2.1.9", "2.1.78", "notes", "2.0.100"] { fm.createFile(atPath: home.path + "/.local/share/claude/versions/" + v, contents: nil) }
        check("lookup: the newest version the native installer keeps (numeric, not text, order)", AIHooks.installedVersions(home: home.path) == [2, 1, 78])
        check("lookup: no versions folder: nothing", AIHooks.installedVersions(home: home.path + "/none") == nil)
        check("lookup: a version is read out of any banner", AIHooks.parseVersion("2.1.100 (Claude Code)\n") == [2, 1, 100] && AIHooks.parseVersion("command not found: claude") == nil)
    }

    // MARK: a session card's details

    /// Before: a later finish without a message kept the turn before's message, and one listing no background tasks kept the
    /// old count ("Done · 1 in the background" for good).
    static func extras(_ check: Check) {
        let x = AgentExtras()
        x.take(session: "s", event: ["kind": "done", "message": "First reply", "background": 2])
        x.take(session: "s", event: ["kind": "start"])
        check("extras: a new prompt keeps what the last finish said (until the next finish)", x["s"]?.message == "First reply" && x["s"]?.background == 2)
        x.take(session: "s", event: ["kind": "done"])
        check("extras: a finish that lists nothing in the background clears the count", x["s"]?.background == 0)
        check("extras: a finish without a message never shows the turn before's", x["s"]?.message == nil)
        x.take(session: "s", event: ["kind": "done", "message": "Second", "background": 1])
        x.take(session: "s", event: ["kind": "input", "notification": "permission_prompt"])
        check("extras: a notification changes neither", x["s"]?.message == "Second" && x["s"]?.background == 1 && x["s"]?.notice == "permission_prompt")
        let e = AgentEntry(id: "s", from: "Claude Code", project: "api", state: "done", since: 0)
        x.take(session: "s", event: ["kind": "done"])
        check("extras: the card's line says no background work after it ended", !AgentListView.stateLine(e, x["s"]).contains(agentsL("%d in the background").replacingOccurrences(of: "%d", with: "")))
    }

    // MARK: reminders ticked here and opened again in Reminders

    /// Before: a reminder completed in the island stayed hidden until the app quit, even after it was opened again elsewhere.
    static func reminders(_ check: Check) {
        let src = FakeReminders(items: [ReminderItem(id: "a", title: "Milk", listID: "home"), ReminderItem(id: "b", title: "Bread", listID: "home")])
        let w = RemindersWatch(defaults: { MemoryDefaults() })
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        w.now = { clock }
        var later: [() -> Void] = []
        w.after = { _, f in later.append(f) }
        w.use(src)
        w.toggle("a")
        later.forEach { $0() }; later = []
        check("reminders: ticked here: saved and gone", src.completed == ["a"] && !w.items.contains { $0.id == "a" })
        w.reload()                                            // EventKit's change notice for that save: it caught up
        src.completed = []                                  // opened again in Reminders (EventKit's change notice reloads)
        w.reload()
        check("reminders: opened again in Reminders: it comes back", w.items.contains { $0.id == "a" } && w.recentlyDone.isEmpty)

        w.toggle("b")
        later.forEach { $0() }; later = []
        let stale = src.items                                 // EventKit hasn't caught up: its next answer still lists it
        let staleSource = FakeReminders(items: stale)
        w.use(staleSource)
        check("reminders: ticked here, EventKit not caught up yet: still hidden", !w.items.contains { $0.id == "b" } && w.recentlyDone["b"] != nil)
        clock = clock.addingTimeInterval(RemindersWatch.catchUp + 1)
        w.reload()
        check("reminders: …and a minute later the source's word counts again", w.items.contains { $0.id == "b" } && w.recentlyDone.isEmpty)
    }

    // MARK: Pear Desktop turned off while an answer is on its way

    /// Before: an answer that came back after the user turned the connection off put the song back on the page and the
    /// client's state back to "ready", with the connection off.
    static func pearLateReply(_ check: Check) {
        var pendingDone: [(PearClient.Reply) -> Void] = []
        let transport: PearClient.Transport = { _, done in pendingDone.append(done) }   // answers only when told to
        let client = PearClient(transport: transport, secrets: MemorySecretStore())
        let w = MusicWatch(pear: client)
        w.scriptsEnabled = false
        w.running = { ["com.github.th-ch.youtube-music"] }
        w.setPear(true)
        check("pear: turned on, a song is asked for", pendingDone.count == 1)
        w.setPear(false)
        let song = #"{"title":"Get Lucky","artist":"Daft Punk","songDuration":369,"elapsedSeconds":61,"isPaused":false,"videoId":"x"}"#
        let answer = pendingDone.removeFirst()
        DispatchQueue.global().async { answer(PearClient.Reply(status: 200, data: Data(song.utf8))) }
        _ = spin(0.5) { false }
        check("pear: an answer after it was turned off doesn't bring the song back", w.track == nil && w.sources.isEmpty)
        check("pear: …nor the client's state (it stays off)", client.status == .off)
        w.setPear(true)
        let next = pendingDone.removeFirst()
        DispatchQueue.global().async { next(PearClient.Reply(status: 200, data: Data(song.utf8))) }
        check("pear: on again, answers count as before", spin(1) { w.track?.title == "Get Lucky" } && client.status == .ready)
        w.setPear(false)
    }

    // MARK: a relay speaking another protocol

    /// Before: a relay whose hello named another protocol (an app updated with a new protocol) was stopped as "outdated" and
    /// never updated (only a different file was), while the card said "Updating the relay…".
    static func relayProtocol(_ check: Check) {
        guard let relay = SSHHostManager.bundledRelay() else { check("relay: the relay is in the app bundle", false); return }
        var tpl = Array("/tmp/cocaine-agm-XXXXXX".utf8CString)
        guard let made = mkdtemp(&tpl) else { check("relay: a temporary folder", false); return }
        let root = String(cString: made)
        let home = root + "/home", support = root + "/support", bin = root + "/bin"
        let fm = FileManager.default
        for d in [home, support, bin] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        defer {
            if let p = SSHTests.servePID(home) { kill(p, SIGCONT); kill(p, SIGKILL) }
            try? fm.removeItem(atPath: root)
        }
        try? SSHTests.fakeSSH.write(toFile: bin + "/ssh", atomically: true, encoding: .utf8)
        chmod(bin + "/ssh", 0o755)
        let m = SSHHostManager()
        m.support = URL(fileURLWithPath: support, isDirectory: true)
        m.keys = SSHMemoryKeys()
        m.sshPath = bin + "/ssh"
        m.environment = ["FAKE_SSH_HOME": home, "PATH": "/usr/bin:/bin", "LANG": "C", "COCAINE_RELAY_NO_LOGIN_SHELL": "1"]
        m.relayScript = relay
        m.watchSystem = false
        m.jitter = { 0 }
        m.tune = { $0.pingEvery = 0.5; $0.pingWait = 2 }
        m.start()
        defer { m.stop() }
        guard case .success(let h) = m.add(alias: "devbox") else { check("relay: a host is added", false); return }
        var deployed: Bool?
        m.deploy(h.id) { deployed = $0 }
        check("relay: installed and connected", spin(25) { deployed == true && m.isUp(h.id) })

        let path = home + "/.cocaine/bin/cocaine-relay"
        func speakOld() {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try? text.replacingOccurrences(of: "my $PROTOCOL = \(SSHWire.protocolVersion);", with: "my $PROTOCOL = 0;").write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o700)
            if let p = SSHTests.servePID(home) { kill(p, SIGKILL) }
        }
        speakOld()
        check("relay: a relay of another protocol is put back to this app's, and connects",
              spin(30) { m.isUp(h.id) && fm.contents(atPath: path) == relay })
        speakOld()                                            // the same again within 10 minutes: no loop of installs
        check("relay: …a second time within 10 minutes it stops and says so (no loop of installs)",
              spin(20) { m.status[h.id]?.phase == .stopped(.relayOutdated) } && fm.contents(atPath: path) != relay)
        let shown = m.host(h.id).map(m.stateText) ?? ""
        check("relay: …in words that don't claim an update is running (\(shown))", shown != L("Updating the relay…") && shown == SSHHostManager.failureText(.relayOutdated))
        m.retry(h.id)
        check("relay: …and the user's Retry updates it", spin(30) { m.isUp(h.id) && fm.contents(atPath: path) == relay })
    }
}
