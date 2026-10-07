// The app's controls, one look per kind: text buttons (CocaineButtonStyle), links to web pages, segmented controls, a
// slider, the value button of a row and the in-app dropdown it opens (PickerCenter / PickerCard). They draw the same in
// the panel, the island and the dialogs, never depend on whether the window is key, and never open a system menu: a
// dropdown is a card in Cocaine's own black surface, under its row, so it can't reach the notch.

import AppKit
import SwiftUI

/// Control metrics and colors (text styles live in UI, Sources/Tokens.swift).
enum CTL {
    static let h: CGFloat = 24                 // every inline control: buttons, fields, segments, chips, value buttons
    static let hDialog: CGFloat = 28           // dialog and island-page actions
    static let radius: CGFloat = 6             // small controls (segments, chips, fields, steppers)
    static let innerRadius: CGFloat = 8        // items inside a card (rows, request cards, tab highlights)
    static let cardRadius: CGFloat = 12        // cards and dialogs
    static let label = Font.system(size: 12, weight: .medium)
    static let labelStrong = Font.system(size: 12, weight: .semibold)
    static let link = Font.system(size: 11)
    static var fill: Color { Color.white.opacity(DisplayOptions.contrast ? 0.18 : 0.10) }
    static var fillHover: Color { Color.white.opacity(DisplayOptions.contrast ? 0.24 : 0.14) }
    static let fillPressed = Color.white.opacity(0.20)
    static var track: Color { Color.white.opacity(DisplayOptions.contrast ? 0.18 : 0.08) }
    static let destructive = Color(red: 0.78, green: 0.18, blue: 0.16)        // a fill: white 12 pt ink on it at 5.4:1 (it was 3.9:1)
    static let destructiveInk = Color(red: 1.0, green: 0.45, blue: 0.42)      // red text on black, over 5:1
    static let onAccentInk = Color.black                                       // 8:1 on the accent; white would be 2.6:1
    static let accent = Color(red: 0.40, green: 0.64, blue: 1.0)               // the island's accent
    static var disabled: Double { UI.disabledOpacity }
}

/// The app's haptic tap, handed in by the app (Haptic in Core.swift, which honours the "Haptic feedback" setting).
enum ControlHaptics { static var tap: () -> Void = {} }

// MARK: - Dimming once

private struct DimmedByContainerKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// A whole group is dimmed and disabled (dimGroup): its controls don't dim themselves again.
    var dimmedByContainer: Bool {
        get { self[DimmedByContainerKey.self] }
        set { self[DimmedByContainerKey.self] = newValue }
    }
}

extension View {
    /// Disables a group of rows and dims it once (text, values and controls alike), never twice.
    func dimGroup(_ off: Bool) -> some View {
        self.disabled(off).allowsHitTesting(!off)
            .opacity(off ? UI.disabledOpacity : 1)
            .transformEnvironment(\.dimmedByContainer) { if off { $0 = true } }
    }
}

final class HoverState: ObservableObject { @Published var on = false }

// MARK: - Text buttons

enum CocaineButtonKind {
    case secondary           // every row button: white .10, white ink
    case primary             // the one main action of a context: accent, black ink
    case destructive         // a row button that destroys or revokes: white .10, red ink
    case destructiveFilled   // a dialog's destructive button: red, white ink
    case plain               // a quiet header action: no fill until hovered
}

/// One capsule button for the whole app: 24 pt in rows, 28 pt in dialogs and island pages.
struct CocaineButtonStyle: ButtonStyle {
    var kind: CocaineButtonKind = .secondary
    var height: CGFloat = CTL.h
    var wide = false
    /// Working (e.g. making the Shortcut): the label stays, a small spinner joins it.
    var busy = false

    func makeBody(configuration: Configuration) -> some View {
        CocaineButtonBody(label: configuration.label, pressed: configuration.isPressed, kind: kind, height: height, wide: wide, busy: busy)
    }
}

private struct CocaineButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let kind: CocaineButtonKind
    let height: CGFloat
    let wide: Bool
    let busy: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.dimmedByContainer) private var dimmedByContainer
    @StateObject private var hover = HoverState()

    private var ink: Color {
        switch kind {
        case .primary: return CTL.onAccentInk
        case .destructive: return CTL.destructiveInk
        case .destructiveFilled: return .white
        case .plain: return hover.on ? .white : UI.secondary
        case .secondary: return .white
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return CTL.accent.opacity(pressed ? 0.8 : hover.on ? 0.92 : 1)
        case .destructiveFilled: return CTL.destructive.opacity(pressed ? 0.8 : hover.on ? 0.92 : 1)
        case .plain: return pressed ? CTL.fillPressed : hover.on ? Color.white.opacity(0.08) : .clear
        case .secondary, .destructive: return pressed ? CTL.fillPressed : hover.on ? CTL.fillHover : CTL.fill
        }
    }

    var body: some View {
        let big = height > CTL.h
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
            label.lineLimit(1)
        }
        .font(big || kind == .primary || kind == .destructiveFilled ? CTL.labelStrong : CTL.label)
        .foregroundStyle(ink)
        .padding(.horizontal, kind == .plain ? 8 : big ? 14 : 12)
        .frame(minWidth: kind == .plain ? nil : 56, maxWidth: wide ? .infinity : nil)
        .frame(height: height)
        .background(Capsule().fill(fill))
        .contentShape(Capsule())
        .scaleEffect(pressed ? 0.97 : 1)
        .opacity(enabled || dimmedByContainer ? 1 : CTL.disabled)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

