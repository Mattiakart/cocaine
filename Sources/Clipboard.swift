import AppKit
import CryptoKit
import Foundation
import ImageIO
import Security

// The island's clipboard history: text, images and file references, searchable, with favorites. Memory only by default; saving
// it on this Mac is optional and encrypted (key in the Keychain). Nothing here ever leaves the Mac.
// The views are in main.swift (they use its private styles); everything they show and do is here.

// MARK: - Items and settings

enum ClipKind: String, Codable { case text, image, files }

struct ClipItem: Identifiable, Equatable, Codable {
    var id = UUID()
    var kind: ClipKind
    var text = ""                    // .text: the plain text, exactly as copied
    var paths: [String] = []         // .files: references (paths), never copies
    var width = 0, height = 0        // .image: pixels
    var bytes = 0                    // what the size limits count
    var digest = ""                  // the same content has the same digest: copying it again moves it to the top
    var date = Date()
    var pinned = false
    var source: String?              // the app it came from (bundle id), when known
    var payload: Data?               // .image: the PNG, in memory only (on disk it's its own encrypted file)

    enum CodingKeys: String, CodingKey { case id, kind, text, paths, width, height, bytes, digest, date, pinned, source }

    var names: [String] { paths.map { ($0 as NSString).lastPathComponent } }

    static func digest(_ kind: ClipKind, _ data: Data) -> String {
        var h = SHA256()
        h.update(data: Data(kind.rawValue.utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func text(_ s: String, date: Date = Date(), source: String? = nil) -> ClipItem {
        let d = Data(s.utf8)
        return ClipItem(kind: .text, text: s, bytes: d.count, digest: digest(.text, d), date: date, source: source)
    }
    static func files(_ paths: [String], date: Date = Date(), source: String? = nil) -> ClipItem {
        let d = Data(paths.joined(separator: "\n").utf8)
        return ClipItem(kind: .files, paths: paths, bytes: d.count, digest: digest(.files, d), date: date, source: source)
    }
    static func image(png: Data, width: Int, height: Int, date: Date = Date(), source: String? = nil) -> ClipItem {
        ClipItem(kind: .image, width: width, height: height, bytes: png.count, digest: digest(.image, png), date: date, source: source, payload: png)
    }
}

struct ClipSettings: Codable, Equatable {
    var persist = false              // off: memory only, as it always was
    var maxItems = 50                // favorites don't count
    var maxAgeHours = 24 * 7         // 0: no limit
    var maxTotalMB = 50
    var maxItemMB = 10
    var skipSecrets = true           // card numbers, keys, tokens
    var excludedApps: [String] = []  // bundle ids, on top of the password managers (always excluded)
    var patterns: [String] = []      // the user's own regular expressions: matching text is skipped

    static let itemChoices = [25, 50, 100, 200, 500]
    static let ageChoices = [1, 24, 24 * 7, 24 * 30, 0]
    static let totalChoices = [10, 50, 100, 250]
    static let itemSizeChoices = [1, 5, 10, 25]
    static let key = "clipboardSettings"

    init() {}
    /// Missing keys (older or newer versions) take their default instead of losing every setting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipSettings()
        persist = (try? c.decodeIfPresent(Bool.self, forKey: .persist)) ?? d.persist
        maxItems = (try? c.decodeIfPresent(Int.self, forKey: .maxItems)) ?? d.maxItems
        maxAgeHours = (try? c.decodeIfPresent(Int.self, forKey: .maxAgeHours)) ?? d.maxAgeHours
        maxTotalMB = (try? c.decodeIfPresent(Int.self, forKey: .maxTotalMB)) ?? d.maxTotalMB
        maxItemMB = (try? c.decodeIfPresent(Int.self, forKey: .maxItemMB)) ?? d.maxItemMB
        skipSecrets = (try? c.decodeIfPresent(Bool.self, forKey: .skipSecrets)) ?? d.skipSecrets
        excludedApps = (try? c.decodeIfPresent([String].self, forKey: .excludedApps)) ?? d.excludedApps
        patterns = (try? c.decodeIfPresent([String].self, forKey: .patterns)) ?? d.patterns
    }

    var maxItemBytes: Int { max(1, maxItemMB) * 1_000_000 }
    var maxTotalBytes: Int { max(1, maxTotalMB) * 1_000_000 }

    static func load(_ d: UserDefaults) -> ClipSettings {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(ClipSettings.self, from: data) else { return ClipSettings() }
        return s
    }
    func save(_ d: UserDefaults) { if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) } }
}

// MARK: - What is never kept

