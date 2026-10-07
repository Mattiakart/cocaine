// Render tools: --render-panel, --render-island, --island-selfcheck (memory-only settings, see AppDefaults), the island pixel checks, sample dialogs.

import AppKit
import AVFoundation
import Combine
import CoreAudio
import EventKit
import Carbon.HIToolbox
import Darwin
import ImageIO
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import os

/// Offscreen checks of the island exactly as the live window holds it: the real IslandView in a hosting view of the real window
/// frame (IslandController.windowFrame), so a canvas that ends up outside the window shows up as missing pixels.
enum IslandCheck {
    static func render(_ im: IslandModel, _ pm: PanelModel, frame: NSRect) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: IslandView(model: im, m: pm, focus: im.focus, batteries: im.batteries, mic: im.mic, usage: im.usage))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: frame.size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels in a box (points, from the top left) that are clearly not black: (bright, pinkish).
    static func count(_ rep: NSBitmapImageRep, _ box: NSRect, pointWidth: CGFloat) -> (bright: Int, pink: Int) {
        let s = CGFloat(rep.pixelsWide) / pointWidth
        var bright = 0, pink = 0
        for y in max(0, Int(box.minY * s))..<min(rep.pixelsHigh, Int(box.maxY * s)) {
            for x in max(0, Int(box.minX * s))..<min(rep.pixelsWide, Int(box.maxX * s)) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.3 else { continue }
                if max(c.redComponent, c.greenComponent, c.blueComponent) > 0.35 { bright += 1 }
                if c.redComponent > 0.6 && c.redComponent - c.greenComponent > 0.2 { pink += 1 }
            }
        }
        return (bright, pink)
    }

    static func alpha(_ rep: NSBitmapImageRep, _ pt: CGPoint, pointWidth: CGFloat) -> CGFloat {
        let s = CGFloat(rep.pixelsWide) / pointWidth
        return rep.colorAt(x: min(rep.pixelsWide - 1, Int(pt.x * s)), y: min(rep.pixelsHigh - 1, Int(pt.y * s)))?.alphaComponent ?? 0
    }

    static func run() -> Int32 {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
        precondition(AppDefaults.isolated, "--island-selfcheck must run with memory-only settings (main.swift)")
    let savedMotion = Motion.disabled
    Motion.disabled = true                                     // the states drawn at once, never a frame of a transition
    defer { Motion.disabled = savedMotion }
        AppDefaults.store.set(false, forKey: "stayActive")     // the states below are the ones named, whatever the user has on
        let g = NotchGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 185, height: 32, centerX: 756, hasNotch: true)
        let closed = IslandController.windowFrame(g, open: false), opened = IslandController.windowFrame(g, open: true)
        check("island: the closed window holds both wings", closed.minX <= g.centerX - g.notchWidth / 2 - IslandModel.maxWing
              && closed.maxX >= g.centerX + g.notchWidth / 2 + IslandModel.maxWing)
        check("island: the window hangs from the top edge", closed.maxY == g.frame.maxY + Island.overscan && opened.maxY == g.frame.maxY + Island.overscan)
        // The bag's box in the closed window (from its top left): left of the notch, in the middle of the menu bar's height.
        let bagX = closed.width / 2 - g.notchWidth / 2 - Island.wing / 2, midY = Island.overscan + g.height / 2
        let bagBox = NSRect(x: bagX - 11, y: midY - 11, width: 22, height: 22)
        var offBright = 0
        for state in ["off", "on", "pink"] {
            let pm = PanelModel()
            pm.persistLanguage = false
            pm.on = state == "on"; pm.fillLevel = pm.on ? 1 : 0; pm.stayActive = state == "pink"; pm.pinkLevel = state == "pink" ? 1 : 0        // Stay active alone, with no chat app open
            let im = IslandModel()
            im.pm = pm; im.geometry = g                 // renderProgress nil: the live path, driven by `open` alone
            let rep = render(im, pm, frame: closed)
            let bag = count(rep, bagBox, pointWidth: closed.width)
            check("pink powder (\(state)): it heads for \(pm.pinkTarget)", pm.pinkTarget == (state == "pink" ? 1 : 0))
            check("island closed (\(state)): the bag is drawn left of the notch (\(bag.bright) px)", bag.bright > 20)
            if state == "off" { offBright = bag.bright }
            if state == "on" { check("island closed (on): the bag is full of powder (\(bag.bright) > \(offBright) px)", bag.bright > offBright) }
            if state == "pink" { check("island closed (Stay active only): the bag is pink (\(bag.pink) px)", bag.pink > 20) }
            check("island closed (\(state)): the notch is filled black", alpha(rep, CGPoint(x: closed.width / 2, y: midY), pointWidth: closed.width) > 0.9)
            let right = count(rep, NSRect(x: closed.width / 2 + g.notchWidth / 2 + 4, y: midY - 10, width: Island.wing - 8, height: 20), pointWidth: closed.width)
            check("island closed (\(state)): the right wing shows what is live only when something is (\(right.bright) px)", state != "off" ? right.bright > 10 : right.bright == 0)
        }
        // Open: the bag has become the Home tab, the page is there.
        let pm = PanelModel()
        pm.persistLanguage = false
        pm.on = true; pm.fillLevel = 1
        let im = IslandModel()
        im.pm = pm; im.geometry = g; im.open = true
        let rep = render(im, pm, frame: opened)
        let l = IslandLayout(notch: g.notchWidth, notchH: g.height)
        let cell = IslandView.cellWidth(tabs: Island.tabs(external: Island.external).count)
        let homeX = IslandView.stripStart(opened.width / 2, cell: cell) + cell / 2
        check("island open: the first tab's highlight starts on the page's text edge, 18 pt in",
              abs(IslandView.stripStart(0, cell: cell) + (cell - IslandView.highlight(cell)) / 2 - (-IslandLayout.openBody / 2 + Space.page)) < 0.01
              && IslandView.highlight(28) <= 26 && IslandView.highlight(31) <= 29)
        let home = count(rep, NSRect(x: homeX - 11, y: midY - 11, width: 22, height: 22), pointWidth: opened.width)
        check("island open: the Home tab is in the strip (\(home.bright) px)", home.bright > 20)
        let page = count(rep, NSRect(x: opened.width / 2 - IslandLayout.openBody / 2, y: l.top + g.height + 8, width: IslandLayout.openBody, height: 150), pointWidth: opened.width)
        check("island open: the page is drawn (\(page.bright) px)", page.bright > 300)
        return failed == 0 ? 0 : 1
    }
}
/// The render tools' dialogs (`--dialog <kind>`), each exactly as the app presents it, on the surface being drawn.
func renderSampleDialog(_ args: [String], surface: DialogSurface) {
    guard let i = args.firstIndex(of: "--dialog"), i + 1 < args.count else { return }
    let kind = args[i + 1]
    var spec: DialogSpec
    switch kind {
    case "links": spec = Dialogs.links(URL(string: "cocaine://on?minutes=90&x-success=shortcuts://x-callback-url/run-shortcut")!)
    case "pattern", "pattern-bad": spec = Dialogs.clipPattern(surface)
    case "persist": spec = Dialogs.clipPersist(surface)
    case "delete": spec = Dialogs.clipDeleteAll(surface)
    case "deletefail": spec = Dialogs.message(L("Some of it couldn't be deleted"), ClipStore.defaultDir.path)
    case "pair": spec = Dialogs.pairPhone()
    case "revoke": spec = Dialogs.revokePhones()
    case "ai": spec = Dialogs.message(L("Can't change AI alerts"), "~/.claude/settings.json\n~/.codex/hooks.json")
    case "login": spec = Dialogs.message(L("Can't change Open at Login"),
                                         "The operation couldn’t be completed. Operation not permitted\n\n" + L("You can add Cocaine manually in System Settings → General → Login Items."))
    case "wake": spec = Dialogs.message(L("Couldn't turn on the wake-ups"))
    case "shortcut": spec = Dialogs.message(L("Can't make the Shortcut"), L("Signing it needs an internet connection and iCloud (sign in to it in System Settings)."))
    case "airdrop": spec = Dialogs.message(L("Couldn't share it"), L("AirDrop isn't available on this Mac right now."))
    case "trash": spec = IslandChoices.spec(L("Clear"), icon: "trash", IslandChoices.clipboardTrash)
    case "input": spec = IslandChoices.spec(L("Input"), icon: "cable.connector", ["HDMI 1", "HDMI 2", "DisplayPort 1", "DisplayPort 2", "USB-C"].map { DialogChoice(id: $0, title: $0, symbol: "cable.connector") })
    case "camera": spec = IslandChoices.spec(L("Camera"), icon: "camera", [DialogChoice(id: "a", title: "FaceTime HD Camera", symbol: "checkmark"), DialogChoice(id: "b", title: "iPhone Camera", symbol: "camera")])
    case "removeold": spec = Dialogs.removeOldShortcuts()
    case "allowold": spec = Dialogs.allowOldShortcuts()

    case "share":
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cocaine-render-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Cocaine.shortcut")
        try? Data("sample".utf8).write(to: file)
        spec = Dialogs.share(Sharing.services(for: [file]))
        try? FileManager.default.removeItem(at: dir)
    default: print("unknown dialog \(kind)"); return
    }
    spec.surface = surface
    DialogCenter.shared.show = { _ in surface }
    DialogCenter.shared.present(spec) { _ in }
    if kind == "pattern-bad" { DialogCenter.shared.text = "([a-z"; DialogCenter.shared.press("add") }
}

