// The "Screens" card of the panel's Island tab: which island screens show and in what order (drag, or the arrow buttons),
// the start screen, each screen's modules (add, remove, order, column, size), a live miniature of the island, what doesn't
// fit, and Restore defaults. Every change goes through ScreenLayout's rules (ScreenLayout.swift) and shows at once on every
// island. Strings: Localization/<lang>.lproj/Screens.strings.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the card is doing: the screen whose modules are open, the row being dragged.
final class ScreensEditorState: ObservableObject {
    static let shared = ScreensEditorState()
    @Published var editing: String?
    var dragging: String?
}

struct ScreensEditor: View {
    @ObservedObject var store = ScreenLayoutStore.shared
    @ObservedObject var state = ScreensEditorState.shared
    @ObservedObject var display = DisplayOptions.shared

    private var layout: ScreenLayout { store.layout }
    private var external: Bool { Island.external }

    static func screenTitle(_ id: String) -> String { ModuleCatalog.screen(id).map { L($0.title) } ?? id }
    static func moduleTitle(_ id: String) -> String { ModuleCatalog.module(id).map { L($0.title) } ?? id }
    static func sizeName(_ s: ModuleSize) -> String { s == .s ? L("Small") : s == .m ? L("Medium") : L("Large") }

    /// Every change: through the layout's rules, with the editor's motion.
    private func edit(_ change: @escaping (inout ScreenLayout) -> Void) {
        withAnimation(ScreensMotion.edit) { store.update(change) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ScreensPreview(layout: layout, selected: previewScreen, external: external)
                .padding(.bottom, Space.xs)
            startRow
            Text(L("Drag to reorder, or use the arrows")).font(UI.detail).foregroundStyle(UI.secondary)
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(layout.screens) { s in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        screenRow(s)
                        if state.editing == s.id {
                            modulesEditor(s).transition(ScreensMotion.rowTransition)
                        }
                    }
                }
            }
            HStack(spacing: Space.m) {
                Text(L("The island keeps its size: what doesn't fit is drawn smaller or left out, never cut."))
                    .font(UI.detail).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.m)
                Button(L("Restore defaults")) { confirmRestore() }.buttonStyle(CocaineButtonStyle())
                    .disabled(store.isStandard)
            }
            .padding(.top, Space.xs)
        }
    }

    /// The preview shows the screen being edited, else the start screen, else the first one shown.
    private var previewScreen: String {
        if let e = state.editing { return e }
        return layout.startScreen(current: nil, external: external) ?? "home"
    }

    // MARK: start screen

    private var startSpec: PickerSpec {
        let items = [PickerItem(id: ScreenLayout.lastUsed, title: L("Last used"), symbol: "clock.arrow.circlepath")]
            + layout.visibleScreens(external: true).compactMap { s in ModuleCatalog.screen(s.id).map { PickerItem(id: s.id, title: L($0.title), symbol: $0.icon) } }
        return PickerSpec(id: "screensStart", title: L("Start screen"), items: items, mode: .single(layout.start))
    }

    private var startRow: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(L("Start screen")).font(UI.title)
                Text(L("The island opens on it")).font(UI.detail).foregroundStyle(UI.secondary)
            }
            Spacer(minLength: Space.m)
            ValueButton(id: "screensStart", title: L("Start screen"),
                        value: layout.start == ScreenLayout.lastUsed ? L("Last used") : Self.screenTitle(layout.start),
                        spec: { startSpec }, onPick: { id in edit { $0.setStart(id) } })
        }
        .frame(minHeight: 22)
    }

    // MARK: a screen's row

    private func screenRow(_ s: ScreenConfig) -> some View {
        let spec = ModuleCatalog.screen(s.id)
        let title = Self.screenTitle(s.id)
        let index = layout.screens.firstIndex { $0.id == s.id } ?? 0
        let open = state.editing == s.id
        let issues = ScreenLayout.resolve(s, in: ScreenLayout.contentSize(stripHeight: 32)).issues.filter { $0 != .empty }
        let canHide = layout.canHide(s.id)
        return HStack(spacing: Space.s) {
            Image(systemName: "line.3.horizontal").font(UI.icon).foregroundStyle(UI.hint).frame(width: 14)
                .accessibilityHidden(true)                                                        // the drag handle (a glyph)
            Image(systemName: spec?.icon ?? "square").font(UI.icon).foregroundStyle(s.visible ? Island.accent : UI.hint)
                .frame(width: UI.iconColumn).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Text(title).font(UI.title).lineLimit(1)
                    if layout.start == s.id { Image(systemName: "flag.fill").font(UI.detail).foregroundStyle(Island.accent).help(L("Start screen")) }
                    if !issues.isEmpty { Image(systemName: "exclamationmark.triangle.fill").font(UI.detail).foregroundStyle(warningColor).help(L("Something doesn't fit")) }
                }
                Text(detail(s)).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { toggleEditing(s.id) }
            glyph(open ? "chevron.up.circle.fill" : "slider.horizontal.3", String(format: L("Edit the modules of %@"), title), on: open) { toggleEditing(s.id) }
            glyph("chevron.up", String(format: L("Move %@ up"), title), disabled: index == 0) { edit { $0.moveScreen(s.id, by: -1) } }
            glyph("chevron.down", String(format: L("Move %@ down"), title), disabled: index == layout.screens.count - 1) { edit { $0.moveScreen(s.id, by: 1) } }
            CocaineSwitch(on: s.visible) { edit { $0.setVisible(s.id, !s.visible) } }
                .disabled(s.visible && !canHide)
                .help(s.visible && !canHide ? L("At least one screen stays shown") : String(format: L("Show %@"), title))
                .accessibilityLabel(String(format: L("Show %@"), title))
        }
        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
        .background(RoundedRectangle(cornerRadius: CTL.innerRadius).fill(Color.white.opacity(open ? 0.08 : 0.04)))
        .onDrag {
            state.dragging = s.id
            return NSItemProvider(object: s.id as NSString)
        }
        .onDrop(of: [UTType.text], delegate: ScreenDropDelegate(target: s.id, state: state, store: store))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue((s.visible ? L("Shown") : L("Hidden")) + ", " + detail(s))
        .accessibilityAction(named: L("Move up")) { edit { $0.moveScreen(s.id, by: -1) } }
        .accessibilityAction(named: L("Move down")) { edit { $0.moveScreen(s.id, by: 1) } }
    }

    private func detail(_ s: ScreenConfig) -> String {
        if Self.isConditional(s.id) && !external { return L("Only with an external monitor") }
        let names = s.modules.map { Self.moduleTitle($0.kind) }
        return names.isEmpty ? L("Empty screen") : names.joined(separator: ", ")
    }
    private static func isConditional(_ id: String) -> Bool { ScreenLayout.isConditional(id) }

    private func toggleEditing(_ id: String) {
        withAnimation(ScreensMotion.edit) { state.editing = state.editing == id ? nil : id }
    }

    /// A small glyph button with a 24 pt target (the same as the island's and the lists').
    private func glyph(_ symbol: String, _ label: String, disabled: Bool = false, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button { Haptic.tap(.alignment); action() } label: {
            Image(systemName: symbol).font(UI.chevron).foregroundStyle(on ? Island.accent : UI.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.3 : 1)
        .help(label).accessibilityLabel(label)
    }

    // MARK: a screen's modules

    private func modulesEditor(_ s: ScreenConfig) -> some View {
        let r = ScreenLayout.resolve(s, in: ScreenLayout.contentSize(stripHeight: 32))
        return VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(s.modules.enumerated()), id: \.element.kind) { i, p in
                moduleRow(s, p, index: i, count: s.modules.count, drawn: r.modules.first { $0.kind == p.kind })
                    .transition(ScreensMotion.rowTransition)
            }
            if s.modules.isEmpty {
                Text(L("Empty screen")).font(UI.detail).foregroundStyle(UI.secondary)
            }
            ForEach(Array(r.issues.enumerated()), id: \.offset) { _, issue in
                if let text = Self.message(issue) {
                    Label(text, systemImage: "exclamationmark.triangle.fill").font(UI.detail).foregroundStyle(warningColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Space.m) {
                let addable = layout.addable(to: s.id)
                ValueButton(id: "screensAdd", title: L("Add module"), value: L("Add module"), maxWidth: 170,
                            spec: { PickerSpec(id: "screensAdd", title: L("Add module"),
                                               items: addable.map { PickerItem(id: $0.id, title: L($0.title), symbol: $0.icon) }, mode: .action) },
                            onPick: { kind in edit { $0.addModule(kind, to: s.id) } })
                    .disabled(addable.isEmpty)
                Spacer(minLength: Space.s)
                let others = layout.screens.filter { $0.id != s.id && !ScreenLayout.isConditional($0.id) }
                ValueButton(id: "screensMerge", title: L("Merge into"), value: L("Merge into"), maxWidth: 170,
                            spec: { PickerSpec(id: "screensMerge", title: String(format: L("Merge %@ into"), Self.screenTitle(s.id)),
                                               items: others.compactMap { o in ModuleCatalog.screen(o.id).map { PickerItem(id: o.id, title: L($0.title), symbol: $0.icon) } },
                                               mode: .action) },
                            onPick: { to in
                                edit { $0.merge(s.id, into: to) }
                                withAnimation(ScreensMotion.edit) { state.editing = to }
                            })
                    .disabled(s.modules.isEmpty || !layout.canHide(s.id) && s.visible)
                    .help(L("Its modules join the other screen, and this one is hidden"))
            }
            .padding(.trailing, Space.s)       // the value buttons' hover pill reaches past their text
        }
        .padding(.leading, 26).padding(.trailing, Space.s).padding(.vertical, Space.xs)
    }

    private func moduleRow(_ s: ScreenConfig, _ p: ModulePlacement, index: Int, count: Int, drawn: ResolvedScreen.Module?) -> some View {
        let spec = ModuleCatalog.module(p.kind)
        let title = Self.moduleTitle(p.kind)
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Image(systemName: spec?.icon ?? "square").font(UI.icon).foregroundStyle(drawn == nil ? UI.hint : UI.secondary)
                    .frame(width: UI.iconColumn).accessibilityHidden(true)
                Text(title).font(UI.value).foregroundStyle(drawn == nil ? UI.secondary : UI.primary).lineLimit(1)
                if drawn == nil { Text(L("Not shown")).font(UI.detail).foregroundStyle(warningColor).lineLimit(1) }
                Spacer(minLength: Space.xs)
                glyph("chevron.up", String(format: L("Move %@ up"), title), disabled: index == 0) { edit { $0.moveModule(p.kind, in: s.id, by: -1) } }
                glyph("chevron.down", String(format: L("Move %@ down"), title), disabled: index == count - 1) { edit { $0.moveModule(p.kind, in: s.id, by: 1) } }
                glyph("xmark", String(format: L("Remove %@"), title)) { edit { $0.removeModule(p.kind, from: s.id) } }
            }
            HStack(spacing: Space.m) {
                Segments(selection: Binding(get: { p.column }, set: { c in edit { $0.setColumn(p.kind, in: s.id, c) } }), values: [0, 1],
                         name: String(format: L("Column of %@"), title), label: { $0 == 0 ? L("Left") : L("Right") })
                    .frame(width: 128)
                Spacer(minLength: Space.xs)
                if let spec, spec.sizes.count > 1 {
                    Segments(selection: Binding(get: { p.size }, set: { z in edit { $0.setSize(p.kind, in: s.id, z) } }), values: spec.sizes,
                             name: String(format: L("Size of %@"), title), label: { $0.letter }, spoken: { Self.sizeName($0) })
                        .frame(width: CGFloat(spec.sizes.count) * 34)
                } else {
                    Text(L("Fills its column")).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                }
            }
            .padding(.leading, UI.iconColumn + Space.s)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// What the island does with a module that doesn't fit, in words (nil: nothing to say).
    static func message(_ i: ResolvedScreen.Issue) -> String? {
        switch i {
        case .empty: return nil
        case .shrunk(let k, _, let to): return String(format: L("%@ is drawn %@: there is no room for more"), moduleTitle(k), sizeName(to).lowercased(with: Language.locale))
        case .noRoom(let k): return String(format: L("No room for %@: make a module smaller, or move it to the other column"), moduleTitle(k))
        case .needsWholePage(let k, let by): return String(format: L("%@ needs the whole screen: %@ isn't shown"), moduleTitle(by), moduleTitle(k))
        case .needsWideColumn(let k, let by): return String(format: L("%@ and %@ both need the wide column: %@ isn't shown"), moduleTitle(by), moduleTitle(k), moduleTitle(k))
        }
    }

    // MARK: restore

    private func confirmRestore() {
        let spec = DialogSpec(icon: "arrow.counterclockwise", title: L("Restore the standard screens?"),
                              message: L("Every screen shown, in the original order, with its own modules; the island opens on the last screen used."),
                              buttons: [DialogButton(id: "restore", title: L("Restore"), role: .destructive), Dialogs.cancel], surface: .panel)
        DialogCenter.shared.present(spec) { r in
            guard r.buttonID == "restore" else { return }
            withAnimation(ScreensMotion.edit) {
                ScreenLayoutStore.shared.restoreDefaults()
                ScreensEditorState.shared.editing = nil
            }
            A11y.announce(L("Screens restored"))
        }
    }
}

