// The "AI context" basket: the only things an AI tool connected through MCP (Sources/MCP*.swift) can ever read. The user fills it
// from the notch ("Use as AI context" on clipboard items and shelf items, typed text); nothing else of the history, the shelf or
// the disk is reachable. Items are held BY REFERENCE (a clipboard item's id, a file's resolved path) and read only when an AI
// tool asks, so an item deleted from the clipboard or a file moved away is simply gone. Bounded (items, bytes), expiring
// (8 hours by default), in memory unless "Keep after restart" is on (then a private 0600 file, never the content of clipboard
// items or files, only typed text and references). Thread-safe: the socket server reads it off the main thread.
// The reader (AIContextReader) turns an entry into bounded text at request time; files are re-checked on every read.

import AppKit
import Combine
import Darwin
import PDFKit
import UniformTypeIdentifiers

struct AIContextEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case clip, file, text }
    var id = UUID()
    var kind: Kind
    /// clip: the clipboard item's id; file: the realpath taken when it was added; text: the text itself.
    var ref: String
    var title: String
    var added: Date
}

enum AIContextLimits {
    static let maxItems = 50
    static let maxTextBytes = 64_000          // a typed or shelf text
    static let maxTitle = 80
    static let maxFileRead = 512 * 1024       // read from a file at most (then "truncated")
    static let maxClipText = 512 * 1024
    static let maxPDFPages = 20
    static let maxOCRBytes = 50 << 20         // images larger than this aren't recognised
    static let expiryChoices = [1, 8, 24, 0]  // hours; 0 = until cleared
}

/// The basket. All state is behind one lock; `entries` is the published copy for SwiftUI (main thread).
final class AIContextBasket: ObservableObject {

    @Published private(set) var entries: [AIContextEntry] = []
    private let lock = NSLock()
    private var items: [AIContextEntry] = []
    private var expiryHours = 8
    private var persistURL: URL?
    var now: () -> Date = Date.init
    /// Resolves a path the way it is checked again on every read (realpath). Tests may wrap it.
    var resolve: (String) -> String? = AIContextPaths.real
    /// After any change (any thread): MCP clients learn the list changed.
    var changed: () -> Void = {}

    init(persistAt url: URL? = nil, expiryHours: Int = 8) {
        self.expiryHours = expiryHours
        if let url { persistURL = url; items = Self.load(url) }
        prune()
        publish()
    }

    // MARK: settings

    var expiry: Int { lock.lock(); defer { lock.unlock() }; return expiryHours }
    func setExpiry(hours: Int) { lock.lock(); expiryHours = max(0, min(24 * 7, hours)); lock.unlock(); prune(); publish() }

    /// Keep the basket in a private file (nil: memory only, and any file is deleted).
    func setPersistence(_ url: URL?) {
        lock.lock()
        let old = persistURL
        persistURL = url
        lock.unlock()
        if url == nil, let old { try? FileManager.default.removeItem(at: old) }
        save()
    }

    // MARK: reading

    /// The live entries (expired ones are dropped first).
    func list() -> [AIContextEntry] { prune(); lock.lock(); defer { lock.unlock() }; return items }
    func entry(_ id: UUID) -> AIContextEntry? { list().first { $0.id == id } }
    var count: Int { list().count }
    func expires(_ e: AIContextEntry) -> Date? { let h = expiry; return h == 0 ? nil : e.added.addingTimeInterval(Double(h) * 3600) }

    // MARK: changing

    enum Refusal: Error, Equatable { case full, badRef, missingFile, secret, tooBig }

    /// Adds items (newest first). The same thing again moves to the top with a fresh time. Returns how many were added and why
    /// the others weren't.
    @discardableResult
    func add(_ list: [(kind: String, ref: String, title: String)]) -> (added: [UUID], refused: [Refusal]) {
        var added: [UUID] = [], refused: [Refusal] = []
        prune()
        for raw in list {
            switch validated(raw) {
            case .failure(let r): refused.append(r)
            case .success(var e):
                lock.lock()
                if let i = items.firstIndex(where: { $0.kind == e.kind && $0.ref == e.ref }) {
                    e.id = items[i].id
                    items.remove(at: i)
                }
                if items.count >= AIContextLimits.maxItems { lock.unlock(); refused.append(.full); continue }
                items.insert(e, at: 0)
                lock.unlock()
                added.append(e.id)
            }
        }
        if !added.isEmpty { save(); publish(); changed() }
        return (added, refused)
    }

