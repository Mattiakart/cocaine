// The shelf's group operations without UI: running a program that can be cancelled (ShelfProc), ZIP archives with ditto
// (several files are staged as APFS clones first), copying and moving into a folder ("keep both" names), the Trash, the apps
// that open every file of a selection, and the one task at a time the island shows with its progress (ShelfTasks).

import AppKit
import Foundation

/// Set from any thread to stop a running job.
final class CancelToken {
    private let lock = NSLock()
    private var flag = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// Runs a program: argv only (never a shell string), stdin from data or nothing, its own small environment, stdout and stderr
/// kept apart and bounded, a timeout, and cancel. Blocks the calling thread (never the main one).
enum ShelfProc {
    struct Result: Equatable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut = false
        var cancelled = false
        var out: String { String(decoding: stdout, as: UTF8.self) }
        var err: String { String(decoding: stderr, as: UTF8.self) }
        var ok: Bool { status == 0 && !timedOut && !cancelled }
    }

    /// The environment a program gets: a plain PATH, the user's HOME and language, and what the caller adds. Nothing of
    /// Cocaine's own environment (test overrides, DYLD_*) is passed on.
    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var e: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": env["HOME"] ?? NSHomeDirectory()]
        for k in ["LANG", "LC_ALL", "USER", "LOGNAME", "TMPDIR"] { if let v = env[k] { e[k] = v } }
        if e["LANG"] == nil { e["LANG"] = "en_US.UTF-8" }
        for (k, v) in extra { e[k] = v }
        return e
    }

    static func run(_ path: String, _ args: [String], stdin: Data? = nil, env: [String: String]? = nil, cwd: URL? = nil,
                    timeout: TimeInterval = 600, cancel: CancelToken? = nil, limit: Int = 1 << 20) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = env ?? environment()
        if let cwd { p.currentDirectoryURL = cwd }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        p.standardInput = inPipe ?? FileHandle.nullDevice
        let lock = NSLock()
        var out = Data(), err = Data()
        let eofOut = DispatchSemaphore(value: 0), eofErr = DispatchSemaphore(value: 0)
        func reader(_ pipe: Pipe, _ eof: DispatchSemaphore, _ append: @escaping (Data) -> Void) {
            pipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { h.readabilityHandler = nil; eof.signal(); return }
                lock.lock(); append(chunk); lock.unlock()
            }
        }
        reader(outPipe, eofOut) { c in if out.count < limit { out.append(c.prefix(limit - out.count)) } }
        reader(errPipe, eofErr) { c in if err.count < limit { err.append(c.prefix(limit - err.count)) } }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil; errPipe.fileHandleForReading.readabilityHandler = nil
            return Result(status: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8))
        }
        if let inPipe, let stdin {
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false, cancelled = false
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            if cancel?.cancelled == true { cancelled = true } else if Date() > deadline { timedOut = true } else { continue }
            p.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 2) }
            break
        }
        _ = eofOut.wait(timeout: .now() + 0.5); _ = eofErr.wait(timeout: .now() + 0.5)
        outPipe.fileHandleForReading.readabilityHandler = nil; errPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        return Result(status: (timedOut || cancelled) ? -1 : p.terminationStatus, stdout: out, stderr: err, timedOut: timedOut, cancelled: cancelled)
    }
}

enum ShelfOpsError: Error, LocalizedError {
    case failed(String)
    case cancelled
    var errorDescription: String? {
        switch self { case .failed(let s): return s; case .cancelled: return L("Cancelled") }
    }
}

// MARK: - ZIP

enum ZipTool {
    static let ditto = "/usr/bin/ditto"

    /// The archive's name: "<name>.zip" for one item, "Archive.zip" for several (as Finder does).
    static func name(for urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent + ".zip" : L("Archive") + ".zip"
    }

    /// Where the archive goes: next to the first item when that folder can be written, else Downloads.
    static func destination(for urls: [URL], downloads: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) -> URL {
        let dir = urls.first?.deletingLastPathComponent() ?? downloads
        let base = FileManager.default.isWritableFile(atPath: dir.path) ? dir : downloads
        return FileNames.unique(base.appendingPathComponent(name(for: urls)))
    }

    /// The argv for ditto: one item keeps its folder name in the archive (--keepParent); several are staged in one folder whose
    /// contents become the archive's top level. Resource forks and extended attributes are kept (--sequesterRsrc).
    static func arguments(source: URL, out: URL, keepParent: Bool) -> [String] {
        ["-c", "-k", "--sequesterRsrc"] + (keepParent ? ["--keepParent"] : []) + [source.path, out.path]
    }

