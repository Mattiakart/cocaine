// iPhone clipboard sync: the iCloud Drive folder (ICloudFolder.swift) watched from this Mac, what comes in from the iPhone
// taken into the clipboard history (source "device:iphone", through the same rules as any copy: secrets, patterns, sizes),
// and items sent to the iPhone on request ("Send to iPhone"; optionally every copy, never secrets or excluded apps' content).
// The short-text channel over the paired iPhone's relay is in ClipRemote.swift, the iPhone Shortcuts in SyncShortcuts.swift,
// the settings card in ClipSyncSettings.swift. Everything is off by default. docs/clipboard-sync.en.md says what it can't do.

import AppKit
import Combine
import Foundation

// MARK: - Settings (their own key: nothing else's settings change)

/// What one paired iPhone may do with the clipboard over the relay (ClipRemote.swift). Both off by default.
struct ClipRemotePerm: Codable, Equatable {
    var read = false                 // `clip get` / `clip list`: the newest item, or the iPhone-readable pinboard
    var write = false                // `clip put` / `clip part`: text into the history

    init(read: Bool = false, write: Bool = false) { self.read = read; self.write = write }
    init(from decoder: Decoder) throws {           // a missing switch is off
        let c = try decoder.container(keyedBy: CodingKeys.self)
        read = (try? c.decodeIfPresent(Bool.self, forKey: .read)) == true
        write = (try? c.decodeIfPresent(Bool.self, forKey: .write)) == true
    }
}

struct ClipSyncSettings: Codable, Equatable {
    var folderOn = false             // the iCloud Drive folder is watched and written
    var folderName = ICloudPaths.defaultName
    var makeCurrent = false          // what arrives from the iPhone also goes on this Mac's clipboard
    var pinboard: UUID?              // …and onto this pinboard
    var sendEveryCopy = false        // every copy made on this Mac goes to the outbox (never secrets, excluded apps, other devices)
    var keepFiles = false            // keep what was taken in, in processed/ (cleaned after keepHours); off: deleted at once
    var keepHours = 24               // processed/ and the outbox's own files are removed after this
    var readableBoard: UUID?         // the pinboard the iPhone may read over the relay (`clip list`, `clip get N`)
    var remote: [String: ClipRemotePerm] = [:]   // pairing id → what it may do
    var universalOffDisk = false     // copies from Universal Clipboard are never written to the saved history

    static let key = "clipSyncSettings"
    static let hourChoices = [1, 24, 24 * 7]

    init() {}
    /// Missing or unknown keys take their default (an older or newer Cocaine never loses the rest).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipSyncSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? def }
        folderOn = v(.folderOn, d.folderOn)
        let name = v(.folderName, d.folderName); folderName = ICloudPaths.validName(name) ? name : d.folderName
        makeCurrent = v(.makeCurrent, d.makeCurrent); pinboard = v(.pinboard, d.pinboard)
        sendEveryCopy = v(.sendEveryCopy, d.sendEveryCopy); keepFiles = v(.keepFiles, d.keepFiles)
        keepHours = max(1, min(24 * 30, v(.keepHours, d.keepHours))); readableBoard = v(.readableBoard, d.readableBoard)
        remote = v(.remote, d.remote); universalOffDisk = v(.universalOffDisk, d.universalOffDisk)
    }

    func perm(_ pairing: String) -> ClipRemotePerm { remote[pairing] ?? ClipRemotePerm() }

    static func load(_ d: UserDefaults) -> ClipSyncSettings {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(ClipSyncSettings.self, from: data) else { return ClipSyncSettings() }
        return s
    }
    func save(_ d: UserDefaults) { if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) } }
}

// MARK: - Sources and the seam the clipboard page uses

extension ClipRules {
    /// The `source` of an item that came from the iPhone through Cocaine's own channels (iCloud Drive or the relay).
    static let iPhoneSource = "device:iphone"
    /// The pasteboard type Cocaine's sync gives such an item's snapshot (never on the real clipboard).
    static let syncType = "local.cocaine.sync.iphone"
}

