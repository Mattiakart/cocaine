// Test flags: --selftest, --agents-test, --layout-test, --remote-test, --dialogs-test, and the self-test groups (dialogs, design passes, power).

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
    let dropped: ControlRequest? = try? parse("cocaine://x-callback-url/status?x-success=https%3A%2F%2Fevil.example%2F&x-error=javascript:alert(1)").get()
    check("link: a callback to anything but Shortcuts is dropped", dropped != nil && dropped?.success == nil && dropped?.failure == nil)
    let evilCallbacks: [String] = ["shortcuts://x-callback-url/run-shortcut?name=Evil", "shortcuts://x-callback-url/open-shortcut?name=x",
                                   "shortcuts://x-callback-url/create-shortcut", "shortcuts://run-shortcut?name=Evil", "shortcuts://x-callback-url", "shortcuts://"]
    check("link: a callback can't run a shortcut or open anything else in Shortcuts", evilCallbacks.allSatisfy { ControlURL.callback($0) == nil })
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

/// `--agents-test`, run from main.swift.
func cliAgentsTest() {
    // AI sessions: the pure logic, the approval protocol over a real socket with this binary as the hook, and the hooks
    // written into a temporary home (never the real ~/.claude or ~/.codex). PASS/FAIL lines, exit status.
    var failed = 0
    func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    AgentTests.pure(check)
    AgentTests.protocolTests(binary: exe, check)
    let home = AgentTests.tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    AIHooks.home = home.path
    AIHooks.binary = "/Applications/Cocaine.app/Contents/MacOS/Cocaine"
    AIHooks.assumeClaudeVersion([2, 1, 100])
    for d in [".claude", ".codex"] { try? FileManager.default.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true) }
    let settingsPath = home.appendingPathComponent(".claude/settings.json").path
    let mine = #"{"model":"opus","hooks":{"PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-guard.sh"}]}]}}"#
    try? mine.write(toFile: settingsPath, atomically: true, encoding: .utf8)
    let claude = AIHooks.tool("claude")!, codex = AIHooks.tool("codex")!
    func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func commands(_ path: String, _ event: String) -> [String] {
        (AIHooks.load(path)?["hooks"]?[event]?.items ?? []).flatMap { $0["hooks"]?.items ?? [] }.compactMap {
            if case .scalar(let s)? = $0["command"] { return (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed)) as? String }
            return nil
        }
    }
    check("hooks: on (temporary home)", AIHooks.set(true, only: [claude, codex]).isEmpty)
    let pr = commands(settingsPath, "PermissionRequest")
    check("hooks: Claude Code's PermissionRequest runs the app's binary next to the user's own hook",
          pr.count == 2 && pr.contains("my-guard.sh") && pr.contains { $0.contains("'/Applications/Cocaine.app/Contents/MacOS/Cocaine' --agent-request claude") })
    check("hooks: the request hook may wait for the notch (timeout \(ApprovalTiming.config) s)", text(settingsPath).contains("\"timeout\": \(ApprovalTiming.config)"))
    check("hooks: MCP questions (Elicitation) too, and the alerts as before",
          commands(settingsPath, "Elicitation").count == 1 && commands(settingsPath, "Notification").count == 1 && commands(settingsPath, "Stop").count == 1)
    check("hooks: alert commands also send where the session runs", commands(settingsPath, "Stop").first?.contains("\"$PPID\"") == true)
    let once = text(settingsPath)
    _ = AIHooks.set(true, only: [claude, codex])
    check("hooks: turning on twice changes nothing", text(settingsPath) == once)
    check("hooks: Codex's PermissionRequest runs the binary as well",
          commands(codex.file, "PermissionRequest").first?.contains("--agent-request codex") == true)
    check("hooks: off", AIHooks.set(false, only: [claude, codex]).isEmpty)
    let off = text(settingsPath)
    check("hooks: off removes only Cocaine's hooks; the user's own and their settings stay",
          !off.contains(AIHooks.marker) && commands(settingsPath, "PermissionRequest") == ["my-guard.sh"] && off.contains("\"model\": \"opus\""))
    _ = AIHooks.set(false, only: [claude, codex])
    check("hooks: off twice changes nothing", text(settingsPath) == off)
    AIHooks.assumeClaudeVersion([2, 0, 0])
    _ = AIHooks.set(true, only: [claude])
    check("hooks: an older Claude Code gets no request hooks it doesn't know",
          commands(settingsPath, "PermissionRequest") == ["my-guard.sh"] && commands(settingsPath, "Elicitation").isEmpty)
    AIHooks.assumeClaudeVersion([2, 1, 100])
    AIHooks.update()
    check("hooks: …and gets them once it's updated (at the app's launch)", commands(settingsPath, "PermissionRequest").count == 2)
    AIHooks.binary = nil
    _ = AIHooks.set(true, only: [claude, codex])
    check("hooks: without an installed app to run, no request hooks for Claude Code (its Notification alerts)",
          commands(settingsPath, "PermissionRequest") == ["my-guard.sh"])
    check("hooks: …and Codex's request just alerts as before", commands(codex.file, "PermissionRequest").first.map { $0.contains("event=input") && !$0.contains("--agent-request") } == true)
    _ = AIHooks.set(false, only: [claude, codex])

    // The origin the alert command sends, run by a real shell, read back by the app's own parser.
    AIHooks.binary = exe
    let stop = AIHooks.command(claude, "done")
    if let a = stop.range(of: "$(/usr/bin/perl -e 'sub e"), let b = stop.range(of: "\"$PPID\" 2>/dev/null)", range: a.upperBound..<stop.endIndex) {
        let snippet = String(stop[a.lowerBound..<b.upperBound])
        let odd = home.appendingPathComponent("my proj&x=1")
        try? FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "cd \"$1\" && x=" + snippet + "; printf %s \"$x\"", "sh", odd.path]
        p.environment = ["TMUX_PANE": "%7", "TMUX": "/private/tmp/tmux-501/default,123,0", "__CFBundleIdentifier": "com.googlecode.iterm2",
                         "ITERM_SESSION_ID": "w0t1p0:ABCDEF12-0000-1111", "TERM_PROGRAM": "iTerm.app", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let q = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let got = AlertParams.parse(URL(string: "cocaine://alert?from=Claude%20Code&event=done" + q)!).origin
        check("hooks: the session's origin survives the shell, the URL and the parser (\(q.prefix(60))…)",
              got.cwd == odd.resolvingSymlinksInPath().path || got.cwd == odd.path)
        check("hooks: …with its terminal app, iTerm2 session, tmux pane and socket, and the agent's pid",
              got.app == "com.googlecode.iterm2" && got.termSession == "ABCDEF12-0000-1111" && got.tmuxPane == "%7"
              && got.tmuxSocket == "/private/tmp/tmux-501/default" && got.pid == getpid())
    } else { check("hooks: the alert command carries the origin snippet", false) }

    // The exact request-hook command, run by a real shell against a real socket.
    let support = AgentTests.tempDir()
    defer { try? FileManager.default.removeItem(at: support) }
    if let key = ApprovalKey.loadOrCreate(AgentPaths.key(support)) {
        let server = ApprovalServer(path: AgentPaths.socket(support), key: key)
        server.onRequest = { id, _, _, _, _ in server.reply(id, decision: "deny", content: nil) }
        try? server.start()
        let cmd = AIHooks.command(claude, "approve")
        let r = AgentTests.runHook(["-c", cmd], executable: "/bin/sh", input: AgentTests.sampleInput, support: support)
        check("hooks: the installed request command, run by sh, returns the notch's answer", r.out.contains(#""behavior":"deny""#) && r.status == 0)
        server.stop()
        let none = AgentTests.runHook(["-c", cmd], executable: "/bin/sh", input: AgentTests.sampleInput, support: support)
        check("hooks: …and nothing, exit 0, when the app isn't there", none.out.isEmpty && none.status == 0)
        let moved = AgentTests.runHook(["-c", cmd.replacingOccurrences(of: exe, with: "/nonexistent/Cocaine")], executable: "/bin/sh",
                                       input: AgentTests.sampleInput, support: support)
        check("hooks: …and when the app was moved away (exit 0, no decision)", moved.out.isEmpty && moved.status == 0)
    }
    exit(failed == 0 ? 0 : 1)
}

/// `--layout-test`, run from main.swift.
func cliLayoutTest() {
    // Where the panel lands for a click on the icon of each screen, for two-monitor layouts.
    let size = NSSize(width: Layout.width, height: 198)
    let layouts: [(String, NSRect, CGFloat)] = [   // name, visible frame (below its menu bar), click x
        ("MacBook, icon near right edge", NSRect(x: 0, y: 0, width: 1512, height: 945), 1460),
        ("external on the right",         NSRect(x: 1512, y: -200, width: 2560, height: 1415), 3900),
        ("external on the left",          NSRect(x: -1920, y: 0, width: 1920, height: 1055), -60),
        ("external above",                NSRect(x: 0, y: 982, width: 1920, height: 1055), 1850),
    ]
    for (name, vis, x) in layouts {
        let f = AppDelegate.panelFrame(size: size, anchorX: x, top: vis.maxY - 6, visible: vis)
        print("\(name): panel \(f.debugDescription)  inside that screen: \(vis.contains(f))")
    }
    // The panel's top strip on other Macs' notches (14" ≈ 185 pt; scaled resolutions make it narrower or wider): no cell under
    // the notch, all inside the frame, none narrower than 24 pt; with and without the AI tab. Too wide a notch: no strip (nil),
    // the panel then shows its tabs as a segmented control, which is also fine.
    var stripFailures = 0
    for notch: CGFloat in [150, 165, 185, 200, 210, 220] {
        for left in [2, 3] {      // back + General (+ AI alerts) | Automation + Island + Quit
            guard let s = StripLayout.make(panelWidth: Layout.width, frameInset: Space.frame, contentInset: Space.l, notchWidth: notch, left: left, right: 3) else {
                print("FAIL  strip, notch \(Int(notch)) pt, \(left)+3 cells: doesn't fit"); stripFailures += 1; continue
            }
            let p = s.problems()
            if !p.isEmpty { stripFailures += 1 }
            print("\(p.isEmpty ? "PASS" : "FAIL")  strip, notch \(Int(notch)) pt, \(left)+3 cells: cell \(s.cell), highlight \(s.highlight), left \(s.leftCells.map { "\($0.lowerBound)…\($0.upperBound)" }), right \(s.rightCells.map { "\($0.lowerBound)…\($0.upperBound)" })" + (p.isEmpty ? "" : " " + p.joined(separator: "; ")))
        }
    }
    let tooWide = StripLayout.make(panelWidth: Layout.width, frameInset: Space.frame, contentInset: Space.l, notchWidth: 300, left: 3, right: 2)
    print(tooWide == nil ? "PASS  strip, notch 300 pt: no strip (tabs fall back to the segmented control)" : "FAIL  strip, notch 300 pt: cells of \(tooWide!.cell) pt")
    if tooWide != nil { stripFailures += 1 }
    // The old layout (4 cells of 38 pt left of a 185 pt notch) must be refused: it put the Automation tab under the notch.
    let old = StripLayout(panelWidth: Layout.width, frameInset: Space.frame, notchWidth: 185, cell: 38, side: 113.5, edgeInset: 4, left: 4, right: 2)
    print(old.problems().isEmpty ? "FAIL  strip: the old 4×38 pt layout isn't caught" : "PASS  strip: the old 4×38 pt layout is caught (\(old.problems()[0]))")
    if old.problems().isEmpty { stripFailures += 1 }
    exit(stripFailures == 0 ? 0 : 1)
}

/// `--remote-test`, run from main.swift.
func cliRemoteTest() {
    // Remote control protocol, Shortcut and listener tests only (also part of --selftest).
    var failed = 0
    RemoteTests.run(gate: Bundle.main.path(forResource: "remote", ofType: "zsh")) { name, ok in
        print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 }
    }
    exit(failed == 0 ? 0 : 1)
}

