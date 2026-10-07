// Tests of the keyboard, accessibility, performance and partial-feature work (part of --selftest, and --ux-test alone).
// Nothing here touches the user's settings, ~/.claude or ~/.codex: temporary folders and suites only.

import AppKit
import SwiftUI

func uxSelfTest(_ check: (String, Bool) -> Void) {
    ShortcutTests.run(check)
    FocusTests.run(check)
    UsageTests.run(check)
    MusicTests.run(check)
    a11ySelfTest(check)
    healthSelfTest(check)
}

/// The shared helpers (Proc, SafeFile, ProcessList), the pause point, and constants that must agree across files.
func healthSelfTest(_ check: (String, Bool) -> Void) {
    // Proc: a timeout, output past the pipe's 64 KB read while it runs, a bounded capture, a grandchild holding the pipe.
    let t0 = Date()
    let slow = Proc.run("/bin/sleep", ["5"], timeout: 0.5)
    check("proc: a program past its timeout is stopped (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)", slow.timedOut && slow.status == -1 && Date().timeIntervalSince(t0) < 3)
    let big = Proc.run("/bin/sh", ["-c", "head -c 300000 /dev/zero"], timeout: 10, capture: true)
    check("proc: 300 KB of output never blocks (\(big.output.count) bytes)", big.status == 0 && big.output.count == 300_000)
    let capped = Proc.run("/bin/sh", ["-c", "head -c 300000 /dev/zero"], timeout: 10, capture: true, limit: 1000)
    check("proc: the capture is bounded", capped.status == 0 && capped.output.count == 1000)
    let t1 = Date()
    let held = Proc.run("/bin/sh", ["-c", "echo hi; (sleep 5 &) ; exit 0"], timeout: 10, capture: true)
    check("proc: a child left holding the pipe doesn't hold the answer back", held.text.hasPrefix("hi") && Date().timeIntervalSince(t1) < 3)
    check("proc: a program that can't start says so", Proc.run("/nonexistent", []).status == -1)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-safe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let f = dir.appendingPathComponent("x.json")
    let wrote = SafeFile.writePrivate(Data("one".utf8), to: f) && SafeFile.writePrivate(Data("two".utf8), to: f)
    check("safefile: written over atomically, 0600, nothing left behind",
          wrote && (try? String(contentsOf: f, encoding: .utf8)) == "two"
          && (try? FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int) == 0o600
          && (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count == 1)
    check("processes: this one is listed", ProcessList.all().contains { $0.pid == getpid() })
    check("wake: the app and crash recovery write the scheduled wake's date the same way (else recovery can't cancel it)",
          [1_790_000_000.0, 1_800_000_123.0].allSatisfy { WakeSchedule.format(Date(timeIntervalSince1970: $0)) == Recovery.wakeString($0) })
    var seen: [Bool] = []
    let token = PowerAwareness.shared.subscribe { seen.append($0) }
    PowerAwareness.shared.set("screens", true); PowerAwareness.shared.set("session", true); PowerAwareness.shared.set("screens", false)
    PowerAwareness.shared.set("session", false)
    PowerAwareness.shared.unsubscribe(token)
    check("energy: the pollers pause while the screens sleep or another user is on, once each way", seen == [true, false])
}

/// Announcements, the island's keys, contrast.
func a11ySelfTest(_ check: (String, Bool) -> Void) {
    var said: [String] = []
    let post = A11y.post
    A11y.post = { said.append($0) }
    defer { A11y.post = post }

    let im = IslandModel()
    im.flashNotice("doc.on.clipboard.fill", "Copied")
    im.flashNotice("speaker.wave.2.fill", "Volume", level: 0.4)
    check("a11y: an island flash is announced (not the volume/brightness levels)", said == ["Copied"])

    // The island's keys: ← → change tabs, Esc closes, ↑ ↓ on the Clipboard page.
    im.open = true; im.tab = "home"
    var closed = 0
    let close = { closed += 1 }
    check("keys: → goes to the next tab and says it", IslandKeys.handle(124, flags: [], editing: false, model: im, close: close) && im.tab == im.tabs[1].id
          && said.last == im.tabs[1].title)
    _ = IslandKeys.handle(123, flags: [], editing: false, model: im, close: close)
    _ = IslandKeys.handle(123, flags: [], editing: false, model: im, close: close)
    check("keys: ← goes back and stops at the first tab", im.tab == "home")
    check("keys: arrows in a text field stay the field's", !IslandKeys.handle(124, flags: [], editing: true, model: im, close: close) && im.tab == "home")
    check("keys: with ⌘ they aren't the island's", !IslandKeys.handle(124, flags: [.command], editing: false, model: im, close: close))
    check("keys: Esc closes the open island", IslandKeys.handle(53, flags: [], editing: false, model: im, close: close) && closed == 1)
    im.open = false
    check("keys: …and does nothing when it is closed", !IslandKeys.handle(53, flags: [], editing: false, model: im, close: close) && closed == 1)

    // Contrast of the fixed colors (WCAG relative luminance).
    func lum(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func c(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b)
    }
    func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
    let card = 0.07                                                      // white 0.07 on black
    check("contrast: white on the destructive fill ≥ 4.5:1 (\(String(format: "%.1f", ratio(1, lum(0.78, 0.18, 0.16)))):1; it was 3.9)",
          ratio(1, lum(0.78, 0.18, 0.16)) >= 4.5)
    let edge = card + 0.34 * (1 - card)
    check("contrast: a control's edge on the card ≥ 3:1 (\(String(format: "%.1f", ratio(lum(edge, edge, edge), lum(card, card, card)))):1)",
          ratio(lum(edge, edge, edge), lum(card, card, card)) >= 3)
    let row = 0.08, star = row + 0.4 * (1 - row)
    check("contrast: the clipboard's star ≥ 3:1 on its row (\(String(format: "%.1f", ratio(lum(star, star, star), lum(row, row, row)))):1; it was 1.7)",
          ratio(lum(star, star, star), lum(row, row, row)) >= 3)
    check("contrast: the text field's placeholder ≥ 4.5:1 on black (\(String(format: "%.1f", ratio(lum(0.5, 0.5, 0.5), 0))):1)", ratio(lum(0.5, 0.5, 0.5), 0) >= 4.5)
    let dimmed = card + 0.6 * UI.disabledOpacity * (1 - card)
    check("contrast: a dimmed group's secondary text stays ≥ 3:1 (\(String(format: "%.1f", ratio(lum(dimmed, dimmed, dimmed), lum(card, card, card)))):1; it was 2.1)",
          ratio(lum(dimmed, dimmed, dimmed), lum(card, card, card)) >= 3)
    DisplayOptions.shared.forceContrast = true
    check("contrast: Increase Contrast brightens the secondary and hint inks", UI.disabledOpacity > 0.6 && DisplayOptions.contrast)
    DisplayOptions.shared.forceContrast = nil
    check("strings: French \"Screens off now\" isn't the same word as \"Screen off\"", { () -> Bool in
        guard let p = Bundle.main.path(forResource: "fr", ofType: "lproj"), let b = Bundle(path: p) else { return true }
        return b.localizedString(forKey: "Screens off now", value: nil, table: "Design") != b.localizedString(forKey: "Screen off", value: nil, table: "Design")
    }())
    check("flags: Traditional Chinese doesn't show China's flag", Language.flag("zh-Hant") != Language.flag("zh-Hans"))
}

/// `--ux-test`, run from main.swift.
func cliUXTest() {
    _ = NSApplication.shared
    var failed = 0
    uxSelfTest { name, ok in print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
    exit(failed == 0 ? 0 : 1)
}
