// The app's side of "AI context (MCP)": the private socket the `--mcp` bridges talk to (only while the master switch is on), and
// what a call may do (MCPHandler): consent first, rate limits, then only the basket (Sources/AIContext.swift) and the pinboards
// the user shared with AI; every call is logged without content. The questions themselves (consent, "pick items for the AI")
// are asked in the notch by Sources/AIContextWiring.swift.

import Darwin
import Foundation

/// One verified call from a bridge.
struct MCPCall {
    var verb: String
    var args: [String: Any]
    var client: MCPClientIdentity
    var session: String
    let token: MCPCancelToken
}

/// Listens on mcp.sock. Each connection: challenge → one signed request → one signed answer. Socket work runs on its queue;
/// `handle` runs on `handlerQueue` (the main queue in the app).
final class MCPAppServer {
    let path: String
    private let keyPath: String
    private let handlerQueue: DispatchQueue
    private let q = DispatchQueue(label: "local.cocaine.mcp.server")
    private var listenFD: Int32 = -1
    private var inode: ino_t = 0
    private var acceptSource: DispatchSourceRead?
    private var key: Data?
    private var conns: [Int32: Conn] = [:]
    static let maxConnections = 16

    /// Who may connect (the same user; tests simulate another one).
    var peerAllowed: (uid_t) -> Bool = { $0 == getuid() }
    /// The program that started a bridge: the bridge's parent's executable (pid → path). Tests inject it.
    var parentProgram: (pid_t) -> String = { pid in
        guard pid > 0, let ppid = AgentProcess.info(pid)?.ppid, ppid > 1 else { return "" }
        return ProcessDetector.path(ppid) ?? ""
    }
    var handle: (MCPCall, @escaping ([String: Any]) -> Void) -> Void = { _, done in done(["ok": false, "error": "not ready", "code": "off"]) }
    /// Refused connections (tests).
    private(set) var refusedCount = 0

    private final class Conn {
        let fd: Int32
        var buf = Data()
        var source: DispatchSourceRead?
        var challenge = ""
        var cnonce: String?
        var peerPid: pid_t = 0
        var token: MCPCancelToken?
        var closed = false
        init(fd: Int32) { self.fd = fd }
    }

    init(socket: String, keyPath: String, handlerQueue: DispatchQueue = .main) {
        path = socket; self.keyPath = keyPath; self.handlerQueue = handlerQueue
    }

    var running: Bool { q.sync { listenFD >= 0 } }

    enum StartError: Error { case unsafeFolder, inUse, key, socket(Int32) }

