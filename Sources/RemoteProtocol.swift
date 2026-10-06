import CryptoKit
import Darwin
import Foundation
import Security

// MARK: - Remote control protocol v2: authenticated, encrypted, replay-proof messages between the iPhone Shortcut and the Mac
//
// The iPhone side is an Apple Shortcut, which has no encryption or HMAC action, only "Generate Hash" (SHA-256/512), Base64,
// URL decoding and regular-expression replacement. Everything below is built from those, so the Shortcut can compute the
// very same thing (see RemoteShortcut.swift):
//   • MAC(m)    = SHA256hex(macOut ‖ SHA256hex(macIn ‖ m)), each key 64 hex characters = exactly one SHA-256 block
//                 (a nested keyed hash with block-sized keys, like HMAC/NMAC: no length extension).
//   • keystream = SHA512hex(enc ‖ "|dir|nonce|ts|i") for i = 0, 1, …, enc 128 hex characters = one SHA-512 block;
//                 the content's bits are XORed with it (a stream cipher), and the MAC covers the ciphertext.
// The relay only ever sees ciphertext, the pairing id, a random nonce and a timestamp.
//
// Command (phone → Mac):  c2.<id>.<nonce>.<ts>.<ct>.<tag>
//   ct  = 682 base64url symbols = 4092 bits: the Base64 of "command\n", padded with "A" (zero bits), XOR keystream("c")
//   tag = MAC("c2|id|nonce|ts|ct")
// Reply (Mac → phone):    r2.<nonce>.<ts>.<bits>.<ct>.<tag>
//   ct  = the UTF-8 answer (space-padded to a multiple of 3 bytes) XOR keystream("r", the request's nonce), base64url
//   tag = MAC("r2|id|nonce|ts|bits|ct"): bound to the pairing and to the request it answers.

/// One paired iPhone. The topics are random secrets on the relay; v2 pairings also carry a 256-bit key.
struct Pairing: Codable, Equatable {
    var id: String
    var cmd: String        // the phone publishes commands here
    var reply: String      // the Mac publishes answers here
    var tier: String       // "basic" or "agents": what the commands may do (the gate in remote.zsh enforces it)
    var relay: String      // the server it was made for: later changes to the setting never move existing secrets
    var v: Int? = nil      // protocol version: nil (old, plain-text Shortcuts) or 2
    var key: String? = nil // v2: the pairing's master key, 64 hex characters
    var created: Double? = nil
    var expires: Double? = nil

    /// Made before v2: its Shortcut sends plain, unauthenticated text.
    /// (A v2 pairing whose key can't be read is not legacy: it is broken and answers nothing.)
    var isLegacy: Bool { (v ?? 1) < 2 }
    var keys: RemoteKeys? { key.flatMap(RemoteKeys.init(masterHex:)) }
    func expired(at now: Date) -> Bool { expires.map { now.timeIntervalSince1970 >= $0 } ?? false }

    /// A new v2 pairing: 192-bit random topics, a 256-bit key, valid for `RemoteProtocol.lifetime`.
    static func make(tier: String, relay: String, now: Date = Date()) -> Pairing? {
        guard let id = RemoteCrypto.random(8), let c = RemoteCrypto.random(24), let r = RemoteCrypto.random(24),
              let k = RemoteCrypto.random(32) else { return nil }
        let t = now.timeIntervalSince1970
        return Pairing(id: id, cmd: "cc" + c, reply: "cr" + r, tier: tier == "agents" ? "agents" : "basic", relay: relay,
                       v: 2, key: k, created: t, expires: t + RemoteProtocol.lifetime)
    }
}

/// The working keys derived from a pairing's master key (HKDF-SHA256). The Shortcut carries these, not the master.
struct RemoteKeys: Equatable {
    let enc: String      // 128 hex characters
    let macIn: String    // 64
    let macOut: String   // 64

