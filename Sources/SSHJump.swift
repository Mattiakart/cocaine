// SSH hosts: going back to a remote session means going to the local terminal tab that holds its ssh connection. The remote
// hook sent $SSH_CONNECTION ("<client ip> <client port> <server ip> <server port>"); the local ssh process whose TCP socket has
// that client port is found with lsof (the user's own processes only, no permission needed), then its terminal (tty) and app,
// and from there AgentFocus goes to the exact tab as for a local session. Behind NAT the port can differ: then a single ssh to
// that server address, then a single ssh naming that host. Cocaine's own background connections are never the answer. If none
// fits, a terminal app comes forward and the app says so. Inside tmux there, its pane is selected through the relay.

import AppKit

enum SSHJump {
    struct Socket: Equatable { var pid: Int32; var localPort: Int; var remoteIP: String; var remotePort: Int }
    struct Conn: Equatable { var clientIP: String; var clientPort: Int; var serverIP: String; var serverPort: Int }
    struct PSRow: Equatable { var pid: Int32; var ppid: Int32; var tty: String; var args: [String] }

    static func connection(_ s: String?) -> Conn? {
        let f = (s ?? "").split(separator: " ").map(String.init)
        guard f.count == 4, let cp = Int(f[1]), let sp = Int(f[3]), (1...65535).contains(cp), (1...65535).contains(sp) else { return nil }
        return Conn(clientIP: normal(f[0]), clientPort: cp, serverIP: normal(f[2]), serverPort: sp)
    }

    /// An address to compare: lower case, without an IPv6 zone or the IPv4-mapped prefix.
    static func normal(_ ip: String) -> String {
        var s = ip.lowercased()
        if let p = s.firstIndex(of: "%") { s = String(s[..<p]) }
        if s.hasPrefix("::ffff:") && s.contains(".") { s = String(s.dropFirst(7)) }
        return s
    }

    /// `lsof -nP -a -u <uid> -c ssh -iTCP -sTCP:ESTABLISHED -F pn` output.
    static func parseLsof(_ text: String) -> [Socket] {
        var out: [Socket] = []
        var pid: Int32?
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let v = String(line.dropFirst())
            if tag == "p" { pid = Int32(v); continue }
            guard tag == "n", let pid, let arrow = v.range(of: "->") else { continue }
            guard let local = endpoint(String(v[..<arrow.lowerBound])), let remote = endpoint(String(v[arrow.upperBound...])) else { continue }
            out.append(Socket(pid: pid, localPort: local.port, remoteIP: remote.ip, remotePort: remote.port))
        }
        return out
    }

    static func endpoint(_ s: String) -> (ip: String, port: Int)? {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let ip = String(s[s.index(after: s.startIndex)..<close])
            guard let port = Int(s[s.index(after: close)...].dropFirst()) else { return nil }
            return (normal(ip), port)
        }
        guard let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]) else { return nil }
        return (normal(String(s[..<colon])), port)
    }

    /// `ps -axo pid=,ppid=,tty=,command=` output.
    static func parsePS(_ text: String) -> [PSRow] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 4, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { return nil }
            return PSRow(pid: pid, ppid: ppid, tty: f[2], args: Array(f[3...]))
        }
    }

    /// The local ssh process holding that connection, or nil. `own`: Cocaine's own pid (its background connections are skipped).
    static func match(_ c: Conn, alias: String, sockets: [Socket], ps: [PSRow], own: Int32) -> Int32? {
        let mine = Set(ps.filter { $0.ppid == own }.map(\.pid))
        let s = sockets.filter { !mine.contains($0.pid) }
        func unique(_ list: [Socket]) -> Int32? { let p = Set(list.map(\.pid)); return p.count == 1 ? p.first : nil }
        if let p = unique(s.filter { $0.localPort == c.clientPort && $0.remotePort == c.serverPort }) { return p }
        if let p = unique(s.filter { $0.localPort == c.clientPort }) { return p }
        if let p = unique(s.filter { $0.remoteIP == c.serverIP && $0.remotePort == c.serverPort }) { return p }
        return byAlias(alias, ps: ps, own: own)
    }

    /// A single interactive ssh (with a terminal) that names this host.
    static func byAlias(_ alias: String, ps: [PSRow], own: Int32) -> Int32? {
        let dest = SSHAlias.destination(alias)?.dest ?? alias
        let host = dest.split(separator: "@").last.map(String.init) ?? dest
        let rows = ps.filter { r in
            guard r.ppid != own, r.tty != "??", r.tty != "-", let first = r.args.first, (first as NSString).lastPathComponent == "ssh" else { return false }
            return r.args.dropFirst().contains { a in a == alias || a == dest || a == host || a.hasSuffix("@" + host) }
        }
        return rows.count == 1 ? rows.first?.pid : nil
    }

    static func lsof() -> String {
        AgentFocus.runTool("/usr/sbin/lsof", ["-nP", "-a", "-u", String(getuid()), "-c", "ssh", "-iTCP", "-sTCP:ESTABLISHED", "-F", "pn"], timeout: 5).out
    }
    static func ps() -> String { AgentFocus.runTool("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="], timeout: 5).out }

    /// Where the local end of a remote session is, as an origin AgentFocus can go to (its tty, its terminal app), or nil.
    static func localOrigin(_ o: AgentOrigin, alias: String) -> AgentOrigin? {
        let rows = parsePS(ps())
        let pid: Int32?
        if let c = connection(o.sshConnection) { pid = match(c, alias: alias, sockets: parseLsof(lsof()), ps: rows, own: getpid()) }
        else { pid = byAlias(alias, ps: rows, own: getpid()) }
        guard let pid, let info = AgentProcess.info(pid), info.uid == getuid() else { return nil }
        var local = AgentOrigin()
        local.pid = pid
        local.pidStart = info.start
        local.tty = info.tty
        local.app = AgentProcess.owningApp(of: pid)?.bundleIdentifier
        let s = local.sanitized()
        return s.tty == nil && s.app == nil ? nil : s
    }

    /// Off the main thread (AgentFocus's queue). `alias` was read on the main thread.
    static func go(_ o: AgentOrigin, alias: String?) -> AgentFocus.Result {
        guard let alias, let local = localOrigin(o, alias: alias) else {
            // No tab found: the first terminal app that runs comes forward, and the app says why it isn't the exact tab.
            let apps = [AgentFocus.terminal, AgentFocus.iterm, AgentFocus.ghostty, AgentFocus.wezterm, AgentFocus.kitty, "dev.warp.Warp-Stable"]
            if let a = apps.lazy.compactMap(AgentFocus.running).first {
                let ok = Thread.isMainThread ? a.activate() : DispatchQueue.main.sync { a.activate() }
                if ok { return AgentFocus.Result(level: .app, appName: a.localizedName, note: .sshTabNotFound) }
            }
            return AgentFocus.Result(level: .none, appName: nil, note: .sshTabNotFound)
        }
        return AgentFocus.execute(AgentFocus.plan(local), appID: AgentFocus.appID(local))
    }
}
