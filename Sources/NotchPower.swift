// The charger and the battery in the notch: plugging in or out, charging, fully charged, low battery and Low Power Mode, shown
// as a HUD below the notch (the island's HUDTimeline) with a battery glyph whose fill runs to the level, a bolt that pops in
// and a percentage that rolls. ChargeEvents is the pure part (readings in, at most one event out, no repeats, no wiggles);
// NotchPowerWatch reads the power sources (IOKit's notification the moment they change, and the app's 2 s poll as a backup)
// and posts the HUD; ChargeGlyphView draws it. docs/notch-animations.en.md.

import AppKit
import IOKit.ps
import SwiftUI

/// One reading of the Mac's own battery and its charger.
struct PowerReading: Equatable {
    var percent: Int
    var onAC: Bool
    var charging = false
    var charged = false              // the battery says it is full (or held full on the charger)
    var lowPower = false             // Low Power Mode
    var minutesToFull: Int? = nil    // nil: not known yet (macOS works it out after a minute or so)
    var minutesToEmpty: Int? = nil
}

/// What the HUD shows about the battery: its level, its state (the glyph's colour and badge) and Low Power Mode.
struct ChargeGlyph: Equatable {
    enum State: String, Equatable { case battery, low, plugged, charging, full }
    var percent: Int
    var state: State
    var lowPower = false
    var detail: String? = nil

    /// The glyph for a reading: full on the charger, charging, plugged in but held (macOS's optimised charging), low, or on battery.
    static func of(_ r: PowerReading, low: Int) -> ChargeGlyph {
        let s: State = r.onAC ? (r.charged || r.percent >= 100 ? .full : r.charging ? .charging : .plugged)
                              : (low > 0 && r.percent <= low ? .low : .battery)
        return ChargeGlyph(percent: min(100, max(0, r.percent)), state: s, lowPower: r.lowPower)
    }
    /// The badge beside the battery: a bolt while it charges (or is full on the charger), a plug while held, none on battery.
    var badge: String? {
        switch state {
        case .charging, .full: return "bolt.fill"
        case .plugged: return "powerplug.fill"
        case .battery, .low: return nil
        }
    }
    /// Its fill: green on the charger, red when low, yellow in Low Power Mode, white otherwise (Boring Notch's rule).
    var tint: Color {
        if lowPower && !(state == .charging || state == .full) { return ChargeGlyph.yellow }
        switch state {
        case .charging, .full, .plugged: return ChargeGlyph.green
        case .low: return ChargeGlyph.red
        case .battery: return .white
        }
    }
    static let green = Color(red: 0.30, green: 0.85, blue: 0.42)
    static let red = Color(red: 1.0, green: 0.36, blue: 0.33)
    static let yellow = Color(red: 1.0, green: 0.84, blue: 0.25)
}

enum ChargeEvent: Equatable { case connected, disconnected, full, low(Int), lowPower(Bool) }

/// Readings in, at most one event out. The first reading only sets the baseline (nothing is announced at launch); the charger
/// plugged or unplugged is said every time; "fully charged" once per time on the charger (not again after it dips to 99 %); a low
/// level once per crossing, re-armed only after the level is back 3 points above it or the charger is in; Low Power Mode on/off.
struct ChargeEvents {
    static let critical = 10
    private(set) var last: PowerReading?
    private var fullSaid = false
    private var lowSaid: Set<Int> = []

    /// The levels that say "low battery" for this setting (0: none; 10 is always one of them while any is on).
    static func levels(_ low: Int) -> [Int] { low <= 0 ? [] : Array(Set([low, critical])).sorted() }

    mutating func feed(_ r: PowerReading, low: Int) -> ChargeEvent? {
        defer { last = r }
        let levels = Self.levels(low)
        for t in lowSaid where r.onAC || r.percent > t + 3 { lowSaid.remove(t) }
        guard let prev = last else {
            fullSaid = r.onAC && (r.charged || r.percent >= 100)
            if !r.onAC { lowSaid = Set(levels.filter { r.percent <= $0 }) }
            return nil
        }
        if r.onAC != prev.onAC {
            if r.onAC { fullSaid = r.charged || r.percent >= 100; return .connected }
            fullSaid = false
            lowSaid.formUnion(levels.filter { r.percent <= $0 })    // unplugged when already low: the unplug notice says it
            return .disconnected
        }
        if r.onAC, !fullSaid, r.charged || r.percent >= 100 { fullSaid = true; return .full }
        if !r.onAC, let t = levels.first(where: { r.percent <= $0 && !lowSaid.contains($0) }) {
            lowSaid.formUnion(levels.filter { r.percent <= $0 })    // the lowest crossed is said, the ones above it with it
            return .low(t)
        }
        if r.lowPower != prev.lowPower { return .lowPower(r.lowPower) }
        return nil
    }

