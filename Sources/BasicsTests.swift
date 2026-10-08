// `--basics-test`: Cocaine leaves basic macOS behaviour alone unless the user switched a feature on (Sources/Basics.swift).
// Universal Clipboard (Handoff copy and paste) against a private pasteboard whose data is a promise that records what is asked
// for, as another device's copy is; the defaults and their one-time migration; the default global shortcuts against macOS's own.
// Memory-only settings, uniquely named pasteboards (never the general one), temporary folders.

import AppKit
import Carbon.HIToolbox

/// A pasteboard item whose data is only promised (as Universal Clipboard's is) and that notes every type someone asks for.
final class PromiseRecorder: NSObject, NSPasteboardItemDataProvider {
    private let lock = NSLock()
    private var list: [String] = []
    var asked: [String] { lock.lock(); defer { lock.unlock() }; return list }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.lock(); list.append(type.rawValue); lock.unlock()
        switch type {
        case .string: item.setString("from my iPhone", forType: type)
        case .rtf: item.setData(Data(#"{\rtf1 from my iPhone}"#.utf8), forType: type)
        case .html: item.setData(Data("<b>from my iPhone</b>".utf8), forType: type)
        case .png: item.setData(ClipboardTests.samplePNG(), forType: type)
        default: item.setData(Data("x".utf8), forType: type)
        }
    }

    /// A fresh private pasteboard holding one promised item with these types.
    static func board(_ types: [String]) -> (NSPasteboard, PromiseRecorder) {
        let pb = NSPasteboard(name: NSPasteboard.Name("local.cocaine.basics-test.\(getpid()).\(UUID().uuidString)"))
        pb.clearContents()
        let rec = PromiseRecorder(), it = NSPasteboardItem()
        it.setDataProvider(rec, forTypes: types.map { NSPasteboard.PasteboardType($0) })
        pb.writeObjects([it])
        return (pb, rec)
    }
}

enum BasicsTests {
    static func run() -> Int {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  basics: " + name); if !ok { failed += 1 } }
        universalClipboard(check)
        clipboardDefaults(check)
        historyPolling(check)
        shortcuts(check)
        inventory(check)
        print(failed == 0 ? "basics: all passed" : "basics: \(failed) FAILED")
        return failed
    }

    static let remoteTypes = [NSPasteboard.PasteboardType.string.rawValue, NSPasteboard.PasteboardType.rtf.rawValue,
                              NSPasteboard.PasteboardType.html.rawValue, NSPasteboard.PasteboardType.png.rawValue,
                              "org.nspasteboard.source", ClipRules.remoteType]

    // MARK: Universal Clipboard: what the real NSPasteboard code asks another device for

    static func universalClipboard(_ check: (String, Bool) -> Void) {
        let off = ClipSettings()
        var on = ClipSettings(); on.includeRemote = true
        func allowed(_ s: ClipSettings) -> ([String], String?) -> Bool {
            { types, source in ClipRules.allowed(types: types, source: source, front: "com.apple.Safari", settings: s) }
        }
        do {
            let (pb, rec) = PromiseRecorder.board(remoteTypes)
            defer { pb.releaseGlobally() }
            let board = SystemPasteboard(pb)
            let types = board.currentTypes
            check("the copy looks like another device's (types only: nothing fetched to know it)", ClipRules.isRemote(types) && rec.asked.isEmpty)
            let snap = board.snapshot(maxImageBytes: 10_000_000, allowed: allowed(off))
            check("other devices off (the default): NOTHING is asked of the other device, not even its source marker",
                  rec.asked.isEmpty && snap.text == nil && snap.rich == nil && snap.image == nil && snap.files.isEmpty)
            check("…and it isn't kept", ClipRules.decide(snap, settings: off) == .skip(.remote))
        }
        do {
            let (pb, rec) = PromiseRecorder.board(remoteTypes)
            defer { pb.releaseGlobally() }
            let snap = SystemPasteboard(pb).snapshot(maxImageBytes: 10_000_000, allowed: allowed(on))
            check("other devices on: only the plain text is asked for (no RTF, HTML, image, file or source transfer)",
                  rec.asked == [NSPasteboard.PasteboardType.string.rawValue])
            check("…and it is kept as another device's text", snap.text == "from my iPhone" && snap.rich == nil && snap.image == nil
                  && { if case .keep(let i) = ClipRules.decide(snap, settings: on) { return i.remote && i.source == ClipRules.remoteSource }; return false }())
        }
        do {   // a remote image only: nothing is fetched even with other devices on
            let (pb, rec) = PromiseRecorder.board([NSPasteboard.PasteboardType.png.rawValue, ClipRules.remoteType])
            defer { pb.releaseGlobally() }
            let snap = SystemPasteboard(pb).snapshot(maxImageBytes: 10_000_000, allowed: allowed(on))
            check("another device's image or file is never fetched", rec.asked.isEmpty && !snap.hasContent)
        }
        do {   // this Mac's own copies are read as before (formatting too)
            let local = remoteTypes.filter { $0 != ClipRules.remoteType && $0 != "org.nspasteboard.source" }
            let (pb, rec) = PromiseRecorder.board(local)
            defer { pb.releaseGlobally() }
            let snap = SystemPasteboard(pb).snapshot(maxImageBytes: 10_000_000, allowed: allowed(off))
            check("a copy made on this Mac is still read with its formatting", snap.text == "from my iPhone" && snap.rich?.html != nil
                  && rec.asked.contains(NSPasteboard.PasteboardType.html.rawValue))
        }
    }

    // MARK: the defaults and their migration

