// Design tokens shared by the panel, the island, the dialogs and the lists: one type scale, three text inks, one spacing
// scale, one way to write a duration, and the geometry of the panel's top strip (pure, so --layout-test can check it for
// any notch width).

import SwiftUI

/// The type scale and control sizes, so the same role looks the same everywhere (panel, island, dialogs, lists).
enum UI {
    // Text, by role.
    static let hero = Font.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit()   // focus timer, calendar day
    static let pageTitle = Font.system(size: 16, weight: .bold)            // island "Cocaine", track title
    static let appTitle = Font.system(size: 13, weight: .bold)             // panel header "Cocaine"
    static let groupTitle = Font.system(size: 13, weight: .medium)         // card titles, island sub-heads
    static let itemTitle = Font.system(size: 13, weight: .medium)          // names in lists: agents, alerts, events, devices
    static let title = Font.system(size: 13)                               // row labels
    static let value = Font.system(size: 12)                               // picked values, island body text, list items
    static let detail = Font.system(size: 11)                              // secondary lines, footnotes (never smaller for text)
    static let section = Font.system(size: 11, weight: .medium)            // island column headers ("Agents", "Downloads")
    static let button = Font.system(size: 12, weight: .semibold)           // filled capsule buttons
    static let buttonSecondary = Font.system(size: 12, weight: .medium)    // grey capsules, Focus/Break
    static let metric = Font.system(size: 12, weight: .medium).monospacedDigit()   // percentages, token counts
    static let mono = Font.system(size: 11, design: .monospaced)           // a command line
    // Glyphs (not running text).
    static let icon = Font.system(size: 12, weight: .medium)
    static let tabIcon = Font.system(size: 13, weight: .medium)
    static let chevron = Font.system(size: 10, weight: .semibold)
    static let switchSize = CGSize(width: 38, height: 22)
    /// The icon column of cards, rows and dialogs: wide symbols (battery, badges) still sit centred on it.
    static let iconColumn: CGFloat = 18
    // Text inks on the black panel and island. Nothing that is read is dimmer than `hint` (about 5:1 on black).
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let hint = Color.white.opacity(0.5)
    /// A whole control that can't be used now (once: the control or its container, never both).
    static let disabledOpacity: Double = 0.4
}

/// The spacing scale: every gap and inset is one of these.
enum Space {
    static let xxs: CGFloat = 2        // title ↔ detail inside a row
    static let xs: CGFloat = 4         // value ↔ chevron, tight groups, weekday chips
    static let s: CGFloat = 6          // rows inside a card, buttons in a group, grid gaps
    static let m: CGFloat = 8          // icon ↔ text, card header ↔ first row, caption ↔ content
    static let l: CGFloat = 10         // card padding, gap between cards
    static let frame: CGFloat = 14     // the panel's frame edge
    static let page: CGFloat = 18      // the island page's side margin, media block gutter
    static let gutter: CGFloat = 22    // the island's two-column gutter
    /// The air above and below a settings row's text, so a row with a detail line keeps the same text-to-text rhythm.
    static let rowAir: CGFloat = 3
}

/// Lengths of time as the app writes them, in its language: the panel, the island and the agent list say it the same way.
enum Dur {
    /// "45 min", "2 h", "2 h 30 min" (any length; "∞" for none).
    static func short(minutes: Int) -> String {
        if minutes <= 0 { return "∞" }
        if minutes < 60 { return String(format: agentsL("%d min"), minutes) }
        let h = String(format: agentsL("%d h"), minutes / 60)
        return minutes % 60 == 0 ? h : h + " " + String(format: agentsL("%d min"), minutes % 60)
    }

    /// Time left, in one unit, for the closed island's wing: "2 h", "45 min" (at least 1 min).
    static func left(seconds: Int) -> String {
        guard seconds > 0 else { return "∞" }
        return seconds >= 3600 ? String(format: agentsL("%d h"), seconds / 3600) : String(format: agentsL("%d min"), max(1, seconds / 60))
    }

    /// How long ago, in one unit: "now", "6 min", "2 h".
    static func ago(seconds: Int) -> String {
        let s = max(0, seconds)
        return s < 60 ? agentsL("now") : s < 3600 ? String(format: agentsL("%d min"), s / 60) : String(format: agentsL("%d h"), s / 3600)
    }

    /// A token count, short and in the app's language: "412K", "8,6 Mio." (whatever the locale's compact form is).
    static func count(_ n: Int, locale: Locale) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
    }
}

