// The app's one motion system: a small set of tokens (durations, springs, stagger, distances), the role each kind of change
// plays (press, selection, page, island open…) mapped to one of them, and the view helpers built on them (.pressable,
// .motionAppear, .motionSelection, .motionNumber, .shimmer, .motionPulse, .motionLift, the direction-aware page slide, the
// busy dots). Rules (docs/motion.en.md):
//   - The model is the only truth; an animation is derived from a change of it (withAnimation / .animation(_, value:)), never
//     a fire-and-forget timer. A new change retargets a running spring (SwiftUI keeps its velocity): no restarts.
//   - Delayed work that a later change can supersede carries a generation (MotionGeneration): only the latest runs.
//   - Reduce Motion: nothing moves or scales; changes cross-fade (opacity only) or happen at once. Reduce Transparency: the
//     dims are more opaque (DialogHost). Motion.disabled (renders, snapshot tests): every animation is nil, every loop still.

import AppKit
import SwiftUI

enum Motion {
    // MARK: switches

    /// Renders and snapshot tests: every animation of the system is nil (the new state is drawn at once) and the loading loops
    /// hold still, so a picture never catches a transition half-way.
    static var disabled = false
    /// Tests: Reduce Motion on or off whatever the Mac says.
    static var reduceOverride: Bool?
    /// The system's Reduce Motion setting.
    static var reduce: Bool { reduceOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The system's Reduce Transparency setting (dims get more opaque).
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    /// The render aid (--render-motion): draw this moment (0 = start, 1 = end) of the transitions that read it (the HUD's drop).
    static var frame: CGFloat?

    // MARK: tokens

    /// Durations of the eased (non-spring) curves, in seconds.
    enum Duration {
        static let instant = 0.08          // press feedback, a symbol swap under Reduce Motion
        static let quick = 0.15            // hover, cross-fades under Reduce Motion, a label swap
        static let standard = 0.22         // a content cross-fade
        static let slow = 0.4              // a full-screen overlay fading away
        static let all = [instant, quick, standard, slow]
    }

    /// A spring: `response` is roughly how long it takes (s), `damping` 1 = no overshoot.
    struct Spring: Equatable {
        let response: Double
        let damping: Double
        var animation: Animation { .spring(response: response, dampingFraction: damping) }
        /// About when it is within 0.1 % of its target (for work that waits for the motion to end).
        var settle: Double { damping >= 1 ? response * 1.2 : Foundation.log(1000.0) / (damping * 2 * .pi / response) }
    }
    /// Small things that follow a finger or a click: a press, a selection, a value.
    static let snappy = Spring(response: 0.24, damping: 0.86)
    /// Things that change place or size: pages, expanding rows, the island closing, a dropdown.
    static let smooth = Spring(response: 0.32, damping: 0.88)
    /// Things that arrive: dialogs, notices, cards.
    static let gentle = Spring(response: 0.42, damping: 0.92)
    /// Things that come out of the notch, and the switch's knob: a touch of give at the end.
    static let bouncy = Spring(response: 0.36, damping: 0.8)
    static let springs = [snappy, smooth, gentle, bouncy]

    /// Items that arrive together come one after another, this far apart (and never more than `maxStagger` in all).
    static let stagger = 0.035
    static let maxStagger = 0.2
    static func stagger(_ index: Int) -> Double { min(maxStagger, Double(max(0, index)) * stagger) }

    /// How far and how much things move.
    enum Distance {
        static let pressScale: CGFloat = 0.97          // a pressed button
        static let pressScaleSmall: CGFloat = 0.92     // a pressed glyph, the switch
        static let pressOpacity: Double = 0.75         // a pressed control under Reduce Motion (it doesn't shrink)
        static let enter: CGFloat = 8                  // a card or row arriving from its edge
        static let enterScale: CGFloat = 0.97          // …and growing to its size
        static let page: CGFloat = 16                  // a page sliding in from the side of the tab it came from
        static let liftScale: CGFloat = 1.02           // a row picked up to be dragged
        static let liftShadow: CGFloat = 8
        static let pulseScale: CGFloat = 1.12          // a count or badge that changed
    }

    /// The window waits this long after the island starts closing before it shrinks back (the close spring has settled).
    static let islandSettle = 0.5

    // MARK: roles

    /// What a change is; each maps to one curve (and to another, or none, with Reduce Motion).
    enum Role: CaseIterable {
        case press, hover, selection, toggle, value
        case expand, page, appear, dropdown, dialog, notice, crossfade, dragSettle
        case islandOpen, islandClose, wing
        case hudDrop, hudRetract, hudBar, hudSwap
    }

    enum Curve: Equatable {
        case spring(Spring), easeOut(Double), easeIn(Double), easeInOut(Double), linear(Double)
        var animation: Animation {
            switch self {
            case .spring(let s): return s.animation
            case .easeOut(let d): return .easeOut(duration: d)
            case .easeIn(let d): return .easeIn(duration: d)
            case .easeInOut(let d): return .easeInOut(duration: d)
            case .linear(let d): return .linear(duration: d)
            }
        }
        var isSpring: Bool { if case .spring = self { return true }; return false }
        /// How long it runs (a spring: until it settles).
        var duration: Double {
            switch self {
            case .spring(let s): return s.settle
            case .easeOut(let d), .easeIn(let d), .easeInOut(let d), .linear(let d): return d
            }
        }
    }

    /// The table (pure: --motion-test checks it). nil: the change happens at once.
    static func curve(_ r: Role, reduce: Bool) -> Curve? {
        if reduce {
            switch r {
            // Movement only: with Reduce Motion it happens at once.
            case .islandOpen, .islandClose, .wing, .toggle, .hudBar, .expand, .dragSettle, .value: return nil
            case .press, .hudSwap: return .easeOut(Duration.instant)
            case .hover: return .easeOut(Duration.quick)
            case .hudDrop: return .easeOut(Duration.quick)
            case .hudRetract: return .easeIn(Duration.quick)
            case .selection, .page, .appear, .dropdown, .dialog, .notice, .crossfade: return .easeInOut(Duration.quick)
            }
        }
        switch r {
        case .press, .selection, .value, .hudBar: return .spring(snappy)
        case .hover: return .easeOut(Duration.quick)
        case .toggle, .islandOpen, .hudDrop: return .spring(bouncy)
        case .expand, .page, .dropdown, .dragSettle, .islandClose, .wing, .hudRetract: return .spring(smooth)
        case .appear, .dialog, .notice: return .spring(gentle)
        case .crossfade: return .easeInOut(Duration.standard)
        case .hudSwap: return .easeInOut(Duration.quick)
        }
    }

    /// The animation for a role now (Reduce Motion as the Mac has it; nil while disabled).
    static func animation(_ r: Role) -> Animation? { animation(r, reduce: reduce) }
    static func animation(_ r: Role, reduce: Bool) -> Animation? { disabled ? nil : curve(r, reduce: reduce)?.animation }

    /// Runs a model change with a role's animation.
    @discardableResult
    static func with<R>(_ r: Role, _ body: () throws -> R) rethrows -> R { try withAnimation(animation(r), body) }

    // MARK: kept names

    /// The alert's full-screen tints: two quick white flashes, or one soft tint that fades.
    static func flashes(reduce: Bool) -> [Double] { reduce ? [0.18, 0] : [0.55, 0, 0.55, 0] }
    /// Each step of the flashes: its value and how long it takes to get there (keyframes, AlertView).
    static func flashSteps(reduce: Bool) -> [(value: Double, duration: Double)] {
        flashes(reduce: reduce).map { ($0, reduce ? 0.45 : 0.2) }
    }
    /// The island's open/close: its role's spring, or no motion at all (it appears and goes at once).
    static func island(_ open: Bool) -> Animation? { animation(open ? .islandOpen : .islandClose) }

    /// The menu-bar bag's pour (drawn by a 30 fps timer that runs only while it pours, redrawing only the bag): filling eases
    /// out over `pourFill`, emptying eases in over `pourEmpty`.
    static let pourFill = 1.4
    static let pourEmpty = 0.7
    static func pour(_ f: CGFloat, filling: Bool) -> CGFloat {
        let t = min(1, max(0, f))
        return filling ? 1 - (1 - t) * (1 - t) : t * t
    }

    // MARK: transitions

    /// A card, a row or a notice arriving from (and leaving toward) an edge: it slides a few points and grows a little as it
    /// fades in. Reduce Motion: it only fades.
    static func appear(_ edge: Edge? = .top, anchor: UnitPoint = .top) -> AnyTransition {
        let r = reduce
        return .modifier(active: MotionEnter(t: 1, edge: edge, anchor: anchor, reduce: r), identity: MotionEnter(t: 0, edge: edge, anchor: anchor, reduce: r))
    }

    /// A page replacing another: the new one comes from the side of the tab that was picked, the old one leaves the other way.
    /// The direction is read when the slide runs (a page leaving reads the newest direction too). Reduce Motion: a cross-fade.
    static func page(_ d: PageDirection) -> AnyTransition {
        let r = reduce
        return .asymmetric(insertion: .modifier(active: PageSlide(t: 1, incoming: true, direction: d, reduce: r),
                                                identity: PageSlide(t: 0, incoming: true, direction: d, reduce: r)),
                           removal: .modifier(active: PageSlide(t: 1, incoming: false, direction: d, reduce: r),
                                              identity: PageSlide(t: 0, incoming: false, direction: d, reduce: r)))
    }
}

/// The screens editor's motion (Settings → Island → Screens), on the system's roles.
enum ScreensMotion {
    /// Editing: reordering, showing and hiding, resizing, a screen's modules opening (the preview follows with the same curve).
    static var edit: Animation? { Motion.animation(.expand) }
    /// A row (a module, a screen's module list) arriving or leaving.
    static var rowTransition: AnyTransition { Motion.appear(.top) }
}

/// Which way the last page change went (by the tabs' order), shared by the page leaving and the page arriving. A reference, so
/// the leaving page (drawn from its last state) still reads the newest direction.
final class PageDirection {
    private(set) var forward = true
    /// The tab moved from index `from` to `to` (nil: not in the list; then the direction stays).
    func note(from: Int?, to: Int?) {
        guard let from, let to, from != to else { return }
        forward = to > from
    }
}

/// t 0: in place; t 1: away (offset toward its edge, a little smaller, transparent).
struct MotionEnter: ViewModifier, Animatable {
    var t: CGFloat
    let edge: Edge?
    var anchor: UnitPoint = .top
    let reduce: Bool
    var animatableData: CGFloat { get { t } set { t = newValue } }
    func body(content: Content) -> some View {
        let d = reduce ? 0 : Motion.Distance.enter * t
        let off: CGSize
        switch edge {
        case .top?: off = CGSize(width: 0, height: -d)
        case .bottom?: off = CGSize(width: 0, height: d)
        case .leading?: off = CGSize(width: -d, height: 0)
        case .trailing?: off = CGSize(width: d, height: 0)
        case nil: off = .zero
        }
        let s = reduce ? 1 : 1 - (1 - Motion.Distance.enterScale) * t
        // Opaque well before it is in place (by t 0.4): a card half-way never lets the page under it show through its text.
        return content.scaleEffect(s, anchor: anchor).offset(off).opacity(Double(min(1, max(0, (1 - t) / 0.6))))
    }
}

/// One side of a page change: t 0 in place, t 1 out to the side (the incoming page from the side it comes from).
struct PageSlide: ViewModifier, Animatable {
    var t: CGFloat
    let incoming: Bool
    let direction: PageDirection
    let reduce: Bool
    var animatableData: CGFloat { get { t } set { t = newValue } }
    func body(content: Content) -> some View {
        let sign: CGFloat = (direction.forward ? 1 : -1) * (incoming ? 1 : -1)
        let dx = reduce ? 0 : sign * Motion.Distance.page * t
        // Fade through: the leaving page is gone by 40 % and the new one starts at 30 %, so the two never read as one muddle.
        let a = incoming ? (1 - t - 0.3) / 0.7 : 1 - 2.5 * t
        return content.offset(x: dx).opacity(Double(min(1, max(0, a))))
    }
}

/// A generation counter for delayed work a later change can supersede: `begin()` before scheduling, `isCurrent` when it runs.
struct MotionGeneration {
    private(set) var value = 0
    @discardableResult mutating func begin() -> Int { value &+= 1; return value }
    mutating func cancel() { value &+= 1 }
    func isCurrent(_ g: Int) -> Bool { g == value }
}

/// A row picked up to be dragged (ScreensEditor): which one, and only while the drag is over the list. The drag can end
/// anywhere (outside the panel, Esc): the lift is shown only while a row reports the drag inside it, so it never stays up.
struct DragLift: Equatable {
    private(set) var dragging: String?
    private(set) var inside = 0          // rows the drag is over (entered, not exited)
    mutating func begin(_ id: String) { dragging = id; inside = 0 }
    mutating func entered() { if dragging != nil { inside += 1 } }
    mutating func exited() { inside = max(0, inside - 1) }
    mutating func ended() { dragging = nil; inside = 0 }
    func lifted(_ id: String) -> Bool { dragging == id && inside > 0 }
}

// MARK: - View helpers

extension View {
    /// Animates this view's changes driven by `value` with a role's curve.
    func motion<V: Equatable>(_ r: Motion.Role, value: V) -> some View { animation(Motion.animation(r), value: value) }

