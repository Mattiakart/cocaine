// The island's Calendar page: Day, Week and Month views, event details, and its CalendarWatch (EventKit, cached per range,
// fetched off the main thread). The pure logic (grid, ranges, buckets, navigation, keys) is in Sources/CalendarGrid.swift.

import AppKit
import EventKit
import SwiftUI

// MARK: - Where events come from

/// Events in an interval. EventKit in the app; fixed sample events in renders and tests (never the user's calendar there).
protocol CalendarSource: AnyObject {
    /// Called on the watch's queue (EventKit may take a while with many calendars); `sync` sources are read on the main thread.
    func events(in interval: DateInterval) -> [CalEvent]
    var sync: Bool { get }
}

final class EventKitSource: CalendarSource {
    let store = EKEventStore()
    var sync: Bool { false }

    func events(in interval: DateInterval) -> [CalEvent] {
        let p = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: p).map(Self.make)          // recurring events come expanded, one per occurrence
    }

    static func make(_ e: EKEvent) -> CalEvent {
        let start: Date = e.startDate ?? Date(), end: Date = e.endDate ?? start
        let c = (e.calendar?.color ?? .systemBlue).usingColorSpace(.sRGB) ?? .systemBlue
        let me = e.attendees?.first { $0.isCurrentUser }
        func text(_ s: String?) -> String? { s.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        let base = e.eventIdentifier ?? e.calendarItemIdentifier
        return CalEvent(id: base + "@" + String(Int(start.timeIntervalSince1970)), title: e.title ?? "", start: start, end: end, allDay: e.isAllDay,
                        calendar: e.calendar?.title ?? "", rgb: [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)],
                        location: text(e.location), notes: e.hasNotes ? text(e.notes) : nil, url: e.url, organizer: text(e.organizer?.name),
                        attendees: e.attendees?.count ?? 0, declined: me?.participantStatus == .declined, openID: e.calendarItemIdentifier)
    }
}

/// The sample week the renders and tests draw: a busy "today", an all-day release, a declined meeting, a conference over four
/// days, an evening that runs past midnight, a crowded Friday (more than three dots), a long title.
final class FixtureSource: CalendarSource {
    let list: [CalEvent]
    var sync: Bool { true }
    init(_ list: [CalEvent]) { self.list = list }
    func events(in interval: DateInterval) -> [CalEvent] { list.filter { $0.end > interval.start && $0.start < interval.end || ($0.start == $0.end && interval.contains($0.start)) } }
}

enum CalendarFixture {
    static let today = CalDate(y: 2026, m: 10, d: 7)

    static func events(today t: CalDate = today, _ cal: Calendar) -> [CalEvent] {
        func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(byAdding: DateComponents(hour: h, minute: m), to: t.adding(days: day, cal).start(cal)) ?? Date() }
        func allDay(_ day: Int, _ days: Int) -> (Date, Date) { (t.adding(days: day, cal).start(cal), t.adding(days: day + days, cal).start(cal).addingTimeInterval(-1)) }
        let work = [0.26, 0.55, 0.98], home = [0.30, 0.78, 0.40], team = [0.69, 0.42, 0.95], ship = [1.0, 0.62, 0.20], trip = [0.95, 0.33, 0.36]
        var n = 0
        func ev(_ title: String, _ s: Date, _ e: Date, all: Bool = false, _ rgb: [Double], cal name: String, loc: String? = nil, notes: String? = nil,
                url: String? = nil, org: String? = nil, people: Int = 0, declined: Bool = false) -> CalEvent {
            n += 1
            return CalEvent(id: "fixture-\(n)", title: title, start: s, end: e, allDay: all, calendar: name, rgb: rgb, location: loc, notes: notes,
                            url: url.flatMap(URL.init(string:)), organizer: org, attendees: people, declined: declined, openID: nil)
        }
        let rel = allDay(0, 1), conf = allDay(-1, 4), holiday = allDay(9, 1)
        return [
            ev("Release 2.6", rel.0, rel.1, all: true, ship, cal: "Cocaine"),
            ev("Stand-up", at(0, 9, 30), at(0, 9, 45), work, cal: "Work", url: "https://meet.google.com/abc-defg-hij", org: "Giulia Rossi", people: 6),
            ev("Budget sync", at(0, 11), at(0, 12), work, cal: "Work", org: "Finance", people: 9, declined: true),
            ev("Lunch with Marco", at(0, 13), at(0, 14), home, cal: "Personal", loc: "Trattoria da Enzo, Via dei Vascellari 29, Roma"),
            ev("Design review: island calendar views", at(0, 16), at(0, 17, 30), team, cal: "Team",
               notes: "Review the Day, Week and Month views and the motion.\n\nJoin: https://us02web.zoom.us/j/81234567890 — bring the renders in it, en, de and ja.",
               org: "Mattia", people: 4),
            ev("Milano Design Conference", conf.0, conf.1, all: true, trip, cal: "Travel", loc: "Milano"),
            ev("Gym", at(1, 7, 30), at(1, 8, 30), home, cal: "Personal"),
            ev("Dentist", at(2, 15), at(2, 15, 45), home, cal: "Personal", loc: "Studio Bianchi"),
            ev("Quarterly planning with the whole product and engineering team", at(2, 10), at(2, 12), work, cal: "Work", people: 23),
            ev("Concert", at(3, 21), at(4, 1, 30), home, cal: "Personal", loc: "Auditorium"),
            ev("1:1 Anna", at(3, 9), at(3, 9, 30), work, cal: "Work", url: "https://teams.microsoft.com/l/meetup-join/19%3a", people: 2),
            ev("Demo prep", at(3, 11), at(3, 12), team, cal: "Team"),
            ev("Customer call", at(3, 14), at(3, 15), work, cal: "Work", people: 5),
            ev("Retro", at(3, 16), at(3, 17), team, cal: "Team"),
            ev("Flight to Berlin", at(6, 7, 10), at(6, 9, 5), trip, cal: "Travel", loc: "FCO → BER"),
            ev("Holiday", holiday.0, holiday.1, all: true, ship, cal: "Holidays"),
            ev("Board meeting", at(13, 10), at(13, 12), work, cal: "Work", people: 8),
            ev("Dinner", at(-5, 20), at(-5, 22), home, cal: "Personal"),
            ev("Haircut", at(-2, 18), at(-2, 18, 30), home, cal: "Personal"),
            ev("Workshop", at(20, 9), at(20, 17), team, cal: "Team"),
        ]
    }
}

