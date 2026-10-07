// --shelf-test: the shelf's rules and engines on temporary folders and generated files (never the user's shelf, clipboard,
// Trash or settings): collections and their file (migration, bookmarks after a move/rename/delete, limits, private files),
// selection and reordering, batch rename (conflicts, unicode, undo), ZIP, image tools, text recognition (skipped, said so, when
// Vision can't run), watched folders (rules, batching, partial downloads), custom actions (argv with hostile names, approval,
// timeout, environment), the drag source's pasteboard, the keys, the shake, the command line, the Info.plist entry points.
// Also the render fixtures (--render-island --shelf-fixture <name>).

import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ShelfTests {
    static func run() -> Int {
        _ = NSApplication.shared
        precondition(AppDefaults.isolated, "tests run with memory-only settings (main.swift)")
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  shelf: " + name); if !ok { failed += 1 } }
        func skip(_ name: String, _ why: String) { print("SKIP  shelf: \(name) (\(why))") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cocaine-shelf-test-\(getpid())-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func dir(_ name: String) -> URL { let d = root.appendingPathComponent(name, isDirectory: true); try? fm.createDirectory(at: d, withIntermediateDirectories: true); return d }
        func file(_ d: URL, _ name: String, _ text: String = "x") -> URL { let u = d.appendingPathComponent(name); try? Data(text.utf8).write(to: u); return u }
        func mode(_ u: URL) -> Int { ((try? fm.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }

        library(check)
        selection(check)
        storeAndDisk(check, dir: dir, file: file, mode: mode)
        pasteboards(check, dir: dir, file: file)
        rename(check, dir: dir, file: file)
        zip(check, dir: dir, file: file)
        images(check, skip, dir: dir)
        ocr(check, skip, dir: dir)
        watching(check, dir: dir, file: file)
        actions(check, dir: dir, file: file)
        entryPoints(check, dir: dir, file: file)
        interaction(check, dir: dir, file: file)
        print(failed == 0 ? "PASS  shelf: all" : "shelf: \(failed) failed")
        return failed
    }

    // MARK: collections (pure)

    static func library(_ check: (String, Bool) -> Void) {
        var l = ShelfLibrary.fresh()
        check("a new shelf has one collection, the default 'Shelf', shown", l.collections.count == 1 && l.collections[0].name.isEmpty && l.current == l.collections[0].id
              && l.collections[0].title == L("Shelf"))
        let a = try! l.create(name: "  Work  ")
        let b = try! l.create(name: String(repeating: "x", count: 200), color: 99)
        check("create: trimmed name, bounded length, colour in range", l.collection(a)?.name == "Work" && l.collection(b)?.name.count == ShelfLimits.nameChars && l.collection(b)?.color == 0)
        try? l.rename(a, to: "Projects"); try? l.recolor(a, 3)
        check("rename and recolour", l.collection(a)?.name == "Projects" && l.collection(a)?.color == 3)
        let f1 = ShelfItem(kind: .file, path: "/tmp/a"), f2 = ShelfItem(kind: .file, path: "/tmp/b"), dup = ShelfItem(kind: .file, path: "/tmp/a")
        let r = l.append([f1, f2, dup, ShelfItem(kind: .text, text: "hi")], to: a)
        check("append: a file already in the collection isn't added twice; texts are", r.added.count == 3 && l.items(in: a).count == 3)
        l.current = a
        l.reorder([f2.id], to: 0, in: a)
        check("reorder: an item moved to the front", l.items(in: a).map(\.path).prefix(2) == ["/tmp/b", "/tmp/a"])
        check("ShelfReorder: several, kept in order, to the end", ShelfReorder.move([1, 2, 3, 4, 5].map(Num.init), ids: [1, 3], to: 99).map(\.id) == [2, 4, 5, 1, 3])
        check("ShelfReorder: several to the front, index counted before the move", ShelfReorder.move([1, 2, 3, 4, 5].map(Num.init), ids: [4, 5], to: 1).map(\.id) == [1, 4, 5, 2, 3])
        check("ShelfReorder: dropped where they already are: no change", ShelfReorder.move([1, 2, 3].map(Num.init), ids: [2], to: 1).map(\.id) == [1, 2, 3])
        // merge: b's items join a; a file of b already in a isn't doubled; b goes; the current follows
        _ = l.append([ShelfItem(kind: .file, path: "/tmp/a"), ShelfItem(kind: .file, path: "/tmp/c")], to: b)
        l.current = b
        try? l.merge(b, into: a)
        check("merge: items join (no duplicates), the merged collection goes, the current one follows",
              l.collection(b) == nil && l.items(in: a).count == 4 && l.current == a)
        let moved = l.transfer([f1.id], from: a, to: l.collections[0].id)
        check("transfer: items move to another collection", moved == 1 && l.items(in: l.collections[0].id).contains { $0.id == f1.id } && !l.items(in: a).contains { $0.id == f1.id })
        let first = l.collections[0].id
        l.moveCollection(a, to: 0)
        check("collections reorder", l.collections[0].id == a && l.collections[1].id == first)
        _ = try? l.delete(a)
        check("delete: the current one moves to a neighbour", l.collection(a) == nil && l.current == first)
        check("the last collection can't be deleted", (try? l.delete(first)) == nil && l.collections.count == 1)
        var m = ShelfLibrary.fresh()
        for i in 0..<(ShelfLimits.collections - 1) { _ = try? m.create(name: "c\(i)") }
        check("at most \(ShelfLimits.collections) collections", m.collections.count == ShelfLimits.collections && (try? m.create(name: "one more")) == nil)
        var big = ShelfLibrary.fresh()
        let many = (0..<(ShelfLimits.itemsPerCollection + 7)).map { ShelfItem(kind: .file, path: "/tmp/f\($0)") }
        let rb = big.append(many, to: big.current)
        check("a collection holds at most \(ShelfLimits.itemsPerCollection) items: the rest are refused and counted",
              big.items(in: big.current).count == ShelfLimits.itemsPerCollection && rb.refused == 7)
        var full = ShelfLibrary.fresh(); let other = try! full.create(name: "o")
        _ = full.append(many.prefix(ShelfLimits.itemsPerCollection).map { $0 }, to: full.current)
        _ = full.append([ShelfItem(kind: .text, text: "t")], to: other)
        check("merge into a full collection is refused and changes nothing", (try? full.merge(other, into: full.current)) == nil && full.collection(other) != nil)
        // sanitize: ids once, a current that exists, an empty list becomes the default
        let c = ShelfCollection(name: "x")
        let bad = ShelfLibrary(collections: [c, c], current: UUID())
        let s = bad.sanitized()
        check("sanitized: duplicate collections dropped, the current one exists", s.collections.count == 1 && s.current == c.id)
        check("sanitized: no collection at all becomes the default one", ShelfLibrary(collections: [], current: UUID()).sanitized().collections.count == 1)
        check("item names: a link shows host and path, a text its first line, bounded",
              ShelfItem(kind: .link, text: "https://example.com/a/b?q=1").name == "example.com/a/b"
              && ShelfItem(kind: .text, text: "\n  first line\nsecond").name == "first line"
              && ShelfItem(kind: .text, text: String(repeating: "w", count: 300)).name.count == 60)
        check("colours: names for VoiceOver, out-of-range indexes clamp", ShelfColors.name(1) == L("Green") && ShelfColors.clamp(-3) == 0 && ShelfColors.clamp(7) == 7)
    }

    struct Num: Identifiable { let id: Int; init(_ i: Int) { id = i } }

    // MARK: selection

    static func selection(_ check: (String, Bool) -> Void) {
        let ids = (0..<8).map { _ in UUID() }
        var s = ShelfSelection()
        s.click(ids[2], order: ids, shift: false, command: false)
        check("click selects one item, anchors and focuses it", s.ids == [ids[2]] && s.anchor == ids[2] && s.focus == ids[2])
        s.click(ids[5], order: ids, shift: true, command: false)
        check("⇧-click selects the range from the anchor", s.ids == Set(ids[2...5]) && s.anchor == ids[2])
        s.click(ids[0], order: ids, shift: true, command: false)
        check("⇧-click the other way: the range is from the same anchor", s.ids == Set(ids[0...2]))
        s.click(ids[7], order: ids, shift: false, command: true)
        check("⌘-click adds one", s.ids == Set(ids[0...2]).union([ids[7]]) && s.anchor == ids[7])
        s.click(ids[1], order: ids, shift: false, command: true)
        check("⌘-click again removes it", !s.ids.contains(ids[1]) && s.ids.count == 3)
        s.click(ids[5], order: ids, shift: true, command: true)
        check("⌘⇧-click adds the range (from the anchor) to the selection", s.ids.isSuperset(of: Set(ids[1...5])) && s.ids.contains(ids[0]) && s.ids.contains(ids[7]))
        s.selectAll(ids)
        check("⌘A selects everything", s.ids == Set(ids))
        s.click(ids[1], order: ids, shift: false, command: false)
        s.move(.right, order: ids, columns: 3, extend: false)
        check("→ moves the focus and the selection", s.ids == [ids[2]] && s.focus == ids[2])
        s.move(.down, order: ids, columns: 3, extend: false)
        check("↓ moves a row down (3 columns)", s.focus == ids[5])
        s.move(.down, order: ids, columns: 3, extend: false)
        check("↓ on the last row stays", s.focus == ids[5])
        s.move(.left, order: ids, columns: 3, extend: true)
        check("⇧← extends from the anchor", s.ids == Set([ids[4], ids[5]]) && s.focus == ids[4])
        s.move(.up, order: ids, columns: 3, extend: true)
        check("⇧↑ extends a row up", s.ids == Set(ids[1...5]))
        var e = ShelfSelection()
        e.move(.left, order: ids, columns: 3, extend: false)
        check("an arrow with nothing selected picks the last item for ←", e.ids == [ids.last!])
        var band = ShelfSelection()
        band.band([ids[1], ids[2]], base: [ids[6]], additive: false)
        check("rubber band: what it touches", band.ids == Set([ids[1], ids[2]]))
        band.band([ids[2], ids[3]], base: [ids[2], ids[6]], additive: true)
        check("rubber band with ⌘/⇧: toggles against what was selected", band.ids == Set([ids[3], ids[6]]))
        var p = ShelfSelection(); p.selectAll(ids)
        p.prune(Set(ids.prefix(3)))
        check("prune: only items still there stay selected", p.ids == Set(ids.prefix(3)))
        check("insertion index: left half before, right half after", ShelfSelection.insertionIndex(over: 3, leftHalf: true) == 3 && ShelfSelection.insertionIndex(over: 3, leftHalf: false) == 4)
        let tiles = (0..<4).map { (ids[$0], CGRect(x: CGFloat($0) * 70, y: 0, width: 66, height: 54)) }
        check("drop marker: over tile 2's left half → 2, right half → 3, past the row's end → 4",
              ShelfDrop.insertionIndex(at: CGPoint(x: 145, y: 20), tiles: tiles) == 2 && ShelfDrop.insertionIndex(at: CGPoint(x: 200, y: 20), tiles: tiles) == 3
              && ShelfDrop.insertionIndex(at: CGPoint(x: 400, y: 20), tiles: tiles) == 4)
    }

    // MARK: the store and its file

    static func storeAndDisk(_ check: (String, Bool) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL, mode: (URL) -> Int) {
        let fm = FileManager.default
        let home = dir("disk")
        let disk = ShelfDisk(dir: home.appendingPathComponent("shelf"), persist: true)
        let files = dir("files")
        let a = file(files, "a.txt", "a"), b = file(files, "b report.pdf", "b"), c = file(files, "c.png", "c")
        let defaults = MemoryDefaults()
        let s1 = ShelfStore(disk: disk, defaults: defaults)
        s1.add(urls: [a, b, c])
        s1.addText("hello")
        s1.addLink(URL(string: "https://example.com/x")!)
        let png = makePNG(width: 8, height: 8, text: nil)
        let imgID = s1.addImage(png, type: .png)
        let w = s1.createCollection("Work")!
        s1.add(urls: [a], to: w)
        s1.flush()
        check("the library is written atomically, private (0600 in a 0700 folder)", mode(disk.library) == 0o600 && mode(disk.dir) == 0o700)
        let imgItem = s1.collections.flatMap(\.items).first { $0.id == imgID }
        let imgURL = imgItem.flatMap { s1.url(of: $0) }
        check("a dropped image is kept as a private file (0600, items folder 0700)", imgURL.map { mode($0) == 0o600 } == true && mode(disk.items) == 0o700)
        let s2 = ShelfStore(disk: disk, defaults: defaults)
        check("read back: the same collections and items, the same current one", s2.library.collections.map(\.items.count) == s1.library.collections.map(\.items.count)
              && s2.library.current == w && s2.collections.count == 2)
        // bookmarks: a renamed file and a file moved to another folder are found again; a deleted one is marked missing
        s2.select(s2.collections[0].id)
        let moved = files.appendingPathComponent("a renamed.txt")
        try? fm.moveItem(at: a, to: moved)
        let sub = files.appendingPathComponent("sub"); try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try? fm.moveItem(at: b, to: sub.appendingPathComponent("b report.pdf"))
        try? fm.removeItem(at: c)
        s2.refresh(force: true)
        let paths = s2.items.filter { $0.kind == .file }.map(\.path)
        check("a renamed file is followed (bookmark)", paths.contains(moved.standardizedFileURL.path))
        check("a file moved to another folder is followed", paths.contains(sub.appendingPathComponent("b report.pdf").standardizedFileURL.path))
        check("a deleted file stays listed, marked missing", s2.items.first { $0.path.hasSuffix("c.png") }?.missing == true)
        check("missing files aren't handed to operations", !s2.fileURLs(s2.items).contains { $0.lastPathComponent == "c.png" })
        s2.flush()
        let s3 = ShelfStore(disk: disk, defaults: defaults)
        check("the new place is saved", s3.collections[0].items.contains { $0.path == moved.standardizedFileURL.path })
        // the Trash counts as gone
        let fakeTrash = dir("Trash")
        let t = file(fakeTrash, "gone.txt", "g")
        let rt = ShelfBookmarks.resolve(path: t.path, bookmark: ShelfBookmarks.make(t), trash: fakeTrash.standardizedFileURL.path)
        check("a file in the Trash counts as missing", rt.missing)
        // removing an image item removes its private file; orphans are cleaned at load
        if let id = imgID, let u = imgURL {
            s3.select(s3.collections[0].id)
            s3.remove([id])
            check("removing an image removes its private file", !fm.fileExists(atPath: u.path))
        }
        let orphan = disk.items.appendingPathComponent("orphan.png"); try? Data([1]).write(to: orphan)
        s3.flush()
        _ = ShelfStore(disk: disk, defaults: defaults)
        check("private files no item uses are removed at load", !fm.fileExists(atPath: orphan.path))
        // limits on texts and links
        check("a text past the limit is refused", s3.addText(String(repeating: "a", count: ShelfLimits.textChars + 1)) == nil)
        check("an empty text is refused", s3.addText("   \n") == nil)
        check("a javascript: link is refused", s3.addLink(URL(string: "javascript:alert(1)")!) == nil)
        check("a file URL isn't a link", s3.addLink(URL(fileURLWithPath: "/etc/hosts")) == nil)
        check("a huge image is refused", s3.addImage(Data(count: ShelfLimits.imageBytes + 1), type: .png) == nil)
        // migration of the old shelf ("shelf.v1": paths only), without losing the ones that are gone
        let mhome = dir("migrate")
        let mdisk = ShelfDisk(dir: mhome.appendingPathComponent("shelf"), persist: true)
        let keep = file(files, "kept.txt", "k")
        let old = MemoryDefaults()
        old.set([keep.path, "/no/such/file.txt"], forKey: ShelfStore.legacyKey)
        let ms = ShelfStore(disk: mdisk, defaults: old)
        check("migration: the old shelf's files are in the default collection, a gone one marked missing",
              ms.items.count == 2 && ms.items[0].path == keep.standardizedFileURL.path && ms.items[1].missing && ms.items[0].bookmark != nil)
        check("migration: written to the new file, then the old key removed", fm.fileExists(atPath: mdisk.library.path) && old.stringArray(forKey: ShelfStore.legacyKey) == nil)
        let mem = MemoryDefaults(); mem.set([keep.path], forKey: ShelfStore.legacyKey)
        let ts = ShelfStore(disk: ShelfDisk(dir: dir("memdisk"), persist: false), defaults: mem)
        check("in memory (tests, renders): migrated for show, the old key kept", ts.items.count == 1 && mem.stringArray(forKey: ShelfStore.legacyKey) != nil)
        // a damaged file is set aside, never deleted
        let dhome = dir("damaged"); let ddisk = ShelfDisk(dir: dhome, persist: true)
        try? Data("{not json".utf8).write(to: ddisk.library)
        let ds = ShelfStore(disk: ddisk, defaults: MemoryDefaults())
        let aside = (try? fm.contentsOfDirectory(atPath: dhome.path))?.contains { $0.hasPrefix("library.json.unreadable-") } ?? false
        check("a damaged library is set aside and a fresh one starts (with a note)", aside && ds.collections.count == 1 && ds.loadNote != nil)
        let huge = dir("huge"); let hdisk = ShelfDisk(dir: huge, persist: true)
        fm.createFile(atPath: hdisk.library.path, contents: Data(count: ShelfLimits.libraryBytes + 1))
        check("a library file past the size limit isn't read", hdisk.load() == .unreadable)
        let v2 = dir("newer"); let vdisk = ShelfDisk(dir: v2, persist: true)
        try? Data(#"{"v":2,"collections":[],"current":"6B29FC40-CA47-1067-B31D-00DD010662DA"}"#.utf8).write(to: vdisk.library)
        check("a library from a newer Cocaine isn't read as this one's", vdisk.load() == .unreadable)
        let m2 = ShelfDisk(dir: dir("m2"), persist: false)
        _ = m2.save(Data("{}".utf8))
        check("in memory nothing is written", !fm.fileExists(atPath: m2.library.path) && m2.load() == .none)
        // COCAINE_SUPPORT moves the folder (tests); isolated flags without it stay in memory
        let saved = getenv("COCAINE_SUPPORT").map { String(cString: $0) }
        setenv("COCAINE_SUPPORT", home.path, 1)
        check("COCAINE_SUPPORT moves the shelf's folder", ShelfDisk.standard.dir.path == home.appendingPathComponent("shelf").path && ShelfDisk.standard.persist)
        unsetenv("COCAINE_SUPPORT")
        check("test and render flags keep the shelf in memory", !ShelfDisk.standard.persist)
        check("the real folder is Application Support/Cocaine/shelf", ShelfDisk.real.dir.path.hasSuffix("Application Support/Cocaine/shelf"))
        if let saved { setenv("COCAINE_SUPPORT", saved, 1) }
    }

    // MARK: pasteboards

    static func pasteboards(_ check: (String, Bool) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        let pb = NSPasteboard(name: NSPasteboard.Name("local.cocaine.shelf-test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let d = dir("pb")
        let f = file(d, "doc one.txt", "1"), g = file(d, "two.txt", "2")
        pb.clearContents(); pb.writeObjects([f as NSURL, g as NSURL])
        check("paste: files", ShelfPaste.read(pb) == .files([f, g]))
        pb.clearContents(); pb.setData(makePNG(width: 4, height: 4, text: nil), forType: .png)
        if case .image(_, let t) = ShelfPaste.read(pb) { check("paste: image data", t == UTType.png.identifier) } else { check("paste: image data", false) }
        pb.clearContents(); pb.setString("  https://example.com/page  ", forType: .string)
        check("paste: a text that is one link is a link", ShelfPaste.read(pb) == .link(URL(string: "https://example.com/page")!))
        pb.clearContents(); pb.setString("see https://example.com", forType: .string)
        check("paste: a sentence with a link is text", ShelfPaste.read(pb) == .text("see https://example.com"))
        pb.clearContents(); pb.setString("javascript:alert(1)", forType: .string)
        check("paste: a javascript: text isn't a link", ShelfPaste.read(pb) == .text("javascript:alert(1)"))
        check("links: only known schemes, http needs a host", ShelfPaste.link(in: "http://") == nil && ShelfPaste.link(in: "mailto:a@b.c") != nil && ShelfPaste.link(in: "file:///etc/passwd") == nil)
        let store = ShelfStore(disk: ShelfDisk(dir: dir("pbstore"), persist: false), defaults: MemoryDefaults())
        store.add(urls: [f]); store.addText("note"); store.addLink(URL(string: "https://example.com")!)
        check("copy: files as file URLs, links as URLs, texts as strings", ShelfPaste.write(store.items, store: store, to: pb)
              && (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) == [f]
              && (pb.pasteboardItems?.count ?? 0) == 3 && (pb.pasteboardItems?.contains { $0.string(forType: .string) == "note" } ?? false))
        // the drag source writes the same, one dragging item per shelf item
        let writers = store.items.compactMap { ShelfDragSource.writer($0, store: store) }
        pb.clearContents(); pb.writeObjects(writers)
        check("drag source: one pasteboard item per shelf item (files, links, texts)", writers.count == 3 && pb.pasteboardItems?.count == 3
              && pb.pasteboardItems?.first?.types.contains(.fileURL) == true)
        check("drag source: Finder decides move/copy outside; private images are copy only",
              ShelfDragSource.operations(outside: true, copyOnly: false) == [.copy, .move, .generic] && ShelfDragSource.operations(outside: true, copyOnly: true) == .copy)
        var missing = store.items[0]; missing.missing = true
        check("drag source: a missing file isn't dragged", ShelfDragSource.writer(missing, store: store) == nil)
    }

    // MARK: rename

    static func rename(_ check: (String, Bool) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        let day = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21
        var r = RenameRule()
        check("rename: nothing asked, nothing changes", RenameEngine.newName("a.txt", index: 0, rule: r, date: day) == "a.txt" && r.isIdentity)
        r.find = "IMG"; r.replace = "Trip"
        check("find/replace (case doesn't matter), the extension untouched", RenameEngine.newName("img_001.JPG", index: 0, rule: r, date: day) == "Trip_001.JPG")
        r = RenameRule(); r.prefix = "2026 "; r.suffix = " final"
        check("prefix and suffix around the name", RenameEngine.newName("report.pdf", index: 0, rule: r, date: day) == "2026 report final.pdf")
        r = RenameRule(); r.numbering = true; r.start = 9; r.digits = 3
        check("numbering with padding", RenameEngine.newName("a.png", index: 2, rule: r, date: day) == "a 011.png")
        r.numberPlace = .before; r.separator = "-"
        check("numbering before", RenameEngine.newName("a.png", index: 0, rule: r, date: day) == "009-a.png")
        r = RenameRule(); r.date = .before
        check("the date before the name", RenameEngine.newName("a.png", index: 0, rule: r, date: day).hasPrefix("2026-09-2"))
        r.dateFormat = "yyyy/MM'/../'dd"
        check("a date format that could add a slash falls back to yyyy-MM-dd", !RenameEngine.newName("a.png", index: 0, rule: r, date: day).contains("/"))
        r = RenameRule(); r.letterCase = .upper
        check("letter case: upper (the extension as it was)", RenameEngine.newName("ünïcode name.txt", index: 0, rule: r, date: day) == "ÜNÏCODE NAME.txt")
        r.letterCase = .title
        check("letter case: title", RenameEngine.newName("hello world.md", index: 0, rule: r, date: day) == "Hello World.md")
        r = RenameRule(); r.newBase = "Photo"; r.numbering = true
        check("a new name for all, numbered", RenameEngine.newName("IMG_1.heic", index: 0, rule: r, date: day) == "Photo 01.heic")
        r = RenameRule(); r.suffix = "-v2"
        check("a folder keeps its whole name as the base", RenameEngine.newName("my.folder", index: 0, rule: r, date: day, isFolder: true) == "my.folder-v2")
        check("names: / and : refused, a leading dot refused, too long refused, control characters refused",
              RenameEngine.problem("a/b") != nil && RenameEngine.problem("a:b") != nil && RenameEngine.problem(".hidden") != nil
              && RenameEngine.problem(String(repeating: "é", count: 200)) != nil && RenameEngine.problem("a\nb") != nil && RenameEngine.problem("ok name.txt") == nil)
        // on disk
        let d = dir("rename")
        let a = file(d, "a.txt", "A"), b = file(d, "b.txt", "B"), c = file(d, "c.txt", "C")
        _ = file(d, "taken.txt", "T")
        var swap = RenameRule(); swap.find = "a"; swap.replace = "TMPX"
        let p1 = RenameEngine.plan([a], rule: { var x = RenameRule(); x.newBase = "taken"; return x }(), dates: [day])
        check("a name already taken in the folder is a conflict; nothing can be applied", p1.conflicts == 1 && !p1.canApply)
        var same = RenameRule(); same.newBase = "same"
        let p2 = RenameEngine.plan([a, b], rule: same, dates: [day, day])
        check("two files given one name: both conflicts", p2.conflicts == 2 && !p2.canApply)
        // a swap: a → b and b → a, through temporary names
        let swapPlan = RenameEngine.Plan(rows: [RenameEngine.Row(from: a, to: b, status: .ok), RenameEngine.Row(from: b, to: a, status: .ok)])
        let swapped = RenameEngine.apply(swapPlan)
        check("a swap (a ↔ b) works and overwrites nothing", swapped.failed.isEmpty && (try? String(contentsOf: a, encoding: .utf8)) == "B" && (try? String(contentsOf: b, encoding: .utf8)) == "A")
        let swapBack = RenameEngine.undo(swapped)
        check("undo puts the names back", swapBack.failed.isEmpty && (try? String(contentsOf: a, encoding: .utf8)) == "A")
        // the plan sees that b's name is free when b itself is renamed in the batch
        var shift = RenameRule(); shift.newBase = "x"; shift.numbering = true; shift.start = 1; shift.digits = 1
        let p3 = RenameEngine.plan([a, b, c], rule: shift, dates: [day, day, day])
        check("a batch plan with numbering: all ok", p3.canApply && p3.changes == 3)
        let done = RenameEngine.apply(p3)
        check("applied: x 1/2/3 exist, the old names don't", done.moved.count == 3 && ["x 1.txt", "x 2.txt", "x 3.txt"].allSatisfy { FileManager.default.fileExists(atPath: d.appendingPathComponent($0).path) }
              && !FileManager.default.fileExists(atPath: a.path))
        let undone = RenameEngine.undo(done)
        check("undo of the batch", undone.moved.count == 3 && FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: c.path))
        // case only, and unicode: NFD vs NFC is the same name on the Mac's volumes
        var upper = RenameRule(); upper.letterCase = .upper
        let p4 = RenameEngine.plan([a], rule: upper, dates: [day])
        let caseDone = RenameEngine.apply(p4)
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        check("a case-only rename (a.txt → A.txt) works", p4.canApply && caseDone.failed.isEmpty && listing.contains("A.txt") && !listing.contains("a.txt"))
        let nfd = file(d, "Cafe\u{301}.txt", "nfd")
        _ = file(d, "other.txt", "o")
        var toNFC = RenameRule(); toNFC.newBase = "Caf\u{E9}"
        let p5 = RenameEngine.plan([d.appendingPathComponent("other.txt")], rule: toNFC, dates: [day])
        check("unicode: 'Café' (composed) conflicts with 'Café' (decomposed) already there", p5.conflicts == 1)
        let p6 = RenameEngine.plan([nfd], rule: { var x = RenameRule(); x.suffix = " é"; return x }(), dates: [day])
        check("unicode names rename fine", RenameEngine.apply(p6).failed.isEmpty)
        // never overwrite: even if the plan was wrong, moveItem refuses and the file goes back
        let x1 = file(d, "keep me.txt", "K"), x2 = file(d, "victim.txt", "V")
        let forced = RenameEngine.Plan(rows: [RenameEngine.Row(from: x1, to: x2, status: .ok)])
        let r2 = RenameEngine.apply(forced)
        check("a rename onto an existing file never overwrites it (the file goes back)", !r2.failed.isEmpty && (try? String(contentsOf: x2, encoding: .utf8)) == "V"
              && (try? String(contentsOf: x1, encoding: .utf8)) == "K")
        _ = swap
    }

    // MARK: ZIP

    static func zip(_ check: (String, Bool) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        let d = dir("zip"), other = dir("zip-other")
        let one = file(d, "one file.txt", "hello"), two = file(d, "two.txt", "world"), clash = file(other, "two.txt", "clash")
        check("zip: a folder keeps its name (--keepParent); several items don't", ZipTool.arguments(source: one, out: d.appendingPathComponent("o.zip"), keepParent: true).contains("--keepParent")
              && !ZipTool.arguments(source: d, out: d.appendingPathComponent("o.zip"), keepParent: false).contains("--keepParent"))
        check("zip names: one item, several (Archive.zip)", ZipTool.name(for: [one]) == "one file.txt.zip" && ZipTool.name(for: [one, two]) == L("Archive") + ".zip")
        do {
            let out = try ZipTool.zip([one, two, clash], to: ZipTool.destination(for: [one, two, clash]))
            let x = dir("unzip")
            let r = ShelfProc.run("/usr/bin/ditto", ["-x", "-k", out.path, x.path])
            let list = Set((try? FileManager.default.contentsOfDirectory(atPath: x.path)) ?? [])
            check("zip of several files: all at the top level, a clashing name made distinct", r.ok && list == ["one file.txt", "two.txt", "two 2.txt"])
            let again = ZipTool.destination(for: [one, two])
            check("the next archive doesn't overwrite the first (Archive 2.zip)", again.lastPathComponent == L("Archive") + " 2.zip")
            let single = try ZipTool.zip([one], to: ZipTool.destination(for: [one]))
            let y = dir("unzip1")
            _ = ShelfProc.run("/usr/bin/ditto", ["-x", "-k", single.path, y.path])
            check("zip of one file: just that file in it", ((try? FileManager.default.contentsOfDirectory(atPath: y.path)) ?? []) == ["one file.txt"])
            let folder = dir("zip-folder"); _ = file(folder, "inner.txt", "i")
            let fz = try ZipTool.zip([folder], to: ZipTool.destination(for: [folder]))
            let z = dir("unzip2")
            _ = ShelfProc.run("/usr/bin/ditto", ["-x", "-k", fz.path, z.path])
            check("zip of one folder: the folder in it, by name", FileManager.default.fileExists(atPath: z.appendingPathComponent("zip-folder/inner.txt").path) && fz.lastPathComponent == "zip-folder.zip")
        } catch { check("zip: \(error)", false) }
        let t = CancelToken(); t.cancel()
        check("zip: cancelled before it starts throws and leaves nothing", (try? ZipTool.zip([one, two], to: d.appendingPathComponent("c.zip"), cancel: t)) == nil
              && !FileManager.default.fileExists(atPath: d.appendingPathComponent("c.zip").path))
        let moved = ShelfFiles.transfer([one], into: other, move: false)
        check("copy to a folder: keep both names, never overwrite", moved.done.count == 1 && moved.problem == nil)
        let again = ShelfFiles.transfer([clash], into: d, move: true)
        check("move to a folder with the same name there: 'two 2.txt'", again.done.first?.to.lastPathComponent == "two 2.txt" && !FileManager.default.fileExists(atPath: clash.path))
        var trashed: [URL] = []
        let tr = ShelfFiles.trash([one], using: { trashed.append($0) })
        check("trash uses the given mover (tests never touch the real Trash)", tr.done == [one] && trashed == [one])
        check("copy paths: one per line; quoted for a shell", ShelfFiles.paths([URL(fileURLWithPath: "/a b/it's")], quoted: true) == "'/a b/it'\\''s'")
    }

    // MARK: images

    static func images(_ check: (String, Bool) -> Void, _ skip: (String, String) -> Void, dir: (String) -> URL) {
        let d = dir("images")
        let src = d.appendingPathComponent("photo.jpg")
        writeJPEG(width: 400, height: 200, gps: true, to: src)
        func size(_ u: URL) -> (Int, Int)? {
            guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return nil }
            return (p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
        func hasGPS(_ u: URL) -> Bool {
            guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return false }
            return p[kCGImagePropertyGPSDictionary] != nil
        }
        check("fixture JPEG has GPS metadata", hasGPS(src))
        check("target size: width, percent, longest side, never larger", ImageTools.targetMaxSide(.width(100), width: 400, height: 200) == 100
              && ImageTools.targetMaxSide(.percent(50), width: 400, height: 200) == 200 && ImageTools.targetMaxSide(.maxSide(1000), width: 400, height: 200) == nil
              && ImageTools.targetMaxSide(.width(100), width: 200, height: 400) == 200)
        do {
            let w = try ImageTools.process(src, job: ImageJob(resize: .width(100)))
            check("resize by width: 100×50, named photo-100.jpg, metadata kept", size(w).map { $0 == (100, 50) } == true && w.lastPathComponent == "photo-100.jpg" && hasGPS(w))
            let p = try ImageTools.process(src, job: ImageJob(resize: .percent(25), format: .png))
            check("resize by percent and convert to PNG", size(p).map { $0 == (100, 50) } == true && p.pathExtension == "png")
            let up = try ImageTools.process(src, job: ImageJob(resize: .maxSide(5000), format: .tiff))
            check("never upscaled; TIFF written", size(up).map { $0 == (400, 200) } == true && up.pathExtension == "tiff")
            let clean = try ImageTools.process(src, job: ImageJob(stripMetadata: true))
            check("strip metadata: no GPS, same size, a new file", !hasGPS(clean) && size(clean).map { $0 == (400, 200) } == true && clean != src)
            let again = try ImageTools.process(src, job: ImageJob(resize: .width(100)))
            check("a second run doesn't overwrite the first (photo-100 2.jpg)", again.lastPathComponent == "photo-100 2.jpg")
            if ImageTools.canHEIC {
                let h = try ImageTools.process(src, job: ImageJob(format: .heic, quality: 0.5))
                check("HEIC written (this Mac can encode it)", h.pathExtension == "heic" && size(h).map { $0 == (400, 200) } == true)
            } else {
                skip("HEIC", "this Mac has no HEIC encoder: the format isn't offered")
                check("HEIC isn't offered without an encoder", !ImageTools.formats.contains(.heic))
            }
            // replacing: the original goes to the (fake) Trash, the new file takes its name
            let rep = d.appendingPathComponent("replace me.jpg")
            writeJPEG(width: 300, height: 300, gps: false, to: rep)
            let bin = dir("fake-trash")
            let out = try ImageTools.process(rep, job: ImageJob(resize: .width(30), replace: true), trash: { u in try FileManager.default.moveItem(at: u, to: bin.appendingPathComponent(u.lastPathComponent)) })
            check("replace originals: the original in the Trash, the new one under its name", out.lastPathComponent == "replace me.jpg" && size(out).map { $0 == (30, 30) } == true
                  && FileManager.default.fileExists(atPath: bin.appendingPathComponent("replace me.jpg").path))
            let conv = d.appendingPathComponent("conv.jpg"); writeJPEG(width: 20, height: 10, gps: false, to: conv)
            let co = try ImageTools.process(conv, job: ImageJob(format: .png, replace: true), trash: { u in try FileManager.default.moveItem(at: u, to: bin.appendingPathComponent(u.lastPathComponent)) })
            check("replace with another format: conv.png, the JPEG in the Trash", co.lastPathComponent == "conv.png" && !FileManager.default.fileExists(atPath: conv.path))
            let pdf = try ImageTools.makePDF([src, p], to: d.appendingPathComponent("photos.pdf"))
            check("create PDF: one page per image", PDFDocument(url: pdf)?.pageCount == 2)
            let st = try ImageTools.stitch([src, src], vertical: true, to: d.appendingPathComponent("stitched.png"))
            check("stitch vertically: one image as tall as both", size(st).map { $0 == (400, 400) } == true)
            let sh = try ImageTools.stitch([src, p], vertical: false, to: d.appendingPathComponent("side.png"))
            check("stitch side by side: scaled to the same height", size(sh).map { $0.1 == 200 && $0.0 == 800 } == true)
        } catch { check("image tools: \(error)", false) }
        let junk = d.appendingPathComponent("not an image.png"); try? Data("nope".utf8).write(to: junk)
        check("a file that isn't an image fails with a message", (try? ImageTools.process(junk, job: ImageJob(resize: .width(10)))) == nil)
        check("FileNames.unique: name 2, name 3", FileNames.unique(URL(fileURLWithPath: "/x/a.txt"), exists: { $0 == "/x/a.txt" || $0 == "/x/a 2.txt" }).lastPathComponent == "a 3.txt")
    }

    // MARK: text recognition

    static func ocr(_ check: (String, Bool) -> Void, _ skip: (String, String) -> Void, dir: (String) -> URL) {
        let ordered = TextRecognition.order([(CGRect(x: 0.6, y: 0.8, width: 0.2, height: 0.05), "world"), (CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05), "hello"),
                                             (CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05), "second")])
        check("reading order: top to bottom, left to right on a line", ordered == "hello world\nsecond")
        let d = dir("ocr")
        let u = d.appendingPathComponent("text.png")
        try? makePNG(width: 900, height: 220, text: "COCAINE SHELF 2026").write(to: u)
        do {
            let s = try TextRecognition.recognize(url: u)
            if s.isEmpty { skip("text recognition", "Vision returned nothing here (no recognition model on this machine?)") }
            else { check("OCR reads the generated image ('\(s.prefix(40))')", s.uppercased().contains("COCAINE") && s.contains("2026")) }
        } catch { skip("text recognition", "Vision isn't available here: \(error.localizedDescription)") }
        let pdfURL = d.appendingPathComponent("text.pdf")
        let doc = PDFDocument(); if let img = NSImage(contentsOf: u), let page = PDFPage(image: img) { doc.insert(page, at: 0) }
        _ = doc.write(to: pdfURL)
        do {
            let s = try TextRecognition.recognize(url: pdfURL)
            if s.isEmpty { skip("OCR of a PDF page", "Vision returned nothing") } else { check("OCR of a scanned PDF's first page", s.uppercased().contains("SHELF")) }
        } catch { skip("OCR of a PDF page", error.localizedDescription) }
        check("languages: the user's first, then English", TextRecognition.languages(preferred: ["it-IT", "en-US"]).first?.hasPrefix("it") ?? false)
    }

    // MARK: watched folders

    static func watching(_ check: (String, Bool) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        check("partial downloads are never taken", ["a.crdownload", "b.download", "c.part", ".hidden", "~$doc.docx", "x.icloud", "y.opdownload"].allSatisfy(WatchMatch.isPartial)
              && !WatchMatch.isPartial("photo.png"))
        let png = FileFacts(name: "Shot.PNG"), pdf = FileFacts(name: "report final.pdf"), shot = FileFacts(name: "x.png", isScreenshot: true), folder = FileFacts(name: "Stuff", isDirectory: true)
        check("rule: extension list (case and dots don't matter)", WatchMatch.matches(WatchRule(field: .ext, value: ".png, jpg"), png) && !WatchMatch.matches(WatchRule(field: .ext, value: "jpg"), png))
        check("rule: kind", WatchMatch.matches(WatchRule(field: .kind, value: "image"), png) && WatchMatch.matches(WatchRule(field: .kind, value: "pdf"), pdf)
              && WatchMatch.matches(WatchRule(field: .kind, value: "folder"), folder) && !WatchMatch.matches(WatchRule(field: .kind, value: "image"), folder))
        check("rule: name contains / starts / ends (without the extension)", WatchMatch.matches(WatchRule(field: .nameContains, value: "FINAL"), pdf)
              && WatchMatch.matches(WatchRule(field: .nameStarts, value: "report"), pdf) && WatchMatch.matches(WatchRule(field: .nameEnds, value: "final"), pdf))
        check("rule: screenshot, and 'not'", WatchMatch.matches(WatchRule(field: .screenshot), shot) && WatchMatch.matches(WatchRule(field: .screenshot, negate: true), png))
        var f = WatchedFolder(path: "/x", rules: [WatchRule(field: .kind, value: "image"), WatchRule(field: .nameContains, value: "shot")])
        check("all rules (AND)", WatchMatch.accepts(png, folder: f) && !WatchMatch.accepts(FileFacts(name: "a.png"), folder: f))
        f.matchAll = false
        check("any rule (OR)", WatchMatch.accepts(FileFacts(name: "a.png"), folder: f) && WatchMatch.accepts(FileFacts(name: "my shot.txt"), folder: f) && !WatchMatch.accepts(pdf, folder: f))
        check("no rules: every new file, never a partial one", WatchMatch.accepts(pdf, folder: WatchedFolder(path: "/x")) && !WatchMatch.accepts(FileFacts(name: "a.part"), folder: WatchedFolder(path: "/x")))
        // batching
        var b = WatchBatcher(delay: 2)
        b.observe("/a", size: 10, now: 0); b.observe("/b", size: 5, now: 1)
        check("batch: not before the folder has been quiet for the delay", b.due(now: 2.5) == nil)
        check("batch: files arriving together land together, in order", b.due(now: 3.1) == ["/a", "/b"] && b.isEmpty)
        b.observe("/c", size: 1, now: 10); b.observe("/c", size: 2, now: 11.5)
        check("batch: a file still growing holds the batch", b.due(now: 12.6) == nil && b.due(now: 13.6) == ["/c"])
        var g = WatchBatcher(delay: 2); g.maxWait = 5
        for t in stride(from: 0.0, through: 6, by: 1) { g.observe("/g", size: Int64(t * 10), now: t) }
        check("batch: a file that never stops growing still lands after the longest wait", g.due(now: 6) == ["/g"])
        var h = WatchBatcher(delay: 1); h.observe("/x", size: 1, now: 0); h.forget("/x")
        check("batch: a file gone before it landed is forgotten", h.due(now: 5) == nil)
        // a real folder: new files after the watch began, partial ones ignored until renamed into place
        let d = dir("watched")
        _ = file(d, "old.txt", "already there")
        var now: TimeInterval = 0
        let w = FolderWatcher(WatchedFolder(path: d.path, rules: [WatchRule(field: .ext, value: "txt, png")], delay: 1), clock: { now })
        var got: [URL] = []
        w.onBatch = { got += $0 }
        check("watching a folder starts", w.start() == .watching)
        _ = file(d, "new.txt", "n"); _ = file(d, "skip.jpg", "j"); let part = file(d, "big.png.crdownload", "p")
        w.scanNow(); now = 0.5; w.tickNow()
        check("nothing lands before the batch delay", got.isEmpty)
        try? FileManager.default.moveItem(at: part, to: d.appendingPathComponent("big.png"))
        w.scanNow(); now = 3; w.tickNow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check("the batch: new matching files (a finished download included), not the old one or other kinds",
              Set(got.map(\.lastPathComponent)) == ["new.txt", "big.png"])
        w.stop()
        check("a folder that isn't there: 'missing'", FolderWatcher(WatchedFolder(path: d.appendingPathComponent("nope").path)).start() == .missing)
        let locked = dir("locked"); chmod(locked.path, 0o000)
        let lockedState = FolderWatcher(WatchedFolder(path: locked.path)).start()
        chmod(locked.path, 0o755)
        check("a folder that can't be read: 'denied' (the permission state shown)", lockedState == .denied)
        // the screenshot flag macOS writes
        let s = file(d, "anything.png", "s")
        let flag = try! PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        _ = flag.withUnsafeBytes { setxattr(s.path, Screenshots.attribute, $0.baseAddress, flag.count, 0, 0) }
        check("screenshots: the flag macOS writes (kMDItemIsScreenCapture) is read", Screenshots.isScreenshot(s) && Screenshots.flag(s) == true)
        check("screenshots: else by macOS's names", Screenshots.isScreenshot(file(d, "Schermata 2026-10-07 alle 10.00.00.png", "x")) && !Screenshots.isScreenshot(file(d, "holiday.png", "x")))
        check("screenshot preset: a 'Screenshots only' rule", WatchedFolder.screenshots().rules.first?.field == .screenshot && WatchedFolder.screenshots().preset == .screenshots)
        // settings: bounded, unknown delays fixed, damaged data gives the defaults
        var cfg = ShelfConfig()
        cfg.watched = (0..<20).map { _ in WatchedFolder(path: "/x", delay: 7) }
        let sane = cfg.sanitized()
        check("settings: at most \(ShelfConfig.maxWatched) folders, a delay that isn't offered becomes 2 s", sane.watched.count == ShelfConfig.maxWatched && sane.watched[0].delay == 2)
        check("settings: unreadable data gives the defaults", ShelfConfig.decode(Data("garbage".utf8)) == ShelfConfig())
        let store = ShelfConfigStore(defaults: { MemoryDefaults() })
        store.update { $0.shakeToOpen = true }
        check("settings store: a change is kept", store.config.shakeToOpen)
    }

    // MARK: custom actions

    static func actions(_ check: (String, Bool) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        let d = dir("actions")
        let hostile = ["plain.txt", "with space.txt", "quote ' \" .txt", "$(touch PWNED).txt", "`id`.txt", "-rf", "--version", "new\nline.txt", "semi;colon&amp|pipe.txt", "ünï 字.txt"]
        let files = hostile.map { file(d, $0, "h") }
        let script = d.appendingPathComponent("print args.sh")
        try? Data("#!/bin/zsh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done\nprintf 'ENV:%s|%s|%s\\0' \"$PATH\" \"${COCAINE_SUPPORT-unset}\" \"${DYLD_INSERT_LIBRARIES-unset}\"\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        var a = ShelfAction(name: "Print", kind: .shell, target: script.path, output: .clipboard)
        let cmd = try? ShelfActionEngine.command(a, files: files)
        check("shell: the script runs itself, each file its own argument, exactly as named", cmd?.path == script.path && cmd?.args == files.map { $0.standardizedFileURL.path })
        check("every file argument is absolute (no leading dash reaches the script as an option)", cmd?.args.allSatisfy { $0.hasPrefix("/") } == true)
        let plain = d.appendingPathComponent("not executable.sh"); try? Data("echo hi".utf8).write(to: plain); chmod(plain.path, 0o644)
        let c2 = try? ShelfActionEngine.command(ShelfAction(name: "x", kind: .shell, target: plain.path), files: [files[0]])
        check("a script without +x is read by zsh: script path, then the files", c2?.path == "/bin/zsh" && c2?.args == [plain.path, files[0].standardizedFileURL.path])
        let sc = try? ShelfActionEngine.command(ShelfAction(name: "s", kind: .shortcut, target: "Resize"), files: Array(files.prefix(2)), outputFile: URL(fileURLWithPath: "/tmp/o.txt"))
        check("Shortcut: shortcuts run <name> --input-path <file>… --output-path", sc?.path == "/usr/bin/shortcuts"
              && sc?.args == ["run", "Resize", "--input-path", files[0].path, "--input-path", files[1].path, "--output-path", "/tmp/o.txt"])
        check("Shortcut: a name that is empty or starts with a dash is refused", ShelfActionEngine.check(ShelfAction(name: "s", kind: .shortcut, target: "-h")) == .badName
              && ShelfActionEngine.check(ShelfAction(name: "s", kind: .shortcut, target: "  ")) == .badName)
        let wf = d.appendingPathComponent("Flow.workflow"); try? FileManager.default.createDirectory(at: wf.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try? Data("<plist/>".utf8).write(to: wf.appendingPathComponent("Contents/document.wflow"))
        let au = try? ShelfActionEngine.command(ShelfAction(name: "w", kind: .automator, target: wf.path), files: Array(files.prefix(2)))
        check("Automator: the files on stdin, one per line", au?.args == ["-i", "-", wf.path] && au?.stdin == Data((files[0].path + "\n" + files[1].path).utf8))
        var newline: Error?
        do { _ = try ShelfActionEngine.command(ShelfAction(name: "w", kind: .automator, target: wf.path), files: [files[7]]) } catch { newline = error }
        check("Automator: a name with a line break is refused (it would split)", (newline as? ShelfActionEngine.Problem).map { if case .newlineInName = $0 { return true }; return false } == true)
        let js = file(d, "act.js", "function run(argv) { return argv.length }")
        let jx = try? ShelfActionEngine.command(ShelfAction(name: "j", kind: .applescript, target: js.path), files: [files[3]])
        check("JavaScript for Automation: osascript -l JavaScript <script> <files>", jx?.args == ["-l", "JavaScript", js.path, files[3].path])
        check("an action whose file is gone is refused", ShelfActionEngine.check(ShelfAction(name: "x", kind: .shell, target: d.appendingPathComponent("gone.sh").path)) != nil
              && ShelfActionEngine.check(ShelfAction(name: "x", kind: .shell, target: "relative.sh")) != nil)
        // approval: never runs before the user said yes; a changed script asks again
        check("a new script needs the user's yes", ShelfActionEngine.needsApproval(a))
        var refused: Error?
        do { _ = try ShelfActionEngine.run(a, files: files) } catch { refused = error }
        check("run without approval is refused (nothing runs)", (refused as? ShelfActionEngine.Problem) == .notApproved && !FileManager.default.fileExists(atPath: d.appendingPathComponent("PWNED).txt").path))
        a.approved = ShelfActionEngine.fingerprint(a)
        check("approved: no question", !ShelfActionEngine.needsApproval(a))
        if let o = try? ShelfActionEngine.run(a, files: files) {
            let parts = o.output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            check("the script gets every hostile name intact, as one argument each (\(parts.count - 1) args)", Array(parts.prefix(files.count)) == files.map(\.path))
            check("nothing in a file name was run as code", !FileManager.default.fileExists(atPath: d.appendingPathComponent("PWNED).txt").path)
                  && !((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).contains("PWNED")
                  && !FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/PWNED"))
            let env = parts.first { $0.hasPrefix("ENV:") } ?? ""
            check("the program's environment: a plain PATH, none of Cocaine's overrides", env.hasPrefix("ENV:/usr/bin:/bin:/usr/sbin:/sbin|unset|unset"))
        } else { check("running the approved script", false) }
        try? Data("#!/bin/zsh\necho changed\n".utf8).write(to: script)
        check("a script changed after the yes asks again", ShelfActionEngine.needsApproval(a))
        let sleeper = d.appendingPathComponent("sleep.sh"); try? Data("#!/bin/zsh\nsleep 10\n".utf8).write(to: sleeper); chmod(sleeper.path, 0o755)
        var sl = ShelfAction(name: "slow", kind: .shell, target: sleeper.path, timeout: 1); sl.approved = ShelfActionEngine.fingerprint(sl)
        let t0 = Date()
        let o2 = try? ShelfActionEngine.run(sl, files: [])
        check("a script past its timeout is stopped", o2?.timedOut == true && Date().timeIntervalSince(t0) < 6)
        let tok = CancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { tok.cancel() }
        let o3 = try? ShelfActionEngine.run({ var x = sl; x.timeout = 30; return x }(), files: [], cancel: tok)
        check("Cancel stops a running script", o3?.cancelled == true)
        let failing = d.appendingPathComponent("fail.sh"); try? Data("#!/bin/zsh\necho oops >&2\nexit 3\n".utf8).write(to: failing); chmod(failing.path, 0o755)
        var fa = ShelfAction(name: "fail", kind: .shell, target: failing.path); fa.approved = ShelfActionEngine.fingerprint(fa)
        let o4 = try? ShelfActionEngine.run(fa, files: [])
        check("a failing script: not ok, its error kept", o4?.ok == false && o4?.errors == "oops")
        check("a Shortcut is approved by its name", ShelfActionEngine.fingerprint(ShelfAction(name: "s", kind: .shortcut, target: "Resize")) == "shortcut:Resize")
        check("Open with and Move to run no code: no question", !ShelfActionEngine.needsApproval(ShelfAction(name: "o", kind: .openWith, target: "/System/Applications/TextEdit.app")))
        let dest = dir("action-dest")
        let mv = try? ShelfActionEngine.run(ShelfAction(name: "m", kind: .moveTo, target: dest.path), files: [files[0]])
        check("Move to a folder: the file moves (where to is reported, so the shelf follows)", mv?.ok == true && mv?.movedTo.first?.to.deletingLastPathComponent().standardizedFileURL == dest.standardizedFileURL)
        let opened = try? ShelfActionEngine.run(ShelfAction(name: "o", kind: .openWith, target: "/System/Applications/TextEdit.app"), files: [files[1]], open: { _, _ in true })
        check("Open with uses the given opener (tests never launch an app)", opened?.ok == true)
        check("at most \(ShelfActionEngine.maxFiles) files at a time", (try? ShelfActionEngine.command(a, files: Array(repeating: files[0], count: ShelfActionEngine.maxFiles + 1))) == nil)
    }

    // MARK: entry points

    static func entryPoints(_ check: (String, Bool) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        let info = Bundle.main.infoDictionary ?? [:]
        if Bundle.main.bundlePath.hasSuffix(".app") {
            let services = info["NSServices"] as? [[String: Any]] ?? []
            let svc = services.first { $0["NSMessage"] as? String == "addToShelf" }
            check("Info.plist: a Services entry 'Add to Cocaine Shelf' for files, text, links and images",
                  (svc?["NSMenuItem"] as? [String: String])?["default"] == "Add to Cocaine Shelf" && (svc?["NSSendFileTypes"] as? [String])?.contains("public.item") == true
                  && (svc?["NSSendTypes"] as? [String])?.contains("public.utf8-plain-text") == true && svc?["NSPortName"] as? String == "Cocaine")
            let docs = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
            check("Info.plist: opens any item as a viewer of rank None (never the default app)", docs.count == 1 && docs[0]["CFBundleTypeRole"] as? String == "Viewer"
                  && docs[0]["LSHandlerRank"] as? String == "None" && (docs[0]["LSItemContentTypes"] as? [String]) == ["public.item"])
            let schemes = ((info["CFBundleURLTypes"] as? [[String: Any]])?.first?["CFBundleURLSchemes"] as? [String]) ?? []
            check("Info.plist: still only the cocaine: scheme (no shelf verbs reachable from the web)", schemes == ["cocaine"])
        } else { print("SKIP  shelf: Info.plist keys (not running from the app bundle)") }
        check("the services provider answers addToShelf:userData:error:", ShelfServices.shared.responds(to: NSSelectorFromString("addToShelf:userData:error:")))
        // the provider adds a pasteboard's files to the shelf
        let d = dir("entry")
        let f = file(d, "from service.txt", "s")
        let center = ShelfCenter(store: ShelfStore(disk: ShelfDisk(dir: dir("entrystore"), persist: false), defaults: MemoryDefaults()), config: ShelfConfigStore(defaults: { MemoryDefaults() }))
        let saved = ShelfEntry.center
        ShelfEntry.center = center
        let pb = NSPasteboard(name: NSPasteboard.Name("local.cocaine.shelf-test.svc.\(UUID().uuidString)"))
        pb.clearContents(); pb.writeObjects([f as NSURL])
        var err: NSString?
        ShelfServices.shared.addToShelf(pb, userData: nil, error: &err)
        check("Services: the files land on the shelf", center.store.items.map(\.path) == [f.standardizedFileURL.path] && err == nil)
        ShelfEntry.openFiles([file(d, "opened.txt", "o"), URL(fileURLWithPath: "/no/such/file")])
        check("open -a Cocaine <files>: existing files land on the shelf, the others are ignored", center.store.items.count == 2)
        pb.releaseGlobally()
        ShelfEntry.center = saved
        // the command line
        let cwd = d.path
        let p = ShelfCLI.paths(["from service.txt", "/no/such", d.appendingPathComponent("opened.txt").path], cwd: cwd)
        check("cli add: relative paths from the current folder; missing ones reported", p.ok == [f.standardizedFileURL.path, d.appendingPathComponent("opened.txt").standardizedFileURL.path] && p.missing == ["/no/such"])
        check("cli add: `open -g -a <this app> <paths>`", ShelfCLI.openArguments(bundle: "/Applications/Cocaine.app", paths: ["/a b"]) == ["-g", "-a", "/Applications/Cocaine.app", "/a b"])
        var lib = ShelfLibrary.fresh()
        _ = lib.append([ShelfItem(kind: .file, path: "/x/y.txt"), ShelfItem(kind: .text, text: "line one\nline\ttwo")], to: lib.current)
        check("cli list: one line per item, tabs and line breaks flattened", ShelfCLI.lines(lib, all: false) == ["\(L("Shelf"))\tfile\t/x/y.txt", "\(L("Shelf"))\ttext\tline one line two"])
        // the shake
        var sh = ShakeDetector()
        var shook = false, t = 0.0, x: CGFloat = 500
        for dir in [1.0, -1, 1, -1, 1] as [CGFloat] { for _ in 0..<6 { x += dir * 10; t += 0.01; shook = sh.feed(x: x, at: t) || shook } }
        check("shake: three quick turns of a drag open the shelf", shook)
        var calm = ShakeDetector(); var any = false; t = 0; x = 0
        for _ in 0..<100 { x += 3; t += 0.01; any = calm.feed(x: x, at: t) || any }
        for dir in [1.0, -1, 1, -1] as [CGFloat] { x += dir * 8; t += 0.5; any = calm.feed(x: x, at: t) || any }
        check("shake: a steady drag or slow small wiggles don't", !any)
    }

    // MARK: interaction (keys, operations offered, tasks, the module's sizes)

    static func interaction(_ check: (String, Bool) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        let d = dir("keys")
        let store = ShelfStore(disk: ShelfDisk(dir: dir("keystore"), persist: false), defaults: MemoryDefaults())
        let center = ShelfCenter(store: store, config: ShelfConfigStore(defaults: { MemoryDefaults() }))
        let pb = NSPasteboard(name: NSPasteboard.Name("local.cocaine.shelf-test.keys.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        center.pasteboard = { pb }
        var kept = 0
        center.takeKeyboard = { kept += 1 }
        store.add(urls: (0..<6).map { file(d, "f\($0).txt", "\($0)") })
        center.columns = 3
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ chars: String? = nil, editing: Bool = false) -> Bool {
            ShelfKeys.handle(code, flags: flags, chars: chars, editing: editing, shown: true, center: center)
        }
        check("⌘A selects everything", key(0, .command, "a") && store.selection.ids.count == 6)
        check("⌘C copies the selection (files) to the pasteboard", key(8, .command, "c") && (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.count == 6)
        check("Esc clears the selection first", key(53) && store.selection.isEmpty)
        check("arrows without a selection are left to the tabs", !key(124))
        center.click(store.items[0].id, shift: false, command: false)
        check("a click takes the keyboard for the shelf", kept == 1 && store.selection.ids == [store.items[0].id])
        check("→ / ↓ move the selection", key(124) && store.selection.focus == store.items[1].id && key(125) && store.selection.focus == store.items[4].id)
        check("⇧← extends it", key(123, .shift) && store.selection.ids.count == 2)
        check("⌫ removes the selection from the shelf (the files stay)", key(51) && store.items.count == 4 && FileManager.default.fileExists(atPath: d.appendingPathComponent("f3.txt").path))
        check("keys typed into a field are left alone", !key(0, .command, "a", editing: true))
        check("⌃/⌥ combinations aren't the shelf's", !key(0, [.command, .option], "a"))
        pb.clearContents(); pb.setString("pasted note", forType: .string)
        check("⌘V adds the clipboard to the shelf", key(9, .command, "v") && store.items.last?.text == "pasted note")
        center.sheet = .menu
        check("Esc closes a sheet before anything else", key(53) && center.sheet == nil)
        // operations offered
        var img = ShelfItem(kind: .file, path: "/x/a.png"); let txt = ShelfItem(kind: .text, text: "t")
        let urlFor: (ShelfItem) -> URL? = { $0.isFileBacked ? URL(fileURLWithPath: $0.path) : nil }
        let opsImg = ShelfOp.available([img, ShelfItem(kind: .file, path: "/x/b.jpg")], urlFor: urlFor, cloud: false, ai: false)
        check("operations: images get resize, OCR, PDF, stitch; no cloud or AI without them",
              [.images, .ocr, .pdf, .stitchV, .rename, .zip, .trash].allSatisfy(opsImg.contains) && !opsImg.contains(.shareLink) && !opsImg.contains(.aiContext))
        let opsTxt = ShelfOp.available([txt], urlFor: urlFor, cloud: true, ai: true)
        check("operations: a text can be copied, shared, removed, used as AI context — not renamed or zipped",
              opsTxt.contains(.copy) && opsTxt.contains(.remove) && opsTxt.contains(.aiContext) && !opsTxt.contains(.rename) && !opsTxt.contains(.zip) && !opsTxt.contains(.shareLink))
        check("operations: 'Share link…' only when a cloud provider is there", ShelfOp.available([img], urlFor: urlFor, cloud: true, ai: false).contains(.shareLink))
        img.missing = true
        check("operations: a missing file can only be removed", ShelfOp.available([img], urlFor: urlFor, cloud: true, ai: true) == [.remove])
        check("CloudShareHook: no providers in this build → no 'Share link…'", center.ops(for: store.items).contains(.shareLink) == false)
        // a job with progress, one at a time
        let tasks = ShelfTasks()
        var result: Int?
        let started = tasks.start("t", work: { _, p in p(0.5); Thread.sleep(forTimeInterval: 0.2); return 7 }, done: { if case .success(let v) = $0 { result = v } })
        let second = tasks.start("u", work: { _, _ in 1 }, done: { _ in })
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        check("jobs: one at a time, its result on the main thread, then idle", started && !second && result == 7 && !tasks.busy)
        // the module's sizes in the screens' catalog
        let spec = ModuleCatalog.module("shelf")
        check("the Shelf module comes in S, M and L", spec?.sizes == [.s, .m, .l])
        var l = ScreenLayout.standard
        l.setSize("shelf", in: "shelf", .m)
        check("a Shelf at size M is drawn at M", ScreenLayout.resolve(l.config("shelf")!, in: ScreenLayout.contentSize(stripHeight: 32)).modules.first?.size == .m)
        // the drop loader reads files and texts from item providers
        var loaded: ShelfDropLoader.Loaded?
        let f = file(d, "dropped.txt", "x")
        ShelfDropLoader.load([NSItemProvider(object: f as NSURL), NSItemProvider(object: "dropped words" as NSString), NSItemProvider(object: NSURL(string: "https://example.com")!)]) { loaded = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check("dropping: a file, a text and a link are read as such", loaded?.files == [f] && loaded?.texts == ["dropped words"] && loaded?.links == [URL(string: "https://example.com")!])
    }

    // MARK: fixtures

    /// A PNG drawn here: white, with black text when given (for OCR).
    static func makePNG(width: Int, height: Int, text: String?) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let text {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(height) * 0.32, nil)
            let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: CGFloat(width) * 0.05, y: CGFloat(height) * 0.35)
            CTLineDraw(line, ctx)
        } else {
            ctx.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        let img = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func writeJPEG(width: Int, height: Int, gps: Bool, to url: URL) {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if gps { props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 45.46, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 9.19, kCGImagePropertyGPSLongitudeRef: "E"] }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

extension FolderWatcher {
    /// Tests: a listing and a tick now, on the watcher's own queue.
    func scanNow() { syncOnQueue { self.scan() } }
    func tickNow() { syncOnQueue { self.tick() } }
}

/// The render fixtures: --shelf (two apps, as before), --shelf-fixture grid|selected|collections|empty|menu|rename|images|
/// openwith|share|sheet-collections|instant|progress|missing|m|s|status, with sample files made in a temporary folder
/// (never the user's), and --shelf-size s|m|l.
enum ShelfFixtures {
    static func files() -> [URL] {
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("cocaine-shelf-fixture", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        let names = ["Quarterly report 2026.pdf", "Screenshot 2026-10-07 at 10.12.44.png", "スクリーンショット 2026-10-07.png", "Präsentation_final_v3.key",
                     "notes.txt", "holiday photo.heic", "invoice-0042.pdf", "Archive.zip", "design-system tokens.json"]
        return names.map { n in
            let u = d.appendingPathComponent(n)
            if !fm.fileExists(atPath: u.path) {
                if n.hasSuffix(".png") { try? ShelfTests.makePNG(width: 32, height: 20, text: nil).write(to: u) } else { try? Data("fixture".utf8).write(to: u) }
            }
            return u
        }
    }

    /// A shelf in memory filled for a fixture.
    static func center(_ name: String) -> ShelfCenter {
        let store = ShelfStore(disk: .memory, defaults: MemoryDefaults())
        let c = ShelfCenter(store: store, config: ShelfConfigStore(defaults: { MemoryDefaults() }))
        fill(c, name)
        return c
    }

    static func fill(_ c: ShelfCenter, _ name: String) {
        let s = c.store
        s.replace(.fresh())
        if name == "empty" { return }
        let list = files()
        s.add(urls: [URL(fileURLWithPath: "/System/Applications/Calculator.app")] + list)
        s.addText("Ciao Mario, ti mando il file domani mattina")
        s.addLink(URL(string: "https://github.com/Mattiakart/cocaine")!)
        if name == "missing" || name == "grid" {
            var l = s.library
            l.collections[0].items.append(ShelfItem(kind: .file, path: "/tmp/cocaine-no-such-file.pdf", missing: true))
            s.replace(l)
        }
        let w = s.createCollection("Lavoro", select: false)!
        s.add(urls: Array(list.prefix(3)), to: w)
        _ = s.createCollection("Screenshots", select: false)
        _ = s.createCollection("Fatture 2026", select: false)
        s.recolorCollection(w, 2)
        if ["selected", "menu", "rename", "images", "share", "openwith"].contains(name) {
            var sel = ShelfSelection()
            for i in s.items where ["png", "pdf"].contains((i.path as NSString).pathExtension) { sel.ids.insert(i.id); sel.focus = i.id; sel.anchor = sel.anchor ?? i.id }
            s.selection = sel
        }
        var cfg = c.config.config
        cfg.watched = [.screenshots(), WatchedFolder(path: list[0].deletingLastPathComponent().path, rules: [WatchRule(field: .ext, value: "pdf, png")], matchAll: false)]
        cfg.actions = [ShelfAction(name: "Optimise images", kind: .shell, target: "/usr/bin/true", output: .shelf, instant: true),
                       ShelfAction(name: "Resize for web", kind: .shortcut, target: "Resize for web", instant: true),
                       ShelfAction(name: "Move to Archive", kind: .moveTo, target: "/tmp")]
        c.config.update { $0 = cfg }
        switch name {
        case "menu": c.sheet = .menu
        case "rename": c.renameRule.prefix = "2026 "; c.renameRule.numbering = true; c.sheet = .rename
        case "images": c.imageJob = ImageJob(resize: .width(1200), format: .jpeg, quality: 0.8, stripMetadata: true); c.sheet = .images
        case "openwith": c.sheet = .openWith(s.fileURLs(s.selectedItems()))
        case "share": c.sheet = .share
        case "sheet-collections": c.sheet = .collections
        case "instant": c.instantShown = true
        case "status": c.say("tray.and.arrow.down.fill", String(format: L("%1$d items added to %2$@"), 3, s.current.title), undo: true)
        default: break
        }
    }

    /// --render-island: the shelf's samples (and the module's size with --shelf-size).
    static func apply(_ im: IslandModel, _ args: [String]) {
        if args.contains("--shelf") {
            im.shelf.replace(.fresh())
            im.shelf.add(urls: [URL(fileURLWithPath: "/Applications/Cocaine.app"), URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")])
        }
        guard let i = args.firstIndex(of: "--shelf-fixture"), i + 1 < args.count else { return }
        let name = args[i + 1]
        im.shelfUI.config.update { $0 = ShelfConfig() }
        fill(im.shelfUI, name)
        if name == "instant" { im.dropHover = true }
        if let j = args.firstIndex(of: "--shelf-size"), j + 1 < args.count, let size = ModuleSize(rawValue: args[j + 1]), size != .l {
            im.screens.update { l in
                l.setSize("shelf", in: "shelf", size)
                _ = l.addModule("downloads", to: "shelf")
                if size == .s { _ = l.addModule("clipboard", to: "shelf") }
            }
            im.tab = "shelf"
        }
        if name == "progress" {
            _ = im.shelfUI.tasks.start(L("Compressing…"), work: { _, p -> Int in p(0.4); Thread.sleep(forTimeInterval: 5); return 0 }, done: { _ in })
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
