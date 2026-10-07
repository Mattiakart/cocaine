import AppKit
import Darwin

// Recovery: nothing Cocaine changes may outlive it. While the app runs it keeps a lease ($SUPPORT/recovery.json) saying
// what it has changed that must be undone if it disappears: sleep turned off (the engine's sleep claim), the system HUD
// frozen, screens dimmed, a wake scheduled. Each field is written BEFORE the change and cleared AFTER undoing it.
// A watchdog (`cocaine watch`, a zsh process in its own session, not named Cocaine) reads a pipe only the app writes to:
// EOF means the app is gone (quit, crash, kill -9), and it then runs `Cocaine --recover-after <pid>`, which undoes what
// the lease lists. Quitting normally undoes everything itself. An update hands the session over to the new version.
//
// Files (all 0600 in a 0700 folder): recovery.json + recovery.lock (lease), instance.lock (one app at a time, holding the
// owner's "pid start"); the engine keeps sleep-claim + state.lock, hold.lock + hold.pid (its display-hold helper) and until
// (a command-line deadline). engine/ holds a copy of the engine, remote.zsh and the app's executable, refreshed at every
// launch, so quitting, the watchdog and the hold helper still work if the app bundle is deleted or replaced while it runs.
// COCAINE_SUPPORT, COCAINE_PMSET, COCAINE_SUDO, COCAINE_CAFFEINATE, COCAINE_HUD_NAME, COCAINE_FAKE_BRIGHTNESS point everything
// at stand-ins for --recovery-test; they grant nothing (the sudo rule allows only the real pmset).

// MARK: - Lease

struct RecoveryLease: Codable, Equatable {
    struct Dim: Codable, Equatable { var id: UInt32; var from: Float; var to: Float }
    var owner: Int32
    var ownerStart: Double            // the owner's start time: a reused pid is not the owner
    var ownsSleep: Bool               // this session releases the engine's sleep claim when it ends
    var hudFrozen = false             // OSDUIHelper may be SIGSTOPped
    var dim: [Dim] = []               // backlight lowered from → to
    var wake: Double?                 // a `pmset schedule wake … cocaine` at this time
    var handoverUntil: Double?        // an update is replacing the app: keep sleep on until then for the new version
    var hudPids: [Int32]? = nil       // the OSDUIHelpers Cocaine froze (nil in older leases: any frozen one counts)
}

enum Recovery {
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var handoverSeconds: Double { Double(env["COCAINE_HANDOVER_SECONDS"] ?? "") ?? 180 }   // tests shorten it

    static var directory: String {
        if let d = env["COCAINE_SUPPORT"], !d.isEmpty { return d }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cocaine", isDirectory: true).path
    }
    static var leasePath: String { directory + "/recovery.json" }
    static var engineCopyDirectory: String { directory + "/engine" }
    /// The engine inside the app bundle, while it is there.
    static var bundledEngine: String? {
        guard let p = Bundle.main.resourcePath.map({ $0 + "/cocaine" }), access(p, R_OK) == 0 else { return nil }
        return p
    }
    /// The bundle's engine, or the copy in engine/ once the bundle is gone (deleted, trashed, being replaced).
    static var enginePath: String { bundledEngine ?? engineCopyDirectory + "/cocaine" }

    /// Copies the engine, remote.zsh and the app's executable into engine/ (a clone on APFS: no extra space; the same files
    /// are not copied again). The executable runs there as a plain program for `--recover-after`, when the watchdog or the
    /// hold helper can't run the app's own (deleted, or a new version that crashes).
    @discardableResult
    static func installEngineCopy() -> Bool {
        ensureDirectory()
        let dir = engineCopyDirectory
        mkdir(dir, 0o700)
        let res = Bundle.main.resourcePath ?? "/nonexistent"
        let items: [(src: String?, name: String, mode: mode_t)] = [(res + "/cocaine", "cocaine", 0o700), (res + "/remote.zsh", "remote.zsh", 0o600),
                                                                   (Bundle.main.executablePath, "cocaine-app", 0o700)]
        var ok = true
        for it in items {
            guard let src = it.src, access(src, R_OK) == 0 else { ok = false; continue }
            let dst = dir + "/" + it.name
            if sameContent(src, dst) { continue }
            let tmp = dst + ".\(getpid())"
            unlink(tmp)
            guard copyfile(src, tmp, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else { unlink(tmp); ok = false; continue }
            removexattr(tmp, "com.apple.quarantine", 0)
            chmod(tmp, it.mode)
            if rename(tmp, dst) != 0 { unlink(tmp); ok = false }
        }
        return ok
    }

    /// Same size and bytes (the executable is compared by size and a few slices: it differs everywhere between builds).
    static func sameContent(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a, &sa) == 0, stat(b, &sb) == 0, sa.st_size == sb.st_size else { return false }
        guard let fa = FileHandle(forReadingAtPath: a), let fb = FileHandle(forReadingAtPath: b) else { return false }
        defer { try? fa.close(); try? fb.close() }
        let size = UInt64(sa.st_size), chunk: UInt64 = 1 << 16
        let offsets: [UInt64] = size <= 4 * chunk ? [0] : [0, size / 3, 2 * size / 3, size - chunk]
        for o in offsets {
            let n = Int(min(size <= 4 * chunk ? size : chunk, size - o))
            try? fa.seek(toOffset: o); try? fb.seek(toOffset: o)
            guard let x = try? fa.read(upToCount: n), let y = try? fb.read(upToCount: n), x == y else { return false }
        }
        return true
    }

