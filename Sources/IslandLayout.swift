// The island's geometry and shapes: Island, NotchGeometry, poses, layout, outline and the morph modifiers.

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

// MARK: - Island: the notch (or the top of any screen) as a live home for Cocaine and its tools

enum Island {
    static let accent = Color(red: 0.40, green: 0.64, blue: 1.0)
    static let overscan = Layout.overscan
    static let openSize = CGSize(width: 640, height: 214)
    static let wing: CGFloat = 62                              // each side of the notch when something is live
    static let slack: CGFloat = 8                              // room around the open island for the spring's overshoot
    /// Opening: quick off the mark, with a touch of give at the end. Closing: a bit quicker, settling without a bounce.
    static let openSpring = Animation.spring(response: 0.4, dampingFraction: 0.78)
    static let closeSpring = Animation.spring(response: 0.32, dampingFraction: 0.9)
    static var forceExternal = false                           // the render tool: show the Monitors tab
    static var external: Bool { forceExternal || !DDCDisplays.externalNames.isEmpty }

    static func clamp(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
    static func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    static func smooth(_ x: CGFloat) -> CGFloat { let t = clamp(x); return t * t * (3 - 2 * t) }
    /// The morph's progress for an item that starts a little later: still 1 at p = 1, and it keeps the spring's overshoot.
    static func delayed(_ p: CGFloat, by d: CGFloat) -> CGFloat { p < 0 ? p : max(0, (p - d) / (1 - d)) }
    /// Cross-morph timing: what the closed island shows is gone by p 0.5, what replaces it arrives over p 0.15…0.6.
    static func meltOut(_ p: CGFloat) -> CGFloat { smooth(p / 0.5) }
    static func meltIn(_ p: CGFloat) -> CGFloat { smooth((p - 0.15) / 0.45) }
    /// id, symbol, title. The first half goes left of the notch, the rest right of it.
    static func tabs(external: Bool) -> [(id: String, icon: String, title: String)] {
        var t = [("home", "house.fill", L("Home")), ("music", "music.note", L("Music")), ("media", "play.rectangle.fill", L("Media")), ("calendar", "calendar", L("Calendar")), ("focus", "timer", L("Focus")),
                 ("files", "tray.full.fill", L("Files")), ("shelf", "tray.and.arrow.down.fill", L("Shelf")), ("clipboard", "doc.on.clipboard", L("Clipboard")),
                 ("status", "gauge.with.needle", L("Status")), ("mirror", "person.crop.square", L("Mirror"))]
        if external { t.append(("display", "display", L("Monitors"))) }
        return t
    }
}

/// Where the island sits: the real notch of a built-in display, or a slim pill at the top of any other screen.
struct NotchGeometry: Equatable {
    var frame: CGRect          // the screen's frame
    var notchWidth: CGFloat
    var height: CGFloat
    var centerX: CGFloat       // the notch's middle, in screen coordinates
    var hasNotch: Bool

    /// The render tools (`--notch-width`): another Mac's notch, to see the panel and the island as they'd be there.
    static var override: NotchGeometry?

    static func current() -> NotchGeometry? {
        if let override { return override }
        let screens = NSScreen.screens
        guard let s = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first else { return nil }
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return NotchGeometry(frame: s.frame, notchWidth: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top,
                                 centerX: s.frame.minX + l.width + (s.frame.width - l.width - r.width) / 2, hasNotch: true)
        }
        return NotchGeometry(frame: s.frame, notchWidth: 150, height: 24, centerX: s.frame.midX, hasNotch: false)
    }
}

/// One moment of the open/close morph. p runs from 0 (closed) to 1 (open) and a spring overshoots it a little past either end;
/// leftW/rightW are the closed island's wings. Everything that moves is a function of this, so the outline, the clip and every
/// icon stay in step whatever the spring does (and the render tool can draw any moment of it).
struct IslandPose {
    var p: CGFloat
    var leftW: CGFloat
    var rightW: CGFloat
    var data: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(p, AnimatablePair(leftW, rightW)) }
        set { p = newValue.first; leftW = newValue.second.first; rightW = newValue.second.second }
    }
    /// 0 with the bag alone on the left, 1 while a flash message widens the left wing.
    var flash: CGFloat { Island.clamp((leftW - Island.wing) / (IslandModel.maxWing - Island.wing)) }
    /// 0 with nothing right of the notch, 1 with something live there.
    var wing: CGFloat { Island.clamp(rightW / Island.wing) }
}

