// The iCloud Drive folder that carries clipboard items between the iPhone and this Mac, without CloudKit, an iOS app or an
// Apple developer account: plain files in the Shortcuts app's own iCloud folder, which an iPhone Shortcut can write and read
// by path ("Save File" / "Get File" with no folder picked) and which macOS mirrors at
// ~/Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/ (no entitlement needed to read or write it).
//
//   <root>/inbox/      iPhone → Mac: one file per item, uniquely named by the Shortcut (no two writers ever touch one name)
//   <root>/outbox/     Mac → iPhone: <unix-ms>-<random>.txt|png per item sent, plus latest.txt or latest.png (the newest)
//   <root>/processed/  what was taken in (or refused), when the user keeps files instead of deleting them; cleaned after a while
//
// No manifest: the folder listing is the state. Everything here is pure or works on a folder it is given (tests use temporary
// folders; nothing touches the real iCloud Drive unless the user turned the feature on). The watcher is in ClipSync.swift.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Where

enum ICloudPaths {
    /// iCloud Drive's local mirror (every app's container is a folder in it).
    static func mobileDocuments(home: URL) -> URL { home.appendingPathComponent("Library/Mobile Documents", isDirectory: true) }
    /// The Shortcuts app's iCloud folder ("iCloud Drive › Shortcuts" on the iPhone): the only place a generated Shortcut can
    /// reach by path, without a folder the user picks on the phone.
    static func shortcutsDocuments(home: URL) -> URL {
        mobileDocuments(home: home).appendingPathComponent("iCloud~is~workflow~my~workflows/Documents", isDirectory: true)
    }
    /// The general iCloud Drive folder (for the docs: what the user sees as "iCloud Drive" in Finder).
    static func cloudDocs(home: URL) -> URL { mobileDocuments(home: home).appendingPathComponent("com~apple~CloudDocs", isDirectory: true) }

    static let defaultName = "Cocaine Clipboard"

    /// The folder for a name chosen in the settings (always inside the Shortcuts folder).
    static func root(home: URL, name: String) -> URL {
        shortcutsDocuments(home: home).appendingPathComponent(validName(name) ? name : defaultName, isDirectory: true)
    }

    /// A folder name the Shortcut can carry in a path: one component, printable, no path tricks, at most 64 characters.
    static func validName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t == s, t.count <= 64, !t.hasPrefix("."), t != "..", !t.contains("/"), !t.contains(":"), !t.contains("\\") else { return false }
        return !t.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// The path the iPhone Shortcuts use for `root` ("Cocaine Clipboard"), nil when `root` isn't a folder directly in Shortcuts' one.
    static func shortcutSubpath(_ root: URL, home: URL) -> String? {
        let base = shortcutsDocuments(home: home).standardizedFileURL.path
        let r = root.standardizedFileURL.path
        guard r.hasPrefix(base + "/") else { return nil }
        let rest = String(r.dropFirst(base.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return validName(rest) ? rest : nil
    }
}

/// The three folders of one sync root.
struct SyncFolder: Equatable {
    let root: URL
    var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    var outbox: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    var processed: URL { root.appendingPathComponent("processed", isDirectory: true) }

    /// Makes the folders. Only its own: the parent (the Shortcuts iCloud folder) must already exist — Cocaine never creates
    /// an iCloud container, and no iCloud Drive means "turn on iCloud Drive", not a folder that never syncs.
    func create(fm: FileManager = .default) throws {
        guard fm.fileExists(atPath: root.deletingLastPathComponent().path) else { throw CocoaError(.fileNoSuchFile) }
        for d in [root, inbox, outbox, processed] where !fm.fileExists(atPath: d.path) {
            try fm.createDirectory(at: d, withIntermediateDirectories: false)
        }
    }
}

enum SyncFolderStatus: Equatable {
    case ready                       // the folder and its inbox/outbox are there
    case notCreated                  // iCloud Drive is there, the folder not yet (made when sync is turned on)
    case noICloud                    // no iCloud Drive / Shortcuts folder on this Mac
    case unreadable                  // there, but can't be read (permission)

    static func of(_ f: SyncFolder, fm: FileManager = .default) -> SyncFolderStatus {
        let parent = f.root.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path) else { return .noICloud }
        guard fm.fileExists(atPath: f.inbox.path), fm.fileExists(atPath: f.outbox.path) else { return .notCreated }
        guard fm.isReadableFile(atPath: f.inbox.path), fm.isWritableFile(atPath: f.outbox.path) else { return .unreadable }
        return .ready
    }
}

// MARK: - Names

enum ClipSyncNames {
    /// "<unix-ms>-<6 hex>.<ext>": unique without coordination (the phone's Shortcut uses "<yyyyMMdd-HHmmss>-<6 digits>").
    static func make(now: Date, ext: String, random: String? = nil) -> String {
        let r = random ?? String(format: "%06x", UInt32.random(in: 0...0xFFFFFF))
        return "\(Int64(now.timeIntervalSince1970 * 1000))-\(r).\(ext)"
    }