    func remove(_ id: UUID) {
        lock.lock(); let n = items.count; items.removeAll { $0.id == id }; let did = items.count != n; lock.unlock()
        if did { save(); publish(); changed() }
    }

    func clear() {
        lock.lock(); let had = !items.isEmpty; items.removeAll(); lock.unlock()
        if had { save(); publish(); changed() }
    }

    private func validated(_ raw: (kind: String, ref: String, title: String)) -> Result<AIContextEntry, Refusal> {
        guard let kind = AIContextEntry.Kind(rawValue: raw.kind) else { return .failure(.badRef) }
        var ref = raw.ref
        switch kind {
        case .clip:
            guard let u = UUID(uuidString: ref) else { return .failure(.badRef) }
            ref = u.uuidString
        case .file:
            guard ref.hasPrefix("/"), !ref.contains("\u{0}"), let real = resolve(ref) else { return .failure(.missingFile) }
            ref = real
        case .text:
            guard !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.badRef) }
            guard ref.utf8.count <= AIContextLimits.maxTextBytes else { return .failure(.tooBig) }
            if ClipRules.looksLikeSecret(ref) || ClipRules.looksLikeCard(ref) { return .failure(.secret) }
        }
        let title = AIContextText.clean(raw.title.isEmpty ? (kind == .file ? (ref as NSString).lastPathComponent : ref) : raw.title,
                                        AIContextLimits.maxTitle)
        return .success(AIContextEntry(kind: kind, ref: ref, title: title.isEmpty ? "…" : title, added: now()))
    }

    private func prune() {
        lock.lock()
        let h = expiryHours, t = now()
        let n = items.count
        if h > 0 { items.removeAll { t.timeIntervalSince($0.added) > Double(h) * 3600 || $0.added > t.addingTimeInterval(300) } }
        let did = items.count != n
        lock.unlock()
        if did { save(); publish(); changed() }
    }

    private func publish() {
        lock.lock(); let snap = items; lock.unlock()
        if Thread.isMainThread { if entries != snap { entries = snap } }
        else { DispatchQueue.main.async { [weak self] in if self?.entries != snap { self?.entries = snap } } }
    }

    // MARK: the optional file

    private struct Saved: Codable { var v = 1; var items: [AIContextEntry] }

    private func save() {
        lock.lock(); let url = persistURL; let snap = items; lock.unlock()
        guard let url, let d = try? JSONEncoder().encode(Saved(items: snap)) else { return }
        SafeFile.writePrivate(d, to: url)
    }

    static func load(_ url: URL) -> [AIContextEntry] {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_size < 8 << 20,
              let d = FileManager.default.contents(atPath: url.path), let s = try? JSONDecoder().decode(Saved.self, from: d), s.v == 1 else { return [] }
        return Array(s.items.prefix(AIContextLimits.maxItems))
    }

    /// Tests: the stored items as they are.
    func rawItems() -> [AIContextEntry] { lock.lock(); defer { lock.unlock() }; return items }
}

enum AIContextPaths {
    /// The canonical path (symlinks and `..` resolved) of something that exists, or nil.
    static func real(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}

/// Text from the outside world made safe to show or return: no control characters (but newlines and tabs where allowed), bounded.
enum AIContextText {
    static func clean(_ s: String, _ limit: Int, keepNewlines: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u == "\n" || u == "\t" { out.append(keepNewlines ? u : " "); continue }
            if CharacterSet.controlCharacters.contains(u) || (0x202A...0x202E).contains(u.value) || (0x2066...0x2069).contains(u.value)
                || u.value == 0x200E || u.value == 0x200F { continue }      // bidi overrides can disguise text
            out.append(u)
        }
        let t = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = keepNewlines ? t : t.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        return collapsed.count > limit ? String(collapsed.prefix(max(1, limit - 1))) + "…" : collapsed
    }

    /// A rough token count, as the clients' output caps count: ~4 ASCII characters per token, any other character 1 token.
    static func tokens(_ s: Substring) -> Int {
        var ascii = 0, other = 0
        for u in s.unicodeScalars { if u.isASCII { ascii += 1 } else { other += 1 } }
        return (ascii + 3) / 4 + other
    }

