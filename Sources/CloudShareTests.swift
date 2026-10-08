// --cloud-test: cloud sharing and the custom actions' extras, with no real network and no real credentials. SigV4 against AWS's
// published examples; S3 (PUT, the UNSIGNED-PAYLOAD fallback, multipart and its abort, presigned links, revoke), WebDAV and the
// Nextcloud share API against local fake servers on 127.0.0.1 (CloudShareFakes.swift); SFTP's arguments and batch (never run
// against a host); the user's upload command with hostile file names; link extraction; error mapping (401/403/404/5xx,
// timeouts, redirects, Cancel); progress; history and settings on disk; the Keychain through a fake and a temporary keychain;
// links kept out of the clipboard history; the webhook action, action keys, chaining, import/export; the shelf's hook.

import AppKit
import Foundation

enum CloudShareTests {
    static func run() -> Int {
        _ = NSApplication.shared
        precondition(AppDefaults.isolated, "tests run with memory-only settings (main.swift)")
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  cloud: " + name); if !ok { failed += 1 } }
        func skip(_ name: String, _ why: String) { print("SKIP  cloud: \(name) (\(why))") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cocaine-cloud-test-\(getpid())-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func dir(_ name: String) -> URL { let d = root.appendingPathComponent(name, isDirectory: true); try? fm.createDirectory(at: d, withIntermediateDirectories: true); return d }
        func file(_ d: URL, _ name: String, _ text: String = "x") -> URL { let u = d.appendingPathComponent(name); try? Data(text.utf8).write(to: u); return u }

        sigv4(check)
        rules(check)
        s3(check, skip, dir: dir, file: file)
        webdav(check, skip, dir: dir, file: file)
        sftp(check, dir: dir, file: file)
        uploader(check, dir: dir, file: file)
        errors(check, skip)
        storage(check, dir: dir, file: file)
        keychain(check, skip, root)
        clipboard(check)
        actions(check, skip, dir: dir, file: file)
        shelfHook(check, skip, dir: dir, file: file)
        print(failed == 0 ? "PASS  cloud: all" : "FAIL  cloud: \(failed) failed")
        return failed
    }

    static let creds = SigV4.Credentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

    static func utc(_ s: String) -> Date { FakeS3.date(s)! }

    // MARK: SigV4 (AWS's published examples)

    static func sigv4(_ check: (String, Bool) -> Void) {
        let d = utc("20150830T123600Z")
        let v = SigV4.sign(method: "GET", path: "/", headers: ["Host": "example.amazonaws.com", "X-Amz-Date": "20150830T123600Z"], payloadHash: SigV4.emptyHash,
                           credentials: .init(accessKey: "AKIDEXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), region: "us-east-1", service: "service", date: d)
        check("SigV4 test suite get-vanilla", v.signature == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
              && v.authorization == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
        let d2 = utc("20130524T000000Z")
        let get = SigV4.sign(method: "GET", path: "/test.txt", headers: ["Host": "examplebucket.s3.amazonaws.com", "Range": "bytes=0-9",
                             "x-amz-content-sha256": SigV4.emptyHash, "x-amz-date": "20130524T000000Z"], payloadHash: SigV4.emptyHash,
                             credentials: creds, region: "us-east-1", service: "s3", date: d2)
        check("S3 docs: GET object", get.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        let ph = SigV4.sha256Hex("Welcome to Amazon S3.")
        let put = SigV4.sign(method: "PUT", path: "/" + SigV4.encode("test$file.text", keepSlash: true),
                             headers: ["Host": "examplebucket.s3.amazonaws.com", "Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY",
                                       "x-amz-content-sha256": ph, "x-amz-date": "20130524T000000Z"], payloadHash: ph, credentials: creds, region: "us-east-1", service: "s3", date: d2)
        check("S3 docs: PUT object (a $ in the key)", put.signature == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
        let list = SigV4.sign(method: "GET", path: "/", query: [("prefix", "J"), ("max-keys", "2")], headers: ["Host": "examplebucket.s3.amazonaws.com",
                              "x-amz-content-sha256": SigV4.emptyHash, "x-amz-date": "20130524T000000Z"], payloadHash: SigV4.emptyHash, credentials: creds, region: "us-east-1", service: "s3", date: d2)
        check("S3 docs: list objects (query sorted)", list.signature == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
        let lc = SigV4.sign(method: "GET", path: "/", query: [("lifecycle", "")], headers: ["Host": "examplebucket.s3.amazonaws.com",
                            "x-amz-content-sha256": SigV4.emptyHash, "x-amz-date": "20130524T000000Z"], payloadHash: SigV4.emptyHash, credentials: creds, region: "us-east-1", service: "s3", date: d2)
        check("S3 docs: GET bucket lifecycle (empty value)", lc.signature == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
        let pre = SigV4.presign(base: "https://examplebucket.s3.amazonaws.com", host: "examplebucket.s3.amazonaws.com", path: "/test.txt", credentials: creds,
                                region: "us-east-1", date: d2, expires: 86400)
        check("S3 docs: presigned URL", pre?.absoluteString == "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
        check("presigned URL: parts and expiry read back", pre.flatMap(SigV4.expiry) == d2.addingTimeInterval(86400) && SigV4.presignedParts(pre!)["X-Amz-Expires"] == "86400")
        let long = SigV4.presign(base: "https://h", host: "h", path: "/k", credentials: creds, region: "auto", date: d2, expires: 30 * 86400)
        check("presigned URL: capped at S3's 7 days", long.map(SigV4.presignedParts)?["X-Amz-Expires"] == "604800")
        check("encoding: unreserved kept, space and unicode percent-encoded, / only in keys",
              SigV4.encode("a b/é~_.-") == "a%20b%2F%C3%A9~_.-" && SigV4.encode("a b/c", keepSlash: true) == "a%20b/c")
    }

    // MARK: rules

    static func rules(_ check: (String, Bool) -> Void) {
        check("TLS only: https yes, http only to this Mac",
              ShareRules.allowed(URL(string: "https://x.example")) && !ShareRules.allowed(URL(string: "http://x.example"))
              && ShareRules.allowed(URL(string: "http://127.0.0.1:9000/b")) && ShareRules.allowed(URL(string: "http://localhost/b"))
              && !ShareRules.allowed(URL(string: "ftp://x.example")) && !ShareRules.allowed(URL(string: "file:///etc/passwd")))
        check("credentials inside an address are refused", !ShareRules.allowed(URL(string: "https://user:pw@x.example"))
              && ShareRules.problem("https://user:pw@x.example", what: "x") != nil)
        check("safe names: path tricks, quotes, shell characters, leading dash/dot", ShareRules.safeName("../../etc/passwd") == "etc-passwd"
              && ShareRules.safeName("$(rm -rf ~); \"x'.txt") == "rm-rf-x-.txt" && ShareRules.safeName("-rf") == "rf" && ShareRules.safeName(".hidden") == "hidden"
              && ShareRules.safeName("") == "file" && ShareRules.safeName("\n\t") == "file")
        check("safe names: accents folded, unicode replaced, extension kept when shortened", ShareRules.safeName("Café ñ.png") == "Cafe-n.png"
              && ShareRules.safeName(String(repeating: "a", count: 300) + ".jpeg").count == 100 && ShareRules.safeName(String(repeating: "a", count: 300) + ".jpeg").hasSuffix(".jpeg")
              && ShareRules.safeName("日本語.pdf") == "pdf")
        check("prefixes: each part made safe, .. and empty parts dropped", ShareRules.safePrefix("/a b/../c//d/") == "a-b/c/d" && ShareRules.safePrefix("") == "")
        check("Content-Type from the file's type", ShareRules.contentType("a.png") == "image/png" && ShareRules.contentType("a.pdf") == "application/pdf"
              && ShareRules.contentType("noext") == "application/octet-stream")
        let r1 = ShareRules.random(), r2 = ShareRules.random()
        check("object names get 128 random bits", r1.count == 32 && r1 != r2 && r1.allSatisfy { $0.isHexDigit })
        var c = S3Preset.all.first { $0.id == "r2" }!.config()
        c.settings["bucket"] = "my-bucket"
        let p = S3Provider(config: c)
        check("S3: the R2 preset asks for the account ID", p.validate(secrets: ["accessKey": "a", "secretKey": "b"]) != nil)
        c.settings["endpoint"] = "http://s3.example.com"
        check("S3: an http endpoint is refused", S3Provider(config: c).validate(secrets: ["accessKey": "a", "secretKey": "b"]) != nil)
        c.settings["endpoint"] = "https://acc.r2.cloudflarestorage.com"
        check("S3: valid with endpoint, bucket and both keys", S3Provider(config: c).validate(secrets: ["accessKey": "a", "secretKey": "b"]) == nil
              && S3Provider(config: c).validate(secrets: ["accessKey": "a"]) != nil)
        c.settings["bucket"] = "Bad_Bucket"
        check("S3: bucket names checked", S3Provider(config: c).validate(secrets: ["accessKey": "a", "secretKey": "b"]) != nil)
        c.settings["bucket"] = "b"; c.settings["pathStyle"] = "0"
        check("S3: virtual-hosted and path-style addresses", S3Provider(config: c).address("k/x y")?.host == "b.acc.r2.cloudflarestorage.com"
              && S3Provider(config: c).address("k/x y")?.path == "/k/x%20y")
        c.settings["pathStyle"] = "1"
        check("S3: path-style puts the bucket in the path", S3Provider(config: c).address("k")?.path == "/b/k" && S3Provider(config: c).address("k")?.host == "acc.r2.cloudflarestorage.com")
        check("S3: keys are <prefix>/<random>/<safe name>", S3Provider(config: c).key(for: "My File (1).png").range(of: "^cocaine/[0-9a-f]{32}/My-File-1-.png$", options: .regularExpression) != nil)
        check("S3: link lifetime defaults to 24 h, clamped to 1 min…7 days", S3Provider(config: c).expiry == 86400
              && { var x = c; x.settings["expiry"] = "99999999"; return S3Provider(config: x).expiry }() == 604800
              && { var x = c; x.settings["expiry"] = "1"; return S3Provider(config: x).expiry }() == 60)
        check("S3: multipart parts at least the minimum, never more than 9 000", S3Provider.partSize(for: 200 << 20) == S3Provider.minPart
              && S3Provider.partSize(for: 1 << 40) * 9000 >= 1 << 40)
        check("new providers ask before every upload", ShareProviderConfig(kind: .s3, title: "x").confirmEach)
        let old = Data(#"{"kind":"webdav","title":"Old"}"#.utf8)
        let dec = try? JSONDecoder().decode(ShareProviderConfig.self, from: old)
        check("a provider saved with fewer fields still loads (confirm on, enabled)", dec?.confirmEach == true && dec?.enabled == true && dec?.title == "Old")
        check("revoke is offered where the service can delete", ShareKind.s3.canRevoke && ShareKind.nextcloud.canRevoke && ShareKind.sftp.canRevoke && !ShareKind.uploader.canRevoke)
    }

    // MARK: S3 against the fake

    static func s3Config(_ base: String) -> ShareProviderConfig {
        ShareProviderConfig(kind: .s3, title: "Fake S3", settings: ["endpoint": base, "region": "auto", "bucket": "bucket", "pathStyle": "1", "prefix": "share/test", "expiry": "3600"])
    }

    static func ctx(_ secrets: [String: String], cancel: CancelToken = CancelToken(), progress: @escaping (Double) -> Void = { _ in },
                    now: Date = Date(), http: ShareHTTP = ShareHTTP()) -> ShareContext {
        ShareContext(cancel: cancel, progress: progress, http: http, secrets: secrets, now: { now })
    }

    static func s3(_ check: (String, Bool) -> Void, _ skip: (String, String) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        let fake = FakeS3(creds: creds, region: "auto")
        guard fake.start() else { skip("S3", "can't listen on 127.0.0.1 here"); return }
        defer { fake.server.stop() }
        let secrets = ["accessKey": creds.accessKey, "secretKey": creds.secretKey]
        let d = dir("s3")
        let f = file(d, "Report Q3 (final).txt", "hello s3")
        let c = s3Config(fake.server.base)
        var steps: [Double] = []
        let lock = NSLock()
        do {
            let done = try ShareEngine.upload([f], with: c, ctx: ctx(secrets, progress: { p in lock.lock(); steps.append(p); lock.unlock() }))
            let r = done.record
            let put = fake.server.log.first { $0.method == "PUT" }
            check("S3: one signed PUT, the body streamed, UNSIGNED-PAYLOAD over the wire", put?.body == Data("hello s3".utf8)
                  && put?.headers["x-amz-content-sha256"] == SigV4.unsignedPayload && fake.badSignatures == 0)
            check("S3: Content-Type from the file's type, key with prefix, random part and a safe name", put?.headers["content-type"] == "text/plain"
                  && (put?.path ?? "").range(of: "^/bucket/share/test/[0-9a-f]{32}/Report-Q3-final-.txt$", options: .regularExpression) != nil)
            check("S3: progress reaches 100 %", steps.last == 1)
            let link = URL(string: r.link)!
            check("S3: the link is presigned for the chosen hour", SigV4.presignedParts(link)["X-Amz-Expires"] == "3600" && r.expires != nil && SigV4.presignedParts(link)["X-Amz-SignedHeaders"] == "host")
            let got = try ShareHTTP().send(URLRequest(url: link))
            check("S3: the presigned link downloads the file (its signature checked by the fake)", got.status == 200 && got.body == Data("hello s3".utf8) && fake.badSignatures == 0)
            var tampered = URLComponents(url: link, resolvingAgainstBaseURL: false)!
            tampered.queryItems = tampered.queryItems?.map { $0.name == "X-Amz-Expires" ? URLQueryItem(name: $0.name, value: "604800") : $0 }
            check("S3: a link whose expiry was changed is refused", (try? ShareHTTP().send(URLRequest(url: tampered.url!)))?.status == 403)
            fake.badSignatures = 0                              // that refusal was the point
            check("S3: the history entry has no contents, just the name, size, link, key", r.name == "Report Q3 (final).txt" && r.size == 8 && r.ref.hasPrefix("share/test/"))
            try ShareEngine.revoke(r, with: c, ctx: ctx(secrets))
            check("S3: revoke deletes the object; its link stops working", fake.objects.isEmpty && (try? ShareHTTP().send(URLRequest(url: link)))?.status == 404)
            check("S3: revoking again is fine (already gone)", (try? ShareEngine.revoke(r, with: c, ctx: ctx(secrets))) != nil)
        } catch { check("S3: upload (\(error))", false) }

        // a public base URL: a plain link, no expiry
        var pub = c; pub.settings["publicBase"] = "https://files.example.com/"
        if let r = try? ShareEngine.upload([f], with: pub, ctx: ctx(secrets)).record {
            check("S3: with a public address the link is that address + key, without expiry",
                  r.link.range(of: "^https://files.example.com/share/test/[0-9a-f]{32}/Report-Q3-final-.txt$", options: .regularExpression) != nil && r.expires == nil)
        } else { check("S3: public address upload", false) }

        // several files: zipped first
        let g = file(d, "second.txt", "two")
        if let r = try? ShareEngine.upload([f, g], with: c, ctx: ctx(secrets)).record,
           let key = fake.server.log.last(where: { $0.method == "PUT" })?.path {
            check("several files go up as one ZIP", r.name.hasSuffix(".zip") && key.hasSuffix(".zip") && fake.objects[key.removingPercentEncoding ?? key]?.prefix(2) == Data("PK".utf8))
        } else { check("several files go up as one ZIP", false) }

        // UNSIGNED-PAYLOAD refused → hashed, and remembered
        fake.refuseUnsigned = true
        if let done = try? ShareEngine.upload([f], with: c, ctx: ctx(secrets)) {
            let last = fake.server.log.last { $0.method == "PUT" }
            check("S3: a store that refuses UNSIGNED-PAYLOAD gets the file hashed, and the provider learns it",
                  last?.headers["x-amz-content-sha256"] == SigV4.sha256Hex("hello s3") && done.learned == ["payload": "hashed"])
            var hashed = c; hashed.settings["payload"] = "hashed"
            let before = fake.server.log.count
            _ = try? ShareEngine.upload([f], with: hashed, ctx: ctx(secrets))
            check("S3: hashed from then on (one request, no retry)", fake.server.log.count == before + 1)
        } else { check("S3: UNSIGNED-PAYLOAD fallback", false) }
        fake.refuseUnsigned = false

        // multipart (thresholds made small here)
        let (t0, m0) = (S3Provider.multipartThreshold, S3Provider.minPart)
        S3Provider.multipartThreshold = 2 << 20; S3Provider.minPart = 1 << 20
        defer { S3Provider.multipartThreshold = t0; S3Provider.minPart = m0 }
        let big = d.appendingPathComponent("big.bin")
        var bytes = Data(count: (5 << 20) + 1234)
        for i in stride(from: 0, to: bytes.count, by: 4096) { bytes[i] = UInt8(i / 4096 % 251) }
        try? bytes.write(to: big)
        var prog: [Double] = []
        if let r = try? ShareEngine.upload([big], with: c, ctx: ctx(secrets, progress: { p in lock.lock(); prog.append(p); lock.unlock() })).record {
            let parts = fake.server.log.filter { $0.method == "PUT" && $0.target.contains("partNumber=") }
            check("S3 multipart: 6 signed parts, put back together byte for byte", parts.count == 6 && fake.objects["/bucket/" + r.ref] == bytes && fake.badSignatures == 0)
            check("S3 multipart: progress grows to 100 %", prog.count >= 6 && prog.last == 1 && zip(prog, prog.dropFirst()).allSatisfy { $0 <= $1 })
        } else { check("S3 multipart upload", false) }
        let cancel = CancelToken()
        let abortsBefore = fake.aborted.count
        do {
            _ = try ShareEngine.upload([big], with: c, ctx: ctx(secrets, cancel: cancel, progress: { p in if p > 0.3 { cancel.cancel() } }))
            check("S3 multipart: Cancel stops it", false)
        } catch {
            check("S3 multipart: Cancel stops it and aborts the half upload (nothing left on the store)",
                  ShareError.from(error) == .cancelled && fake.aborted.count == abortsBefore + 1 && fake.multipartInFlight == 0)
        }
        fake.fail = 403
        check("S3: wrong keys → 'refused'", (try? ShareEngine.upload([f], with: c, ctx: ctx(secrets))) == nil
              && { do { _ = try ShareEngine.upload([f], with: c, ctx: ctx(secrets)); return false } catch { return ShareError.from(error) == .forbidden } }())
        fake.fail = nil
        let wrong = ["accessKey": creds.accessKey, "secretKey": "not-the-key"]
        check("S3: a wrong secret key fails the signature check", { do { _ = try ShareEngine.upload([f], with: c, ctx: ctx(wrong)); return false } catch { return ShareError.from(error) == .forbidden } }())
    }

    // MARK: WebDAV / Nextcloud

    static func webdav(_ check: (String, Bool) -> Void, _ skip: (String, String) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        let fake = FakeDAV(user: "ann@example.com", password: "app-pass-1")
        guard fake.start() else { skip("WebDAV", "can't listen on 127.0.0.1 here"); return }
        defer { fake.server.stop() }
        let d = dir("dav")
        let f = file(d, "photo 1.jpg", "jpegdata")
        let nc = ShareProviderConfig(kind: .nextcloud, title: "NC", settings: ["server": fake.server.base, "user": "ann@example.com", "folder": "Shared/Cocaine", "expiryDays": "7"])
        let secrets = ["password": "app-pass-1", "sharePassword": "s3cret pw"]
        let now = utc("20261008T120000Z")
        do {
            let r = try ShareEngine.upload([f], with: nc, ctx: ctx(secrets, now: now)).record
            check("Nextcloud: folders made level by level", fake.folders.contains("/remote.php/dav/files/ann@example.com/Shared") && fake.folders.contains("/remote.php/dav/files/ann@example.com/Shared/Cocaine"))
            let put = fake.server.log.first { $0.method == "PUT" }
            check("Nextcloud: PUT with Basic auth to the user's files, a safe name", put?.body == Data("jpegdata".utf8) && put?.headers["content-type"] == "image/jpeg"
                  && (put?.path.removingPercentEncoding ?? "").range(of: "^/remote.php/dav/files/ann@example.com/Shared/Cocaine/[0-9a-f]{8}-photo-1.jpg$", options: .regularExpression) != nil)
            check("Nextcloud: a public read-only link with the password and the expiry date", fake.lastShareForm["shareType"] == "3" && fake.lastShareForm["permissions"] == "1"
                  && fake.lastShareForm["password"] == "s3cret pw" && fake.lastShareForm["expireDate"] == "2026-10-15"
                  && (fake.lastShareForm["path"] ?? "").hasPrefix("/Shared/Cocaine/"))
            check("Nextcloud: the link and its id come from the OCS answer", r.link.hasPrefix(fake.server.base + "/s/share") && r.shareID == "40" && r.expires != nil)
            check("Nextcloud: OCS-APIRequest header sent", fake.server.log.contains { $0.method == "POST" && $0.headers["ocs-apirequest"] == "true" })
            try ShareEngine.revoke(r, with: nc, ctx: ctx(secrets))
            check("Nextcloud: revoke deletes the share, then the file", fake.shares.isEmpty && fake.files.isEmpty)
        } catch { check("Nextcloud upload (\(error))", false) }
        fake.ocsStatus = 404
        do { _ = try ShareEngine.upload([f], with: nc, ctx: ctx(secrets, now: now)); check("Nextcloud: a refused share fails", false) }
        catch { check("Nextcloud: a refused share fails, and the uploaded file isn't left behind", ShareError.from(error) == .notFound && fake.files.isEmpty) }
        fake.ocsStatus = 200
        check("OCS answers: failure codes and bad JSON become errors",
              (try? WebDAVProvider.parseShare(Data("not json".utf8))) == nil
              && { do { _ = try WebDAVProvider.parseShare(Data(#"{"ocs":{"meta":{"statuscode":403,"message":"no"},"data":[]}}"#.utf8)); return false } catch { return ShareError.from(error) == .forbidden } }()
              && (try? WebDAVProvider.parseShare(Data(#"{"ocs":{"meta":{"statuscode":200},"data":{"id":"7","url":"http://evil.example/s/x"}}}"#.utf8))) == nil)
        // plain WebDAV with a public base
        fake.folders.insert("/dav")
        let wd = ShareProviderConfig(kind: .webdav, title: "DAV", settings: ["url": fake.server.base + "/dav/", "user": "ann@example.com", "publicBase": "https://pub.example.com/x"])
        if let r = try? ShareEngine.upload([f], with: wd, ctx: ctx(secrets)).record {
            check("WebDAV: PUT into the folder, the link from the public address", r.link.range(of: "^https://pub.example.com/x/[0-9a-f]{8}-photo-1.jpg$", options: .regularExpression) != nil
                  && fake.files.keys.contains { $0.hasPrefix("/dav/") })
        } else { check("WebDAV upload", false) }
        let bad = ["password": "wrong"]
        check("WebDAV: a wrong password → 'refused the credentials'", { do { _ = try ShareEngine.upload([f], with: wd, ctx: ctx(bad)); return false } catch { return ShareError.from(error) == .unauthorized } }())
        var insecure = wd; insecure.settings["url"] = "http://dav.example.com/"
        check("WebDAV: an http address is refused before anything is sent", WebDAVProvider(config: insecure).validate(secrets: secrets) != nil)
    }

    // MARK: SFTP (arguments and batch only)

    static func sftp(_ check: (String, Bool) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        let c = ShareProviderConfig(kind: .sftp, title: "Server", settings: ["host": "files.example.com", "port": "2222", "user": "deploy", "remoteDir": "public_html/s/",
                                                                           "publicBase": "https://example.com/s"])
        let p = SFTPProvider(config: c)
        let args = p.arguments(batch: "/tmp/b")
        check("SFTP: key-only, batch mode, host keys checked, no passwords", args.contains("BatchMode=yes") && args.contains("StrictHostKeyChecking=yes")
              && args.contains("PasswordAuthentication=no") && args.contains("KbdInteractiveAuthentication=no") && !args.joined().contains("StrictHostKeyChecking=no"))
        check("SFTP: port, batch file, then -- and the destination last", Array(args.prefix(4)) == ["-b", "/tmp/b", "-P", "2222"] && args.suffix(2) == ["--", "deploy@files.example.com"])
        var k = c; k.settings["identity"] = "/etc/hosts"
        check("SFTP: a key file is used alone (IdentitiesOnly)", SFTPProvider(config: k).arguments(batch: "b").contains("IdentitiesOnly=yes") && SFTPProvider(config: k).arguments(batch: "b").contains("/etc/hosts"))
        for (h, u, dir) in [("-oProxyCommand=touch /tmp/x", "deploy", "a"), ("files.example.com", "-l", "a"), ("files.example.com", "a b", "a"), ("files.example.com", "deploy", "a\"; rm x"),
                            ("files.example.com", "deploy", "../etc"), ("files.example.com", "deploy", "a b")] {
            var bad = c; bad.settings["host"] = h; bad.settings["user"] = u; bad.settings["remoteDir"] = dir
            check("SFTP: refused: host \(h.prefix(14)), user \(u), folder \(dir.prefix(10))", SFTPProvider(config: bad).validate(secrets: [:]) != nil)
        }
        check("SFTP: valid settings pass", p.validate(secrets: [:]) == nil)
        // the upload with a fake sftp: what it would get
        let d = dir("sftp")
        let hostile = file(d, "$(touch pwned) \"; rm -rf ~ '.txt", "data")
        var seen: (args: [String], batch: String, target: String?) = ([], "", nil)
        var envOK = false
        var context = ctx([:])
        context.run = { path, a, env, _, _ in
            let bi = a.firstIndex(of: "-b").map { a[$0 + 1] } ?? ""
            let text = (try? String(contentsOfFile: bi, encoding: .utf8)) ?? ""
            var target: String?
            if let q = text.split(separator: "\"").dropFirst().first { target = try? FileManager.default.destinationOfSymbolicLink(atPath: String(q)) }
            seen = (a, text, target)
            envOK = path == "/usr/bin/sftp" && env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin" && env["DYLD_INSERT_LIBRARIES"] == nil
            return ShelfProc.Result(status: 0, stdout: Data(), stderr: Data())
        }
        if let r = try? ShareEngine.upload([hostile], with: c, ctx: context).record {
            check("SFTP: runs /usr/bin/sftp with a plain environment (nothing of Cocaine's)", envOK)
            let lines = seen.batch.split(separator: "\n")
            check("SFTP: one put; the local name is a safe link to the file, the remote name safe too", lines.count == 1 && lines[0].hasPrefix("put \"")
                  && seen.batch.range(of: "^put \"[^\"' ;$]+/touch-pwned-rm-rf-.txt\" \"public_html/s/[0-9a-f]{8}-touch-pwned-rm-rf-.txt\"\n$", options: .regularExpression) != nil
                  && seen.target == hostile.standardizedFileURL.path)
            check("SFTP: the link is the public address + the remote name", r.link.range(of: "^https://example.com/s/[0-9a-f]{8}-touch-pwned-rm-rf-.txt$", options: .regularExpression) != nil)
            check("SFTP: the batch and the link are gone afterwards", !FileManager.default.fileExists(atPath: seen.args[1]))
            var removed = ""
            context.run = { _, a, _, _, _ in removed = (try? String(contentsOfFile: a[1], encoding: .utf8)) ?? ""; return ShelfProc.Result(status: 0, stdout: Data(), stderr: Data()) }
            try? ShareEngine.revoke(r, with: c, ctx: context)
            check("SFTP: revoke removes the remote file", removed == "rm \"\(r.ref)\"\n")
        } else { check("SFTP: upload with a fake sftp", false) }
        var calls: [String] = []
        context.run = { _, a, _, _, _ in
            calls.append((try? String(contentsOfFile: a[1], encoding: .utf8)) ?? "")
            return calls.count == 1 ? ShelfProc.Result(status: -1, stdout: Data(), stderr: Data(), cancelled: true) : ShelfProc.Result(status: 0, stdout: Data(), stderr: Data())
        }
        do { _ = try ShareEngine.upload([hostile], with: c, ctx: context); check("SFTP: Cancel", false) }
        catch { check("SFTP: Cancel removes the half-sent file", ShareError.from(error) == .cancelled && calls.count == 2 && calls[1].hasPrefix("rm \"public_html/s/")) }
        check("SFTP: errors in the user's words", SFTPProvider.error("Host key verification failed.") != SFTPProvider.error("Permission denied (publickey).")
              && SFTPProvider.error("ssh: Could not resolve hostname x") == .offline)
    }

    // MARK: the user's command

    static func uploader(_ check: (String, Bool) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        check("tokenize: quotes, escapes, nothing expanded", (try? ShareUploader.tokenize(#"curl -F "a=@{file};type=x" 'it''s' \$HOME "q\"q" $(x)"#))
              == ["curl", "-F", "a=@{file};type=x", "its", "$HOME", "q\"q", "$(x)"])
        check("tokenize: an open quote or a line break is refused", (try? ShareUploader.tokenize("a 'b")) == nil && (try? ShareUploader.tokenize("a\nb")) == nil)
        let exe: (String) -> Bool = { ["/usr/bin/curl", "/bin/sh"].contains($0) }
        func problem(_ t: String) -> ShareUploader.Problem? { if case .failure(let p) = ShareUploader.check(t, isExecutable: exe) { return p }; return nil }
        check("templates: {file} is required", problem("curl https://x") == .noFile)
        check("templates: unknown placeholders are refused", problem("curl {file} {password}") == .unknownPlaceholder("password"))
        check("templates: the program can't be a placeholder", problem("{file} x") == .placeholderInProgram)
        check("templates: a missing program is said", problem("nosuchtool {file}") == .programMissing("nosuchtool"))
        check("templates: a bare name is found in the usual folders, JSON braces are text", problem(#"curl -d '{"a":1}' {file}"#) == nil)
        check("templates: the host is shown before the first run", ShareUploader.host(of: "curl -F f=@{file} https://up.example.com/api") == "up.example.com")
        // a real run with a hostile name
        let d = dir("uploader")
        let witnessName = "cocaine-pwned-\(getpid())"
        let witness = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(witnessName)
        let hostile = file(d, "$(touch \(witnessName)); -rf \"a'b`id`.txt", "payload")
        check("uploader: the hostile file is there", FileManager.default.fileExists(atPath: hostile.path))
        let script = file(d, "up.sh", "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(d.path)/args\"\ncat \"$1\" > \"\(d.path)/content\"\nstat -f %Lp \"$2\" > \"\(d.path)/mode\"\ncat \"$2\" > \"\(d.path)/hdr\"\necho \"done: https://files.example.com/x/abc.txt?token=1 \"\n")
        var c = ShareProviderConfig(kind: .uploader, title: "Mine", settings: ["template": "/bin/sh \(script.path) {file} {secret_headers} {name} {mime}", "extract": "url"])
        let secrets = ["headers": "Authorization: Bearer t0k3n"]
        do { _ = try ShareEngine.upload([hostile], with: c, ctx: ctx(secrets)); check("uploader: not run before it's allowed", false) }
        catch { check("uploader: not run before it's allowed", ShareError.from(error) == .notApproved && !FileManager.default.fileExists(atPath: d.appendingPathComponent("args").path)) }
        c.approved = ShareUploader.fingerprint(c)
        var real = ctx(secrets)
        var argvSeen: [String] = []
        var envClean = false
        let base = real.run
        real.run = { p, a, e, t, k in argvSeen = a; envClean = !e.values.contains { $0.contains("t0k3n") }; return base(p, a, e, t, k) }
        do {
            let r = try ShareEngine.upload([hostile], with: c, ctx: real).record
            let args = (try? String(contentsOf: d.appendingPathComponent("args"), encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            check("uploader: a hostile name reaches the program as one harmless path; nothing ran", !FileManager.default.fileExists(atPath: witness.path)
                  && args.count == 4 && (args[0] as NSString).lastPathComponent == ShareRules.safeName(hostile.lastPathComponent)
                  && args[2] == ShareRules.safeName(hostile.lastPathComponent) && args[3] == "text/plain")
            check("uploader: the program reads the file's real contents", (try? String(contentsOf: d.appendingPathComponent("content"), encoding: .utf8)) == "payload")
            check("uploader: secret headers in a 0600 file, never in the arguments", (try? String(contentsOf: d.appendingPathComponent("mode"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "600"
                  && (try? String(contentsOf: d.appendingPathComponent("hdr"), encoding: .utf8)) == "Authorization: Bearer t0k3n\n" && !argvSeen.joined().contains("t0k3n"))
            check("uploader: the link is the first https URL it printed", r.link == "https://files.example.com/x/abc.txt?token=1")
            check("uploader: secrets aren't in the environment", envClean)
            check("uploader: its temporary files are gone", !FileManager.default.fileExists(atPath: args[0]) && !FileManager.default.fileExists(atPath: args[1]))
        } catch { check("uploader: run (\(error))", false) }
        var changed = c; changed.settings["template"] = c["template"] + " extra"
        check("uploader: a changed command asks again; a changed script too", ShareUploader.needsApproval(changed) && !ShareUploader.needsApproval(c)
              && { try? Data("#!/bin/sh\necho https://evil.example\n".utf8).write(to: script); return ShareUploader.needsApproval(c) }())
        // timeouts and bounded output
        var slow = ShareProviderConfig(kind: .uploader, title: "Slow", settings: ["template": "/bin/sh -c 'sleep 5' sh {file}", "timeout": "1"])
        slow.approved = ShareUploader.fingerprint(slow)
        var tctx = ctx([:])
        tctx.run = { p, a, e, _, k in ShelfProc.run(p, a, env: e, timeout: 1, cancel: k) }
        let t0 = Date()
        check("uploader: a command that hangs is stopped", { do { _ = try ShareEngine.upload([hostile], with: slow, ctx: tctx); return false } catch { return ShareError.from(error) == .timeout } }() && Date().timeIntervalSince(t0) < 4)
        // link extraction
        check("links: the first https URL, trailing punctuation dropped", ShareUploader.extract("ok (see https://a.example/f.png).", mode: .url, pattern: "")?.absoluteString == "https://a.example/f.png")
        check("links: an http link from the internet is refused", ShareUploader.extract("http://a.example/f.png", mode: .url, pattern: "") == nil)
        check("links: a regular expression's first group", ShareUploader.extract("id=1 url=<https://b.example/x> end", mode: .regex, pattern: "url=<([^>]+)>")?.absoluteString == "https://b.example/x")
        check("links: a JSON path with indexes", ShareUploader.extract(#"{"files":[{"url":"https://c.example/1"}],"ok":true}"#, mode: .json, pattern: "files[0].url")?.absoluteString == "https://c.example/1"
              && ShareUploader.extract(#"{"data":{"link":"https://c.example/2"}}"#, mode: .json, pattern: "$.data.link")?.absoluteString == "https://c.example/2"
              && ShareUploader.extract(#"{"files":[]}"#, mode: .json, pattern: "files[0].url") == nil && ShareUploader.extract("<html>", mode: .json, pattern: "url") == nil)
        check("presets are text only: none is set up by itself; the public one carries its warning",
              ShareUploader.presets.contains { $0.id == "litterbox" && $0.warning.count > 60 } && CloudShareCenter.make().store.settings.providers.isEmpty)
    }

    // MARK: errors

    static func errors(_ check: (String, Bool) -> Void, _ skip: (String, String) -> Void) {
        check("statuses: 401, 403, 404, 409, 5xx, others", ShareError.status(401) == .unauthorized && ShareError.status(403) == .forbidden && ShareError.status(404) == .notFound
              && ShareError.status(409) == .conflict && ShareError.status(503) == .server(503) && ShareError.status(418) == .http(418) && ShareError.status(204) == nil
              && ShareError.status(302) == .redirected)
        check("URL errors: timeout, offline, cancel", ShareError.from(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)) == .timeout
              && ShareError.from(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)) == .offline
              && ShareError.from(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)) == .cancelled)
        let server = FakeHTTPServer()
        guard server.start() else { skip("HTTP errors", "can't listen on 127.0.0.1 here"); return }
        defer { server.stop() }
        server.handler = { r in
            switch r.path {
            case "/redirect": return .init(status: 302, headers: ["Location": "http://127.0.0.1:\(server.port)/stolen"])
            case "/slow": return .init(status: 200, delay: 3)
            case "/big": return .init(status: 200, body: Data(count: 300_000))
            case "/err": return .init(status: 500)
            default: return .init(status: 200, body: Data("ok".utf8))
            }
        }
        let http = ShareHTTP()
        var req = URLRequest(url: URL(string: server.base + "/redirect")!)
        req.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        do { _ = try http.send(req); check("redirects aren't followed with credentials", false) }
        catch { check("redirects aren't followed with credentials", ShareError.from(error) == .redirected && !server.log.contains { $0.path == "/stolen" }) }
        http.timeout = 1
        let t0 = Date()
        do { _ = try http.send(URLRequest(url: URL(string: server.base + "/slow")!)); check("a server that doesn't answer times out", false) }
        catch { check("a server that doesn't answer times out", ShareError.from(error) == .timeout && Date().timeIntervalSince(t0) < 2.5) }
        http.timeout = 10
        http.maxResponse = 100_000
        check("answers are bounded", { do { _ = try http.send(URLRequest(url: URL(string: server.base + "/big")!)); return false } catch { return true } }())
        check("5xx → 'try again later'", { do { _ = try http.expect(URLRequest(url: URL(string: server.base + "/err")!)); return false } catch { return ShareError.from(error) == .server(500) } }())
        let cancel = CancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancel.cancel() }
        let t1 = Date()
        do { _ = try ShareHTTP().send(URLRequest(url: URL(string: server.base + "/slow")!), cancel: cancel); check("Cancel stops a request", false) }
        catch { check("Cancel stops a request at once", ShareError.from(error) == .cancelled && Date().timeIntervalSince(t1) < 1.5) }
        check("http to another host is refused before sending", { do { _ = try ShareHTTP().send(URLRequest(url: URL(string: "http://example.com/x")!)); return false } catch { return ShareError.from(error) == .insecure("example.com") } }())
        let secretURL = "https://b.example/k?X-Amz-Signature=abc&X-Amz-Credential=AKIA"
        let texts = [ShareError.insecure("b.example"), .redirected, .unauthorized, .badResponse("x"), .timeout].compactMap(\.errorDescription)
        check("error texts never carry a signed URL or a key", !texts.contains { $0.contains("X-Amz") || $0.contains("AKIA") || $0.contains(secretURL) })
        check("the kill switch: nothing uploads while sharing is off", { do { try ShareEngine.precheck([URL(fileURLWithPath: "/etc/hosts")], kind: .s3, on: false); return false } catch { return ShareError.from(error) == .off } }())
        check("at most 100 files at a time", { do { try ShareEngine.precheck(Array(repeating: URL(fileURLWithPath: "/etc/hosts"), count: 101), kind: .s3, on: true); return false } catch { return ShareError.from(error) == .tooMany(100) } }())
    }

    // MARK: history and settings on disk

    static func storage(_ check: (String, Bool) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        let d = dir("store")
        let hf = d.appendingPathComponent("share/history.json")
        let h = ShareHistory(file: hf)
        let now = Date()
        let a = ShareRecord(provider: "p1", providerTitle: "R2", kind: .s3, name: "a.png", size: 10, date: now, expires: now.addingTimeInterval(3600), link: "https://x/a", ref: "k/a")
        let b = ShareRecord(provider: "p1", providerTitle: "R2", kind: .s3, name: "b.png", size: 10, date: now, expires: now.addingTimeInterval(-1), link: "https://x/b", ref: "k/b")
        h.add(a); h.add(b)
        let mode = ((try? FileManager.default.attributesOfItem(atPath: hf.path))?[.posixPermissions] as? NSNumber)?.intValue
        check("history: saved 0600, read back newest first", mode == 0o600 && ShareHistory(file: hf).records.map(\.name) == ["b.png", "a.png"])
        h.markRevoked(a.id)
        check("history: revoked is remembered", ShareHistory(file: hf).records.first { $0.id == a.id }?.revoked == true)
        h.add(ShareRecord(provider: "p1", providerTitle: "R2", kind: .s3, name: "c", size: 1, date: now, expires: nil, link: "https://x/c", ref: "c"))
        h.removeExpired(now: now)
        check("history: 'Remove expired' drops expired and revoked links, keeps the rest", ShareHistory(file: hf).records.map(\.name) == ["c"])
        for i in 0..<210 { h.add(ShareRecord(provider: "p", providerTitle: "t", kind: .sftp, name: "\(i)", size: 0, date: now, link: "https://x/\(i)", ref: "")) }
        check("history: at most 200 entries", ShareHistory(file: hf).records.count == 200)
        check("history: an unreadable file starts empty", { try? Data("garbage".utf8).write(to: hf); return ShareHistory(file: hf).records.isEmpty }())
        let sf = d.appendingPathComponent("share/providers.json")
        let secrets = MemorySecretStore()
        let s = ShareStore(file: sf, secrets: secrets)
        var c = s3Config("https://acc.r2.cloudflarestorage.com")
        c.title = "My R2"
        s.update { $0.providers.append(c) }
        try? secrets.save(c.id, ["accessKey": "AKIAEXAMPLEKEY", "secretKey": "VERY-SECRET-VALUE"])
        let text = (try? String(contentsOf: sf, encoding: .utf8)) ?? ""
        check("settings: saved 0600 and read back; no secret in the file", ShareStore(file: sf, secrets: secrets).settings.providers.first?.title == "My R2"
              && !text.contains("VERY-SECRET") && !text.contains("AKIAEXAMPLE")
              && ((try? FileManager.default.attributesOfItem(atPath: sf.path))?[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        s.update { $0.on = false }
        check("settings: the kill switch hides every provider from the shelf", s.usable.isEmpty && ShareStore(file: sf, secrets: secrets).settings.on == false)
        s.update { $0.on = true }; s.updateProvider(c.id) { $0.enabled = false }
        check("settings: a provider turned off isn't offered", s.usable.isEmpty)
        s.remove(c.id)
        check("settings: removing a provider deletes its Keychain item", s.settings.providers.isEmpty && (try? secrets.load(c.id)) == [:])
    }

    // MARK: Keychain

    static func keychain(_ check: (String, Bool) -> Void, _ skip: (String, String) -> Void, _ root: URL) {
        let path = root.appendingPathComponent("share.keychain-db").path
        func security(_ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }
        guard security(["create-keychain", "-p", "cocaine-test", path]) == 0 else { skip("keychain", "can't make a temporary keychain here"); return }
        defer { _ = security(["delete-keychain", path]) }
        _ = security(["unlock-keychain", "-p", "cocaine-test", path])
        var kc: SecKeychain?
        guard SecKeychainOpen(path, &kc) == errSecSuccess, let kc else { check("keychain: temporary keychain opens", false); return }
        let store = KeychainSecretStore(service: "local.cocaine.share.test", keychain: kc)
        check("keychain: nothing at first", (try? store.load("p1")) == [:])
        check("keychain: secrets saved and read back", (try? store.save("p1", ["secretKey": "abc", "accessKey": "id", "empty": ""])) != nil
              && (try? store.load("p1")) == ["secretKey": "abc", "accessKey": "id"])
        check("keychain: saving again replaces", (try? store.save("p1", ["secretKey": "new"])) != nil && (try? store.load("p1")) == ["secretKey": "new"])
        check("keychain: one item per provider", (try? store.save("p2", ["password": "x"])) != nil && (try? store.load("p1")) == ["secretKey": "new"])
        check("keychain: delete (twice is fine)", (try? store.delete("p1")) != nil && (try? store.load("p1")) == [:] && (try? store.delete("p1")) != nil)
        check("keychain: the login keychain was not used", (try? KeychainSecretStore(service: "local.cocaine.share.test").load("p2")) == [:])
        check("keychain: the real service name", KeychainSecretStore.service == "local.cocaine.share")
    }

    // MARK: clipboard

    static func clipboard(_ check: (String, Bool) -> Void) {
        let pb = NSPasteboard(name: NSPasteboard.Name("local.cocaine.cloud-test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let link = URL(string: "https://b.example/k?X-Amz-Signature=abc")!
        CloudClipboard.write([link], to: pb)
        let types = pb.types?.map(\.rawValue) ?? []
        check("links: on the clipboard as text", pb.string(forType: .string) == link.absoluteString)
        check("links: a plain copy (2.9): no concealed/transient marker that could keep it from Universal Clipboard or other apps",
              !ClipRules.isConcealed(types) && types.contains(ClipRules.ownType))
        let snap = SystemPasteboard(pb).snapshot(maxImageBytes: 1 << 20, allowed: { _, _ in true })
        if case .skip = ClipRules.decide(snap, settings: ClipSettings()) { check("links: Cocaine's clipboard history doesn't keep them", true) }
        else { check("links: Cocaine's clipboard history doesn't keep them", false) }
        let types2 = Set(types)
        check("links: no URL or file type that another app could read as a document", !types2.contains(NSPasteboard.PasteboardType.fileURL.rawValue))
    }

    // MARK: custom actions: webhook, keys, chain, import/export

    static func actions(_ check: (String, Bool) -> Void, _ skip: (String, String) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        let old = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","kind":"shell","target":"/bin/echo","output":"ignore","timeout":120,"instant":false}"#.utf8)
        let decoded = try? JSONDecoder().decode(ShelfAction.self, from: old)
        check("actions saved before keys/webhooks/chains still load", decoded?.name == "Old" && decoded?.key == nil && decoded?.hook == nil && decoded?.then == nil)
        let server = FakeHTTPServer()
        guard server.start() else { skip("webhook", "can't listen on 127.0.0.1 here"); return }
        defer { server.stop() }
        server.handler = { r in r.path == "/redir" ? .init(status: 307, headers: ["Location": "https://evil.example/"]) : .init(status: 200, body: Data("received \(r.body.count)".utf8)) }
        let d = dir("hook")
        let f1 = file(d, "a b.txt", "one"), f2 = file(d, "c.png", "two!")
        var a = ShelfAction(name: "Hook", kind: .webhook, target: server.base + "/in", hook: WebhookSpec(method: "PUT", body: .file))
        check("webhook: https only (http just for this Mac)", ShelfActionEngine.check(ShelfAction(name: "x", kind: .webhook, target: "http://example.com/x")) != nil
              && ShelfActionEngine.check(a) == nil)
        check("webhook: asks before its first run, and again when the address changes", ShelfActionEngine.needsApproval(a)
              && { var x = a; x.approved = ShelfActionEngine.fingerprint(a); var y = x; y.target += "2"; return !ShelfActionEngine.needsApproval(x) && ShelfActionEngine.needsApproval(y) }())
        check("webhook: not run before it's allowed", (try? ShelfActionEngine.run(a, files: [f1])) == nil && server.log.isEmpty)
        a.approved = ShelfActionEngine.fingerprint(a)
        try? ShelfActionEngine.secrets.save(ShareWebhook.secretAccount(a.id), ["headers": "Authorization: Bearer hook-token\nHost: evil"])
        let out = try? ShelfActionEngine.run(a, files: [f1, f2])
        let puts = server.log.filter { $0.method == "PUT" }
        check("webhook: one PUT per file with its bytes, type and a safe name", puts.count == 2 && puts[0].body == Data("one".utf8) && puts[1].body == Data("two!".utf8)
              && puts[0].headers["x-cocaine-filename"] == "a-b.txt" && puts[1].headers["content-type"] == "image/png")
        check("webhook: the secret header from the Keychain is sent; reserved ones are not", puts.allSatisfy { $0.headers["authorization"] == "Bearer hook-token" }
              && puts.allSatisfy { $0.headers["host"]?.hasPrefix("127.0.0.1") == true })
        check("webhook: the answer is the action's output", out?.ok == true && out?.output == "received 3\nreceived 4")
        a.hook = WebhookSpec(method: "POST", body: .json); a.approved = ShelfActionEngine.fingerprint(a)
        _ = try? ShelfActionEngine.run(a, files: [f1])
        let post = server.log.last
        let json = post.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
        check("webhook: details as JSON (names, sizes, types; no paths)", post?.method == "POST" && post?.headers["content-type"] == "application/json"
              && ((json?["files"] as? [[String: Any]])?.first?["name"] as? String) == "a b.txt" && !String(decoding: post?.body ?? Data(), as: UTF8.self).contains(d.path))
        var r = a; r.target = server.base + "/redir"; r.approved = ShelfActionEngine.fingerprint(r)
        let red = try? ShelfActionEngine.run(r, files: [f1])
        check("webhook: a redirect isn't followed", red?.ok == false && (red?.errors ?? "").isEmpty == false)
        check("webhook: the headers parser drops bad names and line tricks", ShareWebhook.headers("X-Ok: 1\nBad Name: 2\nContent-Length: 9\n: x\nX-A: b").map(\.0) == ["X-Ok", "X-A"])
        // keys
        var k1 = ShelfAction(name: "One", kind: .moveTo, target: d.path); k1.key = 1
        let acts = [k1, ShelfAction(name: "Two", kind: .moveTo, target: d.path)]
        check("keys: ⌥1 finds the action with key 1", ShelfActionKeys.action(18, flags: .option, in: acts)?.name == "One")
        do {                                                              // the shelf's keys: ⌥1 runs it on the selection
            let target = dir("moved-by-key")
            let store = ShelfStore(disk: ShelfDisk(dir: dir("key-store"), persist: false), defaults: MemoryDefaults())
            let config = ShelfConfigStore(defaults: { MemoryDefaults() })
            var mv = ShelfAction(name: "Move", kind: .moveTo, target: target.path); mv.key = 1
            config.update { $0.actions = [mv] }
            let center = ShelfCenter(store: store, config: config)
            store.add(urls: [file(dir("key-src"), "k.txt", "k")])
            let used = ShelfKeys.handle(18, flags: .option, chars: "1", editing: false, shown: true, center: center)
            let deadline = Date().addingTimeInterval(5)
            while center.tasks.busy || !FileManager.default.fileExists(atPath: target.appendingPathComponent("k.txt").path), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            check("keys: ⌥1 in the shelf runs the action on the selection", used && FileManager.default.fileExists(atPath: target.appendingPathComponent("k.txt").path))
            check("keys: not while typing in a field, nor ⌥2 with no action", !ShelfKeys.handle(18, flags: .option, chars: "1", editing: true, shown: true, center: center)
                  && !ShelfKeys.handle(19, flags: .option, chars: "2", editing: false, shown: true, center: center))
        }
        check("keys: ⌘⌥1, ⌥⇧1, ⌥2 (unassigned) don't", ShelfActionKeys.action(18, flags: [.option, .command], in: acts) == nil
              && ShelfActionKeys.action(18, flags: [.option, .shift], in: acts) == nil && ShelfActionKeys.action(19, flags: .option, in: acts) == nil)
        // chain
        var A = ShelfAction(name: "A", kind: .shell, target: "/bin/echo"), B = ShelfAction(name: "B", kind: .shell, target: "/bin/echo"), C = ShelfAction(name: "C", kind: .shell, target: "/bin/echo")
        A.then = B.id; B.then = C.id
        check("chain: A then B", ShelfActionChain.next(after: A, in: [A, B, C], depth: 0)?.id == B.id)
        check("chain: stops at 4 steps", ShelfActionChain.next(after: A, in: [A, B, C], depth: 3) == nil)
        C.then = A.id
        check("chain: a loop is refused", ShelfActionChain.next(after: A, in: [A, B, C], depth: 0) == nil)
        var self1 = A; self1.then = A.id
        check("chain: an action can't follow itself", ShelfActionChain.next(after: self1, in: [self1], depth: 0) == nil)
        check("chain: B gets the files A printed, else the same files", ShelfActionChain.files(output: "\(f2.path)\n/nonexistent/x\nnoise", moved: [], fallback: [f1]) == [f2]
              && ShelfActionChain.files(output: "nothing", moved: [], fallback: [f1]) == [f1] && ShelfActionChain.files(output: "", moved: [f2], fallback: [f1]) == [f2])
        // import / export
        var e1 = ShelfAction(name: "Send", kind: .webhook, target: "https://x.example/h", hook: WebhookSpec()); e1.approved = "yes"; e1.key = 2
        var e2 = ShelfAction(name: "Next", kind: .shortcut, target: "Make GIF"); e2.approved = "shortcut:Make GIF"; e1.then = e2.id
        let data = ShelfActionIO.export([e1, e2])
        let text = String(decoding: data, as: UTF8.self)
        check("export: no approvals, no secrets", !text.contains("\"approved\"") && !text.contains("hook-token") && text.contains("cocaine.shelf-actions"))
        var existing = ShelfAction(name: "Mine", kind: .shell, target: "/bin/echo"); existing.key = 2
        let imported = (try? ShelfActionIO.import(data, existing: [existing])) ?? []
        check("import: new ids, the chain follows them, not approved, a key in use is dropped", imported.count == 2 && imported[0].id != e1.id && imported[0].then == imported[1].id
              && imported.allSatisfy { $0.approved == nil } && imported[0].key == nil && ShelfActionEngine.needsApproval(imported[0]))
        check("import: other files are refused", (try? ShelfActionIO.import(Data("{}".utf8), existing: [])) == nil
              && (try? ShelfActionIO.import(Data(count: (1 << 20) + 1), existing: [])) == nil
              && (try? ShelfActionIO.import(data, existing: Array(repeating: existing, count: ShelfConfig.maxActions))) == nil)
    }

    // MARK: the shelf's hook, end to end

    static func shelfHook(_ check: (String, Bool) -> Void, _ skip: (String, String) -> Void, dir: (String) -> URL, file: (URL, String, String) -> URL) {
        let fake = FakeS3(creds: creds, region: "auto")
        guard fake.start() else { skip("shelf hook", "can't listen on 127.0.0.1 here"); return }
        defer {
            fake.server.stop()
            CloudShareHook.providers = { [] }; CloudShareHook.upload = nil; CloudShareHook.prepare = nil; CloudShareHook.deliver = nil
        }
        let secrets = MemorySecretStore()
        let cloud = CloudShareCenter(store: ShareStore(file: nil, secrets: secrets), history: ShareHistory(file: nil))
        var c = s3Config(fake.server.base); c.confirmEach = false
        cloud.store.update { $0.providers.append(c) }
        try? secrets.save(c.id, ["accessKey": creds.accessKey, "secretKey": creds.secretKey])
        let pb = NSPasteboard(name: NSPasteboard.Name("local.cocaine.cloud-test.shelf.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        cloud.pasteboard = { pb }
        cloud.install()
        check("hook: the shelf lists the enabled providers", CloudShareHook.providers().map(\.id) == [c.id])
        let d = dir("hook-shelf")
        let store = ShelfStore(disk: ShelfDisk(dir: dir("hook-store"), persist: false), defaults: MemoryDefaults())
        let center = ShelfCenter(store: store, config: ShelfConfigStore(defaults: { MemoryDefaults() }))
        center.pasteboard = { pb }
        store.add(urls: [file(d, "note.txt", "shelf file")])
        check("hook: 'Share link…' is offered once a provider is there", center.ops(for: store.items).contains(.shareLink))
        var progressSeen = false
        center.shareLink(provider: c.id)
        let deadline = Date().addingTimeInterval(10)
        while (center.tasks.busy || cloud.history.records.isEmpty) && Date() < deadline {
            if center.tasks.running?.title.contains("Fake S3") == true { progressSeen = true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let link = pb.string(forType: .string) ?? ""
        check("hook: the upload runs as the shelf's job (its progress line, Cancel)", progressSeen)
        check("hook: the link is on the clipboard, as a plain copy", link.hasPrefix(fake.server.base + "/bucket/share/test/") && !ClipRules.isConcealed(pb.types?.map(\.rawValue) ?? []))
        check("hook: the history has it and the toast shows it", cloud.history.records.first?.link == link && cloud.recent?.link == link)
        check("hook: nothing failed the signature check", fake.badSignatures == 0 && fake.objects.count == 1)
        cloud.store.update { $0.on = false }
        check("hook: the kill switch hides 'Share link…'", CloudShareHook.providers().isEmpty && !center.ops(for: store.items).contains(.shareLink))
        cloud.store.update { $0.on = true }
        let spec = cloud.confirmation(c, count: 3)
        check("confirmation: says where and for how long, and Cancel is the default", (spec.message ?? "").contains("127.0.0.1") && spec.safeDefault
              && spec.buttons.contains { $0.id == "upload" })
        // a test of the connection
        let result = cloud.runTest(c)
        if case .success(let s) = result { check("Test connection: uploads, opens the link, deletes it", !s.isEmpty && fake.objects.count == 1) }
        else { check("Test connection (\(result))", false) }
        try? cloud.setSecrets(c.id, ["accessKey": creds.accessKey, "secretKey": "rotated"])
        check("secrets: a change made in Settings is used at once (the cache follows the Keychain)", cloud.secrets(c.id)["secretKey"] == "rotated"
              && secrets.items[c.id]?["secretKey"] == "rotated")
        try? secrets.save(c.id, ["secretKey": "changed-behind-our-back"])
        check("secrets: the Keychain is read once per provider, not on every redraw", cloud.secrets(c.id)["secretKey"] == "rotated")
        try? cloud.setSecrets(c.id, ["accessKey": creds.accessKey, "secretKey": creds.secretKey])
        fake.fail = 401
        if case .failure(let e) = cloud.runTest(c) { check("Test connection: a refusal is said plainly", e == .unauthorized) } else { check("Test connection: refusal", false) }
        fake.fail = nil
        cloud.removeProvider(c.id)
        check("secrets: removing a provider forgets its secrets too", cloud.secrets(c.id).isEmpty && secrets.items[c.id] == nil && CloudShareHook.providers().isEmpty)
    }
}
