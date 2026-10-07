// S3 and every S3-compatible store (AWS S3, Cloudflare R2, Backblaze B2, Wasabi, DigitalOcean Spaces, MinIO) with the user's own
// endpoint, region, bucket and keys. One signed PUT streamed from the file (x-amz-content-sha256: UNSIGNED-PAYLOAD over TLS; if
// the store refuses that, the file is hashed first and sent again, and the provider remembers it), multipart above 100 MB
// (each part hashed, an abort on failure or Cancel so no half upload is left), a presigned GET link (default 24 h, at most the
// 7 days S3 allows) or a public base URL the user set (a public bucket or custom domain), DELETE to take a link back.
// Settings: endpoint, region, bucket, pathStyle (1/0), prefix, expiry (seconds), publicBase, payload (unsigned/hashed).
// Secrets: accessKey, secretKey.

import CryptoKit
import Foundation

struct S3Preset: Identifiable, Equatable {
    var id: String
    var title: String
    var endpoint: String
    var region: String
    var pathStyle: Bool
    var hint: String

    static var all: [S3Preset] { [
        S3Preset(id: "aws", title: "Amazon S3", endpoint: "https://s3.us-east-1.amazonaws.com", region: "us-east-1", pathStyle: false,
                 hint: L("The endpoint is https://s3.<region>.amazonaws.com")),
        S3Preset(id: "r2", title: "Cloudflare R2", endpoint: "https://ACCOUNT_ID.r2.cloudflarestorage.com", region: "auto", pathStyle: true,
                 hint: L("Put your account ID in the endpoint; the region is auto")),
        S3Preset(id: "b2", title: "Backblaze B2", endpoint: "https://s3.us-west-004.backblazeb2.com", region: "us-west-004", pathStyle: true,
                 hint: L("Use the S3 endpoint shown on the bucket's page")),
        S3Preset(id: "wasabi", title: "Wasabi", endpoint: "https://s3.us-east-1.wasabisys.com", region: "us-east-1", pathStyle: true,
                 hint: L("The endpoint is https://s3.<region>.wasabisys.com")),
        S3Preset(id: "spaces", title: "DigitalOcean Spaces", endpoint: "https://nyc3.digitaloceanspaces.com", region: "nyc3", pathStyle: false,
                 hint: L("The endpoint is https://<region>.digitaloceanspaces.com")),
        S3Preset(id: "minio", title: "MinIO", endpoint: "https://minio.example.com", region: "us-east-1", pathStyle: true,
                 hint: L("Your MinIO server's address")),
    ] }

    func config() -> ShareProviderConfig {
        ShareProviderConfig(kind: .s3, title: title, settings: ["endpoint": endpoint, "region": region, "pathStyle": pathStyle ? "1" : "0",
                                                              "prefix": "cocaine", "expiry": "86400", "bucket": "", "publicBase": "", "payload": "unsigned"])
    }
}

struct S3Provider: ShareProvider {
    let config: ShareProviderConfig
    static let multipartThreshold: Int64 = 100 << 20
    static let minPart: Int64 = 16 << 20
    static let maxParts: Int64 = 9_000
    static let defaultExpiry = 86_400

    var region: String { config["region"].isEmpty ? "us-east-1" : config["region"] }
    var bucket: String { config["bucket"] }
    var pathStyle: Bool { config["pathStyle"] != "0" }
    var expiry: Int { max(60, min(SigV4.maxPresign, Int(config["expiry"]) ?? Self.defaultExpiry)) }
    var hashed: Bool { config["payload"] == "hashed" }

    static func validBucket(_ b: String) -> Bool {
        b.count >= 3 && b.count <= 63 && b.range(of: "^[a-z0-9][a-z0-9.-]*[a-z0-9]$", options: .regularExpression) != nil && !b.contains("..")
    }

    func validate(secrets: [String: String]) -> String? {
        if let p = ShareRules.problem(config["endpoint"], what: L("The endpoint")) { return p }
        if config["endpoint"].contains("ACCOUNT_ID") { return L("Put your account ID in the endpoint") }
        if !Self.validBucket(bucket) { return L("The bucket name isn't valid (3–63 lowercase letters, digits, dots or dashes)") }
        if (secrets["accessKey"] ?? "").isEmpty || (secrets["secretKey"] ?? "").isEmpty { return L("The access key and the secret key are needed") }
        if !config["publicBase"].isEmpty, let p = ShareRules.problem(config["publicBase"], what: L("The public address")) { return p }
        return nil
    }

    func credentials(_ s: [String: String]) -> SigV4.Credentials {
        SigV4.Credentials(accessKey: s["accessKey"] ?? "", secretKey: s["secretKey"] ?? "")
    }

    /// The object's key: <prefix>/<32 random hex>/<safe name>. The random part makes the link impossible to guess.
    func key(for name: String) -> String {
        let p = ShareRules.safePrefix(config["prefix"])
        return (p.isEmpty ? "" : p + "/") + ShareRules.random() + "/" + ShareRules.safeName(name)
    }