    /// Press feedback: a pressed control shrinks a little (Reduce Motion: it dims instead) and springs back on release.
    func pressable(_ pressed: Bool, scale: CGFloat = Motion.Distance.pressScale) -> some View {
        modifier(Pressable(pressed: pressed, scale: scale))
    }

    /// Arrives from (and leaves toward) an edge: see Motion.appear.
    func motionAppear(edge: Edge? = .top, anchor: UnitPoint = .top) -> some View { transition(Motion.appear(edge, anchor: anchor)) }

    /// A selection moving (a highlight, a check mark, a chip): the selection's spring.
    func motionSelection<V: Equatable>(_ value: V) -> some View { animation(Motion.animation(.selection), value: value) }

    /// A number that changes: its digits roll (a cross-fade with Reduce Motion).
    func motionNumber<V: Equatable>(_ value: V) -> some View {
        contentTransition(Motion.reduce || Motion.disabled ? .opacity : .numericText()).animation(Motion.animation(.value), value: value)
    }

    /// Loading: a calm light band crosses the view (Reduce Motion: it breathes; disabled: still).
    func shimmer(_ active: Bool = true) -> some View { modifier(Shimmer(active: active)) }

    /// A short pulse each time `trigger` changes (a count, a badge): a little bigger and back (Reduce Motion: a dip in opacity).
    func motionPulse(_ trigger: Int) -> some View { modifier(MotionPulse(trigger: trigger)) }

