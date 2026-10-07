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
    @Published var tab = "home"
    @Published var geometry = NotchGeometry.current() ?? NotchGeometry(frame: .zero, notchWidth: 150, height: 24, centerX: 0, hasNotch: false)
    /// Opened from the keyboard (⌃⌥⌘I): kept open, with the keys of IslandKeys.
    @Published var keyboard = false
    /// The tabs (id, symbol, title), worked out once and again only when the screens or the language change (Island.tabs looks at
    /// every screen; it used to run a dozen times per redraw).
    @Published private(set) var tabs: [(id: String, icon: String, title: String)] = Island.tabs(external: Island.external)
    /// The render tool only: draw this moment of the open/close morph (0…1) instead of following `open`.
    var renderProgress: CGFloat?
    weak var pm: PanelModel?
    let focus = FocusTimer()
    let batteries = BatteryWatch()
    let mic = MicWatch()
    let usage = UsageWatch()
    let files = FileShelf()
    let clipboard = ClipboardHistory.shared
    let shelf = ShelfStore()
    var airDrop: ([URL]) -> Void = { _ in }
    var dropTargeted: (Bool) -> Void = { _ in }
    let calendar = CalendarWatch()
    let music = MusicWatch()
    let mirror = MirrorController()
    let ddc = DDCDisplays()
    let hud = HUDWatch()
    @Published var flash: (icon: String, text: String, level: Double?)?
    private var forwards: [AnyCancellable] = []
    private var flashWork: DispatchWorkItem?

    init() {
        // A page's own data redraws the island only while that page is shown (the closed island draws none of it); what the closed
        // island shows (a focus running, music playing) always does. The microphone is observed by the view itself.
        func page(_ id: String, _ p: ObservableObjectPublisher) -> AnyCancellable {
            p.sink { [weak self] _ in if let self, self.open, self.tab == id { self.objectWillChange.send() } }
        }
        forwards = [page("files", files.objectWillChange), page("clipboard", clipboard.objectWillChange), page("shelf", shelf.objectWillChange),
                    page("calendar", calendar.objectWillChange), page("music", music.objectWillChange), page("mirror", mirror.objectWillChange),
                    page("display", ddc.objectWillChange),
                    focus.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                    music.$playing.removeDuplicates().dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }]
    }

    /// The tabs again (a screen came or went, the language changed).
    func refreshTabs() {
        let t = Island.tabs(external: Island.external)
        if t.map({ $0.id }) != tabs.map({ $0.id }) || t.map({ $0.title }) != tabs.map({ $0.title }) { tabs = t }
        if !tabs.contains(where: { $0.id == tab }) { tab = "home" }
    }

    func tabTitle(_ id: String) -> String { tabs.first { $0.id == id }?.title ?? id }

    /// ← / →: the previous or next tab (no wrapping), said by VoiceOver.
    func stepTab(_ n: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == tab }) else { tab = "home"; return }
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

    /// A short message in the closed island: "Downloaded", "Copied"… VoiceOver says it too (not volume and brightness levels:
    /// they change in steps while a key is held).
    func flashNotice(_ icon: String, _ text: String, level: Double? = nil) {
        flash = (icon, text, level)
        if level == nil { A11y.announce(text) }
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flash = nil }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (level == nil ? 3.2 : 1.6), execute: w)
    }
    static let maxWing: CGFloat = 130
    var relayoutNow: () -> Void = {}
    /// Is something worth a mark right of the notch? (The bag on the left is always there.)
    var rightActive: Bool {
        flash != nil || focus.active || mic.active || music.playing || (pm?.on ?? false) || (pm?.stayActive ?? false) || (pm?.presenceActive ?? false)
            || (pm?.board.contains { $0.state == "waiting" || $0.state == "error" || $0.state == "working" } ?? false)
            || !(pm?.approvals.isEmpty ?? true)
    }
    var leftW: CGFloat { flash != nil ? 130 : Island.wing }
    var rightW: CGFloat { rightActive ? (flash != nil ? 130 : Island.wing) : 0 }
    var hover: (Bool) -> Void = { _ in }
    var toggleOpen: () -> Void = {}
    /// Opens (or closes) the island with the keyboard in it: ⌃⌥⌘I, or VoiceOver's press on the closed island.
    var toggleKeyboard: () -> Void = {}
    var showSettings: () -> Void = {}
    /// The clipboard page's search field needs the keyboard: the panel may take it while that page is shown.
    var setKeyable: (Bool) -> Void = { _ in }
}
