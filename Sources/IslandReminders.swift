// Reminders in the island (EventKit): what is due today and overdue (or everything scheduled, or all), ticked off with one
// click (it stays ticked and struck through for a moment, so a slip can be undone, then leaves), a quick add with the list it
// goes to, which lists show, and the permission asked from inside the island. The "reminders" module goes on any screen; the
// Reminders screen holds it alone (hidden until shown in the screens editor). RemindersLogic is pure; RemindersSource is
// EventKit in the app and a fake in the tests and renders, so they never read the user's reminders.

import AppKit
import EventKit
import SwiftUI

struct ReminderList: Equatable, Identifiable {
    var id: String
    var title: String
    var color: [Double] = [0.4, 0.64, 1]      // r, g, b
    var swiftColor: Color { Color(red: color[0], green: color[1], blue: color[2]) }
}

struct ReminderItem: Equatable, Identifiable {
    var id: String
    var title: String
    var due: Date? = nil
    var allDay = true                       // a due day without a time
    var listID: String
    var priority = 0                        // EventKit: 1 high … 9 low, 0 none
}

enum ReminderAccess: Equatable { case notAsked, denied, granted }

/// Where reminders come from: EventKit, or a fake.
protocol RemindersSource: AnyObject {
    var access: ReminderAccess { get }
    func requestAccess(_ done: @escaping (Bool) -> Void)
    func lists() -> [ReminderList]
    /// The incomplete reminders of these lists (nil: every list), on the main thread.
    func fetch(lists: [String]?, _ done: @escaping ([ReminderItem]) -> Void)
    func setCompleted(_ id: String, _ completed: Bool) throws
    func add(title: String, list: String?, due: DateComponents?) throws -> ReminderItem
    var defaultList: String? { get }
    var onChange: (() -> Void)? { get set }
}

enum RemindersFilter: String, Codable, CaseIterable { case today, scheduled, all }

struct RemindersSettings: Codable, Equatable {
    var lists: [String] = []                 // the lists shown; empty = every list
    var addTo: String? = nil                 // where new reminders go; nil = the default list
    var filter = RemindersFilter.today
    static let key = "notch.reminders"
}

enum RemindersLogic {
    enum Section: String, CaseIterable { case overdue, today, upcoming, someday }

    static func section(_ r: ReminderItem, now: Date, cal: Calendar) -> Section {
        guard let due = r.due else { return .someday }
        let startToday = cal.startOfDay(for: now)
        guard let startTomorrow = cal.date(byAdding: .day, value: 1, to: startToday) else { return .upcoming }
        if r.allDay ? due < startToday : due < now { return .overdue }
        if due < startTomorrow { return .today }
        return .upcoming
    }

    /// What the filter shows, in sections (empty sections left out), each sorted: due first (earliest), then priority, then title.
    static func sections(_ items: [ReminderItem], filter: RemindersFilter, now: Date, cal: Calendar) -> [(Section, [ReminderItem])] {
        let keep: Set<Section> = filter == .today ? [.overdue, .today] : filter == .scheduled ? [.overdue, .today, .upcoming] : Set(Section.allCases)
        var by: [Section: [ReminderItem]] = [:]
        for r in items { let s = section(r, now: now, cal: cal); if keep.contains(s) { by[s, default: []].append(r) } }
        func rank(_ p: Int) -> Int { p == 0 ? 10 : p }
        return Section.allCases.compactMap { s in
            guard let list = by[s], !list.isEmpty else { return nil }
            return (s, list.sorted { a, b in
                if a.due != b.due { return (a.due ?? .distantFuture) < (b.due ?? .distantFuture) }
                if a.priority != b.priority { return rank(a.priority) < rank(b.priority) }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            })
        }
    }

    static func title(_ s: Section) -> String {
        switch s {
        case .overdue: return L("Overdue")
        case .today: return L("Today")
        case .upcoming: return L("Upcoming")
        case .someday: return L("No date")
        }
    }

    /// The text typed for a quick add: trimmed, at most 500 characters; nil when there is nothing.
    static func cleanTitle(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(500))
    }
}