/// A link to a web page: accent text and an arrow out (never "…", which promises a dialog).
struct LinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))     // a glyph
            }
            .font(CTL.link).foregroundStyle(CTL.accent)
            .frame(minHeight: CTL.h).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
    }
}

// MARK: - Segmented control

/// Children of equal width that fill the width offered; asked for its ideal size, as wide as the widest child times their
/// number (so a row can tell whether it fits beside its title).
struct EqualWidthHStack: SwiftUI.Layout {
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let n = CGFloat(subviews.count)
        guard n > 0 else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let h = proposal.height ?? sizes.map(\.height).max() ?? 0
        if let w = proposal.width, w.isFinite { return CGSize(width: w, height: h) }
        return CGSize(width: (sizes.map(\.width).max() ?? 0) * n + spacing * (n - 1), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = CGFloat(subviews.count)
        guard n > 0 else { return }
        let w = (bounds.width - spacing * (n - 1)) / n
        for (i, s) in subviews.enumerated() {
            s.place(at: CGPoint(x: bounds.minX + CGFloat(i) * (w + spacing), y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
        }
    }
}

/// The one segmented control: equal segments, the selected one in the accent with black ink whether or not the window is
/// key; a value that isn't listed (a custom timer length) selects none.
struct Segments<T: Hashable>: View {
    @Binding var selection: T
    let values: [T]
    var name: String = ""                       // what VoiceOver calls the group
    let label: (T) -> String
    var spoken: (T) -> String? = { _ in nil }   // a better name for VoiceOver ("No limit" for "∞")
    /// A shorter label for when the full one doesn't fit at 11 pt ("30′" for "30 Min."); VoiceOver still says the full one.
    var compact: ((T) -> String)? = nil

    @Environment(\.isEnabled) private var enabled
    @Environment(\.dimmedByContainer) private var dimmedByContainer

    var body: some View {
        EqualWidthHStack(spacing: 2) {
            ForEach(values, id: \.self) { v in
                SegmentCell(title: label(v), short: compact?(v), spoken: spoken(v) ?? label(v), on: v == selection) {
                    guard v != selection else { return }
                    ControlHaptics.tap()
                    selection = v
                }
            }
        }
        .padding(2)
        .frame(height: CTL.h)
        .background(RoundedRectangle(cornerRadius: CTL.radius).fill(CTL.track))
        .overlay(RoundedRectangle(cornerRadius: CTL.radius).strokeBorder(UI.boundary, lineWidth: 1))     // its edge, 3:1 on the card
        .opacity(enabled || dimmedByContainer ? 1 : CTL.disabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}

private struct SegmentCell: View {
    let title: String
    var short: String? = nil
    let spoken: String
    let on: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()

    /// The label as it fits: as written, with a thin space, the short form when there is one, then shrunk — never below 11 pt.
    private var label: some View {
        let last = short ?? title.replacingOccurrences(of: " ", with: "")
        return ViewThatFits(in: .horizontal) {
            Text(title).fixedSize()
            Text(title.replacingOccurrences(of: " ", with: "\u{2009}")).fixedSize()     // a thin space
            Text(last).fixedSize()
            Text(last).minimumScaleFactor(11.0 / 12)
        }
    }

    var body: some View {
        Button(action: action) {
            label.font(CTL.label.monospacedDigit()).lineLimit(1)
                .foregroundStyle(on ? CTL.onAccentInk : Color.white.opacity(DisplayOptions.contrast ? 0.95 : 0.78))
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: CTL.radius - 2).fill(on ? CTL.accent : hover.on ? Color.white.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help(spoken == title ? "" : spoken)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Slider

/// The one slider: a 4 pt track, a 14 pt knob, a 24 pt target; drag or click anywhere on it. `live` false: only the end of
/// a drag counts (seeking music), and the knob follows the finger meanwhile.
struct CocaineSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 1                        // for VoiceOver's increment/decrement
    var live = true
    let name: String
    let valueText: String
    let set: (Double) -> Void
    @StateObject private var drag = SliderDrag()
    @Environment(\.isEnabled) private var enabled
    @Environment(\.dimmedByContainer) private var dimmedByContainer

    var body: some View {
        GeometryReader { r in
            let knob: CGFloat = 14, w = max(1, r.size.width - knob)
            let shown = drag.value ?? value
            let f = CGFloat(min(1, max(0, (shown - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound))))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15)).frame(height: 4)
                Capsule().fill(Color.white.opacity(0.85)).frame(width: w * f + knob / 2, height: 4)
                Circle().fill(.white).shadow(color: .black.opacity(0.3), radius: 1.2, y: 0.6)
                    .frame(width: knob, height: knob).offset(x: w * f)
            }
            .frame(height: CTL.h)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let v = at(g.location.x - knob / 2, w)
                    if live { set(v) } else { drag.value = v }
                }
                .onEnded { g in
                    let v = at(g.location.x - knob / 2, w)
                    drag.value = nil
                    set(v)
                })
        }
        .frame(height: CTL.h)
        .opacity(enabled || dimmedByContainer ? 1 : CTL.disabled)
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: set(min(range.upperBound, value + step))
            case .decrement: set(max(range.lowerBound, value - step))
            @unknown default: break
            }
        }
    }

    private func at(_ x: CGFloat, _ w: CGFloat) -> Double {
        range.lowerBound + Double(min(1, max(0, x / w))) * (range.upperBound - range.lowerBound)
    }
}

