// Who may read the AI context, and what they read: the settings of "AI context (MCP)" (off by default), the per-client consent
// (Allow / Allow once / Deny, stored decisions revocable in Settings → AI), the rate limits and the audit log. The log says
// when, which tool, what kind of request, how many items and bytes: NEVER any content, title or path (a 0600 file of JSON lines,
// bounded, plus the recent lines in memory for the Settings viewer).

import Combine
import Darwin
import Foundation

struct MCPSettings: Codable, Equatable {
    var enabled = false               // the master switch: the socket exists only while on
    var persistBasket = false         // keep the basket after a restart (a private file of references and typed text)
    var expiryHours = 8               // 0 = until cleared
    static let key = "mcp.v1"

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? false
        persistBasket = (try? c.decodeIfPresent(Bool.self, forKey: .persistBasket)).flatMap { $0 } ?? false
        let h = (try? c.decodeIfPresent(Int.self, forKey: .expiryHours)).flatMap { $0 } ?? 8
        expiryHours = AIContextLimits.expiryChoices.contains(h) ? h : 8
    }
    static func load(_ d: UserDefaults) -> MCPSettings {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(MCPSettings.self, from: $0) } ?? MCPSettings()
    }
    func save(_ d: UserDefaults) { if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) } }
}

/// An AI tool as Cocaine tells them apart: the name it gives (clientInfo) and the program that started the bridge. Both can be
/// faked by other programs of the same user, so this is a label for the user's decision, not an authentication.
struct MCPClientIdentity: Equatable, Hashable {
    var name: String                  // clientInfo.name, cleaned
    var program: String               // the bridge's parent executable path ("" when unknown)
    var fingerprint: String { name.lowercased() + "|" + program }
    var label: String {
        let prog = (program as NSString).lastPathComponent
        let n = name.isEmpty || name == "unknown" ? (prog.isEmpty ? "An AI tool" : prog) : name
        return prog.isEmpty || prog.caseInsensitiveCompare(n) == .orderedSame ? n : "\(n) (\(prog))"
    }
}

struct MCPConsentRecord: Codable, Equatable, Identifiable {
    enum Decision: String, Codable { case allow, deny }
    var id: String                    // the fingerprint
    var label: String
    var decision: Decision
    var date: Date
    var lastUsed: Date?
}

final class MCPConsentStore: ObservableObject {
    static let key = "mcp.consent.v1"
    static let maxRecords = 40
    static let onceLifetime: TimeInterval = 8 * 3600
    @Published private(set) var records: [MCPConsentRecord] = []
    private var once: [String: Date] = [:]           // fingerprint|session → when "Allow once" was given
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        records = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([MCPConsentRecord].self, from: $0) } ?? []
    }

    enum State: Equatable { case allowed, denied, ask }

    func state(_ c: MCPClientIdentity, session: String, now: Date = Date()) -> State {
        if let r = records.first(where: { $0.id == c.fingerprint }) { return r.decision == .allow ? .allowed : .denied }
        if let t = once[c.fingerprint + "|" + session], now.timeIntervalSince(t) < Self.onceLifetime { return .allowed }
        return .ask
    }

    func record(_ c: MCPClientIdentity, _ d: MCPConsentRecord.Decision, now: Date = Date()) {
        records.removeAll { $0.id == c.fingerprint }
        records.insert(MCPConsentRecord(id: c.fingerprint, label: c.label, decision: d, date: now), at: 0)
        records = Array(records.prefix(Self.maxRecords))
        save()
    }

    func allowOnce(_ c: MCPClientIdentity, session: String, now: Date = Date()) {
        once = once.filter { now.timeIntervalSince($0.value) < Self.onceLifetime }
        if once.count < 200 { once[c.fingerprint + "|" + session] = now }
    }

    func used(_ c: MCPClientIdentity, now: Date = Date()) {
        guard let i = records.firstIndex(where: { $0.id == c.fingerprint }) else { return }
        if let l = records[i].lastUsed, now.timeIntervalSince(l) < 60 { return }     // not a write per call
        records[i].lastUsed = now
        save()
    }

    /// Forgets a decision (and any "once" of that client): it is asked again next time.
    func revoke(_ id: String) {
        records.removeAll { $0.id == id }
        once = once.filter { !$0.key.hasPrefix(id + "|") }
        save()
    }

    func revokeAll() { records.removeAll(); once.removeAll(); save() }

    private func save() { if let d = try? JSONEncoder().encode(records) { defaults.set(d, forKey: Self.key) } }
}

/// Calls per client per minute, and how many questions can wait in the notch at once.
struct MCPRateLimiter {
    var perMinute = 60
    var requestsPerMinute = 4
    private var calls: [String: [Date]] = [:]

    mutating func allow(_ fingerprint: String, request: Bool = false, now: Date = Date()) -> Bool {
        let k = (request ? "req|" : "") + fingerprint
        var list = (calls[k] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard list.count < (request ? requestsPerMinute : perMinute) else { calls[k] = list; return false }
        list.append(now)
        calls[k] = list
        if calls.count > 500 { calls = calls.filter { !$0.value.isEmpty && now.timeIntervalSince($0.value.last!) < 60 } }
        return true
    }
}

struct MCPAuditEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: Date
    var client: String                // the label
    var action: String                // list, get, boards, board, request, resources…
    var outcome: String               // ok, denied, declined, no answer, rate limited, not found, error
    var items = 0
    var bytes = 0
}

/// The log: never content. Lines of JSON in a private file (0600), cut to its newest half past `maxBytes`.
final class MCPAuditLog: ObservableObject {
    static let maxRecent = 200
    static let maxBytes = 256 * 1024
    @Published private(set) var recent: [MCPAuditEntry] = []
    let file: URL?

    init(file: URL?) {
        self.file = file
        if let file, let d = FileManager.default.contents(atPath: file.path) {
            let lines = String(decoding: d, as: UTF8.self).split(separator: "\n").suffix(Self.maxRecent)
            recent = lines.reversed().compactMap { try? JSONDecoder.iso.decode(MCPAuditEntry.self, from: Data($0.utf8)) }
        }
    }

    func add(_ e: MCPAuditEntry) {
        recent.insert(e, at: 0)
        if recent.count > Self.maxRecent { recent.removeLast(recent.count - Self.maxRecent) }
        guard let file, var line = try? JSONEncoder.iso.encode(e) else { return }
        line.append(0x0A)
        var st = stat()
        if lstat(file.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { return }       // not ours: never written through
            if Int(st.st_size) + line.count > Self.maxBytes, let old = FileManager.default.contents(atPath: file.path) {
                let keep = old.suffix(Self.maxBytes / 2)
                let start = keep.firstIndex(of: 0x0A).map { keep.index(after: $0) } ?? keep.startIndex
                SafeFile.writePrivate(Data(keep[start...]) + line, to: file)
                return
            }
            let fd = open(file.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return }
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
        } else {
            SafeFile.writePrivate(line, to: file)
        }
    }

    func clear() {
        recent.removeAll()
        if let file { try? FileManager.default.removeItem(at: file) }
    }
}

extension JSONEncoder { static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
