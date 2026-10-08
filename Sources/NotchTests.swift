// --notch-test: the notch's pure parts and its watches with fakes (Sources/Notch*.swift, Sources/IslandReminders.swift): the
// battery's events and glyph, the HUD's timeline with them, the swipes, the sizes, the controls, the reminders (a fake source,
// never EventKit), the new motion roles and the module stagger. And NotchFixtures: render samples (--notch-fixture <name>).

import AppKit
import SwiftUI

/// Reminders in memory: the tests' and the renders' source.
final class FakeReminders: RemindersSource {
    var access: ReminderAccess
    var grant = true
    var listsValue: [ReminderList]
    var items: [ReminderItem]
    var completed: [String] = []
    var failSave = false
    var defaultList: String?
    var onChange: (() -> Void)?
    private var next = 0

    init(access: ReminderAccess = .granted, lists: [ReminderList] = FakeReminders.sampleLists, items: [ReminderItem] = []) {
        self.access = access; listsValue = lists; self.items = items; defaultList = lists.first?.id
    }
    static let sampleLists = [ReminderList(id: "home", title: "Home", color: [1, 0.6, 0.2]), ReminderList(id: "work", title: "Work", color: [0.4, 0.64, 1])]

    func requestAccess(_ done: @escaping (Bool) -> Void) { access = grant ? .granted : .denied; done(grant) }
    func lists() -> [ReminderList] { listsValue }
    func fetch(lists ids: [String]?, _ done: @escaping ([ReminderItem]) -> Void) {
        done(items.filter { r in !completed.contains(r.id) && (ids?.contains(r.listID) ?? true) })
    }
    func setCompleted(_ id: String, _ c: Bool) throws {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        if c { completed.append(id) } else { completed.removeAll { $0 == id } }
    }
    func add(title: String, list: String?, due: DateComponents?) throws -> ReminderItem {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        next += 1
        let r = ReminderItem(id: "new\(next)", title: title, due: due.flatMap { Calendar.autoupdatingCurrent.date(from: $0) }, listID: list ?? defaultList ?? "")
        items.append(r)
        return r
    }
}

enum NotchTests {
    static func run() -> Int {
        _ = NSApplication.shared
        precondition(AppDefaults.isolated, "tests run with memory-only settings (main.swift)")
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  notch: " + name); if !ok { failed += 1 } }
        power(check); hud(check); swipes(check); sizes(check); controls(check); reminders(check); motion(check)
        return failed
    }

    // MARK: the battery