final class SliderDrag: ObservableObject { @Published var value: Double? }

// MARK: - The value button of a row, and its dropdown

/// One choice in a dropdown.
struct PickerItem: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String? = nil           // an SF Symbol…
    var image: NSImage? = nil           // …an app's icon…
    var emoji: String? = nil            // …or a flag
    var section = 0                     // 1: listed under the second caption ("Open now")
    var destructive = false             // an action that destroys: red ink
}

enum PickerMode: Equatable { case single(String?), multi, action }

struct PickerSpec {
    var id: String                      // the value button that opened it
    var title: String
    var items: [PickerItem]
    var mode: PickerMode
    var selected: Set<String> = []      // multi: what is chosen now
    var sectionTitle: String? = nil     // the caption above section 1
    var surface = DialogSurface.panel
    /// All / None above a multiple choice of more than 4.
    var allNone: Bool { mode == .multi && items.count > 4 }
    /// A search field above more than 10 items.
    var search: Bool { items.count > 10 }
    static let visibleRows = 8          // then it scrolls
}

/// The dropdown's rules, without any UI: order, filtering, the keyboard, what a pick does.
enum PickerLogic {
    struct State {
        var spec: PickerSpec
        var selected: Set<String>
        /// The rows' order, fixed while the dropdown is open: ticking a box never moves rows under the pointer.
        var order: [String]
        /// The ids listed under the second caption (decided on opening, like the order).
        var later: Set<String>
        var query = ""
        var highlight: String?
        var typed = ""                  // type-to-jump buffer (no search field)
        var typedAt = Date.distantPast
    }

    enum Key: Equatable { case up, down, returnKey, space, escape, char(String) }
    enum Outcome: Equatable {
        case none
        case pass                       // not ours: the search field types it
        case close                      // nothing picked
        case pick(String)               // single choice or action: commit and close
        case toggled(Set<String>)       // multiple choice: the new set, the dropdown stays
    }

    static func byTitle(_ a: PickerItem, _ b: PickerItem) -> Bool { a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }

    /// Multiple choice: the chosen ones first, then the rest of the list, then section 1 ("Open now"), each alphabetical.
    /// Otherwise the order given.
    static func open(_ spec: PickerSpec) -> State {
        let sel: Set<String>
        if case .single(let s) = spec.mode { sel = s.map { [$0] } ?? [] } else { sel = spec.mode == .multi ? spec.selected : [] }
        var order = spec.items.map(\.id), later = Set<String>()
        if spec.mode == .multi {
            let chosen = spec.items.filter { sel.contains($0.id) }.sorted(by: byTitle)
            let rest = spec.items.filter { !sel.contains($0.id) && $0.section == 0 }.sorted(by: byTitle)
            let open = spec.items.filter { !sel.contains($0.id) && $0.section != 0 }.sorted(by: byTitle)
            order = (chosen + rest + open).map(\.id)
            later = Set(open.map(\.id))
        } else {
            later = Set(spec.items.filter { $0.section != 0 }.map(\.id))
        }
        var st = State(spec: spec, selected: sel, order: order, later: later)
        if case .single(let s?) = spec.mode, order.contains(s) { st.highlight = s } else { st.highlight = order.first }
        return st
    }

