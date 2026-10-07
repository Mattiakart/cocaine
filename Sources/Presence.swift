// Stay active: chat apps keep showing you as available; --presence-test.

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

// MARK: - Stay active: chat apps (Teams, Slack, Zoom…) keep showing you as available

/// Teams and similar apps mark you "Away" from the system's idle time. While you are idle this sends an invisible mouse event
/// (no movement) now and then, which resets that clock. Sending input needs the Accessibility permission.
enum Presence {
    static let defaultApps = ["Microsoft Teams", "Teams", "Slack", "zoom.us", "Webex", "Skype"]
    static var hasAccess: Bool { CGPreflightPostEventAccess() }

    static func requestAccess() {
        if !CGRequestPostEventAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    /// An event as if the mouse "moved" by zero: the cursor stays put, the idle time restarts.
    @discardableResult
    static func nudge() -> Bool {
        guard hasAccess else { return false }
        let here = CGEvent(source: nil)?.location ?? .zero
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: here, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventDeltaX, value: 0)
        e?.setIntegerValueField(.mouseEventDeltaY, value: 0)
        e?.post(tap: .cghidEventTap)
        return e != nil
    }

    /// Is any of the named apps running? (Matched on a part of the name, ignoring case.)
    static func anyRunning(_ names: [String]) -> Bool {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        return names.contains { n in running.contains { $0.lowercased().contains(n.lowercased()) } }
    }
}

/// `--presence-test`, run from main.swift.
func cliPresenceTest() {
    // Does a presence nudge reset the system idle time? Prints the permission state and the idle time before and after.
    print("post-event access:", Presence.hasAccess, " accessibility:", AXIsProcessTrusted())
    Thread.sleep(forTimeInterval: 3)
    let before = System.idleSeconds
    let sent = Presence.nudge()
    Thread.sleep(forTimeInterval: 0.3)
    let after = System.idleSeconds
    print(String(format: "idle before %.1f s, nudge sent: %@, idle after %.1f s", before, sent ? "yes" : "no", after))
    print(sent && after < before ? "PASS  the nudge resets the idle time" : "FAIL  no effect (permission missing?)")
    exit(0)
}
