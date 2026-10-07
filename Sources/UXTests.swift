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
