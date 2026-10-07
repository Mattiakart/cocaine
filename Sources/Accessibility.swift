// Accessibility helpers: VoiceOver announcements, and the system's display options (Increase Contrast, Reduce Transparency,
// Differentiate Without Colour, Reduce Motion) as one observable object the panel and the island redraw with.

import AppKit
import SwiftUI

enum A11y {
    /// Where announcements go. Tests replace it to see what would be said.
    static var post: (String) -> Void = { text in
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Says `text` with VoiceOver (high priority: it interrupts what is being read). Silent without VoiceOver.
    static func announce(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if Thread.isMainThread { post(t) } else { DispatchQueue.main.async { post(t) } }
    }

    /// The layout of a window changed (a dialog or a list appeared in it): VoiceOver looks at it again.
    static func layoutChanged(_ window: NSWindow?) {
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .layoutChanged)
    }

    static var voiceOver: Bool { NSWorkspace.shared.isVoiceOverEnabled }
}

/// The system's accessibility display options, kept current (System Settings → Accessibility → Display).
final class DisplayOptions: ObservableObject {
    static let shared = DisplayOptions()
    @Published private(set) var increaseContrast = false
    @Published private(set) var reduceTransparency = false
    @Published private(set) var differentiateWithoutColor = false
    @Published private(set) var reduceMotion = false
    /// Tests and the render tool: pretend Increase Contrast is on (nil = the system's value).
    var forceContrast: Bool? { didSet { read() } }

    private init() {
        read()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.read() }
    }

    private func read() {
        let w = NSWorkspace.shared
        let c = forceContrast ?? w.accessibilityDisplayShouldIncreaseContrast
        if c != increaseContrast { increaseContrast = c }
        if w.accessibilityDisplayShouldReduceTransparency != reduceTransparency { reduceTransparency = w.accessibilityDisplayShouldReduceTransparency }
        if w.accessibilityDisplayShouldDifferentiateWithoutColor != differentiateWithoutColor {
            differentiateWithoutColor = w.accessibilityDisplayShouldDifferentiateWithoutColor
        }
        if w.accessibilityDisplayShouldReduceMotion != reduceMotion { reduceMotion = w.accessibilityDisplayShouldReduceMotion }
    }

    /// Increase Contrast, read without subscribing (the views that draw with it observe `shared`).
    static var contrast: Bool { shared.increaseContrast }
}
