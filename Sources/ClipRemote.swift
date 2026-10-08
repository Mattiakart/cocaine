// Short text between the paired iPhone and this Mac's clipboard, over the remote-control relay (protocol v2: authenticated,
// end-to-end encrypted, replay-proof; RemoteProtocol.swift). Commands the iPhone's "Cocaine Clip" Shortcut sends
// (SyncShortcuts.swift), handled here inside the app — never by a shell (remote.zsh's gate refuses `clip`):
//
//   clip put <base64>                     text into the history (≤ ~360 bytes: one command holds 500 bytes)
//   clip part <id> <i>/<n> <base64 piece> one piece of a longer text (n ≤ 6, ≈ 2 KB in all), put together within 2 minutes
//   clip get                              the newest item of the history (text only; secrets never), cut to fit one answer
//   clip get <k>                          the k-th item of the pinboard the user made readable from the iPhone
//   clip list                             that pinboard's items, numbered
//
// Each needs its own switch for that pairing (Settings → Island → iPhone clipboard sync; both off by default), works only for
// an authenticated (v2) pairing at either level, and at most 12 a minute. Never the history beyond its newest item.

import Foundation

enum ClipRemoteCommand: Equatable {
    case put(String)                                   // the text, decoded
    case part(id: String, index: Int, count: Int, piece: String)
    case get(Int?)
    case list
}

struct ClipRemoteParseError: Error, Equatable { var why: String }

enum ClipRemote {
    static let maxParts = 6
    static let maxTotalBytes = 2_200                   // what the pieces may add up to, decoded
    static let partTimeout: Double = 120
    static let perMinute = 12
    /// Room for the item in one answer (RemoteProtocol.maxReplyBytes), with the prefix and a possible note.
    static let replyRoom = RemoteProtocol.maxReplyBytes - 120
    /// What a successful `clip get` answer starts with: the Shortcut copies only such answers, without it.
    static let clipPrefix = "CLIP:"