enum ClipRules {
    /// Marks what Cocaine itself puts on the clipboard, so copying an item again isn't captured as a new one.
    static let ownType = "local.cocaine.clipboard.own"
    /// nspasteboard.org's markers (and the older ones it lists): passwords, one-time content, generated content.
    static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
        "Pasteboard generator type", "net.antelle.keeweb",
    ]
    /// Password managers, by a piece of their bundle id: always excluded, whatever the user's list says.
    static let passwordApps = ["1password", "onepassword", "bitwarden", "keepass", "lastpass", "dashlane", "enpass", "strongbox",
                               "nordpass", "protonpass", "proton.pass", "com.apple.keychainaccess", "com.apple.passwords"]

    static func isConcealed(_ types: [String]) -> Bool { types.contains { concealedTypes.contains($0) } }

    static func isPasswordApp(_ bundle: String?) -> Bool {
        guard let b = bundle?.lowercased(), !b.isEmpty else { return false }
        return passwordApps.contains { b.contains($0) }
    }

    static func isExcluded(source: String?, settings: ClipSettings) -> Bool {
        guard let s = source, !s.isEmpty else { return false }
        return isPasswordApp(s) || settings.excludedApps.contains { $0.caseInsensitiveCompare(s) == .orderedSame }
    }

    /// The whole text is a card number (13–19 digits, spaces or dashes between, valid check digit).
    static func looksLikeCard(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 30, t.range(of: "^[0-9][0-9 -]*[0-9]$", options: .regularExpression) != nil else { return false }
        let digits = t.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() { let x = i % 2 == 1 ? d * 2 : d; sum += x > 9 ? x - 9 : x }
        return sum % 10 == 0
    }

    private static let tokenPrefixes = ["sk-", "sk_live_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "glpat-", "xoxb-", "xoxp-", "xapp-",
                                        "AKIA", "ASIA", "AIza", "ya29.", "npm_", "pypi-", "hf_"]

    /// One word that looks like a key or a token: a known prefix, a JWT, a private key block, or a long random-looking string
    /// (three kinds of characters, digits among them, and high entropy). Words, URLs, paths, e-mail addresses, hex hashes and
    /// UUIDs are not tokens.
    static func looksLikeSecret(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("-----BEGIN") && t.contains("PRIVATE KEY-----") { return true }
        guard (16...512).contains(t.count), t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        if tokenPrefixes.contains(where: { t.hasPrefix($0) }) && t.count >= 20 { return true }
        if t.hasPrefix("eyJ") && t.filter({ $0 == "." }).count == 2 { return true }                     // a JWT
        guard t.count >= 24, !t.contains("://"), !t.hasPrefix("/"), !t.hasPrefix("~"), !t.contains("@") else { return false }
        if t.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil { return false }
        let lower = t.contains { $0.isLowercase }, upper = t.contains { $0.isUppercase }, digit = t.contains { $0.isNumber }
        let symbol = t.contains { "-_+/=.".contains($0) }
        guard [lower, upper, digit, symbol].filter({ $0 }).count >= 3, digit else { return false }
        return entropy(t) >= 3.5
    }

    static func entropy(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        s.forEach { counts[$0, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { r, c in let p = Double(c) / n; return r - p * log2(p) }
    }

    /// A pattern the user typed is valid when it compiles.
    static func validPattern(_ p: String) -> Bool { !p.isEmpty && (try? NSRegularExpression(pattern: p)) != nil }

    static func matchesUserPattern(_ s: String, _ patterns: [String]) -> Bool {
        let sample = s.count > 100_000 ? String(s.prefix(100_000)) : s
        let range = NSRange(sample.startIndex..., in: sample)
        return patterns.contains { p in
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return false }
            return re.firstMatch(in: sample, range: range) != nil
        }
    }

    enum Skip: Equatable { case own, concealed, excludedApp, secret, pattern, tooBig, empty }
    enum Decision: Equatable { case keep(ClipItem), skip(Skip) }

    /// What to do with what is on the clipboard now. Files win over text (Finder also puts the names as text), text over images
    /// (spreadsheets also put a picture of the cells).
    static func decide(_ s: ClipSnapshot, settings: ClipSettings, now: Date = Date()) -> Decision {
        if s.ours { return .skip(.own) }
        if isConcealed(s.types) { return .skip(.concealed) }
        if isExcluded(source: s.source, settings: settings) { return .skip(.excludedApp) }
        if !s.files.isEmpty {
            let item = ClipItem.files(s.files.map(\.path), date: now, source: s.source)
            return item.bytes > settings.maxItemBytes ? .skip(.tooBig) : .keep(item)
        }
        if let t = s.text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if settings.skipSecrets && (looksLikeCard(t) || looksLikeSecret(t)) { return .skip(.secret) }
            if !settings.patterns.isEmpty && matchesUserPattern(t, settings.patterns) { return .skip(.pattern) }
            let item = ClipItem.text(t, date: now, source: s.source)
            return item.bytes > settings.maxItemBytes ? .skip(.tooBig) : .keep(item)
        }
        if s.imageTooBig { return .skip(.tooBig) }
        if let png = s.image {
            guard png.count <= settings.maxItemBytes else { return .skip(.tooBig) }
            return .keep(.image(png: png, width: s.width, height: s.height, date: now, source: s.source))
        }
        return .skip(.empty)
    }
}

