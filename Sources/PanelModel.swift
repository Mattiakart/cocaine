// The panel's model (PanelModel): every setting and live value the panel and the island show.

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

// MARK: - Panel

final class PanelModel: ObservableObject {
    private let settings = Settings()
    static let magnets: [Double] = [1, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50]   // % the slider snaps to

    @Published var on = false
    @Published var holdMissing = false
    @Published var needsAuth = false
    @Published var loginEnabled = false
    @Published var previewing = false
    @Published var fillLevel: CGFloat = 0
    @Published var pouring = false
    @Published var ai = AIHooks.Status()   // the "AI alerts" row shows only on Macs with a supported AI tool
    @Published var settingAI = false
    /// Which page of the panel is open: "" = the home, else "ai", "timer", "battery", "triggers", "keys" or "remote".
    @Published var page = "" { didSet { if page != oldValue { pageChanged() } } }
    var pageChanged: () -> Void = {}
    @Published var alertsPausedUntil: Date?
    @Published var history: [AlertRecord] = []       // newest first; kept by the app delegate
    @Published var timerMinutes: Int { didSet { settings.timerMinutes = timerMinutes; timerChanged() } }
    @Published var onUntil: Date?                    // when Cocaine will turn itself off
    @Published var batteryThreshold: Int { didSet { settings.batteryThreshold = batteryThreshold } }
    @Published var batteryTurnsOff: Bool { didSet { settings.batteryTurnsOff = batteryTurnsOff } }
    @Published var triggerAgents: Bool { didSet { settings.triggerAgents = triggerAgents } }
    @Published var triggerApps: [String] { didSet { settings.triggerApps = triggerApps } }
    @Published var triggerPower: String { didSet { settings.triggerPower = triggerPower; triggersChanged() } }
    @Published var triggerPowerMin: Int { didSet { settings.triggerPowerMin = triggerPowerMin; triggersChanged() } }
    @Published var triggerDisplay: String { didSet { settings.triggerDisplay = triggerDisplay; triggersChanged() } }
    @Published var triggerSchedule: Bool { didSet { settings.triggerSchedule = triggerSchedule; triggersChanged() } }
    @Published var scheduleDays: [Int] { didSet { settings.scheduleDays = scheduleDays; triggersChanged() } }
    @Published var scheduleStart: Int { didSet { settings.scheduleStart = scheduleStart; triggersChanged() } }
    @Published var scheduleEnd: Int { didSet { settings.scheduleEnd = scheduleEnd; triggersChanged() } }
    @Published var triggerAll: Bool { didSet { settings.triggerAll = triggerAll; triggersChanged() } }
    @Published var screenOff: Bool { didSet { settings.screenOff = screenOff; screenModeChanged() } }
    @Published var allowLinks: Bool { didSet { settings.allowLinks = allowLinks } }
    /// How many Smart Triggers are set (the "Any / All" choice shows from two).
    var triggerCount: Int {
        [triggerAgents, !triggerApps.isEmpty, !triggerPower.isEmpty, !triggerDisplay.isEmpty, triggerSchedule].filter { $0 }.count
    }
    @Published var hotkeys: Bool { didSet { settings.hotkeys = hotkeys; hotkeysChanged() } }
    @Published var wakeForPhone: Bool { didSet { settings.wakeForPhone = wakeForPhone; wakeChanged() } }
    @Published var island: Bool { didSet { settings.island = island; islandChanged() } }
    @Published var haptics: Bool { didSet { settings.haptics = haptics } }
    @Published var stayActive: Bool { didSet { settings.stayActive = stayActive; presenceChanged() } }
    @Published var stayActiveAlways: Bool { didSet { settings.stayActiveAlways = stayActiveAlways } }
    @Published var stayActiveApps: [String] { didSet { settings.stayActiveApps = stayActiveApps } }
    @Published var replaceHUD: Bool { didSet { settings.replaceHUD = replaceHUD; hudReplaceChanged() } }
    @Published var presenceAccess = Presence.hasAccess
    @Published var permissionProblems: [Permission] = []
    /// Cocaine is off but Stay active is working: the bag is full of pink powder.
    /// The pink powder has its own fill, animated like the white one: it pours in when Cocaine is off and Stay active is on (whether
    /// or not a chat app is open), and empties when either changes.
    @Published var pinkLevel: CGFloat = 0
    @Published var pinkPouring = false
    var pinkTarget: CGFloat { (!on && (stayActive || presenceActive) && fillLevel < 0.05) ? 1 : 0 }
    var bagPink: Bool { pinkLevel > 0.01 && fillLevel < 0.05 }
    var bagLevel: CGFloat { bagPink ? pinkLevel : fillLevel }
    var bagPouring: Bool { bagPink ? pinkPouring : pouring }
    @Published var presenceActive = false
    /// Why Cocaine is on, when a Smart Trigger turned it on ("Xcode", "On the charger"…); nil otherwise.
    @Published var triggeredBy: String?
    /// Why the triggers can't turn it on now (a low battery, heat); nil when they can.
    @Published var triggerHold: String?
    /// The triggers that are true right now (TriggerKind raw values): a green dot on their rows.
    @Published var liveTriggers: Set<String> = []
    @Published var board: [AgentEntry] = []          // what each AI session is doing, from the hooks (waiting for you first)
    @Published var approvals: [ApprovalRequest] = [] // requests waiting for an answer from the notch
    @Published var agentNotice: String?              // what a click on a session could (and couldn't) do
    @Published var agentApprovals: Bool { didSet { settings.agentApprovals = agentApprovals } }
    var focusAgent: (_ origin: AgentOrigin?, _ name: String) -> Void = { _, _ in }
    var answerApproval: (_ id: String, _ choice: Int) -> Void = { _, _ in }
    var releaseApproval: (_ id: String) -> Void = { _ in }
    @Published var makingShortcut = false
    @Published var phoneCount = 0                    // iPhones paired for remote control
    @Published var phoneLinkUp = false               // at least one is connected to the relay
    @Published var oldPhones = 0                     // pairings with an old (unprotected) Shortcut, or expired
    @Published var oldPhonesAllowedUntil: Date?      // old Shortcuts answered (basic commands only) until then
    @Published var phone = ""                        // "" = not set up; else what alerts go to
    @Published var battery: String?                  // "80%" (nil = no battery)
    @Published var alertDone: Bool { didSet { settings.alertDone = alertDone } }
    @Published var alertInput: Bool { didSet { settings.alertInput = alertInput } }
    @Published var alertFlash: Bool { didSet { settings.alertFlash = alertFlash } }
    @Published var alertSpeak: Bool { didSet { settings.alertSpeak = alertSpeak } }
    @Published var alertVoice: String { didSet { settings.alertVoice = alertVoice; previewVoice() } }   // hear it
    @Published var alertPerSession: Bool { didSet { settings.alertPerSession = alertPerSession } }
    @Published var alertWhenPresent: Bool { didSet { settings.alertWhenPresent = alertWhenPresent } }
    @Published var alertRepeatMinutes: Int { didSet { settings.alertRepeatMinutes = alertRepeatMinutes } }
    @Published var alertDuration: Double { didSet { settings.alertDuration = alertDuration } }
    @Published var alertSound: String {
        didSet { settings.alertSound = alertSound; if !alertSound.isEmpty { NSSound(named: alertSound)?.play() } }   // hear it
    }
    @Published var dimEnabled: Bool { didSet { settings.dimEnabled = dimEnabled; screenModeChanged() } }
    @Published private(set) var levelPercent: Double
    @Published var delayMinutes: Int { didSet { if delayMinutes > 0 { settings.delay = Double(delayMinutes * 60) } } }
    /// "" = same as the Mac, otherwise a code from Language.codes. Changes apply at once.
    @Published var language: String = Language.chosen ?? "" {
        didSet { Language.set(language.isEmpty ? nil : language, persist: persistLanguage); Self.controlWords(); languageChanged() }
    }
    var persistLanguage = true
    var languageChanged: () -> Void = {}

