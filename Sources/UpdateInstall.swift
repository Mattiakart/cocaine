// Installing a verified DMG: mount it read-only in a private folder, copy the app next to the installed one (same volume),
// check the copy (bundle id, the signed version and build, a valid signature that satisfies the RUNNING app's designated
// requirement), then swap the two in one atomic rename. The previous app is kept as the rollback copy until the new one has
// started. Any failure before or during the swap leaves the installed app exactly as it was.

import Foundation
import Security

enum InstallError: Error, Equatable {
    case notWritable(String)
    case mount(String)
    case badImage(String)        // the DMG doesn't hold one plain Cocaine.app
    case copy(String)
    case wrongApp(String)        // id, version or build differ from the signed manifest
    case signature(String)       // invalid, or not signed by the same identity as the running app
    case swap(String)            // nothing was changed (unless the text says CRITICAL)

    var isCritical: Bool { if case .swap(let m) = self { return m.contains("CRITICAL") || m.contains("swapping back failed") }; return false }
}

enum CodeIdentity {
    /// The designated requirement of the code that is running now (not of the file on disk, which may have been replaced).
    static func runningRequirement() -> SecRequirement? {
        var me: SecCode?, st: SecStaticCode?, req: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &st) == errSecSuccess, let st,
              SecCodeCopyDesignatedRequirement(st, [], &req) == errSecSuccess else { return nil }
        return req
    }

    static func requirement(of bundle: URL) -> SecRequirement? {
        var st: SecStaticCode?, req: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &st) == errSecSuccess, let st,
              SecCodeCopyDesignatedRequirement(st, [], &req) == errSecSuccess else { return nil }
        return req
    }

    /// Valid (strict, every architecture, nested code) and satisfying `requirement`.
    static func check(_ bundle: URL, satisfies requirement: SecRequirement) -> Result<Void, InstallError> {
        var st: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &st) == errSecSuccess, let st else { return .failure(.signature("unreadable")) }
        var err: Unmanaged<CFError>?
        let s = SecStaticCodeCheckValidityWithErrors(st, SigningTier.strictFlags, requirement, &err)
        if s == errSecSuccess { return .success(()) }
        let why = (err?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "OSStatus \(s)"
        return .failure(.signature(s == errSecCSReqFailed ? "not signed by the same identity as this app" : why))
    }
}

/// Runs a tool with a deadline; returns its status (or -1 when it couldn't start, -2 when it was stopped at the deadline).
@discardableResult
func runTool(_ path: String, _ args: [String], timeout: TimeInterval = 120, output: UnsafeMutablePointer<String>? = nil) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = output == nil ? FileHandle.nullDevice : pipe
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    let done = DispatchSemaphore(value: 0)
    var data = Data()
    if output != nil { DispatchQueue.global().async { data = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() } } else { done.signal() }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(20_000) }
    if p.isRunning {                                         // past the deadline: TERM, then KILL, never an endless wait
        p.terminate()
        let killAt = Date().addingTimeInterval(5)
        while p.isRunning && Date() < killAt { usleep(20_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
        return -2
    }
    p.waitUntilExit()
    done.wait()
    output?.pointee = String(decoding: data, as: UTF8.self)
    return p.terminationStatus
}

enum DiskImage {
    /// Read-only, not shown in Finder, no auto-open, at a mount point we own (never a shared /Volumes name). hdiutil still
    /// verifies the image's own checksums (no -noverify): cheap next to the download, and it catches a damaged image.
    static func attach(_ dmg: URL, at mountPoint: URL) -> Result<Void, InstallError> {
        do { try UpdateFiles.makePrivate(mountPoint) } catch { return .failure(.mount(error.localizedDescription)) }
        let s = runTool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, dmg.path])
        return s == 0 ? .success(()) : .failure(.mount("hdiutil attach: \(s)"))
    }

    static func detach(_ mountPoint: URL) {
        if runTool("/usr/bin/hdiutil", ["detach", mountPoint.path], timeout: 30) != 0 {
            runTool("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path], timeout: 30)
        }
        try? FileManager.default.removeItem(at: mountPoint)      // only an empty folder once detached
    }
}

