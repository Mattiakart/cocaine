// Cloud sharing: uploading shelf files to a service the user configured and getting a link back. This file holds what every
// provider shares: the provider protocol and its settings (non-secret ones in Application Support, secrets in the Keychain,
// service local.cocaine.share, this device only), the rules (TLS only, no redirects for authenticated requests, size caps,
// file names made safe for object keys, Content-Type from UTType, a global switch), a small HTTP client with progress and
// Cancel, the upload history and the engine that zips several files and hands one file to a provider.
// The providers: ShareProvidersS3.swift, ShareProvidersWebDAV.swift (WebDAV, Nextcloud/ownCloud), ShareProvidersSFTP.swift,
// ShareUploader.swift (the user's own command). The UI and the shelf's hook: CloudShare*.swift. Tests: --cloud-test.
// Nothing here logs: no secret, no signed URL is ever written to a log or an error text.

import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

// MARK: - Kinds and settings

enum ShareKind: String, Codable, CaseIterable {
    case s3, webdav, nextcloud, sftp, uploader

    var title: String {
        switch self {
        case .s3: return L("S3-compatible storage")
        case .webdav: return L("WebDAV")
        case .nextcloud: return L("Nextcloud or ownCloud")
        case .sftp: return L("SFTP (your server)")
        case .uploader: return L("Your own upload command")
        }
    }

    var symbol: String {
        switch self {
        case .s3: return "externaldrive.connected.to.line.below"
        case .webdav: return "server.rack"
        case .nextcloud: return "cloud"
        case .sftp: return "terminal"
        case .uploader: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The largest upload each kind takes (one file, after zipping).
    var maxBytes: Int64 {
        switch self {
        case .s3: return 50 << 30            // multipart above 100 MB, at most 10 000 parts
        case .webdav, .nextcloud: return 4 << 30
        case .sftp: return 50 << 30
        case .uploader: return 2 << 30
        }
    }

    /// Whether a link can be taken back (the file deleted on the service).
    var canRevoke: Bool { self != .uploader }
}

/// One configured provider. Non-secret settings only (the Keychain holds the rest). `settings` keys are per kind (see the
/// provider files); unknown keys are kept, missing ones read as empty.
struct ShareProviderConfig: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString.lowercased()
    var kind: ShareKind
    var title: String
    var enabled = true
    /// Ask before every upload (on for every new provider).
    var confirmEach = true
    var settings: [String: String] = [:]
    /// The user's own command: the fingerprint of the command line they allowed (nil: ask first).
    var approved: String? = nil

    init(kind: ShareKind, title: String, settings: [String: String] = [:]) {
        self.kind = kind; self.title = title; self.settings = settings
    }

    enum CodingKeys: String, CodingKey { case id, kind, title, enabled, confirmEach, settings, approved }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ShareKind.self, forKey: .kind)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil ?? UUID().uuidString.lowercased()
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil ?? kind.title
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil ?? true
        confirmEach = (try? c.decodeIfPresent(Bool.self, forKey: .confirmEach)) ?? nil ?? true
        settings = (try? c.decodeIfPresent([String: String].self, forKey: .settings)) ?? nil ?? [:]
        approved = (try? c.decodeIfPresent(String.self, forKey: .approved)) ?? nil
    }

    subscript(_ key: String) -> String {
        get { settings[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { settings[key] = newValue }
    }

    /// The host shown before an upload ("where do my files go").
    var host: String {
        switch kind {
        case .s3: return URL(string: self["endpoint"])?.host ?? self["endpoint"]
        case .webdav: return URL(string: self["url"])?.host ?? ""
        case .nextcloud: return URL(string: self["server"])?.host ?? ""
        case .sftp: return self["host"]
        case .uploader: return ShareUploader.host(of: self["template"]) ?? L("your command")
        }
    }
}

/// Everything the sharing settings keep (Application Support/Cocaine/share/providers.json, 0600).
struct ShareSettings: Codable, Equatable {
    static let maxProviders = 16
    var v = 1
    /// The global switch: off, no upload starts and the shelf offers none.
    var on = true
    var providers: [ShareProviderConfig] = []

    enum CodingKeys: String, CodingKey { case v, on, providers }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? nil ?? 1
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? nil ?? true
        providers = Array(((try? c.decodeIfPresent([ShareProviderConfig].self, forKey: .providers)) ?? nil ?? []).prefix(Self.maxProviders))
    }
}

