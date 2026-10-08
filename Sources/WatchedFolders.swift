// Watched folders: folders the user picks (Downloads and the screenshot folder as presets) whose new files land in a shelf
// collection, filtered by simple rules (extension, kind, name, "is a screenshot"; all or any), in batches (files that arrive
// together, until the folder has been quiet for the chosen delay, land as one), never half-downloaded files (.crdownload,
// .download, .part…, or a size still changing). Each folder is watched with a kernel event on the folder (DispatchSource,
// O_EVTONLY) and listed when it fires; only files that appear after the watch began count. The pure parts (WatchMatch,
// WatchBatcher) are tested by --shelf-test with temporary folders.

import AppKit
import Foundation
import UniformTypeIdentifiers

struct WatchRule: Codable, Equatable, Identifiable {
    enum Field: String, Codable, CaseIterable { case ext, kind, nameContains, nameStarts, nameEnds, screenshot }
    var id = UUID()
    var field: Field
    /// ext: "png, jpg" (a list); kind: a FileKind; name…: the text (case doesn't matter); screenshot: unused.
    var value = ""
    /// "is not": the rule matches when the test fails.
    var negate = false
}

/// Kinds a rule can ask for.
enum FileKind: String, CaseIterable, Codable {
    case image, video, audio, pdf, archive, document, text, folder
    func matches(_ t: UTType?, isDirectory: Bool) -> Bool {
        if self == .folder { return isDirectory }
        guard let t, !isDirectory else { return false }
        switch self {
        case .image: return t.conforms(to: .image)
        case .video: return t.conforms(to: .movie) || t.conforms(to: .video)
        case .audio: return t.conforms(to: .audio)
        case .pdf: return t.conforms(to: .pdf)
        case .archive: return t.conforms(to: .archive) || t.conforms(to: .diskImage) || ["zip", "dmg", "pkg", "tar", "gz", "7z", "rar"].contains(t.preferredFilenameExtension ?? "")
        case .document: return t.conforms(to: .text) || t.conforms(to: .pdf) || t.conforms(to: .spreadsheet) || t.conforms(to: .presentation)
                            || t.conforms(to: UTType("public.composite-content") ?? .data)
        case .text: return t.conforms(to: .text)
        case .folder: return false
        }
    }
    var title: String {
        switch self {
        case .image: return L("Images"); case .video: return L("Videos"); case .audio: return L("Audio"); case .pdf: return "PDF"
        case .archive: return L("Archives"); case .document: return L("Documents"); case .text: return L("Text files"); case .folder: return L("Folders")
        }
    }
}

struct WatchedFolder: Codable, Equatable, Identifiable {
    enum Preset: String, Codable { case downloads, screenshots }
    var id = UUID()
    var path: String
    var bookmark: Data? = nil
    var preset: Preset? = nil
    var enabled = true
    var rules: [WatchRule] = []
    /// All rules must match (AND), or any (OR).
    var matchAll = true
    /// The collection files land in (nil: the current one when they arrive).
    var collection: UUID? = nil
    /// Seconds without a new or growing file before a batch lands.
    var delay = 2.0
    static let delays: [Double] = [0.5, 2, 5, 10, 30]

    /// The folder now: the screenshot preset follows the screenshot location if it changes.
    var url: URL {
        switch preset {
        case .downloads?: return FileShelf.downloadsFolder
        case .screenshots?: return FileShelf.screenshotsFolder
        case nil:
            if let b = bookmark { let r = ShelfBookmarks.resolve(path: path, bookmark: b); if !r.missing { return URL(fileURLWithPath: r.path) } }
            return URL(fileURLWithPath: path)
        }
    }

    var title: String {
        switch preset {
        case .downloads?: return L("Downloads")
        case .screenshots?: return L("Screenshots")
        case nil: return FileManager.default.displayName(atPath: path)
        }
    }

    static func downloads() -> WatchedFolder { WatchedFolder(path: FileShelf.downloadsFolder.path, preset: .downloads) }
    static func screenshots() -> WatchedFolder {
        WatchedFolder(path: FileShelf.screenshotsFolder.path, preset: .screenshots, rules: [WatchRule(field: .screenshot)])
    }
}

