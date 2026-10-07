// Self-test groups run by --selftest and --dialogs-test (dialogs, design passes, power).

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

/// In-app dialogs (--dialogs-test, part of --selftest): the queue and the rules (Sources/InAppDialog.swift), then the app's real
/// dialogs and flows on a stand-in surface (a clipboard history in a temporary folder; nothing of the user's is touched).
func dialogsSelfTest(_ check: (String, Bool) -> Void) {
    DialogTests.pure(check)
    func key(_ s: DialogSpec, _ k: DialogLogic.Key, _ text: String = "") -> DialogLogic.Outcome {
        DialogLogic.key(s, k, text: text, choice: s.selected ?? s.choices.first?.id)
    }
    let link = Dialogs.links(URL(string: "cocaine://on?x=1")!)
    check("dialogs: the links question defaults to Don't Allow (Return refuses)", DialogLogic.defaultButton(link) == "deny" && key(link, .returnKey) == .finish(.cancelled))
    check("dialogs: …and only its Allow button grants", DialogLogic.press(link, "allow", text: "", choice: nil) == .finish(.button("allow", text: "", choice: nil)))
    check("dialogs: Return never deletes: clipboard history, saved copy, paired iPhones",
          key(Dialogs.clipDeleteAll(.panel), .returnKey) == .finish(.cancelled)
          && key(Dialogs.clipPersist(.panel), .returnKey) == .finish(.button("keep", text: "", choice: nil))
          && key(Dialogs.revokePhones(), .returnKey) == .finish(.cancelled))
    check("dialogs: pairing starts on the basic level and Return sends it",
          key(Dialogs.pairPhone(), .returnKey) == .finish(.button("send", text: "", choice: "basic")))
    let pattern = Dialogs.clipPattern(.panel)
    check("dialogs: a pattern is checked as it will be saved (spaces trimmed)", key(pattern, .returnKey, "  ^IBAN ") == .finish(.button("add", text: "  ^IBAN ", choice: nil)))
    check("dialogs: an invalid or empty pattern is refused in the dialog", key(pattern, .returnKey, "([") == .invalid(L("That isn't a valid pattern"))
          && key(pattern, .returnKey, "   ") == .invalid(L("That isn't a valid pattern")))
    let share = Dialogs.share(Sharing.services(for: [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]))
    check("dialogs: the share list ends with Show in Finder and has only Cancel to press",
          share.choices.last?.id == "finder" && share.choiceMode == .act && share.buttons.map(\.id) == ["cancel"])
    if let air = NSSharingService(named: .sendViaAirDrop)?.title, share.choices.contains(where: { $0.title == air }) {
        check("dialogs: AirDrop is the first way to share", share.choices.first?.title == air)
    }

    // The clipboard's flows, through the shared center on a stand-in surface: no NSAlert, the same outcomes as before.
    let center = DialogCenter.shared
    let (show, fallback) = (center.show, center.fallback)
    defer { center.show = show; center.fallback = fallback }
    var alerts = 0
    center.show = { $0 }
    center.fallback = { _ in alerts += 1; return .cancelled }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cocaine-dialogs-\(getpid())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let fb = FakePasteboard()
    let h = ClipboardHistory(defaults: MemoryDefaults(), dir: dir, keys: MemoryKeyStore(), board: fb)
    ClipboardUI.addPattern(h, from: .island)
    check("dialogs: the pattern editor shows in the island it was asked from", center.surface == .island && center.current?.spec.field != nil)
    center.text = "(["
    center.press("add")
    check("dialogs: a bad pattern keeps the editor open with the reason, nothing saved", center.current != nil && center.problem != nil && h.settings.patterns.isEmpty)
    center.text = "  ^IBAN  "
    _ = center.handle(.returnKey)
    check("dialogs: a good one is saved, trimmed", center.current == nil && h.settings.patterns == ["^IBAN"])
    ClipboardUI.addPattern(h)
    center.text = "secret"
    center.surfaceClosed(.panel)
    check("dialogs: closing the panel cancels the editor (nothing added)", center.current == nil && h.settings.patterns == ["^IBAN"])
    h.frontApp = { "com.apple.TextEdit" }
    fb.put(ClipSnapshot(types: ["public.utf8-plain-text"], text: "keep me"))
    h.captureNow()
    ClipboardUI.confirmDeleteEverything(h)
    _ = center.handle(.returnKey)
    check("dialogs: Return on Delete everything… keeps the history", h.items.count == 1 && center.current == nil)
    ClipboardUI.confirmDeleteEverything(h)
    center.press("delete")
    check("dialogs: Delete everything deletes it", h.items.isEmpty)
    check("dialogs: no system alert came up", alerts == 0)
}

