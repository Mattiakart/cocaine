// The shelf's controller (ShelfCenter): what the island's Shelf module, its sheets, the keys, the drop target and the entry
// points ask for — the group operations on the selection, the custom actions (with their first-run question), watched folders'
// batches, the in-island status line — wired to the store (ShelfStore), the running job (ShelfTasks) and the settings.

import AppKit
import Foundation
import UniformTypeIdentifiers

/// The shelf's group operations, as listed in its menu.
enum ShelfOp: String, CaseIterable, Identifiable {
    case open, openWith, reveal, quickLook, share, airDrop, shareLink, copy, copyPaths, copyNames, copyTo, moveTo, rename, zip, images, ocr, pdf,
         stitchV, stitchH, aiContext, remove, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return L("Open")
        case .openWith: return L("Open With…")
        case .reveal: return L("Show in Finder")
        case .quickLook: return L("Quick Look")
        case .share: return L("Share…")
        case .airDrop: return L("AirDrop")
        case .shareLink: return L("Share link…")
        case .copy: return L("Copy")
        case .copyPaths: return L("Copy Path")
        case .copyNames: return L("Copy Names")
        case .copyTo: return L("Copy to…")
        case .moveTo: return L("Move to…")
        case .rename: return L("Rename…")
        case .zip: return L("Compress (ZIP)")
        case .images: return L("Resize or Convert…")
        case .ocr: return L("Recognize Text")
        case .pdf: return L("Create PDF")
        case .stitchV: return L("Stitch Vertically")
        case .stitchH: return L("Stitch Side by Side")
        case .aiContext: return L("Use as AI Context")
        case .remove: return L("Remove from Shelf")
        case .trash: return L("Move to Trash")
        }
    }

    var symbol: String {
        switch self {
        case .open: return "arrow.up.forward.square"
        case .openWith: return "square.grid.2x2"
        case .reveal: return "folder"
        case .quickLook: return "eye"
        case .share: return "square.and.arrow.up"
        case .airDrop: return "dot.radiowaves.left.and.right"
        case .shareLink: return "link"
        case .copy: return "doc.on.doc"
        case .copyPaths: return "text.alignleft"
        case .copyNames: return "list.bullet"
        case .copyTo: return "plus.rectangle.on.folder"
        case .moveTo: return "folder.badge.plus"
        case .rename: return "pencil"
        case .zip: return "doc.zipper"
        case .images: return "photo.on.rectangle"
        case .ocr: return "text.viewfinder"
        case .pdf: return "doc.richtext"
        case .stitchV: return "rectangle.split.1x2"
        case .stitchH: return "rectangle.split.2x1"
        case .aiContext: return "sparkles"
        case .remove: return "minus.circle"
        case .trash: return "trash"
        }
    }

    var destructive: Bool { self == .trash }

    /// The operations that make sense for these items (in menu order).
    static func available(_ items: [ShelfItem], urlFor: (ShelfItem) -> URL?, cloud: Bool, ai: Bool) -> [ShelfOp] {
        let present = items.filter { !$0.missing }
        let files = present.filter(\.isFileBacked).compactMap(urlFor)
        let realFiles = present.filter { $0.kind == .file }
        let images = files.filter(ImageTools.isImage)
        let ocrable = files.filter { ImageTools.isImage($0) || ImageTools.isPDF($0) }
        let hasLinks = present.contains { $0.kind == .link }
        var out: [ShelfOp] = []
        if !files.isEmpty || hasLinks { out.append(.open) }
        if !files.isEmpty { out += [.openWith, .reveal] }
        if !present.isEmpty { out += [.quickLook, .share] }
        if !files.isEmpty || hasLinks { out.append(.airDrop) }
        if cloud && !files.isEmpty { out.append(.shareLink) }
        if !present.isEmpty { out.append(.copy) }
        if !files.isEmpty { out += [.copyPaths, .copyNames, .copyTo] }
        if !realFiles.isEmpty { out += [.moveTo, .rename] }
        if !files.isEmpty { out.append(.zip) }
        if !images.isEmpty { out.append(.images) }
        if !ocrable.isEmpty { out.append(.ocr) }
        if !images.isEmpty { out.append(.pdf) }
        if images.count >= 2 { out += [.stitchV, .stitchH] }
        if ai && !present.isEmpty { out.append(.aiContext) }
        if !items.isEmpty { out.append(.remove) }
        if !realFiles.isEmpty { out.append(.trash) }
        return out
    }
}