enum Installer {
    static let bundleID = "local.cocaine.toggle"
    static let workPrefix = ".cocaine-update-"

    struct Staged { let app: URL; let work: URL }

    /// Hooks for tests: the swap primitive and the plain rename used when the volume can't swap atomically.
    struct FileOps {
        var swap: (String, String) -> Int32 = { a, b in renamex_np(a, b, UInt32(RENAME_SWAP)) == 0 ? 0 : errno }
        var rename: (String, String) -> Int32 = { a, b in Darwin.rename(a, b) == 0 ? 0 : errno }
    }

    /// Mounts, copies next to `installed`, checks the copy. On failure nothing is left behind.
    static func stage(dmg: URL, manifest: UpdateManifest, installed: URL, requirement: SecRequirement) -> Result<Staged, InstallError> {
        let parent = installed.deletingLastPathComponent()
        guard access(parent.path, W_OK) == 0 else { return .failure(.notWritable(parent.path)) }
        let work = parent.appendingPathComponent(workPrefix + UUID().uuidString)
        do { try UpdateFiles.makePrivate(work) } catch { return .failure(.notWritable(parent.path)) }
        let mount = UpdateFiles.directory.appendingPathComponent("mnt-" + UUID().uuidString)
        if case .failure(let e) = DiskImage.attach(dmg, at: mount) {
            DiskImage.detach(mount)                                  // hdiutil stopped at its deadline may have mounted it already
            try? FileManager.default.removeItem(at: work); return .failure(e)
        }
        defer { DiskImage.detach(mount) }
        let r = copyAndCheck(from: mount.appendingPathComponent("Cocaine.app"), to: work.appendingPathComponent("Cocaine.app"),
                             manifest: manifest, requirement: requirement)
        switch r {
        case .success(let app): return .success(Staged(app: app, work: work))
        case .failure(let e): try? FileManager.default.removeItem(at: work); return .failure(e)
        }
    }

    static func copyAndCheck(from src: URL, to dst: URL, manifest: UpdateManifest, requirement: SecRequirement) -> Result<URL, InstallError> {
        var st = stat()
        guard lstat(src.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return .failure(.badImage("no Cocaine.app folder")) }
        guard runTool("/usr/bin/ditto", [src.path, dst.path], timeout: 300) == 0 else { return .failure(.copy("ditto failed")) }
        if case .failure(let e) = checkApp(dst, manifest: manifest, requirement: requirement) { return .failure(e) }
        return .success(dst)
    }

    /// The app is the one the manifest describes, and signed by the same identity as the running app.
    static func checkApp(_ app: URL, manifest: UpdateManifest, requirement: SecRequirement) -> Result<Void, InstallError> {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        else { return .failure(.wrongApp("no Info.plist")) }
        guard info["CFBundleIdentifier"] as? String == bundleID else { return .failure(.wrongApp("bundle id")) }
        guard info["CFBundleShortVersionString"] as? String == manifest.version else { return .failure(.wrongApp("version")) }
        guard info["CFBundleVersion"] as? String == String(manifest.build) else { return .failure(.wrongApp("build")) }
        return CodeIdentity.check(app, satisfies: requirement)
    }

    /// Puts `staged` where `installed` is and returns where the previous app now is (the rollback copy).
    /// Atomic where the volume supports it (APFS: one renamex_np RENAME_SWAP); otherwise two renames, the first undone if the
    /// second fails, so `installed` always holds a complete app.
    static func swap(installed: URL, staged: URL, ops: FileOps = FileOps()) -> Result<URL, InstallError> {
        let a = installed.path, b = staged.path
        let e = ops.swap(b, a)
        if e == 0 { return .success(staged) }
        guard e == ENOTSUP || e == EINVAL || e == ENOTTY else { return .failure(.swap("swap: \(String(cString: strerror(e)))")) }
        let aside = staged.deletingLastPathComponent().appendingPathComponent("previous-\(UUID().uuidString).app")
        if ops.rename(a, aside.path) != 0 { return .failure(.swap("moving the installed app aside failed")) }
        if ops.rename(b, a) != 0 {
            if ops.rename(aside.path, a) != 0 { return .failure(.swap("CRITICAL: the previous app is at \(aside.path)")) }
            return .failure(.swap("moving the new app into place failed"))
        }
        return .success(aside)
    }