/// The design pass (part of --selftest): the app's language reaches dates and durations, two-finger scrolling over a control
/// only steps it when the gesture started there, and the panel strip never puts a cell under the notch.
func designSelfTest(_ check: (String, Bool) -> Void) {
    let saved = Language.chosen
    defer { Language.set(saved, persist: false) }
    Language.set("de", persist: false)
    check("locale: German UI → German weekday names and relative times, whatever the Mac's language",
          Language.calendar.standaloneWeekdaySymbols.contains("Montag") && Language.locale.language.languageCode?.identifier == "de")
    let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .abbreviated; rel.locale = appLocale()
    check("locale: \"8 h ago\" is German in a German UI (\(rel.localizedString(for: Date().addingTimeInterval(-8 * 3600), relativeTo: Date())))",
          rel.localizedString(for: Date().addingTimeInterval(-8 * 3600), relativeTo: Date()).hasPrefix("vor"))
    Language.set("it", persist: false)
    check("durations: island, panel and agent list say it the same way (\(Dur.short(minutes: 30)), \(Dur.short(minutes: 120)), \(Dur.ago(seconds: 360)))",
          Dur.short(minutes: 30) == String(format: L("%d min"), 30) && Dur.short(minutes: 120) == String(format: L("%d h"), 2)
          && Dur.ago(seconds: 360) == String(format: L("%d min"), 6) && Dur.ago(seconds: 20) == L("now") && Dur.left(seconds: 7200) == String(format: L("%d h"), 2)
          && Dur.short(minutes: 150) == String(format: L("%d h"), 2) + " " + String(format: L("%d min"), 30) && Dur.short(minutes: 0) == "∞")
    check("numbers: token counts in the app's language (\(Dur.count(8_600_000, locale: Language.locale)))",
          Dur.count(8_600_000, locale: Language.locale).contains("8,6") && !Dur.count(8_600_000, locale: Locale(identifier: "en")).contains(","))
    check("strings: the agent state and the alert toggle are separate keys (no \"when it needs you\" as a state)",
          AgentListView.name("waiting") == L("Waiting for you") && L("Waiting for you") != L("Needs you"))
    check("strings: Focus's Break isn't the Pause button's word", L("Break") != L("Pause"))

    typealias C = ScrollSteps.Catcher
    var owned = false
    check("scroll steps: a gesture that starts over the control steps it", C.takes(phase: .began, momentum: [], over: true, owned: &owned)
          && C.takes(phase: .changed, momentum: [], over: true, owned: &owned))
    check("scroll steps: …not its momentum after the fingers lift", !C.takes(phase: [], momentum: .changed, over: true, owned: &owned))
    _ = C.takes(phase: .ended, momentum: [], over: true, owned: &owned)
    check("scroll steps: a panel scroll that slides across the control doesn't change it",
          !C.takes(phase: .began, momentum: [], over: false, owned: &owned) && !C.takes(phase: .changed, momentum: [], over: true, owned: &owned)
          && !C.takes(phase: .ended, momentum: [], over: true, owned: &owned))
    check("scroll steps: a mouse wheel steps only over the control", C.takes(phase: [], momentum: [], over: true, owned: &owned)
          && !C.takes(phase: [], momentum: [], over: false, owned: &owned))

    let strip = StripLayout.make(panelWidth: Layout.width, frameInset: Space.frame, contentInset: Space.l, notchWidth: 185, left: 3, right: 3)
    check("strip: on a 14\" notch (185 pt) back, General and AI alerts fit left of it, Automation, Island and Quit right of it",
          strip != nil && strip!.problems().isEmpty && strip!.leftCells.last!.upperBound <= 127.5 && strip!.rightCells.first!.lowerBound >= 312.5)
    designPass2SelfTest(check)
}

