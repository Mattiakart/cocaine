// The island's windows (IslandPanel, one per screen) and their controller (IslandController): which screens get an island,
// which one is open, the HUD's screen, full screen per screen, the failsafe, the keyboard mode. The pure parts (the choice of
// screens is NotchGeometry.all; the open/hover state machine and the HUD's screen are IslandRouting) are tested with fake
// screens in Sources/IslandTests.swift.

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

    /// One screen's island: its window and what the watch found about it.
    private final class Spot {
        let id: CGDirectDisplayID
        var g: NotchGeometry
        let panel: IslandPanel
        let host: NSHostingView<IslandView>
        var covered = false                   // a full-screen app on this screen
        var missed = 0                        // checks in a row it should have been on screen and wasn't
        var closingUntil = Date.distantPast   // its closing morph runs until then: the window isn't shrunk under it
        var settle = MotionGeneration()       // the shrink after a close: only the latest close's, and none after a reopen
        init(id: CGDirectDisplayID, g: NotchGeometry, panel: IslandPanel, host: NSHostingView<IslandView>) {
            self.id = id; self.g = g; self.panel = panel; self.host = host
        }
    }

    private var spots: [CGDirectDisplayID: Spot] = [:]
    private var order: [CGDirectDisplayID] = []            // the main island first
    private var state = IslandRouting.OpenState()
    private var watchTimer: Timer?
    private var panelModel: PanelModel?
    private var enabled = false
    private var ticks = 0
    /// *Show on all screens* (the Island tab): off = only the main island, as in 2.5.0.
    private(set) var allScreens = true

    private var openSpot: Spot? { state.open.flatMap { spots[$0] } }
    private var mainSpot: Spot? { order.first.flatMap { spots[$0] } }
    /// The island the user is working with: the open one, else the focused screen's, else the main one.
    private var activeSpot: Spot? { openSpot ?? NotchGeometry.focus.flatMap { spots[$0] } ?? mainSpot }

    func start(panelModel: PanelModel, enabled: Bool, allScreens: Bool = true, showSettings: @escaping () -> Void) {
        self.panelModel = panelModel
        self.allScreens = allScreens
        model.pm = panelModel
        model.showSettings = showSettings
        model.hover = { [weak self] inside in self?.hoverActive(inside) }
        model.toggleOpen = { [weak self] in self?.setOpen(!(self?.model.open ?? false)) }
        model.relayoutNow = { [weak self] in self?.relayout() }
        model.toggleKeyboard = { [weak self] in self?.toggleKeyboard() }
        model.hudRoute = { [weak self] display in self?.hudTarget(display: display) ?? 0 }
        model.hudYields = { [weak self] id in
            guard let self, self.model.open else { return false }
            return self.model.openScreen == id || self.spots.count <= 1
        }
        startKeyboard()
        model.setKeyable = { [weak self] on in
            guard let p = self?.activeSpot?.panel else { return }
            p.keyable = on
            if !on, p.isKeyWindow { p.orderOut(nil); p.orderFrontRegardless() }     // gives the keyboard back to the app in front
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // A display plugged, unplugged, rearranged, rescaled or mirrored, the lid (clamshell): every island re-anchored at once,
            // a HUD in flight moved to a screen that is still there.
            self?.relayout(); self?.checkNow(); self?.model.refreshTabs()
        }
        // Into or out of a full-screen Space, displays awake again: hidden or shown at once, not at the next check.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.relayout(); self?.checkNow() }    // after the Space's windows are in
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
        model.hud.onChange = { [weak model] icon, text, level, display in
            DispatchQueue.main.async { model?.flashNotice(icon, text, level: level, display: display) }
        }
        setEnabled(enabled)
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        guard on else {
            DialogCenter.shared.surfaceClosed(.island)
            for s in spots.values { s.panel.orderOut(nil) }
            watchTimer?.invalidate(); watchTimer = nil
            model.files.stop(); model.clipboard.stop(); model.music.stop(); model.hud.stop()
            return
        }
        model.files.start(); model.clipboard.start(); model.music.start()
        syncHUD(panelModel?.replaceHUD ?? false)
        for s in spots.values { s.missed = 0 }
        relayout()
        for s in spots.values where !s.g.menuBarHidden && suspended != s.id { s.panel.orderFrontRegardless() }
        watchTimer?.invalidate()
        // One watch for every island (not one timer per screen): full screen, the failsafe, the closed windows' size.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.watch() }
    }

    /// *Show on all screens* changed.
    func setAllScreens(_ on: Bool) {
        guard on != allScreens else { return }
        allScreens = on
        relayout()
        checkNow()
    }

    // MARK: the screens

    /// The islands for the screens there are now: new screens get one, gone screens lose theirs (an island open there closes,
    /// a HUD there moves), changed screens are re-anchored. Then every window is sized and placed.
    func relayout() {
        guard enabled, let pm = panelModel else { return }
        let list: [NotchGeometry] = NotchGeometry.override.map { [$0] }
            ?? NotchGeometry.all(NotchGeometry.screens(), barThickness: NSStatusBar.system.thickness, allScreens: allScreens)
        let ids = list.map(\.display)
        let gone = Set(spots.keys).subtracting(ids)
        if !gone.isEmpty {
            apply(state.removed(gone))
            for id in gone {
                spots[id]?.panel.orderOut(nil)
                spots[id] = nil
            }
            if let s = suspended, gone.contains(s) { suspended = nil }
        }
        for g in list {
            if let s = spots[g.display] {
                if s.g != g {
                    s.g = g
                    s.host.rootView = view(pm, g)
                }
            } else {
                spots[g.display] = makeSpot(pm, g)
            }
        }
        order = ids
        if let f = NotchGeometry.focus, spots[f] == nil || spots.count < 2 { NotchGeometry.focus = nil }
        // A HUD on a screen that went away goes to where the user is now (or the main island); with nowhere to go, it goes.
        if model.hudShown, model.hudScreen != 0, spots[model.hudScreen] == nil {
            let to = hudTarget(display: nil)
            if spots[to] != nil { model.hudScreen = to } else { model.yieldHUD() }
        }
        if let g = activeSpot?.g, g != model.geometry { model.geometry = g }
        for s in spots.values { place(s) }
    }

    private func view(_ pm: PanelModel, _ g: NotchGeometry) -> IslandView {
        IslandView(model: model, m: pm, focus: model.focus, batteries: model.batteries, mic: model.mic, usage: model.usage,
                   place: IslandPlace(display: g.display, geometry: g))
    }

    private func makeSpot(_ pm: PanelModel, _ g: NotchGeometry) -> Spot {
        let p = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false; p.isMovable = false
        p.animationBehavior = .none                  // no system fade/scale when it is ordered out and in (the island morphs by itself)
        p.appearance = NSAppearance(named: .darkAqua)
        p.ignoresMouseEvents = true
        let h = NSHostingView(rootView: view(pm, g))
        h.sizingOptions = []
        p.contentView = h
        let s = Spot(id: g.display, g: g, panel: p, host: h)
        place(s)
        if !g.menuBarHidden { p.orderFrontRegardless() }      // (a full-screen app there: the next check hides it)
        return s
    }

    /// Size and place one window: just the closed island (and the HUD's room below it), or the open one.
    /// The SwiftUI canvas inside is fixed and centred on the notch, so these instant resizes never move what is drawn.
    private func place(_ s: Spot) {
        let open = state.open == s.id && model.open
        s.panel.ignoresMouseEvents = !open
        let f = Self.windowFrame(s.g, open: open)
        if s.panel.frame != f { s.panel.setFrame(f, display: true) }
    }

    /// The window: closed, wide enough for the widest wings and tall enough for the HUD below the notch, never changing (the
    /// shape animates inside it); it ignores the mouse then, so it never blocks the menu bar or the windows below it. Open, the
    /// open island plus room for the spring's overshoot. Its top is `overscan` above the screen's edge, like the canvas's (see
    /// IslandView: the canvas hangs from the window's top).
    static func windowFrame(_ g: NotchGeometry, open: Bool) -> NSRect {
        let full = open ? CGSize(width: Island.openSize.width + 2 * Island.slack, height: Island.openSize.height + Island.slack)
                        : CGSize(width: g.notchWidth + 2 * IslandModel.maxWing + 20, height: g.height + Island.hudRoom)
        return NSRect(x: g.centerX - full.width / 2, y: g.frame.maxY - full.height, width: full.width, height: full.height + Island.overscan)
    }

    /// The open island itself (the window has some empty room around it).
    static func openRect(_ g: NotchGeometry) -> NSRect {
        NSRect(x: g.centerX - Island.openSize.width / 2, y: g.frame.maxY - Island.openSize.height, width: Island.openSize.width, height: Island.openSize.height + Island.overscan)
    }

    /// Where the HUD goes (see IslandRouting.hudTarget).
    func hudTarget(display: CGDirectDisplayID?) -> CGDirectDisplayID {
        IslandRouting.hudTarget(display: display, pointer: NSEvent.mouseLocation, islands: order.compactMap { spots[$0]?.g },
                                mirrorOf: { CGDisplayMirrorsDisplay($0) })
    }

    /// The settings panel (or a dialog over it) is asked for from this point: with several islands, it hangs from the notch of
    /// that screen's island, unless a full-screen app hides that one (then the island the user last worked with, or the main one).
    func focus(at p: CGPoint) {
        guard spots.count > 1, let s = spot(at: p), !s.covered else { return }
        NotchGeometry.focus = s.id
    }

    /// The screen under a point that has an island.
    private func spot(at p: CGPoint) -> Spot? {
        IslandRouting.screen(at: p, order.compactMap { spots[$0]?.g }).flatMap { spots[$0] }
    }

    // MARK: open and close

    /// Opens the island the user is working with (the pointer's screen first), or closes the open one.
    func setOpen(_ open: Bool, haptic: Bool = false) {
        if open {
            guard let s = spot(at: NSEvent.mouseLocation) ?? activeSpot else { return }
            apply(state.openNow(s.id), haptic: haptic)
        } else {
            apply(state.closeNow())
        }
        if !open { DialogCenter.shared.surfaceClosed(.island); endKeyboard() }   // a dialog in the island goes with it: cancelled
    }

    private func apply(_ actions: [IslandRouting.Action], haptic: Bool = true) {
        for a in actions {
            switch a {
            case .open(let id): show(id, haptic: haptic)
            case .close(let id): hide(id)
            }
        }
    }

    private func show(_ id: CGDirectDisplayID, haptic: Bool) {
        guard enabled, let s = spots[id] else { state.forget(id); return }
        if haptic { Haptic.tap(.alignment) }                  // the island opening under the pointer (no click with it)
        if model.hudScreen == id || spots.count == 1 { model.yieldHUD() }    // the HUD gives way to the open island
        NotchGeometry.focus = spots.count > 1 ? id : nil       // the settings panel and its dialogs hang from this notch now
        if model.geometry != s.g { model.geometry = s.g }
        if model.openScreen != id { model.openScreen = id }
        s.settle.cancel()                                     // reopened mid-close: the pending shrink is void (the morph just turns back)
        s.closingUntil = .distantPast
        model.open = true
        place(s)
    }

    private func hide(_ id: CGDirectDisplayID) {
        DialogCenter.shared.surfaceClosed(.island)
        endKeyboard()
        guard model.open, model.openScreen == id || spots[model.openScreen] == nil else { return }
        model.open = false
        guard let s = spots[id] else { return }
        s.panel.ignoresMouseEvents = true
        s.closingUntil = Date().addingTimeInterval(Motion.islandSettle)
        let gen = s.settle.begin()
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.islandSettle) { [weak self, weak s] in   // after the morph
            guard let self, let s, s.settle.isCurrent(gen), self.state.open != s.id else { return }     // not under a later one
            self.place(s)
        }
    }

    private var suspended: CGDirectDisplayID?
    private var pointerMonitors: [Any] = []

    /// Watches the pointer itself (in every app, and over the islands), so one opens as soon as you touch its notch.
    private func startPointerMonitors() {
        guard pointerMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in self?.pointerMoved(e) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { pointerMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in handler(e); return e }) { pointerMonitors.append(l) }
    }

    /// The settings panel hangs from the same notch: while it is open the island is out of the way (not opening behind it).
    /// The island's own volume/brightness bars only run while *Replace system HUD* is on.
    func syncHUD(_ on: Bool) { if enabled && on { model.hud.start() } else { model.hud.stop() } }

    /// Back from the settings panel: the island opens again where it was, as if the pointer had just touched it (no tap: the
    /// click on the back button already gave one).
    func reopen() {
        guard enabled, let s = activeSpot else { return }
        apply(state.openNow(s.id, hovering: true), haptic: false)
    }

    /// The settings panel is about to hang from the island the user is working with (it is hidden behind it), or went away.
    func setSuspended(_ on: Bool) {
        if on {
            guard let s = activeSpot else { return }
            setOpen(false)
            state.pointerLeft()
            suspended = s.id
            s.panel.orderOut(nil)
        } else {
            guard let id = suspended else { return }
            suspended = nil
            guard enabled, let s = spots[id] else { return }
            // Not over a full-screen app (it would only vanish again at the next check) nor under a hidden menu bar.
            s.covered = Self.fullScreenCovers(s.g, windows: Self.windowList())
            if !s.covered && !s.g.menuBarHidden { s.panel.orderFrontRegardless() }
        }
    }

    /// Any island hidden behind the settings panel?
    var isSuspended: Bool { suspended != nil }

    private func pointerMoved(_ e: NSEvent) {
        guard enabled else { return }
        let p = NSEvent.mouseLocation
        // A hidden menu bar comes down when the pointer touches the top edge: that screen's pill comes with it.
        for s in spots.values where !s.panel.isVisible && s.g.menuBarHidden && !s.covered && suspended != s.id {
            if p.y >= s.g.frame.maxY - 1 && p.y <= s.g.frame.maxY && abs(p.x - s.g.centerX) <= s.g.notchWidth / 2 + 40 {
                place(s)
                s.panel.orderFrontRegardless()
            }
        }
        let over = order.compactMap { spots[$0] }.first { s in
            s.panel.isVisible && suspended != s.id
                && IslandRouting.hoverZone(s.g, open: state.open == s.id && model.open, leftW: model.leftW, rightW: model.rightW).contains(p)
        }?.id
        guard over != state.hovering else { return }
        // Dragging files over a notch: open straight on the shelf.
        if over != nil, e.type == .leftMouseDragged, NSPasteboard(name: .drag).types?.contains(.fileURL) == true { model.tab = "shelf" }
        state.dialog = DialogCenter.shared.isShowing(on: .island)
        state.keyboard = keyboardOpen
        apply(state.pointer(over: over))                   // no delay either way: as fast out as in
    }

    /// The model's hover (the drop target): the island the user is working with.
    private func hoverActive(_ inside: Bool) {
        guard let s = activeSpot else { return }
        state.dialog = DialogCenter.shared.isShowing(on: .island)
        state.keyboard = keyboardOpen
        apply(state.pointer(over: inside ? s.id : nil))
    }

    // MARK: a dialog in the island

    private var dialogMonitors: [Any] = []

    /// The island holds a dialog only while it is on and open (not behind the settings panel).
    var canHoldDialog: Bool { enabled && model.open && (openSpot.map { $0.panel.isVisible && suspended != $0.id } ?? false) }

    /// A dialog came or went: while one is in the island it takes the keyboard (Return, Esc, its text field) and a click in
    /// another app cancels it; afterwards the island goes back to following the pointer.
    func dialogChanged() {
        let on = DialogCenter.shared.isShowing(on: .island)
        state.dialog = on
        guard on != !dialogMonitors.isEmpty else { return }
        if on {
            openSpot?.panel.keyable = true
            openSpot?.panel.makeKey()
            if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in DialogCenter.shared.handleKey(e) ? nil : e }) { dialogMonitors.append(m) }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                DialogCenter.shared.surfaceClosed(.island)
                if let self, self.state.hovering == nil || self.state.hovering != self.state.open { self.setOpen(false) }
            }) { dialogMonitors.append(m) }
        } else {
            dialogMonitors.forEach(NSEvent.removeMonitor)
            dialogMonitors.removeAll()
            if keyboardOpen { openSpot?.panel.makeKey(); return }        // opened from the keyboard: it keeps the keyboard
            model.setKeyable(false)                                      // the search field takes it again on its own click
            if state.hovering == nil || state.hovering != state.open { setOpen(false) }    // the pointer left while the question was up
        }
    }

    // MARK: the watch

    /// Three times a second (the full check every 1.2 s), for every island at once: hide during full-screen video and games on
    /// that screen, follow the screens, keep the closed windows in step. The failsafe too: whatever happened, an island that
    /// should be on screen is put back (closed, in place, in front); if none can be (no screen, or the window server won't show
    /// them), `onShowing(false)` brings the menu-bar icon back.
    private func watch() {
        guard enabled else { return }
        ticks += 1
        if suspended != nil && !settingsOpen() { setSuspended(false) }    // never left hidden behind a settings panel that is gone
        if ticks % 4 == 0 {
            relayout()
            let windows = Self.windowList()                                 // read once for every screen
            for s in spots.values {
                s.covered = Self.fullScreenCovers(s.g, windows: windows)
                // A pill under a hidden menu bar stays away until the pointer reaches the top edge (pointerMoved brings it).
                let tucked = s.g.menuBarHidden && state.open != s.id && state.hovering != s.id
                if s.covered || tucked {
                    if s.covered && state.open == s.id { apply(state.closeNow()) }
                    if s.panel.isVisible { s.panel.orderOut(nil) }
                    s.missed = 0
                } else if suspended != s.id {
                    if !s.panel.isVisible || s.panel.alphaValue < 1 || !Self.onScreen(s.panel.windowNumber) {
                        s.missed += 1
                        if s.missed > 1 {                                 // a moment to settle first (just ordered in, a morph)
                            log.notice("island was not on screen: shown again")
                            if state.open != s.id { s.closingUntil = .distantPast }
                            s.panel.alphaValue = 1
                            place(s)
                            s.panel.orderFrontRegardless()
                        }
                    } else { s.missed = 0 }
                }
            }
            setShowing(spots.values.contains { $0.missed < 6 })            // ~7 s of failed repairs everywhere: the icon comes back
        }
        for s in spots.values where state.open != s.id && Date() >= s.closingUntil { place(s) }   // never shrink under a closing morph
    }
    /// The full check of `watch()` right now.
    private func checkNow() {
        ticks = (ticks / 4) * 4 + 3
        watch()
    }
    private(set) var showing = true
    /// The HUD can be seen on that screen's island now: on, on screen, not under a full-screen app or the settings panel.
    func canShowHUD(on id: CGDirectDisplayID) -> Bool {
        guard enabled, showing, let s = spots[id] else { return false }
        return suspended != s.id && !s.covered && s.panel.isVisible
    }
    /// …on the screen the user is at (where the volume's HUD goes).
    var canShowHUD: Bool { canShowHUD(on: hudTarget(display: nil)) }
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

    /// Every window on screen now, in the window server's terms.
    private static func windowList() -> [Window] {
        let list = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { w in
            guard let b = w[kCGWindowBounds as String] as? [String: Any], let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return Window(layer: w[kCGWindowLayer as String] as? Int ?? -1, pid: w[kCGWindowOwnerPID as String] as? pid_t ?? 0, bounds: r)
        }
    }

    /// A full-screen app (video, a game, any app in its own full-screen Space) on this island's screen: only this one hides.
    private static func fullScreenCovers(_ g: NotchGeometry, windows: [Window]) -> Bool {
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

    /// The open island's window, else the one the user is working with (VoiceOver is told when a dialog appears in it).
    var window: NSWindow? { activeSpot?.panel }

    // MARK: the keyboard (⌃⌥⌘I, or VoiceOver's press on the closed island)

    private(set) var keyboardOpen = false
    private var keyboardMonitors: [Any] = []

    /// Opens the island of the screen with the pointer with the keyboard in it, or closes it. Opened this way it stays open when
    /// the pointer leaves (the pointer's own hover still opens and closes islands at once) until Esc, the shortcut again or a
    /// click elsewhere. ←/→ change tabs, Tab moves between controls (with Full Keyboard Access), and on the Clipboard page ↑/↓
    /// and Return pick an item.
    func toggleKeyboard() {
        guard enabled else { return }
        if keyboardOpen { setOpen(false); return }
        guard let s = spot(at: NSEvent.mouseLocation) ?? activeSpot else { return }
        if suspended == s.id { setSuspended(false) }
        if model.open { setOpen(false) }                 // another screen's island (opened by the pointer) closes first
        keyboardOpen = true
        model.keyboard = true
        state.keyboard = true
        apply(state.openNow(s.id), haptic: false)
        s.panel.keyable = true
        s.panel.makeKey()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, self.keyboardOpen, !DialogCenter.shared.isShowing(on: .island) else { return }
            self.setOpen(false)
        }) { keyboardMonitors.append(m) }
        A11y.announce(String(format: L("Island open, %@. Left and right arrows change tabs, Escape closes."), model.tabTitle(model.tab)))
        let panel = s.panel
        DispatchQueue.main.async { A11y.layoutChanged(panel) }
    }

    /// Leaves keyboard mode (the island is closing): the keyboard goes back to the app in front.
    private func endKeyboard() {
        guard keyboardOpen else { return }
        keyboardOpen = false
        model.keyboard = false
        state.keyboard = false
        keyboardMonitors.forEach(NSEvent.removeMonitor)
        keyboardMonitors.removeAll()
        model.setKeyable(false)
    }

    /// One local key monitor for the islands' windows: Esc closes, ←/→ change tabs, the Clipboard page's ↑/↓/Return.
    /// A dialog in the island has its own (dialogChanged); a text field being typed in keeps its keys.
    private func startKeyboard() {
        guard keyboardMonitors.isEmpty, localKeys == nil else { return }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let panel = self.openSpot?.panel, e.window === panel, !DialogCenter.shared.isShowing(on: .island) else { return e }
            return IslandKeys.handle(e.keyCode, flags: e.modifierFlags, editing: panel.firstResponder is NSTextView, model: self.model,
                                     close: { self.setOpen(false) }) ? nil : e
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, self.keyboardOpen, (n.object as? NSWindow) === self.openSpot?.panel, !DialogCenter.shared.isShowing(on: .island) else { return }
            self.setOpen(false)                                   // another app took the keyboard (⌘Tab): the island lets go too
        }
    }
    private var localKeys: Any?
}

