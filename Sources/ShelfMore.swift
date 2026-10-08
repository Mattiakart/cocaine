// More of the shelf's group operations: selecting by kind or inverting the selection, sorting a collection (name, date added,
// kind, size), copying the names, sending straight to AirDrop, removing the missing items, and removing everything (asked
// first). Pure parts (ShelfArrange) are tested by --media-test; the menu shows them under the operations (ShelfSheets.swift).

import AppKit
import Foundation
import SwiftUI

enum ShelfArrange {
    enum Sort: String, CaseIterable, Identifiable {
        case name, added, kind, size
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: return L("Name")
            case .added: return L("Date Added")
            case .kind: return L("Kind")
            case .size: return L("Size")
            }
        }
        var symbol: String {
            switch self {
            case .name: return "textformat"
            case .added: return "calendar"
            case .kind: return "square.grid.2x2"
            case .size: return "arrow.up.arrow.down"
            }
        }
    }

    enum Pick: String, CaseIterable, Identifiable {
        case images, files, links, texts, missing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .images: return L("Images")
            case .files: return L("Files and Folders")
            case .links: return L("Links")
            case .texts: return L("Texts")
            case .missing: return L("Missing Items")
            }
        }
        var symbol: String {
            switch self {
            case .images: return "photo"
            case .files: return "doc"
            case .links: return "link"
            case .texts: return "text.alignleft"
            case .missing: return "questionmark.circle"
            }
        }
    }

    /// The order a sort gives: names in Finder's order (numbers by value), oldest added first, by kind then extension then
    /// name, largest first. Ties keep the name order; equal names keep their place.
    static func order(_ items: [ShelfItem], by sort: Sort, size: (ShelfItem) -> Int64 = { _ in 0 },
                      isImage: (ShelfItem) -> Bool = { $0.kind == .image }) -> [UUID] {
        func byName(_ a: ShelfItem, _ b: ShelfItem) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        func rank(_ i: ShelfItem) -> Int {
            switch i.kind { case .file: return isImage(i) ? 1 : 0; case .image: return 1; case .link: return 2; case .text: return 3 }
        }
        let indexed = Array(items.enumerated())
        let sorted = indexed.sorted { x, y in
            let a = x.element, b = y.element
            switch sort {
            case .name:
                let c = a.name.localizedStandardCompare(b.name)
                return c == .orderedSame ? x.offset < y.offset : c == .orderedAscending
            case .added:
                return a.added == b.added ? x.offset < y.offset : a.added < b.added
            case .kind:
                if rank(a) != rank(b) { return rank(a) < rank(b) }
                let ea = (a.name as NSString).pathExtension.lowercased(), eb = (b.name as NSString).pathExtension.lowercased()
                if ea != eb { return ea < eb }
                return byName(a, b) || (!byName(b, a) && x.offset < y.offset)
            case .size:
                let sa = size(a), sb = size(b)
                if sa != sb { return sa > sb }
                return byName(a, b) || (!byName(b, a) && x.offset < y.offset)
            }
        }
        return sorted.map(\.element.id)
    }

    /// The items of one kind (images: dropped pictures and image files).
    static func pick(_ items: [ShelfItem], _ p: Pick, isImage: (ShelfItem) -> Bool) -> [UUID] {
        items.filter { i in
            switch p {
            case .images: return isImage(i)
            case .files: return i.kind == .file && !isImage(i)
            case .links: return i.kind == .link
            case .texts: return i.kind == .text
            case .missing: return i.missing
            }
        }.map(\.id)
    }

    /// The names, one per line (a file's name with its extension; a link's address; a text's first line).
    static func names(_ items: [ShelfItem]) -> String {
        items.map { $0.kind == .link ? ($0.text ?? $0.name) : $0.name }.joined(separator: "\n")
    }

    /// A file's size in bytes (a folder: 0; not there: 0).
    static func fileSize(_ url: URL?) -> Int64 {
        guard let url, let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]), v.isDirectory != true else { return 0 }
        return Int64(v.fileSize ?? 0)
    }
}

extension ShelfSelection {
    /// Everything that wasn't selected, and nothing that was.
    mutating func invert(_ order: [UUID]) {
        let next = Set(order).subtracting(ids)
        ids = next
        let first = order.first { next.contains($0) }
        anchor = first; focus = first
    }

    /// Exactly these.
    mutating func set(_ list: [UUID]) {
        ids = Set(list)
        anchor = list.first; focus = list.first
    }
}

extension ShelfLibrary {
    /// The collection's items in this order (ids not in it are ignored; items not named keep their place at the end).
    mutating func arrange(_ order: [UUID], in id: UUID) {
        guard let k = collections.firstIndex(where: { $0.id == id }) else { return }
        let items = collections[k].items
        let pos = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        collections[k].items = items.enumerated().sorted { a, b in
            (pos[a.element.id] ?? Int.max, a.offset) < (pos[b.element.id] ?? Int.max, b.offset)
        }.map(\.element)
    }
}

extension ShelfCenter {
    func isImageItem(_ i: ShelfItem) -> Bool { i.kind == .image || (i.kind == .file && store.url(of: i).map(ImageTools.isImage) == true) }

