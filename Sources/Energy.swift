// One pause point for the app's pollers: while the screens sleep, the Mac sleeps or another user has the screen (fast user
// switching), nothing on screen needs fresh data, so the pollers stop (the clipboard's; others can subscribe) and pick up again
// after. Nothing else changes: event-driven watchers (files, microphone, music) cost nothing while idle anyway.

import AppKit

final class PowerAwareness {
    static let shared = PowerAwareness()
    /// True while nobody can see the screen.
    private(set) var paused = false
    private var reasons = Set<String>()
    private var subscribers: [UUID: (Bool) -> Void] = [:]

    private init() {
        let c = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Notification.Name, String)] = [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "screens"),
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session"),
        ]
        for (off, on, why) in pairs {
            c.addObserver(forName: off, object: nil, queue: .main) { [weak self] _ in self?.set(why, true) }
            c.addObserver(forName: on, object: nil, queue: .main) { [weak self] _ in self?.set(why, false) }
        }
    }

    func set(_ reason: String, _ on: Bool) {
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        if reason == "sleep" && !on { reasons.remove("screens") }       // a wake from sleep: the screens are back too
        let now = !reasons.isEmpty
        guard now != paused else { return }
        paused = now
        subscribers.values.forEach { $0(now) }
    }

    /// `handler(paused)` on every change; keep the token to stay subscribed.
    @discardableResult
    func subscribe(_ handler: @escaping (Bool) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }

    func unsubscribe(_ id: UUID) { subscribers[id] = nil }
}
