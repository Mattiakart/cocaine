// Tests of the clipboard's 2.7 features (part of --clipboard-test and --selftest): the schema 2 migration (fixture indexes as
// schema 1 wrote them), pinboards and their encrypted file with a memory-only history, pasting (a fake pasteboard and a fake
// event poster: no ⌘V is ever sent), formatting, transformations, selection and merging, the Paste Stack, snippets with
// hostile input, suggestions, text in images, Universal Clipboard, the command line's gates, and a 5,000-item search budget.
// Temporary folders, a fake Keychain and uniquely named pasteboards only: never the user's clipboard, files or Keychain.

import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation

final class FakePoster: PasteEventPoster {
    var posted: [CGKeyCode] = []
    var works = true
    func postPaste(keyCode: CGKeyCode) -> Bool { if works { posted.append(keyCode) }; return works }
}

enum PasteTests {
    static func run(_ root: URL) -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  clipboard: " + name); if !ok { failed += 1 } }
        let fm = FileManager.default
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func history(_ name: String, keys: MemoryKeyStore = MemoryKeyStore(), board: FakePasteboard = FakePasteboard(),
                     d: UserDefaults = MemoryDefaults()) -> ClipboardHistory {
            if d.data(forKey: ClipSettings.key) == nil { var s = ClipSettings(); s.maxAgeHours = 0; s.save(d) }   // fixed past dates stay
            let h = ClipboardHistory(defaults: d, dir: root.appendingPathComponent(name), keys: keys, board: board)
            h.frontApp = { "com.apple.TextEdit" }
            return h
        }
        let png = ClipboardTests.samplePNG()

