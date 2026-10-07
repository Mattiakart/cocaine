// SSH hosts: one connection to one host. Cocaine runs the system's own `/usr/bin/ssh` (so ~/.ssh/config, ProxyJump, keys, the
// ssh agent and known_hosts all work as in Terminal), with host-key checking forced on, no forwarding of any kind, no password
// prompts (BatchMode), keepalives, and the relay as the remote command. No port is opened on the Mac or on the host.
// A pure state machine (SSHLinkMachine) decides when to connect, retry (exponential backoff with jitter, sooner after a wake
// or a network change) or stop and say why (wrong host key, failed login, no relay…). SSHConnection drives one ssh process.

import Foundation

enum SSHFailure: Equatable {
    case auth                       // the login was refused (keys, agent, MFA)
    case hostKeyChanged             // the host's key differs from known_hosts: never connected
    case hostKeyUnknown             // not in known_hosts yet: verify it once in Terminal
    case relayMissing               // no relay there (removed, or never installed)
    case relayOutdated              // an older relay: updated when the user installed it before
    case noPerl                     // perl (with JSON::PP and Digest::SHA) isn't there
    case keyMismatch                // the relay's key isn't this Mac's for that host
    case badAlias
    case network(String)            // couldn't reach it (DNS, refused, timed out…): tried again
    case dropped                    // the connection ended: tried again
    case noAnswer                   // the relay stopped answering: tried again
    case protocolError(String)      // a line that broke the rules: tried again

    var retryable: Bool {
        switch self { case .network, .dropped, .noAnswer, .protocolError: return true; default: return false }
    }
    /// Worth trying again after a wake or a network change (an agent unlocked, a VPN up).
    var retryOnWake: Bool { retryable || self == .auth }