/// The island's geometry in a fixed canvas: as wide as the open island plus room for the spring's overshoot, centred on the notch,
/// its top `overscan` above the screen's edge. The canvas never changes size, so resizing the window around it moves nothing.
struct IslandLayout {
    let notch: CGFloat          // the notch's width
    let notchH: CGFloat         // and its height (the menu bar's)
    static let openBody = Island.openSize.width - 28        // the open island between its two top flares

    var size: CGSize { CGSize(width: max(Island.openSize.width + 2 * Island.slack, notch + 2 * IslandModel.maxWing + 20),
                              height: Island.openSize.height + Island.slack + Island.overscan) }
    var cx: CGFloat { size.width / 2 }
    var top: CGFloat { Island.overscan }
    var notchLeft: CGFloat { cx - notch / 2 }
    var notchRight: CGFloat { cx + notch / 2 }

    /// Height trails width a little: the island first runs along the screen's edge, then drops (and on closing, rises first).
    static func depth(_ p: CGFloat) -> CGFloat { p <= 0 ? p : p < 1 ? pow(p, 1.5) : 1 + 1.5 * (p - 1) }

    /// The outline: concave flares where it meets the screen's edge, straight sides, continuous ("squircle") bottom corners.
    /// Closed it is the real notch's silhouette plus its wings; every measure is interpolated, so it morphs along the same lines.
    func sides(_ s: IslandPose) -> (minX: CGFloat, maxX: CGFloat) {
        (min(Island.mix(notchLeft - s.leftW, cx - Self.openBody / 2, s.p), notchLeft),                 // never narrower than the notch
         max(Island.mix(notchRight + s.rightW, cx + Self.openBody / 2, s.p), notchRight))
    }
    func bodyWidth(_ s: IslandPose) -> CGFloat { let b = sides(s); return b.maxX - b.minX }

    func path(_ s: IslandPose) -> Path {
        let p = s.p, d = Self.depth(p)
        let (minX, maxX) = sides(s)
        let y0 = top, y1 = top + max(notchH, Island.mix(notchH, Island.openSize.height, d))
        let flare = max(0, Island.mix(6.5, 14, p))                                                  // how far the flare reaches out
        let flareH = min(max(0, Island.mix(7, 15, p)), (y1 - y0) * 0.4)                             // and down the side
        let corner = max(0, min(Island.mix(10, 24, d) * 1.35, y1 - y0 - flareH, (maxX - minX) / 2)) // span of a bottom corner
        let kf: CGFloat = 0.6, kc: CGFloat = 0.7          // handle lengths: long handles ease into the straight lines (no kink)
        var path = Path()
        path.move(to: CGPoint(x: minX - flare, y: 0))
        path.addLine(to: CGPoint(x: maxX + flare, y: 0))
        path.addLine(to: CGPoint(x: maxX + flare, y: y0))
        path.addCurve(to: CGPoint(x: maxX, y: y0 + flareH), control1: CGPoint(x: maxX + flare * (1 - kf), y: y0), control2: CGPoint(x: maxX, y: y0 + flareH * (1 - kf)))
        path.addLine(to: CGPoint(x: maxX, y: y1 - corner))
        path.addCurve(to: CGPoint(x: maxX - corner, y: y1), control1: CGPoint(x: maxX, y: y1 - corner * (1 - kc)), control2: CGPoint(x: maxX - corner * (1 - kc), y: y1))
        path.addLine(to: CGPoint(x: minX + corner, y: y1))
        path.addCurve(to: CGPoint(x: minX, y: y1 - corner), control1: CGPoint(x: minX + corner * (1 - kc), y: y1), control2: CGPoint(x: minX, y: y1 - corner * (1 - kc)))
        path.addLine(to: CGPoint(x: minX, y: y0 + flareH))
        path.addCurve(to: CGPoint(x: minX - flare, y: y0), control1: CGPoint(x: minX, y: y0 + flareH * (1 - kf)), control2: CGPoint(x: minX - flare * (1 - kf), y: y0))
        path.closeSubpath()
        return path
    }
}

/// The island's outline at a pose: filled black, and used again as the clip of everything inside it.
struct IslandOutline: Shape {
    var pose: IslandPose
    let layout: IslandLayout
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> { get { pose.data } set { pose.data = newValue } }
    func path(in rect: CGRect) -> Path { layout.path(pose) }
}

