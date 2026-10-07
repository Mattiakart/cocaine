// Tests for the dimming and lid rule (DimController on fake displays), the media keys, the island's screen and full-screen
// checks, the battery floor and the DDC queue. Part of --selftest (displaySelfTest), and alone as --display-test.

import AppKit

/// Displays that exist only in memory: every change is recorded, the clock and the lid are the test's.
final class FakeDisplays: DisplayIO {
    struct D { var builtin: Bool; var backlit: Bool; var brightness: Float; var gamma: Float = 1; var online = true; var readable = true }
    var displays: [CGDirectDisplayID: D] = [:]
    var lidClosed = false
    var now = Date(timeIntervalSince1970: 1_000_000)
    var minimum: [CGDirectDisplayID: Float] = [:]       // the lowest each display was ever set to
    var gammaRestores = 0

    var online: [CGDirectDisplayID] { displays.filter { $0.value.online }.keys.sorted() }
    func isBuiltin(_ d: CGDirectDisplayID) -> Bool { displays[d]?.builtin ?? false }
    func hasBacklight(_ d: CGDirectDisplayID) -> Bool { displays[d]?.backlit ?? false }
    func brightness(_ d: CGDirectDisplayID) -> Float? {
        guard let x = displays[d], x.backlit, x.readable else { return nil }
        return x.brightness
    }
    func setBrightness(_ d: CGDirectDisplayID, _ v: Float) {
        let v = min(max(v, 0.01), 1)
        displays[d]?.brightness = v
        minimum[d] = min(minimum[d] ?? 1, v)
    }
    func setGamma(_ d: CGDirectDisplayID, _ scale: Float) { displays[d]?.gamma = scale; minimum[d] = min(minimum[d] ?? 1, scale) }
    func restoreGamma(_ d: CGDirectDisplayID) { displays[d]?.gamma = 1; gammaRestores += 1 }
}

func displaySelfTest(_ check: (String, Bool) -> Void) {
    dimSelfTest(check)
    keysSelfTest(check)
    screensSelfTest(check)
    batteryFloorSelfTest(check)
    ddcSelfTest(check)
    islandSelfTest(check)          // Sources/IslandTests.swift
}