    init?(masterHex: String) {
        guard let master = RemoteCrypto.bytes(hex: masterHex), master.count == 32 else { return nil }
        func derive(_ label: String, _ count: Int) -> String {
            let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: master), salt: Data("cocaine-remote-v2".utf8),
                                           info: Data(label.utf8), outputByteCount: count)
            return k.withUnsafeBytes { RemoteCrypto.hex(Data($0)) }
        }
        enc = derive("enc", 64)
        macIn = derive("mac-in", 32)
        macOut = derive("mac-out", 32)
    }
}

enum RemoteCrypto {
    static let std = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    static let url = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func bytes(hex: String) -> Data? {
        let c = Array(hex.utf8)
        guard c.count % 2 == 0 else { return nil }
        var out = Data(capacity: c.count / 2)
        var i = 0
        while i < c.count {
            guard let b = UInt8(String(decoding: c[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b); i += 2
        }
        return out
    }
    static func random(_ count: Int) -> String? {
        var b = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &b) == errSecSuccess else { return nil }
        return hex(Data(b))
    }
    static func sha256(_ s: String) -> String { hex(Data(SHA256.hash(data: Data(s.utf8)))) }
    static func sha512(_ s: String) -> String { hex(Data(SHA512.hash(data: Data(s.utf8)))) }

    static func mac(_ m: String, _ k: RemoteKeys) -> String { sha256(k.macOut + sha256(k.macIn + m)) }

    /// Constant-time comparison of two hex tags (case-insensitive).
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased().utf8), y = Array(b.lowercased().utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }

    /// `count` keystream bits (0/1), most significant bit of each hex digit first.
    static func keystream(_ k: RemoteKeys, dir: String, nonce: String, ts: String, bits count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count + 512)
        var i = 0
        while out.count < count {
            for c in sha512(k.enc + "|\(dir)|\(nonce)|\(ts)|\(i)").utf8 {
                let v = Int(c >= 97 ? c - 87 : c - 48)
                for s in [3, 2, 1, 0] { out.append(UInt8((v >> s) & 1)) }
            }
            i += 1
        }
        return Array(out.prefix(count))
    }

    static func bits(symbols: String, alphabet: [Character]) -> [UInt8]? {
        var index: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { index[c] = i }
        var out: [UInt8] = []
        out.reserveCapacity(symbols.count * 6)
        for c in symbols {
            guard let v = index[c] else { return nil }
            for s in [5, 4, 3, 2, 1, 0] { out.append(UInt8((v >> s) & 1)) }
        }
        return out
    }
    static func symbols(bits: [UInt8], alphabet: [Character]) -> String {
        var s = ""
        var i = 0
        while i + 6 <= bits.count {
            var v = 0
            for j in 0..<6 { v = v << 1 | Int(bits[i + j]) }
            s.append(alphabet[v]); i += 6
        }
        return s
    }
    static func bits(bytes: Data) -> [UInt8] { bytes.flatMap { b in (0..<8).reversed().map { UInt8((b >> $0) & 1) } } }
    static func bytes(bits: [UInt8]) -> Data {
        var d = Data()
        var i = 0
        while i + 8 <= bits.count {
            var v: UInt8 = 0
            for j in 0..<8 { v = v << 1 | bits[i + j] }
            d.append(v); i += 8
        }
        return d
    }
    static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] { zip(a, b).map { $0 ^ $1 } }
}

/// Why a message was not accepted (for the log and for tests; never sent back to an unauthenticated sender).
enum RemoteReject: String, Error, Equatable {
    case malformed, wrongPairing, badTag, badContent, tooLong, stale, future, replay, state, revoked, unauthenticated, expired

    /// The reason code written to remote-phone.log.
    var code: String {
        switch self {
        case .malformed: return "malformed"
        case .wrongPairing: return "unknown-pairing"
        case .badTag: return "bad-tag"
        case .badContent: return "decrypt-failed"
        case .tooLong: return "too-long"
        case .stale: return "stale"
        case .future: return "future"
        case .replay: return "replay"
        case .state: return "state-not-saved"
        case .revoked: return "revoked"
        case .unauthenticated: return "unauthenticated"
        case .expired: return "expired"
        }
    }
}

