// `Cocaine --mcp`: the MCP server an AI tool starts (stdio). It is only a bridge: MCP on stdin/stdout (Sources/MCPProtocol.swift),
// and for every call that needs data one short connection to the running app over a private Unix socket (`mcp.sock` in
// Cocaine's 0700 folder, 0600, same user only, mutual HMAC proof with the per-install key `mcp.key`). No TCP port, no HTTP.
// It never starts the app's UI, never touches the clipboard, the Keychain or the user's files itself, and never writes
// anything but MCP messages to stdout: at start the real stdout is set aside for MCP and fd 1 points to stderr, so a stray
// print can't break the protocol. It exits when stdin closes.

import CryptoKit
import Darwin
import Foundation

enum MCPWire {
    static let maxRequest = 256 * 1024
    static let maxReply = 8 << 20

    static func paths(_ env: [String: String] = ProcessInfo.processInfo.environment) -> (socket: String, key: String) {
        let dir = AgentPaths.support(env)
        return (dir.appendingPathComponent("mcp.sock").path, dir.appendingPathComponent("mcp.key").path)
    }

    static func mac(_ key: Data, _ parts: [String]) -> String {
        let msg = Data((["cocaine-mcp-v1"] + parts).joined(separator: "\n").utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))).hex
    }

    /// The app's first line: a fresh challenge.
    static func challenge(_ nonce: String) -> Data { line(["v": 1, "challenge": nonce]) }

    /// The bridge's request: the body (JSON text) with a proof over the challenge, its own nonce and the body.
    static func request(key: Data, challenge: String, cnonce: String, body: String) -> Data {
        line(["v": 1, "cnonce": cnonce, "body": body, "mac": mac(key, ["req", challenge, cnonce, body])])
    }

    /// The app's answer, signed so the bridge knows it came from the app that holds the key.
    static func reply(key: Data, cnonce: String, body: String) -> Data { line(["body": body, "mac": mac(key, ["reply", cnonce, body])]) }

    enum Refusal: Error, Equatable { case malformed, badSignature }

    /// The app's check of a request line: (body object) when well-formed and proven.
    static func open(_ data: Data, key: Data, challenge: String) -> Result<(body: [String: Any], cnonce: String), Refusal> {
        guard data.count <= maxRequest, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], o["v"] as? Int == 1,
              let cnonce = o["cnonce"] as? String, cnonce.count >= 16, cnonce.count <= 64, let body = o["body"] as? String,
              let m = o["mac"] as? String else { return .failure(.malformed) }
        guard ApprovalWire.equal(mac(key, ["req", challenge, cnonce, body]), m) else { return .failure(.badSignature) }
        guard let b = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return .failure(.malformed) }
        return .success((b, cnonce))
    }

    /// The bridge's check of the app's answer.
    static func openReply(_ data: Data, key: Data, cnonce: String) -> [String: Any]? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let body = o["body"] as? String, let m = o["mac"] as? String,
              ApprovalWire.equal(mac(key, ["reply", cnonce, body]), m) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    }

    static func line(_ o: [String: Any]) -> Data {
        var d = (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }

    static func json(_ o: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// Reads up to a newline (at most `max` bytes); nil on EOF, error or timeout.
    static func readLine(_ fd: Int32, max: Int) -> Data? {
        var buf = Data(), chunk = [UInt8](repeating: 0, count: 65_536)
        while buf.count <= max {
            if let nl = buf.firstIndex(of: 0x0A) { return buf[buf.startIndex..<nl] }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            buf.append(contentsOf: chunk[0..<n])
        }
        return nil
    }

    static func setTimeout(_ fd: Int32, _ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// The bridge's backend: one socket connection per call.
final class MCPSocketBackend: MCPBackend {
    let socket: String
    let keyPath: String
    let session = ApprovalWire.random(16)          // this bridge process: "Allow once" lasts as long as it does
    init(socket: String, keyPath: String) { self.socket = socket; self.keyPath = keyPath }

    func call(_ verb: String, _ args: [String: Any], client: MCPClientInfo, token: MCPCancelToken) -> MCPBackendReply {
        guard !token.isCancelled, let key = ApprovalKey.read(keyPath) else { return .unavailable }
        let fd = ApprovalServer.connect(socket)
        guard fd >= 0 else { return .unavailable }
        let closer = FDCloser(fd)
        defer { closer.close() }
        token.onCancel { closer.shutdown() }          // the app sees the end and withdraws its question
        MCPWire.setTimeout(fd, 5)
        guard let first = MCPWire.readLine(fd, max: 4096),
              let o = (try? JSONSerialization.jsonObject(with: first)) as? [String: Any], let challenge = o["challenge"] as? String,
              challenge.count >= 16, challenge.count <= 64 else { return .unavailable }
        let cnonce = ApprovalWire.random(16)
        let body = MCPWire.json(["verb": verb, "args": args, "session": session,
                                 "client": ["name": client.name, "version": client.version, "era": client.era]])
        let req = MCPWire.request(key: key, challenge: challenge, cnonce: cnonce, body: body)
        guard req.count <= MCPWire.maxRequest, req.withUnsafeBytes({ ApprovalServer.writeAll(fd, $0) }) else { return .unavailable }
        MCPWire.setTimeout(fd, Int(MCPLimits.callTimeout))
        guard let line = MCPWire.readLine(fd, max: MCPWire.maxReply) else {
            return token.isCancelled ? .refused("Cancelled", code: "cancelled") : .refused("Cocaine didn't answer in time", code: "timeout")
        }
        guard let r = MCPWire.openReply(line, key: key, cnonce: cnonce) else { return .refused("Cocaine's answer couldn't be verified", code: "refused") }
        if r["ok"] as? Bool == true { return .ok(r) }
        if r["code"] as? String == "off" { return .unavailable }
        return .refused(r["error"] as? String ?? "Refused", code: r["code"] as? String ?? "refused")
    }
}

/// Closes a descriptor once, shuts it down from another thread safely.
final class FDCloser {
    private let lock = NSLock()
    private var fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    func shutdown() { lock.lock(); if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }; lock.unlock() }
    func close() { lock.lock(); if fd >= 0 { Darwin.close(fd); fd = -1 }; lock.unlock() }
}

/// Writes MCP lines to the real stdout, one at a time.
final class MCPWriter {
    private let fd: Int32
    private let lock = NSLock()
    init(fd: Int32) { self.fd = fd }
    func write(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        _ = d.withUnsafeBytes { ApprovalServer.writeAll(fd, $0) }
    }
}

enum MCPBridge {
    /// Runs the bridge until stdin closes.
    static func main(env: [String: String] = ProcessInfo.processInfo.environment) -> Never {
        signal(SIGPIPE, SIG_IGN)
        // stdout is MCP's alone: keep the real one aside, and send anything else written to fd 1 to stderr.
        let out = dup(1)
        guard out >= 0 else { exit(70) }
        _ = fcntl(out, F_SETFD, FD_CLOEXEC)
        dup2(2, 1)
        setvbuf(Darwin.stdout, nil, _IONBF, 0)
        let writer = MCPWriter(fd: out)
        let paths = MCPWire.paths(env)
        let session = MCPSession(backend: MCPSocketBackend(socket: paths.socket, keyPath: paths.key), emit: writer.write)
        var reader = MCPLineReader()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(0, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            for ev in reader.feed(Data(chunk[0..<n])) {
                switch ev {
                case .line(let l): session.receive(l)
                case .tooLong: session.receiveTooLong()
                }
            }
        }
        session.cancelAll()
        exit(0)
    }
}

/// `--mcp`, run from main.swift.
func cliMCP() -> Never { MCPBridge.main() }
