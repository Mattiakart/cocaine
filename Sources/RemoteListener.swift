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
        /// Posts `body` to `topic` on `relay`; true when the relay took it.
        var publish: (_ body: String, _ topic: String, _ relay: String, _ session: URLSession) async -> Bool
        var configuration: () -> URLSessionConfiguration = {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 150            // the relay sends a keepalive every 45 s
            c.waitsForConnectivity = true
            return c
        }
        var now: () -> Date = { Date() }
        var legacyUntil: () -> Date? = { nil }
        var expiredText = "This pairing has expired: send a new Shortcut from the Mac."
        var noticeText = "Cocaine was updated: this Shortcut is no longer accepted. Send a new one from the Mac."
        var willRun: () -> Void = {}                     // e.g. stay awake while it runs and the answer goes out
        var note: (String) -> Void = { _ in }            // a log line (never the command itself)
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

    private func run(_ p: Pairing) async {
        let session = URLSession(configuration: hooks.configuration())
        defer { session.invalidateAndCancel() }
        var recent: [Date] = []
        var delay = hooks.firstDelay
        while !Task.isCancelled {
            // Resume after the last message handled, but never earlier than what could still run.
            let now = Int(hooks.now().timeIntervalSince1970)
            let floor = now - Int(maxAge()) - 5
            let since = max(hooks.store.cursor(p.id, now: Double(now)) ?? floor, floor)
            if let url = URL(string: "\(p.relay)/\(p.cmd)/json?since=\(since)") {
                do {
                    let (bytes, response) = try await session.bytes(from: url)
                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                        delay = hooks.firstDelay
                        set(p.id, true)
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            guard line.utf8.count <= 16_384, let m = Self.message(line) else { continue }
                            await handle(m, p, session: session, recent: &recent)
                        }
                    }
                } catch {}
            }
            if Task.isCancelled { break }
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
        guard recent.count < 20 else { hooks.note("phone message dropped: rate limit"); return }
        let decision = RemoteGatekeeper.evaluate(text: m.text, eventID: m.id, eventTime: m.time, pairing: p, active: isActive(p),
                                                 now: now, maxAge: maxAge(), legacyUntil: hooks.legacyUntil(), store: hooks.store,
                                                 expiredText: hooks.expiredText, noticeText: hooks.noticeText)
        var body: String
        switch decision {
        case .drop(let why):
            hooks.note("phone message refused: \(why.rawValue)")
            return
        case .notice(let text):
            hooks.note("old Shortcut refused (told to update)")
            body = text
        case .answer(let text, let nonce):
            guard let keys = p.keys else { return }
            body = RemoteProtocol.sealReply(text, pairingID: p.id, keys: keys, nonce: nonce, now: hooks.now())
        case .run(let command, let tier, let nonce):
            recent.append(now)
            hooks.note(nonce == nil ? "old Shortcut command accepted (basic, unauthenticated)" : "phone command accepted")
            hooks.willRun()
            let execute = hooks.execute
            let output = await Task.detached { execute(command, tier) }.value
            guard isActive(p) else { return }                 // revoked while it ran: say nothing more
            if let nonce, let keys = p.keys {
                body = RemoteProtocol.sealReply(output, pairingID: p.id, keys: keys, nonce: nonce, now: hooks.now())
            } else {
                body = String(output.prefix(3500))
            }
        }
        // The same body every time: a retry the relay did receive only means a duplicate the phone ignores.
        for attempt in 0..<3 {
            if !isActive(p) { return }
            if await hooks.publish(body, p.reply, p.relay, session) { return }
            try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000)
        }
        hooks.note("answer to the phone could not be sent")
    }

    /// A relay event line → the message, or nil for keepalives and anything else.
    static func message(_ line: String) -> (id: String, time: Int, text: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              json["event"] as? String == "message", let id = json["id"] as? String,
              let time = json["time"] as? Int, let text = json["message"] as? String else { return nil }
        return (id, time, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
