// The keep-awake extras wired to the app: the new triggers' readings, "keep awake while…", turn off when unplugged, pause
// while locked, the menu-bar icon style and the change notices. AppDelegate owns one AwakeCenter and gives it a few closures
// (it keeps the on/off logic: setCocaine, AutoOn); the pure rules are in Sources/AwakeTriggers.swift, the panel's rows in
// Sources/AwakePanel.swift, the model they share here (AwakeModel).

import AppKit
import Combine

/// What the panel's keep-awake rows show and change (the settings in Sources/AwakeTriggers.swift).
final class AwakeModel: ObservableObject {
    static let shared = AwakeModel()
    private let settings = Settings()

    @Published var triggerVPN: Bool { didSet { settings.triggerVPN = triggerVPN; triggersChanged() } }
    @Published var triggerCPU: String { didSet { settings.triggerCPU = triggerCPU; triggersChanged() } }
    @Published var triggerCPUPercent: Int { didSet { settings.triggerCPUPercent = triggerCPUPercent; triggersChanged() } }
    @Published var triggerCPUMinutes: Int { didSet { settings.triggerCPUMinutes = triggerCPUMinutes; triggersChanged() } }
    @Published var triggerAudio: [String] { didSet { settings.triggerAudio = triggerAudio; triggersChanged() } }
    @Published var triggerVolumes: [String] { didSet { settings.triggerVolumes = triggerVolumes; triggersChanged() } }
    @Published var triggerUSB: [String] { didSet { settings.triggerUSB = triggerUSB; triggersChanged() } }
    @Published var unplugOff: Int { didSet { settings.unplugOff = unplugOff } }
    @Published var lockPause: Bool { didSet { settings.lockPause = lockPause } }
    @Published var launchTurnsOn: String { didSet { settings.launchTurnsOn = launchTurnsOn } }
    @Published var leftClickToggles: Bool { didSet { settings.leftClickToggles = leftClickToggles } }
    @Published var menuIcon: String { didSet { settings.menuIcon = menuIcon; iconChanged() } }
    @Published var notifyChanges: Bool { didSet { settings.notifyChanges = notifyChanges } }

    /// "Keep awake while…": what is being waited for (nil: nothing), and a line about it.
    @Published var whileTarget: WhileTarget?
    @Published var whileNote: String?
    /// The panel's "until" time (minutes after midnight); not a setting.
    @Published var untilClock: Int = AwakeModel.defaultUntil(Date())
    /// The last CPU load measured (for the CPU row), 0…100.
    @Published var cpuLoad: Int?
    /// The Shortcuts pack being made, and what came of it.
    @Published var packBusy = false
    @Published var packNote: String?

    var triggersChanged: () -> Void = {}
    var iconChanged: () -> Void = {}
    var startWhile: (WhileTarget) -> Void = { _ in }
    var stopWhile: () -> Void = {}
    var keepAwakeUntil: (Date) -> Void = { _ in }
    var addShortcuts: () -> Void = {}

    var config: AwakeTriggerConfig {
        AwakeTriggerConfig(vpn: triggerVPN, cpu: triggerCPU, cpuPercent: triggerCPUPercent, cpuMinutes: triggerCPUMinutes,
                           audio: triggerAudio, volumes: triggerVolumes, usb: triggerUSB)
    }

    init() {
        triggerVPN = settings.triggerVPN
        triggerCPU = settings.triggerCPU
        triggerCPUPercent = settings.triggerCPUPercent
        triggerCPUMinutes = settings.triggerCPUMinutes
        triggerAudio = settings.triggerAudio
        triggerVolumes = settings.triggerVolumes
        triggerUSB = settings.triggerUSB
        unplugOff = settings.unplugOff
        lockPause = settings.lockPause
        launchTurnsOn = settings.launchTurnsOn
        leftClickToggles = settings.leftClickToggles
        menuIcon = settings.menuIcon
        notifyChanges = settings.notifyChanges
        whileTarget = settings.whileTarget
    }

    /// Two hours from now, on the half hour (what the "until" row starts on).
    static func defaultUntil(_ now: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: now.addingTimeInterval(2 * 3600))
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return ((m + 29) / 30 * 30) % 1440
    }
}

/// What AwakeCenter asks of the app.
enum AwakeRequest: Equatable {
    case startByHand(until: Date?)   // "keep awake while…" started: on, as if by hand, no timer
    case resume(until: Date?)        // the screen unlocked: the ON made by hand comes back, with its deadline
    case stopByHand(String)          // unplugged, or what "while…" waited for ended: off, and said (the user's off: triggers wait)
    case pause                       // the screen locked: off for now (not the user's off)
}

final class AwakeCenter {
    let model = AwakeModel.shared
    private let settings = Settings()
    var probe: AwakeProbe = SystemAwakeProbe()
    private var triggers = AwakeTriggerSet()
    private var unplug = UnplugGuard()
    private(set) var lock = LockPause()
    private var watch = WhileWatch()
    private var downloads = DownloadActivity()
    private var observers: [NSObjectProtocol] = []

