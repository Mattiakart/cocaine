// The shelf's data: named collections of items (files and folders held by reference, texts, links and images kept in a private
// folder), saved as one JSON file with bookmarks so moved or renamed files are found again. Pure parts (ShelfLibrary's rules,
// ShelfLimits) are what --shelf-test checks; ShelfStore is the observable store the island and the settings draw from.
//
// On disk (ShelfDisk): <support>/Cocaine/shelf/library.json (0600, atomic) and <support>/Cocaine/shelf/items/<id>.<ext> for
// texts' previews and dropped images (0600, folder 0700). Test and render flags (AppDefaults.isolated) keep everything in
// memory unless COCAINE_SUPPORT points at a test folder, so they never touch the user's shelf.

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Sizes the shelf never goes past: a dropped 2 GB text or 100 000 files can't make the island or its file unusable.
enum ShelfLimits {
    static let collections = 40
    static let itemsPerCollection = 500
    static let textChars = 200_000
    static let linkChars = 4_096
    static let imageBytes = 50 << 20
    static let nameChars = 60
    static let libraryBytes = 16 << 20          // a library file larger than this isn't read (set aside)
}

/// One thing on the shelf.
struct ShelfItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case file, text, link, image }
    var id = UUID()
    var kind: Kind
    /// file: the last known absolute path; image: the file's name inside the private items folder.
    var path = ""
    /// file: bookmark data (finds the file again after a move or rename); nil when it couldn't be made.
    var bookmark: Data? = nil
    /// text: the text; link: the URL; image: its title (the name it is dragged out with).
    var text: String? = nil
    var added = Date()
    /// Not saved: the file couldn't be found at the last look (deleted, in the Trash, on a volume that isn't mounted).
    var missing = false

    enum CodingKeys: String, CodingKey { case id, kind, path, bookmark, text, added }

    /// What the item is called in the island and for VoiceOver.
    var name: String {
        switch kind {
        case .file: return (path as NSString).lastPathComponent
        case .image: return text ?? (path as NSString).lastPathComponent
        case .link:
            guard let s = text, let u = URL(string: s), let h = u.host else { return text ?? "" }
            let rest = u.path == "/" ? "" : u.path
            return String((h + rest).prefix(80))
        case .text:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let line = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.count > 60 ? String(line.prefix(59)) + "…" : line
        }
    }

    /// A file on disk this item stands for (files, and images in the private folder).
    var isFileBacked: Bool { kind == .file || kind == .image }
}

/// A named collection ("Shelf" is the first one; any number up to ShelfLimits.collections).
struct ShelfCollection: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Empty: the default name, said in the app's language ("Shelf").
    var name = ""
    var color = 0
    var items: [ShelfItem] = []
    var created = Date()

    var title: String { name.isEmpty ? L("Shelf") : name }
}

/// Everything on the shelf: the collections, in order, and the one shown.
struct ShelfLibrary: Codable, Equatable {
    static let schema = 1
    var v = ShelfLibrary.schema
    var collections: [ShelfCollection]
    var current: UUID

    static func fresh() -> ShelfLibrary {
        let c = ShelfCollection()
        return ShelfLibrary(collections: [c], current: c.id)
    }

    var currentIndex: Int { collections.firstIndex { $0.id == current } ?? 0 }

    /// Only what makes sense: at least one collection, a current one that exists, ids once, sizes within the limits.
    func sanitized() -> ShelfLibrary {
        var seen = Set<UUID>(), seenItems = Set<UUID>()
        var out: [ShelfCollection] = []
        for var c in collections where !seen.contains(c.id) && out.count < ShelfLimits.collections {
            seen.insert(c.id)
            c.name = String(c.name.prefix(ShelfLimits.nameChars))
            c.color = ShelfColors.clamp(c.color)
            c.items = Array(c.items.filter { seenItems.insert($0.id).inserted }.prefix(ShelfLimits.itemsPerCollection))
            out.append(c)
        }
        if out.isEmpty { out = [ShelfCollection()] }
        var l = ShelfLibrary(v: Self.schema, collections: out, current: current)
        if !out.contains(where: { $0.id == current }) { l.current = out[0].id }
        return l
    }

    // MARK: collections (pure)

