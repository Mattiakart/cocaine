// The app's questions and messages as in-app dialogs, the island's short choices, sharing and the clipboard's dialogs.

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

/// Every question and message of the app, as in-app dialogs (Sources/InAppDialog.swift). The flows, the render tool and the
/// tests use these same specs.
/// Words for why Cocaine is on: the triggers that are true now, by name ("Xcode", "Charger"…).
enum TriggerWords {
    static func reason(_ states: [TriggerKind: Bool], apps: [String], power: String) -> String? {
        var out: [String] = []
        if states[.agents] == true { out.append(L("AI")) }
        if states[.apps] == true { out += apps.prefix(2) }
        if states[.power] == true { out.append(power == "ac" ? L("Charger") : L("Battery")) }
        if states[.display] == true { out.append(L("External display")) }
        if states[.schedule] == true { out.append(L("Schedule")) }
        return out.isEmpty ? nil : out.joined(separator: ", ")
    }
}

/// A short list asked in the open island (a camera, a monitor's input, what to clear): the dialogs' card at the page's top,
/// a row is the answer. In-app, so nothing opens under the notch or outside Cocaine's black.
enum IslandChoices {
    static func spec(_ title: String, icon: String, _ choices: [DialogChoice]) -> DialogSpec {
        DialogSpec(icon: icon, title: title, choices: choices, choiceMode: .act, buttons: [Dialogs.cancel], surface: .island)
    }

    static func ask(_ title: String, icon: String, _ choices: [DialogChoice], _ picked: @escaping (String) -> Void) {
        DialogCenter.shared.present(spec(title, icon: icon, choices)) { r in
            if case .choice(let id) = r { picked(id) }
        }
    }

    /// The clipboard page's trash: empty the history (favorites stay) or delete everything (asks again).
    static var clipboardTrash: [DialogChoice] {
        [DialogChoice(id: "clear", title: L("Clear history (keeps favorites)"), symbol: "clock.arrow.circlepath"),
         DialogChoice(id: "delete", title: L("Delete everything…"), symbol: "trash", destructive: true)]
    }
}

enum Dialogs {
    static var cancel: DialogButton { DialogButton(id: "cancel", title: L("Cancel"), role: .cancel) }
    static var ok: DialogButton { DialogButton(id: "ok", title: L("OK")) }

    /// Removing old Shortcuts can't be undone: those iPhones stop working. Cancel is the default (Return keeps them).
    static func removeOldShortcuts() -> DialogSpec {
        DialogSpec(icon: "iphone.slash", title: L("Remove the old Shortcuts?"), message: L("Those iPhones stop working until you send them a new Shortcut."),
                   critical: true, buttons: [DialogButton(id: "remove", title: L("Remove"), role: .destructive), cancel])
    }

    /// Accepting unprotected Shortcuts lowers the protection: asked, and Return (the default) says no.
    static func allowOldShortcuts() -> DialogSpec {
        DialogSpec(icon: "exclamationmark.shield", title: L("Accept unprotected Shortcuts for 14 days?"),
                   message: L("Old Shortcuts send plain, unauthenticated text: anyone who learns their relay topic could use them"), critical: true,
                   buttons: [DialogButton(id: "allow", title: L("Allow 14 days")), DialogButton(id: "cancel", title: L("Don't Allow"), role: .cancel)],
                   safeDefault: true)
    }


    /// A message with an OK button (errors: the warning icon).
    static func message(_ title: String, _ text: String? = nil, error: Bool = true, surface: DialogSurface = .panel) -> DialogSpec {
        DialogSpec(icon: error ? "exclamationmark.triangle.fill" : "info.circle", title: title, message: text, critical: error, buttons: [ok], surface: surface)
    }

    static func clipPersist(_ surface: DialogSurface) -> DialogSpec {
        DialogSpec(icon: "doc.on.clipboard", title: L("Stop saving the clipboard history?"),
                   message: L("The saved copy can be deleted now, with its Keychain key, or kept encrypted on this Mac for the next time you turn this on."),
                   buttons: [DialogButton(id: "delete", title: L("Delete it"), role: .destructive), DialogButton(id: "keep", title: L("Keep it")), cancel],
                   surface: surface)
    }

    static func clipDeleteAll(_ surface: DialogSurface) -> DialogSpec {
        DialogSpec(icon: "trash", title: L("Delete the whole clipboard history?"),
                   message: L("Everything, favorites included, plus the saved files and their Keychain key. It can't be undone."), critical: true,
                   buttons: [DialogButton(id: "delete", title: L("Delete everything"), role: .destructive), cancel], surface: surface)
    }

