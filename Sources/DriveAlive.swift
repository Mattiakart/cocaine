// Keep selected disks awake (Amphetamine's "Drive Alive"): every chosen interval Cocaine touches each chosen volume that is
// mounted, so an external drive doesn't spin down (or a NAS doesn't park its disks) while you need it.
//
// How, honestly:
//  - "Tiny hidden file" (the default, the one that works): Cocaine rewrites one 64-byte file of its own at the volume's top level,
//    `.cocaine-drive-alive` (hidden, excluded from Time Machine), with F_NOCACHE and F_FULLFSYNC so the write reaches the disk
//    itself instead of staying in memory. Always the same file and the same size: nothing piles up. Opened with O_NOFOLLOW and
//    only if it is a small regular file with one link (never a link someone put there). Removing a disk from the list deletes that file.
//    Read-only volumes are skipped (a read-only volume can only use "Read only").
//  - "Read only": nothing is ever written. Cocaine reads 4 KB with F_NOCACHE from a different spot of one large file near the
//    top of the volume. Best effort: if macOS already has that piece in memory the disk isn't touched, so on a volume of small
//    files it may not keep the disk spinning. Some file systems note an access time.
//  - Each touch opens and closes the file at once (an eject is never blocked) and never happens while macOS is unmounting the
//    volume; one touch at a time per volume, off the main thread.
//  - Limits: a drive's own firmware sleep timer (some USB enclosures) may ignore activity it doesn't see as "real"; a disk asleep
//    because the Mac slept wakes with the Mac. macOS may ask once whether Cocaine may use files on a removable or network volume
//    (Privacy & Security → Files and Folders). Not verified here with a real spinning external drive (none attached): tested on
//    temporary folders and a disk image (--triggers-test).

import AppKit
import Darwin

extension Settings {
    /// The volumes to keep awake, by name.
    var driveAliveVolumes: [String] { get { AwakeLists.clean(d.stringArray(forKey: "driveAliveVolumes")) } nonmutating set { d.set(AwakeLists.clean(newValue), forKey: "driveAliveVolumes") } }
    /// Seconds between touches.
    var driveAliveInterval: Int {
        get { let v = d.object(forKey: "driveAliveInterval") as? Int ?? 60; return DriveAlive.intervals.contains(v) ? v : 60 }
        nonmutating set { d.set(DriveAlive.intervals.contains(newValue) ? newValue : 60, forKey: "driveAliveInterval") }
    }
    /// "write" (a tiny hidden file) or "read" (nothing written).
    var driveAliveMethod: String {
        get { d.string(forKey: "driveAliveMethod") == "read" ? "read" : "write" }
        nonmutating set { d.set(newValue == "read" ? "read" : "write", forKey: "driveAliveMethod") }
    }
    /// Only while Cocaine is on (default), or always.
    var driveAliveAlways: Bool { get { flag("driveAliveAlways", false) } nonmutating set { d.set(newValue, forKey: "driveAliveAlways") } }
}

/// A mounted volume the list can offer.
struct DriveVolume: Equatable {
    var name: String
    var path: String
    var readOnly = false
    var network = false
}

enum DriveAlive {
    static let intervals = [30, 60, 120, 300, 600]
    static let fileName = ".cocaine-drive-alive"
    static let fileSize = 64

    /// Mounted volumes other than the startup disk (hidden system volumes left out).
    static func mounted() -> [DriveVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true, let n = v.volumeName else { return nil }
            return DriveVolume(name: n, path: u.path, readOnly: v.volumeIsReadOnly == true, network: v.volumeIsLocal == false)
        }
    }
}

/// When each volume is due: chosen, mounted, not being unmounted, and the interval passed since its last touch (the first
/// touch at once). Only while Cocaine is on unless "always".
struct DriveAliveSchedule {
    private(set) var last: [String: Date] = [:]          // by mount path
    private(set) var pausedUntil: [String: Date] = [:]

    mutating func due(chosen: [String], mounted: [DriveVolume], interval: Int, on: Bool, always: Bool, now: Date) -> [DriveVolume] {
        let wanted = mounted.filter { m in chosen.contains { $0.caseInsensitiveCompare(m.name) == .orderedSame } }
        last = last.filter { k, _ in wanted.contains { $0.path == k } }        // gone or unchosen: starts afresh next time
        pausedUntil = pausedUntil.filter { $0.value > now }
        guard on || always else { return [] }
        return wanted.filter { v in
            guard pausedUntil[v.path] == nil else { return false }
            if let l = last[v.path], now.timeIntervalSince(l) < Double(interval) { return false }
            return true
        }
    }

