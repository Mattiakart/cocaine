// The Calendar page's pure logic (no EventKit, no SwiftUI): days on the wall calendar, the day/week/month ranges, the month
// grid in any first weekday, events bucketed per day (all-day and multi-day ones on every day they cover), the navigation
// reducer (one source of truth for what is shown), the page's keys, and the bits of an event's details that are text
// (a video-call link, a notes snippet). --calendar-test (Sources/CalendarTests.swift) checks all of it with fixtures.

import Foundation

/// The page's three views, in zoom order (a day is inside a week, a week inside a month).
enum CalView: Int, CaseIterable, Hashable {
    case day = 0, week, month
}

/// A day on the wall calendar (year, month, day), whatever the time zone: the key events are bucketed by and the grid is made of.
struct CalDate: Hashable, Comparable, CustomStringConvertible {
    var y: Int, m: Int, d: Int

    init(y: Int, m: Int, d: Int) { self.y = y; self.m = m; self.d = d }

    /// The day `date` falls on in `cal`'s time zone.
    init(_ date: Date, _ cal: Calendar) {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(y: c.year ?? 1970, m: c.month ?? 1, d: c.day ?? 1)
    }

    static func < (a: CalDate, b: CalDate) -> Bool { (a.y, a.m, a.d) < (b.y, b.m, b.d) }
    var description: String { String(format: "%04d-%02d-%02d", y, m, d) }

    /// The first moment of the day (midnight; 01:00 on a day whose midnight a DST change skips).
    func start(_ cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d)) ?? Date(timeIntervalSince1970: 0)
    }

    /// Noon: a moment that exists on every day (DST changes happen at night), for adding days and reading the weekday.
    func noon(_ cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? start(cal)
    }

    func adding(days n: Int, _ cal: Calendar) -> CalDate {
        n == 0 ? self : CalDate(cal.date(byAdding: .day, value: n, to: noon(cal)) ?? noon(cal), cal)
    }

    /// The same day number `n` months away, clamped to that month's length (31 January + 1 month = 28 or 29 February).
    func adding(months n: Int, _ cal: Calendar) -> CalDate {
        n == 0 ? self : CalDate(cal.date(byAdding: .month, value: n, to: noon(cal)) ?? noon(cal), cal)
    }

    /// 1 = Sunday … 7 = Saturday (Calendar's numbering).
    func weekday(_ cal: Calendar) -> Int { cal.component(.weekday, from: noon(cal)) }

    /// Whole days from `self` to `other` (negative when `other` is earlier); DST-proof (counted between noons).
    func days(to other: CalDate, _ cal: Calendar) -> Int {
        cal.dateComponents([.day], from: noon(cal), to: other.noon(cal)).day ?? 0
    }

    var firstOfMonth: CalDate { CalDate(y: y, m: m, d: 1) }

    static func daysInMonth(y: Int, m: Int, _ cal: Calendar) -> Int {
        cal.range(of: .day, in: .month, for: CalDate(y: y, m: m, d: 1).noon(cal))?.count ?? 30
    }
}

/// A run of whole days: what a view shows (one day, a week, a month's grid) and what is fetched for it.
struct CalendarRange: Hashable {
    let first: CalDate
    let count: Int

    var isEmpty: Bool { count <= 0 }
    func last(_ cal: Calendar) -> CalDate { first.adding(days: max(0, count - 1), cal) }
    func days(_ cal: Calendar) -> [CalDate] {
        var out: [CalDate] = [], d = first
        for _ in 0..<max(0, count) { out.append(d); d = d.adding(days: 1, cal) }
        return out
    }
    func contains(_ d: CalDate, _ cal: Calendar) -> Bool { d >= first && d <= last(cal) }
    /// From the first day's midnight to the midnight after the last day (23, 24 or 25 hours a day across DST).
    func interval(_ cal: Calendar) -> DateInterval {
        let s = first.start(cal), e = first.adding(days: count, cal).start(cal)
        return DateInterval(start: s, end: max(s, e))
    }