/// The sheet over the island's page (the shelf's own in-app menus and forms).
enum ShelfSheet: Equatable {
    case menu
    case openWith([URL])
    case share
    case links                       // the cloud providers (CloudShareHook)
    case rename
    case images
    case collections
    case move([UUID])                // move the selection to another collection
}

final class ShelfCenter: ObservableObject {
    let store: ShelfStore
    let tasks = ShelfTasks()
    let watch = WatchedFolders()
    let config: ShelfConfigStore
    @Published var sheet: ShelfSheet? { didSet { if sheet != oldValue { sheetChanged(oldValue) } } }
    /// A line under the shelf for a few seconds ("3 files added", "Copied"), with an optional Undo.
    @Published private(set) var status: (icon: String, text: String, undo: Bool)? = nil
    /// Files are dragged over the island with ⌥ held: the instant actions show.
    @Published var instantShown = false
    /// The rename sheet's rule and the image sheet's job (kept between uses).
    @Published var renameRule = RenameRule()
    @Published var imageJob = ImageJob()
    /// The last rename, for Undo.
    private(set) var lastRename: RenameEngine.Done?
    private var statusWork: DispatchWorkItem?

    /// Set by the island: the HUD message (when the island is closed), the keyboard, keeping the island open while a sheet,
    /// Quick Look or a folder panel is up, the columns of the grid (for ↑/↓).
    var notice: (String, String) -> Void = { _, _ in }
    var takeKeyboard: () -> Void = {}
    var hold: (Bool) -> Void = { _ in }
    var columns = 5
    /// The pasteboard ⌘C/⌘V and "Copy" use (tests: a private one).
    var pasteboard: () -> NSPasteboard = { .general }

    init(store: ShelfStore, config: ShelfConfigStore = .shared) {
        self.store = store
        self.config = config
        watch.onBatch = { [weak self] f, urls in self?.landed(f, urls) }
    }

    // MARK: status