    mutating func touched(_ path: String, at: Date) { last[path] = at }

    /// macOS is unmounting it: no touch for a while (it may come back under the same path).
    mutating func unmounting(_ path: String, now: Date) { pausedUntil[path] = now.addingTimeInterval(60); last[path] = nil }
}

enum DriveTouchError: Error, Equatable {
    case readOnly, notOurs, noFile, failed(Int32)
}

enum DriveToucher {
    /// The 64 bytes written each time (a line saying what the file is, padded).
    static func payload(_ now: Date) -> Data {
        var s = "Cocaine keeps this disk awake. Safe to delete. \(Int(now.timeIntervalSince1970))"
        s = String(s.prefix(DriveAlive.fileSize - 1))
        s += String(repeating: " ", count: DriveAlive.fileSize - 1 - s.utf8.count) + "\n"
        return Data(s.utf8)
    }

    /// One write of the tiny hidden file at `root`, through to the disk.
    static func write(root: String, now: Date = Date()) -> Result<Void, DriveTouchError> {
        let path = (root as NSString).appendingPathComponent(DriveAlive.fileName)
        var st = stat()
        let existed = lstat(path, &st) == 0
        if existed && ((st.st_mode & S_IFMT) != S_IFREG || st.st_size > 4096) { return .failure(.notOurs) }   // a link, a folder, a big file: not ours
        let fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .failure(errno == EROFS ? .readOnly : .failed(errno)) }
        defer { close(fd) }
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { return .failure(.notOurs) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let bytes = payload(now)
        let n = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, bytes.count, 0) }
        guard n == bytes.count else { return .failure(.failed(errno)) }
        _ = ftruncate(fd, off_t(bytes.count))
        if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }       // some file systems (network ones) don't take F_FULLFSYNC
        if !existed {
            _ = fchflags(fd, UInt32(UF_HIDDEN))
            var u = URL(fileURLWithPath: path), rv = URLResourceValues()     // Time Machine leaves it out
            rv.isExcludedFromBackup = true
            try? u.setResourceValues(rv)
        }
        return .success(())
    }

    /// Deletes the tiny file at `root` if it is ours (a small regular file).
    @discardableResult
    static func remove(root: String) -> Bool {
        let path = (root as NSString).appendingPathComponent(DriveAlive.fileName)
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= 4096 else { return false }
        return unlink(path) == 0
    }

    /// A large file near the top of the volume (its top level and one level down, at most 400 entries looked at): the
    /// largest regular file, not hidden, not ours.
    static func readTarget(root: String) -> String? {
        let fm = FileManager.default
        var best: (String, Int64)?, seen = 0
        func look(_ dir: String, depth: Int) {
            guard seen < 400, let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in names where !n.hasPrefix(".") {
                seen += 1
                if seen >= 400 { return }
                let p = (dir as NSString).appendingPathComponent(n)
                var st = stat()
                guard lstat(p, &st) == 0 else { continue }
                if (st.st_mode & S_IFMT) == S_IFREG {
                    if st.st_size > (best?.1 ?? 0) { best = (p, Int64(st.st_size)) }
                } else if (st.st_mode & S_IFMT) == S_IFDIR && depth == 0 {
                    look(p, depth: 1)
                }
            }
        }
        look(root, depth: 0)
        return best?.0
    }

    /// One uncached 4 KB read at `offsetSeed`'s spot of `file` (nothing written).
    static func read(file: String, offsetSeed: UInt64) -> Result<Void, DriveTouchError> {
        let fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.failed(errno)) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else { return .failure(.noFile) }
        _ = fcntl(fd, F_NOCACHE, 1)
        _ = fcntl(fd, F_RDAHEAD, 0)
        let blocks = max(1, UInt64(st.st_size) / 4096)
        let off = off_t((offsetSeed % blocks) * 4096)
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 4096, off) }
        return n >= 0 ? .success(()) : .failure(.failed(errno))
    }

    static func describe(_ e: DriveTouchError) -> String {
        switch e {
        case .readOnly: return L("Read-only disk: choose Read only")
        case .notOurs: return String(format: L("Something else is named %@ there: left alone"), DriveAlive.fileName)
        case .noFile: return L("No file to read on this disk")
        case .failed(let code): return code == EPERM || code == EACCES ? L("Not allowed: Privacy & Security → Files and Folders") : String(format: L("Failed (error %d)"), Int(code))
        }
    }
}

