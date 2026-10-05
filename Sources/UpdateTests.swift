// Regression tests for the updater (`--update-test`) and the signing tier (`--signature-test`). They use temporary folders,
// a throwaway key pair and a local HTTP server on 127.0.0.1 that this process starts and stops; nothing touches the
// installed app, the network or the user's settings. Tests needing this Mac's local signing identity print SKIP when it
// isn't there (and always in CI).

import CryptoKit
import Foundation
import Security

private var failures = 0
private func check(_ name: String, _ ok: Bool, _ note: String = "") {
    print((ok ? "PASS" : "FAIL") + "  " + name + (ok || note.isEmpty ? "" : "  [\(note)]"))
    if !ok { failures += 1 }
}
private func skip(_ name: String, _ why: String) { print("SKIP  \(name)  (\(why))") }
private var inCI: Bool { ProcessInfo.processInfo.environment["CI"] == "true" }

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

// MARK: - Local HTTP server

/// One connection at a time, `Connection: close`, enough HTTP/1.1 for the downloader. `behave` decides each answer.
final class TestHTTPServer {
    enum Answer { case serve(Data), cut(Data, after: Int), ignoreRange(Data), noLength(Data), status(Int), redirect(String), badRange(Data) }
    private(set) var port: UInt16 = 0
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var _log: [(path: String, range: String?)] = []
    var log: [(path: String, range: String?)] { lock.lock(); defer { lock.unlock() }; return _log }
    private let behave: (_ path: String, _ n: Int) -> Answer
    private let done = DispatchSemaphore(value: 0)

    init?(_ behave: @escaping (_ path: String, _ n: Int) -> Answer) {
        self.behave = behave
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { self.loop() }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func stop() {
        let f = fd; fd = -1
        shutdown(f, SHUT_RDWR); close(f)
        _ = done.wait(timeout: .now() + 2)
    }

    private func loop() {
        var counts: [String: Int] = [:]
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { break }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var req = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while !req.contains(Data("\r\n\r\n".utf8)) {
                let n = read(c, &buf, buf.count); if n <= 0 { break }; req.append(buf, count: n)
            }
            let text = String(decoding: req, as: UTF8.self)
            let lines = text.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            lock.lock(); _log.append((path, range)); lock.unlock()
            counts[path, default: 0] += 1
            answer(c, behave(path, counts[path]!), range: range)
            close(c)
        }
        done.signal()
    }

    private func send(_ c: Int32, _ d: Data) {
        d.withUnsafeBytes { p in
            var off = 0
            while off < d.count { let n = write(c, p.baseAddress! + off, d.count - off); if n <= 0 { return }; off += n }
        }
    }

    private func head(_ c: Int32, _ status: String, _ headers: [String]) {
        send(c, Data((["HTTP/1.1 \(status)"] + headers + ["Connection: close", "", ""]).joined(separator: "\r\n").utf8))
    }

    private func answer(_ c: Int32, _ a: Answer, range: String?) {
        let start = range.flatMap { r -> Int? in r.hasPrefix("bytes=") ? Int(r.dropFirst(6).split(separator: "-").first ?? "") : nil }
        switch a {
        case .serve(let d):
            if let s = start, s < d.count {
                head(c, "206 Partial Content", ["Content-Length: \(d.count - s)", "Content-Range: bytes \(s)-\(d.count - 1)/\(d.count)"])
                send(c, d.subdata(in: s..<d.count))
            } else if let s = start, s >= d.count {
                head(c, "416 Range Not Satisfiable", ["Content-Length: 0", "Content-Range: bytes */\(d.count)"])
            } else {
                head(c, "200 OK", ["Content-Length: \(d.count)"]); send(c, d)
            }
        case .cut(let d, let after):
            let s = start ?? 0
            head(c, s > 0 ? "206 Partial Content" : "200 OK",
                 ["Content-Length: \(d.count - s)"] + (s > 0 ? ["Content-Range: bytes \(s)-\(d.count - 1)/\(d.count)"] : []))
            send(c, d.subdata(in: s..<min(d.count, s + after)))      // then the connection drops
        case .ignoreRange(let d):
            head(c, "200 OK", ["Content-Length: \(d.count)"]); send(c, d)
        case .noLength(let d):                                  // no Content-Length: the body ends when the connection closes
            head(c, "200 OK", []); send(c, d)
        case .badRange(let d):
            if let s = start, s > 0 {
                head(c, "206 Partial Content", ["Content-Length: \(d.count - s)", "Content-Range: bytes 0-\(d.count - s - 1)/\(d.count)"])
                send(c, d.subdata(in: 0..<(d.count - s)))
            } else { head(c, "200 OK", ["Content-Length: \(d.count)"]); send(c, d) }
        case .status(let code):
            head(c, "\(code) Test", ["Content-Length: 0"])
        case .redirect(let to):
            head(c, "302 Found", ["Location: \(to)", "Content-Length: 0"])
        }
    }
}

// MARK: - Dummy app bundles

