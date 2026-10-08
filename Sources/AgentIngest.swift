// One way onto the board for everything that knows about an AI session: the tools' hooks, Claude Code's session files, CLI
// processes, apps quitting and web-chat tabs (Sources/AgentDetectors.swift). The same session seen several ways is ONE row.
//
// Identity, in this order (`AgentBoard.resolve`):
//   1. the tool's own session id (hooks send it; Claude Code's session file carries the same id) → the row with that id;
//   2. same environment and same process (pid + start time) where a process runs one session at a time (Claude Code, the
//      CLIs): the newer, equally trusted source moves the row to the new id (/clear started a new session in that process);
//      a less trusted one just joins the row it found;
//   3. a web chat's tab address (same environment);
//   4. otherwise a new row: the session id, else "<env>|pid:<pid>", else "<env>|<address>", else "<env>|<project>".
// A session on an SSH host (Sources/SSH*.swift) comes in through the same door with its own key, "ssh.<host id>:<session id>",
// and an origin that names only remote things (AgentOrigin.remoteHost…): it never matches a local row by pid or folder.
// Precedence of sources: hook > session file > process > app > browser tab. A less trusted source changes the state only
// when the row's state came from it or a less trusted one, or the better source has been silent for 10 minutes; it always
// adds what it knows of where the session runs. "Ended" (process gone, app quit, tab closed, SessionEnd) always counts, and
// removes the row unless it is a result to show (done, error), which then fades as usual.

import Foundation

struct AgentSignal: Equatable {
    enum Source: Int, Comparable {
        case browser = 1, app = 2, process = 3, stateFile = 4, hook = 5
        static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }
    enum State: String { case open = "idle", working, waiting, done, error, ended }

    var env: String
    var from: String
    var source: Source
    var state: State
    var session: String? = nil
    var project: String? = nil
    var origin: AgentOrigin? = nil
}

extension AgentBoard {
    /// How long a better source's word stands against a lesser one.
    static let freshness: TimeInterval = 600

    enum Outcome: Equatable {
        case created(String), changed(String, from: String), updated(String), removed(String), ignored
        var key: String? {
            switch self { case .created(let k), .changed(let k, _), .updated(let k), .removed(let k): return k; case .ignored: return nil }
        }
    }

    private static func samePID(_ a: AgentOrigin?, _ b: AgentOrigin?) -> Bool {
        guard let p = a?.pid, p == b?.pid else { return false }
        guard let s1 = a?.pidStart, let s2 = b?.pidStart else { return true }
        return abs(s1 - s2) < 2
    }

    /// The row a signal belongs to (index), and whether it should move to the signal's session id.
    func resolve(_ s: AgentSignal) -> (index: Int, rekey: Bool)? {
        if let id = s.session, let i = entries.firstIndex(where: { $0.id == id }) { return (i, false) }
        if s.origin?.pid != nil, AIEnvironments.oneSessionPerProcess.contains(s.env),
           let i = entries.firstIndex(where: { $0.env == s.env && Self.samePID($0.origin, s.origin) }) {
            let theirs = entries[i].src ?? AgentSignal.Source.hook.rawValue
            return (i, s.session != nil && s.source.rawValue >= theirs)
        }
        if let url = s.origin?.url, let i = entries.firstIndex(where: { $0.env == s.env && $0.origin?.url == url }) { return (i, false) }
        return nil
    }

    static func newKey(_ s: AgentSignal) -> String {
        if let id = s.session { return id }
        if let pid = s.origin?.pid { return "\(s.env)|pid:\(pid)" }
        if let url = s.origin?.url { return "\(s.env)|\(url)" }
        return "\(s.env)|\(s.project ?? "")"
    }

    /// What the signal's state does to a row in `old` state: nil = no change of state.
    static func transition(_ old: String?, _ s: AgentSignal) -> String? {
        switch s.state {
        case .open:
            guard let old else { return "idle" }
            // "Idle" from the session file or a process after work: the reply is complete. From a hook (SessionStart) it's no news.
            if (old == "working" || old == "waiting") && s.source != .hook { return "done" }
            return nil
        case .ended: return nil
        default: return s.state.rawValue
        }
    }

