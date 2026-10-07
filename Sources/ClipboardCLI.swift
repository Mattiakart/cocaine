// `cocaine clip list|get|put|paste` (the engine runs `Cocaine --clip …`): the clipboard history and pinboards from Terminal,
// scripts and Mac Shortcuts ("Run Shell Script"). The command talks to the running app over a Unix socket that only exists while
// "Command line" is on in Settings → Island → Clipboard (off by default): `clip.sock` in Cocaine's private folder (0700), the
// socket 0600, same user only (getpeereid), every request signed with a per-install key (`clip.key`, 0600) and fresh (a time
// and a nonce, never accepted twice). "Add only" allows `put`; reading (`list`, `get`) and `paste` need "Add, read and paste".
// Nothing of this goes through the cocaine:// links: a web page can never read or paste the clipboard.

import AppKit
import CryptoKit
import Darwin

enum ClipCLIWire {
    static let maxRequest = 1_100_000
    static let maxReply = 4_000_000
    static let maxText = 1_000_000
    static let freshness: TimeInterval = 120

    static func paths(_ env: [String: String] = ProcessInfo.processInfo.environment) -> (socket: String, key: String) {
        let dir = AgentPaths.support(env)
        return (dir.appendingPathComponent("clip.sock").path, dir.appendingPathComponent("clip.key").path)
    }

    static func mac(_ key: Data, _ body: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: key))).hex
    }

    /// One request line: base64(body) "." hex(HMAC-SHA256(key, body)).
    static func request(key: Data, verb: String, args: [String: Any], now: Date = Date(), nonce: String = ApprovalWire.random(16)) -> Data? {
        let body: [String: Any] = ["v": 1, "verb": verb, "args": args, "ts": now.timeIntervalSince1970, "nonce": nonce]
        guard let d = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        return Data((d.base64EncodedString() + "." + mac(key, d) + "\n").utf8)
    }

    enum Refusal: Error, Equatable { case malformed, badSignature, stale, replayed }

    /// The request's verb and arguments when it is well-formed, signed with `key`, fresh and new (its nonce is remembered).
    static func open(_ line: Data, key: Data, now: Date, seen: inout [String: Date]) -> Result<(verb: String, args: [String: Any]), Refusal> {
        guard line.count <= maxRequest, let s = String(data: line, encoding: .utf8) else { return .failure(.malformed) }
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let body = Data(base64Encoded: String(parts[0])) else { return .failure(.malformed) }
        guard ApprovalWire.equal(mac(key, body), String(parts[1])) else { return .failure(.badSignature) }
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], o["v"] as? Int == 1,
              let verb = o["verb"] as? String, let args = o["args"] as? [String: Any], let ts = o["ts"] as? Double,
              let nonce = o["nonce"] as? String, nonce.count >= 16, nonce.count <= 64 else { return .failure(.malformed) }
        guard abs(now.timeIntervalSince1970 - ts) <= freshness else { return .failure(.stale) }
        seen = seen.filter { now.timeIntervalSince($0.value) <= freshness * 2 }
        guard seen[nonce] == nil else { return .failure(.replayed) }
        if seen.count < 5_000 { seen[nonce] = now }
        return .success((verb, args))
    }
}

