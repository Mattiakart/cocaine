// The privacy permissions Cocaine needs, checked and asked for.

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

// MARK: - Permissions

/// Everything macOS makes Cocaine ask for. Each one is checked, and asked for only when it is missing.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility, camera, calendar, automation, files
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accessibility: return L("Accessibility")
        case .camera: return L("Camera")
        case .calendar: return L("Calendar")
        case .automation: return L("Music and Spotify")
        case .files: return L("Files and folders")
        }
    }
    var reason: String {
        switch self {
        case .accessibility: return L("Stay active and the system HUD need it.")
        case .camera: return L("The Mirror page can't show the camera.")
        case .calendar: return L("The Calendar page can't show your events.")
        case .automation: return L("Music and Spotify can't be controlled.")
        case .files: return L("Downloads and screenshots can't be read.")
        }
    }
    var pane: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .camera: return "Privacy_Camera"
        case .calendar: return "Privacy_Calendars"
        case .automation: return "Privacy_Automation"
        case .files: return "Privacy_FilesAndFolders"
        }
    }
}

enum Permissions {
    enum State { case granted, denied, notAsked }
    static let musicApps = ["com.apple.Music", "com.spotify.client"]

    /// Never blocks: Files and Music/Spotify can only be known by trying (a folder listing that waits for the user's answer while
    /// macOS asks; an Apple-event check that can wait on the other app), so those two come from `probe`, run off the main thread.
    static func state(_ p: Permission) -> State {
        switch p {
        case .accessibility:
            // Stay active posts events (PostEvent) and the HUD keys need an event tap (Accessibility): both are the one switch
            // under Privacy & Security → Accessibility, but they are checked separately, so both must be there.
            return AXIsProcessTrusted() && CGPreflightPostEventAccess() ? .granted : .denied
        case .camera: return cameraState(AVCaptureDevice.authorizationStatus(for: .video))
        case .calendar: return calendarState(EKEventStore.authorizationStatus(for: .event))
        case .automation: return automationState
        case .files: return filesState
        }
    }

    static func cameraState(_ s: AVAuthorizationStatus) -> State {
        switch s { case .authorized: return .granted; case .notDetermined: return .notAsked; default: return .denied }
    }
    /// Full access only: "add events only" (write-only) can't show your events, so it counts as refused.
    static func calendarState(_ s: EKAuthorizationStatus) -> State {
        switch s { case .fullAccess: return .granted; case .notDetermined: return .notAsked; default: return .denied }
    }
    /// The answers of AEDeterminePermissionToAutomateTarget for the running music apps: the worst one counts; an app that isn't
    /// running (-600) or any other error says nothing.
    static func automationState(_ codes: [OSStatus]) -> State {
        codes.contains(-1743) ? .denied : codes.contains(-1744) ? .notAsked : .granted
    }

    private(set) static var automationState = State.granted
    private(set) static var filesState = State.notAsked
    private static let probeQueue = DispatchQueue(label: "local.cocaine.permissions")
    private static var waiting: [(Bool) -> Void]?          // non-nil while a probe runs

    /// Re-checks Files (Downloads and the screenshots folder) and Music/Spotify off the main thread; `done` on the main queue,
    /// with true when something changed. Listing a folder the first time is also what makes macOS ask (once) for it: only
    /// called while the island, whose Files page reads them, is on. One probe at a time (one may wait for an answer); a call
    /// while one runs just waits for it.
    static func probe(files: Bool, done: @escaping (Bool) -> Void = { _ in }) {
        dispatchPrecondition(condition: .onQueue(.main))
        if waiting != nil { waiting?.append(done); return }
        waiting = [done]
        let apps = runningMusicApps()
        probeQueue.async {
            let auto = automationState(apps.map { automation($0, ask: false) })
            var f: State?
            if files { f = canList(FileShelf.downloadsFolder) && canList(FileShelf.screenshotsFolder) ? .granted : .denied }
            DispatchQueue.main.async {
                let changed = auto != automationState || (f != nil && f != filesState)
                automationState = auto; if let f { filesState = f }
                let w = waiting ?? []
                waiting = nil
                w.forEach { $0(changed) }
            }
        }
    }

    private static func canList(_ dir: URL) -> Bool {
        do { _ = try FileManager.default.contentsOfDirectory(atPath: dir.path); return true }
        catch let e as NSError { return !(e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError) && (e.underlyingErrorCode != Int(EPERM)) && (e.underlyingErrorCode != Int(EACCES)) }
    }

    static func runningMusicApps() -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return musicApps.filter { running.contains($0) }
    }

    /// 0 allowed, -1743 refused, -1744 not asked yet, -600 the app isn't running. Never on the main thread (it can block).
    static func automation(_ bundle: String, ask: Bool) -> OSStatus {
        guard let desc = NSAppleEventDescriptor(bundleIdentifier: bundle).aeDesc else { return -600 }
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    static func openPane(_ p: Permission) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(p.pane)") { NSWorkspace.shared.open(u) }
    }

    /// Kept alive while macOS asks: a store that goes away cancels its own request.
    private static var asking: EKEventStore?

    /// Asks for it the right way: the system's own question when it was never asked, the Settings pane when it was refused.
    /// `done` is called on the main queue once the answer is known (at once when nothing could be asked). `explicit`: the user
    /// pressed Allow, so Accessibility also opens its Settings pane (the system's dialog may not come up a second time).
    static func request(_ p: Permission, explicit: Bool = false, done: (() -> Void)? = nil) {
        let st = state(p)
        guard st != .granted else { done?(); return }
        switch p {
        case .accessibility:
            // The system's dialog (it also puts Cocaine in the Accessibility list, switched off), then the posting right if that
            // alone is missing. Settings opens too when the user asked.
            let ax = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            let post = ax ? CGRequestPostEventAccess() : CGPreflightPostEventAccess()
            if explicit && !(ax && post) { openPane(p) }
            done?()
        case .camera:
            if st == .notAsked {
                NSApp.activate()                                             // the question comes up in front
                AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async { done?() } }
            } else { openPane(p); done?() }
        case .calendar:
            if st == .notAsked {
                NSApp.activate()
                let store = EKEventStore()
                asking = store
                store.requestFullAccessToEvents { _, _ in DispatchQueue.main.async { asking = nil; done?() } }
            } else { openPane(p); done?() }
        case .automation:
            if st == .notAsked {
                NSApp.activate()
                let apps = runningMusicApps()
                probeQueue.async {
                    let codes = apps.map { automation($0, ask: true) }
                    DispatchQueue.main.async { automationState = automationState(codes); done?() }
                }
            } else { openPane(p); done?() }
        case .files:
            if st == .notAsked {                                             // listing them is the question
                probe(files: true) { _ in if filesState != .granted { openPane(p) }; done?() }
            } else { openPane(p); done?() }
        }
    }
}

private extension NSError {
    var underlyingErrorCode: Int { (userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0 }
}
