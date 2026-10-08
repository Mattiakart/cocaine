// Two-finger swipes on the notch: up on the open island closes it (it stays closed until the pointer leaves), down on the
// closed notch opens it, sideways on the open island moves between its screens. The island still opens the moment the pointer
// touches the notch; swipes are for the moments hover doesn't cover (closing without moving away, opening again in place,
// changing screens without aiming at a tab). NotchSwipe is the pure part (events in, one action per gesture, the live
// feedback); NotchGestureMonitor reads the trackpad's scroll events. Pinch is left out on purpose: macOS gives a magnify event
// only to the window under the pointer (never to a closed island, which lets the pointer through), and no island action maps
// onto it. A mouse wheel is ignored: these are trackpad gestures, and a wheel over the notch should scroll what is under it.

import AppKit
import SwiftUI

/// The gestures' settings (Settings → Island → Notch).
struct NotchGestureSettings: Codable, Equatable {
    enum Sensitivity: String, Codable, CaseIterable { case low, medium, high }
    var enabled = true
    var swipeClose = true
    var swipeOpen = true
    var swipeScreens = true
    var sensitivity = Sensitivity.medium

    /// How far the fingers travel (in scroll points) before a swipe acts.
    static func threshold(_ s: Sensitivity) -> CGFloat {
        switch s { case .low: return 90; case .medium: return 55; case .high: return 30 }
    }
    var threshold: CGFloat { Self.threshold(sensitivity) }

    static let key = "notch.gestures"
    static func load(_ d: UserDefaults = AppDefaults.store) -> NotchGestureSettings {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(NotchGestureSettings.self, from: $0) } ?? NotchGestureSettings()
    }
    func save(_ d: UserDefaults = AppDefaults.store) {
        if self == NotchGestureSettings() { d.removeObject(forKey: Self.key) } else if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}

/// One gesture at a time, from its first scroll event to its last. Pure.
struct NotchSwipe {
    enum Phase { case began, changed, ended, other }
    enum Action: Equatable { case none, open, close, screen(Int) }
    enum Axis { case undecided, vertical, horizontal }

    /// A scroll event in the finger's terms: dx > 0 the fingers moved right, dy > 0 they moved down.
    struct Event {
        var dx: CGFloat
        var dy: CGFloat
        var phase: Phase
        var momentum = false
        var precise = true
    }

    /// Below this the fingers are resting, not swiping; an axis wins when it is this many times the other.
    static let noise: CGFloat = 4
    static let dominance: CGFloat = 1.5

    private(set) var axis = Axis.undecided
    private(set) var acc = CGPoint.zero
    private(set) var fired = false
    private(set) var active = false
    /// The live feedback, -1…1: negative while the open island is pushed up (closing), positive while the closed notch is pulled
    /// down (opening). Back to 0 when the gesture ends or acts.
    private(set) var progress: CGFloat = 0

    /// `open`: the island under the fingers is open. `owned`: the gesture started where a swipe may act (not over a list or a
    /// control that scrolls itself). Returns what to do (at most one action per gesture).
    mutating func feed(_ e: Event, open: Bool, owned: Bool, settings s: NotchGestureSettings) -> Action {
        guard s.enabled, e.precise, !e.momentum else { return .none }
        if e.phase == .began { self = NotchSwipe(); active = owned }
        guard active else { return .none }
        if e.phase == .ended || e.phase == .other && e.dx == 0 && e.dy == 0 { self = NotchSwipe(); return .none }
        acc.x += e.dx; acc.y += e.dy
        if axis == .undecided {
            let ax = abs(acc.x), ay = abs(acc.y)
            if max(ax, ay) < Self.noise { return .none }
            if ay >= ax * Self.dominance { axis = .vertical } else if ax >= ay * Self.dominance { axis = .horizontal } else { return .none }
        }
        guard !fired else { return .none }
        let t = s.threshold
        switch axis {
        case .vertical:
            if open && s.swipeClose && acc.y < 0 {
                progress = -Island.clamp(-acc.y / t)
                if -acc.y >= t { fired = true; progress = 0; return .close }
            } else if !open && s.swipeOpen && acc.y > 0 {
                progress = Island.clamp(acc.y / t)
                if acc.y >= t { fired = true; progress = 0; return .open }
            } else {
                progress = 0
            }
        case .horizontal:
            guard open && s.swipeScreens else { return .none }
            // Like the trackpad's page swipe: the fingers moving left bring the next screen.
            if abs(acc.x) >= t { fired = true; return .screen(acc.x < 0 ? 1 : -1) }
        case .undecided: break
        }
        return .none
    }

