// --island-review-test: the round-7 review of the island (user reports and what the review found), with fakes only:
// the brightness bar that covered the charging HUD (BrightnessHUDRule, HUDWatch.observe, NotchPowerWatch's source change),
// the swipe down to open (IslandRouting.swipeZone, NotchGestureMonitor driven with synthetic sequences, the phases and both
// scrolling directions), the content growing with the island (IslandScale, ScreenLayout.resolve, the camera's box) and the
// controller's small rules found on the way. Never touches the real brightness, power, camera or trackpad.

import AppKit
import SwiftUI

enum IslandReviewTests {
    static func run() -> Int {
        _ = NSApplication.shared
        precondition(AppDefaults.isolated, "tests run with memory-only settings (main.swift)")
        Motion.disabled = true
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  island review: " + name); if !ok { failed += 1 } }
        brightness(check); swipes(check); scale(check); layoutFit(check); controller(check)
        return failed
    }

    // MARK: 8. the controller's rules found by the review

    static func controller(_ check: (String, Bool) -> Void) {
        check("watch: the window server's list is read only when a full-screen app matters (the setting, a hiding menu bar)",
              !IslandRouting.needsWindowList(hideInFullScreen: false, menuBarHidden: false)
              && IslandRouting.needsWindowList(hideInFullScreen: true, menuBarHidden: false)
              && IslandRouting.needsWindowList(hideInFullScreen: false, menuBarHidden: true))
        check("watch: back from the settings over a full-screen app, the island is not covered unless the user hides it there",
              !IslandRouting.hidden(fullScreen: true, hideInFullScreen: false))
    }

    // MARK: 2. the brightness bar over the charging HUD

