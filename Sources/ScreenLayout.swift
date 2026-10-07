// The island's screens as the user arranges them (ScreenLayout): which pages show, in what order, which modules each page
// holds (in two columns, each module S, M or L), and which page opens first. Pure: the rules here are what --screens-test
// checks; the views are in ScreenModules.swift, the settings card in ScreensEditor.swift. Kept in AppDefaults.store under
// `screens.v1` as JSON; nothing stored (or anything unreadable, or written by a newer Cocaine) is exactly the built-in layout.

import AppKit
import Combine
import SwiftUI

/// A module's height in its column: a third, half, or all of it. (Its width comes from its column, see ScreenLayout.resolve.)
enum ModuleSize: String, Codable, CaseIterable, Comparable {
    case s, m, l
    /// Sixths of the column's height.
    var units: Int { switch self { case .s: return 2; case .m: return 3; case .l: return 6 } }
    static func < (a: ModuleSize, b: ModuleSize) -> Bool { a.units < b.units }
    var letter: String { rawValue.uppercased() }
}

/// How wide a module must be: the island's narrow column (250 pt), its wide one (the rest), or the whole page.
enum ModuleWidth: Int, Comparable {
    case narrow, wide, full
    static func < (a: ModuleWidth, b: ModuleWidth) -> Bool { a.rawValue < b.rawValue }
}

/// One kind of module: what it is, where it comes from, the sizes it can be drawn at without cutting anything.
struct ModuleSpec: Equatable {
    let id: String
    let title: String            // the L() key
    let icon: String
    let home: String             // the built-in screen it belongs to
    let sizes: [ModuleSize]      // ascending
    let width: ModuleWidth
    var exclusive = false        // fills its screen alone (the calendar)
    var minSize: ModuleSize { sizes.first ?? .l }
    var maxSize: ModuleSize { sizes.last ?? .l }

    /// The size it is drawn at when `wanted` is asked: that one when supported, else the next larger, else its largest.
    func fit(_ wanted: ModuleSize) -> ModuleSize { sizes.first { $0 >= wanted } ?? maxSize }
    /// One step smaller, if it has one.
    func smaller(than s: ModuleSize) -> ModuleSize? { sizes.last { $0 < s } }
}

/// One built-in screen: its tab (icon, title) and the modules it starts with.
struct ScreenSpec {
    let id: String
    let icon: String
    let title: String            // the L() key
    let modules: [ModulePlacement]
    /// Shown only while something makes it useful (the Monitors screen: an external monitor).
    var conditional = false
}

/// The registry. Module and screen ids are stored, so they never change; titles are L() keys (Screens.strings and the main table).
enum ModuleCatalog {
    static let modules: [ModuleSpec] = [
        ModuleSpec(id: "cocaine", title: "Cocaine", icon: "power", home: "home", sizes: [.s, .m, .l], width: .narrow),
        ModuleSpec(id: "agents", title: "Agents", icon: "sparkles", home: "home", sizes: [.m, .l], width: .narrow),
        ModuleSpec(id: "music", title: "Music", icon: "music.note", home: "music", sizes: [.l], width: .wide),
        ModuleSpec(id: "media", title: "Media", icon: "play.rectangle.fill", home: "media", sizes: [.l], width: .full),
        ModuleSpec(id: "calendar", title: "Calendar", icon: "calendar", home: "calendar", sizes: [.l], width: .full, exclusive: true),
        ModuleSpec(id: "focus", title: "Focus", icon: "timer", home: "focus", sizes: [.l], width: .full),
        ModuleSpec(id: "downloads", title: "Downloads", icon: "arrow.down.circle", home: "files", sizes: [.m, .l], width: .narrow),
        ModuleSpec(id: "screenshots", title: "Screenshots", icon: "camera.viewfinder", home: "files", sizes: [.l], width: .narrow),
        ModuleSpec(id: "shelf", title: "Shelf", icon: "tray.and.arrow.down.fill", home: "shelf", sizes: [.l], width: .wide),
        ModuleSpec(id: "clipboard", title: "Clipboard", icon: "doc.on.clipboard", home: "clipboard", sizes: [.m, .l], width: .narrow),
        ModuleSpec(id: "batteries", title: "Batteries", icon: "battery.75percent", home: "status", sizes: [.s, .m, .l], width: .narrow),
        ModuleSpec(id: "usage", title: "AI usage", icon: "gauge.with.needle", home: "status", sizes: [.l], width: .narrow),
        ModuleSpec(id: "mirror", title: "Mirror", icon: "person.crop.square", home: "mirror", sizes: [.l], width: .full),
        ModuleSpec(id: "monitors", title: "Monitors", icon: "display", home: "display", sizes: [.l], width: .full),
    ]