    static func matches(_ title: String, _ q: String) -> Bool {
        let t = q.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || title.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func visible(_ st: State) -> [PickerItem] {
        let byID = Dictionary(st.spec.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return st.order.compactMap { byID[$0] }.filter { matches($0.title, st.query) }
    }

    /// The row the second caption goes above (the first visible one of section 1), if any.
    static func captionBefore(_ st: State) -> String? { visible(st).first { st.later.contains($0.id) }?.id }

    static func setQuery(_ st: inout State, _ q: String) {
        st.query = q
        let v = visible(st)
        if !v.contains(where: { $0.id == st.highlight }) { st.highlight = v.first?.id }
    }

    /// Every visible row is chosen (the header then offers None).
    static func allChosen(_ st: State) -> Bool {
        let v = visible(st)
        return !v.isEmpty && v.allSatisfy { st.selected.contains($0.id) }
    }

    static func activate(_ st: inout State, _ id: String) -> Outcome {
        guard st.spec.items.contains(where: { $0.id == id }) else { return .none }
        st.highlight = id
        switch st.spec.mode {
        case .single, .action: return .pick(id)
        case .multi:
            if st.selected.contains(id) { st.selected.remove(id) } else { st.selected.insert(id) }
            return .toggled(st.selected)
        }
    }

    /// All / None over what is visible (a search narrows it).
    static func allNone(_ st: inout State) -> Outcome {
        guard st.spec.mode == .multi else { return .none }
        let ids = Set(visible(st).map(\.id))
        if allChosen(st) { st.selected.subtract(ids) } else { st.selected.formUnion(ids) }
        return .toggled(st.selected)
    }

    static func key(_ st: inout State, _ k: Key, now: Date = Date()) -> Outcome {
        let v = visible(st)
        let i = v.firstIndex { $0.id == st.highlight }
        switch k {
        case .escape: return .close
        case .down:
            guard !v.isEmpty else { return .none }
            st.highlight = v[i.map { min(v.count - 1, $0 + 1) } ?? 0].id          // no wrapping
            return .none
        case .up:
            guard !v.isEmpty else { return .none }
            st.highlight = v[i.map { max(0, $0 - 1) } ?? v.count - 1].id
            return .none
        case .returnKey:
            guard let h = st.highlight, v.contains(where: { $0.id == h }) else { return .none }
            return activate(&st, h)
        case .space:
            if st.spec.search { return .pass }                                     // a space in the search
            guard let h = st.highlight else { return .none }
            return activate(&st, h)
        case .char(let c):
            if st.spec.search { return .pass }
            // Type to jump: the first row starting with what was typed in the last second.
            st.typed = now.timeIntervalSince(st.typedAt) > 1 ? c : st.typed + c
            st.typedAt = now
            if let hit = v.first(where: { $0.title.lowercased().hasPrefix(st.typed.lowercased()) }) { st.highlight = hit.id }
            return .none
        }
    }
}

/// The dropdown on screen (one at a time) and the value buttons that can open one.
final class PickerCenter: ObservableObject {
    static let shared = PickerCenter()
    /// The coordinate space value buttons and the dropdown layer share (the panel's whole page).
    static let space = "cocaine.picker"

    @Published private(set) var state: PickerLogic.State?
    @Published private(set) var anchor: CGRect = .zero           // the value button, in `space`
    @Published var cardHeight: CGFloat = 0
    private var onPick: ((String) -> Void)?
    private var onChange: ((Set<String>) -> Void)?
    private var revealed = false
    /// Scrolls the panel so the whole dropdown is in view (set by the app; the panel's page may be scrolled).
    var reveal: (CGRect) -> Void = { _ in }
    /// Opens the dropdown of a value button by its id, with its current frame (render tool, tests).
    var openers: [String: () -> Void] = [:]

    var isOpen: Bool { state != nil }
    func isOpen(on s: DialogSurface) -> Bool { state?.spec.surface == s }

    var query: String {
        get { state?.query ?? "" }
        set { if state != nil { PickerLogic.setQuery(&state!, newValue) } }
    }

    func present(_ spec: PickerSpec, anchor: CGRect, onPick: ((String) -> Void)? = nil, onChange: ((Set<String>) -> Void)? = nil) {
        if state?.spec.id == spec.id { close(); return }               // its button again: closes it
        close()
        self.anchor = anchor
        self.onPick = onPick; self.onChange = onChange
        cardHeight = 0; revealed = false
        state = PickerLogic.open(spec)
        A11y.announce(spec.title + (state?.highlight.flatMap { h in spec.items.first { $0.id == h }?.title }.map { ", " + $0 } ?? ""))
    }

    func close() {
        guard state != nil else { return }
        state = nil; onPick = nil; onChange = nil
    }

    func surfaceClosed(_ s: DialogSurface) { if isOpen(on: s) { close() } }

    func hover(_ id: String) { if state != nil, state!.highlight != id { state!.highlight = id } }

    func tap(_ id: String) {
        guard state != nil else { return }
        apply(PickerLogic.activate(&state!, id))
    }

    func toggleAll() {
        guard state != nil else { return }
        apply(PickerLogic.allNone(&state!))
    }

    @discardableResult
    func handle(_ k: PickerLogic.Key) -> Bool {
        guard state != nil else { return false }
        let before = state!.highlight
        let o = PickerLogic.key(&state!, k)
        if o == .pass { return false }
        // VoiceOver can't follow the highlight by itself: say the row the arrows (or typing) moved to.
        if o == .none, let st = state, st.highlight != before, let row = st.spec.items.first(where: { $0.id == st.highlight }) {
            let picked = st.selected.contains(row.id)
            A11y.announce(row.title + (st.spec.mode == .multi ? ", " + (picked ? L10nControls.ticked : L10nControls.unticked) : ""))
        }
        apply(o)
        return true
    }

    /// Arrows, Return, Space, Esc and typing for the dropdown on screen; true when the key was used.
    func handleKey(_ e: NSEvent) -> Bool {
        guard state != nil else { return false }
        if let tv = e.window?.firstResponder as? NSTextView, tv.hasMarkedText() { return false }      // an input method composing
        switch e.keyCode {
        case 125: return handle(.down)
        case 126: return handle(.up)
        case 36, 76: return handle(.returnKey)
        case 53: return handle(.escape)
        case 49: return handle(.space)
        default:
            guard let c = e.charactersIgnoringModifiers, !c.isEmpty, e.modifierFlags.intersection([.command, .control]).isEmpty,
                  c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
            return handle(.char(c))
        }
    }

    /// The card's height is known: make sure it is in view (once per opening).
    func measured(_ h: CGFloat) {
        guard abs(cardHeight - h) > 0.5 else { return }
        cardHeight = h
        guard !revealed, h > 0 else { return }
        revealed = true
        let r = CGRect(x: 0, y: anchor.minY, width: 1, height: anchor.height + 4 + h + 10)
        DispatchQueue.main.async { self.reveal(r) }
    }

    private func apply(_ o: PickerLogic.Outcome) {
        switch o {
        case .pick(let id):
            ControlHaptics.tap()
            let f = onPick
            close()
            f?(id)
        case .toggled(let set):
            ControlHaptics.tap()
            onChange?(set)
        case .close: close()
        case .none, .pass: break
        }
    }
}

/// Where a value button is, for its dropdown (not published: it changes as the page scrolls and lays out).
final class FrameBox: ObservableObject { var rect: CGRect = .zero }

/// A row's value, flush with the content edge, and a chevron; a click opens its dropdown under the row.
struct ValueButton: View {
    let id: String
    let title: String                    // the row's title (VoiceOver)
    let value: String
    var maxWidth: CGFloat = 190
    let spec: () -> PickerSpec
    var onPick: ((String) -> Void)? = nil
    var onChange: ((Set<String>) -> Void)? = nil
    @ObservedObject private var center = PickerCenter.shared
    @StateObject private var box = FrameBox()
    @StateObject private var hover = HoverState()

    private func open() { center.present(spec(), anchor: box.rect, onPick: onPick, onChange: onChange) }

    var body: some View {
        let isOpen = center.state?.spec.id == id
        Button { open() } label: {
            HStack(spacing: Space.xs) {
                Text(value).font(UI.value).foregroundStyle(Color.white.opacity(0.88)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))     // a glyph
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .frame(maxWidth: maxWidth, alignment: .trailing)
            .frame(height: CTL.h)
            .padding(.horizontal, 6)
            .background(Capsule().fill(Color.white.opacity(isOpen ? 0.12 : hover.on ? 0.07 : 0)))
            .contentShape(Capsule())
            .padding(.trailing, -6)                     // the text ends on the content edge; the hover pill reaches past it
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .background(GeometryReader { r in
            Color.clear
                .onAppear { box.rect = r.frame(in: .named(PickerCenter.space)); center.openers[id] = { open() } }
                .onChange(of: r.frame(in: .named(PickerCenter.space))) { _, f in box.rect = f }
        })
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(L10nControls.opensList)
    }
}

/// The same value-and-chevron look for a list asked in the island (where the list is the dialogs' card at the page's top).
struct IslandValueButton: View {
    let title: String
    let value: String
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Text(value).font(UI.value).foregroundStyle(Color.white.opacity(0.88)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.white.opacity(0.45))   // a glyph
            }
            .frame(height: CTL.h).padding(.horizontal, 6)
            .background(Capsule().fill(Color.white.opacity(hover.on ? 0.07 : 0)))
            .contentShape(Capsule())
            .padding(.horizontal, -6)
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(L10nControls.opensList)
    }
}

/// The few words the controls say themselves, looked up by the app (it sets them in the app's language).
enum L10nControls {
    static var opensList = "Opens a list"
    static var all = "All"
    static var none = "None"
    static var selected = "%d selected"
    static var search = "Search"
    static var openNow = "Open now"
    static var highlighted = "Highlighted"
    static var ticked = "ticked"
    static var unticked = "not ticked"
}

// MARK: - Rows: shared by dialog choices and dropdowns

/// One row of a list in a card: the same look in a dialog's choices and in a dropdown (28 pt, radius 8, a 16 pt icon slot).
struct ChoiceRow: View {
    enum Leading { case none, symbol(String), image(NSImage), emoji(String), checkbox(Bool, NSImage?) }
    let title: String
    var leading: Leading = .none
    var checked = false                  // single choice: an accent check mark on the right
    var showsCheckColumn = false
    /// VoiceOver says "selected" for the checked row of a choice (not for action rows, which have nothing to be selected).
    var selectable = true
    var highlighted = false
    var destructive = false
    var lines = 1
    var font: Font = UI.title
    var iconFont: Font = UI.icon
    let action: () -> Void
    var hover: (Bool) -> Void = { _ in }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                lead
                Text(title).font(font).foregroundStyle(destructive ? CTL.destructiveInk : UI.primary)
                    .lineLimit(lines).truncationMode(.middle).fixedSize(horizontal: false, vertical: lines > 1)
                Spacer(minLength: Space.xs)
                if showsCheckColumn {
                    Image(systemName: "checkmark").font(iconFont).foregroundStyle(CTL.accent).opacity(checked ? 1 : 0)
                }
            }
            .padding(.horizontal, Space.m).frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: CTL.innerRadius).fill(Color.white.opacity(highlighted ? 0.10 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        .accessibilityAddTraits(checked && selectable ? .isSelected : [])
        .accessibilityValue(highlighted && !checked ? L10nControls.highlighted : "")
    }

    @ViewBuilder private var lead: some View {
        switch leading {
        case .none: EmptyView()
        case .symbol(let s): Image(systemName: s).font(iconFont).foregroundStyle(destructive ? CTL.destructiveInk : CTL.accent).frame(width: 16, height: 16)
        case .image(let i): Image(nsImage: i).resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
        case .emoji(let e): Text(e).font(.system(size: 13)).frame(width: 16, height: 16)
        case .checkbox(let on, let icon):
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(on ? CTL.accent : Color.clear)
                RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Color.clear : Color.white.opacity(0.3), lineWidth: 1)
                if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(CTL.onAccentInk) }   // a glyph
            }
            .frame(width: 16, height: 16)
            if let icon { Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16) }
        }
    }
}

