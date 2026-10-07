// How the shelf is handled with the pointer and the keys: Quick Look (QLPreviewPanel, with the app delegate as its controller),
// dragging several items out at once (an AppKit drag source: one dragging item per item), the tiles' clicks (⇧/⌘, double-click,
// right-click), the island's drop target (files, images, links and text in; items reordered inside the shelf; a drop on a
// collection tab or an instant action), the shelf's keys, and the shake that opens the shelf while dragging.

import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Quick Look

/// The Quick Look panel for the shelf. The panel looks for a controller in the key window's responder chain, which ends with
/// the app delegate (see the extension below); the island is made key first, the app is brought forward so the panel shows in
/// front, and the app that was in front gets the keyboard back when it closes. Arrow keys step through the items, Space closes.
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfQuickLook()
    private(set) var urls: [URL] = []
    private(set) var active = false
    private var start = 0
    private var front: NSRunningApplication?
    private var release: (Bool) -> Void = { _ in }
    private var closeObserver: Any?

    func show(_ urls: [URL], at index: Int, hold: @escaping (Bool) -> Void) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        start = max(0, min(urls.count - 1, index))
        if panel.isVisible && active { panel.reloadData(); panel.currentPreviewItemIndex = start; return }
        active = true
        release = hold
        hold(true)
        front = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if panel.dataSource == nil { panel.dataSource = self; panel.delegate = self }     // no controller found: set it directly
        panel.reloadData()
        panel.currentPreviewItemIndex = start
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in self?.closed() }
        }
    }

    func toggle(_ urls: [URL], at index: Int, hold: @escaping (Bool) -> Void) {
        if let p = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil, p.isVisible { p.orderOut(nil); closed(); return }
        show(urls, at: index, hold: hold)
    }

    private func closed() {
        guard active else { return }
        active = false
        if let o = closeObserver { NotificationCenter.default.removeObserver(o); closeObserver = nil }
        release(false)
        if let f = front, f.processIdentifier != getpid() { f.activate() }
        front = nil
    }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = start
    }

    func end(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil; panel.delegate = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[max(0, min(urls.count - 1, index))] as NSURL }

    /// Space closes the preview (as in Finder); the arrows are the panel's own.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 49 { panel.orderOut(nil); closed(); return true }
        return false
    }

    /// Texts and links are previewed from a private temporary file (0600, in a 0700 folder; replaced at each preview).
    static func preview(text: String, id: UUID) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-shelf-preview-\(getuid())", isDirectory: true)
        let u = dir.appendingPathComponent(id.uuidString + ".txt")
        return SafeFile.writePrivate(Data(text.utf8), to: u) ? u : nil
    }
}

extension AppDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { ShelfQuickLook.shared.active }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { ShelfQuickLook.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { ShelfQuickLook.shared.end(panel) }
}

// MARK: - Dragging out

/// The drag source for shelf items: one NSDraggingItem per item (files as file URLs, links as URLs, texts as strings), so a
/// group drops anywhere at once. Outside Cocaine the receiver decides as Finder does: on the same volume a file is moved (the
/// shelf follows it), on another one copied, ⌥ copies; private images (dropped image data) are only ever copied out.
final class ShelfDragSource: NSObject, NSDraggingSource {
    static let shared = ShelfDragSource()
    /// The items being dragged (the drop target uses it to tell a reorder from new files).
    private(set) var active: [UUID]?
    private var copyOnly = false
    /// The drop target took the drag inside the island (a reorder, or a move to another collection).
    var landedInside = false
    /// The drag ended: the items, the operation the receiver did, whether it was inside the island.
    var ended: ([UUID], NSDragOperation, Bool) -> Void = { _, _, _ in }

    /// What one item puts on the pasteboard.
    static func writer(_ i: ShelfItem, store: ShelfStore) -> NSPasteboardWriting? {
        switch i.kind {
        case .file, .image: return i.missing ? nil : store.url(of: i).map { $0 as NSURL }
        case .link: return i.text.flatMap { URL(string: $0) }.map { $0 as NSURL }
        case .text: return (i.text ?? "") as NSString
        }
    }