    // MARK: Pure decisions (tested by --selftest)

    struct Undo: Equatable { var hud = false, dim = false, wake = false }
    static func undo(_ l: RecoveryLease) -> Undo { Undo(hud: l.hudFrozen, dim: !l.dim.isEmpty, wake: l.wake != nil) }

    /// A hand-over still waiting for the new version (an absurd deadline, e.g. after a clock jump, doesn't count).
    static func handoverPending(_ l: RecoveryLease, now: Double) -> Bool {
        guard let u = l.handoverUntil else { return false }
        return u > now && u <= now + 2 * handoverSeconds
    }

    enum LaunchPlan: Equatable { case fresh, ownerAlive, recover(Undo, adoptSleep: Bool) }
    /// At launch, with the lease another session left. Its sleep is adopted (that session goes on: same ON, same timer);
    /// what only a running app maintains (frozen HUD, dimmed screens, a wake for its listener) is undone.
    static func launchPlan(stale: RecoveryLease?, me: Int32, ownerAlive: Bool) -> LaunchPlan {
        guard let s = stale, s.owner != me else { return .fresh }
        if ownerAlive { return .ownerAlive }
        return .recover(undo(s), adoptSleep: s.ownsSleep)
    }

    /// An instance started only to show an alert quits after a few seconds; one that adopted a session (an update's
    /// hand-over, a crash) runs on as the app instead, or quitting would end that session with nothing to take it over.
    static func alertOnly(launchedForAlert: Bool, adoptedSession: Bool) -> Bool { launchedForAlert && !adoptedSession }

    enum AfterExit: Equatable { case nothing, wait, recover(Undo, releaseSleep: Bool) }
    /// What the watchdog does once app `pid` is gone.
    static func afterExit(lease: RecoveryLease?, pid: Int32, ownerAlive: Bool, now: Double) -> AfterExit {
        guard let l = lease, l.owner == pid, !ownerAlive else { return .nothing }   // quit cleanly, or adopted by a new instance
        if handoverPending(l, now: now) { return .wait }
        return .recover(undo(l), releaseSleep: l.ownsSleep)
    }

    enum QuitPlan: Equatable { case keepForHandover, release, drop }
    static func quitPlan(lease: RecoveryLease, now: Double) -> QuitPlan {
        if handoverPending(lease, now: now) && lease.ownsSleep { return .keepForHandover }
        return lease.ownsSleep ? .release : .drop
    }

    /// Put a dimmed screen back only while it still shows Cocaine's dimming (from `to` up to just below `from`):
    /// a brightness the user chose since then, higher or lower, is kept.
    static func shouldRestoreBrightness(current: Float, from: Float, to: Float) -> Bool {
        current >= to - 0.03 && current < from - 0.002
    }

    // MARK: Files

    /// Runs `body` holding recovery.lock (flock; the kernel drops it if we die). After 10 s it goes on without it.
    @discardableResult
    static func locked<T>(_ body: () -> T) -> T {
        ensureDirectory()
        let fd = open(directory + "/recovery.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd >= 0 {
            var tries = 0
            while flock(fd, LOCK_EX | LOCK_NB) != 0 && tries < 400 { usleep(25_000); tries += 1 }
        }
        defer { if fd >= 0 { close(fd) } }
        return body()
    }

    static func ensureDirectory() {
        mkdir(directory, 0o700)
    }

    static func readLease() -> RecoveryLease? {
        guard let d = FileManager.default.contents(atPath: leasePath) else { return nil }
        return try? JSONDecoder().decode(RecoveryLease.self, from: d)
    }