    static func power(_ check: (String, Bool) -> Void) {
        func r(_ p: Int, ac: Bool, charging: Bool? = nil, charged: Bool = false, lpm: Bool = false) -> PowerReading {
            PowerReading(percent: p, onAC: ac, charging: charging ?? (ac && p < 100), charged: charged, lowPower: lpm)
        }
        var e = ChargeEvents()
        check("battery: the first reading is only the baseline (nothing said at launch)", e.feed(r(55, ac: false), low: 20) == nil)
        check("battery: the same reading again says nothing", e.feed(r(55, ac: false), low: 20) == nil)
        check("battery: charger in → connected", e.feed(r(55, ac: true), low: 20) == .connected)
        check("battery: …a level change while charging says nothing", e.feed(r(70, ac: true), low: 20) == nil)
        check("battery: full → said once", e.feed(r(100, ac: true, charged: true), low: 20) == .full)
        check("battery: …held at 99–100 % it isn't said again", e.feed(r(99, ac: true, charged: false), low: 20) == nil
              && e.feed(r(100, ac: true, charged: true), low: 20) == nil)
        check("battery: charger out → disconnected", e.feed(r(100, ac: false), low: 20) == .disconnected)
        check("battery: plugged in at 100 %: connected (as full), and no separate full after", e.feed(r(100, ac: true, charged: true), low: 20) == .connected
              && e.feed(r(100, ac: true, charged: true), low: 20) == nil)
        _ = e.feed(r(30, ac: false), low: 20)
        check("battery: crossing the low level on battery → low(20), once", e.feed(r(20, ac: false), low: 20) == .low(20)
              && e.feed(r(19, ac: false), low: 20) == nil && e.feed(r(15, ac: false), low: 20) == nil)
        check("battery: …the critical level comes once more → low(10)", e.feed(r(10, ac: false), low: 20) == .low(10) && e.feed(r(8, ac: false), low: 20) == nil)
        _ = e.feed(r(8, ac: true), low: 20); _ = e.feed(r(30, ac: true), low: 20); _ = e.feed(r(30, ac: false), low: 20)
        check("battery: re-armed after charging: low again next time", e.feed(r(20, ac: false), low: 20) == .low(20))
        var f = ChargeEvents()
        _ = f.feed(r(60, ac: true), low: 20)
        check("battery: unplugged already low: the unplug says it, no low right after", f.feed(r(15, ac: false), low: 20) == .disconnected
              && f.feed(r(14, ac: false), low: 20) == nil)
        var g = ChargeEvents()
        _ = g.feed(r(15, ac: false), low: 20)
        check("battery: launched already low: not announced, nor at the next reading", g.feed(r(15, ac: false), low: 20) == nil)
        check("battery: …but a later crossing of the critical level is", g.feed(r(10, ac: false), low: 20) == .low(10))
        var h = ChargeEvents()
        _ = h.feed(r(50, ac: false), low: 0)
        check("battery: low notice off (0): never low", h.feed(r(5, ac: false), low: 0) == nil)
        check("battery: Low Power Mode on and off", h.feed(r(5, ac: false, lpm: true), low: 0) == .lowPower(true) && h.feed(r(5, ac: false, lpm: false), low: 0) == .lowPower(false))
        var w = ChargeEvents()
        _ = w.feed(r(50, ac: true), low: 20)
        var events: [ChargeEvent?] = []
        for i in 0..<20 { events.append(w.feed(r(50, ac: i % 2 == 0 ? false : true), low: 20)) }
        check("battery: a wiggling cable: every in and out said, alternating, nothing else",
              events.enumerated().allSatisfy { $0.element == ($0.offset % 2 == 0 ? .disconnected : .connected) })
        check("battery: levels: 20 → [10, 20]; 10 → [10]; 0 → []", ChargeEvents.levels(20) == [10, 20] && ChargeEvents.levels(10) == [10] && ChargeEvents.levels(0).isEmpty)

        check("glyph: charging / held / full / low / battery", ChargeGlyph.of(r(50, ac: true), low: 20).state == .charging
              && ChargeGlyph.of(r(80, ac: true, charging: false), low: 20).state == .plugged
              && ChargeGlyph.of(r(100, ac: true, charged: true), low: 20).state == .full
              && ChargeGlyph.of(r(12, ac: false), low: 20).state == .low && ChargeGlyph.of(r(40, ac: false), low: 20).state == .battery)
        check("glyph: a badge on the charger only (bolt, or a plug while held)", ChargeGlyph.of(r(50, ac: true), low: 20).badge == "bolt.fill"
              && ChargeGlyph.of(r(80, ac: true, charging: false), low: 20).badge == "powerplug.fill" && ChargeGlyph.of(r(40, ac: false), low: 20).badge == nil)
        check("glyph: green charging, red low, yellow in Low Power Mode on battery, white otherwise",
              ChargeGlyph.of(r(50, ac: true), low: 20).tint == ChargeGlyph.green && ChargeGlyph.of(r(12, ac: false), low: 20).tint == ChargeGlyph.red
              && ChargeGlyph.of(r(50, ac: false, lpm: true), low: 20).tint == ChargeGlyph.yellow && ChargeGlyph.of(r(50, ac: false), low: 20).tint == .white
              && ChargeGlyph.of(r(50, ac: true, lpm: true), low: 20).tint == ChargeGlyph.green)
        check("glyph: the percentage stays within 0…100", ChargeGlyph.of(r(140, ac: false), low: 20).percent == 100 && ChargeGlyph.of(r(-3, ac: false), low: 20).percent == 0)
        var tf = r(40, ac: true); tf.minutesToFull = 75
        let item = ChargeEvents.item(.connected, tf, low: 20)
        check("HUD item: charging says it, with the time to full, as the battery's own kind", item.text == L("Charging") && item.power?.detail != nil
              && item.kind == "power" && item.level == nil && Island.hudHeight(item) == 42)
        check("HUD item: unplugged, full, low", ChargeEvents.item(.disconnected, r(80, ac: false), low: 20).text == L("On battery")
              && ChargeEvents.item(.full, r(100, ac: true, charged: true), low: 20).text == L("Fully charged")
              && ChargeEvents.item(.low(10), r(9, ac: false), low: 20).power?.detail == L("Charge now"))

        // The watch with a fake reader: events reach the HUD only when the setting is on.
        let watch = NotchPowerWatch()
        var posted: [HUDItem] = []
        var reading = r(50, ac: false)
        watch.read = { reading }
        watch.post = { posted.append($0) }
        watch.poll(); reading = r(50, ac: true); watch.poll(); watch.poll()
        check("watch: a plug-in posts one HUD (the baseline and a repeat post none)", posted.count == 1 && posted.first?.power?.state == .charging)
        Settings().notchChargeHUD = false
        reading = r(50, ac: false); watch.poll()
        check("watch: charging notices off: nothing posted", posted.count == 1)
        Settings().notchChargeHUD = true
        check("settings: low battery 20 % by default; choices off/10/20/30", Settings().notchLowBattery == 20 && Settings.lowBatteryChoices == [0, 10, 20, 30])
    }