/// What the app does with a request (pure enough to test with a stand-in history and paste engine).
enum ClipCLIHandler {
    static func reply(_ verb: String, _ args: [String: Any], history h: ClipboardHistory, engine: PasteEngine) -> [String: Any] {
        let access = h.settings.cliAccess
        func err(_ s: String, _ code: Int = 65) -> [String: Any] { ["ok": false, "error": s, "code": code] }
        guard access > 0 else { return err(L("The command line is off: Settings → Island → Clipboard → Command line"), 69) }
        let reading = ["list", "get", "paste"].contains(verb)
        if reading && access < 2 { return err(L("Reading and pasting from the command line are off: Settings → Island → Clipboard → Command line"), 77) }

        // The list a number refers to: a pinboard's items, else the whole history (newest first).
        var list = h.items
        if let name = args["board"] as? String, !name.isEmpty {
            guard let b = h.boards.first(where: { $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
                return err(String(format: L("No pinboard named “%@”"), String(name.prefix(60))))
            }
            list = list.filter { $0.boards.contains(b.id) }
        }
        func pick() -> ClipItem? {
            if let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)) { return list.first { $0.id == id } }
            let n = (args["index"] as? Int) ?? 1
            return n >= 1 && n <= list.count ? list[n - 1] : nil
        }
        switch verb {
        case "list":
            let limit = min(200, max(1, (args["limit"] as? Int) ?? 20))
            let rows: [[String: Any]] = list.prefix(limit).enumerated().map { i, c in
                var r: [String: Any] = ["index": i + 1, "id": c.id.uuidString, "kind": c.kind.rawValue, "title": preview(c),
                                        "date": ISO8601DateFormatter().string(from: c.date)]
                if !c.boards.isEmpty { r["boards"] = c.boards.compactMap { id in h.boards.first { $0.id == id }?.displayName } }
                return r
            }
            return ["ok": true, "items": rows]
        case "get":
            guard let c = pick() else { return err(L("No such item")) }
            switch c.kind {
            case .text: return ["ok": true, "text": String(c.text.prefix(ClipCLIWire.maxText))]
            case .files: return ["ok": true, "text": c.paths.joined(separator: "\n")]
            case .image: return err(L("It's an image: use paste, or copy it from the island"))
            }
        case "paste":
            guard let c = pick() else { return err(L("No such item")) }
            var outcome: PasteEngine.Outcome?
            SnippetPaste.paste(c, engine: engine, plain: (args["plain"] as? Bool) == true ? true : nil) { outcome = $0 }
            switch outcome {
            case .pasted?, nil: return ["ok": true]
            case .copied?: return ["ok": true, "note": L("Copied: press ⌘V to paste")]
            case .failed?: return err(L("Can't copy it"))
            }
        case "put":
            guard let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return err(L("Nothing to add"), 64) }
            guard text.utf8.count <= min(ClipCLIWire.maxText, h.settings.maxItemBytes) else { return err(L("Too big")) }
            let snap = ClipSnapshot(types: ["public.utf8-plain-text"], source: "cli", text: text)
            guard case .keep(var item) = ClipRules.decide(snap, settings: h.settings, now: h.now()) else {
                return err(L("Not kept: it looks like a secret or matches an excluded pattern"))
            }
            item.source = nil
            var board: ClipBoard?
            if let name = args["board"] as? String, !name.isEmpty {
                board = h.boards.first { $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                if board == nil { return err(String(format: L("No pinboard named “%@”"), String(name.prefix(60)))) }
            }
            h.add(item)
            guard let added = h.items.first(where: { $0.kind == .text && $0.digest == item.digest }) else { return err(L("Can't copy it")) }
            if let t = args["title"] as? String, !t.isEmpty { h.rename(added.id, t) }
            if let board { h.pin([added.id], to: board.id) }
            if (args["copy"] as? Bool) == true { _ = h.copy(added) }
            return ["ok": true, "id": added.id.uuidString]
        default:
            return err(L("Unknown command"), 64)
        }
    }

    static func preview(_ c: ClipItem) -> String {
        if let t = c.title { return t }
        switch c.kind {
        case .text: return String(c.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").prefix(80))
        case .image: return "\(c.width)×\(c.height)"
        case .files: return c.names.joined(separator: ", ")
        }
    }
}

/// The app's side: listens on clip.sock only while the command line is allowed.
final class ClipServer {
    static let shared = ClipServer()
    private let q = DispatchQueue(label: "local.cocaine.clip.cli")
    private var fd: Int32 = -1
    private var inode: ino_t = 0
    private var source: DispatchSourceRead?
    private var key: Data?
    private var seen: [String: Date] = [:]
    private(set) var path: String?
    /// Answers a verified request (main thread).
    var handle: (String, [String: Any]) -> [String: Any] = { v, a in ClipCLIHandler.reply(v, a, history: .shared, engine: .shared) }
    var running: Bool { fd >= 0 }