// MARK: - The list: duplicates, limits, search

struct ClipHistoryCore {
    var items: [ClipItem] = []           // newest first

    /// Adds an item; the same content again moves the existing one to the top (it keeps its id, star and stored image).
    /// Returns the item as it is now in the list.
    @discardableResult
    mutating func add(_ item: ClipItem) -> ClipItem {
        if let i = items.firstIndex(where: { $0.digest == item.digest && $0.kind == item.kind }) {
            var old = items.remove(at: i)
            old.date = item.date
            old.source = item.source ?? old.source
            if old.payload == nil { old.payload = item.payload }
            items.insert(old, at: 0)
            return old
        }
        items.insert(item, at: 0)
        return item
    }

    /// Applies the limits (age, count, total size) to what isn't a favorite, oldest first. Returns what was removed.
    @discardableResult
    mutating func prune(now: Date, settings: ClipSettings) -> [ClipItem] {
        var removed: [ClipItem] = []
        if settings.maxAgeHours > 0 {
            let limit = now.addingTimeInterval(-Double(settings.maxAgeHours) * 3600)
            removed += items.filter { !$0.pinned && $0.date < limit }
            items.removeAll { !$0.pinned && $0.date < limit }
        }
        func dropOldestUnpinned() -> Bool {
            guard let i = items.lastIndex(where: { !$0.pinned }) else { return false }
            removed.append(items.remove(at: i))
            return true
        }
        while items.filter({ !$0.pinned }).count > max(1, settings.maxItems), dropOldestUnpinned() {}
        while items.reduce(0, { $0 + $1.bytes }) > settings.maxTotalBytes, dropOldestUnpinned() {}
        return removed
    }

    /// Every word of the query must appear (any case, any accents) in the item's text, file names and paths, image description
    /// or what `describe` adds (kind, source app).
    static func matches(_ item: ClipItem, _ query: String, describe: (ClipItem) -> String = { _ in "" }) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return true }
        let hay: String
        switch item.kind {
        case .text: hay = item.text
        case .files: hay = (item.names + item.paths).joined(separator: "\n")
        case .image: hay = "\(item.width)×\(item.height) \(item.width)x\(item.height) png image"
        }
        let extra = describe(item)
        return words.allSatisfy { w in
            hay.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || extra.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    func filtered(_ query: String, favoritesOnly: Bool, describe: (ClipItem) -> String = { _ in "" }) -> [ClipItem] {
        items.filter { (!favoritesOnly || $0.pinned) && Self.matches($0, query, describe: describe) }
    }
}

// MARK: - Encryption and its key

enum ClipCrypto {
    static let magic = Data("CCLP".utf8)
    static let version: UInt8 = 1
    enum Failure: Error { case notOurs, unreadable }

    /// AES-GCM; the header and what the data is (the index, or which item's image) are authenticated too, so files can't be
    /// swapped between items unnoticed.
    static func seal(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        let header = magic + Data([version])
        let box = try AES.GCM.seal(data, using: key, authenticating: header + Data(context.utf8))
        guard let combined = box.combined else { throw Failure.unreadable }
        return header + combined
    }

    static func open(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        let header = magic + Data([version])
        guard data.count >= header.count + 28, data.prefix(header.count) == header else { throw Failure.notOurs }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(header.count)))
            return try AES.GCM.open(box, using: key, authenticating: header + Data(context.utf8))
        } catch { throw Failure.unreadable }
    }
}

protocol ClipKeyStore: AnyObject {
    func load() throws -> Data?
    func save(_ key: Data) throws
    func delete() throws
}

/// Tests' stand-in for the Keychain.
final class MemoryKeyStore: ClipKeyStore {
    var key: Data?
    var failing = false
    func load() throws -> Data? { if failing { throw KeychainKeyStore.Failure(status: errSecInteractionNotAllowed) }; return key }
    func save(_ k: Data) throws { if failing { throw KeychainKeyStore.Failure(status: errSecInteractionNotAllowed) }; key = k }
    func delete() throws { key = nil }
}

