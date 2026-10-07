// The motion system's tests (--motion-test, part of --selftest) and its render aid (--render-motion): the token table, the
// Reduce Motion mapping, and the state machines that drive animations, under rapid and interrupted sequences; and contact
// sheets of the key transitions at 0, 25, 50, 75 and 100 %, drawn with the same modifiers the app uses.

import AppKit
import SwiftUI

enum MotionTests {
    static func run(_ check: (String, Bool) -> Void) {
        let savedDisabled = Motion.disabled, savedReduce = Motion.reduceOverride
        defer { Motion.disabled = savedDisabled; Motion.reduceOverride = savedReduce }

        // MARK: tokens
        let d = Motion.Duration.all
        check("motion: durations instant < quick < standard < slow, all under half a second",
              zip(d, d.dropFirst()).allSatisfy { $0 < $1 } && d.first! > 0 && d.last! <= 0.5)
        check("motion: every spring has a response of 0.15…0.6 s and a damping of 0.7…1 (no wobble, nothing sluggish)",
              Motion.springs.allSatisfy { (0.15...0.6).contains($0.response) && (0.7...1).contains($0.damping) })
        check("motion: snappy is the quickest spring, gentle the calmest",
              Motion.springs.allSatisfy { Motion.snappy.response <= $0.response } && Motion.springs.allSatisfy { Motion.gentle.damping >= $0.damping })
        check("motion: every spring settles within 0.6 s", Motion.springs.allSatisfy { $0.settle > 0 && $0.settle < 0.6 })
        check("motion: the island's window shrinks only after its close spring has settled",
              Motion.islandSettle >= Motion.curve(.islandClose, reduce: false)!.duration)
        check("motion: stagger grows by step and is capped", Motion.stagger(0) == 0 && Motion.stagger(2) == 2 * Motion.stagger
              && Motion.stagger(1000) == Motion.maxStagger && Motion.stagger(-3) == 0)

        // MARK: the table and Reduce Motion
        check("motion: every role has a curve (nothing pops without Reduce Motion)", Motion.Role.allCases.allSatisfy { Motion.curve($0, reduce: false) != nil })
        let reduced = Motion.Role.allCases.compactMap { Motion.curve($0, reduce: true) }
        check("motion: Reduce Motion: no springs at all (nothing overshoots or bounces)", !reduced.contains { $0.isSpring })
        check("motion: Reduce Motion: every fade is quick (≤ \(Motion.Duration.quick) s)", reduced.allSatisfy { $0.duration <= Motion.Duration.quick })
        let moving: [Motion.Role] = [.islandOpen, .islandClose, .wing, .toggle, .hudBar, .expand, .dragSettle, .value]
        check("motion: Reduce Motion: what only moves (the island's morph, wings, the knob, bars, rows) changes at once",
              moving.allSatisfy { Motion.curve($0, reduce: true) == nil })
        check("motion: Reduce Motion: what arrives (dialogs, dropdowns, pages, notices) still fades",
              [Motion.Role.dialog, .dropdown, .page, .notice, .appear].allSatisfy { Motion.curve($0, reduce: true) != nil })
        Motion.reduceOverride = true
        check("motion: Reduce Motion: the island opens and closes at once", Motion.island(true) == nil && Motion.island(false) == nil)
        Motion.reduceOverride = false
        check("motion: without it, the island springs", Motion.island(true) != nil && Motion.island(false) != nil)
        Motion.disabled = true
        check("motion: disabled (renders, snapshots): no role animates, with or without Reduce Motion",
              Motion.Role.allCases.allSatisfy { Motion.animation($0, reduce: false) == nil && Motion.animation($0, reduce: true) == nil }
              && Motion.island(true) == nil)
        Motion.disabled = false
        check("motion: Reduce Motion turns the alert's flashes into one soft tint",
              Motion.flashes(reduce: true) == [0.18, 0] && Motion.flashes(reduce: false) == [0.55, 0, 0.55, 0]
              && Motion.flashSteps(reduce: false).count == 4 && Motion.flashSteps(reduce: true).allSatisfy { $0.duration >= 0.4 })
        let fills = stride(from: 0.0, through: 1.0, by: 0.05).map { Motion.pour(CGFloat($0), filling: true) }
        check("motion: the pour starts at 0, ends at 1, never goes back, eases out filling and in emptying",
              Motion.pour(0, filling: true) == 0 && Motion.pour(1, filling: false) == 1 && zip(fills, fills.dropFirst()).allSatisfy { $0 <= $1 }
              && Motion.pour(0.5, filling: true) > 0.5 && Motion.pour(0.5, filling: false) < 0.5 && Motion.pour(2, filling: true) == 1)

        // MARK: interruption and repetition
        // The island: 50 alternating enters and leaves end where the pointer is, and every open is followed by a close.
        var st = IslandRouting.OpenState()
        var actions: [IslandRouting.Action] = []
        for i in 0..<50 { actions += st.pointer(over: i % 2 == 0 ? 7 : nil) }
        check("island morph: 50 rapid enters/leaves end closed (the pointer left last), opens and closes alternate",
              st.open == nil && actions.count == 50 && actions.enumerated().allSatisfy { $0.element == ($0.offset % 2 == 0 ? .open(7) : .close(7)) })
        _ = st.pointer(over: 7)
        check("island morph: …and one more enter leaves it open", st.open == 7)

        // The window's shrink after a close: only the latest close's runs, none after a reopen.
        var settle = MotionGeneration()
        var pending: [Int] = [], open = false
        for i in 0..<50 {
            open = i % 2 == 0
            if open { settle.cancel() } else { pending.append(settle.begin()) }
        }
        check("island morph: 50 open/close: only the last close's delayed shrink runs (none overlap)",
              !open && pending.filter { settle.isCurrent($0) }.count == 1 && pending.last.map(settle.isCurrent) == true)
        settle.cancel()
        check("island morph: reopened mid-close: no shrink runs under the open island", pending.allSatisfy { !settle.isCurrent($0) })

        // The page: in the view only while the morph's progress is above 0, so a reversal half-way keeps it (no restart).
        check("island page: mounted while the morph is under way, gone when closed (and in the spring's overshoot below 0)",
              !PageReveal.mounted(0) && !PageReveal.mounted(-0.03) && !PageReveal.mounted(0.005) && PageReveal.mounted(0.3) && PageReveal.mounted(1.04))

        // Pages: 20 rapid tab changes end on the last one, sliding the way of the last change.
        let pager = PageDirection()
        var tab = 0, seq = [3, 1, 4, 1, 5, 2, 6, 5, 3, 5, 0, 2, 4, 6, 1, 3, 2, 0, 4, 2]
        for next in seq { pager.note(from: tab, to: next); tab = next }
        check("pages: 20 rapid changes end on the last tab, sliding back (4 → 2)", tab == 2 && !pager.forward)
        pager.note(from: 2, to: 2); pager.note(from: nil, to: 5); pager.note(from: 1, to: nil)
        check("pages: the same tab, or one not in the list, leaves the direction as it was", !pager.forward)
        seq = [1]; pager.note(from: 0, to: seq[0])
        check("pages: a step to the right slides forward", pager.forward)

        // The HUD: a change every 20 ms keeps the one container down and updates it in place; it goes once, at the end.
        var hud = HUDTimeline()
        var changes: [HUDTimeline.Change] = []
        var t: TimeInterval = 100
        for i in 0..<100 {
            changes.append(hud.post(HUDItem(icon: "speaker.wave.2.fill", text: "Volume", level: Double(i % 17) / 16), now: t))
            changes.append(hud.tick(now: t))
            t += 0.02
        }
        check("HUD: updates every 20 ms: it drops once, then only updates (no hide, no second drop)",
              changes.first == .appear && changes.dropFirst().allSatisfy { $0 == .update || $0 == .none } && hud.shown)
        check("HUD: …showing the latest level", hud.item?.level == Double(99 % 17) / 16)
        hud.post(HUDItem(icon: "sun.max.fill", text: "Brightness", level: 0.5), now: t)
        check("HUD: another kind swaps inside the same container", hud.item?.icon == "sun.max.fill" && hud.shown)
        check("HUD: it goes up once when the keys are quiet", hud.tick(now: t + HUDTimeline.levelQuiet + 0.01) == .hide && !hud.shown
              && hud.tick(now: t + 5) == .none)

        // The switch: spam ends where the clicks say (the knob's spring only follows the value).
        var on = false
        let sw = CocaineSwitch(Binding(get: { on }, set: { on = $0 }))
        for _ in 0..<31 { sw.action() }
        check("switch: 31 rapid clicks end on (odd), no state left half-way", on)

        // The dropdown: its own button spammed opens and closes it; the leaving card keeps what it showed.
        let center = PickerCenter()
        let spec = PickerSpec(id: "lang", title: "Language", items: ["English", "Italiano"].map { PickerItem(id: $0, title: $0) }, mode: .single("English"))
        for _ in 0..<40 { center.present(spec, anchor: .zero) }
        check("dropdown: 40 rapid open/close end closed; the card leaving still has what it showed", !center.isOpen && center.last?.spec.id == "lang")
        center.present(spec, anchor: .zero)
        check("dropdown: …and one more opens it", center.isOpen)
        center.tap("Italiano")
        check("dropdown: a pick closes it", !center.isOpen)

        // A dialog leaving keeps its card's content while it fades.
        let dialogs = DialogCenter()
        dialogs.show = { _ in .panel }
        dialogs.present(DialogTests.info()) { _ in }
        dialogs.cancel()
        check("dialog: answered at once: none shown, the leaving card keeps its content", dialogs.current == nil && dialogs.last?.spec.title == "Info")

        // Dragging a screen's row: the lift never stays up after a cancelled drag.
        var lift = DragLift()
        lift.begin("home"); lift.entered()
        check("drag: picked up over the list: lifted", lift.lifted("home") && !lift.lifted("music"))
        lift.entered(); lift.exited()
        check("drag: moving from row to row (enter before exit) keeps it lifted", lift.lifted("home"))
        lift.exited()
        check("drag: cancelled outside the list (Esc, released elsewhere): it is put down", !lift.lifted("home"))
        lift.exited(); lift.exited()
        check("drag: extra exits never go below zero", lift.inside == 0)
        for _ in 0..<30 { lift.begin("music"); lift.entered(); lift.exited() }
        check("drag: 30 quick drags left the list: nothing lifted", !lift.lifted("music"))
        lift.begin("music"); lift.entered(); lift.ended()
        check("drag: dropped: ended", lift.dragging == nil && !lift.lifted("music"))

        // Loading: the dots brighten one at a time.
        check("loading: one dot bright per phase", (0..<3).allSatisfy { p in (0..<3).filter { BusyDots.opacity(dot: $0, phase: p) == 1 }.count == 1 })
    }
}