private func dimSelfTest(_ check: (String, Bool) -> Void) {
    let builtin: CGDirectDisplayID = 1, studio: CGDirectDisplayID = 2, dell: CGDirectDisplayID = 3
    final class Rig {
        let io = FakeDisplays()
        lazy var dim = DimController(io: io) { [unowned self] in
            self.leases.append($0)
            self.leaseSaw.append(self.io.displays.values.filter(\.backlit).map(\.brightness).min() ?? 1)
        }
        var leases: [[RecoveryLease.Dim]] = []
        var leaseSaw: [Float] = []           // the darkest backlit display when each lease was written
        var i = DimInputs(on: true, dimEnabled: true, screenOff: false, sessionActive: true, idle: 0, delay: 60, level: 0.2, allowed: true)
        /// `seconds` of app time: a tick every 0.5 s, the fade timer every 25 ms in between.
        func run(_ seconds: Double) {
            var t = 0.0
            while t < seconds - 1e-9 {
                if Int((t * 1000).rounded()) % 500 == 0 { dim.tick(i) }
                dim.fadeStep()
                io.now = io.now.addingTimeInterval(0.025); t += 0.025
                if i.idle > 0 { i.idle += 0.025 }
            }
        }
        func b(_ d: CGDirectDisplayID) -> Float { io.displays[d]!.brightness }
        func g(_ d: CGDirectDisplayID) -> Float { io.displays[d]!.gamma }
    }
    func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.001 }

    do {   // (b) lid closed, no external: only the built-in, at once; open: exactly its level from before
        let r = Rig()
        r.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.63)]
        r.run(1)
        r.io.lidClosed = true
        r.dim.lidChanged(closed: true)                   // the notification
        r.run(0.3)
        check("lid: closing it puts the built-in to the minimum within 0.3 s", near(r.b(builtin), DimController.lidLevel))
        check("lid: …whatever the idle setting (dimming off)", { let x = Rig(); x.i.dimEnabled = false
            x.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.5)]; x.run(1); x.io.lidClosed = true; x.run(1)
            return near(x.b(builtin), DimController.lidLevel) }())
        check("lid: the lease says where to restore before anything is lowered",
              r.leases.first.map { $0.count == 1 && near($0[0].from, 0.63) && near($0[0].to, DimController.lidLevel) } == true
              && r.leaseSaw.first.map { near($0, 0.63) } == true)
        r.i.idle = 300; r.run(5)                         // a long while away with the lid shut: still the minimum
        check("lid: stays at the minimum while it's closed", near(r.b(builtin), DimController.lidLevel))
        r.i.idle = 0
        r.io.lidClosed = false
        r.dim.lidChanged(closed: false)
        r.run(1)
        check("lid: opening it gives back exactly the level from before the close", near(r.b(builtin), 0.63) && !r.dim.busy)
        check("lid: …and the lease is cleared once it's back", r.leases.last == [])
    }
    do {   // (a) clamshell: the built-in goes offline a moment after the close; the externals are never touched by the lid
        let r = Rig()
        r.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.7), studio: .init(builtin: false, backlit: true, brightness: 0.8),
                         dell: .init(builtin: false, backlit: false, brightness: 0)]
        r.run(1)
        r.io.lidClosed = true; r.dim.lidChanged(closed: true)
        r.run(1)
        r.io.displays[builtin]!.online = false          // macOS turns the panel off
        r.run(2)
        check("clamshell: the external displays are not touched by the lid", near(r.b(studio), 0.8) && near(r.g(dell), 1)
              && r.io.minimum[studio] == nil && r.io.minimum[dell] == nil)
        r.i.idle = 61; r.run(3)
        check("clamshell: idle dims the externals to the idle level, never lower", near(r.b(studio), 0.2) && (r.io.minimum[studio] ?? 0) >= 0.2 - 0.001
              && near(r.g(dell), DimController.gammaFloor + (1 - DimController.gammaFloor) * 0.2))
        r.i.idle = 0; r.run(1)
        check("clamshell: input brings the externals back", near(r.b(studio), 0.8) && near(r.g(dell), 1))
        r.i.idle = 61; r.run(3); r.i.dimEnabled = false; r.run(1)
        check("clamshell: turning dimming off brings them back too", near(r.b(studio), 0.8) && near(r.g(dell), 1))
        r.i.dimEnabled = true; r.i.idle = 0
        r.io.lidClosed = false; r.io.displays[builtin]!.online = true
        r.dim.lidChanged(closed: false); r.run(1)
        check("clamshell: the built-in comes back from the lid at its level from before", near(r.b(builtin), 0.7))
    }
    do {   // (c) the lid closes while idle-dimmed: built-in to the minimum, externals stay at the idle level; back at the end
        let r = Rig()
        r.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.6), studio: .init(builtin: false, backlit: true, brightness: 0.9)]
        r.i.idle = 61; r.run(3)
        check("idle: every display at the idle level", near(r.b(builtin), 0.2) && near(r.b(studio), 0.2))
        r.io.lidClosed = true; r.dim.lidChanged(closed: true); r.run(1)
        check("idle + lid: built-in to the minimum, the external stays at the idle level", near(r.b(builtin), DimController.lidLevel) && near(r.b(studio), 0.2))
        r.io.lidClosed = false; r.dim.lidChanged(closed: false); r.run(3)
        check("idle + lid open: the built-in back to the idle level (still idle)", near(r.b(builtin), 0.2))
        r.i.idle = 0; r.run(1)
        check("idle + lid: input gives every display its level from before the idle dim", near(r.b(builtin), 0.6) && near(r.b(studio), 0.9))
    }
    do {   // (d) a display unplugged while dimmed: the others stay dimmed (no restore and re-dim flicker); back still dimmed: ours again
        let r = Rig()
        r.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.6), studio: .init(builtin: false, backlit: true, brightness: 0.9)]
        r.i.idle = 61; r.run(3)
        r.io.displays[studio]!.online = false; r.run(1)
        let stayed = near(r.b(builtin), 0.2) && (r.io.minimum[builtin] ?? 1) >= 0.2 - 0.001
        check("unplug: the other display stays dimmed, without a flicker up", stayed && r.dim.isLowered(builtin))
        check("unplug: the lease keeps the unplugged display", r.leases.last?.contains { $0.id == studio && near($0.from, 0.9) } ?? false)
        r.io.displays[studio]!.online = true; r.run(1)
        r.i.idle = 0; r.run(1)
        check("unplug: plugged back still dimmed, it is restored with the rest", near(r.b(studio), 0.9) && near(r.b(builtin), 0.6))
    }
    do {   // (e) another user's session: everything back, nothing dimmed, nothing forced
        let r = Rig()
        r.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.6)]
        r.i.idle = 61; r.run(3)
        r.i.sessionActive = false; r.run(1)
        check("session: switching to another user restores the screen", near(r.b(builtin), 0.6) && !r.dim.busy)
        r.io.lidClosed = true; r.dim.lidChanged(closed: true); r.run(2)
        r.io.displays[builtin]!.brightness = 0.95; r.run(6)
        check("session: under the other user no lid dim and no creep fix", near(r.b(builtin), 0.95) && !r.dim.busy)
    }
    do {   // (f) close, open, close within one restore fade: the final level is the original, never a half-restored one
        let r = Rig()
        r.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.8)]
        r.run(1)
        r.io.lidClosed = true; r.dim.lidChanged(closed: true); r.run(0.5)
        r.io.lidClosed = false; r.dim.lidChanged(closed: false); r.dim.fadeStep(); r.io.now += 0.1; r.dim.fadeStep()   // mid-restore
        let mid = r.b(builtin)
        r.io.lidClosed = true; r.dim.lidChanged(closed: true); r.run(0.5)
        r.io.lidClosed = false; r.dim.lidChanged(closed: false); r.run(1)
        check("lid: close/open/close during a restore fade ends at the original level (F11)", mid > 0.02 && mid < 0.79 && near(r.b(builtin), 0.8))
    }
    do {   // (g) quit during a restore fade: every display at its original, the lease cleared only after
        let r = Rig()
        r.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.7), dell: .init(builtin: false, backlit: false, brightness: 0)]
        r.i.idle = 61; r.run(3)
        r.i.idle = 0; r.dim.tick(r.i); r.dim.fadeStep(); r.io.now += 0.1; r.dim.fadeStep()
        let leasedBefore = r.leases.last?.isEmpty == false
        r.dim.quit()
        check("quit: in the middle of a restore fade every display is back (F12)", near(r.b(builtin), 0.7) && near(r.g(dell), 1) && leasedBefore && r.leases.last == [])
    }
    do {   // (h) an alert with the lid closed, then idle again: input still restores (nothing stale)
        let r = Rig()
        r.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.6), studio: .init(builtin: false, backlit: true, brightness: 0.9)]
        r.io.lidClosed = true; r.dim.lidChanged(closed: true); r.run(1)
        r.i.idle = 61; r.run(3)
        r.i.allowed = false; r.run(1)                    // an alert: the screens stay bright for a while
        check("alert: the idle dim lets go, the built-in behind the lid stays at the minimum",
              near(r.b(studio), 0.9) && near(r.b(builtin), DimController.lidLevel))
        r.i.allowed = true; r.run(3)
        check("alert: afterwards idle dims again", near(r.b(studio), 0.2))
        r.i.idle = 0; r.run(1)
        check("alert: …and input restores it (no stale lid state, F13)", near(r.b(studio), 0.9))
    }
    do {   // (i) automatic brightness creeping up is put back; a big change someone made is kept
        let r = Rig()
        r.io.displays = [studio: .init(builtin: false, backlit: true, brightness: 0.9)]
        r.i.idle = 61; r.run(3)
        r.io.displays[studio]!.brightness = 0.25; r.run(1)
        check("creep: automatic brightness pushing a dimmed screen up a little is put back", near(r.b(studio), 0.2))
        r.io.displays[studio]!.brightness = 0.7; r.run(1)
        check("creep: a big change made by someone is kept (not Cocaine's)", near(r.b(studio), 0.7) && !r.dim.isLowered(studio))
        r.run(2)
        check("creep: …and not pulled down again while the same idle stretch lasts", { r.i.idle = 0; r.run(1); return near(r.b(studio), 0.7) }())
    }
    do {   // (j) the lid's original: the reading at the notification, unless the panel already started powering down
        check("lid original: the reading at the notification", DimController.lidOriginal(current: 0.6, lastSeen: 0.62) == 0.6)
        check("lid original: a reading already lower than just before is not trusted", DimController.lidOriginal(current: 0.1, lastSeen: 0.6) == 0.6)
        check("lid original: no reading at all → the last one seen", DimController.lidOriginal(current: nil, lastSeen: 0.5) == 0.5)
        let r = Rig()
        r.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.55)]
        r.run(1)
        r.io.displays[builtin]!.brightness = 0.05        // macOS ramping the panel down before we read it
        r.io.lidClosed = true; r.dim.lidChanged(closed: true); r.run(1)
        r.io.lidClosed = false; r.dim.lidChanged(closed: false); r.run(1)
        check("lid: a panel already powering down at the close still gets its real level back (F15)", near(r.b(builtin), 0.55))
    }
    do {   // (k) launched (or turned on) with the lid already closed; Cocaine off restores; screen-off mode still dims the lid
        let r = Rig()
        r.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.5)]
        r.io.lidClosed = true
        r.i.on = false; r.run(1)
        check("lid: nothing while Cocaine is off", near(r.b(builtin), 0.5))
        r.i.on = true; r.run(1)
        check("lid: turned on with the lid already closed → the built-in goes down too", near(r.b(builtin), DimController.lidLevel))
        r.i.screenOff = true; r.run(1)
        check("lid: also in screen-off mode", near(r.b(builtin), DimController.lidLevel))
        r.i.on = false; r.run(1)
        check("lid: Cocaine turned off with the lid closed → back to its level", near(r.b(builtin), 0.5) && !r.dim.busy)
    }
    do {   // the built-in leaves the list while lid-dimmed and comes back at our minimum: put back
        let r = Rig()
        r.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.66), studio: .init(builtin: false, backlit: true, brightness: 0.5)]
        r.run(1)
        r.io.lidClosed = true; r.dim.lidChanged(closed: true); r.run(1)
        r.io.displays[builtin]!.online = false; r.run(2)
        r.io.lidClosed = false; r.io.displays[builtin]!.online = true; r.dim.lidChanged(closed: false); r.run(1)
        check("clamshell: a built-in that comes back at our minimum gets its level back", near(r.b(builtin), 0.66))
    }
    do {   // preview: the idle level for a moment, then back, also with Cocaine off
        let r = Rig()
        r.i.on = false
        r.io.displays = [builtin: .init(builtin: true, backlit: true, brightness: 0.6)]
        r.run(0.5); r.dim.preview(); r.run(2)
        let down = near(r.b(builtin), 0.2)
        r.run(3)
        check("preview: down to the chosen level, then back by itself", down && near(r.b(builtin), 0.6) && !r.dim.busy)
    }
    do {   // never below the display's own level: a screen already darker than the dim level is left alone
        let r = Rig()
        r.io.displays = [studio: .init(builtin: false, backlit: true, brightness: 0.1)]
        r.i.idle = 61; r.run(3)
        check("idle: a screen already darker than the dim level is not touched", near(r.b(studio), 0.1) && !r.dim.isLowered(studio))
    }
}