/// What a rule looks at, read once per new file.
struct FileFacts: Equatable {
    var name: String
    var isDirectory = false
    var size: Int64 = 0
    var isScreenshot = false
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var type: UTType? { ext.isEmpty ? nil : UTType(filenameExtension: ext) }

    static func read(_ url: URL) -> FileFacts? {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isPackageKey]) else { return nil }
        let dir = (v.isDirectory ?? false) && !(v.isPackage ?? false)
        return FileFacts(name: url.lastPathComponent, isDirectory: dir, size: Int64(v.fileSize ?? 0), isScreenshot: !dir && Screenshots.isScreenshot(url))
    }
}

enum WatchMatch {
    /// Downloads in progress and the temporary files apps write first.
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp", "temp", "dtapart", "!ut", "aria2"]

    static func isPartial(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("~$") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return partialExtensions.contains(ext) || name.hasSuffix(".icloud")
    }

    static func matches(_ r: WatchRule, _ f: FileFacts) -> Bool {
        let v = r.value.trimmingCharacters(in: .whitespaces).lowercased()
        let n = f.name.lowercased()
        let hit: Bool
        switch r.field {
        case .ext:
            let list = v.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty }
            hit = list.contains(f.ext)
        case .kind: hit = FileKind(rawValue: v).map { $0.matches(f.type, isDirectory: f.isDirectory) } ?? false
        case .nameContains: hit = !v.isEmpty && n.contains(v)
        case .nameStarts: hit = !v.isEmpty && n.hasPrefix(v)
        case .nameEnds: hit = !v.isEmpty && ((n as NSString).deletingPathExtension.hasSuffix(v) || n.hasSuffix(v))
        case .screenshot: hit = f.isScreenshot
        }
        return r.negate ? !hit : hit
    }

    /// Does a new file belong in the collection? No rules: every file (never a partial one).
    static func accepts(_ f: FileFacts, folder: WatchedFolder) -> Bool {
        guard !isPartial(f.name) else { return false }
        guard !folder.rules.isEmpty else { return true }
        return folder.matchAll ? folder.rules.allSatisfy { matches($0, f) } : folder.rules.contains { matches($0, f) }
    }

    /// The rules in a few words, for the settings ("png, jpg · Screenshots").
    static func summary(_ folder: WatchedFolder) -> String {
        guard !folder.rules.isEmpty else { return L("Every new file") }
        let parts = folder.rules.map { r -> String in
            let not = r.negate ? L("not") + " " : ""
            switch r.field {
            case .ext: return not + r.value
            case .kind: return not + (FileKind(rawValue: r.value)?.title ?? r.value)
            case .nameContains: return not + String(format: L("name contains “%@”"), r.value)
            case .nameStarts: return not + String(format: L("name starts with “%@”"), r.value)
            case .nameEnds: return not + String(format: L("name ends with “%@”"), r.value)
            case .screenshot: return not + L("Screenshots")
            }
        }
        return parts.joined(separator: folder.matchAll ? " · " : " | ")
    }
}

/// Files that arrive together land together: a file joins the waiting batch when it appears, its size is looked at again on
/// every tick, and the batch is let go once nothing appeared or grew for `delay` seconds (or it waited `maxWait`).
struct WatchBatcher {
    var delay: TimeInterval
    var maxWait: TimeInterval = 600
    private(set) var pending: [String: Int64] = [:]
    private(set) var order: [String] = []
    private var lastChange: TimeInterval = 0
    private var firstSeen: TimeInterval = 0

    init(delay: TimeInterval) { self.delay = delay }

    var isEmpty: Bool { pending.isEmpty }

    /// A file seen now with this size (new, or looked at again).
    mutating func observe(_ path: String, size: Int64, now: TimeInterval) {
        if let old = pending[path] {
            if old != size { pending[path] = size; lastChange = now }
        } else {
            if pending.isEmpty { firstSeen = now }
            pending[path] = size; order.append(path); lastChange = now
        }
    }