/// The history's key: a random 256-bit key made on this Mac, in the login Keychain, for this device only and never synced.
/// Its access list names the app by its signature: with the stable local signing identity updates keep access; with an ad-hoc
/// signature macOS asks again after each update (or is refused, and then nothing is saved).
final class KeychainKeyStore: ClipKeyStore {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)" }
    }
    let service: String, account: String
    let keychain: AnyObject?          // a specific keychain file (tests use a temporary one); nil: the login keychain

    init(service: String = "local.cocaine.clipboard", account: String = "history-key", keychain: AnyObject? = nil) {
        self.service = service; self.account = account; self.keychain = keychain
    }

    private func query(search: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let keychain { q[search ? kSecMatchSearchList as String : kSecUseKeychain as String] = search ? [keychain] : keychain }
        return q
    }

    func load() throws -> Data? {
        var q = query(search: true)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let d = out as? Data else { throw Failure(status: st) }
        return d
    }

    func save(_ key: Data) throws {
        try delete()
        var q = query(search: false)
        q[kSecValueData as String] = key
        q[kSecAttrLabel as String] = "Cocaine clipboard history"
        q[kSecAttrDescription as String] = "Encrypts the clipboard history saved on this Mac"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw Failure(status: st) }
    }

    func delete() throws {
        let st = SecItemDelete(query(search: true) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw Failure(status: st) }
    }
}

// MARK: - On disk

/// <dir>/index.ccl holds the list (texts and paths included), <dir>/<id>.img each image, all encrypted, 0600 in a 0700 folder,
/// written atomically. An unreadable index is set aside; a bad item doesn't lose the others.
final class ClipStore {
    static let schema = 1
    let dir: URL
    let keys: ClipKeyStore
    private var key: SymmetricKey?
    var index: URL { dir.appendingPathComponent("index.ccl") }