    /// Atomic (temp file + rename), 0600, flushed: the lease must survive a crash or a power cut as written.
    @discardableResult
    static func writeLease(_ l: RecoveryLease) -> Bool {
        ensureDirectory()
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        guard let data = try? e.encode(l) else { return false }
        let tmp = leasePath + ".\(getpid())"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let ok = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) } == data.count
        fsync(fd); close(fd)
        guard ok, rename(tmp, leasePath) == 0 else { unlink(tmp); return false }
        return true
    }

    static func removeLease() { unlink(leasePath) }

    /// There, but not a lease this version can read (damaged, or written by a much newer one).
    static func leaseDamaged() -> Bool { access(leasePath, F_OK) == 0 && readLease() == nil }

    // MARK: Processes

    static func startTime(_ pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
    }

    /// The lease's owner still runs: same pid AND same start time, and not a zombie.
    static func ownerAlive(_ l: RecoveryLease) -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(l.owner, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
        let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
        return info.pbi_status != UInt32(SZOMB) && abs(start - l.ownerStart) < 0.01
    }

    static var hudName: String { env["COCAINE_HUD_NAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "OSDUIHelper" }

    /// Our user's processes called `name` (OSDUIHelper), with whether each is stopped.
    static func processes(named name: String) -> [(pid: pid_t, stopped: Bool)] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))) / MemoryLayout<pid_t>.size
        var out: [(pid_t, Bool)] = []
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  info.pbi_uid == getuid() else { continue }
            let comm = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if comm == name { out.append((pid, info.pbi_status == UInt32(SSTOP))) }
        }
        return out
    }

    /// Gives macOS its volume/brightness HUD back: a frozen OSDUIHelper is ended (SIGKILL works on a stopped process) and
    /// launchd starts a fresh one the next time a HUD is needed — the same thing turning the option off has always done.
    /// Only stopped ones: a running helper is fine as it is. With `only` (the pids the lease says Cocaine froze), a helper
    /// stopped by another tool is left alone; nil or empty = the lease doesn't know (older version): any stopped one.
    @discardableResult
    static func thawHUD(only: [Int32]? = nil) -> Int {
        var n = 0
        let mine = Set(only ?? [])
        for p in processes(named: hudName) where p.stopped && (mine.isEmpty || mine.contains(p.pid)) {
            if kill(p.pid, SIGKILL) == 0 { n += 1 }
        }
        return n
    }

    // MARK: Brightness, wake, engine

    struct BrightnessIO {
        var get: (UInt32) -> Float?
        var set: (UInt32, Float) -> Void
    }

    static let brightness: BrightnessIO = {
        if let path = env["COCAINE_FAKE_BRIGHTNESS"], !path.isEmpty {   // tests: "id value" lines in a file
            func load() -> [UInt32: Float] {
                let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                var m: [UInt32: Float] = [:]
                for line in text.split(separator: "\n") {
                    let f = line.split(separator: " ")
                    if f.count == 2, let id = UInt32(f[0]), let v = Float(f[1]) { m[id] = v }
                }
                return m
            }
            return BrightnessIO(get: { load()[$0] }, set: { id, v in
                var m = load(); m[id] = v
                let text = m.map { "\($0.key) \($0.value)" }.joined(separator: "\n") + "\n"
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
            })
        }
        typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        typealias SetFn = @convention(c) (UInt32, Float) -> Int32
        let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        let g = h.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
        let s = h.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }
        return BrightnessIO(get: { id in var b: Float = 0; return g?(id, &b) == 0 ? b : nil },
                            set: { id, v in _ = s?(id, min(max(v, 0.01), 1)) })
    }()

    /// Undoes a dimming, display by display, unless the user has changed that display's brightness since.
    static func restoreDims(_ dims: [RecoveryLease.Dim]) {
        for d in dims {
            if let cur = brightness.get(d.id), shouldRestoreBrightness(current: cur, from: d.from, to: d.to) { brightness.set(d.id, d.from) }
        }
    }

    /// pmset reads a wake's time as local time in the Mac's time zone at the moment it reads it: the lease keeps the absolute
    /// time and it is written out in the time zone of now (re-read from the system, never a value cached before a change).
    static func wakeString(_ t: Double, timeZone: TimeZone? = nil) -> String {
        NSTimeZone.resetSystemTimeZone()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone ?? TimeZone.current
        f.dateFormat = "MM/dd/yy HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t.rounded(.down)))
    }

    static func cancelWake(_ t: Double) {
        let sudo = env["COCAINE_SUDO"] ?? "/usr/bin/sudo", pmset = env["COCAINE_PMSET"] ?? "/usr/bin/pmset"
        _ = runQuiet(sudo, ["-n", pmset, "schedule", "cancel", "wake", wakeString(t), "cocaine"])
    }

    /// The engine's `release`: 0 done, 2 not authorized, 4 pmset unreadable (the claim is kept); anything else: the engine
    /// couldn't run. Only 0 means sleep is back as it was.
    static func releaseSleep() -> Int32 { runQuiet("/bin/zsh", [enginePath, "release"]) }

    @discardableResult
    static func runQuiet(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Undoes the parts of `l` that `u` lists, clearing each in the lease once done (so a crash here repeats only the rest).
    static func perform(_ u: Undo, on l: inout RecoveryLease) {
        if u.hud { thawHUD(only: l.hudPids); l.hudFrozen = false; l.hudPids = nil; writeLease(l) }
        if u.dim { restoreDims(l.dim); l.dim = []; writeLease(l) }
        if u.wake, let w = l.wake { cancelWake(w); l.wake = nil; writeLease(l) }
    }

    // MARK: Single instance

    private static var instanceFD: Int32 = -1

    /// One Cocaine at a time: two would each freeze the HUD, dim and fight over the switch. Holds instance.lock for the
    /// app's life (the kernel drops it on any exit). Another instance may be quitting (an update): wait up to `wait` s.
    /// `runningApps` also waits for an older Cocaine (no lock) launched before us.
    /// Of two instances, the one that started first stays (same start time: the lower pid), so exactly one survives.
    static func startedFirst(_ pid: pid_t, _ start: Double?, than me: pid_t, _ myStart: Double) -> Bool {
        guard let start else { return false }                    // already gone
        return start < myStart || (start == myStart && pid < me)
    }

    /// The process holding instance.lock, as it wrote itself there ("pid start"); nil when unknown or no longer that process.
    static func instanceHolder() -> (pid: pid_t, start: Double)? {
        guard let text = try? String(contentsOfFile: directory + "/instance.lock", encoding: .utf8) else { return nil }
        let f = text.split(separator: " ")
        guard f.count >= 2, let pid = pid_t(f[0]), pid > 1, let start = Double(f[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              let now = startTime(pid), abs(now - start) < 0.01 else { return nil }
        return (pid, start)
    }

    /// The program `pid` was started from no longer exists (its app bundle was deleted, trashed or moved).
    static func executableGone(_ pid: pid_t) -> Bool {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        // A running process whose executable file was deleted has no path any more: that counts as gone too.
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return startTime(pid) != nil }
        return access(String(cString: buf), F_OK) != 0
    }

    /// Asks a running instance (by pid) to show its panel: what opening Cocaine again should do.
    static var showPanelNotification: Notification.Name { Notification.Name((Bundle.main.bundleIdentifier ?? "local.cocaine.toggle") + ".show-panel") }
    static func askToShowPanel(_ pid: pid_t) {
        DistributedNotificationCenter.default().postNotificationName(showPanelNotification, object: String(pid), userInfo: nil, deliverImmediately: true)
    }

    /// Ends `pid` (after checking it is still the process that started at `start`): SIGTERM (it quits cleanly, undoing what it
    /// changed), then SIGKILL after `grace` s (its watchdog undoes it then). True once it is gone.
    @discardableResult
    static func terminate(_ pid: pid_t, start: Double, grace: Double = 8) -> Bool {
        func same() -> Bool { startTime(pid).map { abs($0 - start) < 0.01 } ?? false }
        guard pid > 1, pid != getpid(), same() else { return true }
        kill(pid, SIGTERM)
        let end = Date().addingTimeInterval(grace)
        while Date() < end { if !same() { return true }; usleep(100_000) }
        if same() { kill(pid, SIGKILL); usleep(300_000) }
        return !same()
    }

    /// `takeOver` (a normal launch): an instance whose app was deleted (a copy left running by an install or the Trash) is
    /// ended and this one starts; one that is fine is asked to show its panel, and this one leaves (never silently: it logs).
    static func claimSingleInstance(wait: Double = 10, runningApps: Bool = true, takeOver: Bool = false) -> Bool {
        ensureDirectory()
        var deadline = Date().addingTimeInterval(wait)
        let fd = open(directory + "/instance.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd >= 0 {
            var triedTakeOver = false, asked = false
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if takeOver && !triedTakeOver, let h = instanceHolder() {
                    triedTakeOver = true
                    if executableGone(h.pid) {
                        log.notice("an instance from a deleted copy of Cocaine (pid \(h.pid)) holds the lock: ending it")
                        terminate(h.pid, start: h.start)
                        deadline = max(deadline, Date().addingTimeInterval(5))
                        continue
                    }
                    // It may be quitting (an update): keep waiting for the lock, but have a running one show its panel now.
                    log.notice("Cocaine is already running (pid \(h.pid)): asking it to show its panel")
                    askToShowPanel(h.pid); asked = true
                }
                if Date() >= deadline {
                    if takeOver && !asked { log.notice("another Cocaine holds the instance lock: leaving") }
                    close(fd); return false
                }
                usleep(100_000)
            }
            let me = getpid()
            let stamp = "\(me) \(startTime(me) ?? 0)\n"
            ftruncate(fd, 0)
            _ = stamp.withCString { pwrite(fd, $0, strlen($0), 0) }
            instanceFD = fd
        }
        guard runningApps, let id = Bundle.main.bundleIdentifier else { return true }
        // Not NSRunningApplication.current: before NSApplication starts it reports pid -1 and no launch date.
        let me = getpid(), myStart = startTime(me) ?? Date().timeIntervalSince1970
        func older() -> Bool {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { a in
                guard a.processIdentifier != me, !a.isTerminated, a.activationPolicy != .prohibited else { return false }
                return startedFirst(a.processIdentifier, startTime(a.processIdentifier), than: me, myStart)
            }
        }
        while older() {
            if Date() >= deadline { return false }
            usleep(200_000)
        }
        return true
    }
}