    /// Set by AppDelegate.
    var perform: (AwakeRequest) -> Void = { _ in }
    var notice: (_ icon: String, _ text: String) -> Void = { _, _ in }

    /// Triggers wait while the screen is locked (with "pause while locked" on).
    var blocksTriggers: Bool { lock.blocksTriggers }

    /// The lock and unlock, from the system (no permission needed).
    func start() {
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked()
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenUnlocked()
        })
        // A volume coming or going: the triggers look again soon (they also look every 5 s).
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                self?.model.triggersChanged()
            })
        }
    }

    // MARK: Triggers

    /// The new triggers' states (only the enabled ones), for the arbiter. Every 5 s.
    func triggerStates(now: Date = Date()) -> [TriggerKind: Bool] {
        let s = triggers.states(settings.awakeTriggers, probe: probe, now: now)
        let load = triggers.cpu.load.map { Int(($0 * 100).rounded()) }
        if model.cpuLoad != load { model.cpuLoad = load }
        return s
    }

    func words(_ states: [TriggerKind: Bool]) -> [String] { AwakeTriggerSet.words(states, settings.awakeTriggers, probe: probe) }

    // MARK: Every 2 s: unplugging, "while…"

    func tick(on: Bool, onAC: Bool?, now: Date = Date()) {
        if let onAC, unplug.step(delay: settings.unplugOff, onAC: onAC, on: on, now: now) {
            log.notice("unplugged: Cocaine off")
            perform(.stopByHand(L("Charger unplugged: Cocaine is off")))
        }
        guard let t = model.whileTarget else { return }
        if !on { if !lock.locked { endWhile(nil) }; return }   // turned off meanwhile (by hand, the timer, the battery…); a lock pause: waits
        let alive: Bool
        switch t.kind {
        case .process: alive = ProcessInfoReader.alive(t)
        case .downloads:
            guard let a = downloads.sample(SystemAwakeProbe.downloads()) else {
                endWhile(L("Can't read the Downloads folder: allow Cocaine in Privacy & Security → Files and Folders"))
                return
            }
            alive = a
        }
        if watch.step(alive: alive, kind: t.kind, now: now) == .end {
            let text = t.kind == .downloads ? L("Downloads finished: Cocaine is off") : String(format: L("%@ ended: Cocaine is off"), t.name)
            endWhile(nil)
            perform(.stopByHand(text))
        }
    }

    /// Starts "keep awake while…": Cocaine on (no timer) until it ends. Downloads: only if the folder can be read.
    func startWhile(_ t: WhileTarget) {
        var t = t
        t.name = String(t.name.prefix(60))
        if t.kind == .downloads {
            downloads = DownloadActivity()
            guard downloads.sample(SystemAwakeProbe.downloads()) != nil else {
                model.whileNote = L("Can't read the Downloads folder: allow Cocaine in Privacy & Security → Files and Folders")
                return
            }
        } else if !ProcessInfoReader.alive(t) {
            model.whileNote = String(format: L("%@ isn't running any more"), t.name)
            return
        }
        watch.reset()
        model.whileTarget = t
        model.whileNote = nil
        settings.whileTarget = t
        perform(.startByHand(until: nil))
    }

    func endWhile(_ note: String?) {
        watch.reset()
        model.whileTarget = nil
        model.whileNote = note
        settings.whileTarget = nil
    }

    /// At launch: a "while…" kept from before goes on only when Cocaine is still on (an update, a crash's adopted session).
    func restore(on: Bool) {
        guard let t = settings.whileTarget else { return }
        if on && (t.kind == .downloads || ProcessInfoReader.alive(t)) { model.whileTarget = t } else { endWhile(nil) }
    }

    // MARK: The lock

    /// Set by AppDelegate: is it on, did a trigger turn it on, its deadline.
    var state: () -> (on: Bool, triggerOwned: Bool, until: Date?) = { (false, false, nil) }

    func screenLocked() {
        let s = state()
        if lock.lock(enabled: settings.lockPause, on: s.on, triggerOwned: s.triggerOwned, until: s.until) == .turnOff {
            log.notice("screen locked: Cocaine paused")
            perform(.pause)
        }
    }

    func screenUnlocked() {
        if case .turnOn(let until) = lock.unlock(now: Date()) {
            log.notice("screen unlocked: Cocaine back on")
            perform(.resume(until: until))
        }
        model.triggersChanged()                         // triggers may turn it on again now
    }

    /// Turned on or off from outside while locked: that stays.
    func userChanged() { lock.userChanged() }

    // MARK: Notices and the icon

    /// A change of state: a notice when asked for (never for the first reading).
    func changed(on: Bool, reason: String?) {
        guard settings.notifyChanges else { return }
        notice(on ? "bolt.fill" : "moon.zzz.fill", ChangeNotice.text(on: on, reason: reason))
    }

    /// The menu-bar image for the chosen style; nil = the baggie.
    func iconImage(on: Bool) -> NSImage? { MenuIconStyle.image(settings.menuIcon, on: on) }
}
