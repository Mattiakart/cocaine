// The island's Shelf module, at three sizes: S (one line: the collection, its count, its first items), M (the collection's items
// in one row) and L (the collection tabs, a toolbar, the grid, a status line). Items are selected with click, ⇧/⌘-click, ⌘A,
// the arrows and a rubber band; dragged out together (ShelfMouse/ShelfDragSource), reordered by dragging inside the grid,
// previewed with Space. The menus and forms are sheets over the page (ShelfSheets.swift); the data is ShelfStore
// (ShelfModel.swift), the controller ShelfCenter (ShelfCommands.swift).

import AppKit
import SwiftUI

extension IslandView {
    /// The shelf, drawn by its own view (it observes the store, the controller and the running job itself).
    func shelfModule(_ b: ModuleBox) -> some View {
        ShelfModuleView(model: model, center: model.shelfUI, store: model.shelf, tasks: model.shelfUI.tasks, box: b, hover: model.dropHover)
    }
}

struct ShelfModuleView: View {
    let model: IslandModel
    @ObservedObject var center: ShelfCenter
    @ObservedObject var store: ShelfStore
    @ObservedObject var tasks: ShelfTasks
    @ObservedObject var cloud = CloudShareCenter.shared          // the link just made (Sources/CloudShareSettings.swift)
    let box: ModuleBox
    let hover: Bool
    @StateObject private var band = ShelfBand()

    static let tile = CGSize(width: 66, height: 54)
    static let gap: CGFloat = 6

    var body: some View {
        Group {
            switch box.size {
            case .s: small
            case .m: medium
            case .l: large
            }
        }
        .onAppear { store.refresh() }
    }

    // MARK: sizes