// MARK: - Errors

enum ShareError: Error, LocalizedError, Equatable {
    case off, noProvider, disabled
    case config(String)
    case insecure(String)          // the host, never the URL
    case redirected
    case unauthorized, forbidden, notFound, conflict
    case tooBig(Int64)
    case tooMany(Int)
    case http(Int)
    case server(Int)
    case timeout
    case offline
    case cancelled
    case badResponse(String)
    case tool(String)
    case notApproved

    var errorDescription: String? {
        switch self {
        case .off: return L("Cloud sharing is off")
        case .noProvider: return L("That sharing service isn't set up any more")
        case .disabled: return L("That sharing service is turned off")
        case .config(let s): return s
        case .insecure(let h): return String(format: L("Only secure (https) addresses are used: %@"), h)
        case .redirected: return L("The server sent the upload somewhere else; Cocaine doesn't follow that with your credentials")
        case .unauthorized: return L("The server refused the credentials (401): check the key or password")
        case .forbidden: return L("Not allowed (403): check the key's permissions, the bucket or the folder")
        case .notFound: return L("Not found (404): check the bucket, the folder or the address")
        case .conflict: return L("The folder doesn't exist on the server (409)")
        case .tooBig(let max): return String(format: L("Too big for this service (at most %@)"), ByteCountFormatter.string(fromByteCount: max, countStyle: .file))
        case .tooMany(let n): return String(format: L("At most %d files at a time"), n)
        case .http(let c): return String(format: L("The server answered with an error (%d)"), c)
        case .server(let c): return String(format: L("The server had a problem (%d): try again later"), c)
        case .timeout: return L("The server didn't answer in time")
        case .offline: return L("Can't reach the server: check the address and the connection")
        case .cancelled: return L("Cancelled")
        case .badResponse(let s): return s
        case .tool(let s): return s
        case .notApproved: return L("This upload command hasn't been allowed to run yet")
        }
    }

    /// An HTTP status turned into the error the user reads.
    static func status(_ code: Int) -> ShareError? {
        switch code {
        case 200..<300: return nil
        case 300..<400: return .redirected
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict
        case 413: return .tooBig(0)
        case 500..<600: return .server(code)
        default: return .http(code)
        }
    }

    static func from(_ e: Error) -> ShareError {
        if let s = e as? ShareError { return s }
        if let s = e as? ShelfOpsError, case .cancelled = s { return .cancelled }
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorTimedOut: return .timeout
            case NSURLErrorAppTransportSecurityRequiresSecureConnection: return .insecure("")
            case NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed: return .offline
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorSecureConnectionFailed:
                return .badResponse(L("The server's certificate isn't trusted"))
            default: break
            }
        }
        return .badResponse(L("The upload didn't work"))
    }
}

// MARK: - Rules

