// The updater the panel shows: checks GitHub at most once a day (or when asked), verifies the signed manifest before even
// saying a version is available, downloads and installs only when the user presses Install, and tells the user plainly
// when this copy can't update itself (Homebrew, ad hoc build, no key, read-only location).

import AppKit
import Combine
import CryptoKit
import Foundation

final class Updater: ObservableObject {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(Double)
        case installing
        case failed(String, retry: Bool)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var lastCheck: Date? = AppDefaults.store.object(forKey: "updateLastCheck") as? Date
    @Published var autoCheck: Bool = AppDefaults.store.object(forKey: "updateAutoCheck") as? Bool ?? true {
        didSet { AppDefaults.store.set(autoCheck, forKey: "updateAutoCheck") }
    }
    @Published private(set) var eligibility = UpdateEligibility.ok

    private var pending: (release: ReleaseInfo, manifest: UpdateManifest)?
    private var download: ResumableDownload?
    private var timer: Timer?
    private var healthObserver: NSObjectProtocol?
    private var lastAction: () -> Void = {}
    /// This copy's designated requirement, to compare with a format-2 manifest's before offering an install.
    private lazy var runningRequirement: String? = SigningTier.facts(of: Bundle.main.bundleURL).designatedRequirement

    /// COCAINE_UPDATE_PREVIEW=available|downloading|failed|homebrew shows that state, for `--render-panel` screenshots only.
    private init() {
        switch ProcessInfo.processInfo.environment["COCAINE_UPDATE_PREVIEW"] {
        case "available": phase = .available("2.10.0")
        case "homebrew": phase = .available("2.10.0"); eligibility = .homebrew
        case "downloading": phase = .downloading(0.42)
        case "failed": phase = .failed(updatesText("The new version failed the authenticity check. Nothing was installed."), retry: false)
        default: break
        }
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    var publicKey: Curve25519.Signing.PublicKey? { UpdateVerifier.publicKey(base64: UpdateKey.publicKeyBase64) }

    /// At launch: right after an in-app update, proves this version runs (UpdateHealth) or says the update was undone; clears
    /// leftovers of a finished or interrupted update, then checks when due (and hourly whether it is).
    func start() {
        let cleanup = { DispatchQueue.global(qos: .utility).async { Installer.cleanupLeftovers(near: Bundle.main.bundleURL) } }
        switch UpdateHealth.launch(currentBuild: currentBuild, pending: UpdateHealth.read(UpdateHealth.pendingFile), mark: UpdateHealth.read(UpdateHealth.markFile)) {
        case .proveHealth:
            let build = currentBuild
            var done = false
            let prove = { if !done { done = true; UpdateHealth.writeMark(build: build) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + UpdateHealth.delay) { prove(); DispatchQueue.main.asyncAfter(deadline: .now() + 15) { cleanup() } }
            healthObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in prove() }
        case .rolledBack:
            UpdateHealth.clear()
            phase = .failed(updatesText("The new version didn't start, so the previous one was put back."), retry: false)
            cleanup()
        case .normal:
            UpdateHealth.clear()
            cleanup()
        }
        eligibility = UpdateEligibility.of(bundle: Bundle.main.bundleURL, tier: SigningTier.current, hasKey: publicKey != nil)
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard phase == .idle || phase == .upToDate, UpdateSchedule.due(enabled: autoCheck, lastCheck: lastCheck, now: Date()) else { return }
        check(automatic: true)
    }

    /// An automatic check that can't reach GitHub stays quiet (no warning every day you're offline).
    func check(automatic: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch phase { case .checking, .downloading, .installing: return; default: break }
        lastAction = { [weak self] in self?.check() }
        phase = .checking
        lastCheck = Date(); AppDefaults.store.set(lastCheck, forKey: "updateLastCheck")
        SmallFetch.get(UpdateSource.latestAPI, maxBytes: 1_000_000, policy: .github, accept: "application/vnd.github+json") { r in
            switch r {
            case .failure(let e): DispatchQueue.main.async { self.failed(e, quiet: automatic) }
            case .success(let data):
                switch UpdateSource.parse(data) {
                case .failure(let e): DispatchQueue.main.async { self.rejected(e, quiet: automatic) }
                case .success(let rel):
                    guard let cur = SemVer(self.currentVersion), rel.version > cur else {
                        DispatchQueue.main.async { self.phase = .upToDate }; return
                    }
                    self.fetchManifest(rel, automatic: automatic)
                }
            }
        }
    }

    private func fetchManifest(_ rel: ReleaseInfo, automatic: Bool) {
        SmallFetch.get(rel.manifest.url, maxBytes: UpdateManifest.maxManifestSize, policy: .github) { r in
            DispatchQueue.main.async {
                switch r {
                case .failure(let e): self.failed(e, quiet: automatic)
                case .success(let data):
                    guard let m = UpdateManifest.decode(data) else { return self.rejected(.malformed("manifest"), quiet: automatic) }
                    if self.publicKey == nil {                      // can't verify: say what exists, never install it
                        self.pending = nil; self.phase = .available(rel.version.description); return
                    }
                    switch UpdateVerifier.check(m, key: self.publicKey, currentVersion: self.currentVersion,
                                                currentBuild: self.currentBuild, release: rel) {
                    case .success:
                        if !UpdateEligibility.signerMatches(release: m.requirement, running: self.runningRequirement) {
                            self.pending = nil; self.eligibility = .otherSigner; self.phase = .available(m.version); return
                        }
                        self.pending = (rel, m); self.phase = .available(m.version)
                    case .failure(.notNewer): self.phase = .upToDate          // an older release replayed: nothing to offer
                    case .failure(.staleBuild(let why)):                      // a release mistake: never "up to date"
                        log.error("update: \(why, privacy: .public)")
                        self.rejected(.staleBuild(why), quiet: false)
                    case .failure(let e): self.rejected(e, quiet: false)       // a bad signature is always shown
                    }
                }
            }
        }
    }

    /// Install (or, for copies that can't update themselves, the right alternative).
    func install() {
        dispatchPrecondition(condition: .onQueue(.main))
        if eligibility != .otherSigner {
            eligibility = UpdateEligibility.of(bundle: Bundle.main.bundleURL, tier: SigningTier.current, hasKey: publicKey != nil)
        }
        guard eligibility == .ok, let p = pending else { NSWorkspace.shared.open(UpdateSource.releasesPage); return }
        let rel = p.release, m = p.manifest
        lastAction = { [weak self] in self?.install() }
        phase = .downloading(0)
        let d = ResumableDownload(.init(url: rel.dmg.url, expectedSize: m.size, sha256: m.sha256))
        d.progress = { done, total in
            DispatchQueue.main.async { if case .downloading = self.phase { self.phase = .downloading(Double(done) / Double(max(total, 1))) } }
        }
        download = d
        d.start { r in
            DispatchQueue.main.async {
                self.download = nil
                switch r {
                case .failure(.cancelled): self.phase = .available(m.version)
                case .failure(let e): self.failed(e, quiet: false)
                case .success(let dmg): self.installDownloaded(dmg, m)
                }
            }
        }
    }

    func cancel() { download?.cancel() }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    func retry() { lastAction() }

    private func installDownloaded(_ dmg: URL, _ m: UpdateManifest) {
        guard let req = CodeIdentity.runningRequirement() else { return failedText(updatesText("This copy's signature can't be read.")) }
        phase = .installing
        let installed = Bundle.main.bundleURL
        RecoverySession.shared.expectingReplacement = true          // our own swap: not "the bundle was replaced behind our back"
        DispatchQueue.global(qos: .userInitiated).async {
            // Hashed again right before mounting: the file in Caches may have changed since the download was checked.
            let rehash = UpdateFiles.sha256(of: dmg) == m.sha256
            let staged: Result<Installer.Staged, InstallError> = rehash ? Installer.stage(dmg: dmg, manifest: m, installed: installed, requirement: req)
                                                                       : .failure(.badImage("the DMG changed after it was verified"))
            let result: Result<URL, InstallError> = staged.flatMap { Installer.install($0, at: installed, manifest: m, requirement: req) }
            if case .success = result { runTool(Self.lsregister, ["-f", installed.path], timeout: 10) }   // Launch Services sees the new version
            DispatchQueue.main.async { () -> Void in
                if !rehash { try? FileManager.default.removeItem(at: dmg); self.failed(.hashMismatch, quiet: false); RecoverySession.shared.expectingReplacement = false; return }
                self.finishInstall(result, dmg: dmg, installed: installed, build: m.build)
            }
        }
    }

    private func finishInstall(_ result: Result<URL, InstallError>, dmg: URL, installed: URL, build: Int) {
        switch result {
        case .failure(let e):
            RecoverySession.shared.expectingReplacement = false
            failedInstall(e)
        case .success(let backup):
            try? FileManager.default.removeItem(at: dmg)
            prepareForUpdateHandover()
            UpdateHealth.expect(build: build)
            let relauncher = Installer.launchRelauncher(pid: getpid(), app: installed, backup: backup, build: build)
            if relauncher == nil {
                RecoverySession.shared.cancelUpdateHandover()        // no new version starts by itself: quitting releases sleep
                UpdateHealth.clear()
                failedText(updatesText("Installed. Quit and reopen Cocaine to start the new version."))
                return
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: Messages

    private func failed(_ e: DownloadFailure, quiet: Bool) {
        if quiet, e == .offline || { if case .network = e { return true }; return false }() { phase = .idle; return }
        switch e {
        case .offline: phase = .failed(updatesText("You're offline."), retry: true)
        case .diskFull: phase = .failed(updatesText("Not enough disk space for the update."), retry: true)
        case .hashMismatch, .tooLarge, .sizeMismatch:
            phase = .failed(updatesText("The download didn't match the signed release and was deleted."), retry: true)
        case .refusedURL: phase = .failed(updatesText("Refused a download from outside GitHub."), retry: false)
        default: phase = .failed(updatesText("Couldn't reach GitHub. Try again later."), retry: true)
        }
    }

    private func rejected(_ e: UpdateRejection, quiet: Bool) {
        switch e {
        case .badSignature, .mismatch: phase = .failed(updatesText("The new version failed the authenticity check. Nothing was installed."), retry: false)
        default:
            if quiet { phase = .idle; return }
            phase = .failed(updatesText("The release on GitHub isn't usable for an update."), retry: false)
        }
    }

    private func failedInstall(_ e: InstallError) {
        switch e {
        case .signature, .wrongApp: failedText(updatesText("The new version failed the authenticity check. Nothing was installed."), retry: false)
        case .notWritable: failedText(updatesText("Cocaine can't write to its folder. Download the update from GitHub."), retry: false)
        case .swap(let m) where e.isCritical: failedText(m, retry: false)
        default: failedText(updatesText("The update couldn't be installed. Nothing was changed."))
        }
    }

    private func failedText(_ t: String, retry: Bool = true) { phase = .failed(t, retry: retry) }

    /// The row's status line.
    var statusText: String {
        switch phase {
        case .idle:
            return lastCheck.map { String(format: updatesText("Last checked %@"), Self.relative($0)) } ?? updatesText("Not checked yet")
        case .checking: return updatesText("Checking…")
        case .upToDate: return updatesText("Cocaine is up to date")
        case .available(let v):
            switch eligibility {
            case .ok: return String(format: updatesText("Version %@ is available"), v)
            case .homebrew: return String(format: updatesText("Version %@: update with Homebrew (brew upgrade --cask cocaine)"), v)
            case .noKey: return String(format: updatesText("Version %@: this build can't verify updates; download it from GitHub"), v)
            case .unsignedBuild: return String(format: updatesText("Version %@: this build is signed ad hoc; download it from GitHub"), v)
            case .notInstalled: return String(format: updatesText("Version %@: move Cocaine to Applications first"), v)
            case .notWritable: return String(format: updatesText("Version %@: Cocaine's folder isn't writable; download it from GitHub"), v)
            case .otherSigner: return String(format: updatesText("Version %@ is signed with another certificate; download it from GitHub"), v)
            }
        case .downloading(let f): return String(format: updatesText("Downloading… %d%%"), Int(f * 100))
        case .installing: return updatesText("Verifying and installing…")
        case .failed(let t, _): return t
        }
    }

    private static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = appLocale()                       // the app's language, not the Mac's ("8 h fa" in an English panel)
        return f.localizedString(for: d, relativeTo: Date())
    }

    /// Copies the Homebrew command (the panel's button for cask installs).
    func copyBrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Homebrew.upgradeCommand, forType: .string)
    }
}