    static func operations(outside: Bool, copyOnly: Bool) -> NSDragOperation {
        outside ? (copyOnly ? [.copy] : [.copy, .move, .generic]) : [.move, .copy, .generic]
    }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operations(outside: context == .outsideApplication, copyOnly: copyOnly)
    }

    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        let ids = active ?? []
        active = nil
        ended(ids, operation, landedInside)
        landedInside = false
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }

    /// Starts dragging `items` from `view` (the tile under the pointer), each with its icon, stacked.
    func begin(_ items: [ShelfItem], store: ShelfStore, from view: NSView, event: NSEvent) {
        let list = items.compactMap { i in Self.writer(i, store: store).map { (i, $0) } }
        guard !list.isEmpty else { return }
        let origin = view.convert(event.locationInWindow, from: nil)
        let dragging = list.enumerated().map { n, pair -> NSDraggingItem in
            let d = NSDraggingItem(pasteboardWriter: pair.1)
            let icon = ShelfIcons.image(pair.0, store: store, side: 48)
            let off = CGFloat(min(n, 4)) * 4
            d.setDraggingFrame(NSRect(x: origin.x - 24 + off, y: origin.y - 24 - off, width: 48, height: 48), contents: icon)
            return d
        }
        active = list.map(\.0.id)
        landedInside = false
        copyOnly = list.contains { $0.0.kind == .image }
        let s = view.beginDraggingSession(with: dragging, event: event, source: self)
        s.draggingFormation = .stack
        s.animatesToStartingPositionsOnCancelOrFail = true
    }
}

/// Icons for items: a file's own icon (cached), a symbol for texts and links.
enum ShelfIcons {
    static func image(_ i: ShelfItem, store: ShelfStore, side: CGFloat) -> NSImage {
        switch i.kind {
        case .file, .image:
            if let u = store.url(of: i), !i.missing { return IconCache.icon(u.path) }
            return NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil) ?? NSImage()
        case .link: return NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
        case .text: return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil) ?? NSImage()
        }
    }
}

/// A tile's pointer handling in AppKit (SwiftUI's onDrag gives one item; this gives the whole selection): a click selects (⇧ a
/// range, ⌘ toggles), a double-click opens, a right-click opens the shelf's menu, a drag past 3 pt drags.
struct ShelfMouse: NSViewRepresentable {
    var click: (_ count: Int, _ flags: NSEvent.ModifierFlags) -> Void
    var context: () -> Void
    var drag: (NSView, NSEvent) -> Void

    func makeNSView(context ctx: Context) -> MouseView { let v = MouseView(); v.handlers = self; return v }
    func updateNSView(_ v: MouseView, context ctx: Context) { v.handlers = self }

    final class MouseView: NSView {
        var handlers: ShelfMouse?
        private var down: NSEvent?
        private var dragged = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with e: NSEvent) { down = e; dragged = false }
        override func mouseDragged(with e: NSEvent) {
            guard let d = down, !dragged else { return }
            let a = d.locationInWindow, b = e.locationInWindow
            if hypot(a.x - b.x, a.y - b.y) > 3 { dragged = true; handlers?.drag(self, d) }
        }
        override func mouseUp(with e: NSEvent) {
            defer { down = nil }
            guard !dragged, let d = down else { return }
            handlers?.click(d.clickCount, d.modifierFlags)
        }
        override func rightMouseDown(with e: NSEvent) { handlers?.context() }
        override func isAccessibilityElement() -> Bool { false }
    }
}

// MARK: - Dropping in

/// Where things are in the island, for the drop target (frames in ShelfDrop.space, written by the views as they lay out).
final class ShelfDropTargets {
    static let shared = ShelfDropTargets()
    var tiles: [(id: UUID, frame: CGRect)] = []
    var grid: CGRect = .zero
    var tabs: [UUID: CGRect] = [:]
    var instant: [UUID: CGRect] = [:]
}

enum ShelfDrop {
    static let space = "cocaine.shelf.drop"
    static let types: [UTType] = [.fileURL, .url, .image, .png, .tiff, .utf8PlainText, .plainText]

    /// Where an internal drag lands: before the tile under the pointer (its left half) or after it; past the last tile, at the end.
    static func insertionIndex(at p: CGPoint, tiles: [(id: UUID, frame: CGRect)]) -> Int? {
        guard !tiles.isEmpty else { return nil }
        if let (n, t) = tiles.enumerated().first(where: { $0.element.frame.insetBy(dx: -4, dy: -4).contains(p) }) {
            return ShelfSelection.insertionIndex(over: n, leftHalf: p.x < t.frame.midX)
        }
        // Between rows or after the last tile on its row.
        let rows = tiles.enumerated().filter { p.y >= $0.element.frame.minY - 4 && p.y <= $0.element.frame.maxY + 4 }
        if let last = rows.last(where: { $0.element.frame.maxX <= p.x }) { return last.offset + 1 }
        if let first = rows.first { return first.offset }
        return tiles.count
    }
}

