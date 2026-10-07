// Cloud sharing's controller: fills in CloudShareHook at launch (the shelf's "Share link…"), asks before an upload (every time
// for a provider set so — the default — and before a command's first run), runs the upload as the shelf's job (progress,
// Cancel), keeps the history, shows the result under the shelf (Copy link, Open, Revoke), puts links on the clipboard marked
// so no clipboard history keeps them, tests a connection (a tiny file uploaded, its link checked, deleted) and takes links back.
// Every upload starts from a click: nothing here uploads by itself (not from watched folders, instant actions or links).

import AppKit
import Foundation

/// Links on the clipboard, kept out of every clipboard history: nspasteboard.org's "concealed" marker (other clipboard apps
/// skip it too) and Cocaine's own marker (its history skips its own writes).
enum CloudClipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    @discardableResult
    static func write(_ links: [URL], to pb: NSPasteboard) -> Bool {
        guard !links.isEmpty else { return false }
        pb.clearContents()
        let it = NSPasteboardItem()
        it.setString(links.map(\.absoluteString).joined(separator: "\n"), forType: .string)
        it.setData(Data(), forType: NSPasteboard.PasteboardType(ClipRules.ownType))
        it.setData(Data(), forType: concealed)
        return pb.writeObjects([it])
    }
}

final class CloudShareCenter: ObservableObject {
    static let shared = CloudShareCenter.make()

    let store: ShareStore
    let history: ShareHistory
    /// The upload just finished (the toast under the shelf), for a few seconds.
    @Published private(set) var recent: ShareRecord?
    /// The provider whose connection is being tested.
    @Published private(set) var testing: String?
    var http: () -> ShareHTTP = { ShareHTTP() }
    var run: ((String, [String], [String: String], TimeInterval, CancelToken) -> ShelfProc.Result)?
    var pasteboard: () -> NSPasteboard = { .general }
    var now: () -> Date = Date.init
    private var recentWork: DispatchWorkItem?

    init(store: ShareStore, history: ShareHistory) { self.store = store; self.history = history }

    /// The real files and the Keychain; memory only for tests and renders.
    static func make() -> CloudShareCenter {
        if AppDefaults.isolated {
            return CloudShareCenter(store: ShareStore(file: nil, secrets: MemorySecretStore()), history: ShareHistory(file: nil))
        }
        let dir = ShareStore.folder
        return CloudShareCenter(store: ShareStore(file: dir.appendingPathComponent("providers.json"), secrets: KeychainSecretStore()),
                                history: ShareHistory(file: dir.appendingPathComponent("history.json")))
    }

