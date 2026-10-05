import AppKit
import Darwin

// Recovery: nothing Cocaine changes may outlive it. While the app runs it keeps a lease ($SUPPORT/recovery.json) saying
// what it has changed that must be undone if it disappears: sleep turned off (the engine's sleep claim), the system HUD
// frozen, screens dimmed, a wake scheduled. Each field is written BEFORE the change and cleared AFTER undoing it.
// A watchdog (`cocaine watch`, a zsh process in its own session, not named Cocaine) reads a pipe only the app writes to:
// EOF means the app is gone (quit, crash, kill -9), and it then runs `Cocaine --recover-after <pid>`, which undoes what
// the lease lists. Quitting normally undoes everything itself. An update hands the session over to the new version.
//
// Files (all 0600 in a 0700 folder): recovery.json + recovery.lock (lease), instance.lock (one app at a time); the engine
// keeps sleep-claim + state.lock. COCAINE_SUPPORT, COCAINE_PMSET, COCAINE_SUDO, COCAINE_HUD_NAME, COCAINE_FAKE_BRIGHTNESS
// point everything at stand-ins for --recovery-test; they grant nothing (the sudo rule allows only the real pmset).

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
    static var enginePath: String { Bundle.main.path(forResource: "cocaine", ofType: nil) ?? "/nonexistent/cocaine" }

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
    /// Only stopped ones: a running helper is fine as it is.
    @discardableResult
    static func thawHUD() -> Int {
        var n = 0
        for p in processes(named: hudName) where p.stopped { if kill(p.pid, SIGKILL) == 0 { n += 1 } }
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

    static func wakeString(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yy HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    static func cancelWake(_ t: Double) {
        let sudo = env["COCAINE_SUDO"] ?? "/usr/bin/sudo", pmset = env["COCAINE_PMSET"] ?? "/usr/bin/pmset"
        _ = runQuiet(sudo, ["-n", pmset, "schedule", "cancel", "wake", wakeString(t), "cocaine"])
    }

    /// The engine's `release`: 0 done, 2 not authorized, 4 pmset unreadable (the claim is kept).
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
        if u.hud { thawHUD(); l.hudFrozen = false; writeLease(l) }
        if u.dim { restoreDims(l.dim); l.dim = []; writeLease(l) }
        if u.wake, let w = l.wake { cancelWake(w); l.wake = nil; writeLease(l) }
    }

    // MARK: Single instance

    private static var instanceFD: Int32 = -1

    /// One Cocaine at a time: two would each freeze the HUD, dim and fight over the switch. Holds instance.lock for the
    /// app's life (the kernel drops it on any exit). Another instance may be quitting (an update): wait up to `wait` s.
    /// `runningApps` also waits for an older Cocaine (no lock) launched before us.
    static func claimSingleInstance(wait: Double = 10, runningApps: Bool = true) -> Bool {
        ensureDirectory()
        let deadline = Date().addingTimeInterval(wait)
        let fd = open(directory + "/instance.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd >= 0 {
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if Date() >= deadline { close(fd); return false }
                usleep(100_000)
            }
            instanceFD = fd
        }
        guard runningApps, let id = Bundle.main.bundleIdentifier else { return true }
        let me = NSRunningApplication.current
        func older() -> Bool {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { a in
                guard a.processIdentifier != me.processIdentifier, !a.isTerminated, a.activationPolicy != .prohibited else { return false }
                guard let theirs = a.launchDate, let mine = me.launchDate else { return a.processIdentifier < me.processIdentifier }
                return theirs < mine || (theirs == mine && a.processIdentifier < me.processIdentifier)
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
    private var heartbeat: Timer?

    /// At launch (after claimSingleInstance). Recovers what a dead session left, adopting its sleep; then takes over the
    /// lease and starts the watchdog. Returns true when it adopted a previous session's sleep.
    @discardableResult
    func start(ownsSleep: Bool) -> Bool {
        guard !active else { return false }
        let me = getpid()
        var adopted = false
        Recovery.locked {
            if var stale = Recovery.readLease() {
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
        spawnWatchdog()
        let every = Double(Recovery.env["COCAINE_HEARTBEAT"] ?? "") ?? 2
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.beat() }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
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

    func noteHUD(_ frozen: Bool) { if lease?.hudFrozen != frozen { mutate { $0.hudFrozen = frozen } } }
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

    /// At quit, after the HUD, dimming and wake have been undone (and noted). Releases sleep, or keeps it for an update.
    func end() {
        guard active, let mine = lease else { return }
        active = false
        heartbeat?.invalidate(); heartbeat = nil
        Recovery.locked {
            var l = Recovery.readLease().flatMap { $0.owner == mine.owner ? $0 : nil } ?? mine
            switch Recovery.quitPlan(lease: l, now: Date().timeIntervalSince1970) {
            case .keepForHandover:
                l.hudFrozen = false; l.dim = []; l.wake = nil
                Recovery.writeLease(l)
            case .release:
                if Recovery.releaseSleep() == 4 { Recovery.writeLease(l) }   // pmset unreadable: the watchdog tries again
                else { Recovery.removeLease() }
            case .drop:
                Recovery.removeLease()
            }
        }
        // The pipe closes when we exit; the watchdog then finds nothing (or the hand-over) and ends.
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

    /// Tells the watchdog the app is alive (and not hung); starts a new one if it has gone.
    private func beat() {
        guard active else { return }
        var gone = writeFD < 0 || watchdogPID == 0
        if !gone {
            var b: UInt8 = 104
            if write(writeFD, &b, 1) < 0 && errno == EPIPE { gone = true }
            var st: Int32 = 0
            if waitpid(watchdogPID, &st, WNOHANG) == watchdogPID { gone = true }
        }
        if gone && Date().timeIntervalSince(lastSpawn) > 10 {
            if writeFD >= 0 { close(writeFD); writeFD = -1 }
            spawnWatchdog()
        }
    }
}

/// Called by the in-app updater right before it quits the app to install a new version: the new version adopts the
/// session (sleep stays on, no off/on blip); if it never starts, the watchdog releases sleep after
/// `Recovery.handoverSeconds`. The HUD, dimming and wake are still undone at quit as usual.
@discardableResult
func prepareForUpdateHandover() -> Bool { RecoverySession.shared.prepareForUpdateHandover() }

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
        default:
            return nil
        }
    }

    /// The watchdog, once app `pid` is gone. 0 done (or nothing to do), 75 try again later (hand-over pending, or pmset
    /// unreadable).
    static func recoverAfter(_ pid: Int32) -> Int32 {
        Recovery.locked { () -> Int32 in
            guard var l = Recovery.readLease() else { return 0 }
            switch Recovery.afterExit(lease: l, pid: pid, ownerAlive: Recovery.ownerAlive(l), now: Date().timeIntervalSince1970) {
            case .nothing: return 0
            case .wait: return 75
            case .recover(let u, let releaseSleep):
                Recovery.perform(u, on: &l)
                if releaseSleep, Recovery.releaseSleep() == 4 { return 75 }
                Recovery.removeLease()
                return 0
            }
        }
    }

    /// The app is alive but has stopped answering: give the system HUD back (it freezes it again if it recovers).
    static func recoverHUD(_ pid: Int32) -> Int32 {
        Recovery.locked {
            if let l = Recovery.readLease(), l.owner == pid, l.hudFrozen { Recovery.thawHUD() }
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

    /// `brew uninstall`, after the app has been quit and before the sudo rule goes: nothing of Cocaine may stay behind.
    static func uninstallCleanup() -> Int32 {
        let literal = Recovery.enginePath.replacingOccurrences(of: "([\\[\\]\\\\.^$*+?(){}|])", with: "\\\\$1", options: .regularExpression)
        Recovery.runQuiet("/usr/bin/pkill", ["-KILL", "-U", String(getuid()), "-xf", "/bin/zsh \(literal) watch [0-9]+ .*"])
        Recovery.locked {
            if var l = Recovery.readLease(), !Recovery.ownerAlive(l) {
                Recovery.perform(Recovery.Undo(hud: false, dim: true, wake: true), on: &l)
            }
            Recovery.thawHUD()                                   // nothing else freezes it: any frozen one is a leftover
            _ = Recovery.releaseSleep()                          // back to the state before Cocaine; ends the display hold
            Recovery.removeLease()
        }
        for f in ["recovery.lock", "sleep-claim", "state.lock", "hold.lock", "instance.lock"] { unlink(Recovery.directory + "/" + f) }
        return 0
    }
}