// MARK: - The app's session

/// The running app's side: writes the lease as things change, keeps the watchdog alive with a heartbeat, and at quit
/// undoes or hands over. All on the main thread.
final class RecoverySession {
    static let shared = RecoverySession()
    private(set) var active = false
    private var lease: RecoveryLease?
    private var writeFD: Int32 = -1
    private(set) var watchdogPID: pid_t = 0
    private var lastSpawn = Date.distantPast
    private var respawnDelay: TimeInterval = 10      // doubles (to 5 min) while new watchdogs keep dying at once
    private var heartbeat: Timer?
    private var bundleStamp: (dev: dev_t, ino: ino_t)?
    private var bundleStrikes = 0
    private var bundleHandled = false
    private var showPanelObserver: NSObjectProtocol?

    /// The in-app updater is replacing the bundle itself: not a reason to quit (it quits and relaunches on its own).
    var expectingReplacement = false
    /// What to do once this app's bundle is gone (deleted, trashed) or replaced by another copy at the same path while it
    /// runs. Default: quit normally (which releases sleep through the engine copy in engine/); when it was replaced, the new
    /// copy is opened once this process has quit and adopts the session. `--recovery-owner` sets its own.
    var onBundleGone: ((_ replaced: Bool) -> Void)?
    /// Another launch asked this instance to show its panel. Default: `cocaine://panel` through the app delegate.
    var onShowPanel: (() -> Void)?

