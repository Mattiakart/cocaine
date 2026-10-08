// SSH hosts: the wire between Cocaine and the relay it runs on a remote machine (relay/cocaine-relay, a perl script) over the
// user's own `/usr/bin/ssh` (Sources/SSHConnection.swift). Pure: framing, signatures, replay and size limits, and turning what a
// remote hook sent into what the rest of the app already understands (an approval request, an alert, a board signal).
//
// Lines, one JSON object or token list each, newline-ended:
//   Mac → relay   `hello <challenge>` once, then `<mac> <seq> <type> <json>`, mac = HMAC(key, "cocaine-ssh-cmd-v1\n<challenge>\n<seq>\n<type>\n<json>")
//   relay → Mac   `@@CR1 <mac> <seq> <type> <rest>`, mac = HMAC(key, "cocaine-ssh-frame-v1\n<challenge>\n<seq>\n<type>\n<rest>")
// The challenge is new for every connection and both sides want strictly growing sequence numbers, so nothing can be
// replayed; anything else on the relay's output (a login banner, a shell's noise) is ignored; a line with a bad signature
// ends the connection. A hook's own line (inside a `hook` frame) is signed again by the hook: HMAC(key,
// "cocaine-ssh-hook-v1\n<json>"); the answer to a request is signed over the hook's own id and nonce:
// HMAC(key, "cocaine-ssh-answer-v1\n<id>\n<nonce>\n<base64 of the hook's output>"). The key is per host, 32 random bytes made
// on the Mac, kept in the Keychain, and written to ~/.cocaine/relay.key (0600) on the host at deploy time (through ssh's stdin,
// never in a command line).

import CommonCrypto
import Foundation

enum SSHWire {
    static let magic = Array("@@CR1 ".utf8)
    static let protocolVersion = 1
    /// The longest line the Mac reads from a relay (a request's input is at most 1 MB before base64).
    static let maxLine = 2_600_000
    /// How much of the relay's output that is not a frame (banners) is tolerated before giving up on the connection.
    static let maxNoise = 64 * 1024

