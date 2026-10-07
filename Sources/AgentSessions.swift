// AI sessions on the board: where each one runs (to go back to it), its state, the order they are shown in, and the copy on
// disk that survives a restart. Pure logic plus small process lookups; the app wires it up in AppDelegate.swift.

import AppKit
import Darwin

/// Where a session runs, as its hook saw it (environment, parent process) and the app completed it. Every field comes from a
/// local, untrusted caller (anything can open a cocaine:// URL), so `sanitized()` keeps only values of the expected shape:
/// they end up in AppleScript, tmux arguments and file URLs.
struct AgentOrigin: Codable, Equatable {
    var app: String?           // bundle id of the terminal or IDE (Terminal, iTerm2, VS Code…)
    var term: String?          // $TERM_PROGRAM, when the bundle id is missing
    var tty: String?           // "ttys003": the agent's terminal
    var termSession: String?   // iTerm2's session UUID ($ITERM_SESSION_ID / $TERM_SESSION_ID, the part after ':')
    var tmuxPane: String?      // "%3"
    var tmuxSocket: String?    // the tmux server's socket ($TMUX up to the first ',')
    var weztermPane: String?
    var cwd: String?           // the folder the agent runs in (absolute)
    var pid: Int32?            // the agent's own process (the hook's parent)
    var pidStart: Double?      // its start time: tells a reused pid apart
    var url: String?           // a web chat's tab (https, a known chat site only): going back selects that tab
    var browser: String?       // the browser holding that tab (bundle id)
    // More terminals' own ids, for going back to the exact pane (Sources/AgentFocus.swift):
    var kittyWindow: String? = nil     // $KITTY_WINDOW_ID
    var kittyListen: String? = nil     // $KITTY_LISTEN_ON (unix:/path only): kitty's remote-control socket
    var cmuxSurface: String? = nil     // $CMUX_SURFACE_ID
    var cmuxWorkspace: String? = nil   // $CMUX_WORKSPACE_ID
    var cmuxSocket: String? = nil      // $CMUX_SOCKET_PATH
    var zellijSession: String? = nil   // $ZELLIJ_SESSION_NAME
    var zellijPane: String? = nil      // $ZELLIJ_PANE_ID
    var ghosttyTerminal: String? = nil // Ghostty's id of the terminal (asked at the session's start, only if already allowed)

    var isEmpty: Bool { self == AgentOrigin() }

    private static func matches(_ s: String?, _ pattern: String) -> String? {
        guard let s, s.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return s
    }