    /// The HUD for an event: its title, its detail line and the glyph.
    static func item(_ e: ChargeEvent, _ r: PowerReading, low: Int) -> HUDItem {
        var g = ChargeGlyph.of(r, low: low)
        let title: String
        switch e {
        case .connected:
            title = g.state == .full ? L("Fully charged") : g.state == .plugged ? L("Plugged in") : L("Charging")
            g.detail = g.state == .charging ? r.minutesToFull.map { String(format: L("Full in %@"), Dur.left(seconds: max(1, $0) * 60)) } : nil
        case .disconnected:
            title = L("On battery")
            g.detail = r.minutesToEmpty.map { String(format: L("%@ left"), Dur.left(seconds: max(1, $0) * 60)) }
        case .full: title = L("Fully charged")
        case .low(let t):
            title = L("Low battery")
            g.detail = t <= critical ? L("Charge now") : L("Charge soon")
        case .lowPower(let on): title = on ? L("Low Power Mode on") : L("Low Power Mode off")
        }
        let icon = g.badge ?? (e == .disconnected ? "bolt.slash.fill" : g.state == .low ? "battery.25percent" : "battery.75percent")
        return HUDItem(icon: icon, text: title, level: nil, power: g)
    }
}

extension Settings {
    /// Notch → Charging: the HUD when the charger is plugged in or out, the battery is full, Low Power Mode changes.
    var notchChargeHUD: Bool { get { flag("notch.chargeHUD", true) } nonmutating set { d.set(newValue, forKey: "notch.chargeHUD") } }
    /// Notch → Low battery: the level (%) that says so on battery; 0 = never.
    var notchLowBattery: Int { get { d.object(forKey: "notch.lowBattery") as? Int ?? 20 } nonmutating set { d.set(newValue, forKey: "notch.lowBattery") } }
    static let lowBatteryChoices = [0, 10, 20, 30]
}

/// Reads the power sources and posts the HUD. One per app (the island's model hands it `post`).
final class NotchPowerWatch {
    static let shared = NotchPowerWatch()
    private var events = ChargeEvents()
    private var source: CFRunLoopSource?
    private var lowPowerObserver: NSObjectProtocol?
    /// Where an event goes (the island's HUD); nil while the island is off (the readings still keep the baseline current).
    var post: ((HUDItem) -> Void)?
    /// Tests: a fake reader.
    var read: () -> PowerReading? = { NotchPowerWatch.readSystem() }

    /// Starts listening (idempotent): IOKit calls back the moment a power source changes.
    func start() {
        guard source == nil else { return }
        poll()
        if let s = IOPSNotificationCreateRunLoopSource({ _ in NotchPowerWatch.shared.poll() }, nil)?.takeRetainedValue() {
            source = s
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
        }
        lowPowerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            NotchPowerWatch.shared.poll()
        }
    }

    func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode); source = nil }
        if let o = lowPowerObserver { NotificationCenter.default.removeObserver(o); lowPowerObserver = nil }
    }

    /// A reading now (IOKit's callback, Low Power Mode, and the app's 2 s poll): an event, if any, goes to the HUD.
    func poll() {
        guard let r = read() else { return }
        feed(r)
    }

    func feed(_ r: PowerReading) {
        let s = Settings()
        let low = s.notchLowBattery
        guard let e = events.feed(r, low: low), s.notchChargeHUD, let post else { return }
        post(ChargeEvents.item(e, r, low: low))
    }

    /// The internal battery, as IOKit has it (nil on a Mac without one).
    static func readSystem() -> PowerReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            func minutes(_ k: String) -> Int? { (d[k] as? Int).flatMap { $0 > 0 ? $0 : nil } }
            return PowerReading(percent: cur * 100 / max, onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                                charging: d[kIOPSIsChargingKey] as? Bool ?? false, charged: d[kIOPSIsChargedKey] as? Bool ?? false,
                                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                minutesToFull: minutes(kIOPSTimeToFullChargeKey), minutesToEmpty: minutes(kIOPSTimeToEmptyKey))
        }
        return nil
    }
}