struct OpenedCommand: Equatable {
    let text: String
    let nonce: String
    let ts: String
    let date: Date
}

enum RemoteProtocol {
    static let commandBits = 4092                 // 682 symbols; the Shortcut pads every command to this (hides its length)
    static let commandBlocks = 8                  // SHA-512 blocks of keystream the Shortcut computes for a command
    static let replyBlocks = 44                   // …and for an answer: 22528 bits
    static let maxReplyBytes = 2805               // a multiple of 3, ≤ 22528/8, and the message stays under ntfy's 4096 bytes
    static let maxCommandBytes = 500
    static let maxLine = 2048
    static let skew: Double = 120                 // how far ahead of the Mac's clock the phone's may be
    static let lifetime: Double = 180 * 86_400    // a pairing expires after 180 days

    private static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    // MARK: timestamps: ISO 8601 as the Shortcut's "Format Date" writes it, made URL-safe ("+" → "p", no fractions)

    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)                  // 2026-10-05T12:03:12Z
    }

    static func date(_ ts: String) -> Date? {
        guard ts.utf8.count <= 32,
              let r = try? NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):?(\d{2}):?(\d{2})(Z|[p+-](\d{2}):?(\d{2}))?$"#),
              let m = r.firstMatch(in: ts, range: NSRange(location: 0, length: (ts as NSString).length)) else { return nil }
        func g(_ i: Int) -> Int? {
            let range = m.range(at: i)
            guard range.location != NSNotFound else { return nil }
            return Int((ts as NSString).substring(with: range))
        }
        guard let y = g(1), let mo = g(2), let d = g(3), let h = g(4), let mi = g(5), let s = g(6),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61 else { return nil }
        var zone = TimeZone.current                  // no zone written: the phone's clock is local, like the Mac's
        if m.range(at: 7).location != NSNotFound {
            let z = (ts as NSString).substring(with: m.range(at: 7))
            if z == "Z" { zone = TimeZone(identifier: "UTC")! } else {
                guard let zh = g(8), let zm = g(9), zh <= 14, zm < 60 else { return nil }
                let secs = (zh * 3600 + zm * 60) * (z.hasPrefix("-") ? -1 : 1)
                guard let tz = TimeZone(secondsFromGMT: secs) else { return nil }
                zone = tz
            }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let comps = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        guard let date = cal.date(from: comps), cal.component(.day, from: date) == d else { return nil }   // no 31 February
        return date
    }

    // MARK: commands

    /// What the Shortcut does (used by tests and the relay test): seal a command.
    static func sealCommand(_ text: String, pairingID: String, keys: RemoteKeys, nonce: String, ts: String) -> String {
        let b64 = Data((text + "\n").utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        var bits = RemoteCrypto.bits(symbols: b64, alphabet: RemoteCrypto.std) ?? []
        bits = Array((bits + [UInt8](repeating: 0, count: commandBits)).prefix(commandBits))
        let ct = RemoteCrypto.symbols(bits: RemoteCrypto.xor(bits, RemoteCrypto.keystream(keys, dir: "c", nonce: nonce, ts: ts, bits: commandBits)),
                                      alphabet: RemoteCrypto.url)
        let tag = RemoteCrypto.mac("c2|\(pairingID)|\(nonce)|\(ts)|\(ct)", keys)
        return "c2.\(pairingID).\(nonce).\(ts).\(ct).\(tag)"
    }

    static func isV2Command(_ line: String) -> Bool { line.hasPrefix("c2.") }

    /// What a message looks like, for the log: its form only (field count and lengths, which check failed), never its
    /// content. Everything here is also visible to the relay.
    static func shape(_ line: String) -> String {
        guard isV2Command(line) else { return "plain text, \(line.utf8.count) bytes" }
        let p = line.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var s = "\(p.count) fields, lengths " + p.map { String($0.utf8.count) }.joined(separator: "/")
        guard p.count == 6 else { return s + " (expected 6 fields: c2.id.nonce.time.ciphertext.tag)" }
        var bad: [String] = []
        if !matches(p[1], "^[0-9a-f]{16}$") { bad.append("id") }
        if !matches(p[2], "^[0-9]{18,40}$") { bad.append("nonce") }
        if date(p[3]) == nil { bad.append("time") }
        if !matches(p[4], "^[A-Za-z0-9_-]{682}$") { bad.append("ciphertext") }
        if !matches(p[5], "^[0-9a-fA-F]{64}$") { bad.append("tag") }
        if !bad.isEmpty { s += " (bad " + bad.joined(separator: ", ") + ")" }
        return s
    }

    /// Checks a command's form and tag, then decrypts it. No policy here (age, replay): see RemoteGatekeeper.
    static func openCommand(_ line: String, pairingID: String, keys: RemoteKeys) -> Result<OpenedCommand, RemoteReject> {
        guard line.utf8.count <= maxLine else { return .failure(.malformed) }
        let p = line.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 6, p[0] == "c2", matches(p[1], "^[0-9a-f]{16}$"), matches(p[2], "^[0-9]{18,40}$"),
              matches(p[4], "^[A-Za-z0-9_-]{682}$"), matches(p[5], "^[0-9a-fA-F]{64}$") else { return .failure(.malformed) }
        guard p[1] == pairingID else { return .failure(.wrongPairing) }
        guard let date = date(p[3]) else { return .failure(.malformed) }
        let m = "c2|\(p[1])|\(p[2])|\(p[3])|\(p[4])"
        // The phone's inner hash is lowercase hex; accept upper case too in case a Shortcuts version prints it so.
        let inner = RemoteCrypto.sha256(keys.macIn + m)
        guard RemoteCrypto.same(RemoteCrypto.sha256(keys.macOut + inner), p[5])
                || RemoteCrypto.same(RemoteCrypto.sha256(keys.macOut + inner.uppercased()), p[5]) else { return .failure(.badTag) }
        guard let ctBits = RemoteCrypto.bits(symbols: p[4], alphabet: RemoteCrypto.url) else { return .failure(.malformed) }
        let plain = RemoteCrypto.xor(ctBits, RemoteCrypto.keystream(keys, dir: "c", nonce: p[2], ts: p[3], bits: commandBits))
        let b64 = String(RemoteCrypto.symbols(bits: plain, alphabet: RemoteCrypto.std).prefix(680))
        guard var data = Data(base64Encoded: b64) else { return .failure(.badContent) }
        while data.last == 0 { data.removeLast() }
        // The Shortcut ends every command with a newline: without it the command was cut (longer than fits).
        guard data.last == 0x0A else { return .failure(.tooLong) }
        data.removeLast()
        guard data.count <= maxCommandBytes, let text = String(data: data, encoding: .utf8), !text.isEmpty,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(data.count > maxCommandBytes ? .tooLong : .badContent)
        }
        return .success(OpenedCommand(text: text, nonce: p[2], ts: p[3], date: date))
    }

    // MARK: replies

    /// The answer, cut to fit (on a character boundary) and padded with spaces to a multiple of 3 bytes.
    static func replyBytes(_ text: String) -> Data {
        var out = Data()
        for ch in text {
            let b = Data(String(ch).utf8)
            if out.count + b.count > maxReplyBytes { break }
            out.append(b)
        }
        if out.isEmpty { out = Data("OK".utf8) }
        while out.count % 3 != 0 { out.append(0x20) }
        return out
    }

    static func sealReply(_ text: String, pairingID: String, keys: RemoteKeys, nonce: String, now: Date) -> String {
        let ts = timestamp(now)
        let bits = RemoteCrypto.bits(bytes: replyBytes(text))
        let ct = RemoteCrypto.symbols(bits: RemoteCrypto.xor(bits, RemoteCrypto.keystream(keys, dir: "r", nonce: nonce, ts: ts, bits: bits.count)),
                                      alphabet: RemoteCrypto.url)
        let tag = RemoteCrypto.mac("r2|\(pairingID)|\(nonce)|\(ts)|\(bits.count)|\(ct)", keys)
        return "r2.\(nonce).\(ts).\(bits.count).\(ct).\(tag)"
    }

    /// What the Shortcut does with an answer (for tests): nil unless it is a genuine answer to `nonce`.
    static func openReply(_ line: String, pairingID: String, keys: RemoteKeys, nonce: String) -> String? {
        let p = line.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 6, p[0] == "r2", p[1] == nonce, let n = Int(p[3]), n > 0, n % 24 == 0, n <= replyBlocks * 512,
              matches(p[4], "^[A-Za-z0-9_-]+$"), p[4].count * 6 == n,
              RemoteCrypto.same(RemoteCrypto.mac("r2|\(pairingID)|\(nonce)|\(p[2])|\(p[3])|\(p[4])", keys), p[5]),
              let bits = RemoteCrypto.bits(symbols: p[4], alphabet: RemoteCrypto.url) else { return nil }
        let plain = RemoteCrypto.bytes(bits: RemoteCrypto.xor(bits, RemoteCrypto.keystream(keys, dir: "r", nonce: nonce, ts: p[2], bits: n)))
        return String(decoding: plain, as: UTF8.self).replacingOccurrences(of: " +$", with: "", options: .regularExpression)
    }
}

