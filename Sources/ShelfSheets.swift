// The shelf's sheets: in-app cards over the island's page (never a system menu): the actions menu, Open With (the apps that open
// every selected file, with their icons), Share (macOS's services, AirDrop first), Share link (the cloud providers, when the
// cloud feature is there), the collections, batch rename with its live preview, and the image options. Esc closes a sheet;
// Return runs rename and the image job.

import AppKit
import SwiftUI

/// Draws the shelf's sheet over the page when one is up (IslandView.page).
struct ShelfSheetLayer: ViewModifier {
    @ObservedObject var center: ShelfCenter

    func body(content: Content) -> some View {
        let on = center.sheet != nil
        return ZStack(alignment: .top) {
            content.disabled(on).opacity(on ? 0.35 : 1).accessibilityHidden(on)
                .overlay { if on { Color.black.opacity(0.4).contentShape(Rectangle()).onTapGesture { Motion.with(.dialog) { center.sheet = nil } }.transition(.opacity) } }
            if let s = center.sheet {
                ShelfSheetCard(center: center, store: center.store, sheet: s)
                    .padding(EdgeInsets(top: 2, leading: 18, bottom: 12, trailing: 18))
                    .motionAppear(edge: .top)
            }
        }
        .animation(Motion.animation(.dialog), value: on)
    }
}

struct ShelfSheetCard: View {
    @ObservedObject var center: ShelfCenter
    @ObservedObject var store: ShelfStore
    let sheet: ShelfSheet

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(DisplayOptions.contrast ? 0.5 : 0.12), lineWidth: DisplayOptions.contrast ? 1 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder private var content: some View {
        switch sheet {
        case .menu: menu
        case .openWith(let urls): openWith(urls)
        case .share: share
        case .links: links
        case .collections: collections
        case .rename: ShelfRenameForm(center: center)
        case .images: ShelfImageForm(center: center)
        case .move(let ids): move(ids)
        }
    }

    // MARK: header