// MARK: - The view

private struct HUDRevealKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    /// How far the HUD has dropped (0 tucked in the notch … 1 down; the spring's overshoot a little past 1), frame by frame: the
    /// battery's fill and the bolt follow it, so they arrive with the container and reverse with it.
    var hudReveal: CGFloat {
        get { self[HUDRevealKey.self] }
        set { self[HUDRevealKey.self] = newValue }
    }
}

/// The battery HUD's content: the badge (bolt or plug) popping in, what happened and the level, the battery glyph filling.
struct ChargeHUDContent: View {
    let item: HUDItem
    let glyph: ChargeGlyph
    let reduce: Bool
    @Environment(\.hudReveal) private var reveal

    var body: some View {
        let pop = reduce ? 1 : Island.mix(0.3, 1, Island.smooth((reveal - 0.35) / 0.65))
        HStack(spacing: Space.m) {
            ZStack {
                if let b = glyph.badge {
                    Image(systemName: b).font(.system(size: 13, weight: .semibold)).foregroundStyle(glyph.tint)
                        .transition(reduce ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                        .id(b)
                } else {
                    Image(systemName: item.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(glyph.state == .low ? ChargeGlyph.red : Island.accent)
                        .transition(.opacity)
                }
            }
            .frame(width: 18)
            .scaleEffect(pop)
            .animation(Motion.animation(.chargeIn, reduce: reduce), value: glyph.badge)
            // The words get the whole column: the title (two lines when there is no detail: "Mode Économie d'énergie activé") and
            // the detail; the level sits under the battery. 2.8.0 put "62% · Carica tra 48 min" on one line and cut it to
            // "Carica tra 4…" under a 185 pt notch, and cut Low Power Mode's title in it/es/fr.
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(glyph.detail == nil ? 2 : 1).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                if let d = glyph.detail {
                    Text(d).font(.system(size: 10)).foregroundStyle(UI.secondary).lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 2) {
                ChargeGlyphView(glyph: glyph, reduce: reduce, reveal: reveal)
                Text("\(glyph.percent)%").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(UI.secondary)
                    .lineLimit(1).fixedSize().motionNumber(glyph.percent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.text + ", \(glyph.percent)%")
    }
}

/// The battery: a thin outline with its nub, and a fill that runs to the level (from empty as the HUD drops; a new level
/// retargets the running spring) in the state's colour, which cross-fades when the state changes.
struct ChargeGlyphView: View {
    let glyph: ChargeGlyph
    var reduce = false
    var reveal: CGFloat = 1
    static let size = CGSize(width: 25, height: 12)

    var body: some View {
        let w = Self.size.width, h = Self.size.height
        let level = CGFloat(glyph.percent) / 100
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5).strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                ChargeFill(fraction: level * (reduce ? 1 : Island.clamp(reveal)))
                    .fill(glyph.tint)
                    .padding(2)
                    .animation(Motion.animation(.levelFill, reduce: reduce), value: glyph.percent)
                    .animation(Motion.animation(.crossfade, reduce: reduce), value: glyph.state)
            }
            .frame(width: w, height: h)
            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.5)).frame(width: 1.5, height: 4)
        }
        .motionPulse(glyph.state == .low ? 1 : 0)                 // turning low while shown: one beat
        .accessibilityHidden(true)
    }
}

/// The fill's width as an animatable fraction (a bar never under 2 pt while there is any charge, so 1 % still shows).
struct ChargeFill: Shape {
    var fraction: CGFloat
    var animatableData: CGFloat { get { fraction } set { fraction = newValue } }
    func path(in rect: CGRect) -> Path {
        let f = Island.clamp(fraction)
        guard f > 0 else { return Path() }
        let w = max(2, rect.width * f)
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), cornerRadius: 1.5)
    }
}