// MARK: - What has already been run, on disk: survives restarts and crashes

/// Remembers, per pairing, every nonce accepted within the last `retention` seconds (older messages are refused by age
/// anyway), plus where each relay connection should resume. Each change is written atomically (temporary file, fsync,
/// rename) under a lock that also serializes threads and processes. If the file is unreadable (damaged), a floor is set
/// at "now": nothing sent before it is accepted, so a damaged file can't reopen old commands to replay.
final class RemoteReplayStore {
    struct State: Codable, Equatable {
        var floor: Double = 0
        var seen: [String: [String: Double]] = [:]       // pairing → nonce → forget after
        var legacy: [String: [String: Double]] = [:]     // pairing → relay message id → forget after (old Shortcuts)
        var cursor: [String: Int] = [:]                  // pairing → newest relay time handled
    }
    enum Claim: Equatable { case fresh, duplicate, failed }

    static let retention: Double = 45 * 60              // ≥ the longest accepted age (20 min with wake-ups) + clock skew
    static let maxPerPairing = 5000

    let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    /// Runs `body` on the current state under the lock; writes the state back if `body` changed it. nil: it couldn't be
    /// locked, or a change couldn't be saved (the caller must then act as if nothing was recorded).
    private func update<T>(now: Double, _ body: (inout State) -> (T, Bool)) -> T? {
        lock.lock(); defer { lock.unlock() }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockFD = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { return nil }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { return nil }
        defer { _ = flock(lockFD, LOCK_UN) }
        var state: State
        var dirty = false
        if let data = try? Data(contentsOf: url) {
            if let s = try? JSONDecoder().decode(State.self, from: data) { state = s } else {
                state = State(floor: now)                    // damaged: refuse anything sent before now
                dirty = true
            }
        } else if access(url.path, F_OK) == 0 || errno != ENOENT {
            state = State(floor: now)                        // there but unreadable (permissions, I/O): same as damaged
            dirty = true
        } else {
            state = State()                                  // first use
        }
        let (result, changed) = body(&state)
        if changed || dirty {
            for (k, v) in state.seen { state.seen[k] = v.filter { $0.value > now } }
            for (k, v) in state.legacy { state.legacy[k] = v.filter { $0.value > now } }
            guard write(state) else { return changed ? nil : result }
        }
        return result
    }

