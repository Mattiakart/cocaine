import Foundation

/// Keeps one outbound connection per paired phone to the relay and answers what arrives. Nothing listens on this Mac.
/// Each phone's messages are handled one at a time, in order; phones run side by side, and everything that decides
/// whether a command runs (RemoteGatekeeper, RemoteReplayStore) is serialized and saved before the command runs, so a
/// message the relay delivers twice (reconnections, restarts) runs at most once.
final class RemoteListener {
    struct Hooks {
        var store: RemoteReplayStore
        /// Runs an accepted command through the gate (`cocaine remote gate --tier=…`) and returns its output.
        var execute: (_ command: String, _ tier: String) -> String
        /// Posts `body` to `topic` on `relay`; the HTTP status (2xx: the relay took it; 0: no answer at all).
        var publish: (_ body: String, _ topic: String, _ relay: String, _ session: URLSession) async -> Int
        var configuration: () -> URLSessionConfiguration = {
            let c = URLSessionConfiguration.ephemeral
            // The relay sends a keepalive every 45 s: 75 s of silence means the connection is dead (a Wi-Fi change can
            // leave it half-open), so reconnect then rather than miss the phone's commands for minutes.
            c.timeoutIntervalForRequest = 75
            c.waitsForConnectivity = true
            return c
        }
        var now: () -> Date = { Date() }
        var legacyUntil: () -> Date? = { nil }
        var expiredText = "This pairing has expired: send a new Shortcut from the Mac."
        var noticeText = "Cocaine was updated: this Shortcut is no longer accepted. Send a new one from the Mac."
        var willRun: () -> Void = {}                     // e.g. stay awake while it runs and the answer goes out
        /// One line per event for remote-phone.log: "phone <id> <code> <detail>". Never a key, topic, command or answer.
        var note: (String) -> Void = { _ in }
        var backoff: (Double) -> Double = { min($0 * 2, 60) }
        var firstDelay = 2.0
    }

    private let hooks: Hooks
    private var tasks: [String: (pairing: Pairing, task: Task<Void, Never>)] = [:]
    private var up = Set<String>()
    private let lock = NSLock()
    private var ageLimit: () -> Double = { 120 }
    var onChange: ((Bool) -> Void)?                    // is at least one phone's connection up?

    init(hooks: Hooks) { self.hooks = hooks }

    /// How far back a reconnection looks for messages it missed (for the log; anything that old is refused anyway).
    static let catchUp = 3600

    /// How old a command may be and still run, in seconds: longer when the Mac wakes on a schedule to pick them up.
    var maxAge: () -> Double {
        get { lock.lock(); defer { lock.unlock() }; return ageLimit }
        set { lock.lock(); ageLimit = newValue; lock.unlock() }
    }

    /// Starts listening for these pairings and stops (at once) for any other: a revoked phone's messages, even one
    /// being handled right now, are never run or answered after this returns.
    func sync(_ list: [Pairing]) {
        lock.lock()
        for (id, entry) in tasks where !list.contains(entry.pairing) { entry.task.cancel(); tasks[id] = nil; up.remove(id) }
        for p in list where tasks[p.id] == nil { tasks[p.id] = (p, spawn(p)) }
        notify()
        lock.unlock()
        hooks.store.forget(keeping: Set(list.map(\.id)), now: hooks.now().timeIntervalSince1970)
    }

    /// Closes every connection without forgetting anything (the app quitting, a test's "restart").
    func stop() {
        lock.lock(); defer { lock.unlock() }
        for (_, entry) in tasks { entry.task.cancel() }
        tasks = [:]; up = []
    }

    /// Drops the (stale, after sleep) connections and opens fresh ones, resuming where each phone left off.
    func reconnect() {
        lock.lock(); defer { lock.unlock() }
        for (id, entry) in tasks { entry.task.cancel(); tasks[id] = (entry.pairing, spawn(entry.pairing)); up.remove(id) }
        notify()
    }