enum ShareRules {
    static let maxFiles = 100
    static let loopback: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// https, or http to this Mac only (tests, a local MinIO).
    static func allowed(_ u: URL?) -> Bool {
        guard let u, let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return u.user == nil && u.password == nil }
        return scheme == "http" && loopback.contains(host) && u.user == nil
    }

    /// Checks an address the user typed: nil when it can be used, else why not.
    static func problem(_ s: String, what: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return String(format: L("%@ is missing"), what) }
        guard let u = URL(string: t), u.host != nil else { return String(format: L("%@ isn't a valid address"), what) }
        if u.user != nil || u.password != nil { return L("Put the user name and password in their own fields, not in the address") }
        return allowed(u) ? nil : L("Only https addresses can be used (http only for this Mac)")
    }

    /// A file name safe for an object key, a WebDAV path and an SFTP command: letters, digits, dot, dash and underscore;
    /// the rest becomes "-"; no leading dot or dash; at most 100 characters, the extension kept.
    static func safeName(_ name: String) -> String {
        let decomposed = name.applyingTransform(.stripDiacritics, reverse: false) ?? name
        var out = ""
        var lastDash = false
        for ch in decomposed.unicodeScalars {
            let ok = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "." || ch == "_" || ch == "-"
            if ok && ch != "-" { out.unicodeScalars.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        while let f = out.first, f == "." || f == "-" { out.removeFirst() }
        while out.contains("..") { out = out.replacingOccurrences(of: "..", with: ".") }
        while let l = out.last, l == "-" || l == "." { out.removeLast() }
        if out.count > 100 {
            let ext = (out as NSString).pathExtension
            let keep = ext.isEmpty || ext.count > 10 ? "" : "." + ext
            out = String(out.prefix(100 - keep.count)) + keep
        }
        return out.isEmpty ? "file" : out
    }

    /// A random part for object keys and paths (128 bits as 32 hex characters, or shorter for display paths).
    static func random(_ chars: Int = 32) -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<chars).map { _ in "0123456789abcdef".randomElement(using: &g)! })
    }

    static func contentType(_ name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// A folder or key prefix the user typed: "/" separated parts, each made safe; empty parts dropped.
    static func safePrefix(_ s: String) -> String {
        s.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .map(safeName).joined(separator: "/")
    }
}

// MARK: - Secrets (Keychain)

/// Where the secrets live: one Keychain item per provider (a small JSON of name → value), service local.cocaine.share,
/// usable only while the Mac is unlocked, this device only, never synced.
protocol ShareSecretStore: AnyObject {
    func load(_ account: String) throws -> [String: String]
    func save(_ account: String, _ values: [String: String]) throws
    func delete(_ account: String) throws
}

final class MemorySecretStore: ShareSecretStore {
    var items: [String: [String: String]] = [:]
    func load(_ a: String) throws -> [String: String] { items[a] ?? [:] }
    func save(_ a: String, _ v: [String: String]) throws { items[a] = v }
    func delete(_ a: String) throws { items[a] = nil }
}

final class KeychainSecretStore: ShareSecretStore {
    static let service = "local.cocaine.share"
    let service: String
    let keychain: AnyObject?          // a temporary keychain file in tests; nil: the login keychain

    init(service: String = KeychainSecretStore.service, keychain: AnyObject? = nil) { self.service = service; self.keychain = keychain }

    private func query(_ account: String, search: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let keychain { q[search ? kSecMatchSearchList as String : kSecUseKeychain as String] = search ? [keychain] : keychain }
        return q
    }

    func load(_ account: String) throws -> [String: String] {
        var q = query(account, search: true)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return [:] }
        guard st == errSecSuccess, let d = out as? Data else { throw KeychainKeyStore.Failure(status: st) }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    func save(_ account: String, _ values: [String: String]) throws {
        try delete(account)
        let clean = values.filter { !$0.value.isEmpty }
        guard !clean.isEmpty else { return }
        var q = query(account, search: false)
        q[kSecValueData as String] = try JSONEncoder().encode(clean)
        q[kSecAttrLabel as String] = "Cocaine sharing"
        q[kSecAttrDescription as String] = "Credentials for a sharing service set up in Cocaine"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw KeychainKeyStore.Failure(status: st) }
    }

    func delete(_ account: String) throws {
        let st = SecItemDelete(query(account, search: true) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw KeychainKeyStore.Failure(status: st) }
    }
}

// MARK: - HTTP

/// One request at a time, off the main thread: a body from memory or streamed from a file, upload progress, Cancel, a timeout,
/// no redirects (an authenticated request is never replayed elsewhere), TLS only, the answer bounded.
final class ShareHTTP {
    struct Response {
        var status: Int
        var headers: [String: String]      // names lowercased
        var body: Data
    }
    enum Body { case none, data(Data), file(URL) }

