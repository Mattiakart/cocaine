// --awake-test: the keep-awake extras' rules (Sources/AwakeTime.swift, AwakeTriggers.swift), the scripting dictionary
// (Sources/Scripting.swift: ScriptingTests) and the Mac Shortcuts pack (Sources/AwakeShortcuts.swift). Fakes only: no
// network interface, process, folder, audio device or setting of the user's is read or changed (settings are in memory).

import AppKit

/// Fixed readings for the new triggers.
struct FakeAwakeProbe: AwakeProbe {
    var ifs: [NetInterface] = []
    var ticks: CPUTicks? = nil
    var output: String? = nil
    var volumes: [String] = []
    var usb: [String] = []
    func interfaces() -> [NetInterface] { ifs }
    func cpuTicks() -> CPUTicks? { ticks }
    func defaultOutput() -> String? { output }
    func mountedVolumes() -> [String] { volumes }
    func usbDevices() -> [String] { usb }
}

enum AwakeTests {
    static func run() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  awake: " + name); if !ok { failed += 1 } }
        untilTests(check)
        triggerTests(check)
        sessionTests(check)
        optionTests(check)
        ScriptingTests.run(check)
        AwakeShortcutTests.run(check)
        print(failed == 0 ? "awake: all passed" : "awake: \(failed) failed")
        return failed
    }

    static var rome: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Rome")!; return c }

    // MARK: Until a time (the same epochs as tests/engine-test.zsh)

    static func untilTests(_ check: (String, Bool) -> Void) {
        let cal = rome
        func at(_ s: String, _ now: TimeInterval) -> TimeInterval? { UntilTime.parse(s, now: Date(timeIntervalSince1970: now), calendar: cal)?.timeIntervalSince1970 }
        let noon: TimeInterval = 1791367200                       // 2026-10-07 12:00 in Rome
        check("until 18:30 at noon is today's 18:30", at("18:30", noon) == 1791390600)
        check("until 18.30 (a dot) and spaces around are read", at(" 18.30 ", noon) == 1791390600)
        check("until 08:00 tomorrow", at("08:00 tomorrow", noon) == 1791439200)
        check("until 11:00 (passed today) is tomorrow's", at("11:00", noon) == 1791439200 + 3 * 3600)
        check("until 11:00 today (passed) is refused", at("11:00 today", noon) == nil)
        check("until 00:10 at 23:50: past midnight, 20 minutes", at("00:10", 1791409800) == 1791411000)
        check("until 22:00 across the October DST change: 23.5 h", at("22:00", 1792877400) == 1792962000)
        check("until 23:00 across it would be 24.5 h: refused", at("23:00", 1792877400) == nil)
        check("until 02:30 on the March jump day: 03:30, like the engine", at("02:30", 1806192000) == 1806197400)
        check("until a local ISO time", at("2026-10-07T18:30", noon) == 1791390600)
        check("until an ISO time with its zone", at("2026-10-07T16:30:00Z", noon) == 1791390600 && at("2026-10-07T18:30:00+02:00", noon) == 1791390600)
        for bad in ["25:00", "18:60", "18:30 yesterday", "2027-03-28T02:30", "2026-04-31T10:00", "2026-10-07T11:00", "2026-10-09T10:00",
                    "$(id)", "18:30;id", "", "1830", "tomorrow", String(repeating: "1", count: 50)] {
            check("until '\(bad.prefix(20))' refused", at(bad, noon) == nil)
        }
        check("minutes left round up", UntilTime.minutesLeft(Date(timeIntervalSince1970: noon + 61), now: Date(timeIntervalSince1970: noon)) == 2)
        check("HH:MM for the engine", UntilTime.hhmm(Date(timeIntervalSince1970: 1791390600), calendar: cal) == "18:30")

        func parse(_ s: String) -> Result<ControlRequest, ControlURL.Failure> {
            ControlURL.parse(URL(string: s)!, now: Date(timeIntervalSince1970: noon), calendar: cal)
        }
        check("link: on?until=18:30 carries the deadline", (try? parse("cocaine://on?until=18:30").get())?.until?.timeIntervalSince1970 == 1791390600
              && (try? parse("cocaine://on?until=18:30").get())?.action == .on(minutes: nil))
        check("link: x-callback on?until=08%3A00%20tomorrow", (try? parse("cocaine://x-callback-url/on?until=08%3A00%20tomorrow").get())?.until?.timeIntervalSince1970
              == 1791439200)
        check("link: 18:30 tomorrow (30.5 h away) is refused", (try? parse("cocaine://on?until=18%3A30%20tomorrow").get()) == nil)
        check("link: until with minutes too is refused", (try? parse("cocaine://on?minutes=5&until=18:30").get()) == nil)
        check("link: until on anything but on is refused", ["off", "toggle", "timer", "pause", "status"].allSatisfy { (try? parse("cocaine://\($0)?until=18:30").get()) == nil })
        if case .failure(let f) = parse("cocaine://on?until=99:99") { check("link: a bad time says badUntil", f == .badUntil) } else { check("link: a bad time says badUntil", false) }
        check("link: plain on has no deadline", (try? parse("cocaine://on").get())?.until == nil)
        check("defaultUntil: on the half hour, two hours ahead", AwakeModel.defaultUntil(Date(timeIntervalSince1970: noon + 600), calendar: cal) == 14 * 60 + 30)
    }

    // MARK: The new triggers

    static func triggerTests(_ check: (String, Bool) -> Void) {
        func i(_ n: String, up: Bool = true, v4: Bool = false, v6: Bool = false) -> NetInterface { NetInterface(name: n, up: up, ipv4: v4, routableIPv6: v6) }
        check("vpn: macOS's own utun interfaces (link-local only) aren't a VPN", !VPNRule.connected([i("utun0"), i("utun1"), i("en0", v4: true)]))
        check("vpn: a utun with an IPv4 address is (WireGuard, Tailscale…)", VPNRule.connected([i("utun0"), i("utun4", v4: true)]))
        check("vpn: ipsec and ppp count, with a routable IPv6 too", VPNRule.connected([i("ipsec0", v4: true)]) && VPNRule.connected([i("ppp0", v6: true)]))
        check("vpn: down, or a name that only starts the same, doesn't", !VPNRule.connected([i("utun3", up: false, v4: true)]) && !VPNRule.connected([i("utunx", v4: true)])
              && !VPNRule.connected([i("tunnelbear", v4: true)]))

        var cpu = CPURule()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func s(_ busy: UInt64, _ total: UInt64, _ secs: Double, rule: String = "above") -> Bool? {
            cpu.step(rule: rule, percent: 50, minutes: 2, ticks: CPUTicks(busy: busy, total: total), now: t0.addingTimeInterval(secs))
        }
        check("cpu: off is nil (no state for the arbiter)", cpu.step(rule: "", percent: 50, minutes: 2, ticks: nil, now: t0) == nil)
        _ = s(0, 0, 0)
        check("cpu: busy, but not for 2 minutes yet", s(80, 100, 5) == false && s(160, 200, 60) == false)
        check("cpu: busy for 2 minutes: true", s(240, 300, 125) == true)
        check("cpu: one quiet sample ends the stretch", s(250, 400, 130) == false && s(330, 500, 135) == false)
        check("cpu: and it needs the full minutes again", s(410, 600, 200) == false && s(490, 700, 256) == true)
        check("cpu: the last load is kept (80 %)", cpu.load.map { abs($0 - 0.8) < 0.001 } == true)
        var quiet = CPURule()
        _ = quiet.step(rule: "below", percent: 25, minutes: 1, ticks: CPUTicks(busy: 0, total: 0), now: t0)
        check("cpu below 25 % for a minute", quiet.step(rule: "below", percent: 25, minutes: 1, ticks: CPUTicks(busy: 10, total: 100), now: t0.addingTimeInterval(5)) == false
              && quiet.step(rule: "below", percent: 25, minutes: 1, ticks: CPUTicks(busy: 20, total: 200), now: t0.addingTimeInterval(66)) == true)
        check("cpu: an unreadable sample is false, not on", quiet.step(rule: "below", percent: 25, minutes: 1, ticks: nil, now: t0.addingTimeInterval(70)) == false)

        var set = AwakeTriggerSet()
        let probe = FakeAwakeProbe(ifs: [i("utun5", v4: true)], ticks: nil, output: "Mattia's AirPods Pro", volumes: ["Backup", "Photos"], usb: ["Studio Display", "YubiKey"])
        let none = set.states(AwakeTriggerConfig(), probe: probe, now: t0)
        check("set: nothing enabled, nothing reported (the arbiter sees only what is on)", none.isEmpty)
        let c = AwakeTriggerConfig(vpn: true, audio: ["airpods"], volumes: ["backup"], usb: ["Keyboard"])
        let st = set.states(c, probe: probe, now: t0)
        check("set: VPN, audio (part of the name, any case), volume true; USB device absent false",
              st == [.vpn: true, .audio: true, .volume: true, .usb: false])
        check("set: the words say what it was", AwakeTriggerSet.words(st, c, probe: probe) == [L("VPN"), "Mattia's AirPods Pro", "backup"])
        check("set: count of enabled", c.count == 4 && AwakeTriggerConfig().count == 0)
        check("set: no default output → audio false", set.states(AwakeTriggerConfig(audio: ["x"]), probe: FakeAwakeProbe(), now: t0) == [.audio: false])

        var arb = TriggerArbiter()
        check("arbiter: All with a new kind false is off", arb.evaluate([.vpn: true, .usb: false], all: true).active == false)
        _ = arb.evaluate([.vpn: true, .cpu: true], all: false)
        check("arbiter: when they end, Any waits the longest grace (CPU's 60 s)", arb.evaluate([.vpn: false, .cpu: false], all: false).grace == 60)
        check("graces: VPN/audio/volume/USB 30 s, CPU 60 s", [TriggerKind.vpn, .audio, .volume, .usb].allSatisfy { $0.grace == 30 } && TriggerKind.cpu.grace == 60)
        check("lists: cleaned, no repeats (any case), no control characters, at most 20",
              AwakeLists.clean(["A", "a", " B ", "C\u{0}D", ""] + (0..<30).map { "n\($0)" }) == ["A", "B", "CD"] + (0..<17).map { "n\($0)" })
    }

    // MARK: Keep awake while…

    static func sessionTests(_ check: (String, Bool) -> Void) {
        var w = WhileWatch()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        check("while: alive is nothing", w.step(alive: true, kind: .process, now: t0) == .none)
        check("while: a process gone ends it 2 s later", w.step(alive: false, kind: .process, now: t0) == .none && w.step(alive: false, kind: .process, now: t0.addingTimeInterval(2)) == .end)
        w.reset()
        check("while: downloads wait a minute between files", w.step(alive: false, kind: .downloads, now: t0) == .none
              && w.step(alive: true, kind: .downloads, now: t0.addingTimeInterval(30)) == .none
              && w.step(alive: false, kind: .downloads, now: t0.addingTimeInterval(40)) == .none
              && w.step(alive: false, kind: .downloads, now: t0.addingTimeInterval(99)) == .none
              && w.step(alive: false, kind: .downloads, now: t0.addingTimeInterval(100)) == .end)

        var d = DownloadActivity()
        typealias E = DownloadActivity.Entry
        check("downloads: unreadable is unknown (nil), not 'finished'", d.sample(nil) == nil)
        check("downloads: a browser's partial file is a download", d.sample([E(name: "a.zip.crdownload", size: 10)]) == true)
        check("downloads: a file that grew since the last look is too", d.sample([E(name: "b.iso", size: 10)]) == false && d.sample([E(name: "b.iso", size: 20)]) == true)
        check("downloads: still, and finished files, are not", d.sample([E(name: "b.iso", size: 20), E(name: "c.pdf", size: 5)]) == false)
        check("downloads: Safari's .download and Firefox's .part", d.sample([E(name: "x.download", size: 0)]) == true && d.sample([E(name: "y.part", size: 1)]) == true)

        let me = ProcessInfoReader.info(getpid())
        check("process: this test reads its own pid, name and start", me != nil && me?.pid == getpid() && (me?.started ?? 0) > 0)
        let t = WhileTarget(kind: .process, pid: getpid(), started: me?.started ?? 0, name: "x")
        check("process: alive while the same process runs", ProcessInfoReader.alive(t))
        check("process: a reused pid (another start time) is not the same process", !ProcessInfoReader.alive(WhileTarget(kind: .process, pid: getpid(), started: 1, name: "x")))
        check("process: a pid that isn't there", !ProcessInfoReader.alive(t, lookup: { _ in nil }) && ProcessInfoReader.info(-1) == nil)
        check("process: the picker lists this user's processes, not Cocaine itself", { let l = ProcessInfoReader.pickable(); return !l.isEmpty && !l.contains { $0.pid == getpid() } }())
        let data = try? JSONEncoder().encode(t)
        check("while: the target survives a restart (JSON)", data.flatMap { try? JSONDecoder().decode(WhileTarget.self, from: $0) } == t)
    }

    // MARK: Unplugged, locked, launch, clicks, icons, settings

    static func optionTests(_ check: (String, Bool) -> Void) {
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        var u = UnplugGuard()
        check("unplug: already on battery at start: no unplugging seen, nothing happens",
              !u.step(delay: 10, onAC: false, on: true, now: t0) && !u.step(delay: 10, onAC: false, on: true, now: t0.addingTimeInterval(60)))
        _ = u.step(delay: 10, onAC: true, on: true, now: t0.addingTimeInterval(70))
        check("unplug: a wiggle (back within the delay) does nothing", !u.step(delay: 10, onAC: false, on: true, now: t0.addingTimeInterval(80))
              && !u.step(delay: 10, onAC: true, on: true, now: t0.addingTimeInterval(85)))
        _ = u.step(delay: 10, onAC: false, on: true, now: t0.addingTimeInterval(100))
        check("unplug: off once the delay has passed, whoever turned it on", u.step(delay: 10, onAC: false, on: true, now: t0.addingTimeInterval(110)))
        check("unplug: turned on again on battery: respected", !u.step(delay: 10, onAC: false, on: true, now: t0.addingTimeInterval(200)))
        var u2 = UnplugGuard()
        _ = u2.step(delay: 0, onAC: true, on: true, now: t0); _ = u2.step(delay: 0, onAC: false, on: true, now: t0)
        check("unplug: the option off (0) never acts", !u2.step(delay: 0, onAC: false, on: true, now: t0.addingTimeInterval(1000)))
        var u3 = UnplugGuard()
        _ = u3.step(delay: 10, onAC: true, on: false, now: t0); _ = u3.step(delay: 10, onAC: false, on: false, now: t0)
        check("unplug: off already: nothing to do, and turning it on later on battery stays on",
              !u3.step(delay: 10, onAC: false, on: false, now: t0.addingTimeInterval(20)) && !u3.step(delay: 10, onAC: false, on: true, now: t0.addingTimeInterval(30)))

        var l = LockPause()
        let until = t0.addingTimeInterval(3600)
        check("lock: off without the option", l.lock(enabled: false, on: true, triggerOwned: false, until: nil) == .none && !l.blocksTriggers)
        check("lock: an ON by hand pauses…", l.lock(enabled: true, on: true, triggerOwned: false, until: until) == .turnOff && l.blocksTriggers)
        check("lock: …a second lock notice changes nothing", l.lock(enabled: true, on: false, triggerOwned: false, until: nil) == .none)
        check("lock: …and comes back at the unlock with its deadline", l.unlock(now: t0.addingTimeInterval(60)) == .turnOn(until: until) && !l.blocksTriggers)
        _ = l.lock(enabled: true, on: true, triggerOwned: false, until: until)
        check("lock: not when its time ran out while locked", l.unlock(now: until) == .none)
        _ = l.lock(enabled: true, on: true, triggerOwned: true, until: nil)
        check("lock: a trigger's ON is the trigger's again (no resume of ours)", l.unlock(now: t0) == .none)
        _ = l.lock(enabled: true, on: true, triggerOwned: false, until: nil)
        l.userChanged()
        check("lock: turned on/off from outside while locked: that stays", l.unlock(now: t0) == .none)
        check("lock: off at the lock: triggers still wait until the unlock", l.lock(enabled: true, on: false, triggerOwned: false, until: nil) == .none && l.blocksTriggers
              && l.unlock(now: t0) == .none)

        check("launch: always turns on (as before), not when already on or a link started it",
              LaunchPolicy.turnOn("always", atLogin: true, alreadyOn: false, pendingLinks: false)
              && !LaunchPolicy.turnOn("always", atLogin: false, alreadyOn: true, pendingLinks: false)
              && !LaunchPolicy.turnOn("always", atLogin: false, alreadyOn: false, pendingLinks: true))
        check("launch: manual: by hand yes, as a login item no", LaunchPolicy.turnOn("manual", atLogin: false, alreadyOn: false, pendingLinks: false)
              && !LaunchPolicy.turnOn("manual", atLogin: true, alreadyOn: false, pendingLinks: false))
        check("launch: never", !LaunchPolicy.turnOn("never", atLogin: false, alreadyOn: false, pendingLinks: false))
        let oapp = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication, targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        check("launch: a plain open isn't a login launch", !LaunchPolicy.launchedAtLogin(oapp) && !LaunchPolicy.launchedAtLogin(nil))
        oapp.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: keyAEPropData)
        check("launch: the login item's open event is", LaunchPolicy.launchedAtLogin(oapp))

        check("click: off by default the left click opens the panel", StatusClick.act(leftToggles: false, right: false, control: false, panelOpen: false) == .panel)
        check("click: with the option a left click toggles; right and ⌃ clicks open the panel; an open panel closes",
              StatusClick.act(leftToggles: true, right: false, control: false, panelOpen: false) == .toggle
              && StatusClick.act(leftToggles: true, right: true, control: false, panelOpen: false) == .panel
              && StatusClick.act(leftToggles: true, right: false, control: true, panelOpen: false) == .panel
              && StatusClick.act(leftToggles: true, right: false, control: false, panelOpen: true) == .panel)

        check("icons: the baggie draws itself (nil); every other style has both symbols on this Mac",
              MenuIconStyle.symbol("bag", on: true) == nil
              && MenuIconStyle.all.dropFirst().allSatisfy { MenuIconStyle.image($0, on: true) != nil && MenuIconStyle.image($0, on: false) != nil })
        check("icons: on and off look different", MenuIconStyle.all.dropFirst().allSatisfy { MenuIconStyle.symbol($0, on: true) != MenuIconStyle.symbol($0, on: false) })
        check("notice: says the reason when there is one", ChangeNotice.text(on: true, reason: "VPN") == L("Cocaine is on") + " · VPN"
              && ChangeNotice.text(on: false, reason: nil) == L("Cocaine is off"))

        let s = Settings()
        check("settings: in memory for this test", AppDefaults.isolated)
        check("settings: defaults (nothing new on unless chosen)", s.unplugOff == 0 && !s.lockPause && s.launchTurnsOn == "always" && !s.leftClickToggles
              && s.menuIcon == "bag" && !s.notifyChanges && !s.triggerVPN && s.triggerCPU.isEmpty && s.whileTarget == nil)
        s.unplugOff = 7; s.menuIcon = "../x"; s.launchTurnsOn = "sometimes"; s.triggerCPUPercent = 500; s.triggerCPUMinutes = 0
        check("settings: values out of their lists fall back", s.unplugOff == 0 && s.menuIcon == "bag" && s.launchTurnsOn == "always"
              && s.triggerCPUPercent == 95 && s.triggerCPUMinutes == 1)
        s.unplugOff = 300; s.whileTarget = WhileTarget(kind: .downloads)
        check("settings: kept values read back", s.unplugOff == 300 && s.whileTarget?.kind == .downloads)
        s.whileTarget = nil
        check("settings: cleared", s.whileTarget == nil)
    }
}