    static let screens: [ScreenSpec] = [
        ScreenSpec(id: "home", icon: "house.fill", title: "Home", modules: [.init("cocaine", 0), .init("agents", 1)]),
        ScreenSpec(id: "music", icon: "music.note", title: "Music", modules: [.init("music", 0)]),
        ScreenSpec(id: "media", icon: "play.rectangle.fill", title: "Media", modules: [.init("media", 0)]),
        ScreenSpec(id: "calendar", icon: "calendar", title: "Calendar", modules: [.init("calendar", 0)]),
        ScreenSpec(id: "focus", icon: "timer", title: "Focus", modules: [.init("focus", 0)]),
        ScreenSpec(id: "files", icon: "tray.full.fill", title: "Files", modules: [.init("downloads", 0), .init("screenshots", 1)]),
        ScreenSpec(id: "shelf", icon: "tray.and.arrow.down.fill", title: "Shelf", modules: [.init("shelf", 0)]),
        ScreenSpec(id: "clipboard", icon: "doc.on.clipboard", title: "Clipboard", modules: [.init("clipboard", 0)]),
        ScreenSpec(id: "status", icon: "gauge.with.needle", title: "Status", modules: [.init("batteries", 0), .init("usage", 1)]),
        ScreenSpec(id: "mirror", icon: "person.crop.square", title: "Mirror", modules: [.init("mirror", 0)]),
        ScreenSpec(id: "display", icon: "display", title: "Monitors", modules: [.init("monitors", 0)], conditional: true),
    ]

    static func module(_ id: String) -> ModuleSpec? { modules.first { $0.id == id } }
    static func screen(_ id: String) -> ScreenSpec? { screens.first { $0.id == id } }
}

struct ModulePlacement: Codable, Equatable, Identifiable {
    var kind: String
    var column: Int
    var size: ModuleSize
    var id: String { kind }
    init(_ kind: String, _ column: Int, _ size: ModuleSize = .l) { self.kind = kind; self.column = column; self.size = size }
}

struct ScreenConfig: Codable, Equatable, Identifiable {
    var id: String
    var visible: Bool
    var modules: [ModulePlacement]
}

/// What drawing a screen in the island's fixed page gives: each module's box, and what had to give way (for the editor).
struct ResolvedScreen: Equatable {
    struct Module: Equatable {
        var kind: String
        var size: ModuleSize
        var column: Int          // 0 or 1; a single column is 0
        var frame: CGRect        // in the page's content box
    }
    enum Issue: Equatable {
        case shrunk(String, ModuleSize, ModuleSize)      // kind, asked, drawn
        case noRoom(String)                              // too many modules in its column
        case needsWholePage(String, String)              // kind left out, because of this one (full width or exclusive)
        case needsWideColumn(String, String)             // kind left out: the wide column is taken by this one
        case empty
    }
    var columns: Int
    var widths: [CGFloat]
    var modules: [Module]
    var issues: [Issue]
    func modules(in column: Int) -> [Module] { modules.filter { $0.column == column } }
}

struct ScreenLayout: Codable, Equatable {
    static let currentVersion = 1
    static let key = "screens.v1"
    static let lastUsed = "last"

    var version = ScreenLayout.currentVersion
    var screens: [ScreenConfig]
    /// The screen the island opens on: a screen's id, or "last" (the one shown last time; the first one after launch).
    var start: String = ScreenLayout.lastUsed

    /// Exactly the island as it was before screens could be arranged.
    static var standard: ScreenLayout {
        ScreenLayout(screens: ModuleCatalog.screens.map { ScreenConfig(id: $0.id, visible: true, modules: $0.modules) })
    }

    // MARK: storing