    static func header<Trailing: View>(_ icon: String, _ title: String, close: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: icon).font(UI.icon).foregroundStyle(Island.accent).frame(width: UI.iconColumn)
            Text(title).font(UI.groupTitle).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Space.s)
            trailing()
            Button(action: close) {
                Image(systemName: "xmark").font(UI.icon).foregroundStyle(UI.secondary).frame(width: CTL.h, height: CTL.h).contentShape(Rectangle())
            }
            .buttonStyle(MotionGlyphStyle()).help(L("Close")).accessibilityLabel(L("Close"))
        }
        .frame(height: CTL.h)
    }

    private func header(_ icon: String, _ title: String) -> some View {
        Self.header(icon, title, close: { Motion.with(.dialog) { center.sheet = nil } }) { EmptyView() }
    }

    private var selectionTitle: String {
        let n = center.selected.count
        return store.selection.isEmpty ? String(format: L("All %d items"), n) : (n == 1 ? (center.selected.first?.name ?? "") : String(format: L("%d items"), n))
    }

    // MARK: the actions menu

    private var menu: some View {
        let items = center.selected
        let ops = center.ops(for: items)
        let custom = center.config.config.actions
        return VStack(alignment: .leading, spacing: Space.s) {
            header("ellipsis.circle", selectionTitle)
            FadingScroll {
                VStack(alignment: .leading, spacing: Space.s) {
                    grid(ops.map { op in (op.id, op.title, op.symbol, op.destructive, { center.run(op) }) })
                    if !custom.isEmpty {
                        Text(L("Your actions")).font(UI.section).foregroundStyle(UI.secondary).padding(.top, 2)
                        grid(custom.map { a in (a.id.uuidString, a.name, a.symbol, false, { center.perform(a) }) })
                    }
                    if store.collections.count > 1 && !store.selection.isEmpty {
                        Text(L("Move to collection")).font(UI.section).foregroundStyle(UI.secondary).padding(.top, 2)
                        grid(store.collections.filter { $0.id != store.library.current }.map { c in
                            (c.id.uuidString, c.title, "arrow.right.circle", false, { center.moveSelection(to: c.id) })
                        })
                    }
                }
            }
        }
    }

    private func grid(_ rows: [(id: String, title: String, symbol: String, destructive: Bool, action: () -> Void)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s), GridItem(.flexible())],
                  alignment: .leading, spacing: Space.s) {
            ForEach(rows, id: \.id) { r in
                ChoiceRow(title: r.title, leading: .symbol(r.symbol), selectable: false, destructive: r.destructive, font: UI.value, action: r.action)
            }
        }
    }

    // MARK: Open With, Share, links

    private func openWith(_ urls: [URL]) -> some View {
        let apps = ShelfFiles.apps(for: urls)
        return VStack(alignment: .leading, spacing: Space.s) {
            header("square.grid.2x2", L("Open With"))
            if apps.isEmpty { Text(L("No app opens all of these")).font(UI.value).foregroundStyle(UI.hint) }
            FadingScroll {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s), GridItem(.flexible())], alignment: .leading, spacing: Space.s) {
                    ForEach(apps, id: \.self) { app in
                        ChoiceRow(title: ShelfFiles.appName(app), leading: .image(IconCache.icon(app.path)), selectable: false, font: UI.value) {
                            Motion.with(.dialog) { center.sheet = nil }
                            _ = ShelfActionEngine.openWith(app, urls)
                        }
                    }
                }
            }
        }
    }

    private var share: some View {
        let things: [Any] = center.selected.filter { !$0.missing }.compactMap { i -> Any? in
            switch i.kind {
            case .file, .image: return store.url(of: i)
            case .link: return i.text.flatMap(URL.init(string:))
            case .text: return i.text
            }
        }
        let services = Sharing.services(for: things)
        let cloud = !CloudShareHook.providers().isEmpty && CloudShareHook.upload != nil && !center.selectedURLs.isEmpty
        return VStack(alignment: .leading, spacing: Space.s) {
            header("square.and.arrow.up", L("Share"))
            FadingScroll {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s), GridItem(.flexible())], alignment: .leading, spacing: Space.s) {
                    ForEach(Array(services.enumerated()), id: \.offset) { _, s in
                        ChoiceRow(title: s.title, leading: .image(s.image), selectable: false, font: UI.value) { center.share(s) }
                    }
                    if cloud {
                        ChoiceRow(title: L("Share link…"), leading: .symbol("link"), selectable: false, font: UI.value) { Motion.with(.dialog) { center.sheet = .links } }
                    }
                }
            }
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header("link", L("Share link"))
            FadingScroll {
                VStack(spacing: Space.s) {
                    ForEach(CloudShareHook.providers(), id: \.id) { p in
                        ChoiceRow(title: p.title, leading: .symbol("icloud.and.arrow.up"), selectable: false, font: UI.value) { center.shareLink(provider: p.id) }
                    }
                }
            }
        }
    }

    private func move(_ ids: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header("arrow.right.circle", L("Move to collection"))
            FadingScroll {
                VStack(spacing: Space.s) {
                    ForEach(store.collections.filter { $0.id != store.library.current }) { c in
                        ChoiceRow(title: c.title, leading: .symbol("circle.fill"), selectable: false, font: UI.value) { center.moveSelection(to: c.id) }
                    }
                }
            }
        }
    }

    // MARK: collections

    private var collections: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Self.header("rectangle.stack", L("Collections"), close: { Motion.with(.dialog) { center.sheet = nil } }) {
                Button(L("New…")) { center.newCollection() }.buttonStyle(CocaineButtonStyle())
            }
            FadingScroll {
                VStack(spacing: Space.xs) {
                    ForEach(Array(store.collections.enumerated()), id: \.element.id) { n, c in collectionRow(c, n) }
                }
            }
        }
    }

    private func collectionRow(_ c: ShelfCollection, _ n: Int) -> some View {
        let on = c.id == store.library.current
        return HStack(spacing: Space.s) {
            Button { Haptic.tap(.alignment); store.recolorCollection(c.id, (c.color + 1) % ShelfColors.count) } label: {
                Circle().fill(ShelfTabs.color(c.color)).frame(width: 12, height: 12).frame(width: CTL.h, height: CTL.h).contentShape(Rectangle())
            }
            .buttonStyle(MotionGlyphStyle())
            .help(L("Change the colour")).accessibilityLabel(L("Colour")).accessibilityValue(ShelfColors.name(c.color)).accessibilityHint(L("Changes it"))
            Button { Haptic.tap(.alignment); Motion.with(.page) { store.select(c.id) }; Motion.with(.dialog) { center.sheet = nil } } label: {
                HStack(spacing: Space.s) {
                    Text(c.title).font(UI.value.weight(on ? .semibold : .regular)).lineLimit(1)
                    Text("\(c.items.count)").font(UI.detail.monospacedDigit()).foregroundStyle(UI.hint)
                    Spacer(minLength: 0)
                    if on { Image(systemName: "checkmark").font(UI.icon).foregroundStyle(Island.accent) }
                }
                .frame(height: CTL.h).contentShape(Rectangle())
            }
            .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScaleRow))
            .accessibilityLabel(c.title).accessibilityValue(String(format: L("%d items"), c.items.count)).accessibilityAddTraits(on ? .isSelected : [])
            ShelfGlyph(symbol: "chevron.left", title: L("Move left")) { store.moveCollection(c.id, by: -1) }.disabled(n == 0)
            ShelfGlyph(symbol: "chevron.right", title: L("Move right")) { store.moveCollection(c.id, by: 1) }.disabled(n == store.collections.count - 1)
            ShelfGlyph(symbol: "pencil", title: L("Rename…")) { center.renameCollection(c.id) }
            ShelfGlyph(symbol: "arrow.triangle.merge", title: L("Merge into…")) { center.mergeCollection(c.id) }.disabled(store.collections.count < 2)
            ShelfGlyph(symbol: "trash", title: L("Delete…")) { center.deleteCollection(c.id) }.disabled(store.collections.count < 2)
        }
        .padding(.horizontal, Space.s)
        .background(RoundedRectangle(cornerRadius: CTL.innerRadius).fill(Color.white.opacity(on ? 0.08 : 0.03)))
    }
}

