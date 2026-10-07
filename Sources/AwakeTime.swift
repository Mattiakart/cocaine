// "Keep awake until a time": the one parser behind cocaine://on?until=…, the AppleScript `keep awake until`, and the panel's
// time row (the engine's `cocaine on until 18:30` does the same in zsh; tests/engine-test.zsh checks both agree).

import Foundation

/// A deadline given as a clock time: `18:30` (the next 18:30: today, or tomorrow once it has passed), `18:30 tomorrow`
/// (or `today`), `2026-10-07T18:30` (local) or a full ISO 8601 time with its zone (`2026-10-07T16:30:00Z`). Always in the
/// future and at most 24 hours away. Clock times go through the calendar, so a DST change in between is counted right; a
/// time the clocks skip that day (02:30 when they jump to 03:00) is counted as if the clocks had not jumped (02:30 → 03:30), like mktime and the engine.
enum UntilTime {
    static let maxAhead: TimeInterval = 24 * 3600

    private static func match(_ pattern: String, _ s: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }

    static func parse(_ raw: String, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let s = trimmed.lowercased()
        guard !s.isEmpty, s.count <= 40 else { return nil }
        var date: Date?
        if let m = match("([0-9]{1,2})[:.]([0-9]{2})(?:\\s+(today|tomorrow))?", s) {
            guard let h = Int(m[1] ?? ""), let mi = Int(m[2] ?? ""), (0...23).contains(h), (0...59).contains(mi) else { return nil }
            date = clock(h, mi, day: m[3], now: now, calendar: calendar)
        } else if let m = match("([0-9]{4})-([0-9]{2})-([0-9]{2})t([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?", s) {
            let n = m.map { $0.flatMap { Int($0) } }
            guard let y = n[1], let mo = n[2], (1...12).contains(mo), let d = n[3], (1...31).contains(d), let h = n[4], (0...23).contains(h),
                  let mi = n[5], (0...59).contains(mi) else { return nil }
            let sec = n[6] ?? 0
            guard (0...59).contains(sec) else { return nil }
            let c = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: sec)
            // Local time: refused when that day has no such date (31 April) or the clocks skip that minute (DST), not guessed.
            if let x = calendar.date(from: c), calendar.dateComponents([.year, .month, .day, .hour, .minute], from: x)
                == DateComponents(year: y, month: mo, day: d, hour: h, minute: mi) { date = x }
            else { return nil }
        } else if s.contains("t") {
            let iso = ISO8601DateFormatter()
            for f: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
                iso.formatOptions = f
                if let d = iso.date(from: trimmed.uppercased()) { date = d; break }
            }
        }
        guard let d = date, d > now, d.timeIntervalSince(now) <= maxAhead else { return nil }
        return d
    }

    /// The next `h:mi` on the wall clock: today if still ahead, else tomorrow (`day` forces one of the two).
    static func clock(_ h: Int, _ mi: Int, day: String?, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        func at(_ dayStart: Date) -> Date? {
            var c = calendar.dateComponents([.year, .month, .day], from: dayStart)
            c.hour = h; c.minute = mi; c.second = 0
            if let d = calendar.date(from: c), calendar.component(.hour, from: d) == h, calendar.component(.minute, from: d) == mi,
               calendar.isDate(d, inSameDayAs: dayStart) { return d }
            // A skipped time (the DST jump): the same minutes past the jump (02:30 → 03:30), as the engine computes it.
            return calendar.nextDate(after: dayStart, matching: DateComponents(hour: h, minute: mi), matchingPolicy: .nextTimePreservingSmallerComponents)
        }
        // Tomorrow from today's noon: right on the 23- and 25-hour days too.
        guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: today),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: noon).map(calendar.startOfDay) else { return nil }
        switch day {
        case "today": return at(today)
        case "tomorrow": return at(tomorrow)
        default:
            if let d = at(today), d > now { return d }
            return at(tomorrow)
        }
    }

    /// Minutes from now to `d`, rounded up (what the panel and `remaining minutes` show).
    static func minutesLeft(_ d: Date, now: Date) -> Int { max(0, Int((d.timeIntervalSince(now) / 60).rounded(.up))) }

    /// "18:30" for the engine and the links (24-hour, the given calendar's zone).
    static func hhmm(_ d: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
