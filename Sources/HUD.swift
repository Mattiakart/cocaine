// The volume and brightness HUD: HUDWatch, the frozen system HUD before macOS 26 (SystemHUD) and the media keys.

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

/// Which brightness changes get a bar in the island. Only the user's: macOS changes the brightness by itself too (automatic
/// brightness's drift and jumps, the charger plugged in or out with "Slightly dim the display on battery", the displays waking),
/// and a bar for those covered the battery's own HUD the moment the charger went in (2.8.0). A change is the user's when it
/// follows a brightness key (handled or left to macOS) pressed after the last system change, or, for a bigger jump (a slider in
/// Control Center, System Settings or the island), when the pointer or the keyboard was used a moment ago. Within
/// `systemQuiet` of a power-source change or a display wake only a key counts. Pure (--island-review-test).
enum BrightnessHUDRule {
    static let keyWindow: TimeInterval = 1.5
    static let systemQuiet: TimeInterval = 6
    static let inputWindow: TimeInterval = 2
    static func reports(delta: Float, sinceKey: TimeInterval, sinceSystem: TimeInterval, sinceInput: TimeInterval) -> Bool {
        let quiet = sinceSystem < systemQuiet
        // A key counts only when it came after the system's change (a key pressed just before plugging in doesn't own the ramp).
        if sinceKey < keyWindow && (!quiet || sinceKey < sinceSystem) { return HUDWatch.reports(delta: delta, sinceKey: sinceKey) }
        if quiet { return false }
        return HUDWatch.reports(delta: delta, sinceKey: .infinity) && sinceInput < inputWindow
    }

    /// Seconds since the user last clicked, dragged or typed (the window server's own count; no event monitor, no permission).
    static func secondsSinceInput() -> TimeInterval {
        let kinds: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

}

/// Volume and brightness changes (the keys, the menu bar, Control Center) as a bar in the island's HUD below the notch: CoreAudio tells us about
/// the volume itself; the brightness of every backlit display is read four times a second. Only the user's brightness changes
/// are shown (BrightnessHUDRule): never automatic brightness's, the charger's or a wake's.
final class HUDWatch {
    /// icon, label, level, and the display it is about (brightness; nil for the volume): the island's HUD goes to that screen.
    var onChange: ((String, String, Double, CGDirectDisplayID?) -> Void)?
    var suppressBrightness: () -> Bool = { false }
    private var timer: Timer?
    private var started = false
    private var lastVolume: Float?, lastMute: Bool?
    private var lastBrightness: [CGDirectDisplayID: Float] = [:]
    private var backlit: [CGDirectDisplayID] = []
    private var polls = 0
    private var keyAt = Date.distantPast
    private let screens = Screens()
    private var device = AudioDeviceID(0)
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private static let volumeSelector: AudioObjectPropertySelector = 0x766D_7663       // 'vmvc': the virtual main volume
    static let pollInterval = 0.25

    private var systemAt = Date.distantPast
    private var wakeObservers: [NSObjectProtocol] = []
    /// Injected by the tests (--island-review-test): the clock, the input idle time, and the app's one power-source watch
    /// (PowerSourceWatch in Sources/Power.swift: looked at again on the spot, then when the charger last went in or out).
    var now: () -> Date = { Date() }
    var sinceInput: () -> TimeInterval = { BrightnessHUDRule.secondsSinceInput() }
    var powerChangedAt: () -> Date = { PowerSourceWatch.shared.check(); return PowerSourceWatch.shared.changedAt }

    /// A brightness key went by (handled or left to macOS): small changes in the next moment are that key's.
    func brightnessKey() { keyAt = now() }
    /// macOS is about to set the brightness by itself (the displays waking; the charger is PowerSourceWatch's): quiet for a moment.
    func systemChanged() { systemAt = now() }

    /// Shown in the island? Right after a key any change counts; otherwise only one bigger than automatic brightness's drift
    /// (a key step is 1/16, a Control Center slider jumps; the ambient ramp moves a few thousandths per poll).
    static func reports(delta: Float, sinceKey: TimeInterval) -> Bool {
        abs(delta) > (sinceKey < 1.5 ? 0.002 : 0.03)
    }

