// Two small Amphetamine things for the keep-awake sessions: statistics (how many sessions, how long in all, since when; Reset)
// and a reminder while Cocaine stays on (every 1, 2, 4 or 8 hours a notice says how long it has been on). Pure here; AwakeCenter
// feeds them, Sources/AwakeProfilesPanel.swift shows them.

import Foundation

struct AwakeStats: Codable, Equatable {
    var sessions = 0
    var seconds: Double = 0
    var since: Date
    /// The session going on now, and the last time it was seen on (a quit or crash in the middle ends it there, not later).
    var onSince: Date?
    var lastSeen: Date?

    init(since: Date) { self.since = since }

    /// Cocaine turned on or off.
    mutating func turned(on: Bool, now: Date) {
        if on {
            guard onSince == nil else { return }
            onSince = now; lastSeen = now; sessions += 1
        } else if let s = onSince {
            seconds += max(0, now.timeIntervalSince(s))
            onSince = nil; lastSeen = nil
        }
    }

    /// While on, now and then (kept so a quit in the middle is counted up to here).
    mutating func seen(now: Date) { if onSince != nil { lastSeen = now } }

    /// At launch: a session left open by a quit or crash ends where it was last seen; if Cocaine is on now, a new one begins.
    mutating func launched(on: Bool, now: Date) {
        if let s = onSince {
            let end = min(now, max(s, lastSeen ?? s))
            seconds += end.timeIntervalSince(s)
            onSince = nil; lastSeen = nil
        }
        if on { turned(on: true, now: now) }
    }

    func total(now: Date) -> Double { seconds + (onSince.map { max(0, now.timeIntervalSince($0)) } ?? 0) }
}

extension Settings {
    var awakeStats: AwakeStats {
        get { d.data(forKey: "awakeStats").flatMap { try? JSONDecoder().decode(AwakeStats.self, from: $0) } ?? AwakeStats(since: Date()) }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "awakeStats") } }
    }
    /// A reminder every this many hours while Cocaine is on; 0 = never.
    var remindHours: Int {
        get { let v = d.object(forKey: "remindHours") as? Int ?? 0; return OnReminder.choices.contains(v) ? v : 0 }
        nonmutating set { d.set(OnReminder.choices.contains(newValue) ? newValue : 0, forKey: "remindHours") }
    }
}

/// "Cocaine has been on for 2 h": once per whole interval of a session.
struct OnReminder {
    static let choices = [0, 1, 2, 4, 8]
    private(set) var told = 0
    private(set) var session: Date?
    private(set) var every = 0

    /// Hours on to say now, or nil.
    mutating func step(onSince: Date?, every hours: Int, now: Date) -> Int? {
        guard let s = onSince, hours > 0 else { told = 0; session = nil; return nil }
        let n = Int(now.timeIntervalSince(s) / Double(hours * 3600))
        if session != s { session = s; every = hours; told = 0 }          // a new session
        else if every != hours { every = hours; told = n }               // the interval changed: from now on
        guard n > told else { return nil }
        told = n
        return n * hours
    }
}
