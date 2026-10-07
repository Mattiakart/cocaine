// SSH hosts: the list of remote machines whose AI agents Cocaine follows (the user adds each one; nothing is ever connected on
// its own), the names offered from ~/.ssh/config and ~/.ssh/known_hosts (read, never written), each host's key in the Keychain,
// and an audit log of what was done (never any content). The connection itself: Sources/SSHConnection.swift; the remote side:
// relay/cocaine-relay; the wire: Sources/SSHProtocol.swift; the remote hooks: Sources/SSHInstall.swift.

import Darwin
import Foundation
import Security

struct SSHHost: Codable, Equatable, Identifiable {
    var id: String                 // 6 hex, made here; a remote session's key starts with it
    var alias: String              // what ssh is given: a Host of ~/.ssh/config, or user@host[:port]
    var name: String? = nil        // the user's own name for it (else the alias)
    var enabled = true             // off: no connection (the per-host kill switch)
    var deployed = false           // the user agreed to put the relay there, and it is there
    var hooks: [String] = []       // tools whose hooks Cocaine put there (with the user's OK)
    var added: Double = 0

    var label: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? alias }

    static func newID(taken: Set<String>) -> String {
        while true {
            var b = [UInt8](repeating: 0, count: 3)
            _ = SecRandomCopyBytes(kSecRandomDefault, 3, &b)
            let id = Data(b).hex
            if !taken.contains(id) { return id }
        }
    }
}

/// What may be handed to ssh as a host: a config alias or user@host[:port], letters, digits and . _ @ : - only, never starting with
/// "-" (it would be read as an option). Always passed as its own argument after "--", never through a shell.
enum SSHAlias {
    static func valid(_ s: String) -> Bool {
        s.count >= 1 && s.count <= 255 && !s.hasPrefix("-") && s.range(of: #"^[A-Za-z0-9._@:-]+$"#, options: .regularExpression) != nil
            && !s.hasSuffix("@") && !s.hasPrefix("@") && s.filter({ $0 == "@" }).count <= 1
    }

    /// The destination and port for ssh: "user@host:2222" → ("user@host", "2222"); an IPv6 address (several colons) as it is.
    static func destination(_ s: String) -> (dest: String, port: String?)? {
        guard valid(s) else { return nil }
        let colons = s.filter { $0 == ":" }.count
        guard colons == 1 else { return (s, nil) }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, let p = Int(parts[1]), (1...65535).contains(p), String(p) == parts[1] else { return nil }
        return (parts[0], String(p))
    }
}

/// The list on disk: <support>/ssh/hosts.json, 0600 in a 0700 folder.
struct SSHHostStore: Codable, Equatable {
    var enabled = true             // the global kill switch: off = every connection closed
    var hosts: [SSHHost] = []
    static let maxHosts = 16

    static func folder(_ support: URL) -> URL { support.appendingPathComponent("ssh", isDirectory: true) }
    static func file(_ support: URL) -> URL { folder(support).appendingPathComponent("hosts.json") }

    static func load(_ support: URL) -> SSHHostStore {
        guard let d = try? Data(contentsOf: file(support)), var s = try? JSONDecoder().decode(SSHHostStore.self, from: d) else { return SSHHostStore() }
        var seen = Set<String>()
        s.hosts = s.hosts.filter { h in
            defer { seen.insert(h.id) }
            return h.id.range(of: #"^[0-9a-f]{6}$"#, options: .regularExpression) != nil && !seen.contains(h.id) && SSHAlias.valid(h.alias)
        }.prefix(maxHosts).map { var h = $0; h.hooks = h.hooks.filter(SSHWire.tools.contains); h.name = h.name.map { String($0.prefix(60)) }; return h }
        return s
    }

    @discardableResult
    func save(_ support: URL) -> Bool {
        guard let d = try? JSONEncoder().encode(self) else { return false }
        return SafeFile.writePrivate(d, to: Self.file(support))
    }
}

// MARK: - Names to offer

/// Host names from ~/.ssh/config (and the files it includes) and ~/.ssh/known_hosts, offered when adding a host. Patterns
/// (`*`, `?`, `!`), Match blocks and anything that isn't a plain name are left out; nothing is connected until the user picks one.
enum SSHConfigScan {
    /// The config's `Host` names in order, following `Include` (relative to ~/.ssh, with globs), at most 8 levels deep.
    static func hosts(config text: String, sshDir: String, home: String, read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
                      glob: (String) -> [String] = SSHConfigScan.glob, depth: Int = 0, visited: inout Set<String>) -> [String] {
        guard depth < 8 else { return [] }
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let words = tokens(raw)
            guard let kw = words.first?.lowercased() else { continue }
            let args = Array(words.dropFirst())
            switch kw {
            case "host":
                for n in args where !n.contains("*") && !n.contains("?") && !n.hasPrefix("!") && SSHAlias.valid(n) && !out.contains(n) { out.append(n) }
            case "include":
                for a in args {
                    var p = a.hasPrefix("~/") ? home + String(a.dropFirst(1)) : a
                    if !p.hasPrefix("/") { p = sshDir + "/" + p }
                    for f in glob(p).sorted() where !visited.contains(f) {
                        visited.insert(f)
                        guard let t = read(f) else { continue }
                        for n in hosts(config: t, sshDir: sshDir, home: home, read: read, glob: glob, depth: depth + 1, visited: &visited) where !out.contains(n) { out.append(n) }
                    }
                }
            default: continue                                  // Match blocks and every other keyword
            }
        }
        return out
    }