    enum Problem: Error, Equatable { case tooMany, notFound, lastOne, full(Int) }

    @discardableResult
    mutating func create(name: String, color: Int? = nil) throws -> UUID {
        guard collections.count < ShelfLimits.collections else { throw Problem.tooMany }
        let c = ShelfCollection(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ShelfLimits.nameChars)),
                                color: ShelfColors.clamp(color ?? (collections.count % ShelfColors.count)))
        collections.append(c)
        return c.id
    }

    mutating func rename(_ id: UUID, to name: String) throws {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { throw Problem.notFound }
        collections[i].name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ShelfLimits.nameChars))
    }

    mutating func recolor(_ id: UUID, _ color: Int) throws {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { throw Problem.notFound }
        collections[i].color = ShelfColors.clamp(color)
    }

    /// Deletes a collection (never the last one); the current one moves to its neighbour. Returns the items it held.
    @discardableResult
    mutating func delete(_ id: UUID) throws -> [ShelfItem] {
        guard collections.count > 1 else { throw Problem.lastOne }
        guard let i = collections.firstIndex(where: { $0.id == id }) else { throw Problem.notFound }
        let gone = collections.remove(at: i)
        if current == id { current = collections[min(i, collections.count - 1)].id }
        return gone.items
    }

    /// Moves every item of `from` into `into` (after its own; what is already there by path isn't added twice), then deletes
    /// `from`. Throws when `into` would hold more than the limit (nothing changes then).
    mutating func merge(_ from: UUID, into: UUID) throws {
        guard from != into, let a = collections.firstIndex(where: { $0.id == from }), let b = collections.firstIndex(where: { $0.id == into })
        else { throw Problem.notFound }
        let have = Set(collections[b].items.filter { $0.kind == .file }.map(\.path))
        let moving = collections[a].items.filter { $0.kind != .file || !have.contains($0.path) }
        guard collections[b].items.count + moving.count <= ShelfLimits.itemsPerCollection else { throw Problem.full(ShelfLimits.itemsPerCollection) }
        collections[b].items += moving
        if current == from { current = into }
        collections.remove(at: a)
    }

    /// Moves a collection one place left (-1) or right (+1), or to an index.
    mutating func moveCollection(_ id: UUID, to index: Int) {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return }
        let c = collections.remove(at: i)
        collections.insert(c, at: max(0, min(collections.count, index)))
    }

    // MARK: items (pure)

    /// Appends items to a collection, skipping files already in it (same path). Returns the ids added; throws `full` with how
    /// many fit when not all of them do (those that fit are added).
    @discardableResult
    mutating func append(_ new: [ShelfItem], to id: UUID) -> (added: [UUID], refused: Int) {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return ([], new.count) }
        var paths = Set(collections[i].items.filter { $0.kind == .file }.map(\.path))
        var added: [UUID] = [], refused = 0
        for item in new {
            if item.kind == .file {
                guard paths.insert(item.path).inserted else { continue }      // already there: not twice
            }
            guard collections[i].items.count < ShelfLimits.itemsPerCollection else { refused += 1; continue }
            collections[i].items.append(item)
            added.append(item.id)
        }
        return (added, refused)
    }

    @discardableResult
    mutating func remove(_ ids: Set<UUID>, from id: UUID) -> [ShelfItem] {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return [] }
        let gone = collections[i].items.filter { ids.contains($0.id) }
        collections[i].items.removeAll { ids.contains($0.id) }
        return gone
    }

    /// The items `ids` moved together (in their current order) so they start at `index` of the list as it is now.
    mutating func reorder(_ ids: Set<UUID>, to index: Int, in id: UUID) {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[i].items = ShelfReorder.move(collections[i].items, ids: ids, to: index)
    }

    /// Moves items to another collection (removed from this one).
    mutating func transfer(_ ids: Set<UUID>, from: UUID, to: UUID) -> Int {
        guard from != to, collections.contains(where: { $0.id == to }) else { return 0 }
        let items = remove(ids, from: from)
        let r = append(items, to: to)
        if r.refused > 0, let back = collections.firstIndex(where: { $0.id == from }) {     // what didn't fit goes back
            let kept = Set(r.added)
            collections[back].items += items.filter { !kept.contains($0.id) }
        }
        return r.added.count
    }

    func items(in id: UUID) -> [ShelfItem] { collections.first { $0.id == id }?.items ?? [] }
    func collection(_ id: UUID) -> ShelfCollection? { collections.first { $0.id == id } }
}