    /// Starts (or keeps) listening at `socket` with the key in `keyPath`; false when it can't (the folder isn't safe, another
    /// Cocaine answers there).
    @discardableResult
    func start(socket: String = ClipCLIWire.paths().socket, keyPath: String = ClipCLIWire.paths().key) -> Bool {
        if running { return true }
        let dir = (socket as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return false }
        if st.st_mode & 0o077 != 0 { chmod(dir, 0o700) }
        guard let k = ApprovalKey.loadOrCreate(keyPath) else { return false }
        if lstat(socket, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFSOCK, ApprovalServer.connect(socket) >= 0 { return false }   // another Cocaine
            unlink(socket)
        }
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0, var addr = ApprovalServer.address(socket) else { if s >= 0 { close(s) }; return false }
        // In a 0700 folder nobody else can reach it even before the chmod (umask isn't touched: it is the whole process's).
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { close(s); return false }
        chmod(socket, 0o600)
        guard listen(s, 8) == 0 else { close(s); unlink(socket); return false }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        if lstat(socket, &st) == 0 { inode = st.st_ino }
        fd = s; key = k; path = socket
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: q)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.resume()
        source = src
        return true
    }

    func stop() {
        q.sync {
            source?.cancel(); source = nil
            if fd >= 0 { close(fd); fd = -1 }
            var st = stat()
            if let p = path, lstat(p, &st) == 0, st.st_ino == inode { unlink(p) }   // only our own socket
            path = nil
        }
    }

    private func acceptAll() {
        while true {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); continue }    // only this user
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
            serve(c)
        }
    }

    /// Reads one line (blocking, with a timeout, on the server's queue), answers on the main thread, writes the answer.
    private func serve(_ c: Int32) {
        var buf = Data(), chunk = [UInt8](repeating: 0, count: 65_536)
        while buf.count <= ClipCLIWire.maxRequest, !buf.contains(0x0A) {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
        }
        guard let nl = buf.firstIndex(of: 0x0A), let key else { close(c); return }
        let line = buf[buf.startIndex..<nl]
        let opened = ClipCLIWire.open(Data(line), key: key, now: Date(), seen: &seen)
        let finish: ([String: Any]) -> Void = { [q] reply in
            q.async {
                var d = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{\"ok\":false}".utf8)
                if d.count > ClipCLIWire.maxReply { d = Data("{\"ok\":false,\"error\":\"too big\"}".utf8) }
                d.append(0x0A)
                _ = d.withUnsafeBytes { ApprovalServer.writeAll(c, $0) }
                close(c)
            }
        }
        switch opened {
        case .failure(let r): finish(["ok": false, "error": "refused (\(r))", "code": 77])
        case .success(let req): DispatchQueue.main.async { [weak self] in finish(self?.handle(req.verb, req.args) ?? ["ok": false]) }
        }
    }
}

/// The command's side (`Cocaine --clip …`, run from main.swift through the engine's `cocaine clip`).
enum ClipCLI {
    static let usage = """
    usage: cocaine clip list [--board NAME] [--limit N] [--json]
           cocaine clip get [N | --id ID] [--board NAME]
           cocaine clip put [--board NAME] [--title TITLE] [--copy] [TEXT…]   (no TEXT: read from standard input)
           cocaine clip paste [N | --id ID] [--board NAME] [--plain]
    N counts from 1, newest first (or in the pinboard). Needs Cocaine running with Settings → Island → Clipboard → Command line on.
    """

