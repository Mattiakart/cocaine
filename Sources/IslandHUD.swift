// The island's HUD: volume and brightness bars and the short notices ("Copied", "Downloaded"…) in a container that hangs
// straight below the notch, as wide as the notch, like a part of it that drops down for a moment. HUDTimeline is its pure
// logic (what is shown, for how long, what waits); IslandHUDView draws it; HUDShape is its outline.

import AppKit
import SwiftUI

/// One thing the container shows: an icon and a level bar (volume, brightness…), or an icon and a short text.
struct HUDItem: Equatable {
    var icon: String
    var text: String
    var level: Double?
    /// The battery's HUD (the charger plugged in or out, full, low: Sources/NotchPower.swift): its glyph instead of a bar.
    var power: ChargeGlyph? = nil
    /// Bars of one kind (all the volume steps of a held key) update in place; another kind (volume, then brightness) swaps the
    /// icon and label inside the same container; every text notice is one kind ("latest wins"); the battery's is its own
    /// (charging, then full: the same glyph changes in place).
    var kind: String { power != nil ? "power" : level != nil ? "level:" + text : "text" }
    var isLevel: Bool { level != nil }
}

/// What the container shows and until when. Pure: the time is handed in, so the tests run it without waiting.
/// - A bar is shown for `levelQuiet` after the last change: a key held or pressed quickly keeps one container up, its bar moving.
/// - A text stays long enough to be read (`textTime`), and a newer text replaces it at once.
/// - A bar arriving over a text that still has a while to go puts that text aside; it comes back when the bars go quiet (with
///   what it had left, at least `resumeMin`). Only the latest text waits, and it waits once: nothing is ever stuck.
struct HUDTimeline {
    static let levelQuiet: TimeInterval = 1.4
    static let resumeMin: TimeInterval = 1.2
    static let parkMin: TimeInterval = 1.0
    /// The battery's HUD stays a little longer than a short notice: the fill has to run and be read (Boring Notch: 3 s).
    static let powerTime: TimeInterval = 3
    static func textTime(_ text: String) -> TimeInterval { min(5, max(2.2, 1.2 + Double(text.count) * 0.05)) }

    enum Change: Equatable { case appear, update, swap, hide, none }

    /// The content (kept while the container retracts, so it never goes blank on its way up).
    private(set) var item: HUDItem?
    private(set) var shown = false
    private(set) var until: TimeInterval = 0
    private(set) var parked: (item: HUDItem, left: TimeInterval)?

    @discardableResult
    mutating func post(_ new: HUDItem, now: TimeInterval) -> Change {
        let change: Change = !shown || item == nil ? .appear : item!.kind == new.kind ? .update : .swap
        if new.isLevel {
            if shown, let cur = item, !cur.isLevel, until - now >= Self.parkMin { parked = (cur, until - now) }
        } else {
            parked = nil                                          // the latest text wins
        }
        item = new
        shown = true
        until = now + (new.isLevel ? Self.levelQuiet : new.power != nil ? Self.powerTime : Self.textTime(new.text))
        return change
    }

    /// Time passed: the container goes (or a text that waited comes back).
    @discardableResult
    mutating func tick(now: TimeInterval) -> Change {
        guard shown, now >= until - 0.001 else { return .none }
        if let p = parked {
            parked = nil
            item = p.item
            until = now + max(Self.resumeMin, p.left)
            return .swap
        }
        shown = false
        return .hide
    }

    /// The island opened (or the HUD has nowhere to be): it gives way at once, nothing comes back later.
    mutating func dismiss() { shown = false; parked = nil }

    var nextDeadline: TimeInterval? { shown ? until : nil }
}

// MARK: - Motion (named, so the app-wide motion pass can tune them in one place)