    func start() {
        guard !started else { return }
        started = true
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.bind() }
        systemListener = l
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, l)
        bind()
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.systemChanged()
            })
        }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.pollBrightness() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.invalidate(); timer = nil
        wakeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        wakeObservers.removeAll()
        if let l = systemListener {
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, l)
        }
        systemListener = nil
        unbind()
        lastVolume = nil; lastMute = nil; lastBrightness = [:]
    }

    private func addresses() -> [AudioObjectPropertyAddress] {
        [AudioObjectPropertyAddress(mSelector: Self.volumeSelector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
         AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)]
    }

    private func unbind() {
        if device != 0, let l = deviceListener { for var a in addresses() { AudioObjectRemovePropertyListenerBlock(device, &a, .main, l) } }
        deviceListener = nil; device = 0
    }

    /// Follows the current output device (headphones in, a speaker out…).
    private func bind() {
        unbind()
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var d = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &d) == noErr, d != 0 else { return }
        device = d
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.volumeChanged() }
        deviceListener = l
        for var addr in addresses() { AudioObjectAddPropertyListenerBlock(d, &addr, .main, l) }
        lastVolume = nil; lastMute = nil
        readVolume(report: false)
    }

    private func volumeChanged() { readVolume(report: true) }

    private func readVolume(report: Bool) {
        guard device != 0 else { return }
        var va = addresses()[0], ma = addresses()[1]
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &va, 0, nil, &size, &v) == noErr else { return }
        var mute: UInt32 = 0, msize = UInt32(MemoryLayout<UInt32>.size)
        let muted = AudioObjectGetPropertyData(device, &ma, 0, nil, &msize, &mute) == noErr && mute != 0
        if report, lastVolume != nil, abs((lastVolume ?? v) - v) > 0.001 || (lastMute != nil && lastMute != muted) {
            let icon = muted || v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            onChange?(icon, L("Volume"), muted ? 0 : Double(v), nil)
        }
        lastVolume = v; lastMute = muted
    }

    /// Every backlit display (the built-in, or an Apple display with the lid closed); the list is looked at again every 4 s.
    private func pollBrightness() {
        if polls % 16 == 0 { backlit = screens.online.filter(screens.hasBacklight) }
        polls += 1
        var seen: [CGDirectDisplayID: Float] = [:]
        for id in backlit {
            guard let b = screens.brightness(id) else { continue }
            seen[id] = b
            observe(id, b)
        }
        lastBrightness = seen
    }

    /// One display's brightness as read now: a bar if the change is the user's. (The tests feed it directly.)
    func observe(_ id: CGDirectDisplayID, _ b: Float) {
        defer { lastBrightness[id] = b }
        guard let l = lastBrightness[id], Self.reports(delta: b - l, sinceKey: now().timeIntervalSince(keyAt)), !suppressBrightness() else { return }
        // The charger's last change, from the app's one power-source watch, which looks again here (not only when IOKit says
        // so: the brightness can start moving before that notification is handled, and its first step must be quiet too).
        let t = now()
        let since = min(t.timeIntervalSince(systemAt), t.timeIntervalSince(powerChangedAt()))
        if BrightnessHUDRule.reports(delta: b - l, sinceKey: t.timeIntervalSince(keyAt), sinceSystem: since, sinceInput: sinceInput()) {
            onChange?("sun.max.fill", L("Brightness"), Double(b), id)
        }
    }
}

/// Before macOS 26 the volume and brightness HUD is drawn by a helper process, OSDUIHelper. While the island shows the bars, that
/// helper is kept started but frozen, so it never draws anything; at any other moment (option off, island hidden in full screen or
/// behind the settings panel, another user's session, Cocaine quitting) it is simply ended and macOS starts a fresh one the next
/// time it needs it. If Cocaine dies, its watchdog ends the frozen helper (Sources/Recovery.swift).
/// From macOS 26 the HUD is drawn by Control Center (its binary carries the OSD service; on 27.0.1, without Cocaine, OSDUIHelper was
/// not running and logged nothing), and Control Center can't be frozen (it owns the menu bar's controls): nothing is
/// frozen or started there. The keys Cocaine handles never reach macOS, so macOS has nothing to show for them.
final class SystemHUD {
    private var timer: Timer?
    private var lastKick = Date.distantPast
    private var lastScan = Date.distantPast
    private var pid: pid_t = 0
    private(set) var active = false