// MARK: - The dropdown card

/// The dropdown: the dialogs' card, as wide as the panel, opening under its row.
struct PickerCard: View {
    @ObservedObject var center: PickerCenter

    var body: some View {
        if let st = center.state { card(st) }
    }

    private func card(_ st: PickerLogic.State) -> some View {
        let rows = PickerLogic.visible(st)
        let caption = PickerLogic.captionBefore(st)
        let multi = st.spec.mode == .multi
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                Text(st.spec.title).font(UI.groupTitle).lineLimit(1)
                if multi {
                    Text(String(format: L10nControls.selected, st.selected.count)).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                }
                Spacer(minLength: Space.m)
                if st.spec.allNone {
                    Button(PickerLogic.allChosen(st) ? L10nControls.none : L10nControls.all) { center.toggleAll() }
                        .buttonStyle(CocaineButtonStyle(kind: .plain))
                }
            }
            .frame(minHeight: 22)
            if st.spec.search {
                HStack(spacing: Space.s) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(UI.hint)      // a glyph
                    DialogTextField(text: Binding(get: { center.query }, set: { center.query = $0 }), placeholder: L10nControls.search)
                }
                .padding(.horizontal, Space.m).frame(height: CTL.h)
                .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(0.08)))
            }
            let list = VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { item in
                    if item.id == caption, let t = st.spec.sectionTitle {
                        VStack(alignment: .leading, spacing: 4) {
                            if item.id != rows.first?.id { Divider().padding(.vertical, 2) }
                            Text(t).font(UI.detail).foregroundStyle(UI.hint).padding(.horizontal, Space.m)
                        }
                    }
                    row(item, st).id(item.id)
                }
                if rows.isEmpty { Text("—").font(UI.value).foregroundStyle(UI.hint).padding(.horizontal, Space.m).frame(height: 28) }
            }
            if rows.count > PickerSpec.visibleRows {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) { list.padding(.trailing, 6) }
                        .frame(height: CGFloat(PickerSpec.visibleRows) * 28 + CGFloat(PickerSpec.visibleRows - 1) * 4)
                        .onChange(of: st.highlight) { _, h in if let h { proxy.scrollTo(h) } }
                        .onAppear { if let h = st.highlight { proxy.scrollTo(h, anchor: .center) } }
                }
            } else {
                list
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CTL.cardRadius).fill(Color.white.opacity(0.07)))
        .background(RoundedRectangle(cornerRadius: CTL.cardRadius).fill(Color.black))            // opaque over the page
        .overlay(RoundedRectangle(cornerRadius: CTL.cardRadius).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: CTL.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(st.spec.title)
    }

    private func row(_ item: PickerItem, _ st: PickerLogic.State) -> some View {
        let lead: ChoiceRow.Leading
        if st.spec.mode == .multi { lead = .checkbox(st.selected.contains(item.id), item.image) }
        else if let i = item.image { lead = .image(i) }
        else if let e = item.emoji { lead = .emoji(e) }
        else if let s = item.symbol { lead = .symbol(s) }
        else { lead = .none }
        var checked = false
        if case .single(let s) = st.spec.mode { checked = s == item.id }
        if st.spec.mode == .multi { checked = st.selected.contains(item.id) }
        return ChoiceRow(title: item.title, leading: lead, checked: checked, showsCheckColumn: { if case .single = st.spec.mode { return true }; return false }(),
                         highlighted: st.highlight == item.id, destructive: item.destructive,
                         action: { center.tap(item.id) }, hover: { inside in if inside { center.hover(item.id) } })
            .frame(height: 28)
    }
}

