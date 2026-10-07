// --clipsync-test: the iPhone clipboard sync. Temporary folders stand in for iCloud Drive (placeholders, partial writes,
// duplicates, big files, removal), a fake history and pasteboard for the clipboard, a simulator for the iPhone Shortcuts
// (ShortcutSim from RemoteTests.swift plus the file, clipboard and If actions), and a relay in memory for the encrypted
// channel. Nothing real is read or written: not iCloud Drive, not the clipboard, not phones.json, not the Shortcuts library.

import AppKit
import Foundation

/// The iPhone's Shortcuts app, for the sync Shortcuts: RemoteTests' ShortcutSim runs the remote actions; this adds the
/// clipboard, files (in iCloud Drive's Shortcuts folder: `files`, by path), Set Name, Format Date's custom style, If and the
/// Shortcut's input (the Share Sheet's, or the clipboard when there is none).
final class SyncShortcutSim {
    let base = ShortcutSim()
    var input: String?                  // what the Share Sheet passed; nil: run on its own (the clipboard is taken)
    var clipboard = ""
    var files: [String: String] = [:]   // "Cocaine Clipboard/outbox/latest.txt" → content
    var saved: [String] = []            // paths written, in order
    var copied: [String] = []           // what was put on the clipboard
    var menuChoice: String { get { base.menuChoice } set { base.menuChoice = newValue } }
    var shown: [String] { base.shown }
    var error: String? { base.error }

    private func value(_ id: String, _ p: [String: Any], _ key: String) -> String {
        if let d = p[key] as? [String: Any], (d["Value"] as? [String: Any])?["Type"] as? String == "ExtensionInput" { return input ?? clipboard }
        if let shape = SyncShortcuts.shape(id, key), !RemoteShortcut.Shape.of(p[key]).fits(shape) { return "" }
        return base.value(p[key])
    }

    private(set) var rounds = 0         // Repeat rounds run (all loops)

    func run(_ actions: [[String: Any]]) {
        var pc = 0
        var loops: [(start: Int, round: Int, count: Int)] = []
        func find(after: Int, _ group: String?, _ test: ([String: Any]) -> Bool) -> Int? {
            actions.indices.first { i in i > after && {
                let q = actions[i]["WFWorkflowActionParameters"] as? [String: Any] ?? [:]
                return q["GroupingIdentifier"] as? String == group && test(q)
            }() }
        }
        while pc < actions.count, base.error == nil {
            let a = actions[pc]
            let id = String((a["WFWorkflowActionIdentifier"] as? String ?? "").dropFirst("is.workflow.actions.".count))
            let p = a["WFWorkflowActionParameters"] as? [String: Any] ?? [:]
            var out: String?
            switch id {
            case "getclipboard": out = clipboard
            case "setclipboard": let v = value(id, p, "WFInput"); copied.append(v); clipboard = v
            case "setitemname": out = value(id, p, "WFInput")
            case "documentpicker.save":
                var path = value(id, p, "WFFileDestinationPath")
                if path.hasPrefix("/") { path.removeFirst() }
                files[path] = value(id, p, "WFInput"); saved.append(path); out = path
            case "documentpicker.open": out = files[value(id, p, "WFGetFilePath")] ?? ""
            case "format.date" where p["WFDateFormatStyle"] as? String == "Custom": out = "20261008-123456"
            case "conditional":
                let mode = p["WFControlFlowMode"] as? Int ?? -1, group = p["GroupingIdentifier"] as? String
                if mode == 0 {
                    let input = (p["WFInput"] as? [String: Any])?["Variable"]
                    let has = !base.value(input).isEmpty
                    let yes = (p["WFCondition"] as? Int) == 101 ? !has : has
                    if !yes {
                        guard let i = find(after: pc, group, { [1, 2].contains($0["WFControlFlowMode"] as? Int ?? -1) }) else { base.error = "unclosed If"; break }
                        pc = i
                    }
                } else if mode == 1 {                                           // the end of the "then" branch: skip "otherwise"
                    guard let i = find(after: pc, group, { $0["WFControlFlowMode"] as? Int == 2 }) else { base.error = "unclosed If"; break }
                    pc = i
                }
            case "choosefrommenu":
                let mode = p["WFControlFlowMode"] as? Int ?? -1, group = p["GroupingIdentifier"] as? String
                if mode == 0 {
                    guard let i = find(after: pc, group, { $0["WFControlFlowMode"] as? Int == 1 && $0["WFMenuItemTitle"] as? String == self.menuChoice }) else { base.error = "no menu item \(menuChoice)"; break }
                    pc = i
                } else if mode == 1 {
                    guard let i = find(after: pc, group, { $0["WFControlFlowMode"] as? Int == 2 }) else { base.error = "unclosed menu"; break }
                    pc = i
                }
            case "repeat.count":
                let mode = p["WFControlFlowMode"] as? Int ?? -1, group = p["GroupingIdentifier"] as? String
                if mode == 0 {
                    let n = p["WFRepeatCount"] as? Int ?? 0
                    guard let end = find(after: pc, group, { $0["WFControlFlowMode"] as? Int == 2 }) else { base.error = "unclosed Repeat"; break }
                    if n < 1 { pc = end } else { loops.append((pc, 1, n)); base.vars["Repeat Index"] = "1" }
                } else if mode == 2, let l = loops.last {
                    if l.round < l.count {
                        loops[loops.count - 1].round += 1
                        base.vars["Repeat Index"] = String(l.round + 1)
                        pc = l.start
                    } else {
                        loops.removeLast()
                        base.vars["Repeat Index"] = loops.last.map { String($0.round) }
                        rounds += l.count
                    }
                }
            case "exit": return
            default: base.run([a]); pc += 1; continue
            }
            if let out, let u = p["UUID"] as? String { base.outputs[u] = out }
            pc += 1
        }
    }
}

enum ClipSyncTests {
    static func run() -> Int {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  clipsync: " + name); if !ok { failed += 1 } }
        Language.set("en", persist: false)                 // the messages checked below, whatever this Mac's language (settings are in memory)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cocaine-clipsync-\(getpid())-\(UUID().uuidString.prefix(6))")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let savedHook = ClipSyncHook.send
        defer { ClipSyncHook.send = savedHook }

        settingsTests(check)
        folderTests(root, check)
        decodeTests(check)
        centerTests(root, check)
        outboundTests(root, check)
        remoteTests(check)
        relayTests(root, check)
        shortcutTests(check)
        return failed
    }