    /// Swap, then check what is now installed; a failed check swaps back. Returns the rollback copy.
    static func install(_ s: Staged, at installed: URL, manifest: UpdateManifest, requirement: SecRequirement,
                        ops: FileOps = FileOps()) -> Result<URL, InstallError> {
        let backup: URL
        switch swap(installed: installed, staged: s.app, ops: ops) {
        case .success(let b): backup = b
        case .failure(let e):
            if !e.isCritical { try? FileManager.default.removeItem(at: s.work) }
            return .failure(e)
        }
        if case .failure(let e) = checkApp(installed, manifest: manifest, requirement: requirement) {
            switch swap(installed: installed, staged: backup, ops: ops) {
            case .success: try? FileManager.default.removeItem(at: s.work); return .failure(e)
            case .failure(let back): return .failure(.swap("check failed (\(e)) and swapping back failed: \(back)"))
            }
        }
        return .success(backup)                                // kept until the new one has started
    }

    /// Leftovers of an update that finished (the running app is fine) or was interrupted: rollback copies, staging folders,
    /// stale mounts. Called at launch.
    static func cleanupLeftovers(near installed: URL) {
        let fm = FileManager.default
        let parent = installed.deletingLastPathComponent()
        for f in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where f.hasPrefix(workPrefix) {
            try? fm.removeItem(at: parent.appendingPathComponent(f))
        }
        let dir = UpdateFiles.directory
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix("mnt-") {
            DiskImage.detach(dir.appendingPathComponent(f))
        }
    }

    /// The helper that starts the new version once this process has quit, and puts the previous version back (and starts
    /// that) if the new one can't be opened. Gives up after 60 s if this process doesn't quit (the update stays installed).
    static let relaunchScript = """
    pid="$1"; app="$2"; backup="$3"; opener="$4"; i=0
    while kill -0 "$pid" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 600 ] && exit 3; sleep 0.1; done
    "$opener" "$app" && exit 0
    if [ -d "$backup" ]; then
      /bin/mv "$app" "$app.failed.$$" && /bin/mv "$backup" "$app" && /bin/rm -rf "$app.failed.$$"
    fi
    "$opener" "$app"
    exit 4
    """

    @discardableResult
    static func launchRelauncher(pid: Int32, app: URL, backup: URL, opener: String = "/usr/bin/open") -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", relaunchScript, "cocaine-relaunch", String(pid), app.path, backup.path, opener]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        return p
    }
}

/// Whether this copy may replace itself, and if not, why (shown to the user: never a silent no-op).
enum UpdateEligibility: Equatable {
    case ok
    case homebrew
    case noKey
    case unsignedBuild(SigningTier)
    case notInstalled            // running from the disk image, a translocated copy or the build folder
    case notWritable(String)

    static func of(bundle: URL, tier: SigningTier, hasKey: Bool, caskrooms: [String] = Homebrew.caskrooms) -> UpdateEligibility {
        if Homebrew.manages(bundle: bundle, caskrooms: caskrooms) { return .homebrew }
        if !hasKey { return .noKey }
        if tier == .adhoc || tier == .unsigned { return .unsignedBuild(tier) }
        let path = bundle.path
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false   // the mounted .dmg
        if path.contains("/AppTranslocation/") || readOnly || !path.hasSuffix(".app") { return .notInstalled }
        let parent = bundle.deletingLastPathComponent().path
        if access(parent, W_OK) != 0 { return .notWritable(parent) }
        return .ok
    }
}
