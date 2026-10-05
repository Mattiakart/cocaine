import AppKit
import Darwin

// Tests for Sources/Recovery.swift: the pure decisions (in --selftest) and --recovery-test, which runs the real engine,
// the real watchdog and real processes against stand-ins in a temporary folder: a fake pmset/sudo keeping SleepDisabled
// in a file, a fake brightness file, and a copy of /bin/sleep standing in for OSDUIHelper. Nothing on this Mac changes
// (the real OSDUIHelper, pmset, brightness and the user's Cocaine are never touched).

enum RecoveryTest {
    /// Pure decisions and the lease file; one `check` line each.
    static func selfChecks(_ check: (String, Bool) -> Void) {
        let now = 1_800_000_000.0
        let l = RecoveryLease(owner: 42, ownerStart: 1, ownsSleep: true, hudFrozen: true,
                              dim: [.init(id: 1, from: 0.8, to: 0.2)], wake: now + 900, handoverUntil: nil)
        check("recovery: a fresh launch has nothing to recover", Recovery.launchPlan(stale: nil, me: 7, ownerAlive: false) == .fresh)
        check("recovery: launch after a crash undoes HUD, dimming and wake and adopts sleep",
              Recovery.launchPlan(stale: l, me: 7, ownerAlive: false) == .recover(.init(hud: true, dim: true, wake: true), adoptSleep: true))
        check("recovery: an alert-only session's lease isn't adopted as sleep",
              { var a = l; a.ownsSleep = false; return Recovery.launchPlan(stale: a, me: 7, ownerAlive: false) == .recover(.init(hud: true, dim: true, wake: true), adoptSleep: false) }())
        check("recovery: a live owner is left alone at launch", Recovery.launchPlan(stale: l, me: 7, ownerAlive: true) == .ownerAlive)
        check("recovery: after exit, everything is undone and sleep released",
              Recovery.afterExit(lease: l, pid: 42, ownerAlive: false, now: now) == .recover(.init(hud: true, dim: true, wake: true), releaseSleep: true))
        check("recovery: after exit, a lease taken over by a new instance is left alone",
              Recovery.afterExit(lease: l, pid: 41, ownerAlive: false, now: now) == .nothing)
        check("recovery: after exit, no lease (clean quit) means nothing to do", Recovery.afterExit(lease: nil, pid: 42, ownerAlive: false, now: now) == .nothing)
        check("recovery: an owner still alive (same start time) is never recovered", Recovery.afterExit(lease: l, pid: 42, ownerAlive: true, now: now) == .nothing)
        var h = l; h.handoverUntil = now + 100
        check("recovery: a pending update hand-over waits", Recovery.afterExit(lease: h, pid: 42, ownerAlive: false, now: now) == .wait)
        check("recovery: an expired hand-over is recovered", Recovery.afterExit(lease: h, pid: 42, ownerAlive: false, now: now + 101) != .wait)
        h.handoverUntil = now + 100_000
        check("recovery: an absurd hand-over deadline doesn't block recovery", Recovery.afterExit(lease: h, pid: 42, ownerAlive: false, now: now) != .wait)
        h.handoverUntil = now + 100
        check("recovery: quit releases sleep", Recovery.quitPlan(lease: l, now: now) == .release)
        check("recovery: quit during an update hand-over keeps sleep", Recovery.quitPlan(lease: h, now: now) == .keepForHandover)
        check("recovery: an alert-only session's quit doesn't touch sleep", { var a = l; a.ownsSleep = false; return Recovery.quitPlan(lease: a, now: now) == .drop }())
        check("recovery: of two instances the earlier one stays, exactly one",
              Recovery.startedFirst(10, 5, than: 20, 6) && !Recovery.startedFirst(20, 6, than: 10, 5)
              && Recovery.startedFirst(10, 5, than: 20, 5) != Recovery.startedFirst(20, 5, than: 10, 5) && !Recovery.startedFirst(10, nil, than: 20, 6))
        check("recovery: brightness still dimmed is restored", Recovery.shouldRestoreBrightness(current: 0.2, from: 0.8, to: 0.2))
        check("recovery: brightness mid-fade is restored", Recovery.shouldRestoreBrightness(current: 0.5, from: 0.8, to: 0.2))
        check("recovery: brightness the user raised is kept", !Recovery.shouldRestoreBrightness(current: 0.9, from: 0.8, to: 0.2))
        check("recovery: brightness the user lowered is kept (the old rule restored it)",
              !Recovery.shouldRestoreBrightness(current: 0.05, from: 0.8, to: 0.2) && Float(0.05) < 0.8)
        check("recovery: brightness already back is left alone", !Recovery.shouldRestoreBrightness(current: 0.8, from: 0.8, to: 0.2))
        // The lease file: round trip and permissions, in a temporary folder.
        let dir = NSTemporaryDirectory() + "cocaine-lease-\(getpid())"
        mkdir(dir, 0o700)
        let saved = getenv("COCAINE_SUPPORT").map { String(cString: $0) }
        setenv("COCAINE_SUPPORT", dir, 1)
        let path = dir + "/recovery.json"
        umask(0o022)
        let ok = Recovery.writeLease(l)
        check("recovery: the lease survives a round trip", ok && Recovery.readLease() == l)
        var st = stat()
        check("recovery: the lease file is private (0600)", stat(path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        let json = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
        check("recovery: the lease has the fields the zsh fallback reads", json.contains("\"owner\":42,") && json.contains("\"hudFrozen\":true") && json.contains("\"ownsSleep\":true"))
        check("recovery: no temporary file is left next to it", (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { $0.hasPrefix("recovery.json.") }.isEmpty == true)
        Recovery.removeLease()
        check("recovery: a missing lease reads as none", Recovery.readLease() == nil)
        try? FileManager.default.removeItem(atPath: dir)
        if let saved { setenv("COCAINE_SUPPORT", saved, 1) } else { unsetenv("COCAINE_SUPPORT") }
    }

    // MARK: - The stand-in app for --recovery-test

    /// `--recovery-owner [on] [hud] [wake <epoch>] [dim id:from:to]…`: behaves like the app's session (instance lock, lease,
    /// real watchdog, heartbeat) and quits like the app on SIGTERM.
    static func owner(_ args: [String]) -> Never {
        let wait = Double(Recovery.env["COCAINE_INSTANCE_WAIT"] ?? "") ?? 10
        guard Recovery.claimSingleInstance(wait: wait, runningApps: false) else { exit(3) }
        RecoverySession.shared.start(ownsSleep: true)
        var i = 0, dims: [RecoveryLease.Dim] = []
        while i < args.count {
            switch args[i] {
            case "on": _ = Recovery.runQuiet("/bin/zsh", [Recovery.enginePath, "on"])
            case "hud": RecoverySession.shared.noteHUD(true)
            case "wake": i += 1; RecoverySession.shared.noteWake(Double(args[i]))
            case "dim":
                i += 1
                let f = args[i].split(separator: ":").compactMap { Float($0) }
                dims.append(.init(id: UInt32(f[0]), from: f[1], to: f[2]))
            default: break
            }
            i += 1
        }
        if !dims.isEmpty { RecoverySession.shared.noteDim(dims) }
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler {
            RecoverySession.shared.noteHUD(false); RecoverySession.shared.noteDim([]); RecoverySession.shared.noteWake(nil)
            RecoverySession.shared.end()
            exit(0)
        }
        src.resume()
        FileManager.default.createFile(atPath: (Recovery.env["COCAINE_TEST_DIR"] ?? "/tmp") + "/ready.\(getpid())", contents: nil)
        withExtendedLifetime(src) { RunLoop.main.run() }
        exit(0)
    }

    // MARK: - --recovery-test

    static func run() -> Int32 {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  " + name); fflush(stdout); if !ok { failed += 1 } }
        guard let bin = Bundle.main.executablePath, FileManager.default.fileExists(atPath: Recovery.enginePath) else {
            print("FAIL  recovery: run it from the built app (needs Contents/Resources/cocaine)"); return 1
        }
        var tbuf = Array("/tmp/cocaine-recovery-test.XXXXXX".utf8CString)
        guard mkdtemp(&tbuf) != nil else { return 1 }
        let T = URL(fileURLWithPath: String(cString: tbuf)).resolvingSymlinksInPath().path
        let support = T + "/support", flagFile = T + "/flag", bright = T + "/bright", pmlog = T + "/pmset.log"
        mkdir(support, 0o700); mkdir(T + "/bin", 0o755)
        func put(_ path: String, _ text: String, mode: Int = 0o644) {
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
        }
        put(T + "/bin/pmset", """
        #!/bin/zsh
        F=\(T)/flag
        case "$1" in
          -g) [[ -e \(T)/unreadable ]] && exit 1; print "System-wide power settings:"; print " SleepDisabled\\t\\t$(<$F)" ;;
          -a) [[ $2 == disablesleep && ( $3 == 0 || $3 == 1 ) ]] || exit 1
              print -r -- $3 > $F
              v=FAKE_PMSET_DELAY_$3; /bin/sleep ${(P)v:-0} ;;
          schedule) print -r -- "$*" >> \(pmlog) ;;
          *) exit 1 ;;
        esac

        """, mode: 0o755)
        put(T + "/bin/sudo", "#!/bin/zsh\n[[ $1 == -n ]] && shift\n[[ -e \(T)/noauth ]] && exit 1\nexec \"$@\"\n", mode: 0o755)
        let standInName = "OSDStandIn"
        // A copy of this binary (`--recovery-standin` just sleeps): a copied /bin/sleep is killed by macOS (platform binary).
        _ = try? FileManager.default.copyItem(atPath: bin, toPath: T + "/" + standInName)
        let env: [String: String] = ["COCAINE_SUPPORT": support, "COCAINE_PMSET": T + "/bin/pmset", "COCAINE_SUDO": T + "/bin/sudo",
                                     "COCAINE_HUD_NAME": standInName, "COCAINE_FAKE_BRIGHTNESS": bright, "COCAINE_TEST_DIR": T,
                                     "COCAINE_HEARTBEAT": "0.5", "COCAINE_WATCH_STALL": "4"]
        for (k, v) in env { setenv(k, v, 1) }              // before Recovery.env is first read; children inherit them
        let engine = Recovery.enginePath
        let engineRE = engine.replacingOccurrences(of: "([\\[\\]\\\\.^$*+?(){}|])", with: "\\\\$1", options: .regularExpression)

        func flag() -> String { ((try? String(contentsOfFile: flagFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func setFlag(_ v: String) { put(flagFile, v + "\n") }
        func sh(_ args: [String], env extra: [String: String] = [:]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
            p.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return -1 }
            p.waitUntilExit(); return p.terminationStatus
        }
        func eng(_ a: String, env extra: [String: String] = [:]) -> Int32 { sh(["/bin/zsh", engine, a], env: extra) }
        func pids(_ pattern: String) -> [pid_t] {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-U", String(getuid()), "-xf", pattern]
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
        }
        func holdRunning() -> Bool { !pids("/bin/zsh \(engineRE) hold").isEmpty }
        func watchdogs(_ owner: pid_t? = nil) -> [pid_t] { pids("/bin/zsh \(engineRE) watch \(owner.map(String.init) ?? "[0-9]+") .*") }
        func alive(_ pid: pid_t) -> Bool {
            var info = proc_bsdinfo()
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 && info.pbi_status != UInt32(SZOMB)
        }
        func stopped(_ pid: pid_t) -> Bool {
            var info = proc_bsdinfo()
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 && info.pbi_status == UInt32(SSTOP)
        }
        @discardableResult
        func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if cond() { return true }; usleep(100_000) }
            return cond()
        }
        func sig(_ pid: pid_t, _ s: Int32) { if pid > 1 { kill(pid, s) } }   // never 0 or -1 (that would hit this test itself)
        var spawned: [Process] = []
        func standIn(stop: Bool = true) -> pid_t {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: T + "/" + standInName); p.arguments = ["--recovery-standin"]
            try? p.run(); spawned.append(p)
            if stop { sig(p.processIdentifier, SIGSTOP); waitFor(2) { stopped(p.processIdentifier) } }
            return p.processIdentifier
        }
        func owner(_ args: [String], env extra: [String: String] = [:], ready: Bool = true) -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin); p.arguments = ["--recovery-owner"] + args
            p.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); spawned.append(p)
            if ready { waitFor(15) { FileManager.default.fileExists(atPath: T + "/ready.\(p.processIdentifier)") } }
            return p
        }
        func lease() -> RecoveryLease? { Recovery.readLease() }
        func claim() -> String? { (try? String(contentsOfFile: support + "/sleep-claim", encoding: .utf8)).map { String($0.prefix(7)) } }
        func reset() {
            for w in watchdogs() { sig(w, SIGKILL) }
            _ = eng("off")
            for p in spawned where p.isRunning { sig(p.processIdentifier, SIGKILL) }
            spawned.removeAll()
            for f in ["recovery.json", "sleep-claim"] { unlink(support + "/" + f) }
            setFlag("0"); put(pmlog, "")
            unlink(T + "/unreadable"); unlink(T + "/noauth")
        }
        defer {
            reset()
            try? FileManager.default.removeItem(atPath: T)
        }
        setFlag("0")

        // 1. The engine's sleep claim, through the real script: every claim × current state.
        do {
            check("engine: first ON records prior=0 when sleep was allowed", eng("on") == 0 && flag() == "1" && claim() == "prior=0")
            check("engine: a second ON keeps the first claim", eng("on") == 0 && claim() == "prior=0")
            check("engine: OFF clears the claim and the hold", eng("off") == 0 && flag() == "0" && claim() == nil && waitFor(3) { !holdRunning() })
            setFlag("1")
            check("engine: ON when already disabled by someone else records prior=1", eng("on") == 0 && claim() == "prior=1")
            _ = eng("release"); reset()
            let table: [(String?, String, String)] = [   // claim, flag now → flag after release
                ("prior=0", "1", "0"), ("prior=0", "0", "0"), ("prior=1", "1", "1"), ("prior=1", "0", "0"), (nil, "1", "1"), (nil, "0", "0")]
            for (c, now, want) in table {
                if let c { put(support + "/sleep-claim", c + " since=0\n", mode: 0o600) } else { unlink(support + "/sleep-claim") }
                setFlag(now)
                let r = eng("release")
                check("engine: release with \(c ?? "no claim") and SleepDisabled=\(now) leaves \(want)", r == 0 && flag() == want && claim() == nil)
            }
            put(support + "/sleep-claim", "prior=0 since=0\n", mode: 0o600); setFlag("1"); put(T + "/unreadable", "")
            check("engine: release with pmset unreadable fails (4) and keeps the claim", eng("release") == 4 && claim() == "prior=0" && flag() == "1")
            unlink(T + "/unreadable"); put(T + "/noauth", "")
            check("engine: release not authorized fails (2) and keeps the claim", eng("release") == 2 && claim() == "prior=0" && flag() == "1")
            unlink(T + "/noauth")
            check("engine: forget keeps the claim while sleep is still disabled", eng("forget") == 0 && claim() == "prior=0")
            setFlag("0")
            check("engine: forget drops it once sleep was turned back on from outside", eng("forget") == 0 && claim() == nil)
            reset()
        }

        // 2. on/off from two places at once (app and iPhone): an OFF that writes first but stops the hold late must not
        //    kill the hold of an ON that ran in between. Fails without the lock.
        do {
            func race(nolock: Bool) -> Bool {   // true = consistent end state
                reset()
                var extra = ["FAKE_PMSET_DELAY_0": "1.0"]
                if nolock { extra["COCAINE_NOLOCK"] = "1" }
                let off = Process(); off.executableURL = URL(fileURLWithPath: "/bin/zsh"); off.arguments = [engine, "off"]
                off.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
                setFlag("1")
                try? off.run()
                usleep(150_000)
                _ = eng("on", env: extra)
                off.waitUntilExit()
                usleep(300_000)
                return (flag() == "1") == holdRunning()
            }
            check("engine: without the lock the race is real (ON's hold killed by a concurrent OFF)", !race(nolock: true))
            check("engine: with the lock on/off from two places end consistent", race(nolock: false) && race(nolock: false))
            reset()
        }

        // 3. Crash (kill -9): the real watchdog undoes everything; brightness the user changed since is kept.
        do {
            let s1 = standIn(), s2 = standIn(stop: false)
            let wake = Date().timeIntervalSince1970 + 900
            let o = owner(["on", "hud", "wake", String(wake), "dim", "1:0.8:0.2", "dim", "2:0.7:0.2", "dim", "3:0.6:0.2"])
            put(bright, "1 0.2\n2 0.9\n3 0.05\n")          // 1 still dimmed; 2 raised and 3 lowered by the user since
            check("crash: the stand-in HUD helpers run (one frozen)", stopped(s1) && alive(s2) && !stopped(s2))
            check("crash: the session is set up (sleep off, hold, lease, watchdog)",
                  flag() == "1" && holdRunning() && lease()?.owner == o.processIdentifier && lease()?.hudFrozen == true && watchdogs(o.processIdentifier).count == 1)
            sig(o.processIdentifier, SIGKILL)
            check("crash: the watchdog clears the lease", waitFor(15) { lease() == nil })
            check("crash: sleep is allowed again (it was before)", flag() == "0" && claim() == nil)
            check("crash: the display-hold helper is gone", waitFor(4) { !holdRunning() })
            check("crash: the frozen HUD helper is ended (launchd restarts it on demand)", waitFor(3) { !alive(s1) })
            check("crash: a HUD helper that wasn't frozen is left alone", alive(s2))
            check("crash: the still-dimmed screen is restored", Recovery.brightness.get(1) == 0.8)
            check("crash: brightness the user changed since is kept", Recovery.brightness.get(2) == 0.9 && Recovery.brightness.get(3) == 0.05)
            check("crash: the scheduled wake is cancelled",
                  ((try? String(contentsOfFile: pmlog, encoding: .utf8)) ?? "").contains("schedule cancel wake \(Recovery.wakeString(wake)) cocaine"))
            check("crash: the watchdog ends", waitFor(5) { watchdogs(o.processIdentifier).isEmpty })
            reset()
        }

        // 4. Sleep already disabled before Cocaine (by the user or another app): a crash leaves it disabled.
        do {
            setFlag("1")
            let o = owner(["on"])
            check("prior state: the claim says it was already disabled", claim() == "prior=1")
            sig(o.processIdentifier, SIGKILL)
            check("prior state: after the crash SleepDisabled is still 1, the helper gone",
                  waitFor(15) { lease() == nil } && flag() == "1" && waitFor(4) { !holdRunning() } && claim() == nil)
            reset()
        }

        // 5. Normal quit (SIGTERM, as from the Quit button or pkill): release, nothing left.
        do {
            let o = owner(["on"])
            sig(o.processIdentifier, SIGTERM)
            check("quit: SleepDisabled back to 0, no lease, no helper, watchdog ends",
                  waitFor(10) { !o.isRunning } && flag() == "0" && lease() == nil && waitFor(4) { !holdRunning() } && waitFor(5) { watchdogs(o.processIdentifier).isEmpty })
            reset()
        }

        // 6. Update hand-over adopted by the new version: sleep stays on throughout.
        do {
            check("update: --prepare-update with no running app does nothing", sh([bin, "--prepare-update"]) == 0 && lease() == nil)
            let o1 = owner(["on"])
            check("update: --prepare-update marks the running session", sh([bin, "--prepare-update"]) == 0 && lease()?.handoverUntil != nil)
            sig(o1.processIdentifier, SIGTERM)
            waitFor(10) { !o1.isRunning }
            usleep(2_500_000)
            check("update: after the old version quits, sleep stays disabled and the lease waits",
                  flag() == "1" && lease()?.owner == o1.processIdentifier && !watchdogs(o1.processIdentifier).isEmpty)
            let o2 = owner([])
            check("update: the new version adopts the session", lease()?.owner == o2.processIdentifier && lease()?.ownsSleep == true && flag() == "1")
            check("update: the old watchdog ends without touching sleep", waitFor(5) { watchdogs(o1.processIdentifier).isEmpty } && flag() == "1")
            sig(o2.processIdentifier, SIGTERM)
            check("update: quitting the new version releases as usual", waitFor(10) { !o2.isRunning } && flag() == "0" && lease() == nil)
            reset()
        }

        // 7. Hand-over that nobody takes (the update failed): released when it expires.
        do {
            let short = ["COCAINE_HANDOVER_SECONDS": "3"]
            let o = owner(["on"], env: short)
            _ = sh([bin, "--prepare-update"], env: short)
            sig(o.processIdentifier, SIGTERM)
            waitFor(10) { !o.isRunning }
            check("update: an unclaimed hand-over keeps sleep only until it expires", flag() == "1")
            check("update: …then the watchdog releases it", waitFor(15) { lease() == nil } && flag() == "0")
            reset()
        }

        // 8. The app hangs (no heartbeat): the HUD is given back, the rest stays.
        do {
            let s = standIn()
            let o = owner(["on", "hud"])
            sig(o.processIdentifier, SIGSTOP)
            check("hang: the frozen HUD helper is ended while the app is stuck", waitFor(12) { !alive(s) })
            check("hang: sleep and lease are untouched", flag() == "1" && lease()?.owner == o.processIdentifier)
            sig(o.processIdentifier, SIGCONT)
            sig(o.processIdentifier, SIGTERM)
            check("hang: after it recovers, quitting still cleans up", waitFor(10) { !o.isRunning } && flag() == "0" && lease() == nil)
            reset()
        }

        // 9. SIGTERM to the watchdog while the app runs: it leaves quietly and the app starts another.
        do {
            let o = owner(["on"])
            let w1 = watchdogs(o.processIdentifier).first ?? 0
            sig(w1, SIGTERM)
            check("watchdog: SIGTERM with the app alive changes nothing", waitFor(5) { !alive(w1) } && flag() == "1" && lease()?.owner == o.processIdentifier)
            check("watchdog: the app starts a new one", waitFor(15) { watchdogs(o.processIdentifier).contains { $0 != w1 } })
            sig(o.processIdentifier, SIGKILL)
            check("watchdog: the new one recovers a crash", waitFor(15) { lease() == nil } && flag() == "0")
            reset()
        }

        // 10. App and watchdog killed together: the next launch recovers (and adopts sleep); uninstall cleans up.
        do {
            let s = standIn()
            let o = owner(["on", "hud"])
            for w in watchdogs(o.processIdentifier) { sig(w, SIGKILL) }
            sig(o.processIdentifier, SIGKILL)
            usleep(500_000)
            check("both killed: the lease stays behind (nothing could act)", lease()?.owner == o.processIdentifier && stopped(s))
            let o2 = owner([])
            check("both killed: the next launch ends the frozen HUD helper", waitFor(3) { !alive(s) })
            check("both killed: the next launch adopts sleep (the session goes on)", flag() == "1" && lease()?.owner == o2.processIdentifier && lease()?.ownsSleep == true)
            check("one at a time: a second instance gives up", owner([], env: ["COCAINE_INSTANCE_WAIT": "1"], ready: false).waitUntilExitStatus(8) == 3
                  && lease()?.owner == o2.processIdentifier)
            check("uninstall: refused (75) while Cocaine runs; its lease and sleep untouched",
                  sh([bin, "--uninstall-cleanup"], env: ["COCAINE_INSTANCE_WAIT": "1"]) == 75 && lease()?.owner == o2.processIdentifier && flag() == "1")
            let s2 = standIn()
            RecoveryTestHelpers.markHUD(support)                // as if o2 had frozen it
            for w in watchdogs(o2.processIdentifier) { sig(w, SIGKILL) }
            sig(o2.processIdentifier, SIGKILL)
            usleep(300_000)
            check("uninstall: cleanup ends the frozen HUD helper, releases sleep, stops the helper",
                  sh([bin, "--uninstall-cleanup"]) == 0 && waitFor(3) { !alive(s2) } && flag() == "0" && waitFor(4) { !holdRunning() })
            let left = ["recovery.json", "recovery.lock", "sleep-claim", "state.lock", "hold.lock", "instance.lock"].filter { FileManager.default.fileExists(atPath: support + "/" + $0) }
            check("uninstall: no Cocaine state files left (\(left.joined(separator: ", ")))", left.isEmpty)
            reset()
        }

        // 11. A damaged lease (disk trouble, a much newer version's): the HUD still comes back, and sleep is released through
        //     the claim by the watchdog; at launch the frozen HUD is ended too.
        do {
            let s = standIn()
            _ = eng("on")
            put(support + "/recovery.json", "{\"owner\":", mode: 0o600)
            check("damaged lease: the watchdog ends the frozen HUD and releases sleep (claim prior=0)",
                  sh([bin, "--recover-after", "99999"]) == 0 && waitFor(3) { !alive(s) } && flag() == "0" && !FileManager.default.fileExists(atPath: support + "/recovery.json"))
            reset()
            let s2 = standIn()
            put(support + "/recovery.json", "garbage", mode: 0o600)
            let o = owner([])
            check("damaged lease: the next launch ends the frozen HUD and starts a good lease", waitFor(3) { !alive(s2) } && lease()?.owner == o.processIdentifier)
            reset()
        }

        check("recovery-test: no test process left behind", watchdogs().isEmpty && !holdRunning())
        return failed == 0 ? 0 : 1
    }
}

enum RecoveryTestHelpers {
    static func markHUD(_ support: String) {
        guard var l = Recovery.readLease() else { return }
        l.hudFrozen = true
        Recovery.writeLease(l)
    }
}

private extension Process {
    /// Exit status, or -1 if it is still running after `seconds` (then it is killed).
    func waitUntilExitStatus(_ seconds: Double) -> Int32 {
        let end = Date().addingTimeInterval(seconds)
        while isRunning && Date() < end { usleep(100_000) }
        if isRunning { kill(processIdentifier, SIGKILL); waitUntilExit(); return -1 }
        return terminationStatus
    }
}