/// The second design pass (part of --selftest and --dialogs-test): in-app dropdowns instead of system menus, the panel's tabs,
/// one battery level, the approval countdown, the schedule's time steps.
func designPass2SelfTest(_ check: (String, Bool) -> Void) {
    ControlTests.pure(check)
    // Tabs: Island only while it is on; General and AI alerts left of the notch, Automation and Island right of it (+ back, Quit).
    check("tabs: General, AI alerts, Automation, Island while the island is on", PanelTabs.list(ai: true, island: true) == ["", "ai", "auto", "island"])
    check("tabs: no Island tab with the island off, no AI tab without an AI tool", PanelTabs.list(ai: false, island: false) == ["", "auto"])
    let split = PanelTabs.split(PanelTabs.list(ai: true, island: true))
    check("tabs: [‹][General][AI] | notch | [Automation][Island][Quit]", split.left == ["", "ai"] && split.right == ["auto", "island"])
    var stripsOK = true
    for notch: CGFloat in [150, 165, 185, 200, 210, 220] {
        for (ai, island) in [(true, true), (false, true)] {
            let (l, r) = PanelTabs.split(PanelTabs.list(ai: ai, island: island))
            if let s = StripLayout.make(panelWidth: Layout.width, frameInset: Space.frame, contentInset: Space.l, notchWidth: notch, left: 1 + l.count, right: r.count + 1) {
                if !s.problems().isEmpty { stripsOK = false }
            } else { stripsOK = false }
        }
    }
    check("tabs: every strip (150–220 pt notches, with and without AI) fits, nothing under the notch", stripsOK)
    // A dropdown's list after its boxes change: what stays keeps its order, what is new follows A–Z.
    check("dropdown: a changed list keeps the old order and appends the new A–Z",
          PanelView.merged(["Xcode", "Slack"], ["Slack", "Mail", "Arc"]) == ["Slack", "Arc", "Mail"] && PanelView.merged(["A"], []) == [])
    // One battery level: the power trigger lets go where Battery Guard acts.
    check("battery: the power trigger lets go at Battery Guard's level (10 % with the guard off)",
          PowerRule.batteryFloor(guardLevel: 20) == 20 && PowerRule.batteryFloor(guardLevel: 0) == 10
          && PowerRule.met(rule: "battery", onAC: false, battery: 21, minimum: PowerRule.batteryFloor(guardLevel: 20)) == true
          && PowerRule.met(rule: "battery", onAC: false, battery: 20, minimum: PowerRule.batteryFloor(guardLevel: 20)) == false)
    // Why it's on.
    check("status: who turned it on, by name", TriggerWords.reason([.apps: true, .power: false], apps: ["Xcode"], power: "ac") == "Xcode"
          && TriggerWords.reason([.agents: true, .power: true], apps: [], power: "ac") == L("AI") + ", " + L("Charger")
          && TriggerWords.reason([.apps: false], apps: [], power: "") == nil)
    // Approvals: the time left before the terminal asks instead, never negative.
    let now = Date()
    check("approvals: the countdown says how long until the terminal asks (1:42, 0:05, 0:00)",
          AgentListView.countdown(now.addingTimeInterval(102), now: now) == "1:42" && AgentListView.countdown(now.addingTimeInterval(4.2), now: now) == "0:05"
          && AgentListView.countdown(now.addingTimeInterval(-3), now: now) == "0:00")
    check("approvals: Allow is the filled button, Deny and Decline are grey",
          AgentListView.kind(ApprovalChoice(label: "allow", decision: "allow"), index: 0) == .primary
          && AgentListView.kind(ApprovalChoice(label: "deny", decision: "deny"), index: 1) == .secondary
          && AgentListView.kind(ApprovalChoice(label: "decline", decision: "decline"), index: 0) == .secondary)
    // The schedule's times: steps of 15 minutes around midnight; an odd time lands on the grid first.
    check("schedule: time steps of 15 min, wrapping at midnight", TimeStepper.stepped(540, by: 1) == 555 && TimeStepper.stepped(0, by: -1) == 1425
          && TimeStepper.stepped(1425, by: 1) == 0 && TimeStepper.stepped(545, by: 1) == 555 && TimeStepper.stepped(545, by: -1) == 540)
    // The removed confirmations: irreversible or security-lowering actions ask first, and Return is the safe answer.
    let remove = Dialogs.removeOldShortcuts(), allow = Dialogs.allowOldShortcuts()
    check("dialogs: removing old Shortcuts asks first; Return keeps them", DialogLogic.defaultButton(remove) == "cancel"
          && DialogLogic.key(remove, .returnKey, text: "", choice: nil) == .finish(.cancelled) && DialogLogic.drawOrder(remove).last?.id == "cancel")
    check("dialogs: accepting unprotected Shortcuts asks first; Return says no", DialogLogic.defaultButton(allow) == "cancel"
          && DialogLogic.key(allow, .returnKey, text: "", choice: nil) == .finish(.cancelled)
          && DialogLogic.press(allow, "allow", text: "", choice: nil) == .finish(.button("allow", text: "", choice: nil)))
    check("dialogs: the links question draws [Allow] [Don't Allow]: the safe default rightmost and the only filled one",
          DialogLogic.drawOrder(Dialogs.links(URL(string: "cocaine://on")!)).map(\.id) == ["allow", "deny"]
          && DialogLogic.kind(Dialogs.links(URL(string: "cocaine://on")!), DialogButton(id: "allow", title: "")) == .secondary)
    check("motion: Reduce Motion turns the morph into a short fade and the flashes into one soft tint",
          Motion.flashes(reduce: true) == [0.18, 0] && Motion.flashes(reduce: false) == [0.55, 0, 0.55, 0])
    check("strings: \"Not paused\" (not \"Off\") when alerts aren't paused", L("Not paused") != L("Off"))
}


