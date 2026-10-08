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

    // Profiles (Sources/AwakeProfiles.swift): the list in priority order, cleaned on every change.
    @Published var profiles: [AwakeProfile] {
        didSet {
            let c = AwakeProfiles.clean(profiles)
            if c != profiles { profiles = c }
            settings.awakeProfiles = profiles
            triggersChanged()
        }
    }
    /// Engaged profiles (ids, priority order), the ones whose conditions hold now, the profile that decides.
    @Published var engagedProfiles: [String] = []
    @Published var holdingProfiles: Set<String> = []
    @Published var leadProfile: String?
    /// The profile open in the editor (not a setting).
    @Published var editingProfile: String?
    @Published var locationAllowed = false
    /// Bluetooth devices the Mac knows (for the picker; read when asked for).
    @Published var bluetoothKnown: [String] = []
    // Keep disks awake (Sources/DriveAlive.swift).
    @Published var driveAliveVolumes: [String] {
        didSet {
            let gone = oldValue.filter { o in !driveAliveVolumes.contains { $0.caseInsensitiveCompare(o) == .orderedSame } }
            settings.driveAliveVolumes = driveAliveVolumes
            if !gone.isEmpty { drivesRemoved(gone) }
        }
    }
    @Published var driveAliveInterval: Int { didSet { settings.driveAliveInterval = driveAliveInterval } }
    @Published var driveAliveMethod: String {
        didSet {
            settings.driveAliveMethod = driveAliveMethod
            if oldValue != driveAliveMethod { driveMethodChanged(driveAliveMethod, driveAliveVolumes) }
        }
    }
    @Published var driveAliveAlways: Bool { didSet { settings.driveAliveAlways = driveAliveAlways } }
    @Published var driveStatus: [String: DriveAliveRunner.Status] = [:]
    // Statistics and the reminder (Sources/AwakeSessions.swift).
    @Published var stats: AwakeStats
    @Published var remindHours: Int { didSet { settings.remindHours = remindHours } }

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

    /// Renders and tests: fixed lists instead of this Mac's audio outputs, volumes, USB devices and processes.
    var sample: [String: [String]]?

    /// `--render-panel … --awake`: every keep-awake row filled with sample values (in memory; nothing of this Mac is shown).
    func fillSample(rows: Bool) {
        sample = ["audio": ["MacBook Pro Speakers", "AirPods Pro", "LG UltraFine Display Audio"], "volumes": ["Backup 2TB", "Photos"],
                  "usb": ["YubiKey 5C NFC", "Studio Display"], "processes": ["Xcode", "ffmpeg", "node", "Terminal"],
                  "wifi": ["Office", "Office-5G", "Home"], "bluetooth": ["MX Keys", "AirPods Pro", "Magic Trackpad"],
                  "apps": ["Keynote", "Xcode", "Final Cut Pro", "Zoom"]]
        fillTriggersSample(CommandLine.arguments)              // --triggers: sample profiles and disks (Sources/TriggersTests.swift)
        guard rows else { return }
        triggerVPN = true; triggerCPU = "above"; triggerCPUPercent = 75; triggerCPUMinutes = 10
        triggerAudio = ["AirPods Pro"]; triggerVolumes = ["Backup 2TB", "Photos"]; triggerUSB = ["YubiKey 5C NFC"]
        unplugOff = 300; lockPause = true; launchTurnsOn = "manual"; leftClickToggles = true; menuIcon = "cup"; notifyChanges = true
        cpuLoad = 82
        whileTarget = WhileTarget(kind: .process, pid: 4001, started: 0, name: "ffmpeg")
        packNote = String(format: L("“%@” opened in Shortcuts"), AwakeShortcuts.title(.keepAwake))
    }

    /// `--render-panel … --triggers` (Sources/TriggersTests.swift): sample profiles, disks and statistics, in memory.
    func fillTriggersSample(_ args: [String]) {
        guard args.contains("--triggers") else { return }
        TriggersFixtures.fill(self, edit: args.contains("--edit-profile"))
    }

    var triggersChanged: () -> Void = {}
    var iconChanged: () -> Void = {}
    var startWhile: (WhileTarget) -> Void = { _ in }
    var stopWhile: () -> Void = {}
    var keepAwakeUntil: (Date) -> Void = { _ in }
    var addShortcuts: () -> Void = {}
    var drivesRemoved: ([String]) -> Void = { _ in }
    var driveMethodChanged: (String, [String]) -> Void = { _, _ in }
    var resetStats: () -> Void = {}

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
        profiles = settings.awakeProfiles
        driveAliveVolumes = settings.driveAliveVolumes
        driveAliveInterval = settings.driveAliveInterval
        driveAliveMethod = settings.driveAliveMethod
        driveAliveAlways = settings.driveAliveAlways
        stats = settings.awakeStats
        remindHours = settings.remindHours
    }

    /// Changes one profile (by id) in place.
    func update(_ id: String, _ change: (inout AwakeProfile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        var p = profiles[i]
        change(&p)
        profiles[i] = p
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
    // Profiles, disks, statistics, the reminder.
    var profileProbe: ProfileProbe = SystemProfileProbe()
    private var engine = ProfileEngine()
    private var profileDownloads = DownloadActivity()
    private(set) var outcome = ProfileOutcome()
    let drives = DriveAliveRunner()
    private var reminder = OnReminder()
    private var lastStatsSave = Date.distantPast
    /// Set by AppDelegate: the user's idle time (Stay active's own nudges left out).
    var idleSeconds: () -> Double = { System.idleSeconds }
    /// Set by AppDelegate: the lead profile's "display may sleep" changed (the engine's display hold follows it).
    var displaySleepChanged: () -> Void = {}

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
        drives.start()
        settings.d.set([String](), forKey: "profilesLive")            // nothing engaged yet in this run
        drives.statusChanged = { [weak self] name, st in self?.model.driveStatus[name] = st }
        model.drivesRemoved = { [weak self] names in self?.drives.removed(names) }
        model.driveMethodChanged = { [weak self] method, names in self?.drives.methodChanged(to: method, names: names) }
        model.resetStats = { [weak self] in self?.resetStats() }
        LocationAccess.shared.changed = { [weak self] in
            self?.model.locationAllowed = LocationAccess.shared.allowed
            self?.model.triggersChanged()
        }
        if AwakeProfiles.needs(model.profiles).contains(.wifi) { model.locationAllowed = LocationAccess.shared.allowed }
        // A volume coming or going: the list is read again (in the background), then the triggers look at once (they also look
        // every 5 s).
        MountedVolumes.shared.refresh()
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MountedVolumes.shared.refresh { self?.model.triggersChanged() }
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

    // MARK: Profiles

    /// One step of the profiles (every 5 s, with the triggers): what they decide, the panel's state, the notices.
    func profileStep(now: Date = Date()) -> ProfileOutcome {
        let list = model.profiles
        let before = outcome
        if !list.contains(where: { $0.enabled }) {
            engine.reset()
            outcome = ProfileOutcome()
        } else {
            let needs = AwakeProfiles.needs(list)
            var snap = profileProbe.snapshot(needs: needs, base: probe, now: now)
            if needs.contains(.idle) { snap.idle = idleSeconds() }
            if needs.contains(.downloads) { snap.downloading = profileDownloads.sample(SystemAwakeProbe.downloads()) }
            outcome = engine.step(list, snapshot: snap)
        }
        publish(outcome, before: before)
        return outcome
    }

    private func publish(_ o: ProfileOutcome, before: ProfileOutcome) {
        if model.engagedProfiles != o.engaged { model.engagedProfiles = o.engaged }
        if model.holdingProfiles != o.holding { model.holdingProfiles = o.holding }
        if model.leadProfile != o.lead?.id { model.leadProfile = o.lead?.id }
        if before.displaySleep != o.displaySleep { displaySleepChanged() }
        if before.engaged != o.engaged {
            let names = o.engaged.compactMap { id in model.profiles.first { $0.id == id }?.name }
            settings.d.set(names, forKey: "profilesLive")                 // what `cocaine profiles` shows
        }
        for p in o.started where p.notify {
            log.notice("profile started")
            notice(p.action == .letSleep ? "moon.zzz.fill" : "bolt.fill",
                   String(format: p.action == .letSleep ? L("“%@” started: triggers wait") : L("“%@” started: keeping the Mac awake"), p.name))
        }
        for p in o.stopped where p.notify {
            log.notice("profile stopped")
            notice("checkmark.circle", String(format: L("“%@” ended"), p.name))
        }
    }

    /// The lead profile lets the displays sleep.
    var profileDisplaySleep: Bool { outcome.displaySleep }

    /// `cocaine://profile?name=…&enabled=…`, AppleScript, `cocaine profiles enable|disable`: false when there is no such profile.
    @discardableResult
    func setProfile(_ key: String, enabled: Bool) -> Bool {
        guard let p = AwakeProfiles.find(key, in: model.profiles) else { return false }
        model.update(p.id) { $0.enabled = enabled }
        return true
    }

    // MARK: Every 2 s: unplugging, "while…"

    func tick(on: Bool, onAC: Bool?, now: Date = Date()) {
        drives.tick(settings: settings, on: on, now: now)                // keep disks awake (Sources/DriveAlive.swift)
        if let h = reminder.step(onSince: model.stats.onSince, every: settings.remindHours, now: now) {
            notice("clock.fill", String(format: L("Cocaine has been on for %@"), Dur.short(minutes: h * 60)))
        }
        if on, now.timeIntervalSince(lastStatsSave) >= 60 {
            model.stats.seen(now: now); settings.awakeStats = model.stats; lastStatsSave = now
        }
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
        model.stats.launched(on: on, now: Date())
        settings.awakeStats = model.stats
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
        model.stats.turned(on: on, now: Date())
        settings.awakeStats = model.stats
        guard settings.notifyChanges else { return }
        notice(on ? "bolt.fill" : "moon.zzz.fill", ChangeNotice.text(on: on, reason: reason))
    }

    func resetStats() {
        var s = AwakeStats(since: Date())
        if model.stats.onSince != nil { s.turned(on: true, now: Date()) }   // the session going on keeps counting, from now
        model.stats = s
        settings.awakeStats = s
    }

    /// The menu-bar image for the chosen style; nil = the baggie.
    func iconImage(on: Bool) -> NSImage? { MenuIconStyle.image(settings.menuIcon, on: on) }
}