    private var small: some View {
        HStack(spacing: Space.m) {
            collectionButton(compact: true)
            if store.isEmpty { Text(L("Drop files here")).font(UI.detail).foregroundStyle(UI.hint).lineLimit(1) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) { ForEach(store.items) { i in tile(i, icon: 24, named: false) } }
            }
            .mask(Self.fadeRight)
            menuButton
        }
        .frame(maxHeight: .infinity)
        .background(dropTint)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                collectionButton(compact: false)
                Spacer(minLength: 0)
                statusLine.frame(maxWidth: 220, alignment: .trailing)
                menuButton
            }
            if store.isEmpty { emptyZone(height: max(30, box.height - 30)) }
            else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.xs) { ForEach(store.items) { i in tile(i, icon: 30, named: box.height >= 70) } }
                }
                .mask(Self.fadeRight)
                .background(dropTint)
            }
            Spacer(minLength: 0)
        }
    }

    private var large: some View {
        let cols = max(1, Int((box.width + Self.gap) / (Self.tile.width + Self.gap)))
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                ShelfTabs(center: center, store: store)
                toolbar
            }
            .frame(height: CTL.h)
            ZStack(alignment: .bottom) {
                if store.isEmpty { emptyZone(height: max(40, box.height - CTL.h - 34)) }
                else { grid(cols) }
                if center.instantShown { instantStrip.motionAppear(edge: .bottom) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            statusLine.frame(height: 14)
        }
        .onAppear { center.columns = cols }
        .onChange(of: cols) { _, c in center.columns = c }
    }

    // MARK: pieces

    /// A row that scrolls sideways fades out at its right edge instead of cutting an item.
    static var fadeRight: some View {
        HStack(spacing: 0) { Rectangle(); LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 22) }
    }

    private var dropTint: some View {
        RoundedRectangle(cornerRadius: CTL.innerRadius).fill(Island.accent.opacity(hover ? 0.10 : 0)).padding(-4)
    }

    private func emptyZone(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            .foregroundStyle(hover ? Island.accent : Color.white.opacity(0.25))
            .background(RoundedRectangle(cornerRadius: 12).fill(Island.accent.opacity(hover ? 0.12 : 0)))
            .overlay(Text(box.size == .l ? L("Drag files, images, links or text onto the notch, then drop them here") : L("Drop files here"))
                .font(UI.value).foregroundStyle(UI.hint).multilineTextAlignment(.center).padding(.horizontal, 12))
            .frame(height: height)
            .accessibilityElement(children: .combine)
    }

    private func grid(_ cols: Int) -> some View {
        FadingScroll {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.tile.width), spacing: Self.gap), count: cols), alignment: .leading, spacing: Self.gap) {
                ForEach(Array(store.items.enumerated()), id: \.element.id) { n, i in
                    tile(i, icon: 34, named: true)
                        .overlay(alignment: .leading) { insertionMark(before: n) }
                        .overlay(alignment: .trailing) { if n == store.items.count - 1 { insertionMark(before: n + 1) } }
                }
            }
            .padding(.vertical, 2)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { ShelfDropTargets.shared.grid = g.frame(in: .named(ShelfDrop.space)) }
                    .onChange(of: g.frame(in: .named(ShelfDrop.space))) { _, f in ShelfDropTargets.shared.grid = f }
            })
            .contentShape(Rectangle())
            .gesture(rubberBand)
            .overlay(alignment: .topLeading) {
                if let r = band.rect {
                    Rectangle().fill(Island.accent.opacity(0.12)).overlay(Rectangle().strokeBorder(Island.accent.opacity(0.7), lineWidth: 1))
                        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY).allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: ShelfBand.space)
            .animation(Motion.animation(.appear), value: store.items.map(\.id))
        }
        .background(dropTint)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(format: L("%@, %d items"), store.current.title, store.items.count))
    }

    /// The marker where items dragged inside the shelf will land.
    @ViewBuilder private func insertionMark(before n: Int) -> some View {
        if store.dropIndex == n {
            Capsule().fill(Island.accent).frame(width: 3).padding(.vertical, 4).offset(x: n == store.items.count ? 4 : -4.5)
                .transition(.opacity).allowsHitTesting(false)
        }
    }

    /// One item: its icon (dimmed with a question mark when missing), its name, the selection; AppKit takes the pointer.
    private func tile(_ i: ShelfItem, icon side: CGFloat, named: Bool) -> some View {
        let selected = store.selection.contains(i.id)
        return accessible(pointer(look(i, side: side, named: named), i), i, selected: selected)
            .motionAppear(edge: .top, anchor: .center)                   // an item lands (and leaves) in place
    }

    private func look(_ i: ShelfItem, side: CGFloat, named: Bool) -> some View {
        let selected = store.selection.contains(i.id)
        let focused = store.selection.focus == i.id && !store.selection.isEmpty
        let ring: Color = selected ? Island.accent : focused ? Color.white.opacity(0.5) : .clear
        return VStack(spacing: 3) {
            ShelfTileIcon(item: i, store: store, side: side)
            if named {
                Text(i.name).font(UI.detail).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(i.missing ? UI.hint : UI.primary)
            }
        }
        .frame(width: named ? Self.tile.width : side + 6, height: named ? Self.tile.height : side + 6)
        .background(RoundedRectangle(cornerRadius: CTL.innerRadius).fill(Island.accent.opacity(selected ? 0.28 : 0)))
        .overlay(RoundedRectangle(cornerRadius: CTL.innerRadius).strokeBorder(ring, lineWidth: 1))
        .motionSelection(selected)
    }

    private func pointer<V: View>(_ v: V, _ i: ShelfItem) -> some View {
        let mouse = ShelfMouse(click: { count, flags in
            if count >= 2 { center.run(.open, items: [i]); return }
            center.click(i.id, shift: flags.contains(.shift), command: flags.contains(.command))
            Haptic.tap(.alignment)
        }, context: {
            if !store.selection.contains(i.id) { center.click(i.id, shift: false, command: false) }
            Motion.with(.dialog) { center.sheet = .menu }
        }, drag: { view, event in startDrag(i, view, event) })
        return v.overlay(mouse)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { register(i.id, g) }
                    .onChange(of: g.frame(in: .named(ShelfDrop.space))) { _, _ in register(i.id, g) }
            })
            .help(i.kind == .file ? i.path : i.name)
    }

    private func startDrag(_ i: ShelfItem, _ view: NSView, _ event: NSEvent) {
        if !store.selection.contains(i.id) { center.click(i.id, shift: false, command: false) }
        ShelfDragSource.shared.ended = { [weak center] ids, op, inside in
            guard let center else { return }
            // Dropped outside the island (a reorder is the drop target's): the items leave the shelf when asked to.
            if !inside && op != [] && center.config.config.removeAfterDragOut { Motion.with(.appear) { center.store.remove(Set(ids)) } }
            center.store.refresh(force: true)          // a file moved by the drop: the item follows it
        }
        ShelfDragSource.shared.begin(store.selectedItems(), store: store, from: view, event: event)
    }

    private func accessible<V: View>(_ v: V, _ i: ShelfItem, selected: Bool) -> some View {
        let value = [kindName(i), i.missing ? L("Missing") : nil, selected ? L("Selected") : nil].compactMap { $0 }.joined(separator: ", ")
        let traits: AccessibilityTraits = selected ? [.isSelected, .isButton] : .isButton
        return v.accessibilityElement(children: .ignore)
            .accessibilityLabel(i.name)
            .accessibilityValue(value)
            .accessibilityAddTraits(traits)
            .accessibilityAction { center.click(i.id, shift: false, command: true) }
            .accessibilityAction(named: L("Open")) { center.run(.open, items: [i]) }
            .accessibilityAction(named: L("Quick Look")) { center.quickLook([i]) }
            .accessibilityAction(named: L("Actions…")) { if !selected { center.click(i.id, shift: false, command: false) }; center.sheet = .menu }
            .accessibilityAction(named: L("Move left")) { move(i, by: -1) }
            .accessibilityAction(named: L("Move right")) { move(i, by: 2) }
            .accessibilityAction(named: L("Remove")) { center.run(.remove, items: [i]) }
    }

    private func move(_ i: ShelfItem, by step: Int) {
        guard let n = store.items.firstIndex(where: { $0.id == i.id }) else { return }
        store.reorder([i.id], to: max(0, n + step))
    }

    private func kindName(_ i: ShelfItem) -> String {
        switch i.kind { case .file: return L("File"); case .image: return L("Image"); case .link: return L("Link"); case .text: return L("Text") }
    }

    private func register(_ id: UUID, _ g: GeometryProxy) {
        let f = g.frame(in: .named(ShelfDrop.space)), b = g.frame(in: .named(ShelfBand.space))
        let t = ShelfDropTargets.shared
        if let k = t.tiles.firstIndex(where: { $0.id == id }) { t.tiles[k].frame = f } else { t.tiles.append((id, f)) }
        let order = store.items.map(\.id)
        t.tiles = t.tiles.filter { order.contains($0.id) }.sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        band.frames[id] = b
    }

    /// Dragging on the grid's empty space draws a band; the items it touches are selected (⇧ or ⌘: added to the selection).
    private var rubberBand: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(ShelfBand.space))
            .onChanged { v in
                if band.base == nil {
                    let f = NSEvent.modifierFlags
                    band.additive = f.contains(.shift) || f.contains(.command)
                    band.base = store.selection.ids
                    center.takeKeyboard()
                }
                let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                               width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                band.rect = r
                let hits = store.items.map(\.id).filter { band.frames[$0]?.intersects(r) == true }
                var s = store.selection
                s.band(hits, base: band.base ?? [], additive: band.additive)
                if s != store.selection { store.selection = s }
            }
            .onEnded { _ in band.rect = nil; band.base = nil }
    }

    private func collectionButton(compact: Bool) -> some View {
        Button { Motion.with(.dialog) { center.sheet = .collections } } label: {
            HStack(spacing: Space.xs) {
                Circle().fill(ShelfTabs.color(store.current.color)).frame(width: 8, height: 8)
                Text(store.current.title).font(UI.section).foregroundStyle(UI.secondary).lineLimit(1)
                Text("\(store.items.count)").font(UI.detail.monospacedDigit()).foregroundStyle(UI.hint)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(UI.hint)   // a glyph
            }
            .frame(height: CTL.h).contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScale))
        .fixedSize()
        .help(L("Collections"))
        .accessibilityLabel(L("Collections"))
        .accessibilityValue(String(format: L("%@, %d items"), store.current.title, store.items.count))
    }

    private var menuButton: some View {
        glyph("ellipsis.circle", L("Actions…")) { Motion.with(.dialog) { center.sheet = .menu } }.disabled(store.isEmpty)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            glyph("doc.on.clipboard", L("Add from the clipboard")) { center.paste() }
            glyph("eye", L("Quick Look")) { center.quickLook() }.disabled(store.isEmpty)
            glyph("square.and.arrow.up", L("Share…")) { center.run(.share) }.disabled(store.isEmpty)
            menuButton
        }
        .fixedSize()
    }

    private func glyph(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        ShelfGlyph(symbol: symbol, title: title, action: action)
    }

    /// The running job (with Cancel), else a message, else what is selected, else a hint.
    @ViewBuilder private var statusLine: some View {
        if let r = tasks.running {
            HStack(spacing: Space.s) {
                if let p = r.progress { ShelfProgressBar(value: p).frame(width: 80) }
                else { BusyDots(color: Island.accent) }
                Text(r.title).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                Button(L("Cancel")) { tasks.cancel() }.buttonStyle(CocaineButtonStyle(kind: .plain, height: 18))
            }
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        } else if cloud.recent != nil {
            CloudToast(center: cloud, compact: box.size != .l)
        } else if let s = center.status {
            HStack(spacing: Space.xs) {
                Image(systemName: s.icon).font(UI.detail).foregroundStyle(Island.accent)
                Text(s.text).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1).truncationMode(.middle)
                if s.undo { Button(L("Undo")) { center.undoRename() }.buttonStyle(CocaineButtonStyle(kind: .plain, height: 18)) }
            }
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        } else if box.size == .l {
            Text(store.selection.isEmpty ? (store.isEmpty ? L("Kept until you remove them; the files aren’t copied")
                                                          : L("Click to select, Space to preview, drag out to use"))
                                         : String(format: L("%1$d of %2$d selected"), store.selection.ids.count, store.items.count))
                .font(UI.detail).foregroundStyle(UI.hint).lineLimit(1)
        }
    }

    /// While files are dragged over the island with ⌥ held: the instant actions, to drop the files straight onto one.
    private var instantStrip: some View {
        HStack(spacing: Space.s) {
            ForEach(center.config.config.actions.filter(\.instant)) { a in
                Label(a.name, systemImage: a.symbol).font(UI.value).lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).frame(height: CTL.hDialog)
                    .background(Capsule().fill(Island.accent.opacity(0.25)))
                    .overlay(Capsule().strokeBorder(Island.accent, lineWidth: 1))
                    .background(GeometryReader { g in
                        Color.clear.onAppear { ShelfDropTargets.shared.instant[a.id] = g.frame(in: .named(ShelfDrop.space)) }
                            .onChange(of: g.frame(in: .named(ShelfDrop.space))) { _, f in ShelfDropTargets.shared.instant[a.id] = f }
                    })
                    .accessibilityLabel(a.name)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85)))
    }
}