    func invertSelection() {
        var s = store.selection
        s.invert(store.items.map(\.id))
        Motion.with(.selection) { store.selection = s }
        takeKeyboard()
    }

    func select(_ p: ShelfArrange.Pick) {
        let ids = ShelfArrange.pick(store.items, p, isImage: isImageItem)
        sheet = nil
        guard !ids.isEmpty else { say("info.circle", L("None on this shelf")); return }
        var s = store.selection
        s.set(ids)
        Motion.with(.selection) { store.selection = s }
        say("checkmark.circle", String(format: L("%d selected"), ids.count))
        takeKeyboard()
    }

    func sort(_ by: ShelfArrange.Sort) {
        let order = ShelfArrange.order(store.items, by: by, size: { [store] in ShelfArrange.fileSize(store.url(of: $0)) }, isImage: isImageItem)
        sheet = nil
        Motion.with(.appear) { store.arrange(order) }
        say("arrow.up.arrow.down", String(format: L("Sorted by %@"), by.title.lowercased(with: Language.locale)))
    }

    func copyNames(_ items: [ShelfItem]) {
        let pb = pasteboard(); pb.clearContents(); pb.setString(ShelfArrange.names(items), forType: .string)
        say("doc.on.clipboard.fill", items.count == 1 ? L("Name copied") : String(format: L("%d names copied"), items.count))
    }

    /// Straight to AirDrop (macOS asks for the device), without going through the Share sheet.
    func airDrop(_ items: [ShelfItem]) {
        guard let s = NSSharingService(named: .sendViaAirDrop) else { fail(L("AirDrop isn't available")); return }
        let things: [Any] = items.filter { !$0.missing }.compactMap { i -> Any? in
            switch i.kind {
            case .file, .image: return store.url(of: i)
            case .link: return i.text.flatMap(URL.init(string:))
            case .text: return nil
            }
        }
        guard !things.isEmpty, s.canPerform(withItems: things) else { fail(L("AirDrop can't send these")); return }
        Sharing.shared.perform(s, things, surface: .island)
    }

    func removeMissing() {
        let ids = Set(store.items.filter(\.missing).map(\.id))
        sheet = nil
        guard !ids.isEmpty else { say("checkmark.circle", L("Nothing is missing")); return }
        Motion.with(.appear) { store.remove(ids) }
        say("minus.circle", String(format: L("%d removed from the shelf"), ids.count))
    }

    /// Everything off this collection (the files stay where they are), after a question when there is more than one item.
    func removeAll(surface: DialogSurface = .island) {
        let n = store.items.count
        sheet = nil
        guard n > 0 else { return }
        let go = { [weak self] in
            guard let self else { return }
            Motion.with(.appear) { self.store.clear() }
            self.say("minus.circle", n == 1 ? L("Removed from the shelf") : String(format: L("%d removed from the shelf"), n))
        }
        guard n > 1 else { go(); return }
        let spec = DialogSpec(icon: "minus.circle", title: String(format: L("Remove all %1$d items from “%2$@”?"), n, store.current.title),
                              message: L("The files themselves stay where they are."),
                              buttons: [DialogButton(id: "remove", title: L("Remove All"), role: .destructive), Dialogs.cancel], surface: surface)
        DialogCenter.shared.present(spec) { r in if r.buttonID == "remove" { go() } }
    }
}

// MARK: - In the actions menu

/// The menu's last sections: select (all, invert, by kind), sort the collection, clear (missing items, everything).
struct ShelfMenuExtras: View {
    @ObservedObject var center: ShelfCenter
    @ObservedObject var store: ShelfStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            title(L("Select"))
            grid([("sel.all", L("Select All"), "checkmark.circle", false, { center.selectAll(); center.sheet = nil }),
                  ("sel.invert", L("Invert Selection"), "circle.lefthalf.filled", false, { center.invertSelection(); center.sheet = nil })]
                 + ShelfArrange.Pick.allCases.map { p in ("pick." + p.rawValue, p.title, p.symbol, false, { center.select(p) }) })
            title(L("Sort by"))
            grid(ShelfArrange.Sort.allCases.map { s in ("sort." + s.rawValue, s.title, s.symbol, false, { center.sort(s) }) })
            title(L("Clear"))
            grid([("clear.missing", L("Remove Missing Items"), "questionmark.circle", false, { center.removeMissing() }),
                  ("clear.all", L("Remove All…"), "minus.circle", true, { center.removeAll() })])
        }
        .padding(.top, 2)
    }

    private func title(_ s: String) -> some View { Text(s).font(UI.section).foregroundStyle(UI.secondary) }

    private func grid(_ rows: [(id: String, title: String, symbol: String, destructive: Bool, action: () -> Void)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s), GridItem(.flexible())],
                  alignment: .leading, spacing: Space.s) {
            ForEach(rows, id: \.id) { r in
                ChoiceRow(title: r.title, leading: .symbol(r.symbol), selectable: false, destructive: r.destructive, lines: 2, font: UI.value, action: r.action)
            }
        }
    }
}