    // MARK: the HUD with the battery

    static func hud(_ check: (String, Bool) -> Void) {
        var t = HUDTimeline()
        let charging = HUDItem(icon: "bolt.fill", text: "Charging", level: nil, power: ChargeGlyph(percent: 99, state: .charging))
        let full = HUDItem(icon: "bolt.fill", text: "Fully charged", level: nil, power: ChargeGlyph(percent: 100, state: .full))
        check("HUD: the battery drops the container", t.post(charging, now: 0) == .appear)
        check("HUD: charging → full updates the same glyph in place (no swap, no second drop)", t.post(full, now: 1) == .update)
        check("HUD: it stays \(HUDTimeline.powerTime) s", t.tick(now: 1 + HUDTimeline.powerTime - 0.1) == .none && t.tick(now: 1 + HUDTimeline.powerTime + 0.01) == .hide)
        var u = HUDTimeline()
        _ = u.post(charging, now: 0)
        check("HUD: a volume bar over it swaps inside the container and the battery comes back after", u.post(HUDItem(icon: "speaker.wave.2.fill", text: "Volume", level: 0.4), now: 0.2) == .swap
              && u.tick(now: 0.2 + HUDTimeline.levelQuiet + 0.01) == .swap && u.item?.power != nil)
        check("HUD: the battery's kind is its own (a text notice swaps it)", charging.kind == "power" && HUDItem(icon: "x", text: "Copied", level: nil).kind == "text")
    }

    // MARK: swipes