    /// Names Cocaine writes into the outbox (and may delete later): nothing else there is ever removed.
    static func isOurs(_ name: String) -> Bool {
        name.range(of: #"^[0-9]{10,16}-[0-9a-f]{6}\.(txt|png)$"#, options: .regularExpression) != nil
    }

    /// Files still being written or not meant for us: hidden files, temporary and partial downloads, editors' lock files.
    static func isTransient(_ name: String) -> Bool {
        let l = name.lowercased()
        if l.hasPrefix(".") || l.hasPrefix("~$") || l.hasSuffix("~") { return true }
        return [".tmp", ".part", ".partial", ".download", ".crdownload", ".sb-", ".swp"].contains { l.hasSuffix($0) || l.contains(".sb-") }
    }

    /// An iCloud placeholder of a file not downloaded yet ("._name.ext.icloud" style: ".name.ext.icloud") → "name.ext".
    static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
    }
}

// MARK: - The inbox, one scan at a time

struct InboxEntry: Equatable {
    var name: String                 // relative to the inbox ("sub/file" one level down at most)
    var size: Int
    var modified: Date
    var isDirectory = false
}

enum InboxReject: String, Error, Equatable {
    case tooBig, empty, unsupported
}

enum InboxAction: Equatable {
    case ingest(String)              // complete and stable: read it, take it in, then move or delete it
    case download(String)            // an iCloud placeholder: ask for it (the name is the placeholder's)
    case reject(String, InboxReject) // never taken in: moved aside (or deleted) so it isn't looked at again
}

/// Decides, scan after scan, which inbox files are ready: placeholders are asked for (again every minute, and counted as
/// "not downloaded" after `downloadTimeout`), names still being written are left alone, a file is taken only once its size
/// and date stayed the same for `stableFor` seconds (a partial write or a download in progress changes them), oversized ones
/// are refused unread. At most `maxPerScan` files per scan, oldest first.
final class InboxScanner {
    var stableFor: Double = 1.5
    var downloadTimeout: Double = 180
    var retryDownload: Double = 60
    var maxBytes: Int
    var maxPerScan = 20

    private var seen: [String: (size: Int, modified: Date, since: Date)] = [:]
    private var asked: [String: (first: Date, last: Date)] = [:]   // placeholder target → when it was asked for
    private(set) var stuck: Set<String> = []                        // placeholders past the timeout
    private(set) var waiting = 0                                    // files not ready yet in the last scan

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func scan(_ entries: [InboxEntry], now: Date) -> [InboxAction] {
        var out: [InboxAction] = []
        var ingests = 0
        var present = Set<String>(), placeholders = Set<String>()
        waiting = 0
        for e in entries.sorted(by: { $0.modified < $1.modified }) where !e.isDirectory {
            let leaf = (e.name as NSString).lastPathComponent
            let dir = (e.name as NSString).deletingLastPathComponent
            if let target = ClipSyncNames.placeholderTarget(leaf) {
                let key = dir.isEmpty ? target : dir + "/" + target
                placeholders.insert(key)
                waiting += 1
                let a = asked[key]
                if a == nil || now.timeIntervalSince(a!.last) >= retryDownload {
                    out.append(.download(e.name))
                    asked[key] = (a?.first ?? now, now)
                }
                if let first = asked[key]?.first, now.timeIntervalSince(first) >= downloadTimeout { stuck.insert(key) }
                continue
            }
            if ClipSyncNames.isTransient(leaf) { continue }
            present.insert(e.name)
            if e.size > maxBytes { out.append(.reject(e.name, .tooBig)); seen[e.name] = nil; continue }
            if let s = seen[e.name], s.size == e.size, s.modified == e.modified {
                if now.timeIntervalSince(s.since) >= stableFor && now.timeIntervalSince(e.modified) >= stableFor {
                    if e.size == 0 { out.append(.reject(e.name, .empty)); seen[e.name] = nil; continue }
                    if ingests < maxPerScan { out.append(.ingest(e.name)); ingests += 1; seen[e.name] = nil } else { waiting += 1 }
                } else { waiting += 1 }
            } else {
                seen[e.name] = (e.size, e.modified, now)
                waiting += 1
            }
        }
        // Forget what is gone (taken by another Mac, deleted by the user, downloaded).
        seen = seen.filter { present.contains($0.key) }
        asked = asked.filter { placeholders.contains($0.key) }
        stuck = stuck.intersection(placeholders)
        return out
    }