    // wired up by AppDelegate
    var toggleCocaine: () -> Void = {}
    var preview: () -> Void = {}
    var setLogin: (Bool) -> Void = { _ in }
    var setAI: (_ id: String, _ on: Bool) -> Void = { _, _ in }
    var pauseAlerts: (Date?) -> Void = { _ in }       // nil = resume
    var testAlert: () -> Void = {}
    var clearHistory: () -> Void = {}
    var previewVoice: () -> Void = {}
    var timerChanged: () -> Void = {}
    var hotkeysChanged: () -> Void = {}
    var triggersChanged: () -> Void = {}
    var screenModeChanged: () -> Void = {}
    var screenOffNow: () -> Void = {}
    var wakeChanged: () -> Void = {}
    var islandChanged: () -> Void = {}
    var presenceChanged: () -> Void = {}
    var hudReplaceChanged: () -> Void = {}
    var requestPresence: () -> Void = {}
    var requestPermission: (Permission) -> Void = { _ in }
    var testPhone: () -> Void = {}
    var sendShortcut: () -> Void = {}
    var revokePhones: () -> Void = {}
    var allowOldPhones: (Bool) -> Void = { _ in }
    var removeOldPhones: () -> Void = {}
    var quit: () -> Void = {}
    /// Closes the settings panel and opens the island again (on the page it was on), for the strip's back button.
    var backToIsland: () -> Void = {}