    /// A file went away before it landed (renamed into place: its new name comes as a new file).
    mutating func forget(_ path: String) {
        pending[path] = nil; order.removeAll { $0 == path }
    }

    /// The batch, if it is ready now (then it is cleared).
    mutating func due(now: TimeInterval) -> [String]? {
        guard !pending.isEmpty, now - lastChange >= delay || now - firstSeen >= maxWait else { return nil }
        let out = order.filter { pending[$0] != nil }
        pending = [:]; order = []
        return out
    }
}

/// Is this file a screenshot? The flag macOS writes on screenshots (an extended attribute, the same as Spotlight's
/// kMDItemIsScreenCapture), else Spotlight, else the screenshot names macOS uses in our languages.
enum Screenshots {
    static let prefixes = ["Screenshot", "Screen Shot", "Schermata", "Captura", "Capture", "Bildschirmfoto", "スクリーンショット", "截屏", "屏幕快照", "螢幕快照"]
    static let attribute = "com.apple.metadata:kMDItemIsScreenCapture"

    static func isScreenshot(_ url: URL) -> Bool {
        if let v = flag(url) { return v }
        if let item = MDItemCreateWithURL(nil, url as CFURL), let v = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) {
            if let b = v as? Bool { return b }
            if let n = v as? NSNumber { return n.boolValue }
        }
        let n = url.lastPathComponent
        return ["png", "jpg", "jpeg", "heic", "mov"].contains(url.pathExtension.lowercased()) && prefixes.contains { n.hasPrefix($0) }
    }

    /// The extended attribute: a binary property list holding true (or 1).
    static func flag(_ url: URL) -> Bool? {
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard size > 0, size < 4096 else { return nil }
        var data = Data(count: size)
        let n = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, 0) }
        guard n == size, let v = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        if let b = v as? Bool { return b }
        if let num = v as? NSNumber { return num.boolValue }
        return nil
    }
}

// MARK: - Watching

/// Whether a watched folder can be watched now.
enum WatchState: Equatable { case off, watching, denied, missing }

/// One folder being watched: kernel events on the folder, a listing when they come, the batcher ticking while files wait.
final class FolderWatcher {
    let folder: WatchedFolder
    /// The folder as it was when the watcher was made (a preset's folder can move: Sources/WatchedFolders.swift's recheck).
    let dir: URL
    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var known = Set<String>()
    private var batcher: WatchBatcher
    private let clock: () -> TimeInterval
    /// A batch is ready (main thread).
    var onBatch: ([URL]) -> Void = { _ in }
    private let lock = NSLock()
    private var _state: WatchState = .off
    /// Read from any thread (the watcher's queue changes it when the folder goes away).
    private(set) var state: WatchState {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set { lock.lock(); _state = newValue; lock.unlock() }
    }

    init(_ folder: WatchedFolder, queue: DispatchQueue = DispatchQueue(label: "local.cocaine.shelf.watch"),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.folder = folder
        self.dir = folder.url
        self.queue = queue
        self.clock = clock
        batcher = WatchBatcher(delay: max(0.2, folder.delay))
    }