    /// Makes the archive. Several items are first cloned into a temporary folder (instant and free on APFS), names made distinct.
    static func zip(_ urls: [URL], to out: URL, cancel: CancelToken? = nil) throws -> URL {
        guard !urls.isEmpty else { throw ShelfOpsError.failed(L("Nothing to compress")) }
        let fm = FileManager.default
        var stage: URL?
        defer { if let s = stage { try? fm.removeItem(at: s) } }
        let source: URL
        if urls.count == 1 {
            source = urls[0]
        } else {
            let s = fm.temporaryDirectory.appendingPathComponent("cocaine-zip-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: s, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            stage = s
            for u in urls {
                if cancel?.cancelled == true { throw ShelfOpsError.cancelled }
                let to = FileNames.unique(s.appendingPathComponent(u.lastPathComponent))
                try fm.copyItem(at: u, to: to)
            }
            source = s
        }
        let r = ShelfProc.run(ditto, arguments(source: source, out: out, keepParent: urls.count == 1), timeout: 3600, cancel: cancel)
        if r.cancelled { try? fm.removeItem(at: out); throw ShelfOpsError.cancelled }
        guard r.ok, fm.fileExists(atPath: out.path) else {
            try? fm.removeItem(at: out)
            throw ShelfOpsError.failed(r.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("Couldn't make the archive") : r.err)
        }
        return out
    }
}

// MARK: - Files

enum ShelfFiles {
    struct Moved: Equatable { var from: URL; var to: URL }

    /// Copies or moves files into a folder, never overwriting ("name 2.ext"). Returns where each one went (those that failed are
    /// left out, with the first problem).
    static func transfer(_ urls: [URL], into dir: URL, move: Bool, cancel: CancelToken? = nil,
                         progress: (Double) -> Void = { _ in }) -> (done: [Moved], problem: String?) {
        let fm = FileManager.default
        var done: [Moved] = [], problem: String?
        for (i, u) in urls.enumerated() {
            if cancel?.cancelled == true { problem = L("Cancelled"); break }
            if move && u.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL { done.append(Moved(from: u, to: u)); continue }
            let to = FileNames.unique(dir.appendingPathComponent(u.lastPathComponent))
            do {
                if move { try fm.moveItem(at: u, to: to) } else { try fm.copyItem(at: u, to: to) }
                done.append(Moved(from: u, to: to))
            } catch { if problem == nil { problem = error.localizedDescription } }
            progress(Double(i + 1) / Double(urls.count))
        }
        return (done, problem)
    }

    /// Moves files to the Trash (they can be put back from there). Returns those that went.
    static func trash(_ urls: [URL], using: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> (done: [URL], problem: String?) {
        var done: [URL] = [], problem: String?
        for u in urls {
            do { try using(u); done.append(u) } catch { if problem == nil { problem = error.localizedDescription } }
        }
        return (done, problem)
    }

    /// Paths for the clipboard: one per line (quoted when `quoted`, for pasting into a shell).
    static func paths(_ urls: [URL], quoted: Bool = false) -> String {
        urls.map { quoted ? "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" : $0.path }.joined(separator: "\n")
    }

    /// The apps that can open every one of these files, the first file's default app first, then by name.
    static func apps(for urls: [URL], workspace: NSWorkspace = .shared) -> [URL] {
        guard let first = urls.first else { return [] }
        var common = workspace.urlsForApplications(toOpen: first).map(\.standardizedFileURL)
        for u in urls.dropFirst() {
            let s = Set(workspace.urlsForApplications(toOpen: u).map(\.standardizedFileURL))
            common = common.filter { s.contains($0) }
        }
        var seen = Set<String>()
        common = common.filter { seen.insert($0.path).inserted }
        let def = workspace.urlForApplication(toOpen: first)?.standardizedFileURL
        let named = common.filter { $0 != def }.sorted { appName($0).localizedStandardCompare(appName($1)) == .orderedAscending }
        return (def.map { common.contains($0) ? [$0] : [] } ?? []) + named
    }

    static func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - One task at a time, with progress

/// What the island shows while a shelf job runs (a ZIP, resizing, OCR, a custom action…): its title, progress (nil: going on),
/// a Cancel button. One at a time; asking for another while one runs is refused with a message.
final class ShelfTasks: ObservableObject {
    struct Running: Equatable {
        var id = UUID()
        var title: String
        var progress: Double?
    }
    @Published private(set) var running: Running?
    private var token: CancelToken?

    var busy: Bool { running != nil }

    /// Runs `work` off the main thread; `done` gets its result on the main thread. False when another job is running.
    @discardableResult
    func start<T>(_ title: String, work: @escaping (CancelToken, @escaping (Double) -> Void) throws -> T,
                  done: @escaping (Result<T, Error>) -> Void) -> Bool {
        guard running == nil else { return false }
        let t = CancelToken()
        token = t
        let r = Running(title: title, progress: nil)
        Motion.with(.appear) { running = r }
        let id = r.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report: (Double) -> Void = { [weak self] p in
                DispatchQueue.main.async { [weak self] in if self?.running?.id == id { self?.running?.progress = max(0, min(1, p)) } }
            }
            let result: Result<T, Error>
            do { result = .success(try work(t, report)) } catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.running?.id == id { Motion.with(.appear) { self.running = nil }; self.token = nil }
                done(result)
            }
        }
        return true
    }

    func cancel() { token?.cancel() }
}