    /// A row picked up to be dragged: a little bigger with a shadow; put back with the settle spring.
    func motionLift(_ lifted: Bool) -> some View { modifier(MotionLift(lifted: lifted)) }
}

struct Pressable: ViewModifier {
    let pressed: Bool
    let scale: CGFloat
    func body(content: Content) -> some View {
        let reduce = Motion.reduce
        return content
            .scaleEffect(pressed && !reduce ? scale : 1)
            .opacity(pressed && reduce ? Motion.Distance.pressOpacity : 1)
            .animation(Motion.animation(.press, reduce: reduce), value: pressed)
    }
}

/// The button style of glyph buttons (steppers' − and +, the editors' arrows): the press feedback and nothing else.
/// Wider plain buttons (rows, value buttons, segments) pass the gentler `pressScale`.
struct MotionGlyphStyle: ButtonStyle {
    var scale: CGFloat = Motion.Distance.pressScaleSmall
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pressable(configuration.isPressed, scale: scale)
    }
}

private struct Shimmer: ViewModifier {
    let active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if !active || Motion.disabled {
            content
        } else if Motion.reduce {
            content.phaseAnimator([1.0, 0.55]) { c, a in c.opacity(a) } animation: { _ in .easeInOut(duration: 1.1) }
        } else {
            content.overlay {
                GeometryReader { r in
                    let w = max(24, r.size.width * 0.5)
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: w)
                        .phaseAnimator([0.0, 1.0]) { band, ph in band.offset(x: -w + ph * (r.size.width + w)) } animation: { ph in ph == 1 ? .easeInOut(duration: 1.4) : nil }
                }
                .mask(content)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct MotionPulse: ViewModifier {
    let trigger: Int
    @ViewBuilder func body(content: Content) -> some View {
        if Motion.disabled {
            content
        } else {
            let reduce = Motion.reduce
            content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { c, k in
                c.scaleEffect(reduce ? 1 : 1 + (Motion.Distance.pulseScale - 1) * k).opacity(reduce ? 1 - 0.4 * Double(k) : 1)
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.12)
                SpringKeyframe(0, duration: 0.36, spring: Spring(response: Motion.snappy.response, dampingRatio: Motion.snappy.damping))
            }
        }
    }
}

private struct MotionLift: ViewModifier {
    let lifted: Bool
    func body(content: Content) -> some View {
        let reduce = Motion.reduce
        return content
            .scaleEffect(lifted && !reduce ? Motion.Distance.liftScale : 1)
            .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: lifted ? Motion.Distance.liftShadow : 0, y: lifted ? 3 : 0)
            .zIndex(lifted ? 1 : 0)
            .animation(Motion.animation(.dragSettle, reduce: reduce) ?? Motion.animation(.hover, reduce: reduce), value: lifted)
    }
}

/// Working: three dots that brighten in turn (opacity only, so the same with Reduce Motion; still while disabled). Calmer
/// than a spinner and the same size wherever it is (a 24 pt row, a button's label).
struct BusyDots: View {
    var color: Color = .white
    var label: String? = nil
    static func opacity(dot: Int, phase: Int) -> Double { dot == phase ? 1 : 0.35 }

    private func dots(_ phase: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in Circle().fill(color).frame(width: 4, height: 4).opacity(Self.opacity(dot: i, phase: phase)) }
        }
    }

    var body: some View {
        Group {
            if Motion.disabled {
                dots(-1)
            } else {
                Color.clear.phaseAnimator([0, 1, 2]) { _, ph in dots(ph) } animation: { _ in .easeInOut(duration: 0.32) }
            }
        }
        .frame(width: 18, height: 12)
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
    }
}
