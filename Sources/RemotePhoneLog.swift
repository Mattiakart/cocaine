import Darwin
import Foundation

/// remote-phone.log: one line per event of the remote control (the gate in remote.zsh writes its lines there too), so a
/// Shortcut that "gets no answer" can be explained from the Mac. Lines carry reason codes, sizes, ages and the pairing
/// id (which the relay sees anyway): never a key, a topic, a command or an answer. Private (0600) and bounded.
final class RemotePhoneLog {
    let url: URL
    let maxBytes: Int
    private let lock = NSLock()

    init(url: URL, maxBytes: Int = 256 * 1024) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// The line as written: local time, then the text with control characters replaced (one event, one line).
    static func line(_ text: String, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let clean = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "?" : Character($0) })
        return f.string(from: date) + " " + clean + "\n"
    }

    func write(_ text: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let data = Data(Self.line(text, at: date).utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        trimIfNeeded()
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        fchmod(fd, 0o600)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
    }

    /// Past `maxBytes`, keeps the newer half (whole lines).
    private func trimIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(maxBytes / 2)
        if let nl = tail.firstIndex(of: 0x0A) { tail = tail[(nl + 1)...] }
        let tmp = url.path + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let ok = tail.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, tail.count) } == tail.count
        close(fd)
        if !ok || rename(tmp, url.path) != 0 { unlink(tmp) }
    }
}