enum TestBundles {
    /// A minimal Cocaine.app: this binary as its executable (so codesign has real Mach-O to sign), the given version/build.
    static func make(at app: URL, version: String, build: Int, marker: String) {
        let fm = FileManager.default
        let macos = app.appendingPathComponent("Contents/MacOS")
        try? fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try? fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        try? fm.copyItem(atPath: exe, toPath: macos.appendingPathComponent("Cocaine").path)
        let info: NSDictionary = ["CFBundleIdentifier": Installer.bundleID, "CFBundleExecutable": "Cocaine", "CFBundlePackageType": "APPL",
                                  "CFBundleShortVersionString": version, "CFBundleVersion": String(build), "CFBundleName": "Cocaine"]
        info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try? Data(marker.utf8).write(to: app.appendingPathComponent("Contents/Resources/marker"))
    }

    static func marker(_ app: URL) -> String? {
        (try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8))
    }

    @discardableResult
    static func signAdhoc(_ app: URL) -> Bool { runTool("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) == 0 }

    static let localKeychain = NSHomeDirectory() + "/.cocaine-signing/cocaine-signing.keychain"

    /// The SHA-1 of this Mac's "Cocaine Local Signing" identity, when there is one (what build.sh signs with).
    static func localIdentity() -> String? {
        guard !inCI, FileManager.default.fileExists(atPath: localKeychain) else { return nil }
        runTool("/usr/bin/security", ["unlock-keychain", "-p", "cocaine", localKeychain])
        var out = ""
        runTool("/usr/bin/security", ["find-certificate", "-c", SigningTier.localCommonName, "-Z", localKeychain], output: &out)
        return out.components(separatedBy: "\n").first { $0.hasPrefix("SHA-1 hash:") }?.components(separatedBy: " ").last
    }

    @discardableResult
    static func signLocal(_ app: URL, _ id: String) -> Bool {
        runTool("/usr/bin/codesign", ["--force", "--sign", id, "--keychain", localKeychain, app.path]) == 0
    }
}

// MARK: - Updater tests

enum UpdateTests {
    static func run() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let scratch = tempDir("updates")                     // never the real ~/Library/Caches/local.cocaine.toggle
        setenv("COCAINE_UPDATES_DIR", scratch.path, 1)
        defer { try? FileManager.default.removeItem(at: scratch) }
        semver(); manifests(); releases(); policyAndSchedule(); homebrew(); downloads(); installs(); relauncher()
        print(failures == 0 ? "update tests: all passed" : "update tests: \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func semver() {
        func v(_ s: String) -> SemVer { SemVer(s)! }
        check("semver: 2.10.0 > 2.9.0 (numeric, not text)", v("2.10.0") > v("2.9.0"))
        check("semver: 2.2.10 > 2.2.9", v("2.2.10") > v("2.2.9"))
        check("semver: v-prefix and two fields: v2.3 == 2.3.0", v("v2.3") == v("2.3.0"))
        check("semver: pre-release < its release", v("2.3.0-beta.2") < v("2.3.0") && !(v("2.3.0") < v("2.3.0-beta.2")))
        check("semver: beta.2 < beta.11 (numeric identifiers)", v("2.3.0-beta.2") < v("2.3.0-beta.11"))
        check("semver: alpha < beta", v("1.0.0-alpha") < v("1.0.0-beta"))
        check("semver: numeric identifier < alphanumeric", v("1.0.0-1") < v("1.0.0-alpha"))
        check("semver: shorter pre-release set ranks lower", v("1.0.0-alpha") < v("1.0.0-alpha.1"))
        check("semver: build metadata ignored", v("2.3.0+45") == v("2.3.0"))
        check("semver: 2.2.3 isn't newer than 2.2.3", !(v("2.2.3") > v("2.2.3")))
        check("semver: rejects junk", ["", "2", "2.x", "2.3.0.1", "-1.0", "2..1", "2.3.0-", "2.3.0-b@d", "１.2.3"].allSatisfy { SemVer($0) == nil })
    }

    static let testKey = Curve25519.Signing.PrivateKey()
    static func manifest(_ version: String, build: Int, data: Data, key: Curve25519.Signing.PrivateKey = testKey) -> UpdateManifest {
        try! UpdateManifest(version: version, build: build, sha256: sha(data), size: Int64(data.count), tier: "local",
                            asset: "Cocaine-\(version).dmg").signed(with: key)
    }

    private static func manifests() {
        let pub = testKey.publicKey
        let dmg = Data("pretend dmg".utf8)
        let good = manifest("2.3.0", build: 45, data: dmg)
        func verdict(_ m: UpdateManifest, key: Curve25519.Signing.PublicKey? = pub, release: ReleaseInfo? = nil) -> Result<SemVer, UpdateRejection> {
            UpdateVerifier.check(m, key: key, currentVersion: "2.2.3", currentBuild: 44, release: release)
        }
        check("signature: a good manifest verifies", (try? verdict(good).get()) == SemVer("2.3.0"))
        var t = good; t.sha256 = sha(Data("evil".utf8))
        check("signature: tampered SHA-256 is rejected", verdict(t) == .failure(.badSignature))
        t = good; t.version = "9.9.9"; t.asset = "Cocaine-9.9.9.dmg"
        check("signature: tampered version is rejected", verdict(t) == .failure(.badSignature))
        t = good; t.build = 99
        check("signature: tampered build is rejected", verdict(t) == .failure(.badSignature))
        t = good; t.size += 1
        check("signature: tampered size is rejected", verdict(t) == .failure(.badSignature))
        check("signature: another key's signature is rejected", verdict(manifest("2.3.0", build: 45, data: dmg, key: .init())) == .failure(.badSignature))
        t = good; t.signature = "AAAA"
        check("signature: garbage signature is rejected", verdict(t) == .failure(.badSignature))
        check("signature: no embedded key → nothing verifies", verdict(good, key: nil) == .failure(.noKey))
        if case .failure(.notNewer) = verdict(manifest("2.2.0", build: 40, data: dmg)) { check("replay: an older, validly signed release is refused", true) }
        else { check("replay: an older, validly signed release is refused", false) }
        if case .failure(.notNewer) = verdict(manifest("2.2.0", build: 99, data: dmg)) { check("replay: an older version is refused even with a higher build number", true) }
        else { check("replay: an older version is refused even with a higher build number", false) }
        if case .failure(.notNewer) = verdict(manifest("2.2.3", build: 44, data: dmg)) { check("replay: the running release itself is refused", true) }
        else { check("replay: the running release itself is refused", false) }
        if case .failure(.notNewer) = verdict(manifest("2.3.0", build: 44, data: dmg)) { check("replay: a newer version with an old build number is refused", true) }
        else { check("replay: a newer version with an old build number is refused", false) }
        let base = UpdateSource.downloadPrefix + "v2.4.0/"
        let rel24 = ReleaseInfo(tag: "v2.4.0", version: SemVer("2.4.0")!, dmg: ReleaseAsset(name: "Cocaine-2.4.0.dmg", size: 11, url: URL(string: base + "Cocaine-2.4.0.dmg")!),
                                manifest: ReleaseAsset(name: "Cocaine-2.4.0.dmg.manifest.json", size: 300, url: URL(string: base + "m")!))
        if case .failure(.mismatch) = verdict(good, release: rel24) { check("replay: 2.3.0's manifest attached to the 2.4.0 release is refused", true) }
        else { check("replay: 2.3.0's manifest attached to the 2.4.0 release is refused", false) }
        let m24 = manifest("2.4.0", build: 46, data: dmg)
        let rel24big = ReleaseInfo(tag: rel24.tag, version: rel24.version, dmg: ReleaseAsset(name: rel24.dmg.name, size: 999, url: rel24.dmg.url), manifest: rel24.manifest)
        if case .failure(.mismatch) = verdict(m24, release: rel24big) { check("signature: DMG asset size different from the signed size is refused", true) }
        else { check("signature: DMG asset size different from the signed size is refused", false) }
        check("signature: matching release passes", (try? verdict(m24, release: rel24).get()) == SemVer("2.4.0"))
        let huge = try! UpdateManifest(version: "2.3.0", build: 45, sha256: sha(dmg), size: UpdateManifest.maxDMGSize + 1, tier: "local", asset: "Cocaine-2.3.0.dmg").signed(with: testKey)
        if case .failure(.malformed) = verdict(huge) { check("size cap: a signed size over 300 MB is refused", true) } else { check("size cap: a signed size over 300 MB is refused", false) }
        check("manifest: JSON round trip", UpdateManifest.decode(try! good.encoded()) == good)
        check("manifest: oversized file isn't parsed", UpdateManifest.decode(Data(repeating: 0x20, count: UpdateManifest.maxManifestSize + 1)) == nil)
    }

    static func releaseJSON(tag: String, prerelease: Bool = false, prefix: String = UpdateSource.downloadPrefix, withManifest: Bool = true, dmgSize: Int = 1000) -> Data {
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        var assets: [[String: Any]] = [["name": "Cocaine-\(v).dmg", "size": dmgSize, "browser_download_url": "\(prefix)\(tag)/Cocaine-\(v).dmg"]]
        if withManifest { assets.append(["name": "Cocaine-\(v).dmg.manifest.json", "size": 400, "browser_download_url": "\(prefix)\(tag)/Cocaine-\(v).dmg.manifest.json"]) }
        return try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": false, "prerelease": prerelease, "assets": assets])
    }

    private static func releases() {
        let ok = UpdateSource.parse(releaseJSON(tag: "v2.10.0"))
        check("release: parses tag, DMG and manifest assets", (try? ok.get())?.version == SemVer("2.10.0") && (try? ok.get())?.manifest.name == "Cocaine-2.10.0.dmg.manifest.json")
        if case .failure = UpdateSource.parse(releaseJSON(tag: "v2.4.0", prefix: "https://evil.example/Mattiakart/cocaine/releases/download/")) {
            check("release: assets outside github.com/Mattiakart/cocaine are ignored", true)
        } else { check("release: assets outside github.com/Mattiakart/cocaine are ignored", false) }
        if case .failure = UpdateSource.parse(releaseJSON(tag: "v2.4.0", prerelease: true)) { check("release: pre-releases are not offered", true) }
        else { check("release: pre-releases are not offered", false) }
        if case .failure = UpdateSource.parse(releaseJSON(tag: "v2.4.0", withManifest: false)) { check("release: no signed manifest → not offered", true) }
        else { check("release: no signed manifest → not offered", false) }
        if case .failure = UpdateSource.parse(Data("{nope".utf8)) { check("release: malformed JSON is rejected", true) } else { check("release: malformed JSON is rejected", false) }
        check("release: API URL is pinned to the repository over https",
              UpdateSource.latestAPI.absoluteString == "https://api.github.com/repos/Mattiakart/cocaine/releases/latest")
    }

    private static func policyAndSchedule() {
        let p = DownloadPolicy.github
        check("policy: https GitHub hosts allowed", p.allowsHost(URL(string: "https://github.com/x")!) && p.allowsHost(URL(string: "https://objects.githubusercontent.com/x")!)
              && p.allowsHost(URL(string: "https://release-assets.githubusercontent.com/x")!))
        check("policy: plain http, other hosts and look-alikes refused",
              !p.allowsHost(URL(string: "http://github.com/x")!) && !p.allowsHost(URL(string: "https://evil.example/x")!)
              && !p.allowsHost(URL(string: "https://github.com.evil.example/x")!) && !p.allowsHost(URL(string: "https://evilgithubusercontent.com/x")!))
        let now = Date()
        check("schedule: first check is due", UpdateSchedule.due(enabled: true, lastCheck: nil, now: now))
        check("schedule: at most once a day", !UpdateSchedule.due(enabled: true, lastCheck: now.addingTimeInterval(-23 * 3600), now: now)
              && UpdateSchedule.due(enabled: true, lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
        check("schedule: switched off → never", !UpdateSchedule.due(enabled: false, lastCheck: nil, now: now))
        check("schedule: clock set back → due", UpdateSchedule.due(enabled: true, lastCheck: now.addingTimeInterval(86400 * 3), now: now))
        check("network: offline is reported, not retried", classifyNetworkError(URLError(.notConnectedToInternet)) == .offline)
        check("network: a dropped connection is retried", classifyNetworkError(URLError(.networkConnectionLost)) == nil
              && classifyNetworkError(URLError(.timedOut)) == nil)
        check("network: TLS failures are refused, not retried", classifyNetworkError(URLError(.serverCertificateUntrusted)) == .refusedURL)
        check("range: Content-Range parsing", ResumableDownload.contentRange("bytes 100-199/1000").map { $0.start == 100 && $0.total == 1000 } == true
              && ResumableDownload.contentRange("bytes */1000") == nil && ResumableDownload.contentRange(nil) == nil)
        check("disk full: ENOSPC is recognised", UpdateFiles.isDiskFull(POSIXError(.ENOSPC)) && UpdateFiles.isDiskFull(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
              && !UpdateFiles.isDiskFull(POSIXError(.EACCES)))
    }

    private static func homebrew() {
        let root = tempDir("brew"), fm = FileManager.default
        let apps = root.appendingPathComponent("Applications"); try? fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let app = apps.appendingPathComponent("Cocaine.app"); try? fm.createDirectory(at: app, withIntermediateDirectories: true)
        let other = root.appendingPathComponent("Other/Cocaine.app"); try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        let room = root.appendingPathComponent("Caskroom/cocaine")
        try? fm.createDirectory(at: room.appendingPathComponent("2.2.3"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: room.appendingPathComponent(".metadata"), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: room.appendingPathComponent("2.2.3/Cocaine.app"), withDestinationURL: app)
        check("homebrew: the cask's app is detected (Caskroom symlink)", Homebrew.manages(bundle: app, caskrooms: [room.path]))
        check("homebrew: another copy on the same Mac isn't", !Homebrew.manages(bundle: other, caskrooms: [room.path]))
        check("homebrew: no Caskroom → not Homebrew", !Homebrew.manages(bundle: app, caskrooms: [root.appendingPathComponent("none").path]))
        check("eligibility: Homebrew copies defer to brew", UpdateEligibility.of(bundle: app, tier: .local, hasKey: true, caskrooms: [room.path]) == .homebrew)
        check("eligibility: no key → never installs", UpdateEligibility.of(bundle: other, tier: .local, hasKey: false, caskrooms: []) == .noKey)
        check("eligibility: ad hoc builds can't update themselves", UpdateEligibility.of(bundle: other, tier: .adhoc, hasKey: true, caskrooms: []) == .unsignedBuild(.adhoc))
        check("eligibility: translocated copy must be moved first",
              UpdateEligibility.of(bundle: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Cocaine.app"), tier: .local, hasKey: true, caskrooms: []) == .notInstalled)
        check("eligibility: a writable, signed, installed copy may update", UpdateEligibility.of(bundle: other, tier: .local, hasKey: true, caskrooms: []) == .ok)
        try? fm.removeItem(at: root)
    }

    /// Runs one download to the end (or 20 s).
    private static func fetch(_ cfg: ResumableDownload.Config, cancelAfter: TimeInterval? = nil) -> (Result<URL, DownloadFailure>?, ResumableDownload) {
        let d = ResumableDownload(cfg)
        let sem = DispatchSemaphore(value: 0)
        var out: Result<URL, DownloadFailure>?
        d.start { out = $0; sem.signal() }
        if let c = cancelAfter { DispatchQueue.global().asyncAfter(deadline: .now() + c) { d.cancel() } }
        _ = sem.wait(timeout: .now() + 20)
        return (out, d)
    }

    private static func downloads() {
        var payload = Data(count: 600_000)
        for i in 0..<payload.count { payload[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 7) }
        let digest = sha(payload)
        var corrupt = payload; corrupt[1234] ^= 0xff
        let server = TestHTTPServer { path, n in
            switch path {
            case "/ok", "/resume": return .serve(payload)
            case "/cut": return n == 1 ? .cut(payload, after: 200_000) : .serve(payload)
            case "/cutalways": return .cut(payload, after: 150_000)
            case "/norange": return .ignoreRange(payload)
            case "/big": return .serve(payload + Data(count: 1000))
            case "/biglen": return .noLength(payload + Data(count: 1000))
            case "/badrange": return .badRange(payload)
            case "/corrupt": return .serve(corrupt)
            case "/flaky": return n == 1 ? .status(503) : .serve(payload)
            case "/404": return .status(404)
            case "/away": return .redirect("http://example.com/Cocaine.dmg")
            default: return .status(404)
            }
        }
        guard let server else { check("download: local server starts", false); return }
        defer { server.stop() }
        func cfg(_ path: String, dir: URL, attempts: Int = 4) -> ResumableDownload.Config {
            var c = ResumableDownload.Config(url: server.url(path), expectedSize: Int64(payload.count), sha256: digest)
            c.directory = dir; c.policy = .loopback; c.maxAttempts = attempts; c.backoff = { _ in 0.05 }; c.requestTimeout = 5
            return c
        }
        func ok(_ r: Result<URL, DownloadFailure>?) -> Bool {
            if case .success(let u)? = r { return (try? Data(contentsOf: u)) == payload } else { return false }
        }
        func req(_ path: String) -> [String?] { server.log.filter { $0.path == path }.map(\.range) }
        let fm = FileManager.default

        var dir = tempDir("dl")
        var (r, d) = fetch(cfg("/ok", dir: dir))
        check("download: whole file, SHA-256 verified", ok(r), "\(String(describing: r)) \(req("/ok"))")
        let perms = (try? fm.attributesOfItem(atPath: dir.path))?[.posixPermissions] as? NSNumber
        check("download: private folder (0700)", perms?.intValue == 0o700)
        (r, _) = fetch(cfg("/ok", dir: dir))
        check("download: an already verified file isn't downloaded again", ok(r) && req("/ok").count == 1)

        dir = tempDir("dl")
        (r, d) = fetch(cfg("/cut", dir: dir))
        check("download: interrupted transfer resumes with Range from where it stopped", ok(r) && req("/cut") == [nil, "bytes=200000-"], "\(req("/cut"))")

        dir = tempDir("dl")
        (r, d) = fetch(cfg("/cutalways", dir: dir, attempts: 1))
        let partial = d.partialURL
        let partSize = ((try? fm.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber)?.intValue ?? -1
        if case .failure(.network)? = r { check("download: gives up after the retries, keeping the partial file", partSize == 150_000, "partial \(partSize)") }
        else { check("download: gives up after the retries, keeping the partial file", false, "\(String(describing: r))") }
        (r, _) = fetch(cfg("/resume", dir: dir))
        check("download: a new session (app restarted) resumes the partial file", ok(r) && req("/resume") == ["bytes=150000-"], "\(req("/resume"))")

        dir = tempDir("dl")
        try? UpdateFiles.makePrivate(dir)
        try? payload.prefix(100_000).write(to: dir.appendingPathComponent("\(digest).dmg.partial"))
        (r, _) = fetch(cfg("/norange", dir: dir))
        check("download: a server that ignores Range restarts the file cleanly", ok(r) && req("/norange") == ["bytes=100000-"])

        dir = tempDir("dl")
        try? UpdateFiles.makePrivate(dir)
        try? payload.prefix(100_000).write(to: dir.appendingPathComponent("\(digest).dmg.partial"))
        (r, _) = fetch(cfg("/badrange", dir: dir))
        check("download: a wrong Content-Range throws the partial away and starts over", ok(r) && req("/badrange") == ["bytes=100000-", nil], "\(req("/badrange"))")

        dir = tempDir("dl")
        try? UpdateFiles.makePrivate(dir)
        try? Data(count: payload.count + 10).write(to: dir.appendingPathComponent("\(digest).dmg.partial"))
        (r, _) = fetch(cfg("/ok", dir: dir))
        check("download: a partial file larger than the signed size is discarded", ok(r))

        dir = tempDir("dl")
        (r, d) = fetch(cfg("/big", dir: dir))
        let bigGone = !fm.fileExists(atPath: d.partialURL.path)
        if case .failure(let e)? = r, e == .sizeMismatch || e == .tooLarge { check("download: more bytes than signed → stopped, file deleted", bigGone) }
        else { check("download: more bytes than signed → stopped, file deleted", false, "\(String(describing: r))") }

        dir = tempDir("dl")
        (r, d) = fetch(cfg("/biglen", dir: dir))
        check("download: no Content-Length and more bytes than signed → stopped at the signed size, file deleted",
              r.map { $0 == .failure(.tooLarge) } == true && !fm.fileExists(atPath: d.partialURL.path), "\(String(describing: r))")

        dir = tempDir("dl")
        (r, d) = fetch(cfg("/corrupt", dir: dir))
        check("download: SHA-256 mismatch → one fresh retry, then refused and deleted",
              r.map { if case .failure(.hashMismatch) = $0 { return true }; return false } == true && req("/corrupt").count == 2
              && !fm.fileExists(atPath: d.partialURL.path) && !fm.fileExists(atPath: d.finalURL.path))

        dir = tempDir("dl")
        (r, _) = fetch(cfg("/flaky", dir: dir))
        check("download: a 503 is retried with backoff", ok(r) && req("/flaky").count == 2)

        dir = tempDir("dl")
        (r, _) = fetch(cfg("/404", dir: dir))
        check("download: a 404 fails at once", r.map { $0 == .failure(.http(404)) } == true && req("/404").count == 1)

        dir = tempDir("dl")
        var c = cfg("/ok", dir: dir)
        c.writeHook = { off, _ in if off >= 100_000 { throw POSIXError(.ENOSPC) } }
        (r, d) = fetch(c)
        check("download: disk full while writing → reported, partial file deleted",
              r.map { $0 == .failure(.diskFull) } == true && !fm.fileExists(atPath: d.partialURL.path))

        dir = tempDir("dl")
        let before = server.log.count
        c = cfg("/ok", dir: dir); c.freeSpace = { _ in 1024 }
        (r, _) = fetch(c)
        check("download: not enough free space → refused before downloading", r.map { $0 == .failure(.diskFull) } == true && server.log.count == before)

        dir = tempDir("dl")
        (r, _) = fetch(cfg("/away", dir: dir))
        check("download: a redirect away from the allowed hosts is refused", r.map { $0 == .failure(.refusedURL) } == true)

        dir = tempDir("dl")
        c = cfg("/ok", dir: dir); c.url = URL(string: "https://evil.example/Cocaine.dmg")!
        (r, _) = fetch(c)
        check("download: a URL outside the policy isn't even requested", r.map { $0 == .failure(.refusedURL) } == true)

        dir = tempDir("dl")
        c = cfg("/ok", dir: dir); c.url = URL(string: "http://127.0.0.1:1/Cocaine.dmg")!; c.maxAttempts = 2
        (r, _) = fetch(c)
        if case .failure(.network)? = r { check("download: server unreachable → retried, then a network error", true) }
        else { check("download: server unreachable → retried, then a network error", false, "\(String(describing: r))") }

        dir = tempDir("dl")
        let slow = TestHTTPServer { _, _ in .cut(payload, after: 50_000) }
        if let slow {
            var s = cfg("/x", dir: dir); s.url = slow.url("/x"); s.maxAttempts = 50; s.backoff = { _ in 0.3 }
            (r, _) = fetch(s, cancelAfter: 0.5)
            check("download: Cancel stops it, keeping what was downloaded", r.map { $0 == .failure(.cancelled) } == true)
            slow.stop()
        }
        try? fm.removeItem(at: dir)
    }

    private static func installs() {
        let fm = FileManager.default
        let root = tempDir("install")
        defer { try? fm.removeItem(at: root) }
        let installed = root.appendingPathComponent("Applications/Cocaine.app")
        func reset(_ m: UpdateManifest? = nil) -> Installer.Staged {
            try? fm.removeItem(at: root.appendingPathComponent("Applications"))
            TestBundles.make(at: installed, version: "2.2.3", build: 44, marker: "old")
            let work = root.appendingPathComponent("Applications/\(Installer.workPrefix)t")
            let app = work.appendingPathComponent("Cocaine.app")
            TestBundles.make(at: app, version: m?.version ?? "2.3.0", build: m?.build ?? 45, marker: "new")
            return Installer.Staged(app: app, work: work)
        }
        var s = reset()
        var r = Installer.swap(installed: installed, staged: s.app)
        check("swap: atomic exchange puts the new app in place, the old one at the rollback path",
              TestBundles.marker(installed) == "new" && (try? r.get()).flatMap(TestBundles.marker) == "old")

        s = reset()
        var ops = Installer.FileOps(); ops.swap = { _, _ in ENOTSUP }
        r = Installer.swap(installed: installed, staged: s.app, ops: ops)
        check("swap: on a volume without atomic swap, two renames still end complete",
              TestBundles.marker(installed) == "new" && (try? r.get()).flatMap(TestBundles.marker) == "old")

        s = reset()
        var calls = 0
        ops.rename = { a, b in calls += 1; return calls == 2 ? EIO : (Darwin.rename(a, b) == 0 ? 0 : errno) }
        r = Installer.swap(installed: installed, staged: s.app, ops: ops)
        check("swap: failure half-way is undone (the installed app is untouched and complete)",
              (try? r.get()) == nil && TestBundles.marker(installed) == "old" && fm.fileExists(atPath: installed.appendingPathComponent("Contents/MacOS/Cocaine").path))

        // Signatures: ad hoc copies are each other's strangers; same identity is required.
        let m = manifest("2.3.0", build: 45, data: Data("x".utf8))
        s = reset(m)
        TestBundles.signAdhoc(installed); TestBundles.signAdhoc(s.app)
        let oldReq = CodeIdentity.requirement(of: installed)!
        if case .failure(.signature) = Installer.checkApp(s.app, manifest: m, requirement: oldReq) {
            check("identity: an ad hoc build never satisfies another build's requirement (refused)", true)
        } else { check("identity: an ad hoc build never satisfies another build's requirement (refused)", false) }
        let newReq = CodeIdentity.requirement(of: s.app)!
        check("identity: the staged app passes against a requirement it does satisfy", (try? Installer.checkApp(s.app, manifest: m, requirement: newReq).get()) != nil)
        if case .failure(.wrongApp) = Installer.checkApp(s.app, manifest: manifest("2.3.1", build: 45, data: Data()), requirement: newReq) {
            check("identity: version different from the signed manifest is refused", true)
        } else { check("identity: version different from the signed manifest is refused", false) }
        try? Data("tampered".utf8).write(to: s.app.appendingPathComponent("Contents/Resources/marker"))
        if case .failure(.signature) = Installer.checkApp(s.app, manifest: m, requirement: newReq) { check("identity: a modified bundle fails its signature", true) }
        else { check("identity: a modified bundle fails its signature", false) }

        // Install with a check that fails after the swap: rolled back.
        s = reset(m)
        TestBundles.signAdhoc(installed); TestBundles.signAdhoc(s.app)
        let rr = Installer.install(s, at: installed, manifest: m, requirement: CodeIdentity.requirement(of: installed)!)
        check("install: failed check after the swap rolls back to the previous app",
              (try? rr.get()) == nil && TestBundles.marker(installed) == "old" && !fm.fileExists(atPath: s.work.path))

        // The full pipeline from a real disk image (ad hoc, so the requirement is the new app's own).
        s = reset(m)
        TestBundles.signAdhoc(installed); TestBundles.signAdhoc(s.app)
        let src = root.appendingPathComponent("dmgsrc"); try? fm.createDirectory(at: src, withIntermediateDirectories: true)
        try? fm.moveItem(at: s.app, to: src.appendingPathComponent("Cocaine.app"))
        try? fm.createSymbolicLink(atPath: src.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        let dmg = root.appendingPathComponent("Cocaine-2.3.0.dmg")
        let made = runTool("/usr/bin/hdiutil", ["create", "-quiet", "-fs", "HFS+", "-volname", "Cocaine test", "-srcfolder", src.path, "-format", "UDZO", dmg.path], timeout: 120) == 0
        let req = CodeIdentity.requirement(of: src.appendingPathComponent("Cocaine.app"))!
        try? fm.removeItem(at: s.work)
        if made {
            let staged = Installer.stage(dmg: dmg, manifest: m, installed: installed, requirement: req)
            check("dmg: mounted read-only, copied and verified next to the installed app",
                  (try? staged.get()).map { TestBundles.marker($0.app) == "new" && $0.app.deletingLastPathComponent().deletingLastPathComponent() == installed.deletingLastPathComponent() } == true,
                  "\(staged)")
            if let st = try? staged.get() {
                let done = Installer.install(st, at: installed, manifest: m, requirement: req)
                check("dmg: installed, previous app kept for rollback", TestBundles.marker(installed) == "new" && (try? done.get()).flatMap(TestBundles.marker) == "old")
                Installer.cleanupLeftovers(near: installed)
                let left = (try? fm.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)) ?? []
                check("dmg: next launch clears the rollback copy and staging folders", left == ["Cocaine.app"], "\(left)")
            }
            var mounted = ""
            runTool("/sbin/mount", [], output: &mounted)
            check("dmg: the image is detached afterwards", !mounted.contains(UpdateFiles.directory.path + "/mnt-"))
            let stranger = root.appendingPathComponent("stranger/Cocaine.app")
            TestBundles.make(at: stranger, version: "2.2.3", build: 44, marker: "other"); TestBundles.signAdhoc(stranger)
            let wrong = Installer.stage(dmg: dmg, manifest: m, installed: installed, requirement: CodeIdentity.requirement(of: stranger)!)
            if case .failure(.signature) = wrong { check("dmg: an app signed by another identity is refused, nothing left behind",
                                                         ((try? fm.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)) ?? []) == ["Cocaine.app"]) }
            else { check("dmg: an app signed by another identity is refused, nothing left behind", false, "\(wrong)") }
        } else { check("dmg: hdiutil create works here", false) }

        // Same local identity: a newer build satisfies the old one's requirement (what keeps updates possible).
        if let id = TestBundles.localIdentity() {
            s = reset(m)
            let signed = TestBundles.signLocal(installed, id) && TestBundles.signLocal(s.app, id)
            let r1 = Installer.checkApp(s.app, manifest: m, requirement: CodeIdentity.requirement(of: installed)!)
            check("identity: two builds signed with the local identity satisfy each other's requirement", signed && (try? r1.get()) != nil, "\(r1)")
        } else { skip("identity: two builds signed with the local identity satisfy each other's requirement", inCI ? "CI" : "no local signing identity on this Mac") }
    }

    private static func relauncher() {
        let fm = FileManager.default
        let root = tempDir("relaunch")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Cocaine.app"), backup = root.appendingPathComponent("old/Cocaine.app")
        TestBundles.make(at: app, version: "2.3.0", build: 45, marker: "new")
        TestBundles.make(at: backup, version: "2.2.3", build: 44, marker: "old")
        let log = root.appendingPathComponent("opened")
        let opener = root.appendingPathComponent("open.sh")
        // Fails for the new app (its marker says "new"), works for the old one: the rollback path.
        try? "#!/bin/sh\nm=$(cat \"$1/Contents/Resources/marker\")\necho \"$m\" >> \(log.path)\n[ \"$m\" = \"$FAIL\" ] && exit 1\nexit 0\n".write(to: opener, atomically: true, encoding: .utf8)
        chmod(opener.path, 0o755)
        let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["1"]
        try? sleeper.run()
        setenv("FAIL", "none", 1)
        let started = Date()
        let h = Installer.launchRelauncher(pid: sleeper.processIdentifier, app: app, backup: backup, opener: opener.path)
        h?.waitUntilExit()
        let opened = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        check("relaunch: waits for the old process to quit, then opens the new app", opened == "new\n" && Date().timeIntervalSince(started) >= 0.8, opened)
        try? fm.removeItem(at: log)
        setenv("FAIL", "new", 1)
        let h2 = Installer.launchRelauncher(pid: 999_999, app: app, backup: backup, opener: opener.path)
        h2?.waitUntilExit()
        let opened2 = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        check("relaunch: if the new app can't open, the previous one is put back and opened",
              opened2 == "new\nold\n" && TestBundles.marker(app) == "old" && h2?.terminationStatus == 4, opened2)
        unsetenv("FAIL")
    }
}

// MARK: - Signing tier tests

enum SignatureTests {
    static func run() -> Int32 {
        typealias F = SigningTier.Facts
        func c(_ f: F) -> SigningTier { SigningTier.classify(f) }
        check("tier: unsigned", c(F()) == .unsigned)
        check("tier: a signature that doesn't validate counts as unsigned", c(F(signed: true, valid: false, certificateCount: 1)) == .unsigned)
        check("tier: ad hoc", c(F(signed: true, valid: true, adhoc: true)) == .adhoc)
        check("tier: local self-signed", c(F(signed: true, valid: true, leafCommonName: SigningTier.localCommonName, certificateCount: 1)) == .local)
        check("tier: a look-alike name with a chain isn't local", c(F(signed: true, valid: true, leafCommonName: SigningTier.localCommonName, certificateCount: 3)) == .otherCertificate)
        check("tier: Developer ID", c(F(signed: true, valid: true, leafCommonName: "Developer ID Application: X (TEAM)", certificateCount: 3, developerID: true)) == .developerID)
        check("tier: Developer ID with stapled ticket = notarized",
              c(F(signed: true, valid: true, certificateCount: 3, developerID: true, stapledTicket: true)) == .notarized)
        check("tier: a ticket file without Developer ID isn't notarized", c(F(signed: true, valid: true, leafCommonName: SigningTier.localCommonName, certificateCount: 1, stapledTicket: true)) == .local)
        check("tier: every tier has a panel line", SigningTier.allCases.allSatisfy { !$0.panelLine.isEmpty })

        let root = tempDir("tier")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Cocaine.app")
        TestBundles.make(at: app, version: "1.0", build: 1, marker: "a")
        runTool("/usr/bin/codesign", ["--remove-signature", app.appendingPathComponent("Contents/MacOS/Cocaine").path])
        check("tier (real): an unsigned bundle reads as unsigned", SigningTier.classify(SigningTier.facts(of: app)) == .unsigned)
        TestBundles.signAdhoc(app)
        let adhoc = SigningTier.facts(of: app)
        check("tier (real): ad hoc signature reads as ad hoc", SigningTier.classify(adhoc) == .adhoc && adhoc.designatedRequirement?.contains("cdhash") == true,
              "\(adhoc)")
        try? Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Resources/marker"))
        check("tier (real): a modified bundle reads as unsigned (invalid)", SigningTier.classify(SigningTier.facts(of: app)) == .unsigned)
        if let id = TestBundles.localIdentity() {
            TestBundles.signLocal(app, id)
            let f = SigningTier.facts(of: app)
            check("tier (real): the local identity reads as local", SigningTier.classify(f) == .local
                  && f.designatedRequirement?.contains("certificate leaf = H\"") == true, "\(f)")
        } else { skip("tier (real): the local identity reads as local", inCI ? "CI" : "no local signing identity on this Mac") }
        let me = SigningTier.facts(of: Bundle.main.bundleURL)
        print("INFO  this build: tier=\(SigningTier.classify(me).rawValue) leaf=\(me.leafCommonName ?? "-") runtime=\(me.hardenedRuntime)")
        print(failures == 0 ? "signature tests: all passed" : "signature tests: \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
