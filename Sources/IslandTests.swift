// Tests for the island on every screen (fake screen lists), its HUD below the notch (HUDTimeline, routing, re-anchoring) and the
// single haptic per action (a counting HapticSink). Part of --selftest and --display-test (displaySelfTest).

import AppKit

/// Counts the taps instead of playing them.
final class HapticSpy: HapticSink {
    var taps: [NSHapticFeedbackManager.FeedbackPattern] = []
    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) { taps.append(pattern) }
}

func islandSelfTest(_ check: (String, Bool) -> Void) {
    islandScreensTest(check)
    islandStateTest(check)
    hudTimelineTest(check)
    hudRoutingTest(check)
    hapticTest(check)
}

private typealias S = NotchGeometry.Screen
// A 14" MacBook Pro (notch, main), a 2560×1440 monitor right of it, a 1920×1080 one above it.
private let builtinF = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let rightF = CGRect(x: 1512, y: -458, width: 2560, height: 1440)
private let aboveF = CGRect(x: 0, y: 982, width: 1920, height: 1080)
private let builtin = S(frame: builtinF, visibleTop: 945, safeTop: 32, auxLeft: 663.5, auxRight: 663.5, builtin: true, id: 1)
private let right = S(frame: rightF, visibleTop: rightF.maxY - 25, safeTop: 0, auxLeft: nil, auxRight: nil, builtin: false, id: 2)
private let above = S(frame: aboveF, visibleTop: aboveF.maxY - 25, safeTop: 0, auxLeft: nil, auxRight: nil, builtin: false, id: 3)

private func islandScreensTest(_ check: (String, Bool) -> Void) {
    let all = NotchGeometry.all([right, builtin, above], barThickness: 24, allScreens: true)
    check("screens: one island per connected screen, the notch's first", all.map(\.display) == [1, 2, 3])
    check("screens: a notch on the notched screen, the pill on the others",
          all[0].hasNotch && all[0].notchWidth == 185 && all[0].centerX == 756 && !all[1].hasNotch && !all[2].hasNotch)
    check("screens: each pill is centred on its own screen, as tall as its menu bar",
          all[1].centerX == rightF.midX && all[1].frame == rightF && all[1].height == 25 && all[2].centerX == aboveF.midX)
    check("screens: Show on all screens off = only the main island, as in 2.5.0",
          NotchGeometry.all([right, builtin, above], barThickness: 24, allScreens: false).map(\.display) == [1])
    var mirror = right; mirror.id = 4; mirror.mirrorOf = 2
    check("screens: a mirror set gets one island (on the display it mirrors)",
          NotchGeometry.all([builtin, right, mirror], barThickness: 24, allScreens: true).map(\.display) == [1, 2])
    check("screens: no screens, no island", NotchGeometry.all([], barThickness: 24, allScreens: true).isEmpty)
    // Hot-plug: the list is worked out again; a monitor unplugged loses its island, the others keep theirs.
    check("screens: unplugging a monitor leaves the others' islands as they were",
          NotchGeometry.all([builtin, above], barThickness: 24, allScreens: true) == [all[0], all[2]])
    check("screens: clamshell (built-in gone) → the monitors' pills, the main one first",
          NotchGeometry.all([right, above], barThickness: 24, allScreens: true).map(\.display) == [2, 3])
    // The closed window holds the notch strip and the HUD's room below it; it never reaches past its screen's top.
    let w = IslandController.windowFrame(all[0], open: false)
    check("geometry: the closed window reaches the HUD's room below the notch",
          w.minY <= builtinF.maxY - 32 - Island.hudHeight(HUDItem(icon: "", text: "x", level: nil)) && w.maxY == builtinF.maxY + Island.overscan)
    check("geometry: the closed window is centred on the notch", abs(w.midX - 756) < 0.01)
    let zone = IslandRouting.hoverZone(all[0], open: false, leftW: Island.wing, rightW: 0)
    check("geometry: the hover zone stops at the screen's top (the screen above has its own island)",
          zone.maxY == builtinF.maxY && !zone.contains(CGPoint(x: 756, y: builtinF.maxY + 5)) && zone.contains(CGPoint(x: 756, y: builtinF.maxY - 5)))
    let pill = IslandRouting.hoverZone(all[1], open: false, leftW: Island.wing, rightW: 0)
    check("geometry: a pill's hover zone is on its own screen", rightF.contains(CGPoint(x: pill.midX, y: pill.midY)) && !builtinF.intersects(pill))
}