    /// A file handled (taken in or moved aside): it is never looked at again under this name.
    func forget(_ name: String) { seen[name] = nil }
}

// MARK: - What a file holds

enum SyncContent: Equatable {
    case text(String)
    case image(png: Data, width: Int, height: Int)

    var isText: Bool { if case .text = self { return true }; return false }
}

enum SyncDecode {
    /// The longest side an image keeps (photos are made smaller, then kept as PNG like any copied image).
    static let maxSide = 2048
    static let maxTextBytes = 1_000_000

    /// Recognised by its bytes, not its name (the Shortcut's file may have any extension, or none).
    static func isImage(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(16))
        guard b.count >= 12 else { return false }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) || b.starts(with: [0xFF, 0xD8, 0xFF]) || b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return true }
        if Array(b[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            return ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1", "avif"].contains(brand)
        }
        return false
    }

    static func decode(_ data: Data, name: String) -> Result<SyncContent, InboxReject> {
        guard !data.isEmpty else { return .failure(.empty) }
        if isImage(data) { return image(data).map { .success($0) } ?? .failure(.unsupported) }
        guard data.count <= maxTextBytes else { return .failure(.tooBig) }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "webloc", let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let u = p["URL"] as? String, !u.isEmpty { return .success(.text(u)) }
        guard let s = text(data) else { return .failure(.unsupported) }
        if ext == "url", let line = s.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("URL=") }) {
            return .success(.text(String(line.dropFirst(4))))
        }
        if ext == "json", let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = j["text"] as? String {
            return t.isEmpty ? .failure(.empty) : .success(.text(t))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .failure(.empty) : .success(.text(s))
    }

    /// UTF-8 (a BOM dropped) or UTF-16 with its BOM; nil for anything binary.
    static func text(_ d: Data) -> String? {
        var data = d
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: d, encoding: .utf16) }
        guard !data.contains(0), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// The image as PNG, at most `maxSide` pixels on its longest side, turned upright.
    static func image(_ d: Data) -> SyncContent? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: min(maxSide, max(w, h))]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return .image(png: out as Data, width: cg.width, height: cg.height)
    }
}

// MARK: - The outbox and the cleaning

enum SyncOutbox {
    static let latestText = "latest.txt", latestImage = "latest.png"

    /// Writes one item: its own uniquely named file, then latest.txt or latest.png (the other one removed, so "Get from Mac"
    /// finds only the newest kind). Atomic (written aside, then renamed). Returns the unique file.
    @discardableResult
    static func write(_ c: SyncContent, to f: SyncFolder, now: Date) throws -> URL {
        let (data, ext): (Data, String)
        switch c {
        case .text(let s): (data, ext) = (Data(s.utf8), "txt")
        case .image(let png, _, _): (data, ext) = (png, "png")
        }
        let unique = f.outbox.appendingPathComponent(ClipSyncNames.make(now: now, ext: ext))
        guard SafeFile.writePrivate(data, to: unique, folderMode: 0o755),
              SafeFile.writePrivate(data, to: f.outbox.appendingPathComponent(ext == "txt" ? latestText : latestImage), folderMode: 0o755)
        else { throw CocoaError(.fileWriteUnknown) }
        try? FileManager.default.removeItem(at: f.outbox.appendingPathComponent(ext == "txt" ? latestImage : latestText))
        return unique
    }

    /// Removes old files: everything in processed/ older than `processedHours`, and Cocaine's own unique files in the outbox
    /// older than `outboxHours` (latest.* stay). Returns how many were removed.
    @discardableResult
    static func clean(_ f: SyncFolder, now: Date, processedHours: Double, outboxHours: Double, fm: FileManager = .default) -> Int {
        var n = 0
        func sweep(_ dir: URL, hours: Double, only: (String) -> Bool) {
            guard hours > 0, let list = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
            for u in list where only(u.lastPathComponent) {
                let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if now.timeIntervalSince(m) > hours * 3600, (try? fm.removeItem(at: u)) != nil { n += 1 }
            }
        }
        sweep(f.processed, hours: processedHours) { !$0.hasPrefix(".") }
        sweep(f.outbox, hours: outboxHours, only: ClipSyncNames.isOurs)
        return n
    }
}