    static func day(_ d: CalDate) -> CalendarRange { CalendarRange(first: d, count: 1) }

    /// The week holding `d`, starting on `cal.firstWeekday` (Monday, Sunday, Saturday… as the Mac is set).
    static func week(containing d: CalDate, _ cal: Calendar) -> CalendarRange {
        let back = (d.weekday(cal) - cal.firstWeekday + 7) % 7
        return CalendarRange(first: d.adding(days: -back, cal), count: 7)
    }

    /// The calendar month holding `d` (1st … last).
    static func month(containing d: CalDate, _ cal: Calendar) -> CalendarRange {
        CalendarRange(first: d.firstOfMonth, count: CalDate.daysInMonth(y: d.y, m: d.m, cal))
    }

    /// The month's grid: whole weeks from the one holding the 1st to the one holding the last day (4, 5 or 6 weeks).
    static func monthGrid(containing d: CalDate, _ cal: Calendar) -> CalendarRange {
        let m = month(containing: d, cal)
        let start = week(containing: m.first, cal).first
        let end = week(containing: m.last(cal), cal).last(cal)
        return CalendarRange(first: start, count: start.days(to: end, cal) + 1)
    }
}

/// A month laid out as the page draws it: weekday headers in the user's first weekday and the app's language, rows of 7 days,
/// days outside the month marked, week numbers where the region uses them.
struct MonthGrid: Equatable {
    let year: Int
    let month: Int
    let weeks: [[CalDate]]
    let weekNumbers: [Int]

    var rows: Int { weeks.count }
    func inMonth(_ d: CalDate) -> Bool { d.y == year && d.m == month }

    static func make(containing d: CalDate, _ cal: Calendar) -> MonthGrid {
        let r = CalendarRange.monthGrid(containing: d, cal)
        let days = r.days(cal)
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min(days.count, $0 + 7)]) }
        // The week's number is that of its 4th day when weeks start on Monday (ISO); otherwise the calendar's own rule.
        let nums = weeks.map { w in cal.component(.weekOfYear, from: w[min(w.count - 1, cal.firstWeekday == 2 ? 3 : 0)].noon(cal)) }
        return MonthGrid(year: d.y, month: d.m, weeks: weeks, weekNumbers: nums)
    }

    /// The weekday names in the order the grid's columns are, starting with `cal.firstWeekday`.
    static func weekdayHeaders(_ cal: Calendar, short: Bool = true) -> [String] {
        let all = short ? cal.shortStandaloneWeekdaySymbols : cal.standaloneWeekdaySymbols
        guard all.count == 7 else { return all }
        return (0..<7).map { all[(cal.firstWeekday - 1 + $0) % 7] }
    }

    /// Regions where people say "week 41": the grid shows a narrow week-number column there.
    static func showsWeekNumbers(region: String?) -> Bool {
        guard let r = region?.uppercased() else { return false }
        return ["SE", "NO", "DK", "FI", "IS", "DE", "AT", "CH", "NL", "BE", "LU", "PL", "CZ", "SK", "HU", "EE", "LV", "LT", "SI", "HR"].contains(r)
    }
}

/// One event (one occurrence of a recurring one: EventKit expands them), as the page uses it: plain values, made off the main
/// thread from an EKEvent or written by hand in the fixtures.
struct CalEvent: Identifiable, Equatable {
    var id: String                      // unique per occurrence: the event's identifier plus its start
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var calendar: String = ""
    var rgb: [Double] = [0.4, 0.64, 1.0]    // the calendar's colour (sRGB)
    var location: String? = nil
    var notes: String? = nil
    var url: URL? = nil
    var organizer: String? = nil
    var attendees: Int = 0
    var declined = false
    var openID: String? = nil           // EKEvent.calendarItemIdentifier, for Calendar's ical://ekevent/… link

