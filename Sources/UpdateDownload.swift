// Downloads for the updater: a small capped fetch (the API answer, the manifest) and a resumable DMG download into a
// private folder. The DMG download keeps its partial file across interruptions and app restarts (named after the expected
// SHA-256, so parts of different releases never mix), resumes with a Range request, retries network errors with backoff,
// never writes past the signed size, checks free space first, and only hands over a file whose SHA-256 matches.

import CryptoKit
import Foundation

enum DownloadFailure: Error, Equatable {
    case offline                 // no network: try again later, nothing retried in a loop
    case network(String)         // still failing after the retries
    case http(Int)
    case refusedURL              // not a GitHub URL (or a redirect away from GitHub)
    case tooLarge                // more bytes than the signed size, or over the cap
    case sizeMismatch
    case hashMismatch            // twice: once is retried from scratch
    case diskFull
    case cancelled
    case io(String)
}

/// Where update files live: ~/Library/Caches/local.cocaine.toggle/Updates, only readable by you. COCAINE_UPDATES_DIR for tests.
enum UpdateFiles {
    static var directory: URL {
        if let d = ProcessInfo.processInfo.environment["COCAINE_UPDATES_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("local.cocaine.toggle/Updates")
    }

    static func makePrivate(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        do {
            while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }   // nil or empty = end
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func freeSpace(at url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init)
    }

    static func isDiskFull(_ e: Error) -> Bool {
        let ns = e as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(u) }
        return false
    }
}

/// Network errors that mean "not connected" (reported, not retried) versus a dropped or flaky transfer (retried).
func classifyNetworkError(_ e: Error) -> DownloadFailure? {
    guard let u = e as? URLError else { return .network((e as NSError).localizedDescription) }
    switch u.code {
    case .cancelled: return .cancelled
    case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
    case .appTransportSecurityRequiresSecureConnection, .serverCertificateUntrusted, .serverCertificateHasBadDate,
         .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
        return .refusedURL
    default: return nil                                       // nil = retryable
    }
}

/// A capped GET for small JSON (the release info, the manifest).
final class SmallFetch: NSObject, URLSessionDataDelegate {
    private let maxBytes: Int
    private let policy: DownloadPolicy
    private var data = Data()
    private var failure: DownloadFailure?
    private var done: ((Result<Data, DownloadFailure>) -> Void)?
    private var session: URLSession?

    private init(maxBytes: Int, policy: DownloadPolicy) { self.maxBytes = maxBytes; self.policy = policy }

    /// `done` runs on a background queue.
    static func get(_ url: URL, maxBytes: Int, policy: DownloadPolicy, accept: String? = nil,
                    done: @escaping (Result<Data, DownloadFailure>) -> Void) {
        guard policy.allowsHost(url) else { done(.failure(.refusedURL)); return }
        let f = SmallFetch(maxBytes: maxBytes, policy: policy)
        f.done = done
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: cfg, delegate: f, delegateQueue: q)
        f.session = s
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if let accept { r.setValue(accept, forHTTPHeaderField: "Accept") }
        r.setValue("Cocaine-Updater", forHTTPHeaderField: "User-Agent")
        s.dataTask(with: r).resume()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let u = newRequest.url, policy.allowsHost(u) { completionHandler(newRequest) } else { failure = .refusedURL; completionHandler(nil) }
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if failure == nil, code != 200 { failure = .http(code) }
        if failure == nil, response.expectedContentLength > Int64(maxBytes) { failure = .tooLarge }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
        data.append(d)
        if data.count > maxBytes { failure = .tooLarge; dataTask.cancel() }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<Data, DownloadFailure>
        if let failure { result = .failure(failure) }
        else if let error { result = .failure(classifyNetworkError(error) ?? .network(error.localizedDescription)) }
        else { result = .success(data) }
        s.finishTasksAndInvalidate()
        session = nil
        let d = done; done = nil
        d?(result)
    }
}