extension Settings {
    /// *Show on all screens* (the Island tab): an island on every connected screen; off, only the main one (2.5.0).
    var islandAllScreens: Bool { get { flag("islandAllScreens", true) } nonmutating set { d.set(newValue, forKey: "islandAllScreens") } }
}

/// The pure parts of having one island per screen (tested with fake screens in Sources/IslandTests.swift).
enum IslandRouting {
    enum Action: Equatable { case open(CGDirectDisplayID), close(CGDirectDisplayID) }

    /// Which island is open and which one the pointer is over. Only one island is open at a time (there is one pointer); hovering
    /// the notch of screen B opens B's island and closes A's. An island with a dialog in it stays (and keeps the others closed)
    /// until the question is answered; one opened from the keyboard stays when the pointer leaves for no island.
    struct OpenState: Equatable {
        private(set) var open: CGDirectDisplayID?
        private(set) var hovering: CGDirectDisplayID?
        var keyboard = false
        var dialog = false

        mutating func pointer(over id: CGDirectDisplayID?) -> [Action] {
            guard id != hovering else { return [] }
            hovering = id
            if dialog { return [] }                                      // a question stays until it's answered or clicked away
            if let id {
                if open == id { return [] }
                var out: [Action] = []
                if let o = open { out.append(.close(o)); keyboard = false }
                open = id
                out.append(.open(id))
                return out
            }
            guard let o = open, !keyboard else { return [] }             // opened from the keyboard: kept until Esc or a click
            open = nil
            return [.close(o)]
        }

