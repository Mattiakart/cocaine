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
        forwards = [files.objectWillChange, clipboard.objectWillChange, shelf.objectWillChange, calendar.objectWillChange, focus.objectWillChange, mic.objectWillChange,
                    music.objectWillChange, mirror.objectWillChange, ddc.objectWillChange]
            .map { $0.sink { [weak self] _ in self?.objectWillChange.send() } }
    }

    /// A short message in the closed island: "Downloaded", "Copied"…
    func flashNotice(_ icon: String, _ text: String, level: Double? = nil) {
        flash = (icon, text, level)
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
    var showSettings: () -> Void = {}
    /// The clipboard page's search field needs the keyboard: the panel may take it while that page is shown.
    var setKeyable: (Bool) -> Void = { _ in }
}