    /// Why a pattern can't be used (after trimming spaces, as it is saved), or nil.
    static func patternProblem(_ text: String) -> String? {
        ClipRules.validPattern(text.trimmingCharacters(in: .whitespaces)) ? nil : L("That isn't a valid pattern")
    }

    static func clipPattern(_ surface: DialogSurface) -> DialogSpec {
        DialogSpec(icon: "text.magnifyingglass", title: L("Exclude text matching a pattern"),
                   message: L("A regular expression, e.g. ^IBAN or \\bconfidential\\b. Matching text isn't kept."),
                   field: DialogField(placeholder: "^IBAN", validate: patternProblem),
                   buttons: [DialogButton(id: "add", title: L("Add"), needsValidInput: true), cancel], surface: surface)
    }

    /// Something opened a cocaine:// link that changes the Mac's sleep. Granting is never the default: Return, Esc and a click
    /// elsewhere all mean Don't Allow (the question can come up while you are typing, and a web page can open such a link).
    static func links(_ url: URL) -> DialogSpec {
        let shown = String(url.absoluteString.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        return DialogSpec(icon: "link", title: L("Allow Shortcuts and links to control Cocaine?"),
                          message: String(format: L("Something opened “%@”. If it wasn't you, choose Don't Allow. You can change this in Automation → Shortcuts."), shown),
                          buttons: [DialogButton(id: "allow", title: L("Allow")), DialogButton(id: "deny", title: L("Don't Allow"), role: .cancel)],
                          safeDefault: true)
    }

    /// Phone alerts: where they go (a row is the answer).
    static func phoneAlertsKind() -> DialogSpec {
        DialogSpec(icon: "bell.badge", title: L("Phone alerts"),
                   message: L("When you're away, alerts can also go to your phone: through a Shortcut on this Mac (it gets the alert's text; make it message you), or posted to an ntfy topic (the text leaves this Mac)."),
                   choices: [DialogChoice(id: "shortcut", title: L("A Shortcut on this Mac…"), symbol: "square.stack.3d.up"),
                             DialogChoice(id: "ntfy", title: L("An ntfy topic…"), symbol: "antenna.radiowaves.left.and.right"),
                             DialogChoice(id: "off", title: L("Turn phone alerts off"), symbol: "bell.slash", destructive: true)],
                   choiceMode: .act, buttons: [cancel])
    }

    static func phoneShortcut(_ current: String) -> DialogSpec {
        DialogSpec(icon: "square.stack.3d.up", title: L("The Shortcut to run"), message: L("Its name exactly as in the Shortcuts app."),
                   field: DialogField(placeholder: L("Shortcut name"), text: current,
                                      validate: { $0.trimmingCharacters(in: .whitespaces).isEmpty ? L("Type the Shortcut's name") : nil }),
                   buttons: [DialogButton(id: "save", title: L("Save"), needsValidInput: true), cancel])
    }

    static func phoneNtfy(_ current: String) -> DialogSpec {
        DialogSpec(icon: "antenna.radiowaves.left.and.right", title: L("The ntfy topic"),
                   message: L("An address like https://ntfy.sh/a-long-secret-name. Anyone who knows it can read the alerts."),
                   field: DialogField(placeholder: "https://ntfy.sh/…", text: current, validate: ntfyProblem),
                   buttons: [DialogButton(id: "save", title: L("Save"), needsValidInput: true), cancel])
    }

    static func ntfyProblem(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: t), u.scheme == "https", u.host != nil, u.path.count > 1, !t.contains(" ") else { return L("An https:// address with a topic") }
        return nil
    }

    static func pairPhone() -> DialogSpec {
        DialogSpec(icon: "iphone", title: L("Pair an iPhone"),
                   message: L("The Shortcut carries a secret that lets whoever has it control this Mac, within the level you choose. Send it only to your own devices."),
                   choices: [DialogChoice(id: "basic", title: L("Status, on/off and projects"), symbol: "power"),
                             DialogChoice(id: "agents", title: L("Also start and steer AI agents"), symbol: "sparkles")],
                   selected: "basic",
                   buttons: [DialogButton(id: "send", title: L("Send")), cancel])
    }