/// The island's drop target (all of it): files open the island on the shelf and land in the current collection, or in the
/// collection tab under the pointer; with ⌥ held, on an instant action, that action runs on them instead. Items dragged inside
/// the shelf are reordered. Images, links and text become items too.
struct ShelfDropDelegate: DropDelegate {
    let model: IslandModel
    var center: ShelfCenter { model.shelfUI }
    var store: ShelfStore { model.shelf }
    var targets: ShelfDropTargets { .shared }

    private var internalDrag: Bool { ShelfDragSource.shared.active != nil }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: ShelfDrop.types) }

    func dropEntered(info: DropInfo) {
        if !model.dropHover { Motion.with(.hover) { model.dropHover = true } }
        if !internalDrag { model.dropTargeted(true) }
        update(info)
    }

    func dropExited(info: DropInfo) {
        Motion.with(.hover) { model.dropHover = false; store.dropIndex = nil; store.dropCollection = nil; center.instantShown = false }
        model.dropTargeted(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: internalDrag ? .move : .copy)
    }

    private func update(_ info: DropInfo) {
        let p = info.location
        let tab = targets.tabs.first { $0.value.contains(p) }?.key
        if store.dropCollection != tab { Motion.with(.hover) { store.dropCollection = tab } }
        let wantsInstant = !internalDrag && center.config.config.instantActions && NSEvent.modifierFlags.contains(.option)
            && center.config.config.actions.contains { $0.instant }
        if center.instantShown != wantsInstant { Motion.with(.appear) { center.instantShown = wantsInstant } }
        let idx = internalDrag && tab == nil && targets.grid.insetBy(dx: -8, dy: -8).contains(p) ? ShelfDrop.insertionIndex(at: p, tiles: targets.tiles) : nil
        if store.dropIndex != idx { Motion.with(.dragSettle) { store.dropIndex = idx } }
    }

    func performDrop(info: DropInfo) -> Bool {
        let p = info.location
        let tab = store.dropCollection
        let index = store.dropIndex
        let instant = center.instantShown ? targets.instant.first { $0.value.contains(p) }?.key : nil
        Motion.with(.hover) { model.dropHover = false; store.dropIndex = nil; store.dropCollection = nil; center.instantShown = false }
        if let ids = ShelfDragSource.shared.active {
            ShelfDragSource.shared.landedInside = true
            let set = Set(ids)
            if let tab, tab != store.library.current { center.store.selection.ids = set; center.moveSelection(to: tab); return true }
            if let index { Motion.with(.dragSettle) { store.reorder(set, to: index) }; Haptic.tap(.alignment) }
            return true
        }
        let providers = info.itemProviders(for: ShelfDrop.types)
        ShelfDropLoader.load(providers) { loaded in
            if let instant, let a = center.config.config.actions.first(where: { $0.id == instant }) {
                let files = loaded.files
                if !files.isEmpty { center.perform(a, files: files) }
                return
            }
            Haptic.tap(.generic)
            loaded.add(to: store, center: center, collection: tab)
        }
        return true
    }
}

/// Reads dropped providers: file URLs; else images, links, texts (one kind per provider, files first).
enum ShelfDropLoader {
    struct Loaded {
        var files: [URL] = []
        var images: [(Data, UTType)] = []
        var links: [URL] = []
        var texts: [String] = []

        func add(to store: ShelfStore, center: ShelfCenter, collection: UUID?) {
            var n = 0, refused = 0
            Motion.with(.appear) {
                let r = store.add(urls: files, to: collection); n += r.added.count; refused += r.refused
                for (d, t) in images { if store.addImage(d, type: t, to: collection) != nil { n += 1 } }
                for l in links { if store.addLink(l, to: collection) != nil { n += 1 } }
                for s in texts { if store.addText(s, to: collection) != nil { n += 1 } }
            }
            center.report(added: n, refused: refused, collection: collection)
        }
    }

    static func load(_ providers: [NSItemProvider], done: @escaping (Loaded) -> Void) {
        var out = Loaded()
        let group = DispatchGroup(), lock = NSLock()
        for p in providers {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil), u.isFileURL { lock.lock(); out.files.append(u); lock.unlock() }
                    else if let u = item as? URL, u.isFileURL { lock.lock(); out.files.append(u); lock.unlock() }
                }
            } else if let t = [UTType.png, .tiff, .jpeg, .heic, .image].first(where: { p.hasItemConformingToTypeIdentifier($0.identifier) }) {
                p.loadDataRepresentation(forTypeIdentifier: t.identifier) { d, _ in
                    defer { group.leave() }
                    if let d, d.count <= ShelfLimits.imageBytes {
                        let type: UTType = t == .image ? .png : t
                        lock.lock(); out.images.append((d, type)); lock.unlock()
                    }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                    defer { group.leave() }
                    if let u = obj as? URL { lock.lock(); if u.isFileURL { out.files.append(u) } else { out.links.append(u) }; lock.unlock() }
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    defer { group.leave() }
                    if let s = obj as? String {
                        lock.lock()
                        if let u = ShelfPaste.link(in: s) { out.links.append(u) } else if s.count <= ShelfLimits.textChars { out.texts.append(s) }
                        lock.unlock()
                    }
                }
            } else { group.leave() }
        }
        group.notify(queue: .main) { done(out) }
    }
}