/// The running part: AwakeCenter calls `tick` every 2 s; touches run on a serial queue, results come back on the main thread.
final class DriveAliveRunner {
    struct Status: Equatable { var at: Date?; var problem: String? }
    private var schedule = DriveAliveSchedule()
    private let queue = DispatchQueue(label: "cocaine.drive-alive", qos: .utility)
    private var inFlight = Set<String>()
    private var targets: [String: String] = [:]          // read mode: the file picked per volume
    private var seed = UInt64.random(in: 0..<UInt64.max)
    private var observers: [NSObjectProtocol] = []
    private var lastLook = Date.distantPast
    /// By volume name (what the panel shows).
    var statusChanged: (String, Status) -> Void = { _, _ in }

    func start() {
        let c = NSWorkspace.shared.notificationCenter
        observers.append(c.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] n in
            if let path = (n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path { self?.schedule.unmounting(path, now: Date()) }
        })
    }

    /// The mounted volumes (tests: a stand-in). Read on the runner's queue, never on the main thread: a network volume that stopped
    /// answering can keep `mountedVolumeURLs`' name and flag lookups waiting for a long time, and this used to run in the app's
    /// 0.5 s tick.
    var mountedReader: () -> [DriveVolume] = DriveAlive.mounted
    private var looking = false

    func tick(settings: Settings, on: Bool, now: Date = Date()) {
        let chosen = settings.driveAliveVolumes
        guard !chosen.isEmpty, !looking, now.timeIntervalSince(lastLook) >= 5 || now < lastLook else { return }    // a look every 5 s is plenty
        lastLook = now
        looking = true
        let interval = settings.driveAliveInterval, always = settings.driveAliveAlways, method = settings.driveAliveMethod
        let read = mountedReader
        queue.async { [weak self] in
            let mounted = read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.looking = false
                self.touchDue(chosen: chosen, mounted: mounted, interval: interval, on: on, always: always, method: method, now: now)
            }
        }
    }

    private func touchDue(chosen: [String], mounted: [DriveVolume], interval: Int, on: Bool, always: Bool, method: String, now: Date) {
        let due = schedule.due(chosen: chosen, mounted: mounted, interval: interval, on: on, always: always, now: now)
        for v in due where !inFlight.contains(v.path) {
            inFlight.insert(v.path)
            schedule.touched(v.path, at: now)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let s = seed, cached = targets[v.path]
            queue.async { [weak self] in
                var target = cached
                let r: Result<Void, DriveTouchError>
                if method == "read" {
                    if target == nil || !FileManager.default.fileExists(atPath: target!) { target = DriveToucher.readTarget(root: v.path) }
                    r = target.map { DriveToucher.read(file: $0, offsetSeed: s) } ?? .failure(.noFile)
                } else if v.readOnly {
                    r = .failure(.readOnly)
                } else {
                    r = DriveToucher.write(root: v.path)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight.remove(v.path)
                    self.targets[v.path] = target
                    switch r {
                    case .success: self.statusChanged(v.name, Status(at: Date(), problem: nil))
                    case .failure(let e):
                        log.notice("drive alive: \(String(describing: e), privacy: .public)")
                        self.statusChanged(v.name, Status(at: nil, problem: DriveToucher.describe(e)))
                    }
                }
            }
        }
    }

    /// A volume taken off the list: its tiny file goes too (when mounted and ours).
    func removed(_ names: [String]) {
        queue.async { Self.removeFiles(names: names, mounted: DriveAlive.mounted()) }
    }

    /// The method changed to "Read only" (nothing written from now on): the tiny files already written go too.
    func methodChanged(to method: String, names: [String]) {
        guard method == "read", !names.isEmpty else { return }
        queue.async { Self.removeFiles(names: names, mounted: DriveAlive.mounted()) }
    }

    /// Deletes the tiny file (if it is ours) on each of `names` that is mounted and writable. Returns how many went.
    @discardableResult
    static func removeFiles(names: [String], mounted: [DriveVolume]) -> Int {
        mounted.filter { m in !m.readOnly && names.contains { $0.caseInsensitiveCompare(m.name) == .orderedSame } }
            .filter { DriveToucher.remove(root: $0.path) }.count
    }
}