    static var defaultDir: URL {
        if let base = ProcessInfo.processInfo.environment["COCAINE_SUPPORT"], !base.isEmpty {
            return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("clipboard", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cocaine/clipboard", isDirectory: true)
    }

    init(dir: URL, keys: ClipKeyStore) { self.dir = dir; self.keys = keys }

    var unlocked: Bool { key != nil }

    /// Loads the key from the Keychain, or makes one. Throws when the Keychain can't be used: then nothing is written.
    func unlock() throws {
        if key != nil { return }
        if let d = try keys.load(), d.count == 32 { key = SymmetricKey(data: d); return }
        let k = SymmetricKey(size: .bits256)
        try keys.save(k.withUnsafeBytes { Data($0) })
        key = k
    }

    /// Forgets the key in memory (persistence off, files kept for next time).
    func lock() { key = nil }

    struct Index: Codable {
        var v: Int
        var items: [Lossy]
        struct Lossy: Codable {
            var item: ClipItem?
            init(_ i: ClipItem) { item = i }
            init(from decoder: Decoder) throws { item = try? ClipItem(from: decoder) }
            func encode(to encoder: Encoder) throws { try item?.encode(to: encoder) }
        }
    }

    enum LoadProblem: Equatable { case none, unreadableIndex, droppedItems(Int) }

    /// The saved items (images not read yet), and whether something had to be dropped.
    func load() -> (items: [ClipItem], problem: LoadProblem) {
        guard let key else { return ([], .none) }
        guard let raw = try? Data(contentsOf: index) else { removeOrphans(keeping: []); return ([], .none) }
        guard let plain = try? ClipCrypto.open(raw, key: key, context: "index"),
              let idx = try? JSONDecoder().decode(Index.self, from: plain), idx.v == Self.schema else {
            // Damaged, from another key (the Keychain item was deleted), or from a newer version: set aside, start empty.
            let aside = dir.appendingPathComponent("index.unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: index, to: aside)
            removeOrphans(keeping: [])
            return ([], .unreadableIndex)
        }
        var items: [ClipItem] = []
        var dropped = idx.items.filter { $0.item == nil }.count
        for case let i? in idx.items.map(\.item) {
            if i.kind == .image && !FileManager.default.fileExists(atPath: blob(i.id).path) { dropped += 1; continue }
            items.append(i)
        }
        removeOrphans(keeping: Set(items.map(\.id)))
        return (items, dropped > 0 ? .droppedItems(dropped) : .none)
    }

    func saveIndex(_ items: [ClipItem]) throws {
        guard let key else { return }
        let data = try JSONEncoder().encode(Index(v: Self.schema, items: items.map(Index.Lossy.init)))
        try write(try ClipCrypto.seal(data, key: key, context: "index"), to: index)
    }

    func writeImage(_ id: UUID, _ png: Data) throws {
        guard let key else { return }
        try write(try ClipCrypto.seal(png, key: key, context: "image:" + id.uuidString), to: blob(id))
    }

    func readImage(_ id: UUID) -> Data? {
        guard let key, let raw = try? Data(contentsOf: blob(id)) else { return nil }
        return try? ClipCrypto.open(raw, key: key, context: "image:" + id.uuidString)
    }

    func removeImage(_ id: UUID) { try? FileManager.default.removeItem(at: blob(id)) }

    /// Removes the folder and the Keychain key. Everything in it was encrypted with that key, so whatever the disk still keeps
    /// of those files is unreadable once the key is gone (overwriting in place isn't reliable on SSDs and APFS).
    func wipe() throws {
        key = nil
        var firstError: Error?
        if FileManager.default.fileExists(atPath: dir.path) {
            do { try FileManager.default.removeItem(at: dir) } catch { firstError = error }
        }
        do { try keys.delete() } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }

    func blob(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString + ".img") }

    private func removeOrphans(keeping ids: Set<UUID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in names where n.hasSuffix(".img") || n.hasPrefix(".tmp-") {
            if n.hasSuffix(".img"), let id = UUID(uuidString: String(n.dropLast(4))), ids.contains(id) { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    /// A private folder, a temp file that is 0600 from the start, synced, then renamed over the old one.
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let tmp = dir.appendingPathComponent(".tmp-" + UUID().uuidString)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let ok = data.withUnsafeBytes { p -> Bool in
            guard let base = p.baseAddress else { return true }
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, base + off, p.count - off)
                if n <= 0 { return false }
                off += n
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else { unlink(tmp.path); throw CocoaError(.fileWriteUnknown) }
    }
}

// MARK: - The clipboard itself

/// What was on the clipboard at one change.
struct ClipSnapshot {
    var changeCount = 0
    var types: [String] = []
    var source: String?
    var ours = false
    var text: String?
    var files: [URL] = []
    var image: Data?
    var width = 0, height = 0
    var imageTooBig = false
    var stale = false                 // it changed while being read
    var hasContent: Bool { text != nil || !files.isEmpty || image != nil || imageTooBig }
}

protocol ClipPasteboard: AnyObject {
    var changeCount: Int { get }
    /// Reads it (may be slow: call it off the main thread). `allowed` sees the types and source first: secrets aren't even read.
    func snapshot(maxImageBytes: Int, allowed: ([String], String?) -> Bool) -> ClipSnapshot
    /// Puts an item back, with the right types; returns the new change count, or nil.
    func write(_ item: ClipItem, payload: Data?) -> Int?
}

final class SystemPasteboard: ClipPasteboard {
    let pb: NSPasteboard
    init(_ pb: NSPasteboard) { self.pb = pb }
    var changeCount: Int { pb.changeCount }

    func snapshot(maxImageBytes: Int, allowed: ([String], String?) -> Bool) -> ClipSnapshot {
        var s = ClipSnapshot()
        s.changeCount = pb.changeCount
        s.types = pb.types?.map(\.rawValue) ?? []
        if s.types.contains(ClipRules.ownType) { s.ours = true; return s }
        if s.types.contains("org.nspasteboard.source") { s.source = pb.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")) }
        guard allowed(s.types, s.source) else { return s }
        let has = { (t: NSPasteboard.PasteboardType) in s.types.contains(t.rawValue) }
        if has(.fileURL), let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            s.files = urls
        } else if has(.string), let t = pb.string(forType: .string) {
            s.text = t
        } else if has(.rtf), let d = pb.data(forType: .rtf), let a = NSAttributedString(rtf: d, documentAttributes: nil) {
            s.text = a.string                                            // rich text: its plain text
        } else if has(.png) || has(.tiff) {
            // Image data only (promised files aren't fetched). TIFF is uncompressed, so it may be far bigger than its PNG.
            if has(.png), let d = pb.data(forType: .png) {
                if d.count > maxImageBytes { s.imageTooBig = true } else { s.image = d }
            } else if let d = pb.data(forType: .tiff) {
                if d.count > maxImageBytes * 8 { s.imageTooBig = true }
                else if let png = NSBitmapImageRep(data: d)?.representation(using: .png, properties: [:]) {
                    if png.count > maxImageBytes { s.imageTooBig = true } else { s.image = png }
                }
            }
            if let d = s.image, let src = CGImageSourceCreateWithData(d as CFData, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                s.width = p[kCGImagePropertyPixelWidth] as? Int ?? 0
                s.height = p[kCGImagePropertyPixelHeight] as? Int ?? 0
            } else if s.image != nil { s.image = nil }                  // not an image after all
        }
        s.stale = pb.changeCount != s.changeCount
        return s
    }

    func write(_ item: ClipItem, payload: Data?) -> Int? {
        let own = NSPasteboard.PasteboardType(ClipRules.ownType)
        switch item.kind {
        case .text:
            pb.clearContents()
            let it = NSPasteboardItem()
            it.setString(item.text, forType: .string)
            it.setData(Data(), forType: own)
            guard pb.writeObjects([it]) else { return nil }
        case .image:
            guard let png = payload, let rep = NSBitmapImageRep(data: png) else { return nil }
            pb.clearContents()
            let it = NSPasteboardItem()
            it.setData(png, forType: .png)
            if rep.pixelsWide * rep.pixelsHigh <= 12_000_000, let tiff = rep.tiffRepresentation { it.setData(tiff, forType: .tiff) }   // apps that read only TIFF
            it.setData(Data(), forType: own)
            guard pb.writeObjects([it]) else { return nil }
        case .files:
            let urls = item.paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return nil }
            pb.clearContents()
            guard pb.writeObjects(urls as [NSURL]) else { return nil }
            pb.setData(Data(), forType: own)
        }
        return pb.changeCount
    }
}

// MARK: - The history the island shows

final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory(defaults: .standard, dir: ClipStore.defaultDir, keys: KeychainKeyStore(), board: SystemPasteboard(.general))

    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var settings: ClipSettings
    @Published var paused = false { didSet { if paused != oldValue { seen = board.changeCount } } }   // nothing copied meanwhile is kept
    @Published var query = ""
    @Published var favoritesOnly = false
    @Published var hovered: UUID?                        // the island row under the pointer
    @Published private(set) var saving = false          // persistence on and working: the history is on disk
    @Published private(set) var problem: String?        // why it isn't saved, or what had to be dropped
    @Published private(set) var missing: Set<UUID> = []  // file references whose files are gone
    @Published private(set) var thumbs: [UUID: NSImage] = [:]

    var now: () -> Date = Date.init
    var frontApp: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    let board: ClipPasteboard
    let store: ClipStore
    private let defaults: UserDefaults
    private var core = ClipHistoryCore()
    private var seen: Int
    private var reading = false
    private var timer: Timer?
    private var ticks = 0
    private var saveWork: DispatchWorkItem?
    private var thumbsLoading: Set<UUID> = []
    private let reader = DispatchQueue(label: "local.cocaine.clipboard.read", qos: .utility)
    private let io = DispatchQueue(label: "local.cocaine.clipboard.io", qos: .utility)

    init(defaults: UserDefaults, dir: URL, keys: ClipKeyStore, board: ClipPasteboard) {
        self.defaults = defaults
        self.board = board
        store = ClipStore(dir: dir, keys: keys)
        settings = ClipSettings.load(defaults)
        seen = board.changeCount
    }

    var visible: [ClipItem] { core.filtered(query, favoritesOnly: favoritesOnly, describe: describe) }
    var running: Bool { timer != nil }

    // MARK: watching

    func start() {
        guard timer == nil else { return }
        seen = board.changeCount
        if settings.persist && !saving { openStore() }
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in self?.poll() }   // changeCount is cheap; the tolerance lets macOS batch wake-ups
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refreshMissing()
    }

    /// With the island off: a memory-only history is forgotten, a saved one stays on disk.
    func stop() {
        timer?.invalidate(); timer = nil
        if saving { flush() } else { replace([]) }
    }

    func poll() {
        ticks += 1
        if ticks % 86 == 0 { expire() }                           // about once a minute
        guard !paused else { seen = board.changeCount; return }
        guard !reading else { return }
        let c = board.changeCount
        guard c != seen else { return }
        seen = c
        read(attempt: 0)
    }

    /// Reads off the main thread (huge or slow pasteboards don't freeze the island). Content still arriving (types declared,
    /// data not yet there) is read again twice, a little later.
    private func read(attempt: Int, sync: Bool = false) {
        reading = true
        let s = settings, front = frontApp()
        let job = { [board] () -> ClipSnapshot in
            board.snapshot(maxImageBytes: s.maxItemBytes) { types, source in
                !ClipRules.isConcealed(types) && !ClipRules.isExcluded(source: source ?? front, settings: s)
            }
        }
        let finish = { [weak self] (snap: ClipSnapshot) in
            guard let self else { return }
            self.reading = false
            var snap = snap
            if snap.source == nil { snap.source = front }
            guard !snap.stale, !self.paused else { return }               // a newer change is next in line
            if !snap.hasContent, !snap.ours, !snap.types.isEmpty, attempt < 2, !ClipRules.isConcealed(snap.types),
               !ClipRules.isExcluded(source: snap.source, settings: s) {
                if sync { self.read(attempt: attempt + 1, sync: true); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, !self.reading, self.board.changeCount == snap.changeCount else { return }
                    self.read(attempt: attempt + 1)
                }
                return
            }
            self.take(snap)
        }
        if sync { finish(reader.sync(execute: job)) }
        else { reader.async { let snap = job(); DispatchQueue.main.async { finish(snap) } } }
    }

    /// Tests: read the (fake or private) pasteboard now, synchronously.
    func captureNow() {
        let c = board.changeCount
        guard c != seen, !paused else { return }
        seen = c
        read(attempt: 0, sync: true)
    }

    func take(_ snap: ClipSnapshot) {
        guard case .keep(let item) = ClipRules.decide(snap, settings: settings, now: now()) else { return }
        add(item)
    }

    func add(_ item: ClipItem) {
        let before = Set(core.items.map(\.id))
        let kept = core.add(item)
        let removed = core.prune(now: now(), settings: settings)
        if saving, !before.contains(kept.id), kept.kind == .image, let png = kept.payload, !removed.contains(where: { $0.id == kept.id }) {
            io.async { [store] in try? store.writeImage(kept.id, png) }
        }
        forget(removed)
        if saving { scheduleSave() }
        publish()
    }

    // MARK: actions

    /// Puts it back on the clipboard (not captured again) and moves it to the top.
    @discardableResult
    func copy(_ item: ClipItem) -> Bool {
        let payload = item.kind == .image ? imageData(item) : nil
        guard let c = board.write(item, payload: payload) else { return false }
        seen = c
        var moved = item
        moved.date = now()
        moved.payload = payload ?? item.payload
        core.add(moved)
        if saving { scheduleSave() }
        publish()
        return true
    }

    func togglePin(_ id: UUID) {
        guard let i = core.items.firstIndex(where: { $0.id == id }) else { return }
        core.items[i].pinned.toggle()
        forget(core.prune(now: now(), settings: settings))           // unpinning may put it over a limit
        if saving { scheduleSave() }
        publish()
    }

    func remove(_ id: UUID) {
        guard let i = core.items.firstIndex(where: { $0.id == id }) else { return }
        forget([core.items.remove(at: i)])
        if saving { scheduleSave() }
        publish()
    }

    /// Everything but the favorites.
    func clearHistory() {
        let gone = core.items.filter { !$0.pinned }
        core.items.removeAll { !$0.pinned }
        forget(gone)
        if saving { scheduleSave() }
        publish()
    }

    /// Everything, favorites included, plus the saved files and the Keychain key (also what is left from a time persistence
    /// was on). Persistence stays as it was: if on, it starts again with a new key. Returns false when something stayed.
    @discardableResult
    func deleteEverything() -> Bool {
        saveWork?.cancel(); saveWork = nil
        core.items = []
        thumbs = [:]
        query = ""
        var ok = true
        io.sync { [store] in do { try store.wipe() } catch { ok = false } }
        if saving {
            do { try io.sync { [store] in try store.unlock() } }
            catch { saving = false; settings.persist = false; settings.save(defaults); problem = keychainProblem(error) }
        }
        publish()
        return ok
    }

    func update(_ new: ClipSettings) {
        let old = settings
        var s = new
        s.persist = old.persist                                       // only through setPersist
        settings = s
        s.save(defaults)
        if s.excludedApps != old.excludedApps {                       // an app excluded now: what came from it goes
            let gone = core.items.filter { ClipRules.isExcluded(source: $0.source, settings: s) }
            core.items.removeAll { ClipRules.isExcluded(source: $0.source, settings: s) }
            forget(gone)
        }
        forget(core.prune(now: now(), settings: s))
        if saving { scheduleSave() }
        publish()
    }

    /// On: opens (or makes) the encrypted store and merges what is in memory with what was saved. Off: stops saving; `wipe`
    /// also deletes the files and the key, otherwise they stay (encrypted) for the next time it's turned on.
    func setPersist(_ on: Bool, wipe: Bool = false) {
        if on {
            settings.persist = true
            settings.save(defaults)
            openStore()
            return
        }
        saveWork?.cancel(); saveWork = nil
        if saving {
            flush()
            for i in core.items.indices where core.items[i].kind == .image && core.items[i].payload == nil {   // images read lazily stay usable
                let id = core.items[i].id
                core.items[i].payload = io.sync { [store] in store.readImage(id) }
            }
        }
        core.items.removeAll { $0.kind == .image && $0.payload == nil }
        saving = false
        settings.persist = false
        settings.save(defaults)
        problem = nil
        if wipe { io.sync { [store] in try? store.wipe() } } else { io.sync { [store] in store.lock() } }
        publish()
    }

    private func openStore() {
        do {
            try io.sync { [store] in try store.unlock() }
        } catch {
            // Never a silent fallback to plain files: without the key nothing is written.
            saving = false
            settings.persist = false
            settings.save(defaults)
            problem = keychainProblem(error)
            return
        }
        let loaded = io.sync { [store] in store.load() }
        switch loaded.problem {
        case .none: problem = nil
        case .unreadableIndex: problem = clipboardL("The saved history couldn't be read and was set aside.")
        case .droppedItems(let n): problem = String(format: clipboardL("%d saved items couldn't be read."), n)
        }
        let memory = core.items
        core.items = loaded.items.sorted { $0.date > $1.date }
        for m in memory.reversed() {                                   // what's in memory is newer; a star on either side stays
            let kept = core.add(m)
            if m.pinned, let i = core.items.firstIndex(where: { $0.id == kept.id }) { core.items[i].pinned = true }
        }
        core.items.sort { $0.date > $1.date }
        saving = true
        forget(core.prune(now: now(), settings: settings))
        for i in core.items where i.kind == .image {
            if let png = i.payload { io.async { [store] in if !FileManager.default.fileExists(atPath: store.blob(i.id).path) { try? store.writeImage(i.id, png) } } }
        }
        saveNow()
        publish()
        refreshMissing()
    }

    private func keychainProblem(_ error: Error) -> String {
        String(format: clipboardL("Can't use the Keychain (%@): the history stays in memory only."), "\(error)")
    }

    // MARK: limits, missing files, images

    /// Limits apply even when nothing new is copied (the age one above all).
    func expire() {
        let removed = core.prune(now: now(), settings: settings)
        if !removed.isEmpty {
            forget(removed)
            if saving { scheduleSave() }
            publish()
        }
        refreshMissing()
    }

    func refreshMissing() {
        let refs = core.items.filter { $0.kind == .files }.map { ($0.id, $0.paths) }
        guard !refs.isEmpty else { if !missing.isEmpty { missing = [] }; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let gone = Set(refs.filter { _, paths in paths.contains { !FileManager.default.fileExists(atPath: $0) } }.map(\.0))
            DispatchQueue.main.async { if let self, self.missing != gone { self.missing = gone } }
        }
    }

    /// Tests: the same, synchronously.
    func refreshMissingNow() {
        missing = Set(core.items.filter { $0.kind == .files && $0.paths.contains { !FileManager.default.fileExists(atPath: $0) } }.map(\.id))
    }

    /// The PNG, from memory or from its encrypted file.
    func imageData(_ item: ClipItem) -> Data? {
        if let p = core.items.first(where: { $0.id == item.id })?.payload ?? item.payload { return p }
        return saving ? io.sync { [store] in store.readImage(item.id) } : nil
    }

    /// A small picture for the row, made once, off the main thread.
    func thumbnail(_ item: ClipItem) -> NSImage? {
        if let t = thumbs[item.id] { return t }
        guard item.kind == .image, !thumbsLoading.contains(item.id) else { return nil }
        thumbsLoading.insert(item.id)
        let payload = core.items.first(where: { $0.id == item.id })?.payload ?? item.payload
        let saving = self.saving
        io.async { [weak self, store] in
            let data = payload ?? (saving ? store.readImage(item.id) : nil)
            var img: NSImage?
            if let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 96,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbsLoading.remove(item.id)
                if let img, self.core.items.contains(where: { $0.id == item.id }) { self.thumbs[item.id] = img }
            }
        }
        return nil
    }