// MARK: - Keys

/// The shelf's keys while the island has the keyboard and the shelf is shown (pure enough to test: the center and the model's
/// state are handed in). True when the key was used.
enum ShelfKeys {
    static func handle(_ code: UInt16, flags: NSEvent.ModifierFlags, chars: String?, editing: Bool, shown: Bool, center: ShelfCenter) -> Bool {
        guard shown else { return false }
        let store = center.store
        let cmd = flags.contains(.command), shift = flags.contains(.shift)
        if center.sheet == nil, !editing, let a = ShelfActionKeys.action(code, flags: flags, in: center.config.config.actions), !store.items.isEmpty {
            center.perform(a); return true                                                 // ⌥1…⌥9: the user's action keys
        }
        let others = flags.intersection([.control, .option])
        guard others.isEmpty else { return false }
        if let sheet = center.sheet {
            if code == 53 { Motion.with(.dialog) { center.sheet = nil }; return true }     // Esc closes the sheet first (even typing)
            if (code == 36 || code == 76) && !cmd {                                       // Return: the sheet's main button
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.hasMarkedText() { return false }
                switch sheet {
                case .rename: if center.renamePlan(center.renameRule).canApply { center.rename(center.renameRule) }; return true
                case .images: center.images(center.imageJob); return true
                default: return false
                }
            }
            return false
        }
        guard !editing else { return false }
        let order = store.items.map(\.id)
        if cmd {
            switch chars?.lowercased() {
            case "a": center.selectAll(); return true
            case "c": guard !store.selection.isEmpty else { return false }; center.run(.copy); return true
            case "v": center.paste(); return true
            default: break
            }
            if code == 51, !store.selection.isEmpty { center.run(.trash, items: store.selectedItems().filter { $0.kind == .file }); return true }   // ⌘⌫
            return false
        }
        let hasSel = !store.selection.isEmpty
        switch code {
        case 49 where hasSel: center.quickLook(); return true                                 // Space
        case 36 where hasSel, 76 where hasSel: center.run(.open, items: store.selectedItems()); return true   // Return
        case 51 where hasSel, 117 where hasSel: center.run(.remove, items: store.selectedItems()); return true  // ⌫ ⌦
        case 53 where hasSel: center.clearSelection(); return true                             // Esc: the selection first
        case 123 where hasSel, 124 where hasSel, 125 where hasSel, 126 where hasSel:
            let d: ShelfSelection.Direction = code == 123 ? .left : code == 124 ? .right : code == 125 ? .down : .up
            var s = store.selection
            s.move(d, order: order, columns: center.columns, extend: shift)
            Motion.with(.selection) { store.selection = s }
            if let f = s.focus, let it = store.item(f) { A11y.announce(it.name) }
            return true
        default: return false
        }
    }
}

// MARK: - Shake to open

/// A shake while dragging files: at least 3 horizontal turns, each of at least `minTravel` points, within `window` seconds.
struct ShakeDetector {
    var minTravel: CGFloat = 30
    var window: TimeInterval = 0.6
    private var lastX: CGFloat?
    private var dir: CGFloat = 0
    private var travel: CGFloat = 0
    private var turns: [TimeInterval] = []

    mutating func reset() { lastX = nil; dir = 0; travel = 0; turns = [] }

    /// Feeds one pointer position; true once when a shake is complete (then it starts over).
    mutating func feed(x: CGFloat, at t: TimeInterval) -> Bool {
        defer { lastX = x }
        guard let l = lastX else { return false }
        let dx = x - l
        guard abs(dx) > 0.5 else { return false }
        let d: CGFloat = dx > 0 ? 1 : -1
        if d == dir { travel += abs(dx); return false }
        if travel >= minTravel { turns.append(t) }
        dir = d; travel = abs(dx)
        turns = turns.filter { t - $0 <= window }
        if turns.count >= 3 { reset(); return true }
        return false
    }
}
