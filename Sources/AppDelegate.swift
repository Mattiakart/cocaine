// The app delegate: the menu-bar item, the panel, Cocaine on/off, dimming, triggers, alerts, links and the phone.

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let model = PanelModel()
    private var statusItem: NSStatusItem!
    private var panel: MenuPanel!
    private var hostView: PanelHostingView!
    private var panelTop: CGFloat = 0
    private var wantOn: Bool?        // what the user last asked for, until the script has applied it
    private var applying = false
    private var panelMonitors: [Any] = []
    private var ticker: Timer?
    private var fadeTimer: Timer?
    private var quitSignals: [DispatchSourceSignal] = []
    private var ticks = 0
    private var lastOn: Bool?
    private let screens = Screens()
    /// Idle dimming and the lid rule (Sources/DimController.swift); this file only feeds it and runs its fades.
    private lazy var dim = DimController(io: screens, note: { RecoverySession.shared.noteDim($0) })
    private let clamshell = ClamshellWatcher()
    private var sessionActive = true    // false while another user is on screen (fast user switching)
    private var dimQuiet = Date.distantPast   // the island ignores brightness changes until then (they are Cocaine's own)
    private var supervising = false
    private let launchedAt = Date()
    private let alerter = Alerter()
    private var brightUntil = Date.distantPast   // after an alert, don't dim again right away
    private var didFinishLaunching = false
    private var launchedForAlert = false         // started only to show an alert: don't turn Cocaine on
    private var repeatTimer: Timer?
    private let speech = AVSpeechSynthesizer()
    private let island = IslandController()
    private let systemHUD = SystemHUD()
    private let mediaKeys = MediaKeys()
    private var autoAsked = Set<Permission>()
    private var presenceAssertion: IOPMAssertionID = 0
    private var lastOnAC: Bool?
    /// What each AI session is doing, from the hooks; what it held before a restart comes back first (also in an instance
    /// started just for an alert, which used to overwrite the saved board with that one alert).
    private lazy var board: AgentBoard = { let b = AgentBoard(); b.restore(); return b }()
    private var alertDedup = AlertDeduper()
    private var approvalServer: ApprovalServer?
    private var approvals = ApprovalStore()
    private var approvalAlerted: [String: Date] = [:]   // session → when the notch announced its request
    private var agentNoticeWork: DispatchWorkItem?
    private var batteryGuard = BatteryGuard()
    private var batteryFloor = BatteryFloor()
    private var autoOn = AutoOn() { didSet { if autoOn.owned != oldValue.owned { settings.triggerOwned = autoOn.owned } } }
    private var triggerActive = false
    private var arbiter = TriggerArbiter()
    private var triggerGrace: TimeInterval = 180
    private var requestedOn: Bool?                   // what Cocaine itself last applied; any other change came from outside
    private var realIdle = RealIdle()
    private var idleNow = 0.0                        // the user's idle time, Stay active's nudges left out
    private var screenGate = ScreenOffGate()
    private var heatGuard = HeatGuard()
    private var asking = false                       // the "allow links" question is on screen
    private var linksRefusedUntil = Date.distantPast
    private let hotkeys = Hotkeys()
    private var pendingCommands: [URL] = []          // cocaine://on|off|… that arrived while the app was still starting
    private var iconLevel: CGFloat = -1   // -1 = not drawn yet
    private var iconAnim: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        // First: undo what a crashed session left (adopting its sleep), then start this session's lease and watchdog.
        let adopted = RecoverySession.shared.start(ownsSleep: !launchedForAlert)
        if adopted { log.notice("recovered a previous session; its sleep setting goes on") }
        if adopted && settings.triggerOwned && System.cocaineOn { autoOn.resume(now: Date()) }    // still the trigger's ON
        else if settings.triggerOwned { settings.triggerOwned = false }
        // A link that started us during an update's hand-over (or after a crash) must not end that session 6 s later.
        launchedForAlert = Recovery.alertOnly(launchedForAlert: launchedForAlert, adoptedSession: adopted)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        model.toggleCocaine = { [weak self] in self?.toggleCocaine() }
        model.preview = { [weak self] in self?.preview() }
        model.setLogin = { [weak self] in self?.setLogin($0) }
        model.setAI = { [weak self] in self?.setAI($0, $1) }
        model.pauseAlerts = { [weak self] in self?.pauseAlerts(until: $0) }
        model.testAlert = { [weak self] in
            self?.hidePanel()
            self?.alert(Notice(from: "Cocaine", message: L("This is a test"), project: nil), away: true, test: true)
        }
        model.previewVoice = { [weak self] in self?.speak("Claude Code, " + L("has finished")) }
        model.clearHistory = { [weak self] in
            self?.settings.alertHistory = []
            self?.model.history = []
        }
        model.timerChanged = { [weak self] in self?.timerChanged() }
        model.hotkeysChanged = { [weak self] in self?.applyHotkeys() }
        model.triggersChanged = { [weak self] in self?.evaluateTriggers(System.cocaineOn) }
        model.screenModeChanged = { [weak self] in self?.syncScreenMode() }
        model.screenOffNow = { [weak self] in
            self?.hidePanel()
            DispatchQueue.global().async { PowerState.sleepDisplays() }
        }
        syncScreenMode()
        // Triggers look again at once after a wake, a clock or time-zone change, or a display coming or going.
        let recheck: (Notification) -> Void = { [weak self] n in
            if n.name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.evaluateTriggers(System.cocaineOn) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: recheck)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: recheck)
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, NSApplication.didChangeScreenParametersNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: recheck)
        }
        model.wakeChanged = { [weak self] in self?.applyWake(ask: true) }
        model.islandChanged = { [weak self] in
            guard let self else { return }
            self.island.setEnabled(self.settings.island)
            self.statusItem.isVisible = !self.settings.island || !self.island.showing    // the island replaces the menu-bar icon
        }
        statusItem.isVisible = !settings.island
        // …unless it can't be shown: Cocaine is never left without a sign on screen.
        island.onShowing = { [weak self] shown in
            guard let self else { return }
            log.notice("island \(shown ? "on screen" : "can't be shown: menu-bar icon back", privacy: .public)")
            self.statusItem.isVisible = !self.settings.island || !shown
        }
        island.settingsOpen = { [weak self] in self?.panel?.isVisible ?? false }
        island.start(panelModel: model, enabled: settings.island) { [weak self] in
            self?.island.setOpen(false)
            self?.showPanel(fromClick: false)
        }
        setUpDialogs()
        model.presenceChanged = { [weak self] in
            guard let self else { return }
            self.updatePink()                                                // the pink powder pours in (or out) with the switch
            self.autoAsked.remove(.accessibility)           // turning it on asks again, if it's still missing
            self.refreshPermissions(askMissing: true)
            if !self.model.permissionProblems.isEmpty { self.watchPermissions() }
            self.presenceTick()
        }
        model.requestPresence = { [weak self] in self?.model.requestPermission(.accessibility) }
        model.requestPermission = { [weak self] p in
            Permissions.request(p, explicit: true) { self?.refreshPermissions() }
            self?.watchPermissions()
        }
        mediaKeys.onStep = { [weak self] key, fine in self?.handleMediaKey(key, fine: fine) ?? false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in      // at launch: ask for what an enabled feature lacks
            guard let self else { return }
            self.refreshPermissions(askMissing: true)
            if !self.model.permissionProblems.isEmpty { self.watchPermissions() }
        }
        // Back from System Settings (or anywhere): look again at once.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPermissions()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.systempreferences", let self else { return }
            self.refreshPermissions()
            if !self.model.permissionProblems.isEmpty { self.watchPermissions() }      // a switch flipped there can take a moment
        }
        model.hudReplaceChanged = { [weak self] in self?.applyHUDReplacement() }
        if !settings.replaceHUD || !SystemHUD.freezesHelper() { SystemHUD.cleanup() }
        applyHUDReplacement(atLaunch: true)
        island.model.hud.suppressBrightness = { [weak self] in
            guard let self else { return false }
            return self.dim.busy || self.fadeTimer != nil || Date() < self.dimQuiet
        }
        setUpDimming()
        island.model.focus.onStart = { [weak self] minutes in
            guard let self, !System.cocaineOn else { return }
            self.setCocaine(true, forMinutes: minutes)
        }
        model.sendShortcut = { [weak self] in self?.sendShortcutToPhone() }
        model.revokePhones = { [weak self] in self?.revokePhones() }
        model.allowOldPhones = { [weak self] on in
            PhoneLink.legacyUntil = on ? Date().addingTimeInterval(PhoneLink.legacyDays * 86_400) : nil
            self?.syncPhones()
        }
        model.removeOldPhones = { [weak self] in
            let now = Date()
            if let list = PhoneLink.loadForChange(), PhoneLink.save(list.filter { !$0.isLegacy && !$0.expired(at: now) }) { PhoneLink.legacyUntil = nil }
            self?.syncPhones()
        }
        model.testPhone = { Phone.send(L("This is a test")) }
        syncPhones()
        model.quit = { NSApp.terminate(nil) }
        model.backToIsland = { [weak self] in self?.hidePanel(); self?.island.reopen() }
        model.focusAgent = { [weak self] origin, name in self?.goToSession(origin, name) }
        model.answerApproval = { [weak self] id, choice in self?.answerApproval(id, choice) }
        model.releaseApproval = { [weak self] id in self?.releaseApproval(id) }
        model.board = board.entries                      // restored from before a restart
        model.languageChanged = { [weak self] in self?.refreshIcon(on: System.cocaineOn, animate: false) }
        hostView = PanelHostingView(rootView: PanelView(m: model))
        hostView.sizingOptions = [.intrinsicContentSize]
        hostView.onSizeChange = { [weak self] in DispatchQueue.main.async { self?.fitPanel(animated: true) } }
        let overlay = NSHostingView(rootView: PanelDialogOverlay(m: model))
        overlay.sizingOptions = []                           // it takes the panel's size, never gives it one
        panel = MenuPanel(content: hostView, overlay: overlay)
        // A dropdown that ends below the visible part of a long page: the page scrolls so all of it shows.
        PickerCenter.shared.reveal = { [weak self] r in self?.hostView.scrollToVisible(r) }
        model.pageChanged = { [weak self] in                     // a new page starts at its top
            PickerCenter.shared.close()
            guard let scroll = self?.panel.scroll else { return }
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        for (id, saved) in settings.savedBrightness {   // an older version quit or crashed while screens were lowered
            if let cur = screens.brightness(id), Recovery.shouldRestoreBrightness(current: cur, from: saved, to: settings.level) {
                screens.setBrightness(id, saved)
            }
        }
        settings.savedBrightness = [:]
        UserDefaults.standard.removeObject(forKey: "savedBrightness")   // pre-1.6 single-display key

        // Quit cleanly (restoring everything) on kill/pkill, Ctrl-C and a closed Terminal too; kill -9 and crashes: the watchdog.
        quitSignals = [SIGTERM, SIGINT, SIGHUP].map { sig in
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { NSApp.terminate(nil) }
            s.resume()
            return s
        }

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        tick()
        didFinishLaunching = true
        applyHotkeys()
        model.phone = Phone.configured ? Phone.summary : ""
        if launchedForAlert {                        // `open cocaine://…` started us: show it, then go away again
            pendingCommands.forEach(command)         // (a status question is answered first)
            pendingCommands = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
            return
        }
        // Opening the app turns Cocaine on; a link that started it decides by itself (cocaine://off must not turn it on first).
        if !System.cocaineOn && pendingCommands.isEmpty { toggleCocaine() }
        startApprovals()                             // not in an instance started just for an alert: it quits in 6 s
        Updater.shared.start()                       // leftovers of an update, then a check at most once a day
        pendingCommands.forEach(command)             // then whatever was asked for while it started
        pendingCommands = []
        DispatchQueue.global().async {
            AIHooks.update()
            let ai = AIHooks.status()
            DispatchQueue.main.async { self.model.ai = ai }   // ready before the panel first opens
        }
    }

    /// `cocaine://alert?from=Claude%20Code&event=done|input|error|start|agentstart|agentstop&session=<id>&project=<folder>`
    /// (or `&message=…`) from an AI agent's hook or any script; and control commands: `cocaine://on|off|toggle|panel`,
    /// `cocaine://timer?minutes=90`, `cocaine://pause?minutes=60`, `cocaine://resume` (for Shortcuts, scripts, hotkeys).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "cocaine" {
            guard url.host == "alert" else {
                if didFinishLaunching { command(url); continue }
                pendingCommands.append(url)
                // Started only to answer "status" (or show an alert): answer, then go away again. Anything else keeps it running.
                launchedForAlert = !pendingNeedsApp
                continue
            }
            if !didFinishLaunching { launchedForAlert = !pendingNeedsApp }
            // Anything can open a cocaine:// URL: AlertParams keeps values short, free of control characters, well-formed.
            let p = AlertParams.parse(url)
            let trusted = p.token == settings.testToken                         // only the app's own tools know it
            let from = p.from, project = p.project, event = p.event
            let session = p.sessionKey                                          // tools that don't say: one per AI and folder
            if trusted && p.test == "phone" { Phone.send(p.message ?? L("This is a test")); continue }
            let isTest = trusted && p.test != nil
            // A tool that fires the same hook twice (or a URL opened twice) makes one alert, not two.
            if !isTest, ["done", "input", "error"].contains(event), alertDedup.isDuplicate("\(session)|\(event)") {
                log.notice("duplicate \(event, privacy: .public) for \(session, privacy: .public): ignored")
                continue
            }
            let origin: AgentOrigin? = p.origin.isEmpty ? nil : AgentProcess.complete(p.origin)
            if let running = p.running {                                        // the tool's own list of work still in flight
                var s = sessions[session] ?? SessionState()
                s.inFlight = running
                sessions[session] = s
            }
            if event == "error" {                                    // an agent stopped with an error
                if !isTest { boardSet(session, from, project, "error", origin) }
                if settings.alertError { alert(Notice(from: from, message: p.message ?? L("stopped with an error"), project: project, session: session, origin: origin),
                                                away: trusted && p.test == "away" ? true : nil) }
                continue
            }
            if event != "done" && event != "input" {                 // silent signs of life: prompts, agents and tasks
                if !isTest, ["start", "agentstart", "taskstart"].contains(event) { boardSet(session, from, project, "working", origin) }
                activity(session, event)
                continue
            }
            let input = event == "input"
            if p.message == nil && !(input ? settings.alertInput : settings.alertDone) {   // alerts of this kind are off
                if !isTest { boardSet(session, from, project, input ? "waiting" : "done", origin) }
                continue
            }
            // Claude Code's own "needs you" after a request the notch already announced (handed back, or expired): one alert.
            if input && p.message == nil && !isTest, let t = approvalAlerted[session], Date().timeIntervalSince(t) < 300 {
                boardSet(session, from, project, "waiting", origin)
                continue
            }
            let message = p.message ?? (input ? L("needs your input") : L("has finished"))
            let notice = Notice(from: from, message: message, project: project, session: session, origin: origin)
            if p.message == nil && !input && settings.alertPerSession && !isTest {
                boardSet(session, from, project, "working", origin)  // still counts as at work until it stays quiet
                holdUntilQuiet(session, notice)                    // one alert when the whole session is done
                continue
            }
            if !isTest { boardSet(session, from, project, input ? "waiting" : "done", origin) }
            if input, var s = sessions[session] {                 // it needs you now; "done" will come again later
                s.timer?.cancel(); s.notice = nil; sessions[session] = s
            }
            alert(notice, away: trusted && p.test == "away" ? true : nil)
        }
    }

    /// A pending link that needs the app to keep running (anything but "status").
    private var pendingNeedsApp: Bool {
        pendingCommands.contains { if case .success(let r) = ControlURL.parse($0) { return r.action != .status }; return false }
    }

    /// The control commands above. Anything can open a cocaine:// link (a web page too), so what changes the Mac's sleep
    /// needs the "Shortcuts app and links" switch, or the user's OK when it's off. Bad values are refused, not guessed.
    private func command(_ url: URL) {
        let req: ControlRequest
        switch ControlURL.parse(url) {
        case .success(let r): req = r
        case .failure(let f):
            log.notice("command refused: \(String(describing: f), privacy: .public)")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let e = items.first(where: { $0.name == "x-error" })?.value.flatMap(ControlURL.callback),
               let r = ControlURL.reply(e, [("errorMessage", f == .badMinutes ? "minutes must be 1 to 1440" : "unknown command")]) {
                NSWorkspace.shared.open(r)
            }
            return
        }
        log.notice("command \(String(describing: req.action), privacy: .public)")
        guard req.action.guarded else { runCommand(req); return }
        linksAllowed(url) { [weak self] allowed in
            guard allowed else {
                if let e = req.failure, let r = ControlURL.reply(e, [("errorMessage", "not allowed")]) { NSWorkspace.shared.open(r) }
                return
            }
            self?.runCommand(req)
        }
    }

    /// A control command that may run (allowed, or not guarded): does it and answers the caller's x-success.
    private func runCommand(_ req: ControlRequest) {
        switch req.action {
        case .on(let minutes): autoOn.userToggled(to: true, triggerActive: triggerActive); setCocaine(true, forMinutes: minutes)
        case .off: autoOn.userToggled(to: false, triggerActive: triggerActive); setCocaine(false)
        case .toggle: toggleCocaine()
        case .timer(let minutes): autoOn.userToggled(to: true, triggerActive: triggerActive); setCocaine(true, forMinutes: minutes ?? (settings.timerMinutes > 0 ? settings.timerMinutes : 60))
        case .pause(let minutes): pauseAlerts(until: Date().addingTimeInterval(Double(minutes ?? 60) * 60))
        case .resume: pauseAlerts(until: nil)
        case .panel: if !panel.isVisible { showPanel(fromClick: false) }
        case .status: break
        }
        guard let s = req.success else { return }
        // Answer with what was asked for (a change is applied in the background: report the target, not the old state).
        let on = wantOn ?? System.cocaineOn
        if let r = ControlURL.reply(s, ControlURL.status(on: on, until: settings.onUntil, now: Date(),
                                                         screenOff: screenOffMode, trigger: triggerActive)) {
            NSWorkspace.shared.open(r)
        }
    }

    /// Links may change things when the switch is on; otherwise ask, in the panel (one question at a time, and after a "Don't
    /// Allow" links are ignored for 10 minutes, so a page can't flood the screen with questions). Return, Esc and a click
    /// elsewhere are Don't Allow (see Dialogs.links). `done` runs once, at once when there's nothing to ask.
    private func linksAllowed(_ url: URL, _ done: @escaping (Bool) -> Void) {
        if settings.allowLinks { done(true); return }
        guard !asking, Date() >= linksRefusedUntil else { done(false); return }
        asking = true
        DialogCenter.shared.present(Dialogs.links(url)) { [weak self] r in
            guard let self else { return }
            self.asking = false
            guard r.buttonID == "allow" else {
                self.linksRefusedUntil = Date().addingTimeInterval(600)
                done(false)
                return
            }
            self.settings.allowLinks = true
            self.model.allowLinks = true
            done(true)
        }
    }

    private func boardSet(_ session: String, _ from: String, _ project: String?, _ state: String, _ origin: AgentOrigin? = nil) {
        board.set(session, from: from, project: project, state: state, origin: origin)
        writeBoard()
    }

    // MARK: Requests answered from the notch (Sources/AgentApprovals.swift)

    private func startApprovals() {
        let dir = AgentPaths.support()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let key = ApprovalKey.loadOrCreate(AgentPaths.key(dir)) else { log.error("approvals: no key"); return }
        let server = ApprovalServer(path: AgentPaths.socket(dir), key: key)
        server.onRequest = { [weak self] id, nonce, tool, input, origin in self?.approvalArrived(id, nonce, tool, input, origin) }
        server.onGone = { [weak self] id in
            guard let self else { return }
            self.approvals.gone(id, now: Date())
            self.publishApprovals()
        }
        do { try server.start(); approvalServer = server }
        catch { log.error("approvals: socket not started: \(String(describing: error), privacy: .public)") }   // hooks fall back to the terminal
    }

    private func approvalArrived(_ id: String, _ nonce: String, _ tool: String, _ input: [String: Any], _ origin: AgentOrigin) {
        guard let server = approvalServer else { return }
        guard var r = ApprovalRequest.make(id: id, nonce: nonce, tool: tool, input: input, origin: AgentProcess.complete(origin), now: Date()) else {
            server.reply(id, decision: "none", content: nil)
            return
        }
        let session = r.session ?? "\(r.from)|\(r.project ?? "")"
        r.session = session
        boardSet(session, r.from, r.project, "waiting", r.origin)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard ApprovalPolicy.hold(enabled: settings.agentApprovals, answerable: r.answerable, origin: r.origin, frontmost: front,
                                  idleSeconds: System.idleSeconds), approvals.add(r) else {
            server.reply(id, decision: "none", content: nil)     // the terminal asks; Claude Code's Notification hook alerts then
            if r.tool == "codex" { approvalAlert(r) }           // Codex has no other "needs you" hook
            return
        }
        log.notice("approval \(id, privacy: .public) from \(r.from, privacy: .public): held for the notch")
        publishApprovals()
        approvalAlert(r)
        DispatchQueue.main.asyncAfter(deadline: .now() + ApprovalTiming.app + 0.5) { [weak self] in self?.expireApprovals() }
    }

    private func approvalAlert(_ r: ApprovalRequest) {
        approvalAlerted = approvalAlerted.filter { Date().timeIntervalSince($0.value) < 600 }
        approvalAlerted[r.session ?? ""] = Date()
        guard settings.alertInput else { return }
        alert(Notice(from: r.from, message: r.event == "Elicitation" ? L("asks you a question") : L("needs your approval"), project: r.project,
                     session: r.session, origin: r.origin))
    }

    private func expireApprovals() {
        for id in approvals.expire(now: Date()) { approvalServer?.reply(id, decision: "none", content: nil) }   // the terminal asks now
        publishApprovals()
    }

    private func publishApprovals() {
        let now = Date()
        model.approvals = approvals.pending.filter { $0.deadline > now }
    }

    /// A click on one of a request's buttons. The first click wins; a late or repeated one changes nothing.
    private func answerApproval(_ id: String, _ choice: Int) {
        let r = approvals.requests[id]
        switch approvals.answer(id, choice: choice, now: Date()) {
        case .send(let decision, let content):
            approvalServer?.reply(id, decision: decision, content: content) { [weak self] sent in
                guard let self else { return }
                if !sent { self.showAgentNotice(L("That request was no longer waiting: answer it in the terminal.")) }
                else if let r, let s = r.session { self.boardSet(s, r.from, r.project, "working") }
            }
            log.notice("approval \(id, privacy: .public): \(decision, privacy: .public) from the notch")
        case .expired:
            approvalServer?.reply(id, decision: "none", content: nil)
            showAgentNotice(L("That request had expired: the terminal asks for it now."))
        case .alreadyAnswered: break                                  // a second click on the same request
        case .unknown: showAgentNotice(L("That request was no longer waiting: answer it in the terminal."))
        }
        publishApprovals()
    }

    private func releaseApproval(_ id: String) {
        if approvals.release(id, now: Date()) { approvalServer?.reply(id, decision: "none", content: nil) }
        publishApprovals()
    }

    // MARK: Going back to a session (Sources/AgentFocus.swift)

    private func goToSession(_ origin: AgentOrigin?, _ name: String) {
        guard let origin, !origin.isEmpty else {
            showAgentNotice(L("Cocaine doesn't know where this session runs (an older hook, or a script): look for it in your terminal."))
            return
        }
        AgentFocus.go(origin) { [weak self] r in
            guard let self else { return }
            if r.note == .automationDenied { Permissions.openPane(.automation) }
            if let text = Self.focusMessage(r, name) { self.showAgentNotice(text) }
            else { self.hidePanel(); self.island.setOpen(false) }   // it's in front: get out of the way
        }
    }

    /// What a click could do, said plainly when it's less than the exact tab. nil = it got there.
    static func focusMessage(_ r: AgentFocus.Result, _ name: String) -> String? {
        let app = r.appName ?? name
        switch r.level {
        case .exact: return nil
        case .window: return String(format: L("Opened the project in %@ (its terminal panel can't be selected from outside)."), app)
        case .app:
            return r.note == .automationDenied
                ? String(format: L("Brought %@ forward. To select the exact tab, allow Cocaine to control %@ in Privacy & Security → Automation."), app, app)
                : String(format: L("Brought %@ forward, but not the exact tab (it was closed, or %@ can't be steered from outside)."), app, app)
        case .folder: return String(format: L("%@ isn't open any more: opened the session's folder in Finder."), app)
        case .none:
            return r.note == .noInfo ? L("Cocaine doesn't know where this session runs (an older hook, or a script): look for it in your terminal.")
                : L("The app this session ran in isn't open, and its folder is gone.")
        }
    }

    private func showAgentNotice(_ text: String) {
        model.agentNotice = text
        if settings.island { island.model.flashNotice("arrow.uturn.left.circle", text) }
        agentNoticeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.model.agentNotice = nil }
        agentNoticeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    private func writeBoard() {
        board.prune()
        model.board = board.entries
        board.write(cocaineOn: System.cocaineOn, until: settings.onUntil)
    }

    /// Per session: agents and tasks still running, its last sign of life, and a "finished" on hold. `inFlight` is the
    /// tool's own count of work still in flight (Claude Code sends it); when known, it replaces counting agents.
    private struct SessionState {
        var agents = 0, tasks = 0
        var inFlight: Int?
        var touched = Date()
        var notice: Notice?
        var timer: DispatchWorkItem?
        var busy: Bool { inFlight.map { $0 > 0 } ?? (agents + tasks > 0) }
        /// With the tool's own count a short wait is enough; by counting agents alone, wait out the ~30 s gaps an
        /// active session has between steps.
        var quietSeconds: Double { inFlight == nil ? 60 : 20 }
    }
    private var sessions: [String: SessionState] = [:]

    /// Agents or tasks starting and ending: counted, and (like any sign of life) they push a held "finished" back.
    private func activity(_ key: String, _ event: String) {
        if sessions.count > 200 {                    // anything can send these: forget the quiet ones rather than grow forever
            sessions = sessions.filter { $0.value.notice != nil || Date().timeIntervalSince($0.value.touched) < 3600 }
        }
        var s = sessions[key] ?? SessionState()
        switch event {
        case "agentstart": s.agents += 1
        case "agentstop": s.agents = max(0, s.agents - 1)
        case "taskstart": s.tasks += 1
        case "taskstop": s.tasks = max(0, s.tasks - 1)
        default: break
        }
        s.touched = Date()
        sessions[key] = s
        log.notice("session \(key, privacy: .public) \(event, privacy: .public): \(s.agents, privacy: .public) agent(s), \(s.tasks, privacy: .public) task(s)")
        if s.notice != nil { rearm(key) }
    }

    /// Holds a session's "finished": it's shown once nothing of that session is running and it has had no sign of
    /// life for `quietSeconds`; every new event starts the wait again.
    private func holdUntilQuiet(_ key: String, _ n: Notice) {
        sessions = sessions.filter { Date().timeIntervalSince($0.value.touched) < 6 * 3600 }   // forget old sessions
        var s = sessions[key] ?? SessionState()
        s.notice = n
        s.touched = Date()
        sessions[key] = s
        rearm(key)
    }

    private func rearm(_ key: String) {
        guard var s = sessions[key] else { return }
        s.timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let s = self.sessions[key], let n = s.notice else { return }
            let quiet = Date().timeIntervalSince(s.touched)
            let busy = s.busy && quiet < 1800                   // a count stuck by a lost "ended" gives up after 30 min
            if quiet < s.quietSeconds - 0.5 || busy {
                log.notice("session \(key, privacy: .public) still working (in flight: \(s.inFlight.map(String.init) ?? "?", privacy: .public), agents: \(s.agents, privacy: .public)): holding")
                self.rearm(key)
                return
            }
            self.sessions[key] = nil
            self.boardSet(key, n.from, n.project, "done")
            self.alert(n)
        }
        s.timer = work
        sessions[key] = s
        DispatchQueue.main.asyncAfter(deadline: .now() + s.quietSeconds, execute: work)
    }

    struct Notice {
        let from: String, message: String, project: String?
        var session: String? = nil, origin: AgentOrigin? = nil          // where it came from: a click on it goes back there
    }

    /// Away from the Mac (idle 20 s, or screens dimmed), or always if the user wants: wake the screens, restore the
    /// brightness, flash them with the message, play the sound, read it aloud. At the Mac: just refill the baggie.
    private func alert(_ a: Notice, away forced: Bool? = nil, repeated: Bool = false, test: Bool = false) {
        if let until = settings.alertsPausedUntil, forced == nil {
            log.notice("alert from \(a.from, privacy: .public) muted until \(until, privacy: .public)")
            return
        }
        let away = forced ?? (idleNow >= 20 || dim.idleDimmed || (screenOffMode && screenGate.fired))
        log.notice("alert from \(a.from, privacy: .public) project \(a.project ?? "-", privacy: .public) (away: \(away, privacy: .public), repeated: \(repeated, privacy: .public))")
        if !repeated && !test {                          // "Recent alerts"
            settings.alertHistory = [AlertRecord(from: a.from, message: a.message, project: a.project, at: Date(), session: a.session, origin: a.origin)]
                + settings.alertHistory
            model.history = settings.alertHistory
        }
        pulseIcon()
        if away && !repeated && !test && Phone.configured {
            Phone.send([a.from, a.message, a.project].compactMap { $0 }.joined(separator: " · "))
        }
        guard away || settings.alertWhenPresent else { return }
        if settings.alertFlash {
            var activity: IOPMAssertionID = 0            // wakes a sleeping display
            IOPMAssertionDeclareUserActivity("Cocaine alert" as CFString, kIOPMUserActiveLocal, &activity)
            brightUntil = Date().addingTimeInterval(max(settings.delay, 60))
            updateDimming(on: System.cocaineOn)          // the idle dim lets go at once (a built-in behind a closed lid stays dark)
            alerter.show(title: a.from, message: a.message, detail: a.project, seconds: settings.alertDuration)
        }
        if !settings.alertSound.isEmpty { NSSound(named: settings.alertSound)?.play() }
        if settings.alertSpeak { speak([a.from, a.message, a.project].compactMap { $0 }.joined(separator: ", ")) }
        if away && settings.alertRepeatMinutes > 0 && !repeated && !test { repeatUntilBack(a) }
    }

    /// Every few minutes (the user's choice), for up to 30 minutes, as long as nobody has touched the Mac since.
    private func repeatUntilBack(_ a: Notice) {
        repeatTimer?.invalidate()
        let minutes = settings.alertRepeatMinutes
        var count = 0
        let t = Timer(timeInterval: Double(minutes * 60), repeats: true) { [weak self] t in
            count += 1
            guard let self, count * minutes <= 30, self.idleNow >= Double(minutes * 60 - 10),
                  self.settings.alertRepeatMinutes == minutes else { t.invalidate(); return }
            self.alert(a, away: true, repeated: true)
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    private func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = Voices.voice(settings.alertVoice)
        speech.stopSpeaking(at: .immediate)                 // a new alert (or preview) replaces the one being read
        speech.speak(u)
    }

    private func pauseAlerts(until: Date?) {
        settings.alertsPausedUntil = until
        model.alertsPausedUntil = settings.alertsPausedUntil
        if until != nil { repeatTimer?.invalidate() }
    }

    /// The fill animation again, as a small "something happened" in the menu bar.
    private func pulseIcon() {
        guard System.cocaineOn else { return }
        iconLevel = 0.2
        refreshIcon(on: true)
    }

    /// Quitting (Quit button, ⌘Q, logout, shutdown) turns Cocaine off, just as opening the app turns it on: sleep goes back
    /// to what it was before Cocaine turned it off (unless someone changed it since), or stays for the new version during
    /// an update (Sources/Recovery.swift).
    func applicationWillTerminate(_ n: Notification) {
        systemHUD.disable()                      // macOS draws its own volume and brightness HUD again
        approvalServer?.stop()                   // waiting hooks see the socket close: their terminals ask as usual
        board.write(cocaineOn: System.cocaineOn, until: settings.onUntil)   // the board as it was, for the next launch
        mediaKeys.stop()
        ClipboardHistory.shared.flush()          // a saved history gets its last change
        WakeSchedule.cancel()                    // nothing would be listening at that wake
        fadeTimer?.invalidate()
        dim.quit()                               // every lowered display back, also in the middle of a fade; then the lease is cleared
        settings.savedBrightness = [:]
        RecoverySession.shared.noteDim([])
        RecoverySession.shared.end()
    }

    /// Opening Cocaine again (e.g. from Spotlight) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // An `open` right after launch (Homebrew reopening the app after an upgrade) isn't a request for the panel.
        guard Date().timeIntervalSince(launchedAt) > 5 else { return false }
        if !panel.isVisible { showPanel(fromClick: false) }
        return false
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel(fromClick: true) }
    }

    /// Opens the panel under the icon that was clicked. With several screens the icon is in every screen's menu bar,
    /// so the click position, not the icon's own window, says which one.
    private func showPanel(fromClick: Bool) {
        refreshPanelState()
        refreshPermissions()
        let mouse = NSEvent.mouseLocation
        let clicked = fromClick ? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } : nil
        var screen = clicked ?? NSScreen.main
        var anchorX = mouse.x
        if settings.island, let g = NotchGeometry.current() {
            screen = NSScreen.screens.first { $0.frame == g.frame } ?? screen       // under the notch, where the island is
            anchorX = g.centerX
        } else if let button = statusItem.button, let bar = button.window {
            let icon = bar.convertToScreen(button.convert(button.bounds, to: nil))
            if clicked == nil || clicked == bar.screen { screen = bar.screen ?? screen; anchorX = icon.midX }
        }
        guard let screen else { return }
        panelTop = settings.island ? screen.frame.maxY : (screen.visibleFrame.maxY - 6).rounded()   // from the notch, or under the menu bar
        panel.attach(toTop: settings.island)
        model.page = ""                                              // always opens on the home
        fitPanel(animated: false, centeredOn: anchorX, screen: screen)
        panel.makeKeyAndOrderFront(nil)
        if settings.island { island.setSuspended(true) }
        statusItem.button?.highlight(true)
        // Clicks elsewhere close it; a click on the icon itself (which also arrives here on macOS 27) toggles instead.
        let iconZone = NSRect(x: anchorX - 18, y: screen.frame.maxY - 44, width: 36, height: 44)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            if !iconZone.contains(NSEvent.mouseLocation) { self?.hidePanel() }
        }) { panelMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if DialogCenter.shared.isShowing(on: .panel), DialogCenter.shared.handleKey(e) { return nil }   // Return/Esc: the dialog's
            if PickerCenter.shared.isOpen(on: .panel), PickerCenter.shared.handleKey(e) { return nil }     // ↑↓, Return, Space, Esc: the dropdown's
            if e.keyCode == 53 {                                   // Esc: closes the panel
                self?.hidePanel()
                return nil
            }
            return e
        }) { panelMonitors.append(m) }
    }

    /// Sizes the panel to its content with the top edge fixed under the icon, so it only grows or shrinks downward.
    private func fitPanel(animated: Bool, centeredOn midX: CGFloat? = nil, screen: NSScreen? = nil) {
        guard panel.isVisible || midX != nil else { return }
        hostView.layoutSubtreeIfNeeded()
        let natural = hostView.fittingSize
        guard natural.height > 0 else { return }
        // Never taller than the screen it's on (below the menu bar, 8 pt from the bottom): the rest scrolls.
        let visible = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var limit = max(240, panelTop - visible.minY - 8)
        let test = UserDefaults.standard.double(forKey: "testMaxHeight")        // tests: pretend the screen is small
        if test > 0 { limit = test }
        let size = NSSize(width: Layout.width, height: min(natural.height, limit))
        let top = panelTop + (settings.island ? Layout.overscan : 0)        // hanging from the notch: starts above the screen's top edge
        var frame = NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height)
        if let midX {
            frame = Self.panelFrame(size: size, anchorX: midX, top: top,
                                    visible: (screen ?? NSScreen.main)?.visibleFrame ?? .zero)
        }
        guard frame != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// Centred under the icon, kept 8 pt inside the screen it opens on.
    static func panelFrame(size: NSSize, anchorX: CGFloat, top: CGFloat, visible: NSRect) -> NSRect {
        let x = min(max(anchorX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8).rounded()
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    private func hidePanel() {
        island.setSuspended(false)
        panelMonitors.forEach(NSEvent.removeMonitor)
        panelMonitors.removeAll()
        panel.orderOut(nil)
        NSCursor.arrow.set()                                // in case it closed with the pointer on the mirror
        statusItem.button?.highlight(false)
        DialogCenter.shared.surfaceClosed(.panel)           // a question on it is answered Cancel (the next one, if any, reopens it)
        PickerCenter.shared.surfaceClosed(.panel)
    }

    /// In-app dialogs: over the panel (opened, under the notch or the icon, when it isn't), or in the open island when asked from
    /// there. Only when neither can be shown (no screen) does NSAlert come up instead.
    private func setUpDialogs() {
        let center = DialogCenter.shared
        center.show = { [weak self] want in
            guard let self, self.panel != nil else { return nil }
            if want == .island && self.island.canHoldDialog { return .island }
            if !self.panel.isVisible { self.showPanel(fromClick: false) }
            guard self.panel.isVisible else { return nil }
            self.panel.makeKey()                            // Return, Esc and the text field (the panel never activates the app)
            return .panel                                   // the card is drawn over the visible area, wherever the page is scrolled
        }
        center.changed = { [weak self] in
            if center.current != nil { PickerCenter.shared.close() }        // a question replaces an open dropdown
            self?.island.dialogChanged()
            self?.panel?.overlay.isHidden = !center.isShowing(on: .panel)
        }
    }

    private func refreshPanelState() {
        let login = SMAppService.mainApp.status == .enabled
        if model.loginEnabled != login { model.loginEnabled = login }
        let on = System.cocaineOn
        DispatchQueue.global().async {
            let missing = on && !System.displayHeld
            let ai = AIHooks.status()
            DispatchQueue.main.async {
                if self.model.holdMissing != missing { self.model.holdMissing = missing }
                if missing { self.superviseHold() }
                if !self.model.settingAI && self.model.ai != ai { self.model.ai = ai }
                let paused = self.settings.alertsPausedUntil   // a pause ends by itself
                if self.model.alertsPausedUntil != paused { self.model.alertsPausedUntil = paused }
                let phone = Phone.configured ? Phone.summary : ""
                if self.model.phone != phone { self.model.phone = phone }
                self.model.battery = System.battery.map { "\($0.percent)%" }
            }
        }
    }

    /// Connects or disconnects one AI tool (adds or removes its hooks); its tick flips at once.
    private func setAI(_ id: String, _ enable: Bool) {
        guard !model.settingAI, let tool = AIHooks.tool(id) else { return }
        model.settingAI = true
        if let i = model.ai.tools.firstIndex(where: { $0.id == id }) { model.ai.tools[i].on = enable }
        DispatchQueue.global().async {
            let failed = AIHooks.set(enable, only: [tool])
            let ai = AIHooks.status()
            DispatchQueue.main.async {
                self.model.settingAI = false
                self.model.ai = ai
                log.notice("AI alerts for \(id, privacy: .public) \(enable ? "on" : "off", privacy: .public), failed: \(failed.count, privacy: .public)")
                guard !failed.isEmpty else { return }
                DialogCenter.shared.present(Dialogs.message(L("Can't change AI alerts"),
                                                            failed.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: "\n"))) { _ in }
            }
        }
    }

    // MARK: State

    private func tick() {
        ticks += 1
        let on = System.cocaineOn
        idleNow = realIdle.update(systemIdle: System.idleSeconds, now: Date())
        if on != lastOn {
            // Turned on or off from outside (`cocaine on|off`, `cocaine remote`, another tool): that's the user's choice,
            // just like the switch, so a Smart Trigger doesn't undo it at once.
            if Self.isOutsideChange(last: lastOn, now: on, requested: requestedOn, pending: wantOn) {
                log.notice("turned \(on ? "on" : "off", privacy: .public) from outside")
                autoOn.userToggled(to: on, triggerActive: triggerActive)
                requestedOn = on
            }
            if lastOn == true && !on { DispatchQueue.global().async { engine("forget") } }   // OFF from anywhere ends our claim
            lastOn = on
            refreshIcon(on: on)
            if on { superviseHold() }
        } else if on && ticks % 20 == 0 {
            superviseHold()                          // every 10 s
        }
        if wantOn == nil && model.on != on { model.on = on }   // don't fight a switch the user just flipped
        if panel.isVisible && ticks % 4 == 0 { refreshPanelState() }
        if alerter.isShowing, let at = alerter.shownAt, Date().timeIntervalSince(at) > 1.5, idleNow < 0.6 {
            alerter.close(animated: true)            // the user is back
        }
        updateDimming(on: on)
        syncSystemHUD()                                          // the island hidden (full screen…) or back: who shows the HUD
        if ticks % 4 == 0 { checkTimer(on) }                     // every 2 s
        if ticks % 10 == 0 { evaluateTriggers(on) }              // every 5 s
        if ticks % 20 == 0 { checkBattery(on); checkHeat(on); writeBoard(); presenceTick() }    // every 10 s
        if ticks % 4 == 0 { watchPower(); mediaKeys.healthCheck() }   // every 2 s
    }

    // MARK: Permissions

    /// What the features that are on need.
    private func neededPermissions() -> [Permission] {
        var n: [Permission] = []
        if settings.stayActive || settings.replaceHUD { n.append(.accessibility) }
        return n
    }

    /// Checks everything. With `askMissing`, asks (once per launch each) for what an enabled feature needs and lacks; the rest is
    /// asked when you use it (camera, calendar, music) and listed under Permissions if it was refused.
    /// Never blocks: Files and Music/Spotify are re-checked off the main thread and land here again when they change.
    private func refreshPermissions(askMissing: Bool = false) {
        let problems = Self.permissionProblems(needed: neededPermissions(), island: settings.island, state: Permissions.state)
        for p in problems where askMissing && !autoAsked.contains(p) && neededPermissions().contains(p) {
            autoAsked.insert(p); Permissions.request(p)
        }
        if model.permissionProblems != problems { model.permissionProblems = problems }
        let access = Presence.hasAccess
        if model.presenceAccess != access { model.presenceAccess = access }
        // A permission just given: start what was waiting for it.
        // A permission taken away: the tap is dropped, so giving it back recreates it here.
        mediaKeys.healthCheck()
        if settings.replaceHUD && !mediaKeys.running && AXIsProcessTrusted() { mediaKeys.start() }
        Permissions.probe(files: settings.island) { [weak self] changed in if changed { self?.refreshPermissions() } }
    }

    /// What the Permissions card lists: what an enabled feature needs and lacks, and (with the island on) what was refused.
    static func permissionProblems(needed: [Permission], island: Bool, state: (Permission) -> Permissions.State) -> [Permission] {
        var problems = needed.filter { state($0) != .granted }
        if island { problems += [Permission.camera, .calendar, .automation, .files].filter { !problems.contains($0) && state($0) == .denied } }
        return problems
    }

    /// After asking (or sending you to Settings), look again every second for a minute, and whenever Cocaine comes to the front.
    private var permissionWatch: Timer?
    private func watchPermissions() {
        permissionWatch?.invalidate()
        var n = 0
        permissionWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            n += 1
            guard let self, n <= 60 else { t.invalidate(); return }
            self.refreshPermissions()
            if self.model.permissionProblems.isEmpty { t.invalidate() }
        }
    }

    // MARK: Stay active, charging, the HUD keys

    /// While a chat app is open (or always) and you are idle, keeps the idle clock from running out; holds the display awake.
    private func presenceTick() {
        let want = settings.stayActive && (settings.stayActiveAlways || Presence.anyRunning(settings.stayActiveApps))
        refreshPermissions()                                    // (also starts the HUD keys once their permission is given)
        if want != model.presenceActive {
            model.presenceActive = want
            updatePink()                                           // the pink powder follows
        }
        // In screen-off mode (Cocaine on) the displays are meant to go dark: no display hold, and never input to a
        // sleeping display, which would light it up again (chat apps may then show you away).
        let dark = screenOffMode && System.cocaineOn
        if want {
            if dark, presenceAssertion != 0 { IOPMAssertionRelease(presenceAssertion); presenceAssertion = 0 }
            if !dark && presenceAssertion == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "Cocaine keeps you available in chat apps" as CFString, &presenceAssertion)
            }
            // Only just before a chat app (or the screen saver) would take you for away, not every 45 s; never under another user.
            if sessionActive && System.idleSeconds > Presence.nudgeAfter(screenSaverIdle: Presence.screenSaverIdle)
                && !PowerState.displaysAsleep && !(dark && screenGate.fired) && Presence.nudge() {
                realIdle.lastNudge = Date()
            }
        } else if presenceAssertion != 0 {
            IOPMAssertionRelease(presenceAssertion); presenceAssertion = 0
        }
    }

    /// A message in the island when the charger is plugged in or out.
    private func watchPower() {
        guard let b = System.battery else { return }
        if let last = lastOnAC, last != b.onAC {
            island.model.flashNotice(b.onAC ? "bolt.fill" : "battery.50", (b.onAC ? L("Charging") : L("On battery")) + " \(b.percent)%")
        }
        lastOnAC = b.onAC
    }

    /// Volume, mute and brightness keys: applied here, shown in the island. False leaves the key to macOS.
    private func handleMediaKey(_ key: Int, fine: Bool) -> Bool {
        // Only while the island can show the bar: in full screen, behind the settings panel, under another user or with the
        // island off, the key goes to macOS and macOS shows its own indicator.
        guard hudInIsland else { return false }
        if key == 0 || key == 1 || key == 7 {
            guard let r = MediaKeys.changeVolume(key: key, fine: fine) else { return false }
            let icon = r.muted || r.level == 0 ? "speaker.slash.fill" : r.level < 0.34 ? "speaker.wave.1.fill" : r.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            island.model.flashNotice(icon, L("Volume"), level: r.muted ? 0 : Double(r.level))
            return true
        }
        // The display under the pointer (else the built-in, else an Apple display with the lid closed); a lowered one is left to macOS.
        guard let id = screens.keyTarget(pointer: CGEvent(source: nil)?.location), !dim.isLowered(id), !dim.previewing,
              let b = screens.brightness(id) else { return false }
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        let new = min(1, max(0, b + (key == 2 ? step : -step)))
        dimQuiet = Date().addingTimeInterval(1)
        screens.setBrightness(id, new)
        island.model.flashNotice("sun.max.fill", L("Brightness"), level: Double(new))
        return true
    }

    private func applyHUDReplacement(atLaunch: Bool = false) {
        island.syncHUD(settings.replaceHUD)
        if settings.replaceHUD {
            if !atLaunch {                                        // just turned on: ask if it's missing (at launch: 3 s later, once)
                autoAsked.remove(.accessibility)
                refreshPermissions(askMissing: true)
                if !model.permissionProblems.isEmpty { watchPermissions() }
            }
            if AXIsProcessTrusted() { mediaKeys.start() }
        } else {
            mediaKeys.stop()
        }
        syncSystemHUD()
    }

    /// The island shows the volume and brightness bars right now: Replace system HUD on, the island on and on screen (not hidden
    /// by a full-screen app or the settings panel), and this user's session in front.
    private var hudInIsland: Bool {
        settings.replaceHUD && settings.island && island.canShowHUD && sessionActive
    }

    /// Before macOS 26 the system HUD is a separate helper, kept frozen only while the island shows the bars (any other moment
    /// it is let go, so there is always an indicator). From macOS 26 the HUD is drawn by Control Center: nothing is frozen, the
    /// keys Cocaine handles simply never reach macOS (Sources/HUD.swift).
    private func syncSystemHUD() {
        if hudInIsland && SystemHUD.freezesHelper() { systemHUD.enable() } else { systemHUD.disable() }
    }

    // MARK: Timer, Battery Guard, Smart Triggers, hotkeys

    /// Turns Cocaine off when its time is up (a timer from the panel, `cocaine://timer` or `cocaine remote on --for`).
    private func checkTimer(_ on: Bool) {
        let until = settings.onUntil
        if model.onUntil != until { model.onUntil = until }
        guard wantOn == nil else { return }
        if on, let until, Date() >= until {
            settings.onUntil = nil
            model.onUntil = nil
            autoOn.userToggled(to: false, triggerActive: triggerActive)     // a trigger doesn't undo it at once
            setCocaine(false, auto: true)
            log.notice("timer over: Cocaine off")
            alert(Notice(from: "Cocaine", message: L("Timer over: Cocaine is off"), project: nil), away: true)
        } else if !on && until != nil {
            settings.onUntil = nil                               // a deadline with nothing to end
            model.onUntil = nil
        }
    }

    /// On battery power, at the chosen level: turn Cocaine off (or just warn), once until the battery recovers.
    private func checkBattery(_ on: Bool) {
        let b = System.battery
        model.battery = b.map { "\($0.percent)%" }
        guard let b else { return }
        // The floor first: at 5 % Cocaine lets go whatever Battery Guard says (off, or already used up), every time.
        let floor = batteryFloor.check(percent: b.percent, onAC: b.onAC, on: on)
        if floor != .none {
            log.notice("battery at \(b.percent, privacy: .public)%: the floor lets the Mac sleep")
            autoOn.userToggled(to: false, triggerActive: triggerActive)
            setCocaine(false, auto: true)
            let text = String(format: L("Battery at %d%%: Cocaine is off"), b.percent)
            if floor == .release { alert(Notice(from: "Cocaine", message: text, project: nil), away: true) }
            else { island.model.flashNotice("battery.0", text) }      // turned on again down there: said again, quietly
            return
        }
        guard batteryGuard.check(percent: b.percent, onAC: b.onAC, threshold: settings.batteryThreshold), on else { return }
        log.notice("battery at \(b.percent, privacy: .public)%")
        if settings.batteryTurnsOff {
            autoOn.userToggled(to: false, triggerActive: triggerActive)
            setCocaine(false, auto: true)
            alert(Notice(from: "Cocaine", message: String(format: L("Battery at %d%%: Cocaine is off"), b.percent), project: nil), away: true)
        } else {
            alert(Notice(from: "Cocaine", message: String(format: L("Battery at %d%%"), b.percent), project: nil), away: true)
        }
    }

    /// Lid closed, on battery, getting hot (a Mac in a bag): turn Cocaine off so it can sleep and cool down.
    private func checkHeat(_ on: Bool) {
        let onAC = PowerState.onAC
        guard heatGuard.check(lidClosed: System.lidClosed, onAC: onAC, thermal: ProcessInfo.processInfo.thermalState), on else { return }
        log.notice("hot with the lid closed on battery: Cocaine off")
        autoOn.userToggled(to: false, triggerActive: triggerActive)
        setCocaine(false, auto: true)
        alert(Notice(from: "Cocaine", message: L("Too hot with the lid closed: Cocaine is off"), project: nil), away: true)
    }

    /// The Battery Guard has turned Cocaine off for a low battery: no trigger turns it back on until it recovers.
    private var lowBattery: Bool { settings.batteryTurnsOff && batteryGuard.tripped }

    /// Smart Triggers: an AI at work (from the hooks), a chosen program, the power source, an external display or the
    /// schedule keeps Cocaine on; "Any" or "All" of them, as chosen.
    private func evaluateTriggers(_ on: Bool) {
        guard !launchedForAlert else { return }                 // started only to show an alert: change nothing
        var states: [TriggerKind: Bool] = [:]
        if settings.triggerAgents { states[.agents] = board.anyLive() }
        let apps = settings.triggerApps.map { $0.lowercased() }
        var openApps: [String] = []                        // the chosen programs running now (for "Turned on by Xcode")
        if !apps.isEmpty {
            let names = System.runningNames()
            openApps = settings.triggerApps.filter { names.contains($0.lowercased()) }
            states[.apps] = !openApps.isEmpty
        }
        let b = System.battery
        // One battery level for everything: the power trigger lets go where Battery Guard acts (10 % when the guard is off).
        states[.power] = PowerRule.met(rule: settings.triggerPower, onAC: b?.onAC ?? PowerState.onAC, battery: b?.percent,
                                       minimum: PowerRule.batteryFloor(guardLevel: settings.batteryThreshold))
        states[.display] = DisplayRule.met(rule: settings.triggerDisplay, external: PowerState.externalDisplays)
        if settings.triggerSchedule { states[.schedule] = settings.schedule.contains(Date(), calendar: .autoupdatingCurrent) }
        let floorBlocked = b.map { batteryFloor.blocks(percent: $0.percent, onAC: $0.onAC) } ?? false
        let blocked = lowBattery || heatGuard.tripped || floorBlocked
        let (active, grace) = arbiter.evaluate(states, all: settings.triggerAll, blocked: blocked)
        if !active { triggerGrace = grace }
        triggerActive = active
        switch autoOn.step(active: active, isOn: wantOn ?? on, now: Date(), grace: triggerGrace) {
        case .turnOn: log.notice("smart trigger: on"); setCocaine(true, auto: true)
        case .turnOff: log.notice("smart trigger: off"); setCocaine(false, auto: true)
        case .none: break
        }
        // What the panel says about it: which are true now, who turned Cocaine on, why they can't.
        let live = Set(states.filter { $0.value == true }.map(\.key.rawValue))
        if model.liveTriggers != live { model.liveTriggers = live }
        let by: String? = autoOn.owned && active ? TriggerWords.reason(states, apps: openApps, power: settings.triggerPower) : nil

        if model.triggeredBy != by { model.triggeredBy = by }
        let hold: String? = !blocked || states.values.allSatisfy({ $0 != true }) ? nil
            : lowBattery || floorBlocked ? L("Triggers on hold: battery low") : L("Triggers on hold: too hot with the lid closed")
        if model.triggerHold != hold { model.triggerHold = hold }
    }

    private func timerChanged() {
        // Picking a length while Cocaine is off means "keep it awake for that long": it turns on for it.
        guard System.cocaineOn || model.on || wantOn == true else {
            autoOn.userToggled(to: true, triggerActive: triggerActive)
            setCocaine(true)                                  // by hand: starts the chosen timer
            return
        }
        let minutes = settings.timerMinutes

        settings.onUntil = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil    // applies to now
        model.onUntil = settings.onUntil
    }

    /// ⌃⌥⌘C toggles Cocaine, ⌃⌥⌘O opens the panel, ⌃⌥⌘P pauses (or resumes) alerts.
    private func applyHotkeys() {
        hotkeys.set(enabled: settings.hotkeys) { [weak self] id in
            guard let self else { return }
            switch id {
            case 1: self.toggleCocaine()
            case 2: if self.panel.isVisible { self.hidePanel() } else { self.showPanel(fromClick: false) }
            case 3: self.pauseAlerts(until: self.settings.alertsPausedUntil == nil ? Date().addingTimeInterval(3600) : nil)
            default: break
            }
        }
    }

    private let phoneListener = PhoneLink.listener()
    private let sleepWatcher = SleepWatcher()

    /// Applies the "Wake for iPhone" option: schedules the next wake (asking, when the user just turned it on, for the
    /// one-time permission) or cancels it.
    private func applyWake(ask: Bool) {
        phoneListener.maxAge = { [weak self] in (self?.settings.wakeForPhone ?? false) ? WakeSchedule.maxCommandAge : 120 }
        guard settings.wakeForPhone else { WakeSchedule.cancelInBackground(); return }
        sleepWatcher.willSleep = { [weak self] in self?.armWake(beforeSleep: true) }
        sleepWatcher.didWake = { [weak self] in
            guard let self, self.settings.wakeForPhone, self.model.phoneCount > 0 else { return }
            WakeHold.extend(90)                      // long enough to reconnect and answer
            self.phoneListener.reconnect()
            self.armWake(beforeSleep: false)
        }
        sleepWatcher.start()
        // No phone paired: nothing would listen at a wake, so none is scheduled (and no sudo at every sleep). Just turned on, the
        // one-time permission is still asked now, so pairing a phone later needs nothing more.
        guard model.phoneCount > 0 || ask else { WakeSchedule.cancelInBackground(); return }
        let failed = { [weak self] in
            guard let self else { return }
            self.settings.wakeForPhone = false
            self.model.wakeForPhone = false
            DialogCenter.shared.present(Dialogs.message(L("Couldn't turn on the wake-ups"))) { _ in }
        }
        let done = { [weak self] in if (self?.model.phoneCount ?? 0) == 0 { WakeSchedule.cancelInBackground() } }
        WakeSchedule.armInBackground { [weak self] ok in
            guard let self else { return }
            if ok || !ask { if ok { done() }; return }
            self.hidePanel(); NSApp.activate()
            let user = NSUserName()
            DispatchQueue.global().async {                 // the password prompt never stalls the app
                let granted = Authorization.installCommand(user: user).map {
                    Authorization.runAsRoot($0, prompt: L("Cocaine needs your permission once, to wake your Mac for your iPhone."))
                } ?? false
                DispatchQueue.main.async {
                    guard granted else { failed(); return }
                    WakeSchedule.armInBackground { ok in if ok { done() } else { failed() } }
                }
            }
        }
    }

    /// Schedules the next wake just before sleeping and just after waking (so there is always one ahead), unless the
    /// battery is low and unplugged. Before sleeping it must be done before the Mac goes down (a moment on the main thread,
    /// only with a phone paired); after waking it runs in the background.
    private func armWake(beforeSleep: Bool) {
        guard settings.wakeForPhone, model.phoneCount > 0 else { return }
        if let b = System.battery, !b.onAC, b.percent <= 20 { WakeSchedule.cancelInBackground(); return }
        if beforeSleep { WakeSchedule.arm() } else { WakeSchedule.armInBackground() }
    }

    /// Starts listening for the paired phones (at launch and whenever the list changes).
    private func syncPhones(_ given: [Pairing]? = nil) {
        let list = given ?? PhoneLink.load()
        let now = Date(), allowed = PhoneLink.legacyUntil
        // Answered: v2 pairings that haven't expired, and old ones only while the user allows them.
        model.phoneCount = list.filter { $0.isLegacy ? allowed != nil : !$0.expired(at: now) }.count
        model.oldPhones = list.filter { $0.isLegacy || $0.expired(at: now) }.count
        model.oldPhonesAllowedUntil = list.contains(where: \.isLegacy) ? allowed : nil
        phoneListener.onChange = { [weak self] up in self?.model.phoneLinkUp = up }
        phoneListener.sync(list)
        applyWake(ask: false)
    }

    /// Pairs a new iPhone: asks what it may do, makes a Shortcut carrying its own secret topics, and opens the share
    /// sheet (AirDrop, Messages, Mail…) on it.
    private func sendShortcutToPhone() {
        DialogCenter.shared.present(Dialogs.pairPhone()) { [weak self] r in
            guard case .button("send", _, let level) = r else { return }
            self?.makeShortcut(tier: level == "agents" ? "agents" : "basic")
        }
    }

    private func makeShortcut(tier: String) {
        guard let pairing = PhoneLink.newPairing(tier: tier) else { return }
        model.makingShortcut = true
        DispatchQueue.global().async {
            let file = PhoneShortcut.signedFile(pairing)
            DispatchQueue.main.async {
                self.model.makingShortcut = false
                guard let file else {
                    DialogCenter.shared.present(Dialogs.message(L("Can't make the Shortcut"),
                        L("Signing it needs an internet connection and iCloud (sign in to it in System Settings)."))) { _ in }
                    return
                }
                guard let list = PhoneLink.loadForChange(), PhoneLink.save(list + [pairing]) else {
                    DialogCenter.shared.present(Dialogs.message(L("Can't make the Shortcut"))) { _ in }
                    return
                }
                self.syncPhones()
                self.presentShare(file)
                log.notice("shortcut ready to share: \(file.lastPathComponent, privacy: .public)")
                // It holds a secret: don't leave the file lying around.
                DispatchQueue.main.asyncAfter(deadline: .now() + 600) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            }
        }
    }

    private func revokePhones() {
        DialogCenter.shared.present(Dialogs.revokePhones()) { [weak self] r in
            guard r.buttonID == "revoke" else { return }
            if !PhoneLink.save([]) {                          // couldn't write: delete it, and still stop answering now
                try? FileManager.default.removeItem(at: PhoneLink.file)
                DialogCenter.shared.present(Dialogs.message(L("Can't make the Shortcut"))) { _ in }
            }
            self?.syncPhones([])
        }
    }

    /// The ways to share the file (AirDrop first, Messages, Mail, Notes…) plus "Show in Finder", as a list in the panel (opened
    /// again if it was closed while the Shortcut was signed). One tap on a service and its own window opens: the panel closes
    /// first (it floats above normal windows) and the app comes to the front (those windows can't open from a panel that isn't).
    private func presentShare(_ file: URL) {
        let services = Sharing.services(for: [file])
        DialogCenter.shared.present(Dialogs.share(services)) { [weak self] r in
            guard case .choice(let id) = r else { return }
            self?.hidePanel()
            if id == "finder" { NSWorkspace.shared.activateFileViewerSelecting([file]); return }
            guard let i = Int(id.dropFirst()), services.indices.contains(i) else { return }
            Sharing.shared.perform(services[i], [file], surface: .panel)
        }
    }

    /// Fills the baggie gradually when Cocaine turns on, empties it when it turns off.
    private func refreshIcon(on: Bool, animate: Bool = true) {
        guard let b = statusItem.button else { return }
        b.toolTip = on ? L("Cocaine is on") : L("Cocaine is off")
        b.setAccessibilityLabel(b.toolTip)
        guard animate else { return }
        let target: CGFloat = on ? 1 : 0
        iconAnim?.invalidate()
        guard iconLevel >= 0 else { setIconLevel(target, pouring: false); return }   // first draw: no animation
        let start = iconLevel, duration = on ? 1.4 : 0.7
        let began = Date()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let f = min(1, CGFloat(Date().timeIntervalSince(began) / duration))
            let eased = on ? 1 - (1 - f) * (1 - f) : f * f                 // ease-out filling, ease-in emptying
            self.setIconLevel(start + (target - start) * eased, pouring: on && f < 1)
            if f >= 1 { t.invalidate(); self.iconAnim = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        iconAnim = t
    }

    private func setIconLevel(_ level: CGFloat, pouring: Bool) {
        iconLevel = level
        model.fillLevel = level
        if model.pouring != pouring { model.pouring = pouring }
        redrawStatusItem()
        updatePink()
    }

    private var pinkTimer: Timer?
    private var pinkHeading: CGFloat = -1

    /// Animates the pink powder toward where it should be (full or empty), the way the white one fills and empties.
    private func updatePink() {
        let target = model.pinkTarget
        guard target != pinkHeading else { return }
        pinkHeading = target
        pinkTimer?.invalidate()
        let start = model.pinkLevel, filling = target > start, duration = filling ? 1.4 : 0.6, began = Date()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let f = min(1, CGFloat(Date().timeIntervalSince(began) / duration))
            let eased = filling ? 1 - (1 - f) * (1 - f) : f * f                        // ease-out filling, ease-in emptying
            self.model.pinkLevel = start + (target - start) * eased
            let pouring = filling && f < 1
            if self.model.pinkPouring != pouring { self.model.pinkPouring = pouring }
            self.redrawStatusItem()
            if f >= 1 { t.invalidate(); self.pinkTimer = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        pinkTimer = t
    }

    private func redrawStatusItem() {
        statusItem.button?.image = Baggie.image(level: model.bagLevel, pouring: model.bagPouring, pink: model.bagPink)
    }

    /// While Cocaine is on, make sure the script's display helper runs (it doesn't after a restart).
    private func superviseHold() {
        guard !supervising else { return }
        supervising = true
        DispatchQueue.global().async {
            let missing = System.cocaineOn && !System.displayHeld
            if missing { engine("on") }
            DispatchQueue.main.async {
                self.supervising = false
                if missing { log.notice("display hold was missing; restarted it") }
                if self.panel.isVisible { self.refreshPanelState() }
            }
        }
    }

    /// Flips the switch at once and applies it in the background; clicks made meanwhile are never lost.
    private func toggleCocaine() {
        let target = !(wantOn ?? model.on)
        autoOn.userToggled(to: target, triggerActive: triggerActive)
        setCocaine(target)
    }

    /// Sets Cocaine on or off. By hand it also starts the chosen timer (or `forMinutes`); a trigger, the timer itself or
    /// the battery guard (`auto`) leaves the deadline alone.
    private func setCocaine(_ target: Bool, auto: Bool = false, forMinutes: Int? = nil) {
        wantOn = target
        model.on = target
        if !auto {
            let minutes = forMinutes ?? settings.timerMinutes
            settings.onUntil = target && minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
            model.onUntil = settings.onUntil
        }
        applyWanted()
    }

    /// A change of state Cocaine didn't make: not the first reading, nothing of ours in flight, and not what we last applied.
    static func isOutsideChange(last: Bool?, now: Bool, requested: Bool?, pending: Bool?) -> Bool {
        guard let last, last != now, pending == nil else { return false }
        return requested != now
    }

    private func applyWanted() {
        guard !applying, let target = wantOn else { return }
        applying = true
        requestedOn = target
        DispatchQueue.global().async {
            let arg = target ? "on" : "off"
            var status = engine(arg)
            if status == 2, Authorization.install() {   // first run on this Mac: ask for the admin password once
                log.notice("sudo rule installed")
                status = engine(arg)
            }
            DispatchQueue.main.async {
                self.applying = false
                self.requestedOn = System.cocaineOn       // what our apply really left (a failed one changed nothing)
                self.model.needsAuth = status == 2
                if self.wantOn == target { self.wantOn = nil }
                self.tick()                          // shows the real state (reverts the switch if it failed)
                self.refreshPanelState()
                self.applyWanted()                   // the user changed their mind while this was running
            }
        }
    }

    // MARK: Dimming

    /// "Turn the screen off instead" is chosen (it applies while Cocaine is on).
    private var screenOffMode: Bool { settings.dimEnabled && settings.screenOff }

    /// Tells the engine's display helper whether to keep the displays on (normal) or let them sleep (screen off).
    private func syncScreenMode() {
        let mode = screenOffMode ? "screen-off" : "normal"
        updateDimming(on: System.cocaineOn)                        // switching over while dimmed: the idle dim lets go
        DispatchQueue.global().async { run("/bin/zsh", [scriptPath, "mode", mode]) }
    }

    /// The dimming's wiring: the lid the instant it moves, the other user's session, the fades.
    private func setUpDimming() {
        dim.log = { log.notice("dim: \($0, privacy: .public)") }
        dim.onFade = { [weak self] in self?.runFades() }
        clamshell.onChange = { [weak self] closed in self?.dim.lidChanged(closed: closed) }
        clamshell.start()
        // Fast user switching: under another user nothing is dimmed (their screen, their brightness), the HUD keys go back to macOS.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionChanged(false)
        }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionChanged(true)
        }
        // The settings panel's screen went away (unplugged, the lid closed into clamshell): close it rather than leave it
        // open off screen, with the island waiting behind it.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible,
                  !NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) else { return }
            log.notice("the settings panel's screen is gone: closed")
            self.hidePanel()
        }
        // Any brightness key (handled or left to macOS): the next small change is that key's, worth a bar in the island.
        mediaKeys.onKey = { [weak self] key in if key == 2 || key == 3 { self?.island.model.hud.brightnessKey() } }
    }

    private func sessionChanged(_ active: Bool) {
        guard active != sessionActive else { return }
        sessionActive = active
        log.notice("session \(active ? "active" : "switched away", privacy: .public)")
        updateDimming(on: System.cocaineOn)
        syncSystemHUD()
    }

    private func runFades() {
        dimQuiet = Date().addingTimeInterval(3)                    // Cocaine's own changes: no Brightness bar in the island
        guard fadeTimer == nil else { return }
        let t = Timer(timeInterval: 0.025, repeats: true) { [weak self] t in
            guard let self, self.dim.fadeStep() else { t.invalidate(); self?.fadeTimer = nil; return }
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    private func dimInputs(on: Bool) -> DimInputs {
        DimInputs(on: on, dimEnabled: settings.dimEnabled, screenOff: screenOffMode, sessionActive: sessionActive, idle: idleNow,
                  delay: settings.delay, level: settings.level, allowed: Date() > brightUntil)
    }

    private func updateDimming(on: Bool) {
        let idle = idleNow                                         // Stay active's own nudges don't count as you
        dim.tick(dimInputs(on: on))
        if screenOffMode && sessionActive {
            // Once per idle stretch, after the delay: displays off. The Mac keeps running (disablesleep); input wakes them.
            if screenGate.step(idle: idle, delay: settings.delay, enabled: true, on: on, allowed: Date() > brightUntil,
                               asleep: PowerState.displaysAsleep) {
                log.notice("screens off after \(Int(idle), privacy: .public)s idle")
                DispatchQueue.global().async { PowerState.sleepDisplays() }
            }
        }
    }

    /// "Preview": the chosen dim for three seconds, then back.
    private func preview() {
        guard !model.previewing else { return }
        model.previewing = true
        dim.preview()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) { [weak self] in self?.model.previewing = false }
    }

    private func setLogin(_ enable: Bool) {
        let svc = SMAppService.mainApp
        do {
            if enable { try svc.register() } else { try svc.unregister() }
            if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            DialogCenter.shared.present(Dialogs.message(L("Can't change Open at Login"),
                "\(error.localizedDescription)\n\n" + L("You can add Cocaine manually in System Settings → General → Login Items."))) { _ in }
        }
        model.loginEnabled = svc.status == .enabled
    }
}
