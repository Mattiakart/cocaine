// How the open island's content grows with it (Settings → Island → Notch: Large, Extra large, or the sliders). Every page was
// drawn for the standard 640 × 214 island; a bigger island gives every module a bigger box (ScreenLayout.resolve, both
// columns), and what has a fixed size inside it (the camera's picture, the screenshots, the media tiles, the monitors' sliders,
// the focus column) grows with the room it gets instead of staying the old size in a bigger box. Text stays on the app's one
// type scale (design rule); lists show more rows, columns get wider. Pure (--island-review-test).

import AppKit
import SwiftUI

enum IslandScale {
    /// The island every page was laid out for.
    static let standardOpen = CGSize(width: 640, height: 214)

    /// How much bigger the open island is: the smaller of its two ratios to the standard one (so nothing grown by it can
    /// overflow either way), never under 1.
    static func factor(open: CGSize) -> CGFloat {
        guard open.width.isFinite, open.height.isFinite, open.width > 0, open.height > 0 else { return 1 }
        return max(1, min(open.width / standardOpen.width, open.height / standardOpen.height))
    }
    /// …for the island as set now.
    static var factor: CGFloat { factor(open: Island.openSize) }

    /// The hero numbers (the focus timer): UI.hero, grown with the module (display figures, not running text).
    static func hero(_ f: CGFloat) -> Font {
        f <= 1 ? UI.hero : .system(size: grow(46, f), weight: .semibold, design: .rounded).monospacedDigit()
    }

    /// A fixed measure grown by a factor, on whole points.
    static func grow(_ v: CGFloat, _ f: CGFloat) -> CGFloat { (v * max(1, f)).rounded() }

    /// The page's content box of the standard island, for a strip (notch) of this height: what ScreenLayout.contentSize gives at 640 × 214.
    static func standardBox(stripHeight: CGFloat) -> CGSize {
        CGSize(width: standardOpen.width - 28 - 2 * Space.page, height: standardOpen.height - stripHeight - 8 - 16)
    }

    /// The narrow column (250 pt in the standard island) in a page box this wide: it grows in step with the page, so both
    /// columns of Home, Files and Status use a bigger island (not only the wide one).
    static func narrowColumn(boxWidth: CGFloat, standardWidth: CGFloat) -> CGFloat {
        guard standardWidth > 0, boxWidth > standardWidth else { return ScreenLayout.narrowColumn }
        return (ScreenLayout.narrowColumn * boxWidth / standardWidth).rounded()
    }

    /// A picture of fixed shape (`base`, as drawn in a box of `standard` size) in a box of `box` size: it takes all of the
    /// extra height, keeps its shape, and leaves at least `keepWidth` of the box's width for what is beside it. Never smaller
    /// than `base`, never larger than the box.
    static func fill(base: CGSize, standard: CGSize, box: CGSize, keepWidth: CGFloat) -> CGSize {
        guard base.width > 0, base.height > 0 else { return base }
        var h = min(box.height, base.height + max(0, box.height - standard.height))
        var w = h * base.width / base.height
        let maxW = max(base.width, box.width - keepWidth)
        if w > maxW { w = maxW; h = w * base.height / base.width }
        return CGSize(width: max(base.width, w.rounded()), height: max(base.height, h.rounded()))
    }
}

extension ModuleBox {
    /// Its box in the standard island (its own size when not known: then nothing grows).
    var standardSize: CGSize { standard.width > 0 && standard.height > 0 ? standard : CGSize(width: width, height: height) }
    /// The module's growth over its box in the standard island (1 there).
    var factor: CGFloat {
        let s = standardSize
        return max(1, min(width / s.width, height / s.height))
    }
    /// How much taller and wider its box is than in the standard island.
    var extraHeight: CGFloat { max(0, height - standardSize.height) }
    var extraWidth: CGFloat { max(0, width - standardSize.width) }
}