    func say(_ icon: String, _ text: String, undo: Bool = false) {
        statusWork?.cancel()
        Motion.with(.notice) { status = (icon, text, undo) }
        A11y.announce(text)
        notice(icon, text)
        let w = DispatchWorkItem { [weak self] in Motion.with(.notice) { self?.status = nil } }
        statusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (undo ? 8 : 3.5), execute: w)
    }

    func fail(_ text: String) { say("exclamationmark.triangle.fill", text) }

    // MARK: the selection

    var selected: [ShelfItem] { store.selectedItems(orAll: true) }
    var selectedURLs: [URL] { store.fileURLs(selected) }

    func ops(for items: [ShelfItem]) -> [ShelfOp] {
        ShelfOp.available(items, urlFor: { [store] in store.url(of: $0) }, cloud: !CloudShareHook.providers().isEmpty && CloudShareHook.upload != nil,
                          ai: AIContextHook.add != nil)
    }

    /// Click on a tile (⇧/⌘ from the event's modifiers).
    func click(_ id: UUID, shift: Bool, command: Bool) {
        var s = store.selection
        s.click(id, order: store.items.map(\.id), shift: shift, command: command)
        Motion.with(.selection) { store.selection = s }
        takeKeyboard()
    }

    func selectAll() { var s = store.selection; s.selectAll(store.items.map(\.id)); Motion.with(.selection) { store.selection = s } }
    func clearSelection() { Motion.with(.selection) { store.selection = ShelfSelection() } }

    // MARK: adding

    func add(_ urls: [URL], to collection: UUID? = nil, from source: String? = nil) {
        guard !urls.isEmpty else { return }
        let r = Motion.with(.appear) { store.add(urls: urls, to: collection) }
        report(added: r.added.count, refused: r.refused, collection: collection)
    }

    func report(added: Int, refused: Int, collection: UUID? = nil) {
        let target = collection.flatMap { store.library.collection($0) } ?? store.current
        let name = target.title
        if refused > 0 && target.items.count < ShelfLimits.itemsPerCollection { fail(L("The shelf is full: remove some items first")) }   // its size
        else if refused > 0 { fail(String(format: L("%1$@ is full (%2$d items at most)"), name, ShelfLimits.itemsPerCollection)) }
        else if added > 0 {
            say("tray.and.arrow.down.fill", added == 1 ? String(format: L("1 item added to %@"), name) : String(format: L("%1$d items added to %2$@"), added, name))
        }
    }

    /// ⌘V or "Add from clipboard": what the pasteboard holds becomes items.
    func paste() {
        let n = Motion.with(.appear) { ShelfPaste.add(pasteboard(), to: store) }
        if n == 0 { fail(L("Nothing on the clipboard to add")) } else { report(added: n, refused: 0) }
    }

    /// A watched folder's batch.
    private func landed(_ f: WatchedFolder, _ urls: [URL]) {
        let target = f.collection.flatMap { store.library.collection($0) != nil ? $0 : nil }
        add(urls, to: target)
    }

    /// Watched folders run while the island is on.
    var watching = false {
        didSet {
            guard watching != oldValue else { return }
            applyWatching()
            // A shelf that couldn't be read at launch was set aside: said once, when the island is there to say it.
            if watching, !noteShown, let note = store.loadNote {
                noteShown = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.fail(note) }
            }
        }
    }
    private var noteShown = false
    func applyWatching() { watch.apply(config.config.watched, running: watching) }

    // MARK: the operations

    func run(_ op: ShelfOp, items given: [ShelfItem]? = nil) {
        let items = given ?? selected
        let urls = store.fileURLs(items)
        sheet = nil
        switch op {
        case .open:
            for u in urls { NSWorkspace.shared.open(u) }
            for l in items where l.kind == .link { if let u = l.text.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) } }
        case .openWith:
            Motion.with(.dialog) { sheet = .openWith(urls) }
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .quickLook:
            quickLook(items)
        case .share:
            Motion.with(.dialog) { sheet = .share }
        case .airDrop:
            airDrop(items)
        case .shareLink:
            Motion.with(.dialog) { sheet = .links }
        case .copy:
            if ShelfPaste.write(items, store: store, to: pasteboard()) { Haptic.tap(.generic); say("doc.on.clipboard.fill", L("Copied")) }
        case .copyPaths:
            let pb = pasteboard(); pb.clearContents(); pb.setString(ShelfFiles.paths(urls), forType: .string)
            say("doc.on.clipboard.fill", urls.count == 1 ? L("Path copied") : String(format: L("%d paths copied"), urls.count))
        case .copyNames:
            copyNames(items)
        case .copyTo, .moveTo:
            chooseFolder(move: op == .moveTo) { [weak self] dir in self?.transfer(items, into: dir, move: op == .moveTo) }
        case .rename:
            Motion.with(.dialog) { sheet = .rename }
        case .zip:
            zip(urls)
        case .images:
            Motion.with(.dialog) { sheet = .images }
        case .ocr:
            recognize(urls.filter { ImageTools.isImage($0) || ImageTools.isPDF($0) })
        case .pdf:
            let imgs = urls.filter(ImageTools.isImage)
            guard let first = imgs.first else { return }
            let out = first.deletingPathExtension().appendingPathExtension("pdf")
            job(L("Creating the PDF…"), produce: { _, _ in [try ImageTools.makePDF(imgs, to: Self.writable(out))] })
        case .stitchV, .stitchH:
            let imgs = urls.filter(ImageTools.isImage)
            guard let first = imgs.first else { return }
            let out = first.deletingLastPathComponent().appendingPathComponent(first.deletingPathExtension().lastPathComponent + "-" + L("stitched") + ".png")
            job(L("Stitching…"), produce: { _, _ in [try ImageTools.stitch(imgs, vertical: op == .stitchV, to: Self.writable(out))] })
        case .aiContext:
            let list = items.filter { !$0.missing }.map { i -> (kind: String, ref: String, title: String) in
                switch i.kind {
                case .file, .image: return ("file", store.url(of: i)?.path ?? i.path, i.name)
                case .link, .text: return ("text", i.text ?? "", i.name)
                }
            }
            AIContextHook.add?(list)
            say("sparkles", String(format: L("%d added as AI context"), list.count))
        case .remove:
            let ids = Set(items.map(\.id))
            Motion.with(.appear) { store.remove(ids) }
            say("minus.circle", ids.count == 1 ? L("Removed from the shelf") : String(format: L("%d removed from the shelf"), ids.count))
        case .trash:
            let files = items.filter { $0.kind == .file && !$0.missing }
            let r = ShelfFiles.trash(files.compactMap { store.url(of: $0) })
            let gone = Set(files.filter { f in r.done.contains { $0.path == f.path } }.map(\.id))
            Motion.with(.appear) { store.remove(gone) }
            if let p = r.problem { fail(p) } else { say("trash", String(format: L("%d moved to the Trash"), gone.count)) }
        }
    }

    /// A folder next to `url` that can be written (else Downloads), with a name that is free.
    static func writable(_ url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = FileManager.default.isWritableFile(atPath: dir.path) ? dir : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return FileNames.unique(base.appendingPathComponent(url.lastPathComponent))
    }

    /// A job whose result is new files: they land in the current collection.
    func job(_ title: String, produce: @escaping (CancelToken, @escaping (Double) -> Void) throws -> [URL]) {
        let target = store.library.current
        let ok = tasks.start(title, work: produce) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let urls):
                let a = Motion.with(.appear) { self.store.add(urls: urls, to: target) }
                Haptic.tap(.generic)
                self.say("checkmark.circle.fill", urls.count == 1 ? String(format: L("Made %@"), urls[0].lastPathComponent) : String(format: L("Made %d files"), urls.count))
                if a.refused > 0 { self.report(added: 0, refused: a.refused, collection: target) }
            case .failure(let e): self.fail(e.localizedDescription)
            }
        }
        if !ok { fail(L("Wait for the job running now to finish")) }
    }

    func zip(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let out = ZipTool.destination(for: urls)
        job(L("Compressing…"), produce: { t, _ in [try ZipTool.zip(urls, to: out, cancel: t)] })
    }

    func images(_ job: ImageJob) {
        sheet = nil
        let items = selected.filter { $0.isFileBacked && !$0.missing }
        let pairs = items.compactMap { i in store.url(of: i).flatMap { ImageTools.isImage($0) ? (i.id, $0) : nil } }
        guard !pairs.isEmpty else { return }
        imageJob = job
        let target = store.library.current
        let ok = tasks.start(L("Processing images…"), work: { t, progress -> [(UUID, URL)] in
            var out: [(UUID, URL)] = []
            for (n, (id, u)) in pairs.enumerated() {
                if t.cancelled { throw ShelfOpsError.cancelled }
                out.append((id, try ImageTools.process(u, job: job)))
                progress(Double(n + 1) / Double(pairs.count))
            }
            return out
        }) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let made):
                if job.replace {
                    for (id, u) in made { self.store.noteMoved(id, to: u) }       // the items now stand for the new files
                } else {
                    Motion.with(.appear) { _ = self.store.add(urls: made.map(\.1), to: target) }
                }
                Haptic.tap(.generic)
                self.say("checkmark.circle.fill", String(format: L("%d images done"), made.count))
            case .failure(let e): self.fail(e.localizedDescription)
            }
        }
        if !ok { fail(L("Wait for the job running now to finish")) }
    }

    func recognize(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let target = store.library.current
        let ok = tasks.start(L("Recognizing text…"), work: { t, progress -> String in
            var parts: [String] = []
            for (n, u) in urls.enumerated() {
                if t.cancelled { throw ShelfOpsError.cancelled }
                let s = try TextRecognition.recognize(url: u)
                if !s.isEmpty { parts.append(s) }
                progress(Double(n + 1) / Double(urls.count))
            }
            return parts.joined(separator: "\n\n")
        }) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let text) where text.isEmpty: self.fail(L("No text found"))
            case .success(let text):
                let pb = self.pasteboard(); pb.clearContents(); pb.setString(text, forType: .string)
                let added = Motion.with(.appear) { self.store.addText(text, to: target) }
                Haptic.tap(.generic)
                // Said as it is: a text too long for the shelf (or a full shelf) is only copied.
                self.say("text.viewfinder", added != nil ? L("Text copied and added to the shelf") : L("Text copied (too long for the shelf)"))
            case .failure(let e): self.fail(e.localizedDescription)
            }
        }
        if !ok { fail(L("Wait for the job running now to finish")) }
    }

    // MARK: rename

    func renamePlan(_ rule: RenameRule) -> RenameEngine.Plan {
        let files = selected.filter { $0.kind == .file && !$0.missing }
        let urls = files.compactMap { store.url(of: $0) }
        let dates = urls.map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date() }
        return RenameEngine.plan(urls, rule: rule, dates: dates, isFolder: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
    }

    func rename(_ rule: RenameRule) {
        let plan = renamePlan(rule)
        guard plan.canApply else { return }
        renameRule = rule
        let done = RenameEngine.apply(plan)
        follow(done)
        sheet = nil
        lastRename = done
        if let f = done.failed.first { fail(f.why) }
        else { Haptic.tap(.generic); say("pencil", String(format: L("%d renamed"), done.moved.count), undo: true) }
    }

    func undoRename() {
        guard let last = lastRename else { return }
        lastRename = nil
        let back = RenameEngine.undo(last)
        follow(back)
        if let f = back.failed.first { fail(f.why) } else { say("arrow.uturn.backward", L("Names put back")) }
    }

    /// Items follow their files after a rename.
    private func follow(_ done: RenameEngine.Done) {
        for m in done.moved {
            for c in store.collections { for i in c.items where i.kind == .file && i.path == m.from.standardizedFileURL.path { store.noteMoved(i.id, to: m.to) } }
        }
    }

    // MARK: Copy to / Move to

    /// The system's folder panel (the point of the feature: macOS records the folder the user chose). The app comes forward
    /// for it and the app that was in front gets the keyboard back after.
    func chooseFolder(move: Bool, _ picked: @escaping (URL) -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.allowsMultipleSelection = false
        p.prompt = move ? L("Move Here") : L("Copy Here")
        p.message = move ? L("Choose where to move the files") : L("Choose where to copy the files")
        if let b = config.config.lastFolder {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: b, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) { p.directoryURL = u }
        }
        hold(true)
        let front = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        p.begin { [weak self] r in
            self?.hold(false)
            if front?.processIdentifier != getpid() { front?.activate() }
            guard r == .OK, let u = p.url else { return }
            self?.config.update { $0.lastFolder = ShelfBookmarks.make(u) }
            picked(u)
        }
    }

    func transfer(_ items: [ShelfItem], into dir: URL, move: Bool) {
        let pairs = items.filter { $0.isFileBacked && !$0.missing && (!move || $0.kind == .file) }.compactMap { i in store.url(of: i).map { (i.id, $0) } }
        guard !pairs.isEmpty else { return }
        let ok = tasks.start(move ? L("Moving…") : L("Copying…"), work: { t, progress in
            ShelfFiles.transfer(pairs.map(\.1), into: dir, move: move, cancel: t, progress: progress)
        }) { [weak self] r in
            guard let self, case .success(let res) = r else { return }
            if move { for m in res.done { if let id = pairs.first(where: { $0.1 == m.from })?.0 { self.store.noteMoved(id, to: m.to) } } }
            if let p = res.problem { self.fail(p) }
            else {
                Haptic.tap(.generic)
                let name = FileManager.default.displayName(atPath: dir.path)
                self.say(move ? "folder.badge.plus" : "plus.rectangle.on.folder",
                         String(format: move ? L("%1$d moved to %2$@") : L("%1$d copied to %2$@"), res.done.count, name))
            }
        }
        if !ok { fail(L("Wait for the job running now to finish")) }
    }

    // MARK: sharing

    func share(_ service: NSSharingService) {
        let items: [Any] = selected.filter { !$0.missing }.compactMap { i -> Any? in
            switch i.kind {
            case .file, .image: return store.url(of: i)
            case .link: return i.text.flatMap(URL.init(string:))
            case .text: return i.text
            }
        }
        sheet = nil
        Sharing.shared.perform(service, items, surface: .island)
    }

    func shareLink(provider: String) {
        sheet = nil
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let finish: (Result<[URL], Error>) -> Void = { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let links):
                let pb = self.pasteboard()
                if let deliver = CloudShareHook.deliver { deliver(links, pb) }      // kept out of clipboard histories
                else { pb.clearContents(); pb.setString(links.map(\.absoluteString).joined(separator: "\n"), forType: .string) }
                Haptic.tap(.generic)
                self.say("link", links.count == 1 ? L("Link copied") : String(format: L("%d links copied"), links.count))
            case .failure(let e):
                if case ShareError.cancelled = e { self.say("xmark.circle", L("Cancelled")) } else { self.fail(e.localizedDescription) }
            }
        }
        if let prepare = CloudShareHook.prepare {                            // the shelf's own progress line and Cancel
            prepare(urls, provider) { [weak self] title, work in
                guard let self else { return }
                if !self.tasks.start(title, work: work, done: finish) { self.fail(L("Wait for the job running now to finish")) }
            }
        } else if let upload = CloudShareHook.upload {
            say("arrow.up.circle", L("Uploading…"))
            upload(urls, provider, finish)
        }
    }

    // MARK: custom actions

    /// Runs a custom action on the selection (or on `files`, e.g. dropped on an instant action). The first time (or after its
    /// script changed) the user is asked, in the island.
    func perform(_ a: ShelfAction, files given: [URL]? = nil, depth: Int = 0) {
        sheet = nil
        let files = given ?? selectedURLs
        if let p = ShelfActionEngine.check(a) { fail(p.localizedDescription); return }
        if ShelfActionEngine.needsApproval(a) {
            guard let print = ShelfActionEngine.fingerprint(a) else { fail(String(format: L("Couldn't read %@"), (a.target as NSString).lastPathComponent)); return }
            let what = a.kind == .shortcut ? String(format: L("the Shortcut “%@”"), a.target) : a.target
            let spec = DialogSpec(icon: "exclamationmark.shield", title: String(format: L("Run “%@”?"), a.name),
                                  message: a.kind == .webhook ? ShelfActionEngine.webhookQuestion(a)
                                      : String(format: L("It runs %@ with your permissions. Cocaine asks again if it changes."), what),
                                  buttons: [DialogButton(id: "run", title: L("Run")), Dialogs.cancel], safeDefault: true, surface: .island)
            DialogCenter.shared.present(spec) { [weak self] r in
                guard r.buttonID == "run", let self else { return }
                self.config.updateAction(a.id) { $0.approved = print }
                var ok = a; ok.approved = print
                self.execute(ok, files: files, depth: depth)
            }
            return
        }
        execute(a, files: files, depth: depth)
    }

    private func execute(_ a: ShelfAction, files: [URL], depth: Int = 0) {
        let target = store.library.current
        let started = tasks.start(a.name, work: { t, _ in try ShelfActionEngine.run(a, files: files, cancel: t) }) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let o):
                for m in o.movedTo { for c in self.store.collections { for i in c.items where i.kind == .file && i.path == m.from.path { self.store.noteMoved(i.id, to: m.to) } } }
                if o.cancelled { self.say("xmark.circle", L("Cancelled")); return }
                if o.timedOut { self.fail(String(format: L("%@ took too long and was stopped"), a.name)); return }
                if !o.ok { self.fail(o.errors.split(whereSeparator: \.isNewline).first.map(String.init) ?? String(format: L("%@ didn't work"), a.name)); return }
                if !o.output.isEmpty {
                    switch a.output {
                    case .clipboard: let pb = self.pasteboard(); pb.clearContents(); pb.setString(o.output, forType: .string)
                    case .shelf: Motion.with(.appear) { _ = self.store.addText(String(o.output.prefix(ShelfLimits.textChars)), to: target) }
                    case .ignore: break
                    }
                }
                Haptic.tap(.generic)
                self.say(a.symbol, String(format: L("%@ done"), a.name))
                if let next = ShelfActionChain.next(after: a, in: self.config.config.actions, depth: depth) {   // A's output → B
                    self.perform(next, files: ShelfActionChain.files(output: o.output, moved: o.movedTo.map(\.to), fallback: files), depth: depth + 1)
                }
            case .failure(let e): self.fail(e.localizedDescription)
            }
        }
        if !started { fail(L("Wait for the job running now to finish")) }
    }

    // MARK: Quick Look

    func quickLook(_ items: [ShelfItem]? = nil) {
        let list = (items ?? selected).filter { !$0.missing }
        guard !list.isEmpty else { return }
        let urls = list.compactMap { i -> URL? in
            switch i.kind {
            case .file, .image: return store.url(of: i)
            case .text, .link: return ShelfQuickLook.preview(text: i.text ?? "", id: i.id)
            }
        }
        let focus = store.selection.focus.flatMap { f in list.firstIndex { $0.id == f } } ?? 0
        ShelfQuickLook.shared.show(urls, at: focus, hold: hold)
    }

    // MARK: collections

    func newCollection() {
        guard store.collections.count < ShelfLimits.collections else { fail(String(format: L("At most %d collections"), ShelfLimits.collections)); return }
        let spec = DialogSpec(icon: "plus.rectangle.on.rectangle", title: L("New collection"),
                              field: DialogField(placeholder: L("Name"), validate: { $0.trimmingCharacters(in: .whitespaces).isEmpty ? L("Give it a name") : nil }),
                              buttons: [DialogButton(id: "ok", title: L("Create"), needsValidInput: true), Dialogs.cancel], surface: .island)
        DialogCenter.shared.present(spec) { [weak self] r in
            guard case .button("ok", let text, _) = r, let self else { return }
            Motion.with(.page) { _ = self.store.createCollection(text) }
        }
    }

    func renameCollection(_ id: UUID) {
        guard let c = store.library.collection(id) else { return }
        let spec = DialogSpec(icon: "pencil", title: L("Rename collection"),
                              field: DialogField(placeholder: L("Name"), text: c.title, validate: { $0.trimmingCharacters(in: .whitespaces).isEmpty ? L("Give it a name") : nil }),
                              buttons: [DialogButton(id: "ok", title: L("Rename"), needsValidInput: true), Dialogs.cancel], surface: .island)
        DialogCenter.shared.present(spec) { [weak self] r in
            guard case .button("ok", let text, _) = r else { return }
            self?.store.renameCollection(id, text)
        }
    }

    func deleteCollection(_ id: UUID, surface: DialogSurface = .island) {
        guard let c = store.library.collection(id), store.collections.count > 1 else { return }
        let spec = DialogSpec(icon: "trash", title: String(format: L("Delete “%@”?"), c.title),
                              message: c.items.isEmpty ? nil : String(format: L("Its %d items leave the shelf; the files themselves stay where they are."), c.items.count),
                              critical: true, buttons: [DialogButton(id: "delete", title: L("Delete"), role: .destructive), Dialogs.cancel], surface: surface)
        DialogCenter.shared.present(spec) { [weak self] r in
            guard r.buttonID == "delete" else { return }
            Motion.with(.page) { _ = self?.store.deleteCollection(id) }
        }
    }

    func mergeCollection(_ id: UUID, surface: DialogSurface = .island) {
        let others = store.collections.filter { $0.id != id }
        guard !others.isEmpty, let c = store.library.collection(id) else { return }
        let spec = DialogSpec(icon: "arrow.triangle.merge", title: String(format: L("Merge “%@” into…"), c.title),
                              choices: others.map { DialogChoice(id: $0.id.uuidString, title: $0.title, symbol: "circle.fill") },
                              choiceMode: .act, buttons: [Dialogs.cancel], surface: surface)
        DialogCenter.shared.present(spec) { [weak self] r in
            guard case .choice(let s) = r, let into = UUID(uuidString: s), let self else { return }
            if Motion.with(.page, { self.store.merge(id, into: into) }) { self.say("arrow.triangle.merge", L("Merged")) }
            else { self.fail(String(format: L("%1$@ is full (%2$d items at most)"), self.store.library.collection(into)?.title ?? "", ShelfLimits.itemsPerCollection)) }
        }
    }

    /// Moves the selection to another collection.
    func moveSelection(to id: UUID) {
        sheet = nil
        let n = Motion.with(.appear) { store.transfer(store.selection.ids, to: id) }
        if n > 0, let c = store.library.collection(id) { say("arrow.right.circle", String(format: L("%1$d moved to %2$@"), n, c.title)) }
    }

    // MARK: the island's keys

    private func sheetChanged(_ old: ShelfSheet?) {
        let wants = sheet == .rename || sheet == .images
        let had = old == .rename || old == .images
        if wants != had { hold(wants) }
        if sheet != nil { takeKeyboard() }
    }
}