final class ResumableDownload: NSObject, URLSessionDataDelegate {
    struct Config {
        var url: URL
        var expectedSize: Int64
        var sha256: String
        var directory: URL = UpdateFiles.directory
        var policy: DownloadPolicy = .github
        var maxAttempts = 4
        var backoff: (Int) -> TimeInterval = { n in pow(3, Double(n - 1)) * (1 + Double.random(in: 0...0.25)) }   // 1, 3, 9 s…
        var freeSpace: (URL) -> Int64? = UpdateFiles.freeSpace
        var writeHook: ((_ offset: Int64, _ count: Int) throws -> Void)?   // tests: inject a full disk
        var requestTimeout: TimeInterval = 30
        static let spaceMargin: Int64 = 64 * 1024 * 1024
    }

    let config: Config
    var progress: ((_ done: Int64, _ total: Int64) -> Void)?
    private var completion: ((Result<URL, DownloadFailure>) -> Void)?
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q }()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var offset: Int64 = 0
    private var attempt = 0
    private var hashRetried = false
    private var cancelled = false
    private var pending: DownloadFailure?      // decided in a delegate callback; acted on when the task completes
    private var restart = false                // the server's answer made the partial file useless: start again from 0
    private var transient: Int?                // a 5xx/408/429 answer: retried like a dropped connection
    private(set) var requests: [String] = []   // the Range header of each request (tests)

    var partialURL: URL { config.directory.appendingPathComponent("\(config.sha256).dmg.partial") }
    var finalURL: URL { config.directory.appendingPathComponent("\(config.sha256).dmg") }

    init(_ config: Config) { self.config = config }

    /// `done` runs once, on a background queue: the verified DMG's URL, or why not.
    func start(done: @escaping (Result<URL, DownloadFailure>) -> Void) {
        completion = done
        queue.addOperation { self.begin() }
    }

    /// Stops; what was downloaded stays for the next try.
    func cancel() {
        queue.addOperation {
            self.cancelled = true
            if let t = self.task { t.cancel() } else { self.finish(.failure(.cancelled)) }
        }
    }

    private func begin() {
        guard !cancelled else { return finish(.failure(.cancelled)) }
        guard config.policy.allowsHost(config.url) else { return finish(.failure(.refusedURL)) }
        guard config.expectedSize > 0, config.expectedSize <= UpdateManifest.maxDMGSize else { return finish(.failure(.tooLarge)) }
        let fm = FileManager.default
        do { try UpdateFiles.makePrivate(config.directory) } catch { return finish(.failure(.io("folder: \(error.localizedDescription)"))) }
        removeOtherReleases()
        if fm.fileExists(atPath: finalURL.path) {
            if UpdateFiles.sha256(of: finalURL) == config.sha256 { return finish(.success(finalURL)) }
            try? fm.removeItem(at: finalURL)
        }
        offset = ((try? fm.attributesOfItem(atPath: partialURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if offset > config.expectedSize { try? fm.removeItem(at: partialURL); offset = 0 }
        if offset == config.expectedSize { return verify() }
        if let free = config.freeSpace(config.directory), free < config.expectedSize - offset + Config.spaceMargin {
            return finish(.failure(.diskFull))
        }
        if !fm.fileExists(atPath: partialURL.path) {
            guard fm.createFile(atPath: partialURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { return finish(.failure(.io("can't create the download file"))) }
        }
        do {
            let h = try FileHandle(forWritingTo: partialURL)
            try h.truncate(atOffset: UInt64(offset))           // a torn last write is cut back to what was counted
            try h.seek(toOffset: UInt64(offset))
            handle = h
        } catch { return finish(.failure(.io(error.localizedDescription))) }

        attempt += 1
        pending = nil; restart = false; transient = nil
        var r = URLRequest(url: config.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: config.requestTimeout)
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")      // byte offsets must be the file's
        r.setValue("Cocaine-Updater", forHTTPHeaderField: "User-Agent")
        if offset > 0 { r.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        requests.append(offset > 0 ? "bytes=\(offset)-" : "")
        if session == nil {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = config.requestTimeout
            cfg.timeoutIntervalForResource = 3600
            cfg.waitsForConnectivity = false
            cfg.urlCache = nil
            session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        }
        task = session?.dataTask(with: r)
        task?.resume()
    }

    /// Only the current release's files stay in the folder.
    private func removeOtherReleases() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(atPath: config.directory.path)) ?? []
        where (f.hasSuffix(".dmg") || f.hasSuffix(".dmg.partial")) && !f.hasPrefix(config.sha256) {
            try? fm.removeItem(at: config.directory.appendingPathComponent(f))
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let u = newRequest.url, config.policy.allowsHost(u) { completionHandler(newRequest) }
        else { pending = .refusedURL; completionHandler(nil) }
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard pending == nil, let http = response as? HTTPURLResponse else { pending = pending ?? .io("not HTTP"); return completionHandler(.cancel) }
        switch http.statusCode {
        case 206:
            guard offset > 0, let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")),
                  range.start == offset, range.total == config.expectedSize else { restart = true; return completionHandler(.cancel) }
        case 200:
            if offset > 0 {                                       // the server ignored Range: take the whole file again
                do { try handle?.truncate(atOffset: 0); try handle?.seek(toOffset: 0) } catch { pending = .io(error.localizedDescription) }
                offset = 0
            }
            if http.expectedContentLength >= 0, http.expectedContentLength != config.expectedSize { pending = .sizeMismatch }
        case 416:
            restart = true
        case 500...599, 408, 429:
            transient = http.statusCode; return completionHandler(.cancel)
        default:
            pending = .http(http.statusCode)
        }
        completionHandler(pending == nil && !restart ? .allow : .cancel)
    }

    /// "bytes 100-199/1000" → (100, 1000).
    static func contentRange(_ v: String?) -> (start: Int64, total: Int64)? {
        guard let v, v.hasPrefix("bytes ") else { return nil }
        let rest = v.dropFirst(6).split(separator: "/")
        guard rest.count == 2, let total = Int64(rest[1]), let start = rest[0].split(separator: "-").first.flatMap({ Int64($0) })
        else { return nil }
        return (start, total)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard pending == nil, !restart, transient == nil else { return }
        if offset + Int64(data.count) > config.expectedSize { pending = .tooLarge; dataTask.cancel(); return }
        do {
            try config.writeHook?(offset, data.count)
            try handle?.write(contentsOf: data)
        } catch {
            pending = UpdateFiles.isDiskFull(error) ? .diskFull : .io(error.localizedDescription)
            dataTask.cancel(); return
        }
        offset += Int64(data.count)
        progress?(offset, config.expectedSize)
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close(); handle = nil
        task = nil
        let fm = FileManager.default
        if let p = pending {
            switch p {
            case .tooLarge, .sizeMismatch, .diskFull, .io: try? fm.removeItem(at: partialURL)   // useless, and space matters
            default: break
            }
            return finish(.failure(p))
        }
        if cancelled { return finish(.failure(.cancelled)) }
        if restart { try? fm.removeItem(at: partialURL); offset = 0; return retry(.network("bad range answer")) }
        if let code = transient { return retry(.http(code)) }
        if let error {
            let kind = classifyNetworkError(error)
            if let kind { return finish(.failure(kind)) }        // offline, refused…: not retried here
            return retry(.network(error.localizedDescription))
        }
        if offset == config.expectedSize { return verify() }
        retry(.network("transfer ended early"))                // a 5xx, or a connection closed short
    }

    private func retry(_ reason: DownloadFailure) {
        guard attempt < config.maxAttempts else { return finish(.failure(reason)) }
        let wait = config.backoff(attempt)
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in self?.queue.addOperation { self?.begin() } }
    }

    private func verify() {
        let fm = FileManager.default
        if UpdateFiles.sha256(of: partialURL) == config.sha256 {
            do {
                if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
                try fm.moveItem(at: partialURL, to: finalURL)
            } catch { return finish(.failure(.io(error.localizedDescription))) }
            return finish(.success(finalURL))
        }
        try? fm.removeItem(at: partialURL)
        offset = 0
        guard !hashRetried else { return finish(.failure(.hashMismatch)) }
        hashRetried = true                                     // a corrupted part on disk or in transit: once more from scratch
        attempt = 0
        begin()
    }

    private func finish(_ r: Result<URL, DownloadFailure>) {
        try? handle?.close(); handle = nil
        session?.finishTasksAndInvalidate(); session = nil
        let c = completion; completion = nil
        c?(r)
    }
}