/// Dragging a screen's row over another moves it there (live, as the pointer passes); the drop just ends the drag.
struct ScreenDropDelegate: DropDelegate {
    let target: String
    let state: ScreensEditorState
    let store: ScreenLayoutStore

    func dropEntered(info: DropInfo) {
        guard let d = state.dragging, d != target, let to = store.layout.screens.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(ScreensMotion.edit) { store.update { $0.moveScreen(d, to: to) } }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { state.dragging = nil; return true }
    func dropExited(info: DropInfo) {}
}

/// The island in miniature with the edited layout: its tabs (the shown screens, in order; the edited one highlighted) and the
/// modules of one screen as boxes where the island draws them. A schematic (no live content, no camera): it follows every
/// change with the editor's motion.
struct ScreensPreview: View {
    let layout: ScreenLayout
    let selected: String
    let external: Bool
    static let width: CGFloat = Layout.width - 2 * Space.frame - 2 * Space.l
    private static let strip: CGFloat = 32

    var body: some View {
        let s = Self.width / Island.openSize.width
        let box = ScreenLayout.contentSize(stripHeight: Self.strip)
        let config = layout.config(selected) ?? ScreenConfig(id: selected, visible: true, modules: [])
        let r = ScreenLayout.resolve(config, in: box)
        let ox = (Island.openSize.width - IslandLayout.openBody) / 2 + Space.page, oy = Self.strip + 8
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24 * s, style: .continuous).fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 24 * s, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            RoundedRectangle(cornerRadius: 6 * s).fill(Color.white.opacity(0.07))                        // where the notch is
                .frame(width: 185 * s, height: Self.strip * s * 0.8)
                .offset(x: (Island.openSize.width - 185) / 2 * s)
            tabs(scale: s)
            ForEach(r.modules, id: \.kind) { m in
                tile(m, scale: s)
                    .frame(width: m.frame.width * s, height: m.frame.height * s)
                    .offset(x: (ox + m.frame.minX) * s, y: (oy + m.frame.minY) * s)
                    .transition(.opacity)
            }
            if r.modules.isEmpty {
                Text(L("Empty screen")).font(UI.detail).foregroundStyle(UI.secondary)
                    .frame(width: box.width * s, height: box.height * s)
                    .offset(x: ox * s, y: oy * s)
            }
        }
        .frame(width: Self.width, height: Island.openSize.height * s, alignment: .topLeading)
        .animation(ScreensMotion.edit, value: layout)
        .animation(ScreensMotion.edit, value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Island preview"))
        .accessibilityValue(spoken(r))
    }

