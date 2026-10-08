// The island's model (IslandModel).

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

// MARK: Island model and controller

final class IslandModel: ObservableObject {
    @Published var open = false
    /// Which screen's island is open (its display id; 0 with a single island). Only one is open at a time.
    @Published var openScreen: CGDirectDisplayID = 0
    /// The screen shown (a ScreenLayout screen id). Asked for one that isn't shown (a hidden screen, or "shelf" while a file is
    /// dragged in when the shelf was moved into another screen), it shows the screen that holds that module, else the start one.
    @Published var tab = "home" {
        didSet {
            if let t = shownScreen(for: tab), t != tab { tab = t; return }
            pager.note(from: tabs.firstIndex { $0.id == oldValue }, to: tabs.firstIndex { $0.id == tab })    // the pages slide that way
        }
    }
    /// Which way the last screen change went (by the tabs' order): the pages slide from that side (Motion.page).
    let pager = PageDirection()
    @Published var geometry = NotchGeometry.current() ?? NotchGeometry(frame: .zero, notchWidth: 150, height: 24, centerX: 0, hasNotch: false)
    /// A two-finger swipe on the notch being followed, -1…1 (Sources/NotchGestures.swift); 0 at rest.
    @Published var gestureProgress: CGFloat = 0
    /// Opened from the keyboard (⌃⌥⌘I): kept open, with the keys of IslandKeys.
    @Published var keyboard = false
    /// The arrangement of the screens, shared by every island and the settings card.
    let screens: ScreenLayoutStore
    /// The layout as this island last took it (the store publishes before its value changes).
    private(set) var layout: ScreenLayout
    /// Whether an external monitor makes the Monitors screen show (worked out with the tabs).
    private(set) var external = Island.external
    /// The tabs (id, symbol, title), worked out once and again only when the screens, the layout or the language change
    /// (Island.tabs looks at every screen; it used to run a dozen times per redraw).
    @Published private(set) var tabs: [(id: String, icon: String, title: String)]
    /// The render tool only: draw this moment of the open/close morph (0…1) instead of following `open`.
    var renderProgress: CGFloat?
    /// The render tool only (--render-motion page): the screen the drawn page change comes from.
    var renderPageFrom: String?
    weak var pm: PanelModel?
    let focus = FocusTimer()
    let batteries = BatteryWatch()
    let mic = MicWatch()
    let usage = UsageWatch()
    let files = FileShelf()
    let clipboard = ClipboardHistory.shared
    let shelf = ShelfStore()
    /// The shelf's controller: its sheets, operations, keys, watched folders (Sources/ShelfCommands.swift).
    lazy var shelfUI = ShelfCenter(store: shelf)
    /// The shelf keeps the island open (a form being filled in, Quick Look, a folder panel), as a dialog does.
    var shelfHold = false
    var airDrop: ([URL]) -> Void = { _ in }
    var dropTargeted: (Bool) -> Void = { _ in }
    /// Files are being dragged over the island: the shelf shows where they will land.
    @Published var dropHover = false
    let calendar = CalendarWatch()
    /// Reminders (Sources/IslandReminders.swift): EventKit once the island starts (NotchWiring), a fake in tests and renders.
    let reminders = RemindersWatch()
    let music = MusicWatch()
    let mirror = MirrorController()
    let ddc = DDCDisplays()
    let hud = HUDWatch()
    /// The HUD below the notch (Sources/IslandHUD.swift): what it shows (kept while it retracts), whether it is down, and on
    /// which screen's island (the display id the controller routed it to; 0 = the only island, or the render tools').
    @Published private(set) var hudItem: HUDItem?
    @Published private(set) var hudShown = false
    @Published var hudScreen: CGDirectDisplayID = 0
    private var hudTimeline = HUDTimeline()
    /// The screen a HUD goes to (set by the controller): the display a key acted on, else the pointer's screen, else the notch's.
    var hudRoute: (CGDirectDisplayID?) -> CGDirectDisplayID = { _ in 0 }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The island on this display (0: any) is open: the HUD there gives way.
    var hudYields: (CGDirectDisplayID) -> Bool = { _ in false }
    private var forwards: [AnyCancellable] = []
    private var flashWork: DispatchWorkItem?