    private func write(_ state: State) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        let tmp = url.path + ".tmp"
        let fd = open(tmp, O_CREAT | O_TRUNC | O_WRONLY, 0o600)
        guard fd >= 0 else { return false }
        let ok = data.withUnsafeBytes { p in Darwin.write(fd, p.baseAddress, data.count) == data.count } && fsync(fd) == 0
        close(fd)
        guard ok, rename(tmp, url.path) == 0 else { unlink(tmp); return false }
        let dfd = open(url.deletingLastPathComponent().path, O_RDONLY)
        if dfd >= 0 { _ = fsync(dfd); close(dfd) }
        return true
    }

    /// Records a nonce before its command runs: `.fresh` exactly once per nonce (within the retention). Anything sent at
    /// or before the floor is a duplicate. `.failed` (couldn't save) means: don't run it.
    func claim(pairing: String, nonce: String, sentAt: Double, now: Double) -> Claim {
        update(now: now) { s -> (Claim, Bool) in
            if sentAt <= s.floor { return (.duplicate, false) }
            var mine = s.seen[pairing] ?? [:]
            if let until = mine[nonce], until > now { return (.duplicate, false) }
            mine = mine.filter { $0.value > now }
            guard mine.count < Self.maxPerPairing else { return (.failed, false) }
            mine[nonce] = max(sentAt, now) + Self.retention
            s.seen[pairing] = mine
            return (.fresh, true)
        } ?? .failed
    }

    /// The same for old Shortcuts, which have no nonce: the relay's message id (weaker: the relay can change it).
    func claimLegacy(pairing: String, id: String, now: Double) -> Claim {
        update(now: now) { s -> (Claim, Bool) in
            var mine = s.legacy[pairing] ?? [:]
            if let until = mine[id], until > now { return (.duplicate, false) }
            mine = mine.filter { $0.value > now }
            guard mine.count < Self.maxPerPairing else { return (.failed, false) }
            mine[id] = now + Self.retention
            s.legacy[pairing] = mine
            return (.fresh, true)
        } ?? .failed
    }

    func cursor(_ pairing: String, now: Double) -> Int? {
        update(now: now) { s in (s.cursor[pairing], false) } ?? nil
    }

    func advance(_ pairing: String, to time: Int, now: Double) {
        _ = update(now: now) { s -> (Bool, Bool) in
            guard time > (s.cursor[pairing] ?? 0) else { return (true, false) }
            s.cursor[pairing] = time
            return (true, true)
        }
    }

    /// Drops everything kept for pairings no longer in `ids` (after a revoke). Their nonces are gone, so a floor at "now"
    /// keeps what they sent before from running if the pairing comes back (a phones.json read again after a failed read).
    func forget(keeping ids: Set<String>, now: Double) {
        _ = update(now: now) { s -> (Bool, Bool) in
            let before = s
            s.seen = s.seen.filter { ids.contains($0.key) }
            s.legacy = s.legacy.filter { ids.contains($0.key) }
            s.cursor = s.cursor.filter { ids.contains($0.key) }
            if s != before { s.floor = max(s.floor, now) }
            return (true, s != before)
        }
    }

    func snapshot() -> State? {
        lock.lock(); defer { lock.unlock() }
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }
}