// MARK: - Batch rename

/// A form's own state (no @State: the command-line build has no macros, and these forms keep it simple).
final class ShelfFormState: ObservableObject {
    @Published var tab = 0
    @Published var sizeText = ""
}

struct ShelfRenameForm: View {
    @ObservedObject var center: ShelfCenter
    @StateObject private var form = ShelfFormState()
    private var tab: Int { form.tab }

    private var rule: Binding<RenameRule> { Binding(get: { center.renameRule }, set: { center.renameRule = $0 }) }

    var body: some View {
        let plan = center.renamePlan(center.renameRule)
        VStack(alignment: .leading, spacing: Space.s) {
            ShelfSheetCard.header("pencil", String(format: L("Rename %d items"), plan.rows.count), close: { Motion.with(.dialog) { center.sheet = nil } }) {
                Button(L("Rename")) { center.rename(center.renameRule) }
                    .buttonStyle(CocaineButtonStyle(kind: .primary)).disabled(!plan.canApply)
            }
            HStack(alignment: .top, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Segments(selection: $form.tab, values: [0, 1, 2, 3], name: L("Rename"), label: { [L("Replace"), L("Add"), L("Number"), L("Case")][$0] })
                    fields
                }
                .frame(width: 270)
                preview(plan)
            }
        }
    }

    @ViewBuilder private var fields: some View {
        switch tab {
        case 0:
            ShelfLabeledField(title: L("Find"), text: rule.find, autofocus: true)
            ShelfLabeledField(title: L("Replace with"), text: rule.replace)
        case 1:
            ShelfLabeledField(title: L("Before"), text: rule.prefix, autofocus: true)
            ShelfLabeledField(title: L("After"), text: rule.suffix)
        case 2:
            HStack(spacing: Space.s) {
                Text(L("Number")).font(UI.value).foregroundStyle(UI.secondary)
                Spacer(minLength: 0)
                Segments(selection: rule.numberPlace, values: RenameRule.Place.allCases, name: L("Number"),
                         label: { $0 == .before ? L("Before") : L("After") }).frame(width: 120).dimGroup(!center.renameRule.numbering)
                CocaineSwitch(on: center.renameRule.numbering) { center.renameRule.numbering.toggle() }.accessibilityLabel(L("Number"))
            }
            HStack(spacing: Space.s) {
                Text(L("Date")).font(UI.value).foregroundStyle(UI.secondary)
                Spacer(minLength: 0)
                Segments(selection: rule.date, values: RenameRule.DateMode.allCases, name: L("Date"),
                         label: { $0 == .none ? L("Off") : $0 == .before ? L("Before") : L("After") }).frame(width: 170)
            }
        default:
            Segments(selection: rule.letterCase, values: RenameRule.LetterCase.allCases, name: L("Case"),
                     label: { [.keep: L("Keep"), .lower: "abc", .upper: "ABC", .title: "Abc"][$0] ?? "" },
                     spoken: { [.keep: L("Keep"), .lower: L("lowercase"), .upper: L("UPPERCASE"), .title: L("Title Case")][$0] })
            ShelfLabeledField(title: L("New name"), text: rule.newBase, autofocus: true)
        }
    }

    private func preview(_ plan: RenameEngine.Plan) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            if plan.conflicts + plan.invalid > 0 {
                Label(String(format: L("%d can't be renamed like this"), plan.conflicts + plan.invalid), systemImage: "exclamationmark.triangle.fill")
                    .font(UI.detail).foregroundStyle(warningColor)
            }
            FadingScroll {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(plan.rows) { r in
                        HStack(spacing: Space.xs) {
                            Text(r.newName).font(UI.detail).foregroundStyle(color(r.status)).lineLimit(1).truncationMode(.middle)
                            if case .conflict(let why) = r.status { Image(systemName: "exclamationmark.triangle.fill").font(UI.detail).foregroundStyle(warningColor).help(why) }
                            if case .invalid(let why) = r.status { Image(systemName: "exclamationmark.triangle.fill").font(UI.detail).foregroundStyle(warningColor).help(why) }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(r.oldName + ", " + r.newName + statusWords(r.status))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ s: RenameEngine.Status) -> Color {
        switch s { case .ok: return .white; case .unchanged: return UI.hint; case .invalid, .conflict: return warningColor }
    }
    private func statusWords(_ s: RenameEngine.Status) -> String {
        switch s { case .ok: return ""; case .unchanged: return ", " + L("unchanged"); case .invalid(let w), .conflict(let w): return ", " + w }
    }
}

// MARK: - Image options

struct ShelfImageForm: View {
    @ObservedObject var center: ShelfCenter
    @StateObject private var form = ShelfFormState()
    private var sizeText: String { get { form.sizeText } nonmutating set { form.sizeText = newValue } }

    private enum ResizeKind: Int, CaseIterable { case keep, width, percent, side }

    private var kind: ResizeKind {
        switch center.imageJob.resize { case .none: return .keep; case .width: return .width; case .percent: return .percent; case .maxSide: return .side }
    }

    private func setKind(_ k: ResizeKind) {
        let n = Int(sizeText) ?? (k == .percent ? 50 : 1200)
        switch k {
        case .keep: center.imageJob.resize = .none
        case .width: center.imageJob.resize = .width(n)
        case .percent: center.imageJob.resize = .percent(min(100, n))
        case .side: center.imageJob.resize = .maxSide(n)
        }
        if k != .keep && sizeText.isEmpty { sizeText = "\(n)" }
    }

    var body: some View {
        let n = center.selected.filter { !$0.missing }.compactMap { center.store.url(of: $0) }.filter(ImageTools.isImage).count
        VStack(alignment: .leading, spacing: Space.s) {
            ShelfSheetCard.header("photo.on.rectangle", String(format: L("%d images"), n), close: { Motion.with(.dialog) { center.sheet = nil } }) {
                Button(L("Apply")) { center.images(center.imageJob) }
                    .buttonStyle(CocaineButtonStyle(kind: .primary)).disabled(n == 0 || center.imageJob.isIdentity)
            }
            HStack(spacing: Space.s) {
                Text(L("Size")).font(UI.value).foregroundStyle(UI.secondary).frame(width: 70, alignment: .leading)
                Segments(selection: Binding(get: { kind }, set: { setKind($0) }), values: ResizeKind.allCases, name: L("Size"),
                         label: { [L("Keep"), L("Width"), "%", L("Longest side")][$0.rawValue] })
                if kind != .keep {
                    ShelfField(text: Binding(get: { sizeText }, set: { sizeText = String($0.filter(\.isNumber).prefix(5)); setKind(kind) }), placeholder: kind == .percent ? "50" : "1200")
                        .shelfFieldLook().frame(width: 70)
                    Text(kind == .percent ? "%" : "px").font(UI.detail).foregroundStyle(UI.hint)
                }
            }
            HStack(spacing: Space.s) {
                Text(L("Format")).font(UI.value).foregroundStyle(UI.secondary).frame(width: 70, alignment: .leading)
                Segments(selection: Binding(get: { center.imageJob.format }, set: { center.imageJob.format = $0 }), values: ImageTools.formats, name: L("Format"),
                         label: { $0 == .same ? L("Same") : $0.rawValue.uppercased() })
            }
            HStack(spacing: Space.s) {
                Text(L("Quality")).font(UI.value).foregroundStyle(UI.secondary).frame(width: 70, alignment: .leading)
                Segments(selection: Binding(get: { center.imageJob.quality }, set: { center.imageJob.quality = $0 }), values: [0.6, 0.8, 0.9, 1.0], name: L("Quality"),
                         label: { $0 >= 1 ? L("Best") : "\(Int($0 * 100))" })
                    .dimGroup(!(center.imageJob.format == .jpeg || center.imageJob.format == .heic || center.imageJob.format == .same))
            }
            HStack(spacing: Space.l) {
                toggle(L("Remove metadata"), center.imageJob.stripMetadata) { center.imageJob.stripMetadata.toggle() }
                toggle(L("Replace originals"), center.imageJob.replace) { center.imageJob.replace.toggle() }
            }
        }
        .onAppear {
            switch center.imageJob.resize { case .width(let v), .maxSide(let v), .percent(let v): sizeText = "\(v)"; case .none: break }
        }
    }

    private func toggle(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: Space.s) {
            Text(title).font(UI.value).foregroundStyle(UI.secondary).lineLimit(1)
            CocaineSwitch(on: on, action: action).fixedSize().accessibilityLabel(title)
        }
        .help(title)
    }
}