    /// At launch (after claimSingleInstance). Recovers what a dead session left, adopting its sleep; then takes over the
    /// lease and starts the watchdog. Returns true when it adopted a previous session's sleep.
    @discardableResult
    func start(ownsSleep: Bool) -> Bool {
        guard !active else { return false }
        let me = getpid()
        var adopted = false
        Recovery.installEngineCopy()                     // before anything needs it: quitting, the watchdog, the hold helper
        Recovery.locked {
            if Recovery.leaseDamaged() {
                Recovery.thawHUD()                   // what it said is unknown: at least the system HUD comes back (always safe)
            } else if var stale = Recovery.readLease() {
                switch Recovery.launchPlan(stale: stale, me: me, ownerAlive: Recovery.ownerAlive(stale)) {
                case .recover(let u, let adopt):
                    Recovery.perform(u, on: &stale)
                    adopted = adopt
                case .ownerAlive, .fresh: break      // can't happen past the instance lock; we take the lease over
                }
            }
            let l = RecoveryLease(owner: me, ownerStart: Recovery.startTime(me) ?? 0, ownsSleep: ownsSleep || adopted)
            Recovery.writeLease(l)
            lease = l
        }
        active = true
        if let exe = Bundle.main.executablePath { var st = stat(); if stat(exe, &st) == 0 { bundleStamp = (st.st_dev, st.st_ino) } }
        spawnWatchdog()
        let every = Double(Recovery.env["COCAINE_HEARTBEAT"] ?? "") ?? 2
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.beat() }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
        // Opening Cocaine again while it runs shows this instance's panel (see Recovery.claimSingleInstance).
        showPanelObserver = DistributedNotificationCenter.default().addObserver(forName: Recovery.showPanelNotification, object: String(me), queue: .main) { [weak self] _ in
            if let h = self?.onShowPanel { h(); return }
            guard let app = NSApp, let url = URL(string: "cocaine://panel") else { return }
            app.delegate?.application?(app, open: [url])
        }
        return adopted
    }

    /// Read-modify-write under the lock, so a `--prepare-update` written meanwhile by another process is kept.
    private func mutate(_ change: (inout RecoveryLease) -> Void) {
        guard active, var base = lease else { return }
        Recovery.locked {
            if let disk = Recovery.readLease(), disk.owner == base.owner { base = disk }
            change(&base)
            Recovery.writeLease(base)
            lease = base
        }
    }

    func noteHUD(_ frozen: Bool) { if lease?.hudFrozen != frozen { mutate { $0.hudFrozen = frozen; if !frozen { $0.hudPids = nil } } } }
    /// An OSDUIHelper Cocaine has just frozen (recovery then ends only those, never one another tool stopped).
    func noteFrozen(_ pid: pid_t) {
        guard lease?.hudPids?.contains(pid) != true else { return }
        mutate { l in l.hudFrozen = true; l.hudPids = Array(((l.hudPids ?? []) + [pid]).suffix(8)) }
    }
    func noteDim(_ dims: [RecoveryLease.Dim]) { if lease?.dim != dims { mutate { $0.dim = dims } } }
    func noteWake(_ t: Double?) { if lease?.wake != t { mutate { $0.wake = t } } }

    /// An update is about to replace the app: when it quits, sleep stays as it is for `Recovery.handoverSeconds`, for
    /// the new version to adopt; if no new version starts by then, the watchdog releases it.
    @discardableResult
    func prepareForUpdateHandover() -> Bool {
        guard active else { return false }
        mutate { $0.handoverUntil = Date().timeIntervalSince1970 + Recovery.handoverSeconds }
        return true
    }

    /// The update won't restart the app after all: a later quit releases sleep as usual.
    func cancelUpdateHandover() { if active { mutate { $0.handoverUntil = nil } } }

    /// At quit, after the HUD, dimming and wake have been undone (and noted). Releases sleep, or keeps it for an update.
    /// The lease is removed only once sleep is really back: if the engine couldn't do it (not authorized, pmset unreadable,
    /// no engine at all), the watchdog tries again, and failing that the next launch adopts the session.
    func end() {
        guard active, let mine = lease else { return }
        active = false
        heartbeat?.invalidate(); heartbeat = nil
        Recovery.locked {
            var l = Recovery.readLease().flatMap { $0.owner == mine.owner ? $0 : nil } ?? mine
            switch Recovery.quitPlan(lease: l, now: Date().timeIntervalSince1970) {
            case .keepForHandover:
                l.hudFrozen = false; l.dim = []; l.wake = nil; l.hudPids = nil
                Recovery.writeLease(l)
            case .release:
                if Recovery.releaseSleep() == 0 { Recovery.removeLease() } else { Recovery.writeLease(l) }
            case .drop:
                Recovery.removeLease()
            }
        }
        // The pipe closes when we exit; the watchdog then finds nothing (or the hand-over, or what's left) and acts.
    }

    // MARK: Watchdog

    private func spawnWatchdog() {
        guard let bin = Bundle.main.executablePath else { return }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return }
        let (r, w) = (fds[0], fds[1])
        _ = fcntl(r, F_SETFD, FD_CLOEXEC)
        _ = fcntl(w, F_SETFD, FD_CLOEXEC)                       // never inherited: only this process may keep the pipe open
        _ = fcntl(w, F_SETFL, O_NONBLOCK)
        _ = fcntl(w, F_SETNOSIGPIPE, 1)                         // a dead watchdog is an EPIPE, not a SIGPIPE
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, r, 0)
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // Own session (Ctrl-C, a closed Terminal or a process-group kill don't reach it), default signals, and no inherited fds.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var all = sigset_t(~0 as UInt32), none = sigset_t(0)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        let args = ["/bin/zsh", Recovery.enginePath, "watch", String(getpid()), bin]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/zsh", &fa, &attr, &argv, environ)
        argv.forEach { free($0) }
        posix_spawn_file_actions_destroy(&fa)
        posix_spawnattr_destroy(&attr)
        close(r)
        lastSpawn = Date()
        if rc == 0 {
            if writeFD >= 0 { close(writeFD) }
            writeFD = w
            watchdogPID = pid
        } else {
            close(w)
        }
    }

    /// Tells the watchdog the app is alive (and not hung); starts a new one if it has gone (at once the first time, then
    /// less and less often while new ones keep dying: no endless spawning every 10 s). Also notices the bundle going away.
    private func beat() {
        guard active else { return }
        var gone = writeFD < 0 || watchdogPID == 0
        if !gone {
            var b: UInt8 = 104
            if write(writeFD, &b, 1) < 0 && errno == EPIPE { gone = true }
            var st: Int32 = 0
            if waitpid(watchdogPID, &st, WNOHANG) == watchdogPID { gone = true }
        }
        if !gone && Date().timeIntervalSince(lastSpawn) > 60 { respawnDelay = 10 }     // this one has lived: back to normal
        if gone && Date().timeIntervalSince(lastSpawn) > respawnDelay {
            if writeFD >= 0 { close(writeFD); writeFD = -1 }
            watchdogPID = 0
            if Date().timeIntervalSince(lastSpawn) < 120 { respawnDelay = min(respawnDelay * 2, 300) }
            spawnWatchdog()
        }
        checkBundle()
    }

    enum BundleState: Equatable { case same, gone, replaced }
    /// The file `path` compared with the one this app was started from (device and inode).
    static func bundleState(path: String?, stamp: (dev: dev_t, ino: ino_t)?) -> BundleState {
        guard let path, let stamp else { return .same }
        var st = stat()
        if stat(path, &st) != 0 { return errno == ENOENT || errno == ENOTDIR ? .gone : .same }
        return st.st_dev == stamp.dev && st.st_ino == stamp.ino ? .same : .replaced
    }

    private func checkBundle() {
        guard !bundleHandled, !expectingReplacement else { bundleStrikes = 0; return }
        let s = Self.bundleState(path: Bundle.main.executablePath, stamp: bundleStamp)
        guard s != .same else { bundleStrikes = 0; return }
        bundleStrikes += 1
        guard bundleStrikes >= 2 else { return }                // seen twice in a row, not in the middle of a swap
        bundleHandled = true
        let replaced = s == .replaced
        log.notice("this copy of Cocaine was \(replaced ? "replaced" : "deleted", privacy: .public) while running: quitting\(replaced ? " and opening the new one" : "", privacy: .public)")
        if let h = onBundleGone { h(replaced); return }
        if replaced {
            prepareForUpdateHandover()                          // the new copy adopts the session: no off/on blip
            if Detached.spawn(["/bin/sh", "-c", Self.reopenScript, "cocaine-reopen", String(getpid()), Bundle.main.bundlePath]) == nil {
                cancelUpdateHandover()
            }
        }
        NSApp.terminate(nil)
    }

    /// Waits (up to a minute) for this process to quit, then opens the app now at its path.
    static let reopenScript = """
    i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 600 ] && exit 3; sleep 0.1; done
    exec /usr/bin/open "$2"
    """
}