/// Reordering a list by ids (pure; the selection and the drop marker use it).
enum ShelfReorder {
    /// The elements whose ids are in `ids`, kept in their order, moved so they start where `index` pointed in the list before
    /// the move (an index past the end appends them).
    static func move<T: Identifiable>(_ list: [T], ids: Set<T.ID>, to index: Int) -> [T] where T.ID: Hashable {
        let moving = list.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return list }
        let before = list.prefix(max(0, min(index, list.count))).filter { !ids.contains($0.id) }.count
        var rest = list.filter { !ids.contains($0.id) }
        rest.insert(contentsOf: moving, at: min(before, rest.count))
        return rest
    }
}

/// The collections' colors (an index is stored; the palette can follow the design).
enum ShelfColors {
    static let palette: [(r: Double, g: Double, b: Double, name: String)] = [
        (0.40, 0.64, 1.00, "Blue"), (0.35, 0.80, 0.50, "Green"), (1.00, 0.62, 0.25, "Orange"), (1.00, 0.45, 0.68, "Pink"),
        (0.70, 0.52, 1.00, "Purple"), (1.00, 0.42, 0.40, "Red"), (0.98, 0.84, 0.30, "Yellow"), (0.62, 0.62, 0.66, "Grey"),
    ]
    static var count: Int { palette.count }
    static func clamp(_ i: Int) -> Int { (0..<count).contains(i) ? i : 0 }
    /// The color's name for VoiceOver (L keys: "Blue", "Green"…).
    static func name(_ i: Int) -> String {
        switch clamp(i) {
        case 0: return L("Blue"); case 1: return L("Green"); case 2: return L("Orange"); case 3: return L("Pink")
        case 4: return L("Purple"); case 5: return L("Red"); case 6: return L("Yellow"); default: return L("Grey")
        }
    }
}

// MARK: - Bookmarks

/// Finding a file again: its bookmark first (follows a move or rename on the same volume), then the last known path.
enum ShelfBookmarks {
    static func make(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    struct Resolved: Equatable { var path: String; var bookmark: Data?; var missing: Bool }

    /// Where the file is now. A file in the Trash counts as missing; a stale bookmark is made again from where it was found.
    static func resolve(path: String, bookmark: Data?, trash: String = ShelfBookmarks.trashPath) -> Resolved {
        if let b = bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: b, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                let p = u.standardizedFileURL.path
                if FileManager.default.fileExists(atPath: p) {
                    if isInTrash(p, trash: trash) { return Resolved(path: p, bookmark: b, missing: true) }
                    let fresh = (stale || p != path) ? (make(u) ?? b) : b
                    return Resolved(path: p, bookmark: fresh, missing: false)
                }
            }
        }
        if FileManager.default.fileExists(atPath: path), !isInTrash(path, trash: trash) {
            return Resolved(path: path, bookmark: bookmark ?? make(URL(fileURLWithPath: path)), missing: false)
        }
        return Resolved(path: path, bookmark: bookmark, missing: true)
    }

    static var trashPath: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").standardizedFileURL.path }
    static func isInTrash(_ p: String, trash: String) -> Bool { p == trash || p.hasPrefix(trash + "/") || p.contains("/.Trashes/") }
}

// MARK: - On disk

/// The shelf's folder: library.json and the private items. `persist` false: nothing is written (renders, tests), the items
/// folder is a temporary one.
struct ShelfDisk {
    let dir: URL
    let persist: Bool
    var library: URL { dir.appendingPathComponent("library.json") }
    var items: URL { dir.appendingPathComponent("items", isDirectory: true) }

