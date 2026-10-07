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
        guard let l = contentView?.layer else { return }
        l.cornerRadius = toTop ? 28 : 12
        l.maskedCorners = toTop ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    private static func roundedMask(radius r: CGFloat) -> NSImage {
        let edge = 2 * r + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}


/// A menu item that runs a closure.
private final class ClosureItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
