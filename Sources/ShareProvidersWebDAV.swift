// WebDAV (any server: Synology, Fastmail, Apache…) and Nextcloud/ownCloud. A PUT over HTTPS with the user's (app) password from
// the Keychain; for Nextcloud/ownCloud the folder is made if missing and a public link is created with the OCS share API
// (shareType 3, read-only, with the optional password and expiry date); taking it back deletes the share, then the file.
// WebDAV settings: url (the folder uploads go to), user, publicBase (the address the folder is published at; empty: the link is
// the WebDAV address, which asks for your login). Nextcloud settings: server, user, folder, expiryDays (0: none).
// Secrets: password; Nextcloud also sharePassword (the link's own password, optional).

import Foundation

struct WebDAVProvider: ShareProvider {
    let config: ShareProviderConfig
    var nextcloud: Bool { config.kind == .nextcloud }

    static func trimmed(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }

    /// The folder's WebDAV address (no trailing slash).
    var folderURL: String {
        if nextcloud {
            let f = ShareRules.safePrefix(config["folder"].isEmpty ? "Cocaine" : config["folder"])
            return Self.trimmed(config["server"]) + "/remote.php/dav/files/" + SigV4.encode(config["user"]) + (f.isEmpty ? "" : "/" + f)
        }
        return Self.trimmed(config["url"])
    }

    /// The folder as the share API wants it (relative to the user's files, starting with "/").
    var sharePath: String { "/" + ShareRules.safePrefix(config["folder"].isEmpty ? "Cocaine" : config["folder"]) }

    var expiryDays: Int { max(0, min(365, Int(config["expiryDays"]) ?? 7)) }

    func validate(secrets: [String: String]) -> String? {
        if nextcloud {
            if let p = ShareRules.problem(config["server"], what: L("The server address")) { return p }
        } else if let p = ShareRules.problem(config["url"], what: L("The WebDAV address")) { return p }
        if config["user"].isEmpty { return L("The user name is needed") }
        if (secrets["password"] ?? "").isEmpty { return L("The password (an app password is best) is needed") }
        if !nextcloud, !config["publicBase"].isEmpty, let p = ShareRules.problem(config["publicBase"], what: L("The public address")) { return p }
        return nil
    }

    func auth(_ s: [String: String]) -> String { ShareHTTP.basic(config["user"], s["password"] ?? "") }

    func req(_ method: String, _ url: String, _ s: [String: String]) throws -> URLRequest {
        guard let u = URL(string: url) else { throw ShareError.config(L("The address isn't valid")) }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.setValue(auth(s), forHTTPHeaderField: "Authorization")
        if nextcloud { r.setValue("true", forHTTPHeaderField: "OCS-APIRequest") }
        return r
    }

    /// Makes the folder (each level), when it's Nextcloud's; an existing one (405) is fine.
    func makeFolder(_ ctx: ShareContext) throws {
        guard nextcloud else { return }
        let base = Self.trimmed(config["server"]) + "/remote.php/dav/files/" + SigV4.encode(config["user"])
        var path = base
        for part in ShareRules.safePrefix(config["folder"].isEmpty ? "Cocaine" : config["folder"]).split(separator: "/") {
            path += "/" + SigV4.encode(String(part))
            let r = try ctx.http.send(req("MKCOL", path, ctx.secrets), cancel: ctx.cancel)
            if r.status == 405 || (200..<300).contains(r.status) { continue }
            if let e = ShareError.status(r.status) { throw e }
        }
    }

    func upload(_ file: URL, name: String, size: Int64, ctx: ShareContext) throws -> ShareUploaded {
        try makeFolder(ctx)
        let remote = ShareRules.random(8) + "-" + name
        let url = folderURL + "/" + SigV4.encode(remote)
        var put = try req("PUT", url, ctx.secrets)
        put.setValue(ShareRules.contentType(name), forHTTPHeaderField: "Content-Type")
        _ = try ctx.http.expect(put, body: .file(file), cancel: ctx.cancel, progress: { s, t in ctx.progress(t > 0 ? Double(s) / Double(t) : 0) })
        ctx.progress(1)
        if nextcloud {
            do { return try share(remote, ctx: ctx) }
            catch {
                _ = try? ctx.http.send(req("DELETE", url, ctx.secrets), cancel: CancelToken())     // no link: the file doesn't stay
                throw error
            }
        }
        let pub = config["publicBase"]
        let link = pub.isEmpty ? url : Self.trimmed(pub) + "/" + SigV4.encode(remote)
        guard let u = URL(string: link) else { throw ShareError.config(L("The public address isn't valid")) }
        return ShareUploaded(link: u, ref: remote)
    }