    /// The longest prefix of `s` (from character `offset`) within `budget` tokens: (text, next offset or nil when it all fit).
    static func cut(_ s: String, from offset: Int, budget: Int) -> (text: String, next: Int?) {
        guard offset < s.count else { return ("", nil) }
        let start = s.index(s.startIndex, offsetBy: max(0, offset))
        var used = 0, ascii = 0, end = start, count = 0
        var i = start
        while i < s.endIndex {
            let c = s[i]
            let cost: Int
            if c.unicodeScalars.allSatisfy(\.isASCII) { ascii += 1; cost = ascii % 4 == 1 ? 1 : 0 } else { cost = c.unicodeScalars.count }
            if used + cost > budget { break }
            used += cost
            i = s.index(after: i); end = i; count += 1
        }
        let text = String(s[start..<end])
        return (text, end < s.endIndex ? offset + count : nil)
    }
}

/// One entry turned into what an AI tool receives, at request time.
struct AIContextContent: Equatable {
    var id: UUID
    var kind: String          // text, image, file, folder, pdf…
    var title: String
    var mime: String
    var text: String          // the readable text (or the metadata, said in words)
    var bytes: Int            // what was read
    var note: String? = nil   // e.g. "truncated at 512 KB", "metadata only"
}

/// Turns basket entries into content, re-checking everything at the moment it is read.
struct AIContextReader {
    /// A clipboard item by id (the history's own, at this moment).
    var clip: (UUID) -> ClipItem? = { id in ClipboardHistory.shared.items.first { $0.id == id } }
    /// Text recognised in an image file (nil: none / not possible). Vision, on this Mac.
    var recognize: (URL) -> String? = { try? TextRecognition.recognize(url: $0) }

    enum Failure: Error, Equatable { case gone, notAllowed, unreadable }

    func content(_ e: AIContextEntry) -> Result<AIContextContent, Failure> {
        switch e.kind {
        case .text:
            return .success(AIContextContent(id: e.id, kind: "text", title: e.title, mime: "text/plain", text: e.ref, bytes: e.ref.utf8.count))
        case .clip:
            guard let u = UUID(uuidString: e.ref), let c = clip(u) else { return .failure(.gone) }
            switch c.kind {
            case .text:
                var t = c.text, note: String?
                if t.utf8.count > AIContextLimits.maxClipText { t = String(decoding: Data(t.utf8).prefix(AIContextLimits.maxClipText), as: UTF8.self); note = "truncated at 512 KB" }
                return .success(AIContextContent(id: e.id, kind: "text", title: e.title, mime: "text/plain", text: t, bytes: t.utf8.count, note: note))
            case .image:
                let meta = "Image from the clipboard, \(c.width)×\(c.height) pixels."
                if let o = c.ocr, !o.isEmpty {
                    return .success(AIContextContent(id: e.id, kind: "image", title: e.title, mime: "text/plain", text: meta + "\nText recognised in it (OCR, secrets masked):\n" + o,
                                                     bytes: o.utf8.count, note: "OCR text only; the image itself is not sent"))
                }
                return .success(AIContextContent(id: e.id, kind: "image", title: e.title, mime: "text/plain", text: meta, bytes: 0,
                                                 note: "metadata only (no recognised text; turn on text recognition in Settings → Island → Clipboard)"))
            case .files:
                // A copied file reference: its paths only (the files themselves are not in the basket).
                let t = "Files copied to the clipboard (paths only):\n" + c.paths.prefix(100).joined(separator: "\n")
                return .success(AIContextContent(id: e.id, kind: "files", title: e.title, mime: "text/plain", text: t, bytes: t.utf8.count,
                                                 note: "paths only: add the files themselves from the shelf to share their content"))
            }
        case .file:
            return file(e)
        }
    }