/// Starts a program in its own session, detached from this app (it outlives it; Ctrl-C or a process-group kill don't reach
/// it), with default signals and no inherited descriptors. Returns its pid.
enum Detached {
    @discardableResult
    static func spawn(_ args: [String], environment: [String: String]? = nil) -> pid_t? {
        guard let path = args.first else { return nil }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var all = sigset_t(~0 as UInt32), none = sigset_t(0)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let envList = environment.map { $0.map { "\($0.key)=\($0.value)" } }
        var envp: [UnsafeMutablePointer<CChar>?]? = envList.map { $0.map { strdup($0) } + [nil] }
        var pid: pid_t = 0
        let rc: Int32
        if var e = envp { rc = posix_spawn(&pid, path, &fa, &attr, &argv, &e) } else { rc = posix_spawn(&pid, path, &fa, &attr, &argv, environ) }
        argv.forEach { free($0) }
        envp?.forEach { free($0) }
        envp = nil
        posix_spawn_file_actions_destroy(&fa)
        posix_spawnattr_destroy(&attr)
        return rc == 0 ? pid : nil
    }
}

/// SIGTERM, SIGINT or SIGHUP that arrive while the app is still starting (before AppDelegate installs its own handlers) are
/// held and turn into a normal quit once it runs, instead of killing it half set up.
enum EarlyQuit {
    private static var sources: [DispatchSourceSignal] = []
    static func install() {
        sources = [SIGTERM, SIGINT, SIGHUP].map { sig in
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { NSApp?.terminate(nil) }
            s.resume()
            return s
        }
    }
}

