// Approving an AI agent's request from the notch, through the tools' own documented hook protocols only:
//   Claude Code: the PermissionRequest hook (decision allow/deny) and the Elicitation hook (an MCP server's question:
//   accept with content, decline or cancel). Codex: its PermissionRequest hook (decision allow/deny).
// The hook (this same binary, `Cocaine --agent-request <tool>`) sends the request over a Unix socket that only this user can
// open and waits for the app's answer, which carries an HMAC made with a per-install key; anything else (app not running,
// socket error, bad signature, timeout, expired request, "answer in the terminal") prints nothing, and the tool goes on with
// its own prompt in the terminal. Nothing is ever approved automatically.

import AppKit
import CommonCrypto
import Darwin

enum ApprovalTiming {
    static let app: TimeInterval = 120          // how long the notch holds a request before handing it back to the terminal
    static let hook: TimeInterval = 135         // how long the hook waits for the app (a little longer: the app answers first)
    static let config = "150"                   // the tool's own timeout for the hook (seconds), after which it goes on anyway
}

enum AgentPaths {
    /// Cocaine's private folder (0700); COCAINE_SUPPORT (as for the engine scripts) moves it, for tests.
    static func support(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let s = env["COCAINE_SUPPORT"], s.hasPrefix("/") { return URL(fileURLWithPath: s, isDirectory: true) }
        return AgentBoard.directory
    }
    static func socket(_ dir: URL) -> String { dir.appendingPathComponent("agents.sock").path }
    static func key(_ dir: URL) -> String { dir.appendingPathComponent("agents.key").path }
}

/// The per-install secret that signs the app's answers. 32 random bytes, hex, in a 0600 file of the user's.
enum ApprovalKey {
    /// The key if the file is safe to trust: a regular file (not a link), the user's, readable by nobody else.
    static func read(_ path: String) -> Data? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count == 64, let d = Data(hex: hex) else { return nil }
        return d
    }

    /// The app's side: the existing key, or a new one (also when the old file is unsafe).
    static func loadOrCreate(_ path: String) -> Data? {
        if let k = read(path) { return k }
        var b = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess else { return nil }
        let d = Data(b)
        unlink(path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let hex = Array(d.hex.utf8)
        guard write(fd, hex, hex.count) == hex.count else { return nil }
        return d
    }
}

