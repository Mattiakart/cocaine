// The detectors beyond the hooks: Claude Code's session files, CLI processes started in a terminal, apps starting and quitting,
// and (opt-in) the chat sites' tabs in the browsers. Each turns what it sees into AgentSignals for the one ingestion path
// (Sources/AgentIngest.swift); AIEnvironmentCenter runs them and tells the AI tab what is installed and running.
// Nothing here reads a conversation: Claude Code's session file gives its id, folder, process and busy/idle state (its
// "name", derived from the conversation, is never read); a browser is asked only for the addresses of chat-site tabs.

import AppKit
import Darwin

// MARK: - Claude Code's session files (~/.claude/sessions/<pid>.json)

/// Claude Code (2.1.x, seen on 2.1.292) keeps one small JSON file per running session, named after its process: pid, sessionId,
/// cwd, status ("busy" while it works, "idle" when it waits for the next prompt), statusUpdatedAt, kind, entrypoint, procStart.
/// Undocumented: every field is optional here, and an unknown status only says the session is open.
enum ClaudeSessionFiles {
    struct Record: Equatable {
        var pid: Int32
        var session: String
        var cwd: String?
        var status: String?
        var entrypoint: String?
        var procStart: Double?          // the process's start, from "Wed Oct  7 08:51:59 2026" (UTC)
    }

    private static let startFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    static func parseStart(_ s: String) -> Double? {
        let one = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return startFormat.date(from: one)?.timeIntervalSince1970
    }

    /// Only the fields above; nil unless it has a pid and a session id of a safe shape.
    static func parse(_ data: Data) -> Record? {
        guard data.count < 64 * 1024, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let pid = (j["pid"] as? NSNumber)?.int32Value, pid > 1,
              let sid = j["sessionId"] as? String, sid.range(of: #"^[A-Za-z0-9._:-]{1,100}$"#, options: .regularExpression) != nil else { return nil }
        let status = (j["status"] as? String).flatMap { $0.range(of: #"^[A-Za-z_ -]{1,40}$"#, options: .regularExpression) != nil ? $0.lowercased() : nil }
        return Record(pid: pid, session: sid, cwd: j["cwd"] as? String, status: status,
                      entrypoint: (j["entrypoint"] as? String).map { String($0.prefix(40)) },
                      procStart: (j["procStart"] as? String).flatMap(parseStart))
    }

    /// busy → working; idle → open (after work: completed); anything that says it waits for a permission or an answer → waiting.
    static func state(_ status: String?) -> AgentSignal.State {
        guard let s = status else { return .open }
        if s == "busy" || s == "running" || s == "working" { return .working }
        if ["wait", "input", "permission", "approval", "question"].contains(where: { s.contains($0) }) { return .waiting }
        return .open
    }

    static func env(_ entrypoint: String?) -> String {
        (entrypoint ?? "").lowercased().contains("desktop") ? "claude-desktop-code" : "claude-code"
    }

    /// The process behind a record: running, ours, and the same one (start time within 2 s, or named claude when the file has
    /// no start time). Its kernel start time, or nil when it is gone.
    static func liveStart(_ r: Record, info: (pid_t) -> AgentProcess.Info? = AgentProcess.info) -> Double? {
        guard let i = info(r.pid), i.uid == getuid() else { return nil }
        if let s = r.procStart { return abs(i.start - s) < 2 ? i.start : nil }
        return i.name.lowercased().contains("claude") ? i.start : nil
    }

    /// One signal per file: the session and its state, or "ended" for a file left by a process that is gone.
    static func scan(_ dir: URL, info: (pid_t) -> AgentProcess.Info? = AgentProcess.info,
                     complete: (AgentOrigin) -> AgentOrigin = AgentProcess.complete) -> [AgentSignal] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.prefix(200).compactMap { name in
            guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path), let r = parse(data),
                  name == "\(r.pid).json" else { return nil }
            let env = env(r.entrypoint)
            var s = AgentSignal(env: env, from: "Claude Code", source: .stateFile, state: state(r.status), session: r.session,
                                project: r.cwd.map { ($0 as NSString).lastPathComponent })
            guard let start = liveStart(r, info: info) else { s.state = .ended; return s }
            s.origin = complete(AgentOrigin(cwd: r.cwd, pid: r.pid, pidStart: start).sanitized())
            return s
        }
    }
}

// MARK: - CLI processes

enum ProcessDetector {
    struct Fact: Equatable {
        var pid: pid_t
        var name: String
        var path: String?
        var parentName: String?
        var tty: String?
        var start: Double
        var cwd: String?
    }

    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "nu", "xonsh", "tcsh", "csh", "ksh", "dash", "login", "tmux", "screen", "-zsh", "-bash"]

    /// An interactive session: a known CLI, started from a shell on a terminal (an MCP server or an app's helper is not one).
    static func signal(_ f: Fact) -> AgentSignal? {
        guard let env = AIEnvironments.forProcess(name: f.name, path: f.path), let e = AIEnvironments.env(env),
              let tty = f.tty, tty.hasPrefix("ttys"), let parent = f.parentName, shells.contains(parent) else { return nil }
        return AgentSignal(env: env, from: e.name, source: .process, state: .open, session: nil,
                           project: f.cwd.map { ($0 as NSString).lastPathComponent },
                           origin: AgentOrigin(tty: tty, cwd: f.cwd, pid: f.pid, pidStart: f.start).sanitized())
    }