    var timeout: TimeInterval = 60
    var maxResponse = 1 << 20
    /// Tests: every request that was sent (method, URL, headers), to check what went out.
    var record: ((URLRequest) -> Void)?

    func send(_ request: URLRequest, body: Body = .none, cancel: CancelToken? = nil, progress: ((Int64, Int64) -> Void)? = nil) throws -> Response {
        guard ShareRules.allowed(request.url) else { throw ShareError.insecure(request.url?.host ?? "") }
        if cancel?.cancelled == true { throw ShareError.cancelled }
        var req = request
        req.timeoutInterval = timeout
        req.httpShouldHandleCookies = false
        req.cachePolicy = .reloadIgnoringLocalCacheData
        record?(req)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = 24 * 3600
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        cfg.waitsForConnectivity = false
        let box = Delegate(limit: maxResponse, progress: progress)
        let session = URLSession(configuration: cfg, delegate: box, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task: URLSessionTask
        switch body {
        case .none: task = session.dataTask(with: req)
        case .data(let d): task = session.uploadTask(with: req, from: d)
        case .file(let f): task = session.uploadTask(with: req, fromFile: f)
        }
        task.resume()
        while box.done.wait(timeout: .now() + 0.1) == .timedOut {
            if cancel?.cancelled == true { task.cancel(); _ = box.done.wait(timeout: .now() + 5); throw ShareError.cancelled }
        }
        if box.tooLarge { throw ShareError.badResponse(L("The server's answer was too long")) }
        if box.redirected { throw ShareError.redirected }
        if let e = box.error { throw ShareError.from(e) }
        guard let r = box.response else { throw ShareError.badResponse(L("The server didn't answer")) }
        var h: [String: String] = [:]
        for (k, v) in r.allHeaderFields { if let k = k as? String, let v = v as? String { h[k.lowercased()] = v } }
        return Response(status: r.statusCode, headers: h, body: box.data)
    }

    /// Like `send`, and an error status becomes the error the user reads.
    func expect(_ request: URLRequest, body: Body = .none, cancel: CancelToken? = nil, progress: ((Int64, Int64) -> Void)? = nil) throws -> Response {
        let r = try send(request, body: body, cancel: cancel, progress: progress)
        if let e = ShareError.status(r.status) { throw e }
        return r
    }

    private final class Delegate: NSObject, URLSessionDataDelegate {
        let done = DispatchSemaphore(value: 0)
        let limit: Int
        let progress: ((Int64, Int64) -> Void)?
        var data = Data()
        var response: HTTPURLResponse?
        var error: Error?
        var redirected = false
        var tooLarge = false

        init(limit: Int, progress: ((Int64, Int64) -> Void)?) { self.limit = limit; self.progress = progress }

        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            redirected = true
            completionHandler(nil)                 // never followed: the 3xx itself is the answer
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didSendBodyData sent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            progress?(totalBytesSent, totalBytesExpectedToSend)
        }

        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response as? HTTPURLResponse
            if let r = self.response, (300..<400).contains(r.statusCode) { redirected = true }
            completionHandler(.allow)
        }

        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
            if data.count + d.count > limit { tooLarge = true; dataTask.cancel(); return }
            data.append(d)
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if response == nil { response = task.response as? HTTPURLResponse }
            if let error, !(tooLarge && (error as NSError).code == NSURLErrorCancelled) { self.error = error }
            done.signal()
        }
    }

    static func basic(_ user: String, _ password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }
}

// MARK: - Providers

/// What an upload hands a provider and gets back.
struct ShareContext {
    var cancel: CancelToken
    var progress: (Double) -> Void
    var http: ShareHTTP
    var secrets: [String: String]
    var now: () -> Date = Date.init
    /// Runs a program (SFTP, the user's command): the real one, or a fake in tests.
    var run: (_ path: String, _ args: [String], _ env: [String: String], _ timeout: TimeInterval, _ cancel: CancelToken) -> ShelfProc.Result = { p, a, e, t, c in
        ShelfProc.run(p, a, env: e, timeout: t, cancel: c, limit: 256 << 10)
    }
}