private func islandStateTest(_ check: (String, Bool) -> Void) {
    var s = IslandRouting.OpenState()
    check("state: hovering A's notch opens A", s.pointer(over: 1) == [.open(1)] && s.open == 1)
    check("state: moving to B's notch closes A and opens B only", s.pointer(over: 2) == [.close(1), .open(2)] && s.open == 2)
    check("state: leaving every notch closes B", s.pointer(over: nil) == [.close(2)] && s.open == nil)
    check("state: the same island twice does nothing", { var x = IslandRouting.OpenState(); _ = x.pointer(over: 1); return x.pointer(over: 1).isEmpty }())
    var k = IslandRouting.OpenState()
    _ = k.openNow(1); k.keyboard = true
    check("state: opened from the keyboard it stays when the pointer goes nowhere", k.pointer(over: nil).isEmpty && k.open == 1)
    check("state: …but another notch under the pointer takes over", k.pointer(over: 2) == [.close(1), .open(2)] && !k.keyboard)
    var d = IslandRouting.OpenState()
    _ = d.pointer(over: 1); d.dialog = true
    check("state: a dialog keeps its island open, other notches wait", d.pointer(over: 2).isEmpty && d.pointer(over: nil).isEmpty && d.open == 1)
    var r = IslandRouting.OpenState()
    _ = r.pointer(over: 2)
    check("state: a screen unplugged while its island is open: it closes, nothing waits for it", r.removed([2]) == [.close(2)] && r.open == nil && r.hovering == nil)
    check("state: …another screen unplugged changes nothing", { var x = IslandRouting.OpenState(); _ = x.pointer(over: 1); return x.removed([3]).isEmpty && x.open == 1 }())
    var c = IslandRouting.OpenState()
    _ = c.pointer(over: 1)
    check("state: closing on purpose (Esc, a click) closes the open one", c.closeNow() == [.close(1)] && c.closeNow().isEmpty)
}

private func hudTimelineTest(_ check: (String, Bool) -> Void) {
    let vol = { (v: Double) in HUDItem(icon: "speaker.wave.2.fill", text: "Volume", level: v) }
    let bri = { (v: Double) in HUDItem(icon: "sun.max.fill", text: "Brightness", level: v) }
    var t = HUDTimeline()
    check("hud: the first change drops the container", t.post(vol(0.5), now: 0) == .appear && t.shown)
    check("hud: a held key updates the same container (no rebuild)", t.post(vol(0.56), now: 0.1) == .update && t.post(vol(0.62), now: 0.2) == .update && t.item?.level == 0.62)
    check("hud: each change extends its time", t.until == 0.2 + HUDTimeline.levelQuiet)
    check("hud: volume then brightness swaps inside the same container", t.post(bri(0.3), now: 0.8) == .swap && t.item?.text == "Brightness")
    check("hud: still there just before 1.4 s of quiet", t.tick(now: 0.8 + 1.3) == .none && t.shown)
    check("hud: gone after 1.4 s of quiet (the content is kept for the retract)", t.tick(now: 0.8 + 1.41) == .hide && !t.shown && t.item?.text == "Brightness")
    check("hud: a change during the retract drops it again", t.post(vol(0.4), now: 2.3) == .appear && t.shown)
    var n = HUDTimeline()
    n.post(HUDItem(icon: "doc.on.clipboard.fill", text: "Copied", level: nil), now: 0)
    check("hud: a newer text replaces the shown one at once (latest wins)", n.post(HUDItem(icon: "arrow.down.circle.fill", text: "Downloaded x.dmg", level: nil), now: 0.3) == .update
          && n.item?.text == "Downloaded x.dmg")
    n.post(vol(0.5), now: 0.5)
    check("hud: a bar over a text puts the text aside", n.item?.isLevel == true && n.parked?.item.text == "Downloaded x.dmg")
    check("hud: …and it comes back when the bars go quiet", n.tick(now: 0.5 + HUDTimeline.levelQuiet) == .swap && n.item?.text == "Downloaded x.dmg")
    check("hud: …then goes (nothing is ever stuck)", n.tick(now: 0.5 + HUDTimeline.levelQuiet + 5.1) == .hide && n.parked == nil)
    var y = HUDTimeline()
    y.post(vol(0.5), now: 0)
    y.dismiss()
    check("hud: the island opening makes it give way, nothing comes back", !y.shown && y.nextDeadline == nil && y.tick(now: 10) == .none)
    check("hud: a text stays long enough to read", HUDTimeline.textTime("Copied") >= 2.2 && HUDTimeline.textTime(String(repeating: "x", count: 200)) <= 5)
    // The model: messages are announced, levels not; a HUD for an open island is not shown under it.
    let im = IslandModel()
    var said: [String] = []
    let post = A11y.post
    A11y.post = { said.append($0) }
    im.hudRoute = { _ in 7 }
    im.flashNotice("doc.on.clipboard.fill", "Copied")
    im.flashNotice("speaker.wave.2.fill", "Volume", level: 0.4)
    check("hud: the model routes it, keeps one container, says only the message", im.hudScreen == 7 && im.hudShown && im.hudItem?.level == 0.4 && said == ["Copied"])
    im.yieldHUD()
    im.hudYields = { $0 == 7 }
    im.flashNotice("speaker.wave.2.fill", "Volume", level: 0.5)
    check("hud: no HUD under that screen's open island", !im.hudShown)
    A11y.post = post
    check("hud: the wings no longer widen for a message", im.leftW == Island.wing)
}