    private static var appNames: [String: String] = [:]
    static func appName(_ bundle: String?) -> String? {
        guard let b = bundle, !b.isEmpty else { return nil }
        if let n = appNames[b] { return n }
        let n = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map { FileManager.default.displayName(atPath: $0.path) } ?? b
        let name = n.hasSuffix(".app") ? String(n.dropLast(4)) : n
        appNames[b] = name
        return name
    }

    /// What search also looks at: the kind's name and the source app.
    func describe(_ item: ClipItem) -> String {
        let kind = item.kind == .image ? clipboardL("Image") : item.kind == .files ? clipboardL("File") : ""
        return [kind, Self.appName(item.source) ?? ""].joined(separator: " ")
    }

    // MARK: saving

    private func publish() { items = core.items }

    private func forget(_ removed: [ClipItem]) {
        for r in removed {
            thumbs[r.id] = nil
            if saving && r.kind == .image { io.async { [store] in store.removeImage(r.id) } }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func saveNow() {
        saveWork = nil
        guard saving else { return }
        let list = core.items
        io.async { [weak self, store] in
            do { try store.saveIndex(list) } catch {
                DispatchQueue.main.async { self?.problem = clipboardL("Couldn't save the history.") + " " + error.localizedDescription }
            }
        }
    }

    /// Writes what's pending and waits for it (quit, tests).
    func flush() {
        if saveWork != nil { saveWork?.cancel(); saveNow() }
        io.sync {}
    }

    /// Tests and the render tool: a ready-made list, nothing captured or saved.
    func replace(_ list: [ClipItem]) {
        core.items = list
        thumbs = [:]
        publish()
    }
}