    static let names: Set<String> = Set(AIEnvironments.all.flatMap(\.executables))

    /// This Mac's candidates (the user's own processes with a known CLI's name).
    static func facts() -> [Fact] {
        ProcessList.all().filter { names.contains($0.name) }.compactMap { p in
            guard let i = AgentProcess.info(p.pid), i.uid == getuid() else { return nil }
            return Fact(pid: p.pid, name: p.name, path: path(p.pid), parentName: AgentProcess.info(i.ppid)?.name, tty: i.tty,
                        start: i.start, cwd: cwd(p.pid))
        }
    }

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return path.hasPrefix("/") ? path : nil
    }
}

// MARK: - Web chats in the browsers (opt-in)

enum BrowserTabs {
    /// The chat tabs of one running browser, as signals; nil when it can't be asked (no Automation permission, or an error).
    static func scan(_ browser: String, run: (String, String) -> String? = BrowserTabs.runScript) -> [AgentSignal]? {
        guard let script = AIEnvironments.scanScript(browser), let out = run(script, browser) else { return nil }
        return AIEnvironments.parseScan(out).compactMap { tab in
            guard let e = AIEnvironments.env(tab.env) else { return nil }
            return AgentSignal(env: tab.env, from: e.name, source: .browser, state: .open,
                               origin: AgentOrigin(url: tab.url, browser: browser).sanitized())
        }
    }

    /// Never asks: a browser not allowed yet is skipped (the question comes only when the user turns the feature on).
    static func runScript(_ source: String, _ browser: String) -> String? {
        guard AgentFocus.automation(browser, ask: false) == 0 else { return nil }
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil ? (r?.stringValue ?? "") : nil
    }
}

// MARK: - The center: runs the detectors, knows what is installed and running

final class AIEnvironmentCenter: ObservableObject {
    static let shared = AIEnvironmentCenter()

    /// Environments whose app is installed, and whose app (or CLI process) is running now.
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var running: Set<String> = []
    /// The opt-in for web chats (it needs Automation for each browser, asked when it is turned on).
    @Published var webChats: Bool = AppDefaults.store.bool(forKey: "aiWebChats") {
        didSet {
            guard webChats != oldValue else { return }
            AppDefaults.store.set(webChats, forKey: "aiWebChats")
            if webChats { Permissions.askBrowsers() }
        }
    }

    /// A detector's batch: its signals, then (for full scans) the rows of its environments it didn't see again have ended.
    struct Batch { var signals: [AgentSignal]; var source: AgentSignal.Source; var envs: Set<String>; var full: Bool }
    var onBatch: (Batch) -> Void = { _ in }
    var onAppQuit: (String) -> Void = { _ in }

    var claudeSessions = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
    private var timer: Timer?
    private var ticks = 0
    private let queue = DispatchQueue(label: "local.cocaine.ai-detectors", qos: .utility)
    private var busy = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard timer == nil else { return }
        let c = NSWorkspace.shared.notificationCenter
        observers.append(c.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let id = app.bundleIdentifier else { return }
            self?.onAppQuit(id)
            self?.refreshRunning()
        })
        observers.append(c.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRunning()
        })
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// Installed apps (a LaunchServices lookup each) and running ones; for the AI tab.
    func refresh() {
        var inst = Set<String>()
        for e in AIEnvironments.all where !e.bundleIDs.isEmpty {
            if e.bundleIDs.contains(where: { !$0.hasSuffix("*") && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) { inst.insert(e.id) }
        }
        if installed != inst { installed = inst }
        refreshRunning()
    }

    private var processEnvs = Set<String>()
    private func refreshRunning() {
        let ids = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        var run = processEnvs
        for e in AIEnvironments.all where ids.contains(where: e.matchesBundle) { run.insert(e.id) }
        if running != run { running = run }
    }

    private func tick() {
        ticks += 1
        guard !busy, !PowerAwareness.shared.paused else { return }
        busy = true
        let dir = claudeSessions
        let browsers = webChats && ticks % 3 == 1
            ? AIEnvironments.browsers.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } : []
        let webOff = !webChats
        queue.async { [weak self] in
            var batches: [Batch] = []
            batches.append(Batch(signals: ClaudeSessionFiles.scan(dir), source: .stateFile, envs: ["claude-code", "claude-desktop-code"], full: true))
            let procs = ProcessDetector.facts().compactMap(ProcessDetector.signal)
            batches.append(Batch(signals: procs, source: .process, envs: Set(AIEnvironments.all.filter { !$0.executables.isEmpty }.map(\.id)), full: true))
            let webEnvs = Set(AIEnvironments.all.filter { $0.kind == .web }.map(\.id))
            if webOff {
                batches.append(Batch(signals: [], source: .browser, envs: webEnvs, full: true))   // turned off: the tab rows go
            } else if !browsers.isEmpty {
                var all: [AgentSignal] = []
                var complete = true
                for b in browsers { if let s = BrowserTabs.scan(b) { all += s } else { complete = false } }
                batches.append(Batch(signals: all, source: .browser, envs: webEnvs, full: complete))
            }
            let procEnvs = Set(procs.map(\.env))
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if self.processEnvs != procEnvs { self.processEnvs = procEnvs; self.refreshRunning() }
                batches.forEach(self.onBatch)
            }
        }
    }
}