struct ShareUploaded: Equatable {
    var link: URL
    /// What revoke needs: the object key, the remote path.
    var ref: String
    /// A Nextcloud share's id (to delete the share before the file).
    var shareID: String? = nil
    var expires: Date? = nil
    /// Settings the provider learned (S3: the store refuses unsigned payloads), saved by the caller.
    var settingsChange: [String: String]? = nil
}

protocol ShareProvider {
    var config: ShareProviderConfig { get }
    /// Why it can't be used as set up (a missing field, an http address), or nil.
    func validate(secrets: [String: String]) -> String?
    /// Uploads one file (several were zipped before) under the name `name` (already safe).
    func upload(_ file: URL, name: String, size: Int64, ctx: ShareContext) throws -> ShareUploaded
    /// Deletes the uploaded file (and its share): the link stops working.
    func revoke(_ ref: String, shareID: String?, ctx: ShareContext) throws
}

enum ShareProviders {
    static func make(_ c: ShareProviderConfig) -> ShareProvider {
        switch c.kind {
        case .s3: return S3Provider(config: c)
        case .webdav, .nextcloud: return WebDAVProvider(config: c)
        case .sftp: return SFTPProvider(config: c)
        case .uploader: return UploaderProvider(config: c)
        }
    }
}

// MARK: - History

/// One upload as the history keeps it: where it went, the link, when it expires. No file contents.
struct ShareRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var provider: String
    var providerTitle: String
    var kind: ShareKind
    var name: String
    var size: Int64
    var date: Date
    var expires: Date?
    var link: String
    var ref: String
    var shareID: String?
    var revoked = false

    func expired(_ now: Date = Date()) -> Bool { expires.map { $0 <= now } ?? false }
}

/// The upload history (Application Support/Cocaine/share/history.json, 0600, at most 200 entries); memory only for tests and
/// renders.
final class ShareHistory: ObservableObject {
    static let max = 200
    @Published private(set) var records: [ShareRecord] = []
    let file: URL?

    init(file: URL?) {
        self.file = file
        if let file, let d = try? Data(contentsOf: file), let r = try? Self.decoder.decode([ShareRecord].self, from: d) { records = Array(r.prefix(Self.max)) }
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    func add(_ r: ShareRecord) { records.insert(r, at: 0); records = Array(records.prefix(Self.max)); save() }
    func remove(_ id: UUID) { records.removeAll { $0.id == id }; save() }
    func markRevoked(_ id: UUID) { if let i = records.firstIndex(where: { $0.id == id }) { records[i].revoked = true; save() } }
    func removeExpired(now: Date = Date()) { records.removeAll { $0.expired(now) || $0.revoked }; save() }
    func clear() { records = []; save() }
    func record(_ id: UUID) -> ShareRecord? { records.first { $0.id == id } }

    private func save() {
        guard let file, let d = try? Self.encoder.encode(records) else { return }
        SafeFile.writePrivate(d, to: file)
    }
}

// MARK: - The settings store

final class ShareStore: ObservableObject {
    @Published private(set) var settings: ShareSettings
    let file: URL?
    let secrets: ShareSecretStore

    init(file: URL?, secrets: ShareSecretStore) {
        self.file = file; self.secrets = secrets
        if let file, let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(ShareSettings.self, from: d) { settings = s }
        else { settings = ShareSettings() }
    }

