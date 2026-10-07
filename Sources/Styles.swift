// Shared view pieces: the warning color, the switch, press scale, powder line, Layout, two-finger scroll steps.

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

/// Warnings: deep orange on a light panel, light orange on a dark one; both read at over 4.5:1 contrast.
let warningColor = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 1.0, green: 0.72, blue: 0.30, alpha: 1)
        : NSColor(srgbRed: 0.63, green: 0.28, blue: 0.0, alpha: 1)
})

// The type scale, text inks and spacing live in Sources/Tokens.swift (UI, Space), shared with the dialogs and the agent list.
extension UI {
    /// In-app dialogs (Sources/InAppDialog.swift) in the same type scale and colors.
    static var dialog: DialogStyle {
        DialogStyle(title: groupTitle, body: value, row: title, detail: detail, icon: icon, accent: Island.accent, warning: warningColor)
    }
}

/// Cocaine's one switch, the same size everywhere: grey track when off, accent color when on, a white knob. The main
/// one also shows a thin line of powder that pours in (and fades out) with the menu-bar baggie's fill level.
struct CocaineSwitch: View {
    let on: Bool
    var powder: CGFloat? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.dimmedByContainer) private var dimmedByContainer

    init(on: Bool, powder: CGFloat? = nil, action: @escaping () -> Void) {
        self.on = on; self.powder = powder; self.action = action
    }

    init(_ isOn: Binding<Bool>) {
        self.init(on: isOn.wrappedValue) { isOn.wrappedValue.toggle() }
    }

    var body: some View {
        let w = UI.switchSize.width, h = UI.switchSize.height
        Button(action: { Haptic.tap(.alignment); action() }) {
            ZStack {
                Capsule().fill(on ? Island.accent : Color.white.opacity(0.18))
                if let powder { Canvas { g, size in PowderLine.draw(g, size, level: powder) } }
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.28), radius: 1.1, y: 0.6)
                    .padding(2)
                    .frame(width: h, height: h)
                    .offset(x: on ? (w - h) / 2 : -(w - h) / 2)
            }
            .frame(width: w, height: h)
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: on)
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .opacity(enabled || dimmedByContainer ? 1 : UI.disabledOpacity)        // dimmed once: by itself, or by its group
        .accessibilityValue(on ? L("On") : L("Off"))
        .accessibilityAddTraits(.isToggle)
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum PowderLine {
    /// Grains along the track, left to right: position (0…1 of the line), vertical jitter, size, brightness.
    typealias Grain = (x: CGFloat, dy: CGFloat, r: CGFloat, a: CGFloat)
    // Spelled out step by step with explicit types: as one tuple expression in a closure, Swift 5.10 (CI) gave up on it
    // ("unable to type-check this expression in reasonable time").
    static let grains: [Grain] = {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func rnd() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let top: UInt64 = seed >> 33
            return CGFloat(top) / CGFloat(2_147_483_648.0)
        }
        var out: [Grain] = []
        out.reserveCapacity(44)
        for i in 0..<44 {
            let x: CGFloat = CGFloat(i) / 43
            let dy: CGFloat = (rnd() - 0.5) * 3
            let r: CGFloat = 0.4 + rnd() * 0.5
            let a: CGFloat = 0.6 + rnd() * 0.4
            out.append((x: x, dy: dy, r: r, a: a))
        }
        return out
    }()

    /// The line runs from the track's left end to where the knob sits when on; `level` says how much of it is there.
    static func draw(_ g: GraphicsContext, _ size: CGSize, level: CGFloat) {
        let lvl = min(max(level, 0), 1)
        guard lvl > 0.01 else { return }
        let start: CGFloat = 6, end = size.width - size.height + 2, mid = size.height / 2
        for gr in grains where gr.x <= lvl {
            let x = start + gr.x * (end - start), r = gr.r
            g.fill(Path(ellipseIn: CGRect(x: x - r, y: mid + gr.dy - r, width: 2 * r, height: 2 * r)),
                   with: .color(.white.opacity(gr.a * (0.4 + 0.6 * lvl))))
        }
    }
}

enum Layout {
    static let width: CGFloat = 440                          // the panel's width: one number, never taken from content
    static let overscan: CGFloat = 6                         // windows hanging from the notch start this far above the screen's top edge
    // Two vertical edges, everything on one of them: the frame edge (14 pt from the panel's sides) holds containers (cards,
    // tabs, dividers); the content edge (10 pt further in) holds every text, icon and control. Controls end on the
    // content edge, on the right; full-width controls span it.
}

/// Two-finger scrolling (or the mouse wheel) over a control: calls `perform` with whole steps, positive = more (swipe left or up).
struct ScrollSteps: NSViewRepresentable {
    let threshold: CGFloat
    let perform: (Int) -> Void
    func makeNSView(context: Context) -> NSView { let v = Catcher(); v.threshold = threshold; v.perform = perform; return v }
    func updateNSView(_ v: NSView, context: Context) { (v as? Catcher)?.threshold = threshold; (v as? Catcher)?.perform = perform }

    final class Catcher: NSView {
        var threshold: CGFloat = 10
        var perform: (Int) -> Void = { _ in }
        private var acc: CGFloat = 0
        private var monitor: Any?

        /// Looks at every scroll event of the app and takes those that land on this view (SwiftUI's own hit testing would
        /// never hand them to a background view).
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let over = self.bounds.contains(self.convert(e.locationInWindow, from: nil))
                guard Self.takes(phase: e.phase, momentum: e.momentumPhase, over: over, owned: &self.owned),
                      DialogCenter.shared.current == nil, !PickerCenter.shared.isOpen else { return e }   // a question or a dropdown on top: nothing under it changes
                self.handle(e)
                return nil                                       // used here: the panel behind doesn't scroll as well
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

        /// Whether this control takes a scroll event. A trackpad gesture belongs to the control only if it *started* over it: a
        /// scroll of the panel that slides across the timer keeps scrolling the panel (and changes nothing); the momentum after
        /// lifting the fingers never steps. A mouse wheel (no phases) steps while the pointer is over the control.
        var owned = false
        static func takes(phase: NSEvent.Phase, momentum: NSEvent.Phase, over: Bool, owned: inout Bool) -> Bool {
            if !momentum.isEmpty { return false }
            if phase.contains(.mayBegin) || phase.contains(.began) { owned = over; return owned }
            if phase.contains(.ended) || phase.contains(.cancelled) { let was = owned; owned = false; return was && over }
            if phase.isEmpty { return over }                             // a wheel click
            return owned && over                                         // .changed (and .stationary)
        }

        private func handle(_ e: NSEvent) {
            if e.phase == .began || e.phase == .mayBegin { acc = 0 }
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
            let dx = e.scrollingDeltaX * k, dy = e.scrollingDeltaY * k
            acc += abs(dx) > abs(dy) ? -dx : -dy
            let n = Int(acc / threshold)
            if n != 0 { acc -= CGFloat(n) * threshold; Haptic.tap(.alignment); perform(n) }
        }
    }
}

extension View {
    func onScrollSteps(every points: CGFloat = 12, _ perform: @escaping (Int) -> Void) -> some View { background(ScrollSteps(threshold: points, perform: perform)) }
}
