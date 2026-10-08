// The menu-bar panel's window (MenuPanel), its hosting view and closure menu items.

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

// MARK: - App

/// Tells the app when the SwiftUI content's size changes (e.g. the brightness section appears).
final class PanelHostingView: NSHostingView<PanelView> {
    var onSizeChange: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}

/// Borderless panel shown under the menu-bar icon. It can take clicks without activating the app, never
/// resizes while open, and closes only when you click elsewhere, press Esc or click the icon again.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }     // exactly where we say, even above the screen
    /// The content scrolls when it is taller than the screen allows (the app sizes the window; see fitPanel).
    let scroll = NSScrollView()
    /// The dialog layer above the scroll view (PanelDialogOverlay): pinned to the visible area, hidden while no dialog is up.
    let overlay: NSView

    init(content: NSView, overlay: NSView) {
        self.overlay = overlay
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isMovable = false

        let fx = NSView()
        fx.wantsLayer = true
        fx.layer?.backgroundColor = NSColor.black.cgColor
        fx.layer?.cornerRadius = 12
        appearance = NSAppearance(named: .darkAqua)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none                 // content can never be dragged sideways
        scroll.usesPredominantAxisScrolling = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        fx.addSubview(scroll)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        fx.addSubview(overlay)
        NSLayoutConstraint.activate([      // the document is pinned to the top: the app sizes the window, top edge fixed
            overlay.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: fx.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: fx.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalToConstant: Layout.width),     // required: the content is exactly as wide as the box
        ])
        fx.layer?.masksToBounds = true
        contentView = fx
    }

    /// Hanging from the top of the screen under the notch (flat top, round bottom, like the open island), or a floating menu.
    func attach(toTop: Bool) {
        hangsFromNotch = toTop
        guard let l = contentView?.layer else { return }
        l.cornerRadius = toTop ? 28 : 12
        l.maskedCorners = toTop ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    // MARK: Opening and closing (round 7: it used to appear and vanish at once)

    private(set) var hangsFromNotch = false
    private var motion = MotionGeneration()
    /// Closing: ordered out once the fade has run (a reopen meanwhile cancels it). While it fades the panel counts as closed
    /// (isVisible false): a click on the icon, a dialog or a shortcut opens it again rather than "closing" it twice.
    private(set) var closing = false
    override var isVisible: Bool { super.isVisible && !closing }

    /// How the panel arrives (pure; --ui-test checks it). From the notch it drops out of it like the open island: it starts as
    /// tall as the notch strip and grows to its size, top edge fixed, already opaque (black from black). As a menu under the
    /// icon it slides down a few points as it fades in. Reduce Motion: a short fade in place. Motion.disabled (tests): at once.
    struct Entrance: Equatable {
        let start: NSRect
        let startAlpha: CGFloat
        let duration: Double
    }
    static let dropStart: CGFloat = 44                         // the notch strip's height and a little: where the drop starts
    static func entrance(to frame: NSRect, fromNotch: Bool, reduce: Bool, disabled: Bool = Motion.disabled) -> Entrance {
        if disabled { return Entrance(start: frame, startAlpha: 1, duration: 0) }
        if reduce { return Entrance(start: frame, startAlpha: 0, duration: Motion.Duration.quick) }
        if fromNotch {
            let h = min(frame.height, dropStart)
            return Entrance(start: NSRect(x: frame.minX, y: frame.maxY - h, width: frame.width, height: h), startAlpha: 1, duration: 0.3)
        }
        return Entrance(start: frame.offsetBy(dx: 0, dy: Motion.Distance.enter), startAlpha: 0, duration: Motion.Duration.standard)
    }
    /// How it leaves: a quick fade (and from the notch, back up into it). Reduce Motion: the fade alone.
    static func exit(from frame: NSRect, toNotch: Bool, reduce: Bool, disabled: Bool = Motion.disabled) -> Entrance {
        if disabled { return Entrance(start: frame, startAlpha: 1, duration: 0) }
        if toNotch && !reduce {
            let h = min(frame.height, dropStart)
            return Entrance(start: NSRect(x: frame.minX, y: frame.maxY - h, width: frame.width, height: h), startAlpha: 0, duration: 0.2)
        }
        return Entrance(start: frame, startAlpha: 0, duration: Motion.Duration.quick)
    }
    /// An ease-out with a long, soft landing: close to the notch's open spring without overshooting the screen's edge.
    static let entranceCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    /// Shows the panel at `frame` with its entrance.
    func present(at frame: NSRect) {
        closing = false
        let g = motion.begin()
        KeyboardNav.shared.reset()                             // a fresh panel shows no keyboard ring until Tab
        let e = Self.entrance(to: frame, fromNotch: hangsFromNotch, reduce: Motion.reduce)
        guard e.duration > 0 else { alphaValue = 1; setFrame(frame, display: true); makeKeyAndOrderFront(nil); return }
        alphaValue = e.startAlpha
        setFrame(e.start, display: true)
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = e.duration
            ctx.timingFunction = Self.entranceCurve
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = 1
            if e.start != frame { animator().setFrame(frame, display: true) }
        } completionHandler: { [weak self] in
            guard let self, self.motion.isCurrent(g) else { return }
            self.alphaValue = 1
        }
    }

    /// Hides the panel with its exit, then orders it out (`done` runs once it is gone; at once while motion is off).
    func dismiss(_ done: @escaping () -> Void = {}) {
        let g = motion.begin()
        let e = Self.exit(from: frame, toNotch: hangsFromNotch, reduce: Motion.reduce)
        guard e.duration > 0, isVisible else { orderOut(nil); alphaValue = 1; done(); return }
        closing = true
        let full = frame
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = e.duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            if e.start != full { animator().setFrame(e.start, display: true) }
        } completionHandler: { [weak self] in
            guard let self, self.motion.isCurrent(g) else { return }          // reopened meanwhile: stays
            self.orderOut(nil)
            self.alphaValue = 1
            self.closing = false
            done()
        }
    }

    // MARK: The dialog layer

    private var overlayGeneration = MotionGeneration()
    /// Shows the dialog layer at once; hides it only after the card's exit has run (it used to vanish with the card mid-way).
    func setOverlay(visible: Bool) {
        let g = overlayGeneration.begin()
        if visible { overlay.isHidden = false; return }
        let wait = Self.overlayHideDelay(reduce: Motion.reduce, disabled: Motion.disabled)
        guard wait > 0 else { overlay.isHidden = true; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.overlayGeneration.isCurrent(g) else { return }
            self.overlay.isHidden = true
        }
    }
    /// How long the dialog layer stays after its card left: the dialog curve's length (pure, --ui-test).
    static func overlayHideDelay(reduce: Bool, disabled: Bool) -> Double {
        disabled ? 0 : (Motion.curve(.dialog, reduce: reduce)?.duration ?? 0)
    }
}