/// Smart Triggers on power, displays and schedules; screen-off mode; control links (part of --selftest).
func powerSelfTest(_ check: (String, Bool) -> Void) {
    func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    var rome = Calendar(identifier: .gregorian); rome.timeZone = TimeZone(identifier: "Europe/Rome")!
    var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let work = TimeWindow(days: [2, 3, 4, 5, 6], start: 9 * 60, end: 18 * 60)
    check("schedule: Monday 10:00 is inside 9–18 on weekdays", work.contains(at("2026-10-05T08:00:00Z"), calendar: rome))
    check("schedule: the end time itself is outside", !work.contains(at("2026-10-05T16:00:00Z"), calendar: rome))
    check("schedule: one minute before the start is outside", !work.contains(at("2026-10-05T06:59:00Z"), calendar: rome))
    check("schedule: Saturday is outside", !work.contains(at("2026-10-10T08:00:00Z"), calendar: rome))
    let night = TimeWindow(days: [6], start: 22 * 60, end: 6 * 60)       // Friday night
    check("schedule: past midnight, Friday 23:00 is inside", night.contains(at("2026-10-09T21:00:00Z"), calendar: rome))
    check("schedule: past midnight, Saturday 02:00 still belongs to Friday", night.contains(at("2026-10-10T00:00:00Z"), calendar: rome))
    check("schedule: past midnight, Saturday 23:00 is outside", !night.contains(at("2026-10-10T21:00:00Z"), calendar: rome))
    check("schedule: past midnight, Friday 02:00 belongs to Thursday (not chosen)", !night.contains(at("2026-10-09T00:00:00Z"), calendar: rome))
    check("schedule: start == end is the whole day", TimeWindow(days: [2], start: 600, end: 600).contains(at("2026-10-05T02:00:00Z"), calendar: rome))
    check("schedule: no day chosen, never", !TimeWindow(days: [], start: 0, end: 600).contains(at("2026-10-05T02:00:00Z"), calendar: rome))
    // DST in Rome: 29 March 2026 02:00 → 03:00, 25 October 2026 03:00 → 02:00.
    let early = TimeWindow(days: [1], start: 150, end: 240)                 // Sunday 02:30–04:00
    check("schedule: DST spring forward, a window starting in the skipped hour still runs (03:10)", early.contains(at("2026-03-29T01:10:00Z"), calendar: rome))
    check("schedule: DST spring forward, 01:59 is before it", !early.contains(at("2026-03-29T00:59:00Z"), calendar: rome))
    let fall = TimeWindow(days: [1], start: 120, end: 180)                  // Sunday 02:00–03:00
    check("schedule: DST fall back, 02:30 summer time is inside", fall.contains(at("2026-10-25T00:30:00Z"), calendar: rome))
    check("schedule: DST fall back, 02:30 winter time (the repeated hour) is inside too", fall.contains(at("2026-10-25T01:30:00Z"), calendar: rome))
    check("schedule: DST fall back, 03:05 winter time is outside", !fall.contains(at("2026-10-25T02:05:00Z"), calendar: rome))
    check("schedule: read on the local wall clock (time zone)", work.contains(at("2026-10-05T10:00:00Z"), calendar: rome)
          && !work.contains(at("2026-10-05T10:00:00Z"), calendar: tokyo))

    var arb = TriggerArbiter()
    check("arbiter: any, one is enough", arb.evaluate([.agents: false, .schedule: true], all: false).active)
    check("arbiter: all, one false is not enough", !arb.evaluate([.agents: false, .schedule: true], all: true).active)
    check("arbiter: all, every one true", arb.evaluate([.agents: true, .schedule: true], all: true).active)
    check("arbiter: nothing enabled is never active", !arb.evaluate([:], all: true).active && !arb.evaluate([:], all: false).active)
    var g1 = TriggerArbiter(); _ = g1.evaluate([.apps: true, .schedule: true], all: false)
    check("arbiter: any, the longest grace of what was holding it", g1.evaluate([.apps: false, .schedule: false], all: false).grace == 180)
    var g2 = TriggerArbiter(); _ = g2.evaluate([.apps: true, .schedule: true], all: true)
    check("arbiter: all, a schedule ending ends it at once", g2.evaluate([.apps: true, .schedule: false], all: true).grace == 0)
    var g3 = TriggerArbiter(); _ = g3.evaluate([.apps: true, .schedule: true], all: true)
    check("arbiter: all, an app closing gets its grace", g3.evaluate([.apps: false, .schedule: true], all: true).grace == 180)
    var g4 = TriggerArbiter()
    let blocked = g4.evaluate([.power: true], all: false, blocked: true)
    check("arbiter: a low battery blocks every trigger", !blocked.active && blocked.grace == 0)
    // A schedule turns Cocaine on and off on time; the user's OFF wins until the window ends.
    var s = AutoOn(); let t0 = Date()
    check("schedule trigger: on at the start", s.step(active: true, isOn: false, now: t0, grace: 0) == .turnOn)
    check("schedule trigger: off right at the end", s.step(active: false, isOn: true, now: t0 + 3600, grace: 0) == .turnOff)
    var u = AutoOn()
    _ = u.step(active: true, isOn: false, now: t0, grace: 0)
    u.userToggled(to: false, triggerActive: true)
    check("schedule trigger: the user's OFF holds for the rest of the window", u.step(active: true, isOn: false, now: t0 + 60, grace: 0) == .none)
    check("schedule trigger: …and the next window turns it on again", u.step(active: false, isOn: false, now: t0 + 3600, grace: 0) == .none
          && u.step(active: true, isOn: false, now: t0 + 86400, grace: 0) == .turnOn)
    // Turned off from outside (`cocaine off`, `cocaine remote off`) while a trigger holds it: counts as the user's OFF.
    check("outside change: an OFF Cocaine didn't make is seen", AppDelegate.isOutsideChange(last: true, now: false, requested: true, pending: nil))
    check("outside change: our own OFF is not", !AppDelegate.isOutsideChange(last: true, now: false, requested: false, pending: nil)
          && !AppDelegate.isOutsideChange(last: true, now: false, requested: true, pending: false))
    check("outside change: the first reading is not a change", !AppDelegate.isOutsideChange(last: nil, now: true, requested: nil, pending: nil))
    var x = AutoOn()
    _ = x.step(active: true, isOn: false, now: t0)
    if AppDelegate.isOutsideChange(last: true, now: false, requested: true, pending: nil) { x.userToggled(to: false, triggerActive: true) }
    check("outside change: a trigger doesn't turn it back on at once", x.step(active: true, isOn: false, now: t0 + 5) == .none)

    check("power: on the charger", PowerRule.met(rule: "ac", onAC: true, battery: 50, minimum: 20) == true
          && PowerRule.met(rule: "ac", onAC: false, battery: 50, minimum: 20) == false)
    check("power: on battery above the level", PowerRule.met(rule: "battery", onAC: false, battery: 50, minimum: 20) == true)
    check("power: on battery at or below the level lets go", PowerRule.met(rule: "battery", onAC: false, battery: 20, minimum: 20) == false)
    check("power: on battery, but plugged in, or no battery", PowerRule.met(rule: "battery", onAC: true, battery: 90, minimum: 20) == false
          && PowerRule.met(rule: "battery", onAC: true, battery: nil, minimum: 20) == false)
    check("power: off is not a trigger", PowerRule.met(rule: "", onAC: true, battery: 50, minimum: 20) == nil)
    check("display: connected / not connected", DisplayRule.met(rule: "connected", external: 1) == true && DisplayRule.met(rule: "connected", external: 0) == false
          && DisplayRule.met(rule: "disconnected", external: 0) == true && DisplayRule.met(rule: "", external: 2) == nil)

    // Stay active nudges every ~10 s after 45 s idle: the system idle never passes ~55 s, so a 1-minute dim never came.
    var ri = RealIdle(); var sysLast = t0; var maxSys = 0.0, real = 0.0
    for sec in stride(from: 0.0, through: 300, by: 1) {
        let now = t0 + sec
        var sys = now.timeIntervalSince(sysLast)
        if sys > 45 && Int(sec) % 10 == 0 { sysLast = now; ri.lastNudge = now; sys = 0 }
        maxSys = max(maxSys, sys)
        real = ri.update(systemIdle: sys, now: now)
    }
    check("idle: with Stay active the system idle stays under a minute (the old dimming never fired)", maxSys < 60)
    check("idle: the user's own idle keeps counting through the nudges", real >= 299)
    check("idle: real input starts it again", ri.update(systemIdle: 0, now: t0 + 400) < 1)

    var gate = ScreenOffGate()
    check("screen off: not before the delay", !gate.step(idle: 50, delay: 60, enabled: true, on: true, asleep: false))
    check("screen off: at the delay, once", gate.step(idle: 60, delay: 60, enabled: true, on: true, asleep: false)
          && !gate.step(idle: 90, delay: 60, enabled: true, on: true, asleep: false))
    check("screen off: again after the user came back and left", !gate.step(idle: 1, delay: 60, enabled: true, on: true, asleep: false)
          && gate.step(idle: 61, delay: 60, enabled: true, on: true, asleep: false))
    var gate2 = ScreenOffGate()
    check("screen off: only while Cocaine is on", !gate2.step(idle: 999, delay: 60, enabled: true, on: false, asleep: false))
    check("screen off: waits while an alert keeps the screen lit", !gate2.step(idle: 999, delay: 60, enabled: true, on: true, allowed: false, asleep: false)
          && gate2.step(idle: 999, delay: 60, enabled: true, on: true, allowed: true, asleep: false))
    var gate3 = ScreenOffGate()
    check("screen off: displays already asleep are left alone", !gate3.step(idle: 99, delay: 60, enabled: true, on: true, asleep: true) && gate3.fired)

    var heat = HeatGuard()
    check("heat: lid closed, on battery, serious → off, once", heat.check(lidClosed: true, onAC: false, thermal: .serious)
          && !heat.check(lidClosed: true, onAC: false, thermal: .critical))
    check("heat: lid open or on the charger is left alone", { var h = HeatGuard(); return !h.check(lidClosed: false, onAC: false, thermal: .critical)
        && !h.check(lidClosed: true, onAC: true, thermal: .critical) && !h.check(lidClosed: true, onAC: false, thermal: .fair) }())

    func parse(_ s: String) -> Result<ControlRequest, ControlURL.Failure> { ControlURL.parse(URL(string: s)!) }
    check("link: on for 90 minutes", (try? parse("cocaine://on?minutes=90").get())?.action == .on(minutes: 90))
    check("link: off, toggle and status", (try? parse("cocaine://off").get())?.action == .off && (try? parse("cocaine://TOGGLE").get())?.action == .toggle
          && (try? parse("cocaine://status").get())?.action == .status)
    check("link: minutes out of range or not a number are refused", [0, 1441, 99999].allSatisfy { parse("cocaine://on?minutes=\($0)") == .failure(.badMinutes) }
          && parse("cocaine://timer?minutes=abc") == .failure(.badMinutes) && parse("cocaine://timer?minutes=-5") == .failure(.badMinutes)
          && parse("cocaine://timer?minutes=1e3") == .failure(.badMinutes))
    check("link: unknown commands and other schemes are refused", parse("cocaine://sleepnow") == .failure(.unknown("sleepnow"))
          && parse("http://on") == .failure(.notOurs))
    check("link: x-callback-url status with a Shortcuts callback",
          (try? parse("cocaine://x-callback-url/status?x-success=shortcuts%3A%2F%2Fx-callback-url%2Fic-success%3Fid%3D1").get())?.success?.scheme == "shortcuts")
    check("link: a callback to anything but Shortcuts is dropped",
          (try? parse("cocaine://x-callback-url/status?x-success=https%3A%2F%2Fevil.example%2F&x-error=javascript:alert(1)").get()).map { $0.success == nil && $0.failure == nil } == true)
    check("link: a callback can't run a shortcut or open anything else in Shortcuts",
          ["shortcuts://x-callback-url/run-shortcut?name=Evil", "shortcuts://x-callback-url/open-shortcut?name=x",
           "shortcuts://x-callback-url/create-shortcut", "shortcuts://run-shortcut?name=Evil", "shortcuts://x-callback-url", "shortcuts://"]
            .allSatisfy { ControlURL.callback($0) == nil })
    check("link: Shortcuts' own answer address is accepted", ControlURL.callback("shortcuts://x-callback-url/ic-success?id=1") != nil)
    check("link: changing commands need permission, status and panel don't",
          ControlAction.on(minutes: nil).guarded && ControlAction.off.guarded && ControlAction.pause(minutes: nil).guarded
          && !ControlAction.status.guarded && !ControlAction.panel.guarded)
    let reply = ControlURL.reply(URL(string: "shortcuts://x-callback-url/ic-success?id=1")!, [("state", "on&evil=1")])
    check("link: reply values are encoded, never spliced", URLComponents(url: reply!, resolvingAgainstBaseURL: false)?.queryItems?.count == 2
          && URLComponents(url: reply!, resolvingAgainstBaseURL: false)?.queryItems?.last?.value == "on&evil=1")
    let st = Dictionary(uniqueKeysWithValues: ControlURL.status(on: true, until: t0 + 90.5 * 60, now: t0, screenOff: true, trigger: false))
    check("link: status says on, minutes left (rounded up) and the mode", st["state"] == "on" && st["remaining_minutes"] == "91" && st["screen_off_mode"] == "1")
    let off = Dictionary(uniqueKeysWithValues: ControlURL.status(on: false, until: t0 + 600, now: t0, screenOff: false, trigger: false))
    check("link: status when off has no deadline", off["state"] == "off" && off["remaining_minutes"] == "" && off["until"] == "")
}
