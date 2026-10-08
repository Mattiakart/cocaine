// SFTP to the user's own server through /usr/bin/sftp (the system curl has no SFTP). Keys only: the ssh-agent or a key file in
// ~/.ssh, BatchMode (never a password prompt), password and keyboard-interactive logins turned off, host keys checked
// (StrictHostKeyChecking=yes: the server must already be in ~/.ssh/known_hosts — connect once with ssh to add it). Cocaine never
// stores a password. The commands go in a batch file Cocaine writes (0600, deleted after); the file is handed to sftp as a
// link with a safe name in a private temporary folder, so no name the user's file has can reach the batch syntax.
// Settings: host, port, user, remoteDir, publicBase (the web address remoteDir is served at), identity (a key file, optional).

import Foundation

struct SFTPProvider: ShareProvider {
    let config: ShareProviderConfig
    static let sftp = "/usr/bin/sftp"
    static let timeout: TimeInterval = 3600

    /// How long an upload may take: an hour, or longer for a big file (at least 1 MB/s is expected; 50 GB is allowed).
    static func timeout(for size: Int64) -> TimeInterval { max(timeout, Double(max(0, size)) / 1_000_000) }

    var port: Int { Int(config["port"]).flatMap { (1...65535).contains($0) ? $0 : nil } ?? 22 }

    static func validHost(_ h: String) -> Bool {
        !h.isEmpty && h.count <= 253 && !h.hasPrefix("-") && h.range(of: "^[A-Za-z0-9.:-]+$", options: .regularExpression) != nil
    }
    static func validUser(_ u: String) -> Bool {
        !u.isEmpty && u.count <= 64 && !u.hasPrefix("-") && u.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }
    /// A remote folder: letters, digits, . _ - / ~ only (nothing that sftp's batch syntax would read as a quote or a glob).
    static func validDir(_ d: String) -> Bool {
        !d.hasPrefix("-") && d.count <= 255 && d.range(of: "^[A-Za-z0-9._/~-]*$", options: .regularExpression) != nil && !d.split(separator: "/").contains("..")
    }

    var remoteDir: String {
        let d = config["remoteDir"]
        return d.hasSuffix("/") && d.count > 1 ? String(d.dropLast()) : d
    }

    func validate(secrets: [String: String]) -> String? {
        if !Self.validHost(config["host"]) { return L("The server's name isn't valid") }
        if !Self.validUser(config["user"]) { return L("The user name isn't valid") }
        if !Self.validDir(remoteDir) { return L("The remote folder can have letters, digits, dots, dashes, underscores and slashes only") }
        if let p = ShareRules.problem(config["publicBase"], what: L("The public address")) { return p }
        let id = config["identity"]
        if !id.isEmpty && (!id.hasPrefix("/") || !FileManager.default.fileExists(atPath: id)) { return L("The key file isn't there") }
        return nil
    }

    /// sftp's arguments: the batch file, the options that keep it key-only and host-checked, then the destination.
    func arguments(batch: String) -> [String] {
        var a = ["-b", batch, "-P", String(port),
                 "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "PasswordAuthentication=no",
                 "-o", "KbdInteractiveAuthentication=no", "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15"]
        let id = config["identity"]
        if !id.isEmpty { a += ["-o", "IdentitiesOnly=yes", "-i", id] }
        let host = config["host"].contains(":") ? "[" + config["host"] + "]" : config["host"]
        return a + ["--", config["user"] + "@" + host]
    }

    func remotePath(_ name: String) -> String { (remoteDir.isEmpty ? "" : remoteDir + "/") + name }

    /// The batch: put the file (a safe local name, a safe remote name). Quoted anyway.
    static func batch(put local: String, to remote: String) -> String { "put \"\(local)\" \"\(remote)\"\n" }
    static func batch(remove remote: String) -> String { "rm \"\(remote)\"\n" }

    static func environment() -> [String: String] {
        var extra: [String: String] = [:]
        if let s = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { extra["SSH_AUTH_SOCK"] = s }     // the ssh-agent's keys
        return ShelfProc.environment(extra)
    }

    /// Runs one batch; the errors sftp printed become the error (bounded, its first line).
    func runBatch(_ text: String, ctx: ShareContext, cancel: CancelToken, timeout: TimeInterval = SFTPProvider.timeout) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-sftp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = dir.appendingPathComponent("batch")
        guard SafeFile.writePrivate(Data(text.utf8), to: b) else { throw ShareError.tool(L("Couldn't prepare the upload")) }
        let r = ctx.run(Self.sftp, arguments(batch: b.path), Self.environment(), timeout, cancel)
        if r.cancelled { throw ShareError.cancelled }
        if r.timedOut { throw ShareError.timeout }
        guard r.status == 0 else { throw Self.error(r.err) }
    }

    static func error(_ stderr: String) -> ShareError {
        let s = stderr.lowercased()
        if s.contains("host key verification failed") || s.contains("no matching host key") || s.contains("host key for") {
            return .tool(L("The server's host key isn't known or has changed: connect once with ssh in Terminal to check and add it"))
        }
        if s.contains("permission denied") { return .tool(L("The server refused the key: add your key to the ssh-agent or choose the key file")) }
        if s.contains("could not resolve") || s.contains("connection refused") || s.contains("timed out") || s.contains("no route") { return .offline }
        if s.contains("no such file") { return .tool(L("The remote folder doesn't exist")) }
        let line = stderr.split(whereSeparator: \.isNewline).map(String.init).first { !$0.isEmpty } ?? ""
        return .tool(line.isEmpty ? L("sftp didn't work") : String(line.prefix(160)))
    }

    func upload(_ file: URL, name: String, size: Int64, ctx: ShareContext) throws -> ShareUploaded {
        let remoteName = ShareRules.random(8) + "-" + ShareRules.safeName(name)
        let remote = remotePath(remoteName)
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-sftp-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let local = stage.appendingPathComponent(ShareRules.safeName(name))
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: file.standardizedFileURL)
        do { try runBatch(Self.batch(put: local.path, to: remote), ctx: ctx, cancel: ctx.cancel, timeout: Self.timeout(for: size)) }
        catch {
            // Cancelled, timed out, the connection lost or sftp failing half-way: a half file never stays served (a file that
            // never got there makes this rm fail quietly).
            if let e = error as? ShareError, case .config = e {} else {
                try? runBatch(Self.batch(remove: remote), ctx: ctx, cancel: CancelToken(), timeout: 30)
            }
            throw error
        }
        ctx.progress(1)
        let base = WebDAVProvider.trimmed(config["publicBase"])
        guard let u = URL(string: base + "/" + SigV4.encode(remoteName)) else { throw ShareError.config(L("The public address isn't valid")) }
        return ShareUploaded(link: u, ref: remote)
    }

    func revoke(_ ref: String, shareID: String?, ctx: ShareContext) throws {
        guard Self.validDir(ref) else { throw ShareError.config(L("The remote folder can have letters, digits, dots, dashes, underscores and slashes only")) }
        try runBatch(Self.batch(remove: ref), ctx: ctx, cancel: ctx.cancel, timeout: 60)
    }
}