    /// An absolute socket path (after `prefix`), no "..", only plain characters.
    private static func socketPath(_ s: String?, prefix: String) -> String? {
        guard let s, s.hasPrefix(prefix) else { return nil }
        guard let ok = matches(String(s.dropFirst(prefix.count)), #"^/[A-Za-z0-9._/-]{1,200}$"#), !ok.contains("..") else { return nil }
        return ok
    }

    /// Only well-formed values survive; everything else becomes nil.
    func sanitized() -> AgentOrigin {
        var o = AgentOrigin()
        o.app = Self.matches(app, #"^[A-Za-z0-9][A-Za-z0-9.-]{0,99}$"#)
        o.term = Self.matches(term, #"^[A-Za-z0-9._ -]{1,40}$"#)
        let t = tty.map { $0.hasPrefix("/dev/") ? String($0.dropFirst(5)) : $0 }
        o.tty = Self.matches(t, #"^ttys[0-9]{1,4}$"#)
        let s = termSession.map { $0.split(separator: ":").last.map(String.init) ?? $0 }
        o.termSession = Self.matches(s, #"^[A-Za-z0-9-]{8,64}$"#)
        o.tmuxPane = Self.matches(tmuxPane, #"^%[0-9]{1,6}$"#)
        if let sock = Self.matches(tmuxSocket, #"^/[A-Za-z0-9._/-]{1,200}$"#), !sock.contains("..") { o.tmuxSocket = sock }
        o.weztermPane = Self.matches(weztermPane, #"^[0-9]{1,9}$"#)
        if let c = cwd, c.hasPrefix("/"), c.count <= 1024, !c.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            o.cwd = (c as NSString).standardizingPath
        }
        if let p = pid, p > 1, p < 1_000_000 { o.pid = p }
        if let s = pidStart, s > 0, s.isFinite { o.pidStart = s }
        o.url = url.flatMap(AIEnvironments.safeChatURL)
        o.browser = Self.matches(browser, #"^[A-Za-z0-9][A-Za-z0-9.-]{0,99}$"#).flatMap { AIEnvironments.browsers.contains($0) ? $0 : nil }
        o.kittyWindow = Self.matches(kittyWindow, #"^[0-9]{1,9}$"#)
        o.kittyListen = Self.socketPath(kittyListen, prefix: "unix:").map { "unix:" + $0 }
        o.cmuxSurface = Self.matches(cmuxSurface, #"^[A-Za-z0-9-]{1,64}$"#)
        o.cmuxWorkspace = Self.matches(cmuxWorkspace, #"^[A-Za-z0-9-]{1,64}$"#)
        o.cmuxSocket = Self.socketPath(cmuxSocket, prefix: "")
        o.zellijSession = Self.matches(zellijSession, #"^[A-Za-z0-9._-]{1,64}$"#)
        o.zellijPane = Self.matches(zellijPane, #"^[0-9]{1,6}$"#)
        o.ghosttyTerminal = Self.matches(ghosttyTerminal, #"^[A-Za-z0-9-]{1,64}$"#)
        return o
    }

    /// `newer`'s fields where it has them, ours elsewhere: a later event of the same session can be less complete.
    func merged(with newer: AgentOrigin?) -> AgentOrigin {
        guard let n = newer else { return self }
        var o = self
        if n.pid != nil && n.pid != pid { o.pidStart = nil }          // another process: its start time comes with it
        o.app = n.app ?? app; o.term = n.term ?? term; o.tty = n.tty ?? tty; o.termSession = n.termSession ?? termSession
        o.tmuxPane = n.tmuxPane ?? tmuxPane; o.tmuxSocket = n.tmuxSocket ?? tmuxSocket; o.weztermPane = n.weztermPane ?? weztermPane
        o.cwd = n.cwd ?? cwd; o.pid = n.pid ?? o.pid; o.pidStart = n.pidStart ?? o.pidStart
        o.url = n.url ?? url; o.browser = n.browser ?? browser
        o.kittyWindow = n.kittyWindow ?? kittyWindow; o.kittyListen = n.kittyListen ?? kittyListen
        o.cmuxSurface = n.cmuxSurface ?? cmuxSurface; o.cmuxWorkspace = n.cmuxWorkspace ?? cmuxWorkspace; o.cmuxSocket = n.cmuxSocket ?? cmuxSocket
        o.zellijSession = n.zellijSession ?? zellijSession; o.zellijPane = n.zellijPane ?? zellijPane
        o.ghosttyTerminal = n.ghosttyTerminal ?? ghosttyTerminal
        return o
    }
}

/// What the hooks say each AI session is doing: working, waiting for you, done, or failed. Written to a file the
/// `cocaine remote status` command reads (it uses state, from, project and since; the other keys are optional).
struct AgentEntry: Codable, Identifiable, Equatable {
    var id: String
    var from: String
    var project: String?
    var state: String            // working | waiting | done | error | idle (open, nothing going on)
    var since: Double
    var origin: AgentOrigin?
    var restored: Bool?          // read back from disk at launch, not heard from since
    // Where the row's knowledge comes from (Sources/AgentIngest.swift): the environment (AIEnvironments id), the most
    // trusted source that set its state (AgentSignal.Source) and when, and the last time a detector saw the session.
    var env: String? = nil
    var src: Int? = nil
    var srcAt: Double? = nil
    var seen: Double? = nil
    var isLive: Bool { state == "working" || state == "waiting" }
    var needsYou: Bool { state == "waiting" || state == "error" }

    /// Waiting for you first, then failed, then at work, then finished, then merely open; newest first within each.
    var rank: Int { ["waiting": 0, "error": 1, "working": 2, "done": 3, "idle": 4][state] ?? 5 }
}

/// Process facts from the kernel (no permission needed for the user's own processes).
enum AgentProcess {
    struct Info { let ppid: pid_t; let start: Double; let tty: String?; let uid: uid_t; let name: String }

    static func info(_ pid: pid_t) -> Info? {
        guard pid > 0 else { return nil }
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0, kp.kp_proc.p_pid == pid else { return nil }
        let st = kp.kp_proc.p_starttime
        let dev = kp.kp_eproc.e_tdev
        var tty: String?
        if dev != -1, let n = devname(dev, S_IFCHR) { tty = String(cString: n) }
        let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return Info(ppid: kp.kp_eproc.e_ppid, start: Double(st.tv_sec) + Double(st.tv_usec) / 1e6, tty: tty,
                    uid: kp.kp_eproc.e_ucred.cr_uid, name: name)
    }

    /// Is this exact process (same pid and start time, ours) still running? nil = can't tell.
    static func alive(pid: Int32?, start: Double?) -> Bool? {
        guard let pid, let start else { return nil }
        guard let i = info(pid) else { return false }
        return i.uid == getuid() && abs(i.start - start) < 1
    }

    /// The first app with a window up the parent chain (Terminal, iTerm2, VS Code…), at most 30 steps.
    static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<30 {
            guard p > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            guard let i = info(p) else { return nil }
            p = i.ppid
        }
        return nil
    }

    /// Completes an origin the app got from a hook while the agent is still running: its start time, terminal and app.
    static func complete(_ o: AgentOrigin) -> AgentOrigin {
        var o = o
        guard let pid = o.pid, let i = info(pid), i.uid == getuid() else { o.pid = nil; o.pidStart = nil; return o }
        o.pidStart = i.start
        if o.tty == nil, let t = i.tty, t.hasPrefix("ttys") { o.tty = t }
        if o.app == nil, let id = owningApp(of: pid)?.bundleIdentifier { o.app = id }
        return o.sanitized()
    }
}

final class AgentBoard {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cocaine", isDirectory: true)
    static let defaultFile = directory.appendingPathComponent("state.json")
    static let maxEntries = 100                       // anything can open cocaine://alert: the board can't grow without end
    let file: URL
    var entries: [AgentEntry] = []                    // changed through set, ingest (AgentIngest.swift), prune

    init(file: URL = AgentBoard.defaultFile) { self.file = file }

    /// Is the session's agent still running? nil when the board can't tell (no pid known).
    static func liveness(_ e: AgentEntry) -> Bool? { AgentProcess.alive(pid: e.origin?.pid, start: e.origin?.pidStart) }

    /// Records a session's new state (its time restarts only when the state changes, or when it was only restored).
    func set(_ id: String, from: String, project: String?, state: String, origin: AgentOrigin? = nil, now: Date = Date(),
             alive: (AgentEntry) -> Bool? = AgentBoard.liveness) {
        if let i = entries.firstIndex(where: { $0.id == id }) {
            if entries[i].state != state || entries[i].restored == true { entries[i].since = now.timeIntervalSince1970 }
            entries[i].state = state; entries[i].from = from; entries[i].project = project ?? entries[i].project
            let o = (entries[i].origin ?? AgentOrigin()).merged(with: origin)
            entries[i].origin = o.isEmpty ? nil : o
            entries[i].restored = nil
        } else {
            entries.append(AgentEntry(id: id, from: from, project: project, state: state, since: now.timeIntervalSince1970,
                                      origin: origin.flatMap { $0.isEmpty ? nil : $0 }))
        }
        prune(now, alive: alive)
    }

    /// Finished and failed ones fade after 30 minutes (a finished one whose process still runs becomes "open" instead). A live
    /// one whose process is known to be gone is dropped; one nobody has updated for 2 hours (working) or 6 hours (waiting) is
    /// stale unless its process is known to be running (24 hours). An open (idle) one stays while its process runs, and goes
    /// with it; when its process can't be checked, 30 minutes after a detector last saw it.
    func prune(_ now: Date = Date(), alive: (AgentEntry) -> Bool? = AgentBoard.liveness) {
        let t = now.timeIntervalSince1970
        entries = entries.compactMap { e in
            var e = e
            let age = t - e.since
            if e.state == "idle" {
                switch alive(e) {
                case false?: return nil
                case true?: return e
                case nil: return t - (e.seen ?? e.since) > 1800 ? nil : e
                }
            }
            if !e.isLive {
                guard age > 1800 else { return e }
                if e.state == "done", alive(e) == true { e.state = "idle"; return e }     // finished, but the session is still open
                return nil
            }
            switch alive(e) {
            case false?: return nil
            case true?: return age > 24 * 3600 ? nil : e
            case nil: return age > (e.state == "working" ? 7200 : 6 * 3600) ? nil : e
            }
        }
        if entries.count > Self.maxEntries {                            // the oldest finished ones go first, then the oldest
            let byAge = entries.sorted { ($0.isLive ? 1 : 0, $0.since) < ($1.isLive ? 1 : 0, $1.since) }
            let drop = Set(byAge.prefix(entries.count - Self.maxEntries).map(\.id))
            entries.removeAll { drop.contains($0.id) }
        }
        entries = Self.order(entries)
    }

    static func order(_ list: [AgentEntry]) -> [AgentEntry] {
        list.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.since != b.since { return a.since > b.since }
            return a.id < b.id
        }
    }

    /// Something is working or waiting for the user (what Smart Triggers keep the Mac awake for).
    func anyLive(_ now: Date = Date(), alive: (AgentEntry) -> Bool? = AgentBoard.liveness) -> Bool {
        entries.contains { e in
            guard e.isLive else { return false }
            switch alive(e) {
            case false?: return false
            case true?: return true
            case nil: return now.timeIntervalSince1970 - e.since < 7200
            }
        }
    }

    func entry(_ id: String) -> AgentEntry? { entries.first { $0.id == id } }

    /// Remembers the Ghostty terminal a session started in (AgentFocus goes back to it). False if nothing changed.
    @discardableResult
    func setGhosttyTerminal(_ id: String, _ terminal: String) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return false }
        var o = entries[i].origin ?? AgentOrigin()
        o.ghosttyTerminal = terminal
        o = o.sanitized()
        guard o != entries[i].origin, o.ghosttyTerminal != nil else { return false }
        entries[i].origin = o
        return true
    }

    struct Snapshot: Codable { var updated: Double; var cocaine: String; var until: Double?; var agents: [AgentEntry] }

    /// Atomic (a crash never leaves half a file) and private to the user.
    @discardableResult
    func write(cocaineOn: Bool, until: Date?, now: Date = Date()) -> Bool {
        let snap = Snapshot(updated: now.timeIntervalSince1970, cocaine: cocaineOn ? "ON" : "OFF", until: until?.timeIntervalSince1970, agents: entries)
        guard let data = try? JSONEncoder().encode(snap) else { return false }
        return SafeFile.writePrivate(data, to: file)                     // 0600 from the first byte (it was briefly umask's)
    }

    /// At launch: what the board held before the app quit, marked as restored, minus what has gone stale or whose process is
    /// gone. A damaged file restores nothing (and is replaced by the next write).
    func restore(now: Date = Date(), alive: (AgentEntry) -> Bool? = AgentBoard.liveness) {
        guard let data = try? Data(contentsOf: file), let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        var seen = Set<String>()
        let t = now.timeIntervalSince1970
        entries = snap.agents.compactMap { e in
            guard !seen.contains(e.id), !e.id.isEmpty, e.id.count <= 200, e.since.isFinite, e.since <= t + 60 else { return nil }
            seen.insert(e.id)
            var e = e
            e.restored = true
            e.origin = e.origin?.sanitized()
            return e
        }
        prune(now, alive: alive)
    }
}

/// A cocaine://alert URL's parameters, cleaned: values are short and free of control (and text-direction) characters, the
/// session id keeps only safe characters, and the origin only well-formed values.
struct AlertParams {
    var from = "Cocaine"
    var event = "done"
    var session: String?
    var project: String?
    var message: String?
    var running: Int?
    var token: String?
    var test: String?
    var origin = AgentOrigin()

    static func parse(_ url: URL, userName: String = NSUserName()) -> AlertParams {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String, _ limit: Int = 80) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value else { return nil }
            let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map {
                $0.value < 32 || $0.value == 127 || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) ? " " : $0 }))
            let clean = String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespaces)
            return clean.isEmpty ? nil : clean
        }
        var p = AlertParams()
        p.from = value("from") ?? "Cocaine"
        p.event = value("event") ?? "done"
        p.project = value("project").flatMap { $0 == "/" || $0 == userName ? nil : $0 }    // not a real project
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        p.session = value("session").map { String(String.UnicodeScalarView($0.unicodeScalars.filter { safe.contains($0) })) }.flatMap { $0.isEmpty ? nil : $0 }
        p.message = value("message", 200)
        p.running = value("running").flatMap(Int.init).map { min(max($0, 0), 10_000) }
        p.token = value("token")
        p.test = value("test")
        p.origin = AgentOrigin(app: value("app"), term: value("term"), tty: value("tty"), termSession: value("tsid"),
                               tmuxPane: value("tmux"), tmuxSocket: value("tmuxs", 220), weztermPane: value("wez"),
                               cwd: value("cwd", 1024), pid: value("pid").flatMap { Int32($0) },
                               kittyWindow: value("kitty"), kittyListen: value("kittys", 220), cmuxSurface: value("cmux"),
                               cmuxWorkspace: value("cmuxw"), cmuxSocket: value("cmuxs", 220), zellijSession: value("zj"),
                               zellijPane: value("zjp")).sanitized()
        return p
    }

    /// The board's key: the tool's session id, or (tools that don't send one) one per AI and folder.
    var sessionKey: String { session ?? "\(from)|\(project ?? "")" }
}

/// The same event for the same session twice within a short time (a tool that fires a hook twice, a duplicated URL) is one.
struct AlertDeduper {
    private var last: [String: Date] = [:]
    mutating func isDuplicate(_ key: String, now: Date = Date(), window: TimeInterval = 2) -> Bool {
        last = last.filter { now.timeIntervalSince($0.value) < 60 }
        defer { last[key] = now }
        if let t = last[key], now.timeIntervalSince(t) < window { return true }
        return false
    }
}