private func hudRoutingTest(_ check: (String, Bool) -> Void) {
    let isl = NotchGeometry.all([builtin, right, above], barThickness: 24, allScreens: true)
    let none: (CGDirectDisplayID) -> CGDirectDisplayID = { _ in 0 }
    check("hud route: brightness goes to the display it changed", IslandRouting.hudTarget(display: 1, pointer: CGPoint(x: 2000, y: 100), islands: isl, mirrorOf: none) == 1)
    check("hud route: a mirrored display's change goes to its set's island",
          IslandRouting.hudTarget(display: 9, pointer: nil, islands: isl, mirrorOf: { $0 == 9 ? 2 : 0 }) == 2)
    check("hud route: the volume goes to the screen under the pointer", IslandRouting.hudTarget(display: nil, pointer: CGPoint(x: 2000, y: 100), islands: isl, mirrorOf: none) == 2
          && IslandRouting.hudTarget(display: nil, pointer: CGPoint(x: 100, y: 1500), islands: isl, mirrorOf: none) == 3)
    check("hud route: a display without an island (all screens off) → the pointer's island, else the main one",
          IslandRouting.hudTarget(display: 2, pointer: CGPoint(x: 9000, y: 0), islands: [isl[0]], mirrorOf: none) == 1)
    // Re-anchoring: the HUD's screen is unplugged while it shows: the next target is a screen that is still there.
    let after = NotchGeometry.all([builtin, above], barThickness: 24, allScreens: true)
    check("hud route: a HUD on an unplugged screen moves to one that is there", after.map(\.display).contains(
          IslandRouting.hudTarget(display: nil, pointer: CGPoint(x: 2000, y: 100), islands: after, mirrorOf: none)))
    check("hud route: no island at all → 0 (nothing shown)", IslandRouting.hudTarget(display: 1, pointer: nil, islands: [], mirrorOf: none) == 0)
}

private func hapticTest(_ check: (String, Bool) -> Void) {
    let spy = HapticSpy()
    let (sink, clock, click, controlTap) = (Haptic.sink, Haptic.clock, Haptic.clickInProgress, ControlHaptics.tap)
    defer { Haptic.sink = sink; Haptic.clock = clock; Haptic.clickInProgress = click; ControlHaptics.tap = controlTap; Haptic.resetForTests() }
    var now: TimeInterval = 1000
    var clicking = false
    Haptic.sink = spy; Haptic.clock = { now }; Haptic.clickInProgress = { clicking }
    PanelModel.controlWords()                                    // the controls' tap, as the app sets it
    func count(_ run: () -> Void) -> Int { Haptic.resetForTests(); spy.taps = []; now += 1; run(); return spy.taps.count }

    // A click on a Force Touch trackpad is its own tap: none of ours on top (that was the double tap).
    clicking = true
    check("haptic: a clicked segment, switch, tab or button adds no second tap to the trackpad's click", count { ControlHaptics.tap() } == 0 && count { Haptic.tap(.alignment) } == 0)
    clicking = false
    check("haptic: the same control from the keyboard taps exactly once", count { ControlHaptics.tap() } == 1)
    // Dropdown: picking a row (Return in the list) taps once.
    let pc = PickerCenter.shared
    pc.present(PickerSpec(id: "t", title: "T", items: [PickerItem(id: "a", title: "A"), PickerItem(id: "b", title: "B")], mode: .single("a")), anchor: .zero)
    check("haptic: a dropdown pick taps once", count { pc.tap("b") } == 1)
    pc.close()
    // The time stepper: − / + once; a scroll step once (ScrollSteps' tap; its step function no longer adds one).
    var minutes = 600
    check("haptic: the time stepper's − / + tap once", count { TimeStepper.step(&minutes, by: 1, fromScroll: false) } == 1 && minutes == 615)
    check("haptic: a scroll step over it taps once (it tapped twice)", count { Haptic.tap(.alignment); TimeStepper.step(&minutes, by: 1, fromScroll: true) } == 1 && minutes == 630)
    // The island's tabs from the keyboard (← →) and the focus buttons.
    let im = IslandModel()
    im.tab = "home"
    check("haptic: a tab change from the keyboard taps once", count { im.stepTab(1) } == 1)
    let f = FocusTimer(defaults: MemoryDefaults())
    check("haptic: start / pause / reset of a focus tap once each", count { f.start() } == 1 && count { f.pause() } == 1 && count { f.reset() } == 1)
    // The safety net: the same pattern twice within 60 ms plays once; further apart, twice.
    check("haptic: the same tap twice within 60 ms plays once", count { Haptic.tap(.alignment); now += 0.03; Haptic.tap(.alignment) } == 1)
    check("haptic: …and twice when they are apart (a ruler's ticks while dragging)", count { Haptic.tap(.alignment); now += 0.08; Haptic.tap(.alignment); now += 0.08; Haptic.tap(.levelChange) } == 3)
    // Old events: a click handled a while ago doesn't silence a later tap (NSApp.currentEvent stays the last event).
    let e = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 50, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
    check("haptic: a click is recognised only while it is being handled", Haptic.isClick(e, now: 50.05) && !Haptic.isClick(e, now: 52) && !Haptic.isClick(nil, now: 0))
}