    static func brightness(_ check: (String, Bool) -> Void) {
        typealias R = BrightnessHUDRule
        // The user's report: plugging the charger in, macOS raises the brightness by itself; that got a bar over the battery HUD.
        check("brightness: the charger's own ramp (no key, no click) gets no bar", !R.reports(delta: 0.12, sinceKey: 60, sinceSystem: 0.4, sinceInput: 30))
        check("brightness: …not even with a click just before plugging in", !R.reports(delta: 0.12, sinceKey: 60, sinceSystem: 0.4, sinceInput: 0.5))
        check("brightness: …nor a key pressed just before plugging in", !R.reports(delta: 0.0625, sinceKey: 1.0, sinceSystem: 0.4, sinceInput: 1.0))
        check("brightness: a brightness key after plugging in still shows its bar", R.reports(delta: 0.0625, sinceKey: 0.2, sinceSystem: 1.0, sinceInput: 0.2))
        check("brightness: a key, away from any system change: even a small step shows", R.reports(delta: 0.004, sinceKey: 0.3, sinceSystem: 600, sinceInput: 0.3))
        check("brightness: a slider (a jump right after a click or drag) shows", R.reports(delta: 0.2, sinceKey: 60, sinceSystem: 600, sinceInput: 0.4))
        check("brightness: automatic brightness's jump while nobody touches anything doesn't", !R.reports(delta: 0.2, sinceKey: 60, sinceSystem: 600, sinceInput: 40))
        check("brightness: automatic brightness's drift never does", !R.reports(delta: 0.01, sinceKey: 60, sinceSystem: 600, sinceInput: 0.1))
        check("brightness: the quiet ends: a slider 6 s after plugging in shows again", R.reports(delta: 0.2, sinceKey: 60, sinceSystem: R.systemQuiet + 0.1, sinceInput: 0.2))

        // HUDWatch itself, on a fake clock, input and power source.
        let w = HUDWatch()
        var now = Date(timeIntervalSince1970: 1_000_000)
        var input: TimeInterval = 50
        var source = "Battery Power"
        var bars: [Double] = []
        w.now = { now }; w.sinceInput = { input }; w.powerSource = { source }
        w.onChange = { _, _, level, _ in bars.append(level) }
        w.observe(1, 0.5)                                        // the baseline
        source = "AC Power"; now += 0.3                          // plugged in: the ramp starts before IOKit's callback is handled
        w.observe(1, 0.56); now += 0.25; w.observe(1, 0.62); now += 0.25; w.observe(1, 0.7)
        check("brightness: the ramp after plugging in is quiet, from its first step (the source is read on the spot)", bars.isEmpty)
        now += 0.5; w.brightnessKey(); now += 0.1; w.observe(1, 0.76)
        check("brightness: …a key pressed during the quiet still gets its bar", bars.count == 1 && abs(bars[0] - 0.76) < 0.001)
        now += 30; input = 0.3; w.observe(1, 0.95)
        check("brightness: later, a slider jump gets its bar", bars.count == 2 && abs(bars[1] - 0.95) < 0.001)
        now += 30; input = 40; w.observe(1, 0.6)
        check("brightness: later, automatic brightness's jump doesn't", bars.count == 2)
        now += 30; w.systemChanged(); now += 1; input = 0.5; w.observe(1, 0.8)
        check("brightness: a display wake (systemChanged) quiets it like the charger", bars.count == 2)
        w.suppressBrightness = { true }; now += 30; w.brightnessKey(); w.observe(1, 0.3)
        check("brightness: Cocaine's own dimming never gets a bar", bars.count == 2)

        // NotchPowerWatch tells the brightness watch when the charger goes in or out (and only then).
        let pw = NotchPowerWatch()
        var changes = 0
        pw.onSourceChange = { changes += 1 }
        pw.feed(PowerReading(percent: 50, onAC: false))
        pw.feed(PowerReading(percent: 49, onAC: false))
        check("brightness: no source change at the first reading or a level change", changes == 0)
        pw.feed(PowerReading(percent: 49, onAC: true, charging: true))
        pw.feed(PowerReading(percent: 50, onAC: true, charging: true))
        pw.feed(PowerReading(percent: 50, onAC: false))
        check("brightness: …one at each plug and unplug", changes == 2)

        // The whole chain as the island wires it: the charging HUD stays when macOS raises the brightness.
        let im = IslandModel()
        let said = A11y.post
        A11y.post = { _ in }
        defer { A11y.post = said }
        var t: TimeInterval = 100
        im.now = { t }
        let hud = HUDWatch()
        var clock = Date(timeIntervalSince1970: 2_000_000)
        hud.now = { clock }; hud.sinceInput = { 60 }; hud.powerSource = { nil }
        hud.onChange = { icon, text, level, display in im.flashNotice(icon, text, level: level, display: display) }
        let power = NotchPowerWatch()
        power.post = { im.flashItem($0) }
        power.onSourceChange = { hud.systemChanged() }
        hud.observe(1, 0.4)
        power.feed(PowerReading(percent: 62, onAC: false))
        power.feed(PowerReading(percent: 62, onAC: true, charging: true, minutesToFull: 48))
        let first = im.hudItem?.kind
        for i in 1...6 { clock += 0.25; t += 0.25; hud.observe(1, 0.4 + Float(i) * 0.03) }
        check("brightness: the charging HUD is not covered by the brightness macOS sets on plugging in (2.8.0: it was)",
              first == "power" && im.hudItem?.kind == "power" && im.hudShown)

        // The battery HUD's lines fit a 14" notch (185 pt) in every language: 2.8.0 cut "62% · Carica tra 48 min" and every
        // language's "Plug in the charger soon".
        func width(_ s: String, _ size: CGFloat, _ w: NSFont.Weight = .regular) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: w)]).width
        }
        // The text column: the HUD less its margins, the badge, the gaps and the battery with its level under it.
        let avail: CGFloat = 185 - 2 * (Space.l + 2) - 18 - 2 * Space.m - max(ChargeGlyphView.size.width + 2.5, width("100%", 10, .medium))
        var cut: [String] = []
        let events: [(ChargeEvent, PowerReading)] = [(.connected, PowerReading(percent: 62, onAC: true, charging: true, minutesToFull: 48)),
            (.connected, PowerReading(percent: 80, onAC: true, charging: false)), (.full, PowerReading(percent: 100, onAC: true, charged: true)),
            (.disconnected, PowerReading(percent: 86, onAC: false, minutesToEmpty: 412)), (.low(20), PowerReading(percent: 18, onAC: false)),
            (.low(10), PowerReading(percent: 9, onAC: false)), (.lowPower(true), PowerReading(percent: 41, onAC: false, lowPower: true)),
            (.lowPower(false), PowerReading(percent: 41, onAC: false))]
        for code in Language.codes {
            Language.set(code, persist: false)
            for (e, r) in events {
                let item = ChargeEvents.item(e, r, low: 20)
                guard let g = item.power else { continue }
                // The title has two lines when there is no detail (a word never breaks: 1.7 lines' worth at most).
                let title = width(item.text, 11, .semibold) * 0.85, detail = g.detail.map { width($0, 10) * 0.85 } ?? 0
                if title > (g.detail == nil ? 1.7 * avail : avail) || detail > avail { cut.append("\(code): \(item.text) / \(g.detail ?? "")") }
            }
        }
        Language.set(nil, persist: false)
        if !cut.isEmpty { print(cut.joined(separator: "\n")) }
        check("battery HUD: its title, level and detail fit the notch-wide HUD in all 8 languages", cut.isEmpty)
    }

    // MARK: 3. the swipe down to open

    static func swipes(_ check: (String, Bool) -> Void) {
        // A 14" MacBook Pro: the notch 185 × 32 at the top centre.
        let g = NotchGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 185, height: 32, centerX: 756, hasNotch: true, display: 1)
        let top = g.frame.maxY
        let below = CGPoint(x: 756, y: top - 32 - 30)            // just under the notch: where a swipe down to open starts
        let onNotch = CGPoint(x: 756, y: top - 10)
        let farAway = CGPoint(x: 756, y: 400)
        let hover = IslandRouting.hoverZone(g, open: false, leftW: Island.wing, rightW: 0)
        let zone = IslandRouting.swipeZone(g, open: false, leftW: Island.wing, rightW: 0)
        check("swipe: the closed island's swipe zone reaches below the notch, where hovering doesn't open it (2.8.0 used the hover zone: unreachable)",
              zone.contains(below) && !hover.contains(below) && zone.contains(onNotch))
        check("swipe: …it stops at the screen's top and is not the whole screen", zone.maxY == top && !zone.contains(farAway)
              && !zone.contains(CGPoint(x: 100, y: top - 40)))
        check("swipe: the open island's swipe zone is the open island", IslandRouting.swipeZone(g, open: true, leftW: 62, rightW: 62)
              == IslandRouting.hoverZone(g, open: true, leftW: 62, rightW: 62))

        // The phases and both scrolling directions: fingers moving down are dy > 0 whatever the setting.
        check("swipe: the trackpad's phases (mayBegin/began start, ended/cancelled end, momentum none)",
              NotchSwipe.phase(.mayBegin) == .began && NotchSwipe.phase(.began) == .began && NotchSwipe.phase(.changed) == .changed
              && NotchSwipe.phase(.ended) == .ended && NotchSwipe.phase(.cancelled) == .ended && NotchSwipe.phase([]) == .other)
        let natural = NotchSwipe.event(dx: 0, dy: 6, inverted: true, phase: .changed, momentum: false, precise: true)
        let classic = NotchSwipe.event(dx: 0, dy: -6, inverted: false, phase: .changed, momentum: false, precise: true)
        check("swipe: fingers down read the same with natural scrolling on and off", natural.dy > 0 && classic.dy > 0 && natural.dy == classic.dy)

        // The monitor, driven with synthetic sequences against a fake controller (the island under the pointer).
        let spy = HapticSpy()
        let (sink, clock, click) = (Haptic.sink, Haptic.clock, Haptic.clickInProgress)
        defer { Haptic.sink = sink; Haptic.clock = clock; Haptic.clickInProgress = click; Haptic.resetForTests() }
        var hclock: TimeInterval = 5000
        Haptic.sink = spy; Haptic.clock = { hclock }; Haptic.clickInProgress = { false }; Haptic.resetForTests()
        var isOpen = false
        var opened = 0, closed = 0, steps: [Int] = [], feedback: [CGFloat] = []
        var blocked = false
        let m = NotchGestureMonitor()
        m.settings = NotchGestureSettings()
        m.target = { p in
            IslandRouting.swipeZone(g, open: isOpen, leftW: Island.wing, rightW: 0).contains(p) ? NotchGestureTarget(display: 1, open: isOpen, window: nil) : nil
        }
        m.blocked = { blocked }
        m.open = { _ in opened += 1; isOpen = true }
        m.close = { closed += 1; isOpen = false }
        m.screen = { steps.append($0) }
        m.feedback = { feedback.append($0) }
        let t = m.settings.threshold
        func gesture(at p: CGPoint, dx: CGFloat = 0, dy: CGFloat, steps n: Int = 10, mayBegin: Bool = true) {
            hclock += 1
            if mayBegin { m.handle(NotchSwipe.Event(dx: 0, dy: 0, phase: .began), at: p) }
            m.handle(NotchSwipe.Event(dx: dx / CGFloat(n), dy: dy / CGFloat(n), phase: .began), at: p)
            for _ in 1..<n { m.handle(NotchSwipe.Event(dx: dx / CGFloat(n), dy: dy / CGFloat(n), phase: .changed), at: p) }
            m.handle(NotchSwipe.Event(dx: 0, dy: 0, phase: .ended), at: p)
        }
        gesture(at: below, dy: t * 1.5)
        check("swipe: two fingers down just below the closed notch open it, once, with one haptic", opened == 1 && isOpen && spy.taps.count == 1)
        check("swipe: …the notch followed the fingers and was let go", feedback.contains { $0 > 0.3 } && feedback.last == 0)
        check("swipe: the gesture's start is kept for the diagnostics", m.lastStart?.display == 1 && m.lastStart?.owned == true && m.lastStart?.open == false)
        gesture(at: below, dy: t * 1.5)
        check("swipe: down again on the open island does nothing", opened == 1 && closed == 0)
        gesture(at: below, dy: -t * 1.5)
        check("swipe: up on the open island closes it, one haptic", closed == 1 && !isOpen && spy.taps.count == 2)
        gesture(at: below, dy: t * 1.5, mayBegin: false)
        check("swipe: down again in place reopens it (no mayBegin first: a quick flick)", opened == 2 && spy.taps.count == 3)
        isOpen = false
        gesture(at: farAway, dy: t * 3)
        check("swipe: far from the notch: never", opened == 2)
        blocked = true
        gesture(at: below, dy: t * 3)
        check("swipe: a dialog, a shelf form or the keyboard mode holds the island: never", opened == 2)
        blocked = false
        isOpen = true
        gesture(at: CGPoint(x: 756, y: top - 120), dx: -t * 1.5, dy: 2)
        check("swipe: sideways on the open island: the next screen, once (its haptic is the tab change's)", steps == [1])
        let before = opened
        m.settings.swipeOpen = false; isOpen = false
        gesture(at: below, dy: t * 3)
        check("swipe: swipe down to open off: nothing", opened == before)
    }

    // MARK: 5. the content grows with the island

    static func scale(_ check: (String, Bool) -> Void) {
        let std = IslandScale.factor(open: NotchSizing.presetSize(.standard)!)
        let large = IslandScale.factor(open: NotchSizing.presetSize(.large)!)
        let xl = IslandScale.factor(open: NotchSizing.presetSize(.extraLarge)!)
        let mx = IslandScale.factor(open: CGSize(width: NotchSizing.openWidths.upperBound, height: NotchSizing.openHeights.upperBound))
        check("scale: 1 for the standard island, growing with each preset, the smaller ratio", std == 1 && large > 1 && xl > large && mx > xl
              && abs(xl - min(760.0 / 640, 274.0 / 214)) < 0.0001)
        check("scale: a broken size never scales anything", IslandScale.factor(open: CGSize(width: CGFloat.nan, height: 0)) == 1)
        check("scale: the standard box is the standard island's page box", IslandScale.standardBox(stripHeight: 32)
              == CGSize(width: 640 - 28 - 2 * Space.page, height: 214 - 32 - 24))

        // The camera (the user's example): its picture fills the module's extra height at its shape.
        func mirror(_ open: CGSize, strip: CGFloat = 32) -> CGSize {
            let stdBox = IslandScale.standardBox(stripHeight: strip)
            let box = CGSize(width: open.width - 28 - 2 * Space.page, height: open.height - strip - 24)
            return IslandView.mirrorSize(ModuleBox(size: .l, width: box.width, height: box.height, standard: stdBox))
        }
        let m0 = mirror(NotchSizing.presetSize(.standard)!), m1 = mirror(NotchSizing.presetSize(.large)!), m2 = mirror(NotchSizing.presetSize(.extraLarge)!)
        let m3 = mirror(CGSize(width: 800, height: 300))
        check("scale: the camera is 250 × 146 in the standard island, as before", m0 == IslandView.mirrorBase)
        check("scale: the camera grows with every bigger size (2.8.0: it stayed 250 × 146)", m1.height > m0.height && m2.height > m1.height && m3.height > m2.height
              && m3.width > m0.width)
        check("scale: …keeping its shape", [m1, m2, m3].allSatisfy { abs($0.width / $0.height - 250.0 / 146) < 0.02 })
        check("scale: …never past the module's box, leaving the controls their room", [(CGSize(width: 760, height: 274), m2), (CGSize(width: 800, height: 300), m3)].allSatisfy { open, cam in
            cam.height <= open.height - 32 - 24 && cam.width <= open.width - 28 - 2 * Space.page - IslandView.mirrorControls - Space.gutter })
        let wide = IslandView.mirrorSize(ModuleBox(size: .l, width: 600, height: 600, standard: CGSize(width: 576, height: 158)))
        check("scale: in a tall narrow box the width limits it (the controls keep their room)", wide.width <= 600 - IslandView.mirrorControls - Space.gutter
              && abs(wide.width / wide.height - 250.0 / 146) < 0.02)

        // Both columns grow: Home at Extra large.
        let box = CGSize(width: 760 - 28 - 2 * Space.page, height: 274 - 32 - 24)
        let home = ScreenLayout.resolve(ScreenLayout.standard.config("home")!, in: box)
        let stdHome = ScreenLayout.resolve(ScreenLayout.standard.config("home")!, in: IslandScale.standardBox(stripHeight: 32))
        check("scale: the narrow column grows with the island too (2.8.0: 250 pt in any size)", home.widths[0] > 250 && stdHome.widths[0] == 250
              && abs(home.widths[0] + home.widths[1] + Space.gutter - box.width) < 0.5)
        let b = ModuleBox.of(home.modules[0], standard: stdHome)
        check("scale: each module knows its box in the standard island (what it grows from)", b.standard == stdHome.modules[0].frame.size && b.factor > 1
              && b.extraHeight == box.height - stdHome.modules[0].frame.height)
        check("scale: a box built without its standard one grows nothing", ModuleBox(size: .l, width: 300, height: 200).factor == 1
              && ModuleBox(size: .l, width: 300, height: 200).extraHeight == 0)
        check("scale: fixed sizes grow on whole points, never shrink", IslandScale.grow(62, 1.19) == 74 && IslandScale.grow(62, 0.5) == 62)
    }

    // MARK: 8. every module at every size, in every island size: nothing taller than its box

    /// Each module's least height (its content laid out at its box's width) against its box, for every size it has, in every
    /// screen's column arrangement of the standard layout, for every island size preset and strip height. Modules whose
    /// content reads the Mac (the monitors, the calendar, the batteries, the AI usage) are left out; the camera never starts in tests.
    static func layoutFit(_ check: (String, Bool) -> Void) {
        let pm = PanelModel()
        pm.persistLanguage = false
        let im = IslandModel()
        im.pm = pm
        im.files.downloads = [FileShelf.Item(url: URL(fileURLWithPath: "/tmp/cocaine-sample.dmg"), date: Date(), size: 5_200_000)]
        im.reminders.use(FakeReminders(items: [ReminderItem(id: "1", title: "Buy milk", due: Date(), listID: "home")]))
        let view = IslandView(model: im, m: pm, focus: im.focus, batteries: im.batteries, mic: im.mic, usage: im.usage)
        let kinds = ["cocaine", "controls", "media", "focus", "downloads", "screenshots", "reminders", "mirror"]
        let sizes: [CGSize] = [NotchSizing.presetSize(.standard)!, NotchSizing.presetSize(.large)!, NotchSizing.presetSize(.extraLarge)!, CGSize(width: 800, height: 300)]
        check("fit: the measure sees a view that spills out of its box, and none that fits",
              spill(Color.red.frame(width: 50, height: 130), box: CGSize(width: 100, height: 100)) >= 14
              && spill(Color.red, box: CGSize(width: 100, height: 100)) == 0)
        var worst: [String] = []
        for open in sizes {
            NotchPrefs.shared.updateSizing { $0.openWidth = open.width; $0.openHeight = open.height }
            for strip: CGFloat in [24, 32, 38] {
                let boxSize = ScreenLayout.contentSize(stripHeight: strip)
                for kind in kinds {
                    guard let spec = ModuleCatalog.module(kind) else { continue }
                    for size in spec.sizes {
                        // The module alone in its column (S and M stacked under another module would only be shorter).
                        let screen = ScreenConfig(id: "home", visible: true, modules: [ModulePlacement(kind, spec.width == .wide ? 1 : 0, size),
                                                                                         ModulePlacement(spec.width == .full ? kind : "cocaine", 1, .l)])
                        let r = ScreenLayout.resolve(screen, in: boxSize)
                        let stdR = ScreenLayout.resolve(screen, in: IslandScale.standardBox(stripHeight: strip))
                        guard let mod = r.modules.first(where: { $0.kind == kind }) else { continue }
                        let b = ModuleBox.of(mod, standard: stdR)
                        let out = spill(view.module(kind, b), box: CGSize(width: b.width, height: b.height))
                        if out > 0 { worst.append("\(kind) \(size.letter) \(Int(open.width))×\(Int(open.height)) strip \(Int(strip)): \(Int(out)) pt outside its box") }
                    }
                }
            }
        }
        NotchPrefs.shared.updateSizing { $0 = NotchSizing() }
        if !worst.isEmpty { print(worst.prefix(16).joined(separator: "\n")) }
        check("fit: every module at every size it has fits its box in every island size and strip height", worst.isEmpty)
    }
}