/// `--selftest`, run from main.swift.
func cliSelfTest() {
    // The pure automation logic: battery guard, smart triggers, agent board. Prints PASS/FAIL lines.
    var failed = 0
    func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
    check("launch: an alert-only launch that adopted a session (update hand-over, crash) runs on as the app",
          !Recovery.alertOnly(launchedForAlert: true, adoptedSession: true) && Recovery.alertOnly(launchedForAlert: true, adoptedSession: false)
          && !Recovery.alertOnly(launchedForAlert: false, adoptedSession: false))
    setenv("COCAINE_PROBE_SUDO", "/tmp/evil", 1)
    check("launch: test overrides are dropped from the app's environment (and its children's)",
          TestOverrides.scrub(prefix: "COCAINE_PROBE") == ["COCAINE_PROBE_SUDO"] && Recovery.env["COCAINE_PROBE_SUDO"] == nil && getenv("COCAINE_PROBE_SUDO") == nil)
    do {   // phones.json: never written over when it can't be read; private from the first byte
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-phones-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("phones.json")
        let p1 = Pairing.make(tier: "basic", relay: "https://relay.test")!
        check("phones: missing file = no pairings", PhoneLink.loadChecked(f) == [] && PhoneLink.loadForChange(f) == [])
        check("phones: saved 0600 in a 0700 folder and read back", PhoneLink.save([p1], to: f) && PhoneLink.load(f) == [p1]
              && (try? FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int) == 0o600
              && (try? FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) == 0o700)
        try? Data("{ not json".utf8).write(to: f)
        check("phones: a damaged file reads as 'unknown', not as no pairings", PhoneLink.loadChecked(f) == nil)
        let changed = PhoneLink.loadForChange(f)
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasPrefix("phones.unreadable-") } ?? []
        check("phones: …a change starts empty but the damaged file is kept aside, never overwritten",
              changed == [] && kept.count == 1 && (try? String(contentsOf: dir.appendingPathComponent(kept[0]), encoding: .utf8)) == "{ not json")
    }
    var g = BatteryGuard()
    check("battery: off threshold never fires", !g.check(percent: 5, onAC: false, threshold: 0))
    check("battery: above threshold is quiet", !g.check(percent: 40, onAC: false, threshold: 20))
    check("battery: fires at the threshold", g.check(percent: 20, onAC: false, threshold: 20))
    check("battery: fires only once while it stays low", !g.check(percent: 15, onAC: false, threshold: 20))
    check("battery: not re-armed by a small recovery", !g.check(percent: 22, onAC: false, threshold: 20) && !g.check(percent: 19, onAC: false, threshold: 20))
    check("battery: plugging in re-arms it", !g.check(percent: 19, onAC: true, threshold: 20) && g.check(percent: 19, onAC: false, threshold: 20))
    check("battery: never fires on power", { var x = BatteryGuard(); return !x.check(percent: 3, onAC: true, threshold: 30) }())
    do {   // after an update or a crash the new instance adopts the session: a trigger's ON stays the trigger's
        var fresh = AutoOn(), resumed = AutoOn(); let t = Date()
        resumed.resume(now: t)
        check("triggers: an adopted trigger ON ends with its trigger (after the grace); without it, it would stay on forever",
              resumed.step(active: false, isOn: true, now: t.addingTimeInterval(60)) == .none
              && resumed.step(active: false, isOn: true, now: t.addingTimeInterval(200)) == .turnOff
              && fresh.step(active: false, isOn: true, now: t.addingTimeInterval(200)) == .none)
    }
    var a = AutoOn(); let t0 = Date()
    check("trigger: nothing active, nothing to do", a.step(active: false, isOn: false, now: t0) == .none)
    check("trigger: active and off → turn on", a.step(active: true, isOn: false, now: t0) == .turnOn)
    check("trigger: stays on while active", a.step(active: true, isOn: true, now: t0 + 60) == .none)
    check("trigger: waits out the grace period", a.step(active: false, isOn: true, now: t0 + 120) == .none)
    check("trigger: off after 3 quiet minutes", a.step(active: false, isOn: true, now: t0 + 61 + 180) == .turnOff)
    var b = AutoOn()
    _ = b.step(active: true, isOn: false, now: t0)
    b.userToggled(to: false, triggerActive: true)
    check("trigger: user's OFF is respected while active", b.step(active: true, isOn: false, now: t0 + 10) == .none)
    check("trigger: …until the trigger has gone away", b.step(active: false, isOn: false, now: t0 + 20) == .none && b.step(active: true, isOn: false, now: t0 + 30) == .turnOn)
    var c = AutoOn()
    check("trigger: a manual ON is never turned off by it", { _ = c.step(active: true, isOn: true, now: t0); return c.step(active: false, isOn: true, now: t0 + 999) == .none }())
    var d = AutoOn()
    _ = d.step(active: true, isOn: false, now: t0)
    d.userToggled(to: true, triggerActive: true)
    check("trigger: user takes over an auto-on", d.step(active: false, isOn: true, now: t0 + 999) == .none)
    powerSelfTest(check)
    displaySelfTest(check)                         // dimming and the lid, keys, island screen, battery floor, DDC (DisplayTests.swift)
    let board = AgentBoard(); let now = Date()
    board.set("s1", from: "Claude Code", project: "x", state: "working", now: now)
    board.set("s2", from: "Codex", project: nil, state: "waiting", now: now)
    check("board: working and waiting are live", board.anyLive(now))
    board.set("s1", from: "Claude Code", project: "x", state: "done", now: now)
    board.set("s2", from: "Codex", project: nil, state: "done", now: now)
    check("board: nothing live when all are done", !board.anyLive(now))
    board.prune(now.addingTimeInterval(1900))
    check("board: finished sessions fade after 30 minutes", board.entries.isEmpty)
    board.set("s3", from: "Gemini CLI", project: nil, state: "working", now: now)
    board.prune(now.addingTimeInterval(7300))
    check("board: a 'working' nobody updated for 2 hours is dropped", board.entries.isEmpty)
    check("hud: this process is not mistaken for the system helper", !SystemHUD.helperPIDs().contains(getpid()))
    check("hud: volume-up key down is decoded", MediaKeys.decode(data1: (0 << 16) | (0xA << 8))?.down == true)
    check("hud: brightness-down key up is decoded", { let k = MediaKeys.decode(data1: (3 << 16) | (0xB << 8)); return k?.key == 3 && k?.down == false }())
    check("hud: other keys are ignored", MediaKeys.decode(data1: (16 << 16) | (0xA << 8)) == nil)
    do {   // a key left to macOS must keep its release, or macOS repeats it forever (brightness running up by itself)
        var t = MediaKeyTracker()
        check("hud: a key we handled has its release swallowed too", t.down(2, handled: true) && t.up(2))
        check("hud: …but only once", !t.up(2))
        check("hud: a key left to macOS keeps its release (not swallowed)", !t.down(2, handled: false) && !t.up(2))
        check("hud: a release with no press seen is never swallowed", !t.up(3))
        _ = t.down(2, handled: true)
        check("hud: auto-repeat then a pass-through: the release goes to macOS", !t.down(2, handled: false) && !t.up(2))
        _ = t.down(0, handled: true)
        check("hud: keys are tracked separately", !t.up(2) && t.up(0))
    }
    check("wake: date in pmset's format", WakeSchedule.format(Date(timeIntervalSince1970: 1_790_000_000)).range(of: "^\\d\\d/\\d\\d/\\d\\d \\d\\d:\\d\\d:\\d\\d$", options: .regularExpression) != nil)
    check("wake: the sudo rule allows only schedule wake/cancel wake, tagged cocaine",
          Authorization.installCommand(user: "u")?.contains("/usr/bin/pmset schedule wake * cocaine, /usr/bin/pmset schedule cancel wake * cocaine,") == true)
    do {   // the one-time authorization: how its outcome is read (the old code never saw the "rc=" line after `exit`)
        let dir = NSTemporaryDirectory() + "cocaine-auth-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dest = dir + "/rule"
        let cmd = Authorization.installCommand(user: NSUserName(), dest: dest, asRoot: false)!
        check("auth: the install command ends with exit (the case the old report missed)", cmd.hasSuffix("exit $r"))
        check("auth: a successful install is reported as success", Authorization.runPlain(cmd) && FileManager.default.fileExists(atPath: dest))
        check("auth: a failing install is reported as failure", !Authorization.runPlain("exit 3"))
        check("auth: a failure inside the install (bad destination) is reported as failure",
              !Authorization.runPlain(Authorization.installCommand(user: NSUserName(), dest: dir + "/no/such/dir/rule", asRoot: false)!))
        check("auth: no report line (cancelled, killed) is a failure", !Authorization.succeeded("") && !Authorization.succeeded("garbage\n"))
        check("auth: only rc=0 is success", Authorization.succeeded("rc=0\n") && !Authorization.succeeded("rc=1\n") && !Authorization.succeeded("rc=10\n"))
        check("auth: noise before the report is ignored", Authorization.succeeded("warning\nrc=0\n"))
        try? FileManager.default.removeItem(atPath: dest)
        check("auth: retry after a failure works", Authorization.runPlain(cmd) && FileManager.default.fileExists(atPath: dest))
        check("auth: a user name with shell characters is refused", Authorization.installCommand(user: "a; rm -rf /") == nil)
    }
    check("wake: sleep/wake notifications can be registered", SleepWatcher().start())
    check("relay: a message event is read", RemoteListener.message(#"{"id":"a","time":1790000000,"event":"message","message":" status "}"#)?.text == "status")
    check("relay: keepalives and open events are ignored", RemoteListener.message(#"{"id":"a","time":1,"event":"keepalive"}"#) == nil
          && RemoteListener.message(#"{"id":"a","time":1,"event":"open"}"#) == nil && RemoteListener.message("garbage") == nil)
    RemoteTests.run(gate: Bundle.main.path(forResource: "remote", ofType: "zsh"), check)   // iPhone remote control: see Sources/RemoteTests.swift
    check("permissions: camera states", Permissions.cameraState(.authorized) == .granted && Permissions.cameraState(.notDetermined) == .notAsked
          && Permissions.cameraState(.denied) == .denied && Permissions.cameraState(.restricted) == .denied)
    check("permissions: calendar needs full access (write-only counts as refused)", Permissions.calendarState(.fullAccess) == .granted
          && Permissions.calendarState(.writeOnly) == .denied && Permissions.calendarState(.notDetermined) == .notAsked && Permissions.calendarState(.denied) == .denied)
    check("permissions: music apps, the worst answer counts", Permissions.automationState([]) == .granted && Permissions.automationState([0, -600]) == .granted
          && Permissions.automationState([0, -1744]) == .notAsked && Permissions.automationState([-1744, -1743]) == .denied)
    do {
        func st(_ m: [Permission: Permissions.State]) -> (Permission) -> Permissions.State { { m[$0] ?? .granted } }
        check("permissions: nothing listed when all is allowed", AppDelegate.permissionProblems(needed: [.accessibility], island: true, state: st([:])).isEmpty)
        check("permissions: a needed one that is missing is listed", AppDelegate.permissionProblems(needed: [.accessibility], island: false, state: st([.accessibility: .denied])) == [.accessibility])
        check("permissions: page permissions only when refused, only with the island",
              AppDelegate.permissionProblems(needed: [], island: true, state: st([.camera: .denied, .calendar: .notAsked, .files: .denied])) == [.camera, .files]
              && AppDelegate.permissionProblems(needed: [], island: false, state: st([.camera: .denied])).isEmpty)
    }
    if ClipboardTests.run() != 0 { failed += 1 }           // the clipboard history (its own PASS/FAIL lines; temp folders, fake Keychain)
    _ = NSApplication.shared
    AgentTests.pure(check)                                 // AI sessions: order, restore, liveness, URLs, focus plan, requests
    RecoveryTest.selfChecks(check)
    dialogsSelfTest(check)                                 // in-app dialogs: queue, default buttons, validation, the real flows
    designSelfTest(check)                                  // language in dates and durations, scroll steps, the panel strip
    uxSelfTest(check)                                      // shortcuts, focus timer, usage reader, island keys, contrast (Sources/UXTests.swift)
    if IslandCheck.run() != 0 { failed += 1 }              // the island as the live window holds it (its own PASS/FAIL lines)
    exit(failed == 0 ? 0 : 1)
}

/// `--dialogs-test`, run from main.swift.
func cliDialogsTest() {
    // The in-app dialogs alone (also part of --selftest). PASS/FAIL lines, exit status.
    _ = NSApplication.shared
    var failed = 0
    dialogsSelfTest { name, ok in print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
    designPass2SelfTest { name, ok in print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }   // the dropdowns too
    exit(failed == 0 ? 0 : 1)
}