    /// The few words Sources/Controls.swift shows by itself, in the app's language; its haptic tap.
    static func controlWords() {
        L10nControls.opensList = L("Opens a list"); L10nControls.all = L("All"); L10nControls.none = L("None")
        L10nControls.selected = L("%d selected"); L10nControls.search = L("Search"); L10nControls.openNow = L("Open now")
        ControlHaptics.tap = { Haptic.tap(.alignment) }
    }

    init() {
        Self.controlWords()
        dimEnabled = settings.dimEnabled
        levelPercent = Double((settings.level * 100).rounded())
        delayMinutes = Int(settings.delay) / 60
        alertDone = settings.alertDone
        alertInput = settings.alertInput
        alertFlash = settings.alertFlash
        alertSpeak = settings.alertSpeak
        alertVoice = settings.alertVoice
        alertPerSession = settings.alertPerSession
        agentApprovals = settings.agentApprovals
        alertWhenPresent = settings.alertWhenPresent
        alertRepeatMinutes = settings.alertRepeatMinutes
        alertDuration = settings.alertDuration
        alertSound = settings.alertSound
        alertsPausedUntil = settings.alertsPausedUntil
        history = settings.alertHistory
        timerMinutes = settings.timerMinutes
        onUntil = settings.onUntil
        batteryThreshold = settings.batteryThreshold
        batteryTurnsOff = settings.batteryTurnsOff
        triggerAgents = settings.triggerAgents
        triggerApps = settings.triggerApps
        triggerPower = settings.triggerPower
        triggerPowerMin = settings.triggerPowerMin
        triggerDisplay = settings.triggerDisplay
        triggerSchedule = settings.triggerSchedule
        scheduleDays = settings.scheduleDays
        scheduleStart = settings.scheduleStart
        scheduleEnd = settings.scheduleEnd
        triggerAll = settings.triggerAll
        screenOff = settings.screenOff
        allowLinks = settings.allowLinks
        hotkeys = settings.hotkeys
        wakeForPhone = settings.wakeForPhone
        island = settings.island
        haptics = settings.haptics
        stayActive = settings.stayActive
        stayActiveAlways = settings.stayActiveAlways
        stayActiveApps = settings.stayActiveApps
        replaceHUD = settings.replaceHUD
    }

    /// Free movement in whole percents, but values near a magnet snap to it, with a trackpad "click".
    func setLevel(_ raw: Double) {
        var v = raw.rounded()
        if let near = Self.magnets.min(by: { abs($0 - raw) < abs($1 - raw) }), abs(near - raw) <= 1.2 { v = near }
        guard v != levelPercent else { return }
        if Self.magnets.contains(v) { Haptic.tap(.alignment) }        // through Haptic: silent when Haptic feedback is off
        levelPercent = v
        settings.level = Float(v) / 100
    }
}
