// --power-review-test: regression tests for the defects the round-7 review of keep-awake and system control found (each one
// failed on the code before its fix). Fakes, fixed clocks, settings in memory and temporary folders only: no real display,
// brightness, backlight, pmset state or disk of the user's is read or changed.

import AppKit

enum PowerReviewTests {
    static func run() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  power: " + name); if !ok { failed += 1 } }
        profileTests(check)
        cpuTests(check)
        autoOnTests(check)
        dimTests(check)
        uninstallTests(check)
        driveTests(check)
        cliTests(check)
        backlightTests(check)
        print(failed == 0 ? "power: all passed" : "power: \(failed) failed")
        return failed
    }

    static let t0 = Date(timeIntervalSince1970: 1791367200)

    // MARK: Profiles: an empty list with "is not", the clock going back

    static func profileTests(_ check: (String, Bool) -> Void) {
        var s = AwakeSnapshot()
        s.now = t0; s.ssid = "Home"; s.usb = ["YubiKey"]; s.output = "Speakers"; s.volumes = ["Backup"]; s.addresses = ["10.0.0.2"]
        s.dns = ["1.1.1.1"]; s.bluetooth = ["MX Keys"]; s.front = "Xcode"; s.running = ["xcode"]
        let negatedEmpty = AwakeCondition.nameKinds.map { k -> AwakeCondition in var c = AwakeCondition.make(k); c.negate = true; return c }
        check("an “is not” list condition with nothing chosen is never met (every list kind)",
              negatedEmpty.allSatisfy { !ConditionEval.met($0, s) })
        var p = AwakeProfile(name: "USB", conditions: [negatedEmpty.first { $0.kind == .usb }!]); p.startAfter = 0
        var e = ProfileEngine()
        check("…so a profile with only that condition never starts", !e.step([p], snapshot: s).keepAwake)
        var named = AwakeCondition.make(.usb); named.negate = true; named.names = ["Studio Display"]
        check("“is not” with a name chosen still works", ConditionEval.met(named, s))

        // Engaged, then the clock goes back an hour and the conditions stop: it still stops after its "stop after".
        var q = AwakeProfile(name: "Q"); q.startAfter = 0; q.stopAfter = 60
        var l = ProfileLatch()
        _ = l.step(holds: true, profile: q, now: t0)
        let back = t0.addingTimeInterval(-3600)
        _ = l.step(holds: false, profile: q, now: t0.addingTimeInterval(30))            // stop delay starts
        let early = l.step(holds: false, profile: q, now: back)                          // clock set back an hour
        let late = l.step(holds: false, profile: q, now: back.addingTimeInterval(61))
        check("profile: the clock set back during the stop delay → it stops 60 s later, not an hour later", early == .none && late == .stopped)
        var r = ProfileLatch(); var m = q; m.maxMinutes = 30
        _ = r.step(holds: true, profile: m, now: t0)
        _ = r.step(holds: true, profile: m, now: back)
        check("profile: …and its longest run counts from the jump", r.step(holds: true, profile: m, now: back.addingTimeInterval(1800)) == .spent)
        var st = ProfileLatch(); var w = q; w.startAfter = 30
        _ = st.step(holds: true, profile: w, now: t0)
        _ = st.step(holds: true, profile: w, now: back)
        check("profile: …and a start delay too", st.step(holds: true, profile: w, now: back.addingTimeInterval(30)) == .started)
    }

    // MARK: CPU: a reading made right after another is not a load sample

    static func cpuTests(_ check: (String, Bool) -> Void) {
        var cpu = CPURule()
        func s(_ busy: UInt64, _ total: UInt64, _ secs: Double) -> Bool? {
            cpu.step(rule: "above", percent: 50, minutes: 1, ticks: CPUTicks(busy: busy, total: total), now: t0.addingTimeInterval(secs))
        }
        _ = s(0, 0, 0)
        _ = s(80, 100, 5); _ = s(400, 500, 30)
        // A setting changed (or a disk mounted) 50 ms after the last look: a handful of idle ticks.
        let blip = s(400, 504, 30.05)
        check("cpu: a sample 50 ms after the last one doesn't end a busy stretch", blip == false && cpu.since != nil)
        check("cpu: …and the stretch goes on to hold its minute", s(800, 1000, 66) == true)
        check("cpu: the clock set back restarts the stretch instead of waiting for the old time",
              s(900, 1100, -600) == false && s(1300, 1600, -540) == true)
        // The same through a profile's processor condition (ProfileEngine keeps one CPURule per condition).
        var c = AwakeCondition.make(.cpu); c.id = "k"; c.number = 50; c.minutes = 1
        var p = AwakeProfile(name: "CPU", conditions: [c]); p.startAfter = 0; p.stopAfter = 0
        var e = ProfileEngine(), on = false
        for i in 0...14 {
            var snap = AwakeSnapshot(); snap.now = t0.addingTimeInterval(Double(i) * 5)
            snap.cpuTicks = CPUTicks(busy: UInt64(i * 80), total: UInt64(i * 100))
            _ = e.step([p], snapshot: snap)
            var blipSnap = snap; blipSnap.now = snap.now.addingTimeInterval(0.05)                   // an extra look in between
            blipSnap.cpuTicks = CPUTicks(busy: UInt64(i * 80), total: UInt64(i * 100 + 3))
            on = e.step([p], snapshot: blipSnap).keepAwake
        }
        check("cpu: a profile's processor condition holds through extra looks in between", on)
    }

    // MARK: Smart Triggers' ON: the clock going back, a wake

    static func autoOnTests(_ check: (String, Bool) -> Void) {
        var a = AutoOn()
        _ = a.step(active: true, isOn: false, now: t0)                                    // a trigger turns it on
        let back = t0.addingTimeInterval(-3600)
        let first = a.step(active: false, isOn: true, now: back, grace: 30)
        let after = a.step(active: false, isOn: true, now: back.addingTimeInterval(30), grace: 30)
        check("triggers: the clock set back an hour → the ON a trigger made ends after its grace, not an hour later",
              first == .none && after == .turnOff)
        var w = AutoOn()
        _ = w.step(active: true, isOn: false, now: t0)
        let wake = t0.addingTimeInterval(4 * 3600)
        w.woke(now: wake)
        check("triggers: after a long sleep the first look (the reason not back yet) doesn't end it at once",
              w.step(active: false, isOn: true, now: wake.addingTimeInterval(1), grace: 30) == .none
              && w.step(active: false, isOn: true, now: wake.addingTimeInterval(31), grace: 30) == .turnOff)
        var u = AutoOn()
        u.woke(now: wake)
        check("triggers: a wake gives nothing to an ON the user made", !u.owned && u.lastActive == .distantPast)
        var pc = PowerSourceChange()
        pc.feed(onAC: false, now: t0)
        let firstReading = pc.at
        pc.feed(onAC: false, now: t0.addingTimeInterval(5))
        pc.feed(onAC: true, now: t0.addingTimeInterval(9))
        check("power source: the first reading isn't a change; plugging in is, at its time",
              firstReading == .distantPast && pc.at == t0.addingTimeInterval(9))
    }

    // MARK: Dimming: macOS's own brightness change behind a closed lid or at the charger

    static func dimTests(_ check: (String, Bool) -> Void) {
        let builtin: CGDirectDisplayID = 1, studio: CGDirectDisplayID = 2
        func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.001 }
        func rig(_ displays: [CGDirectDisplayID: FakeDisplays.D]) -> (FakeDisplays, DimController) {
            let io = FakeDisplays(); io.displays = displays
            return (io, DimController(io: io) { _ in })
        }
        func run(_ io: FakeDisplays, _ dim: DimController, _ i: inout DimInputs, _ seconds: Double) {
            var t = 0.0
            while t < seconds - 1e-9 {
                if Int((t * 1000).rounded()) % 500 == 0 { dim.tick(i) }
                dim.fadeStep()
                io.now = io.now.addingTimeInterval(0.025); t += 0.025
                if i.idle > 0 { i.idle += 0.025 }
            }
        }
        // Lid closed (no external display), Cocaine on: the built-in at the minimum. The charger goes in and macOS raises it.
        do {
            let (io, dim) = rig([builtin: .init(builtin: true, backlit: true, brightness: 0.6)])
            var i = DimInputs(on: true, dimEnabled: false, sessionActive: true, idle: 0, delay: 60, level: 0.2)
            run(io, dim, &i, 1)
            io.lidClosed = true; dim.lidChanged(closed: true); run(io, dim, &i, 1)
            io.displays[builtin]!.brightness = 0.5; run(io, dim, &i, 1)                          // macOS's jump, no charger change known
            check("lid: a built-in behind the closed lid raised by macOS is put back to the minimum", near(io.displays[builtin]!.brightness, DimController.lidLevel))
            io.lidClosed = false; dim.lidChanged(closed: false); run(io, dim, &i, 1)
            check("lid: …and opening the lid still gives back the level from before the close", near(io.displays[builtin]!.brightness, 0.6))
        }
        // Idle-dimmed external display; the charger goes in 2 s before macOS raises the brightness: not the user's.
        do {
            let (io, dim) = rig([studio: .init(builtin: false, backlit: true, brightness: 0.9)])
            var i = DimInputs(on: true, dimEnabled: true, sessionActive: true, idle: 61, delay: 60, level: 0.2)
            run(io, dim, &i, 3)
            i.powerChangedAt = io.now.addingTimeInterval(-2)
            io.displays[studio]!.brightness = 0.6; run(io, dim, &i, 1)
            check("charger: the jump macOS makes when the charger goes in is put back (the dim stays)", near(io.displays[studio]!.brightness, 0.2) && dim.isLowered(studio))
            i.idle = 0; run(io, dim, &i, 2)
            check("charger: …and input brings back the level from before the dim", near(io.displays[studio]!.brightness, 0.9))
        }
        // The same jump with no charger change around it is still someone's choice (kept), as before.
        do {
            let (io, dim) = rig([studio: .init(builtin: false, backlit: true, brightness: 0.9)])
            var i = DimInputs(on: true, dimEnabled: true, sessionActive: true, idle: 61, delay: 60, level: 0.2)
            i.powerChangedAt = io.now.addingTimeInterval(-600)
            run(io, dim, &i, 3)
            io.displays[studio]!.brightness = 0.6; run(io, dim, &i, 1)
            check("charger: a jump long after the last plug/unplug is still the user's (kept)", near(io.displays[studio]!.brightness, 0.6) && !dim.isLowered(studio))
        }
        check("dim rule: lid → never the user's; 3 s after a power change → not; 30 s after → the user's",
              !DimController.userRaised(by: 0.5, reason: "lid", sincePowerChange: 999)
              && !DimController.userRaised(by: 0.5, reason: "idle", sincePowerChange: 3)
              && DimController.userRaised(by: 0.5, reason: "idle", sincePowerChange: 30)
              && !DimController.userRaised(by: 0.05, reason: "idle", sincePowerChange: 30))
    }

    // MARK: Uninstall: every state file the engine writes goes

    static func uninstallTests(_ check: (String, Bool) -> Void) {
        guard let engine = Bundle.main.path(forResource: "cocaine", ofType: nil), let text = try? String(contentsOfFile: engine, encoding: .utf8) else {
            check("uninstall: the engine is in the bundle", false); return
        }
        // Every `NAME="$HLOCKDIR/<file>"` the engine defines, except the lease (removed with its own call) and engine/ (a folder).
        let rx = try! NSRegularExpression(pattern: #"="\$HLOCKDIR/([A-Za-z0-9._-]+)""#)
        let files = rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in Range(m.range(at: 1), in: text).map { String(text[$0]) } }
        let wanted = Set(files).subtracting(["recovery.json"]).filter { !$0.hasPrefix("engine") }
        check("uninstall: found the engine's state files (\(wanted.sorted().joined(separator: " ")))", wanted.count >= 6)
        check("uninstall: every one of them is removed (screen-off used to stay)", wanted.isSubset(of: Set(RecoveryCLI.stateFiles)))
    }

    // MARK: Keep disks awake: the tiny file goes with an uninstall or a switch to "Read only"; no disk reading on the main thread

    static func driveTests(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("cocaine-power-\(getpid())")
        try? fm.removeItem(at: tmp)
        let a = tmp.appendingPathComponent("A").path, b = tmp.appendingPathComponent("B").path
        try? fm.createDirectory(atPath: a, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: b, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        _ = DriveToucher.write(root: a); _ = DriveToucher.write(root: b)
        let mounted = [DriveVolume(name: "Backup", path: a), DriveVolume(name: "Photos", path: b)]
        let n = DriveAliveRunner.removeFiles(names: ["backup"], mounted: mounted)
        check("disks: removing one disk's file leaves the other's", n == 1 && !fm.fileExists(atPath: a + "/" + DriveAlive.fileName)
              && fm.fileExists(atPath: b + "/" + DriveAlive.fileName))

        // A switch to "Read only" deletes the files already written (nothing is written any more after it): the model says so,
        // the runner then removes them with removeFiles (above).
        func wait(_ until: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(3)
            while !until() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return until()
        }
        check("disks: the model tells the runner when the method changes", {
            let m = AwakeModel()
            var seen: (String, [String])?
            m.driveMethodChanged = { seen = ($0, $1) }
            m.driveAliveVolumes = ["Photos"]
            m.driveAliveMethod = m.driveAliveMethod == "read" ? "write" : "read"
            m.driveAliveMethod = "read"
            return seen?.0 == "read" && seen?.1 == ["Photos"]
        }())

        // A slow disk reading (a network volume that stopped answering) never holds the main thread.
        let settings = Settings()
        settings.driveAliveVolumes = ["Photos"]
        settings.driveAliveMethod = "write"                     // (the check above left it on "Read only")
        let slow = DriveAliveRunner()
        slow.mountedReader = { Thread.sleep(forTimeInterval: 0.8); return mounted }
        var touched: String?
        slow.statusChanged = { name, st in if st.at != nil { touched = name } }
        try? fm.removeItem(atPath: b + "/" + DriveAlive.fileName)
        let start = Date()
        slow.tick(settings: settings, on: true, now: Date())
        let blocked = Date().timeIntervalSince(start)
        check("disks: the 5 s look returns at once with a slow disk reading (\(Int(blocked * 1000)) ms)", blocked < 0.2)
        check("disks: …and touches the disk once the reading arrives", wait { touched == "Photos" } && fm.fileExists(atPath: b + "/" + DriveAlive.fileName))
        settings.driveAliveVolumes = []
    }

    // MARK: `cocaine profiles` from the engine's copy of the executable

    static func cliTests(_ check: (String, Bool) -> Void) {
        check("cli: from the bundle, the app's own domain", ProfilesCLI.appDefaults(bundleID: "local.cocaine.toggle") === UserDefaults.standard)
        check("cli: from the copy without a bundle id, the app's domain by name (not the executable's)",
              ProfilesCLI.appDefaults(bundleID: nil) !== UserDefaults.standard)
    }

    // MARK: Keyboard backlight auto-off: Stay active's nudges are not you

    static func backlightTests(_ check: (String, Bool) -> Void) {
        // The app hands the backlight its idle time without Stay active's own nudges (RealIdle), like the dimming.
        var real = RealIdle()
        var clock = t0, system = 0.0
        func step(_ secs: Double, nudge: Bool = false) -> (raw: Double, ours: Double) {
            clock = clock.addingTimeInterval(secs); system += secs
            if nudge { real.lastNudge = clock; system = 0 }
            return (system, real.update(systemIdle: system, now: clock))
        }
        _ = step(0)
        let light = KeyboardBacklight(device: FakeBacklight(level: 0.6), defaults: MemoryDefaults())
        light.setIdleOff(60)
        var idle = 0.0
        let saved = UserIdle.provider
        defer { UserIdle.provider = saved }
        UserIdle.provider = { idle }                  // what AppDelegate does with its RealIdle; the backlight must use it
        light.keepingAwake = { true }
        var x = step(70); idle = x.ours; light.tick()
        let off = light.dimmed
        x = step(200, nudge: true); idle = x.ours; light.tick()               // Stay active nudges at 270 s
        check("backlight: off after a minute away, and a Stay active nudge doesn't turn it back on", off && light.dimmed && x.raw < 1)
        idle = 0; light.tick()
        check("backlight: real input does", !light.dimmed && (light.device as? FakeBacklight)?.value == 0.6)
    }
}