    /// The parsed arguments: (verb, args, json) or a usage error.
    static func parse(_ a: [String], stdin: () -> String?) -> (verb: String, args: [String: Any], json: Bool)? {
        guard let verb = a.first, ["list", "get", "put", "paste"].contains(verb) else { return nil }
        var args: [String: Any] = [:], json = false, words: [String] = []
        var i = 1
        while i < a.count {
            let x = a[i]
            func value() -> String? { i + 1 < a.count ? a[i + 1] : nil }
            switch x {
            case "--json": json = true
            case "--plain": args["plain"] = true
            case "--copy": args["copy"] = true
            case "--board", "--title", "--id", "--limit":
                guard let v = value() else { return nil }
                if x == "--limit" { guard let n = Int(v) else { return nil }; args["limit"] = n } else { args[String(x.dropFirst(2))] = v }
                i += 1
            case "--": words += a[(i + 1)...]; i = a.count; continue
            default:
                if x.hasPrefix("--") { return nil }
                words.append(x)
            }
            i += 1
        }
        switch verb {
        case "get", "paste":
            if let w = words.first { guard words.count == 1, let n = Int(w), n >= 1 else { return nil }; args["index"] = n }
        case "put":
            let text = words.isEmpty ? stdin() : words.joined(separator: " ")
            guard let t = text, !t.isEmpty else { return nil }
            args["text"] = t
        default:
            if !words.isEmpty { return nil }
        }
        return (verb, args, json)
    }

    /// Sends a request and waits (at most `timeout`) for the answer; nil: Cocaine isn't listening.
    static func send(verb: String, args: [String: Any], socket: String, keyPath: String, timeout: Int = 30) -> [String: Any]? {
        guard let key = ApprovalKey.read(keyPath), let req = ClipCLIWire.request(key: key, verb: verb, args: args) else { return nil }
        let fd = ApprovalServer.connect(socket)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard req.withUnsafeBytes({ ApprovalServer.writeAll(fd, $0) }) else { return nil }
        var buf = Data(), chunk = [UInt8](repeating: 0, count: 65_536)
        while buf.count <= ClipCLIWire.maxReply, !buf.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
        }
        guard let nl = buf.firstIndex(of: 0x0A) else { return nil }
        return (try? JSONSerialization.jsonObject(with: buf[buf.startIndex..<nl])) as? [String: Any]
    }

    /// Runs the command; returns its exit status (0 ok, 64 usage, 65 refused, 69 Cocaine not listening, 77 not allowed).
    static func main(_ a: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        guard let p = parse(a, stdin: readStdin) else { FileHandle.standardError.write(Data((usage + "\n").utf8)); return 64 }
        let paths = ClipCLIWire.paths()
        guard let r = send(verb: p.verb, args: p.args, socket: paths.socket, keyPath: paths.key) else {
            FileHandle.standardError.write(Data("cocaine clip: Cocaine isn't running, or Command line is off (Settings → Island → Clipboard).\n".utf8))
            return 69
        }
        guard r["ok"] as? Bool == true else {
            FileHandle.standardError.write(Data("cocaine clip: \(r["error"] as? String ?? "refused")\n".utf8))
            return Int32((r["code"] as? Int) ?? 65)
        }
        switch p.verb {
        case "list":
            let rows = r["items"] as? [[String: Any]] ?? []
            if p.json, let d = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                FileHandle.standardOutput.write(d); print("")
            } else {
                for row in rows { print("\(row["index"] ?? "")\t\(row["kind"] ?? "")\t\(row["title"] ?? "")") }
            }
        case "get": FileHandle.standardOutput.write(Data((r["text"] as? String ?? "").utf8))
        case "put": if let id = r["id"] as? String { print(id) }
        default: if let n = r["note"] as? String { FileHandle.standardError.write(Data((n + "\n").utf8)) }
        }
        return 0
    }

    private static func readStdin() -> String? {
        guard isatty(0) == 0 else { return nil }
        let d = FileHandle.standardInput.readData(ofLength: ClipCLIWire.maxText + 1)
        guard d.count <= ClipCLIWire.maxText else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// `--clip`, run from main.swift.
func cliClip() { exit(ClipCLI.main(Array(CommandLine.arguments.dropFirst(2)))) }