        /// Opened on purpose (the keyboard, back from the settings, a drop): `hovering` says the pointer is taken to be there.
        mutating func openNow(_ id: CGDirectDisplayID, hovering h: Bool = false) -> [Action] {
            if h { hovering = id }
            guard open != id else { return [] }
            var out: [Action] = []
            if let o = open { out.append(.close(o)) }
            open = id
            out.append(.open(id))
            return out
        }

        mutating func closeNow() -> [Action] {
            keyboard = false
            guard let o = open else { return [] }
            open = nil
            return [.close(o)]
        }

        /// The settings panel came over the island: the pointer counts as gone.
        mutating func pointerLeft() { hovering = nil }

        /// Screens went away: an island open there closes (its window goes), nothing waits for a pointer that can't come back.
        mutating func removed(_ ids: Set<CGDirectDisplayID>) -> [Action] {
            if let h = hovering, ids.contains(h) { hovering = nil }
            guard let o = open, ids.contains(o) else { return [] }
            open = nil; keyboard = false; dialog = false
            return [.close(o)]
        }

        /// An island that couldn't be opened (gone between two events).
        mutating func forget(_ id: CGDirectDisplayID) { if open == id { open = nil }; if hovering == id { hovering = nil } }
    }

    /// The island whose screen holds this point (AppKit coordinates; a screen's frame includes its top edge row).
    static func screen(at p: CGPoint, _ islands: [NotchGeometry]) -> CGDirectDisplayID? {
        islands.first { g in p.x >= g.frame.minX && p.x < g.frame.maxX && p.y >= g.frame.minY && p.y <= g.frame.maxY }?.display
    }