    /// A config line's words: `Keyword arg…` or `Keyword=arg`, double quotes group, `#` starts a comment.
    static func tokens(_ line: String) -> [String] {
        var s = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard !s.isEmpty, s.first != "#" else { return [] }
        let keyword = s.prefix { $0 != " " && $0 != "\t" && $0 != "=" }
        s = s.dropFirst(keyword.count).drop { $0 == " " || $0 == "\t" }
        if s.first == "=" { s = s.dropFirst().drop { $0 == " " || $0 == "\t" } }
        var out = [String(keyword)], cur = "", quoted = false, any = false
        for c in s {
            if c == "\"" { quoted.toggle(); any = true; continue }
            if !quoted && c == "#" && cur.isEmpty && !any { break }
            if !quoted && (c == " " || c == "\t") {
                if !cur.isEmpty || any { out.append(cur); cur = ""; any = false }
                continue
            }
            cur.append(c)
        }
        if !cur.isEmpty || any { out.append(cur) }
        return out
    }

    static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_matchc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }

    /// known_hosts: plain names only (hashed entries, markers and patterns are skipped); "[host]:2222" becomes "host:2222".
    static func knownHosts(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = f.first, !first.hasPrefix("#"), !first.hasPrefix("@") else { continue }
            for raw in first.split(separator: ",").map(String.init) {
                guard !raw.hasPrefix("|") else { continue }
                var n = raw
                if raw.hasPrefix("["), let close = raw.firstIndex(of: "]") {
                    let h = String(raw[raw.index(after: raw.startIndex)..<close])
                    let port = raw[raw.index(after: close)...].dropFirst()
                    n = port.isEmpty || port == "22" ? h : h + ":" + port
                }
                guard !n.contains("*"), !n.contains("?"), !n.hasPrefix("!"), SSHAlias.valid(n), SSHAlias.destination(n) != nil, !out.contains(n) else { continue }
                out.append(n)
            }
        }
        return out
    }

    /// Both, the config's names first; at most 50.
    static func suggestions(home: String = NSHomeDirectory()) -> [String] {
        let dir = home + "/.ssh"
        var visited: Set<String> = [dir + "/config"]
        let config = (try? String(contentsOfFile: dir + "/config", encoding: .utf8)).map { hosts(config: $0, sshDir: dir, home: home, visited: &visited) } ?? []
        let known = (try? String(contentsOfFile: dir + "/known_hosts", encoding: .utf8)).map(knownHosts) ?? []
        return Array((config + known.filter { !config.contains($0) }).prefix(50))
    }
}

// MARK: - Keys

/// Each host's key (32 bytes): in the login Keychain, this device only, never synced. Tests use the memory one.
protocol SSHKeyStore: AnyObject {
    func load(_ host: String) -> Data?
    func save(_ host: String, _ key: Data) -> Bool
    func delete(_ host: String)
}

final class SSHMemoryKeys: SSHKeyStore {
    var keys: [String: Data] = [:]
    func load(_ host: String) -> Data? { keys[host] }
    func save(_ host: String, _ key: Data) -> Bool { keys[host] = key; return true }
    func delete(_ host: String) { keys[host] = nil }
}

final class SSHKeychainKeys: SSHKeyStore {
    let service = "local.cocaine.ssh-hosts"
    private func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: host]
    }
    func load(_ host: String) -> Data? {
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 else { return nil }
        return d
    }
    func save(_ host: String, _ key: Data) -> Bool {
        delete(host)
        var q = query(host)
        q[kSecValueData as String] = key
        q[kSecAttrLabel as String] = "Cocaine SSH host key"
        q[kSecAttrDescription as String] = "Signs what Cocaine and its relay on an SSH host say to each other"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    func delete(_ host: String) { SecItemDelete(query(host) as CFDictionary) }
}

// MARK: - Audit log

/// <support>/ssh/audit.log (0600): when, which host, what happened (connected, relay installed, hooks changed, a request and its
/// answer's kind). Never a command, a plan, a message or a file's content. Kept to 256 KB (the older half goes to audit.log.1).
enum SSHAudit {
    static let limit = 256 * 1024
    private static let lock = NSLock()

    static func line(host: SSHHost?, _ what: String, now: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        let who = host.map { "\($0.id) \($0.alias)" } ?? "-"
        let clean = what.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : String($0) }.joined()
        return "\(f.string(from: now)) \(who) \(clean.prefix(300))\n"
    }

    static func append(_ support: URL, host: SSHHost?, _ what: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let dir = SSHHostStore.folder(support)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = dir.appendingPathComponent("audit.log").path
        var st = stat()
        if lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG else { return }
            if st.st_size > limit { _ = rename(path, path + ".1") }
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let b = Array(line(host: host, what, now: now).utf8)
        _ = write(fd, b, b.count)
    }
}