extension Island {
    /// Room below the notch the closed window keeps for the HUD (its tallest form plus the spring's overshoot).
    static let hudRoom: CGFloat = 52
    /// Its heights: a bar, or up to two lines of text.
    static func hudHeight(_ item: HUDItem?) -> CGFloat { item?.isLevel ?? true ? 30 : 42 }
    /// Dropping out of the notch: quick, with a touch of give (Motion's hudDrop role: the bouncy spring).
    static func hudDrop(reduce: Bool) -> Animation? { Motion.animation(.hudDrop, reduce: reduce) }
    /// Going back up into the notch: smooth (hudRetract: the smooth spring).
    static func hudRetract(reduce: Bool) -> Animation? { Motion.animation(.hudRetract, reduce: reduce) }
    /// The bar running to its new level (never rebuilt: the same bar moves; a new level retargets the running spring).
    static func hudBar(reduce: Bool) -> Animation? { Motion.animation(.hudBar, reduce: reduce) }
    /// Another kind in the same container: icon and label cross-fade, the height follows.
    static func hudSwap(reduce: Bool) -> Animation? { Motion.animation(.hudSwap, reduce: reduce) }
}

// MARK: - The outline

/// The container's outline in the island's canvas: it starts inside the closed island (black on black, so there is no seam),
/// goes straight down the notch's sides, with small concave fillets where it leaves the island's bottom edge (the same
/// shape as the island's flares at the top of the screen), and ends in the island's continuous bottom corners.
/// `reveal` 0 is tucked into the notch, 1 is fully down; with Reduce Motion it is always fully down and fades instead.
struct HUDShape: Shape {
    var reveal: CGFloat
    var height: CGFloat
    let left: CGFloat           // the notch's edges in the canvas
    let right: CGFloat
    let join: CGFloat           // the closed island's bottom (the notch's)
    let filletLeft: Bool        // the island goes on past this side (a wing): a fillet joins the two
    let filletRight: Bool
    /// The closed island's bottom corner (the notch's, or the user's on a bar without one): the container ends in the same.
    var cornerSpan: CGFloat = HUDShape.corner
    var animatableData: AnimatablePair<CGFloat, CGFloat> { get { AnimatablePair(reveal, height) } set { reveal = newValue.first; height = newValue.second } }

    static let overlap: CGFloat = 14          // reaches up into the island: covers its own bottom corner when no wing is there
    static let corner: CGFloat = 13.5         // the closed island's bottom corner span (IslandLayout.path at p = 0)
    static let fillet: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let drop = max(0, height * reveal)
        let top = join - Self.overlap, bottom = join + drop
        let corner = max(0, min(cornerSpan, drop * 0.9, (right - left) / 2))
        let f = min(Self.fillet, drop / 3)
        let fl = filletLeft ? f : 0, fr = filletRight ? f : 0
        let kf: CGFloat = 0.6, kc: CGFloat = 0.7
        var p = Path()
        p.move(to: CGPoint(x: left - fl, y: top))
        p.addLine(to: CGPoint(x: right + fr, y: top))
        p.addLine(to: CGPoint(x: right + fr, y: join))
        p.addCurve(to: CGPoint(x: right, y: join + fr), control1: CGPoint(x: right + fr * (1 - kf), y: join), control2: CGPoint(x: right, y: join + fr * (1 - kf)))
        p.addLine(to: CGPoint(x: right, y: bottom - corner))
        p.addCurve(to: CGPoint(x: right - corner, y: bottom), control1: CGPoint(x: right, y: bottom - corner * (1 - kc)), control2: CGPoint(x: right - corner * (1 - kc), y: bottom))
        p.addLine(to: CGPoint(x: left + corner, y: bottom))
        p.addCurve(to: CGPoint(x: left, y: bottom - corner), control1: CGPoint(x: left + corner * (1 - kc), y: bottom), control2: CGPoint(x: left, y: bottom - corner * (1 - kc)))
        p.addLine(to: CGPoint(x: left, y: join + fl))
        p.addCurve(to: CGPoint(x: left - fl, y: join), control1: CGPoint(x: left, y: join + fl * (1 - kf)), control2: CGPoint(x: left - fl * (1 - kf), y: join))
        p.closeSubpath()
        return p
    }
}