/// Called by the in-app updater right before it quits the app to install a new version: the new version adopts the
/// session (sleep stays on, no off/on blip); if it never starts, the watchdog releases sleep after
/// `Recovery.handoverSeconds`. The HUD, dimming and wake are still undone at quit as usual.
@discardableResult
func prepareForUpdateHandover() -> Bool { RecoverySession.shared.prepareForUpdateHandover() }

/// The COCAINE_* variables point the engine, the recovery and the updater at stand-ins for tests. A normal launch of the
/// app removes them from its own environment (so also from everything it starts), whoever set them.
enum TestOverrides {
    @discardableResult
    static func scrub(prefix: String = "COCAINE_") -> [String] {
        let names = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix(prefix) }.sorted()
        names.forEach { unsetenv($0) }
        return names
    }
}

// MARK: - Command line (used by the watchdog and by Homebrew)

enum RecoveryCLI {
    /// nil: not a recovery command.
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "--recover-after":
            guard args.count == 3, let pid = Int32(args[2]) else { return 64 }
            return recoverAfter(pid)
        case "--recover-hud":
            guard args.count == 3, let pid = Int32(args[2]) else { return 64 }
            return recoverHUD(pid)
        case "--prepare-update":
            return prepareUpdate()
        case "--uninstall-cleanup":
            return uninstallCleanup()
        case "--boot-check":
            return bootCheck()
        default:
            return nil
        }
    }

    /// Exit statuses the watchdog understands: 0 done (or nothing to do), 75 try again later (hand-over pending, pmset
    /// unreadable), 69 sleep couldn't be released (not authorized, no engine): the lease is kept for the next launch.
    static let done: Int32 = 0, later: Int32 = 75, notReleased: Int32 = 69

    static func released(_ status: Int32) -> Int32 { status == 0 ? done : status == 4 ? later : notReleased }

    /// The watchdog, once app `pid` is gone.
    static func recoverAfter(_ pid: Int32, holdingInstanceLock: Bool = false) -> Int32 {
        Recovery.locked { () -> Int32 in
            // Unreadable: whose it was is unknown. With no Cocaine running (its instance lock is free), undo the safe parts:
            // the HUD, and sleep through the engine's claim (which only puts back what Cocaine itself changed).
            if Recovery.leaseDamaged() {
                guard holdingInstanceLock || Recovery.claimSingleInstance(wait: 0, runningApps: false) else { return done }
                Recovery.thawHUD()
                let r = released(Recovery.releaseSleep())
                if r == done { Recovery.removeLease() }
                return r
            }
            guard var l = Recovery.readLease() else { return done }
            switch Recovery.afterExit(lease: l, pid: pid, ownerAlive: Recovery.ownerAlive(l), now: Date().timeIntervalSince1970) {
            case .nothing: return done
            case .wait: return later
            case .recover(let u, let releaseSleep):
                Recovery.perform(u, on: &l)
                if releaseSleep {
                    let r = released(Recovery.releaseSleep())
                    if r != done { return r }                      // the lease stays: the next try (or launch) takes it
                }
                Recovery.removeLease()
                return done
            }
        }
    }

    /// The app is alive but has stopped answering: give the system HUD back (it freezes it again if it recovers).
    static func recoverHUD(_ pid: Int32) -> Int32 {
        Recovery.locked {
            if let l = Recovery.readLease(), l.owner == pid, l.hudFrozen { Recovery.thawHUD(only: l.hudPids) }
        }
        return 0
    }

    /// `brew upgrade`, before quitting the old version: hand the running session over to the new one.
    static func prepareUpdate() -> Int32 {
        Recovery.locked {
            guard var l = Recovery.readLease(), Recovery.ownerAlive(l), l.ownsSleep else { return }
            l.handoverUntil = Date().timeIntervalSince1970 + Recovery.handoverSeconds
            Recovery.writeLease(l)
        }
        return 0
    }

    /// `--boot-check`: for a login item or a person at Terminal, with no Cocaine running. Undoes what a session that didn't
    /// survive a restart, a power cut or a kill of both the app and its watchdog left (its lease: sleep back as it was,
    /// dimmed screens, a scheduled wake, a frozen HUD), and ends a command-line deadline (`cocaine on 90m`) that has passed.
    /// With Cocaine running it does nothing (the app handles both). 0, or 75 when pmset couldn't be read.
    static func bootCheck() -> Int32 {
        guard Recovery.claimSingleInstance(wait: 0, runningApps: false) else { return done }
        var r = done
        if Recovery.leaseDamaged() { r = recoverAfter(0, holdingInstanceLock: true) }
        else if let l = Recovery.readLease(), !Recovery.ownerAlive(l) { r = recoverAfter(l.owner, holdingInstanceLock: true) }
        Recovery.runQuiet("/bin/zsh", [Recovery.enginePath, "expire"])
        return r == later ? later : done
    }

    /// `brew uninstall`, before the sudo rule goes: nothing of Cocaine may stay behind. A running Cocaine is asked to quit
    /// first (SIGTERM to the lease's owner, checked by pid AND start time, so a reused pid is never signalled; a quit
    /// undoes everything itself). 75 = it is still running: the cask then keeps the sudo rule, so sleep can still be put back.
    static func uninstallCleanup() -> Int32 {
        let wait = Double(Recovery.env["COCAINE_INSTANCE_WAIT"] ?? "") ?? 10
        if !Recovery.claimSingleInstance(wait: min(wait, 2), runningApps: false) {
            var owners: [(pid_t, Double)] = []
            if let l = Recovery.readLease(), Recovery.ownerAlive(l) { owners.append((l.owner, l.ownerStart)) }
            if let h = Recovery.instanceHolder(), !owners.contains(where: { $0.0 == h.pid }) { owners.append(h) }
            for (pid, start) in owners { Recovery.terminate(pid, start: start, grace: wait) }
            guard Recovery.claimSingleInstance(wait: wait, runningApps: false) else { return later }
        }
        // Watchdogs still retrying after a crash, started from the bundle's engine or from the copy in engine/.
        for engine in Set([Recovery.bundledEngine, Recovery.engineCopyDirectory + "/cocaine"].compactMap { $0 }) {
            let literal = engine.replacingOccurrences(of: "([\\[\\]\\\\.^$*+?(){}|])", with: "\\\\$1", options: .regularExpression)
            Recovery.runQuiet("/usr/bin/pkill", ["-KILL", "-U", String(getuid()), "-xf", "/bin/zsh \(literal) watch [0-9]+ .*"])
        }
        var result = done
        Recovery.locked {
            if var l = Recovery.readLease(), !Recovery.ownerAlive(l) {
                Recovery.perform(Recovery.Undo(hud: false, dim: true, wake: true), on: &l)
            }
            Recovery.thawHUD()                                   // nothing else freezes it: any frozen one is a leftover
            let r = Recovery.releaseSleep()                      // back to the state before Cocaine; ends the display hold
            if r == 0 { Recovery.removeLease() } else { result = released(r) }
        }
        guard result == done else { return result }               // sleep not back yet: keep the state (and the sudo rule)
        for f in ["recovery.lock", "sleep-claim", "state.lock", "hold.lock", "hold.pid", "until", "instance.lock"] { unlink(Recovery.directory + "/" + f) }
        try? FileManager.default.removeItem(atPath: Recovery.engineCopyDirectory)
        return done
    }
}