    /// The video-call link to show, if any (the event's URL, its location, then its notes).
    var videoLink: URL? { CalendarText.videoLink(url: url, location: location, notes: notes) }
}

enum CalendarBuckets {
    /// The days an event covers: from its start's day to its end's day, a timed event ending exactly at midnight not counting
    /// the day it ends on (an all-day event from EventKit ends at 23:59:59 or at the next midnight: both are one day).
    static func span(_ e: CalEvent, _ cal: Calendar) -> (CalDate, CalDate) {
        let a = CalDate(e.start, cal)
        guard e.end > e.start else { return (a, a) }
        var b = CalDate(e.end, cal)
        if b > a && b.start(cal) == e.end { b = b.adding(days: -1, cal) }
        return (a, max(a, b))
    }

    /// Events per day of `range`, each day's list in page order: all-day first, then by start time, end, title.
    static func bucket(_ events: [CalEvent], range: CalendarRange, _ cal: Calendar) -> [CalDate: [CalEvent]] {
        var out: [CalDate: [CalEvent]] = [:]
        guard !range.isEmpty else { return out }
        let last = range.last(cal)
        for e in events {
            let (a, b) = span(e, cal)
            guard b >= range.first, a <= last else { continue }
            var d = max(a, range.first)
            let stop = min(b, last)
            while d <= stop { out[d, default: []].append(e); d = d.adding(days: 1, cal) }
        }
        for k in out.keys { out[k]?.sort(by: order) }
        return out
    }

    static func order(_ a: CalEvent, _ b: CalEvent) -> Bool {
        if a.allDay != b.allDay { return a.allDay }
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end < b.end }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    /// The day's count as the page says it ("3 events"): declined events are listed (dimmed) but don't count.
    static func count(_ list: [CalEvent]) -> Int { list.filter { !$0.declined }.count }

    /// The coloured dots of a grid cell: at most `max`, one per counted event, and how many more there are.
    static func dots(_ list: [CalEvent], max: Int = 3) -> (colors: [[Double]], more: Int) {
        let counted = list.filter { !$0.declined }
        return (counted.prefix(max).map(\.rgb), Swift.max(0, counted.count - max))
    }
}

/// What the page shows: the view and the day in focus. The displayed range is always worked out from these two (never kept
/// separately), so a run of quick taps can't leave a range and a title that disagree.
struct CalendarNav: Equatable {
    var view: CalView = .day
    var selected: CalDate
    var event: String? = nil            // the event whose details are open
    /// How far from today the page goes, either way.
    static let years = 10

    func range(_ cal: Calendar) -> CalendarRange {
        switch view {
        case .day: return .day(selected)
        case .week: return .week(containing: selected, cal)
        case .month: return .monthGrid(containing: selected, cal)
        }
    }

    /// What identifies the displayed range (a month's grid by its month, not by its first cell).
    func rangeKey(_ cal: Calendar) -> String {
        switch view {
        case .day: return "d\(selected)"
        case .week: return "w\(CalendarRange.week(containing: selected, cal).first)"
        case .month: return "m\(selected.y)-\(selected.m)"
        }
    }

    private static func clamp(_ d: CalDate, today: CalDate, _ cal: Calendar) -> CalDate {
        let lo = today.adding(months: -12 * years, cal), hi = today.adding(months: 12 * years, cal)
        return min(max(d, lo), hi)
    }

    /// The next (n = 1) or previous (n = -1) day, week or month; a month keeps the day number (clamped to its length).
    mutating func step(_ n: Int, today: CalDate, _ cal: Calendar) {
        switch view {
        case .day: selected = Self.clamp(selected.adding(days: n, cal), today: today, cal)
        case .week: selected = Self.clamp(selected.adding(days: 7 * n, cal), today: today, cal)
        case .month: selected = Self.clamp(selected.adding(months: n, cal), today: today, cal)
        }
        event = nil
    }