    /// The stored value, or the standard layout when there is none, it can't be read, or a newer Cocaine wrote it.
    static func decode(_ data: Data?) -> ScreenLayout {
        guard let data, let l = try? JSONDecoder().decode(ScreenLayout.self, from: data), l.version == currentVersion else { return standard }
        return l.sanitized()
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Only what this version knows, each once: unknown screens and modules dropped, missing screens added (as they come in
    /// the standard layout, after the others), sizes and columns in range, at least one screen shown, a start that exists.
    func sanitized() -> ScreenLayout {
        var seen = Set<String>(), out: [ScreenConfig] = []
        for s in screens where ModuleCatalog.screen(s.id) != nil && !seen.contains(s.id) {
            seen.insert(s.id)
            var kinds = Set<String>()
            let mods = s.modules.compactMap { p -> ModulePlacement? in
                guard let spec = ModuleCatalog.module(p.kind), !kinds.contains(p.kind) else { return nil }
                kinds.insert(p.kind)
                return ModulePlacement(p.kind, min(1, max(0, p.column)), spec.fit(p.size))
            }
            out.append(ScreenConfig(id: s.id, visible: s.visible, modules: mods))
        }
        for spec in ModuleCatalog.screens where !seen.contains(spec.id) {
            out.append(ScreenConfig(id: spec.id, visible: true, modules: spec.modules))
        }
        var l = ScreenLayout(version: Self.currentVersion, screens: out, start: start)
        if !l.screens.contains(where: { $0.visible && !Self.isConditional($0.id) }),
           let i = l.screens.firstIndex(where: { !Self.isConditional($0.id) }) { l.screens[i].visible = true }
        if l.start != Self.lastUsed && ModuleCatalog.screen(l.start) == nil { l.start = Self.lastUsed }
        return l
    }

    static func isConditional(_ id: String) -> Bool { ModuleCatalog.screen(id)?.conditional ?? false }

    // MARK: what the island shows

    /// The tabs, in order: the shown screens (the Monitors screen only with an external monitor).
    func visibleScreens(external: Bool) -> [ScreenConfig] {
        screens.filter { $0.visible && (external || !Self.isConditional($0.id)) }
    }

    /// The screen to open on: the chosen one if it is shown, else (or with "last used") `current` if shown, else the first.
    func startScreen(current: String?, external: Bool) -> String? {
        let ids = visibleScreens(external: external).map(\.id)
        if start != Self.lastUsed, ids.contains(start) { return start }
        if let current, ids.contains(current) { return current }
        return ids.first
    }

    /// Where a module (or a built-in screen's name, e.g. "shelf" while dragging a file) can be seen now: that screen if it is
    /// shown, else the first shown screen holding that module.
    func screenShowing(_ id: String, external: Bool) -> String? {
        let shown = visibleScreens(external: external)
        if shown.contains(where: { $0.id == id }) { return id }
        let kinds = ModuleCatalog.screen(id)?.modules.map(\.kind) ?? [id]
        return shown.first { s in s.modules.contains { kinds.contains($0.kind) } }?.id
    }

    func config(_ id: String) -> ScreenConfig? { screens.first { $0.id == id } }

    // MARK: edits (each keeps the rules: the editor calls these and nothing else)

    /// Moves a screen by `by` places (-1 up, +1 down). False when it can't move that way.
    @discardableResult mutating func moveScreen(_ id: String, by: Int) -> Bool {
        guard let i = screens.firstIndex(where: { $0.id == id }) else { return false }
        let j = i + by
        guard j >= 0, j < screens.count, j != i else { return false }
        screens.insert(screens.remove(at: i), at: j)
        return true
    }

    /// Moves a screen to an index (drag and drop): it ends up at `index` in the new order.
    @discardableResult mutating func moveScreen(_ id: String, to index: Int) -> Bool {
        guard let i = screens.firstIndex(where: { $0.id == id }) else { return false }
        let j = min(max(0, index), screens.count - 1)
        guard j != i else { return false }
        screens.insert(screens.remove(at: i), at: j)
        return true
    }

    /// Can this screen be hidden? Not the last one shown (the Monitors screen, which comes and goes, doesn't count).
    func canHide(_ id: String) -> Bool {
        guard let s = config(id), s.visible else { return false }
        if Self.isConditional(id) { return true }
        return screens.contains { $0.id != id && $0.visible && !Self.isConditional($0.id) }
    }

    @discardableResult mutating func setVisible(_ id: String, _ on: Bool) -> Bool {
        guard let i = screens.firstIndex(where: { $0.id == id }) else { return false }
        if !on && !canHide(id) { return false }
        screens[i].visible = on
        return true
    }

    mutating func setStart(_ id: String) {
        start = id == Self.lastUsed || ModuleCatalog.screen(id) != nil ? id : Self.lastUsed
    }

    /// Modules that can be added to a screen: those it doesn't hold yet.
    func addable(to id: String) -> [ModuleSpec] {
        let have = Set(config(id)?.modules.map(\.kind) ?? [])
        return ModuleCatalog.modules.filter { !have.contains($0.id) }
    }

    /// Adds a module where it fits best (see `place`).
    @discardableResult mutating func addModule(_ kind: String, to id: String) -> Bool {
        guard let i = screens.firstIndex(where: { $0.id == id }), ModuleCatalog.module(kind) != nil,
              !screens[i].modules.contains(where: { $0.kind == kind }) else { return false }
        Self.place(kind, into: &screens[i])
        return true
    }

    /// Puts a module into a screen: in the column with the most room, as large as fits there; when neither column has room,
    /// the modules of the column that can make room are made smaller (the lowest first) until it fits at its smallest. When
    /// nothing can make room it goes in the emptier column at its smallest, and the editor says what doesn't fit.
    static func place(_ kind: String, into screen: inout ScreenConfig) {
        guard let spec = ModuleCatalog.module(kind) else { return }
        let mods = screen.modules
        func used(_ c: Int) -> Int { mods.filter { $0.column == c }.map(\.size.units).reduce(0, +) }
        func least(_ c: Int) -> Int { mods.filter { $0.column == c }.map { ModuleCatalog.module($0.kind)?.minSize.units ?? 6 }.reduce(0, +) }
        let order = used(0) <= used(1) ? [0, 1] : [1, 0]
        for c in order {
            if let s = spec.sizes.last(where: { $0.units <= 6 - used(c) }) {
                screen.modules.append(ModulePlacement(kind, c, s)); return
            }
        }
        for c in (least(0) <= least(1) ? [0, 1] : [1, 0]) {
            guard let s = spec.sizes.last(where: { $0.units <= 6 - least(c) }) else { continue }
            // Shrink the column's modules, the lowest first, one step at a time, until `s` fits.
            var total = used(c)
            while total + s.units > 6 {
                guard let j = screen.modules.indices.last(where: { k in
                    screen.modules[k].column == c && ModuleCatalog.module(screen.modules[k].kind)?.smaller(than: screen.modules[k].size) != nil
                }), let smaller = ModuleCatalog.module(screen.modules[j].kind)?.smaller(than: screen.modules[j].size) else { break }
                total -= screen.modules[j].size.units - smaller.units
                screen.modules[j].size = smaller
            }
            screen.modules.append(ModulePlacement(kind, c, s)); return
        }
        screen.modules.append(ModulePlacement(kind, order[0], spec.minSize))
    }

    @discardableResult mutating func removeModule(_ kind: String, from id: String) -> Bool {
        guard let i = screens.firstIndex(where: { $0.id == id }), let j = screens[i].modules.firstIndex(where: { $0.kind == kind }) else { return false }
        screens[i].modules.remove(at: j)
        return true
    }

    /// Moves a module up or down among its column's modules (its order in the screen's list otherwise).
    @discardableResult mutating func moveModule(_ kind: String, in id: String, by: Int) -> Bool {
        guard let i = screens.firstIndex(where: { $0.id == id }), let j = screens[i].modules.firstIndex(where: { $0.kind == kind }) else { return false }
        let k = j + by
        guard k >= 0, k < screens[i].modules.count, k != j else { return false }
        screens[i].modules.insert(screens[i].modules.remove(at: j), at: k)
        return true
    }

    @discardableResult mutating func setSize(_ kind: String, in id: String, _ size: ModuleSize) -> Bool {
        guard let i = screens.firstIndex(where: { $0.id == id }), let j = screens[i].modules.firstIndex(where: { $0.kind == kind }),
              let spec = ModuleCatalog.module(kind), spec.sizes.contains(size) else { return false }
        screens[i].modules[j].size = size
        return true
    }

    @discardableResult mutating func setColumn(_ kind: String, in id: String, _ column: Int) -> Bool {
        guard let i = screens.firstIndex(where: { $0.id == id }), let j = screens[i].modules.firstIndex(where: { $0.kind == kind }),
              column == 0 || column == 1 else { return false }
        screens[i].modules[j].column = column
        return true
    }

    /// Merges one screen into another: its modules join the other's (each placed as `place` does; any it already holds are
    /// skipped) and it is hidden. False when it can't be hidden or there is nothing to move.
    @discardableResult mutating func merge(_ from: String, into to: String) -> Bool {
        guard from != to, let a = screens.firstIndex(where: { $0.id == from }), let b = screens.firstIndex(where: { $0.id == to }) else { return false }
        let have = Set(screens[b].modules.map(\.kind))
        let moving = screens[a].modules.filter { !have.contains($0.kind) }
        guard !moving.isEmpty, !screens[a].visible || canHide(from) else { return false }
        for p in moving { Self.place(p.kind, into: &screens[b]) }
        screens[a].visible = false
        return true
    }

    // MARK: drawing a screen in the island's fixed page

    static let narrowColumn: CGFloat = 250          // template A: the island's left column (Home, Files, Status)
    static let gutter: CGFloat = Space.gutter
    static let gap: CGFloat = Space.l               // between modules stacked in a column

    /// The page's content box for a strip (notch) of this height: the open island's size, less the strip and the page's margins.
    static func contentSize(stripHeight: CGFloat) -> CGSize {
        CGSize(width: IslandLayout.openBody - 2 * Space.page, height: Island.openSize.height - stripHeight - 8 - 16)
    }

    /// Lays a screen out in the island's page, which never grows: a module that would not fit is drawn smaller, or left out
    /// (and the editor says which and why). Nothing is ever drawn cut.
    static func resolve(_ screen: ScreenConfig, in box: CGSize) -> ResolvedScreen {
        var issues: [ResolvedScreen.Issue] = []
        var mods: [(p: ModulePlacement, spec: ModuleSpec)] = []
        for p in screen.modules { if let s = ModuleCatalog.module(p.kind), !mods.contains(where: { $0.p.kind == p.kind }) { mods.append((p, s)) } }
        guard !mods.isEmpty else { return ResolvedScreen(columns: 1, widths: [box.width], modules: [], issues: [.empty]) }

        // A module that fills a screen (the calendar) is alone on it.
        if let ex = mods.first(where: { $0.spec.exclusive }) {
            for m in mods where m.p.kind != ex.p.kind { issues.append(.needsWholePage(m.p.kind, ex.p.kind)) }
            mods = [ex]
        }
        var cols = [mods.filter { $0.p.column == 0 }, mods.filter { $0.p.column != 0 }]
        // A module that needs the whole width takes the screen to its column.
        if !cols[0].isEmpty && !cols[1].isEmpty {
            if let f = cols[0].first(where: { $0.spec.width == .full }) ?? cols[1].first(where: { $0.spec.width == .full }) {
                let keep = cols[0].contains { $0.p.kind == f.p.kind } ? 0 : 1
                for m in cols[1 - keep] { issues.append(.needsWholePage(m.p.kind, f.p.kind)) }
                cols[1 - keep] = []
            }
        }
        // Two modules that need the wide column: the right one gives way.
        if !cols[0].isEmpty && !cols[1].isEmpty, let w0 = cols[0].first(where: { $0.spec.width == .wide }) {
            for m in cols[1] where m.spec.width == .wide { issues.append(.needsWideColumn(m.p.kind, w0.p.kind)) }
            cols[1].removeAll { $0.spec.width == .wide }
        }
        cols = cols.filter { !$0.isEmpty }
        var widths: [CGFloat]
        if cols.count == 1 {
            widths = [box.width]
        } else {
            let wide = box.width - narrowColumn - gutter
            func needsWide(_ c: Int) -> Bool { cols[c].contains { $0.spec.width == .wide } }
            func biggest(_ c: Int) -> Int { cols[c].map { $0.spec.fit($0.p.size).units }.max() ?? 0 }
            // The column with the module that needs room, else the one with the larger module, gets the wide share; on a tie
            // the right one does (the built-in pages: 250 pt on the left, the rest on the right).
            let leftWide = needsWide(0) || (!needsWide(1) && biggest(0) > biggest(1))
            widths = leftWide ? [wide, narrowColumn] : [narrowColumn, wide]
        }

        var out: [ResolvedScreen.Module] = []
        for (c, col) in cols.enumerated() {
            var sizes = col.map { $0.spec.fit($0.p.size) }
            for (k, m) in col.enumerated() where sizes[k] != m.p.size { issues.append(.shrunk(m.p.kind, m.p.size, sizes[k])) }
            var kept = Array(col.indices)
            // Too tall: the lowest module that can be smaller is made smaller; when none can, the lowest is left out.
            while kept.map({ sizes[$0].units }).reduce(0, +) > 6 {
                if let k = kept.last(where: { col[$0].spec.smaller(than: sizes[$0]) != nil }) {
                    let s = col[k].spec.smaller(than: sizes[k])!
                    issues.removeAll { if case .shrunk(let kind, _, _) = $0 { return kind == col[k].p.kind }; return false }
                    issues.append(.shrunk(col[k].p.kind, col[k].p.size, s))
                    sizes[k] = s
                } else {
                    let k = kept.removeLast()
                    issues.removeAll { if case .shrunk(let kind, _, _) = $0 { return kind == col[k].p.kind }; return false }
                    issues.append(.noRoom(col[k].p.kind))
                }
            }
            let x = c == 0 ? 0 : widths[0] + gutter
            let unitH = (box.height - gap * CGFloat(max(0, kept.count - 1))) / 6
            var y: CGFloat = 0
            for k in kept {
                let h = sizes[k] == .l ? box.height : unitH * CGFloat(sizes[k].units)
                out.append(.init(kind: col[k].p.kind, size: sizes[k], column: c, frame: CGRect(x: x, y: y, width: widths[c], height: h)))
                y += h + gap
            }
        }
        return ResolvedScreen(columns: cols.count, widths: widths, modules: out, issues: issues)
    }
}

/// The layout everyone draws from (every island, on every display, and the settings card): one shared value, saved on change.
final class ScreenLayoutStore: ObservableObject {
    static let shared = ScreenLayoutStore()
    @Published private(set) var layout: ScreenLayout
    private let defaults: () -> UserDefaults

    init(defaults: @escaping () -> UserDefaults = { AppDefaults.store }) {
        self.defaults = defaults
        layout = ScreenLayout.decode(defaults().data(forKey: ScreenLayout.key))
    }

    /// Changes the layout through its rules; saves it (or forgets it when it is the standard one again).
    func update(_ change: (inout ScreenLayout) -> Void) {
        var l = layout
        change(&l)
        set(l)
    }

    func set(_ l: ScreenLayout) {
        let clean = l.sanitized()
        guard clean != layout else { return }
        layout = clean
        if clean == .standard { defaults().removeObject(forKey: ScreenLayout.key) }
        else if let d = clean.encoded() { defaults().set(d, forKey: ScreenLayout.key) }
    }

    func restoreDefaults() { set(.standard) }
    var isStandard: Bool { layout == .standard }
}

/// The motion of screens and of their editor, in small named pieces (the app-wide motion pass tunes them in one place).
/// Reduce Motion: no movement, a plain cross-fade at most.
enum ScreensMotion {
    /// A screen replacing another in the open island.
    static var change: Animation? { Motion.reduce ? .easeInOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.88) }
    static var pageTransition: AnyTransition {
        Motion.reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity)
    }
    /// Editing: reordering, showing and hiding, resizing (the preview follows with the same curve).
    static var edit: Animation? { Motion.reduce ? nil : .spring(response: 0.3, dampingFraction: 0.86) }
    static var rowTransition: AnyTransition { Motion.reduce ? .opacity : .opacity.combined(with: .move(edge: .top)) }
}