    /// Puts a signal on the board. See the top of this file for identity and precedence.
    @discardableResult
    func ingest(_ s: AgentSignal, now: Date = Date(), alive: (AgentEntry) -> Bool? = AgentBoard.liveness) -> Outcome {
        let t = now.timeIntervalSince1970
        var origin = s.origin.map { $0.isEmpty ? nil : $0 } ?? nil
        if origin?.url == nil, let link = AIEnvironments.deepLink(env: s.env, session: s.session) { // the app opens it by its id
            var o = origin ?? AgentOrigin(); o.url = link; origin = o
        }
        guard let (i, rekey) = resolve(s) else {
            guard s.state != .ended, let state = Self.transition(nil, s) else { return .ignored }
            var e = AgentEntry(id: Self.newKey(s), from: s.from, project: s.project, state: state, since: t, origin: origin)
            e.env = s.env; e.src = s.source.rawValue; e.srcAt = t
            if s.source != .hook { e.seen = t }
            entries.removeAll { $0.id == e.id }
            entries.append(e)
            prune(now, alive: alive)
            return .created(e.id)
        }
        var e = entries[i]
        let old = e.state
        e.unreachable = nil                                                // heard from: its host is reachable (SSH hosts)
        // Refreshed once a minute at most: the board (and state.json, and the island) changes only when something does.
        if s.source != .hook, t - (e.seen ?? 0) >= 60 { e.seen = t }
        let o = (e.origin ?? AgentOrigin()).merged(with: origin)
        e.origin = o.isEmpty ? nil : o
        if e.project == nil { e.project = s.project }
        if e.env == nil { e.env = s.env }
        if s.state == .ended {
            if e.isLive || e.state == "idle" {
                entries.remove(at: i)
                return .removed(e.id)
            }
            entries[i] = e
            return .updated(e.id)
        }
        let theirs = e.src ?? AgentSignal.Source.hook.rawValue
        let stale = t - (e.srcAt ?? e.since) > Self.freshness
        if s.source.rawValue >= theirs || stale || e.restored == true, let state = Self.transition(old, s) {
            if state != old || e.restored == true { e.since = t }
            e.state = state
            e.from = s.from
            e.project = s.project ?? e.project
            if state != old || e.src != s.source.rawValue || s.source == .hook || t - (e.srcAt ?? 0) >= 60 { e.srcAt = t }
            e.src = s.source.rawValue
            e.restored = nil
        } else if s.source.rawValue >= theirs, t - (e.srcAt ?? 0) >= 60 {
            e.srcAt = t                                                    // still heard from: its word stays fresh
            e.restored = nil
        }
        let rowID = e.id
        if rekey, let id = s.session, id != e.id {
            entries.removeAll { $0.id == id }
            e.id = id
        }
        if let j = entries.firstIndex(where: { $0.id == rowID }) { entries[j] = e } else { entries.append(e) }
        prune(now, alive: alive)
        return e.state != old ? .changed(e.id, from: old) : .updated(e.id)
    }

    /// An app quit: the sessions that ran in it and can't be checked by their own process end with it (a desktop app's
    /// threads stayed "working" after it was quit). Returns the rows removed.
    @discardableResult
    func appQuit(_ bundleID: String, alive: (AgentEntry) -> Bool? = AgentBoard.liveness) -> [String] {
        let gone = entries.filter { e in
            (e.isLive || e.state == "idle") && (e.origin?.app == bundleID || e.origin?.browser == bundleID) && alive(e) != true
        }.map(\.id)
        entries.removeAll { gone.contains($0.id) }
        return gone
    }

    /// After a detector's full scan: its open rows (kept up by this source, of these environments) that it didn't see again
    /// have ended (the process quit, the tab closed). Returns the rows removed.
    @discardableResult
    func sweep(source: AgentSignal.Source, envs: Set<String>, seen: Set<String>) -> [String] {
        let gone = entries.filter { e in
            guard let env = e.env, envs.contains(env), e.src == source.rawValue, !seen.contains(e.id) else { return false }
            return e.isLive || e.state == "idle"
        }.map(\.id)
        entries.removeAll { gone.contains($0.id) }
        return gone
    }
}