private func keysSelfTest(_ check: (String, Bool) -> Void) {
    var t = MediaKeyTracker()
    var steps = 0
    // A press left to macOS (the screen lowered), then Cocaine could handle it (the dim lets go): the rest of that press is macOS's.
    check("keys: a passed press stays passed through its repeats (F2)",
          !t.down(2, isRepeat: false) { false } && !t.down(2, isRepeat: true) { steps += 1; return true } && steps == 0)
    check("keys: …and its release reaches macOS", !t.up(2))
    check("keys: a swallowed press swallows its repeats, each one a step", t.down(3, isRepeat: false) { steps += 1; return true }
          && t.down(3, isRepeat: true) { steps += 1; return false } && steps == 2 && t.up(3))
    check("keys: the repeat bit is read", MediaKeys.decode(data1: (2 << 16) | (0xA << 8) | 1)?.isRepeat == true
          && MediaKeys.decode(data1: (2 << 16) | (0xA << 8))?.isRepeat == false)
    check("keys: no modifier → a normal step", MediaKeys.route([]) == (false, false))
    check("keys: ⌥⇧ → a fine step", MediaKeys.route([.option, .shift]) == (false, true))
    check("keys: ⌥ alone is macOS's (opens Sound / Displays settings), not swallowed", MediaKeys.route([.option]).pass)
    check("keys: ⌃, ⌘ and ⇧ combos are passed through", MediaKeys.route([.control]).pass && MediaKeys.route([.command]).pass
          && MediaKeys.route([.shift]).pass && MediaKeys.route([.option, .control]).pass)
    check("keys: caps lock and fn don't count as modifiers", MediaKeys.route([.capsLock, .function]) == (false, false))
    check("stay available: nudged just before the 5-minute away timers", Presence.nudgeAfter(screenSaverIdle: nil) == 270)
    check("stay available: …or before an earlier screen saver (which locks the Mac)", Presence.nudgeAfter(screenSaverIdle: 120) == 90)
    check("stay available: never more often than every 45 s", Presence.nudgeAfter(screenSaverIdle: 60) == 45)
    check("hud: before macOS 26 the system helper is frozen, from 26 nothing is", SystemHUD.freezesHelper(osMajor: 15)
          && !SystemHUD.freezesHelper(osMajor: 26) && !SystemHUD.freezesHelper(osMajor: 27))
    check("hud: automatic brightness drift is not shown", !HUDWatch.reports(delta: 0.01, sinceKey: 60))
    check("hud: a key step or a slider jump is", HUDWatch.reports(delta: 0.0625, sinceKey: 60) && HUDWatch.reports(delta: -0.004, sinceKey: 0.3))
}