// MARK: - The watch: access, the shown range's events, the cache

/// The page's state and data: the authorization, the navigation (one source of truth: what is shown is worked out from it), the
/// shown range's events per day, a cache per range with the adjacent ranges prefetched, and the page's keys.
final class CalendarWatch: ObservableObject {
    @Published var access = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published var asked = EKEventStore.authorizationStatus(for: .event) != .notDetermined
    @Published private(set) var nav: CalendarNav
    /// The shown range's events, per day (declined ones included, dimmed by the views).
    @Published private(set) var byDay: [CalDate: [CalEvent]] = [:]
    /// The next two weeks from now: the Day view of an empty today lists them.
    @Published private(set) var upcoming: [CalEvent] = []
    /// Bumped on every range or view change, with how it changed: the page's slide/zoom keyframes play on it.
    @Published private(set) var motion = CalendarMotion.Trigger()
    /// Bumped by Today: the today mark pulses once.
    @Published private(set) var pulse = 0

    /// Tests and renders: a fixed clock, calendar and source.
    var now: () -> Date = { Date() }
    var calendarOverride: Calendar?
    private var source: CalendarSource?
    private var injected = false                      // a fixture or a test's source: never EventKit
    private var cache: [DateInterval: [CalEvent]] = [:]
    private var cacheOrder: [DateInterval] = []
    private var inFlight: Set<DateInterval> = []
    private var generation = 0
    private let queue = DispatchQueue(label: "local.cocaine.calendar", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    static let cacheSize = 12

    /// While the page is on screen, and the window it is in: the page's keys only apply then and there.
    var pageVisible = false
    weak var pageWindow: NSWindow?

    init() {
        nav = CalendarNav(selected: CalDate(Date(), CalendarWatch.macCalendar()))
        let c = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            observers.append(c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.invalidate(dayChanged: true) })
        }
        // The page's keys go first (this watch is made with the island's model, before the island's own key monitor: local
        // monitors are asked in the order they were added), and only while the page is shown in a window with the keyboard.
        if !AppDefaults.isolated { installKeys() }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// The Mac's calendar in the app's language: weekday and month names follow the app, the first weekday, the week-number
    /// rule and the time zone stay the Mac's (setting a locale alone would bring that locale's first weekday).
    static func macCalendar() -> Calendar {
        let mac = Calendar.autoupdatingCurrent
        var c = Calendar(identifier: .gregorian)
        c.locale = Language.locale
        c.firstWeekday = mac.firstWeekday
        c.minimumDaysInFirstWeek = mac.minimumDaysInFirstWeek
        c.timeZone = .autoupdatingCurrent
        return c
    }

    var cal: Calendar { calendarOverride ?? Self.macCalendar() }
    var today: CalDate { CalDate(now(), cal) }
    var range: CalendarRange { nav.range(cal) }
    var details: CalEvent? { nav.event.flatMap { id in byDay.values.lazy.flatMap { $0 }.first { $0.id == id } } }

    // MARK: access