    func start() throws {
        try q.sync {
            guard listenFD < 0 else { return }
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var st = stat()
            guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { throw StartError.unsafeFolder }
            if st.st_mode & 0o077 != 0 { chmod(dir, 0o700) }
            guard let k = ApprovalKey.loadOrCreate(keyPath) else { throw StartError.key }
            if lstat(path, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFSOCK, ApprovalServer.connect(path).closingIfOpen() { throw StartError.inUse }
                unlink(path)
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw StartError.socket(errno) }
            guard var addr = ApprovalServer.address(path) else { close(fd); throw StartError.socket(ENAMETOOLONG) }
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard ok == 0 else { let e = errno; close(fd); throw StartError.socket(e) }
            chmod(path, 0o600)
            guard listen(fd, 16) == 0 else { let e = errno; close(fd); unlink(path); throw StartError.socket(e) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            if lstat(path, &st) == 0 { inode = st.st_ino }
            listenFD = fd; key = k
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
            src.setEventHandler { [weak self] in self?.acceptAll() }
            src.resume()
            acceptSource = src
        }
    }

    func stop() {
        q.sync {
            acceptSource?.cancel(); acceptSource = nil
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            let open = Array(conns.values)
            open.forEach(drop)
            open.forEach { $0.token?.cancel() }                   // turned off: questions still on screen are withdrawn
            var st = stat()
            if lstat(path, &st) == 0, st.st_ino == inode { unlink(path) }      // only our own socket
        }
    }

    private func acceptAll() {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, peerAllowed(uid), conns.count < Self.maxConnections else {
                refusedCount += 1; close(fd); continue
            }
            let c = Conn(fd: fd)
            var pid: pid_t = 0
            var len = socklen_t(MemoryLayout<pid_t>.size)
            if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 { c.peerPid = pid }
            c.challenge = ApprovalWire.random(16)
            MCPWire.setTimeout(fd, 5)
            guard MCPWire.challenge(c.challenge).withUnsafeBytes({ ApprovalServer.writeAll(fd, $0) }) else { close(fd); continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            conns[fd] = c
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
            src.setEventHandler { [weak self, weak c] in if let self, let c { self.readable(c) } }
            src.setCancelHandler { close(fd) }
            src.resume()
            c.source = src
            q.asyncAfter(deadline: .now() + 5) { [weak self, weak c] in        // the request must come at once
                if let self, let c, c.cnonce == nil, !c.closed { self.refusedCount += 1; self.drop(c) }
            }
        }
    }

    private func readable(_ c: Conn) {
        var b = [UInt8](repeating: 0, count: 65_536)
        let n = read(c.fd, &b, b.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard n > 0 else {                                     // the bridge went away (its client cancelled, or it ended)
            let t = c.token
            drop(c)
            t?.cancel()
            return
        }
        guard c.cnonce == nil else { return }                  // nothing more is expected after the request
        c.buf.append(contentsOf: b[0..<n])
        guard c.buf.count <= MCPWire.maxRequest else { refusedCount += 1; drop(c); return }
        guard let nl = c.buf.firstIndex(of: 0x0A), let key else { return }
        switch MCPWire.open(Data(c.buf[c.buf.startIndex..<nl]), key: key, challenge: c.challenge) {
        case .failure:
            refusedCount += 1
            _ = MCPWire.line(["error": "refused"]).withUnsafeBytes { ApprovalServer.writeAll(c.fd, $0) }
            drop(c)
        case .success(let req):
            c.cnonce = req.cnonce
            let token = MCPCancelToken()
            c.token = token
            let body = req.body
            let ci = body["client"] as? [String: Any] ?? [:]
            let client = MCPClientIdentity(name: AIContextText.clean(ci["name"] as? String ?? "unknown", 60), program: parentProgram(c.peerPid))
            let call = MCPCall(verb: body["verb"] as? String ?? "", args: body["args"] as? [String: Any] ?? [:], client: client,
                               session: AIContextText.clean(body["session"] as? String ?? "", 64), token: token)
            handlerQueue.async { [weak self] in
                self?.handle(call) { reply in self?.answer(c, reply) }
            }
        }
    }

    private func answer(_ c: Conn, _ reply: [String: Any]) {
        q.async { [self] in
            guard !c.closed, let key, let cnonce = c.cnonce else { return }
            var body = MCPWire.json(reply)
            if body.utf8.count > MCPWire.maxReply - 4096 { body = MCPWire.json(["ok": false, "error": "The answer was too big", "code": "error"]) }
            MCPWire.setTimeout(c.fd, 5)
            _ = fcntl(c.fd, F_SETFL, fcntl(c.fd, F_GETFL) & ~O_NONBLOCK)
            _ = MCPWire.reply(key: key, cnonce: cnonce, body: body).withUnsafeBytes { ApprovalServer.writeAll(c.fd, $0) }
            drop(c)
        }
    }

    private func drop(_ c: Conn) {
        guard !c.closed else { return }
        c.closed = true
        shutdown(c.fd, SHUT_RDWR)
        if let s = c.source { s.cancel(); c.source = nil } else { close(c.fd) }
        conns[c.fd] = nil
    }
}

private extension Int32 {
    /// A connect() result: true when it connected (and closes it).
    func closingIfOpen() -> Bool { if self >= 0 { close(self); return true }; return false }
}

/// What a call may do. Main queue in the app (tests: any one queue). Pure apart from the closures it is given.
final class MCPHandler {
    let basket: AIContextBasket
    let consent: MCPConsentStore
    let audit: MCPAuditLog
    var enabled: () -> Bool
    var limiter = MCPRateLimiter()
    /// Clipboard items by id, read on this queue (the reader then works off it).
    var clipItems: () -> [ClipItem] = { ClipboardHistory.shared.items }
    /// The pinboards (only those with `ai` set are ever shown).
    var boards: () -> [ClipBoard] = { ClipboardHistory.shared.boards }
    var recognize: (URL) -> String? = { try? TextRecognition.recognize(url: $0) }
    /// Asks the user whether this client may read (nil: no answer). Returns a function that withdraws the question.
    var askConsent: (_ client: MCPClientIdentity, _ count: Int, _ done: @escaping (AIConsentAnswer?) -> Void) -> (() -> Void) = { _, _, done in done(nil); return {} }
    /// Asks the user to pick items for the AI (nil: declined or no answer). Returns a function that withdraws the question.
    var askPick: (_ client: MCPClientIdentity, _ reason: String, _ kinds: [String], _ done: @escaping ([(kind: String, ref: String, title: String)]?) -> Void) -> (() -> Void) = { _, _, _, done in done(nil); return {} }
    /// Where file reading and text recognition run (off the main thread in the app).
    var readQueue = DispatchQueue(label: "local.cocaine.mcp.read", qos: .userInitiated)
    var now: () -> Date = Date.init
    /// The queue calls arrive on (the server's handlerQueue): answers and withdrawals come back on it.
    var queue = DispatchQueue.main
    private var waiting: [String: [(AIConsentAnswer?) -> Void]] = [:]     // one question per client at a time

    init(basket: AIContextBasket, consent: MCPConsentStore, audit: MCPAuditLog, enabled: @escaping () -> Bool) {
        self.basket = basket; self.consent = consent; self.audit = audit; self.enabled = enabled
    }

    static func err(_ text: String, _ code: String) -> [String: Any] { ["ok": false, "error": text, "code": code] }

    func handle(_ call: MCPCall, _ done: @escaping ([String: Any]) -> Void) {
        let c = call.client
        func log(_ outcome: String, items: Int = 0, bytes: Int = 0) {
            audit.add(MCPAuditEntry(date: now(), client: c.label, action: call.verb, outcome: outcome, items: items, bytes: bytes))
        }
        guard enabled() else { done(Self.err("AI context (MCP) is off in Cocaine", "off")); return }
        if call.verb == "status" { done(["ok": true]); return }
        guard ["list", "get", "boards", "board", "request"].contains(call.verb) else { done(Self.err("Unknown request", "unknown")); return }
        guard limiter.allow(c.fingerprint, now: now()) else { log("rate limited"); done(Self.err("Too many requests: wait a minute", "rate")); return }
        switch consent.state(c, session: call.session, now: now()) {
        case .denied:
            log("denied"); done(Self.err("The user denied this tool access to the Cocaine AI context (they can change it in Cocaine → Settings → AI).", "denied"))
        case .allowed:
            consent.used(c, now: now())
            perform(call, log: log, done)
        case .ask:
            if waiting[c.fingerprint] != nil { waiting[c.fingerprint]!.append { [weak self] a in self?.answered(a, call, log: log, done) }; return }
            waiting[c.fingerprint] = [{ [weak self] a in self?.answered(a, call, log: log, done) }]
            var finished = false
            let withdraw = askConsent(c, basket.count) { [weak self] a in
                guard let self, !finished else { return }
                finished = true
                switch a {
                case .allow?: self.consent.record(c, .allow, now: self.now())
                case .deny?: self.consent.record(c, .deny, now: self.now())
                case .once?: self.consent.allowOnce(c, session: call.session, now: self.now())
                case nil: break
                }
                let list = self.waiting.removeValue(forKey: c.fingerprint) ?? []
                list.forEach { $0(a) }
            }
            call.token.onCancel { [queue] in queue.async { if !finished { withdraw() } } }
        }
    }

    private func answered(_ a: AIConsentAnswer?, _ call: MCPCall, log: @escaping (String, Int, Int) -> Void, _ done: @escaping ([String: Any]) -> Void) {
        switch a {
        case .allow?, .once?: perform(call, log: { log($0, $1, $2) }, done)
        case .deny?: log("denied", 0, 0); done(Self.err("The user denied this tool access to the Cocaine AI context.", "denied"))
        case nil: log("no answer", 0, 0); done(Self.err("The user didn't answer in Cocaine; try again later.", "noanswer"))
        }
    }

    private func perform(_ call: MCPCall, log: @escaping (String, Int, Int) -> Void, _ done: @escaping ([String: Any]) -> Void) {
        let budget = min(MCPLimits.resultTokens, max(500, call.args["budget"] as? Int ?? MCPLimits.resultTokens))
        switch call.verb {
        case "list":
            let rows: [[String: Any]] = basket.list().map { e in
                var r: [String: Any] = ["id": e.id.uuidString, "kind": e.kind.rawValue, "title": e.title,
                                        "added": ISO8601DateFormatter().string(from: e.added)]
                if let x = basket.expires(e) { r["expires"] = ISO8601DateFormatter().string(from: x) }
                if e.kind == .text { r["bytes"] = e.ref.utf8.count }
                return r
            }
            log("ok", rows.count, 0)
            done(["ok": true, "items": rows])
        case "get":
            guard let id = (call.args["id"] as? String).flatMap(UUID.init(uuidString:)), let e = basket.entry(id) else {
                log("not found", 0, 0); done(Self.err("No such item in the AI context (it may have been removed or expired).", "gone")); return
            }
            let offset = max(0, call.args["offset"] as? Int ?? 0)
            read([e]) { results in
                guard let r = results.first else { return }
                switch r {
                case .failure(let f):
                    log(f == .gone ? "not found" : "refused", 0, 0)
                    done(Self.err(f == .gone ? "That item is gone (deleted or moved)." : "That item can't be read.", f == .gone ? "gone" : "refused"))
                case .success(let content):
                    let page = Self.page(content, offset: offset, budget: budget)
                    log("ok", 1, page["text"].map { ($0 as? String ?? "").utf8.count } ?? 0)
                    done(page.merging(["ok": true]) { a, _ in a })
                }
            }
        case "boards":
            let items = clipItems()
            let rows: [[String: Any]] = boards().filter(\.ai).map { b in
                ["id": b.id.uuidString, "name": b.displayName, "count": items.filter { $0.boards.contains(b.id) }.count]
            }
            log("ok", rows.count, 0)
            done(["ok": true, "boards": rows])
        case "board":
            let want = (call.args["board"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let b = boards().first(where: { $0.ai && ($0.id.uuidString == want.uppercased()
                    || $0.displayName.compare(want, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame) }) else {
                log("not found", 0, 0); done(Self.err("No pinboard shared with AI by that name.", "gone")); return
            }
            let list = clipItems().filter { $0.boards.contains(b.id) }
            let start = max(0, call.args["cursor"] as? Int ?? 0)
            let reader = AIContextReader(clip: { id in list.first { $0.id == id } }, recognize: recognize)
            var parts: [String] = [], left = budget, i = start
            while i < list.count {
                let item = list[i]
                let e = AIContextEntry(id: item.id, kind: .clip, ref: item.id.uuidString, title: ClipCLIHandler.preview(item), added: item.date)
                guard case .success(let content) = reader.content(e) else { i += 1; continue }
                let head = "## \(content.title) (\(content.kind))\n"
                let cut = AIContextText.cut(content.text, from: 0, budget: max(0, left - AIContextText.tokens(head[...]) - 20))
                if cut.text.isEmpty && !parts.isEmpty { break }
                parts.append(head + cut.text + (cut.next != nil ? "\n[this item was cut here]" : ""))
                left -= AIContextText.tokens(parts.last![...])
                i += 1
                if left < 200 { break }
            }
            let text = parts.joined(separator: "\n\n")
            log("ok", i - start, text.utf8.count)
            var r: [String: Any] = ["ok": true, "id": b.id.uuidString, "name": b.displayName, "text": list.isEmpty ? "(empty)" : text]
            if i < list.count { r["next"] = i }
            done(r)
        case "request":
            guard limiter.allow(call.client.fingerprint, request: true, now: now()) else { log("rate limited", 0, 0); done(Self.err("Too many requests: wait a minute", "rate")); return }
            let reason = AIContextText.clean(call.args["reason"] as? String ?? "", 300)
            let kinds = (call.args["kinds"] as? [String] ?? ["clipboard", "shelf"]).filter { ["clipboard", "shelf"].contains($0) }
            var finished = false
            let withdraw = askPick(call.client, reason, kinds.isEmpty ? ["clipboard", "shelf"] : kinds) { [weak self] picked in
                guard let self, !finished else { return }
                finished = true
                guard let picked, !picked.isEmpty else { log("declined", 0, 0); done(["ok": true, "declined": true]); return }
                let ids = self.basket.add(picked).added
                let entries = ids.compactMap { self.basket.entry($0) }
                self.read(entries) { results in
                    let share = max(500, budget / max(1, results.count))
                    let pages: [[String: Any]] = results.compactMap { r in
                        guard case .success(let c) = r else { return nil }
                        return Self.page(c, offset: 0, budget: share)
                    }
                    log("ok", pages.count, pages.reduce(0) { $0 + (($1["text"] as? String)?.utf8.count ?? 0) })
                    done(["ok": true, "items": pages])
                }
            }
            call.token.onCancel { [queue] in queue.async { if !finished { finished = true; withdraw(); log("cancelled", 0, 0) } } }
        default:
            done(Self.err("Unknown request", "unknown"))
        }
    }

    /// Reads entries off this queue, answers back on it.
    private func read(_ entries: [AIContextEntry], _ done: @escaping ([Result<AIContextContent, AIContextReader.Failure>]) -> Void) {
        let items = clipItems()
        let reader = AIContextReader(clip: { id in items.first { $0.id == id } }, recognize: recognize)
        let back = queue
        readQueue.async {
            let r = entries.map { reader.content($0) }
            back.async { done(r) }
        }
    }

    /// One page of an item's text: from `offset` (characters), within `budget` tokens.
    static func page(_ c: AIContextContent, offset: Int, budget: Int) -> [String: Any] {
        let cut = AIContextText.cut(c.text, from: offset, budget: budget)
        var item: [String: Any] = ["id": c.id.uuidString, "kind": c.kind, "title": c.title, "mime": c.mime]
        if let n = c.note { item["note"] = n }
        var r: [String: Any] = ["item": item, "text": cut.text, "offset": offset, "total": c.text.count]
        if let next = cut.next { r["next"] = next }
        return r
    }
}

enum AIConsentAnswer: Equatable { case allow, once, deny }