    static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func image(_ w: Int, _ h: Int, type: NSBitmapImageRep.FileType = .png) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(NSColor(deviceRed: 0.2, green: 0.5, blue: 0.9, alpha: 1), atX: 0, y: 0)
        return rep.representation(using: type, properties: [:])!
    }

    // MARK: settings

    static func settingsTests(_ check: (String, Bool) -> Void) {
        let s = ClipSyncSettings()
        check("off by default: folder sync, current clipboard, every copy, kept files, Universal Clipboard off-disk",
              !s.folderOn && !s.makeCurrent && !s.sendEveryCopy && !s.keepFiles && !s.universalOffDisk && s.pinboard == nil && s.readableBoard == nil)
        check("off by default: a pairing may neither read nor write the clipboard", s.perm("anything") == ClipRemotePerm() && !ClipRemotePerm().read && !ClipRemotePerm().write)
        let d = MemoryDefaults()
        check("nothing saved: the defaults", ClipSyncSettings.load(d) == s)
        d.set(Data(#"{"folderOn":true,"folderName":"../x","keepHours":-5,"future":1,"remote":{"abc":{"read":true}}}"#.utf8), forKey: ClipSyncSettings.key)
        let l = ClipSyncSettings.load(d)
        check("settings: unknown keys ignored, a bad folder name and hours replaced, the rest kept",
              l.folderOn && l.folderName == ICloudPaths.defaultName && l.keepHours == 1 && l.perm("abc").read && !l.perm("abc").write)
        d.set(Data("garbage".utf8), forKey: ClipSyncSettings.key)
        check("settings: damaged → the defaults (all off)", ClipSyncSettings.load(d) == s)
    }

    // MARK: the folder and the scanner

    static func folderTests(_ root: URL, _ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let home = root.appendingPathComponent("home-folder")
        let r = ICloudPaths.root(home: home, name: "Cocaine Clipboard")
        check("paths: the folder is in Shortcuts' iCloud folder", r.path.hasSuffix("Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/Cocaine Clipboard"))
        check("paths: the Shortcuts' path for it", ICloudPaths.shortcutSubpath(r, home: home) == "Cocaine Clipboard"
              && ICloudPaths.shortcutSubpath(ICloudPaths.cloudDocs(home: home).appendingPathComponent("X"), home: home) == nil)
        check("paths: names with path tricks are refused (and fall back to the default)",
              ["", "..", ".hidden", "a/b", "a:b", " x", String(repeating: "a", count: 65), "a\u{7}"].allSatisfy { !ICloudPaths.validName($0) }
              && ICloudPaths.validName("Clipboard é 2") && ICloudPaths.root(home: home, name: "../../etc").lastPathComponent == ICloudPaths.defaultName)
        let f = SyncFolder(root: r)
        check("status: no iCloud Drive on this Mac", SyncFolderStatus.of(f) == .noICloud)
        check("create: never makes the iCloud container itself", (try? f.create()) == nil && !fm.fileExists(atPath: ICloudPaths.shortcutsDocuments(home: home).path))
        try? fm.createDirectory(at: ICloudPaths.shortcutsDocuments(home: home), withIntermediateDirectories: true)
        check("status: iCloud there, folder not made yet", SyncFolderStatus.of(f) == .notCreated)
        check("create: inbox, outbox, processed", (try? f.create()) != nil && SyncFolderStatus.of(f) == .ready
              && [f.inbox, f.outbox, f.processed].allSatisfy { fm.fileExists(atPath: $0.path) })

        // Names
        let n = ClipSyncNames.make(now: Date(timeIntervalSince1970: 1_791_000_000.123), ext: "txt", random: "a1b2c3")
        check("names: <unix-ms>-<random>.<ext>, recognised as ours", n == "1791000000123-a1b2c3.txt" && ClipSyncNames.isOurs(n) && !ClipSyncNames.isOurs("latest.txt"))
        check("names: unique", Set((0..<200).map { _ in ClipSyncNames.make(now: Date(), ext: "txt") }).count == 200)
        check("names: temporary and hidden files are left alone", [".x.txt", "a.tmp", "b.part", "c.download", "~$d", "e~", "f.crdownload"].allSatisfy(ClipSyncNames.isTransient)
              && !ClipSyncNames.isTransient("20261008-120000-123456.txt"))
        check("names: an iCloud placeholder names its file", ClipSyncNames.placeholderTarget(".20261008-1.txt.icloud") == "20261008-1.txt" && ClipSyncNames.placeholderTarget("a.icloud") == nil)

        // The scanner, on made-up listings
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        let s = InboxScanner(maxBytes: 1000)
        func e(_ name: String, _ size: Int, _ age: Double = 10) -> InboxEntry { InboxEntry(name: name, size: size, modified: t0.addingTimeInterval(-age)) }
        let a1 = s.scan([e("a.txt", 10), e(".b.txt.icloud", 0), e("c.tmp", 5), e("big.png", 5000), e("z.txt", 0)], now: t0)
        check("scan: a new file waits (not stable yet); a placeholder is asked for; a big one refused unread; temporary ignored",
              a1.count == 2 && a1.contains(.reject("big.png", .tooBig)) && a1.contains(.download(".b.txt.icloud")) && s.waiting >= 2)
        let a2 = s.scan([e("a.txt", 10), e(".b.txt.icloud", 0), e("z.txt", 0)], now: t0.addingTimeInterval(2))
        check("scan: unchanged for the wait → taken; an empty file refused; the placeholder not asked again within a minute",
              a2.contains(.ingest("a.txt")) && a2.contains(.reject("z.txt", .empty)) && !a2.contains(.download(".b.txt.icloud")))
        let growing = InboxScanner(maxBytes: 1000)
        _ = growing.scan([e("p.txt", 10, 0)], now: t0)
        let g2 = growing.scan([e("p.txt", 20, 0)], now: t0.addingTimeInterval(2))
        let g3 = growing.scan([InboxEntry(name: "p.txt", size: 20, modified: t0)], now: t0.addingTimeInterval(4))
        check("scan: a file still being written (size changing) waits until it settles", g2.isEmpty && g3 == [.ingest("p.txt")])
        let ph = InboxScanner(maxBytes: 1000)
        ph.downloadTimeout = 100
        _ = ph.scan([e(".q.png.icloud", 0)], now: t0)
        let p2 = ph.scan([e(".q.png.icloud", 0)], now: t0.addingTimeInterval(61))
        _ = ph.scan([e(".q.png.icloud", 0)], now: t0.addingTimeInterval(130))
        check("scan: a placeholder is asked for again every minute and counted as stuck after the timeout", p2 == [.download(".q.png.icloud")] && ph.stuck == ["q.png"])
        _ = ph.scan([], now: t0.addingTimeInterval(140))
        check("scan: what disappeared is forgotten", ph.stuck.isEmpty)
        let many = InboxScanner(maxBytes: 1000)
        let list = (0..<30).map { e("m\($0).txt", 3, Double(100 - $0)) }
        _ = many.scan(list, now: t0)
        let m2 = many.scan(list, now: t0.addingTimeInterval(2))
        check("scan: at most 20 per scan, oldest first", m2.count == 20 && m2.first == .ingest("m0.txt"))

        // The outbox and cleaning
        let out = try? SyncOutbox.write(.text("hello"), to: f, now: t0)
        check("outbox: the item's own file and latest.txt", out.map { ClipSyncNames.isOurs($0.lastPathComponent) } == true
              && (try? String(contentsOf: f.outbox.appendingPathComponent("latest.txt"), encoding: .utf8)) == "hello")
        let png = image(8, 6)
        _ = try? SyncOutbox.write(.image(png: png, width: 8, height: 6), to: f, now: t0)
        check("outbox: an image replaces latest.txt by latest.png (Get from Mac finds only the newest kind)",
              fm.fileExists(atPath: f.outbox.appendingPathComponent("latest.png").path) && !fm.fileExists(atPath: f.outbox.appendingPathComponent("latest.txt").path))
        _ = try? SyncOutbox.write(.text("again"), to: f, now: t0)
        check("outbox: …and back", !fm.fileExists(atPath: f.outbox.appendingPathComponent("latest.png").path))
        try? Data("user".utf8).write(to: f.outbox.appendingPathComponent("notes.txt"))
        try? Data("old".utf8).write(to: f.processed.appendingPathComponent("1-old.txt"))
        let removed = SyncOutbox.clean(f, now: Date().addingTimeInterval(3 * 3600), processedHours: 1, outboxHours: 1)
        let left = (try? fm.contentsOfDirectory(atPath: f.outbox.path)) ?? []
        check("clean: old processed files and Cocaine's own outbox files go; latest.* and the user's files stay",
              removed == 4 && Set(left) == ["latest.txt", "notes.txt"] && ((try? fm.contentsOfDirectory(atPath: f.processed.path)) ?? []).isEmpty)
    }

    // MARK: what files hold

    static func decodeTests(_ check: (String, Bool) -> Void) {
        func text(_ d: Data, _ name: String = "x") -> String? { if case .success(.text(let s)) = SyncDecode.decode(d, name: name) { return s }; return nil }
        check("decode: UTF-8 text, as is", text(Data("Ciao è ✓ 🇮🇹\nline 2".utf8)) == "Ciao è ✓ 🇮🇹\nline 2")
        check("decode: with a BOM, and UTF-16", text(Data([0xEF, 0xBB, 0xBF]) + Data("bom".utf8)) == "bom" && text("utf16 é".data(using: .utf16)!) == "utf16 é")
        check("decode: binary is refused", SyncDecode.decode(Data([0x00, 0x01, 0x02, 0x03, 0x00, 0x99, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60]), name: "x") == .failure(.unsupported))
        check("decode: empty and blank are refused", SyncDecode.decode(Data(), name: "x") == .failure(.empty) && SyncDecode.decode(Data(" \n".utf8), name: "x") == .failure(.empty))
        let webloc = try! PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com/a?b=1"], format: .xml, options: 0)
        check("decode: a shared link (.webloc, .url) is its address", text(webloc, "x.webloc") == "https://example.com/a?b=1"
              && text(Data("[InternetShortcut]\nURL=https://apple.com\n".utf8), "y.url") == "https://apple.com")
        check("decode: a .json with a text", text(Data(#"{"text":"from json"}"#.utf8), "z.json") == "from json")
        check("decode: too long a text is refused", SyncDecode.decode(Data(repeating: 0x61, count: SyncDecode.maxTextBytes + 1), name: "x") == .failure(.tooBig))
        for (type, label) in [(NSBitmapImageRep.FileType.png, "PNG"), (.jpeg, "JPEG"), (.tiff, "TIFF"), (.gif, "GIF")] {
            let d = image(30, 20, type: type)
            if case .success(.image(let png, let w, let h)) = SyncDecode.decode(d, name: "photo.txt") {
                check("decode: a \(label) is recognised by its bytes (whatever its name) and kept as PNG", w == 30 && h == 20 && png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
            } else { check("decode: a \(label) is recognised by its bytes (whatever its name) and kept as PNG", false) }
        }
        if case .success(.image(_, let w, let h)) = SyncDecode.decode(image(3000, 1500, type: .jpeg), name: "big") {
            check("decode: a big photo is made smaller (longest side 2048)", w == 2048 && h == 1024)
        } else { check("decode: a big photo is made smaller (longest side 2048)", false) }
        let heic = Data([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0])
        check("decode: HEIC is recognised as an image (and refused when it isn't one)", SyncDecode.isImage(heic) && SyncDecode.decode(heic, name: "x") == .failure(.unsupported))
    }

    // MARK: the watcher, end to end on a temporary "iCloud Drive"

    static func makeHistory(_ root: URL, _ name: String, board: FakePasteboard = FakePasteboard(), d: UserDefaults = MemoryDefaults()) -> ClipboardHistory {
        if d.data(forKey: ClipSettings.key) == nil { var s = ClipSettings(); s.maxAgeHours = 0; s.save(d) }
        let h = ClipboardHistory(defaults: d, dir: root.appendingPathComponent(name), keys: MemoryKeyStore(), board: board)
        h.frontApp = { "com.apple.TextEdit" }
        return h
    }

    static func centerTests(_ root: URL, _ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let home = root.appendingPathComponent("home-center")
        try? fm.createDirectory(at: ICloudPaths.shortcutsDocuments(home: home), withIntermediateDirectories: true)
        let board = FakePasteboard()
        let h = makeHistory(root, "center", board: board)
        let c = ClipSyncCenter(history: h, defaults: MemoryDefaults(), home: home)
        var downloads: [String] = []
        c.download = { downloads.append($0.lastPathComponent) }
        var offset = 0.0
        c.now = { Date().addingTimeInterval(offset) }
        func scan() {
            var done = false
            c.scan { done = true }
            let until = Date().addingTimeInterval(5)
            while !done && Date() < until { pump(0.02) }
            c.io.sync {}
        }
        check("before it's turned on: no folder is made", !fm.fileExists(atPath: c.folder.root.path))
        check("turned on: the folder is made, and the sync starts", c.enableFolder() && c.status == .ready && c.settings.folderOn && ClipSyncHook.send != nil)
        c.stop()                                                                    // the tests drive the scans themselves
        let f = c.folder
        func drop(_ name: String, _ data: Data) { try? data.write(to: f.inbox.appendingPathComponent(name)) }
        drop("20261008-120000-111111.txt", Data("Hello from the iPhone ✓".utf8))
        drop("20261008-120001-222222", image(40, 30, type: .jpeg))                        // no extension: Save File may name it so
        drop("20261008-120002-333333.txt", Data("Hello from the iPhone ✓".utf8))          // the same content again (iCloud's "name 2")
        drop(".20261008-120003-444444.txt.icloud", Data())
        drop("20261008-120004-555555.txt", Data("sk-live-AbCdEf1234567890XyZ9876543210".utf8))   // a key
        drop("20261008-120005-666666.tmp", Data("partial".utf8))
        try? fm.createDirectory(at: f.inbox.appendingPathComponent("sub"), withIntermediateDirectories: true)
        drop("sub/20261008-120006-777777.txt", Data("in a folder".utf8))
        scan()
        check("first look: nothing taken yet (sizes must settle); the placeholder is asked for", h.items.isEmpty && downloads == ["20261008-120003-444444.txt"])
        offset = 3
        scan()
        let texts = h.items.filter { $0.kind == .text }.map(\.text)
        check("then: text and photo taken, from the iPhone; the duplicate once; the key refused; one level of folders read",
              texts.sorted() == ["Hello from the iPhone ✓", "in a folder"] && h.items.filter { $0.kind == .image }.count == 1
              && h.items.allSatisfy { $0.source == ClipRules.iPhoneSource && $0.fromIPhone && $0.fromDevice && !$0.remote })
        check("counters: received 3, refused 1 (the key); last sync set", c.received == 3 && c.refused == 1 && c.lastSync != nil)
        let left = Set((try? fm.contentsOfDirectory(atPath: f.inbox.path)) ?? [])
        check("taken files are deleted (default); placeholders and temporary files stay", left == [".20261008-120003-444444.txt.icloud", "20261008-120005-666666.tmp", "sub"])
        check("the Mac's clipboard is left alone (Make it the current clipboard is off)", board.written.isEmpty)
        // Options: a pinboard, the current clipboard, kept files.
        guard let pb = h.createBoard("From iPhone") else { check("pinboard made", false); return }
        c.update { $0.pinboard = pb.id; $0.makeCurrent = true; $0.keepFiles = true }
        c.stop()
        drop("20261008-120010-888888.txt", Data("pin me".utf8))
        scan(); offset = 6; scan()
        let pinned = h.items.first { $0.text == "pin me" }
        check("options: pinned to the chosen pinboard and put on the clipboard (marked as Cocaine's own)",
              pinned?.boards.contains(pb.id) == true && board.written.last?.text == "pin me" && board.content.ours)
        check("options: the file kept in processed/", ((try? fm.contentsOfDirectory(atPath: f.processed.path)) ?? []).contains { $0.hasSuffix("20261008-120010-888888.txt") })
        drop("20261008-120011-999999.txt", Data(repeating: 0x61, count: ClipSyncRules.maxInboxBytes + 1))
        scan()
        check("a file over the size limit is set aside unread", ((try? fm.contentsOfDirectory(atPath: f.processed.path)) ?? []).contains { $0.hasSuffix("20261008-120011-999999.txt") }
              && c.note != nil)
        try? fm.removeItem(at: f.inbox.appendingPathComponent(".20261008-120003-444444.txt.icloud"))
        drop("20261008-120003-444444.txt", Data("downloaded later".utf8))                 // iCloud brought it down
        scan(); offset = 9; scan()
        check("a placeholder downloaded later is taken then", h.items.contains { $0.text == "downloaded later" })

        // The test button: a probe written and read back, nothing left behind.
        c.test()
        let until = Date().addingTimeInterval(5)
        while c.testing && Date() < until { pump(0.02) }
        check("test: written, read back and removed", c.note?.contains("ms") == true
              && !((try? fm.contentsOfDirectory(atPath: f.root.path)) ?? []).contains { $0.hasPrefix("probe-") })
        // Turned off: no longer watched, nothing taken, the island's action goes.
        c.update { $0.folderOn = false }
        drop("20261008-120020-000000.txt", Data("after off".utf8))
        pump(0.2)
        check("turned off: the island's Send to iPhone goes away, nothing more is taken", ClipSyncHook.send == nil && !h.items.contains { $0.text == "after off" })
        // Universal Clipboard copies kept off the saved history.
        do {
            let d = MemoryDefaults(), keys = MemoryKeyStore(), dir = root.appendingPathComponent("offdisk")
            var s = ClipSettings(); s.persist = true; s.maxAgeHours = 0; s.save(d)
            let p = ClipboardHistory(defaults: d, dir: dir, keys: keys, board: FakePasteboard())
            let pc = ClipSyncCenter(history: p, defaults: d, home: home)
            pc.update { $0.universalOffDisk = true }
            p.start()
            p.add(.text("copied on the iPad", source: ClipRules.remoteSource))
            p.add(.text("copied here", source: "com.apple.TextEdit"))
            p.flush(); p.stop()
            let again = ClipboardHistory(defaults: d, dir: dir, keys: keys, board: FakePasteboard())
            again.start(); again.stop()
            check("Universal Clipboard off-disk: its copies are used but never saved; this Mac's are", p.items.count == 2
                  && again.items.map(\.text) == ["copied here"])
            pc.update { $0.universalOffDisk = false }
            let p2 = ClipboardHistory(defaults: d, dir: dir, keys: keys, board: FakePasteboard())
            _ = ClipSyncCenter(history: p2, defaults: d, home: home)
            p2.start(); p2.add(.text("iPad again", source: ClipRules.remoteSource)); p2.flush(); p2.stop()
            let a2 = ClipboardHistory(defaults: d, dir: dir, keys: keys, board: FakePasteboard())
            a2.start(); a2.stop()
            check("…and with the setting off (default) they are saved like any copy", a2.items.contains { $0.text == "iPad again" })
        }
        // Search: from:iphone finds both kinds of other-device items.
        let q = ClipQuery.parse("from:iphone")
        check("search: from:iphone matches items from the iPhone sync and Universal Clipboard",
              q.matches(.text("x", source: ClipRules.iPhoneSource), boards: [], appName: { _ in nil }, describe: { _ in "" })
              && q.matches(.text("y", source: ClipRules.remoteSource), boards: [], appName: { _ in nil }, describe: { _ in "" })
              && !q.matches(.text("z", source: "com.apple.TextEdit"), boards: [], appName: { _ in nil }, describe: { _ in "" }))
    }

    // MARK: to the iPhone

    static func outboundTests(_ root: URL, _ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        var settings = ClipSettings()
        settings.excludedApps = ["com.example.secret"]
        settings.patterns = ["^INTERNAL-"]
        func refused(_ i: ClipItem, auto: Bool = false) -> ClipSyncRules.Refusal? { ClipSyncRules.outbound(i, settings: settings, automatic: auto) }
        check("outbound: plain text goes", refused(.text("Buy milk")) == nil)
        check("outbound: keys, tokens, card numbers never go (even with the history's filter off)", {
            var off = settings; off.skipSecrets = false
            return ["sk-live-AbCdEf1234567890XyZ9876543210", "4111 1111 1111 1111", "my token ghp_abcdefghijklmnopqrstuvwxyz0123456789 here",
                    "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----"].allSatisfy { ClipSyncRules.outbound(.text($0), settings: off, automatic: false) == .secret }
        }())
        check("outbound: the user's patterns, excluded apps and password managers", refused(.text("INTERNAL-plan")) == .pattern
              && refused(.text("x", source: "com.example.secret")) == .excludedApp && refused(.text("x", source: "com.agilebits.onepassword7")) == .excludedApp)
        check("outbound: files never (only their names would arrive)", refused(.files(["/tmp/a"])) == .files)
        check("outbound: every-copy mode never sends back what came from a device", refused(.text("x", source: ClipRules.iPhoneSource), auto: true) == .fromDevice
              && refused(.text("x", source: ClipRules.remoteSource), auto: true) == .fromDevice && refused(.text("x", source: ClipRules.iPhoneSource)) == nil)
        var img = ClipItem.image(png: image(4, 4), width: 4, height: 4)
        img.ocr = "password •••"
        check("outbound: every-copy mode skips an image whose recognised text had a secret", refused(img, auto: true) == .secret && refused(img) == nil)

        let home = root.appendingPathComponent("home-out")
        try? fm.createDirectory(at: ICloudPaths.shortcutsDocuments(home: home), withIntermediateDirectories: true)
        let h = makeHistory(root, "out")
        let c = ClipSyncCenter(history: h, defaults: MemoryDefaults(), home: home)
        _ = c.enableFolder(); c.stop()
        h.add(.text("to the phone"))
        h.add(.text("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))   // kept (history filter) only when allowed; add it straight for the test
        let ids = h.items.map(\.id)
        let r = c.sendToIPhone(ids)
        let outbox = (try? fm.contentsOfDirectory(atPath: c.folder.outbox.path)) ?? []
        check("Send to iPhone: the text written (own file + latest.txt), the token refused, and said so",
              r.sent == 1 && outbox.filter(ClipSyncNames.isOurs).count == 1 && (try? String(contentsOf: c.folder.outbox.appendingPathComponent("latest.txt"), encoding: .utf8)) == "to the phone"
              && r.message.contains(L("Not sent: it looks like a password, key or card number.")))
        h.add(.image(png: image(5, 5), width: 5, height: 5))
        _ = c.sendToIPhone([h.items[0].id])
        check("Send to iPhone: an image becomes latest.png", fm.fileExists(atPath: c.folder.outbox.appendingPathComponent("latest.png").path))
        // Every copy
        c.update { $0.sendEveryCopy = true }
        let before = c.sent
        h.add(.text("auto one", source: "com.apple.TextEdit"))
        pump(0.1)
        h.add(.text("4111 1111 1111 1111", source: "com.apple.TextEdit"))
        pump(0.1)
        h.add(.text("from phone", source: ClipRules.iPhoneSource))
        pump(0.1)
        check("every copy: a new copy goes, a card number and the iPhone's own don't", c.sent == before + 1
              && (try? String(contentsOf: c.folder.outbox.appendingPathComponent("latest.txt"), encoding: .utf8)) == "auto one")
        c.update { $0.sendEveryCopy = false }
        h.add(.text("not auto", source: "com.apple.TextEdit"))
        pump(0.1)
        check("every copy off: nothing more goes", c.sent == before + 1)
    }

    // MARK: the relay's clip commands

    static func remoteTests(_ check: (String, Bool) -> Void) {
        func p(_ s: String) -> Result<ClipRemoteCommand, ClipRemoteParseError>? { ClipRemote.parse(s) }
        let b64 = Data("Ciao ✓\nriga".utf8).base64EncodedString()
        check("parse: not a clip command → the gate's", p("status") == nil && p("clipboard") == nil)
        check("parse: put, part, get, get N, list", p("clip put \(b64)") == .success(.put("Ciao ✓\nriga")) && p("clip get") == .success(.get(nil))
              && p("clip get 3") == .success(.get(3)) && p("clip list") == .success(.list)
              && p("clip part 123456 2/3 QUJD") == .success(.part(id: "123456", index: 2, count: 3, piece: "QUJD")))
        let bad = ["clip", "clip put", "clip put !!", "clip put \(b64) extra", "clip get 0", "clip get -1", "clip get 100", "clip get x",
                   "clip part 1 1/2", "clip part a$ 1/2 QUJD", "clip part 1 a/b QUJD", "clip part 1 1/2 QU JD", "clip rm", "clip put /w==="]
        check("parse: anything else is refused (\(bad.count) forms)", bad.allSatisfy { if case .failure? = p($0) { return true }; return false })

        var perms: [String: ClipRemotePerm] = [:]
        var history: [ClipItem] = [.text("newest text")]
        var added: [String] = []
        var board: (String, [ClipItem])? = ("Phone", [.text("first"), .text("sk-live-AbCdEf1234567890XyZ9876543210"), .image(png: image(2, 2), width: 2, height: 2)])
        var t = Date(timeIntervalSince1970: 1_791_000_000)
        var settings = ClipSettings()
        func handler(limit: Int = 10_000) -> ClipRemoteHandler {
            ClipRemoteHandler(perMinute: limit, context: .init(perm: { perms[$0] ?? ClipRemotePerm() }, newest: { history.first }, readable: { board.map { (name: $0.0, items: $0.1) } },
                                             settings: { settings }, add: { s in
                if case .keep = ClipSyncRules.decide(.text(s), settings: settings, now: t) { added.append(s); return true }
                return false
            }, now: { t }))
        }
        let pair = Pairing.make(tier: "basic", relay: "https://relay.test")!
        let legacy = Pairing(id: "0011223344556677", cmd: "c", reply: "r", tier: "agents", relay: "https://relay.test")
        var hd = handler()
        // The permission matrix
        let cmds = ["clip get", "clip list", "clip get 1", "clip put \(b64)", "clip part 9 1/1 \(b64)"]
        func outcome(_ c: String, _ pr: Pairing = pair, auth: Bool = true) -> String { hd.handle(c, pairing: pr, authenticated: auth) ?? "<gate>" }
        check("matrix: nothing allowed by default (every command refused, nothing added)",
              cmds.allSatisfy { outcome($0).contains("off") } && added.isEmpty)
        perms[pair.id] = ClipRemotePerm(read: true, write: false)
        check("matrix: read only → get/list work, put/part refused", outcome("clip get") == "CLIP:newest text" && outcome("clip list").hasPrefix("Phone\n1. first")
              && outcome("clip put \(b64)").contains("off") && outcome("clip part 9 1/1 \(b64)").contains("off") && added.isEmpty)
        perms[pair.id] = ClipRemotePerm(read: false, write: true)
        check("matrix: write only → put works, get/list refused", outcome("clip put \(b64)").contains("added") && added == ["Ciao ✓\nriga"]
              && outcome("clip get").contains("off") && outcome("clip list").contains("off"))
        perms[pair.id] = ClipRemotePerm(read: true, write: true)
        check("matrix: another pairing's switches don't count", outcome("clip get", Pairing.make(tier: "agents", relay: "x")!).contains("off"))
        perms[legacy.id] = ClipRemotePerm(read: true, write: true)
        check("matrix: an old (plain-text, unauthenticated) Shortcut never reaches the clipboard, whatever the switches",
              outcome("clip get", legacy, auth: false).contains("newer Shortcut") && outcome("clip get", pair, auth: false).contains("newer Shortcut"))
        check("matrix: either level (basic here, agents above)", outcome("clip get") == "CLIP:newest text")
        // Secrets and kinds on the way out
        history = [.text("ghp_abcdefghijklmnopqrstuvwxyz0123456789")]
        check("get: a key is never sent", outcome("clip get").contains("password") && !outcome("clip get").contains("ghp_"))
        settings.patterns = ["^secret plan"]
        history = [.text("secret plan for Monday")]
        check("get: the user's patterns hold too", !outcome("clip get").contains("Monday"))
        history = [.image(png: image(2, 2), width: 2, height: 2)]
        check("get: an image says to use Get from Mac", outcome("clip get").contains("Get from Mac"))
        history = []
        check("get: empty history said so", outcome("clip get").contains("empty"))
        check("pinboard: items by number; a key masked in the list and refused; an image pointed elsewhere; out of range said",
              outcome("clip get 1") == "CLIP:first" && outcome("clip list").contains("2. •••") && !outcome("clip get 2").contains("sk-live")
              && outcome("clip get 3").contains("Get from Mac") && outcome("clip get 9").contains("9"))
        board = nil
        check("pinboard: none readable → said so", outcome("clip list").contains("pinboard") && outcome("clip get 1").contains("pinboard"))
        // Cutting
        let long = String(repeating: "é", count: 3000)
        history = [.text(long)]
        let cut = outcome("clip get")
        check("get: a long text is cut to fit one answer, on a character boundary, and says so",
              cut.hasPrefix("CLIP:éé") && Data(cut.utf8).count <= RemoteProtocol.maxReplyBytes && cut.contains("6000"))
        history = [.text(String(repeating: "a", count: ClipRemote.replyRoom))]
        check("get: exactly the room → not cut", !outcome("clip get").contains("["))
        // Secrets coming in
        check("put: a key from the iPhone isn't kept (the history's rules)", outcome("clip put \(Data("sk-live-AbCdEf1234567890XyZ9876543210".utf8).base64EncodedString())").contains("not kept"))
        check("put: empty text", outcome("clip put \(Data("   ".utf8).base64EncodedString())").contains("no text"))

        // Pieces
        added = []
        func pieces(_ s: String, size: Int = SyncShortcuts.pieceSize) -> [String] {
            let b = Array(Data(s.utf8).base64EncodedString())
            return stride(from: 0, to: b.count, by: size).map { String(b[$0..<min(b.count, $0 + size)]) }
        }
        let twoK = String(repeating: "Lorem ipsum é ✓ ", count: 110)                 // ≈ 2.1 KB
        let ps = pieces(twoK)
        check("pieces: ≈2 KB is \(ps.count) pieces (≤ 6)", (5...6).contains(ps.count))
        var replies: [String] = []
        for (i, piece) in ps.enumerated().reversed() { replies.append(outcome("clip part 42 \(i + 1)/\(ps.count) \(piece)")) }   // out of order
        check("pieces: put together in any order; earlier ones are acknowledged", added == [twoK] && replies.dropLast().allSatisfy { $0.contains("received") })
        let seven = String(repeating: "x", count: 2400)
        check("pieces: more than 6 is too long", outcome("clip part 7 1/7 \(pieces(seven)[0])").contains("too long"))
        let big = pieces(String(repeating: "y", count: 2300))
        var bigReplies: [String] = []
        for (i, piece) in big.enumerated() { bigReplies.append(outcome("clip part 8 \(i + 1)/\(big.count) \(piece)")) }
        check("pieces: over \(ClipRemote.maxTotalBytes) bytes is too long (fail closed)", bigReplies.last?.contains("too long") == true && !added.contains { $0.hasPrefix("yyy") })
        check("pieces: a different count for the same id breaks it", outcome("clip part 9 1/2 QUJD").contains("1 of 2") && outcome("clip part 9 2/3 QUJD").contains("didn't match"))
        check("pieces: the same piece twice is fine; another content for the same index breaks it",
              outcome("clip part 10 1/2 QUJD").contains("1 of 2") && outcome("clip part 10 1/2 QUJD").contains("1 of 2") && outcome("clip part 10 1/2 RUZH").contains("didn't match"))
        _ = outcome("clip part 11 1/2 \(pieces("ab")[0])")
        t = t.addingTimeInterval(ClipRemote.partTimeout + 1)
        check("pieces: a text not finished within 2 minutes is dropped", outcome("clip part 11 2/2 QUJD").contains("1 of 2"))
        check("pieces: index outside 1…n", outcome("clip part 12 3/2 QUJD").contains("didn't match") && outcome("clip part 12 0/2 QUJD").contains("didn't match"))
        // Rate limit
        hd = handler(limit: ClipRemote.perMinute)
        perms[pair.id] = ClipRemotePerm(read: true, write: true)
        history = [.text("rate")]
        let burst = (0..<15).map { _ in outcome("clip get") }
        check("rate: 12 a minute per pairing, then refused", burst.prefix(12).allSatisfy { $0 == "CLIP:rate" } && burst.suffix(3).allSatisfy { $0.contains("too many") })
        t = t.addingTimeInterval(61)
        check("rate: …and fine again a minute later", outcome("clip get") == "CLIP:rate")
    }

    // MARK: through protocol v2, the listener and the gate

    static func relayTests(_ root: URL, _ check: (String, Bool) -> Void) {
        let p = Pairing.make(tier: "basic", relay: "https://relay.test")!, k = p.keys!
        let store = RemoteReplayStore(url: root.appendingPathComponent("clip-state.json"))
        func eval(_ text: String) -> RemoteDecision {
            RemoteGatekeeper.evaluate(text: text, eventID: UUID().uuidString, eventTime: Int(Date().timeIntervalSince1970), pairing: p, active: true,
                                      now: Date(), maxAge: 120, legacyUntil: nil, store: store, expiredText: "E", noticeText: "N")
        }
        let sealed = RemoteProtocol.sealCommand("clip get", pairingID: p.id, keys: k, nonce: RemoteTests.nonce(), ts: RemoteProtocol.timestamp(Date()))
        check("v2: a sealed clip command opens and runs once", { if case .run("clip get", _, _?) = eval(sealed) { return true }; return false }())
        check("v2: …its replay is dropped", eval(sealed) == .drop(.replay))
        var parts = sealed.split(separator: ".").map(String.init)
        parts[4] = String(parts[4].reversed())
        check("v2: a tampered clip command is refused", eval(parts.joined(separator: ".")) == .drop(.badTag))
        check("v2: the relay never sees the text sent", !RemoteProtocol.sealCommand("clip put \(Data("my secret note".utf8).base64EncodedString())", pairingID: p.id, keys: k,
                                                                                     nonce: RemoteTests.nonce(), ts: RemoteProtocol.timestamp(Date())).contains("bXkgc2VjcmV0"))
        let piece = "clip part 123456 6/6 " + String(repeating: "A", count: SyncShortcuts.pieceSize)
        check("v2: the longest piece fits one command", (try? RemoteProtocol.openCommand(RemoteProtocol.sealCommand(piece, pairingID: p.id, keys: k, nonce: RemoteTests.nonce(),
                                                                                                                      ts: RemoteProtocol.timestamp(Date())), pairingID: p.id, keys: k).get())?.text == piece)
        let reply = RemoteProtocol.sealReply("CLIP:ciao", pairingID: p.id, keys: k, nonce: "123456789012345678", now: Date())
        check("v2: the answer is bound to its request", RemoteProtocol.openReply(reply, pairingID: p.id, keys: k, nonce: "123456789012345678") == "CLIP:ciao"
              && RemoteProtocol.openReply(reply, pairingID: p.id, keys: k, nonce: "999999999999999999") == nil)

        // The listener: a clip command is answered by the app (intercept), never handed to the gate.
        let lock = NSLock()
        var executed: [String] = [], intercepted: [(String, Bool)] = [], published: [String] = []
        var h = RemoteListener.Hooks(store: RemoteReplayStore(url: root.appendingPathComponent("clip-listener.json")),
                                     execute: { c, _ in lock.withLock { executed.append(c) }; return "gate ran \(c)" },
                                     publish: { body, _, _, _ in lock.withLock { published.append(body) }; return 200 })
        h.intercept = { c, _, auth in
            guard c.hasPrefix("clip ") else { return nil }
            lock.withLock { intercepted.append((c, auth)) }
            return "CLIP:from the app"
        }
        h.configuration = { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [MockRelayProtocol.self]; return c }
        h.firstDelay = 0.05
        h.backoff = { _ in 0.05 }
        let l = RemoteListener(hooks: h)
        let q = Pairing.make(tier: "basic", relay: "https://relay.test")!
        let now = Int(Date().timeIntervalSince1970)
        let c1 = RemoteProtocol.sealCommand("clip get", pairingID: q.id, keys: q.keys!, nonce: RemoteTests.nonce(), ts: RemoteProtocol.timestamp(Date()))
        let c2 = RemoteProtocol.sealCommand("status", pairingID: q.id, keys: q.keys!, nonce: RemoteTests.nonce(), ts: RemoteProtocol.timestamp(Date()))
        MockRelayProtocol.add(q.cmd, id: "clip1", time: now, text: c1)
        MockRelayProtocol.add(q.cmd, id: "clip1b", time: now, text: c1)          // delivered again
        MockRelayProtocol.add(q.cmd, id: "clip2", time: now, text: c2)
        l.sync([q])
        let until = Date().addingTimeInterval(4)
        while lock.withLock({ published.count < 2 }) && Date() < until { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 0.3)
        l.stop()
        lock.lock()
        let ex = executed, ic = intercepted, pub = published
        lock.unlock()
        check("listener: clip goes to the app (authenticated, once), other commands to the gate", ic.count == 1 && ic[0].0 == "clip get" && ic[0].1 && ex == ["status"])
        check("listener: the app's answer goes back sealed for that request",
              pub.contains { RemoteProtocol.openReply($0, pairingID: q.id, keys: q.keys!, nonce: String(c1.split(separator: ".")[2])) == "CLIP:from the app" })

        // remote.zsh's gate never takes clip (the text could hold anything): refused even at the agents level.
        if let script = Bundle.main.path(forResource: "remote", ofType: "zsh") ?? [Bundle.main.resourcePath.map { $0 + "/remote.zsh" }].compactMap({ $0 }).first,
           FileManager.default.fileExists(atPath: script) {
            let home = root.appendingPathComponent("gate-home")
            try? FileManager.default.createDirectory(at: home.appendingPathComponent("support"), withIntermediateDirectories: true)
            func gate(_ command: String) -> Int32 {
                let pr = Process()
                pr.executableURL = URL(fileURLWithPath: "/bin/zsh")
                pr.arguments = [script, "gate", "--tier=agents"]
                pr.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "COCAINE_SUPPORT": home.appendingPathComponent("support").path,
                                  "COCAINE_ENGINE": "/usr/bin/false", "COCAINE_DOMAIN": "local.cocaine.test-\(getpid())", "SSH_ORIGINAL_COMMAND": command]
                pr.standardOutput = FileHandle.nullDevice; pr.standardError = FileHandle.nullDevice
                guard (try? pr.run()) != nil else { return -1 }
                pr.waitUntilExit()
                return pr.terminationStatus
            }
            check("gate: clip commands are refused by the shell gate (answered only inside the app)", ["clip get", "clip put QUJD", "clip list"].allSatisfy { gate($0) == 126 })
        } else { check("gate: remote.zsh found in the app", false) }
    }

    // MARK: the Shortcuts

    static func shortcutTests(_ check: (String, Bool) -> Void) {
        let labels = SyncShortcutLabels()
        let sub = "Cocaine Clipboard"
        func actions(_ d: Data?) -> [[String: Any]] {
            d.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["WFWorkflowActions"] as? [[String: Any]] ?? []
        }
        let send = SyncShortcuts.build(.sendToMac, subpath: sub, pairing: nil, labels: labels)
        let get = SyncShortcuts.build(.getFromMac, subpath: sub, pairing: nil, labels: labels)
        for (name, d) in [("Send to Mac", send), ("Get from Mac", get)] {
            let pr = d.map { SyncShortcuts.problems($0, subpath: sub) } ?? ["not built"]
            check("shortcut \(name): known actions and keys, blocks balanced, files only in the sync folder\(pr.isEmpty ? "" : ": " + pr.prefix(3).joined(separator: "; "))", pr.isEmpty)
        }
        check("shortcuts: a folder Shortcuts can't reach builds nothing", SyncShortcuts.build(.sendToMac, subpath: "../x", pairing: nil, labels: labels) == nil
              && SyncShortcuts.build(.getFromMac, subpath: nil, pairing: nil, labels: labels) == nil)
        let plist = send.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        check("Send to Mac: in the Share Sheet for text, links and images; with no input it takes the clipboard",
              (plist?["WFWorkflowTypes"] as? [String]) == ["ActionExtension"] && (plist?["WFWorkflowInputContentItemClasses"] as? [String])?.contains("WFImageContentItem") == true
              && ((plist?["WFWorkflowNoInputBehavior"] as? [String: Any])?["Name"] as? String) == "WFWorkflowNoInputBehaviorGetClipboard")

        // Send to Mac, run: what it saves is exactly what was shared or copied, uniquely named, in the inbox.
        func runSend(input: String?, clipboard: String) -> SyncShortcutSim {
            let s = SyncShortcutSim(); s.input = input; s.clipboard = clipboard; s.run(actions(send)); return s
        }
        let cases: [(String, String?, String)] = [("text", "Hello Mac", ""), ("unicode", "Città ✓ 日本語 🇮🇹\n\"quotes\" $(id) `x` ; | &", ""),
                                                  ("large", String(repeating: "0123456789", count: 50_000), ""), ("an image", "\u{1}IMAGE-BYTES", ""),
                                                  ("no input: the clipboard", nil, "from the clipboard")]
        for (what, input, clip) in cases {
            let s = runSend(input: input, clipboard: clip)
            let path = s.saved.first ?? ""
            check("Send to Mac (\(what)): saved as is in inbox/, unique name, said so", s.error == nil && s.saved.count == 1
                  && path.hasPrefix(sub + "/inbox/") && path.range(of: #"/inbox/[0-9]{8}-[0-9]{6}-[0-9]{6}$"#, options: .regularExpression) != nil
                  && s.files[path] == (input ?? clip) && s.shown == [labels.sent])
        }
        let n1 = runSend(input: "a", clipboard: "").saved.first, n2 = runSend(input: "a", clipboard: "").saved.first
        check("Send to Mac: two runs, two names (random part)", n1 != nil && n1 != n2 || n1 == n2 && false)
        do {   // what the Mac then does with that very file
            let s = runSend(input: "Città ✓ 日本語", clipboard: "")
            if let path = s.saved.first, case .success(.text(let t)) = SyncDecode.decode(Data(s.files[path]!.utf8), name: (path as NSString).lastPathComponent) {
                check("Send to Mac → the Mac: the file decodes to the same text", t == "Città ✓ 日本語")
            } else { check("Send to Mac → the Mac: the file decodes to the same text", false) }
        }

        // Get from Mac, run.
        func runGet(_ files: [String: String]) -> SyncShortcutSim {
            let s = SyncShortcutSim(); s.files = files; s.clipboard = "before"; s.run(actions(get)); return s
        }
        let gt = runGet(["\(sub)/outbox/latest.txt": "From the Mac ✓"])
        check("Get from Mac: the text goes on the clipboard and is shown", gt.error == nil && gt.clipboard == "From the Mac ✓" && gt.shown == [labels.copied + "\nFrom the Mac ✓"])
        let gi = runGet(["\(sub)/outbox/latest.png": "\u{1}PNG", "\(sub)/outbox/latest.txt": "older text"])
        check("Get from Mac: an image wins (and is said)", gi.clipboard == "\u{1}PNG" && gi.shown == [labels.copiedImage])
        let gn = runGet([:])
        check("Get from Mac: nothing there → says so, the clipboard untouched", gn.clipboard == "before" && gn.copied.isEmpty && gn.shown == [labels.nothing])
        let ge = runGet(["\(sub)/outbox/latest.txt": ""])
        check("Get from Mac: an empty file doesn't empty the clipboard", ge.copied.isEmpty && ge.shown == [labels.nothing])

        // The checks catch what would break or overreach.
        func mutated(_ base: Data?, _ change: (inout [[String: Any]]) -> Void) -> Data {
            var a = actions(base)
            change(&a)
            return (try? PropertyListSerialization.data(fromPropertyList: ["WFWorkflowActions": a], format: .binary, options: 0)) ?? Data()
        }
        func setParam(_ a: inout [[String: Any]], _ id: String, _ key: String, _ v: Any) {
            for i in a.indices where a[i]["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.\(id)" {
                var q = a[i]["WFWorkflowActionParameters"] as! [String: Any]; q[key] = v; a[i]["WFWorkflowActionParameters"] = q
            }
        }
        check("checks: a save outside the sync folder is caught", SyncShortcuts.problems(mutated(send) { setParam(&$0, "documentpicker.save", "WFFileDestinationPath", RemoteShortcut.Builder.token([.t("/Other/x")])) }, subpath: sub)
            .contains { $0.contains("outside the sync folder") })
        check("checks: overwriting or asking where is caught", SyncShortcuts.problems(mutated(send) { setParam(&$0, "documentpicker.save", "WFSaveFileOverwrite", true) }, subpath: sub)
            .contains { $0.contains("must not ask nor overwrite") })
        check("checks: an action nobody checked (a shell script) is caught", !SyncShortcuts.problems(mutated(get) {
            $0.append(["WFWorkflowActionIdentifier": "is.workflow.actions.runshellscript", "WFWorkflowActionParameters": ["Script": "x"]]) }).isEmpty)
        check("checks: an If on anything but a whole variable, or another test, is caught",
              SyncShortcuts.problems(mutated(get) { setParam(&$0, "conditional", "WFCondition", 4) }).contains { $0.contains("has any value") })
        check("checks: an If left open is caught", SyncShortcuts.problems(mutated(get) { $0.removeLast() }).contains { $0.contains("not closed") || $0.contains("order") })
        let wrongShape = mutated(get) { a in
            for i in a.indices where a[i]["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.setclipboard" {
                var q = a[i]["WFWorkflowActionParameters"] as! [String: Any]
                q["WFInput"] = ["Value": ["string": "\u{FFFC}", "attachmentsByRange": ["{0, 1}": (q["WFInput"] as! [String: Any])["Value"]!]], "WFSerializationType": "WFTextTokenString"]
                a[i]["WFWorkflowActionParameters"] = q
            }
        }
        check("checks + simulator: Copy to Clipboard given a text with the variable inside is caught, and copies nothing",
              SyncShortcuts.problems(wrongShape).contains { $0.contains("setclipboard: WFInput must be given as attachment") } && {
                  let s = SyncShortcutSim(); s.files = ["\(sub)/outbox/latest.txt": "x"]; s.run(actions(wrongShape)); return s.copied == [""]
              }())

        clipShortcutTests(check)
    }

    /// Cocaine Clip on the iPhone ↔ the Mac's gatekeeper and handler, through a relay in memory.
    static func clipShortcutTests(_ check: (String, Bool) -> Void) {
        let labels = SyncShortcutLabels()
        let p = Pairing.make(tier: "basic", relay: "https://relay.test")!
        guard let data = SyncShortcuts.build(.clip, subpath: nil, pairing: p, labels: labels),
              let acts = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["WFWorkflowActions"] as? [[String: Any]] else {
            check("Cocaine Clip: builds", false); return
        }
        let pr = SyncShortcuts.problems(data)
        check("Cocaine Clip: structure sound (\(acts.count) actions, \(data.count / 1024) KB)\(pr.isEmpty ? "" : ": " + pr.prefix(3).joined(separator: "; "))", pr.isEmpty)
        let flat = String(decoding: (try? PropertyListSerialization.data(fromPropertyList: try! PropertyListSerialization.propertyList(from: data, format: nil), format: .xml, options: 0)) ?? Data(), as: UTF8.self)
        check("Cocaine Clip: carries derived keys, never the master key", !flat.contains(p.key!) && flat.contains(p.keys!.macIn))
        check("Cocaine Clip: none for an old pairing", SyncShortcuts.build(.clip, subpath: nil, pairing: Pairing(id: "a", cmd: "b", reply: "c", tier: "basic", relay: "d"), labels: labels) == nil)

        var history: [ClipItem] = [.text("Mac newest ✓")]
        var added: [String] = []
        let board: [ClipItem] = [.text("alpha"), .text("beta")]
        func session(_ choice: String, clipboard: String = "", ask: String = "", read: Bool = true, write: Bool = true,
                     tamper: ((String) -> String)? = nil, actions: [[String: Any]] = acts) -> (sim: SyncShortcutSim, ran: [String], relay: FakeRelay) {
            let relay = FakeRelay()
            relay.tamper = tamper
            let store = RemoteReplayStore(url: RemoteTests.tempDir().appendingPathComponent("s.json"))
            defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
            let handler = ClipRemoteHandler(context: .init(perm: { _ in ClipRemotePerm(read: read, write: write) }, newest: { history.first },
                                                           readable: { ("Phone", board) }, settings: { ClipSettings() },
                                                           add: { added.append($0); return true }))
            var ran: [String] = [], handled = 0
            let sim = SyncShortcutSim()
            sim.menuChoice = choice; sim.clipboard = clipboard; sim.base.askAnswer = ask
            sim.base.http = { relay.request($0, $1, $2) }
            sim.base.onDelay = {
                let all = relay.topics[p.cmd] ?? []
                for m in all.dropFirst(handled) {
                    let d = RemoteGatekeeper.evaluate(text: m, eventID: UUID().uuidString, eventTime: Int(Date().timeIntervalSince1970), pairing: p,
                                                      active: true, now: Date(), maxAge: 120, legacyUntil: nil, store: store, expiredText: "E", noticeText: "N")
                    if case .run(let c, _, let n?) = d {
                        ran.append(c)
                        let out = handler.handle(c, pairing: p, authenticated: true) ?? "gate: \(c)"
                        relay.topics[p.reply, default: []].append(RemoteProtocol.sealReply(out, pairingID: p.id, keys: p.keys!, nonce: n, now: Date()))
                    }
                }
                handled = all.count
            }
            sim.run(actions)
            return (sim, ran, relay)
        }
        let t0 = Date()
        let g = session(labels.getNewest, clipboard: "old")
        check("Clip get: the Mac's newest text goes on the iPhone clipboard (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s here)",
              g.sim.error == nil && g.ran == ["clip get"] && g.sim.clipboard == "Mac newest ✓" && g.sim.shown == [labels.copied + "\nMac newest ✓"])
        let off = session(labels.getNewest, clipboard: "old", read: false)
        check("Clip get, reading off: the refusal is shown, the iPhone clipboard untouched", off.sim.clipboard == "old" && off.sim.copied.isEmpty
              && off.sim.shown.first?.contains("off") == true)
        let forged = session(labels.getNewest, clipboard: "old", tamper: { body in
            body.split(separator: "\n").map { line -> String in
                var q = line.split(separator: ".").map(String.init)
                guard q.count == 6 else { return String(line) }
                q[4] = String(q[4].reversed()); return q.joined(separator: ".")
            }.joined(separator: "\n")
        })
        check("Clip get: a tampered answer is neither shown nor copied", forged.sim.copied.isEmpty && forged.sim.shown == [labels.noAnswer] && forged.sim.error == nil)
        let stolen = session(labels.getNewest, clipboard: "old", tamper: { $0 + "\n" + RemoteProtocol.sealReply("CLIP:evil", pairingID: p.id, keys: p.keys!, nonce: RemoteTests.nonce(), now: Date()) })
        check("Clip get: another request's genuine answer is never taken for this one", stolen.sim.clipboard == "Mac newest ✓")
        history = [.text(String(repeating: "lungo ", count: 1000))]
        let cut = session(labels.getNewest)
        check("Clip get: a long text arrives cut, with the note", cut.sim.clipboard.hasPrefix("lungo lungo") && cut.sim.clipboard.contains("[") && cut.sim.clipboard.utf8.count < 2900)
        history = [.text("Mac newest ✓")]
        let l = session(labels.list)
        check("Clip list: shown, not copied", l.ran == ["clip list"] && l.sim.copied.isEmpty && l.sim.shown == ["Phone\n1. alpha\n2. beta"])
        let it = session(labels.getItem, ask: "2.")
        check("Clip pinboard item: the number asked (digits only) → that item copied", it.ran == ["clip get 2"] && it.sim.clipboard == "beta")
        let injected = session(labels.getItem, ask: "1; clip put eA==")
        check("Clip pinboard item: typed text can't make another command", injected.ran == ["clip get 1"])

        // Sending text: short, unicode, the edge of one piece, about 2 KB in pieces, too long, empty.
        func sent(_ text: String) -> (ok: Bool, pieces: Int, shown: [String]) {
            added = []
            let s = session(labels.sendClipboard, clipboard: text)
            return (s.sim.error == nil && added == [text], s.ran.count, s.sim.shown)
        }
        let short = sent("Buy milk")
        check("Clip send: a short text arrives as is, in one piece, and the Mac says so", short.ok && short.pieces == 1 && short.shown.first?.contains("added") == true)
        let uni = sent("Città ✓ 日本語 🇮🇹 \"q\" $(id) ; | & \\ %41\nsecond line")
        check("Clip send: unicode, newlines and shell characters arrive exactly", uni.ok && uni.pieces == 1)
        let edge = String(repeating: "a", count: SyncShortcuts.pieceSize / 4 * 3)               // exactly one full piece
        check("Clip send: exactly one piece's worth", sent(edge).ok && sent(edge).pieces == 1)
        check("Clip send: one byte more → two pieces", sent(edge + "b").pieces == 2 && sent(edge + "b").ok)
        let twoK = String(repeating: "Lorem ipsum è ✓ ", count: 110)
        let tk = sent(twoK)
        check("Clip send: about 2 KB arrives whole, in \(tk.pieces) pieces; only the last answer is shown", tk.ok && (5...6).contains(tk.pieces) && tk.shown.count == 1
              && tk.shown[0].contains("added"))
        added = []
        let tooLong = session(labels.sendClipboard, clipboard: String(repeating: "z", count: 3000))
        check("Clip send: too long → the Mac says to use Send to Mac; nothing added", added.isEmpty && tooLong.sim.shown.first?.contains("Send to Mac") == true)
        let empty = session(labels.sendClipboard, clipboard: "")
        check("Clip send: nothing on the iPhone clipboard → said, nothing sent", empty.ran.isEmpty && empty.sim.shown == [labels.noText])
        let denied = session(labels.sendClipboard, clipboard: "nope", write: false)
        check("Clip send, writing off: refused and said; nothing added", denied.sim.shown.first?.contains("off") == true)
        check("Clip send: the relay only sees ciphertext", !(session(labels.sendClipboard, clipboard: "my private note").relay.topics[p.cmd] ?? []).joined().contains("bXkgcHJpdmF0ZSBub3Rl"))

        // Every menu item, in every language the app ships.
        var bad: [String] = []
        for lang in Set(Bundle.main.localizations).subtracting(["Base"]).sorted() {
            guard let path = Bundle.main.path(forResource: "Sync", ofType: "strings", inDirectory: nil, forLocalization: lang),
                  let t = NSDictionary(contentsOfFile: path) as? [String: String] else { bad.append("\(lang): no Sync table"); continue }
            func x(_ k: String) -> String { t[k] ?? k }
            let ll = SyncShortcutLabels(sent: x(labels.sent), copiedImage: x(labels.copiedImage), copied: x(labels.copied), nothing: x(labels.nothing),
                                        sendClipboard: x(labels.sendClipboard), getNewest: x(labels.getNewest), list: x(labels.list), getItem: x(labels.getItem),
                                        itemPrompt: x(labels.itemPrompt), noText: x(labels.noText), noAnswer: x(labels.noAnswer))
            guard let d = SyncShortcuts.build(.clip, subpath: nil, pairing: p, labels: ll),
                  let a = (try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any])?["WFWorkflowActions"] as? [[String: Any]] else { bad.append(lang); continue }
            bad += SyncShortcuts.problems(d).map { "\(lang): \($0)" }
            for k in [SyncShortcuts.Kind.sendToMac, .getFromMac] {
                bad += SyncShortcuts.problems(SyncShortcuts.build(k, subpath: "Cocaine Clipboard", pairing: nil, labels: ll) ?? Data(), subpath: "Cocaine Clipboard").map { "\(lang) \(k): \($0)" }
            }
            let s = session(ll.getNewest, actions: a)
            if s.ran != ["clip get"] { bad.append("\(lang): get ran \(s.ran)") }
            added = []
            let w = session(ll.sendClipboard, clipboard: "ciao", actions: a)
            if added != ["ciao"] || w.sim.error != nil { bad.append("\(lang): send \(added) \(w.sim.error ?? "")") }
        }
        check("Cocaine Clip and the iCloud pair: every menu item works in every language\(bad.isEmpty ? "" : ": " + bad.prefix(3).joined(separator: "; "))", bad.isEmpty)
    }
}