    struct Address: Equatable {
        var base: String          // scheme://host[:port]
        var host: String          // the Host header as sent (with a non-default port)
        var path: String          // the encoded canonical URI
    }

    func address(_ key: String) -> Address? {
        guard let e = URLComponents(string: config["endpoint"]), let scheme = e.scheme, let h = e.host else { return nil }
        let port = e.port.map { ":\($0)" } ?? ""
        let encodedKey = SigV4.encode(key, keepSlash: true)
        let basePath = e.path.hasSuffix("/") ? String(e.path.dropLast()) : e.path
        if pathStyle {
            return Address(base: "\(scheme)://\(h)\(port)", host: h + port, path: basePath + "/" + SigV4.encode(bucket) + (key.isEmpty ? "" : "/" + encodedKey))
        }
        let vh = bucket + "." + h
        return Address(base: "\(scheme)://\(vh)\(port)", host: vh + port, path: basePath + "/" + encodedKey)
    }

    func request(_ method: String, _ a: Address, query: [(String, String)] = [], payload: String, secrets: [String: String], date: Date,
                 extra: [String: String] = [:]) -> URLRequest {
        let q = SigV4.canonicalQuery(query)
        var req = URLRequest(url: URL(string: a.base + a.path + (q.isEmpty ? "" : "?" + q))!)
        req.httpMethod = method
        let amz = SigV4.stamps(date).amz
        var signedHeaders = ["host": a.host, "x-amz-content-sha256": payload, "x-amz-date": amz]
        for (k, v) in extra where k.lowercased().hasPrefix("x-amz-") { signedHeaders[k.lowercased()] = v }
        let s = SigV4.sign(method: method, path: a.path, query: query, headers: signedHeaders, payloadHash: payload,
                           credentials: credentials(secrets), region: region, service: "s3", date: date)
        for (k, v) in signedHeaders where k != "host" { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in extra { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(s.authorization, forHTTPHeaderField: "Authorization")
        return req
    }

    /// The SHA-256 of a file, read in 1 MB pieces (constant memory), Cancel checked between pieces.
    static func hashFile(_ u: URL, cancel: CancelToken) throws -> String {
        guard let h = try? FileHandle(forReadingFrom: u) else { throw ShareError.badResponse(L("Couldn't read the file")) }
        defer { try? h.close() }
        var hasher = SHA256Stream()
        while true {
            if cancel.cancelled { throw ShareError.cancelled }
            guard let d = try h.read(upToCount: 1 << 20), !d.isEmpty else { break }
            hasher.update(d)
        }
        return hasher.hex()
    }

    /// Does the store's answer say it doesn't take UNSIGNED-PAYLOAD?
    static func refusedUnsigned(_ r: ShareHTTP.Response) -> Bool {
        guard [400, 403, 501].contains(r.status) else { return false }
        let b = String(decoding: r.body.prefix(4096), as: UTF8.self)
        return b.contains("XAmzContentSHA256Mismatch") || b.contains("NotImplemented") || b.contains("UNSIGNED-PAYLOAD") || b.contains("x-amz-content-sha256")
    }

    func upload(_ file: URL, name: String, size: Int64, ctx: ShareContext) throws -> ShareUploaded {
        let k = key(for: name)
        guard let a = address(k) else { throw ShareError.config(L("The endpoint isn't a valid address")) }
        let type = ShareRules.contentType(name)
        var change: [String: String]? = nil
        if size > Self.multipartThreshold {
            try multipart(file, a, size: size, type: type, ctx: ctx)
        } else {
            let progress: (Int64, Int64) -> Void = { sent, total in ctx.progress(total > 0 ? Double(sent) / Double(total) : 0) }
            var payload = hashed ? try Self.hashFile(file, cancel: ctx.cancel) : SigV4.unsignedPayload
            var r = try ctx.http.send(request("PUT", a, payload: payload, secrets: ctx.secrets, date: ctx.now(), extra: ["Content-Type": type]),
                                      body: .file(file), cancel: ctx.cancel, progress: progress)
            if !hashed && Self.refusedUnsigned(r) {
                payload = try Self.hashFile(file, cancel: ctx.cancel)
                r = try ctx.http.send(request("PUT", a, payload: payload, secrets: ctx.secrets, date: ctx.now(), extra: ["Content-Type": type]),
                                      body: .file(file), cancel: ctx.cancel, progress: progress)
                if ShareError.status(r.status) == nil { change = ["payload": "hashed"] }
            }
            if let e = ShareError.status(r.status) { throw e }
        }
        ctx.progress(1)
        var out = try link(k, a, ctx: ctx)
        out.settingsChange = change
        return out
    }

    func link(_ key: String, _ a: Address, ctx: ShareContext) throws -> ShareUploaded {
        let pub = config["publicBase"]
        if !pub.isEmpty {
            let base = pub.hasSuffix("/") ? String(pub.dropLast()) : pub
            guard let u = URL(string: base + "/" + SigV4.encode(key, keepSlash: true)) else { throw ShareError.config(L("The public address isn't valid")) }
            return ShareUploaded(link: u, ref: key)
        }
        let now = ctx.now()
        guard let u = SigV4.presign(base: a.base, host: a.host, path: a.path, credentials: credentials(ctx.secrets), region: region, date: now, expires: expiry)
        else { throw ShareError.badResponse(L("Couldn't make the link")) }
        return ShareUploaded(link: u, ref: key, expires: now.addingTimeInterval(TimeInterval(expiry)))
    }

    static func partSize(for size: Int64) -> Int64 {
        let need = (size + maxParts - 1) / maxParts
        let mb: Int64 = 1 << 20
        return max(minPart, (need + mb - 1) / mb * mb)
    }

    private func multipart(_ file: URL, _ a: Address, size: Int64, type: String, ctx: ShareContext) throws {
        let start = try ctx.http.expect(request("POST", a, query: [("uploads", "")], payload: SigV4.emptyHash, secrets: ctx.secrets, date: ctx.now(),
                                                extra: ["Content-Type": type]), cancel: ctx.cancel)
        guard let id = Self.xmlValue("UploadId", in: start.body) else { throw ShareError.badResponse(L("The store didn't start the upload")) }
        do {
            guard let h = try? FileHandle(forReadingFrom: file) else { throw ShareError.badResponse(L("Couldn't read the file")) }
            defer { try? h.close() }
            let part = Self.partSize(for: size)
            var etags: [String] = []
            var sent: Int64 = 0
            var n = 1
            while sent < size {
                if ctx.cancel.cancelled { throw ShareError.cancelled }
                guard let d = try h.read(upToCount: Int(min(part, size - sent))), !d.isEmpty else { break }
                let base = sent
                let r = try ctx.http.expect(request("PUT", a, query: [("partNumber", String(n)), ("uploadId", id)], payload: SigV4.sha256Hex(d),
                                                    secrets: ctx.secrets, date: ctx.now()),
                                            body: .data(d), cancel: ctx.cancel, progress: { s, _ in ctx.progress(Double(base + s) / Double(size)) })
                guard let tag = r.headers["etag"] else { throw ShareError.badResponse(L("The store didn't confirm a part")) }
                etags.append(tag)
                sent += Int64(d.count)
                n += 1
            }
            let xml = Self.completeXML(etags)
            let r = try ctx.http.expect(request("POST", a, query: [("uploadId", id)], payload: SigV4.sha256Hex(xml), secrets: ctx.secrets, date: ctx.now(),
                                                extra: ["Content-Type": "application/xml"]), body: .data(xml), cancel: ctx.cancel)
            if String(decoding: r.body.prefix(2048), as: UTF8.self).contains("<Error>") { throw ShareError.badResponse(L("The store couldn't put the parts together")) }
        } catch {
            // Cleans the half upload (with its own token: the user's Cancel must not stop the cleanup).
            _ = try? ctx.http.send(request("DELETE", a, query: [("uploadId", id)], payload: SigV4.emptyHash, secrets: ctx.secrets, date: ctx.now()),
                                   cancel: CancelToken())
            throw error
        }
    }

    static func completeXML(_ etags: [String]) -> Data {
        var s = "<CompleteMultipartUpload>"
        for (i, t) in etags.enumerated() {
            let tag = t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            s += "<Part><PartNumber>\(i + 1)</PartNumber><ETag>\(tag)</ETag></Part>"
        }
        return Data((s + "</CompleteMultipartUpload>").utf8)
    }

    static func xmlValue(_ tag: String, in d: Data) -> String? {
        let s = String(decoding: d.prefix(64 << 10), as: UTF8.self)
        guard let a = s.range(of: "<\(tag)>"), let b = s.range(of: "</\(tag)>", range: a.upperBound..<s.endIndex) else { return nil }
        let v = String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    func revoke(_ ref: String, shareID: String?, ctx: ShareContext) throws {
        guard let a = address(ref) else { throw ShareError.config(L("The endpoint isn't a valid address")) }
        let r = try ctx.http.send(request("DELETE", a, payload: SigV4.emptyHash, secrets: ctx.secrets, date: ctx.now()), cancel: ctx.cancel)
        if r.status == 404 { return }                  // already gone
        if let e = ShareError.status(r.status) { throw e }
    }
}

/// SHA-256 over pieces (CryptoKit's hasher, kept in a value).
struct SHA256Stream {
    private var h = CryptoKit.SHA256()
    mutating func update(_ d: Data) { h.update(data: d) }
    func hex() -> String { SigV4.hex(h.finalize()) }
}