extension ClipItem {
    /// From another device: Universal Clipboard ("Another device") or Cocaine's iPhone sync.
    var fromDevice: Bool { source?.hasPrefix("device:") == true }
    var fromIPhone: Bool { source == ClipRules.iPhoneSource }
}

/// "Send to iPhone" on the clipboard page: set while the iCloud Drive sync is on (the page shows the action only then).
enum ClipSyncHook {
    /// Sends these items; how many went out and what to say.
    static var send: (([UUID]) -> (sent: Int, message: String))?
}

// MARK: - The rules (pure)

enum ClipSyncRules {
    /// What arrives from the iPhone, judged like any copy (secrets, the user's patterns, sizes), with the iPhone as source.
    static func decide(_ c: SyncContent, settings: ClipSettings, now: Date) -> ClipRules.Decision {
        var s = ClipSnapshot(types: [ClipRules.syncType], source: ClipRules.iPhoneSource)
        switch c {
        case .text(let t): s.text = t
        case .image(let png, let w, let h): s.image = png; s.width = w; s.height = h
        }
        return ClipRules.decide(s, settings: settings, now: now)
    }

    enum Refusal: String, Equatable { case secret, pattern, excludedApp, files, fromDevice, tooBig, empty }

    /// May this item go to the iPhone? Never what looks like a password, key or card number (whatever the "skip" setting
    /// says), never an excluded app's or a password manager's, never files (only their names would arrive); `automatic`
    /// (every copy) also never sends back what came from another device.
    static func outbound(_ item: ClipItem, settings: ClipSettings, automatic: Bool) -> Refusal? {
        if automatic && item.fromDevice { return .fromDevice }
        if ClipRules.isExcluded(source: item.source, settings: settings) { return .excludedApp }
        switch item.kind {
        case .files: return .files
        case .text:
            let t = item.text
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
            if ClipRules.looksLikeSecret(t) || ClipRules.looksLikeCard(t) || ClipRules.masked(t) != t { return .secret }
            if !settings.patterns.isEmpty && ClipRules.matchesUserPattern(t, settings.patterns) { return .pattern }
            if t.utf8.count > SyncDecode.maxTextBytes { return .tooBig }
        case .image:
            if item.bytes > 20_000_000 { return .tooBig }
            if automatic, let o = item.ocr, o.contains("•••") { return .secret }     // its recognised text had a secret in it
        }
        return nil
    }

    /// The largest file taken from the inbox (photos are made smaller afterwards).
    static let maxInboxBytes = 25_000_000
}

// MARK: - The watcher and the actions

final class ClipSyncCenter: ObservableObject {
    static let shared = ClipSyncCenter(history: .shared, defaults: AppDefaults.store, home: FileManager.default.homeDirectoryForCurrentUser)

    @Published private(set) var settings: ClipSyncSettings
    @Published private(set) var status: SyncFolderStatus = .notCreated
    @Published private(set) var received = 0
    @Published private(set) var sent = 0
    @Published private(set) var refused = 0
    @Published private(set) var notDownloaded = 0
    @Published private(set) var lastSync: Date?
    @Published private(set) var note: String?          // the last thing worth saying (a refusal, a failure, a test result)
    @Published private(set) var testing = false

    let history: ClipboardHistory
    let defaults: UserDefaults
    let home: URL
    var now: () -> Date = Date.init
    /// Asks iCloud for a file not downloaded yet (tests: a fake). Works without entitlements on the files' metadata; whether
    /// it downloads for an app like Cocaine is not verified on a device (docs/clipboard-sync).
    var download: (URL) -> Void = { try? FileManager.default.startDownloadingUbiquitousItem(at: $0) }

    let io = DispatchQueue(label: "local.cocaine.clipsync.io", qos: .utility)
    private let scanner = InboxScanner(maxBytes: ClipSyncRules.maxInboxBytes)
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var running = false
    private var lastClean = Date.distantPast
    private var recent: [String: Date] = [:]           // digests taken in the last 10 minutes (iCloud's "name 2" copies)
    private var watchSub: AnyCancellable?
    private var lastAuto: (id: UUID, date: Date)?
    private var lastSentDigest = ""