    /// What ssh printed on its standard error (and how it ended), in words the app can act on.
    static func classify(stderr: String, status: Int32) -> SSHFailure {
        let s = stderr
        if s.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || s.range(of: #"Host key for \S+ has changed"#, options: .regularExpression) != nil { return .hostKeyChanged }
        if s.contains("Host key verification failed") || s.range(of: #"No \S+ host key is known for"#, options: .regularExpression) != nil { return .hostKeyUnknown }
        if s.contains("Permission denied (") || s.contains("Too many authentication failures") || s.contains("Authentication failed") { return .auth }
        if s.contains("Can't locate JSON/PP.pm") || s.contains("Can't locate Digest/SHA.pm") || s.contains("Can't locate IO/Socket")
            || s.range(of: #"perl['’]?: (No such file|not found|command not found)"#, options: .regularExpression) != nil { return .noPerl }
        if s.contains("cocaine-relay: no key") { return .keyMismatch }
        if s.contains("cocaine-relay") && (s.contains("not found") || s.contains("No such file") || s.contains("Permission denied")) { return .relayMissing }
        if status == 127 { return .relayMissing }
        if s.contains("Could not resolve hostname") { return .network("dns") }
        let last = s.split(separator: "\n").last.map { String($0.prefix(160)) } ?? ""
        if status == 255 { return .network(last) }
        return last.isEmpty ? .dropped : .network(last)
    }
}

/// What the relay says about itself when a connection starts.
struct SSHHello: Equatable {
    var sha: String
    var os: String
    var perl: String
    var offset: Double            // the host's clock minus the Mac's
}

// MARK: - The state machine

struct SSHLinkMachine: Equatable {
    enum Phase: Equatable { case off, connecting, connected, retrying(Date), stopped(SSHFailure) }
    enum Event: Equatable { case enable, disable, up, down(SSHFailure), tick, wake, network, retry }
    enum Effect: Equatable { case connect, disconnect, schedule(Date), unreachable, reachable, ping }

    var phase = Phase.off
    var attempt = 0
    var connectedAt: Date?
    /// A connection that lasted this long counts as good: the backoff starts again from the beginning after it.
    static let stable: TimeInterval = 60

    /// 2 s, 4 s, 8 s … up to 5 minutes, ± 20 % (`jitter` in -0.2…0.2) so hosts don't all retry at once.
    static func backoff(_ attempt: Int, jitter: Double) -> TimeInterval {
        let base = min(300, 2 * pow(2, Double(max(0, min(attempt, 20) - 1))))
        return base * (1 + max(-0.2, min(0.2, jitter)))
    }

    mutating func handle(_ e: Event, now: Date, jitter: Double = 0) -> [Effect] {
        switch e {
        case .enable:
            switch phase {
            case .off, .stopped: phase = .connecting; attempt = 0; return [.connect]
            default: return []
            }
        case .disable:
            let was = phase
            phase = .off; connectedAt = nil
            return was == .off ? [] : [.disconnect, .unreachable]
        case .up:
            guard phase == .connecting else { return [] }
            phase = .connected; connectedAt = now
            return [.reachable]
        case .down(let f):
            switch phase {
            case .off, .stopped, .retrying: return []
            case .connected, .connecting: break
            }
            if let at = connectedAt, now.timeIntervalSince(at) >= Self.stable { attempt = 0 }
            connectedAt = nil
            if f.retryable {
                attempt += 1
                let at = now.addingTimeInterval(Self.backoff(attempt, jitter: jitter))
                phase = .retrying(at)
                return [.unreachable, .schedule(at)]
            }
            phase = .stopped(f)
            return [.unreachable]
        case .tick:
            if case .retrying(let at) = phase, now >= at { phase = .connecting; return [.connect] }
            return []
        case .wake, .network:
            switch phase {
            case .retrying: phase = .connecting; return [.connect]
            case .stopped(let f) where f.retryOnWake: phase = .connecting; return [.connect]
            case .connected: return [.ping]
            default: return []
            }
        case .retry:
            switch phase {
            case .retrying, .stopped: phase = .connecting; attempt = 0; return [.connect]
            default: return []
            }
        }
    }
}

// MARK: - Running ssh

/// A program on pipes (ssh, or a fake one in the tests). Callbacks on the main queue; `onExit` comes after the last output.
protocol SSHTransport: AnyObject {
    var onOutput: (Data) -> Void { get set }
    var onExit: (_ status: Int32, _ stderr: String) -> Void { get set }
    func start() -> Bool
    func send(_ d: Data)
    func closeInput()
    func stop()
}

final class SSHProcessTransport: SSHTransport {
    var onOutput: (Data) -> Void = { _ in }
    var onExit: (Int32, String) -> Void = { _, _ in }
    private let p = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let wq = DispatchQueue(label: "local.cocaine.ssh.write")
    private var err = Data()
    private var outDone = false, errDone = false, status: Int32?
    private var reported = false
    static let maxStderr = 16 * 1024

    init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        p.standardInput = input; p.standardOutput = output; p.standardError = errors
    }

    func start() -> Bool {
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)    // a dead ssh is an EPIPE, never a SIGPIPE
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                if d.isEmpty { h.readabilityHandler = nil; self.outDone = true; self.finish() } else { self.onOutput(d) }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                if d.isEmpty { h.readabilityHandler = nil; self.errDone = true; self.finish() }
                else if self.err.count < Self.maxStderr { self.err.append(d.prefix(Self.maxStderr - self.err.count)) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let s = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = s
                self.finish()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.outDone = true; self.errDone = true; self.finish() }  // a child kept a pipe open
            }
        }
        do { try p.run() } catch { return false }
        return true
    }

    private func finish() {
        guard !reported, let s = status, outDone, errDone else { return }
        reported = true
        onExit(s, String(decoding: err, as: UTF8.self))
    }

    func send(_ d: Data) {
        let fd = input.fileHandleForWriting.fileDescriptor
        wq.async { d.withUnsafeBytes { _ = ApprovalServer.writeAll(fd, $0) } }
    }

    func closeInput() { wq.async { try? self.input.fileHandleForWriting.close() } }

    func stop() {
        closeInput()
        guard p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.p.isRunning == true { kill(pid, SIGKILL) }
        }
    }
}