    init(screens: ScreenLayoutStore = .shared) {
        self.screens = screens
        layout = screens.layout
        let ext = Island.external
        external = ext
        tabs = Island.tabs(external: ext, layout: screens.layout)
        tab = screens.layout.startScreen(current: nil, external: ext) ?? "home"
        // A module's own data redraws the island only while a screen holding it is shown (the closed island draws none of it);
        // what the closed island shows (a focus running, music playing) always does. The microphone is observed by the view itself.
        func page(_ kinds: [String], _ p: ObservableObjectPublisher) -> AnyCancellable {
            p.sink { [weak self] _ in if let self, self.open, self.showsAny(kinds) { self.objectWillChange.send() } }
        }
        forwards = [page(["downloads", "screenshots"], files.objectWillChange), page(["clipboard"], clipboard.objectWillChange),
                    page(["shelf"], shelf.objectWillChange), page(["calendar"], calendar.objectWillChange), page(["music"], music.objectWillChange),
                    page(["mirror"], mirror.objectWillChange), page(["monitors"], ddc.objectWillChange),
                    focus.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                    music.$playing.removeDuplicates().dropFirst().sink { [weak self] _ in self?.objectWillChange.send() },
                    // The layout changed (the settings card, on any display): the tabs follow, a hidden screen gives way.
                    screens.$layout.dropFirst().sink { [weak self] l in self?.refreshTabs(l) },
                    // A chosen start screen: the island opens on it every time (set once it has closed, so closing shows no jump).
                    $open.removeDuplicates().dropFirst().sink { [weak self] isOpen in if !isOpen { self?.scheduleStart() } }]
        MediaWiring.attach(self)                                   // keyboard backlight HUD and auto-off (Sources/MediaSettings.swift)
    }

    /// The modules of the screen shown.
    var shownModules: [String] { layout.config(tab)?.modules.map(\.kind) ?? [] }
    func showsAny(_ kinds: [String]) -> Bool { shownModules.contains { kinds.contains($0) } }
    /// Is this module on the screen shown? (Return copies on the clipboard module wherever it is.)
    func shows(_ kind: String) -> Bool { showsAny([kind]) }

    /// The screen to show when `id` is asked for: itself when shown, else the one holding that module, else the start screen.
    private func shownScreen(for id: String) -> String? {
        let l = layout
        return l.screenShowing(id, external: external) ?? l.startScreen(current: nil, external: external)
    }