    /// The arrow keys in the month grid: ±1 day, ±7 days (into the next or previous month when it gets there).
    mutating func move(days n: Int, today: CalDate, _ cal: Calendar) {
        let to = Self.clamp(selected.adding(days: n, cal), today: today, cal)
        if to != selected { selected = to; event = nil }
    }

    mutating func goToday(_ today: CalDate) { selected = today; event = nil }

    mutating func select(_ d: CalDate, today: CalDate, _ cal: Calendar) {
        let to = Self.clamp(d, today: today, cal)
        if to != selected { selected = to; event = nil }
    }

    mutating func setView(_ v: CalView) { if v != view { view = v; event = nil } }

    mutating func open(event id: String?) { event = id }

    /// How the page moves from one state to the next: the displayed range slides (-1 back, 1 forward), the view zooms (1 in
    /// towards a day, -1 out towards the month), or only the selection moves inside what is shown.
    enum Change: Equatable { case none, select, slide(Int), zoom(Int) }

    static func change(from a: CalendarNav, to b: CalendarNav, _ cal: Calendar) -> Change {
        if a.view != b.view { return .zoom(b.view.rawValue < a.view.rawValue ? 1 : -1) }
        if a.rangeKey(cal) != b.rangeKey(cal) { return .slide(b.selected < a.selected ? -1 : 1) }
        return a == b ? .none : .select
    }
}

/// The page's keys (pure): what a key does in each view. The island's own keys (←/→ between tabs, Esc closes) apply when
/// this returns nil.
enum CalendarKeys {
    enum Action: Equatable { case step(Int), move(Int), today, openDay, closeDetails }

    static func action(code: UInt16, chars: String?, view: CalView, detailsOpen: Bool) -> Action? {
        switch code {
        case 53: return detailsOpen ? .closeDetails : nil                        // Esc: the details first, then the island
        case 123: return view == .month ? .move(-1) : .step(-1)                  // ←
        case 124: return view == .month ? .move(1) : .step(1)                    // →
        case 126: return view == .month ? .move(-7) : nil                        // ↑
        case 125: return view == .month ? .move(7) : nil                         // ↓
        case 116: return .step(-1)                                               // Page Up
        case 121: return .step(1)                                                // Page Down
        case 115: return .today                                                  // Home
        case 36, 76: return view == .month && !detailsOpen ? .openDay : nil      // Return: the day, in the Day view
        default: return chars?.lowercased() == "t" ? .today : nil
        }
    }
}

/// The text bits of an event's details.
enum CalendarText {
    /// Hosts of the video-call services whose links are shown as "Video call" (any https link in the event's own URL field
    /// also is, when it points to one of these).
    static let videoHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com",
                             "meet.jit.si", "facetime.apple.com", "chime.aws", "gotomeeting.com", "bluejeans.com", "skype.com"]

    static func isVideo(_ u: URL) -> Bool {
        guard let s = u.scheme?.lowercased(), s == "https" || s == "http", let h = u.host?.lowercased() else { return false }
        return videoHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// The first video-call link: the event's URL field, then any link in its location, then in its notes. Only http(s): a link
    /// from an invitation never opens anything but the browser.
    static func videoLink(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isVideo(url) { return url }
        for text in [location, notes].compactMap({ $0 }) {
            guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { break }
            for m in det.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let u = m.url, isVideo(u) { return u }
            }
        }
        return nil
    }

    /// The notes as one short paragraph: tags and runs of blank space collapsed, cut at `max` characters on a word.
    static func snippet(_ notes: String?, max: Int = 140) -> String? {
        guard var t = notes else { return nil }
        t = t.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        t = t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !t.isEmpty else { return nil }
        if t.count <= max { return t }
        let cut = t.prefix(max)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(word) + "…"
    }

    /// The link as written in the details: its host and path, without the scheme ("meet.google.com/abc-defg-hij").
    static func display(_ u: URL) -> String {
        var s = (u.host ?? "") + u.path
        if s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? u.absoluteString : s
    }
}
