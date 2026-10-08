// SSH hosts: every host's connection, what its relay sends (requests to the notch, news to the alerts and the board), the
// answers going back, the relay's installation and its hooks there (each only after the user's OK), and the kill switches.
// The app wires the callbacks in AppDelegate.startApprovals; the Settings card is Sources/SSHHostsView.swift.

import AppKit
import Network

struct SSHHostStatus: Equatable {
    var phase: SSHLinkMachine.Phase = .off
    var hello: SSHHello?
    var hooksOn: [String] = []        // tools with Cocaine's hooks there (read from their files)
    var present: [String] = []        // tools found there
    var failure: SSHFailure?          // the last thing that went wrong (deploy, hooks), if it still stands
    var note: String?                 // the last thing done, in words
    var working = false               // installing, reading or writing there
}

struct SSHReview: Equatable {
    var host: String
    var plan: SSHInstallPlan
}

final class SSHHostManager: ObservableObject {
    static let shared = SSHHostManager()

    @Published private(set) var store = SSHHostStore()
    @Published private(set) var status: [String: SSHHostStatus] = [:]
    @Published var review: SSHReview?

    // What the tests replace.
    var support = AgentPaths.support()
    var keys: SSHKeyStore = SSHKeychainKeys()
    var sshPath = "/usr/bin/ssh"
    var environment: [String: String]? = nil
    var relayScript: Data? = SSHHostManager.bundledRelay()
    var makeTransport: (_ executable: String, _ args: [String], _ env: [String: String]?) -> SSHTransport = {
        SSHProcessTransport(executable: $0, arguments: $1, environment: $2)
    }
    var jitter: () -> Double = { Double.random(in: -0.2...0.2) }
    var tune: (SSHConnection) -> Void = { _ in }
    var watchSystem = true                       // wake and network notifications (off in tests)

    // The app's side (AppDelegate.startApprovals).
    var onRequest: (ApprovalRequest) -> Void = { _ in }
    var onAlert: (_ params: AlertParams, _ extra: [String: Any]?) -> Void = { _, _ in }
    var onBoard: (_ session: String, _ from: String, _ project: String, _ state: String, _ origin: AgentOrigin) -> Void = { _, _, _, _, _ in }
    var onGone: (_ id: String) -> Void = { _ in }
    var onReachable: (_ host: String, _ reachable: Bool) -> Void = { _, _ in }
    var onRemoved: (_ host: String) -> Void = { _ in }
    var remotePids: (_ host: String) -> [Int32] = { _ in [] }

    private var machines: [String: SSHLinkMachine] = [:]
    private var conns: [String: SSHConnection] = [:]
    private struct Pending { var host: String; var conn: Int; var nonce: String; var tool: String; var input: [String: Any] }
    private var pending: [String: Pending] = [:]
    private var alive: [String: [Int32: Bool]] = [:]
    private var downSince: [String: Date] = [:]
    private var lastAlivePoll: [String: Date] = [:]
    private var controlSeen: [String: Bool] = [:]
    private var ticker: Timer?
    private var path: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    static func bundledRelay() -> Data? {
        Bundle.main.url(forResource: "cocaine-relay", withExtension: nil).flatMap { try? Data(contentsOf: $0) }
    }
    var relaySHA: String { relayScript.map(SSHWire.sha256) ?? "" }

    func host(_ id: String?) -> SSHHost? { store.hosts.first { $0.id == id } }
    func isUp(_ id: String) -> Bool { conns[id]?.isUp == true }
    var anyConfigured: Bool { !store.hosts.isEmpty }
    /// Connected as the state machine says (what the UI shows; the operations check the connection itself).
    func connected(_ id: String) -> Bool { status[id]?.phase == .connected }
    var connectedCount: Int { store.hosts.filter { connected($0.id) }.count }

    // MARK: Life