/// `--island-selfcheck`, run from main.swift.
func cliIslandSelfcheck() {
    _ = NSApplication.shared
    exit(IslandCheck.run())
}

/// `--render-island`, run from main.swift.
func cliRenderIsland() {
    // Draws the island offscreen to a PNG: --open, --tab <id>, --lang <code>, --focus (a running focus), --mic, --agents.
    _ = NSApplication.shared
    precondition(AppDefaults.isolated, "renders run with memory-only settings (main.swift): their samples never reach the real ones")
    Motion.disabled = true                                     // deterministic: the state drawn, never a frame of a transition
    let args = CommandLine.arguments
    let pm = PanelModel()
    pm.persistLanguage = false
    pm.language = args.firstIndex(of: "--lang").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
    pm.on = !args.contains("--off"); pm.fillLevel = pm.on ? 1 : 0
    pm.ai = AIHooks.Status(tools: AIHooks.tools.enumerated().map { i, t in AIHooks.Entry(id: t.id, name: t.name, installed: i < 3, on: i < 2) }, codexNeedsTrust: false)
    if args.contains("--agents") {
        let t = Date().timeIntervalSince1970
        pm.board = [AgentEntry(id: "1", from: "Claude Code", project: "canonical-com", state: "working", since: t - 400),
                    AgentEntry(id: "2", from: "Codex", project: "PneuSuperStore", state: "waiting", since: t - 90)]
    }
    if args.contains("--many-agents") || args.contains("--approval") {         // the full list, and a request to answer
        (pm.board, pm.approvals) = AgentTests.sample(approval: args.contains("--approval"))
    }
    pm.timerMinutes = 120; pm.onUntil = Date().addingTimeInterval(7000)
    if args.contains("--presence") { pm.presenceActive = true; pm.pinkLevel = 1 }
    if let i = args.firstIndex(of: "--pink-level"), i + 1 < args.count, let v = Double(args[i + 1]) { pm.pinkLevel = CGFloat(v); pm.pinkPouring = v < 1 }        // a frame of the pink powder filling
    // Before the model works out its tabs: --external (the Monitors screen), --screens-fixture <name> (an arranged layout,
    // ScreenFixtures in Sources/ScreensTests.swift).
    Island.forceExternal = args.contains("--external")
    applyScreensFixture(args)
    let im = IslandModel()
    im.pm = pm
    // --notch-width 210: another Mac's notch (a 14" is 185 pt; scaled resolutions change it).
    let notchW = args.firstIndex(of: "--notch-width").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }.map { CGFloat($0) } ?? 185
    // --notch-height 38: a taller menu bar (the open page gets shorter); --tab calendar draws the fixture events (never the
    // user's calendar), with --calendar-view day|week|month, --calendar-details, --calendar-select YYYY-MM-DD, --calendar-access denied|notasked.
    let notchH = args.firstIndex(of: "--notch-height").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }.map { CGFloat($0) } ?? 32
    im.geometry = NotchGeometry(frame: .zero, notchWidth: notchW, height: notchH, centerX: 0, hasNotch: true)
    im.calendar.renderSample(args)
    im.open = args.contains("--open")
    if let i = args.firstIndex(of: "--tab"), i + 1 < args.count { im.tab = args[i + 1] }
    if args.contains("--focus") { im.focus.start() }
    if args.contains("--mic") { im.mic.active = true }
    im.batteries.items = [BatteryItem(id: "mac", name: "MacBook Pro", icon: "laptopcomputer", parts: [("", 80)], charging: true),
                          BatteryItem(id: "a", name: "AirPods Pro", icon: "airpodspro", parts: [("L", 71), ("R", 64), ("↳", 90)]),
                          BatteryItem(id: "k", name: "Magic Keyboard", icon: "keyboard", parts: [("", 22)])]
    im.usage.codex = [UsageWatch.Limit(id: "w", name: L("Week"), percent: 5, resets: Date().addingTimeInterval(86400 * 5))]
    im.files.downloads = [FileShelf.Item(url: URL(fileURLWithPath: "/Applications/Cocaine.app"), date: Date(), size: 5_200_000),
                          FileShelf.Item(url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), date: Date(), size: 120_000_000)]
    im.files.shots = (0..<5).map { FileShelf.Item(url: URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic").deletingLastPathComponent().appendingPathComponent("shot\($0).png"), date: Date(), size: 1) }
    im.clipboard.replace([ClipItem.text("brew upgrade --cask cocaine"), {
                              var f = ClipItem.files(["/System/Library/CoreServices/Finder.app"]); f.pinned = true; return f }(),
                          ClipItem.text("https://github.com/Mattiakart/cocaine"), ClipItem.text("Ciao Mario, ti mando il file domani mattina"),
                          ClipItem.files(["/tmp/cocaine-no-such-file.pdf"])])
    im.music.setSample(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
    if args.contains("--shelf") { im.shelf.urls = [URL(fileURLWithPath: "/Applications/Cocaine.app"), URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")] }
    im.usage.claudeFive = 412_000; im.usage.claudeWeek = 8_600_000; im.usage.loaded = true
    // The morph: --progress 0.3 (or a list, 0,0.15,0.3…, drawn one under the other) draws those moments of opening; closing runs
    // the same frames backwards. --flash "text" / --level 0.6 shows a flash message, --pink the pink bag, --external the Monitors tab,
    // --notch covers the notch like the hardware does (what you really see), --xray shows it in translucent red instead.
    let progress = args.firstIndex(of: "--progress").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }?
        .split(separator: ",").compactMap { Double($0).map { CGFloat($0) } }
    if let i = args.firstIndex(of: "--flash"), i + 1 < args.count {
        let level = args.firstIndex(of: "--level").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
        im.flashNotice(level == nil ? "arrow.down.circle.fill" : "speaker.wave.2.fill", args[i + 1], level: level)    // the HUD below the notch
    }
    if args.contains("--pink") { pm.on = false; pm.fillLevel = 0; pm.presenceActive = true; pm.pinkLevel = 1 }        // Stay active alone: the pink bag
    Island.forceExternal = args.contains("--external")
    renderSampleDialog(args, surface: .island)                 // --dialog <kind>: a dialog in the open island
    if args.contains("--live-window") {
        // What the real window shows: the IslandView alone in a hosting view of the live window's size (closed: 465×38 on a
        // 185 pt notch), not the roomy canvas above. --island-selfcheck runs the same thing and checks the pixels.
        let g = NotchGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 185, height: 32, centerX: 756, hasNotch: true)
        im.geometry = g
        if let p = progress?.first { im.renderProgress = p; im.open = p > 0 }
        let rep = IslandCheck.render(im, pm, frame: IslandController.windowFrame(g, open: im.open))
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
        exit(0)
    }
    let notch = args.contains("--notch") ? Color.black : args.contains("--xray") ? Color.red.opacity(0.45) : nil
    func frame(_ p: CGFloat?) -> NSBitmapImageRep {
        if let p { im.renderProgress = p; im.open = p > 0 }
        let l = IslandLayout(notch: notchW, notchH: notchH)
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.55, green: 0.7, blue: 0.9), Color(red: 0.8, green: 0.6, blue: 0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
            IslandView(model: im, m: pm, focus: im.focus, batteries: im.batteries, mic: im.mic, usage: im.usage)
            if let notch {
                IslandOutline(pose: IslandPose(p: 0, leftW: 0, rightW: 0), layout: l).fill(notch).frame(width: l.size.width, height: l.size.height)
            }
        }.frame(width: 760, height: im.open || progress != nil ? 250 : im.flash != nil ? 110 : 70, alignment: .top).clipped()
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))      // measured sizes (lists that fade when cut) settle
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
    var reps = progress.map { $0.map { frame($0) } } ?? [frame(nil)]
    if reps.count > 1 {                     // a contact sheet, labelled with each frame's progress
        let w = reps[0].size.width, h = reps[0].size.height, sheet = NSImage(size: NSSize(width: w, height: h * CGFloat(reps.count)))
        sheet.lockFocus()
        for (i, r) in reps.enumerated() {
            r.draw(in: NSRect(x: 0, y: h * CGFloat(reps.count - 1 - i), width: w, height: h))
            NSString(string: String(format: "p %.2f", progress![i])).draw(at: NSPoint(x: 8, y: h * CGFloat(reps.count - 1 - i) + 8),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.black])
        }
        sheet.unlockFocus()
        reps = [NSBitmapImageRep(data: sheet.tiffRepresentation!)!]
    }
    try? reps[0].representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}