    /// nil: not a clip command (the gate takes it). Otherwise the command, or why it isn't one.
    static func parse(_ text: String) -> Result<ClipRemoteCommand, ClipRemoteParseError>? {
        let w = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard w.first == "clip" else { return nil }
        func b64(_ s: String) -> Bool { s.range(of: "^[A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil }
        switch (w.count > 1 ? w[1] : "", w.count) {
        case ("put", 3):
            guard b64(w[2]), let d = Data(base64Encoded: w[2]), let s = String(data: d, encoding: .utf8) else { return .failure(ClipRemoteParseError(why: "bad text")) }
            return .success(.put(s))
        case ("part", 5):
            let fr = w[3].split(separator: "/").compactMap { Int($0) }
            guard w[2].range(of: "^[A-Za-z0-9]{1,16}$", options: .regularExpression) != nil, fr.count == 2,
                  w[3].range(of: "^[0-9]{1,2}/[0-9]{1,2}$", options: .regularExpression) != nil,
                  w[4].range(of: "^[A-Za-z0-9+/=]+$", options: .regularExpression) != nil else { return .failure(ClipRemoteParseError(why: "bad part")) }
            return .success(.part(id: w[2], index: fr[0], count: fr[1], piece: w[4]))
        case ("get", 2): return .success(.get(nil))
        case ("get", 3):
            guard let k = Int(w[2]), (1...99).contains(k), w[2].range(of: "^[0-9]+$", options: .regularExpression) != nil else { return .failure(ClipRemoteParseError(why: "bad number")) }
            return .success(.get(k))
        case ("list", 2): return .success(.list)
        default: return .failure(ClipRemoteParseError(why: "unknown clip command"))
        }
    }

    /// What the commands may see and do (the app's history; tests give fakes).
    struct Context {
        var perm: (_ pairing: String) -> ClipRemotePerm
        var newest: () -> ClipItem?
        var readable: () -> (name: String, items: [ClipItem])?       // the iPhone-readable pinboard, newest first
        var settings: () -> ClipSettings
        var add: (String) -> Bool                                     // text from the iPhone into the history; false: not kept
        var now: () -> Date = Date.init
    }
}

/// Puts `clip part` pieces together: per pairing and id, all pieces within `ClipRemote.partTimeout`, the same count in each,
/// no index twice with different content, no more than `maxTotalBytes`. Anything inconsistent drops that text (fail closed).
final class ClipPartAssembler {
    private struct Pending { var count: Int; var pieces: [Int: String]; var started: Date }
    private var pending: [String: Pending] = [:]

    enum Outcome: Equatable { case waiting(have: Int, of: Int), done(String), invalid, tooLong }

    func add(pairing: String, id: String, index: Int, count: Int, piece: String, now: Date) -> Outcome {
        pending = pending.filter { now.timeIntervalSince($0.value.started) < ClipRemote.partTimeout }
        guard (1...ClipRemote.maxParts).contains(count) else { return count > ClipRemote.maxParts ? .tooLong : .invalid }
        guard (1...count).contains(index) else { return .invalid }
        let key = pairing + "|" + id
        guard pending.count < 16 || pending[key] != nil else { return .invalid }
        var p = pending[key] ?? Pending(count: count, pieces: [:], started: now)
        guard p.count == count, p.pieces[index] == nil || p.pieces[index] == piece else { pending[key] = nil; return .invalid }
        p.pieces[index] = piece
        guard p.pieces.values.reduce(0, { $0 + $1.utf8.count }) <= (ClipRemote.maxTotalBytes * 4 + 2) / 3 + 4 else { pending[key] = nil; return .tooLong }
        guard p.pieces.count == count else { pending[key] = p; return .waiting(have: p.pieces.count, of: count) }
        pending[key] = nil
        let joined = (1...count).map { p.pieces[$0]! }.joined()
        guard let d = Data(base64Encoded: joined), let s = String(data: d, encoding: .utf8) else { return .invalid }
        return d.count > ClipRemote.maxTotalBytes ? .tooLong : .done(s)
    }
}

/// The per-pairing limit: `ClipRemote.perMinute` clip commands in any minute.
final class ClipRateLimiter {
    private var times: [String: [Date]] = [:]
    func allow(_ pairing: String, now: Date, limit: Int = ClipRemote.perMinute) -> Bool {
        var t = (times[pairing] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard t.count < limit else { times[pairing] = t; return false }
        t.append(now)
        times[pairing] = t
        return true
    }
}

/// Answers clip commands. One per app; thread-safe (the relay's listener calls it from its tasks).
final class ClipRemoteHandler {
    let context: ClipRemote.Context
    private let lock = NSLock()
    private let parts = ClipPartAssembler()
    private let limiter = ClipRateLimiter()
    private let perMinute: Int

    init(perMinute: Int = ClipRemote.perMinute, context: ClipRemote.Context) { self.context = context; self.perMinute = perMinute }

    /// nil: not a clip command. `authenticated`: it came from a v2 pairing (old plain-text Shortcuts never reach the clipboard).
    func handle(_ text: String, pairing: Pairing, authenticated: Bool) -> String? {
        guard let parsed = ClipRemote.parse(text) else { return nil }
        guard authenticated, !pairing.isLegacy else { return L("Cocaine: the clipboard needs a newer Shortcut. On the Mac: Settings → Remote work → iPhone → Send.") }
        guard case .success(let cmd) = parsed else { return L("Cocaine: unknown clipboard command.") }
        lock.lock(); defer { lock.unlock() }
        let now = context.now(), perm = context.perm(pairing.id)
        switch cmd {
        case .put, .part:
            guard perm.write else { return L("Cocaine: sending text to this Mac's clipboard is off. On the Mac: Settings → Island → iPhone clipboard sync.") }
        case .get, .list:
            guard perm.read else { return L("Cocaine: reading this Mac's clipboard from the iPhone is off. On the Mac: Settings → Island → iPhone clipboard sync.") }
        }
        guard limiter.allow(pairing.id, now: now, limit: perMinute) else { return L("Cocaine: too many clipboard requests: wait a minute.") }
        switch cmd {
        case .put(let s): return put(s)
        case .part(let id, let i, let n, let piece):
            switch parts.add(pairing: pairing.id, id: id, index: i, count: n, piece: piece, now: now) {
            case .waiting(let have, let of): return String(format: L("Cocaine: part %d of %d received."), have, of)
            case .done(let s): return put(s)
            case .invalid: return L("Cocaine: the parts didn't match: send it again.")
            case .tooLong: return L("Cocaine: too long for this channel (about 2,000 characters): use “Send to Mac” (iCloud Drive).")
            }
        case .get(nil):
            guard let item = context.newest() else { return L("Cocaine: the clipboard history is empty.") }
            return answer(item)
        case .get(let k?):
            guard let b = context.readable() else { return L("Cocaine: no pinboard is readable from the iPhone. On the Mac: Settings → Island → iPhone clipboard sync.") }
            guard k <= b.items.count else { return String(format: L("Cocaine: there is no item %d on “%@”."), k, b.name) }
            return answer(b.items[k - 1])
        case .list:
            guard let b = context.readable() else { return L("Cocaine: no pinboard is readable from the iPhone. On the Mac: Settings → Island → iPhone clipboard sync.") }
            guard !b.items.isEmpty else { return String(format: L("Cocaine: “%@” is empty."), b.name) }
            let s = context.settings()
            let lines = b.items.prefix(20).enumerated().map { i, c -> String in
                let t: String
                if ClipSyncRules.outbound(c, settings: s, automatic: false) != nil { t = "•••" }
                else if let title = c.title, !title.isEmpty { t = title }
                else if c.kind == .image { t = L("Image") }
                else { t = String(c.text.prefix(60)).replacingOccurrences(of: "\n", with: " ") }
                return "\(i + 1). \(t)"
            }
            return b.name + "\n" + lines.joined(separator: "\n")
        }
    }

    private func put(_ s: String) -> String {
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return L("Cocaine: there was no text to add.") }
        guard context.add(s) else { return L("Cocaine: not kept: it looks like a password, key or card number, or matches an excluded pattern.") }
        return String(format: L("Cocaine: added to this Mac's clipboard history (%d characters)."), s.count)
    }

    /// One item as an answer: text only, checked like anything sent to the iPhone, cut to fit (and saying so).
    private func answer(_ item: ClipItem) -> String {
        if item.kind == .image { return L("Cocaine: that item is an image: use “Get from Mac” (iCloud Drive).") }
        if item.kind == .files { return L("Cocaine: that item is a file: files aren't sent.") }
        if let r = ClipSyncRules.outbound(item, settings: context.settings(), automatic: false) {
            return r == .secret ? L("Cocaine: not sent: it looks like a password, key or card number.") : ClipSyncCenter.refusalText(r)
        }
        let full = Data(item.text.utf8).count
        var out = Data()
        for ch in item.text {
            let b = Data(String(ch).utf8)
            if out.count + b.count > ClipRemote.replyRoom { break }
            out.append(b)
        }
        let text = String(decoding: out, as: UTF8.self)
        guard out.count < full else { return ClipRemote.clipPrefix + text }
        return ClipRemote.clipPrefix + text + "\n" + String(format: L("[cut: %d of %d bytes]"), out.count, full)
    }
}

extension ClipRemote {
    /// The app's handler: the shared history and settings, read on the main thread.
    static let shared = ClipRemoteHandler(context: Context(
        perm: { id in onMain { ClipSyncCenter.shared.settings.perm(id) } },
        newest: { onMain { ClipboardHistory.shared.items.first } },
        readable: {
            onMain {
                let c = ClipSyncCenter.shared, h = ClipboardHistory.shared
                guard let id = c.settings.readableBoard, let b = h.board(id) else { return nil }
                return (b.displayName, h.items.filter { $0.boards.contains(id) })
            }
        },
        settings: { onMain { ClipboardHistory.shared.settings } },
        add: { s in onMain { ClipSyncCenter.shared.ingest(.text(s)) } }))

    static func onMain<T>(_ body: () -> T) -> T { Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body) }
}