    /// A file: only the exact resolved path the user added, still resolving to itself (no symlink swapped in since), opened
    /// without following links and checked to be the same file that was looked at.
    func file(_ e: AIContextEntry) -> Result<AIContextContent, Failure> {
        let path = e.ref
        guard path.hasPrefix("/"), let real = AIContextPaths.real(path) else { return .failure(.gone) }
        guard real == path else { return .failure(.notAllowed) }
        var st = stat()
        guard lstat(path, &st) == 0 else { return .failure(.gone) }
        let name = (path as NSString).lastPathComponent
        let type = UTType(filenameExtension: (path as NSString).pathExtension)
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        let mod = ISO8601DateFormatter().string(from: modified)
        if (st.st_mode & S_IFMT) == S_IFDIR {
            let n = (try? FileManager.default.contentsOfDirectory(atPath: path).count) ?? 0
            let t = "Folder “\(name)”, \(n) items, modified \(mod). Its contents are not shared (add files one by one)."
            return .success(AIContextContent(id: e.id, kind: "folder", title: e.title, mime: "text/plain", text: t, bytes: 0, note: "metadata only"))
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.notAllowed) }
        let size = Int(st.st_size)
        let url = URL(fileURLWithPath: path)
        let meta = "File “\(name)”, \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)), \(type?.localizedDescription ?? "unknown type"), modified \(mod)."
        if type?.conforms(to: .pdf) == true {
            guard let doc = PDFDocument(url: url) else { return .failure(.unreadable) }
            var parts: [String] = [], total = 0
            for i in 0..<min(doc.pageCount, AIContextLimits.maxPDFPages) {
                guard let s = doc.page(at: i)?.string else { continue }
                parts.append(s); total += s.utf8.count
                if total > AIContextLimits.maxFileRead { break }
            }
            let t = parts.joined(separator: "\n\n")
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .success(AIContextContent(id: e.id, kind: "pdf", title: e.title, mime: "text/plain", text: meta + " No text layer.", bytes: 0, note: "metadata only"))
            }
            return .success(AIContextContent(id: e.id, kind: "pdf", title: e.title, mime: "text/plain", text: t, bytes: t.utf8.count,
                                             note: doc.pageCount > AIContextLimits.maxPDFPages ? "first \(AIContextLimits.maxPDFPages) pages" : nil))
        }
        if type?.conforms(to: .image) == true {
            if size <= AIContextLimits.maxOCRBytes, let o = recognize(url), !o.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .success(AIContextContent(id: e.id, kind: "image", title: e.title, mime: "text/plain",
                                                 text: meta + "\nText recognised in it (OCR):\n" + o, bytes: o.utf8.count, note: "OCR text only; the image itself is not sent"))
            }
            return .success(AIContextContent(id: e.id, kind: "image", title: e.title, mime: "text/plain", text: meta, bytes: 0, note: "metadata only"))
        }
        // Read a bounded prefix through a descriptor that refuses links, and make sure it is the file that was checked.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return .failure(.unreadable) }
        defer { close(fd) }
        var fst = stat()
        guard fstat(fd, &fst) == 0, fst.st_dev == st.st_dev, fst.st_ino == st.st_ino, (fst.st_mode & S_IFMT) == S_IFREG else { return .failure(.notAllowed) }
        let want = min(size, AIContextLimits.maxFileRead)
        var buf = [UInt8](repeating: 0, count: max(1, want))
        var got = 0
        while got < want {
            let n = read(fd, &buf[got], want - got)
            if n <= 0 { break }
            got += n
        }
        let data = Data(buf.prefix(got))
        guard Self.looksLikeText(data, type: type) else {
            return .success(AIContextContent(id: e.id, kind: "file", title: e.title, mime: "text/plain", text: meta + " Not a text file: its content is not shared.",
                                             bytes: 0, note: "metadata only"))
        }
        var text = String(decoding: data, as: UTF8.self)
        if got < size, text.hasSuffix("\u{FFFD}") { text.removeLast() }       // a character cut in half at the limit
        return .success(AIContextContent(id: e.id, kind: "file", title: e.title, mime: type?.preferredMIMEType ?? "text/plain", text: text, bytes: got,
                                         note: got < size ? "truncated: first \(got / 1024) KB of \(size / 1024) KB" : nil))
    }

    /// Text: a text type, or (any type) UTF-8 without NUL bytes in its first 8 KB.
    static func looksLikeText(_ d: Data, type: UTType?) -> Bool {
        let head = d.prefix(8192)
        if head.contains(0) { return false }
        if let t = type, t.conforms(to: .text) || t.conforms(to: .sourceCode) || t.conforms(to: .json) || t.conforms(to: .xml) || t.conforms(to: .propertyList) { return true }
        if d.isEmpty { return true }
        // Valid UTF-8 (a character cut at the end of the sample is fine).
        for drop in 0...3 where head.count > drop {
            if String(data: head.dropLast(drop), encoding: .utf8) != nil { return true }
        }
        return false
    }
}
