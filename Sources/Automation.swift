// Automation: the timer, Battery Guard, Smart Triggers state and power/lid readings (global shortcuts: Sources/Shortcuts.swift).

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

// MARK: - Automation: timer, battery guard, smart triggers, agent states, phone alerts

extension Settings {
    static let timerChoices = [0, 30, 60, 120, 240, 480]        // minutes Cocaine stays on when turned on by hand; 0 = until turned off
    static let batteryChoices = [0, 10, 15, 20, 30]             // % at which to act on battery; 0 = off

    var timerMinutes: Int { get { d.object(forKey: "timerMinutes") as? Int ?? 0 } nonmutating set { d.set(newValue, forKey: "timerMinutes") } }
    /// When Cocaine turns itself off (also set by `cocaine remote on --for …`).
    var onUntil: Date? {
        get { let v = d.double(forKey: "onUntil"); return v > 0 ? Date(timeIntervalSince1970: v) : nil }
        nonmutating set { if let n = newValue { d.set(n.timeIntervalSince1970, forKey: "onUntil") } else { d.removeObject(forKey: "onUntil") } }
    }
    var batteryThreshold: Int { get { d.object(forKey: "batteryThreshold") as? Int ?? 0 } nonmutating set { d.set(newValue, forKey: "batteryThreshold") } }
    var batteryTurnsOff: Bool { get { flag("batteryTurnsOff", true) } nonmutating set { d.set(newValue, forKey: "batteryTurnsOff") } }
    var triggerAgents: Bool { get { flag("triggerAgents", false) } nonmutating set { d.set(newValue, forKey: "triggerAgents") } }
    var triggerApps: [String] { get { d.stringArray(forKey: "triggerApps") ?? [] } nonmutating set { d.set(newValue, forKey: "triggerApps") } }
    // Power, display and schedule triggers (Sources/Power.swift)
    var triggerPower: String { get { d.string(forKey: "triggerPower") ?? "" } nonmutating set { d.set(newValue, forKey: "triggerPower") } }   // "" | ac | battery
    var triggerDisplay: String { get { d.string(forKey: "triggerDisplay") ?? "" } nonmutating set { d.set(newValue, forKey: "triggerDisplay") } }   // "" | connected | disconnected
    var triggerSchedule: Bool { get { flag("triggerSchedule", false) } nonmutating set { d.set(newValue, forKey: "triggerSchedule") } }
    var scheduleDays: [Int] { get { (d.array(forKey: "scheduleDays") as? [Int])?.filter { (1...7).contains($0) } ?? [2, 3, 4, 5, 6] } nonmutating set { d.set(newValue, forKey: "scheduleDays") } }
    var scheduleStart: Int { get { TimeWindow.clamp(d.object(forKey: "scheduleStart") as? Int ?? 540) } nonmutating set { d.set(TimeWindow.clamp(newValue), forKey: "scheduleStart") } }
    var scheduleEnd: Int { get { TimeWindow.clamp(d.object(forKey: "scheduleEnd") as? Int ?? 1080) } nonmutating set { d.set(TimeWindow.clamp(newValue), forKey: "scheduleEnd") } }
    var triggerAll: Bool { get { flag("triggerAll", false) } nonmutating set { d.set(newValue, forKey: "triggerAll") } }
    /// Cocaine is on because a Smart Trigger turned it on (kept across an update's or a crash's adopted session).
    var triggerOwned: Bool { get { flag("triggerOwned", false) } nonmutating set { d.set(newValue, forKey: "triggerOwned") } }
    var schedule: TimeWindow { TimeWindow(days: Set(scheduleDays), start: scheduleStart, end: scheduleEnd) }
    /// "Dim the screen when idle" turns the displays off instead (the Mac keeps working).
    var screenOff: Bool { get { flag("screenOff", false) } nonmutating set { d.set(newValue, forKey: "screenOff") } }
    /// Shortcuts and cocaine:// links may turn Cocaine on and off without asking.
    var allowLinks: Bool { get { flag("allowLinks", false) } nonmutating set { d.set(newValue, forKey: "allowLinks") } }
    /// Global shortcuts (Sources/Shortcuts.swift): on unless turned off, so the keyboard always has a way to Cocaine (with the island
    /// on there is no menu-bar icon to reach). Which keys: "shortcuts.v1".
    var hotkeys: Bool { get { flag("hotkeys", true) } nonmutating set { d.set(newValue, forKey: "hotkeys") } }
    var haptics: Bool { get { flag("haptics", true) } nonmutating set { d.set(newValue, forKey: "haptics") } }
    var stayActive: Bool { get { flag("stayActive", false) } nonmutating set { d.set(newValue, forKey: "stayActive") } }
    var stayActiveAlways: Bool { get { flag("stayActiveAlways", false) } nonmutating set { d.set(newValue, forKey: "stayActiveAlways") } }
    var stayActiveApps: [String] { get { d.stringArray(forKey: "stayActiveApps") ?? Presence.defaultApps } nonmutating set { d.set(newValue, forKey: "stayActiveApps") } }
    var replaceHUD: Bool { get { flag("replaceHUD", false) } nonmutating set { d.set(newValue, forKey: "replaceHUD") } }
    var island: Bool { get { flag("island", true) } nonmutating set { d.set(newValue, forKey: "island") } }
    var wakeForPhone: Bool { get { flag("wakeForPhone", false) } nonmutating set { d.set(newValue, forKey: "wakeForPhone") } }
    /// A random value the app keeps for its own tools (`cocaine remote notify test`); URLs need it for `test=` flags.
    var testToken: String {
        if let t = d.string(forKey: "testToken") { return t }
        let t = UUID().uuidString
        d.set(t, forKey: "testToken")
        return t
    }
    var alertError: Bool { get { flag("alertError", true) } nonmutating set { d.set(newValue, forKey: "alertError") } }
    /// Claude Code's and Codex's requests can be answered from the notch (off: they're only shown, the terminal asks).
    var agentApprovals: Bool { get { flag("agentApprovals", false) } nonmutating set { d.set(newValue, forKey: "agentApprovals") } }
    /// Phone alerts: a Shortcut to run (given the alert text) and/or an ntfy topic URL. Set in the panel or with `cocaine remote notify`.
    var phoneShortcut: String {
        get { d.string(forKey: "phoneShortcut") ?? "" }
        nonmutating set { if newValue.isEmpty { d.removeObject(forKey: "phoneShortcut") } else { d.set(newValue, forKey: "phoneShortcut") } }
    }
    var phoneNtfy: String {
        get { d.string(forKey: "phoneNtfy") ?? "" }
        nonmutating set { if newValue.isEmpty { d.removeObject(forKey: "phoneNtfy") } else { d.set(newValue, forKey: "phoneNtfy") } }
    }
}

