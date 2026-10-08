// The keyboard backlight on Macs that have one: its level read and set through macOS's private CoreBrightness framework
// (KeyboardBrightnessClient, loaded at run time and asked method by method, so a Mac or a macOS without it just shows nothing),
// a row on the island's Monitors page (a switch and a slider), the HUD under the notch when Cocaine changes it, and an optional
// auto-off when the Mac is idle (optionally only while Cocaine keeps it awake), restored at the next input or when Cocaine quits.
// Under test and render flags the device is a fake: the real backlight is never written by a test. --media-test runs the rules.

import AppKit
import Foundation
import SwiftUI

/// What Cocaine needs from a keyboard backlight.
protocol BacklightDevice: AnyObject {
    var available: Bool { get }
    /// 0…1, nil when it can't be read.
    func level() -> Double?
    @discardableResult func set(_ level: Double) -> Bool
    /// macOS turned it off by itself (bright light around, the lid closed).
    var suppressed: Bool { get }
}

/// The real one: CoreBrightness's KeyboardBrightnessClient, every method checked before it is called (private API: it can
/// change or go away with any macOS update; then `available` is false and the feature hides).
final class CoreBrightnessBacklight: BacklightDevice {
    private let client: NSObject?
    private let keyboard: UInt64

    private typealias GetFloat = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias GetBool = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias SetFloat = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    init() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { client = nil; keyboard = 0; return }
        let c = cls.init()
        let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard c.responds(to: idsSel), let ids = c.perform(idsSel)?.takeRetainedValue() as? [NSNumber], !ids.isEmpty else { client = nil; keyboard = 0; return }
        client = c
        let builtIn = Self.imp(c, "isKeyboardBuiltIn:", GetBool.self)
        keyboard = ids.map(\.uint64Value).first { id in builtIn.map { $0(c, NSSelectorFromString("isKeyboardBuiltIn:"), id) } ?? false } ?? ids[0].uint64Value
    }

    private static func imp<T>(_ o: NSObject, _ name: String, _ type: T.Type) -> T? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel), let m = class_getInstanceMethod(Swift.type(of: o), sel) else { return nil }
        return unsafeBitCast(method_getImplementation(m), to: type)
    }

    var available: Bool {
        guard let c = client else { return false }
        return Self.imp(c, "brightnessForKeyboard:", GetFloat.self) != nil && Self.imp(c, "setBrightness:forKeyboard:", SetFloat.self) != nil
    }

    func level() -> Double? {
        guard let c = client, let f = Self.imp(c, "brightnessForKeyboard:", GetFloat.self) else { return nil }
        let v = Double(f(c, NSSelectorFromString("brightnessForKeyboard:"), keyboard))
        return v.isFinite ? max(0, min(1, v)) : nil
    }

    func set(_ level: Double) -> Bool {
        guard let c = client, let f = Self.imp(c, "setBrightness:forKeyboard:", SetFloat.self) else { return false }
        return f(c, NSSelectorFromString("setBrightness:forKeyboard:"), Float(max(0, min(1, level))), keyboard)
    }

    var suppressed: Bool {
        guard let c = client, let f = Self.imp(c, "isBacklightSuppressedOnKeyboard:", GetBool.self) else { return false }
        return f(c, NSSelectorFromString("isBacklightSuppressedOnKeyboard:"), keyboard)
    }
}

/// Tests and renders: a backlight in memory, every write recorded.
final class FakeBacklight: BacklightDevice {
    var available: Bool
    var value: Double
    var writes: [Double] = []
    var suppressed = false
    init(available: Bool = true, level: Double = 0.5) { self.available = available; value = level }
    func level() -> Double? { available ? value : nil }
    func set(_ level: Double) -> Bool { guard available else { return false }; value = max(0, min(1, level)); writes.append(value); return true }
}

final class KeyboardBacklight: ObservableObject {
    /// The app's: the real backlight, or a fake under test and render flags (AppDefaults.isolated).
    static let shared = KeyboardBacklight(device: AppDefaults.isolated ? FakeBacklight(level: 0.6) : CoreBrightnessBacklight())

    static let idleChoices = [0, 30, 60, 120, 300]      // seconds; 0: never