// MARK: - Text fields

/// A field with its label on the left (rename's find/replace…).
struct ShelfLabeledField: View {
    let title: String
    @Binding var text: String
    var autofocus = false
    var body: some View {
        HStack(spacing: Space.s) {
            Text(title).font(UI.value).foregroundStyle(UI.secondary).frame(width: 84, alignment: .leading).lineLimit(1)
            ShelfField(text: $text, placeholder: title, autofocus: autofocus).shelfFieldLook()
        }
    }
}

extension View {
    /// The dialogs' field look: 24 pt, a rounded white .08 fill.
    func shelfFieldLook() -> some View {
        frame(height: CTL.h).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(0.08)))
    }
}

/// AppKit's text field (it takes the keyboard without @FocusState, which the command-line build can't use); only an
/// `autofocus` one takes it when it appears.
struct ShelfField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var autofocus = false

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false; f.drawsBackground = false
        f.focusRingType = .exterior; f.isBezeled = false
        f.font = .systemFont(ofSize: 12); f.textColor = .white
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.5), .font: NSFont.systemFont(ofSize: 12)])
        f.cell?.isScrollable = true; f.cell?.wraps = false; f.lineBreakMode = .byClipping
        f.delegate = context.coordinator
        f.stringValue = text
        f.setAccessibilityLabel(placeholder)
        if autofocus { DispatchQueue.main.async { f.window?.makeFirstResponder(f) } }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text && f.currentEditor() == nil { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ShelfField
        init(_ p: ShelfField) { parent = p }
        func controlTextDidChange(_ n: Notification) { if let f = n.object as? NSTextField { parent.text = f.stringValue } }
    }
}
