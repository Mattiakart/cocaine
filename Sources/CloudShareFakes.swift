// --cloud-test's stand-ins: a tiny HTTP/1.1 server on 127.0.0.1 (a random port, only in the test process, gone when the test
// ends) that plays S3 (checking every SigV4 signature it gets, presigned links included, and multipart), WebDAV and the
// Nextcloud share API. No real network, no real credentials.

import Foundation

final class FakeHTTPServer {
    struct Request {
        var method: String
        var target: String               // path + "?" + query, as sent (still encoded)
        var headers: [String: String]    // names lowercased
        var body: Data
        var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }
        var query: [(String, String)] {
            guard let q = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return [] }
            return q.split(separator: "&").map { kv in
                let p = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).removingPercentEncoding ?? String($0) }
                return (p[0], p.count > 1 ? p[1] : "")
            }
        }
    }
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        var delay: TimeInterval = 0
    }

    private(set) var port: UInt16 = 0
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var _log: [Request] = []
    var log: [Request] { lock.lock(); defer { lock.unlock() }; return _log }
    var handler: (Request) -> Response = { _ in Response(status: 404) }
    var base: String { "http://127.0.0.1:\(port)" }

    /// Listens on 127.0.0.1 only. False when that isn't possible here.
    func start() -> Bool {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return false }
        var out = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: out.sin_port)
        let listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(listener, nil, nil)
                if c < 0 { return }
                Thread.detachNewThread { self?.serve(c) }
            }
        }
        return true
    }

    func stop() { if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); fd = -1 } }

    private func readAll(_ c: Int32, into buf: inout Data, until done: (Data) -> Bool) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !done(buf) {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { return false }
            buf.append(contentsOf: chunk[0..<n])
        }
        return true
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))   // a client gone mustn't kill the test
        var tv = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data()
        let sep = Data("\r\n\r\n".utf8)
        guard readAll(c, into: &buf, until: { $0.range(of: sep) != nil }), let r = buf.range(of: sep) else { return }
        let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
        var body = Data(buf[r.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        if headers["expect"]?.lowercased() == "100-continue" { _ = "HTTP/1.1 100 Continue\r\n\r\n".withCString { write(c, $0, strlen($0)) } }
        if let n = headers["content-length"].flatMap(Int.init) {
            guard readAll(c, into: &body, until: { $0.count >= n }) else { return }
        } else if headers["transfer-encoding"]?.lowercased() == "chunked" {
            let end = Data("0\r\n\r\n".utf8)
            guard readAll(c, into: &body, until: { $0.range(of: end) != nil }) else { return }
            body = Self.dechunk(body)
        }
        let req = Request(method: String(first[0]), target: String(first[1]), headers: headers, body: body)
        lock.lock(); _log.append(req); lock.unlock()
        let resp = handler(req)
        if resp.delay > 0 { Thread.sleep(forTimeInterval: resp.delay) }
        var out = "HTTP/1.1 \(resp.status) X\r\nContent-Length: \(resp.body.count)\r\nConnection: close\r\n"
        for (k, v) in resp.headers { out += "\(k): \(v)\r\n" }
        var d = Data((out + "\r\n").utf8)
        d.append(resp.body)
        d.withUnsafeBytes { p in var off = 0; while off < p.count { let n = write(c, p.baseAddress! + off, p.count - off); if n <= 0 { break }; off += n } }
    }

    static func dechunk(_ d: Data) -> Data {
        var out = Data(); var rest = d[...]
        while let r = rest.range(of: Data("\r\n".utf8)) {
            let size = Int(String(decoding: rest[..<r.lowerBound], as: UTF8.self), radix: 16) ?? 0
            if size == 0 { break }
            let start = r.upperBound
            out.append(rest[start..<(start + size)])
            rest = rest[(start + size + 2)...]
        }
        return out
    }
}