    static func freezesHelper(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> Bool { osMajor < 26 }

    func enable() {
        guard !active else { return }
        active = true
        RecoverySession.shared.noteHUD(true)                                      // noted before the first freeze
        tick()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func disable() {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        pid = 0
        for pid in Self.helperPIDs() { kill(pid, SIGKILL) }
        RecoverySession.shared.noteHUD(false)
    }

    /// After a crash the helper could be left frozen: end any frozen one at launch.
    static func cleanup() { for pid in helperPIDs() where isStopped(pid) { kill(pid, SIGKILL) } }

    /// The helper's pid is kept and checked with one cheap call; the full process list is read again only when it is gone.
    private func tick() {
        if pid > 0 && !Self.isHelper(pid) { pid = 0 }
        if pid == 0 && Date().timeIntervalSince(lastScan) > 1 {
            lastScan = Date()
            pid = Self.helperPIDs().first ?? 0
        }
        if pid == 0 {
            if Date().timeIntervalSince(lastKick) > 3 {                           // start it now, so the first HUD can't flash
                lastKick = Date()
                DispatchQueue.global().async { run("/bin/launchctl", ["kickstart", "gui/\(getuid())/com.apple.OSDUIHelper"]) }
            }
            return
        }
        if !Self.isStopped(pid) { RecoverySession.shared.noteFrozen(pid); kill(pid, SIGSTOP) }   // noted first
    }

    private static func name(_ pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 64)
        return proc_name(pid, &name, UInt32(name.count)) > 0 ? String(cString: name) : nil
    }

    static func isHelper(_ pid: pid_t) -> Bool { name(pid) == "OSDUIHelper" }

    static func helperPIDs() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)              // how many there are now, with room to grow
        let count = max(Int(bytes) / MemoryLayout<pid_t>.size + 64, 1024)
        var pids = [pid_t](repeating: 0, count: count)
        let n = Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(count * MemoryLayout<pid_t>.size))) / MemoryLayout<pid_t>.size
        return pids.prefix(n).filter { $0 > 0 && isHelper($0) }
    }

    static func isStopped(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return r > 0 && info.pbi_status == 4                                     // SSTOP
    }
}

// MARK: - The macOS volume and brightness keys, shown in the island instead of macOS's own HUD

/// Which media keys the tap swallowed: decided once per press, from its first key-down. A press left to macOS (the screen is
/// lowered, no volume control, the island hidden, a modifier combo) goes to macOS whole: its auto-repeats and its release too,
/// even if Cocaine could handle the key by then. A swallowed press keeps its repeats and release swallowed. Otherwise macOS sees a
/// key that is pressed forever and repeats it (brightness running up or down on its own).
struct MediaKeyTracker {
    private var swallowed = Set<Int>()
    private var passed = Set<Int>()

    /// A key-down; `isRepeat` from the event's repeat bit. `handle` (which acts on the key) is called for a fresh press and for
    /// the repeats of a swallowed one, never for the repeats of a passed one. True = swallow the event.
    mutating func down(_ key: Int, isRepeat: Bool, handle: () -> Bool) -> Bool {
        if isRepeat && swallowed.contains(key) { _ = handle(); return true }
        if isRepeat && passed.contains(key) { return false }
        swallowed.remove(key); passed.remove(key)
        if handle() { swallowed.insert(key); return true }
        passed.insert(key)
        return false
    }
    /// A fresh press already decided.
    mutating func down(_ key: Int, handled: Bool) -> Bool { down(key, isRepeat: false) { handled } }
    /// The release: swallowed only if that key's press was.
    mutating func up(_ key: Int) -> Bool {
        passed.remove(key)
        return swallowed.remove(key) != nil
    }
}