/// The ssh command lines. Hosts and ports are their own arguments after "--"; the remote commands are constants (no host, path or
/// user text is ever put in them), in single quotes for the remote login shell (sh, bash, zsh, fish and csh all read them alike).
enum SSHCommand {
    static let serve = #"sh -c 'exec "$HOME/.cocaine/bin/cocaine-relay" serve'"#
    /// Reads the key (first line of stdin), then the relay (the rest); replaces both only once both are written; prints the version.
    static let deploy = #"sh -c 'umask 077 && mkdir -p "$HOME/.cocaine/bin" "$HOME/.cocaine/run" && chmod 700 "$HOME/.cocaine" "$HOME/.cocaine/bin" "$HOME/.cocaine/run" && IFS= read -r k && echo "$k" > "$HOME/.cocaine/relay.key.new" && cat > "$HOME/.cocaine/bin/cocaine-relay.new" && chmod 700 "$HOME/.cocaine/bin/cocaine-relay.new" && mv -f "$HOME/.cocaine/relay.key.new" "$HOME/.cocaine/relay.key" && mv -f "$HOME/.cocaine/bin/cocaine-relay.new" "$HOME/.cocaine/bin/cocaine-relay" && exec "$HOME/.cocaine/bin/cocaine-relay" version'"#

    /// The options for every connection: never a password prompt, the host's key always checked against known_hosts (a changed or
    /// unknown key stops it), no agent, X11 or port forwarding (even if ~/.ssh/config asks for them), no local or remote command
    /// from the config, keepalives. `control`: the master connection the user opened in Terminal (for MFA), if any.
    static func arguments(alias: String, remote: String, control: String? = nil) -> [String]? {
        guard let d = SSHAlias.destination(alias) else { return nil }
        var a = ["-T", "-x", "-a", "-e", "none",
                 "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15",
                 "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                 "-o", "ExitOnForwardFailure=yes", "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
                 "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "ControlMaster=no"]
        if let control, control.hasPrefix("/"), !control.contains("'") { a += ["-S", control] }
        if let p = d.port { a += ["-p", p] }
        return a + ["--", d.dest, remote]
    }

    /// The shell file that opens the master connection in Terminal (login with MFA or a password there; the app then uses it).
    static func terminalScript(alias: String, control: String) -> String? {
        guard let d = SSHAlias.destination(alias), control.hasPrefix("/"), !control.contains("'") else { return nil }
        let port = d.port.map { " -p \($0)" } ?? ""
        return "#!/bin/sh\n# Opened by Cocaine (SSH hosts): log in to \(d.dest) here; Cocaine then connects through this login.\n"
            + "exec /usr/bin/ssh -M -S '\(control)' -o ControlPersist=8h\(port) -- '\(d.dest)'\n"
    }
}

// MARK: - One connection

/// One ssh process to one host: the handshake, the signed lines, keepalives, and the end (exactly one `onEnd`).
final class SSHConnection {
    let host: SSHHost
    private let key: Data
    private let transport: SSHTransport
    private let challenge = ApprovalWire.random(16)
    private var buffer = Data()
    private var noise = 0
    private var lastSeq = -1
    private var outSeq = 0
    private var hello: SSHHello?
    private var ended = false
    private var flood = SSHGuard()
    private var pingSent: Date?
    private var calls: [Int: (Date, ([String: Any]?) -> Void)] = [:]
    private var nextCall = 1
    private var timer: Timer?
    var now: () -> Date = Date.init

    var onHello: (SSHHello) -> Void = { _ in }
    var onFrame: (SSHWire.Frame) -> Void = { _ in }
    var onEnd: (SSHFailure) -> Void = { _ in }
    var isUp: Bool { hello != nil && !ended }

    init(host: SSHHost, key: Data, transport: SSHTransport) {
        self.host = host; self.key = key; self.transport = transport
    }

    func start() {
        transport.onOutput = { [weak self] d in self?.received(d) }
        transport.onExit = { [weak self] status, err in
            guard let self, !self.ended else { return }
            self.end(self.hello == nil ? SSHFailure.classify(stderr: err, status: status) : .dropped)
        }
        guard transport.start() else { end(.network("ssh")); return }
        transport.send(SSHWire.hello(challenge: challenge))
        let t = Timer(timeInterval: min(5, max(0.2, pingWait / 4)), repeats: true) { [weak self] _ in self?.housekeeping() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in    // a login that never finishes
            guard let self, self.hello == nil, !self.ended else { return }
            self.end(.network("timeout"))
        }
    }