/// The page-wide layer that holds a dropdown: a click anywhere outside the card closes it; the card hangs `gap` under its
/// value button, `x` from the left, `width` wide (the panel's frame edge to frame edge). Nothing is dimmed.
struct PickerLayer: View {
    @ObservedObject var center: PickerCenter
    let surface: DialogSurface
    let x: CGFloat
    let width: CGFloat
    static let gap: CGFloat = 4

    var body: some View {
        if center.isOpen(on: surface) {
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { center.close() }
                PickerCard(center: center)
                    .frame(width: width)
                    .background(GeometryReader { r in Color.clear.preference(key: PickerCardHeight.self, value: r.size.height) })
                    .padding(.leading, x)
                    .padding(.top, Self.top(center.anchor))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onPreferenceChange(PickerCardHeight.self) { h in center.measured(h) }
        }
    }

    /// The card's top: under its row, always (never above it, so never up into the notch).
    static func top(_ anchor: CGRect) -> CGFloat { anchor.maxY + gap }
    /// How tall the page must be to hold the card.
    static func reserved(_ anchor: CGRect, card: CGFloat, bottom: CGFloat) -> CGFloat { top(anchor) + card + bottom }
}

private struct PickerCardHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Tests (part of --selftest and --dialogs-test)

enum ControlTests {
    static func pure(_ check: (String, Bool) -> Void) {
        func items(_ names: [String], section: Int = 0) -> [PickerItem] { names.map { PickerItem(id: $0, title: $0, section: section) } }

        // Single choice.
        let lang = PickerSpec(id: "lang", title: "Language", items: items(["English", "Italiano", "Deutsch"]), mode: .single("Italiano"))
        var st = PickerLogic.open(lang)
        check("picker: a single choice keeps its order and starts on the chosen row", st.order == ["English", "Italiano", "Deutsch"] && st.highlight == "Italiano")
        _ = PickerLogic.key(&st, .down)
        check("picker: ↓ moves to the next row", st.highlight == "Deutsch")
        _ = PickerLogic.key(&st, .down)
        check("picker: …and doesn't wrap at the end", st.highlight == "Deutsch")
        _ = PickerLogic.key(&st, .up); _ = PickerLogic.key(&st, .up); _ = PickerLogic.key(&st, .up)
        check("picker: ↑ stops at the first row", st.highlight == "English")
        check("picker: Return picks the highlighted row (and closes)", PickerLogic.key(&st, .returnKey) == .pick("English"))
        check("picker: Esc closes without picking", PickerLogic.key(&st, .escape) == .close)
        check("picker: a click on a row picks it", PickerLogic.activate(&st, "Deutsch") == .pick("Deutsch"))
        check("picker: no search field and no All/None for 3 rows", !lang.search && !lang.allNone)
        var jump = PickerLogic.open(lang)
        let t0 = Date()
        _ = PickerLogic.key(&jump, .char("d"), now: t0)
        check("picker: typing jumps to the first row that starts with it", jump.highlight == "Deutsch")
        _ = PickerLogic.key(&jump, .char("e"), now: t0.addingTimeInterval(2))
        check("picker: …a pause starts a new word", jump.highlight == "English")
        check("picker: Space picks too when there is no search field", PickerLogic.key(&jump, .space) == .pick("English"))

        // Multiple choice: chosen first, then the list, then "Open now"; the order doesn't move while it's open.
        var apps = items(["Teams", "Slack", "zoom.us"]) + items(["Xcode", "Mail", "Final Cut Pro"], section: 1)
        let multi = PickerSpec(id: "apps", title: "Apps", items: apps, mode: .multi, selected: ["Slack", "Xcode"], sectionTitle: "Open now")
        var m = PickerLogic.open(multi)
        check("picker: multiple choice lists the chosen first (A–Z), then the rest, then Open now (A–Z)",
              m.order == ["Slack", "Xcode", "Teams", "zoom.us", "Final Cut Pro", "Mail"])
        check("picker: the Open now caption goes above its first row", PickerLogic.captionBefore(m) == "Final Cut Pro")
        check("picker: ticking a box keeps the list open and reports the new set", PickerLogic.activate(&m, "Mail") == .toggled(["Slack", "Xcode", "Mail"]))
        check("picker: …and doesn't move any row", m.order == ["Slack", "Xcode", "Teams", "zoom.us", "Final Cut Pro", "Mail"])
        check("picker: unticking removes it", PickerLogic.activate(&m, "Slack") == .toggled(["Xcode", "Mail"]))
        check("picker: All/None from 5 items", multi.allNone)
        check("picker: All ticks every row", PickerLogic.allNone(&m) == .toggled(Set(multi.items.map(\.id))) && PickerLogic.allChosen(m))
        check("picker: …then None unticks every row", PickerLogic.allNone(&m) == .toggled([]))
        m.highlight = "Teams"
        check("picker: Space toggles the highlighted row", PickerLogic.key(&m, .space) == .toggled(["Teams"]))

        // Search: more than 10 items; filtering, and All/None only over what is found.
        apps = items((1...12).map { "App \($0)" }) + items(["Xcode"], section: 1)
        var s = PickerLogic.open(PickerSpec(id: "many", title: "Programs", items: apps, mode: .multi, sectionTitle: "Open now"))
        check("picker: a search field from 11 items", s.spec.search)
        check("picker: with a search field, typing and Space go to the field", PickerLogic.key(&s, .char("x")) == .pass && PickerLogic.key(&s, .space) == .pass)
        PickerLogic.setQuery(&s, "xco")
        check("picker: the search filters (any case) and the highlight follows", PickerLogic.visible(s).map(\.id) == ["Xcode"] && s.highlight == "Xcode")
        check("picker: All over a search ticks only what is found", PickerLogic.allNone(&s) == .toggled(["Xcode"]))
        PickerLogic.setQuery(&s, "zzz")
        check("picker: nothing found: Return does nothing", PickerLogic.visible(s).isEmpty && PickerLogic.key(&s, .returnKey) == .none)
        PickerLogic.setQuery(&s, "café")
        check("picker: accents don't matter", PickerLogic.matches("Cafe Bar", "café"))

        // Actions: a click is the answer; a destructive row keeps its flag.
        let act = PickerSpec(id: "pause", title: "Pause", items: [PickerItem(id: "30", title: "30 min"), PickerItem(id: "del", title: "Delete everything…", destructive: true)], mode: .action)
        var a = PickerLogic.open(act)
        check("picker: an action row is the answer (and closes)", PickerLogic.activate(&a, "del") == .pick("del") && a.spec.items[1].destructive)
        check("picker: an id that isn't listed does nothing", PickerLogic.activate(&a, "nope") == .none)

        // The center: one at a time, its own button closes it, a pick runs once.
        let c = PickerCenter()
        var picked: [String] = []
        c.present(lang, anchor: CGRect(x: 0, y: 100, width: 50, height: 24), onPick: { picked.append($0) })
        check("picker: the card hangs under its button (never above it)", PickerLayer.top(c.anchor) == 128 && PickerLayer.top(c.anchor) > c.anchor.maxY)
        c.tap("Deutsch"); c.tap("English")
        check("picker: a pick runs once and closes", picked == ["Deutsch"] && !c.isOpen)
        c.present(lang, anchor: .zero); c.present(lang, anchor: .zero)
        check("picker: its own button again closes it", !c.isOpen)
        c.present(lang, anchor: .zero); c.present(multi, anchor: .zero)
        check("picker: another button replaces it", c.state?.spec.id == "apps")
        c.surfaceClosed(.island)
        check("picker: the island closing leaves a panel dropdown alone", c.isOpen)
        c.surfaceClosed(.panel)
        check("picker: the panel closing closes it", !c.isOpen)
        check("picker: keys with nothing open aren't taken", !c.handle(.down))
    }
}