    private var startWork: DispatchWorkItem?
    private func scheduleStart() {
        startWork?.cancel()
        guard layout.start != ScreenLayout.lastUsed else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.open, let s = self.layout.startScreen(current: self.tab, external: self.external) else { return }
            if s != self.tab { self.tab = s }
        }
        startWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.islandSettle, execute: w)          // after the closing morph
    }

    /// The tabs again (a screen came or went, the language or the layout changed). The screen shown, if it is no longer
    /// shown, gives way to the start screen with the screens' transition.
    func refreshTabs(_ newLayout: ScreenLayout? = nil) {
        let l = newLayout ?? screens.layout
        if l != layout { layout = l; objectWillChange.send() }      // a screen's modules changed: the page redraws
        external = Island.external
        let t = Island.tabs(external: external, layout: l)
        if t.map({ $0.id }) != tabs.map({ $0.id }) || t.map({ $0.title }) != tabs.map({ $0.title }) { tabs = t }
        if !t.contains(where: { $0.id == tab }), let next = l.screenShowing(tab, external: external) ?? l.startScreen(current: nil, external: external) {
            Motion.with(.page) { tab = next }
        }
    }

    func tabTitle(_ id: String) -> String { tabs.first { $0.id == id }?.title ?? id }

    /// ← / →: the previous or next tab (no wrapping), said by VoiceOver.
    func stepTab(_ n: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == tab }) else { tab = tabs.first?.id ?? "home"; return }
        let j = min(tabs.count - 1, max(0, i + n))
        guard j != i else { return }
        Haptic.tap(.alignment)
        tab = tabs[j].id
        A11y.announce(tabs[j].title)
    }

    /// Return on the Clipboard page: copies the highlighted item (the first one found when none is), with the same flash as a click.
    @discardableResult
    func copyHighlighted() -> Bool {
        let list = clipboard.visible
        guard let c = list.first(where: { $0.id == clipboard.hovered }) ?? list.first else { return false }
        copyClip(c)
        return true
    }

    func copyClip(_ c: ClipItem) {
        if clipboard.copy(c) {
            Haptic.tap(.generic)
            flashNotice("doc.on.clipboard.fill", L("Copied"))
        } else {
            flashNotice("exclamationmark.triangle.fill", c.kind == .files ? L("The file is no longer there") : L("Can't copy it"))
        }
    }

    /// What the HUD shows now, if it is down (VoiceOver's summary of the closed island, the render tools).
    var flash: (icon: String, text: String, level: Double?)? { hudShown ? hudItem.map { ($0.icon, $0.text, $0.level) } : nil }

    /// A short message or a level in the HUD below the notch: "Downloaded", "Copied", the volume… VoiceOver says the messages
    /// (not volume and brightness levels: they change in steps while a key is held). `display`: the screen it is about (the
    /// display whose brightness changed); nil = wherever the user is (see hudRoute).
    func flashNotice(_ icon: String, _ text: String, level: Double? = nil, display: CGDirectDisplayID? = nil) {
        if level == nil { A11y.announce(text) }
        let target = hudRoute(display)
        if hudYields(target) { return }                  // that island is open: the HUD doesn't come down under it
        if target != hudScreen { hudScreen = target }
        hudTimeline.post(HUDItem(icon: icon, text: text, level: level), now: now())
        publishHUD()
    }

    /// A whole HUD item (the battery's, Sources/NotchPower.swift), shown where the user is.
    func flashItem(_ item: HUDItem, display: CGDirectDisplayID? = nil) {
        A11y.announce(item.text + (item.power.map { ", \($0.percent)%" } ?? ""))
        let target = hudRoute(display)
        if hudYields(target) { return }
        if target != hudScreen { hudScreen = target }
        hudTimeline.post(item, now: now())
        publishHUD()
    }

    /// The island opened (or the HUD's screen went away with nowhere to go): the HUD goes up at once and stays up.
    func yieldHUD() {
        hudTimeline.dismiss()
        publishHUD()
    }

    /// The pure timeline's state onto the view, and a wake-up at its next deadline (one work item, never one per change).
    private func publishHUD() {
        if hudItem != hudTimeline.item { hudItem = hudTimeline.item }
        if hudShown != hudTimeline.shown { hudShown = hudTimeline.shown }
        flashWork?.cancel(); flashWork = nil
        guard let deadline = hudTimeline.nextDeadline else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hudTimeline.tick(now: self.now())
            self.publishHUD()
        }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, deadline - now()), execute: w)
    }
    static let maxWing: CGFloat = 130
    var relayoutNow: () -> Void = {}
    /// Is something worth a mark right of the notch? (The bag on the left is always there.)
    var rightActive: Bool {
        focus.active || mic.active || music.playing || (pm?.on ?? false) || (pm?.stayActive ?? false) || (pm?.presenceActive ?? false)
            || (pm?.board.contains { $0.state == "waiting" || $0.state == "error" || $0.state == "working" } ?? false)
            || !(pm?.approvals.isEmpty ?? true)
    }
    /// The wings no longer widen for a message: messages and bars are in the HUD below the notch (2.5.0 put them right of it).
    var leftW: CGFloat { Island.wing }
    var rightW: CGFloat { rightActive ? Island.wing : 0 }
    var hover: (Bool) -> Void = { _ in }
    var toggleOpen: () -> Void = {}
    /// Opens (or closes) the island with the keyboard in it: ⌃⌥⌘I, or VoiceOver's press on the closed island.
    var toggleKeyboard: () -> Void = {}
    var showSettings: () -> Void = {}
    /// The clipboard page's search field needs the keyboard: the panel may take it while that page is shown.
    var setKeyable: (Bool) -> Void = { _ in }
}