    static func hmac(_ key: Data, _ message: Data) -> String {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { k in message.withUnsafeBytes { m in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), k.baseAddress, key.count, m.baseAddress, message.count, &out)
        } }
        return Data(out).hex
    }

    static func hmac(_ key: Data, _ message: String) -> String { hmac(key, Data(message.utf8)) }

    static func sha256(_ d: Data) -> String {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        d.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(d.count), &out) }
        return Data(out).hex
    }

    static func newKey() -> Data? {
        var b = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess else { return nil }
        return Data(b)
    }

    // MARK: Mac → relay

    static func hello(challenge: String) -> Data { Data("hello \(challenge)\n".utf8) }

    /// One signed command line.
    static func command(_ type: String, _ body: [String: Any], key: Data, challenge: String, seq: Int) -> Data? {
        guard type.range(of: #"^[a-z]{2,12}$"#, options: .regularExpression) != nil,
              let json = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]),
              !json.contains(0x0A) else { return nil }
        let text = String(decoding: json, as: UTF8.self)
        let mac = hmac(key, "cocaine-ssh-cmd-v1\n\(challenge)\n\(seq)\n\(type)\n\(text)")
        return Data("\(mac) \(seq) \(type) ".utf8) + json + Data([0x0A])
    }

    // MARK: relay → Mac

    struct Frame: Equatable {
        var seq: Int
        var type: String
        var rest: Data
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: rest)) as? [String: Any] }
        static func == (a: Frame, b: Frame) -> Bool { a.seq == b.seq && a.type == b.type && a.rest == b.rest }
    }

    enum FrameError: Error, Equatable { case noise, badSignature, replay, tooLong, malformed }

    /// Reads one line of the relay's output. `noise` for lines that aren't frames (ignored); any other error ends the connection.
    static func frame(_ line: Data, key: Data, challenge: String, lastSeq: Int) -> Result<Frame, FrameError> {
        guard line.count <= maxLine else { return .failure(.tooLong) }
        let b = [UInt8](line)
        guard b.starts(with: magic) else { return .failure(.noise) }
        var i = magic.count
        func token() -> String? {
            let start = i
            while i < b.count, b[i] != 0x20 { i += 1 }
            guard i < b.count, i > start else { return nil }
            defer { i += 1 }
            return String(decoding: b[start..<i], as: UTF8.self)
        }
        guard let mac = token(), mac.count == 64, let seqText = token(), let seq = Int(seqText), seq >= 0, seq < 1 << 50,
              let type = token(), type.range(of: #"^[a-z]{2,12}$"#, options: .regularExpression) != nil else { return .failure(.malformed) }
        let rest = Data(b[i...])
        var signed = Data("cocaine-ssh-frame-v1\n\(challenge)\n\(seq)\n\(type)\n".utf8)
        signed.append(rest)
        guard ApprovalWire.equal(mac.lowercased(), hmac(key, signed)) else { return .failure(.badSignature) }
        guard seq > lastSeq else { return .failure(.replay) }
        return .success(Frame(seq: seq, type: type, rest: rest))
    }

    // MARK: A hook's line

    struct HookMessage: Equatable {
        var conn: Int
        var id: String
        var nonce: String
        var request: Bool
        var ts: Double
        var tool: String
        var kind: String
        var sid: String?
        var env: [String: String]
        var pid: Int32?
        var input: Data?
        var cut: Bool
    }

    static let tools: Set<String> = ["claude", "codex", "gemini", "qwen", "cursor"]
    static let kinds: Set<String> = ["done", "input", "error", "start", "open", "end", "agentstart", "agentstop", "approve", "plan"]

    /// A `hook` frame's rest: `<conn> <hook mac> <json>`, the hook's own signature checked, every field of the expected shape.
    static func hook(_ rest: Data, key: Data) -> HookMessage? {
        let b = [UInt8](rest)
        guard let s1 = b.firstIndex(of: 0x20), let conn = Int(String(decoding: b[..<s1], as: UTF8.self)), conn > 0 else { return nil }
        let after = b[(s1 + 1)...]
        guard let s2 = after.firstIndex(of: 0x20) else { return nil }
        let mac = String(decoding: after[..<s2], as: UTF8.self)
        let json = Data(after[(s2 + 1)...])
        guard mac.count == 64, ApprovalWire.equal(mac.lowercased(), hmac(key, Data("cocaine-ssh-hook-v1\n".utf8) + json)) else { return nil }
        return message(json, conn: conn)
    }

    /// The fields of a hook's (or a backlog's) JSON, checked.
    static func message(_ json: Data, conn: Int) -> HookMessage? {
        guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any], o["v"] as? Int == 1,
              let t = o["t"] as? String, ["req", "evt"].contains(t),
              let tool = o["tool"] as? String, tools.contains(tool), let kind = o["kind"] as? String, kinds.contains(kind) else { return nil }
        let request = t == "req"
        guard request == (kind == "approve") else { return nil }
        let id = o["id"] as? String ?? ""
        let nonce = o["nonce"] as? String ?? ""
        if request || conn > 0 {
            guard id.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil,
                  nonce.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil else { return nil }
        }
        var env: [String: String] = [:]
        for (k, v) in o["env"] as? [String: Any] ?? [:] {
            guard ["SSH_CONNECTION", "TMUX", "TMUX_PANE", "PWD", "TERM_PROGRAM", "ZELLIJ_SESSION_NAME", "ZELLIJ_PANE_ID"].contains(k),
                  let s = v as? String, s.count <= 400 else { continue }
            env[k] = s
        }
        let sid = (o["sid"] as? String).flatMap { $0.range(of: #"^[A-Za-z0-9._:-]{1,80}$"#, options: .regularExpression) != nil ? $0 : nil }
        let pid = (o["pid"] as? Int).flatMap { $0 > 1 && $0 < 1 << 31 ? Int32($0) : nil }
        let input = (o["in"] as? String).flatMap { Data(base64Encoded: $0) }
        return HookMessage(conn: conn, id: id, nonce: nonce, request: request, ts: (o["ts"] as? Double) ?? Double(o["ts"] as? Int ?? 0),
                           tool: tool, kind: kind, sid: sid, env: env, pid: pid, input: input, cut: o["cut"] as? Bool == true)
    }

    /// The `ans` command's body for a request: the hook prints `output` (nil = nothing: the tool asks in its terminal).
    static func answer(key: Data, conn: Int, id: String, nonce: String, output: String?) -> [String: Any] {
        let out = output.map { Data($0.utf8).base64EncodedString() } ?? ""
        return ["c": conn, "id": id, "out": out, "mac": hmac(key, "cocaine-ssh-answer-v1\n\(id)\n\(nonce)\n\(out)")]
    }

    /// What the remote hook prints for the user's reply: the very same output the local hook would (ApprovalWire.hookOutput,
    /// which reads the tool's input for anything echoed), or nil. "none" (handed back, expired) is nil.
    static func hookOutput(decision: String, content: String?, id: String, nonce: String, tool: String, input: [String: Any]) -> String? {
        guard decision != "none", let k = newKey() else { return nil }
        let line = ApprovalWire.answer(key: k, id: id, nonce: nonce, decision: decision, content: content)
        return ApprovalWire.hookOutput(answer: line.dropLast(), key: k, id: id, nonce: nonce, tool: tool, input: input)
    }
}

/// Replays and floods: the ids a host's hooks already used (a request id seen twice is refused), the hooks' clocks against the
/// relay's, and a token bucket on what a host may send.
struct SSHGuard {
    private var seen: [String: Date] = [:]
    private var tokens: Double
    private var last: Date
    let burst: Double
    let perSecond: Double
    static let maxSkew: TimeInterval = 600

    init(burst: Double = 200, perSecond: Double = 25, now: Date = Date()) {
        self.burst = burst; self.perSecond = perSecond; tokens = burst; last = now
    }

    /// True when this frame may be handled now (one token per frame).
    mutating func allow(now: Date) -> Bool {
        tokens = min(burst, tokens + now.timeIntervalSince(last) * perSecond)
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    /// A hook message's id is new and its clock close to the relay's (`offset` = relay clock − Mac clock at hello).
    mutating func fresh(id: String, ts: Double, offset: Double, now: Date) -> Bool {
        if seen.count > 4000 { seen = seen.filter { now.timeIntervalSince($0.value) < 3600 } }
        guard !id.isEmpty, seen[id] == nil else { return false }
        guard abs(ts - offset - now.timeIntervalSince1970) <= Self.maxSkew else { return false }
        seen[id] = now
        return true
    }
}

// MARK: - From a remote hook to what the app knows

enum SSHEvents {
    static func toolName(_ id: String) -> String {
        ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI", "qwen": "Qwen Code", "cursor": "Cursor"][id] ?? "AI"
    }

    /// The board's key of a remote session: `ssh.<host id>:<the tool's session id>` (never the same as a local one).
    static func sessionKey(host: SSHHost, sid: String?, tool: String, project: String?) -> String {
        // Only the characters a session id keeps everywhere (ApprovalRequest.make, AlertParams), and at most 80 in all.
        let raw = sid ?? "\(tool)-\((project ?? "") as NSString).lastPathComponent)"
        let safe = String(raw.unicodeScalars.filter { ($0.isASCII && (CharacterSet.alphanumerics.contains($0))) || "._:-".unicodeScalars.contains($0) }.prefix(68).map(Character.init))
        return "ssh.\(host.id):" + safe
    }

    /// Where a remote session runs, as the Mac can use it: the host, the remote folder (for its name), the remote process (asked
    /// through the relay whether it still runs) and the ssh connection's addresses (to find the local tab: Sources/SSHJump.swift).
    /// Nothing the Mac would take as a local process, terminal or folder.
    static func origin(_ m: SSHWire.HookMessage, host: SSHHost) -> AgentOrigin {
        var o = AgentOrigin()
        o.remoteHost = host.id
        o.remoteCwd = m.env["PWD"]
        o.remotePid = m.pid
        o.sshConnection = m.env["SSH_CONNECTION"]
        o.remoteTmuxPane = m.env["TMUX_PANE"]
        o.remoteTmuxSocket = m.env["TMUX"].map { String($0.split(separator: ",").first ?? "") }
        return o.sanitized()
    }

    /// The remote folder's name with the host's: "api · devbox".
    static func project(_ m: SSHWire.HookMessage, input: [String: Any]?, host: SSHHost) -> String {
        let cwd = m.env["PWD"] ?? input?["cwd"] as? String ?? ""
        let name = (cwd as NSString).lastPathComponent
        let folder = name.isEmpty || name == "/" ? nil : ApprovalRequest.clean(name, 60)
        return [folder, host.label].compactMap { $0 }.joined(separator: " · ")
    }

    /// A remote request as the notch shows it: the same review as a local one, its session keyed by host.
    static func request(_ m: SSHWire.HookMessage, input: [String: Any], host: SSHHost, now: Date) -> ApprovalRequest? {
        guard m.request, ["claude", "codex"].contains(m.tool), ApprovalHook.handles(tool: m.tool, input) else { return nil }
        var bounded = ApprovalHook.bounded(input)
        let key = sessionKey(host: host, sid: AgentEventHook.sessionID(input) ?? m.sid, tool: m.tool, project: nil)
        bounded["session_id"] = key
        bounded["cwd"] = nil                                            // a remote folder is never opened on the Mac
        guard var r = ApprovalRequest.make(id: m.id, nonce: m.nonce, tool: m.tool, input: bounded, origin: origin(m, host: host), now: now) else { return nil }
        r.project = project(m, input: input, host: host)
        r.session = key
        return r
    }

    /// A remote hook's news as an alert link would carry it, plus its text for the session card (kinds with text).
    static func alert(_ m: SSHWire.HookMessage, input: [String: Any]?, host: SSHHost) -> (params: AlertParams, extra: [String: Any]?)? {
        guard !m.request else { return nil }
        var p = AlertParams()
        p.from = toolName(m.tool)
        p.session = sessionKey(host: host, sid: input.flatMap(AgentEventHook.sessionID) ?? m.sid, tool: m.tool, project: m.env["PWD"])
        p.project = project(m, input: input, host: host)
        p.origin = origin(m, host: host)
        var extra: [String: Any]?
        if ["done", "error", "input", "plan"].contains(m.kind), let input {
            let e = AgentEventHook.event(kind: m.kind, input: input)
            extra = e
            p.running = (e["running"] as? Int).map { min(max($0, 0), 10_000) }
        }
        switch m.kind {
        case "error":
            p.event = "error"
            p.message = AgentExtra.errorText(extra?["error"] as? String ?? "unknown")
        case "input":
            // Only the kinds that mean "it waits for you" (as for a local session: AppDelegate.agentEvent).
            let n = extra?["notification"] as? String
            guard n == nil || ["permission_prompt", "elicitation_dialog", "agent_needs_input"].contains(n!) else { return nil }
            p.event = "input"
        case "plan": p.event = "start"
        default: p.event = m.kind
        }
        return (p, extra)
    }

    /// News kept while the Mac was away (the relay's backlog): only the latest state of each session, for the board, no alert.
    static func late(_ list: [SSHWire.HookMessage], host: SSHHost) -> [(session: String, from: String, project: String, state: String, origin: AgentOrigin)] {
        var latest: [String: SSHWire.HookMessage] = [:]
        var order: [String] = []
        for m in list where !m.request {
            let key = sessionKey(host: host, sid: m.sid, tool: m.tool, project: m.env["PWD"])
            if latest[key] == nil { order.append(key) }
            if (latest[key]?.ts ?? 0) <= m.ts { latest[key] = m }
        }
        return order.compactMap { key in
            guard let m = latest[key] else { return nil }
            let state: String
            switch m.kind {
            case "end": state = "ended"
            case "open": state = "idle"
            case "start", "agentstart", "plan": state = "working"
            case "input": state = "waiting"
            case "error": state = "error"
            case "done": state = "done"
            default: return nil
            }
            return (key, toolName(m.tool), project(m, input: nil, host: host), state, origin(m, host: host))
        }
    }
}