    func stop(_ why: SSHFailure = .dropped) {
        guard !ended else { return }
        if hello != nil { _ = send("bye", [:]) }
        end(why)
    }

    private func end(_ why: SSHFailure) {
        guard !ended else { return }
        ended = true
        timer?.invalidate(); timer = nil
        transport.stop()
        let waiting = calls.values.map(\.1)
        calls = [:]
        waiting.forEach { $0(nil) }
        onEnd(why)
    }

    @discardableResult
    func send(_ type: String, _ body: [String: Any]) -> Bool {
        guard !ended, let line = SSHWire.command(type, body, key: key, challenge: challenge, seq: outSeq) else { return false }
        outSeq += 1
        transport.send(line)
        return true
    }

    /// A command with a reply (`r`), or nil after `timeout` or when the connection ends.
    func call(_ type: String, _ body: [String: Any], timeout: TimeInterval = 20, _ done: @escaping ([String: Any]?) -> Void) {
        let r = nextCall; nextCall += 1
        var b = body; b["r"] = r
        guard send(type, b) else { done(nil); return }
        calls[r] = (now().addingTimeInterval(timeout), done)
    }

    func ping() {
        guard isUp, pingSent == nil else { return }
        pingSent = now()
        send("ping", ["n": outSeq])
    }

    /// Keepalive: a ping every `pingEvery` seconds; no pong within `pingWait` ends the connection (and it is tried again).
    var pingEvery: TimeInterval = 30
    var pingWait: TimeInterval = 20
    private var lastPing = Date.distantPast

    private func housekeeping() {
        let t = now()
        if let p = pingSent, t.timeIntervalSince(p) > pingWait { end(.noAnswer); return }
        if pingSent == nil, isUp, t.timeIntervalSince(lastPing) >= pingEvery { lastPing = t; ping() }
        for (r, c) in calls where t >= c.0 { calls[r] = nil; c.1(nil) }
    }

    private func received(_ d: Data) {
        guard !ended else { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(Data(line))
            if ended { return }
        }
        if buffer.count > SSHWire.maxLine { end(.protocolError("long")) }
    }

    private func handle(_ line: Data) {
        switch SSHWire.frame(line, key: key, challenge: challenge, lastSeq: lastSeq) {
        case .failure(.noise):
            noise += line.count + 1
            if noise > SSHWire.maxNoise { end(.protocolError("noise")) }
        case .failure(.badSignature) where hello == nil: end(.keyMismatch)
        case .failure(let e): end(.protocolError(String(describing: e)))
        case .success(let f):
            lastSeq = f.seq
            guard flood.allow(now: now()) else { return }                  // a flood: dropped, the connection stays
            if hello == nil {
                guard f.type == "hello", let o = f.json, o["proto"] as? Int == SSHWire.protocolVersion, let sha = o["sha"] as? String else {
                    end(f.type == "hello" ? .relayOutdated : .protocolError("hello")); return
                }
                let ts = (o["ts"] as? Double) ?? Double(o["ts"] as? Int ?? 0)
                let h = SSHHello(sha: sha, os: String((o["os"] as? String ?? "").prefix(20)), perl: String((o["perl"] as? String ?? "").prefix(20)),
                                 offset: ts - now().timeIntervalSince1970)
                hello = h
                onHello(h)
                return
            }
            switch f.type {
            case "pong": pingSent = nil
            case "file", "put", "probe", "bye":
                if let o = f.json, let r = o["r"] as? Int, let c = calls.removeValue(forKey: r) { c.1(o) }
            default: onFrame(f)
            }
        }
    }

    /// A `hook` frame's message, its hook's signature checked, and checked for replays (its id is new, its clock close to the relay's).
    func hookMessage(_ rest: Data) -> SSHWire.HookMessage? {
        guard let m = SSHWire.hook(rest, key: key), flood.fresh(id: m.id, ts: m.ts, offset: hello?.offset ?? 0, now: now()) else { return nil }
        return m
    }

    func answer(conn: Int, id: String, nonce: String, output: String?) -> Bool {
        send("ans", SSHWire.answer(key: key, conn: conn, id: id, nonce: nonce, output: output))
    }
}