/// A job's progress: the accent filling a track (the same look in every size).
struct ShelfProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(CTL.track)
                Capsule().fill(Island.accent).frame(width: max(4, g.size.width * CGFloat(max(0, min(1, value)))))
            }
        }
        .frame(height: 4)
        .motion(.value, value: value)
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100))%")
    }
}

/// The rubber band's state (not published per frame of the island; only its rectangle is drawn).
final class ShelfBand: ObservableObject {
    static let space = "cocaine.shelf.grid"
    @Published var rect: CGRect?
    var base: Set<UUID>?
    var additive = false
    var frames: [UUID: CGRect] = [:]
}

/// An item's picture: a thumbnail for images, the file's icon otherwise, a symbol for texts and links.
struct ShelfTileIcon: View {
    let item: ShelfItem
    let store: ShelfStore
    let side: CGFloat
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            switch item.kind {
            case .file, .image:
                if let u = store.url(of: item), !item.missing {
                    Image(nsImage: IconCache.icon(u.path)).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc").font(.system(size: side * 0.6)).foregroundStyle(UI.hint)
                }
            case .link:
                Image(systemName: "link").font(.system(size: side * 0.5, weight: .medium)).foregroundStyle(Island.accent)
                    .frame(width: side, height: side).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            case .text:
                Image(systemName: "text.alignleft").font(.system(size: side * 0.45, weight: .medium)).foregroundStyle(UI.secondary)
                    .frame(width: side, height: side).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            }
            if item.missing {
                Image(systemName: "questionmark.circle.fill").font(.system(size: max(10, side * 0.32))).foregroundStyle(warningColor)
                    .background(Circle().fill(Color.black))
            }
        }
        .frame(width: side, height: side)
        .opacity(item.missing ? 0.55 : 1)
    }
}

