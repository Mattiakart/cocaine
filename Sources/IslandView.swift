// The island's SwiftUI view (IslandView): the strip, the wings and the open page.

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

// MARK: Island views

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var m: PanelModel
    @ObservedObject var focus: FocusTimer
    @ObservedObject var batteries: BatteryWatch
    @ObservedObject var mic: MicWatch
    @ObservedObject var usage: UsageWatch
    @ObservedObject var dialogs = DialogCenter.shared
    @ObservedObject var display = DisplayOptions.shared
    /// A request from an AI waiting for an answer takes the open island's page (Sources/PlanReviewView.swift) until put aside.
    @ObservedObject var review = ApprovalReviewModel.shared
    /// The notch's sizes and controls (Sources/NotchSizing.swift).
    @ObservedObject var prefs = NotchPrefs.shared
    /// The screen this island is on (one island per screen, IslandController); nil = the model's own geometry (render tools).
    var place: IslandPlace? = nil

    var g: NotchGeometry { place?.geometry ?? model.geometry }
    /// This island is the open one (only one is open at a time: the pointer is on one screen).
    private var isOpen: Bool { model.open && (place == nil || model.openScreen == place!.display) }
    /// The HUD was sent to this island.
    private var hudHere: Bool { place == nil || model.hudScreen == place!.display || model.hudScreen == 0 }
    var files: FileShelf { model.files }
    var clipboard: ClipboardHistory { model.clipboard }
    var calendar: CalendarWatch { model.calendar }
    private var waiting: Bool { !m.approvals.isEmpty || m.board.contains(where: \.needsYou) }
    private var working: Bool { m.board.contains { $0.state == "working" } }

    /// Closed and open are one view: a single progress (0 closed … 1 open, sprung) drives the outline, its clip and every icon,
    /// so the bag, the live item and the tabs travel and change into each other instead of fading between two layouts.
    var body: some View {
        let open = isOpen
        let pose = IslandPose(p: model.renderProgress ?? (open ? 1 : 0), leftW: model.leftW, rightW: model.rightW)
        let l = IslandLayout(notch: g.notchWidth, notchH: g.height, closedCorner: g.hasNotch ? HUDShape.corner : prefs.sizing.pillCorner,
                             openCorner: prefs.sizing.openCorner)
        let reduce = Motion.reduce || display.reduceMotion
        ZStack(alignment: .topLeading) {
            IslandOutline(pose: pose, layout: l).fill(Color.black)                  // reaches above the screen's edge
                // Open, it floats a little over what is under it (Boring Notch's shadow); closed it is part of the screen's edge.
                .shadow(color: .black.opacity(open ? 0.55 : 0), radius: open ? 6 : 0, y: open ? 2 : 0)
            ZStack(alignment: .topLeading) {
                strip(pose, l)
                VStack(spacing: 0) {
                    Color.clear.frame(height: l.top + g.height)
                    // The page follows the same sprung progress as the outline, and is in the view only while that progress is
                    // above 0 (PageReveal): reopening half-way through a close carries on from where it is, never from scratch.
                    page.modifier(PageReveal(pose: pose, layout: l))
                }
                .frame(width: l.size.width, height: l.size.height, alignment: .top)
            }
            .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
            .mask(IslandOutline(pose: pose, layout: l))                            // nothing ever shows outside the black
            IslandHUDView(model: model, layout: l, notchH: g.height, pose: pose, here: hudHere, islandOpen: open)   // below the notch
            if !open { closedElement(l) }
        }
        .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
        // A two-finger swipe being followed (Sources/NotchGestures.swift): pushed up, the open island shrinks a little toward the
        // notch, as if closing; pulled down, the closed notch grows a little. Let go, it springs back. (Reduce Motion: still.)
        .modifier(GestureFollow(progress: reduce ? 0 : model.gestureProgress))
        .contentShape(Rectangle())
        // Files, images, links and text dropped anywhere on the island land on the shelf; items dragged inside it are reordered;
        // with ⌥ held, an instant action takes them (Sources/ShelfInteraction.swift).
        .coordinateSpace(name: ShelfDrop.space)
        .onDrop(of: ShelfDrop.types, delegate: ShelfDropDelegate(model: model))
        // Exactly the window's size, the canvas hanging from its top and centred on the notch whatever that size is. (Without the
        // zero minimums this frame takes the canvas's size, 656×228, and the hosting view centres that in the 38 pt closed window:
        // the closed island ended up 95 pt above the window, i.e. invisible. --island-selfcheck guards it.)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        // One spring for the morph: a reversal mid-way retargets it (SwiftUI keeps its velocity), so rapid in/out never restarts it.
        .animation(Motion.island(open), value: open)
        .animation(Motion.animation(.wing), value: model.leftW)
        .animation(Motion.animation(.wing), value: model.rightW)
        // No focus ring on the island's buttons when it takes the keyboard for a dialog, a shelf form or the search field (the
        // window becomes key and AppKit focused its first button: a stray border). Opened from the keyboard (⌃⌥⌘I), where Tab
        // moves between controls, the ring shows where the keyboard is.
        .focusEffectDisabled(!model.keyboard)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Language.locale)
        .preferredColorScheme(.dark)
    }

    // MARK: the strip: the closed island's wings, and the open island's tabs

    /// Every item of the top strip, closed or open. Left: the bag (it becomes the Home tab), the tabs, the microphone. Right: what is
    /// live (it melts into the gear), the tabs and the gear. Tabs wait behind the notch while closed and slide out of it on opening.
    @ViewBuilder private func strip(_ s: IslandPose, _ l: IslandLayout) -> some View {
        let tabs = model.tabs, half = (tabs.count + 1) / 2, cell = cellWidth
        // The outermost highlights' edges on the page's text edge (18 pt in), whatever the cell width.
        let left0 = Self.stripStart(l.cx, cell: cell), right1 = 2 * l.cx - left0
        let leftTabs = Array(tabs.prefix(half).enumerated()), rightTabs = Array(tabs.dropFirst(half).enumerated()), nRight = tabs.count - half
        ForEach(leftTabs, id: \.element.id) { i, t in
            Group { if i == 0 { homeButton(t, s, cell: cell) } else { tabButton(t, cell: cell) } }
                .modifier(StripSlide(pose: s, layout: l, from: i == 0 ? .leftWing : .behindLeft, to: left0 + cell * (CGFloat(i) + 0.5),
                                     width: cell, order: i, fade: i == 0 ? .none : .reveal))
        }
        if mic.active {
            Image(systemName: "mic.fill").font(.system(size: 12)).foregroundStyle(.orange).frame(width: 24, height: g.height).help(L("Microphone in use"))
                .modifier(StripSlide(pose: s, layout: l, from: .behindLeft, to: left0 + cell * CGFloat(half) + 12, width: 24, order: half, fade: .reveal))
                .transition(.opacity)
        }
        rightWing.frame(width: max(1, model.rightW), height: g.height).allowsHitTesting(false).accessibilityHidden(true)   // (said by closedElement)
            .modifier(StripSlide(pose: s, layout: l, from: .rightWing, to: right1 - cell / 2, width: max(1, model.rightW), order: 0, fade: .melt))
        ForEach(rightTabs, id: \.element.id) { j, t in
            tabButton(t, cell: cell).modifier(StripSlide(pose: s, layout: l, from: .behindRight, to: right1 - cell * (CGFloat(nRight - j) + 0.5),
                                             width: cell, order: nRight - j, fade: .reveal))
        }
        Button { model.showSettings() } label: {
            ZStack {
                StripHighlight(selected: false, width: Self.highlight(cell), height: 26)
                Image(systemName: "gearshape").font(UI.tabIcon).foregroundStyle(UI.hint)
            }
            .frame(width: cell, height: g.height).contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle()).help(L("Settings")).accessibilityLabel(L("Settings"))
        .allowsHitTesting(isOpen).accessibilityHidden(!isOpen)
        .modifier(StripSlide(pose: s, layout: l, from: .gear, to: right1 - cell / 2, width: cell, order: 0, fade: .gear))
    }

    /// The first tab is the bag itself: closed it sits left of the notch (or a flash icon does), open it is the first tab: Home,
    /// or (when the screens were rearranged) the first screen's icon, which the bag melts into.
    private func homeButton(_ t: (id: String, icon: String, title: String), _ s: IslandPose, cell: CGFloat) -> some View {
        let selected = model.tab == t.id
        return Button { Haptic.tap(.alignment); Motion.with(.page) { model.tab = t.id } } label: {
            ZStack {
                StripHighlight(selected: selected, width: Self.highlight(cell), height: 26)
                    .modifier(CellMorph(pose: s, kind: .highlight))
                if t.id == "home" {
                    BagIcon(bag: m.bag, size: 20).frame(width: 20, height: 20)       // only it redraws while the powder pours
                        .modifier(CellMorph(pose: s, kind: .bag(dim: selected ? 1 : 0.6)))
                } else {
                    BagIcon(bag: m.bag, size: 20).frame(width: 20, height: 20)
                        .modifier(CellMorph(pose: s, kind: .bag(dim: 1))).modifier(FirstCellMorph(pose: s, out: true))
                    Image(systemName: t.icon).font(UI.tabIcon).foregroundStyle(selected ? Color.white : UI.hint)
                        .modifier(FirstCellMorph(pose: s, out: false))
                }
            }
            .frame(width: cell, height: g.height)
            .contentShape(Rectangle())
            .motionSelection(selected)
        }
        .buttonStyle(MotionGlyphStyle()).help(t.title).accessibilityLabel(t.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .allowsHitTesting(isOpen).accessibilityHidden(!isOpen)
    }

    /// The closed island for VoiceOver: one element, "Cocaine", saying what the wings show; its action opens the island with the
    /// keyboard in it (as ⌃⌥⌘I does). The window ignores the pointer while closed, so this is the way in without a mouse.
    private func closedElement(_ l: IslandLayout) -> some View {
        Color.clear
            .frame(width: g.notchWidth + model.leftW + max(model.rightW, 1), height: g.height)
            .offset(x: l.notchLeft - model.leftW, y: l.top)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Cocaine")
            .accessibilityValue(closedSummary)
            .accessibilityHint(L("Opens the island. Left and right arrows change tabs, Escape closes."))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.toggleKeyboard() }
    }

    /// What the closed island shows, in words (the bag and the right wing).
    private var closedSummary: String {
        var parts = [m.on ? L("Cocaine is on") : L("Cocaine is off")]
        if let f = model.flash, f.level == nil { parts.append(f.text) }
        if focus.running { parts.append(focus.spoken) }
        if waiting { parts.append(L("An AI needs you")) }
        if mic.active { parts.append(L("Microphone in use")) }
        if working { parts.append(String(format: L("%d AI at work"), m.board.filter { $0.state == "working" }.count)) }
        if model.music.playing { parts.append(L("Music playing")) }
        if m.on, let u = m.onUntil { parts.append(String(format: L("until %@"), PanelView.timeString(u))) }
        if !m.on && (m.stayActive || m.presenceActive) { parts.append(L("Stay active")) }
        return parts.joined(separator: ", ")
    }

    /// Which item the right wing shows now (its changes swap in place: the stateSwap motion).
    private var wingState: String {
        focus.running ? "focus" : waiting ? "waiting" : mic.active ? "mic" : working ? "working" : model.music.playing ? "music"
            : m.on ? "on" : m.stayActive || m.presenceActive ? "stay" : "none"
    }

    /// Right of the notch: one item at a time; another one takes its place by shrinking out as the new one grows in (Reduce
    /// Motion: a quick cross-fade), never a jump.
    private var rightWing: some View {
        ZStack {
            rightWingItem.id(wingState)
                .transition(Motion.reduce ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
        }
        .animation(Motion.animation(.stateSwap), value: wingState)
    }

    /// Right of the notch: what is going on, by importance. (Messages and volume/brightness bars are in the HUD below the notch.)
    @ViewBuilder private var rightWingItem: some View {
        if focus.running {
            TimelineView(.periodic(from: .now, by: 1)) { _ in       // the countdown redraws itself, not the whole island
                Text(focus.text).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
            }
        }
        else if waiting { Image(systemName: "hand.raised.fill").foregroundStyle(warningColor).motionPulse(m.approvals.count) }
        else if mic.active { Image(systemName: "mic.fill").foregroundStyle(.orange) }
        else if working { aiAtWork }
        else if model.music.playing { Visualizer(playing: !Motion.reduce) }                     // Reduce Motion: still bars
        else if m.on { Text(m.onUntil.map { Self.remaining($0) } ?? "∞").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75)) }
        else if m.stayActive || m.presenceActive { Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Color(red: 1, green: 0.5, blue: 0.72)) }
    }

    /// AIs at work: the same sparkles as in the lists, and how many (not a spinner, which reads as "Cocaine is busy").
    private var aiAtWork: some View {
        let n = m.board.filter { $0.state == "working" }.count
        return HStack(spacing: 3) {
            Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))     // a glyph, sized to the wing
            Text("\(n)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                .motionNumber(n)                         // the count rolls to its new value
        }
        .foregroundStyle(Island.accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L("%d AI at work"), n))
    }

    private static func remaining(_ until: Date) -> String { Dur.left(seconds: Int(until.timeIntervalSinceNow)) }

    // MARK: open

    /// The selected screen's page, below the strip, its modules as the layout places them (ScreenModules.swift). Only there
    /// while open: it is inserted once and unfolds (see PageReveal); changing screens slides them from the side of the tab picked (Motion.page).
    private var page: some View {
        ZStack(alignment: .top) {
            if let r = review.current(in: m.approvals) {                    // a request waits: its review takes the page
                let open = m.approvals.filter { $0.answerable && !review.later.contains($0.id) }
                let i = open.firstIndex { $0.id == r.id } ?? 0
                ApprovalReviewView(request: r, index: i, count: open.count, island: true, accent: Island.accent, warning: warningColor,
                                   step: { d in if open.indices.contains(i + d) { Motion.with(.page) { review.selected = open[i + d].id } } })
                    .transition(Motion.appear(.top))
            } else if let f = Motion.frame, let from = model.renderPageFrom {      // the render aid: one moment of a page change
                screenPage(from).modifier(PageSlide(t: f, incoming: false, direction: model.pager, reduce: Motion.reduce))
                screenPage(model.tab).modifier(PageSlide(t: 1 - f, incoming: true, direction: model.pager, reduce: Motion.reduce))
            } else {
                screenPage(model.tab).id(model.tab).transition(Motion.page(model.pager))
            }
        }
        .animation(Motion.animation(.page), value: model.tab)
        .animation(Motion.animation(.notice), value: review.current(in: m.approvals)?.id)
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
        .frame(width: IslandLayout.openBody, height: Island.openSize.height - g.height, alignment: .top)
        .modifier(ShelfSheetLayer(center: model.shelfUI))                  // the shelf's menus and forms (Sources/ShelfSheets.swift)
        .dialogHost(dialogs, .island, UI.dialog, maxWidth: Layout.width - 28, inset: EdgeInsets(top: 4, leading: 18, bottom: 8, trailing: 18))
    }

    private var cellWidth: CGFloat { Self.cellWidth(tabs: model.tabs.count) }
    static func cellWidth(tabs: Int) -> CGFloat { tabs >= 11 ? 28 : 31 }     // 11: room for the mic too
    /// A tab's highlight: never wider than its cell (it would cover the neighbours).
    static func highlight(_ cell: CGFloat) -> CGFloat { min(30, cell - 2) }
    /// Where the strip's first cell starts, so its highlight's left edge is on the page's text edge.
    static func stripStart(_ cx: CGFloat, cell: CGFloat) -> CGFloat { cx - IslandLayout.openBody / 2 + Space.page - (cell - highlight(cell)) / 2 }

    private func tabButton(_ t: (id: String, icon: String, title: String), cell: CGFloat) -> some View {
        Button { Haptic.tap(.alignment); Motion.with(.page) { model.tab = t.id } } label: {
            ZStack {
                StripHighlight(selected: model.tab == t.id, width: Self.highlight(cell), height: 26)
                Image(systemName: t.icon).font(UI.tabIcon)
                    .foregroundStyle(model.tab == t.id ? Color.white : UI.hint)
            }
            .frame(width: cell, height: g.height)            // the whole cell, the full height of the strip
            .contentShape(Rectangle())
            .motionSelection(model.tab == t.id)
        }
        .buttonStyle(MotionGlyphStyle()).help(t.title).accessibilityLabel(t.title)
        .allowsHitTesting(isOpen).accessibilityHidden(!isOpen)
        .accessibilityAddTraits(model.tab == t.id ? .isSelected : [])
    }

}