    func start() {
        guard !started else { return }
        started = true
        store = SSHHostStore.load(support)
        status = Dictionary(uniqueKeysWithValues: store.hosts.map { ($0.id, SSHHostStatus()) })
        AgentBoard.remoteLiveness = { [weak self] e in self?.liveness(e) ?? (e.unreachable == true ? true : nil) }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        if watchSystem {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.everyHost(.wake)
            })
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] p in
                guard p.status == .satisfied else { return }
                DispatchQueue.main.async { self?.everyHost(.network) }
            }
            m.start(queue: DispatchQueue.global(qos: .utility))
            path = m
        }
        for h in store.hosts where wanted(h) { drive(h.id, .enable) }
    }

    /// Everything closed (the app quits): waiting hooks see their connection end, and their terminals ask.
    func stop() {
        ticker?.invalidate(); ticker = nil
        path?.cancel(); path = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        for (_, c) in conns { c.stop() }
        conns = [:]
        started = false
    }

    private func wanted(_ h: SSHHost) -> Bool { store.enabled && h.enabled && h.deployed }
    private func isOff(_ id: String) -> Bool { (machines[id]?.phase ?? .off) == .off }

    private func everyHost(_ e: SSHLinkMachine.Event) { for h in store.hosts { drive(h.id, e) } }

    private func tick() {
        let now = Date()
        for h in store.hosts {
            drive(h.id, .tick)
            if isUp(h.id), now.timeIntervalSince(lastAlivePoll[h.id] ?? .distantPast) >= 60 { pollAlive(h.id) }
            // A login just opened in Terminal (Connect in Terminal): try again through it at once.
            let has = FileManager.default.fileExists(atPath: controlPath(h.id))
            if has && controlSeen[h.id] != true, case .stopped? = machines[h.id]?.phase, wanted(h) { drive(h.id, .retry) }
            controlSeen[h.id] = has
        }
    }

    // MARK: The state machine's effects

    func drive(_ id: String, _ e: SSHLinkMachine.Event) {
        guard host(id) != nil else { return }
        var m = machines[id] ?? SSHLinkMachine()
        let effects = m.handle(e, now: Date(), jitter: jitter())
        machines[id] = m
        update(id) { $0.phase = m.phase }
        for fx in effects {
            switch fx {
            case .connect: connect(id)
            case .disconnect:
                if let c = conns.removeValue(forKey: id) { c.stop() }
            case .schedule: break
            case .unreachable:
                if downSince[id] == nil { downSince[id] = Date() }
                handBackAll(host: id)
                onReachable(id, false)
            case .reachable:
                downSince[id] = nil
                onReachable(id, true)
                afterConnect(id)
            case .ping: conns[id]?.ping()
            }
        }
    }

    private func update(_ id: String, _ f: (inout SSHHostStatus) -> Void) {
        var s = status[id] ?? SSHHostStatus()
        f(&s)
        if status[id] != s { status[id] = s }
    }

    func controlPath(_ id: String) -> String {
        let p = SSHHostStore.folder(support).appendingPathComponent("c-\(id)").path
        return p.utf8.count <= 80 ? p : NSHomeDirectory() + "/.ssh/cocaine-\(id)"   // a Unix socket's path has room for ~100 bytes
    }

    private func connect(_ id: String) {
        guard let h = host(id) else { return }
        conns.removeValue(forKey: id)?.stop()
        guard let key = keys.load(id) else { drive(id, .down(.keyMismatch)); return }
        let control = FileManager.default.fileExists(atPath: controlPath(id)) ? controlPath(id) : nil
        guard let args = SSHCommand.arguments(alias: h.alias, remote: SSHCommand.serve, control: control) else { drive(id, .down(.badAlias)); return }
        let c = SSHConnection(host: h, key: key, transport: makeTransport(sshPath, args, environment))
        tune(c)
        c.onHello = { [weak self, weak c] hello in
            guard let self, let c, self.conns[id] === c else { return }
            self.hello(id, c, hello)
        }
        c.onFrame = { [weak self, weak c] f in
            guard let self, let c, self.conns[id] === c else { return }
            self.frame(id, c, f)
        }
        c.onEnd = { [weak self, weak c] why in
            guard let self, let c, self.conns[id] === c else { return }
            self.conns[id] = nil
            self.audit(id, "disconnected (\(Self.word(why)))")
            self.drive(id, .down(why))
            if why == .relayOutdated { self.updateRelay(id) }
        }
        conns[id] = c
        audit(id, "connecting")
        c.start()
    }

    private func hello(_ id: String, _ c: SSHConnection, _ h: SSHHello) {
        update(id) { $0.hello = h }
        guard h.sha == relaySHA else {                       // an older (or newer) relay there: put this one instead (onEnd)
            audit(id, "relay differs from this app's")
            c.stop(.relayOutdated)
            return
        }
        audit(id, "connected")
        update(id) { $0.failure = nil }
        drive(id, .up)
    }

    /// A relay of another version there (its hello named another protocol, or another file): this app's goes in its place, only
    /// where the user installed one before, and at most once in 10 minutes per host (a relay that still differs after its
    /// update then stays stopped with the reason shown, never a loop of installs).
    private var relayUpdatedAt: [String: Date] = [:]
    static let relayUpdateEvery: TimeInterval = 600

    private func updateRelay(_ id: String) {
        guard host(id)?.deployed == true else { return }
        let now = Date()
        if let last = relayUpdatedAt[id], now.timeIntervalSince(last) < Self.relayUpdateEvery { return }
        relayUpdatedAt[id] = now
        deploy(id)
    }

    private func afterConnect(_ id: String) {
        pollAlive(id)
        refreshHooks(id)
    }

    // MARK: What the relay sends

    private func frame(_ id: String, _ c: SSHConnection, _ f: SSHWire.Frame) {
        guard let h = host(id) else { return }
        switch f.type {
        case "hook":
            guard let m = c.hookMessage(f.rest) else { audit(id, "refused a hook line (bad signature or replay)"); return }
            let input = m.input.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            if m.request {
                guard store.enabled, let input, let r = SSHEvents.request(m, input: input, host: h, now: Date()) else {
                    _ = c.answer(conn: m.conn, id: m.id, nonce: m.nonce, output: nil)   // the terminal asks
                    return
                }
                pending[m.id] = Pending(host: id, conn: m.conn, nonce: m.nonce, tool: m.tool, input: input)
                audit(id, "request \(r.kind.rawValue) from \(m.tool) (\(m.id.prefix(8)))")
                onRequest(r)
            } else if let (p, extra) = SSHEvents.alert(m, input: input, host: h) {
                onAlert(p, extra)
            }
        case "late":
            guard let m = SSHWire.message(f.rest, conn: 0) else { return }
            for s in SSHEvents.late([m], host: h) { onBoard(s.session, s.from, s.project, s.state, s.origin) }
        case "gone":
            if let rid = f.json?["id"] as? String, pending[rid]?.host == id { pending[rid] = nil; onGone(rid) }
        case "alive":
            var map: [Int32: Bool] = [:]
            for (k, v) in f.json?["pids"] as? [String: Any] ?? [:] { if let p = Int32(k) { map[p] = (v as? Int ?? 0) == 1 } }
            alive[id] = map
            onReachable(id, true)                          // the board prunes with the new answers
        default: break
        }
    }

    private func pollAlive(_ id: String) {
        lastAlivePoll[id] = Date()
        let pids = remotePids(id)
        guard !pids.isEmpty else { return }
        conns[id]?.send("alive", ["pids": pids.prefix(200).map { Int($0) }])
    }

    /// A remote session's process: true while its host is unreachable (kept, for up to 6 hours), else what its relay said.
    func liveness(_ e: AgentEntry) -> Bool? {
        guard let h = e.origin?.remoteHost else { return nil }
        if !isUp(h) {                                    // down since when it dropped; never connected here: the usual rules
            guard let since = downSince[h] else { return nil }
            return Date().timeIntervalSince(since) < 6 * 3600 ? true : nil
        }
        guard let pid = e.origin?.remotePid else { return nil }
        return alive[h]?[pid]
    }

    // MARK: Answers

    func owns(_ id: String) -> Bool { pending[id] != nil }

    /// The user's answer (already accepted by the ApprovalStore) as the remote hook prints it; false if that hook is gone.
    func reply(_ id: String, decision: String, content: String?, done: @escaping (Bool) -> Void = { _ in }) {
        guard let p = pending.removeValue(forKey: id), let c = conns[p.host], c.isUp else { DispatchQueue.main.async { done(false) }; return }
        let out = SSHWire.hookOutput(decision: decision, content: content, id: id, nonce: p.nonce, tool: p.tool, input: p.input)
        let sent = c.answer(conn: p.conn, id: id, nonce: p.nonce, output: out)
        audit(p.host, "answer \(decision == "none" ? "handed back to the terminal" : decision) (\(id.prefix(8)))")
        DispatchQueue.main.async { done(sent && (out != nil || decision == "none")) }
    }

    private func handBackAll(host id: String) {
        for (rid, p) in pending where p.host == id { pending[rid] = nil; onGone(rid) }
    }

    // MARK: The user's actions

    enum AddError: Error, Equatable { case invalid, duplicate, full }

    @discardableResult
    func add(alias raw: String, name: String? = nil) -> Result<SSHHost, AddError> {
        let alias = raw.trimmingCharacters(in: .whitespaces)
        guard SSHAlias.destination(alias) != nil else { return .failure(.invalid) }
        guard !store.hosts.contains(where: { $0.alias == alias }) else { return .failure(.duplicate) }
        guard store.hosts.count < SSHHostStore.maxHosts else { return .failure(.full) }
        let h = SSHHost(id: SSHHost.newID(taken: Set(store.hosts.map(\.id))), alias: alias, name: name, added: Date().timeIntervalSince1970)
        store.hosts.append(h)
        store.save(support)
        status[h.id] = SSHHostStatus()
        audit(h.id, "added")
        return .success(h)
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = store.hosts.firstIndex(where: { $0.id == id }) else { return }
        store.hosts[i].enabled = on
        store.save(support)
        audit(id, on ? "turned on" : "turned off")
        drive(id, wanted(store.hosts[i]) ? .enable : .disable)
    }

    /// The global switch: off closes every connection.
    func setAllEnabled(_ on: Bool) {
        store.enabled = on
        store.save(support)
        audit(nil, on ? "SSH hosts turned on" : "SSH hosts turned off")
        for h in store.hosts { drive(h.id, wanted(h) ? .enable : .disable) }
    }

    func retry(_ id: String) {
        guard let h = host(id), wanted(h) else { return }
        update(id) { $0.failure = nil }
        relayUpdatedAt[id] = nil                                // the user's own try: an outdated relay may be updated again
        drive(id, isOff(id) ? .enable : .retry)
    }

    /// Puts the relay (and this Mac's key for it) on the host; only after the user said yes (or to update one they installed).
    func deploy(_ id: String, done: @escaping (Bool) -> Void = { _ in }) {
        guard let h = host(id), let script = relayScript, status[id]?.working != true else { done(false); return }
        let existing = keys.load(id)
        guard let key = existing ?? SSHWire.newKey(), existing != nil || keys.save(id, key) else {
            update(id) { $0.note = L("Couldn't keep the host's key in the Keychain.") }
            done(false); return
        }
        let control = FileManager.default.fileExists(atPath: controlPath(id)) ? controlPath(id) : nil
        guard let args = SSHCommand.arguments(alias: h.alias, remote: SSHCommand.deploy, control: control) else { done(false); return }
        update(id) { $0.working = true; $0.note = L("Installing the relay…") }
        audit(id, existing == nil ? "installing the relay (new key)" : "installing the relay")
        let t = makeTransport(sshPath, args, environment)
        var out = Data()
        var finished = false
        let want = "cocaine-relay \(SSHWire.protocolVersion) \(relaySHA)"
        t.onOutput = { out.append($0.prefix(max(0, 4096 - out.count))) }
        t.onExit = { [weak self] status, err in
            guard let self, !finished else { return }
            finished = true
            self.update(id) { $0.working = false }
            if status == 0, String(decoding: out, as: UTF8.self).contains(want) {
                if let i = self.store.hosts.firstIndex(where: { $0.id == id }) { self.store.hosts[i].deployed = true; self.store.save(self.support) }
                self.audit(id, "relay installed")
                self.update(id) { $0.note = L("Relay installed."); $0.failure = nil }
                if let h = self.host(id), self.wanted(h) { self.drive(id, self.isOff(id) ? .enable : .retry) }
                done(true)
            } else {
                let f = SSHFailure.classify(stderr: err, status: status)
                self.audit(id, "relay install failed (\(Self.word(f)))")
                self.update(id) { $0.failure = f; $0.note = nil }
                done(false)
            }
        }
        guard t.start() else { finished = true; update(id) { $0.working = false; $0.failure = .network("ssh") }; done(false); return }
        t.send(Data(key.hex.utf8) + Data([0x0A]) + script)
        t.closeInput()
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { if !finished { t.stop() } }
    }

    /// Reads the hooks' files there and says which tools have Cocaine's hooks.
    func refreshHooks(_ id: String) {
        guard let c = conns[id], c.isUp else { return }
        c.call("probe", [:], timeout: 30) { [weak self] probe in
            guard let self, let probe else { return }
            let present = (probe["tools"] as? [String: Any] ?? [:]).compactMap { ($0.value as? Bool) == true ? $0.key : nil }.sorted()
            self.update(id) { $0.present = present }
            let tools = SSHInstaller.tools(present: Set(AIHooks.remoteIDs), claudeVersion: nil)
            self.fetch(c, SSHInstaller.paths(tools)) { files in
                let on = SSHInstaller.hooksOn(files: files)
                self.update(id) { $0.hooksOn = on }
            }
        }
    }

    private func fetch(_ c: SSHConnection, _ paths: [String], _ done: @escaping ([String: SSHRemoteFile]) -> Void) {
        var files: [String: SSHRemoteFile] = [:]
        func step(_ i: Int) {
            guard i < paths.count else { done(files); return }
            c.call("get", ["path": paths[i]]) { o in
                if let o, let f = SSHInstaller.file(o), f.path == paths[i] { files[f.path] = f }
                step(i + 1)
            }
        }
        step(0)
    }

    /// What adding the hooks there would change: shown to the user (`review`) before anything is written.
    func reviewHooks(_ id: String) {
        guard let c = conns[id], c.isUp else { update(id) { $0.note = L("Connect to the host first.") }; return }
        update(id) { $0.working = true; $0.note = L("Reading the AI tools' settings there…") }
        c.call("probe", [:], timeout: 30) { [weak self] probe in
            guard let self else { return }
            guard let probe else { self.update(id) { $0.working = false; $0.note = L("The host didn't answer.") }; return }
            let present = Set((probe["tools"] as? [String: Any] ?? [:]).compactMap { ($0.value as? Bool) == true ? $0.key : nil })
            let tools = SSHInstaller.tools(present: present, claudeVersion: probe["claude"] as? String)
            self.fetch(c, SSHInstaller.paths(tools)) { files in
                let plan = SSHInstaller.plan(on: true, tools: tools, files: files)
                self.update(id) { $0.working = false; $0.note = nil; $0.present = present.sorted() }
                self.review = SSHReview(host: id, plan: plan)
            }
        }
    }

    /// The user said yes to the review: the changes are written there, all or none.
    func applyReview(done: @escaping (Bool) -> Void = { _ in }) {
        guard let r = review else { done(false); return }
        review = nil
        apply(r.host, r.plan, done: done)
    }

    /// Removes Cocaine's hooks there (no review needed: it only takes Cocaine's own lines out).
    func removeHooks(_ id: String, done: @escaping (Bool) -> Void = { _ in }) {
        guard let c = conns[id], c.isUp else { done(false); return }
        let tools = SSHInstaller.tools(present: Set(AIHooks.remoteIDs), claudeVersion: nil)
        update(id) { $0.working = true }
        fetch(c, SSHInstaller.paths(tools)) { [weak self] files in
            guard let self else { return }
            self.update(id) { $0.working = false }
            self.apply(id, SSHInstaller.plan(on: false, tools: tools, files: files), done: done)
        }
    }

    private func apply(_ id: String, _ plan: SSHInstallPlan, done: @escaping (Bool) -> Void) {
        guard let c = conns[id], c.isUp else { update(id) { $0.note = L("The host isn't connected: nothing was changed.") }; done(false); return }
        let ws = SSHInstaller.writes(plan)
        var undo: [SSHInstaller.Write] = []
        update(id) { $0.working = true }
        func finish(_ ok: Bool, _ why: String?) {
            update(id) {
                $0.working = false
                $0.note = ok ? (plan.on ? L("Hooks added there.") : L("Hooks removed there.")) : String(format: L("Nothing was changed there (%@)."), why ?? "?")
            }
            audit(id, (plan.on ? "hooks added" : "hooks removed") + (ok ? "" : " FAILED, rolled back") + ": " + plan.changes.map(\.path).joined(separator: ", "))
            if ok, let i = store.hosts.firstIndex(where: { $0.id == id }) {
                let touched = Set(plan.changes.map(\.tool) + plan.unchanged)
                store.hosts[i].hooks = plan.on ? Array(Set(store.hosts[i].hooks).union(touched)).sorted() : Array(Set(store.hosts[i].hooks).subtracting(touched)).sorted()
                store.save(support)
            }
            refreshHooks(id)
            done(ok)
        }
        func rollback(_ list: [SSHInstaller.Write], _ why: String) {
            guard let w = list.first else { finish(false, why); return }
            c.call("put", SSHInstaller.body(w, r: 0)) { o in
                if o?["ok"] as? Bool != true { self.audit(id, "rollback of \(w.path) failed: put it back from ~/.cocaine/backup there") }
                rollback(Array(list.dropFirst()), why)
            }
        }
        func step(_ i: Int) {
            guard i < ws.count else { finish(true, nil); return }
            c.call("put", SSHInstaller.body(ws[i].apply, r: 0)) { o in
                if o?["ok"] as? Bool == true { undo.insert(ws[i].undo, at: 0); step(i + 1) }
                else { rollback(undo, (o?["err"] as? String) ?? "no answer") }
            }
        }
        step(0)
    }

    /// Removes the host. `cleanUp`: first takes Cocaine's hooks and ~/.cocaine off it (it must be connected).
    func remove(_ id: String, cleanUp: Bool, done: @escaping (Bool) -> Void = { _ in }) {
        guard host(id) != nil else { done(false); return }
        func forget() {
            drive(id, .disable)
            conns.removeValue(forKey: id)?.stop()
            keys.delete(id)
            audit(id, "removed")
            store.hosts.removeAll { $0.id == id }
            store.save(support)
            status[id] = nil; machines[id] = nil; alive[id] = nil; downSince[id] = nil; relayUpdatedAt[id] = nil
            try? FileManager.default.removeItem(atPath: SSHHostStore.folder(support).appendingPathComponent("\(id).command").path)
            onRemoved(id)
            done(true)
        }
        guard cleanUp else { forget(); return }
        guard let c = conns[id], c.isUp else { update(id) { $0.note = L("Connect to the host first, or remove it from Cocaine only.") }; done(false); return }
        removeHooks(id) { [weak self] ok in
            guard let self else { return }
            guard ok else { done(false); return }
            c.call("uninstall", [:]) { o in
                if o?["ok"] as? Bool == true { self.audit(id, "relay removed there"); forget() }
                else { self.update(id) { $0.note = L("The relay couldn't be removed there.") }; done(false) }
            }
        }
    }

    /// For a login that needs the user (MFA, a password): Terminal opens one master connection; Cocaine then uses it.
    func connectInTerminal(_ id: String) -> Bool {
        guard let h = host(id), let script = SSHCommand.terminalScript(alias: h.alias, control: controlPath(id)) else { return false }
        let url = SSHHostStore.folder(support).appendingPathComponent("\(id).command")
        guard SafeFile.writePrivate(Data(script.utf8), to: url) else { return false }
        chmod(url.path, 0o700)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentFocus.terminal) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: cfg)
        audit(id, "login opened in Terminal")
        return true
    }

    /// tmux on the host: the session's pane, selected there (part of going back to a remote session).
    func selectRemoteTmux(host id: String, pane: String, socket: String?) {
        var b: [String: Any] = ["pane": pane]
        if let socket { b["socket"] = socket }
        conns[id]?.send("tmux", b)
    }

    private func audit(_ id: String?, _ what: String) { SSHAudit.append(support, host: host(id), what) }

    /// Renders (`--ssh-sample`, `--ssh-review`): sample hosts in every state, in memory only (nothing read, written or connected).
    func applyFixture(_ args: [String]) {
        guard args.contains("--ssh-sample") || args.contains("--ssh-review") else { return }
        store = SSHHostStore(enabled: true, hosts: [
            SSHHost(id: "aaaaaa", alias: "devbox", name: "Dev box", deployed: true, hooks: ["claude", "codex"]),
            SSHHost(id: "bbbbbb", alias: "gpu-training-cluster-node-07.internal.example.com", deployed: true),
            SSHHost(id: "cccccc", alias: "build", deployed: true),
            SSHHost(id: "dddddd", alias: "me@203.0.113.9:2222"),
        ])
        status = ["aaaaaa": SSHHostStatus(phase: .connected, hooksOn: ["claude", "codex"]),
                  "bbbbbb": SSHHostStatus(phase: .retrying(Date().addingTimeInterval(240))),
                  "cccccc": SSHHostStatus(phase: .stopped(.hostKeyChanged)),
                  "dddddd": SSHHostStatus()]
        if args.contains("--ssh-review") {
            let before = "{\n  \"model\": \"opus\"\n}\n"
            let tools = SSHInstaller.tools(present: ["claude", "codex"], claudeVersion: "2.1.90")
            let files = [".claude/settings.json": SSHRemoteFile(path: ".claude/settings.json", exists: true, text: before, sha: SSHWire.sha256(Data(before.utf8))),
                         ".codex/hooks.json": SSHRemoteFile(path: ".codex/hooks.json", exists: false, text: nil, sha: "")]
            review = SSHReview(host: "aaaaaa", plan: SSHInstaller.plan(on: true, tools: tools, files: files))
        }
    }
    static func word(_ f: SSHFailure) -> String {
        switch f {
        case .auth: return "login refused"
        case .hostKeyChanged: return "host key changed"
        case .hostKeyUnknown: return "host key unknown"
        case .relayMissing: return "no relay"
        case .relayOutdated: return "relay outdated"
        case .noPerl: return "no perl"
        case .keyMismatch: return "key mismatch"
        case .badAlias: return "bad host name"
        case .network(let s): return "network: \(s)"
        case .dropped: return "dropped"
        case .noAnswer: return "no answer"
        case .protocolError(let s): return "protocol: \(s)"
        }
    }
}