    /// Where the pointer opens an island: closed, just what is drawn (the notch and its wings) and the very top edge of the
    /// screen; open, the open island and a small margin. Never past the screen's top (a screen stacked above has its own).
    static func hoverZone(_ g: NotchGeometry, open: Bool, leftW: CGFloat, rightW: CGFloat) -> CGRect {
        let top = g.frame.maxY
        if open {
            let r = IslandController.openRect(g), m: CGFloat = 8
            return CGRect(x: r.minX - m, y: r.minY - m, width: r.width + 2 * m, height: top - (r.minY - m))
        }
        let m: CGFloat = 3, minY = top - g.height - 2
        return CGRect(x: g.centerX - g.notchWidth / 2 - leftW - m, y: minY, width: g.notchWidth + leftW + rightW + 2 * m, height: top - minY)
    }

    /// The screen whose island shows a HUD. A key that acted on one display (brightness: the backlit display under the pointer,
    /// else the built-in, Screens.keyTarget) shows it there, on the island of that display or of the display it mirrors. Anything
    /// else (volume, a download, a copy, an AI's note) shows where the user is: the island of the screen under the pointer, else
    /// the main island. Every other screen stays quiet: one HUD, never one per screen.
    static func hudTarget(display: CGDirectDisplayID?, pointer: CGPoint?, islands: [NotchGeometry],
                          mirrorOf: (CGDirectDisplayID) -> CGDirectDisplayID) -> CGDirectDisplayID {
        let ids = islands.map(\.display)
        if let d = display {
            if ids.contains(d) { return d }
            let m = mirrorOf(d)
            if m != 0, ids.contains(m) { return m }
        }
        if let p = pointer, let s = screen(at: p, islands) { return s }
        return ids.first ?? 0
    }
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