extension Data {
    init?(hex: String) {
        var out = [UInt8](); out.reserveCapacity(hex.count / 2)
        var it = hex.utf8.makeIterator()
        while let a = it.next() {
            guard let b = it.next(), let x = UInt8(String(decoding: [a, b], as: UTF8.self), radix: 16) else { return nil }
            out.append(x)
        }
        self.init(out)
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

enum ApprovalWire {
    static func random(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).hex
    }

    static func mac(key: Data, id: String, nonce: String, decision: String, content: String?) -> String {
        let msg = Array("cocaine-approval-v1\n\(id)\n\(nonce)\n\(decision)\n\(content ?? "")".utf8)
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { k in CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), k.baseAddress, key.count, msg, msg.count, &out) }
        return Data(out).hex
    }

    static func equal(_ a: String, _ b: String) -> Bool {          // constant time
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The app's signed answer, one line.
    static func answer(key: Data, id: String, nonce: String, decision: String, content: String?) -> Data {
        var o: [String: Any] = ["id": id, "decision": decision, "mac": mac(key: key, id: id, nonce: nonce, decision: decision, content: content)]
        if let content { o["content"] = content }
        return ((try? JSONSerialization.data(withJSONObject: o)) ?? Data()) + Data([0x0A])
    }

    static let permissionDecisions: Set<String> = ["allow", "deny"]
    static let elicitationDecisions: Set<String> = ["accept", "decline", "cancel"]

    /// What the hook prints for the app's answer: the documented hook output, or nil (no decision: the tool asks as usual).
    /// The answer must be for this request (id), signed with the key over this request's nonce, and valid for the event.
    static func hookOutput(answer line: Data, key: Data, id: String, nonce: String, event: String) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              o["id"] as? String == id, let decision = o["decision"] as? String, let mac = o["mac"] as? String else { return nil }
        let content = o["content"] as? String
        guard equal(mac, Self.mac(key: key, id: id, nonce: nonce, decision: decision, content: content)) else { return nil }
        var out: [String: Any]
        if event == "Elicitation" {
            guard elicitationDecisions.contains(decision) else { return nil }
            out = ["hookEventName": "Elicitation", "action": decision]
            if decision == "accept" {
                guard let c = content, let obj = try? JSONSerialization.jsonObject(with: Data(c.utf8)) as? [String: Any] else { return nil }
                out["content"] = obj
            }
        } else {
            guard permissionDecisions.contains(decision) else { return nil }
            var d: [String: Any] = ["behavior": decision]
            if decision == "deny" { d["message"] = "Denied from the Cocaine notch." }
            out = ["hookEventName": "PermissionRequest", "decision": d]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": out], options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One button of a request: what it says and what it sends.
struct ApprovalChoice: Equatable {
    var label: String            // "allow" / "deny" / "decline" are translated by the UI; an MCP form's values are shown as they are
    var decision: String
    var content: String? = nil   // JSON object text for "accept"
}

struct ApprovalRequest: Equatable, Identifiable {
    var id: String
    var nonce: String
    var tool: String             // "claude" | "codex"
    var from: String             // "Claude Code" | "Codex"
    var event: String            // "PermissionRequest" | "Elicitation"
    var session: String?
    var project: String?
    var title: String            // the tool asking ("Bash", an MCP server…)
    var summary: String          // the command, file, URL or question
    var choices: [ApprovalChoice]
    var answerable: Bool         // false: shown as waiting, handed back to the terminal at once (no documented way to answer)
    var origin: AgentOrigin
    var received: Date
    var deadline: Date

    static func clean(_ s: String, _ limit: Int) -> String {
        let t = String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value < 32 || $0.value == 127 || (0x202A...0x202E).contains($0.value)
            || (0x2066...0x2069).contains($0.value) ? " " : $0 }))
        let one = t.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return one.count > limit ? String(one.prefix(limit - 1)) + "…" : one
    }

    /// Reads the hook's JSON input (as the tool sent it) into a request. nil when it isn't a request this app can show.
    static func make(id: String, nonce: String, tool: String, input: [String: Any], origin: AgentOrigin, now: Date,
                     hold: TimeInterval = ApprovalTiming.app) -> ApprovalRequest? {
        guard ["claude", "codex"].contains(tool), id.range(of: #"^[A-Za-z0-9-]{8,64}$"#, options: .regularExpression) != nil,
              nonce.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil else { return nil }
        let event = input["hook_event_name"] as? String ?? "PermissionRequest"
        let session = (input["session_id"] as? String).map { String(String.UnicodeScalarView($0.unicodeScalars.filter {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-").contains($0) }).prefix(80)) }
        var origin = origin
        if origin.cwd == nil, let c = input["cwd"] as? String { origin.cwd = c; origin = origin.sanitized() }
        let project = origin.cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        var r = ApprovalRequest(id: id, nonce: nonce, tool: tool, from: tool == "claude" ? "Claude Code" : "Codex", event: event,
                                session: session.flatMap { $0.isEmpty ? nil : String($0) }, project: project, title: "", summary: "",
                                choices: [], answerable: true, origin: origin, received: now, deadline: now.addingTimeInterval(hold))
        switch event {
        case "PermissionRequest":
            let name = clean(input["tool_name"] as? String ?? "", 60)
            let args = input["tool_input"] as? [String: Any] ?? [:]
            r.title = name.isEmpty ? "?" : name
            let key = ["command", "file_path", "notebook_path", "url", "path", "pattern", "query", "description", "prompt"].first { args[$0] is String }
            let main = key.flatMap { args[$0] as? String }
            let fallback = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
            // Line breaks stay visible (in a command they start another command); the other control characters go.
            let shown = (main ?? fallback).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: " ⏎ ")
            r.summary = clean(shown, 300)
            r.choices = [ApprovalChoice(label: "allow", decision: "allow"), ApprovalChoice(label: "deny", decision: "deny")]
            // A question to the user (AskUserQuestion) has no documented hook answer: show it, leave it to the terminal.
            if name == "AskUserQuestion" { r.answerable = false; r.choices = [] }
            // Allowed from the notch only what the notch shows in full: one field, not cut, and nothing else that matters
            // (a Write's content, an Edit's new text, an MCP call's arguments next to a harmless description).
            if !fullyShown(key: key, text: shown, args: args) { r.answerable = false; r.choices = [] }
        case "Elicitation" where tool == "claude":
            r.title = clean(input["mcp_server_name"] as? String ?? input["server"] as? String ?? "MCP", 60)
            r.summary = clean(input["message"] as? String ?? "", 300)
            r.choices = elicitationChoices(input)
        default:
            return nil
        }
        return r
    }

    /// The longest text the notch shows whole (it wraps over a few lines, never cut).
    static let shownLimit = 180
    /// Fields that only describe or tune a call (a Bash command's label and timeout, a Read's range).
    static let incidental: Set<String> = ["description", "timeout", "run_in_background", "offset", "limit"]

    /// Everything the request would allow is in the one field shown, and that field fits whole.
    static func fullyShown(key: String?, text: String, args: [String: Any]) -> Bool {
        guard let key, !incidental.contains(key) || args.count == 1 else { return false }
        guard clean(text, shownLimit + 1).count <= shownLimit else { return false }
        return args.keys.allSatisfy { $0 == key || incidental.contains($0) }
    }

    /// An MCP question that one click can answer: a form with a single choice (enum) or yes/no (boolean) field. Anything
    /// else can only be declined here; the terminal answers the rest.
    static func elicitationChoices(_ input: [String: Any]) -> [ApprovalChoice] {
        var out: [ApprovalChoice] = []
        let mode = input["mode"] as? String ?? "form"
        if mode == "form", let schema = input["requested_schema"] as? [String: Any],
           let props = schema["properties"] as? [String: Any], props.count == 1, let (name, raw) = props.first,
           let field = raw as? [String: Any] {
            func accept(_ label: String, _ value: Any) -> ApprovalChoice? {
                guard let d = try? JSONSerialization.data(withJSONObject: [name: value], options: [.sortedKeys]) else { return nil }
                return ApprovalChoice(label: clean(label, 40), decision: "accept", content: String(decoding: d, as: UTF8.self))
            }
            if let values = field["enum"] as? [String], (1...6).contains(values.count) {
                let names = field["enumNames"] as? [String]
                out = values.enumerated().compactMap { i, v in accept(names?.count == values.count ? names![i] : v, v) }
            } else if field["type"] as? String == "boolean" {
                out = [accept("yes", true), accept("no", false)].compactMap { $0 }
            }
        }
        return out + [ApprovalChoice(label: "decline", decision: "decline")]
    }
}

/// Each request's life: pending until one answer (the first click wins), a hand-back to the terminal, its deadline, or the
/// hook going away. Pure: the app drives it with the clock.
struct ApprovalStore {
    enum State: Equatable { case pending, answered, released, expired, gone }
    enum Outcome: Equatable { case send(decision: String, content: String?), alreadyAnswered, expired, unknown }
    static let maxPending = 20

    private(set) var requests: [String: ApprovalRequest] = [:]
    private(set) var states: [String: State] = [:]
    private var closedAt: [String: Date] = [:]

    var pending: [ApprovalRequest] {
        requests.values.filter { states[$0.id] == .pending }.sorted { ($0.received, $0.id) < ($1.received, $1.id) }
    }

    /// False for a repeated id (a replayed request) or when too many are already waiting.
    mutating func add(_ r: ApprovalRequest) -> Bool {
        guard requests[r.id] == nil, pending.count < Self.maxPending else { return false }
        requests[r.id] = r; states[r.id] = .pending
        return true
    }

    mutating func answer(_ id: String, choice: Int, now: Date) -> Outcome {
        guard let r = requests[id], let st = states[id] else { return .unknown }
        switch st {
        case .pending: break
        case .expired: return .expired
        default: return .alreadyAnswered
        }
        if now >= r.deadline { close(id, .expired, now); return .expired }
        guard r.answerable, r.choices.indices.contains(choice) else { return .unknown }
        close(id, .answered, now)
        return .send(decision: r.choices[choice].decision, content: r.choices[choice].content)
    }

    /// "Answer in the terminal": the hook gets no decision. False if it was no longer pending.
    mutating func release(_ id: String, now: Date) -> Bool {
        guard states[id] == .pending else { return false }
        close(id, .released, now)
        return true
    }

    /// The hook went away (the tool timed it out, the user interrupted, the session ended).
    mutating func gone(_ id: String, now: Date) { if states[id] == .pending { close(id, .gone, now) } }

    /// Pending ones past their deadline become expired; returns them. Closed ones are forgotten a minute later (until then a
    /// late click still finds them and is told so).
    mutating func expire(now: Date) -> [String] {
        let due = pending.filter { now >= $0.deadline }.map(\.id)
        due.forEach { close($0, .expired, now) }
        for (id, t) in closedAt where now.timeIntervalSince(t) > 60 { requests[id] = nil; states[id] = nil; closedAt[id] = nil }
        return due
    }

    func state(_ id: String) -> State? { states[id] }

    private mutating func close(_ id: String, _ s: State, _ now: Date) { states[id] = s; closedAt[id] = now }
}

enum ApprovalPolicy {
    /// Hold a request in the notch, or hand it straight back to the terminal: off, not answerable here, or the user is right
    /// there in that session's own app (the terminal prompt is quicker than the notch).
    static func hold(enabled: Bool, answerable: Bool, origin: AgentOrigin, frontmost: String?, idleSeconds: Double) -> Bool {
        guard enabled, answerable else { return false }
        if let app = origin.app, let front = frontmost, app == front, idleSeconds < 10 { return false }
        return true
    }
}

// MARK: - The app's side: the socket server

/// Listens on the socket; every connection is one hook waiting for one answer. All socket work runs on its own queue;
/// the callbacks come on the main queue.
final class ApprovalServer {
    let path: String
    private let key: Data
    private let q = DispatchQueue(label: "local.cocaine.approvals")
    private var listenFD: Int32 = -1
    private var inode: ino_t = 0
    private var acceptSource: DispatchSourceRead?
    private final class Conn {
        let fd: Int32
        var buffer = Data()
        var source: DispatchSourceRead?
        var id: String?
        var nonce: String?
        var closed = false
        init(fd: Int32) { self.fd = fd }
    }
    private var conns: [Int32: Conn] = [:]
    private var byId: [String: Conn] = [:]

    /// A hook's request: its id, nonce, tool and raw input, and its origin. Main queue.
    var onRequest: (_ id: String, _ nonce: String, _ tool: String, _ input: [String: Any], _ origin: AgentOrigin) -> Void = { _, _, _, _, _ in }
    /// The hook went away before an answer. Main queue.
    var onGone: (_ id: String) -> Void = { _ in }

    init(path: String, key: Data) { self.path = path; self.key = key }

    enum StartError: Error { case unsafeFolder, inUse, socket(Int32) }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { throw StartError.unsafeFolder }
        if st.st_mode & 0o077 != 0 { chmod(dir, 0o700) }
        if lstat(path, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFSOCK, Self.connect(path) >= 0 { throw StartError.inUse }   // another Cocaine answers
            unlink(path)                                                                            // a stale one
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket(errno) }
        guard var addr = Self.address(path) else { close(fd); throw StartError.socket(ENAMETOOLONG) }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { let e = errno; close(fd); throw StartError.socket(e) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); unlink(path); throw StartError.socket(e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if lstat(path, &st) == 0 { inode = st.st_ino }
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.resume()
        acceptSource = src
    }

    func stop() {
        q.sync {
            acceptSource?.cancel(); acceptSource = nil
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            conns.values.forEach(drop)
            var st = stat()
            if lstat(path, &st) == 0, st.st_ino == inode { unlink(path) }   // only our own socket
        }
    }

    /// Sends the signed answer (or "none") and closes; false if that hook is no longer there.
    func reply(_ id: String, decision: String, content: String?, done: @escaping (Bool) -> Void = { _ in }) {
        q.async {
            guard let c = self.byId[id], !c.closed, let nonce = c.nonce else { DispatchQueue.main.async { done(false) }; return }
            let line = ApprovalWire.answer(key: self.key, id: id, nonce: nonce, decision: decision, content: content)
            let sent = line.withUnsafeBytes { Self.writeAll(c.fd, $0) }
            self.drop(c)
            DispatchQueue.main.async { done(sent) }
        }
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        return addr
    }

    /// A connected socket, or -1.
    static func connect(_ path: String) -> Int32 {
        guard var addr = address(path) else { return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if r != 0 { close(fd); return -1 }
        return fd
    }

    static func writeAll(_ fd: Int32, _ buf: UnsafeRawBufferPointer) -> Bool {
        var off = 0
        while off < buf.count {
            let n = write(fd, buf.baseAddress! + off, buf.count - off)
            if n < 0 && (errno == EINTR || errno == EAGAIN) { usleep(1000); continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), conns.count < 64 else { close(fd); continue }   // only this user
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let c = Conn(fd: fd)
            conns[fd] = c
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
            src.setEventHandler { [weak self, weak c] in if let self, let c { self.readable(c) } }
            src.setCancelHandler { close(fd) }                          // closed only once the source is done with it
            src.resume()
            c.source = src
            q.asyncAfter(deadline: .now() + 5) { [weak self, weak c] in      // a request must arrive at once
                if let self, let c, c.id == nil, !c.closed { self.drop(c) }
            }
        }
    }

    private func readable(_ c: Conn) {
        var buf = [UInt8](repeating: 0, count: 16384)
        let n = read(c.fd, &buf, buf.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard n > 0 else {                                          // the hook went away
            let id = c.id
            drop(c)
            if let id { DispatchQueue.main.async { self.onGone(id) } }
            return
        }
        guard c.id == nil else { return }                           // nothing more is expected after the request
        c.buffer.append(contentsOf: buf[0..<n])
        guard c.buffer.count <= 600_000 else { drop(c); return }
        guard let nl = c.buffer.firstIndex(of: 0x0A) else { return }
        let line = c.buffer[c.buffer.startIndex..<nl]
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], o["v"] as? Int == 1,
              let id = o["id"] as? String, let nonce = o["nonce"] as? String, let tool = o["tool"] as? String,
              let input = o["input"] as? [String: Any], byId[id] == nil else { drop(c); return }
        var origin = AgentOrigin()
        if let od = o["origin"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: od),
           let parsed = try? JSONDecoder().decode(AgentOrigin.self, from: data) { origin = parsed.sanitized() }
        c.id = id; c.nonce = nonce
        byId[id] = c
        DispatchQueue.main.async { self.onRequest(id, nonce, tool, input, origin) }
    }

    private func drop(_ c: Conn) {
        guard !c.closed else { return }
        c.closed = true
        shutdown(c.fd, SHUT_RDWR)                                       // the hook sees the end at once
        if let s = c.source { s.cancel(); c.source = nil } else { close(c.fd) }
        conns[c.fd] = nil
        if let id = c.id { byId[id] = nil }
    }
}

// MARK: - The hook's side

enum ApprovalHook {
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "login"]

    /// Where the agent runs: its environment, and its own process (the first non-shell up from this hook).
    static func origin(env: [String: String]) -> AgentOrigin {
        var o = AgentOrigin()
        o.app = env["__CFBundleIdentifier"]
        o.term = env["TERM_PROGRAM"]
        o.termSession = env["ITERM_SESSION_ID"] ?? env["TERM_SESSION_ID"]
        o.tmuxPane = env["TMUX_PANE"]
        o.tmuxSocket = env["TMUX"].map { String($0.split(separator: ",").first ?? "") }
        o.weztermPane = env["WEZTERM_PANE"]
        o.cwd = env["PWD"] ?? FileManager.default.currentDirectoryPath
        var p = getppid()
        for _ in 0..<6 {
            guard p > 1, let i = AgentProcess.info(p) else { break }
            if !shells.contains(i.name) { o.pid = p; o.pidStart = i.start; if let t = i.tty { o.tty = t }; break }
            p = i.ppid
        }
        return o.sanitized()
    }

    /// Reads what the tool sends on stdin: at most 512 KB, for at most `seconds`.
    static func readInput(_ fd: Int32 = 0, seconds: Double = 3) -> Data {
        var data = Data()
        let end = Date().addingTimeInterval(seconds)
        var buf = [UInt8](repeating: 0, count: 65536)
        while data.count < 524_288 {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(0, end.timeIntervalSinceNow) * 1000)
            guard ms > 0, poll(&p, 1, ms) > 0 else { break }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return data
    }

    /// The whole hook: what to print (nil = nothing, the tool asks as usual). Never throws, never blocks past `timeout`.
    static func run(tool: String, input: Data, env: [String: String], timeout: Double = ApprovalTiming.hook) -> String? {
        guard ["claude", "codex"].contains(tool),
              let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return nil }
        let event = json["hook_event_name"] as? String ?? "PermissionRequest"
        guard event == "PermissionRequest" || (event == "Elicitation" && tool == "claude") else { return nil }
        let dir = AgentPaths.support(env)
        guard let key = ApprovalKey.read(AgentPaths.key(dir)) else { return nil }
        let path = AgentPaths.socket(dir)
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { return nil }
        let fd = ApprovalServer.connect(path)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return nil }      // the server is this user's
        let id = UUID().uuidString, nonce = ApprovalWire.random(16)
        var req: [String: Any] = ["v": 1, "id": id, "nonce": nonce, "tool": tool, "input": json]
        if let o = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(origin(env: env))) { req["origin"] = o }
        guard var body = try? JSONSerialization.data(withJSONObject: req) else { return nil }
        body.append(0x0A)
        guard body.withUnsafeBytes({ ApprovalServer.writeAll(fd, $0) }) else { return nil }
        let end = Date().addingTimeInterval(timeout)
        var line = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while line.count < 65536 {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(0, end.timeIntervalSinceNow) * 1000)
            guard ms > 0 else { return nil }
            let r = poll(&p, 1, ms)
            if r < 0 && errno == EINTR { continue }
            guard r > 0 else { return nil }
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return nil }
            line.append(contentsOf: buf[0..<n])
            if let nl = line.firstIndex(of: 0x0A) {
                return ApprovalWire.hookOutput(answer: line[line.startIndex..<nl], key: key, id: id, nonce: nonce, event: event)
            }
        }
        return nil
    }
}
