// --calendar-test: the Calendar page's logic with fixtures (Sources/CalendarGrid.swift) and its watch with fake sources
// (Sources/IslandCalendar.swift). Never EventKit, never the user's calendar.

import AppKit
import Foundation

/// A source that is read off the main thread, counting what it is asked for.
private final class CountingSource: CalendarSource {
    let list: [CalEvent]
    private let lock = NSLock()
    private var asked: [DateInterval] = []
    var sync: Bool { false }
    init(_ list: [CalEvent]) { self.list = list }
    func events(in i: DateInterval) -> [CalEvent] {
        lock.lock(); asked.append(i); lock.unlock()
        return FixtureSource(list).events(in: i)
    }
    var calls: [DateInterval] { lock.lock(); defer { lock.unlock() }; return asked }
}

enum CalendarTests {
    static func cal(_ tz: String, first: Int = 2, minDays: Int = 4, locale: String = "en_GB") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.firstWeekday = first
        c.minimumDaysInFirstWeek = minDays
        c.locale = Locale(identifier: locale)
        c.firstWeekday = first                    // after the locale, which brings its own
        c.minimumDaysInFirstWeek = minDays
        return c
    }

    static func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    static func ev(_ id: String, _ a: String, _ b: String, allDay: Bool = false, declined: Bool = false, rgb: [Double] = [1, 0, 0]) -> CalEvent {
        CalEvent(id: id, title: id, start: iso(a), end: iso(b), allDay: allDay, rgb: rgb, declined: declined)
    }

    /// Prints PASS/FAIL lines; returns the number of failures.
    static func run() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  calendar: " + name); if !ok { failed += 1 } }
        let rome = cal("Europe/Rome"), romeSun = cal("Europe/Rome", first: 1, minDays: 1, locale: "en_US"), romeSat = cal("Europe/Rome", first: 7, minDays: 1)

        // MARK: days and months
        check("leap year: February 2028 has 29 days, 2027 has 28", CalDate.daysInMonth(y: 2028, m: 2, rome) == 29 && CalDate.daysInMonth(y: 2027, m: 2, rome) == 28)
        check("31 January + 1 month is 29 February in 2028, 28 February in 2027",
              CalDate(y: 2028, m: 1, d: 31).adding(months: 1, rome) == CalDate(y: 2028, m: 2, d: 29)
              && CalDate(y: 2027, m: 1, d: 31).adding(months: 1, rome) == CalDate(y: 2027, m: 2, d: 28))
        check("adding days crosses months and years", CalDate(y: 2026, m: 12, d: 30).adding(days: 3, rome) == CalDate(y: 2027, m: 1, d: 2)
              && CalDate(y: 2028, m: 3, d: 1).adding(days: -1, rome) == CalDate(y: 2028, m: 2, d: 29))
        check("days between, across the March DST change", CalDate(y: 2026, m: 3, d: 28).days(to: CalDate(y: 2026, m: 3, d: 31), rome) == 3)

        // MARK: DST (Europe/Rome: 29 March 2026 02:00 → 03:00, 25 October 2026 03:00 → 02:00)
        let spring = CalendarRange.day(CalDate(y: 2026, m: 3, d: 29)).interval(rome), fall = CalendarRange.day(CalDate(y: 2026, m: 10, d: 25)).interval(rome)
        check("DST: 29 March 2026 in Rome lasts 23 hours", spring.duration == 23 * 3600)
        check("DST: 25 October 2026 in Rome lasts 25 hours", fall.duration == 25 * 3600)
        let wkSpring = CalendarRange.week(containing: CalDate(y: 2026, m: 3, d: 29), rome)
        check("DST: the week holding 29 March 2026 is 23–29 March (Monday first), 7 days, 167 hours",
              wkSpring.first == CalDate(y: 2026, m: 3, d: 23) && wkSpring.days(rome).count == 7 && wkSpring.interval(rome).duration == 167 * 3600)
        check("DST: the week after starts on 30 March", CalendarRange.week(containing: CalDate(y: 2026, m: 3, d: 30), rome).first == CalDate(y: 2026, m: 3, d: 30))
        let skipped = ev("skipped", "2026-03-29T00:30:00Z", "2026-03-29T01:30:00Z")          // 01:30 → 03:30 local, over the missing hour
        let repeated = ev("repeated", "2026-10-25T00:30:00Z", "2026-10-25T01:30:00Z")        // 02:30 CEST → 02:30 CET, the hour twice
        let b1 = CalendarBuckets.bucket([skipped], range: wkSpring, rome)
        check("DST: an event over the skipped hour is on 29 March only", b1.keys.sorted() == [CalDate(y: 2026, m: 3, d: 29)])
        let b2 = CalendarBuckets.bucket([repeated], range: .week(containing: CalDate(y: 2026, m: 10, d: 25), rome), rome)
        check("DST: an event in the repeated hour is on 25 October only", b2.keys.sorted() == [CalDate(y: 2026, m: 10, d: 25)])
        let octGrid = MonthGrid.make(containing: CalDate(y: 2026, m: 10, d: 1), rome)
        check("DST: October 2026's grid has no day twice or missing (5 weeks, 35 different days)",
              octGrid.rows == 5 && Set(octGrid.weeks.joined()).count == 35)

        // MARK: month grids
        for (name, c) in [("Monday", rome), ("Sunday", romeSun), ("Saturday", romeSat)] {
            var ok = true, detail = ""
            for y in [2026, 2027, 2028] {
                for m in 1...12 {
                    let g = MonthGrid.make(containing: CalDate(y: y, m: m, d: 1), c)
                    let flat = Array(g.weeks.joined()), n = CalDate.daysInMonth(y: y, m: m, c)
                    let lead = (CalDate(y: y, m: m, d: 1).weekday(c) - c.firstWeekday + 7) % 7
                    let rows = (lead + n + 6) / 7
                    let good = g.weeks.allSatisfy { $0.count == 7 } && flat.first?.weekday(c) == c.firstWeekday && g.rows == rows
                        && (4...6).contains(g.rows) && flat.filter(g.inMonth).count == n && flat.firstIndex(of: CalDate(y: y, m: m, d: 1)) == lead
                        && zip(flat, flat.dropFirst()).allSatisfy { $0.adding(days: 1, c) == $1 }
                    if !good { ok = false; detail = "\(y)-\(m)" }
                }
            }
            check("grid, \(name) first: every month of 2026–2028 starts on that weekday, whole weeks, the month's days once \(detail)", ok)
        }
        // A month starting on each weekday (Monday first): the 1st sits in that column.
        var columns = Set<Int>()
        for m in 1...12 {
            let g = MonthGrid.make(containing: CalDate(y: 2026, m: m, d: 1), rome)
            if let i = Array(g.weeks.joined()).firstIndex(of: CalDate(y: 2026, m: m, d: 1)) {
                if i == (CalDate(y: 2026, m: m, d: 1).weekday(rome) + 5) % 7 { columns.insert(i) }
            }
        }
        let extra = MonthGrid.make(containing: CalDate(y: 2027, m: 2, d: 1), rome)        // 2027 completes the set if 2026 doesn't
        if let i = Array(extra.weeks.joined()).firstIndex(of: CalDate(y: 2027, m: 2, d: 1)) { columns.insert(i) }
        for m in 1...12 {
            let g = MonthGrid.make(containing: CalDate(y: 2027, m: m, d: 1), rome)
            if let i = Array(g.weeks.joined()).firstIndex(of: CalDate(y: 2027, m: m, d: 1)) { columns.insert(i) }
        }
        check("grid: months starting on each of the 7 weekdays put the 1st in columns 0…6", columns == Set(0...6))
        check("grid: February 2021 (28 days from a Monday) is 4 weeks with Monday first", MonthGrid.make(containing: CalDate(y: 2021, m: 2, d: 1), rome).rows == 4)
        check("grid: February 2026 (28 days from a Sunday) is 4 weeks with Sunday first, 5 with Monday first",
              MonthGrid.make(containing: CalDate(y: 2026, m: 2, d: 1), romeSun).rows == 4 && MonthGrid.make(containing: CalDate(y: 2026, m: 2, d: 1), rome).rows == 5)
        check("grid: March 2026 (31 days from a Sunday) is 6 weeks with Monday first", MonthGrid.make(containing: CalDate(y: 2026, m: 3, d: 1), rome).rows == 6)
        let feb28 = MonthGrid.make(containing: CalDate(y: 2028, m: 2, d: 10), rome)
        check("grid: February 2028 shows the 29th, inside the month, and 1 March outside it",
              feb28.weeks.joined().contains(CalDate(y: 2028, m: 2, d: 29)) && feb28.inMonth(CalDate(y: 2028, m: 2, d: 29)) && !feb28.inMonth(CalDate(y: 2028, m: 3, d: 1)))
        check("grid: weekday headers follow the first weekday (Mon…, Sun…, Sat…)",
              MonthGrid.weekdayHeaders(rome).first == "Mon" && MonthGrid.weekdayHeaders(romeSun).first == "Sun" && MonthGrid.weekdayHeaders(romeSat).first == "Sat"
              && MonthGrid.weekdayHeaders(rome).count == 7)
        let de = cal("Europe/Berlin", locale: "de_DE")
        check("grid: weekday headers in the app's language (Mo… in German)", MonthGrid.weekdayHeaders(de).first?.hasPrefix("Mo") == true)
        check("grid: ISO week numbers: 7 October 2026 is week 41, 1 January 2027 is in week 53",
              octGrid.weekNumbers[1] == 41 && MonthGrid.make(containing: CalDate(y: 2027, m: 1, d: 1), rome).weekNumbers.first == 53)
        check("grid: week numbers shown in Germany and Sweden, not in Italy or the US",
              MonthGrid.showsWeekNumbers(region: "DE") && MonthGrid.showsWeekNumbers(region: "se") && !MonthGrid.showsWeekNumbers(region: "IT") && !MonthGrid.showsWeekNumbers(region: nil))
        check("ranges: a month's range is its days, its grid is whole weeks",
              CalendarRange.month(containing: CalDate(y: 2026, m: 10, d: 7), rome) == CalendarRange(first: CalDate(y: 2026, m: 10, d: 1), count: 31)
              && CalendarRange.monthGrid(containing: CalDate(y: 2026, m: 10, d: 7), rome) == CalendarRange(first: CalDate(y: 2026, m: 9, d: 28), count: 35))
        check("ranges: the week of Wednesday 7 October 2026 starts Monday 5, Sunday 4, Saturday 3",
              CalendarRange.week(containing: CalDate(y: 2026, m: 10, d: 7), rome).first.d == 5
              && CalendarRange.week(containing: CalDate(y: 2026, m: 10, d: 7), romeSun).first.d == 4
              && CalendarRange.week(containing: CalDate(y: 2026, m: 10, d: 7), romeSat).first.d == 3)

        // MARK: buckets
        let wk = CalendarRange.week(containing: CalDate(y: 2026, m: 10, d: 7), rome)        // 5–11 October
        let multi = ev("multi", "2026-10-05T08:00:00Z", "2026-10-07T10:00:00Z")
        let toMidnight = ev("midnight", "2026-10-07T20:00:00Z", "2026-10-07T22:00:00Z")      // 22:00 → 00:00 local
        let overnight = ev("overnight", "2026-10-07T20:00:00Z", "2026-10-08T00:30:00Z")      // 22:00 → 02:30 local
        let allDayExact = ev("allday", "2026-10-06T22:00:00Z", "2026-10-07T22:00:00Z", allDay: true)       // midnight → midnight
        let allDayEK = ev("alldayEK", "2026-10-06T22:00:00Z", "2026-10-07T21:59:59Z", allDay: true)        // EventKit: ends 23:59:59
        let threeDays = ev("three", "2026-10-08T22:00:00Z", "2026-10-11T21:59:59Z", allDay: true)          // 9, 10, 11
        let long = ev("long", "2026-09-01T08:00:00Z", "2026-12-01T08:00:00Z")
        let zero = ev("zero", "2026-10-06T08:00:00Z", "2026-10-06T08:00:00Z")
        let b = CalendarBuckets.bucket([multi, toMidnight, overnight, allDayExact, allDayEK, threeDays, long, zero], range: wk, rome)
        func on(_ id: String) -> [Int] { b.keys.filter { k in b[k]!.contains { $0.id == id } }.map(\.d).sorted() }
        check("buckets: a 3-day timed event is on each of its days", on("multi") == [5, 6, 7])
        check("buckets: a timed event ending exactly at midnight isn't on the next day", on("midnight") == [7])
        check("buckets: an evening past midnight is on both days", on("overnight") == [7, 8])
        check("buckets: an all-day event from midnight to midnight is one day", on("allday") == [7])
        check("buckets: an all-day event ending 23:59:59 (EventKit) is one day", on("alldayEK") == [7])
        check("buckets: a 3-day all-day event is on its 3 days", on("three") == [9, 10, 11])
        check("buckets: an event longer than the range covers only the range's days", on("long") == [5, 6, 7, 8, 9, 10, 11])
        check("buckets: a zero-length event is on its day", on("zero") == [6])
        check("buckets: all-day events come first in a day, then by start", b[CalDate(y: 2026, m: 10, d: 7)]?.first?.allDay == true
              && b[CalDate(y: 2026, m: 10, d: 7)]!.filter { !$0.allDay }.map(\.start) == b[CalDate(y: 2026, m: 10, d: 7)]!.filter { !$0.allDay }.map(\.start).sorted())
        let late = ev("late", "2026-10-07T23:30:00Z", "2026-10-08T00:15:00Z")
        func dayOf(_ c: Calendar) -> [CalDate] { CalendarBuckets.bucket([late], range: CalendarRange(first: CalDate(y: 2026, m: 10, d: 5), count: 7), c).keys.sorted() }
        check("time zones: 23:30 UTC is on 8 October in Rome and Tokyo, 7 October in New York",
              dayOf(rome) == [CalDate(y: 2026, m: 10, d: 8)] && dayOf(cal("Asia/Tokyo")) == [CalDate(y: 2026, m: 10, d: 8)]
              && dayOf(cal("America/New_York")) == [CalDate(y: 2026, m: 10, d: 7)])
        let declined = ev("no", "2026-10-07T09:00:00Z", "2026-10-07T10:00:00Z", declined: true)
        let five = (0..<5).map { ev("e\($0)", "2026-10-07T0\($0):00:00Z", "2026-10-07T0\($0):30:00Z", rgb: [Double($0), 0, 0]) }
        let d5 = CalendarBuckets.dots(five + [declined])
        check("dots: at most 3, then the overflow count; declined events not counted", d5.colors.count == 3 && d5.more == 2
              && CalendarBuckets.count(five + [declined]) == 5 && CalendarBuckets.dots([declined]).colors.isEmpty)

        // MARK: navigation
        let today = CalDate(y: 2026, m: 10, d: 7)
        var n = CalendarNav(view: .month, selected: CalDate(y: 2026, m: 1, d: 31))
        n.step(1, today: today, rome)
        check("nav: next month from 31 January is 28 February", n.selected == CalDate(y: 2026, m: 2, d: 28))
        n = CalendarNav(view: .week, selected: today); n.step(-1, today: today, rome)
        check("nav: previous week is 7 days back", n.selected == CalDate(y: 2026, m: 9, d: 30))
        n = CalendarNav(view: .day, selected: today, event: "x"); n.step(1, today: today, rome)
        check("nav: next day, and the details close", n.selected == CalDate(y: 2026, m: 10, d: 8) && n.event == nil)
        n = CalendarNav(view: .month, selected: CalDate(y: 2026, m: 10, d: 31)); n.move(days: 1, today: today, rome)
        check("nav: → on the last day of the month goes to the 1st of the next", n.selected == CalDate(y: 2026, m: 11, d: 1))
        n.move(days: -7, today: today, rome)
        check("nav: ↑ goes a week back", n.selected == CalDate(y: 2026, m: 10, d: 25))
        n.goToday(today)
        check("nav: Today", n.selected == today)
        n = CalendarNav(view: .month, selected: today)
        for _ in 0..<200 { n.step(1, today: today, rome) }
        check("nav: clamped 10 years ahead", n.selected == CalDate(y: 2036, m: 10, d: 7))
        for _ in 0..<400 { n.step(-1, today: today, rome) }
        check("nav: clamped 10 years back", n.selected == CalDate(y: 2016, m: 10, d: 7))
        let a = CalendarNav(view: .month, selected: today)
        var s = a; s.select(CalDate(y: 2026, m: 10, d: 9), today: today, rome)
        var t = a; t.step(1, today: today, rome)
        var u = a; u.setView(.week)
        var w = a; w.setView(.week); var w2 = w; w2.setView(.month)
        var p = a; p.step(-1, today: today, rome)
        check("nav: a day in the same month only moves the selection", CalendarNav.change(from: a, to: s, rome) == .select)
        check("nav: next month slides forward, previous back", CalendarNav.change(from: a, to: t, rome) == .slide(1) && CalendarNav.change(from: a, to: p, rome) == .slide(-1))
        check("nav: month → week zooms in, week → month zooms out", CalendarNav.change(from: a, to: u, rome) == .zoom(1) && CalendarNav.change(from: w, to: w2, rome) == .zoom(-1))
        var cross = a; cross.select(CalDate(y: 2026, m: 11, d: 2), today: today, rome)
        check("nav: selecting a day of the next month (grid's trailing days) slides", CalendarNav.change(from: a, to: cross, rome) == .slide(1))
        check("nav: the displayed range comes from the view and the day",
              CalendarNav(view: .week, selected: today).range(rome) == .week(containing: today, rome) && a.range(rome) == .monthGrid(containing: today, rome))

        // MARK: keys
        check("keys: ←/→ change the day or week, move the day in the month",
              CalendarKeys.action(code: 123, chars: nil, view: .week, detailsOpen: false) == .step(-1)
              && CalendarKeys.action(code: 124, chars: nil, view: .day, detailsOpen: false) == .step(1)
              && CalendarKeys.action(code: 124, chars: nil, view: .month, detailsOpen: false) == .move(1))
        check("keys: ↑/↓ move a week in the month, nothing elsewhere",
              CalendarKeys.action(code: 126, chars: nil, view: .month, detailsOpen: false) == .move(-7)
              && CalendarKeys.action(code: 125, chars: nil, view: .week, detailsOpen: false) == nil)
        check("keys: Return opens the day from the month; Esc closes the details, else is the island's",
              CalendarKeys.action(code: 36, chars: nil, view: .month, detailsOpen: false) == .openDay
              && CalendarKeys.action(code: 53, chars: nil, view: .month, detailsOpen: true) == .closeDetails
              && CalendarKeys.action(code: 53, chars: nil, view: .month, detailsOpen: false) == nil)
        check("keys: T and Home go to today, Page Up/Down change the range",
              CalendarKeys.action(code: 17, chars: "t", view: .week, detailsOpen: false) == .today
              && CalendarKeys.action(code: 115, chars: nil, view: .day, detailsOpen: false) == .today
              && CalendarKeys.action(code: 121, chars: nil, view: .month, detailsOpen: false) == .step(1))

        // MARK: text
        check("video: the event's URL when it is a call", CalendarText.videoLink(url: URL(string: "https://meet.google.com/abc-defg-hij"), location: nil, notes: nil)?.host == "meet.google.com")
        check("video: found in the notes (Zoom subdomain)", CalendarText.videoLink(url: URL(string: "https://example.com/agenda"), location: "Room 4",
                                                                          notes: "Agenda…\nJoin: https://us02web.zoom.us/j/812345 thanks")?.absoluteString == "https://us02web.zoom.us/j/812345")
        check("video: only http(s) links (no custom schemes from an invitation), no look-alike hosts",
              CalendarText.videoLink(url: URL(string: "zoommtg://zoom.us/join?confno=1"), location: nil, notes: "javascript:alert(1) https://zoom.us.evil.com/x") == nil)
        check("notes: tags and blank lines collapsed, cut on a word",
              CalendarText.snippet("<p>Hello</p>\n\n  world   again", max: 140) == "Hello world again"
              && CalendarText.snippet(String(repeating: "word ", count: 60), max: 20) == "word word word word…" && CalendarText.snippet("  \n ") == nil)
        check("open in Calendar: Calendar's own event link, none without an identifier",
              CalendarWatch.calendarURL(CalEvent(id: "x", title: "", start: Date(), end: Date(), allDay: false, openID: "AB-12"))?.absoluteString == "ical://ekevent/AB-12?method=show&options=more"
              && CalendarWatch.calendarURL(CalEvent(id: "x", title: "", start: Date(), end: Date(), allDay: false)) == nil)
        check("the page's calendar keeps the Mac's first weekday whatever the app's language",
              CalendarWatch.macCalendar().firstWeekday == Calendar.autoupdatingCurrent.firstWeekday)

        // MARK: the watch (fixture source, read on the main thread)
        var said: [String] = []
        let post = A11y.post
        A11y.post = { said.append($0) }
        defer { A11y.post = post }
        let watch = CalendarWatch()
        watch.useFixture(CalendarFixture.events(rome), today: CalendarFixture.today, calendar: rome)
        let todays = watch.byDay[CalendarFixture.today] ?? []
        check("watch: today's fixture events are there (all-day release and conference first)", todays.count == 6 && todays.prefix(2).allSatisfy(\.allDay))
        check("watch: today's count leaves out the declined meeting", CalendarBuckets.count(todays) == 5)
        watch.setView(.month)
        check("watch: the month view has the whole grid's events (the conference on 4 days)",
              (6...9).allSatisfy { d in watch.byDay[CalDate(y: 2026, m: 10, d: d)]?.contains { $0.title.hasPrefix("Milano") } == true })
        check("watch: changing view is announced", said.last?.hasPrefix(L("Month view") + ", ") == true)
        let tok = watch.motion.token
        for _ in 0..<5 { watch.step(1) }
        for _ in 0..<5 { watch.step(-1) }
        check("watch: 10 quick taps end on the month they should, each one a new transition, the events of that month shown",
              watch.nav.selected == CalendarFixture.today && watch.motion.token == tok &+ 10 && watch.motion.change == .slide(-1)
              && watch.byDay[CalendarFixture.today]?.count == 6)
        watch.select(CalDate(y: 2026, m: 10, d: 10))
        check("watch: selecting a day in the month moves the selection only", watch.motion.token == tok &+ 10 && watch.nav.selected.d == 10)
        watch.perform(.openDay)
        check("watch: Return opens that day in the Day view (a zoom in)", watch.nav.view == .day && watch.motion.change == .zoom(1))
        watch.goToday()
        check("watch: Today goes back to today and pulses", watch.nav.selected == CalendarFixture.today && watch.pulse == 1)
        watch.open(todays.first { $0.title == "Stand-up" })
        check("watch: an event's details", watch.details?.videoLink?.host == "meet.google.com" && watch.details?.attendees == 6)
        watch.perform(.closeDetails)
        check("watch: Esc closes them", watch.details == nil)
        watch.setView(.week)
        check("watch: the week's title and count text", !watch.title().isEmpty && CalendarWatch.countText(3).contains("3"))
        check("watch: the day's label for VoiceOver says the date and how many events",
              watch.dayLabel(CalendarFixture.today).contains(String(format: L("%d events"), 5)))

        // MARK: the watch with a source read off the main thread: cache, prefetch, invalidation
        let src = CountingSource(CalendarFixture.events(rome))
        let w3 = CalendarWatch()
        w3.calendarOverride = rome
        let t9 = CalendarFixture.today.noon(rome)
        w3.now = { t9 }
        w3.useSource(src, today: CalendarFixture.today)
        func settle() { let end = Date().addingTimeInterval(2); while Date() < end && (w3.byDay.isEmpty || w3.pending > 0) { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        settle()
        check("async: the visible week arrives from the background queue", (w3.byDay[CalendarFixture.today]?.count ?? 0) == 6)
        let first = src.calls.count
        check("async: the week, the next two weeks and the weeks either side are fetched (4 ranges)", first == 4 && w3.cachedRanges == 4)
        w3.step(1)                     // day view: the next day is in the same cached week
        w3.setView(.week); w3.step(1)  // the next week was prefetched
        settle()
        check("async: moving to a prefetched week reads nothing new for it", !src.calls.dropFirst(first).contains(CalendarRange.week(containing: CalendarFixture.today.adding(days: 8, rome), rome).interval(rome)))
        let before = src.calls.count
        w3.invalidate(dayChanged: false)
        settle()
        check("async: a change in the calendars (EKEventStoreChanged) fetches the shown range again", src.calls.count > before && (w3.byDay.values.joined().count > 0))
        return failed
    }
}