    static func clipboardDefaults(_ check: (String, Bool) -> Void) {
        let d = ClipSettings()
        check("default: copies from other devices are left alone", !d.includeRemote)
        check("default: no global shortcut opens the clipboard (⌃⌘V is Paste Special in Microsoft Office)", d.openShortcut == nil)
        check("default: Paste Stack's key exists but is registered only while a stack waits",
              d.pasteNext != nil && ClipHotKeys.wanted(settings: d, stackActive: false, boards: [], items: []).isEmpty)

        // Settings saved by 2.8 (every key was written, no schema): the old defaults reset once.
        var old = ClipSettings(); old.includeRemote = true; old.openShortcut = ClipSettings.defaultOpen; old.maxItems = 200
        func legacy(_ s: ClipSettings) -> Data {
            var o = (try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(s)) ?? Data())) as? [String: Any] ?? [:]
            o.removeValue(forKey: "schema")
            return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
        }
        let migrated = try? JSONDecoder().decode(ClipSettings.self, from: legacy(old))
        check("2.8 settings at the old defaults: other devices off, ⌃⌘V freed, the rest kept",
              migrated?.includeRemote == false && migrated?.openShortcut == nil && migrated?.maxItems == 200)
        var custom = old; custom.includeRemote = false; custom.openShortcut = Shortcut(keyCode: UInt32(kVK_ANSI_X), mods: Shortcut.hyper)
        let kept = try? JSONDecoder().decode(ClipSettings.self, from: legacy(custom))
        check("2.8 settings with a shortcut of the user's own: kept", kept?.openShortcut == custom.openShortcut && kept?.includeRemote == false)
        let chosen = try? JSONDecoder().decode(ClipSettings.self, from: (try? JSONEncoder().encode(old)) ?? Data())
        check("chosen after the migration (schema 2 saved): other devices on and ⌃⌘V stay", chosen?.includeRemote == true && chosen?.openShortcut == ClipSettings.defaultOpen)
        let store = MemoryDefaults()
        store.set(legacy(old), forKey: ClipSettings.key)
        let loaded = ClipSettings.load(store)
        let resaved = store.data(forKey: ClipSettings.key).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        check("the migration is saved at once (so it happens once)", !loaded.includeRemote && resaved?["schema"] as? Int == ClipSettings.schema
              && resaved?["includeRemote"] as? Bool == false)
    }

    // MARK: the history's watch: another device's copy is not touched while the system brings it over

    static func historyPolling(_ check: (String, Bool) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-basics-\(getpid())-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fb = FakePasteboard()
        let h = ClipboardHistory(defaults: MemoryDefaults(), dir: root, keys: MemoryKeyStore(), board: fb)
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        h.now = { clock }
        h.frontApp = { "com.apple.TextEdit" }
        h.syncReads = true
        let remote = ClipSnapshot(types: [NSPasteboard.PasteboardType.string.rawValue, ClipRules.remoteType], text: "from my iPhone")

        fb.put(remote); h.poll()
        clock += 10; h.poll()
        check("default: another device's copy is never read, never kept", fb.dataReads == 0 && h.items.isEmpty && h.remoteWait == nil)

        var on = h.settings; on.includeRemote = true; h.update(on)
        fb.put(remote); h.poll()
        check("other devices on: not read at the change itself (the system is still bringing it over)", fb.dataReads == 0 && h.remoteWait != nil)
        clock += ClipboardHistory.remoteSettle - 1; h.poll()
        check("…nor before \(Int(ClipboardHistory.remoteSettle)) s", fb.dataReads == 0)
        clock += 1.5; h.poll()
        check("…then read once, its plain text kept as another device's", fb.dataReads == 1 && h.items.first?.text == "from my iPhone" && h.items.first?.remote == true)

        fb.put(remote); h.poll()
        fb.put(ClipSnapshot(types: [NSPasteboard.PasteboardType.string.rawValue], text: "typed here")); clock += 0.7; h.poll()
        clock += 5; h.poll()
        check("replaced meanwhile by a copy on this Mac: the other device's isn't fetched, this Mac's is kept",
              fb.dataReads == 2 && h.items.first?.text == "typed here" && h.remoteWait == nil)

        fb.put(remote); h.poll()
        h.pause(until: nil); h.poll()
        clock += 5; h.paused = false; h.poll()
        check("paused meanwhile: the wait is dropped, nothing fetched", fb.dataReads == 2 && h.remoteWait == nil)
    }

    // MARK: default global shortcuts vs macOS's own

    static func shortcuts(_ check: (String, Bool) -> Void) {
        let system = ShortcutRules.systemShortcuts()
        for a in ShortcutAction.allCases {
            let s = a.defaultShortcut
            check("default \(s.glyphs) (\(a.rawValue)) is ⌃⌥⌘: not macOS's, not this Mac's System Settings shortcuts",
                  s.mods == Shortcut.hyper && !ShortcutRules.reserved.contains(s) && !system.contains(s))
        }
        check("the suggested ⌃⌘V isn't one of this Mac's System Settings shortcuts (it is Office's Paste Special: not registered by default)",
              !system.contains(ClipSettings.defaultOpen))
        check("Paste Stack's ⌃⌥⌘V isn't one of this Mac's System Settings shortcuts", !system.contains(ClipSettings.defaultPasteNext))
    }

    // MARK: the app's other defaults

    static func inventory(_ check: (String, Bool) -> Void) {
        for (name, ok) in Basics.inventoryChecks() { check(name, ok) }
    }
}

func cliBasicsTest() -> Never { exit(BasicsTests.run() == 0 ? 0 : 1) }