final class MediaKeys {
    var onStep: ((Int, Bool) -> Bool)?             // key code, fine step (⌥⇧): return true when it was handled
    var onKey: ((Int) -> Void)?                    // every press of one of these keys, handled or not
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tracker = MediaKeyTracker()

    /// NX_KEYTYPE_*: 0 volume up, 1 volume down, 2 brightness up, 3 brightness down, 7 mute. Bit 0 of the flags: an auto-repeat.
    static func decode(data1: Int) -> (key: Int, down: Bool, isRepeat: Bool)? {
        let key = (data1 & 0xFFFF0000) >> 16, flags = data1 & 0x0000FFFF
        guard [0, 1, 2, 3, 7].contains(key) else { return nil }
        return (key, ((flags & 0xFF00) >> 8) == 0xA, flags & 0x1 != 0)
    }

    /// No modifier: a normal step. ⌥⇧: a fine step. Anything else is macOS's (⌥ alone opens Sound or Displays settings, ⌃ and
    /// ⌘ combos belong to other apps): passed through untouched.
    static func route(_ mods: NSEvent.ModifierFlags) -> (pass: Bool, fine: Bool) {
        let m = mods.intersection([.shift, .control, .option, .command])
        if m.isEmpty { return (false, false) }
        if m == [.option, .shift] { return (false, true) }
        return (true, false)
    }

    var running: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil, AXIsProcessTrusted() else { return tap != nil }
        let mask: CGEventMask = 1 << 14                                    // NX_SYSDEFINED
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MediaKeys>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // A timeout: on again. Taken away with the permission: healthCheck() drops it, a new grant makes a new one.
                if let t = me.tap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8, let k = MediaKeys.decode(data1: ns.data1) else { return Unmanaged.passUnretained(event) }
            if !k.down { return me.tracker.up(k.key) ? nil : Unmanaged.passUnretained(event) }   // swallow the release only of a key we swallowed
            if !k.isRepeat { me.onKey?(k.key) }
            let r = MediaKeys.route(ns.modifierFlags)
            let swallow = me.tracker.down(k.key, isRepeat: k.isRepeat) { !r.pass && (me.onStep?(k.key, r.fine) ?? false) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
        tracker = MediaKeyTracker()
    }

    /// Accessibility taken away (the tap stops receiving, but still exists): drop it, so the next grant creates a working one.
    func healthCheck() {
        guard let t = tap else { return }
        if !AXIsProcessTrusted() || !CFMachPortIsValid(t) { log.notice("media-key tap lost its permission: dropped"); stop() }
        else if !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
    }

    // MARK: acting on the keys

    private static func outputDevice() -> AudioDeviceID? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var d = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &d) == noErr && d != 0 ? d : nil
    }

    /// Volume up/down/mute. Returns the new level and whether it's muted, or nil when this output has no volume control.
    static func changeVolume(key: Int, fine: Bool) -> (level: Float, muted: Bool)? {
        guard let dev = outputDevice() else { return nil }
        var va = AudioObjectPropertyAddress(mSelector: 0x766D_7663, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var ma = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &va, 0, nil, &size, &v) == noErr else { return nil }
        var mute: UInt32 = 0, msize = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectGetPropertyData(dev, &ma, 0, nil, &msize, &mute) == noErr
        let step: Float32 = fine ? 1.0 / 64 : 1.0 / 16
        if key == 7 {
            guard hasMute else { return nil }
            mute = mute == 0 ? 1 : 0
            AudioObjectSetPropertyData(dev, &ma, 0, nil, msize, &mute)
            return (v, mute != 0)
        }
        v = min(1, max(0, v + (key == 0 ? step : -step)))
        AudioObjectSetPropertyData(dev, &va, 0, nil, size, &v)
        if hasMute && mute != 0 && key == 0 { mute = 0; AudioObjectSetPropertyData(dev, &ma, 0, nil, msize, &mute) }
        return (v, mute != 0 && key != 0)
    }
}