    static func swipes(_ check: (String, Bool) -> Void) {
        let s = NotchGestureSettings()
        let t = s.threshold
        func ev(_ dx: CGFloat, _ dy: CGFloat, _ p: NotchSwipe.Phase = .changed, momentum: Bool = false, precise: Bool = true) -> NotchSwipe.Event {
            NotchSwipe.Event(dx: dx, dy: dy, phase: p, momentum: momentum, precise: precise)
        }
        var w = NotchSwipe()
        _ = w.feed(ev(0, 0, .began), open: true, owned: true, settings: s)
        var acts: [NotchSwipe.Action] = []
        var progress: [CGFloat] = []
        for _ in 0..<20 { acts.append(w.feed(ev(0.5, -t / 8), open: true, owned: true, settings: s)); progress.append(w.progress) }
        check("swipe: up on the open island closes it once, at the threshold", acts.filter { $0 == .close }.count == 1 && acts.firstIndex(of: .close) == 7)
        check("swipe: …the live feedback deepens toward -1 before it acts, then rests at 0",
              zip(progress.prefix(6), progress.prefix(7).dropFirst()).allSatisfy { $1 < $0 } && progress[6] < -0.8 && progress.last == 0)
        _ = w.feed(ev(0, 0, .ended), open: false, owned: true, settings: s)
        check("swipe: ended: reset", w.progress == 0 && !w.fired)

        var d = NotchSwipe()
        _ = d.feed(ev(0, 0, .began), open: false, owned: true, settings: s)
        var a2: [NotchSwipe.Action] = []
        for _ in 0..<10 { a2.append(d.feed(ev(0, t / 4), open: false, owned: true, settings: s)) }
        check("swipe: down on the closed notch opens it, once", a2.filter { $0 == .open }.count == 1)
        var up = NotchSwipe()
        _ = up.feed(ev(0, 0, .began), open: false, owned: true, settings: s)
        check("swipe: up on a closed notch does nothing", (0..<10).allSatisfy { _ in up.feed(ev(0, -t / 4), open: false, owned: true, settings: s) == .none })

        func horizontal(_ dx: CGFloat) -> [NotchSwipe.Action] {
            var h = NotchSwipe()
            _ = h.feed(ev(0, 0, .began), open: true, owned: true, settings: s)
            return (0..<10).map { _ in h.feed(ev(dx, 0.3), open: true, owned: true, settings: s) }
        }
        check("swipe: fingers left → the next screen, right → the previous, once each", horizontal(-t / 4).filter { $0 == .screen(1) }.count == 1
              && horizontal(t / 4).filter { $0 == .screen(-1) }.count == 1)
        var diag = NotchSwipe()
        _ = diag.feed(ev(0, 0, .began), open: true, owned: true, settings: s)
        check("swipe: a diagonal (neither axis 1.5× the other) does nothing", (0..<20).allSatisfy { _ in diag.feed(ev(t / 4, -t / 4), open: true, owned: true, settings: s) == .none })
        var wheel = NotchSwipe()
        check("swipe: a mouse wheel is never a swipe", (0..<20).allSatisfy { i in wheel.feed(ev(0, -t, i == 0 ? .began : .other, precise: false), open: true, owned: true, settings: s) == .none })
        var mom = NotchSwipe()
        _ = mom.feed(ev(0, 0, .began), open: true, owned: true, settings: s)
        check("swipe: the momentum after lifting the fingers never acts", (0..<20).allSatisfy { _ in mom.feed(ev(0, -t, momentum: true), open: true, owned: true, settings: s) == .none })
        var over = NotchSwipe()
        _ = over.feed(ev(0, 0, .began), open: true, owned: false, settings: s)
        check("swipe: started over a list that scrolls: never the island's", (0..<20).allSatisfy { _ in over.feed(ev(0, -t), open: true, owned: true, settings: s) == .none })
        var off = s; off.enabled = false
        var o = NotchSwipe()
        _ = o.feed(ev(0, 0, .began), open: true, owned: true, settings: off)
        check("swipe: gestures off: nothing", (0..<10).allSatisfy { _ in o.feed(ev(0, -t), open: true, owned: true, settings: off) == .none })
        var noClose = s; noClose.swipeClose = false
        var nc = NotchSwipe()
        _ = nc.feed(ev(0, 0, .began), open: true, owned: true, settings: noClose)
        check("swipe: swipe up to close off: no close, no feedback", (0..<10).allSatisfy { _ in nc.feed(ev(0, -t), open: true, owned: true, settings: noClose) == .none } && nc.progress == 0)
        var rapid = NotchSwipe()
        var closes = 0
        for _ in 0..<50 {
            _ = rapid.feed(ev(0, 0, .began), open: true, owned: true, settings: s)
            for _ in 0..<4 { if rapid.feed(ev(0, -t / 2), open: true, owned: true, settings: s) == .close { closes += 1 } }
            _ = rapid.feed(ev(0, 0, .ended), open: true, owned: true, settings: s)
        }
        check("swipe: 50 rapid swipes: one close each, nothing left half-way", closes == 50 && rapid.progress == 0)
        check("swipe: sensitivity: high needs the least travel, low the most",
              NotchGestureSettings.threshold(.high) < NotchGestureSettings.threshold(.medium) && NotchGestureSettings.threshold(.medium) < NotchGestureSettings.threshold(.low))
        var saved = NotchGestureSettings(); saved.sensitivity = .high; saved.swipeScreens = false
        let d0 = MemoryDefaults()
        saved.save(d0)
        check("swipe: settings saved and read back; the defaults leave nothing stored", NotchGestureSettings.load(d0) == saved
              && { NotchGestureSettings().save(d0); return d0.object(forKey: NotchGestureSettings.key) == nil }())
        check("swipe: the feedback's scale stays within 0.94…1.1", GestureFollow.scale(-5) == 0.94 && GestureFollow.scale(5) == 1.1 && GestureFollow.scale(0) == 1)
    }