extension IslandReviewTests {
    /// Draws a view in a box of this size (as the page does: top-aligned, never clipped) on a transparent canvas with room around
    /// it, and says how far anything drawn reaches outside the box, in points (0: it fits). What a page would show cut or
    /// spilling into the island's margins.
    static func spill<V: View>(_ v: V, box: CGSize) -> CGFloat {
        let m: CGFloat = 60
        let canvas = CGSize(width: box.width + 2 * m, height: box.height + 2 * m)
        let root = ZStack(alignment: .topLeading) {
            Color.clear
            v.frame(width: box.width, height: box.height, alignment: .top).offset(x: m, y: m)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: rep)
        let sx = CGFloat(rep.pixelsWide) / canvas.width, sy = CGFloat(rep.pixelsHigh) / canvas.height
        let inner = CGRect(x: (m - 1) * sx, y: (m - 1) * sy, width: (box.width + 2) * sx, height: (box.height + 2) * sy)
        var worst: CGFloat = 0
        guard let data = rep.bitmapData, rep.bitsPerSample == 8, rep.hasAlpha else { return 0 }
        let spp = rep.samplesPerPixel, row = rep.bytesPerRow
        let alphaAt = rep.bitmapFormat.contains(.alphaFirst) ? 0 : spp - 1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where !inner.contains(CGPoint(x: x, y: y)) {
                guard data[y * row + x * spp + alphaAt] > 38 else { continue }
                let px = CGFloat(x) / sx, py = CGFloat(y) / sy
                let d = max(m - px, px - (m + box.width), m - py, py - (m + box.height), 0)
                worst = max(worst, d)
            }
        }
        window.contentView = nil
        return worst.rounded(.up)
    }
}

func cliIslandReviewTest() { exit(IslandReviewTests.run() == 0 ? 0 : 1) }