/// A vertical list that scrolls only when it must. With a `cap` it is exactly as tall as its content up to the cap (a short list
/// leaves no empty space under it, so it never squeezes what comes after); without one it fills the height it is given. When
/// the content is cut, its bottom edge fades out instead of slicing a row in half.
struct FadingScroll<Content: View>: View {
    var cap: CGFloat? = nil
    @ViewBuilder let content: () -> Content
    @StateObject private var size = ScrollSizes()

    var body: some View {
        let cut = size.content > size.viewport + 1 && size.viewport > 0
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { r in Color.clear.onAppear { size.content = r.size.height }
                    .onChange(of: r.size.height) { _, h in size.content = h } })
        }
        .frame(height: cap.map { min($0, size.content) })
        .frame(maxHeight: cap == nil ? .infinity : nil, alignment: .top)
        .background(GeometryReader { r in Color.clear.onAppear { size.viewport = r.size.height }
            .onChange(of: r.size.height) { _, h in size.viewport = h } })
        .mask(VStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, cut ? .clear : .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
        })
    }
}

final class ScrollSizes: ObservableObject {
    @Published var content: CGFloat = 0
    @Published var viewport: CGFloat = 0
}

/// The panel's top strip when it hangs from the notch: tabs left of the notch, the rest right of it, never under it.
/// Each side gets exactly what the notch leaves; cells shrink (down to `minCell`) to fit; nil when they can't.
struct StripLayout: Equatable {
    static let maxCell: CGFloat = 38
    static let minCell: CGFloat = 24            // the smallest hit area we accept
    static let maxHighlight: CGFloat = 30
    static let perSide = 3                      // at most this many cells on either side

    let panelWidth: CGFloat
    let frameInset: CGFloat                     // the panel's frame edge (the strip starts there)
    let notchWidth: CGFloat
    let cell: CGFloat
    let side: CGFloat                           // the width each side of the notch has
    let edgeInset: CGFloat                      // from the frame edge to the first cell (outer side)
    let left: Int
    let right: Int

    var highlight: CGFloat { min(Self.maxHighlight, cell - 2) }
    var notchMinX: CGFloat { (panelWidth - notchWidth) / 2 }
    var notchMaxX: CGFloat { (panelWidth + notchWidth) / 2 }

    /// The cells' frames in panel coordinates (x only): left side from its outer edge, right side ending at its outer edge.
    var leftCells: [ClosedRange<CGFloat>] {
        (0..<left).map { i in let x = frameInset + edgeInset + CGFloat(i) * cell; return x...(x + cell) }
    }
    var rightCells: [ClosedRange<CGFloat>] {
        let end = panelWidth - frameInset - edgeInset
        return (0..<right).map { i in let x = end - CGFloat(right - i) * cell; return x...(x + cell) }
    }

    /// `contentInset`: where the panel's text starts, measured from the frame edge; the outermost highlights line up with it
    /// when there is room.
    static func make(panelWidth: CGFloat, frameInset: CGFloat, contentInset: CGFloat, notchWidth: CGFloat, left: Int, right: Int) -> StripLayout? {
        guard left <= perSide, right <= perSide, left > 0 || right > 0 else { return nil }
        let side = (panelWidth - 2 * frameInset - notchWidth) / 2
        let n = CGFloat(max(left, right))
        let cell = min(maxCell, floor(side / n))
        guard cell >= minCell else { return nil }
        let hl = min(maxHighlight, cell - 2)
        let wanted = max(0, contentInset - (cell - hl) / 2)          // the highlight's outer edge on the content edge
        let inset = min(wanted, max(0, side - n * cell))
        return StripLayout(panelWidth: panelWidth, frameInset: frameInset, notchWidth: notchWidth, cell: cell, side: side,
                           edgeInset: inset, left: left, right: right)
    }

    /// What --layout-test checks: nothing under the notch, everything inside the panel's frame, every cell big enough.
    func problems() -> [String] {
        var out: [String] = []
        for c in leftCells + rightCells {
            if c.upperBound > notchMinX + 0.01 && c.lowerBound < notchMaxX - 0.01 { out.append("cell \(c) is under the notch \(notchMinX)…\(notchMaxX)") }
            if c.lowerBound < frameInset - 0.01 || c.upperBound > panelWidth - frameInset + 0.01 { out.append("cell \(c) is outside the frame") }
            if c.upperBound - c.lowerBound < Self.minCell { out.append("cell \(c) is narrower than \(Self.minCell)") }
        }
        if highlight > cell { out.append("highlight \(highlight) wider than its cell \(cell)") }
        return out
    }
}