/// `--motion-test`, run from main.swift (and by --selftest).
func cliMotionTest() {
    _ = NSApplication.shared
    var failed = 0
    MotionTests.run { name, ok in print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
    exit(failed == 0 ? 0 : 1)
}

// MARK: - The render aid

/// `--render-motion <out-prefix> [kind…] [--reduce-motion]`: for each transition (island, page, hud, dropdown, dialog; all by
/// default) a strip of five frames at 0, 25, 50, 75 and 100 %, written to <out-prefix>-<kind>.png. Memory-only settings, sample
/// content (never the user's).
func cliRenderMotion() {
    _ = NSApplication.shared
    precondition(AppDefaults.isolated, "renders run with memory-only settings (main.swift)")
    let args = CommandLine.arguments
    let out = args[2]
    Motion.disabled = true                                   // only the frame asked for, never an animation in between
    if args.contains("--reduce-motion") { Motion.reduceOverride = true }
    let all = ["island", "page", "hud", "dropdown", "dialog"]
    let kinds = args.dropFirst(3).filter { all.contains($0) }
    let frames: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
    for kind in kinds.isEmpty ? all : Array(kinds) {
        let reps = frames.map { MotionRender.frame(kind, $0) }
        let w = reps[0].size.width, h = reps[0].size.height
        let sheet = NSImage(size: NSSize(width: w * CGFloat(reps.count), height: h + 18))
        sheet.lockFocus()
        NSColor(white: 0.85, alpha: 1).setFill(); NSRect(origin: .zero, size: sheet.size).fill()
        for (i, r) in reps.enumerated() {
            r.draw(in: NSRect(x: w * CGFloat(i), y: 0, width: w, height: h))
            NSString(string: "\(kind) \(Int(frames[i] * 100))%" + (Motion.reduce ? " (Reduce Motion)" : "")).draw(at: NSPoint(x: w * CGFloat(i) + 6, y: h + 2),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.black])
        }
        sheet.unlockFocus()
        let path = out + "-" + kind + ".png"
        try? NSBitmapImageRep(data: sheet.tiffRepresentation!)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print(path)
    }
    exit(0)
}