    // MARK: sizes

    static func sizes(_ check: (String, Bool) -> Void) {
        let z = NotchSizing()
        check("sizes: the defaults are the standard island (640 × 214, 150 pt bar, the menu bar's height)",
              z.preset == .standard && z.pill == NotchSizing.Pill(width: 150, height: nil) && z.openCorner == 32)
        var x = z; x.openWidth = 300; x.openHeight = .nan; x.openCorner = 99; x.pill.width = 5; x.pill.height = 90; x.perScreen = ["": .init(), "a": .init(width: 900)]
        let c = x.sanitized()
        check("sizes: out of range values are clamped (never smaller than the standard island)", c.openWidth == 640 && c.openHeight == 214 && c.openCorner == 40
              && c.pill.width == 110 && c.pill.height == 40 && c.perScreen.keys.sorted() == ["a"] && c.perScreen["a"]?.width == 260)
        var p = z; p.apply(.large)
        check("sizes: presets set the open size, and a custom size reads as custom", p.preset == .large && p.openWidth == 700
              && { var q = p; q.openWidth = 702; return q.preset == .custom }())
        var s = z; s.perScreen["k1"] = .init(width: 200, height: 30)
        check("sizes: a screen's own bar over everyone's", s.pill(for: "k1").width == 200 && s.pill(for: "other") == s.pill)
        check("sizes: the bar as tall as the menu bar (22…44), or the system's while it hides; a set height wins",
              NotchSizing.closedPill(.init(), bar: 24, fallback: 24).height == 24 && NotchSizing.closedPill(.init(), bar: 0, fallback: 24).height == 24
              && NotchSizing.closedPill(.init(), bar: 60, fallback: 24).height == 44 && NotchSizing.closedPill(.init(width: 180, height: 30), bar: 24, fallback: 24) == (180, 30))
        // The live island follows the store.
        let screen = NotchGeometry.Screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleTop: 1055, safeTop: 0, auxLeft: nil, auxRight: nil, builtin: false, id: 5, key: "k1")
        let notched = NotchGeometry.Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleTop: 950, safeTop: 32, auxLeft: 663, auxRight: 664, builtin: true, id: 1, key: "k2")
        NotchPrefs.shared.updateSizing { $0.apply(.extraLarge); $0.perScreen["k1"] = .init(width: 220, height: nil); $0.pill.width = 170 }
        let g = NotchGeometry.make(screen, barThickness: 24), gn = NotchGeometry.make(notched, barThickness: 24)
        check("sizes: the island's open size, window and page box follow the setting", Island.openSize == CGSize(width: 760, height: 274)
              && IslandController.windowFrame(g, open: true).width == 760 + 2 * Island.slack && IslandLayout.openBody == 732
              && ScreenLayout.contentSize(stripHeight: 32).height == 274 - 32 - 24)
        check("sizes: a bar screen takes its own width; a notched screen keeps the notch's", g.notchWidth == 220 && g.height == 25 && gn.notchWidth == 185 && gn.height == 32)
        let l0 = IslandLayout(notch: 185, notchH: 32), l1 = IslandLayout(notch: 185, notchH: 32, closedCorner: 6, openCorner: 20)
        let pose = IslandPose(p: 1, leftW: 62, rightW: 62)
        check("sizes: the corners change the outline (open and closed)", l0.path(pose).description != l1.path(pose).description
              && l0.path(IslandPose(p: 0, leftW: 62, rightW: 62)).description != l1.path(IslandPose(p: 0, leftW: 62, rightW: 62)).description)
        NotchPrefs.shared.updateSizing { $0 = NotchSizing() }
        check("sizes: reset: the standard island again, nothing stored", Island.openSize == CGSize(width: 640, height: 214) && AppDefaults.store.object(forKey: NotchPrefs.sizingKey) == nil)
        check("sizes: the display key is empty for the render tools' display 0", NotchSizing.displayKey(0) == "")
    }

    // MARK: controls

    static func controls(_ check: (String, Bool) -> Void) {
        let c = NotchControlsConfig(shown: ["next", "bogus", "next", "cocaine", "mute", "focus", "screenshot", "displaySleep", "reminders", "settings"]).sanitized()
        check("controls: unknown and repeated ids go, at most 7 kept in order", c.shown == ["next", "cocaine", "mute", "focus", "screenshot", "displaySleep", "reminders"])
        var d = NotchControlsConfig()
        check("controls: the standard row, the rest hidden", d.shown == NotchControlsConfig.standard && Set(d.hidden + d.shown).count == NotchControlCatalog.all.count)
        check("controls: move within the row, not past its ends", d.move("next", by: -1) && d.shown[3] == "next" && !d.move("cocaine", by: -1) && !d.move("settings", by: 1))
        check("controls: show at the end, hide; not twice, not past the limit", d.set("mute", shown: true) && d.shown.last == "mute" && !d.set("mute", shown: true)
              && !d.set("focus", shown: true) && d.set("cocaine", shown: false) && !d.isShown("cocaine") && d.set("focus", shown: true))
        check("controls: the catalog's ids are unique", Set(NotchControlCatalog.all.map(\.id)).count == NotchControlCatalog.all.count)
        NotchPrefs.shared.updateControls { $0.set("settings", shown: false) }
        check("controls: saved through the store; the standard row again stores nothing",
              AppDefaults.store.data(forKey: NotchPrefs.controlsKey) != nil && { NotchPrefs.shared.updateControls { $0 = NotchControlsConfig() }; return AppDefaults.store.data(forKey: NotchPrefs.controlsKey) == nil }())
        // The modules and the Reminders screen.
        let std = ScreenLayout.standard
        check("screens: the Reminders screen exists, hidden until shown (the tabs stay as they were)", std.config("reminders")?.visible == false
              && !std.visibleScreens(external: true).contains { $0.id == "reminders" })
        check("screens: a layout stored before 2.8 gets the Reminders screen hidden", ScreenLayout(screens: [ScreenConfig(id: "home", visible: true, modules: [])]).sanitized().config("reminders")?.visible == false)
        var l = std
        check("screens: Controls and Reminders can be added to Home", l.addable(to: "home").map(\.id).contains("controls") && l.addModule("controls", to: "home"))
        let r = ScreenLayout.resolve(l.config("home")!, in: ScreenLayout.contentSize(stripHeight: 32))
        check("screens: …and Home still draws everything (made smaller where needed, nothing left out)", r.modules.count == 3 && !r.issues.contains { if case .noRoom = $0 { return true }; return false })
        let rr = ScreenLayout.resolve(std.config("reminders")!, in: ScreenLayout.contentSize(stripHeight: 32))
        check("screens: the Reminders screen draws its module whole", rr.issues.isEmpty && rr.modules.first?.kind == "reminders")
        _ = l
    }

    // MARK: reminders

    static func reminders(_ check: (String, Bool) -> Void) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = ISO8601DateFormatter().date(from: "2026-10-08T10:00:00+02:00")!
        func at(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }
        let items = [ReminderItem(id: "a", title: "Pay rent", due: at(-30), listID: "home"),
                     ReminderItem(id: "b", title: "Call Anna", due: at(-1), allDay: false, listID: "work"),
                     ReminderItem(id: "c", title: "Buy milk", due: cal.startOfDay(for: now), listID: "home"),
                     ReminderItem(id: "d", title: "Standup", due: at(3), allDay: false, listID: "work", priority: 1),
                     ReminderItem(id: "e", title: "Dentist", due: at(48), listID: "home"),
                     ReminderItem(id: "f", title: "Someday", listID: "home")]
        let sec = RemindersLogic.sections(items, filter: .today, now: now, cal: cal)
        check("reminders: today = overdue first, then today; an all-day today isn't overdue", sec.map(\.0) == [.overdue, .today]
              && sec[0].1.map(\.id) == ["a", "b"] && sec[1].1.map(\.id) == ["c", "d"])
        check("reminders: scheduled adds upcoming; all adds the undated", RemindersLogic.sections(items, filter: .scheduled, now: now, cal: cal).map(\.0) == [.overdue, .today, .upcoming]
              && RemindersLogic.sections(items, filter: .all, now: now, cal: cal).last?.1.map(\.id) == ["f"])
        check("reminders: a quick add is trimmed, and nothing for blanks", RemindersLogic.cleanTitle("  Milk \n") == "Milk" && RemindersLogic.cleanTitle("   ") == nil)

        let d = MemoryDefaults()
        let w = RemindersWatch(defaults: { d })
        w.now = { now }; w.cal = cal
        var later: [() -> Void] = []
        w.after = { _, f in later.append(f) }
        let src = FakeReminders(access: .notAsked, items: items)
        w.use(src)
        check("reminders: not asked yet: nothing read, the island asks", w.access == .notAsked && w.items.isEmpty)
        w.requestAccess()
        check("reminders: allowed: the lists and the reminders come", w.access == .granted && w.items.count == 6 && w.lists.count == 2 && w.shownCount == 4)
        w.toggle("a")
        check("reminders: ticked: shown ticked, not saved yet", w.completing.contains("a") && src.completed.isEmpty)
        w.toggle("a")
        later.forEach { $0() }; later.removeAll()
        check("reminders: ticked again before it leaves: back, never saved", !w.completing.contains("a") && src.completed.isEmpty && w.items.contains { $0.id == "a" })
        w.toggle("b"); later.forEach { $0() }; later.removeAll()
        check("reminders: after the moment: saved as completed and gone", src.completed == ["b"] && !w.items.contains { $0.id == "b" } && w.completing.isEmpty)
        for _ in 0..<15 { w.toggle("c") }
        later.forEach { $0() }; later.removeAll()
        check("reminders: 15 rapid clicks (odd): completed once", src.completed == ["b", "c"])
        src.failSave = true
        w.toggle("d"); later.forEach { $0() }; later.removeAll()
        check("reminders: a save that fails: put back, and said", w.items.contains { $0.id == "d" } && !w.completing.contains("d") && w.problem != nil)
        src.failSave = false
        w.draft = "   "
        check("reminders: an empty quick add adds nothing", !w.addDraft())
        w.update { $0.addTo = "work" }
        w.draft = "Book flights"
        check("reminders: a quick add goes to the chosen list, due today on the today page, and clears the field", w.addDraft() && w.draft.isEmpty
              && src.items.last?.listID == "work" && src.items.last?.due.map { cal.isDate($0, inSameDayAs: now) } == true && w.problem == nil)
        w.update { $0.lists = ["work"] }
        check("reminders: only the lists picked are shown; the settings are saved", w.items.allSatisfy { $0.listID == "work" }
              && RemindersWatch(defaults: { d }).settings.lists == ["work"])
        let denied = RemindersWatch(defaults: { d })
        let ds = FakeReminders(access: .notAsked); ds.grant = false
        denied.use(ds); denied.requestAccess()
        check("reminders: refused: the island says so (no list read)", denied.access == .denied && denied.lists.isEmpty)
    }

    // MARK: motion

    static func motion(_ check: (String, Bool) -> Void) {
        check("motion: the notch opens on its own spring (Boring Notch's 0.42 / 0.8) and closes critically damped",
              Motion.curve(.islandOpen, reduce: false) == .spring(Motion.notchOpen) && Motion.curve(.islandClose, reduce: false) == .spring(Motion.notchClose)
              && Motion.notchClose.damping == 1)
        check("motion: the window shrinks only after the close spring has settled", Motion.islandSettle >= Motion.notchClose.settle)
        check("motion: Reduce Motion: the battery's fill and a followed swipe change at once; the bolt and the modules fade",
              Motion.curve(.levelFill, reduce: true) == nil && Motion.curve(.gestureFollow, reduce: true) == nil
              && Motion.curve(.chargeIn, reduce: true) == .easeOut(Motion.Duration.quick) && Motion.curve(.contentIn, reduce: true) != nil)
        let a0 = (0...20).map { ModuleStagger.arrival(CGFloat($0) / 20, order: 0) }, a3 = (0...20).map { ModuleStagger.arrival(CGFloat($0) / 20, order: 3) }
        check("motion: modules arrive one after another: each never ahead of the one before, all in place when open, none when closed",
              zip(a0, a3).allSatisfy { $0 >= $1 } && a0.last == 1 && a3.last == 1 && a0.first == 0 && a3.first == 0
              && zip(a3, a3.dropFirst()).allSatisfy { $0 <= $1 })
        check("motion: the stagger is short (the last module in by 40 % more of the morph at most)", ModuleStagger.lag(100) <= 0.45)
    }
}