    init(history: ClipboardHistory, defaults: UserDefaults, home: URL) {
        self.history = history
        self.defaults = defaults
        self.home = home
        settings = ClipSyncSettings.load(defaults)
        history.keepOffDisk = { [weak self] item in (self?.settings.universalOffDisk ?? false) && item.remote }
        // Renders (--clipsync-fixture, memory-only settings): everything on, sample counters, never this Mac's folder.
        if AppDefaults.isolated && CommandLine.arguments.contains("--clipsync-fixture") {
            settings.folderOn = true; settings.makeCurrent = true; settings.sendEveryCopy = false; settings.universalOffDisk = true
            settings.remote["a1b2c3d4e5f60718"] = ClipRemotePerm(read: true, write: false)
            received = 12; sent = 4; refused = 1; notDownloaded = 1; lastSync = Date(timeIntervalSince1970: 1_791_000_000)
            note = L("Not sent: it looks like a password, key or card number.")
        }
    }

    var folder: SyncFolder { SyncFolder(root: ICloudPaths.root(home: home, name: settings.folderName)) }
    /// How the folder appears in Finder and on the iPhone.
    var folderDisplay: String { "iCloud Drive › Shortcuts › " + settings.folderName }

    func update(_ change: (inout ClipSyncSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        let restart = s.folderOn != settings.folderOn || s.folderName != settings.folderName
        let auto = s.sendEveryCopy != settings.sendEveryCopy
        settings = s
        s.save(defaults)
        if restart { stop(); start() }
        if auto { watchCopies() }
    }

    // MARK: on / off

    /// Turns the folder sync on: makes the folder (only now, only inside the Shortcuts iCloud folder) and starts watching.
    @discardableResult
    func enableFolder() -> Bool {
        do { try folder.create() } catch {
            refreshStatus()
            note = status == .noICloud ? L("iCloud Drive isn't on for this Mac: turn it on in System Settings → Apple Account → iCloud.")
                                       : L("Couldn't make the folder in iCloud Drive.")
            return false
        }
        update { $0.folderOn = true }
        return true
    }

    func start() {
        refreshStatus()
        ClipSyncHook.send = settings.folderOn ? { [weak self] ids in self?.sendToIPhone(ids) ?? (0, "") } : nil
        watchCopies()
        guard settings.folderOn, !running else { return }
        running = true
        watchFolder()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.scan() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scan()
    }

    func stop() {
        running = false
        timer?.invalidate(); timer = nil
        source?.cancel(); source = nil
        ClipSyncHook.send = nil
    }

    func refreshStatus() {
        let f = folder
        if AppDefaults.isolated && home == FileManager.default.homeDirectoryForCurrentUser { status = settings.folderOn ? .ready : .notCreated; return }   // renders: never the real folder
        status = SyncFolderStatus.of(f)
    }

    /// The inbox's own changes wake a scan at once; the timer covers what doesn't (iCloud finishing a download, size settling).
    private func watchFolder() {
        source?.cancel(); source = nil
        let fd = open(folder.inbox.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        s.setEventHandler { [weak self] in self?.scan() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    // MARK: the inbox

    /// Lists the inbox (and one level of folders in it), off the main thread; takes in what is ready.
    func scan(done: (() -> Void)? = nil) {
        let f = folder, t = now(), clean = t.timeIntervalSince(lastClean) > 600, hours = Double(settings.keepHours)
        if clean { lastClean = t }
        io.async { [weak self] in
            guard let self else { return }
            let entries = Self.list(f.inbox)
            let actions = self.scanner.scan(entries, now: t)
            var taken: [(String, Result<SyncContent, InboxReject>, String)] = []
            for a in actions {
                switch a {
                case .download(let name):
                    let dir = (name as NSString).deletingLastPathComponent, leaf = (name as NSString).lastPathComponent
                    let target = ClipSyncNames.placeholderTarget(leaf) ?? leaf
                    self.download(f.inbox.appendingPathComponent(dir.isEmpty ? target : dir + "/" + target))
                case .reject(let name, let why):
                    taken.append((name, .failure(why), ""))
                case .ingest(let name):
                    let url = f.inbox.appendingPathComponent(name)
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }   // gone meanwhile
                    let digest = ClipItem.digest(SyncDecode.isImage(data) ? .image : .text, data)
                    taken.append((name, SyncDecode.decode(data, name: name), digest))
                }
            }
            let stuck = self.scanner.stuck.count
            if clean { SyncOutbox.clean(f, now: t, processedHours: hours, outboxHours: hours) }
            DispatchQueue.main.async {
                self.notDownloaded = stuck
                for (name, result, digest) in taken { self.take(name, result, digest: digest, folder: f) }
                done?()
            }
        }
    }

    static func list(_ dir: URL, fm: FileManager = .default) -> [InboxEntry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        func entries(_ d: URL, prefix: String) -> [InboxEntry] {
            guard let list = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: keys, options: []) else { return [] }
            return list.prefix(500).map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return InboxEntry(name: prefix + u.lastPathComponent, size: v?.fileSize ?? 0, modified: v?.contentModificationDate ?? .distantPast,
                                  isDirectory: v?.isDirectory ?? false)
            }
        }
        var all = entries(dir, prefix: "")
        for d in all where d.isDirectory && !d.name.hasPrefix(".") { all += entries(dir.appendingPathComponent(d.name), prefix: d.name + "/") }
        return all
    }

    /// One file decided: taken into the history (or refused), then deleted or moved to processed/.
    private func take(_ name: String, _ result: Result<SyncContent, InboxReject>, digest: String, folder f: SyncFolder) {
        let t = now()
        recent = recent.filter { t.timeIntervalSince($0.value) < 600 }
        switch result {
        case .failure(let why):
            refused += 1
            note = why == .tooBig ? L("A file from the iPhone was too big and was set aside.") : L("A file from the iPhone couldn't be read and was set aside.")
            put(aside: name, folder: f, keep: true)
            return
        case .success(let content):
            if recent[digest] == nil {
                recent[digest] = t
                if ingest(content) { received += 1; lastSync = t } else { refused += 1 }
            }
        }
        put(aside: name, folder: f, keep: settings.keepFiles)
    }

    private func put(aside name: String, folder f: SyncFolder, keep: Bool) {
        let url = f.inbox.appendingPathComponent(name)
        io.async {
            let fm = FileManager.default
            if keep {
                try? fm.createDirectory(at: f.processed, withIntermediateDirectories: true)
                let dest = f.processed.appendingPathComponent("\(Int64(Date().timeIntervalSince1970 * 1000))-" + name.replacingOccurrences(of: "/", with: "-"))
                if (try? fm.moveItem(at: url, to: dest)) != nil { return }
            }
            try? fm.removeItem(at: url)
        }
    }

    /// Takes one item from the iPhone into the history: the clipboard's rules, then its pinboard and the Mac's clipboard when
    /// the user asked for them. Also used by the relay's `clip put` (ClipRemote.swift). False: not kept (and why is noted).
    @discardableResult
    func ingest(_ content: SyncContent) -> Bool {
        guard case .keep(let item) = ClipSyncRules.decide(content, settings: history.settings, now: now()) else {
            note = L("Something from the iPhone wasn't kept: it looks like a password or key, matches an excluded pattern, or is too big.")
            return false
        }
        history.add(item)
        guard let kept = history.items.first(where: { $0.digest == item.digest && $0.kind == item.kind }) else { return true }
        if let b = settings.pinboard, history.board(b) != nil { history.pin([kept.id], to: b) }
        if settings.makeCurrent { history.copy(kept) }
        return true
    }

    // MARK: to the iPhone

    /// "Send to iPhone": each item checked (ClipSyncRules.outbound), then written to the outbox. Says what happened.
    @discardableResult
    func sendToIPhone(_ ids: [UUID]) -> (sent: Int, message: String) {
        let items = ids.compactMap { id in history.items.first { $0.id == id } }
        var ok = 0, no: ClipSyncRules.Refusal?
        for i in items {
            if let r = ClipSyncRules.outbound(i, settings: history.settings, automatic: false) { no = no ?? r; continue }
            if write(i) { ok += 1 }
        }
        if let no { refused += items.count - ok; note = Self.refusalText(no) }
        else if ok == 0 { note = L("Couldn't write to the iCloud Drive folder.") }
        else { note = nil }
        let message = ok > 0 ? String(format: L("%d sent to the iPhone: run “Get from Mac” there"), ok) + (note.map { " · " + $0 } ?? "")
                             : (note ?? L("Couldn't write to the iCloud Drive folder."))
        A11y.announce(message)
        return (ok, message)
    }

    static func refusalText(_ r: ClipSyncRules.Refusal) -> String {
        switch r {
        case .secret: return L("Not sent: it looks like a password, key or card number.")
        case .pattern: return L("Not sent: it matches one of your excluded patterns.")
        case .excludedApp: return L("Not sent: it comes from an excluded app.")
        case .files: return L("Files can't be sent: copy the file's contents, or use AirDrop.")
        case .fromDevice: return L("Not sent: it came from another device.")
        case .tooBig: return L("Not sent: too big.")
        case .empty: return L("Not sent: it's empty.")
        }
    }

    private func write(_ item: ClipItem) -> Bool {
        let content: SyncContent
        switch item.kind {
        case .text: content = .text(item.text)
        case .image:
            guard let png = history.imageData(item) else { return false }
            content = .image(png: png, width: item.width, height: item.height)
        case .files: return false
        }
        guard settings.folderOn, (try? SyncOutbox.write(content, to: folder, now: now())) != nil else { return false }
        sent += 1
        lastSync = now()
        lastSentDigest = item.digest
        return true
    }

    /// "Send every copy": the newest item, when it is new, goes out (checked like any other, never back to its device).
    private func watchCopies() {
        guard settings.folderOn && settings.sendEveryCopy else { watchSub = nil; return }
        lastAuto = history.items.first.map { ($0.id, $0.date) }
        watchSub = history.$items.receive(on: DispatchQueue.main).sink { [weak self] list in
            guard let self, let top = list.first else { return }
            if let l = self.lastAuto, l.id == top.id && l.date == top.date { return }
            self.lastAuto = (top.id, top.date)
            guard top.digest != self.lastSentDigest, ClipSyncRules.outbound(top, settings: self.history.settings, automatic: true) == nil else { return }
            _ = self.write(top)
        }
    }

    // MARK: the test button

    /// Writes a small file into the folder, reads it back, removes it. Says how it went (and how long it took).
    func test() {
        guard !testing else { return }
        testing = true
        let f = folder
        io.async { [weak self] in
            let t0 = Date()
            let probe = f.root.appendingPathComponent("probe-\(UUID().uuidString.prefix(8)).txt")
            let body = "cocaine probe \(UUID().uuidString)"
            var ok = SafeFile.writePrivate(Data(body.utf8), to: probe, folderMode: 0o755)
            ok = ok && (try? String(contentsOf: probe, encoding: .utf8)) == body
            try? FileManager.default.removeItem(at: probe)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DispatchQueue.main.async {
                self?.testing = false
                self?.refreshStatus()
                self?.note = ok ? String(format: L("The folder works: written and read back in %d ms. iCloud uploads it in the background."), ms)
                                : L("Couldn't write to the iCloud Drive folder.")
            }
        }
    }

    func openInFinder() {
        let f = folder
        if FileManager.default.fileExists(atPath: f.root.path) { NSWorkspace.shared.activateFileViewerSelecting([f.root]) }
        else { NSWorkspace.shared.open(ICloudPaths.shortcutsDocuments(home: home)) }
    }

    /// Tests and renders: counters and a status set by hand.
    func setForRender(status: SyncFolderStatus, received: Int, sent: Int, lastSync: Date?) {
        self.status = status; self.received = received; self.sent = sent; self.lastSync = lastSync
    }
}

/// `--clipsync-fixture` for --render-island (memory-only settings): one sample item from the iPhone, and Send to iPhone offered.
enum ClipSyncFixtures {
    static func apply(_ args: [String], _ h: ClipboardHistory) {
        guard AppDefaults.isolated, args.contains("--clipsync-fixture") else { return }
        if let i = h.items.first(where: { $0.text == "#ff6b9d" }) { h.modify(i.id) { $0.source = ClipRules.iPhoneSource } }
        ClipSyncHook.send = { ids in (ids.count, String(format: L("%d sent to the iPhone: run “Get from Mac” there"), ids.count)) }
    }
}
