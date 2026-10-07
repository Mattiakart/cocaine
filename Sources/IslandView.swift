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

    private var g: NotchGeometry { model.geometry }
    var files: FileShelf { model.files }
    var clipboard: ClipboardHistory { model.clipboard }
    var calendar: CalendarWatch { model.calendar }
    private var waiting: Bool { !m.approvals.isEmpty || m.board.contains(where: \.needsYou) }
    private var working: Bool { m.board.contains { $0.state == "working" } }

    /// Closed and open are one view: a single progress (0 closed … 1 open, sprung) drives the outline, its clip and every icon,
    /// so the bag, the live item and the tabs travel and change into each other instead of fading between two layouts.
    var body: some View {
        let open = model.open
        let pose = IslandPose(p: model.renderProgress ?? (open ? 1 : 0), leftW: model.leftW, rightW: model.rightW)
        let l = IslandLayout(notch: g.notchWidth, notchH: g.height)
        ZStack(alignment: .topLeading) {
            IslandOutline(pose: pose, layout: l).fill(Color.black)                  // reaches above the screen's edge
            ZStack(alignment: .topLeading) {
                strip(pose, l)
                VStack(spacing: 0) {
                    Color.clear.frame(height: l.top + g.height)
                    if open {
                        page.modifier(PageReveal(pose: IslandPose(p: model.renderProgress ?? 1, leftW: pose.leftW, rightW: pose.rightW), layout: l))
                            .transition(.modifier(active: PageReveal(pose: IslandPose(p: 0, leftW: model.leftW, rightW: model.rightW), layout: l),
                                                  identity: PageReveal(pose: IslandPose(p: 1, leftW: model.leftW, rightW: model.rightW), layout: l)))
                    }
                }
                .frame(width: l.size.width, height: l.size.height, alignment: .top)
            }
            .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
            .mask(IslandOutline(pose: pose, layout: l))                            // nothing ever shows outside the black
        }
        .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: Binding(get: { false }, set: { model.dropTargeted($0) })) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { DispatchQueue.main.async { Haptic.tap(.generic); model.shelf.add(u) } }
                }
            }
            return true
        }
        // Exactly the window's size, the canvas hanging from its top and centred on the notch whatever that size is. (Without the
        // zero minimums this frame takes the canvas's size, 656×228, and the hosting view centres that in the 38 pt closed window:
        // the closed island ended up 95 pt above the window, i.e. invisible. --island-selfcheck guards it.)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .animation(Motion.island(open ? Island.openSpring : Island.closeSpring), value: open)
        .animation(Motion.island(.spring(response: 0.3, dampingFraction: 0.84)), value: model.leftW)
        .animation(Motion.island(.spring(response: 0.3, dampingFraction: 0.84)), value: model.rightW)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Language.locale)
        .preferredColorScheme(.dark)
    }

    // MARK: the strip: the closed island's wings, and the open island's tabs

    /// Every item of the top strip, closed or open. Left: the bag (it becomes the Home tab), the tabs, the microphone. Right: what is
    /// live (it melts into the gear), the tabs and the gear. Tabs wait behind the notch while closed and slide out of it on opening.
    @ViewBuilder private func strip(_ s: IslandPose, _ l: IslandLayout) -> some View {
        let tabs = Island.tabs(external: Island.external), half = (tabs.count + 1) / 2, cell = cellWidth
        // The outermost highlights' edges on the page's text edge (18 pt in), whatever the cell width.
        let left0 = Self.stripStart(l.cx, cell: cell), right1 = 2 * l.cx - left0
        let leftTabs = Array(tabs.prefix(half).enumerated()), rightTabs = Array(tabs.dropFirst(half).enumerated()), nRight = tabs.count - half
        ForEach(leftTabs, id: \.element.id) { i, t in
            Group { if i == 0 { homeButton(t, s) } else { tabButton(t) } }
                .modifier(StripSlide(pose: s, layout: l, from: i == 0 ? .leftWing : .behindLeft, to: left0 + cell * (CGFloat(i) + 0.5),
                                     width: cell, order: i, fade: i == 0 ? .none : .reveal))
        }
        if mic.active {
            Image(systemName: "mic.fill").font(.system(size: 12)).foregroundStyle(.orange).frame(width: 24, height: g.height).help(L("Microphone in use"))
                .modifier(StripSlide(pose: s, layout: l, from: .behindLeft, to: left0 + cell * CGFloat(half) + 12, width: 24, order: half, fade: .reveal))
                .transition(.opacity)
        }
        rightWing.frame(width: max(1, model.rightW), height: g.height).allowsHitTesting(false).accessibilityHidden(model.open)
            .modifier(StripSlide(pose: s, layout: l, from: .rightWing, to: right1 - cell / 2, width: max(1, model.rightW), order: 0, fade: .melt))
        ForEach(rightTabs, id: \.element.id) { j, t in
            tabButton(t).modifier(StripSlide(pose: s, layout: l, from: .behindRight, to: right1 - cell * (CGFloat(nRight - j) + 0.5),
                                             width: cell, order: nRight - j, fade: .reveal))
        }
        Button { model.showSettings() } label: {
            Image(systemName: "gearshape").font(UI.tabIcon).foregroundStyle(UI.hint)
                .frame(width: cell, height: g.height).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(L("Settings")).accessibilityLabel(L("Settings"))
        .allowsHitTesting(model.open).accessibilityHidden(!model.open)
        .modifier(StripSlide(pose: s, layout: l, from: .gear, to: right1 - cell / 2, width: cell, order: 0, fade: .gear))
    }

    /// The Home tab is the bag itself: closed it sits left of the notch (or a flash icon does), open it is the first tab.
    private func homeButton(_ t: (id: String, icon: String, title: String), _ s: IslandPose) -> some View {
        let selected = model.tab == t.id
        return Button { Haptic.tap(.alignment); model.tab = t.id } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.16 : 0)).frame(width: Self.highlight(cellWidth), height: 26)
                    .modifier(CellMorph(pose: s, kind: .highlight))
                Image(nsImage: Self.bag(level: m.bagLevel, pouring: m.bagPouring, pink: m.bagPink)).frame(width: 20, height: 20)
                    .modifier(CellMorph(pose: s, kind: .bag(dim: selected ? 1 : 0.6)))
                if let f = model.flash {
                    Image(systemName: f.icon).foregroundStyle(Island.accent).modifier(CellMorph(pose: s, kind: .flashIcon))
                }
            }
            .frame(width: cellWidth, height: g.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(t.title).accessibilityLabel(t.title)
        .allowsHitTesting(model.open).accessibilityHidden(!model.open)
    }

    /// The menu-bar bag, always in its light-on-dark colors (the island is black).
    private static func bag(level: CGFloat, pouring: Bool, pink: Bool) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            Baggie.draw(in: rect, level: level, pouring: pouring, palette: Baggie.palette(dark: true, pink: pink))
            return true
        }
    }

    /// Right of the notch: what is going on, by importance.
    @ViewBuilder private var rightWing: some View {
        if let f = model.flash {
            if let l = f.level {
                Capsule().fill(Color.white.opacity(0.2)).frame(width: 78, height: 5)
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 78 * min(1, max(0, l)), height: 5) }
            } else {
                // The start of a file name says which file it is; the end is cut (".dmg" isn't news).
                Text(f.text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail).padding(.horizontal, Space.m)
            }
        }
        else if focus.running { Text(focus.text).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white) }
        else if waiting { Image(systemName: "hand.raised.fill").foregroundStyle(warningColor) }
        else if mic.active { Image(systemName: "mic.fill").foregroundStyle(.orange) }
        else if working { aiAtWork }
        else if model.music.playing { Visualizer(playing: true) }
        else if m.on { Text(m.onUntil.map { Self.remaining($0) } ?? "∞").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75)) }
        else if m.stayActive || m.presenceActive { Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Color(red: 1, green: 0.5, blue: 0.72)) }
    }

    /// AIs at work: the same sparkles as in the lists, and how many (not a spinner, which reads as "Cocaine is busy").
    private var aiAtWork: some View {
        let n = m.board.filter { $0.state == "working" }.count
        return HStack(spacing: 3) {
            Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))     // a glyph, sized to the wing
            Text("\(n)").font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(Island.accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L("%d AI at work"), n))
    }

    private static func remaining(_ until: Date) -> String { Dur.left(seconds: Int(until.timeIntervalSinceNow)) }

    // MARK: open

    /// The selected tab's page, below the strip. Only there while open: it is inserted once and unfolds (see PageReveal).
    private var page: some View {
        Group {
            switch model.tab {
            case "focus": focusTab
            case "calendar": calendarTab
            case "music": musicTab
            case "media": mediaTab
            case "mirror": mirrorTab
            case "display": displayTab
            case "files": filesTab
            case "shelf": shelfTab
            case "clipboard": clipboardTab
            case "status": statusTab
            default: homeTab
            }
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
        .frame(width: IslandLayout.openBody, height: Island.openSize.height - g.height, alignment: .top)
        .dialogHost(dialogs, .island, UI.dialog, maxWidth: Layout.width - 28, inset: EdgeInsets(top: 4, leading: 18, bottom: 8, trailing: 18))
    }

    private var cellWidth: CGFloat { Self.cellWidth(tabs: Island.tabs(external: Island.external).count) }
    static func cellWidth(tabs: Int) -> CGFloat { tabs >= 11 ? 28 : 31 }     // 11: room for the mic too
    /// A tab's highlight: never wider than its cell (it would cover the neighbours).
    static func highlight(_ cell: CGFloat) -> CGFloat { min(30, cell - 2) }
    /// Where the strip's first cell starts, so its highlight's left edge is on the page's text edge.
    static func stripStart(_ cx: CGFloat, cell: CGFloat) -> CGFloat { cx - IslandLayout.openBody / 2 + Space.page - (cell - highlight(cell)) / 2 }

    private func tabButton(_ t: (id: String, icon: String, title: String)) -> some View {
        Button { Haptic.tap(.alignment); model.tab = t.id } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(model.tab == t.id ? 0.16 : 0)).frame(width: Self.highlight(cellWidth), height: 26)
                Image(systemName: t.icon).font(UI.tabIcon)
                    .foregroundStyle(model.tab == t.id ? Color.white : UI.hint)
            }
            .frame(width: cellWidth, height: g.height)            // the whole cell, the full height of the strip
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(t.title).accessibilityLabel(t.title)
        .allowsHitTesting(model.open).accessibilityHidden(!model.open)
        .accessibilityAddTraits(model.tab == t.id ? .isSelected : [])
    }

}