    private func spoken(_ r: ResolvedScreen) -> String {
        let shown = layout.visibleScreens(external: external).map { ScreensEditor.screenTitle($0.id) }.joined(separator: ", ")
        let mods = r.modules.map { ScreensEditor.moduleTitle($0.kind) + " " + ScreensEditor.sizeName($0.size) }.joined(separator: ", ")
        return String(format: L("Tabs: %@. %@: %@"), shown, ScreensEditor.screenTitle(selected), mods.isEmpty ? L("Empty screen") : mods)
    }

    @ViewBuilder private func tabs(scale s: CGFloat) -> some View {
        let shown = layout.visibleScreens(external: external)
        let cell = IslandView.cellWidth(tabs: shown.count), half = (shown.count + 1) / 2
        let cx = Island.openSize.width / 2
        let left0 = IslandView.stripStart(cx, cell: cell), right1 = 2 * cx - left0
        let n = shown.count
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
            let x = i < half ? left0 + cell * (CGFloat(i) + 0.5) : right1 - cell * (CGFloat(n - i) + 0.5)
            let on = t.id == selected
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(on ? 0.2 : 0)).frame(width: IslandView.highlight(cell) * s, height: 26 * s)
                Image(systemName: ModuleCatalog.screen(t.id)?.icon ?? "square").font(.system(size: 13 * s, weight: .medium))
                    .foregroundStyle(on ? Color.white : UI.hint)
            }
            .frame(width: cell * s, height: Self.strip * s)
            .offset(x: (x - cell / 2) * s)
        }
        Image(systemName: "gearshape").font(.system(size: 13 * s, weight: .medium)).foregroundStyle(UI.hint)
            .frame(width: cell * s, height: Self.strip * s)
            .offset(x: (right1 - cell) * s)
    }

    private func tile(_ m: ResolvedScreen.Module, scale s: CGFloat) -> some View {
        let spec = ModuleCatalog.module(m.kind)
        return RoundedRectangle(cornerRadius: 6).fill(Island.accent.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Island.accent.opacity(0.55), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                HStack(spacing: Space.xs) {
                    Image(systemName: spec?.icon ?? "square").font(UI.detail)
                    Text(ScreensEditor.moduleTitle(m.kind)).font(UI.detail).lineLimit(1)
                }
                .foregroundStyle(UI.primary).padding(.horizontal, Space.s).padding(.top, Space.xs)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(m.size.letter).font(UI.detail.monospacedDigit()).foregroundStyle(UI.secondary).padding(Space.xs)
            }
    }
}
