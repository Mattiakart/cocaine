// The shelf's selection, as pure rules: a click, ⇧-click (a range from the anchor), ⌘-click (toggle), ⌘A, the arrow keys in
// the grid (⇧ extends), a rubber band, and keeping it to what is still there. Tested by --shelf-test.

import Foundation

struct ShelfSelection: Equatable {
    var ids: Set<UUID> = []
    /// Where a ⇧-click range starts.
    var anchor: UUID?
    /// The item the keyboard is on (Quick Look starts there; arrows move from it).
    var focus: UUID?

    var isEmpty: Bool { ids.isEmpty }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    enum Direction { case left, right, up, down }

    /// A click on `id`: alone (it only), ⌘ (toggle it), ⇧ (everything from the anchor to it; with ⌘ added to what was selected).
    mutating func click(_ id: UUID, order: [UUID], shift: Bool, command: Bool) {
        guard order.contains(id) else { return }
        if shift, let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            let range = Set(order[min(i, j)...max(i, j)])
            ids = command ? ids.union(range) : range
            focus = id
            return
        }
        if command {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id; focus = id
            return
        }
        ids = [id]; anchor = id; focus = id
    }

    mutating func selectAll(_ order: [UUID]) {
        ids = Set(order)
        if anchor == nil || !order.contains(anchor!) { anchor = order.first }
        if focus == nil || !order.contains(focus!) { focus = order.first }
    }

    mutating func clear() { self = ShelfSelection() }

    /// The arrow keys in a grid of `columns`: the focus moves (at the edges it stays); ⇧ extends from the anchor.
    mutating func move(_ d: Direction, order: [UUID], columns: Int, extend: Bool) {
        guard !order.isEmpty else { return }
        let cols = max(1, columns)
        guard let f = focus, let i = order.firstIndex(of: f) else {
            let first = d == .left || d == .up ? order.last! : order.first!
            ids = [first]; anchor = first; focus = first
            return
        }
        var j = i
        switch d {
        case .left: j = max(0, i - 1)
        case .right: j = min(order.count - 1, i + 1)
        case .up: j = i - cols >= 0 ? i - cols : i
        case .down: j = i + cols < order.count ? i + cols : i
        }
        let to = order[j]
        if extend {
            let a = anchor.flatMap { order.firstIndex(of: $0) } ?? i
            ids = Set(order[min(a, j)...max(a, j)])
            if anchor == nil { anchor = order[a] }
        } else {
            ids = [to]; anchor = to
        }
        focus = to
    }

    /// A rubber band over `hits` (the items it touches now), starting from `base` (what was selected when it began; kept with ⌘ or ⇧).
    mutating func band(_ hits: [UUID], base: Set<UUID>, additive: Bool) {
        ids = additive ? base.symmetricDifference(Set(hits)) : Set(hits)
        if let h = hits.first { anchor = anchor ?? h; focus = hits.last }
    }

    /// Only items that are still there.
    mutating func prune(_ present: Set<UUID>) {
        ids.formIntersection(present)
        if let a = anchor, !present.contains(a) { anchor = nil }
        if let f = focus, !present.contains(f) { focus = ids.first }
    }

    /// The index an item at `index` is dropped to (for the insertion marker), from the pointer's place over a tile: its left
    /// half before it, its right half after it.
    static func insertionIndex(over index: Int, leftHalf: Bool) -> Int { leftHalf ? index : index + 1 }
}
