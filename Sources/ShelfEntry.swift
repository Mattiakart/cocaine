// Ways into the shelf from outside the island: the Services menu ("Add to Cocaine Shelf", Info.plist NSServices), files opened
// with Cocaine (`open -a Cocaine file…`, Info.plist CFBundleDocumentTypes as a viewer of rank None, so Cocaine is never the
// default app for anything), the command line (`cocaine shelf add|list|clear`, which runs `Cocaine --shelf …`), and a shake
// while dragging files. The cocaine:// link scheme has no shelf verbs: a web page can't add paths or read the shelf.

import AppKit
import Combine
import Foundation

enum ShelfEntry {
    /// The island's shelf, once the island has started (files opened before that wait in `pending`).
    static var center: ShelfCenter? { didSet { if let c = center, !pending.isEmpty { c.add(pending); pending = [] } } }
    private static var pending: [URL] = []
    static let clearNotification = Notification.Name("local.cocaine.shelf.clear")
    private static var shake = ShakeDetector()
    private static var dragCount = -1

    /// Files opened with Cocaine (Finder's Open With, `open -a Cocaine`, the command line's `shelf add`): they land on the shelf.
    static func openFiles(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        if let c = center { c.add(files) } else { pending += files }
    }

    /// The island started: the services provider, the command line's "clear", watched folders, settings changes.
    static func start(_ c: ShelfCenter) {
        center = c
        NSApp.servicesProvider = ShelfServices.shared
        DistributedNotificationCenter.default().addObserver(forName: clearNotification, object: Bundle.main.bundleIdentifier, queue: .main) { _ in
            Motion.with(.appear) { c.store.clear() }
        }
        configWatch = c.config.$config.dropFirst().sink { [weak c] _ in DispatchQueue.main.async { c?.applyWatching() } }
    }
    private static var configWatch: AnyCancellable?

    /// A shake while dragging files (only with *Shake to open*): true when the island should open on the shelf.
    static func shook(_ e: NSEvent, overIsland: Bool) -> Bool {
        guard let c = center, c.config.config.shakeToOpen, e.type == .leftMouseDragged, !overIsland else { shake.reset(); return false }
        let pb = NSPasteboard(name: .drag)
        guard pb.types?.contains(.fileURL) == true else { shake.reset(); return false }
        if pb.changeCount != dragCount { dragCount = pb.changeCount; shake.reset() }
        return shake.feed(x: NSEvent.mouseLocation.x, at: e.timestamp)
    }
}

/// The Services menu's "Add to Cocaine Shelf" (files from Finder; text, links and images from any app).
final class ShelfServices: NSObject {
    static let shared = ShelfServices()

    @objc func addToShelf(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let c = ShelfEntry.center else { error.pointee = "Cocaine's island is off" as NSString; return }
        let n = ShelfPaste.add(pboard, to: c.store)
        if n == 0 { error.pointee = "Nothing to add" as NSString; return }
        c.report(added: n, refused: 0)
    }
}

/// `Cocaine --shelf add <file>… | list [--all] [--json] | clear` (the engine's `cocaine shelf …`). Local only: it acts as the
/// user who runs it, on that user's shelf.
enum ShelfCLI {
    static let usage = "usage: cocaine shelf add <file>… | list [--all] [--json] | clear"

    /// The paths to add: each must exist; relative ones are taken from the current folder.
    static func paths(_ args: [String], cwd: String = FileManager.default.currentDirectoryPath) -> (ok: [String], missing: [String]) {
        var ok: [String] = [], missing: [String] = []
        for a in args {
            let p = a.hasPrefix("/") ? a : (cwd as NSString).appendingPathComponent(a)
            let std = URL(fileURLWithPath: p).standardizedFileURL.path
            if FileManager.default.fileExists(atPath: std) { ok.append(std) } else { missing.append(a) }
        }
        return (ok, missing)
    }

    /// `open`'s arguments: in the background, this very app (its bundle, not whatever "Cocaine" Launch Services prefers).
    static func openArguments(bundle: String, paths: [String]) -> [String] { ["-g", "-a", bundle] + paths }

    /// The lines `list` prints: collection, kind, path or text (tabs and line breaks shown as spaces).
    static func lines(_ l: ShelfLibrary, all: Bool) -> [String] {
        let cols = all ? l.collections : l.collections.filter { $0.id == l.current }
        return cols.flatMap { c in c.items.map { i in
            let what = i.kind == .file ? i.path : (i.kind == .image ? i.name : (i.text ?? ""))
            let flat = what.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            return [c.title, i.kind.rawValue, String(flat.prefix(300))].joined(separator: "\t")
        } }
    }

    static func run(_ args: [String]) -> Int32 {
        guard let verb = args.first else { FileHandle.standardError.write(Data((usage + "\n").utf8)); return 64 }
        let rest = Array(args.dropFirst())
        switch verb {
        case "add":
            let p = paths(rest)
            for m in p.missing { FileHandle.standardError.write(Data("cocaine shelf: no such file: \(m)\n".utf8)) }
            guard !p.ok.isEmpty else { return p.missing.isEmpty ? 64 : 1 }
            let r = ShelfProc.run("/usr/bin/open", openArguments(bundle: Bundle.main.bundlePath, paths: p.ok), timeout: 30)
            if r.status != 0 { FileHandle.standardError.write(Data("cocaine shelf: couldn't reach Cocaine\n".utf8)); return 1 }
            print("added \(p.ok.count)")
            return p.missing.isEmpty ? 0 : 1
        case "list":
            let disk = ShelfDisk.real
            guard case .ok(let l) = disk.load() else { return 0 }          // nothing saved yet: an empty shelf
            if rest.contains("--json") {
                let all = rest.contains("--all")
                let cols = all ? l.collections : l.collections.filter { $0.id == l.current }
                let obj = cols.map { c in ["name": c.title, "items": c.items.map { i -> [String: String] in
                    ["kind": i.kind.rawValue, "name": i.name, "value": i.kind == .file ? i.path : (i.kind == .image ? i.name : (i.text ?? ""))] }] as [String: Any] }
                if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: d, as: UTF8.self)) }
            } else {
                for line in lines(l, all: rest.contains("--all")) { print(line) }
            }
            return 0
        case "clear":
            let id = Bundle.main.bundleIdentifier ?? "local.cocaine.toggle"
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != getpid() }
            if running {
                DistributedNotificationCenter.default().postNotificationName(ShelfEntry.clearNotification, object: id, userInfo: nil, deliverImmediately: true)
            } else {
                let store = ShelfStore(disk: .real, defaults: MemoryDefaults())
                store.clear(); store.flush()
            }
            print("cleared")
            return 0
        default:
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 64
        }
    }
}