    /// Reads the authorization and loads what is shown (called when the page appears).
    func refresh() {
        if injected { load(); return }
        if AppDefaults.isolated { access = false; asked = false; return }      // tests and renders never read the user's calendar
        let st = EKEventStore.authorizationStatus(for: .event)
        let a = st == .fullAccess, ak = st != .notDetermined
        if access != a { access = a }
        if asked != ak { asked = ak }
        guard access else { return }
        if source == nil {                                       // made when first read: connecting to Calendar takes a moment,
            let s = EventKitSource()                             // and a store made before the permission sees no events
            source = s
            observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: s.store, queue: .main) { [weak self] _ in
                self?.invalidate(dayChanged: false)
            })
        }
        load()
    }

    func requestAccess() {
        Permissions.request(.calendar) { [weak self] in self?.asked = true; self?.refresh() }
    }

    /// Renders and tests: these events, this "today", this access (nil: granted), never EventKit.
    func useFixture(_ list: [CalEvent], today: CalDate, calendar: Calendar, access: EKAuthorizationStatus? = nil) {
        calendarOverride = calendar
        source = FixtureSource(list); injected = true
        let t = today.noon(calendar).addingTimeInterval(-2.5 * 3600)          // 09:30 on the fixture's day
        now = { t }
        let st = access ?? .fullAccess
        self.access = st == .fullAccess; asked = st != .notDetermined
        cache = [:]; cacheOrder = []
        nav = CalendarNav(view: nav.view, selected: today)
        load()
    }

    /// Tests: events from `s` (read on the background queue unless it is `sync`), access granted.
    func useSource(_ s: CalendarSource, today: CalDate) {
        source = s; injected = true
        access = true; asked = true
        cache = [:]; cacheOrder = []
        nav = CalendarNav(selected: today)
        load()
    }

    /// Fetches on their way (tests wait for them).
    var pending: Int { inFlight.count }

    // MARK: navigation (every change goes through apply)

    func setView(_ v: CalView) { apply { $0.setView(v) } }
    func step(_ n: Int) { apply { [today, cal] in $0.step(n, today: today, cal) } }
    func move(days n: Int) { apply { [today, cal] in $0.move(days: n, today: today, cal) } }
    func select(_ d: CalDate) { apply { [today, cal] in $0.select(d, today: today, cal) } }
    func open(_ e: CalEvent?) { apply { $0.open(event: e?.id) } }
    func goToday() {
        apply { [today] in $0.goToday(today) }
        pulse &+= 1
    }
    /// A day of the week or month, opened in the Day view.
    func openDay(_ d: CalDate) { apply { [today, cal] in $0.select(d, today: today, cal); $0.setView(.day) } }

    func apply(_ f: (inout CalendarNav) -> Void) {
        var n = nav
        f(&n)
        let change = CalendarNav.change(from: nav, to: n, cal)
        guard change != .none else { return }
        let detailsChanged = n.event != nav.event
        switch change {
        case .slide, .zoom:
            // The new range is drawn at once (no animation in this transaction: nothing is left half-way between two ranges);
            // the keyframes on the trigger carry it in. A tap during them restarts them from where the content is.
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { nav = n; motion = CalendarMotion.Trigger(token: motion.token &+ 1, change: change) }
            load()
            announceRange()
        default:
            withAnimation(detailsChanged ? CalendarMotion.details : CalendarMotion.select) { nav = n }
            if !detailsChanged { A11y.announce(dayLabel(n.selected)) }
        }
    }

    // MARK: data

    /// What is fetched for a view: the week for Day and Week (so moving between them reuses it), the month's grid for Month.
    func fetchRange(_ v: CalView, _ d: CalDate) -> CalendarRange {
        v == .month ? .monthGrid(containing: d, cal) : .week(containing: d, cal)
    }

    private func load() {
        guard access, source != nil else { byDay = [:]; return }
        let c = cal, r = fetchRange(nav.view, nav.selected)
        request(r.interval(c)) { [weak self] list in
            guard let self, self.fetchRange(self.nav.view, self.nav.selected) == r else { return }
            self.byDay = CalendarBuckets.bucket(list, range: self.nav.range(c), c)
        }
        // Today and the next two weeks, for the Day view of an empty today.
        let t = today, upto = CalendarRange(first: t, count: 14)
        request(upto.interval(c)) { [weak self] list in
            guard let self else { return }
            let now = self.now()
            self.upcoming = Array(list.filter { $0.end > now && !$0.declined }.sorted(by: CalendarBuckets.order).prefix(6))
        }
        // The ranges either side, so the next tap draws at once.
        let step: (CalDate, Int) -> CalDate = { d, k in self.nav.view == .month ? d.adding(months: k, c) : d.adding(days: 7 * k, c) }
        for k in [1, -1] { request(fetchRange(nav.view, step(nav.selected, k)).interval(c), done: nil) }
    }

    private func request(_ i: DateInterval, done: (([CalEvent]) -> Void)?) {
        if let hit = cache[i] { done?(hit); return }
        guard let source else { return }
        if source.sync { store(i, source.events(in: i)); done?(cache[i] ?? []); return }
        guard !inFlight.contains(i) else { return }       // its result reloads what is shown when it lands
        inFlight.insert(i)
        let gen = generation
        queue.async { [weak self] in
            let list = source.events(in: i)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(i)
                guard gen == self.generation else { self.load(); return }   // the calendar changed meanwhile: fetch again
                self.store(i, list)
                if let done { done(list) } else if i == self.fetchRange(self.nav.view, self.nav.selected).interval(self.cal) { self.load() }
            }
        }
    }

    private func store(_ i: DateInterval, _ list: [CalEvent]) {
        cache[i] = list
        cacheOrder.removeAll { $0 == i }
        cacheOrder.append(i)
        while cacheOrder.count > Self.cacheSize { cache[cacheOrder.removeFirst()] = nil }
    }

    /// The calendar's events changed (EKEventStoreChanged), or the day, time zone or region did: everything is fetched again.
    func invalidate(dayChanged: Bool) {
        generation &+= 1
        cache = [:]; cacheOrder = []
        objectWillChange.send()                                // "today" may have moved
        refresh()
    }

    var cachedRanges: Int { cache.count }

    // MARK: words

    var locale: Locale { Language.locale }

    func dayLabel(_ d: CalDate) -> String {
        let date = d.noon(cal).formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))
        return date + ", " + Self.countText(CalendarBuckets.count(byDay[d] ?? []))
    }

    static func countText(_ n: Int) -> String {
        n == 0 ? L("No events") : n == 1 ? L("1 event") : String(format: L("%d events"), n)
    }

    /// The header's title for what is shown: "October 2026", "5 – 11 Oct 2026".
    func title() -> String {
        let c = cal
        switch nav.view {
        case .day, .month: return CalendarFormat.capitalizedFirst(nav.selected.noon(c).formatted(.dateTime.month(.wide).year().locale(locale)), locale)
        case .week:
            let r = range
            let f = DateIntervalFormatter()
            f.locale = locale; f.calendar = c; f.timeZone = c.timeZone
            f.dateTemplate = "dMMMy"
            return f.string(from: r.first.noon(c), to: r.last(c).noon(c))
        }
    }

    /// "Week 41", where the region uses week numbers.
    func weekNumberText() -> String? {
        guard nav.view == .week, MonthGrid.showsWeekNumbers(region: Locale.current.region?.identifier) else { return nil }
        return String(format: L("Week %d"), cal.component(.weekOfYear, from: range.first.adding(days: 3, cal).noon(cal)))
    }

    static func viewName(_ v: CalView) -> String {
        switch v { case .day: return L("Day (calendar view)"); case .week: return L("Week (calendar view)"); case .month: return L("Month (calendar view)") }
    }

    private func announceRange() {
        let name = nav.view == .day ? L("Day view") : nav.view == .week ? L("Week view") : L("Month view")
        let what = nav.view == .day ? dayLabel(nav.selected) : title()
        A11y.announce(name + ", " + what)
    }

    // MARK: keys

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.handle(e) else { return e }
            return nil
        }
    }

    /// The page's keys (CalendarKeys) in the island's window, while the page is shown and nothing else wants them.
    func handle(_ e: NSEvent) -> Bool {
        guard pageVisible, access, let w = pageWindow, e.window === w, !DialogCenter.shared.isShowing(on: .island),
              !(w.firstResponder is NSTextView), e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let a = CalendarKeys.action(code: e.keyCode, chars: e.charactersIgnoringModifiers, view: nav.view, detailsOpen: nav.event != nil)
        else { return false }
        perform(a)
        return true
    }

    func perform(_ a: CalendarKeys.Action) {
        switch a {
        case .step(let n): step(n)
        case .move(let n): move(days: n)
        case .today: goToday()
        case .openDay: openDay(nav.selected)
        case .closeDetails: open(nil)
        }
    }

    // MARK: actions out of the island

    /// Calendar's own link to an event (no permission needed: it is a URL Calendar.app handles); nil without an identifier.
    static func calendarURL(_ e: CalEvent?) -> URL? {
        guard let id = e?.openID, !id.isEmpty, let enc = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-:"))) else { return nil }
        return URL(string: "ical://ekevent/\(enc)?method=show&options=more")
    }

    /// Opens the event in Calendar.app (on its date); without an identifier, opens Calendar.app itself. Picking a date in
    /// Calendar from outside needs AppleScript, i.e. the Automation permission: not asked for this.
    static func openInCalendar(_ e: CalEvent?) {
        if let u = calendarURL(e) { NSWorkspace.shared.open(u); return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// The render tool's flags (--calendar-view day|week|month, --calendar-details, --calendar-select YYYY-MM-DD,
    /// --calendar-access denied|notasked): always the fixture events, never the user's calendar.
    func renderSample(_ args: [String]) {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        func date(_ s: String?) -> CalDate? {
            guard let p = s?.split(separator: "-").compactMap({ Int($0) }), p.count == 3 else { return nil }
            return CalDate(y: p[0], m: p[1], d: p[2])
        }
        let c = Self.macCalendar(), t = date(value("--calendar-today")) ?? CalendarFixture.today
        let access: EKAuthorizationStatus? = value("--calendar-access") == "denied" ? .denied : value("--calendar-access") == "notasked" ? .notDetermined : nil
        useFixture(CalendarFixture.events(today: t, c), today: t, calendar: c, access: access)
        let v: CalView = value("--calendar-view") == "week" ? .week : value("--calendar-view") == "month" ? .month : .day
        var n = CalendarNav(view: v, selected: date(value("--calendar-select")) ?? t)
        if args.contains("--calendar-details") {
            let list = CalendarBuckets.bucket(CalendarFixture.events(today: t, c), range: .day(n.selected), c)[n.selected] ?? []
            n.event = (list.first { !$0.allDay && $0.notes != nil } ?? list.first { !$0.allDay } ?? list.first)?.id
        }
        nav = n
        load()
    }
}

/// Dates written for the page.
enum CalendarFormat {
    /// "ottobre 2026" → "Ottobre 2026"; only the first letter (a "de" in "7 de octubre" stays lower case).
    static func capitalizedFirst(_ s: String, _ loc: Locale) -> String {
        guard let f = s.first else { return s }
        return String(f).uppercased(with: loc) + s.dropFirst()
    }

    /// An event's time as a list row says it: "09:30 – 10:00", "All day", or with the dates when it spans days.
    static func time(_ e: CalEvent, on day: CalDate?, _ cal: Calendar, _ loc: Locale) -> String {
        let (a, b) = CalendarBuckets.span(e, cal)
        if e.allDay {
            if a == b { return L("All day") }
            return L("All day") + " · " + interval(a.noon(cal), b.noon(cal), "dMMM", cal, loc)
        }
        if a == b { return interval(e.start, e.end, "jmm", cal, loc) }
        return interval(e.start, e.end, "dMMMjmm", cal, loc)
    }

    /// The details' line: the date and the time range.
    static func longTime(_ e: CalEvent, _ cal: Calendar, _ loc: Locale) -> String {
        let (a, b) = CalendarBuckets.span(e, cal)
        if e.allDay {
            let d = a == b ? a.noon(cal).formatted(.dateTime.weekday(.wide).day().month(.wide).locale(loc))
                           : interval(a.noon(cal), b.noon(cal), "EEEdMMM", cal, loc)
            return d + " · " + L("All day")
        }
        return interval(e.start, e.end, "EEEdMMMjmm", cal, loc)
    }

    static func interval(_ a: Date, _ b: Date, _ template: String, _ cal: Calendar, _ loc: Locale) -> String {
        let f = DateIntervalFormatter()
        f.locale = loc; f.calendar = cal; f.timeZone = cal.timeZone
        f.dateTemplate = template
        return f.string(from: a, to: max(a, b))
    }
}

// MARK: - Motion (named helpers, so the app-wide motion pass can retune them in one place)

enum CalendarMotion {
    /// What the keyframes play on: a token that changes on every range or view change, and the kind of change.
    struct Trigger: Equatable {
        var token = 0
        var change: CalendarNav.Change = .none
    }

    /// The content's offset, scale and opacity while it arrives.
    struct Enter {
        var dx: CGFloat = 0
        var scale: CGFloat = 1
        var opacity: Double = 1
    }

    static let slideDistance: CGFloat = 26
    static let zoomScale: CGFloat = 0.92
    static let spring = Spring(response: 0.36, dampingRatio: 0.86)

    /// Moving the selection inside what is shown (a day, an event): quick, no bounce; a plain fade with Reduce Motion.
    static var select: Animation { Motion.reduce ? .easeInOut(duration: 0.12) : .spring(response: 0.26, dampingFraction: 0.86) }
    /// The event's details coming in and going.
    static var details: Animation { Motion.reduce ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.88) }

    /// Where the arriving content starts: slid in from the side it comes from (week/month/day forward = from the right), or
    /// zoomed in or out from the selected day; with Reduce Motion it only fades in.
    static func start(_ c: CalendarNav.Change) -> Enter {
        if Motion.reduce { return Enter(dx: 0, scale: 1, opacity: 0.35) }
        switch c {
        case .slide(let d): return Enter(dx: CGFloat(d) * slideDistance, scale: 1, opacity: 0)
        case .zoom(let d): return Enter(dx: 0, scale: d > 0 ? zoomScale : 1 / zoomScale, opacity: 0)
        default: return Enter()
        }
    }

    /// The pulse of the today mark: a ring that grows and fades once.
    struct Pulse { var scale: CGFloat = 1; var opacity: Double = 0 }
}