/// `--render-panel`, run from main.swift.
func cliRenderPanel() {
    // Draws the panel offscreen to a PNG, in the language picked by -AppleLanguages, to check translations fit.
    _ = NSApplication.shared
    precondition(AppDefaults.isolated, "renders run with memory-only settings (main.swift): their samples never reach the real ones")
    Motion.disabled = true                                     // deterministic: a dropdown or dialog drawn fully there
    let model = PanelModel()
    model.persistLanguage = false
    let langArg = CommandLine.arguments.firstIndex(of: "--lang").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
    model.language = langArg ?? ""                  // never the user's saved choice: "" = same as the Mac
    model.on = !CommandLine.arguments.contains("--off")
    model.fillLevel = model.on ? 1 : 0
    model.needsAuth = CommandLine.arguments.contains("--needs-auth")
    model.holdMissing = CommandLine.arguments.contains("--hold-missing")
    // --ai-on connects the first two tools, --codex-trust shows the Codex reminder, --no-ai hides the row.
    model.ai = AIHooks.Status(tools: AIHooks.tools.enumerated().map { i, t in
        AIHooks.Entry(id: t.id, name: t.name, installed: !CommandLine.arguments.contains("--no-ai") && i < 3,
                      on: CommandLine.arguments.contains("--ai-on") && i < 2)
    }, codexNeedsTrust: CommandLine.arguments.contains("--codex-trust"))
    if CommandLine.arguments.contains("--paused") { model.alertsPausedUntil = Date().addingTimeInterval(3600) }
    if CommandLine.arguments.contains("--ai-open") { model.page = "ai" }
    if CommandLine.arguments.contains("--last") {                  // a sample "Recent alerts" list
        model.history = [("Claude Code", "has finished", "Cocaine", 0.0), ("Codex", "needs your input", "PneuSuperStore", 900),
                         ("Cursor", "has finished", "Gestionale", 4000)]
            .map { AlertRecord(from: $0.0, message: L($0.1), project: $0.2, at: Date().addingTimeInterval(-$0.3)) }
    } else {
        model.history = []                                         // never the user's real alerts (project names) in a render
    }
    // --island / --no-island: hanging from the notch (the strip) or not, whatever the real setting; --notch-width 210: another Mac's notch.
    applyScreensFixture(CommandLine.arguments)                  // --screens-fixture <name>, --screens-edit <screen id>
    if CommandLine.arguments.contains("--island") { model.island = true }
    if CommandLine.arguments.contains("--no-island") { model.island = false }
    if let i = CommandLine.arguments.firstIndex(of: "--notch-width"), i + 1 < CommandLine.arguments.count, let w = Double(CommandLine.arguments[i + 1]) {
        NotchGeometry.override = NotchGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: CGFloat(w), height: 32, centerX: 756, hasNotch: true)
    }
    if let i = CommandLine.arguments.firstIndex(of: "--auto"), i + 1 < CommandLine.arguments.count {   // open a group of Automation
        let wanted = CommandLine.arguments[i + 1]
        model.page = ["none", "timer", "battery", "general"].contains(wanted) ? "" : wanted == "ai" ? "ai" : wanted == "island" ? "island" : "auto"
        if wanted == "island" { model.island = true }                 // the Island tab exists only while the island is on
        if CommandLine.arguments.contains("--schedule") { model.triggerSchedule = true; model.scheduleDays = [2, 3, 4, 5, 6]; model.scheduleStart = 540; model.scheduleEnd = 1080 }
        model.triggerAgents = true; model.triggerApps = ["Xcode"]; model.timerMinutes = 120; model.batteryThreshold = 20
        model.phoneCount = CommandLine.arguments.contains("--no-phone") ? 0 : 1; model.phoneLinkUp = true; model.battery = "80%"
        model.phone = "Comando Rapido “Avvisa iPhone”"
    }
    if CommandLine.arguments.contains("--agents") {
        let t = Date().timeIntervalSince1970
        model.board = [AgentEntry(id: "1", from: "Claude Code", project: "canonical-com", state: "working", since: t - 400),
                       AgentEntry(id: "2", from: "Codex", project: "PneuSuperStore", state: "waiting", since: t - 90),
                       AgentEntry(id: "3", from: "Cursor", project: "Gestionale", state: "error", since: t - 30)]
    }
    if CommandLine.arguments.contains("--many-agents") || CommandLine.arguments.contains("--approval") {
        (model.board, model.approvals) = AgentTests.sample(approval: CommandLine.arguments.contains("--approval"))
    }
    if CommandLine.arguments.contains("--speak") {                  // the longest voice name: the widest thing a row can hold
        model.alertSpeak = true
        model.alertVoice = Voices.available.map(\.identifier).max { Voices.name($0).count < Voices.name($1).count } ?? ""
    }
    if CommandLine.arguments.contains("--longsound") { model.alertDuration = 0; model.alertRepeatMinutes = 10 }
    AwakeModel.shared.fillSample(rows: CommandLine.arguments.contains("--awake"))   // keep-awake rows: sample lists, never this Mac's
    if let i = CommandLine.arguments.firstIndex(of: "--timer"), i + 1 < CommandLine.arguments.count { model.timerMinutes = Int(CommandLine.arguments[i + 1]) ?? 0 }
    renderSampleDialog(CommandLine.arguments, surface: .panel)          // --dialog <kind>: a dialog over the panel
    let checkOverflow = CommandLine.arguments.contains("--overflow-check")
    // The page with its dialog layer on top, as the panel's window stacks them (the dialog is over the visible area).
    let surface = PanelView(m: model).overlay(alignment: .top) { PanelDialogOverlay(m: model) }
    let host = checkOverflow ? NSHostingView(rootView: AnyView(surface.frame(width: Layout.width + 260, alignment: .topLeading)))
                             : NSHostingView(rootView: AnyView(surface.background(Color.black)))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
    if CommandLine.arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
    if CommandLine.arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))      // the dialog card's measured height reaches the panel
    // --picker <id>: that row's dropdown open (language, sound, voice, pause, triggerApps, stayApps, excludedApps, patterns,
    // scheduleStart…), checked to hang under its row, below the strip, inside the panel's frame.
    var pickerReport: String?
    if let i = CommandLine.arguments.firstIndex(of: "--picker"), i + 1 < CommandLine.arguments.count {
        let id = CommandLine.arguments[i + 1]
        if let open = PickerCenter.shared.openers[id] {
            open()
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
            let c = PickerCenter.shared, top = PickerLayer.top(c.anchor)
            let notchBottom = model.island ? Layout.overscan + (NotchGeometry.current()?.height ?? 0) : 0
            let ok = c.isOpen && top > c.anchor.maxY && top >= notchBottom && c.cardHeight > 0
            pickerReport = "\(ok ? "PASS" : "FAIL")  dropdown \(id): row bottom \(String(format: "%.1f", c.anchor.maxY)), card top \(String(format: "%.1f", top)) (under its row; strip ends at \(String(format: "%.1f", notchBottom))), card \(String(format: "%.0f", Layout.width - 2 * Space.frame))×\(String(format: "%.0f", c.cardHeight)) pt"
        } else {
            pickerReport = "FAIL  dropdown \(id): no such value button on this page (\(PickerCenter.shared.openers.keys.sorted().joined(separator: ", ")))"
        }
    }
    window.setContentSize(host.fittingSize)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    if checkOverflow {      // the rightmost painted pixel must stay inside the 14 pt margin
        var maxX = 0
        outer: for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { maxX = x; break outer }
        }
        let right = CGFloat(maxX + 1) * host.bounds.width / CGFloat(rep.pixelsWide)
        let ok = right <= Layout.width - 14 + 0.5
        print("\(ok ? "PASS" : "FAIL")  rightmost painted \(String(format: "%.1f", right)) pt (limit \(Layout.width - 14))")
    }
    if let pickerReport { print(pickerReport) }
    print(Bundle.main.preferredLocalizations.first ?? "?")

    exit(0)
}