/// The reminders the island shows, and what a click does to them.
final class RemindersWatch: ObservableObject {
    @Published private(set) var access: ReminderAccess = .notAsked
    @Published private(set) var lists: [ReminderList] = []
    @Published private(set) var items: [ReminderItem] = []
    @Published private(set) var settings: RemindersSettings
    /// Ticked a moment ago: shown ticked and struck through until it leaves (a second click before then puts it back).
    @Published private(set) var completing: Set<String> = []
    @Published private(set) var problem: String?
    @Published var draft = ""

    /// How long a ticked reminder stays before it leaves.
    static let linger: TimeInterval = 1.4
    var now: () -> Date = { Date() }
    var cal = Calendar.autoupdatingCurrent
    private var source: RemindersSource?
    private var pending: [String: Int] = [:]
    private var generation = 0
    private let defaults: () -> UserDefaults
    var after: (TimeInterval, @escaping () -> Void) -> Void = { t, f in DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }

    init(defaults: @escaping () -> UserDefaults = { AppDefaults.store }) {
        self.defaults = defaults
        settings = defaults().data(forKey: RemindersSettings.key).flatMap { try? JSONDecoder().decode(RemindersSettings.self, from: $0) } ?? RemindersSettings()
    }

    /// The app: EventKit (made only now, so a test or render never touches it).
    func start() { if source == nil { use(EventKitReminders()) } }

    /// A source (EventKit, or a fake in tests and renders).
    func use(_ s: RemindersSource) {
        source = s
        s.onChange = { [weak self] in self?.reload() }
        access = s.access
        reload()
    }

    func requestAccess() {
        guard let s = source else { return }
        s.requestAccess { [weak self] _ in
            guard let self else { return }
            self.access = s.access
            self.reload()
        }
    }

    func reload() {
        guard let s = source else { return }
        access = s.access
        guard access == .granted else { lists = []; items = []; return }
        lists = s.lists()
        let wanted = settings.lists.filter { id in lists.contains { $0.id == id } }
        s.fetch(lists: wanted.isEmpty ? nil : wanted) { [weak self] got in
            guard let self else { return }
            Motion.with(.expand) { self.items = got.filter { !self.recentlyDone.contains($0.id) } }
        }
    }
    /// Completed here and saved, before EventKit's change notice catches up.
    private var recentlyDone: Set<String> = []

    var sections: [(RemindersLogic.Section, [ReminderItem])] {
        RemindersLogic.sections(items, filter: settings.filter, now: now(), cal: cal)
    }
    var shownCount: Int { sections.reduce(0) { $0 + $1.1.count } }
    func list(_ id: String) -> ReminderList? { lists.first { $0.id == id } }
    var addList: ReminderList? { settings.addTo.flatMap(list) ?? source?.defaultList.flatMap(list) ?? lists.first }

    /// A click on a reminder's circle: ticked (it leaves after `linger`), or, ticked a moment ago, put back.
    func toggle(_ id: String) {
        if completing.contains(id) {
            Motion.with(.stateSwap) { _ = completing.remove(id) }
            pending[id] = nil
            return
        }
        Motion.with(.stateSwap) { _ = completing.insert(id) }
        generation += 1
        let g = generation
        pending[id] = g
        after(Self.linger) { [weak self] in self?.commit(id, generation: g) }
    }

    private func commit(_ id: String, generation g: Int) {
        guard pending[id] == g, completing.contains(id), let s = source else { return }
        pending[id] = nil
        do {
            try s.setCompleted(id, true)
            recentlyDone.insert(id)
            Motion.with(.expand) {
                completing.remove(id)
                items.removeAll { $0.id == id }
            }
            problem = nil
        } catch {
            Motion.with(.stateSwap) { _ = completing.remove(id) }
            problem = L("Couldn't save the reminder")
        }
    }

    /// Return in the quick-add field: a new reminder in the chosen list (due today when the page shows today's).
    @discardableResult
    func addDraft() -> Bool {
        guard let title = RemindersLogic.cleanTitle(draft), let s = source, access == .granted else { return false }
        let due: DateComponents? = settings.filter == .today ? cal.dateComponents([.year, .month, .day], from: now()) : nil
        do {
            let r = try s.add(title: title, list: addList?.id, due: due)
            Motion.with(.expand) { items.append(r) }
            draft = ""
            problem = nil
            return true
        } catch {
            problem = L("Couldn't save the reminder")
            return false
        }
    }

