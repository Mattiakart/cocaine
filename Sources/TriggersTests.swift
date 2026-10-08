// --triggers-test: keep-awake profiles (Sources/AwakeProfiles.swift), their links, AppleScript and command line
// (Sources/AwakeProfilesCLI.swift), keeping disks awake (Sources/DriveAlive.swift: the schedule, and the real file operations in a
// temporary folder), statistics and the reminder (Sources/AwakeSessions.swift). Fixed snapshots and settings in memory: no setting,
// network, device or disk of the user's is read or changed (the temporary folder is deleted at the end).
// TriggersFixtures: the sample profiles and disks for `--render-panel … --triggers [--edit-profile]`.

import AppKit

enum TriggersTests {
    static func run() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  triggers: " + name); if !ok { failed += 1 } }
        ipTests(check)
        conditionTests(check)
        latchTests(check)
        engineTests(check)
        storageTests(check)
        linkTests(check)
        cliTests(check)
        driveTests(check)
        sessionTests(check)
        scriptingTests(check)
        print(failed == 0 ? "triggers: all passed" : "triggers: \(failed) failed")
        return failed
    }

    static let t0 = Date(timeIntervalSince1970: 1791367200)        // 2026-10-07 12:00 in Rome (a Wednesday)

    static func snap(_ f: (inout AwakeSnapshot) -> Void = { _ in }) -> AwakeSnapshot {
        var s = AwakeSnapshot()
        s.now = t0
        s.calendar = AwakeTests.rome
        f(&s)
        return s
    }

    static func cond(_ k: AwakeCondition.Kind, _ f: (inout AwakeCondition) -> Void = { _ in }) -> AwakeCondition {
        var c = AwakeCondition.make(k); f(&c); return c
    }

    // MARK: IP addresses

    static func ipTests(_ check: (String, Bool) -> Void) {
        check("ip: a /24 range", IPMatch.matches("192.168.1.0/24", "192.168.1.77") && !IPMatch.matches("192.168.1.0/24", "192.168.2.1"))
        check("ip: /8 and /32 and /0", IPMatch.matches("10.0.0.0/8", "10.200.3.4") && IPMatch.matches("10.1.2.3/32", "10.1.2.3")
              && !IPMatch.matches("10.1.2.3/32", "10.1.2.4") && IPMatch.matches("0.0.0.0/0", "8.8.8.8"))
        check("ip: a beginning, and a whole address", IPMatch.matches("10.0.", "10.0.5.1") && !IPMatch.matches("10.0.", "10.10.5.1")
              && IPMatch.matches("172.20.10.2", "172.20.10.2") && !IPMatch.matches("172.20.10.2", "172.20.10.20"))
        check("ip: IPv6 by beginning", IPMatch.matches("2001:db8:", "2001:db8::1") && !IPMatch.matches("2001:db8:", "2001:dead::1"))
        check("ip: a range never matches an IPv6 address", !IPMatch.matches("10.0.0.0/8", "fd00::1"))
        check("ip: what may be typed", ["192.168.1.0/24", "10.0.", "10.1.2.3", "2001:db8:", "fe80::1"].allSatisfy(IPMatch.valid))
        check("ip: what may not", ["", "hello", "300.1.1.1", "10.0.0.0/33", "1.2.3", "10.0.0.0/x", "$(id)", String(repeating: "1", count: 60)].allSatisfy { !IPMatch.valid($0) })
    }

    // MARK: Conditions

    static func conditionTests(_ check: (String, Bool) -> Void) {
        func met(_ c: AwakeCondition, _ f: (inout AwakeSnapshot) -> Void) -> Bool { ConditionEval.met(c, snap(f)) }
        let wifi = cond(.wifi) { $0.names = ["Office"] }
        check("wifi: the network by name, any case", met(wifi) { $0.ssid = "office" } && !met(wifi) { $0.ssid = "Home" })
        check("wifi: a hidden name (no Location) is never met, not even with “is not”",
              !met(wifi) { $0.ssid = nil } && !met(cond(.wifi) { $0.names = ["Office"]; $0.negate = true }) { $0.ssid = nil })
        check("wifi: “is not” another network", met(cond(.wifi) { $0.names = ["Office"]; $0.negate = true }) { $0.ssid = "Home" })
        check("wifi connected, ethernet, hotspot, internet, VPN read their flags",
              met(cond(.wifiConnected)) { $0.wifiConnected = true } && met(cond(.ethernet)) { $0.ethernet = true }
              && met(cond(.hotspot)) { $0.expensive = true } && met(cond(.internet)) { $0.internet = true } && met(cond(.vpn)) { $0.vpn = true }
              && !met(cond(.ethernet)) { _ in } && met(cond(.internet) { $0.negate = true }) { $0.internet = false })
        check("ip address: any of the Mac's addresses in a range", met(cond(.ipAddress) { $0.names = ["192.168.1.0/24"] }) { $0.addresses = ["fd00::2", "192.168.1.20"] }
              && !met(cond(.ipAddress) { $0.names = ["192.168.1.0/24"] }) { $0.addresses = ["10.0.0.2"] })
        check("dns server", met(cond(.dns) { $0.names = ["1.1.1.1"] }) { $0.dns = ["192.168.1.1", "1.1.1.1"] })
        check("usb, sound output, disk: part of the name is enough", met(cond(.usb) { $0.names = ["YubiKey"] }) { $0.usb = ["YubiKey 5C NFC"] }
              && met(cond(.audio) { $0.names = ["AirPods"] }) { $0.output = "Mattia's AirPods Pro" }
              && met(cond(.volume) { $0.names = ["Backup"] }) { $0.volumes = ["Backup 2TB"] })
        check("a list condition with nothing chosen is never met", !met(cond(.usb)) { $0.usb = ["YubiKey"] } && !met(cond(.volume)) { $0.volumes = ["X"] })
        let bt = cond(.bluetooth) { $0.names = ["MX Keys"] }
        check("bluetooth: before the first reading unknown (never met), then by name",
              !met(bt) { $0.bluetooth = nil } && met(bt) { $0.bluetooth = ["MX Keys Mac"] } && !met(bt) { $0.bluetooth = [] }
              && !met(cond(.bluetooth) { $0.names = ["MX Keys"]; $0.negate = true }) { $0.bluetooth = nil })
        check("front app by name or bundle id", met(cond(.frontApp) { $0.names = ["keynote"] }) { $0.front = "Keynote" }
              && met(cond(.frontApp) { $0.names = ["com.apple.iWork.Keynote"] }) { $0.frontBundle = "com.apple.iWork.Keynote" }
              && !met(cond(.frontApp) { $0.names = ["Keynote"] }) { $0.front = "Safari" })
        check("running app", met(cond(.appRunning) { $0.names = ["Xcode"] }) { $0.running = ["xcode", "finder"] }
              && !met(cond(.appRunning) { $0.names = ["Xcode"] }) { $0.running = ["finder"] })
        check("idle: less than 10 min, or 10 min or more", met(cond(.idle)) { $0.idle = 30 } && !met(cond(.idle)) { $0.idle = 600 }
              && met(cond(.idle) { $0.above = true }) { $0.idle = 600 })
        check("downloads: unknown (folder unreadable) never met", met(cond(.downloads)) { $0.downloading = true } && !met(cond(.downloads)) { $0.downloading = nil }
              && !met(cond(.downloads) { $0.negate = true }) { $0.downloading = nil })
        check("power and battery", met(cond(.power)) { $0.onAC = true } && met(cond(.power) { $0.negate = true }) { $0.onAC = false }
              && met(cond(.battery)) { $0.battery = 30 } && !met(cond(.battery)) { $0.battery = 29 }
              && met(cond(.battery) { $0.above = false; $0.number = 20 }) { $0.battery = 19 }
              && !met(cond(.battery)) { $0.battery = nil } && !met(cond(.battery) { $0.above = false }) { $0.battery = nil })
        check("display and mirroring", met(cond(.display)) { $0.externalDisplays = 1 } && !met(cond(.display)) { _ in }
              && met(cond(.mirroring)) { $0.mirroring = true })
        check("schedule: weekdays 9–18 at Wednesday noon; not on Sunday", met(cond(.schedule)) { _ in }
              && !met(cond(.schedule) { $0.days = [1] }) { _ in })
        check("cpu: what the engine measured for that condition", met(cond(.cpu) { $0.id = "c1" }) { $0.cpuHolds = ["c1": true] }
              && !met(cond(.cpu) { $0.id = "c1" }) { $0.cpuHolds = [:] })
        var p = AwakeProfile(name: "P", conditions: [cond(.power), cond(.display)])
        let one = snap { $0.onAC = true }
        check("profile: All needs both, Any one", !p.holds(one) && { p.matchAll = false; return p.holds(one) }())
        check("profile: no conditions never holds", !AwakeProfile(name: "E").holds(snap()))
        check("every kind has a title and a symbol", AwakeCondition.Kind.allCases.allSatisfy {
            !ProfileWords.kindTitle($0).isEmpty && NSImage(systemSymbolName: ProfileWords.symbol($0), accessibilityDescription: nil) != nil })
    }

    // MARK: Start and stop without flapping

    static func latchTests(_ check: (String, Bool) -> Void) {
        var p = AwakeProfile(name: "P"); p.startAfter = 10; p.stopAfter = 60
        var l = ProfileLatch()
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        check("start: not before the conditions held 10 s", l.step(holds: true, profile: p, now: at(0)) == .none && l.step(holds: true, profile: p, now: at(5)) == .none)
        check("start: after 10 s", l.step(holds: true, profile: p, now: at(10)) == .started && l.engaged)
        // Flapping: off and on every 5 s for two minutes never stops it.
        var changes = 0
        for i in 0..<24 { if l.step(holds: i % 2 == 0 ? false : true, profile: p, now: at(15 + Double(i) * 5)) != .none { changes += 1 } }
        check("flapping every 5 s for 2 min: it stays on", changes == 0 && l.engaged)
        check("stop: after 60 s without a break", l.step(holds: false, profile: p, now: at(200)) == .none && l.step(holds: false, profile: p, now: at(259)) == .none
              && l.step(holds: false, profile: p, now: at(260)) == .stopped && !l.engaged)
        var q = ProfileLatch()
        _ = q.step(holds: true, profile: p, now: at(0))
        check("a short blip before the start doesn't count", q.step(holds: false, profile: p, now: at(4)) == .none
              && q.step(holds: true, profile: p, now: at(6)) == .none && q.step(holds: true, profile: p, now: at(15)) == .none
              && q.step(holds: true, profile: p, now: at(16)) == .started)
        var z = AwakeProfile(name: "Z"); z.startAfter = 0; z.stopAfter = 0
        var zl = ProfileLatch()
        check("start and stop at once with 0 s", zl.step(holds: true, profile: z, now: at(0)) == .started && zl.step(holds: false, profile: z, now: at(1)) == .stopped)
        var m = AwakeProfile(name: "M"); m.startAfter = 0; m.maxMinutes = 30
        var ml = ProfileLatch()
        _ = ml.step(holds: true, profile: m, now: at(0))
        check("at most 30 min: then it stops and waits", ml.step(holds: true, profile: m, now: at(1799)) == .none
              && ml.step(holds: true, profile: m, now: at(1800)) == .spent && !ml.engaged
              && ml.step(holds: true, profile: m, now: at(4000)) == .none && !ml.engaged)
        check("…until the conditions break; then it can start again", ml.step(holds: false, profile: m, now: at(4005)) == .none
              && ml.step(holds: true, profile: m, now: at(4010)) == .started)
    }

    // MARK: The engine: priority, letting the Mac sleep, the displays

    static func engineTests(_ check: (String, Bool) -> Void) {
        func p(_ name: String, _ c: [AwakeCondition], _ f: (inout AwakeProfile) -> Void = { _ in }) -> AwakeProfile {
            var x = AwakeProfile(name: name, conditions: c); x.id = name; x.startAfter = 0; x.stopAfter = 0; f(&x); return x
        }
        let office = p("office", [cond(.wifi) { $0.names = ["Office"] }]) { $0.displaySleep = true }
        let desk = p("desk", [cond(.display)])
        let low = p("low", [cond(.battery) { $0.above = false; $0.number = 20 }]) { $0.action = .letSleep }
        var e = ProfileEngine()
        let s1 = snap { $0.ssid = "Office"; $0.externalDisplays = 1; $0.battery = 50 }
        let o1 = e.step([office, desk, low], snapshot: s1)
        check("two hold: both engaged, the first decides", o1.engaged == ["office", "desk"] && o1.lead?.id == "office" && o1.keepAwake && !o1.block)
        check("the lead lets the displays sleep", o1.displaySleep)
        check("started: both, in order", o1.started.map(\.id) == ["office", "desk"])
        let o2 = e.step([desk, office, low], snapshot: s1)
        check("reordered: the new first decides (no new start)", o2.lead?.id == "desk" && !o2.displaySleep && o2.started.isEmpty)
        let s2 = snap { $0.ssid = "Office"; $0.externalDisplays = 1; $0.battery = 10 }
        let o3 = e.step([low, office, desk], snapshot: s2)
        check("“Let the Mac sleep” first: it decides, every trigger waits", o3.lead?.id == "low" && o3.block && !o3.keepAwake && !o3.displaySleep)
        let o4 = e.step([office, desk, low], snapshot: s2)
        check("…below a profile that keeps it awake it doesn't", o4.lead?.id == "office" && o4.keepAwake)
        var off = office; off.enabled = false
        let o5 = e.step([off, desk, low], snapshot: s1)
        check("disabled: forgotten at once, the next one decides", !o5.engaged.contains("office") && o5.lead?.id == "desk" && e.latches["office"] == nil)
        let o6 = e.step([off, desk, low], snapshot: snap { $0.battery = 50 })
        check("its conditions end: stopped, nothing decides", o6.stopped.map(\.id) == ["desk"] && o6.lead == nil && !o6.keepAwake && !o6.block)
        // The processor: each CPU condition keeps its own stretch.
        let cpu = p("cpu", [cond(.cpu) { $0.id = "k"; $0.number = 50; $0.minutes = 1 }])
        var ce = ProfileEngine()
        var busy = 0
        for i in 0...13 {
            let s = snap { $0.now = t0.addingTimeInterval(Double(i) * 5); $0.cpuTicks = CPUTicks(busy: UInt64(i * 80), total: UInt64(i * 100)) }
            if ce.step([cpu], snapshot: s).keepAwake { busy = i; break }
        }
        check("cpu 80% busy: on once it held a minute", busy == 13)
    }

    // MARK: Storage

    static func storageTests(_ check: (String, Bool) -> Void) {
        var many = (0..<30).map { AwakeProfile(name: "P\($0)", conditions: Array(repeating: cond(.power), count: 20)) }
        many[1].id = many[0].id
        many[2].name = "  \u{7}  "
        many[3].startAfter = -5; many[3].stopAfter = 99999; many[3].maxMinutes = 5000
        many[4].conditions = [cond(.cpu) { $0.number = 400; $0.minutes = 0 }, cond(.idle) { $0.number = 0 }, cond(.battery) { $0.number = 1000 },
                              cond(.ipAddress) { $0.names = ["10.0.0.0/8", "nonsense", "$(id)"] }, cond(.schedule) { $0.days = [0, 9, 3, 3]; $0.start = -4; $0.end = 5000 },
                              cond(.power) { $0.names = ["x"]; $0.number = 7 }]
        let c = AwakeProfiles.clean(many)
        check("clean: at most 20 profiles of 12 conditions", c.count == 20 && c.allSatisfy { $0.conditions.count <= 12 })
        check("clean: ids unique", Set(c.map(\.id)).count == c.count && Set(c.flatMap { $0.conditions.map(\.id) }).count == c.flatMap(\.conditions).count)
        check("clean: an empty name gets one", c[2].name == String(format: L("Profile %d"), 3))
        check("clean: delays and the longest run in range", c[3].startAfter == 0 && c[3].stopAfter == 3600 && c[3].maxMinutes == 1440)
        let k = c[4].conditions
        check("clean: numbers in range", k[0].number == 95 && k[0].minutes == 1 && k[1].number == 1 && k[2].number == 100)
        check("clean: only addresses and ranges kept", k[3].names == ["10.0.0.0/8"])
        check("clean: days and times", k[4].days == [3] && k[4].start == 0 && k[4].end == 1439)
        check("clean: conditions without names or numbers keep none", k[5].names.isEmpty && k[5].number == 0)
        check("clean: what is already clean stays the same", AwakeProfiles.clean(c) == c)
        let data = AwakeProfiles.encode(c)
        check("encode → decode round trip", AwakeProfiles.decode(data) == c)
        let messy = #"[{"name":"A","conditions":[{"kind":"wifi","names":["Office"]},{"kind":"teleport"},{"nope":1}]},{"name":5},"x",{"name":"B","action":"explode"}]"#
        let d = AwakeProfiles.decode(Data(messy.utf8))
        check("decode: unknown kinds and broken entries are skipped, missing fields take defaults",
              d.count == 3 && d[0].name == "A" && d[0].conditions.count == 1 && d[0].conditions[0].names == ["Office"] && d[0].enabled
              && d[0].startAfter == 10 && d[1].name == String(format: L("Profile %d"), 2) && d[2].name == "B" && d[2].action == .keepAwake)
        check("decode: garbage is no profiles", AwakeProfiles.decode(Data("{".utf8)).isEmpty && AwakeProfiles.decode(nil).isEmpty)
        check("templates: each is valid and already clean", AwakeProfiles.templates.allSatisfy { t in
            guard let p = AwakeProfiles.template(t) else { return false }
            return AwakeProfiles.clean([p]).first.map { $0.conditions == p.conditions && $0.name == p.name } ?? false })
        check("templates: low battery lets the Mac sleep", AwakeProfiles.template("lowbattery")?.action == .letSleep)
        let s = Settings()
        s.awakeProfiles = [AwakeProfile(name: "Office", conditions: [cond(.wifi) { $0.names = ["Office"] }])]
        check("settings: kept (in memory here)", s.awakeProfiles.first?.name == "Office" && AppDefaults.isolated)
        check("needs: only what enabled profiles use", AwakeProfiles.needs(s.awakeProfiles) == [.wifi]
              && AwakeProfiles.needs([{ var p = AwakeProfile(name: "x", conditions: [cond(.bluetooth)]); p.enabled = false; return p }()]).isEmpty)
        check("find: by name (any case) or id", AwakeProfiles.find("office", in: s.awakeProfiles) != nil && AwakeProfiles.find("nope", in: s.awakeProfiles) == nil)
    }

    // MARK: Links

    static func linkTests(_ check: (String, Bool) -> Void) {
        func parse(_ s: String) -> ControlAction? { try? ControlURL.parse(URL(string: s)!).get().action }
        check("link: profile?name=Office&enabled=0", parse("cocaine://profile?name=Office&enabled=0") == .profile(name: "Office", enabled: false))
        check("link: enabled=on, a name with spaces", parse("cocaine://profile?name=At%20the%20office&enabled=on") == .profile(name: "At the office", enabled: true))
        check("link: x-callback form", parse("cocaine://x-callback-url/profile?name=A&enabled=1&x-success=shortcuts://x-callback-url/ok") == .profile(name: "A", enabled: true))
        check("link: no name, no enabled, a bad value, a control character, too long: refused",
              ["cocaine://profile?enabled=1", "cocaine://profile?name=A", "cocaine://profile?name=A&enabled=maybe",
               "cocaine://profile?name=%07&enabled=1", "cocaine://profile?name=\(String(repeating: "a", count: 41))&enabled=1"].allSatisfy { parse($0) == nil })
        check("link: a profile change is guarded", ControlAction.profile(name: "A", enabled: true).guarded)
        check("link: built and read back", ProfileLink.url(name: "Big & small", enabled: true).flatMap { try? ControlURL.parse($0).get().action } == .profile(name: "Big & small", enabled: true))
        check("script dialog says which profile", ScriptingDialog.describe(ControlRequest(action: .profile(name: "Office", enabled: false), success: nil, failure: nil)).contains("Office"))
    }

    // MARK: Command line

    static func cliTests(_ check: (String, Bool) -> Void) {
        let d = MemoryDefaults()
        var office = AwakeProfile(name: "Office", conditions: [cond(.wifi) { $0.names = ["Office"] }])
        var off = AwakeProfile(name: "Presenting", conditions: [cond(.mirroring)]); off.enabled = false
        office.id = "o1"
        d.set(AwakeProfiles.encode([office, off]), forKey: "awakeProfiles")
        d.set(["Office"], forKey: "profilesLive")
        var opened: [URL] = []
        func run(_ a: [String], ok: Bool = true) -> ProfilesCLI.Output {
            ProfilesCLI.run(a, defaults: d, mounted: { [DriveVolume(name: "Backup 2TB", path: "/Volumes/Backup 2TB")] }) { opened.append($0); return ok }
        }
        let l = run([])
        check("cli: list shows state, name and conditions", l.code == 0 && l.text.contains("ACTIVE  Office") && l.text.contains("off     Presenting"))
        let j = run(["list", "--json"])
        let arr = (try? JSONSerialization.jsonObject(with: Data(j.text.utf8))) as? [[String: Any]]
        check("cli: --json", arr?.count == 2 && arr?[0]["active"] as? Bool == true && arr?[1]["enabled"] as? Bool == false
              && (arr?[0]["conditions"] as? [String]) == ["wifi"])
        let e = run(["disable", "office"])
        check("cli: disable goes through the guarded link", e.code == 0 && opened.last == ProfileLink.url(name: "Office", enabled: false))
        check("cli: an unknown profile, nothing opened", run(["enable", "Nope"]).code == 65 && opened.count == 1)
        check("cli: the app didn't take it", run(["enable", "Office"], ok: false).code == 69)
        check("cli: bad usage", run(["enable"]).code == 64 && run(["frobnicate"]).code == 64)
        d.set(["Backup 2TB", "Photos"], forKey: "driveAliveVolumes")
        let k = run(["disks"])
        check("cli: disks, mounted or not", k.code == 0 && k.text.contains("mounted      Backup 2TB") && k.text.contains("not mounted  Photos"))
        let kj = (try? JSONSerialization.jsonObject(with: Data(run(["disks", "--json"]).text.utf8))) as? [String: Any]
        check("cli: disks --json", kj?["method"] as? String == "write" && (kj?["disks"] as? [[String: Any]])?.count == 2)
        check("cli: no profiles", ProfilesCLI.run([], defaults: MemoryDefaults()) { _ in true }.text.hasPrefix("no profiles"))
        let sample = #"{"SPBluetoothDataType":[{"device_connected":[{"MX Keys":{"device_rssi":"-50"}},{"AirPods Pro":{}}],"device_not_connected":[{"Old Mouse":{}}]}]}"#
        check("bluetooth: the connected list from system_profiler", BluetoothScan.parse(Data(sample.utf8)) == ["AirPods Pro", "MX Keys"]
              && BluetoothScan.parse(Data("nope".utf8)) == nil && BluetoothScan.parse(Data(#"{"SPBluetoothDataType":[{}]}"#.utf8)) == [])
    }

    // MARK: Keep disks awake

    static func failure(_ r: Result<Void, DriveTouchError>) -> DriveTouchError? { if case .failure(let e) = r { return e }; return nil }

    static func driveTests(_ check: (String, Bool) -> Void) {
        var s = DriveAliveSchedule()
        let backup = DriveVolume(name: "Backup 2TB", path: "/Volumes/Backup 2TB"), photos = DriveVolume(name: "Photos", path: "/Volumes/Photos")
        func at(_ x: Double) -> Date { t0.addingTimeInterval(x) }
        var due = s.due(chosen: ["backup 2tb"], mounted: [backup, photos], interval: 60, on: true, always: false, now: at(0))
        check("disks: a chosen, mounted disk at once (any case); an unchosen one never", due == [backup])
        s.touched(backup.path, at: at(0))
        check("disks: not again before the interval", s.due(chosen: ["Backup 2TB"], mounted: [backup], interval: 60, on: true, always: false, now: at(59)).isEmpty)
        check("disks: again after it", s.due(chosen: ["Backup 2TB"], mounted: [backup], interval: 60, on: true, always: false, now: at(60)) == [backup])
        check("disks: only while Cocaine is on, unless always", s.due(chosen: ["Backup 2TB"], mounted: [backup], interval: 60, on: false, always: false, now: at(200)).isEmpty
              && s.due(chosen: ["Backup 2TB"], mounted: [backup], interval: 60, on: false, always: true, now: at(200)) == [backup])
        check("disks: not mounted, nothing", s.due(chosen: ["Backup 2TB"], mounted: [photos], interval: 60, on: true, always: false, now: at(300)).isEmpty)
        s.unmounting(backup.path, now: at(400))
        due = s.due(chosen: ["Backup 2TB"], mounted: [backup], interval: 30, on: true, always: false, now: at(430))
        check("disks: while macOS unmounts it, a minute without touches", due.isEmpty
              && s.due(chosen: ["Backup 2TB"], mounted: [backup], interval: 30, on: true, always: false, now: at(461)) == [backup])
        check("disks: the payload is 64 bytes, a line", DriveToucher.payload(t0).count == DriveAlive.fileSize && DriveToucher.payload(t0).last == 10)

        // The real file operations, in a temporary folder standing in for a volume's top level.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cocaine-drive-\(getpid())-\(UUID().uuidString.prefix(6))")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent(DriveAlive.fileName)
        let w1 = DriveToucher.write(root: root.path, now: t0)
        let a1 = try? fm.attributesOfItem(atPath: file.path)
        var st = stat(); lstat(file.path, &st)
        check("write: the tiny file, 64 bytes, hidden", (try? w1.get()) != nil && (a1?[.size] as? NSNumber)?.intValue == 64 && (st.st_flags & UInt32(UF_HIDDEN)) != 0)
        check("write: left out of Time Machine", (try? file.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true)
        _ = DriveToucher.write(root: root.path, now: t0.addingTimeInterval(60))
        let n2 = (try? fm.contentsOfDirectory(atPath: root.path))?.count
        check("write again: the same file, the same size, nothing piles up", n2 == 1 && ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue == 64
              && (try? String(contentsOf: file, encoding: .utf8))?.contains("\(Int(t0.timeIntervalSince1970) + 60)") == true)
        // Never through a link, never over someone else's file.
        try? fm.removeItem(at: file)
        let victim = root.appendingPathComponent("victim.txt")
        try? Data("keep me".utf8).write(to: victim)
        try? fm.createSymbolicLink(at: file, withDestinationURL: victim)
        check("write: a link put there is refused, its target untouched", failure(DriveToucher.write(root: root.path)) == .notOurs
              && (try? String(contentsOf: victim, encoding: .utf8)) == "keep me")
        check("remove: a link is not ours, left alone", !DriveToucher.remove(root: root.path) && fm.fileExists(atPath: victim.path))
        try? fm.removeItem(at: file)
        try? fm.linkItem(at: victim, to: file)
        check("write: a hard link is refused too", failure(DriveToucher.write(root: root.path)) == .notOurs && (try? String(contentsOf: victim, encoding: .utf8)) == "keep me")
        try? fm.removeItem(at: file)
        try? Data(repeating: 1, count: 10_000).write(to: file)
        check("write: a big file with that name isn't ours", failure(DriveToucher.write(root: root.path)) == .notOurs
              && ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue == 10_000)
        try? fm.removeItem(at: file)
        _ = DriveToucher.write(root: root.path)
        check("remove: deletes ours", DriveToucher.remove(root: root.path) && !fm.fileExists(atPath: file.path))
        // A folder that can't be written: an error, nothing created.
        let ro = root.appendingPathComponent("ro")
        try? fm.createDirectory(at: ro, withIntermediateDirectories: true)
        chmod(ro.path, 0o555)
        let wr = DriveToucher.write(root: ro.path)
        chmod(ro.path, 0o755)
        if case .failure(.failed(let code)) = wr { check("write: not writable → an error (\(code)), nothing created", !fm.fileExists(atPath: ro.appendingPathComponent(DriveAlive.fileName).path)) }
        else { check("write: not writable → an error", false) }
        // Read only: the largest file near the top, read without writing anything.
        let sub = root.appendingPathComponent("Movies")
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try? Data(repeating: 7, count: 300_000).write(to: sub.appendingPathComponent("big.mov"))
        try? Data(repeating: 7, count: 1000).write(to: root.appendingPathComponent("small.txt"))
        try? Data(repeating: 7, count: 900_000).write(to: root.appendingPathComponent(".hidden-huge"))
        let target = DriveToucher.readTarget(root: root.path)
        check("read: picks the largest visible file, one level down at most", target?.hasSuffix("Movies/big.mov") == true)
        let before = (try? fm.attributesOfItem(atPath: sub.appendingPathComponent("big.mov").path))?[.modificationDate] as? Date
        check("read: reads at different spots, nothing written", (try? DriveToucher.read(file: target ?? "", offsetSeed: 12345).get()) != nil
              && (try? DriveToucher.read(file: target ?? "", offsetSeed: 99).get()) != nil
              && (try? fm.attributesOfItem(atPath: sub.appendingPathComponent("big.mov").path))?[.modificationDate] as? Date == before
              && !fm.fileExists(atPath: file.path))
        check("read: an empty disk has nothing to read", DriveToucher.readTarget(root: ro.path) == nil)
        check("errors say what to do", [DriveTouchError.readOnly, .notOurs, .noFile, .failed(EPERM), .failed(EIO)].allSatisfy { !DriveToucher.describe($0).isEmpty }
              && DriveToucher.describe(.failed(EPERM)) != DriveToucher.describe(.failed(EIO)))
        check("settings: interval and method only take known values", {
            let s = Settings(); s.driveAliveInterval = 7; s.driveAliveMethod = "rm -rf"
            return s.driveAliveInterval == 60 && s.driveAliveMethod == "write"
        }())
    }

    // MARK: Statistics and the reminder

    static func sessionTests(_ check: (String, Bool) -> Void) {
        var s = AwakeStats(since: t0)
        s.turned(on: true, now: t0)
        s.turned(on: true, now: t0.addingTimeInterval(10))            // already on: the same session
        s.turned(on: false, now: t0.addingTimeInterval(3600))
        check("stats: one session of an hour", s.sessions == 1 && s.seconds == 3600 && s.onSince == nil)
        s.turned(on: true, now: t0.addingTimeInterval(7200))
        check("stats: the session going on counts", s.total(now: t0.addingTimeInterval(9000)) == 3600 + 1800 && s.sessions == 2)
        s.seen(now: t0.addingTimeInterval(7800))
        s.launched(on: false, now: t0.addingTimeInterval(90000))       // quit in the middle: counted up to the last sight
        check("stats: a session left open ends where it was last seen", s.seconds == 3600 + 600 && s.onSince == nil)
        s.launched(on: true, now: t0.addingTimeInterval(100000))
        check("stats: launched while on starts one", s.sessions == 3 && s.onSince != nil)
        var r = OnReminder()
        let on = t0
        check("reminder: never with 0", r.step(onSince: on, every: 0, now: on.addingTimeInterval(99999)) == nil)
        check("reminder: nothing in the first hour", r.step(onSince: on, every: 1, now: on.addingTimeInterval(3599)) == nil)
        check("reminder: at 1 h, once", r.step(onSince: on, every: 1, now: on.addingTimeInterval(3600)) == 1 && r.step(onSince: on, every: 1, now: on.addingTimeInterval(3700)) == nil)
        check("reminder: at 2 h", r.step(onSince: on, every: 1, now: on.addingTimeInterval(7300)) == 2)
        check("reminder: the interval changed: from now on, no catching up", r.step(onSince: on, every: 2, now: on.addingTimeInterval(7400)) == nil
              && r.step(onSince: on, every: 2, now: on.addingTimeInterval(14400)) == 4)
        let later = on.addingTimeInterval(20000)
        check("reminder: a new session starts over", r.step(onSince: later, every: 1, now: later.addingTimeInterval(3600)) == 1)
        check("reminder: off, nothing", r.step(onSince: nil, every: 1, now: later) == nil)
    }

    // MARK: AppleScript (the dictionary as Cocoa loads it from the bundle)

    static func scriptingTests(_ check: (String, Bool) -> Void) {
        guard Bundle.main.url(forResource: "Cocaine", withExtension: "sdef") != nil else {
            check("script: run from the app bundle (the dictionary is in Contents/Resources)", false)
            return
        }
        let reg = NSScriptSuiteRegistry.shared()
        func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 + FourCharCode($1) } }
        let en = reg.commandDescription(withAppleEventClass: code("CcAw"), andAppleEventCode: code("PrOn"))
        let dis = reg.commandDescription(withAppleEventClass: code("CcAw"), andAppleEventCode: code("PrOf"))
        check("script: enable/disable profile load with our classes", en?.commandClassName == "CocaineEnableProfileCommand"
              && dis?.commandClassName == "CocaineDisableProfileCommand")
        let app = reg.classDescription(withAppleEventCode: code("capp"))
        check("script: active profile and profile names", app?.appleEventCode(forKey: "scriptActiveProfile") != nil && app?.appleEventCode(forKey: "scriptProfileNames") != nil)
        // The commands on a fake gate.
        let m = AwakeModel.shared, saved = m.profiles
        defer { m.profiles = saved }
        var office = AwakeProfile(name: "Office", conditions: [cond(.power)]); office.id = "o1"
        m.profiles = [office]
        let c = ScriptingCenter.shared
        let keep = c.perform
        defer { c.perform = keep }
        var asked: [ControlRequest] = [], allow = true
        c.perform = { req, done in
            asked.append(req)
            if allow, case .profile(let n, let e) = req.action { m.update(AwakeProfiles.find(n, in: m.profiles)!.id) { $0.enabled = e } }
            done(allow)
        }
        func run(_ d: NSScriptCommandDescription?, _ name: String) -> (Any?, Int) {
            guard let cmd = d?.createCommandInstance() else { return (nil, 99) }
            cmd.directParameter = name
            let r = cmd.execute()
            return (r, cmd.scriptErrorNumber)
        }
        let r1 = run(dis, "office")
        check("script: disable profile \"office\" → false, through the gate", asked.last?.action == .profile(name: "Office", enabled: false)
              && (r1.0 as? NSNumber)?.boolValue == false && r1.1 == 0 && m.profiles[0].enabled == false)
        let r2 = run(en, "Nope")
        check("script: an unknown profile is an error, the gate isn't asked", r2.1 == ScriptError.badValue && asked.count == 1)
        allow = false
        let r3 = run(en, "Office")
        check("script: refused: -1743, nothing changed", r3.1 == ScriptError.notAllowed && m.profiles[0].enabled == false)
        m.leadProfile = "o1"
        check("script: the properties read the model", NSApplication.shared.scriptActiveProfile == "Office" && NSApplication.shared.scriptProfileNames == ["Office"])
        m.leadProfile = nil
        check("script: no profile deciding: empty text", NSApplication.shared.scriptActiveProfile == "")
    }
}

/// The sample profiles and disks for renders (`--render-panel … --auto auto --triggers [--edit-profile]`): in memory only.
enum TriggersFixtures {
    static func fill(_ am: AwakeModel, edit: Bool) {
        func c(_ k: AwakeCondition.Kind, _ f: (inout AwakeCondition) -> Void = { _ in }) -> AwakeCondition { var x = AwakeCondition.make(k); f(&x); return x }
        var office = AwakeProfile(name: L("At the office"), conditions: [c(.wifi) { $0.names = ["Office", "Office-5G"] }, c(.power),
                                                                       c(.cpu) { $0.number = 25; $0.minutes = 5 }])
        office.id = "f-office"; office.stopAfter = 300; office.maxMinutes = 240
        var backup = AwakeProfile(name: L("Backup disk"), conditions: [c(.volume) { $0.names = ["Backup 2TB"] }])
        backup.id = "f-backup"; backup.displaySleep = true
        var low = AwakeProfile(name: L("Low battery"), conditions: [c(.power) { $0.negate = true }, c(.battery) { $0.above = false; $0.number = 20 }])
        low.id = "f-low"; low.action = .letSleep; low.startAfter = 0
        var present = AwakeProfile(name: L("Presenting"), conditions: [c(.mirroring), c(.frontApp) { $0.names = ["Keynote"] },
                                                                     c(.schedule), c(.bluetooth) { $0.names = ["MX Keys"] }])
        present.id = "f-present"; present.enabled = false; present.matchAll = false
        am.profiles = [low, office, backup, present]
        am.engagedProfiles = ["f-office"]
        am.leadProfile = "f-office"
        am.holdingProfiles = ["f-office", "f-backup"]
        am.editingProfile = edit ? "f-office" : nil
        am.driveAliveVolumes = ["Backup 2TB", "Photos", "NAS"]
        am.driveStatus = ["Backup 2TB": .init(at: Date().addingTimeInterval(-40), problem: nil),
                          "Photos": .init(at: nil, problem: L("Read-only disk: choose Read only"))]
        am.driveAliveInterval = 120
        var s = AwakeStats(since: Date().addingTimeInterval(-6 * 86400))
        s.sessions = 14; s.seconds = 41 * 3600
        am.stats = s
        am.remindHours = 2
    }
}