/// Battery Guard: fires once when the battery (on battery power) reaches the threshold, and re-arms when it recovers.
struct BatteryGuard {
    var tripped = false

    mutating func check(percent: Int, onAC: Bool, threshold: Int) -> Bool {
        guard threshold > 0 else { tripped = false; return false }
        if onAC || percent > threshold + 3 { tripped = false; return false }
        if percent <= threshold && !tripped { tripped = true; return true }
        return false
    }
}

/// Smart Triggers: turns Cocaine on when something wants the Mac awake, and off again a while after it stops, but only
/// if the trigger (not the user) turned it on; a user who turns it off while a trigger is active is not overruled.
struct AutoOn {
    enum Step { case none, turnOn, turnOff }
    var owned = false                  // Cocaine is on because a trigger turned it on
    var suppressed = false             // the user said no while a trigger was active
    var lastActive = Date.distantPast

    mutating func step(active: Bool, isOn: Bool, now: Date, grace: TimeInterval = 180) -> Step {
        if now < lastActive { lastActive = now }    // the clock went back: the grace counts from now (it never waits for the old time)
        if active {
            lastActive = now
            if !isOn && !suppressed { owned = true; return .turnOn }
            return .none
        }
        suppressed = false
        if owned {
            if !isOn { owned = false; return .none }
            if now.timeIntervalSince(lastActive) >= grace { owned = false; return .turnOff }
        }
        return .none
    }

    mutating func userToggled(to on: Bool, triggerActive: Bool) {
        owned = false
        if !on && triggerActive { suppressed = true }
    }

    /// A new instance took over a session a trigger had turned on (an update, a crash): it stays the trigger's, so it
    /// ends when the trigger does (after the grace), instead of becoming an ON nobody turns off.
    mutating func resume(now: Date) { owned = true; lastActive = now }

    /// The Mac woke from sleep: a trigger's reason (the Wi-Fi, a VPN, a display) takes a moment to come back, so the grace of an ON
    /// a trigger made counts from the wake, not from before the sleep (which ended it at the first look after any long sleep).
    mutating func woke(now: Date) { if owned { lastActive = max(lastActive, now) } }
}

// AgentEntry and AgentBoard (what each AI session is doing) live in Sources/AgentSessions.swift.

extension System {
    /// Charge and power source of the internal battery; nil on a Mac without one.
    static var battery: (percent: Int, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (cur * 100 / max, (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }

    /// Names of every running process and app, lowercased (what a Smart Trigger matches against).
    static func runningNames() -> Set<String> {
        var names = Set(ProcessList.all().map { $0.name.lowercased() })
        for app in NSWorkspace.shared.runningApplications {
            if let n = app.localizedName { names.insert(n.lowercased()) }
            if let n = app.bundleURL?.deletingPathExtension().lastPathComponent { names.insert(n.lowercased()) }
        }
        return names
    }

    /// Regular apps the user can pick as a trigger, by name.
    static func runningAppNames() -> [String] {
        Array(Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)))
            .filter { $0 != "Cocaine" }.sorted { $0.lowercased() < $1.lowercased() }
    }
}

// Global shortcuts live in Sources/Shortcuts.swift.