private func screensSelfTest(_ check: (String, Bool) -> Void) {
    typealias W = IslandController.Window
    // Built-in 1512×982 (main, at the origin) and a 2560×1440 monitor to its right, top-aligned (AppKit y = 982-1440).
    let builtinAK = CGRect(x: 0, y: 0, width: 1512, height: 982), extAK = CGRect(x: 1512, y: -458, width: 2560, height: 1440)
    let builtinG = IslandController.globalRect(builtinAK, primaryHeight: 982), extG = IslandController.globalRect(extAK, primaryHeight: 982)
    check("full screen: coordinates are converted (AppKit → window server)", builtinG == CGRect(x: 0, y: 0, width: 1512, height: 982)
          && extG == CGRect(x: 1512, y: 0, width: 2560, height: 1440))
    let big = W(layer: 0, pid: 42, bounds: CGRect(x: 1600, y: 30, width: 2400, height: 1400))
    check("full screen: a big window on the other monitor doesn't hide the built-in's island (F5)",
          !IslandController.covers(screen: builtinG, topInset: 32, windows: [big], ownPID: 1))
    let fs = W(layer: 0, pid: 42, bounds: CGRect(x: 0, y: 32, width: 1512, height: 950))
    check("full screen: a full-screen app on this screen does (below the camera strip)", IslandController.covers(screen: builtinG, topInset: 32, windows: [fs], ownPID: 1))
    let zoomed = W(layer: 0, pid: 42, bounds: CGRect(x: 0, y: 37, width: 1512, height: 945))
    check("full screen: a zoomed window that stops below the menu bar doesn't", !IslandController.covers(screen: builtinG, topInset: 32, windows: [zoomed], ownPID: 1))
    check("full screen: our own windows and other levels don't count", !IslandController.covers(screen: builtinG, windows: [W(layer: 0, pid: 1, bounds: builtinG), W(layer: 25, pid: 9, bounds: builtinG)], ownPID: 1))
    let leftAK = CGRect(x: -1920, y: 982, width: 1920, height: 1080)            // above and to the left: negative x, above the main
    let leftG = IslandController.globalRect(leftAK, primaryHeight: 982)
    check("full screen: a screen above-left has negative global coordinates", leftG == CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
          && IslandController.covers(screen: leftG, windows: [W(layer: 0, pid: 5, bounds: leftG)], ownPID: 1)
          && !IslandController.covers(screen: builtinG, windows: [W(layer: 0, pid: 5, bounds: leftG)], ownPID: 1))

    typealias S = NotchGeometry.Screen
    let notched = S(frame: builtinAK, visibleTop: 945, safeTop: 32, auxLeft: 663.5, auxRight: 663.5, builtin: true)
    let monitor = S(frame: extAK, visibleTop: extAK.maxY - 25, safeTop: 0, auxLeft: nil, auxRight: nil, builtin: false)
    let g1 = NotchGeometry.choose([monitor, notched], barThickness: 24)
    check("island screen: the notch even when its screen isn't first", g1?.hasNotch == true && g1?.frame == builtinAK && g1?.centerX == 756)
    let air = S(frame: builtinAK, visibleTop: 958, safeTop: 0, auxLeft: nil, auxRight: nil, builtin: true)
    let g2 = NotchGeometry.choose([monitor, air], barThickness: 24)
    check("island screen: no notch → the built-in, whichever screen is first (not the focused one, F6)", g2?.frame == builtinAK && g2?.hasNotch == false)
    let mon2 = S(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visibleTop: 1055, safeTop: 0, auxLeft: nil, auxRight: nil, builtin: false)
    check("island screen: clamshell with two monitors → the main one (first), always the same",
          NotchGeometry.choose([monitor, mon2], barThickness: 24)?.frame == extAK && NotchGeometry.choose([monitor, mon2], barThickness: 24)?.frame == extAK)
    check("island screen: the pill is as tall as that screen's menu bar", g2?.height == 24 && NotchGeometry.choose([monitor], barThickness: 24)?.height == 25)
    let hidden = S(frame: extAK, visibleTop: extAK.maxY, safeTop: 0, auxLeft: nil, auxRight: nil, builtin: false)
    let g3 = NotchGeometry.choose([hidden], barThickness: 24)
    check("island screen: a hidden menu bar is noticed (the pill waits for the top edge)", g3?.menuBarHidden == true && g3?.height == 24)
    check("island screen: no screens → none", NotchGeometry.choose([], barThickness: 24) == nil)
}