    let device: BacklightDevice
    @Published private(set) var available: Bool
    @Published private(set) var level: Double
    /// Cocaine turned it off for idleness (and turns it back on at the next input).
    @Published private(set) var dimmed = false
    /// The HUD under the notch (the island sets it).
    var hud: ((Double) -> Void)?
    /// Seconds since the last keyboard, mouse or trackpad input; whether Cocaine keeps the Mac awake (tests hand in their own).
    var idleSeconds: () -> Double = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }
    var keepingAwake: () -> Bool = { System.cocaineOn }
    let defaults: UserDefaults
    private var saved: Double?
    private var lastOn = 0.5
    private var timer: Timer?
    private var quitObserver: NSObjectProtocol?

    init(device: BacklightDevice, defaults: UserDefaults = AppDefaults.store) {
        self.device = device
        self.defaults = defaults
        available = device.available
        level = device.level() ?? 0
        if level > 0.01 { lastOn = level }
    }

    // MARK: settings

    var idleOff: Int { let v = defaults.integer(forKey: "kbIdleOff"); return Self.idleChoices.contains(v) ? v : 0 }
    var onlyWhileAwake: Bool { defaults.bool(forKey: "kbIdleOnlyAwake") }

    func setIdleOff(_ s: Int) { defaults.set(Self.idleChoices.contains(s) ? s : 0, forKey: "kbIdleOff"); objectWillChange.send(); apply() }
    func setOnlyWhileAwake(_ on: Bool) { defaults.set(on, forKey: "kbIdleOnlyAwake"); objectWillChange.send(); apply() }

    var suppressed: Bool { available && device.suppressed }

    // MARK: the level

    func refresh() {
        let a = device.available
        if available != a { available = a }
        if let v = device.level(), abs(v - level) > 0.001 { level = v; if v > 0.01 { lastOn = v } }
    }

    /// The user set it (the island's slider or switch, Settings): the HUD shows it; an auto-off in progress is forgotten.
    func set(_ v: Double, showHUD: Bool = true) {
        let v = max(0, min(1, v))
        guard available, device.set(v) else { return }
        saved = nil; if dimmed { dimmed = false }
        level = v
        if v > 0.01 { lastOn = v }
        if showHUD { hud?(v) }
    }

    func toggle() { set(level > 0.01 ? 0 : lastOn) }

    // MARK: auto-off

    enum Step: Equatable { case none, dim, restore }

    /// Off after `idleOff` seconds without input (if asked only while Cocaine keeps the Mac awake: only then); back on at the
    /// next input, or as soon as the rule no longer applies.
    static func decide(idle: Double, idleOff: Int, onlyWhileAwake: Bool, awake: Bool, dimmed: Bool) -> Step {
        let wantOff = idleOff > 0 && idle >= Double(idleOff) && (!onlyWhileAwake || awake)
        if wantOff && !dimmed { return .dim }
        if !wantOff && dimmed { return .restore }
        return .none
    }

    func tick() {
        switch Self.decide(idle: idleSeconds(), idleOff: idleOff, onlyWhileAwake: onlyWhileAwake, awake: keepingAwake(), dimmed: dimmed) {
        case .none: break
        case .dim:
            let cur = device.level() ?? level
            guard cur > 0.01 else { return }                       // already off (by the user, or macOS): nothing to bring back
            saved = cur
            if device.set(0) { dimmed = true; level = 0 } else { saved = nil }
        case .restore:
            restore()
        }
        reschedule()
    }

    /// Brings back what auto-off turned off, unless the user set another level meanwhile.
    func restore() {
        guard dimmed else { return }
        dimmed = false
        if let s = saved, (device.level() ?? 0) < 0.01, device.set(s) { level = s }
        saved = nil
    }

    /// Starts or stops the idle check (every 2 s; every 0.5 s while dimmed, so the light comes back quickly).
    func apply() {
        if quitObserver == nil {
            quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.restore()                                     // never leave the keyboard dark after Cocaine quits
            }
        }
        if idleOff == 0 { restore() }
        reschedule()
    }

    private func reschedule() {
        let want = available && idleOff > 0
        let interval: TimeInterval = dimmed ? 0.5 : 2
        if !want { timer?.invalidate(); timer = nil; return }
        if let t = timer, abs(t.timeInterval - interval) < 0.01 { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval / 4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

// MARK: - The island's row (Monitors page)

/// The keyboard backlight on the island: a switch and a slider (only on a Mac that has one).
struct KeyboardBacklightRow: View {
    @ObservedObject var light = KeyboardBacklight.shared
    var body: some View {
        if light.available {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Keyboard")).font(UI.itemTitle).lineLimit(1)
                    if light.suppressed { Text(L("Turned off by macOS")).font(UI.detail).foregroundStyle(UI.hint).lineLimit(1) }
                    else if light.dimmed { Text(L("Off while you're away")).font(UI.detail).foregroundStyle(UI.hint).lineLimit(1) }
                }
                .frame(width: 130, alignment: .leading)
                CocaineSwitch(on: light.level > 0.01) { light.toggle() }.accessibilityLabel(L("Keyboard backlight"))
                HStack(spacing: Space.s) {
                    Image(systemName: "light.min").font(.system(size: 11)).foregroundStyle(UI.secondary).frame(width: 14)   // a glyph
                    CocaineSlider(value: light.level * 100, range: 0...100, step: 10, name: L("Keyboard backlight"),
                                  valueText: "\(Int((light.level * 100).rounded()))%") { light.set($0 / 100) }
                        .frame(width: 160)
                    Image(systemName: "light.max").font(.system(size: 11)).foregroundStyle(UI.secondary).frame(width: 14)   // a glyph
                }
                Spacer(minLength: 0)
            }
            .onAppear { light.refresh() }
        }
    }
}