    static var folder: URL {
        if let base = ProcessInfo.processInfo.environment["COCAINE_SUPPORT"], !base.isEmpty {
            return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("share", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cocaine/share", isDirectory: true)
    }

    func update(_ body: (inout ShareSettings) -> Void) {
        var s = settings
        body(&s)
        s.providers = Array(s.providers.prefix(ShareSettings.maxProviders))
        guard s != settings else { return }
        settings = s
        guard let file, let d = try? JSONEncoder().encode(s) else { return }
        SafeFile.writePrivate(d, to: file)
    }

    func provider(_ id: String) -> ShareProviderConfig? { settings.providers.first { $0.id == id } }

    func updateProvider(_ id: String, _ body: (inout ShareProviderConfig) -> Void) {
        update { s in if let i = s.providers.firstIndex(where: { $0.id == id }) { body(&s.providers[i]) } }
    }

    /// Removes a provider and its Keychain item.
    func remove(_ id: String) {
        update { $0.providers.removeAll { $0.id == id } }
        try? secrets.delete(id)
    }

    /// What the shelf lists: the enabled providers, none while sharing is off.
    var usable: [ShareProviderConfig] { settings.on ? settings.providers.filter(\.enabled) : [] }
}

// MARK: - The engine

/// Uploads files with a provider: checks the switch, the count and the size, zips several files (ditto) in a private
/// temporary folder, uploads, cleans up. Blocks (never on the main thread).
enum ShareEngine {
    struct Prepared: Equatable {
        var name: String
        var size: Int64
    }

    /// The total size of what would be uploaded (folders counted through).
    static func size(of urls: [URL]) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        for u in urls {
            if ZipTool.isFolder(u) {
                let e = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [])
                while let f = e?.nextObject() as? URL {
                    total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            } else {
                total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    static func precheck(_ urls: [URL], kind: ShareKind, on: Bool) throws {
        guard on else { throw ShareError.off }
        guard !urls.isEmpty else { throw ShareError.config(L("Nothing to upload")) }
        guard urls.count <= ShareRules.maxFiles else { throw ShareError.tooMany(ShareRules.maxFiles) }
        let s = size(of: urls)
        if s > kind.maxBytes { throw ShareError.tooBig(kind.maxBytes) }
    }

    struct Done: Equatable {
        var record: ShareRecord
        /// Settings the provider learned on the way (saved by the caller).
        var learned: [String: String]?
    }

    static func upload(_ urls: [URL], with config: ShareProviderConfig, ctx: ShareContext, on: Bool = true,
                       provider: ShareProvider? = nil) throws -> Done {
        try precheck(urls, kind: config.kind, on: on)
        guard config.enabled else { throw ShareError.disabled }
        let p = provider ?? ShareProviders.make(config)
        if let why = p.validate(secrets: ctx.secrets) { throw ShareError.config(why) }
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("cocaine-share-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        var file = urls[0]
        if urls.count > 1 || ZipTool.isFolder(file) {
            ctx.progress(0)
            file = try ZipTool.zip(urls, to: stage.appendingPathComponent(ShareRules.safeName(ZipTool.name(for: urls))), cancel: ctx.cancel)
        }
        if ctx.cancel.cancelled { throw ShareError.cancelled }
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size > config.kind.maxBytes { throw ShareError.tooBig(config.kind.maxBytes) }
        let name = ShareRules.safeName(file.lastPathComponent)
        let up = try p.upload(file, name: name, size: size, ctx: ctx)
        let r = ShareRecord(provider: config.id, providerTitle: config.title, kind: config.kind, name: file.lastPathComponent, size: size,
                            date: ctx.now(), expires: up.expires, link: up.link.absoluteString, ref: up.ref, shareID: up.shareID)
        return Done(record: r, learned: up.settingsChange)
    }

    /// Takes a link back: deletes the file (and the share) on the service.
    static func revoke(_ r: ShareRecord, with config: ShareProviderConfig, ctx: ShareContext) throws {
        guard config.kind.canRevoke else { throw ShareError.config(L("This service can't take a link back")) }
        try ShareProviders.make(config).revoke(r.ref, shareID: r.shareID, ctx: ctx)
    }

    /// A tiny file to test a connection with (uploaded, then deleted).
    static func testFile(in dir: URL) throws -> URL {
        let u = dir.appendingPathComponent("cocaine-test-\(ShareRules.random(8)).txt")
        try Data("Cocaine connection test. This file is deleted right away.\n".utf8).write(to: u)
        return u
    }
}