        // MARK: schema 1 → 2
        do {
            let dir = root.appendingPathComponent("v1"), keys = MemoryKeyStore(), store = ClipStore(dir: dir, keys: keys)
            try? store.unlock()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let key = SymmetricKey(data: keys.key!)
            // Exactly what 2.6's synthesized Codable wrote: dates as seconds since 2001, `pinned`, no schema 2 field.
            let imgID = UUID(), textID = UUID(), favID = UUID()
            let v1 = """
            {"v":1,"items":[
             {"id":"\(textID.uuidString)","kind":"text","text":"old text","paths":[],"width":0,"height":0,"bytes":8,
              "digest":"\(ClipItem.digest(.text, Data("old text".utf8)))","date":780000000,"pinned":false,"source":"com.apple.TextEdit"},
             {"id":"\(favID.uuidString)","kind":"text","text":"old favorite","paths":[],"width":0,"height":0,"bytes":12,
              "digest":"\(ClipItem.digest(.text, Data("old favorite".utf8)))","date":779990000,"pinned":true},
             {"id":"\(imgID.uuidString)","kind":"image","text":"","paths":[],"width":4,"height":3,"bytes":\(png.count),
              "digest":"\(ClipItem.digest(.image, png))","date":779980000,"pinned":true}
            ]}
            """
            try? ClipCrypto.seal(Data(v1.utf8), key: key, context: "index").write(to: store.index)
            try? store.writeImage(imgID, png)
            let loaded = store.load()
            if loaded.items.count != 3 { print("note: v1 load \(loaded.problem) \(loaded.items.map(\.text))") }
            check("schema 1 index loads with schema 2 code (every item, nothing set aside)", loaded.problem == .none && loaded.items.count == 3
                  && loaded.items.map(\.text) == ["old text", "old favorite", ""] && loaded.items[0].source == "com.apple.TextEdit"
                  && !fm.fileExists(atPath: dir.appendingPathComponent("unreadable-").path))
            check("schema 1 favorites become the Favorites pinboard; new fields take defaults", loaded.items[1].boards == [ClipBoard.favoritesID]
                  && loaded.items[0].boards.isEmpty && loaded.items[0].title == nil && !loaded.items[0].hasRich && loaded.items[0].used.isEmpty
                  && loaded.items[2].isFavorite && store.readImage(imgID) == png)
            // Through the history: pinned items move to the pinboards' file, the index is written as schema 2, a restart reads both.
            let d = MemoryDefaults()
            var s = ClipSettings(); s.persist = true; s.maxAgeHours = 0; s.save(d)
            let h = ClipboardHistory(defaults: d, dir: dir, keys: keys, board: FakePasteboard())
            h.start(); h.stop()
            let idx = (try? ClipCrypto.open(Data(contentsOf: store.index), key: key, context: "index")).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            check("migration: the next save is schema 2, pinned items in boards.ccl, the image file kept",
                  idx?["v"] as? Int == 2 && (idx?["items"] as? [Any])?.count == 1 && fm.fileExists(atPath: store.boardsFile.path)
                  && fm.fileExists(atPath: store.blob(imgID).path))
            let again = ClipboardHistory(defaults: d, dir: dir, keys: keys, board: FakePasteboard())
            again.start(); again.stop()
            check("migration: a restart reads both files (3 items, favorites starred, image readable)", again.items.count == 3
                  && again.items.filter(\.isFavorite).count == 2 && again.items.first { $0.kind == .image }.map { again.imageData($0) == png } == true)
            // Newer than this version: set aside with its files, never misread, never deleted.
            let newer = "{\"v\":3,\"items\":[{\"id\":\"\(UUID().uuidString)\",\"kind\":\"hologram\"}]}"
            try? ClipCrypto.seal(Data(newer.utf8), key: key, context: "index").write(to: store.index)
            let n = store.load()
            let asides = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("unreadable-") }
            check("an index from a newer Cocaine is set aside (kept), not misread", n.problem == .unreadableIndex && n.items.isEmpty && asides.count == 1)
            // An item of a kind this version doesn't know: only that item is dropped.
            let mixed = "{\"v\":2,\"items\":[{\"id\":\"\(UUID().uuidString)\",\"kind\":\"text\",\"text\":\"fine\",\"date\":1,\"future\":{\"x\":1}},{\"id\":\"\(UUID().uuidString)\",\"kind\":\"hologram\"}]}"
            try? ClipCrypto.seal(Data(mixed.utf8), key: key, context: "index").write(to: store.index)
            let m = store.load()
            check("schema 2: unknown fields are ignored, an unknown kind drops only that item, a missing digest is worked out",
                  m.items.map(\.text) == ["fine"] && m.problem == .droppedItems(1) && m.items[0].digest == ClipItem.digest(.text, Data("fine".utf8)))
            // Encode → decode round trip of every schema 2 field.
            var full = ClipItem.text("round", rich: ClipRich(rtf: Data("{\\rtf1 x}".utf8), html: nil))
            full.title = "Named"; full.ocr = "words"; full.used = ["com.apple.Safari": 2]; full.lastUsed = t0; full.boards = [ClipBoard.favoritesID]
            full.snippet = SnippetInfo(hotkey: Shortcut(keyCode: 1, mods: Shortcut.hyper))
            let rt = (try? JSONEncoder().encode(full)).flatMap { try? JSONDecoder().decode(ClipItem.self, from: $0) }
            check("schema 2: every new field survives a round trip (formatting itself is not in the index)", rt?.title == "Named" && rt?.ocr == "words"
                  && rt?.used == ["com.apple.Safari": 2] && rt?.lastUsed == t0 && rt?.isFavorite == true && rt?.snippet == full.snippet
                  && rt?.hasRich == true && rt?.rich == nil)
        }

        // MARK: pinboards (pure)
        do {
            var b: [ClipBoard] = [.favorites]
            let p = PinboardRules.create(&b, name: "  Prompts ", color: 3)
            check("pinboards: create trims the name, keeps the colour", p?.name == "Prompts" && p?.color == 3 && b.count == 2)
            check("pinboards: names are unique (any case, accents), not empty, bounded", PinboardRules.create(&b, name: "PROMPTS") == nil
                  && PinboardRules.create(&b, name: "   ") == nil && PinboardRules.create(&b, name: String(repeating: "x", count: 41)) == nil
                  && PinboardRules.problem("Favorites", in: b) != nil || L("Favorites") != "Favorites")
            let code = PinboardRules.create(&b, name: "Code", icon: "terminal.fill")
            check("pinboards: rename refuses a taken name, takes a new one", !PinboardRules.rename(&b, code!.id, to: "prompts")
                  && PinboardRules.rename(&b, code!.id, to: "Snippets") && b.last?.name == "Snippets")
            PinboardRules.move(&b, code!.id, by: -5)
            check("pinboards: reorder (clamped)", b.map(\.id) == [code!.id, ClipBoard.favoritesID, p!.id])
            PinboardRules.move(&b, code!.id, before: p!.id)
            check("pinboards: move before another (drag in the settings)", b.map(\.id) == [ClipBoard.favoritesID, code!.id, p!.id])
            check("pinboards: Favorites is always there, duplicates and extras dropped", PinboardRules.normalized([p!, p!]).map(\.id) == [ClipBoard.favoritesID, p!.id]
                  && PinboardRules.normalized((0..<40).map { ClipBoard(name: "b\($0)") }).count == PinboardRules.maxBoards)
            let bad = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"x\",\"color\":99,\"icon\":\"evil; rm\",\"extra\":1}"
            let decoded = try? JSONDecoder().decode(ClipBoard.self, from: Data(bad.utf8))
            check("pinboards: a stored colour or symbol out of range is clamped or dropped", decoded?.color == BoardColor.count - 1 && decoded?.icon == nil)
            var core = ClipHistoryCore()
            let a = ClipItem.text("a", date: t0), c = ClipItem.text("c", date: t0 + 1)
            core.add(a); core.add(c)
            core.assign([a.id, c.id], to: p!.id); core.move([a.id], from: p!.id, to: code!.id)
            check("pinboards: an item can be on several; moving takes it off one and puts it on another",
                  core.items.first { $0.id == a.id }?.boards == [code!.id] && core.items.first { $0.id == c.id }?.boards == [p!.id])
            core.assign([c.id], to: ClipBoard.favoritesID); core.forgetBoard(p!.id)
            check("pinboards: deleting a pinboard takes its items off it only", core.items.first { $0.id == c.id }?.boards == [ClipBoard.favoritesID])
            var lim = ClipSettings(); lim.maxItems = 1; lim.maxAgeHours = 1
            core = ClipHistoryCore()
            var old = ClipItem.text("pinned old", date: t0 - 86400 * 30); old.boards = [p!.id]
            core.add(old); core.add(.text("x", date: t0)); core.add(.text("y", date: t0))
            core.prune(now: t0, settings: lim)
            check("pinboards: pinned items are never removed by the limits (age, count)", core.items.contains { $0.text == "pinned old" } && core.items.count == 2)
        }

        // MARK: pinboards saved with a memory-only history
        do {
            let keys = MemoryKeyStore(), fb = FakePasteboard(), d = MemoryDefaults()
            let h = history("pb", keys: keys, board: fb, d: d)
            fb.put(ClipSnapshot(types: ["public.utf8-plain-text"], text: "keep me pinned")); h.captureNow()
            fb.put(ClipSnapshot(types: ["public.utf8-plain-text"], text: "memory only")); h.captureNow()
            fb.put(ClipSnapshot(types: ["public.png"], image: png, width: 4, height: 3)); h.captureNow()
            let dir = root.appendingPathComponent("pb")
            check("history off: nothing on disk before anything is pinned", !fm.fileExists(atPath: dir.path) && keys.key == nil)
            let prompts = h.createBoard("Prompts", color: 2)
            h.pin([h.items.first { $0.text == "keep me pinned" }!.id], to: prompts!.id)
            h.pin([h.items.first { $0.kind == .image }!.id], to: ClipBoard.favoritesID)
            h.flush()
            let boardsFile = dir.appendingPathComponent("boards.ccl")
            let raw = (try? Data(contentsOf: boardsFile)) ?? Data()
            check("history off: pinning saves boards.ccl (encrypted: no name, no text readable), never the history",
                  !h.saving && h.boardsOpen && !raw.isEmpty && raw.range(of: Data("keep me pinned".utf8)) == nil && raw.range(of: Data("Prompts".utf8)) == nil
                  && !fm.fileExists(atPath: dir.appendingPathComponent("index.ccl").path) && keys.key != nil)
            func perms(_ u: URL) -> Int { ((try? fm.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
            check("history off: the pinboards' files are 0600 in a 0700 folder", perms(dir) == 0o700 && perms(boardsFile) == 0o600)
            let back = history("pb", keys: keys, board: FakePasteboard(), d: d)
            back.start(); back.stop()
            check("history off: a restart brings back the pinboards and pinned items (image too), not the rest",
                  Set(back.items.map(\.text)) == Set(["keep me pinned", ""]) && back.boards.map(\.displayName).contains("Prompts")
                  && back.items.first { $0.kind == .image }.map { back.imageData($0) == png } == true)
            let wrong = history("pb", keys: MemoryKeyStore(), board: FakePasteboard(), d: d)
            wrong.start(); wrong.stop()
            let asides = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("unreadable-") }
            check("pinboards: another key can't read them (set aside, nothing deleted, starts empty)", wrong.items.isEmpty && asides.count == 1
                  && fm.fileExists(atPath: dir.appendingPathComponent(asides[0]).appendingPathComponent("boards.ccl").path)
                  && ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".img") })
            // Unpinning with a memory-only history: the item stays (in memory), its file goes.
            let h2 = history("pb2", keys: MemoryKeyStore())
            h2.add(.image(png: png, width: 4, height: 3)); let img = h2.items[0]
            h2.pin([img.id], to: ClipBoard.favoritesID); h2.flush()
            let blob = h2.store.blob(img.id)
            let written = fm.fileExists(atPath: blob.path)
            h2.unpin([img.id], from: ClipBoard.favoritesID); h2.flush()
            check("history off: unpinning keeps the item in memory (image readable), removes its file", written && !fm.fileExists(atPath: blob.path)
                  && h2.imageData(h2.items[0]) == png)
            h2.pin([img.id], to: ClipBoard.favoritesID)
            let b2 = h2.createBoard("Temp")!
            h2.pin([img.id], to: b2.id)
            h2.deleteBoard(b2.id); h2.deleteBoard(ClipBoard.favoritesID)
            check("pinboards: deleting one takes its items off it; Favorites can't be deleted", h2.items[0].boards == [ClipBoard.favoritesID]
                  && h2.boards.contains { $0.isFavorites } && !h2.boards.contains { $0.id == b2.id })
            h2.deleteEverything()
            check("delete everything: pinboards gone too (only Favorites, empty), files and key gone", h2.items.isEmpty && h2.boards == [.favorites]
                  && !fm.fileExists(atPath: root.appendingPathComponent("pb2").path))
        }

        // MARK: Universal Clipboard (another device)
        do {
            let fb = FakePasteboard(), h = history("remote", board: fb)
            h.frontApp = { "com.apple.Safari" }
            var on = h.settings; on.includeRemote = true; h.update(on)          // off by default since 2.9 (Sources/Basics.swift)
            fb.put(ClipSnapshot(types: ["public.utf8-plain-text", ClipRules.remoteType], text: "from my iPhone")); h.captureNow()
            check("Universal Clipboard: a copy marked com.apple.is-remote-clipboard is from another device, not the app in front",
                  h.items.first?.source == ClipRules.remoteSource && h.items.first?.remote == true && ClipboardHistory.appName(ClipRules.remoteSource) == L("Another device"))
            var ex = h.settings; ex.excludedApps = ["com.apple.Safari"]; h.update(ex)
            fb.put(ClipSnapshot(types: ["public.utf8-plain-text", ClipRules.remoteType], text: "phone again")); h.captureNow()
            check("Universal Clipboard: the app in front being excluded doesn't drop another device's copy", h.items.first?.text == "phone again")
            var off = h.settings; off.includeRemote = false; h.update(off)
            check("Universal Clipboard: turning other devices off removes their unpinned copies", !h.items.contains { $0.remote })
            let reads = fb.dataReads
            fb.put(ClipSnapshot(types: ["public.utf8-plain-text", ClipRules.remoteType], text: "not wanted")); h.captureNow()
            check("Universal Clipboard: with other devices off, their copies aren't kept, or even read", h.items.isEmpty && fb.dataReads == reads
                  && ClipRules.decide(ClipSnapshot(types: [ClipRules.remoteType], text: "x"), settings: off) == .skip(.remote))
            let pb = NSPasteboard(name: NSPasteboard.Name("local.cocaine.remotetest.\(getpid()).\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            pb.clearContents(); pb.setString("handoff", forType: .string); pb.setData(Data(), forType: NSPasteboard.PasteboardType(ClipRules.remoteType))
            let snap = SystemPasteboard(pb).snapshot(maxImageBytes: 1_000_000) { _, _ in true }
            check("Universal Clipboard: the real pasteboard code sees the marker", snap.remote && snap.text == "handoff")
            check("search: from:device and from:mac", ClipQuery.parse("from:iphone").remote == true && ClipQuery.parse("from:mac").remote == false)
        }

        // MARK: formatting (rich flavours)
        do {
            let pb = NSPasteboard(name: NSPasteboard.Name("local.cocaine.richtest.\(getpid()).\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            let sys = SystemPasteboard(pb)
            let bold = NSAttributedString(string: "bold words", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            let rtf = try! bold.data(from: NSRange(location: 0, length: bold.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let html = Data("<b>bold words</b>".utf8)
            pb.clearContents(); pb.setString("bold words", forType: .string); pb.setData(rtf, forType: .rtf); pb.setData(html, forType: .html)
            let s = sys.snapshot(maxImageBytes: 1_000_000) { _, _ in true }
            check("formatting: RTF and HTML are kept with the plain text", s.text == "bold words" && s.rich?.rtf == rtf && s.rich?.html == html)
            guard case .keep(let item) = ClipRules.decide(s, settings: ClipSettings()) else { check("formatting: kept", false); return failed }
            check("formatting: the item counts its formatting in its size; the plain text is what's searched", item.hasRich && item.bytes == 10 + rtf.count + html.count
                  && ClipHistoryCore.matches(item, "BOLD") && !ClipHistoryCore.matches(item, "rtf1"))
            _ = sys.write(item, payload: nil, rich: item.rich)
            check("formatting: pasted rich, it has RTF and HTML again", pb.data(forType: .rtf) == rtf && pb.data(forType: .html) == html && pb.string(forType: .string) == "bold words")
            _ = sys.write(item, payload: nil, rich: nil)
            check("formatting: pasted plain, it has the text only", pb.data(forType: .rtf) == nil && pb.data(forType: .html) == nil && pb.string(forType: .string) == "bold words")
            check("formatting: too big for the item limit, the formatting goes, not the text", {
                var tiny = ClipSettings(); tiny.maxItemMB = 1
                let big = ClipSnapshot(types: ["public.utf8-plain-text"], text: "t", rich: ClipRich(rtf: Data(count: 999_999), html: Data(count: 500_000)))
                if case .keep(let i) = ClipRules.decide(big, settings: tiny) { return i.rich?.rtf?.count == 999_999 && i.rich?.html == nil }
                return false
            }())
            check("formatting: bounded: both, else RTF, else HTML, else none", ClipRich.bounded(rtf: Data(count: 10), html: Data(count: 10), limit: 15)?.html == nil
                  && ClipRich.bounded(rtf: Data(count: 20), html: Data(count: 10), limit: 15)?.rtf == nil
                  && ClipRich.bounded(rtf: Data(count: 20), html: Data(count: 20), limit: 15) == nil)
            // Through the history: "paste plain by default", and ⇧ for the other way.
            let fb = FakePasteboard(), h = history("rich", board: fb)
            h.add(item)
            h.copy(h.items[0])
            let richByDefault = fb.writtenRich.last??.rtf == rtf
            h.copy(h.items[0], plain: true)
            let plainAsked = fb.writtenRich.last! == nil
            var s2 = h.settings; s2.pastePlain = true; h.update(s2)
            h.copy(h.items[0])
            check("formatting: rich by default, plain when asked; 'Paste without formatting' makes plain the default",
                  richByDefault && plainAsked && fb.writtenRich.last! == nil)
            // Saved: the formatting has its own encrypted file and comes back.
            let keys = MemoryKeyStore(), d = MemoryDefaults()
            let ph = history("richsave", keys: keys, d: d)
            ph.setPersist(true); ph.add(item); ph.flush()
            let blob = ph.store.blob(ph.items[0].id, .rich)
            let reopened = history("richsave", keys: keys, d: d); reopened.start(); reopened.stop()
            check("formatting: saved in its own encrypted file (not readable), read back when pasting", fm.fileExists(atPath: blob.path)
                  && ((try? Data(contentsOf: blob))?.range(of: html) == nil) && reopened.richData(reopened.items[0])?.rtf == rtf)
        }

        // MARK: direct paste (fake pasteboard, fake poster: no real ⌘V)
        do {
            let fb = FakePasteboard(), h = history("paste", board: fb)
            h.add(.text("hello paste", date: t0))
            let e = PasteEngine(history: h), poster = FakePoster()
            e.poster = poster; e.after = { _, f in f() }; e.modifiersDown = { false }; e.trusted = { true }
            e.frontApp = { "com.apple.TextEdit" }; e.ownBundle = "local.cocaine.toggle"
            var closed = 0; e.closeIsland = { closed += 1 }
            var notes: [String] = []; e.notify = { _, t in notes.append(t) }
            var out: PasteEngine.Outcome?
            e.paste(h.items[0]) { out = $0 }
            check("paste: copies, closes the island, sends ⌘V to the app in front, notes where it went", out == .pasted("com.apple.TextEdit")
                  && fb.written.last?.text == "hello paste" && closed == 1 && poster.posted == [CGKeyCode(kVK_ANSI_V)] && h.items[0].used["com.apple.TextEdit"] == 1)
            e.trusted = { false }
            e.paste(h.items[0]) { out = $0 }
            check("paste: without Accessibility it only copies, and says so in one line", out == .copied(.noPermission) && poster.posted.count == 1
                  && notes.last == L("Copied: press ⌘V (allow Accessibility to paste directly)"))
            e.trusted = { true }; e.frontApp = { "local.cocaine.toggle" }
            e.paste(h.items[0]) { out = $0 }
            check("paste: never into Cocaine itself (copy only)", out == .copied(.noTarget) && poster.posted.count == 1)
            var app = "com.apple.TextEdit"
            e.frontApp = { app }
            e.after = { _, f in app = "com.apple.Terminal"; f() }
            e.paste(h.items[0]) { out = $0 }
            check("paste: if another app came to the front meanwhile, no ⌘V (copy only)", out == .copied(.targetChanged) && poster.posted.count == 1)
            e.after = { _, f in f() }; app = "com.apple.TextEdit"
            var held = 3
            e.modifiersDown = { held -= 1; return held > 0 }
            e.paste(h.items[0]) { out = $0 }
            check("paste: waits for the shortcut's keys to be let go", out == .pasted("com.apple.TextEdit") && held == 0 && poster.posted.count == 2)
            e.modifiersDown = { false }
            var s = h.settings; s.directPaste = false; h.update(s)
            e.paste(h.items[0]) { out = $0 }
            check("paste: direct paste off copies only", out == .copied(.directOff) && poster.posted.count == 2)
            s.directPaste = true; h.update(s)
            e.paste(.files(["/nonexistent/x-\(UUID().uuidString)"])) { out = $0 }
            check("paste: a file that is gone fails, nothing sent", out == .failed && poster.posted.count == 2)
            check("paste: ⌘V is the key that types v on the layout in use", PasteEngine.vKeyCode(translate: { $0 == 47 ? "v" : $0 == 9 ? "." : nil }) == 47
                  && PasteEngine.vKeyCode(translate: { _ in nil }) == CGKeyCode(kVK_ANSI_V))
            PasteHook.paste = nil
            ClipboardWiring.registerHooks(history: h, engine: e)
            h.add(.text("via hook"))
            PasteHook.paste?(h.items[0].id.uuidString, true)
            check("paste: PasteHook.paste is registered and pastes by id", fb.written.last?.text == "via hook" && poster.posted.count == 3)
            PasteHook.paste = nil; AIContextHook.add = nil
            // Several at once, the Paste Stack.
            h.add(.text("one", date: t0 + 10)); h.add(.text("two", date: t0 + 11)); h.add(.files(["/tmp"], date: t0 + 12)); h.add(.image(png: png, width: 4, height: 3, date: t0 + 13))
            let pick = ["one", "two"].map { t in h.items.first { $0.text == t }! } + [h.items.first { $0.kind == .files }!, h.items.first { $0.kind == .image }!]
            e.pasteTogether(pick) { out = $0 }
            check("paste together: in the order picked, with the separator, files as paths, images left out",
                  fb.written.last?.text == "one\ntwo\n/tmp" && out == .pasted("com.apple.TextEdit"))
            e.startStack(pick.map(\.id))
            var pasted: [String] = []
            while e.pasteNext() { pasted.append(fb.written.last?.kind == .image ? "image" : fb.written.last?.text ?? "?") }
            check("Paste Stack: each 'Paste next' pastes the next in order, then it is empty", pasted == ["one", "two", "", "image"] && e.stack.isEmpty
                  && fb.written.count >= 4)
            var st = PasteStack(queue: [pick[0].id, pick[1].id, pick[0].id]); st.reverse()
            check("Paste Stack: no item twice; reverse", st.queue == [pick[1].id, pick[0].id])
            e.startStack([UUID(), pick[0].id])
            check("Paste Stack: an item deleted meanwhile is skipped", e.pasteNext() && fb.written.last?.text == "one")
            check("Paste Stack: 'Paste next' is registered only while a stack waits", ClipHotKeys.wanted(settings: h.settings, stackActive: true, boards: [], items: []).filter { $0.0 != .open }.count == 1
                  && ClipHotKeys.wanted(settings: h.settings, stackActive: false, boards: [], items: []).filter { $0.0 != .open }.isEmpty)
        }

        // MARK: selection and merge (reducers)
        do {
            let ids = (0..<6).map { _ in UUID() }
            var s = ClipSelection()
            s.only(ids[1]); s.toggle(ids[4]); s.toggle(ids[2])
            check("selection: ⌘-click adds in the order picked, again removes", s.ids == [ids[1], ids[4], ids[2]])
            s.toggle(ids[4])
            check("selection: …and removes", s.ids == [ids[1], ids[2]])
            s.only(ids[1]); s.extend(to: ids[3], in: ids)
            check("selection: ⇧-click selects the range from the anchor", s.ids == [ids[1], ids[2], ids[3]])
            s.extend(to: ids[0], in: ids)
            check("selection: ⇧-click the other way, from the same anchor", s.ids == [ids[0], ids[1]])
            s.clear()
            var cur = s.step(1, from: ids[2], in: ids); cur = s.step(1, from: cur, in: ids)
            check("selection: ⇧↓ twice from a row: three rows", s.ids == [ids[2], ids[3], ids[4]] && cur == ids[4])
            s.selectAll(ids); s.keep(Set(ids.prefix(3)))
            check("selection: ⌘A, and deleted items leave the selection", s.ids == Array(ids.prefix(3)) && s.ordered(in: ids.reversed()) == Array(ids.prefix(3)).reversed())
            let h = history("merge")
            h.add(.text("alpha", date: t0)); h.add(.text("beta", date: t0 + 1))
            var sep = h.settings; sep.separator = "comma"; h.update(sep)
            let merged = h.merge([h.items[1].id, h.items[0].id])
            check("merge: a new text item with the separator, originals kept", merged?.text == "alpha, beta" && h.items.count == 3 && h.items[0].id == merged?.id)
            check("merge: needs two items with text", h.merge([h.items[0].id]) == nil
                  && ClipMerge.text([.image(png: png, width: 1, height: 1)], separator: "\n") == nil)
            h.remove([h.items[0].id, h.items[1].id])
            let undone = h.undoRemove()
            check("delete: Undo brings the items back where they were", undone == 2 && h.items.count == 3 && h.items[0].text == "alpha, beta")
        }

        // MARK: transformations
        do {
            check("transform: case", ClipTransform.upper.apply("Ciao è") == "CIAO È" && ClipTransform.lower.apply("ABC") == "abc"
                  && ClipTransform.title.apply("hello world") == "Hello World")
            check("transform: trim, join lines, sort, unique", ClipTransform.trim.apply("  a  \n b ") == "a\nb" && ClipTransform.singleLine.apply("a\n\n b\n") == "a b"
                  && ClipTransform.sortLines.apply("b\na10\na2") == "a2\na10\nb" && ClipTransform.uniqueLines.apply("x\ny\nx") == "x\ny")
            check("transform: JSON pretty and compact; not JSON: not offered", ClipTransform.jsonPretty.apply("{\"b\":1,\"a\":[1,2]}") == "{\n  \"a\" : [\n    1,\n    2\n  ],\n  \"b\" : 1\n}"
                  && ClipTransform.jsonMinify.apply("{ \"a\" : 1 }") == "{\"a\":1}" && ClipTransform.jsonPretty.apply("not json {") == nil)
            check("transform: URL and Base64 both ways", ClipTransform.urlDecode.apply("a%20b%2Fc") == "a b/c" && ClipTransform.urlEncode.apply("a b&c") == "a%20b%26c"
                  && ClipTransform.base64Encode.apply("hi") == "aGk=" && ClipTransform.base64Decode.apply("aGk=") == "hi" && ClipTransform.base64Decode.apply("@@@") == nil)
            check("transform: link tracking removed, other parameters kept", ClipTransform.stripTracking.apply("see https://x.com/p?id=3&utm_source=a&fbclid=z ok")
                  == "see https://x.com/p?id=3 ok" && ClipTransform.stripTracking.apply("https://x.com/p?id=3") == nil)
            check("transform: only those that change the text are offered; huge input is refused", !ClipTransform.applicable(to: "ABC").contains(.upper)
                  && ClipTransform.upper.apply(String(repeating: "a", count: ClipTransform.maxInput + 1)) == nil)
        }

        // MARK: snippets (placeholders, hostile input)
        do {
            var c = SnippetExpander.Context(clipboard: "CLIP {date} {input:x}", now: t0, locale: Locale(identifier: "en_US_POSIX"), inputs: ["Name": "Ann {clipboard}"])
            check("snippet: placeholders filled", SnippetExpander.expand("Hi {input:Name}, {date:yyyy}", c) == "Hi Ann {clipboard}, 2026")
            check("snippet: a value is never expanded again (one pass)", SnippetExpander.expand("{clipboard}", c) == "CLIP {date} {input:x}")
            check("snippet: unknown placeholders and stray braces stay as typed; {{ }} are braces", SnippetExpander.expand("{nope} { open {{x}} }x{", c) == "{nope} { open {x} }x{")
            check("snippet: inputs found once each, in order, bounded in number and length",
                  SnippetExpander.inputs(in: "{input:A}{input:B}{input:A}{input:C}{input:D}{input:E}{input:F}{input:\(String(repeating: "n", count: 50))}") == ["A", "B", "C", "D", "E"])
            c.clipboard = String(repeating: "x", count: 5_000_000)
            check("snippet: a huge clipboard is bounded", SnippetExpander.expand("{clipboard}{clipboard}{clipboard}{clipboard}{clipboard}{clipboard}", c).count == SnippetExpander.maxResult)
            check("snippet: a long or multi-line brace isn't a placeholder", SnippetExpander.tokens("{" + String(repeating: "a", count: 70) + "}") == [.text("{" + String(repeating: "a", count: 70) + "}")]
                  && SnippetExpander.tokens("{a\nb}") == [.text("{a\nb}")])
            check("snippet: a bad date pattern doesn't crash", !SnippetExpander.expand("{date:''''''}", c).isEmpty)
            // Through the paste engine, with the inputs answered by a stand-in.
            let fb = FakePasteboard(), h = history("snip", board: fb)
            fb.content.text = "on the clipboard"
            var sn = ClipItem.text("To {input:Who}: {clipboard}"); sn.snippet = SnippetInfo(); sn.boards = [ClipBoard.favoritesID]
            h.add(sn)
            let e = PasteEngine(history: h); let poster = FakePoster()
            e.poster = poster; e.after = { _, f in f() }; e.modifiersDown = { false }; e.trusted = { true }; e.frontApp = { "com.apple.Mail" }
            let realAsk = SnippetPaste.ask
            SnippetPaste.ask = { names, done in done(Dictionary(uniqueKeysWithValues: names.map { ($0, "Bob") })) }
            SnippetPaste.paste(h.items[0], engine: e)
            let filled = fb.written.last?.text
            SnippetPaste.ask = { _, done in done(nil) }
            let before = fb.written.count
            SnippetPaste.paste(h.items[0], engine: e)
            SnippetPaste.ask = realAsk
            check("snippet: pasted with its placeholders filled; cancelling a question pastes nothing", filled == "To Bob: on the clipboard"
                  && fb.written.count == before && poster.posted.count == 1)
            var plain = ClipItem.text("literal {date}"); plain.boards = []
            h.add(plain)
            e.paste(h.items[0])
            check("snippet: an ordinary item's braces are pasted as they are", fb.written.last?.text == "literal {date}")
            let hk = Shortcut(keyCode: UInt32(kVK_ANSI_S), mods: Shortcut.ctrl | Shortcut.opt | Shortcut.cmd)
            var withKey = h.items.first { $0.snippet != nil }!; withKey.snippet?.hotkey = hk
            check("snippet: its global shortcut is wanted only while it is pinned", ClipHotKeys.wanted(settings: h.settings, stackActive: false, boards: [], items: [withKey]).filter { $0.0 != .open }.first?.0 == .snippet(withKey.id)
                  && ClipHotKeys.wanted(settings: h.settings, stackActive: false, boards: [], items: [{ var x = withKey; x.boards = []; return x }()]).filter { $0.0 != .open }.isEmpty)
            check("snippet: a shortcut the app or another clipboard shortcut uses is refused, a plain key too",
                  ClipHotKeys.problem(Shortcut(keyCode: UInt32(kVK_ANSI_C), mods: Shortcut.hyper), for: .snippet(UUID()), settings: h.settings, boards: [], items: [],
                                      appShortcuts: [Shortcut(keyCode: UInt32(kVK_ANSI_C), mods: Shortcut.hyper)], system: []) != nil
                  && ClipHotKeys.problem(hk, for: .board(UUID()), settings: h.settings, boards: [], items: [withKey], appShortcuts: [], system: []) != nil
                  && ClipHotKeys.problem(hk, for: .snippet(withKey.id), settings: h.settings, boards: [], items: [withKey], appShortcuts: [], system: []) == nil
                  && ClipHotKeys.problem(Shortcut(keyCode: UInt32(kVK_ANSI_S), mods: 0), for: .snippet(UUID()), settings: h.settings, boards: [], items: [], appShortcuts: [], system: []) != nil)
            var reg: [UInt32: Shortcut] = [:], unreg = 0
            let keys = ClipHotKeys(register: { s, id in
                if s == hk { return (-9878, nil) }
                reg[id] = s; return (noErr, OpaquePointer(bitPattern: Int(id) * 16))
            }, unregister: { _ in unreg += 1 })
            let other = Shortcut(keyCode: UInt32(kVK_ANSI_B), mods: Shortcut.hyper)
            let bid = UUID()
            keys.apply([(.snippet(withKey.id), hk), (.board(bid), other)])
            check("clipboard shortcuts: registered with their own ids; one taken by another app is reported", keys.registeredCount == 1 && keys.status[.snippet(withKey.id)] == -9878
                  && keys.status[.board(bid)] == noErr && keys.targets[2] == .board(bid))
            keys.apply([])
            check("clipboard shortcuts: all let go", keys.registeredCount == 0 && unreg == 1)
        }

        // MARK: search filters and suggestions
        do {
            let q = ClipQuery.parse("type:image app:Safari board:\"My board\" date:7d hello", now: t0)
            check("search: filters parsed, quotes kept together, the rest are words", q.kinds == [.image] && q.apps == ["Safari"] && q.boards == ["My board"]
                  && q.since == t0 - 7 * 86400 && q.words == ["hello"])
            check("search: unknown filters are words", ClipQuery.parse("foo:bar type:nonsense").words == ["foo:bar", "type:nonsense"])
            check("search: links and colours", ClipLooks.isLink("https://github.com/x") && !ClipLooks.isLink("see https://x.com") && ClipLooks.isLink("www.apple.com")
                  && ClipLooks.color("#ff8000")?.g == Double(0x80) / 255 && ClipLooks.color("rgb(255, 0, 0)")?.r == 1 && ClipLooks.color("123456") == nil
                  && ClipLooks.color("#12345") == nil && ClipLooks.color("rgba(10,10,10,2)") == nil)
            let h = history("search")
            h.now = { t0 + 60 }
            var a = ClipItem.text("https://apple.com", date: t0, source: "com.apple.Safari"); a.boards = [ClipBoard.favoritesID]
            h.add(a); h.add(.text("#ffffff", date: t0 + 1)); h.add(.image(png: png, width: 4, height: 3, date: t0 - 30 * 86400))
            let o = h.items.first { $0.kind == .image }!; h.modify(o.id) { $0.ocr = "Invoice 2026" }
            func got(_ s: String, board: UUID? = nil, kind: ClipQuery.Kind? = nil) -> [String] { h.query = s; return h.listed(board: board, kind: kind).map { $0.kind == .image ? "img" : $0.text } }
            check("search: type:link, type:color, a board, an app, a date", got("type:link") == ["https://apple.com"] && got("type:colour") == ["#ffffff"]
                  && got("", board: ClipBoard.favoritesID) == ["https://apple.com"] && got("app:safari") == ["https://apple.com"]
                  && got("date:7d").count == 2 && got("", kind: .image) == ["img"])
            check("search: the text found in an image", got("invoice") == ["img"])
            h.query = ""
            var used = ClipItem.text("SELECT * FROM t", date: t0 - 3 * 86400); used.used = ["com.tableplus": 4]
            var copiedThere = ClipItem.text("from tableplus", date: t0, source: "com.tableplus")
            copiedThere.date = t0 - 86400
            let sql = ClipBoard(name: "SQL", app: "com.tableplus")
            var onBoard = ClipItem.text("tied", date: t0 - 10 * 86400); onBoard.boards = [sql.id]
            let list = [ClipItem.text("latest", date: t0, source: "com.tableplus"), used, copiedThere, onBoard, .text("unrelated", date: t0)]
            let r = ClipSuggest.rank(list, front: "com.tableplus", boards: [.favorites, sql], now: t0)
            check("suggestions: pasted there first, then its pinboard and what was copied there; never the item on the clipboard now",
                  r.map(\.text) == ["SELECT * FROM t", "tied", "from tableplus"] || r.map(\.text) == ["SELECT * FROM t", "from tableplus", "tied"])
            check("suggestions: nothing for an unknown app or none in front", ClipSuggest.rank(list, front: "com.other", boards: [sql], now: t0).isEmpty
                  && ClipSuggest.rank(list, front: nil, boards: [sql], now: t0).isEmpty)
            // 5,000 items stay responsive: one search with filters within a time budget.
            let big = history("perf")
            var many: [ClipItem] = []
            for i in 0..<5_000 { many.append(.text("item number \(i) with some ordinary words to look through, café \(i % 97)", date: t0 - Double(i), source: i % 3 == 0 ? "com.apple.Safari" : "com.apple.Notes")) }
            big.replace(many)
            let start = Date()
            big.query = "cafe 42 app:notes"
            let found = big.listed(board: nil, kind: .text).count
            big.query = "zzz-not-there"
            let none = big.listed(board: nil, kind: nil).count
            let took = Date().timeIntervalSince(start)
            check(String(format: "search: 5,000 items, two searches in %.0f ms (budget 600 ms)", took * 1000), took < 0.6 && found > 0 && none == 0)
        }

        // MARK: text in images (Vision, on this Mac)
        do {
            let size = NSSize(width: 520, height: 140)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
            NSString(string: "COCAINE 2026").draw(at: NSPoint(x: 24, y: 40), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 56), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            let img = rep.representation(using: .png, properties: [:])!
            let text = ClipOCR.recognize(img, languages: ["en-US"])
            check("text in images: Vision reads a generated image (\(text ?? "nothing"))", text?.uppercased().contains("COCAINE") == true && text?.contains("2026") == true)
            check("text in images: kept for search with secrets masked, bounded", ClipOCR.stored("key ghp_aBcD1234eFgH5678iJkL9012mNoP3456qRsT here") == "key ••• here"
                  && ClipOCR.stored(String(repeating: "a ", count: 5_000)).count == ClipItem.maxOCR)
            let h = history("ocr")
            h.add(.image(png: img, width: 520, height: 140))
            var done = false
            h.recognizeText(h.items[0], store: true) { _ in done = true }
            let until = Date().addingTimeInterval(20)
            while !done && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            h.query = "cocaine"
            check("text in images: stored with the item, the image is found by its words", done && h.visible.count == 1)
            h.query = ""
        }

        // MARK: the command line (`cocaine clip`), its gates
        do {
            let dir = URL(fileURLWithPath: "/tmp/cc-\(getpid())-\(UUID().uuidString.prefix(4))")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: dir) }
            let sock = dir.appendingPathComponent("clip.sock").path, keyPath = dir.appendingPathComponent("clip.key").path
            let fb = FakePasteboard(), h = history("cli", board: fb)
            h.add(.text("first secret-free text", date: t0)); h.add(.text("second", date: t0 + 1))
            let e = PasteEngine(history: h); let poster = FakePoster()
            e.poster = poster; e.after = { _, f in f() }; e.modifiersDown = { false }; e.trusted = { true }; e.frontApp = { "com.apple.Terminal" }
            let server = ClipServer()
            server.handle = { v, a in ClipCLIHandler.reply(v, a, history: h, engine: e) }
            check("command line: the socket starts, 0600, with its own key (0600)", server.start(socket: sock, keyPath: keyPath) && {
                var st = stat(); return lstat(sock, &st) == 0 && st.st_mode & 0o777 == 0o600 && lstat(keyPath, &st) == 0 && st.st_mode & 0o777 == 0o600 }())
            func ask(_ verb: String, _ args: [String: Any] = [:]) -> [String: Any]? {
                var out: [String: Any]?, finished = false
                DispatchQueue.global().async { out = ClipCLI.send(verb: verb, args: args, socket: sock, keyPath: keyPath, timeout: 5); finished = true }
                let until = Date().addingTimeInterval(8)
                while !finished && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                return out
            }
            var r = ask("list")
            check("command line: off by default, nothing is read", r?["ok"] as? Bool == false && r?["code"] as? Int == 69 && h.settings.cliAccess == 0)
            var s = h.settings; s.cliAccess = 1; h.update(s)
            r = ask("put", ["text": "from the terminal", "title": "T"])
            let added = h.items.first?.text == "from the terminal" && h.items.first?.title == "T"
            let listRefused = ask("list")?["code"] as? Int == 77, getRefused = ask("get", ["index": 1])?["code"] as? Int == 77
            let pasteRefused = ask("paste", ["index": 1])?["code"] as? Int == 77
            check("command line: 'Add only' adds, but can't list, get or paste", r?["ok"] as? Bool == true && added && listRefused && getRefused && pasteRefused && poster.posted.isEmpty)
            r = ask("put", ["text": "ghp_aBcD1234eFgH5678iJkL9012mNoP3456qRsT"])
            check("command line: the secrets filter applies to what it adds", r?["ok"] as? Bool == false && !h.items.contains { $0.text.hasPrefix("ghp_") })
            s.cliAccess = 2; h.update(s)
            r = ask("list", ["limit": 2])
            let rows = r?["items"] as? [[String: Any]]
            let got = ask("get", ["index": 2])?["text"] as? String
            _ = ask("paste", ["index": 3])
            check("command line: full access lists, gets and pastes (⌘V to the app in front)", rows?.count == 2 && rows?[0]["title"] as? String == "T"
                  && got == "second" && poster.posted.count == 1 && fb.written.last?.text == "first secret-free text")
            let p = h.createBoard("Prompts")!
            _ = ask("put", ["text": "to a board", "board": "prompts"])
            check("command line: put onto a pinboard by name; get from it", h.items.first { $0.text == "to a board" }?.boards == [p.id]
                  && ask("get", ["board": "Prompts", "index": 1])?["text"] as? String == "to a board" && ask("get", ["board": "Nope"])?["ok"] as? Bool == false)
            // Forged, stale and replayed requests.
            let key = ApprovalKey.read(keyPath)!
            func raw(_ line: Data) -> [String: Any]? {
                var out: [String: Any]?, finished = false
                DispatchQueue.global().async {
                    let fd = ApprovalServer.connect(sock)
                    if fd >= 0 {
                        _ = line.withUnsafeBytes { ApprovalServer.writeAll(fd, $0) }
                        var buf = [UInt8](repeating: 0, count: 65_536); let n = read(fd, &buf, buf.count)
                        if n > 0 { out = (try? JSONSerialization.jsonObject(with: Data(buf[0..<n]))) as? [String: Any] }
                        close(fd)
                    }
                    finished = true
                }
                let until = Date().addingTimeInterval(8)
                while !finished && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                return out
            }
            let forged = ClipCLIWire.request(key: Data(repeating: 7, count: 32), verb: "list", args: [:])!
            let stale = ClipCLIWire.request(key: key, verb: "list", args: [:], now: Date().addingTimeInterval(-600))!
            let once = ClipCLIWire.request(key: key, verb: "list", args: [:], nonce: "fixed-nonce-0123456789")!
            let first = raw(once), second = raw(once)
            check("command line: a request signed with another key, a stale one and a replayed one are refused",
                  (raw(forged)?["error"] as? String)?.contains("badSignature") == true && (raw(stale)?["error"] as? String)?.contains("stale") == true
                  && first?["ok"] as? Bool == true && (second?["error"] as? String)?.contains("replayed") == true)
            check("command line: arguments parsed; bad ones are a usage error", ClipCLI.parse(["get", "3", "--board", "X"], stdin: { nil })?.args["index"] as? Int == 3
                  && ClipCLI.parse(["put"], stdin: { "piped" })?.args["text"] as? String == "piped" && ClipCLI.parse(["get", "zero"], stdin: { nil }) == nil
                  && ClipCLI.parse(["rm", "-rf"], stdin: { nil }) == nil && ClipCLI.parse(["list", "--limit"], stdin: { nil }) == nil)
            server.stop()
            check("command line: stopped, the socket is gone", !fm.fileExists(atPath: sock) && ClipCLI.send(verb: "list", args: [:], socket: sock, keyPath: keyPath) == nil)
        }
        return failed
    }
}
