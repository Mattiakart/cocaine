// The island's window (IslandPanel) and its controller (IslandController).

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

private final class IslandPanel: NSPanel {
    /// A dialog in the island asks for the keyboard explicitly (Return, Esc, its text field); the panel never activates the app.
    var keyable = false
    /// Set by a mouse-down on a text field (the clipboard's search): only that click may take the keyboard. Clicking a tab or a
    /// button must not, or the next tab change had to put the window out and in again to give the keyboard back, which showed
    /// as the island fading out and popping back (seen live: every tab left after the Clipboard one).
    private var textKeyable = false
    override var canBecomeKey: Bool { keyable || textKeyable }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let content = contentView {
            let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            textKeyable = hit is NSTextField || hit is NSTextView
        }
        super.sendEvent(event)
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }     // exactly where we say, even above the screen
}

final class IslandController {
    let model = IslandModel()
    private var panel: IslandPanel?
    private var host: NSHostingView<IslandView>?
    private var openTimer: Timer?, closeTimer: Timer?, watchTimer: Timer?
    private var panelModel: PanelModel?
    private var enabled = false
    private var ticks = 0

    func start(panelModel: PanelModel, enabled: Bool, showSettings: @escaping () -> Void) {
        self.panelModel = panelModel
        model.pm = panelModel
        model.showSettings = showSettings
        model.hover = { [weak self] inside in self?.hover(inside) }
        model.toggleOpen = { [weak self] in self?.setOpen(!(self?.model.open ?? false)) }
        model.relayoutNow = { [weak self] in self?.relayout() }
        model.toggleKeyboard = { [weak self] in self?.toggleKeyboard() }
        startKeyboard()
        model.setKeyable = { [weak self] on in
            guard let p = self?.panel else { return }
            p.keyable = on
            if !on, p.isKeyWindow { p.orderOut(nil); p.orderFrontRegardless() }     // gives the keyboard back to the app in front
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.relayout(); self?.checkNow(); self?.model.refreshTabs()                    // a display plugged, unplugged, mirrored, the lid (clamshell)
        }
        // Into or out of a full-screen Space, displays awake again: hidden or shown at once, not at the next check.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.checkNow() }    // after the Space's windows are in
            }
        }
        model.mic.start()
        startPointerMonitors()
        model.files.onNew = { [weak model] icon, text in model?.flashNotice(icon, text) }
        model.airDrop = { urls in                     // one tap: straight to AirDrop's own picker; a problem is said in the island
            guard !urls.isEmpty else { return }
            Sharing.shared.perform(NSSharingService(named: .sendViaAirDrop), urls, surface: .island)
        }
        model.dropTargeted = { [weak self] t in
            guard t, let self else { return }
            self.model.tab = "shelf"
            self.setOpen(true)
        }
        model.hud.onChange = { [weak model] icon, text, level in DispatchQueue.main.async { model?.flashNotice(icon, text, level: level) } }
        setEnabled(enabled)
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        guard on else { DialogCenter.shared.surfaceClosed(.island); panel?.orderOut(nil); watchTimer?.invalidate(); watchTimer = nil; model.files.stop(); model.clipboard.stop(); model.music.stop(); model.hud.stop(); return }
        model.files.start(); model.clipboard.start(); model.music.start()
        syncHUD(panelModel?.replaceHUD ?? false)
        if panel == nil, let pm = panelModel {
            let p = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.hidesOnDeactivate = false; p.isMovable = false
            p.animationBehavior = .none                  // no system fade/scale when it is ordered out and in (the island morphs by itself)
            p.appearance = NSAppearance(named: .darkAqua)
            let h = NSHostingView(rootView: IslandView(model: model, m: pm, focus: model.focus, batteries: model.batteries, mic: model.mic, usage: model.usage))
            h.sizingOptions = []
            p.contentView = h
            panel = p; host = h
        }
        missed = 0
        relayout()
        panel?.orderFrontRegardless()
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.watch() }
    }

    /// Size and place the window: just the closed island, or the open one (with a little room for the spring's overshoot).
    /// The SwiftUI canvas inside is fixed and centred on the notch, so these instant resizes never move what is drawn.
    func relayout() {
        guard enabled, let g = NotchGeometry.current(), let panel else { return }
        if g != model.geometry { model.geometry = g }
        panel.ignoresMouseEvents = !model.open
        let f = Self.windowFrame(g, open: model.open)
        if panel.frame != f { panel.setFrame(f, display: true) }
    }

    /// The window: closed, wide enough for the widest wings and never changing (the shape animates inside it); it ignores the
    /// mouse then, so it never blocks the menu bar below it. Open, the open island plus room for the spring's overshoot.
    /// Its top is `overscan` above the screen's edge, like the canvas's (see IslandView: the canvas hangs from the window's top).
    static func windowFrame(_ g: NotchGeometry, open: Bool) -> NSRect {
        let full = open ? CGSize(width: Island.openSize.width + 2 * Island.slack, height: Island.openSize.height + Island.slack)
                        : CGSize(width: g.notchWidth + 2 * IslandModel.maxWing + 20, height: g.height)
        return NSRect(x: g.centerX - full.width / 2, y: g.frame.maxY - full.height, width: full.width, height: full.height + Island.overscan)
    }

    /// The open island itself (the window has some empty room around it).
    private func openRect(_ g: NotchGeometry) -> NSRect {
        NSRect(x: g.centerX - Island.openSize.width / 2, y: g.frame.maxY - Island.openSize.height, width: Island.openSize.width, height: Island.openSize.height + Island.overscan)
    }

    func setOpen(_ open: Bool) {
        openTimer?.invalidate(); closeTimer?.invalidate()
        if !open { DialogCenter.shared.surfaceClosed(.island); endKeyboard() }   // a dialog in the island goes with it: cancelled
        guard model.open != open else { return }
        if open {
            Haptic.tap(.alignment)
            model.open = true
            relayout()
        } else {
            model.open = false
            panel?.ignoresMouseEvents = true
            closingUntil = Date().addingTimeInterval(0.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in     // after the morph (and not under a later one)
                guard let self, !self.model.open, Date() >= self.closingUntil.addingTimeInterval(-0.02) else { return }
                self.relayout()
            }
        }
    }

    private var hovering = false
    private var suspended = false
    private var closingUntil = Date.distantPast
    private var pointerMonitors: [Any] = []

    /// Watches the pointer itself (in every app, and over the island), so it opens as soon as you touch the notch.
    private func startPointerMonitors() {
        guard pointerMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in self?.pointerMoved(e) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { pointerMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in handler(e); return e }) { pointerMonitors.append(l) }
    }

    /// The settings panel hangs from the same notch: while it is open the island is out of the way (not opening behind it).
    /// The island's own volume/brightness bars only run while *Replace system HUD* is on.
    func syncHUD(_ on: Bool) { if enabled && on { model.hud.start() } else { model.hud.stop() } }

    /// Back from the settings panel: the island opens again where it was, as if the pointer had just touched it.
    func reopen() {
        guard enabled else { return }
        hovering = true
        setOpen(true)
    }

    func setSuspended(_ s: Bool) {
        suspended = s
        if s {
            setOpen(false); hovering = false
            panel?.orderOut(nil)
        } else if enabled {
            // Not over a full-screen app (it would only vanish again at the next check) nor under a hidden menu bar.
            covered = NotchGeometry.current().map(Self.fullScreenCovers) ?? false
            if !covered && !model.geometry.menuBarHidden { panel?.orderFrontRegardless() }
        }
    }

    private func pointerMoved(_ e: NSEvent) {
        guard enabled, !suspended, let panel else { return }
        let p = NSEvent.mouseLocation, g = model.geometry
        if !panel.isVisible {
            // A hidden menu bar comes down when the pointer touches the top edge: the pill comes with it.
            guard g.menuBarHidden, !covered, p.y >= g.frame.maxY - 1, abs(p.x - g.centerX) <= g.notchWidth / 2 + 40 else { return }
            relayout()
            panel.orderFrontRegardless()
        }
        // Open: the open island. Closed: just what is drawn (the notch and its wings), and the very top edge of the screen.
        let f: NSRect = model.open ? openRect(g)
            : NSRect(x: g.centerX - g.notchWidth / 2 - model.leftW, y: g.frame.maxY - g.height - 2, width: g.notchWidth + model.leftW + model.rightW, height: g.height + 14)
        let margin: CGFloat = model.open ? 8 : 3
        let inside = p.x >= f.minX - margin && p.x <= f.maxX + margin && p.y >= f.minY - (model.open ? margin : 0) && p.y <= f.maxY + 2
        if inside != hovering {
            hovering = inside
            // Dragging files over the notch: open straight on the shelf.
            if inside, e.type == .leftMouseDragged, NSPasteboard(name: .drag).types?.contains(.fileURL) == true { model.tab = "shelf" }
            hover(inside)
        }
    }

    private func hover(_ inside: Bool) {
        openTimer?.invalidate(); closeTimer?.invalidate()
        if !inside && DialogCenter.shared.isShowing(on: .island) { return }     // a question stays until it's answered or clicked away
        if !inside && keyboardOpen { return }                                   // opened from the keyboard: kept until Esc or a click elsewhere
        setOpen(inside)                                    // no delay either way: as fast out as in
    }

    // MARK: a dialog in the island

    private var dialogMonitors: [Any] = []

    /// The island holds a dialog only while it is on and open (not behind the settings panel).
    var canHoldDialog: Bool { enabled && !suspended && model.open && (panel?.isVisible ?? false) }

    /// A dialog came or went: while one is in the island it takes the keyboard (Return, Esc, its text field) and a click in
    /// another app cancels it; afterwards the island goes back to following the pointer.
    func dialogChanged() {
        let on = DialogCenter.shared.isShowing(on: .island)
        guard on != !dialogMonitors.isEmpty else { return }
        if on {
            panel?.keyable = true
            panel?.makeKey()
            if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in DialogCenter.shared.handleKey(e) ? nil : e }) { dialogMonitors.append(m) }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                DialogCenter.shared.surfaceClosed(.island)
                if !(self?.hovering ?? true) { self?.setOpen(false) }
            }) { dialogMonitors.append(m) }
        } else {
            dialogMonitors.forEach(NSEvent.removeMonitor)
            dialogMonitors.removeAll()
            if keyboardOpen { panel?.makeKey(); return }                 // opened from the keyboard: it keeps the keyboard
            model.setKeyable(false)                                      // the search field takes it again on its own click
            if !hovering { setOpen(false) }                              // the pointer left while the question was up
        }
    }

    /// Once a second: hide during full-screen video and games, follow the screen, keep the closed width in step.
    /// The failsafe too: whatever happened, an island that should be on screen is put back (closed, in place, in front); if it
    /// can't be (no screen, or the window server won't show it), `onShowing(false)` brings the menu-bar icon back.
    private func watch() {
        guard enabled, let panel else { return }
        ticks += 1
        if suspended && !settingsOpen() { setSuspended(false) }         // never left hidden behind a settings panel that is gone
        if ticks % 4 == 0 {
            let g = NotchGeometry.current()
            covered = g.map(Self.fullScreenCovers) ?? false
            // A pill under a hidden menu bar stays away until the pointer reaches the top edge (pointerMoved brings it).
            let tucked = (g?.menuBarHidden ?? false) && !model.open && !hovering
            if covered || g == nil || tucked {
                if panel.isVisible { panel.orderOut(nil) }
                missed = 0
            } else if !suspended {
                if !panel.isVisible || panel.alphaValue < 1 || !Self.onScreen(panel.windowNumber) {
                    missed += 1
                    if missed > 1 {                                       // a moment to settle first (just ordered in, a morph)
                        log.notice("island was not on screen: shown again")
                        if !model.open { closingUntil = .distantPast }
                        panel.alphaValue = 1
                        relayout()
                        panel.orderFrontRegardless()
                    }
                } else { missed = 0 }
            }
            setShowing(g != nil && missed < 6)                            // ~7 s of failed repairs: the icon comes back
        }
        if !model.open && Date() >= closingUntil { relayout() }        // never shrink the window under a closing morph
    }
    /// The full check of `watch()` right now.
    private func checkNow() {
        ticks = (ticks / 4) * 4 + 3
        watch()
    }
    private var missed = 0
    private var covered = false
    private(set) var showing = true
    /// Something drawn in the island now would be seen: it is on, on screen, not under a full-screen app or the settings panel.
    var canShowHUD: Bool { enabled && showing && !suspended && !covered && (panel?.isVisible ?? false) }
    var onShowing: (Bool) -> Void = { _ in }
    var settingsOpen: () -> Bool = { false }
    private func setShowing(_ s: Bool) {
        guard s != showing else { return }
        showing = s
        onShowing(s)
    }

    /// Is the window really on screen, as the window server says (not just ordered in, as AppKit says)?
    private static func onScreen(_ number: Int) -> Bool {
        guard number > 0, let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]], let w = info.first else { return false }
        return (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    /// A full-screen app (video, a game, any app in its own full-screen Space) on the island's screen.
    private static func fullScreenCovers(_ g: NotchGeometry) -> Bool {
        let list = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
        let windows: [Window] = list.compactMap { w in
            guard let b = w[kCGWindowBounds as String] as? [String: Any], let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return Window(layer: w[kCGWindowLayer as String] as? Int ?? -1, pid: w[kCGWindowOwnerPID as String] as? pid_t ?? 0, bounds: r)
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? g.frame.height
        return covers(screen: globalRect(g.frame, primaryHeight: primaryHeight), topInset: g.hasNotch ? g.height : 0,
                      windows: windows, ownPID: getpid())
    }

    struct Window { var layer: Int; var pid: pid_t; var bounds: CGRect }

    /// Window bounds are in the window server's global space (top-left origin on the main display, y down); an NSScreen frame is
    /// AppKit's (bottom-left origin, y up).
    static func globalRect(_ appKit: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: appKit.minX, y: primaryHeight - appKit.maxY, width: appKit.width, height: appKit.height)
    }

    /// Covered when one normal-level window of another app spans the whole screen, menu-bar strip included (a zoomed window stops
    /// below the menu bar); on a notched screen a full-screen app may keep out of the strip beside the camera (`topInset`).
    /// Position counts, not just size: a big window on another monitor, however large, doesn't cover this one.
    static func covers(screen: CGRect, topInset: CGFloat = 0, windows: [Window], ownPID: pid_t) -> Bool {
        var need = screen
        need.origin.y += topInset; need.size.height -= topInset                // global space: y grows downward
        return windows.contains { $0.layer == 0 && $0.pid != ownPID && $0.bounds.insetBy(dx: -1, dy: -1).contains(need) }
    }

    /// The island's window (VoiceOver is told when a dialog appears in it).
    var window: NSWindow? { panel }

    // MARK: the keyboard (⌃⌥⌘I, or VoiceOver's press on the closed island)

    private(set) var keyboardOpen = false
    private var keyboardMonitors: [Any] = []

    /// Opens the island with the keyboard in it, or closes it. Opened this way it stays open when the pointer leaves (the pointer's
    /// own hover still opens and closes it at once) until Esc, the shortcut again or a click elsewhere. ←/→ change tabs, Tab moves
    /// between controls (with Full Keyboard Access), and on the Clipboard page ↑/↓ and Return pick an item.
    func toggleKeyboard() {
        guard enabled, let panel else { return }
        if keyboardOpen { setOpen(false); return }
        if suspended { setSuspended(false) }
        keyboardOpen = true
        model.keyboard = true
        setOpen(true)
        panel.keyable = true
        panel.makeKey()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, self.keyboardOpen, !DialogCenter.shared.isShowing(on: .island) else { return }
            self.setOpen(false)
        }) { keyboardMonitors.append(m) }
        A11y.announce(String(format: L("Island open, %@. Left and right arrows change tabs, Escape closes."), model.tabTitle(model.tab)))
        DispatchQueue.main.async { A11y.layoutChanged(panel) }
    }

    /// Leaves keyboard mode (the island is closing): the keyboard goes back to the app in front.
    private func endKeyboard() {
        guard keyboardOpen else { return }
        keyboardOpen = false
        model.keyboard = false
        keyboardMonitors.forEach(NSEvent.removeMonitor)
        keyboardMonitors.removeAll()
        model.setKeyable(false)
    }

    /// One local key monitor for the island's own window: Esc closes, ←/→ change tabs, the Clipboard page's ↑/↓/Return.
    /// A dialog in the island has its own (dialogChanged); a text field being typed in keeps its keys.
    private func startKeyboard() {
        guard keyboardMonitors.isEmpty, localKeys == nil else { return }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let panel = self.panel, e.window === panel, !DialogCenter.shared.isShowing(on: .island) else { return e }
            return IslandKeys.handle(e.keyCode, flags: e.modifierFlags, editing: panel.firstResponder is NSTextView, model: self.model,
                                     close: { self.setOpen(false) }) ? nil : e
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, self.keyboardOpen, (n.object as? NSWindow) === self.panel, !DialogCenter.shared.isShowing(on: .island) else { return }
            self.setOpen(false)                                   // another app took the keyboard (⌘Tab): the island lets go too
        }
    }
    private var localKeys: Any?
}

/// The island's keys (pure enough to test: the model and a close function are handed in). True when the key was used.
enum IslandKeys {
    static func handle(_ code: UInt16, flags: NSEvent.ModifierFlags, editing: Bool, model: IslandModel, close: () -> Void) -> Bool {
        let plain = flags.intersection([.command, .option, .control]).isEmpty
        guard plain else { return false }
        if model.tab == "clipboard", model.open {
            switch code {
            case 125: model.clipboard.step(1); return true                         // ↓
            case 126: model.clipboard.step(-1); return true                        // ↑
            case 36, 76:                                                          // Return: copy the highlighted one
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.hasMarkedText() { return false }
                return model.copyHighlighted()
            default: break
            }
        }
        switch code {
        case 53:                                                                  // Esc
            if editing && !model.clipboard.query.isEmpty { return false }         // the search field clears itself first
            guard model.open else { return false }
            close()
            return true
        case 123 where !editing: model.stepTab(-1); return true                   // ←
        case 124 where !editing: model.stepTab(1); return true                    // →
        default: return false
        }
    }
}
