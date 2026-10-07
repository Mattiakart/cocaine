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
    private lazy var store = EKEventStore()           // made when first read (not at launch: connecting to Calendar takes a moment)
    private var storeHasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess

    func refresh() {
        access = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard access else { return }
        if !storeHasAccess { store = EKEventStore(); storeHasAccess = true }     // a store made before the permission sees no events
        let now = Date(), end = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
        let found = store.events(matching: store.predicateForEvents(withStart: Calendar.current.startOfDay(for: now), end: end, calendars: nil))
            .filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }.prefix(6)
        events = found.map { e in Ev(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                                     color: Color(nsColor: e.calendar.color ?? .systemBlue)) }
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
                    } else {
                        Button(L("Allow Calendar")) { calendar.requestAccess() }
                            .buttonStyle(CocaineButtonStyle(kind: .primary, height: CTL.hDialog))
                    }
                } else if calendar.events.isEmpty {
                    Text(L("No events in the next two weeks")).font(UI.value).foregroundStyle(UI.hint)
                } else {
                    FadingScroll(cap: 124) { VStack(alignment: .leading, spacing: Space.m) { ForEach(calendar.events) { e in
                        HStack(spacing: Space.m) {
                            Capsule().fill(e.color).frame(width: 3, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(UI.itemTitle).lineLimit(1)
                                Text(e.allDay ? e.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(loc)) + " · " + L("All day")
                                     : e.start.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(loc)))
                                    .font(UI.detail).foregroundStyle(UI.secondary)
                            }
                            Spacer(minLength: 0)
                        }
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