    /// Fills in the shelf's hook (AppDelegate, at launch).
    func install() {
        CloudShareHook.providers = { [weak self] in self?.store.usable.map { (id: $0.id, title: $0.title) } ?? [] }
        CloudShareHook.prepare = { [weak self] files, id, start in self?.prepare(files, provider: id, surface: .island, start: start) }
        CloudShareHook.deliver = { links, pb in CloudClipboard.write(links, to: pb) }
        CloudShareHook.upload = { [weak self] files, id, completion in
            guard let self else { return }
            self.prepare(files, provider: id, surface: .island) { _, work in
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = Result { try work(CancelToken(), { _ in }) }
                    DispatchQueue.main.async { completion(r) }
                }
            }
        }
    }

    func secrets(_ id: String) -> [String: String] { (try? store.secrets.load(id)) ?? [:] }

    func context(_ id: String, cancel: CancelToken, progress: @escaping (Double) -> Void) -> ShareContext {
        var c = ShareContext(cancel: cancel, progress: progress, http: http(), secrets: secrets(id), now: now)
        if let run { c.run = run }
        return c
    }

    // MARK: uploading

    /// What is said before an upload: where the files go and how long the link works.
    func confirmation(_ c: ShareProviderConfig, count: Int) -> DialogSpec {
        let what = count == 1 ? L("1 item") : String(format: L("%d items (zipped)"), count)
        var lines = [String(format: L("%1$@ go to %2$@."), what, c.host.isEmpty ? c.title : c.host)]
        lines.append(Self.lifetime(c))
        return DialogSpec(icon: "icloud.and.arrow.up", title: String(format: L("Upload to %@?"), c.title), message: lines.joined(separator: " "),
                          buttons: [DialogButton(id: "upload", title: L("Upload")), Dialogs.cancel], safeDefault: true, surface: .island)
    }

    static func lifetime(_ c: ShareProviderConfig) -> String {
        switch c.kind {
        case .s3:
            if !c["publicBase"].isEmpty { return L("Anyone with the link can open it until you revoke it.") }
            let h = S3Provider(config: c).expiry / 3600
            return String(format: L("Anyone with the link can open it for %@."), h >= 24 ? String(format: L("%d days"), h / 24) : String(format: L("%d hours"), max(1, h)))
        case .nextcloud:
            let d = WebDAVProvider(config: c).expiryDays
            return d > 0 ? String(format: L("Anyone with the link can open it for %@."), String(format: L("%d days"), d)) : L("Anyone with the link can open it until you revoke it.")
        case .webdav, .sftp: return L("Anyone with the link can open it until you revoke it.")
        case .uploader: return L("The service decides how long the link works.")
        }
    }

    func approval(_ c: ShareProviderConfig, surface: DialogSurface) -> DialogSpec {
        DialogSpec(icon: "exclamationmark.shield", title: String(format: L("Run “%@”?"), c.title),
                   message: String(format: L("Cocaine runs this command with your permissions to upload: %@. It asks again if the command changes."), String(c["template"].prefix(400))),
                   buttons: [DialogButton(id: "run", title: L("Run")), Dialogs.cancel], safeDefault: true, surface: surface)
    }

    func prepare(_ files: [URL], provider id: String, surface: DialogSurface,
                 start: @escaping (String, @escaping (CancelToken, @escaping (Double) -> Void) throws -> [URL]) -> Void) {
        guard store.settings.on else { DialogCenter.shared.present(Dialogs.message(L("Cloud sharing is off"), nil, surface: surface)) { _ in }; return }
        guard let c = store.provider(id), c.enabled else {
            DialogCenter.shared.present(Dialogs.message(ShareError.noProvider.localizedDescription, nil, surface: surface)) { _ in }; return
        }
        let go: (ShareProviderConfig) -> Void = { [weak self] c in
            guard let self else { return }
            start(String(format: L("Uploading to %@…"), c.title)) { [weak self] t, p in
                guard let self else { throw ShareError.cancelled }
                let done = try ShareEngine.upload(files, with: c, ctx: self.context(c.id, cancel: t, progress: p), on: self.store.settings.on)
                DispatchQueue.main.async { self.finished(done) }
                guard let u = URL(string: done.record.link) else { throw ShareError.badResponse(L("Couldn't make the link")) }
                return [u]
            }
        }
        if c.kind == .uploader && ShareUploader.needsApproval(c) {
            DialogCenter.shared.present(approval(c, surface: surface)) { [weak self] r in
                guard r.buttonID == "run", let self else { return }
                let print = ShareUploader.fingerprint(c)
                self.store.updateProvider(c.id) { $0.approved = print }
                var ok = c; ok.approved = print
                go(ok)
            }
            return
        }
        guard c.confirmEach else { go(c); return }
        var spec = confirmation(c, count: files.count)
        spec.surface = surface
        DialogCenter.shared.present(spec) { r in if r.buttonID == "upload" { go(c) } }
    }

    private func finished(_ done: ShareEngine.Done) {
        history.add(done.record)
        if let l = done.learned { store.updateProvider(done.record.provider) { c in for (k, v) in l { c.settings[k] = v } } }
        show(done.record)
    }

    func show(_ r: ShareRecord) {
        recentWork?.cancel()
        Motion.with(.notice) { recent = r }
        let w = DispatchWorkItem { [weak self] in Motion.with(.notice) { self?.recent = nil } }
        recentWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: w)
    }

    func dismiss() { recentWork?.cancel(); Motion.with(.notice) { recent = nil } }

    // MARK: the links afterwards

    func copy(_ r: ShareRecord) {
        guard let u = URL(string: r.link) else { return }
        CloudClipboard.write([u], to: pasteboard())
        Haptic.tap(.generic)
        A11y.announce(L("Link copied"))
    }

    func open(_ r: ShareRecord) {
        guard let u = URL(string: r.link), ShareRules.allowed(u) else { return }
        NSWorkspace.shared.open(u)
    }

    /// Takes a link back after asking: the file (and the share) is deleted on the service.
    func revoke(_ r: ShareRecord, surface: DialogSurface) {
        guard let c = store.provider(r.provider) else {
            DialogCenter.shared.present(Dialogs.message(ShareError.noProvider.localizedDescription, L("You can still remove the entry from the history."), surface: surface)) { _ in }
            return
        }
        let spec = DialogSpec(icon: "link.badge.plus", title: L("Revoke the link?"),
                              message: String(format: L("“%1$@” is deleted from %2$@ and the link stops working."), r.name, c.title), critical: true,
                              buttons: [DialogButton(id: "revoke", title: L("Revoke"), role: .destructive), Dialogs.cancel], surface: surface)
        DialogCenter.shared.present(spec) { [weak self] res in
            guard res.buttonID == "revoke", let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try ShareEngine.revoke(r, with: c, ctx: self.context(c.id, cancel: CancelToken(), progress: { _ in })) }
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.history.markRevoked(r.id)
                        if self.recent?.id == r.id { self.dismiss() }
                        Haptic.tap(.generic)
                        A11y.announce(L("Link revoked"))
                    case .failure(let e):
                        DialogCenter.shared.present(Dialogs.message(L("Couldn't revoke the link"), ShareError.from(e).localizedDescription, surface: surface)) { _ in }
                    }
                }
            }
        }
    }

    // MARK: testing a connection

    /// Uploads a tiny generated file, checks the link (a presigned S3 link is fetched), deletes it; says how it went.
    func test(_ id: String, surface: DialogSurface = .panel, done: ((Result<String, ShareError>) -> Void)? = nil) {
        guard var c = store.provider(id), testing == nil else { return }
        c.enabled = true
        c.title = c.title.isEmpty ? c.kind.title : c.title
        let report: (Result<String, ShareError>) -> Void = { r in
            if let done { done(r); return }
            switch r {
            case .success(let s): DialogCenter.shared.present(Dialogs.message(String(format: L("%@ works"), c.title), s, error: false, surface: surface)) { _ in }
            case .failure(let e): DialogCenter.shared.present(Dialogs.message(String(format: L("%@ doesn't work yet"), c.title), e.localizedDescription, surface: surface)) { _ in }
            }
        }
        let go: (ShareProviderConfig) -> Void = { [weak self] c in
            guard let self else { return }
            self.testing = c.id
            DispatchQueue.global(qos: .userInitiated).async {
                let r = self.runTest(c)
                DispatchQueue.main.async { self.testing = nil; report(r) }
            }
        }
        if c.kind == .uploader && ShareUploader.needsApproval(c) {
            if done != nil { report(.failure(.notApproved)); return }
            DialogCenter.shared.present(approval(c, surface: surface)) { [weak self] r in
                guard r.buttonID == "run", let self else { return }
                let print = ShareUploader.fingerprint(c)
                self.store.updateProvider(c.id) { $0.approved = print }
                c.approved = print
                go(c)
            }
            return
        }
        go(c)
    }

    /// The test itself (blocking): what worked, or the first thing that didn't.
    func runTest(_ c: ShareProviderConfig) -> Result<String, ShareError> {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cocaine-share-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let f = try ShareEngine.testFile(in: dir)
            let ctx = context(c.id, cancel: CancelToken(), progress: { _ in })
            let done = try ShareEngine.upload([f], with: c, ctx: ctx)
            if let l = done.learned { DispatchQueue.main.async { self.store.updateProvider(c.id) { p in for (k, v) in l { p.settings[k] = v } } } }
            var steps = [L("A test file was uploaded.")]
            if c.kind == .s3 && c["publicBase"].isEmpty, let u = URL(string: done.record.link) {
                let r = try ctx.http.send(URLRequest(url: u), cancel: ctx.cancel)
                guard r.status == 200 else { throw ShareError.badResponse(String(format: L("The file went up, but its link doesn't open (%d)"), r.status)) }
                steps.append(L("Its link opens."))
            }
            if c.kind.canRevoke {
                try ShareEngine.revoke(done.record, with: c, ctx: ctx)
                steps.append(L("It was deleted again."))
            } else {
                steps.append(L("This service can't delete it: it expires on its own."))
            }
            return .success(steps.joined(separator: " "))
        } catch {
            return .failure(ShareError.from(error))
        }
    }
}