    /// An NSEvent in the finger's terms (natural scrolling or not).
    static func event(_ e: NSEvent) -> Event {
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        let phase: Phase = e.phase.contains(.began) || e.phase.contains(.mayBegin) ? .began
            : e.phase.contains(.ended) || e.phase.contains(.cancelled) ? .ended : e.phase.contains(.changed) ? .changed : .other
        return Event(dx: e.scrollingDeltaX * sign, dy: e.scrollingDeltaY * sign, phase: phase, momentum: !e.momentumPhase.isEmpty,
                     precise: e.hasPreciseScrollingDeltas)
    }
}

/// What the controller tells the monitor about the island under the pointer.
struct NotchGestureTarget {
    var display: CGDirectDisplayID
    var open: Bool
    var window: NSWindow?
}

/// Reads the trackpad's scroll events over the islands and acts on them through the controller's hands.
final class NotchGestureMonitor {
    var settings = NotchGestureSettings.load()
    private var swipe = NotchSwipe()
    private var owner: CGDirectDisplayID?
    private var monitors: [Any] = []
    var target: (CGPoint) -> NotchGestureTarget? = { _ in nil }
    var blocked: () -> Bool = { false }
    var open: (CGDirectDisplayID) -> Void = { _ in }
    var close: () -> Void = {}
    var screen: (Int) -> Void = { _ in }
    var feedback: (CGFloat) -> Void = { _ in }

    func start() {
        guard monitors.isEmpty else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in self?.handle(e) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in self?.handle(e); return e }) { monitors.append(l) }
    }

    func stop() { monitors.forEach(NSEvent.removeMonitor); monitors.removeAll() }

    private func handle(_ e: NSEvent) {
        let ev = NotchSwipe.event(e)
        if ev.phase == .began {
            let t = target(NSEvent.mouseLocation)
            owner = t?.display
            let owned = t.map { !blocked() && !Self.scrollsItself(e, in: $0) } ?? false
            _ = swipe.feed(ev, open: t?.open ?? false, owned: owned, settings: settings)
            return
        }
        guard let id = owner else { return }
        let isOpen = target(NSEvent.mouseLocation).map { $0.display == id && $0.open } ?? false
        let before = swipe.progress
        let action = swipe.feed(ev, open: isOpen, owned: true, settings: settings)
        if swipe.progress != before { feedback(swipe.progress) }
        switch action {
        case .none: break
        case .open: Haptic.tap(.alignment); open(id)
        case .close: Haptic.tap(.alignment); close()
        case .screen(let n): screen(n)                      // the island's own step: its haptic and VoiceOver
        }
        if ev.phase == .ended { owner = nil; feedback(0) }
    }

    /// Over something in the open island that scrolls (a list taller than its box, a horizontal row, a stepper that takes
    /// two-finger steps): the gesture is that control's, never the island's.
    private static func scrollsItself(_ e: NSEvent, in t: NotchGestureTarget) -> Bool {
        guard t.open, let w = t.window, e.window === w, let root = w.contentView else { return false }
        // Every view under the point, not just the hit one: SwiftUI's steppers are background views, its lists NSScrollViews.
        func search(_ v: NSView) -> Bool {
            for sub in v.subviews where !sub.isHidden {
                let p = sub.convert(e.locationInWindow, from: nil)
                guard sub.bounds.contains(p) else { continue }
                if sub is ScrollSteps.Catcher { return true }
                if let s = sub as? NSScrollView, let doc = s.documentView {
                    let clip = s.contentView.bounds.size, size = doc.frame.size
                    if size.height > clip.height + 1 || size.width > clip.width + 1 { return true }
                }
                if search(sub) { return true }
            }
            return false
        }
        return search(root)
    }
}

/// The live feedback of a swipe on the island: -1…0 pushed up (it shrinks toward the notch a little), 0…1 pulled down (the closed
/// notch grows a little), from the top edge so it never leaves the screen's edge. Springs back with the follow spring.
struct GestureFollow: ViewModifier {
    let progress: CGFloat
    static func scale(_ p: CGFloat) -> CGFloat { 1 + (p < 0 ? 0.06 : 0.1) * max(-1, min(1, p)) }
    func body(content: Content) -> some View {
        content.scaleEffect(Self.scale(progress), anchor: .top).animation(Motion.animation(.gestureFollow), value: progress)
    }
}