    func isActive(_ p: Pairing) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tasks[p.id]?.pairing == p
    }

    private func spawn(_ p: Pairing) -> Task<Void, Never> { Task.detached { [weak self] in await self?.run(p) } }

    private func set(_ id: String, _ connected: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard tasks[id] != nil else { return }
        if connected { up.insert(id) } else { up.remove(id) }
        notify()
    }

    private func notify() {
        let any = !up.isEmpty
        DispatchQueue.main.async { self.onChange?(any) }
    }

    /// "phone <first 8 of the pairing id> <code> <detail>"
    static func logLine(_ p: Pairing, _ code: String, _ detail: String = "") -> String {
        "phone \(p.id.prefix(8)) \(code)" + (detail.isEmpty ? "" : " " + detail)
    }
    private func note(_ p: Pairing, _ code: String, _ detail: String = "") { hooks.note(Self.logLine(p, code, detail)) }

    private func run(_ p: Pairing) async {
        let session = URLSession(configuration: hooks.configuration())
        defer { session.invalidateAndCancel() }
        var recent: [Date] = []
        var delay = hooks.firstDelay
        var lastProblem = "", announced = false          // logged once per change, not on every retry
        while !Task.isCancelled {
            // Resume after the last message handled (up to an hour back), so what arrived while the connection was down
            // is seen: what is still fresh runs, what is too old is refused and logged as stale — never skipped unseen.
            // Without a cursor (first start), only what could still run.
            let now = Int(hooks.now().timeIntervalSince1970)
            let floor = now - Int(maxAge()) - 5
            let since = hooks.store.cursor(p.id, now: Double(now)).map { max($0, now - Self.catchUp) } ?? floor
            var problem = "bad relay address"
            if let url = URL(string: "\(p.relay)/\(p.cmd)/json?since=\(since)") {
                do {
                    let (bytes, response) = try await session.bytes(from: url)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    problem = "HTTP \(status)"
                    if status == 200 {
                        delay = hooks.firstDelay
                        set(p.id, true)
                        if !announced { note(p, "relay-up", "listening") }
                        announced = true
                        lastProblem = ""
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            guard line.utf8.count <= 16_384, let m = Self.message(line) else { continue }
                            await handle(m, p, session: session, recent: &recent)
                        }
                        problem = "connection closed"
                    }
                } catch {
                    problem = "connection failed (\((error as NSError).domain) \((error as NSError).code))"
                }
            }
            if Task.isCancelled { break }
            if problem != "connection closed" {          // a plain reconnection is routine; a failure is logged once
                if problem != lastProblem { note(p, "relay-down", problem) }
                lastProblem = problem
                announced = false
            }
            set(p.id, false)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = hooks.backoff(delay)
        }
    }

    private func handle(_ m: (id: String, time: Int, text: String), _ p: Pairing, session: URLSession, recent: inout [Date]) async {
        let now = hooks.now()
        defer { hooks.store.advance(p.id, to: m.time, now: now.timeIntervalSince1970) }
        // No more than 20 messages a minute are even looked at (cheap, but bounded).
        recent = recent.filter { $0.timeIntervalSince(now) > -60 }
        guard recent.count < 20 else { note(p, "rate-limit", "more than 20 commands in a minute"); return }
        let decision = RemoteGatekeeper.evaluate(text: m.text, eventID: m.id, eventTime: m.time, pairing: p, active: isActive(p),
                                                 now: now, maxAge: maxAge(), legacyUntil: hooks.legacyUntil(), store: hooks.store,
                                                 expiredText: hooks.expiredText, noticeText: hooks.noticeText)
        // How old the message says it is (v2), or the relay's time (old Shortcuts): explains stale/future at a glance.
        let ageSeconds = Int((now.timeIntervalSince1970 - (RemoteGatekeeper.sentAt(m.text) ?? Double(m.time))).rounded())
        let age = "age \(ageSeconds) s (limit \(Int(maxAge())) s, \(Int(RemoteProtocol.skew)) s ahead tolerated)"
        var body: String
        switch decision {
        case .drop(let why):
            switch why {
            case .malformed where !p.isLegacy && p.keys == nil: note(p, "bad-pairing", "its key can't be read: send a new Shortcut")
            case .malformed: note(p, why.code, RemoteProtocol.shape(m.text))
            case .stale, .future: note(p, why.code, age)
            case .unauthenticated where !p.isLegacy: note(p, why.code, "not a v2 message (\(RemoteProtocol.shape(m.text)))")
            case .unauthenticated where RemoteProtocol.isV2Command(m.text): note(p, why.code, "v2 message for an old pairing")
            case .unauthenticated: note(p, "legacy-refused", "old Shortcut, already told to update")
            case .badTag: note(p, why.code, "made with another key, or changed on the way")
            default: note(p, why.code)
            }
            return
        case .notice(let text):
            note(p, "legacy-refused", "old Shortcut, told to update")
            body = text
        case .answer(let text, let nonce, let why):
            note(p, why.code, "answered without running")
            guard let keys = p.keys else { return }
            body = RemoteProtocol.sealReply(text, pairingID: p.id, keys: keys, nonce: nonce, now: hooks.now())
        case .run(let command, let tier, let nonce):
            recent.append(now)
            note(p, nonce == nil ? "legacy-accepted" : "accepted", nonce == nil ? "old Shortcut, basic level, unauthenticated" : "\(tier) level, \(age)")
            hooks.willRun()
            let execute = hooks.execute
            let output = await Task.detached { execute(command, tier) }.value
            guard isActive(p) else { note(p, "revoked", "while it ran: no answer"); return }
            if let nonce, let keys = p.keys {
                body = RemoteProtocol.sealReply(output, pairingID: p.id, keys: keys, nonce: nonce, now: hooks.now())
            } else {
                body = String(output.prefix(3500))
            }
        }
        // The same body every time: a retry the relay did receive only means a duplicate the phone ignores.
        var statuses: [String] = []
        for attempt in 0..<3 {
            if !isActive(p) { note(p, "revoked", "before the answer went out"); return }
            let status = await hooks.publish(body, p.reply, p.relay, session)
            if status / 100 == 2 { note(p, "reply-sent", "\(body.utf8.count) bytes, HTTP \(status)"); return }
            statuses.append(status == 0 ? "no connection" : "HTTP \(status)")
            if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000) }
        }
        note(p, "reply-failed", "\(body.utf8.count) bytes, " + statuses.joined(separator: ", "))
    }

    /// A relay event line → the message, or nil for keepalives and anything else.
    static func message(_ line: String) -> (id: String, time: Int, text: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              json["event"] as? String == "message", let id = json["id"] as? String,
              let time = json["time"] as? Int, let text = json["message"] as? String else { return nil }
        return (id, time, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