    /// The real folder (or COCAINE_SUPPORT/shelf in tests); in memory for test and render flags without COCAINE_SUPPORT.
    static var standard: ShelfDisk {
        if let base = ProcessInfo.processInfo.environment["COCAINE_SUPPORT"], base.hasPrefix("/") {
            return ShelfDisk(dir: URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("shelf", isDirectory: true), persist: true)
        }
        if AppDefaults.isolated { return memory }
        return real
    }
    /// The user's real shelf folder (the command line uses it even though it runs as a flag).
    static var real: ShelfDisk {
        if let base = ProcessInfo.processInfo.environment["COCAINE_SUPPORT"], base.hasPrefix("/") {
            return ShelfDisk(dir: URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("shelf", isDirectory: true), persist: true)
        }
        return ShelfDisk(dir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cocaine/shelf", isDirectory: true), persist: true)
    }
    static var memory: ShelfDisk {
        ShelfDisk(dir: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cocaine-shelf-\(getpid())", isDirectory: true), persist: false)
    }

    enum Loaded: Equatable { case none, ok(ShelfLibrary), unreadable }

    func load() -> Loaded {
        guard persist else { return .none }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: library.path) else { return .none }
        if let size = attrs[.size] as? Int, size > ShelfLimits.libraryBytes { return .unreadable }
        guard let data = try? Data(contentsOf: library) else { return .unreadable }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        guard let l = try? dec.decode(ShelfLibrary.self, from: data), l.v == ShelfLibrary.schema else { return .unreadable }
        return .ok(l.sanitized())
    }

    static func encode(_ l: ShelfLibrary) -> Data? {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        return try? enc.encode(l)
    }

    @discardableResult
    func save(_ data: Data) -> Bool {
        guard persist else { return true }
        return SafeFile.writePrivate(data, to: library)
    }

    /// A damaged library is kept aside (library.json.unreadable-<time>), never deleted: a newer Cocaine or a fix can read it.
    func setAside() {
        guard persist else { return }
        let to = dir.appendingPathComponent("library.json.unreadable-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: library, to: to)
    }

    func ensureItems() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: items.path) {
            try? fm.createDirectory(at: items, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// A new private file for an item (0600 in the 0700 folder).
    func store(_ data: Data, ext: String, id: UUID) -> String? {
        ensureItems()
        let name = id.uuidString + (ext.isEmpty ? "" : "." + ext)
        return SafeFile.writePrivate(data, to: items.appendingPathComponent(name)) ? name : nil
    }

    func url(ofPrivate name: String) -> URL { items.appendingPathComponent((name as NSString).lastPathComponent) }

    /// Removes private files no item refers to any more.
    func removeOrphans(keeping names: Set<String>) {
        guard let list = try? FileManager.default.contentsOfDirectory(atPath: items.path) else { return }
        for n in list where !names.contains(n) && !n.hasPrefix(".") { try? FileManager.default.removeItem(at: items.appendingPathComponent(n)) }
    }
}

// MARK: - The store

/// The shelf the island, the settings and the entry points share. Main thread only.
final class ShelfStore: ObservableObject {
    @Published private(set) var library: ShelfLibrary
    /// The items picked in the current collection (the island's selection).
    @Published var selection = ShelfSelection()
    /// While items are dragged inside the shelf: where they would land (an index in the current collection).
    @Published var dropIndex: Int?
    /// The collection tab a drag is over (drops go into that one).
    @Published var dropCollection: UUID?
    /// Something to say after a load (a damaged file was set aside, the old shelf was brought over).
    @Published private(set) var loadNote: String?
    let disk: ShelfDisk
    private let defaults: UserDefaults
    private let writer = DispatchQueue(label: "local.cocaine.shelf.save", qos: .utility)
    private var lastRefresh = Date.distantPast
    static let legacyKey = "shelf.v1"

    init(disk: ShelfDisk = .standard, defaults: UserDefaults = AppDefaults.store) {
        self.disk = disk
        self.defaults = defaults
        var lib: ShelfLibrary
        var note: String?
        switch disk.load() {
        case .ok(let l): lib = l
        case .unreadable:
            disk.setAside()
            lib = .fresh()
            note = L("The shelf couldn't be read; it was set aside and a new one started")
        case .none: lib = .fresh()
        }
        // The shelf before collections (2.6 and earlier): a list of paths in the settings. Brought over once, whole: files that
        // are gone now stay listed as missing (nothing is dropped without the user seeing it).
        var migrated = false
        if let old = defaults.stringArray(forKey: Self.legacyKey) {
            if case .ok = disk.load() {} else {
                let items = old.prefix(ShelfLimits.itemsPerCollection).map { p -> ShelfItem in
                    let r = ShelfBookmarks.resolve(path: p, bookmark: nil)
                    return ShelfItem(kind: .file, path: r.path, bookmark: r.bookmark, missing: r.missing)
                }
                _ = lib.append(Array(items), to: lib.collections[0].id)
                migrated = true
            }
        }
        library = lib
        loadNote = note
        if migrated {
            // Written synchronously: the old key goes only once the new file is safely there.
            if let data = ShelfDisk.encode(library), disk.save(data), disk.persist { defaults.removeObject(forKey: Self.legacyKey) }
        }
        if disk.persist { disk.removeOrphans(keeping: privateNames) }
        refresh(force: true)
    }

    // MARK: reading

    var current: ShelfCollection { library.collections[library.currentIndex] }
    var items: [ShelfItem] { current.items }
    var collections: [ShelfCollection] { library.collections }
    var isEmpty: Bool { items.isEmpty }

    func item(_ id: UUID) -> ShelfItem? { items.first { $0.id == id } }

    /// The file an item stands for, if it has one.
    func url(of item: ShelfItem) -> URL? {
        switch item.kind {
        case .file: return URL(fileURLWithPath: item.path)
        case .image: return disk.url(ofPrivate: item.path)
        case .text, .link: return nil
        }
    }

    /// The selection, in the collection's order; or every item when nothing is selected and `orAll`.
    func selectedItems(orAll: Bool = false) -> [ShelfItem] {
        let s = selection.ids
        let picked = items.filter { s.contains($0.id) }
        return picked.isEmpty && orAll ? items : picked
    }

    /// The files of these items that are there now (missing ones left out).
    func fileURLs(_ list: [ShelfItem]) -> [URL] { list.filter { $0.isFileBacked && !$0.missing }.compactMap { url(of: $0) } }

    private var privateNames: Set<String> {
        Set(library.collections.flatMap(\.items).filter { $0.kind == .image }.map { ($0.path as NSString).lastPathComponent })
    }

    // MARK: changing (each change is saved)

    private func change(_ body: (inout ShelfLibrary) -> Void) {
        var l = library
        body(&l)
        guard l != library else { return }
        library = l
        selection.prune(Set(items.map(\.id)))
        save()
    }

    private func save() {
        guard disk.persist, let data = ShelfDisk.encode(library) else { return }
        let d = disk
        writer.async { if !d.save(data) { log.error("shelf: couldn't save the library") } }
    }

    /// Waits for the last save (the command line, tests, quitting).
    func flush() { writer.sync {} }

    /// Files and folders by URL into a collection (the current one by default). Returns the ids added and how many didn't fit.
    @discardableResult
    func add(urls: [URL], to collection: UUID? = nil) -> (added: [UUID], refused: Int) {
        let new = urls.filter(\.isFileURL).map { u -> ShelfItem in
            let p = u.standardizedFileURL.path
            return ShelfItem(kind: .file, path: p, bookmark: ShelfBookmarks.make(u))
        }
        return add(items: new, to: collection)
    }

    @discardableResult
    func add(items new: [ShelfItem], to collection: UUID? = nil) -> (added: [UUID], refused: Int) {
        var r: (added: [UUID], refused: Int) = ([], 0)
        let target = collection ?? library.current
        change { r = $0.append(new, to: target) }
        return r
    }

    /// A text item (refused past ShelfLimits.textChars).
    @discardableResult
    func addText(_ s: String, to collection: UUID? = nil) -> UUID? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : s
        guard !t.isEmpty, t.count <= ShelfLimits.textChars else { return nil }
        return add(items: [ShelfItem(kind: .text, text: t)], to: collection).added.first
    }

    /// A web link (http, https, mailto…; not file URLs, which are files).
    @discardableResult
    func addLink(_ u: URL, to collection: UUID? = nil) -> UUID? {
        guard !u.isFileURL, let scheme = u.scheme?.lowercased(), ShelfPaste.linkSchemes.contains(scheme),
              u.absoluteString.count <= ShelfLimits.linkChars else { return nil }
        return add(items: [ShelfItem(kind: .link, text: u.absoluteString)], to: collection).added.first
    }

    /// Image data (dropped or pasted, not a file): kept as a private file in the shelf's folder.
    @discardableResult
    func addImage(_ data: Data, type: UTType, title: String? = nil, to collection: UUID? = nil) -> UUID? {
        guard data.count <= ShelfLimits.imageBytes, !data.isEmpty else { return nil }
        let id = UUID()
        let ext = type.preferredFilenameExtension ?? "png"
        guard let name = disk.store(data, ext: ext, id: id) else { return nil }
        let t = title ?? ShelfPaste.imageTitle(ext: ext)
        let r = add(items: [ShelfItem(id: id, kind: .image, path: name, text: t)], to: collection)
        if r.added.isEmpty { try? FileManager.default.removeItem(at: disk.url(ofPrivate: name)) }
        return r.added.first
    }

    func remove(_ ids: Set<UUID>) {
        var gone: [ShelfItem] = []
        change { gone = $0.remove(ids, from: $0.current) }
        removePrivate(gone)
    }

    func clear() { remove(Set(items.map(\.id))) }

    func reorder(_ ids: Set<UUID>, to index: Int) { change { $0.reorder(ids, to: index, in: $0.current) } }
    /// The current collection in this order (a sort: Sources/ShelfMore.swift).
    func arrange(_ order: [UUID]) { change { $0.arrange(order, in: $0.current) } }

    @discardableResult
    func transfer(_ ids: Set<UUID>, to collection: UUID) -> Int {
        var n = 0
        change { n = $0.transfer(ids, from: $0.current, to: collection) }
        return n
    }

    private func removePrivate(_ gone: [ShelfItem]) {
        let keep = privateNames
        for i in gone where i.kind == .image && !keep.contains(i.path) { try? FileManager.default.removeItem(at: disk.url(ofPrivate: i.path)) }
    }

    // MARK: collections

    func select(_ id: UUID) {
        guard id != library.current, library.collections.contains(where: { $0.id == id }) else { return }
        change { $0.current = id }
        selection = ShelfSelection()
    }

    @discardableResult
    func createCollection(_ name: String, select: Bool = true) -> UUID? {
        var id: UUID?
        change { id = try? $0.create(name: name) }
        if select, let id { self.select(id) }
        return id
    }

    func renameCollection(_ id: UUID, _ name: String) { change { try? $0.rename(id, to: name) } }
    func recolorCollection(_ id: UUID, _ color: Int) { change { try? $0.recolor(id, color) } }
    func moveCollection(_ id: UUID, by step: Int) {
        guard let i = library.collections.firstIndex(where: { $0.id == id }) else { return }
        change { $0.moveCollection(id, to: i + step) }
    }
    @discardableResult
    func deleteCollection(_ id: UUID) -> Bool {
        var gone: [ShelfItem] = [], ok = false
        change { if let g = try? $0.delete(id) { gone = g; ok = true } }
        removePrivate(gone)
        return ok
    }
    @discardableResult
    func merge(_ from: UUID, into: UUID) -> Bool {
        var ok = false
        change { ok = (try? $0.merge(from, into: into)) != nil }
        return ok
    }

    // MARK: following files

    /// Looks again where every file is (bookmarks first): moved files are followed, gone ones marked. Off the main thread; at
    /// most every 2 s unless forced.
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 2 else { return }
        lastRefresh = Date()
        let snapshot = library.collections.flatMap(\.items).filter(\.isFileBacked).map { ($0.id, $0.kind, $0.path, $0.bookmark) }
        guard !snapshot.isEmpty else { return }
        let disk = self.disk
        let work = {
            var found: [UUID: ShelfBookmarks.Resolved] = [:]
            for (id, kind, path, bm) in snapshot {
                if kind == .image {
                    found[id] = ShelfBookmarks.Resolved(path: path, bookmark: nil, missing: !FileManager.default.fileExists(atPath: disk.url(ofPrivate: path).path))
                } else {
                    found[id] = ShelfBookmarks.resolve(path: path, bookmark: bm)
                }
            }
            return found
        }
        if Thread.isMainThread && force && AppDefaults.isolated {        // tests and renders: at once, deterministic
            apply(work())
        } else {
            DispatchQueue.global(qos: .utility).async { let f = work(); DispatchQueue.main.async { self.apply(f) } }
        }
    }

    /// Applies a refresh: paths and bookmarks that changed are saved; the missing marks only drawn.
    func apply(_ found: [UUID: ShelfBookmarks.Resolved]) {
        var l = library
        var saveNeeded = false
        for c in l.collections.indices {
            for i in l.collections[c].items.indices {
                guard let r = found[l.collections[c].items[i].id] else { continue }
                var it = l.collections[c].items[i]
                if it.kind == .file && (it.path != r.path || it.bookmark != r.bookmark) { it.path = r.path; it.bookmark = r.bookmark; saveNeeded = true }
                it.missing = r.missing
                l.collections[c].items[i] = it
            }
        }
        guard l != library || saveNeeded else {
            // Equality ignores nothing but `missing` is part of ==: covered above.
            return
        }
        library = l
        if saveNeeded { save() }
    }

    /// A file of the shelf was renamed or moved by Cocaine itself: the item follows at once.
    func noteMoved(_ id: UUID, to url: URL) {
        change { l in
            for c in l.collections.indices {
                if let i = l.collections[c].items.firstIndex(where: { $0.id == id }) {
                    l.collections[c].items[i].path = url.standardizedFileURL.path
                    l.collections[c].items[i].bookmark = ShelfBookmarks.make(url)
                    l.collections[c].items[i].missing = false
                }
            }
        }
    }

    /// Tests and renders: replaces the whole library.
    func replace(_ l: ShelfLibrary) { library = l.sanitized(); selection = ShelfSelection(); save() }
}

/// Reading what was dropped or pasted: files, images, links, text (in that order of preference).
enum ShelfPaste {
    static let linkSchemes: Set<String> = ["http", "https", "mailto", "ftp", "ftps", "sms", "tel", "facetime", "maps"]
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]

