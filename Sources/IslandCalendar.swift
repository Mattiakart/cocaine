// The island's Calendar page and its CalendarWatch.

import AppKit
import AVFoundation
import Combine
import CoreAudio
import EventKit
import Carbon.HIToolbox
import Darwin
import ImageIO
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import os

/// Today and the next events (up to two weeks ahead) from the Calendar app, with the user's permission.
final class CalendarWatch: ObservableObject {
    struct Ev: Identifiable { var id: String; var title: String; var start: Date; var end: Date; var allDay: Bool; var color: Color }
    @Published var events: [Ev] = []
    @Published var access = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published var asked = EKEventStore.authorizationStatus(for: .event) != .notDetermined
    private var store = EKEventStore()
    private var storeHasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess

    private let queue = DispatchQueue(label: "local.cocaine.calendar", qos: .userInitiated)
    private var busy = false

    /// Fetches the next two weeks off the main thread (EventKit can take a while with many calendars).
    func refresh() {
        let a = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        if access != a { access = a }
        asked = EKEventStore.authorizationStatus(for: .event) != .notDetermined
        guard access, !busy else { return }
        if !storeHasAccess { store = EKEventStore(); storeHasAccess = true }     // a store made before the permission sees no events
        busy = true
        queue.async { [store] in
            let now = Date(), end = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
            let found = store.events(matching: store.predicateForEvents(withStart: Calendar.current.startOfDay(for: now), end: end, calendars: nil))
                .filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }.prefix(6)
            let list = found.map { e in Ev(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                                           color: Color(nsColor: e.calendar.color ?? .systemBlue)) }
            DispatchQueue.main.async { self.events = list; self.busy = false }
        }
    }

    func requestAccess() {
        Permissions.request(.calendar) { [weak self] in self?.asked = true; self?.refresh() }
    }
}

extension IslandView {
    // MARK: calendar

    var calendarTab: some View {
        let loc = Language.locale
        return HStack(alignment: .top, spacing: Space.page) {           // template B: a 128 pt block, an 18 pt gutter (as Music)
            VStack(alignment: .leading, spacing: 0) {
                Text(Date().formatted(.dateTime.weekday(.wide).locale(loc)).capitalized(with: loc)).font(UI.buttonSecondary).foregroundStyle(Island.accent)
                Text(Date().formatted(.dateTime.day().locale(loc))).font(UI.hero)
                Text(Date().formatted(.dateTime.month(.wide).year().locale(loc))).font(UI.value).foregroundStyle(UI.secondary)
            }
            .frame(width: 128, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.m) {
                if !calendar.access {
                    Text(L("Show your next events here")).font(UI.value).foregroundStyle(UI.secondary)
                    if calendar.asked {
                        Text(L("Allow it in System Settings → Privacy & Security → Calendars")).font(UI.detail).foregroundStyle(UI.hint)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("Open Settings")) { Permissions.openPane(.calendar) }
                            .buttonStyle(CocaineButtonStyle(kind: .primary, height: CTL.hDialog))
                    } else {
                        Button(L("Allow Calendar")) { calendar.requestAccess() }
                            .buttonStyle(CocaineButtonStyle(kind: .primary, height: CTL.hDialog))
                    }
                } else if calendar.events.isEmpty {
                    Text(L("No events in the next two weeks")).font(UI.value).foregroundStyle(UI.hint)
                } else {
                    FadingScroll(cap: 124) { VStack(alignment: .leading, spacing: Space.m) { ForEach(calendar.events) { e in
                        let when = e.allDay ? e.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(loc)) + " · " + L("All day")
                            : e.start.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(loc))
                        HStack(spacing: Space.m) {
                            Capsule().fill(e.color).frame(width: 3, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(UI.itemTitle).lineLimit(1)
                                Text(when).font(UI.detail).foregroundStyle(UI.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(e.title)
                        .accessibilityValue(when)
                    } } }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if Permissions.state(.calendar) == .notAsked { calendar.requestAccess() }          // asked the first time the page is opened
            calendar.refresh()
        }
    }
}