/// `--notch-test`, run from main.swift.
func cliNotchTest() { exit(NotchTests.run() == 0 ? 0 : 1) }

// MARK: - Render samples

/// `--notch-fixture <name>` for --render-island / --render-panel: charging, full, low, unplugged, lowpower (the battery HUD),
/// reminders (the Reminders screen with sample reminders), reminders-ask (its permission), controls (the Controls module on Home),
/// sizes (a large island). Sample data only.
enum NotchFixtures {
    static func name(_ args: [String]) -> String? { args.firstIndex(of: "--notch-fixture").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

    /// Before the island's model is made (layout and sizes).
    static func layout(_ args: [String]) {
        guard let n = name(args) else { return }
        switch n {
        case "controls": ScreenLayoutStore.shared.update { $0.addModule("controls", to: "home") }
        case "reminders", "reminders-ask":
            ScreenLayoutStore.shared.update { $0.setVisible("reminders", true) }
            let w = RemindersWatch()                                  // Settings → Island → Notch: sample lists
            w.use(FakeReminders(access: n == "reminders" ? .granted : .notAsked))
            NotchSettingsLink.reminders = w
        case "sizes", "large": NotchPrefs.shared.updateSizing { $0.apply(.large) }
        case "xl": NotchPrefs.shared.updateSizing { $0.apply(.extraLarge) }
        case let n where n.hasPrefix("mod-"):        // mod-<kind>-<s|m|l>[-xl|-max]: one module at a size on Home, beside Agents
            let parts = n.split(separator: "-").map(String.init)
            guard parts.count >= 3, let size = ModuleSize(rawValue: parts[2]) else { break }
            if parts.count > 3 { NotchFixtures.layout(["", "--notch-fixture", parts[3]]) }
            ScreenLayoutStore.shared.update { l in
                guard let i = l.screens.firstIndex(where: { $0.id == "home" }) else { return }
                l.screens[i].modules = [ModulePlacement(parts[1], 0, size)] + (parts[1] == "agents" ? [] : [ModulePlacement("agents", 1, .l)])
            }
        case "max": NotchPrefs.shared.updateSizing { $0.openWidth = NotchSizing.openWidths.upperBound; $0.openHeight = NotchSizing.openHeights.upperBound }
        default: break
        }
    }

    static func apply(_ args: [String], _ im: IslandModel) {
        guard let n = name(args) else { return }
        func power(_ e: ChargeEvent, _ r: PowerReading) { im.flashItem(ChargeEvents.item(e, r, low: 20)) }
        switch n {
        case "charging": power(.connected, PowerReading(percent: 62, onAC: true, charging: true, minutesToFull: 48))
        case "full": power(.full, PowerReading(percent: 100, onAC: true, charged: true))
        case "low": power(.low(20), PowerReading(percent: 18, onAC: false))
        case "unplugged": power(.disconnected, PowerReading(percent: 86, onAC: false, minutesToEmpty: 412))
        case "lowpower": power(.lowPower(true), PowerReading(percent: 41, onAC: false, lowPower: true))
        case "reminders", "reminders-ask":
            let now = Date(), cal = Calendar.autoupdatingCurrent
            let src = FakeReminders(access: n == "reminders" ? .granted : .notAsked, items: [
                ReminderItem(id: "1", title: "Send the invoice to Marco", due: now.addingTimeInterval(-86400), listID: "work"),
                ReminderItem(id: "2", title: "Buy milk", due: cal.startOfDay(for: now), listID: "home"),
                ReminderItem(id: "3", title: "Call the tyre shop", due: now.addingTimeInterval(3600), allDay: false, listID: "work", priority: 1),
                ReminderItem(id: "4", title: "Water the plants", due: cal.startOfDay(for: now), listID: "home")])
            im.reminders.use(src)
            im.tab = "reminders"
            NotchSettingsLink.reminders = im.reminders
        default: break
        }
    }
}