    static func imageTitle(ext: String, date: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return String(format: L("Image %@"), f.string(from: date)) + "." + ext
    }

    /// One pasteboard's contents as shelf items to add (files first; then one image; then a link or a text).
    enum Content: Equatable { case files([URL]), image(Data, String), link(URL), text(String), nothing }

    static func read(_ pb: NSPasteboard) -> Content {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        for t in imageTypes {
            if let d = pb.data(forType: t), !d.isEmpty {
                let ut = UTType(t.rawValue) ?? .png
                return .image(d, ut.identifier)
            }
        }
        if let s = pb.string(forType: .string) {
            if let u = link(in: s) { return .link(u) }
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(s) }
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let u = urls.first, !u.isFileURL { return .link(u) }
        return .nothing
    }

    /// A text that is just one link (one line, a known scheme) is a link item.
    static func link(in s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= ShelfLimits.linkChars, !t.contains(where: { $0.isWhitespace }),
              let u = URL(string: t), let scheme = u.scheme?.lowercased(), linkSchemes.contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" { guard u.host?.isEmpty == false else { return nil } }
        return u
    }

    /// Adds a pasteboard's contents to the store. Returns how many items were added (0: nothing usable).
    @discardableResult
    static func add(_ pb: NSPasteboard, to store: ShelfStore, collection: UUID? = nil) -> Int {
        switch read(pb) {
        case .files(let u): return store.add(urls: u, to: collection).added.count
        case .image(let d, let t): return store.addImage(d, type: UTType(t) ?? .png, to: collection) == nil ? 0 : 1
        case .link(let u): return store.addLink(u, to: collection) == nil ? 0 : 1
        case .text(let s): return store.addText(s, to: collection) == nil ? 0 : 1
        case .nothing: return 0
        }
    }

    /// Writes items to a pasteboard (⌘C, the drag's contents): files as file URLs, links as URLs, texts as strings.
    static func write(_ items: [ShelfItem], store: ShelfStore, to pb: NSPasteboard) -> Bool {
        let objects: [NSPasteboardWriting] = items.compactMap { i in
            switch i.kind {
            case .file, .image: return i.missing ? nil : store.url(of: i).map { $0 as NSURL }
            case .link: return (i.text.flatMap { URL(string: $0) }).map { $0 as NSURL }
            case .text: return (i.text ?? "") as NSString
            }
        }
        guard !objects.isEmpty else { return false }
        pb.clearContents()
        return pb.writeObjects(objects)
    }
}