private enum MotionRender {
    static func snapshot<V: View>(_ v: V, size: CGSize) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height, alignment: .top).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    static func island(_ f: CGFloat, configure: (IslandModel) -> Void) -> NSBitmapImageRep {
        let pm = PanelModel()
        pm.persistLanguage = false
        pm.on = true; pm.fillLevel = 1
        let im = IslandModel()
        im.pm = pm
        im.geometry = NotchGeometry(frame: .zero, notchWidth: 185, height: 32, centerX: 0, hasNotch: true)
        configure(im)
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.55, green: 0.7, blue: 0.9), Color(red: 0.8, green: 0.6, blue: 0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
            IslandView(model: im, m: pm, focus: im.focus, batteries: im.batteries, mic: im.mic, usage: im.usage)
        }
        return snapshot(view, size: CGSize(width: 680, height: 250))
    }

    static func frame(_ kind: String, _ f: CGFloat) -> NSBitmapImageRep {
        Motion.frame = nil
        switch kind {
        case "island":
            return island(f) { im in im.renderProgress = f; im.open = f > 0 }
        case "page":
            return island(f) { im in
                im.renderProgress = 1; im.open = true
                let tabs = im.tabs.map(\.id)
                im.tab = tabs.count > 1 ? tabs[1] : tabs[0]
                im.renderPageFrom = tabs[0]
                im.pager.note(from: 0, to: 1)
                Motion.frame = f
            }
        case "hud":
            let rep = island(f) { im in im.flashNotice("speaker.wave.2.fill", "Volume", level: 0.6); Motion.frame = f }
            Motion.frame = nil
            return rep
        case "dropdown":
            let c = PickerCenter()
            c.present(PickerSpec(id: "lang", title: "Language", items: ["English", "Italiano", "Deutsch", "日本語"].map { PickerItem(id: $0, title: $0) },
                                 mode: .single("Italiano")), anchor: CGRect(x: 0, y: 40, width: 100, height: 24))
            let v = ZStack(alignment: .topLeading) {
                Color.black
                HStack { Text("Language").font(UI.title); Spacer(); Text("Italiano").font(UI.value) }
                    .foregroundStyle(.white).padding(.horizontal, 24).frame(height: 24).offset(y: 40)
                PickerCard(center: c).frame(width: 412)
                    .modifier(MotionEnter(t: 1 - f, edge: .top, anchor: .top, reduce: Motion.reduce))
                    .padding(.leading, 14).padding(.top, PickerLayer.top(c.anchor))
            }
            return snapshot(v, size: CGSize(width: 440, height: 250))
        default:   // dialog
            let c = DialogCenter()
            c.show = { _ in .panel }
            c.present(DialogSpec(icon: "arrow.counterclockwise", title: "Restore the standard screens?", message: "Every screen shown, in the original order.",
                                 buttons: [DialogButton(id: "restore", title: "Restore", role: .destructive), DialogButton(id: "cancel", title: "Cancel", role: .cancel)])) { _ in }
            let v = ZStack(alignment: .top) {
                Color.black
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<6, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)).frame(height: 28)
                            .overlay(Text("Row \(i + 1)").font(UI.title).foregroundStyle(.white).padding(.leading, 10), alignment: .leading)
                    }
                }.padding(14)
                Color.black.opacity(0.72 * Double(f))
                InAppDialogCard(center: c, style: UI.dialog).padding(.horizontal, 14).padding(.top, 14)
                    .modifier(MotionEnter(t: 1 - f, edge: .top, anchor: .top, reduce: Motion.reduce))
            }
            return snapshot(v, size: CGSize(width: 440, height: 250))
        }
    }
}
