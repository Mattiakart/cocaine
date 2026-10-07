// Render tools: saved settings around renders, the island pixel checks, the sample dialogs.

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

/// The render tools fill a PanelModel with sample values, which writes some into the real settings: this puts back exactly what
/// was there (removing them instead wiped the user's own Stay active, HUD and timer choices).
struct SavedSettings {
    static let keys = ["triggerSchedule", "scheduleDays", "scheduleStart", "scheduleEnd", "triggerPower", "triggerDisplay", "triggerAll", "dimEnabled", "screenOff",
                       "timerMinutes", "batteryThreshold", "batteryTurnsOff", "triggerAgents", "triggerApps", "hotkeys", "onUntil", "wakeForPhone", "island",
                       "stayActive", "stayActiveAlways", "stayActiveApps", "replaceHUD", "haptics", "alertDone", "alertInput", "alertFlash", "alertSpeak", "alertVoice",
                       "alertPerSession", "agentApprovals", "alertWhenPresent", "alertRepeatMinutes", "alertDuration", "alertSound", "language"]
    let values: [String: Any] = Dictionary(uniqueKeysWithValues: keys.compactMap { k in UserDefaults.standard.object(forKey: k).map { (k, $0) } })
    func restore() {
        for k in Self.keys { if let v = values[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        UserDefaults.standard.synchronize()
    }
}

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
        let saved = SavedSettings()
        defer { saved.restore() }                                  // the checks must not leave anything in the real settings
        UserDefaults.standard.set(false, forKey: "stayActive")     // the states below are the ones named, whatever the user has on
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