extension View {
    /// Carries the page's content in after a range or view change (see CalendarMotion.start); interruption-safe: a new trigger
    /// restarts the keyframes from the jump, so rapid taps never leave the content between two places.
    func calendarEnter(_ trigger: CalendarMotion.Trigger, anchor: UnitPoint) -> some View {
        keyframeAnimator(initialValue: CalendarMotion.Enter(), trigger: trigger) { content, v in
            content.offset(x: v.dx).scaleEffect(v.scale, anchor: anchor).opacity(v.opacity)
        } keyframes: { _ in
            let s = CalendarMotion.start(trigger.change)
            KeyframeTrack(\.dx) {
                MoveKeyframe(s.dx)
                SpringKeyframe(0, duration: 0.42, spring: CalendarMotion.spring)
            }
            KeyframeTrack(\.scale) {
                MoveKeyframe(s.scale)
                SpringKeyframe(1, duration: 0.42, spring: CalendarMotion.spring)
            }
            KeyframeTrack(\.opacity) {
                MoveKeyframe(s.opacity)
                LinearKeyframe(1, duration: Motion.reduce ? 0.15 : 0.2)
            }
        }
    }

    /// The today mark's single pulse when Today is pressed (nothing with Reduce Motion).
    func calendarPulse(_ trigger: Int, radius: CGFloat) -> some View {
        overlay {
            Color.clear.keyframeAnimator(initialValue: CalendarMotion.Pulse(), trigger: trigger) { content, v in
                content.overlay(RoundedRectangle(cornerRadius: radius).stroke(Island.accent, lineWidth: 2).scaleEffect(v.scale).opacity(v.opacity))
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    MoveKeyframe(1)
                    LinearKeyframe(Motion.reduce ? 1 : 1.35, duration: 0.5)
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(Motion.reduce ? 0 : 0.9)
                    LinearKeyframe(0, duration: 0.5)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - The page

extension IslandView {
    var calendarTab: some View { CalendarPage(watch: calendar) }
}

/// The page's layout: a header row (title, previous / Today / next, the view switch) and the view under it, sized to the open
/// island's fixed page (576 × 158 pt on a 32 pt notch): nothing scrolls the island; event lists scroll inside their column.
enum CalendarLayout {
    static let headerGap: CGFloat = Space.s
    static let switchWidth: CGFloat = 186
    static let sideWidth: CGFloat = 204
    static let weekNumberWidth: CGFloat = 20
    static let weekdayHeader: CGFloat = 14
    static let dayBlock: CGFloat = 128
}

struct CalendarPage: View {
    @ObservedObject var watch: CalendarWatch
    @ObservedObject private var display = DisplayOptions.shared

    var body: some View {
        Group {
            if !watch.access { accessView } else { content }
        }
        .background(CalendarWindowReader { [weak w = watch] win in w?.pageWindow = win })
        .onAppear {
            watch.pageVisible = true
            if Permissions.state(.calendar) == .notAsked && !AppDefaults.isolated { watch.requestAccess() }   // asked the first time the page is opened
            watch.refresh()
        }
        .onDisappear { watch.pageVisible = false }
    }

    /// Not asked yet: the button that asks. Refused: where to allow it, and the Settings button.
    private var accessView: some View {
        HStack(alignment: .top, spacing: Space.page) {
            CalendarDayBlock(watch: watch, day: watch.today)
            VStack(alignment: .leading, spacing: Space.m) {
                Text(L("Show your events here")).font(UI.value).foregroundStyle(UI.secondary)
                if watch.asked {
                    Text(L("Allow it in System Settings → Privacy & Security → Calendars")).font(UI.detail).foregroundStyle(UI.hint)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("Open Settings")) { Haptic.tap(.alignment); Permissions.openPane(.calendar) }
                        .buttonStyle(CocaineButtonStyle(kind: .primary, height: CTL.hDialog))
                } else {
                    Button(L("Allow Calendar")) { Haptic.tap(.alignment); watch.requestAccess() }
                        .buttonStyle(CocaineButtonStyle(kind: .primary, height: CTL.hDialog))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: CalendarLayout.headerGap) {
            header
            ZStack(alignment: .topLeading) {
                viewBody
                    .id(watch.nav.rangeKey(watch.cal))          // a new range is a new view: nothing animates from the old one
                    .calendarEnter(watch.motion, anchor: zoomAnchor)
                    .opacity(watch.details == nil ? 1 : 0)
                    .accessibilityHidden(watch.details != nil)
                if let e = watch.details {
                    CalendarDetails(watch: watch, event: e)
                        .transition(Motion.reduce ? .opacity : .opacity.combined(with: .offset(x: 18)))
                        .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
    }

    /// The selected day's place in the view: zooming between views grows from it and shrinks into it.
    private var zoomAnchor: UnitPoint {
        let c = watch.cal, r = watch.range, i = r.first.days(to: watch.nav.selected, c)
        switch watch.nav.view {
        case .day: return .topLeading
        case .week: return UnitPoint(x: (CGFloat(i) + 0.5) / 7, y: 0.3)
        case .month:
            let rows = max(1, r.count / 7)
            return UnitPoint(x: (CGFloat(i % 7) + 0.5) / 7 * 0.62, y: (CGFloat(i / 7) + 0.5) / CGFloat(rows))
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(watch.title()).font(UI.groupTitle).lineLimit(1).minimumScaleFactor(0.85)
                if let w = watch.weekNumberText() { Text(w).font(UI.detail).foregroundStyle(UI.hint).lineLimit(1) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .layoutPriority(1)
            Spacer(minLength: 0)
            HStack(spacing: Space.xxs) {
                navButton("chevron.left", previousName) { watch.step(-1) }
                Button(L("Today")) { Haptic.tap(.alignment); watch.goToday() }
                    .buttonStyle(CocaineButtonStyle(kind: .secondary))
                    .help(L("Today"))
                navButton("chevron.right", nextName) { watch.step(1) }
            }
            Segments(selection: Binding(get: { watch.nav.view }, set: { watch.setView($0) }), values: CalView.allCases,
                     name: L("Calendar view"), label: CalendarWatch.viewName)
                .frame(width: CalendarLayout.switchWidth)
        }
        .frame(height: CTL.h)
    }

    private var previousName: String {
        switch watch.nav.view { case .day: return L("Previous day"); case .week: return L("Previous week"); case .month: return L("Previous month") }
    }
    private var nextName: String {
        switch watch.nav.view { case .day: return L("Next day"); case .week: return L("Next week"); case .month: return L("Next month") }
    }

    private func navButton(_ symbol: String, _ name: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptic.tap(.alignment); action() } label: {
            Image(systemName: symbol).font(UI.chevron).frame(width: 12)
        }
        .buttonStyle(CocaineButtonStyle(kind: .plain))
        .help(name)
        .accessibilityLabel(name)
    }

    // MARK: the three views

    @ViewBuilder private var viewBody: some View {
        switch watch.nav.view {
        case .day: CalendarDayView(watch: watch)
        case .week: CalendarWeekView(watch: watch)
        case .month: CalendarMonthView(watch: watch)
        }
    }
}

/// The big date: weekday, day number, "Today" or the month.
struct CalendarDayBlock: View {
    @ObservedObject var watch: CalendarWatch
    let day: CalDate

    var body: some View {
        let loc = watch.locale, d = day.noon(watch.cal), isToday = day == watch.today
        VStack(alignment: .leading, spacing: 0) {
            Text(CalendarFormat.capitalizedFirst(d.formatted(.dateTime.weekday(.wide).locale(loc)), loc)).font(UI.buttonSecondary).foregroundStyle(Island.accent)
            Text(d.formatted(.dateTime.day().locale(loc))).font(UI.hero)
                .calendarPulse(isToday ? watch.pulse : 0, radius: 10)
            Text(isToday ? L("Today") : CalendarFormat.capitalizedFirst(d.formatted(.dateTime.month(.wide).year().locale(loc)), loc))
                .font(UI.value).foregroundStyle(UI.secondary)
        }
        .frame(width: CalendarLayout.dayBlock, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Day: the big date on the left, the day's events on the right (an empty today lists the next two weeks instead).
struct CalendarDayView: View {
    @ObservedObject var watch: CalendarWatch

    var body: some View {
        let day = watch.nav.selected, list = watch.byDay[day] ?? []
        HStack(alignment: .top, spacing: Space.page) {
            CalendarDayBlock(watch: watch, day: day)
            VStack(alignment: .leading, spacing: Space.s) {
                if list.isEmpty {
                    Text(L("No events")).font(UI.value).foregroundStyle(UI.hint)
                    if day == watch.today && !watch.upcoming.isEmpty {
                        Text(L("Coming up")).font(UI.section).foregroundStyle(UI.secondary)
                        FadingScroll { VStack(alignment: .leading, spacing: Space.s) {
                            ForEach(watch.upcoming) { e in CalendarEventRow(watch: watch, event: e, day: nil, withDate: true) }
                        } }
                    }
                } else {
                    FadingScroll { VStack(alignment: .leading, spacing: Space.s) {
                        ForEach(list) { e in CalendarEventRow(watch: watch, event: e, day: day, withDate: false) }
                    } }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One event in a list: the calendar's colour, the title, the time. A button: it opens the details.
struct CalendarEventRow: View {
    @ObservedObject var watch: CalendarWatch
    let event: CalEvent
    let day: CalDate?
    var withDate = false
    @StateObject private var hover = HoverState()

    var body: some View {
        let c = watch.cal, loc = watch.locale
        var when = CalendarFormat.time(event, on: day, c, loc)
        if withDate { when = event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(loc)) + " · " + when }
        let declined = event.declined
        return Button { Haptic.tap(.alignment); watch.open(event) } label: {
            HStack(spacing: Space.m) {
                Capsule().fill(CalendarColor.of(event)).frame(width: 3, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(UI.itemTitle).lineLimit(1).strikethrough(declined, color: UI.hint)
                    Text(declined ? when + " · " + L("Declined") : when).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if event.videoLink != nil { Image(systemName: "video.fill").font(UI.icon).foregroundStyle(UI.hint).accessibilityHidden(true) }
            }
            .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
            .background(RoundedRectangle(cornerRadius: CTL.innerRadius).fill(Color.white.opacity(hover.on ? 0.08 : 0)))
            .opacity(declined ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(event.title)
        .accessibilityValue(declined ? when + ", " + L("Declined") : when)
        .accessibilityHint(L("Shows the event's details"))
        .accessibilityAddTraits(.isButton)
    }
}

enum CalendarColor {
    static func of(_ e: CalEvent) -> Color {
        Color(.sRGB, red: e.rgb.count > 0 ? e.rgb[0] : 0.4, green: e.rgb.count > 1 ? e.rgb[1] : 0.64, blue: e.rgb.count > 2 ? e.rgb[2] : 1, opacity: 1)
    }
    static func rgb(_ v: [Double]) -> Color { Color(.sRGB, red: v.count > 0 ? v[0] : 0.4, green: v.count > 1 ? v[1] : 0.64, blue: v.count > 2 ? v[2] : 1, opacity: 1) }
}

/// Week: seven columns, each a day's header (a button: that day in the Day view) and its events as compact chips; today's
/// column is tinted and its date in the accent.
struct CalendarWeekView: View {
    @ObservedObject var watch: CalendarWatch

    var body: some View {
        let c = watch.cal, days = watch.range.days(c), today = watch.today
        HStack(alignment: .top, spacing: Space.xs) {
            ForEach(days, id: \.self) { d in
                let list = watch.byDay[d] ?? [], isToday = d == today
                VStack(alignment: .leading, spacing: Space.xs) {
                    dayHeader(d, isToday: isToday, count: CalendarBuckets.count(list))
                    if list.isEmpty {
                        Spacer(minLength: 0)
                    } else {
                        FadingScroll { VStack(alignment: .leading, spacing: Space.xxs) {
                            ForEach(list) { e in chip(e) }
                        } }
                    }
                }
                .padding(Space.xs)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: CTL.innerRadius).fill(isToday ? Island.accent.opacity(0.14) : Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: CTL.innerRadius).strokeBorder(isToday ? Island.accent.opacity(0.7) : .clear, lineWidth: 1))
                .calendarPulse(isToday ? watch.pulse : 0, radius: CTL.innerRadius)
            }
        }
    }

    private func dayHeader(_ d: CalDate, isToday: Bool, count: Int) -> some View {
        let loc = watch.locale, date = d.noon(watch.cal)
        return Button { Haptic.tap(.alignment); watch.openDay(d) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(CalendarFormat.capitalizedFirst(date.formatted(.dateTime.weekday(.abbreviated).locale(loc)), loc))
                    .font(UI.detail).foregroundStyle(isToday ? Island.accent : UI.secondary).lineLimit(1)
                Text(date.formatted(.dateTime.day().locale(loc))).font(UI.metric).foregroundStyle(isToday ? Island.accent : UI.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(watch.dayLabel(d))
        .accessibilityHint(L("Opens the day"))
    }

    private func chip(_ e: CalEvent) -> some View {
        let loc = watch.locale
        let time = e.allDay ? "" : e.start.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute().locale(loc))
        return Button { Haptic.tap(.alignment); watch.open(e) } label: {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1).fill(CalendarColor.of(e)).frame(width: 2.5, height: 12)
                (Text(time.isEmpty ? "" : time + " ").foregroundColor(UI.hint) + Text(e.title).foregroundColor(UI.primary))
                    .font(UI.detail).lineLimit(1).strikethrough(e.declined, color: UI.hint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2).frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(e.allDay ? CalendarColor.of(e).opacity(0.28) : .clear))
            .opacity(e.declined ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(e.title)
        .accessibilityLabel(e.title)
        .accessibilityValue(CalendarFormat.time(e, on: nil, watch.cal, loc) + (e.declined ? ", " + L("Declined") : ""))
        .accessibilityHint(L("Shows the event's details"))
    }
}

/// Month: the grid (weekday headers, days outside the month dimmed, today in the accent, up to three dots per day in the
/// calendars' colours and "+n"), and beside it the selected day's events.
struct CalendarMonthView: View {
    @ObservedObject var watch: CalendarWatch

    var body: some View {
        let c = watch.cal, grid = MonthGrid.make(containing: watch.nav.selected, c)
        let weeks = MonthGrid.showsWeekNumbers(region: Locale.current.region?.identifier)
        HStack(alignment: .top, spacing: Space.page) {
            VStack(spacing: Space.xxs) {
                HStack(spacing: 0) {
                    if weeks { Color.clear.frame(width: CalendarLayout.weekNumberWidth) }
                    ForEach(Array(MonthGrid.weekdayHeaders(c).enumerated()), id: \.offset) { _, s in
                        Text(s).font(UI.detail).foregroundStyle(UI.hint).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                    }
                }
                .frame(height: CalendarLayout.weekdayHeader)
                .accessibilityHidden(true)
                GeometryReader { r in
                    let cols = r.size.width - (weeks ? CalendarLayout.weekNumberWidth : 0), cw = cols / 7, rh = r.size.height / CGFloat(grid.rows)
                    let idx = grid.weeks.flatMap { $0 }.firstIndex(of: watch.nav.selected)
                    ZStack(alignment: .topLeading) {
                        if let i = idx {                    // one highlight that moves from day to day
                            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.14))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UI.boundary, lineWidth: 1))
                                .frame(width: cw - 2, height: rh - 1)
                                .offset(x: (weeks ? CalendarLayout.weekNumberWidth : 0) + CGFloat(i % 7) * cw + 1, y: CGFloat(i / 7) * rh + 0.5)
                                .accessibilityHidden(true)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(grid.weeks.enumerated()), id: \.offset) { wi, week in
                                HStack(spacing: 0) {
                                    if weeks {
                                        Text("\(grid.weekNumbers[wi])").font(UI.detail).foregroundStyle(UI.hint).monospacedDigit()
                                            .frame(width: CalendarLayout.weekNumberWidth, height: rh).accessibilityHidden(true)
                                    }
                                    ForEach(week, id: \.self) { d in cell(d, grid: grid, width: cw, height: rh) }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            side
                .frame(width: CalendarLayout.sideWidth)
        }
    }

    private func cell(_ d: CalDate, grid: MonthGrid, width: CGFloat, height: CGFloat) -> some View {
        let list = watch.byDay[d] ?? [], inMonth = grid.inMonth(d), isToday = d == watch.today, selected = d == watch.nav.selected
        let (dots, more) = CalendarBuckets.dots(list)
        return Button {
            Haptic.tap(.alignment)
            if selected { watch.openDay(d) } else { watch.select(d) }
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 1) {
                    Text("\(d.d)").font(.system(size: 11, weight: isToday || selected ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(isToday ? CTL.onAccentInk : inMonth ? UI.primary : UI.hint)
                        .frame(width: 22, height: 14)
                        .background(Capsule().fill(isToday ? Island.accent : .clear))
                        .calendarPulse(isToday ? watch.pulse : 0, radius: 7)
                    HStack(spacing: 2) {
                        ForEach(Array(dots.enumerated()), id: \.offset) { _, rgb in Circle().fill(CalendarColor.rgb(rgb)).frame(width: 3.5, height: 3.5) }
                    }
                    .frame(height: 3.5)
                    .opacity(inMonth ? 1 : 0.55)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if more > 0 {
                    Text("+\(more)").font(UI.detail).foregroundStyle(UI.hint).padding(.trailing, 1)
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(watch.dayLabel(d))
        .accessibilityValue(isToday ? L("Today") : "")
        .accessibilityHint(selected ? L("Opens the day") : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The selected day's events.
    private var side: some View {
        let d = watch.nav.selected, list = watch.byDay[d] ?? [], loc = watch.locale
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(CalendarFormat.capitalizedFirst(d.noon(watch.cal).formatted(.dateTime.weekday(.wide).day().month(.wide).locale(loc)), loc))
                    .font(UI.groupTitle).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Text("\(CalendarBuckets.count(list))").font(UI.metric).foregroundStyle(UI.hint).accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(watch.dayLabel(d))
            .accessibilityAddTraits(.isHeader)
            if list.isEmpty {
                Text(L("No events")).font(UI.value).foregroundStyle(UI.hint)
                Spacer(minLength: 0)
            } else {
                FadingScroll { VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(list) { e in CalendarEventRow(watch: watch, event: e, day: d) }
                } }
            }
        }
        .id(d)
        .transition(.opacity)
    }
}

/// An event's details, over the view: title, time, calendar, place, video call, people, a few words of the notes, and the
/// way to Calendar. ← Back (or Esc) returns to the view.
struct CalendarDetails: View {
    @ObservedObject var watch: CalendarWatch
    let event: CalEvent

    var body: some View {
        let c = watch.cal, loc = watch.locale, e = event
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Button { Haptic.tap(.alignment); watch.open(nil) } label: {
                    Image(systemName: "chevron.left").font(UI.chevron).frame(width: 12)
                }
                .buttonStyle(CocaineButtonStyle(kind: .plain))
                .help(L("Back")).accessibilityLabel(L("Back"))
                Circle().fill(CalendarColor.of(e)).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(e.title).font(UI.itemTitle).lineLimit(1).strikethrough(e.declined, color: UI.hint)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: Space.gutter) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    line("clock", CalendarFormat.longTime(e, c, loc))
                    if !e.calendar.isEmpty { line("calendar", e.calendar, tint: CalendarColor.of(e)) }
                    if let l = e.location { line("mappin.and.ellipse", l) }
                    if let p = people(e) { line("person.2", p) }
                    if e.declined { line("xmark.circle", L("Declined")) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: Space.s) {
                    if let s = CalendarText.snippet(e.notes) {
                        Text(s).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(L("Notes") + ": " + s)
                    }
                    if let u = e.videoLink {
                        Button { Haptic.tap(.alignment); NSWorkspace.shared.open(u) } label: {
                            HStack(spacing: Space.xs) {
                                Image(systemName: "video.fill").font(UI.icon)
                                Text(CalendarText.display(u)).font(CTL.link).lineLimit(1).truncationMode(.middle)
                            }
                            .foregroundStyle(CTL.accent).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(u.absoluteString)
                        .accessibilityLabel(L("Video call") + ", " + CalendarText.display(u))
                        .accessibilityAddTraits(.isLink)
                    }
                    Button(L("Open in Calendar")) { Haptic.tap(.alignment); CalendarWatch.openInCalendar(e) }
                        .buttonStyle(CocaineButtonStyle(kind: .secondary))
                }
                .frame(width: 228, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Event details"))
    }

    private func line(_ symbol: String, _ text: String, tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: symbol).font(UI.icon).foregroundStyle(tint ?? UI.hint).frame(width: UI.iconColumn).accessibilityHidden(true)
            Text(text).font(UI.value).foregroundStyle(UI.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    private func people(_ e: CalEvent) -> String? {
        var parts: [String] = []
        if let o = e.organizer { parts.append(String(format: L("Organiser: %@"), o)) }
        if e.attendees > 0 { parts.append(e.attendees == 1 ? L("1 attendee") : String(format: L("%d attendees"), e.attendees)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Hands the page's window to the watch (its keys apply only there).
private struct CalendarWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { let v = Probe(); v.found = found; return v }
    func updateNSView(_ v: NSView, context: Context) {}
    final class Probe: NSView {
        var found: (NSWindow?) -> Void = { _ in }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); found(window) }
    }
}