/// Carries one item of the top strip along the morph, from where it is in the closed island (a wing, or tucked behind the notch)
/// to its cell in the open strip. Items leave in a short stagger, outermost first, so they come out of the notch like a train and
/// never cross; closing runs the same function backwards, so the innermost are home first.
struct StripSlide: ViewModifier, Animatable {
    enum From { case leftWing, rightWing, gear, behindLeft, behindRight }
    enum Fade { case none, reveal, melt, gear }
    var pose: IslandPose
    let layout: IslandLayout
    let from: From
    let to: CGFloat             // the centre of its cell in the open strip
    let width: CGFloat
    let order: Int              // 0 = outermost
    let fade: Fade
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> { get { pose.data } set { pose.data = newValue } }

    func body(content: Content) -> some View {
        let l = layout, p = pose.p
        let start: CGFloat
        switch from {
        case .leftWing: start = l.notchLeft - pose.leftW / 2
        case .rightWing: start = l.notchRight + pose.rightW / 2
        case .behindLeft: start = l.notchLeft + width / 2
        case .behindRight: start = l.notchRight - width / 2
        case .gear: start = Island.mix(l.notchRight - width / 2, l.notchRight + pose.rightW / 2, pose.wing)    // where the live item is, if any
        }
        let t = Island.delayed(p, by: CGFloat(order) * 0.045)
        let x = Island.mix(start, to, t)
        // How much of it is out from behind the notch (the hardware hides the rest; without a notch it fades in the same way).
        let out = Island.clamp(x < l.cx ? (l.notchLeft - (x - width / 2)) / width : (x + width / 2 - l.notchRight) / width)
        var alpha: CGFloat = 1, scale: CGFloat = 1, blur: CGFloat = 0
        switch fade {
        case .none: break
        case .reveal:           // they fan out of the notch: small while still bunched up, full size once in their cells
            alpha = out * Island.smooth(t / 0.6); scale = Island.mix(0.45, 1, Island.clamp(t))
        case .melt:                                         // the closed island's live item, melting into the gear as it travels
            let m = Island.meltOut(p)
            alpha = (1 - m) * pose.wing; scale = 1 - 0.3 * m; blur = 3 * m
        case .gear:
            let a = Island.meltIn(p)
            alpha = Island.mix(out, a, pose.wing); scale = 0.6 + 0.4 * alpha; blur = 3 * (1 - a) * pose.wing
        }
        return content.scaleEffect(scale).blur(radius: blur).opacity(alpha)
            .offset(x: x - width / 2, y: l.top)
    }
}

/// Cross-morphs inside the bag's cell: the flash icon melts out as the bag melts in, and the Home highlight appears.
struct CellMorph: ViewModifier, Animatable {
    enum Kind { case bag(dim: CGFloat), flashIcon, highlight }
    var pose: IslandPose
    let kind: Kind
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> { get { pose.data } set { pose.data = newValue } }

    func body(content: Content) -> some View {
        let p = pose.p
        var alpha: CGFloat = 1, scale: CGFloat = 1, blur: CGFloat = 0
        switch kind {
        case .bag(let dim):                                 // closed: full; open: like an unselected tab when Home isn't shown
            let a = Island.mix(1, Island.meltIn(p), pose.flash)
            alpha = a * Island.mix(1, dim, Island.clamp(p)); scale = Island.mix(1, 0.7 + 0.3 * a, pose.flash); blur = 3 * (1 - a)
        case .flashIcon:
            let m = Island.meltOut(p)
            alpha = 1 - m; scale = 1 - 0.3 * m; blur = 3 * m
        case .highlight: alpha = Island.clamp((p - 0.5) / 0.4)
        }
        return content.scaleEffect(scale).blur(radius: blur).opacity(alpha)
    }
}

/// The open page below the strip: it grows with the island's width (so it is never cut by the sides), fades in a beat after
/// the island starts to open, and goes first on closing.
struct PageReveal: ViewModifier, Animatable {
    var pose: IslandPose
    let layout: IslandLayout
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> { get { pose.data } set { pose.data = newValue } }
    func body(content: Content) -> some View {
        let c = Island.smooth((pose.p - 0.35) / 0.55)
        let scale = min(1, max(0.5, layout.bodyWidth(pose) / IslandLayout.openBody))
        return content.opacity(c).scaleEffect(scale, anchor: .top).offset(y: -8 * (1 - c))
    }
}
