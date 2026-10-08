// The island's sizes as the user sets them (Settings → Island → Notch): the open island (presets and sliders, never smaller
// than the standard 640 × 214 every page was laid out for, so nothing gets cut), its bottom corners open, and the closed bar on
// screens without a notch (width, height, corners; for all of them or one screen at a time). On a screen with a notch the
// closed island is the notch itself: its size is the hardware's. Pure rules here; NotchPrefs keeps them and the other notch
// settings and tells the island when they change.

import AppKit
import Combine
import SwiftUI

struct NotchSizing: Codable, Equatable {
    /// The closed bar on a screen without a notch. `height` nil: as tall as that screen's menu bar.
    struct Pill: Codable, Equatable {
        var width: CGFloat = 150
        var height: CGFloat? = nil
    }
    enum Preset: String, CaseIterable { case standard, large, extraLarge, custom }

    var openWidth: CGFloat = 640
    var openHeight: CGFloat = 214
    /// The open island's bottom corners (their span, as IslandLayout draws them).
    var openCorner: CGFloat = 32
    /// The closed bar's bottom corners on screens without a notch.
    var pillCorner: CGFloat = 13.5
    var pill = Pill()
    /// One screen's own closed bar (by NotchSizing.displayKey), over `pill`.
    var perScreen: [String: Pill] = [:]

    static let openWidths: ClosedRange<CGFloat> = 640...800
    static let openHeights: ClosedRange<CGFloat> = 214...300
    static let openCorners: ClosedRange<CGFloat> = 16...40
    static let pillCorners: ClosedRange<CGFloat> = 4...16
    static let pillWidths: ClosedRange<CGFloat> = 110...260
    static let pillHeights: ClosedRange<CGFloat> = 22...40

    static func presetSize(_ p: Preset) -> CGSize? {
        switch p {
        case .standard: return CGSize(width: 640, height: 214)
        case .large: return CGSize(width: 700, height: 244)
        case .extraLarge: return CGSize(width: 760, height: 274)
        case .custom: return nil
        }
    }
    var preset: Preset {
        Preset.allCases.first { Self.presetSize($0) == CGSize(width: openWidth, height: openHeight) } ?? .custom
    }
    mutating func apply(_ p: Preset) { if let s = Self.presetSize(p) { openWidth = s.width; openHeight = s.height } }

    static func clamp(_ v: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat { v.isFinite ? min(r.upperBound, max(r.lowerBound, v.rounded())) : r.lowerBound }
    static func clampPill(_ p: Pill) -> Pill { Pill(width: clamp(p.width, pillWidths), height: p.height.map { clamp($0, pillHeights) }) }

    /// Every value in its range (a value from a newer Cocaine, or edited by hand, can't break the island).
    func sanitized() -> NotchSizing {
        var s = self
        s.openWidth = Self.clamp(openWidth, Self.openWidths)
        s.openHeight = Self.clamp(openHeight, Self.openHeights)
        s.openCorner = Self.clamp(openCorner, Self.openCorners)
        s.pillCorner = min(Self.pillCorners.upperBound, max(Self.pillCorners.lowerBound, pillCorner.isFinite ? pillCorner : 13.5))
        s.pill = Self.clampPill(pill)
        s.perScreen = perScreen.filter { !$0.key.isEmpty }.mapValues(Self.clampPill)
        return s
    }

    /// The closed bar of a screen (its own, else everyone's).
    func pill(for key: String) -> Pill { perScreen[key] ?? pill }

    /// A display's lasting name for its settings: vendor, model and serial (the display id changes between plugs).
    static func displayKey(_ id: CGDirectDisplayID) -> String {
        id == 0 ? "" : "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    /// The closed island on a screen without a notch: `bar` its menu bar's height (0 when hidden), `fallback` the system's.
    static func closedPill(_ p: Pill, bar: CGFloat, fallback: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let hidden = bar < 1
        let auto = hidden ? max(22, fallback) : min(max(bar, 22), 44)
        return (p.width, p.height ?? auto)
    }
}

/// The notch's settings, kept in AppDefaults.store and shared by every island and the settings card.
final class NotchPrefs: ObservableObject {
    static let shared = NotchPrefs()
    @Published private(set) var sizing: NotchSizing
    @Published private(set) var gestures: NotchGestureSettings
    @Published private(set) var controls: NotchControlsConfig
    /// The last sizing read (Island.openSize reads it on every layout; never the defaults themselves).
    static var current: NotchSizing { shared.sizing }
    private let defaults: () -> UserDefaults

    static let sizingKey = "notch.sizing"
    static let controlsKey = "notch.controls"

    init(defaults: @escaping () -> UserDefaults = { AppDefaults.store }) {
        self.defaults = defaults
        let d = defaults()
        sizing = (d.data(forKey: Self.sizingKey).flatMap { try? JSONDecoder().decode(NotchSizing.self, from: $0) } ?? NotchSizing()).sanitized()
        gestures = NotchGestureSettings.load(d)
        controls = (d.data(forKey: Self.controlsKey).flatMap { try? JSONDecoder().decode(NotchControlsConfig.self, from: $0) } ?? NotchControlsConfig()).sanitized()
    }

    func updateSizing(_ change: (inout NotchSizing) -> Void) {
        var s = sizing
        change(&s)
        s = s.sanitized()
        guard s != sizing else { return }
        sizing = s
        save(s == NotchSizing() ? nil : s, Self.sizingKey)
    }

    func updateGestures(_ change: (inout NotchGestureSettings) -> Void) {
        var g = gestures
        change(&g)
        guard g != gestures else { return }
        gestures = g
        g.save(defaults())
    }

    func updateControls(_ change: (inout NotchControlsConfig) -> Void) {
        var c = controls
        change(&c)
        c = c.sanitized()
        guard c != controls else { return }
        controls = c
        save(c == NotchControlsConfig() ? nil : c, Self.controlsKey)
    }

    private func save<T: Encodable>(_ v: T?, _ key: String) {
        if let v, let data = try? JSONEncoder().encode(v) { defaults().set(data, forKey: key) } else { defaults().removeObject(forKey: key) }
    }
}