/// A fake S3: objects in memory, every signature checked (header-signed and presigned), multipart, optional refusal of
/// UNSIGNED-PAYLOAD, scripted failures.
final class FakeS3 {
    let server = FakeHTTPServer()
    let creds: SigV4.Credentials
    let region: String
    var objects: [String: Data] = [:]
    var badSignatures = 0
    var refuseUnsigned = false
    var fail: Int? = nil                     // answer every request with this status
    var aborted: [String] = []
    private var uploads: [String: [Int: Data]] = [:]
    private let lock = NSLock()

    init(creds: SigV4.Credentials, region: String) { self.creds = creds; self.region = region }

    func start() -> Bool {
        server.handler = { [unowned self] r in self.lock.lock(); defer { self.lock.unlock() }; return self.handle(r) }
        return server.start()
    }

    /// Recomputes the signature from what arrived.
    func verify(_ r: FakeHTTPServer.Request) -> Bool {
        let q = r.query
        if let sig = q.first(where: { $0.0 == "X-Amz-Signature" })?.1 {           // presigned
            guard let date = q.first(where: { $0.0 == "X-Amz-Date" })?.1, let d = Self.date(date) else { return false }
            let rest = q.filter { $0.0 != "X-Amz-Signature" }
            let cr = SigV4.canonicalRequest(method: r.method, path: r.path, query: rest, headers: ["host": r.headers["host"] ?? ""], payloadHash: SigV4.unsignedPayload)
            let (_, day) = SigV4.stamps(d)
            let sts = SigV4.stringToSign(amz: date, scope: SigV4.scope(day: day, region: region, service: "s3"), canonical: cr.text)
            return SigV4.hex(SigV4.hmac(SigV4.signingKey(secret: creds.secretKey, day: day, region: region, service: "s3"), sts)) == sig
        }
        guard let auth = r.headers["authorization"], let amz = r.headers["x-amz-date"], let d = Self.date(amz),
              let sh = auth.range(of: "SignedHeaders=")?.upperBound, let sg = auth.range(of: "Signature=")?.upperBound else { return false }
        let signedNames = auth[sh...].prefix { $0 != "," }.split(separator: ";").map(String.init)
        let sig = String(auth[sg...])
        var hs: [String: String] = [:]
        for n in signedNames { hs[n] = r.headers[n] ?? "" }
        let payload = r.headers["x-amz-content-sha256"] ?? ""
        if payload != SigV4.unsignedPayload && payload != SigV4.sha256Hex(r.body) { return false }
        let s = SigV4.sign(method: r.method, path: r.path, query: r.query, headers: hs, payloadHash: payload, credentials: creds, region: region, service: "s3", date: d)
        return s.signature == sig && auth.contains("Credential=\(creds.accessKey)/")
    }

    static func date(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.date(from: s)
    }