    func update(_ change: (inout RemindersSettings) -> Void) {
        var n = settings
        change(&n)
        guard n != settings else { return }
        settings = n
        if let d = try? JSONEncoder().encode(n) { defaults().set(d, forKey: RemindersSettings.key) }
        reload()
    }
}

/// The reminders in EventKit (its own store: the calendar's has its own permission).
final class EventKitReminders: RemindersSource {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.onChange?() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var access: ReminderAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToReminders { ok, _ in DispatchQueue.main.async { done(ok) } }
    }

    func lists() -> [ReminderList] {
        store.calendars(for: .reminder).map { c in
            var rgb: [Double] = [0.4, 0.64, 1]
            if let k = c.color.usingColorSpace(.sRGB) { rgb = [Double(k.redComponent), Double(k.greenComponent), Double(k.blueComponent)] }
            return ReminderList(id: c.calendarIdentifier, title: c.title, color: rgb)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var defaultList: String? { store.defaultCalendarForNewReminders()?.calendarIdentifier }

    func fetch(lists ids: [String]?, _ done: @escaping ([ReminderItem]) -> Void) {
        let cals = ids.map { want in store.calendars(for: .reminder).filter { want.contains($0.calendarIdentifier) } }
        let p = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        store.fetchReminders(matching: p) { found in
            let cal = Calendar.autoupdatingCurrent
            let items = (found ?? []).map { r -> ReminderItem in
                let dc = r.dueDateComponents
                return ReminderItem(id: r.calendarItemIdentifier, title: r.title ?? "", due: dc.flatMap { cal.date(from: $0) },
                                    allDay: dc?.hour == nil, listID: r.calendar.calendarIdentifier, priority: r.priority)
            }
            DispatchQueue.main.async { done(items) }
        }
    }

    func setCompleted(_ id: String, _ completed: Bool) throws {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { throw CocoaError(.fileNoSuchFile) }
        r.isCompleted = completed
        try store.save(r, commit: true)
    }

    func add(title: String, list: String?, due: DateComponents?) throws -> ReminderItem {
        let r = EKReminder(eventStore: store)
        r.title = title
        guard let c = list.flatMap({ id in store.calendars(for: .reminder).first { $0.calendarIdentifier == id } }) ?? store.defaultCalendarForNewReminders()
        else { throw CocoaError(.fileNoSuchFile) }
        r.calendar = c
        r.dueDateComponents = due
        try store.save(r, commit: true)
        return ReminderItem(id: r.calendarItemIdentifier, title: title, due: due.flatMap { Calendar.autoupdatingCurrent.date(from: $0) },
                            allDay: true, listID: c.calendarIdentifier)
    }
}

// MARK: - The module

extension IslandView {
    func remindersModule(_ b: ModuleBox) -> some View { RemindersModuleView(watch: model.reminders, size: b.size) }
}

struct RemindersModuleView: View {
    @ObservedObject var watch: RemindersWatch
    let size: ModuleSize

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Text(L("Reminders")).font(UI.section).foregroundStyle(UI.secondary)
                if watch.access == .granted && watch.shownCount > 0 {
                    Text("\(watch.shownCount)").font(UI.section.monospacedDigit()).foregroundStyle(UI.hint).motionNumber(watch.shownCount)
                }
                Spacer(minLength: Space.s)
                if watch.access == .granted && size != .s {
                    IslandValueButton(title: L("Show"), value: filterName(watch.settings.filter)) {
                        IslandChoices.ask(L("Show"), icon: "line.3.horizontal.decrease", RemindersFilter.allCases.map {
                            DialogChoice(id: $0.rawValue, title: filterName($0), symbol: $0 == watch.settings.filter ? "checkmark" : "circle")
                        }) { id in watch.update { $0.filter = RemindersFilter(rawValue: id) ?? .today } }
                    }
                }
            }
            switch watch.access {
            case .notAsked: permission(denied: false)
            case .denied: permission(denied: true)
            case .granted: content
            }
            if let p = watch.problem {
                Text(p).font(UI.detail).foregroundStyle(warningColor).lineLimit(1).transition(Motion.appear(.top))
            }
        }
        .animation(Motion.animation(.notice), value: watch.problem)
    }

    private func filterName(_ f: RemindersFilter) -> String {
        switch f { case .today: return L("Today and overdue"); case .scheduled: return L("Scheduled"); case .all: return L("All") }
    }

    /// Asked from inside the island: a button that asks macOS, or (refused) the way to the privacy settings.
    private func permission(denied: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(denied ? L("Cocaine isn't allowed to see your reminders.") : L("Show your reminders here: due today, overdue, a quick add."))
                .font(UI.value).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true)
            Button(denied ? L("Open Privacy Settings") : L("Allow access to Reminders")) {
                if denied {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                } else {
                    watch.requestAccess()
                }
            }
            .buttonStyle(CocaineButtonStyle(kind: denied ? .secondary : .primary, height: CTL.hDialog))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var content: some View {
        let sections = watch.sections
        if sections.isEmpty {
            Text(watch.settings.filter == .today ? L("Nothing due today") : L("No reminders"))
                .font(UI.value).foregroundStyle(UI.hint).transition(.opacity)
        } else if size == .s {
            if let first = sections.first?.1.first { row(first) }
        } else {
            FadingScroll {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(sections, id: \.0) { s, list in
                        if sections.count > 1 || s != .today {
                            Text(RemindersLogic.title(s)).font(UI.detail).foregroundStyle(s == .overdue ? ChargeGlyph.red : UI.hint)
                                .padding(.top, Space.xs)
                        }
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                            row(r).transition(.asymmetric(insertion: Motion.appear(.top), removal: .opacity))
                        }
                    }
                }
            }
        }
        if size != .s { addField }
        Spacer(minLength: 0)
    }

    private func dueText(_ r: ReminderItem) -> String? {
        guard let d = r.due else { return nil }
        let f = DateFormatter()
        f.locale = Language.locale
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = r.allDay ? .none : .short
        return f.string(from: d)
    }

    private func row(_ r: ReminderItem) -> some View {
        let done = watch.completing.contains(r.id)
        let overdue = RemindersLogic.section(r, now: watch.now(), cal: watch.cal) == .overdue
        let color = watch.list(r.listID)?.swiftColor ?? Island.accent
        return Button { Haptic.tap(.generic); watch.toggle(r.id) } label: {
            HStack(spacing: Space.m) {
                ZStack {
                    Circle().strokeBorder(color, lineWidth: 1.5)
                    Circle().fill(color).padding(3).scaleEffect(done ? 1 : 0.2).opacity(done ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                .animation(Motion.animation(.toggle), value: done)
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.title).font(UI.value).foregroundStyle(done ? UI.hint : UI.primary).strikethrough(done, color: UI.hint).lineLimit(1)
                    if let d = dueText(r) {
                        Text(d).font(UI.detail).foregroundStyle(overdue && !done ? ChargeGlyph.red : UI.hint).lineLimit(1)
                    }
                }
                .animation(Motion.animation(.stateSwap), value: done)
                Spacer(minLength: 0)
                if r.priority > 0 && r.priority <= 4 {
                    Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(warningColor).accessibilityHidden(true)
                }
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScaleRow))
        .accessibilityLabel(r.title + (dueText(r).map { ", " + $0 } ?? ""))
        .accessibilityValue(done ? L10nControls.ticked : L10nControls.unticked)
        .accessibilityHint(L("Marks it as completed"))
    }

    private var addField: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "plus.circle.fill").font(UI.icon).foregroundStyle(UI.hint).frame(width: 16).accessibilityHidden(true)
            TextField(L("New reminder"), text: $watch.draft)
                .textFieldStyle(.plain).font(UI.value)
                .onSubmit { if watch.addDraft() { Haptic.tap(.generic) } }
                .accessibilityLabel(L("New reminder"))
            if watch.lists.count > 1, let l = watch.addList {
                IslandValueButton(title: L("Add to"), value: l.title) {
                    IslandChoices.ask(L("Add to"), icon: "list.bullet", watch.lists.map {
                        DialogChoice(id: $0.id, title: $0.title, symbol: $0.id == l.id ? "checkmark" : "list.bullet")
                    }) { id in watch.update { $0.addTo = id } }
                }
                .frame(maxWidth: 110)
            }
        }
        .frame(height: CTL.h)
        .padding(.horizontal, Space.s)
        .background(RoundedRectangle(cornerRadius: CTL.radius).fill(CTL.track))
    }
}
