// Shared helpers for running programs (Proc: a timeout, output drained while it runs and bounded, never a deadlock on a full
// pipe), listing processes (ProcessList) and writing private files atomically (SafeFile: 0600 from the first byte, fsync, rename).

import Darwin
import Foundation

enum Proc {
    struct Result {
        var status: Int32                 // -1: couldn't start (or was killed after the timeout)
        var output: Data
        var timedOut: Bool
        var text: String { String(decoding: output, as: UTF8.self) }
    }

    /// Runs `path` with `args` and waits, at most `timeout` seconds (then SIGTERM, and SIGKILL 2 s later). With `capture` its
    /// standard output (and standard error with `stderr`) is read as it comes, up to `limit` bytes; the rest is drained and
    /// dropped, so a chatty program never blocks on a full pipe. A child that keeps the pipe open after the program ended (an
    /// agent it started) doesn't hold the answer back. Blocks the calling thread: never call it on the main thread for a program
    /// that can take long.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 120, capture: Bool = false, stderr: Bool = false,
                    env: [String: String]? = nil, limit: Int = 1 << 20) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let env { p.environment = env }
        p.standardInput = FileHandle.nullDevice
        let lock = NSLock(), eof = DispatchSemaphore(value: 0)
        var data = Data()
        var pipe: Pipe?
        if capture {
            let pp = Pipe()
            pipe = pp
            p.standardOutput = pp
            p.standardError = stderr ? pp : FileHandle.nullDevice
            pp.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { h.readabilityHandler = nil; eof.signal(); return }
                lock.lock()
                if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
                lock.unlock()
            }
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            pipe?.fileHandleForReading.readabilityHandler = nil
            return Result(status: -1, output: Data(), timedOut: false)
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 2) }
        }
        if let pipe {
            _ = eof.wait(timeout: .now() + (timedOut ? 0.1 : 0.5))          // the last bytes (or a grandchild holding the pipe)
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        lock.lock(); let out = data; lock.unlock()
        return Result(status: timedOut ? -1 : p.terminationStatus, output: out, timedOut: timedOut)
    }
}

/// Every process the user can see: pid and short name (proc_name), sized by asking first.
enum ProcessList {
    static func all() -> [(pid: pid_t, name: String)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var buf = [CChar](repeating: 0, count: 256)
        var out: [(pid_t, String)] = []
        out.reserveCapacity(max(0, n))
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            if proc_name(pid, &buf, UInt32(buf.count)) > 0 { out.append((pid, String(cString: buf))) }
        }
        return out
    }
}

enum SafeFile {
    /// Writes `data` to `url` so that a crash never leaves half a file and nobody else can read it, not even for a moment: a
    /// temporary file created 0600 (O_EXCL), written, fsynced, renamed over the old one. The folder is made 0700 if missing.
    @discardableResult
    static func writePrivate(_ data: Data, to url: URL, folderMode: mode_t = 0o700) -> Bool {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: folderMode])
        }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let ok = data.withUnsafeBytes { p -> Bool in
            guard let base = p.baseAddress else { return true }
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, base + off, p.count - off)
                if n <= 0 { return false }
                off += n
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else { unlink(tmp.path); return false }
        return true
    }
}