    static func revokePhones() -> DialogSpec {
        DialogSpec(icon: "iphone.slash", title: L("Revoke every paired iPhone?"), message: L("They stop working until you send a new Shortcut."), critical: true,
                   buttons: [DialogButton(id: "revoke", title: L("Revoke"), role: .destructive), cancel])
    }

    /// The share list: the ways macOS offers to send the file, AirDrop first, then Show in Finder. A row is the answer
    /// ("s0", "s1"… for `services`, or "finder"); AirDrop, Messages and Mail then open their own window (Apple's: not embeddable).
    static func share(_ services: [NSSharingService], surface: DialogSurface = .panel) -> DialogSpec {
        DialogSpec(icon: "square.and.arrow.up", title: L("Send the Shortcut to your iPhone"),
                   message: L("AirDrop, Messages and Mail then open their own macOS window to pick who gets it."),
                   choices: services.enumerated().map { DialogChoice(id: "s\($0.offset)", title: $0.element.title, image: $0.element.image) }
                       + [DialogChoice(id: "finder", title: L("Show in Finder"), symbol: "folder")],
                   choiceMode: .act, buttons: [cancel], surface: surface)
    }
}

/// Sharing files: the services macOS offers (AirDrop first), performed with the app in front (their windows can't open from a
/// panel of an app that isn't), and a failure said in the app.
final class Sharing: NSObject, NSSharingServiceDelegate {
    static let shared = Sharing()
    private var surface = DialogSurface.panel

    static func services(for items: [Any]) -> [NSSharingService] {
        let all = NSSharingService.sharingServices(forItems: items)
        let air = NSSharingService(named: .sendViaAirDrop)?.title
        return all.filter { $0.title == air } + all.filter { $0.title != air }
    }

    func perform(_ service: NSSharingService?, _ items: [Any], surface: DialogSurface) {
        self.surface = surface
        guard let service, service.canPerform(withItems: items) else {
            DialogCenter.shared.present(Dialogs.message(L("Couldn't share it"), L("AirDrop isn't available on this Mac right now."), surface: surface)) { _ in }
            return
        }
        NSApp.activate()
        service.delegate = self
        service.perform(withItems: items)
    }

    func sharingService(_ s: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let e = error as NSError
        guard !(e.domain == NSCocoaErrorDomain && e.code == NSUserCancelledError) else { return }     // closed by the user
        log.notice("share failed: \(e.domain, privacy: .public) \(e.code, privacy: .public)")
        DialogCenter.shared.present(Dialogs.message(L("Couldn't share it"), e.localizedDescription, surface: surface)) { _ in }
    }
}

/// The clipboard's confirmations and its little editor, as in-app dialogs where they were asked from (the panel or the island).
enum ClipboardUI {
    static func setPersist(_ h: ClipboardHistory, _ on: Bool, from surface: DialogSurface = .panel) {
        if on { h.setPersist(true); return }
        DialogCenter.shared.present(Dialogs.clipPersist(surface)) { r in
            switch r.buttonID {
            case "delete": h.setPersist(false, wipe: true)
            case "keep": h.setPersist(false, wipe: false)
            default: break                                    // Cancel, Esc, a click elsewhere: still saving
            }
        }
    }

    static func confirmDeleteEverything(_ h: ClipboardHistory, from surface: DialogSurface = .panel) {
        DialogCenter.shared.present(Dialogs.clipDeleteAll(surface)) { r in
            guard r.buttonID == "delete" else { return }
            if !h.deleteEverything() {
                DialogCenter.shared.present(Dialogs.message(L("Some of it couldn't be deleted"), ClipStore.defaultDir.path, surface: surface)) { _ in }
            }
        }
    }

    static func addPattern(_ h: ClipboardHistory, from surface: DialogSurface = .panel) {
        DialogCenter.shared.present(Dialogs.clipPattern(surface)) { r in
            guard case .button("add", let text, _) = r else { return }
            let p = text.trimmingCharacters(in: .whitespaces)
            guard ClipRules.validPattern(p) else { return }       // the dialog doesn't let a bad one through; never saved anyway
            var s = h.settings
            if !s.patterns.contains(p) { s.patterns.append(p) }
            h.update(s)
        }
    }

    /// Apps that are open now and could be excluded: name and bundle id.
    static func runningApps(excluding: [String]) -> [(name: String, id: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { (a.localizedName ?? $0, $0) } }
            .filter { app in !excluding.contains(app.1) && !ClipRules.isPasswordApp(app.1) && app.1 != Bundle.main.bundleIdentifier }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            .map { (name: $0.0, id: $0.1) }
    }
}