    static func ocsBase(_ server: String) -> String { trimmed(server) + "/ocs/v2.php/apps/files_sharing/api/v1/shares" }

    /// The body of the share request (form-encoded).
    func shareForm(path: String, secrets: [String: String], now: Date) -> (body: Data, expires: Date?) {
        var items: [(String, String)] = [("path", path), ("shareType", "3"), ("permissions", "1")]
        if let p = secrets["sharePassword"], !p.isEmpty { items.append(("password", p)) }
        var expires: Date?
        if expiryDays > 0 {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            let d = cal.date(byAdding: .day, value: expiryDays, to: now) ?? now
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
            items.append(("expireDate", f.string(from: d)))
            expires = cal.startOfDay(for: d)
        }
        return (Data(items.map { SigV4.encode($0.0) + "=" + SigV4.encode($0.1) }.joined(separator: "&").utf8), expires)
    }

    struct OCSShare: Equatable { var id: String; var url: URL }

    /// Reads the OCS answer (JSON): the share's id and public link, or the server's reason.
    static func parseShare(_ d: Data) throws -> OCSShare {
        guard let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ocs = root["ocs"] as? [String: Any] else {
            throw ShareError.badResponse(L("The server's answer isn't a share"))
        }
        let meta = ocs["meta"] as? [String: Any]
        let code = (meta?["statuscode"] as? Int) ?? Int(meta?["statuscode"] as? String ?? "") ?? 0
        guard code == 100 || code == 200 else {
            let msg = (meta?["message"] as? String).map { String($0.prefix(160)) } ?? ""
            if code == 403 || code == 997 { throw ShareError.forbidden }
            if code == 404 { throw ShareError.notFound }
            throw ShareError.badResponse(msg.isEmpty ? String(format: L("The server answered with an error (%d)"), code) : msg)
        }
        let data = (ocs["data"] as? [String: Any]) ?? ((ocs["data"] as? [[String: Any]])?.first ?? [:])
        let id: String? = (data["id"] as? String) ?? (data["id"] as? Int).map(String.init)
        guard let id, let s = data["url"] as? String, let u = URL(string: s), ShareRules.allowed(u) else {
            throw ShareError.badResponse(L("The server's answer isn't a share"))
        }
        return OCSShare(id: id, url: u)
    }

    func share(_ remote: String, ctx: ShareContext) throws -> ShareUploaded {
        var r = try req("POST", Self.ocsBase(config["server"]) + "?format=json", ctx.secrets)
        let form = shareForm(path: sharePath + "/" + remote, secrets: ctx.secrets, now: ctx.now())
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let resp = try ctx.http.send(r, body: .data(form.body), cancel: ctx.cancel)
        if let e = ShareError.status(resp.status), resp.status != 400, resp.status != 403, resp.status != 404 { throw e }
        let s = try Self.parseShare(resp.body)
        return ShareUploaded(link: s.url, ref: remote, shareID: s.id, expires: form.expires)
    }

    func revoke(_ ref: String, shareID: String?, ctx: ShareContext) throws {
        if let id = shareID, nextcloud {
            let r = try ctx.http.send(req("DELETE", Self.ocsBase(config["server"]) + "/" + SigV4.encode(id) + "?format=json", ctx.secrets), cancel: ctx.cancel)
            if r.status != 404, let e = ShareError.status(r.status) { throw e }
        }
        let r = try ctx.http.send(req("DELETE", folderURL + "/" + SigV4.encode(ref), ctx.secrets), cancel: ctx.cancel)
        if r.status == 404 { return }
        if let e = ShareError.status(r.status) { throw e }
    }
}