    private func handle(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Response {
        if let f = fail { return .init(status: f, body: Data("<Error><Code>Scripted</Code></Error>".utf8)) }
        guard verify(r) else { badSignatures += 1; return .init(status: 403, body: Data("<Error><Code>SignatureDoesNotMatch</Code></Error>".utf8)) }
        let key = r.path.removingPercentEncoding ?? r.path
        let q = Dictionary(r.query, uniquingKeysWith: { a, _ in a })
        switch r.method {
        case "PUT" where q["uploadId"] != nil:
            let n = Int(q["partNumber"] ?? "") ?? 0
            uploads[q["uploadId"]!, default: [:]][n] = r.body
            return .init(status: 200, headers: ["ETag": "\"etag-\(n)\""])
        case "PUT":
            if refuseUnsigned && r.headers["x-amz-content-sha256"] == SigV4.unsignedPayload {
                return .init(status: 501, body: Data("<Error><Code>NotImplemented</Code><Message>UNSIGNED-PAYLOAD</Message></Error>".utf8))
            }
            objects[key] = r.body
            return .init(status: 200, headers: ["ETag": "\"x\""])
        case "POST" where q["uploads"] != nil:
            let id = "up-" + ShareRules.random(8)
            uploads[id] = [:]
            return .init(status: 200, body: Data("<InitiateMultipartUploadResult><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>".utf8))
        case "POST" where q["uploadId"] != nil:
            guard let parts = uploads[q["uploadId"]!] else { return .init(status: 404) }
            let xml = String(decoding: r.body, as: UTF8.self)
            guard xml.components(separatedBy: "<Part>").count - 1 == parts.count else { return .init(status: 200, body: Data("<Error>InvalidPart</Error>".utf8)) }
            objects[key] = parts.keys.sorted().reduce(into: Data()) { $0.append(parts[$1]!) }
            uploads[q["uploadId"]!] = nil
            return .init(status: 200, body: Data("<CompleteMultipartUploadResult/>".utf8))
        case "DELETE" where q["uploadId"] != nil:
            aborted.append(q["uploadId"]!); uploads[q["uploadId"]!] = nil
            return .init(status: 204)
        case "DELETE":
            return objects.removeValue(forKey: key) == nil ? .init(status: 404) : .init(status: 204)
        case "GET":
            guard let d = objects[key] else { return .init(status: 404) }
            return .init(status: 200, body: d)
        default: return .init(status: 400)
        }
    }

    var multipartInFlight: Int { lock.lock(); defer { lock.unlock() }; return uploads.count }
}

/// A fake WebDAV + Nextcloud OCS server: Basic auth checked, folders, files, shares.
final class FakeDAV {
    let server = FakeHTTPServer()
    let user: String, password: String
    var folders: Set<String> = []
    var files: [String: Data] = [:]
    var shares: [String: String] = [:]        // id → path
    var lastShareForm: [String: String] = [:]
    var ocsStatus = 200
    private let lock = NSLock()

    init(user: String, password: String) { self.user = user; self.password = password }

    func start() -> Bool {
        server.handler = { [unowned self] r in self.lock.lock(); defer { self.lock.unlock() }; return self.handle(r) }
        return server.start()
    }

    private func handle(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Response {
        guard r.headers["authorization"] == ShareHTTP.basic(user, password) else { return .init(status: 401) }
        let path = r.path.removingPercentEncoding ?? r.path
        if path.hasPrefix("/ocs/v2.php/apps/files_sharing/api/v1/shares") {
            guard r.headers["ocs-apirequest"] == "true" else { return .init(status: 400) }
            if r.method == "POST" {
                var form: [String: String] = [:]
                for kv in String(decoding: r.body, as: UTF8.self).split(separator: "&") {
                    let p = kv.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                    form[p[0]] = p.count > 1 ? p[1] : ""
                }
                lastShareForm = form
                if ocsStatus != 200 {
                    return .init(status: 200, body: Data("{\"ocs\":{\"meta\":{\"status\":\"failure\",\"statuscode\":\(ocsStatus),\"message\":\"Wrong path, file/folder doesn't exist\"},\"data\":[]}}".utf8))
                }
                let id = String(shares.count + 40)
                shares[id] = form["path"]
                let json = "{\"ocs\":{\"meta\":{\"status\":\"ok\",\"statuscode\":200,\"message\":\"OK\"},\"data\":{\"id\":\(id),\"url\":\"\(server.base)/s/share\(id)\"}}}"
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
            }
            if r.method == "DELETE" {
                let id = String(path.split(separator: "/").last ?? "")
                return shares.removeValue(forKey: id) == nil ? .init(status: 404) : .init(status: 200, body: Data("{\"ocs\":{\"meta\":{\"statuscode\":200},\"data\":[]}}".utf8))
            }
        }
        switch r.method {
        case "MKCOL":
            if folders.contains(path) { return .init(status: 405) }
            folders.insert(path); return .init(status: 201)
        case "PUT":
            let dir = (path as NSString).deletingLastPathComponent
            if !folders.contains(dir) && !dir.hasSuffix("/dav") && !folders.isEmpty { return .init(status: 409) }
            files[path] = r.body; return .init(status: 201)
        case "DELETE":
            return files.removeValue(forKey: path) == nil ? .init(status: 404) : .init(status: 204)
        default: return .init(status: 405)
        }
    }
}