    /// Starts watching; the state says whether it could (a folder that can't be listed is a missing permission or gone).
    @discardableResult
    func start() -> WatchState {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { state = .missing; return state }
        let listing: [String]
        do { listing = try fm.contentsOfDirectory(atPath: dir.path) } catch {
            state = .denied; return state                     // macOS's Files and Folders permission (or the folder's own)
        }
        known = Set(listing)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { state = .denied; return state }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link, .extend], queue: queue)
        s.setEventHandler { [weak self, weak s] in
            // The folder itself deleted or renamed (moved to the Trash): no longer watched, said so; the next recheck finds
            // it again if it comes back.
            if let ev = s?.data, ev.contains(.delete) || ev.contains(.rename) { self?.lost(); return }
            self?.scan()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        state = .watching
        return state
    }

    /// Runs on the watcher's queue and waits (tests).
    func syncOnQueue(_ f: () -> Void) { queue.sync(execute: f) }

    func stop() {
        source?.cancel(); source = nil
        timer?.cancel(); timer = nil
        state = .off
    }

    /// The folder went away while watched.
    private func lost() {
        source?.cancel(); source = nil
        timer?.cancel(); timer = nil
        state = .missing
    }

    deinit { stop() }

    /// The folder changed: new names are looked at (rules), and join the batch.
    func scan() {
        guard state == .watching else { return }
        guard let now = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) { lost() }
            return
        }
        let set = Set(now)
        for gone in known.subtracting(set) { batcher.forget(dir.appendingPathComponent(gone).path) }
        for name in set.subtracting(known) where !WatchMatch.isPartial(name) {
            let u = dir.appendingPathComponent(name)
            guard let f = FileFacts.read(u), WatchMatch.accepts(f, folder: folder) else { continue }
            batcher.observe(u.path, size: f.size, now: clock())
        }
        known = set
    }

    /// While files wait: their sizes again (a download still growing holds the batch), and the batch once it is quiet.
    func tick() {
        guard !batcher.isEmpty else { return }
        let t = clock()
        for p in batcher.order {
            if let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.fileSizeKey]) { batcher.observe(p, size: Int64(v.fileSize ?? 0), now: t) }
            else { batcher.forget(p) }
        }
        if let ready = batcher.due(now: t) {
            let urls = ready.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state == .watching else { return }           // stopped meanwhile: nothing lands
                self.onBatch(urls)
            }
        }
    }
}

/// Every watched folder of the settings, started and stopped as they change; batches go to `onBatch(folder, files)`.
final class WatchedFolders: ObservableObject {
    @Published private(set) var states: [UUID: WatchState] = [:]
    private var watchers: [UUID: FolderWatcher] = [:]
    var onBatch: (WatchedFolder, [URL]) -> Void = { _, _ in }
    private var wanted: [WatchedFolder] = []
    private var recheckTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        // Back from sleep, or Cocaine brought forward (after allowing access in System Settings): every folder is checked again.
        let again: (Notification) -> Void = { [weak self] _ in self?.recheck() }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: again))
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: again))
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        recheckTimer?.invalidate()
    }

    /// Restarts what isn't watching any more (a folder gone, access granted since, a preset folder that moved: the screenshot
    /// location changed). Once a minute while folders are watched, and on wake.
    func recheck() {
        guard !wanted.isEmpty else { return }
        apply(wanted, running: true)
    }

    /// Matches the watchers to `folders` (only enabled ones run). Called at launch and whenever the settings change.
    func apply(_ folders: [WatchedFolder], running: Bool) {
        var keep = Set<UUID>()
        wanted = running ? folders.filter(\.enabled) : []
        for f in folders where f.enabled && running {
            keep.insert(f.id)
            if let w = watchers[f.id], w.folder == f, w.state == .watching, w.dir.standardizedFileURL.path == f.url.standardizedFileURL.path { continue }
            watchers[f.id]?.stop()
            let w = FolderWatcher(f)
            w.onBatch = { [weak self] urls in self?.onBatch(f, urls) }
            states[f.id] = w.start()
            watchers[f.id] = w
        }
        for (id, w) in watchers where !keep.contains(id) { w.stop(); watchers[id] = nil }
        for f in folders where !keep.contains(f.id) { states[f.id] = .off }
        for id in states.keys where !folders.contains(where: { $0.id == id }) { states[id] = nil }
        if wanted.isEmpty { recheckTimer?.invalidate(); recheckTimer = nil }
        else if recheckTimer == nil {
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.recheck() }
            t.tolerance = 15
            RunLoop.main.add(t, forMode: .common)
            recheckTimer = t
        }
    }

    func state(_ id: UUID) -> WatchState { states[id] ?? .off }

    /// Tries again (after the user granted access in System Settings).
    func retry(_ folders: [WatchedFolder]) {
        for (_, w) in watchers where w.state != .watching { w.stop() }
        watchers = watchers.filter { $0.value.state == .watching }
        apply(folders, running: true)
    }
}