/// Carries the container's content along the reveal: it fades in once there is room for it and rises with the drop.
private struct HUDContentReveal: ViewModifier, Animatable {
    var reveal: CGFloat
    let reduce: Bool
    var animatableData: CGFloat { get { reveal } set { reveal = newValue } }
    func body(content: Content) -> some View {
        let a = reduce ? 1 : Island.smooth((reveal - 0.35) / 0.65)
        return content.opacity(a).offset(y: reduce ? 0 : -6 * (1 - Island.clamp(reveal)))
            .environment(\.hudReveal, reveal)          // the battery's fill and bolt follow the drop frame by frame
    }
}

// MARK: - The view

/// The container in one island's canvas. `here`: this island is the one the HUD was sent to; `islandOpen`: this island is open
/// (the HUD gives way to it).
struct IslandHUDView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var display = DisplayOptions.shared
    let layout: IslandLayout
    let notchH: CGFloat
    let pose: IslandPose
    let here: Bool
    let islandOpen: Bool

    var body: some View {
        let reduce = display.reduceMotion || Motion.reduce
        let frame = model.hudItem == nil ? nil : Motion.frame             // the render aid: one moment of the drop
        let visible = frame.map { $0 > 0 } ?? (here && model.hudShown && !islandOpen)
        // One value drives the drop and the content: a new HUD while one is down keeps it down and only swaps what is inside;
        // a reversal mid-way retargets the spring from where the container is.
        let reveal = frame ?? (visible ? 1 : 0)
        let item = model.hudItem
        let h = Island.hudHeight(item)
        let join = layout.top + notchH
        let shape = HUDShape(reveal: reduce ? 1 : reveal, height: h, left: layout.notchLeft, right: layout.notchRight, join: join,
                             filletLeft: pose.leftW > 1, filletRight: pose.rightW > 1, cornerSpan: layout.closedCorner)
        ZStack(alignment: .topLeading) {
            if reduce {
                shape.fill(Color.black).opacity(Double(reveal))                          // Reduce Motion: fades, never moves
            } else {
                shape.fill(Color.black)
            }
            content(item, h: h, reduce: reduce)
                .frame(width: layout.notchRight - layout.notchLeft, height: h)
                .offset(x: layout.notchLeft, y: join)
                .modifier(HUDContentReveal(reveal: reveal, reduce: reduce))
                .opacity(reduce ? Double(reveal) : 1)
                .mask(shape)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .animation(visible ? Island.hudDrop(reduce: reduce) : Island.hudRetract(reduce: reduce), value: visible)
        .animation(Island.hudSwap(reduce: reduce), value: item?.kind)
        .allowsHitTesting(false)
        .accessibilityHidden(true)                    // a notice is announced when it comes; the bars are the system's own sounds
    }

    @ViewBuilder private func content(_ item: HUDItem?, h: CGFloat, reduce: Bool) -> some View {
        if let item, let glyph = item.power {
            ChargeHUDContent(item: item, glyph: glyph, reduce: reduce)
                .padding(.horizontal, Space.l + 2)
                .padding(.top, 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(item.kind)
                .transition(.opacity)
        } else if let item {
            HStack(spacing: Space.m) {
                Image(systemName: item.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Island.accent)
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(Island.hudSwap(reduce: reduce), value: item.icon)
                if let level = item.level {
                    HUDBar(level: level, reduce: reduce)
                } else {
                    // The start of a file name says which file it is; the end is cut (".dmg" isn't news).
                    Text(item.text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                        .lineLimit(2).truncationMode(.tail).minimumScaleFactor(0.9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Space.l + 2)
            .padding(.top, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(item.kind)                            // another kind: a cross-fade; the same kind: updated in place
            .transition(.opacity)
        }
    }
}

/// The level bar: the island's white bar on a faint track; a new level moves the same bar.
private struct HUDBar: View {
    let level: Double
    let reduce: Bool
    var body: some View {
        GeometryReader { r in
            let v = CGFloat(min(1, max(0, level)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(.white).frame(width: max(5, r.size.width * v)).opacity(v > 0 ? 1 : 0)
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
        }
        .animation(Island.hudBar(reduce: reduce), value: level)
    }
}