// MARK: - The decision for one message from the relay

enum RemoteDecision: Equatable {
    case run(command: String, tier: String, nonce: String?)   // nonce nil: an old Shortcut, answer in plain text
    case answer(String, nonce: String, why: RemoteReject)    // an authenticated answer without running anything
    case notice(String)                                      // plain text to an old Shortcut: it must be replaced
    case drop(RemoteReject)
}

enum RemoteGatekeeper {
    /// Everything that decides whether a message runs. `maxAge`: how old a command may be (longer with wake-ups);
    /// `legacyUntil`: until when the user allowed old, unauthenticated Shortcuts (basic commands only).
    static func evaluate(text raw: String, eventID: String, eventTime: Int, pairing: Pairing, active: Bool, now: Date,
                         maxAge: Double, legacyUntil: Date?, store: RemoteReplayStore,
                         expiredText: String, noticeText: String) -> RemoteDecision {
        guard active else { return .drop(.revoked) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= RemoteProtocol.maxLine else { return .drop(.malformed) }
        let t = now.timeIntervalSince1970
        if let keys = pairing.keys, !pairing.isLegacy {
            guard RemoteProtocol.isV2Command(text) else { return .drop(.unauthenticated) }
            let opened: OpenedCommand
            switch RemoteProtocol.openCommand(text, pairingID: pairing.id, keys: keys) {
            case .success(let o): opened = o
            case .failure(let e):
                // Only errors found after the tag checked out (so from the genuine phone) are answered, once per nonce.
                if e == .tooLong || e == .badContent, let n = nonce(text), let sent = sentAt(text),
                   t - sent <= maxAge, sent - t <= RemoteProtocol.skew {
                    guard store.claim(pairing: pairing.id, nonce: n, sentAt: sent, now: t) == .fresh else { return .drop(.replay) }
                    return .answer(e == .tooLong ? "cocaine: command too long (\(RemoteProtocol.maxCommandBytes) bytes at most)"
                                                 : "cocaine: unreadable command", nonce: n, why: e)
                }
                return .drop(e)
            }
            let sent = opened.date.timeIntervalSince1970
            if sent - t > RemoteProtocol.skew { return .drop(.future) }
            if t - sent > maxAge { return .drop(.stale) }
            switch store.claim(pairing: pairing.id, nonce: opened.nonce, sentAt: sent, now: t) {
            case .duplicate: return .drop(.replay)
            case .failed: return .drop(.state)
            case .fresh: break
            }
            if pairing.expired(at: now) { return .answer(expiredText, nonce: opened.nonce, why: .expired) }
            return .run(command: opened.text, tier: pairing.tier == "agents" ? "agents" : "basic", nonce: opened.nonce)
        }
        guard pairing.isLegacy else { return .drop(.malformed) }   // v2 with a damaged key: never falls back to plain text
        // An old Shortcut: plain text, no key. Never anything that runs code, and only while the user allows it.
        if RemoteProtocol.isV2Command(text) { return .drop(.unauthenticated) }
        if t - Double(eventTime) > maxAge || Double(eventTime) - t > RemoteProtocol.skew { return .drop(.stale) }
        if let until = legacyUntil, until > now {
            switch store.claimLegacy(pairing: pairing.id, id: eventID, now: t) {
            case .duplicate: return .drop(.replay)
            case .failed: return .drop(.state)
            case .fresh: return .run(command: String(text.prefix(RemoteProtocol.maxCommandBytes)), tier: "basic", nonce: nil)
            }
        }
        // Tell the phone (at most every 10 minutes) that its Shortcut must be replaced.
        guard store.claimLegacy(pairing: pairing.id, id: "notice-\(Int(t) / 600)", now: t) == .fresh else { return .drop(.unauthenticated) }
        return .notice(noticeText)
    }

    private static func fields(_ line: String) -> [Substring] { line.split(separator: ".", omittingEmptySubsequences: false) }
    private static func nonce(_ line: String) -> String? {
        let p = fields(line)
        guard p.count == 6, p[2].range(of: "^[0-9]{18,40}$", options: .regularExpression) != nil else { return nil }
        return String(p[2])
    }
    /// When a v2 message says it was sent (its form only; nil if unreadable). For the log and the age checks.
    static func sentAt(_ line: String) -> Double? {
        let p = fields(line)
        return p.count == 6 ? RemoteProtocol.date(String(p[3]))?.timeIntervalSince1970 : nil
    }
}