private func batteryFloorSelfTest(_ check: (String, Bool) -> Void) {
    var f = BatteryFloor()
    check("battery floor: at 5 % on battery Cocaine lets go even with the guard off (F9)", f.check(percent: 5, onAC: false, on: true) == .release)
    check("battery floor: told once, then quiet while Cocaine stays off", f.check(percent: 5, onAC: false, on: false) == .none)
    check("battery floor: turned on again at 4 % → let go again (not just once)", f.check(percent: 4, onAC: false, on: true) == .releaseQuietly)
    check("battery floor: triggers stay blocked until it's well above", f.blocks(percent: 7, onAC: false) && !f.blocks(percent: 3, onAC: true)
          && { var x = f; _ = x.check(percent: 9, onAC: false, on: false); return !x.blocks(percent: 7, onAC: false) }())
    check("battery floor: never on the charger", f.check(percent: 2, onAC: true, on: true) == .none)
    check("battery floor: above it nothing, and no block before it ever acted", { var x = BatteryFloor()
        return x.check(percent: 6, onAC: false, on: true) == .none && !x.blocks(percent: 6, onAC: false) }())
}

private func ddcSelfTest(_ check: (String, Bool) -> Void) {
    var c = DDCCoalescer(minInterval: 0.1)
    let t0 = Date(timeIntervalSince1970: 0)
    check("ddc: the first value goes out at once", c.offer(key: "1b", value: 10, now: t0) == true)
    _ = c.take(now: t0)
    check("ddc: values while a slider moves wait (≤10 writes a second)", c.offer(key: "1b", value: 20, now: t0.addingTimeInterval(0.02)) == false
          && c.offer(key: "1b", value: 30, now: t0.addingTimeInterval(0.04)) == false)
    check("ddc: …and only the latest is written", c.take(now: t0.addingTimeInterval(0.05)).isEmpty && c.take(now: t0.addingTimeInterval(0.11)).map(\.value) == [30])
    check("ddc: nothing left after that", c.take(now: t0.addingTimeInterval(0.5)).isEmpty)
    check("ddc: brightness and contrast are separate", { var x = DDCCoalescer(minInterval: 0.1)
        return x.offer(key: "1b", value: 1, now: t0) && x.offer(key: "1c", value: 2, now: t0) && !x.hasPending }())

    typealias P = DDCMatch.Service
    typealias Sc = DDCMatch.Screen
    // Two monitors whose services come in the other order than the screens: matched by vendor/model/serial, not by position.
    let services = [P(index: 0, vendor: 0x10AC, model: 0xA0C3, serial: 222, name: "DELL U2720Q"), P(index: 1, vendor: 0x1E6D, model: 0x5B10, serial: 111, name: "LG HDR 4K")]
    let screens = [Sc(id: 7, vendor: 0x1E6D, model: 0x5B10, serial: 111, name: "LG HDR 4K"), Sc(id: 8, vendor: 0x10AC, model: 0xA0C3, serial: 222, name: "DELL U2720Q")]
    let m = DDCMatch.match(services: services, screens: screens)
    check("ddc: monitors are matched by their identity, not by order (F19)", m[0]?.id == 8 && m[1]?.id == 7)
    let twins = [P(index: 0, vendor: 1, model: 2, serial: 0, name: "X"), P(index: 1, vendor: 1, model: 2, serial: 0, name: "X")]
    let twinScreens = [Sc(id: 3, vendor: 1, model: 2, serial: 0, name: "X"), Sc(id: 4, vendor: 1, model: 2, serial: 0, name: "X")]
    let mt = DDCMatch.match(services: twins, screens: twinScreens)
    check("ddc: two identical monitors without serials are each matched once", Set([mt[0]?.id, mt[1]?.id].compactMap { $0 }) == [3, 4])
    check("ddc: a service with no screen gets none (not someone else's name)", DDCMatch.match(services: [services[0]], screens: [screens[0]])[0] == nil)
    check("ddc: the reply to a VCP read is decoded", DDCReply.parse([0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0x00]).map { $0.current == 50 && $0.max == 100 } == true)
    check("ddc: a bad reply is refused", DDCReply.parse([0x6E, 0x88, 0x02, 0x01, 0x10, 0, 0, 0x64, 0, 0x32]) == nil && DDCReply.parse([1, 2]) == nil)
}

/// `--display-test`, run from main.swift.
func cliDisplayTest() {
    var failed = 0
    displaySelfTest { name, ok in print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
    print(failed == 0 ? "all passed" : "\(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
