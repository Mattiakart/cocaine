// The volume and brightness HUD: HUDWatch, the frozen system HUD (SystemHUD) and the media keys.

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

/// Volume and brightness changes (the keys, the menu bar, Control Center) as a message in the island, the instant they happen:
/// CoreAudio tells us about the volume itself; the brightness is read forty times a second (a few microseconds each).
final class HUDWatch {
    var onChange: ((String, String, Double) -> Void)?
    var suppressBrightness: () -> Bool = { false }
    private var timer: Timer?
    private var started = false
    private var lastVolume: Float?, lastMute: Bool?, lastBrightness: Float?
    private let screens = Screens()
    private var device = AudioDeviceID(0)
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private static let volumeSelector: AudioObjectPropertySelector = 0x766D_7663       // 'vmvc': the virtual main volume

    func start() {
        guard !started else { return }
        started = true
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.bind() }
        systemListener = l
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, l)
        bind()
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in self?.pollBrightness() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.invalidate(); timer = nil
        if let l = systemListener {
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, l)
        }
        systemListener = nil
        unbind()
        lastVolume = nil; lastMute = nil; lastBrightness = nil
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
            onChange?(icon, L("Volume"), muted ? 0 : Double(v))
        }
        lastVolume = v; lastMute = muted
    }

    private func pollBrightness() {
        guard let id = screens.online.first(where: { CGDisplayIsBuiltin($0) != 0 }), let b = screens.brightness(id) else { return }
        if let l = lastBrightness, abs(l - b) > 0.002, !suppressBrightness() { onChange?("sun.max.fill", L("Brightness"), Double(b)) }
        lastBrightness = b
    }
}

/// macOS draws its volume and brightness HUD in a helper process, OSDUIHelper. While *Replace system HUD* is on, that helper is
/// kept started but frozen, so it never draws anything; when the option is turned off (or Cocaine quits) the helper is simply ended
/// and macOS starts a fresh one the next time it needs it. If Cocaine dies, its watchdog ends the frozen helper (Sources/Recovery.swift).
final class SystemHUD {
    private var timer: Timer?
    private var lastKick = Date.distantPast
    private(set) var active = false

    func enable() {
        guard !active else { return }
        active = true
        RecoverySession.shared.noteHUD(true)                                      // noted before the first freeze
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func disable() {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        for pid in Self.helperPIDs() { kill(pid, SIGKILL) }
        RecoverySession.shared.noteHUD(false)
    }

    /// After a crash the helper could be left frozen: end any frozen one at launch.
    static func cleanup() { for pid in helperPIDs() where isStopped(pid) { kill(pid, SIGKILL) } }

    private func tick() {
        let pids = Self.helperPIDs()
        if pids.isEmpty {
            if Date().timeIntervalSince(lastKick) > 3 {                           // start it now, so the first HUD can't flash
                lastKick = Date()
                DispatchQueue.global().async { run("/bin/launchctl", ["kickstart", "gui/\(getuid())/com.apple.OSDUIHelper"]) }
            }
            return
        }
        for pid in pids where !Self.isStopped(pid) { RecoverySession.shared.noteFrozen(pid); kill(pid, SIGSTOP) }   // noted first
    }

    static func helperPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 2048)
        let n = Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))) / MemoryLayout<pid_t>.size
        var found: [pid_t] = []
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(n) where pid > 0 {
            if proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "OSDUIHelper" { found.append(pid) }
        }
        return found
    }

    static func isStopped(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return r > 0 && info.pbi_status == 4                                     // SSTOP
    }
}

// MARK: - The macOS volume and brightness keys, shown in the island instead of macOS's own HUD

/// Intercepts the volume, mute and brightness keys (needs Accessibility), applies them itself and shows the island's bar.
/// Which media keys the tap swallowed on the way down: only their release may be swallowed too. A key left to macOS (the screen is
/// dimmed, no built-in display, no volume control) must reach macOS whole, release included; otherwise macOS sees a key that is
/// pressed forever and repeats it (brightness running up on its own).
struct MediaKeyTracker {
    private var swallowed = Set<Int>()
    /// A press (or auto-repeat): true when it is swallowed.
    mutating func down(_ key: Int, handled: Bool) -> Bool {
        if handled { swallowed.insert(key) } else { swallowed.remove(key) }
        return handled
    }
    /// The release: swallowed only if that key's press was.
    mutating func up(_ key: Int) -> Bool { swallowed.remove(key) != nil }
}

final class MediaKeys {
    var onStep: ((Int, Bool) -> Bool)?             // key code, fine step (⌥⇧): return true when it was handled
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tracker = MediaKeyTracker()

    /// NX_KEYTYPE_*: 0 volume up, 1 volume down, 2 brightness up, 3 brightness down, 7 mute.
    static func decode(data1: Int) -> (key: Int, down: Bool)? {
        let key = (data1 & 0xFFFF0000) >> 16, flags = data1 & 0x0000FFFF
        guard [0, 1, 2, 3, 7].contains(key) else { return nil }
        return (key, ((flags & 0xFF00) >> 8) == 0xA)
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
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }; return Unmanaged.passUnretained(event) }
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8, let k = MediaKeys.decode(data1: ns.data1) else { return Unmanaged.passUnretained(event) }
            if !k.down { return me.tracker.up(k.key) ? nil : Unmanaged.passUnretained(event) }   // swallow the release only of a key we swallowed
            let fine = ns.modifierFlags.contains([.option, .shift])
            return me.tracker.down(k.key, handled: me.onStep?(k.key, fine) ?? false) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
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
