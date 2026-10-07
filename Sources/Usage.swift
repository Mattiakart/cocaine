// The AI tools' usage on the island's Status page, read from their own local files: Claude Code's token counts (an incremental
// reader that remembers how far it read each file) and Codex's rate limits (the newest session files that report them).

import Foundation
import SwiftUI

/// Claude Code's tokens (input + output, each message once) in the last 5 hours and 7 days, from ~/.claude/projects/**/*.jsonl.
/// The first refresh reads the last week's files once; later ones read only what was appended since (per-file offsets), so a
/// refresh costs milliseconds instead of reading hundreds of MB again. A refresh that runs out of time says so (partial) and
/// the next one carries on where it stopped: a total is never shown as complete when it isn't.
final class ClaudeUsageReader {
    /// How far a file has been read, and its messages so far (dropped with it when it is cut short, replaced or gone).
    struct FileState { var offset: UInt64; var size: UInt64; var messages: [String: (at: Date, tokens: Int)] = [:] }
    let root: URL
    private(set) var files: [String: FileState] = [:]
    /// Bytes read by the last refresh (tests: a second refresh reads only what was appended).
    private(set) var bytesRead: UInt64 = 0
    static let chunk = 4 << 20

    init(root: URL) { self.root = root }

    func refresh(now: Date = Date(), budget: TimeInterval = 4) -> (five: Int, week: Int, partial: Bool) {
        bytesRead = 0
        let weekAgo = now.addingTimeInterval(-7 * 86400), fiveAgo = now.addingTimeInterval(-5 * 3600)
        let started = Date()
        var partial = false
        var seen: [String: FileState] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var list: [(URL, Date, UInt64)] = []
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let u as URL in en where u.pathExtension == "jsonl" {
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let m = v.contentModificationDate, m > weekAgo else { continue }
                list.append((u, m, UInt64(v.fileSize ?? 0)))
            }
        }
        list.sort { $0.1 > $1.1 }                                   // newest first: a cut-short first run has the last hours
        for (u, _, size) in list {
            var st = files[u.path] ?? FileState(offset: 0, size: 0)
            if size < st.offset { st = FileState(offset: 0, size: 0) }   // cut short or replaced: read again
            st.size = size
            if st.offset < size {
                if Date().timeIntervalSince(started) > budget { partial = true }
                else if !read(u, &st, deadline: started.addingTimeInterval(budget)) { partial = true }
            }
            seen[u.path] = st
        }
        files = seen                                                // a file gone or older than a week is forgotten
        var best: [String: (at: Date, tokens: Int)] = [:]          // a message in two files (a resumed session) counts once
        for (path, st) in files {
            let recent = st.messages.filter { $0.value.at > weekAgo }
            if recent.count != st.messages.count { files[path]?.messages = recent }
            for (id, v) in recent where v.tokens > (best[id]?.tokens ?? -1) { best[id] = v }
        }
        var five = 0, week = 0
        for v in best.values { week += v.tokens; if v.at > fiveAgo { five += v.tokens } }
        return (five, week, partial)
    }

    /// Reads one file from its offset to its end (whole lines only; a line still being written waits for the next refresh).
    /// False when the deadline cut it short.
    private func read(_ u: URL, _ st: inout FileState, deadline: Date) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: u) else { return true }
        defer { try? h.close() }
        do { try h.seek(toOffset: st.offset) } catch { return true }
        var carry = Data()
        let name = u.lastPathComponent
        while true {
            guard let chunk = try? h.read(upToCount: Self.chunk), !chunk.isEmpty else { return true }
            bytesRead += UInt64(chunk.count)
            var buf = carry
            buf.append(chunk)
            guard let lastNL = buf.lastIndex(of: 10) else { carry = buf; continue }
            let whole = buf[buf.startIndex...lastNL]
            Self.scan(whole, file: name) { id, at, tokens in
                if tokens > (st.messages[id]?.tokens ?? -1) { st.messages[id] = (at, tokens) }
            }
            st.offset += UInt64(whole.count)
            carry = Data(buf[buf.index(after: lastNL)...])
            if Date() > deadline { return false }
        }
    }

    private static let needle = Array(#""output_tokens":"#.utf8)
    private static let inputKey = Array(#""input_tokens":"#.utf8)
    private static let tsKey = Array(#""timestamp":""#.utf8)
    private static let idKey = Array(#""id":"msg_"#.utf8)

    /// Every line of `data` that reports tokens: (message id, when, input + output). Lines without "output_tokens" are skipped
    /// without being turned into strings.
    static func scan(_ data: Data, file: String, _ found: (String, Date, Int) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let n = raw.count
            var from = 0
            while from < n, let hit = find(needle, base, from, n) {
                var lineStart = hit
                while lineStart > 0 && raw[lineStart - 1] != 10 { lineStart -= 1 }
                var lineEnd = hit
                while lineEnd < n && raw[lineEnd] != 10 { lineEnd += 1 }
                if let tsAt = find(tsKey, base, lineStart, lineEnd), let at = parseISO(raw, tsAt + tsKey.count, lineEnd) {
                    let tokens = number(after: inputKey, raw, base, lineStart, lineEnd) + number(after: needle, raw, base, lineStart, lineEnd)
                    var id = "\(file)\(at.timeIntervalSince1970)"
                    if let idAt = find(idKey, base, lineStart, lineEnd) {
                        var e = idAt + idKey.count
                        while e < lineEnd && raw[e] != 34 { e += 1 }
                        id = String(decoding: UnsafeRawBufferPointer(rebasing: raw[(idAt + idKey.count)..<e]), as: UTF8.self)
                    }
                    found(id, at, tokens)
                }
                from = lineEnd + 1
            }
        }
    }

    private static func find(_ needle: [UInt8], _ base: UnsafeRawPointer, _ from: Int, _ to: Int) -> Int? {
        guard to - from >= needle.count else { return nil }
        return needle.withUnsafeBytes { nb -> Int? in
            guard let p = memmem(base + from, to - from, nb.baseAddress, needle.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(p))
        }
    }

    private static func number(after key: [UInt8], _ raw: UnsafeRawBufferPointer, _ base: UnsafeRawPointer, _ from: Int, _ to: Int) -> Int {
        guard let at = find(key, base, from, to) else { return 0 }
        var i = at + key.count, v = 0
        while i < to, raw[i] >= 48, raw[i] <= 57 { v = v &* 10 &+ Int(raw[i] - 48); i += 1 }
        return v
    }

    /// "2026-10-07T10:05:09.123Z" (UTC, as Claude Code writes it); anything else: nil.
    static func parseISO(_ raw: UnsafeRawBufferPointer, _ at: Int, _ end: Int) -> Date? {
        guard end - at >= 20 else { return nil }
        func num(_ i: Int, _ len: Int) -> Int? {
            var v = 0
            for k in i..<(i + len) { let c = raw[k]; guard c >= 48 && c <= 57 else { return nil }; v = v * 10 + Int(c - 48) }
            return v
        }
        guard let y = num(at, 4), raw[at + 4] == 45, let mo = num(at + 5, 2), raw[at + 7] == 45, let d = num(at + 8, 2), raw[at + 10] == 84,
              let h = num(at + 11, 2), let mi = num(at + 14, 2), let s = num(at + 17, 2), (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var i = at + 19, frac = 0.0
        if i < end, raw[i] == 46 {
            var scale = 0.1
            i += 1
            while i < end, raw[i] >= 48, raw[i] <= 57 { frac += Double(raw[i] - 48) * scale; scale /= 10; i += 1 }
        }
        guard i < end, raw[i] == 90 else { return nil }                  // Z
        // Days from the civil date (Howard Hinnant's algorithm).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Date(timeIntervalSince1970: Double(days * 86400 + h * 3600 + mi * 60 + s) + frac)
    }
}

/// Codex's rate limits: the newest of its session files (~/.codex/sessions/**/*.jsonl) that reports them. Recent sessions don't
/// always have a "rate_limits" event (a session just started, an older Codex), so up to `maxFiles` of them are looked at, newest
/// first, each from its last 512 KB.
enum CodexUsage {
    struct Limit: Identifiable, Equatable { var id: String; var minutes: Int; var percent: Double; var resets: Date? }

    static func limits(root: URL, maxFiles: Int = 30) -> [Limit] {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var list: [(URL, Date)] = []
        for case let u as URL in en where u.pathExtension == "jsonl" {
            list.append((u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast))
        }
        for (u, _) in list.sorted(by: { $0.1 > $1.1 }).prefix(maxFiles) {
            if let found = fromTail(u), !found.isEmpty { return found }
        }
        return []
    }

    static func fromTail(_ u: URL) -> [Limit]? {
        guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        return parse(String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self))
    }

    /// The plan named next to the newest limits ("plus", "pro", "prolite"…), if any.
    static func planType(_ text: String) -> String? {
        guard let r = text.range(of: "\"plan_type\":\"", options: .backwards) else { return nil }
        let v = text[r.upperBound...].prefix { $0 != "\"" }.prefix(30)
        return v.isEmpty || !v.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) ? nil : String(v)
    }

    /// The newest session's plan type (read with the limits).
    static func plan(root: URL, maxFiles: Int = 30) -> String? {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        var list: [(URL, Date)] = []
        for case let u as URL in en where u.pathExtension == "jsonl" {
            list.append((u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast))
        }
        for (u, _) in list.sorted(by: { $0.1 > $1.1 }).prefix(maxFiles) {
            guard let h = try? FileHandle(forReadingFrom: u) else { continue }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
            let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
            try? h.close()
            if let p = planType(text) { return p }
        }
        return nil
    }

    /// The last "rate_limits" in `text`: each window's percent used, its length and when it resets ("resets_at", seconds since
    /// 1970, or "resets_in_seconds" from the line's timestamp), whatever order the keys come in.
    static func parse(_ text: String) -> [Limit]? {
        guard let r = text.range(of: "\"rate_limits\":", options: .backwards) else { return nil }
        let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let line = text[lineStart...].prefix { $0 != "\n" }
        var stamp: Date?
        if let t = line.range(of: "\"timestamp\":\"") {
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let s = String(line[t.upperBound...].prefix { $0 != "\"" })
            stamp = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        let tail = String(text[r.upperBound...].prefix(1500))
        guard let objects = try? NSRegularExpression(pattern: #"\{[^{}]*"used_percent"[^{}]*\}"#) else { return nil }
        func value(_ key: String, _ s: String) -> Double? {
            guard let k = s.range(of: "\"\(key)\":") else { return nil }
            return Double(s[k.upperBound...].prefix { "0123456789.-".contains($0) })
        }
        var out: [Limit] = []
        for m in objects.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)) {
            guard let rr = Range(m.range, in: tail) else { continue }
            let o = String(tail[rr])
            guard let pct = value("used_percent", o), let win = value("window_minutes", o).map({ Int($0) }) else { continue }
            var resets = value("resets_at", o).map { Date(timeIntervalSince1970: $0) }
            if resets == nil, let secs = value("resets_in_seconds", o), let stamp { resets = stamp.addingTimeInterval(secs) }
            if !out.contains(where: { $0.minutes == win }) { out.append(Limit(id: "codex\(win)", minutes: win, percent: pct, resets: resets)) }
        }
        return out
    }
}

/// What the Status page shows, refreshed when the page opens (at most every 30 s), read off the main thread.
final class UsageWatch: ObservableObject {
    struct Limit: Identifiable { var id: String; var name: String; var percent: Double; var resets: Date?; var minutes: Int? = nil }
    @Published var codex: [Limit] = []
    @Published var codexPlan: String?
    /// Claude Code's plan limits (Quotas.swift), from the statusline wrapper's records; empty until it reports them.
    @Published var claudeLimits: [QuotaWindow] = []
    @Published var claudeLimitsAt: Date?
    /// The statusline wrapper is on (so "no limits yet" means "not reported yet", not "not set up").
    @Published var claudeLimitsOn = false
    @Published var claudeFive = 0
    @Published var claudeWeek = 0
    @Published var loaded = false
    /// The Claude Code counts are still being read (a first run over a week of large files): shown as such, never as final.
    @Published var partial = false
    private var busy = false, last = Date.distantPast
    private let queue = DispatchQueue(label: "local.cocaine.usage", qos: .utility)
    private lazy var claude = ClaudeUsageReader(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"))
    private let codexRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")

    func refresh(force: Bool = false) {
        guard !busy, force || Date().timeIntervalSince(last) > 30 else { return }
        busy = true
        queue.async { [claude, codexRoot] in
            let c = CodexUsage.limits(root: codexRoot)
            let plan = c.isEmpty ? nil : CodexUsage.plan(root: codexRoot)
            let q = Quotas.claude(folder: StatusLineHook.folder(ProcessInfo.processInfo.environment))
            let on = StatusLineHook.isOn()
            let t = claude.refresh()
            DispatchQueue.main.async {
                self.codex = c.map { Limit(id: $0.id, name: Self.windowName($0.minutes), percent: $0.percent, resets: $0.resets, minutes: $0.minutes) }
                self.codexPlan = plan
                self.claudeLimits = q.windows; self.claudeLimitsAt = q.at; self.claudeLimitsOn = on
                self.claudeFive = t.five; self.claudeWeek = t.week; self.partial = t.partial
                self.loaded = true; self.busy = false; self.last = Date()
                if t.partial { self.refresh(force: true) }          // carries on where it stopped
            }
        }
    }

    /// "Week", "Day", "5 h" in the app's language (on the main thread: the language can change meanwhile).
    static func windowName(_ minutes: Int) -> String { Quotas.windowName(minutes) }
}

// MARK: - Tests (part of --selftest): generated files in a temporary folder, never ~/.claude or ~/.codex

enum UsageTests {
    static func line(_ id: String, _ at: Date, input: Int, output: Int, pad: Int = 0) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let filler = String(repeating: "x", count: pad)
        return #"{"type":"assistant","timestamp":"\#(f.string(from: at))","message":{"id":"msg_\#(id)","content":"\#(filler)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":999,"cache_read_input_tokens":777,"output_tokens":\#(output)}}}"# + "\n"
    }

    /// A plain full parse, the reference the incremental reader must agree with.
    static func reference(_ dir: URL, now: Date) -> (Int, Int) {
        var best: [String: (Date, Int)] = [:]
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let u = en?.nextObject() as? URL {
            guard u.pathExtension == "jsonl", let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            for l in text.split(separator: "\n") where l.contains("\"output_tokens\":") {
                let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                guard let t = l.range(of: "\"timestamp\":\""), let at = iso.date(from: String(l[t.upperBound...].prefix(24))) else { continue }
                func n(_ k: String) -> Int { l.range(of: k).flatMap { Int(l[$0.upperBound...].prefix { $0.isNumber }) } ?? 0 }
                let id = l.range(of: "\"id\":\"msg_").map { String(l[$0.upperBound...].prefix { $0 != "\"" }) } ?? ""
                let total = n("\"input_tokens\":") + n("\"output_tokens\":")
                if total > (best[id]?.1 ?? -1) { best[id] = (at, total) }
            }
        }
        var five = 0, week = 0
        for v in best.values where v.0 > now.addingTimeInterval(-7 * 86400) { week += v.1; if v.0 > now.addingTimeInterval(-5 * 3600) { five += v.1 } }
        return (five, week)
    }

    static func run(_ check: (String, Bool) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = dir.appendingPathComponent("projects/-Users-x-proj")
        try? FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let now = Date()
        // 6 files, 3000 lines each, some big (padding), a message repeated (streamed twice: counted once, the larger total).
        var big = 0
        for f in 0..<6 {
            var text = ""
            for i in 0..<3000 {
                let at = now.addingTimeInterval(-Double((f * 3000 + i) * 60))               // spread over ~12 days
                text += line("f\(f)i\(i)", at, input: 3 + i % 7, output: 10 + i % 50, pad: i % 500 == 0 ? 20_000 : 40)
                if i % 3 == 0 { text += #"{"type":"user","timestamp":"x","message":"no tokens here"}"# + "\n" }
            }
            text += line("f\(f)i5", now.addingTimeInterval(-Double((f * 3000 + 5) * 60)), input: 3, output: 5000)   // the same message, final count
            big += text.utf8.count
            try? text.write(to: proj.appendingPathComponent("s\(f).jsonl"), atomically: true, encoding: .utf8)
        }
        let r = ClaudeUsageReader(root: dir.appendingPathComponent("projects"))
        let started = Date()
        let first = r.refresh(now: now, budget: 30)
        let ref = reference(dir, now: now)
        check("usage: the incremental reader agrees with a full parse (5 h \(first.five) = \(ref.0), 7 d \(first.week) = \(ref.1)) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s",
              first.five == ref.0 && first.week == ref.1 && !first.partial && first.week > 0)
        // Append to one file (one line half written): a second refresh reads only what was added, and counts it.
        let f0 = proj.appendingPathComponent("s0.jsonl")
        let added = line("new1", now.addingTimeInterval(-30), input: 100, output: 200) + line("new2", now.addingTimeInterval(-20), input: 1, output: 2)
        let half = String(line("new3", now.addingTimeInterval(-10), input: 1000, output: 1000).dropLast(30))
        if let h = try? FileHandle(forWritingTo: f0) { _ = try? h.seekToEnd(); h.write(Data((added + half).utf8)); try? h.close() }
        let second = r.refresh(now: now, budget: 30)
        check("usage: a second refresh reads only the appended bytes (\(r.bytesRead) of \(big + (added + half).utf8.count))",
              r.bytesRead == UInt64((added + half).utf8.count))
        check("usage: …and counts the new messages, not the half-written line", second.five == first.five + 303 && second.week == first.week + 303)
        if let h = try? FileHandle(forWritingTo: f0) { _ = try? h.seekToEnd(); h.write(Data(String(line("new3", now.addingTimeInterval(-10), input: 1000, output: 1000).suffix(30)).utf8)); try? h.close() }
        check("usage: the line is counted once it is complete", r.refresh(now: now, budget: 30).five == second.five + 2000)
        // A budget too short: the result says partial, and the next refresh finishes the job.
        let slow = ClaudeUsageReader(root: dir.appendingPathComponent("projects"))
        let cut = slow.refresh(now: now, budget: 0)
        var done = cut
        for _ in 0..<50 where done.partial { done = slow.refresh(now: now, budget: 0.001) }
        let full = r.refresh(now: now, budget: 30)
        check("usage: out of time it says partial (the old reader showed a cut total as final), then carries on to the full count",
              cut.partial && !done.partial && done.week == full.week && done.five == full.five)
        // A file replaced by a shorter one is read again from the start.
        try? (line("only", now.addingTimeInterval(-60), input: 1, output: 1)).write(to: f0, atomically: true, encoding: .utf8)
        let replaced = r.refresh(now: now, budget: 30)
        check("usage: a file cut short or replaced is read again", replaced.five < full.five && r.files.first(where: { $0.key.hasSuffix("/s0.jsonl") })?.value.offset == UInt64(line("only", now, input: 1, output: 1).utf8.count))
        var raw = Array("2026-10-07T10:05:09.250Z".utf8)
        let parsed = raw.withUnsafeMutableBytes { ClaudeUsageReader.parseISO(UnsafeRawBufferPointer($0), 0, $0.count) }
        check("usage: timestamps parsed without a formatter", parsed == ISO8601DateFormatter().date(from: "2026-10-07T10:05:09Z")?.addingTimeInterval(0.25))
        raw = Array("2026-10-07 10:05".utf8)
        check("usage: …and a malformed one is skipped", raw.withUnsafeMutableBytes { ClaudeUsageReader.parseISO(UnsafeRawBufferPointer($0), 0, $0.count) } == nil)

        // Codex: the newest session without limits doesn't hide an older one that has them; keys in any order.
        let codex = dir.appendingPathComponent("codex/2026/10/07")
        try? FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let older = #"{"timestamp":"2026-10-07T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"window_minutes":300,"used_percent":42.5,"resets_in_seconds":3600},"secondary":{"used_percent":7.0,"window_minutes":10080,"resets_at":1791000000}}}}"#
        try? (older + "\n").write(to: codex.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: codex.appendingPathComponent("a.jsonl").path)
        try? (#"{"timestamp":"2026-10-07T09:00:00.000Z","type":"session_meta"}"# + "\n").write(to: codex.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        let lim = CodexUsage.limits(root: dir.appendingPathComponent("codex"))
        let iso = ISO8601DateFormatter()
        check("usage: Codex limits come from the newest session that has them (\(lim.map { "\($0.minutes)m \($0.percent)%" }))",
              lim.count == 2 && lim[0].minutes == 300 && lim[0].percent == 42.5 && lim[0].resets == iso.date(from: "2026-10-07T09:00:00Z")
              && lim[1].minutes == 10080 && lim[1].resets == Date(timeIntervalSince1970: 1_791_000_000))
        check("usage: Codex with no limits anywhere: nothing", CodexUsage.limits(root: dir.appendingPathComponent("projects")).isEmpty)
    }
}