/// A 24 pt glyph button of the shelf's toolbar.
struct ShelfGlyph: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @StateObject private var hover = HoverState()
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: { Haptic.tap(.alignment); action() }) {
            Image(systemName: symbol).font(UI.icon).foregroundStyle(hover.on ? Color.white : UI.secondary)
                .frame(width: CTL.h, height: CTL.h)
                .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(hover.on ? 0.10 : 0)))
                .contentShape(Rectangle())
                .animation(Motion.animation(.hover), value: hover.on)
        }
        .buttonStyle(MotionGlyphStyle())
        .opacity(enabled ? 1 : CTL.disabled)
        .onHover { hover.on = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The collection tabs (L size): a chip per collection (its colour, its name), the one shown highlighted; a drag over a chip
/// drops into that collection. The last button manages them.
struct ShelfTabs: View {
    @ObservedObject var center: ShelfCenter
    @ObservedObject var store: ShelfStore

    static func color(_ i: Int) -> Color { let c = ShelfColors.palette[ShelfColors.clamp(i)]; return Color(red: c.r, green: c.g, blue: c.b) }

    var body: some View {
        HStack(spacing: Space.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    ForEach(store.collections) { c in chip(c) }
                }
            }
            ShelfGlyph(symbol: "plus", title: L("New collection")) { center.newCollection() }
            ShelfGlyph(symbol: "rectangle.stack", title: L("Collections")) { Motion.with(.dialog) { center.sheet = .collections } }
        }
    }

    private func chip(_ c: ShelfCollection) -> some View {
        let on = c.id == store.library.current
        let target = store.dropCollection == c.id
        return Button { Haptic.tap(.alignment); Motion.with(.page) { store.select(c.id) } } label: {
            HStack(spacing: 5) {
                Circle().fill(Self.color(c.color)).frame(width: 7, height: 7)
                Text(c.title).font(UI.detail.weight(on ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(on ? Color.white : UI.secondary)
                if !c.items.isEmpty { Text("\(c.items.count)").font(UI.detail.monospacedDigit()).foregroundStyle(UI.hint) }
            }
            .padding(.horizontal, 8).frame(height: CTL.h - 2)
            .background(Capsule().fill(target ? Island.accent.opacity(0.35) : Color.white.opacity(on ? 0.16 : 0.05)))
            .overlay(Capsule().strokeBorder(target ? Island.accent : .clear, lineWidth: 1))
            .contentShape(Capsule())
            .motionSelection(on)
        }
        .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScale))
        .background(GeometryReader { g in
            Color.clear.onAppear { ShelfDropTargets.shared.tabs[c.id] = g.frame(in: .named(ShelfDrop.space)) }
                .onChange(of: g.frame(in: .named(ShelfDrop.space))) { _, f in ShelfDropTargets.shared.tabs[c.id] = f }
                .onDisappear { ShelfDropTargets.shared.tabs[c.id] = nil }
        })
        .accessibilityLabel(c.title)
        .accessibilityValue(String(format: L("%d items"), c.items.count) + ", " + ShelfColors.name(c.color))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityAction(named: L("Rename…")) { center.renameCollection(c.id) }
        .accessibilityAction(named: L("Delete…")) { center.deleteCollection(c.id) }
    }
}
