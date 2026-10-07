// Settings → Island → Pinboards: the pinboards' manager (create, rename, colour, symbol, order, the app they are suggested in,
// their global shortcut, delete). The clipboard's other settings are rows of the Clipboard card in Sources/PanelView.swift.

import AppKit
import SwiftUI

final class PinboardsEditorState: ObservableObject {
    static let shared = PinboardsEditorState()
    @Published var open: UUID?                       // the pinboard whose settings are shown
}

struct PinboardsManager: View {
    @ObservedObject var h: ClipboardHistory
    @ObservedObject var st = PinboardsEditorState.shared
    @ObservedObject var rec = ClipShortcutRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(h.boards.enumerated()), id: \.element.id) { i, b in
                VStack(alignment: .leading, spacing: Space.s) {
                    row(b, index: i)
                    if st.open == b.id { details(b, index: i).transition(ScreensMotion.rowTransition) }
                }
            }
            .motion(.dragSettle, value: h.boards.map(\.id))
            HStack(spacing: Space.m) {
                Text(h.settings.persist ? L("Saved on this Mac, encrypted, with the history.")
                                        : L("Saved on this Mac, encrypted, even with the history in memory only."))
                    .font(UI.detail).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.m)
                Button(L("New pinboard…")) { PickerCenter.shared.close(); ClipActions.newBoard(from: .panel) }.buttonStyle(CocaineButtonStyle())
                    .disabled(h.boards.count >= PinboardRules.maxBoards)
            }
        }
    }

    private func count(_ b: ClipBoard) -> Int { h.items.filter { $0.boards.contains(b.id) }.count }

    private func row(_ b: ClipBoard, index i: Int) -> some View {
        let open = st.open == b.id
        return Button {
            Haptic.tap(.alignment)
            Motion.with(.expand) { st.open = open ? nil : b.id }
        } label: {
            HStack(spacing: Space.m) {
                Image(systemName: b.symbol).font(UI.icon).foregroundStyle(BoardColor.color(b.color)).frame(width: UI.iconColumn)
                Text(b.displayName).font(UI.title).lineLimit(1)
                Text("\(count(b))").font(UI.metric).foregroundStyle(UI.hint)
                Spacer(minLength: Space.m)
                if let k = b.hotkey { Text(k.glyphs).font(UI.value.monospacedDigit()).foregroundStyle(UI.secondary) }
                if let app = b.app { Text(ClipboardHistory.appName(app) ?? app).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1) }
                Image(systemName: open ? "chevron.up" : "chevron.down").font(UI.chevron).foregroundStyle(UI.hint)
            }
            .frame(minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScaleRow))
        .accessibilityLabel(b.displayName)
        .accessibilityValue(String(format: L("%d items"), count(b)))
        .accessibilityHint(open ? L("Hides its settings") : L("Shows its settings"))
        .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
    }

    private func details(_ b: ClipBoard, index i: Int) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Text(L("Colour")).font(UI.title)
                Spacer(minLength: Space.m)
                ForEach(0..<BoardColor.count, id: \.self) { c in
                    Button { Haptic.tap(.alignment); edit(b.id) { $0.color = c } } label: {
                        Circle().fill(BoardColor.color(c)).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: b.color == c ? 2 : 0).padding(-3))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(MotionGlyphStyle())
                    .accessibilityLabel(BoardColor.name(c)).accessibilityAddTraits(b.color == c ? [.isButton, .isSelected] : .isButton)
                }
            }
            HStack(spacing: Space.m) {
                Text(L("Symbol")).font(UI.title)
                Spacer(minLength: Space.m)
                ValueButton(id: "boardIcon-\(b.id)", title: L("Symbol"), value: "", maxWidth: 40, spec: {
                    PickerSpec(id: "boardIcon-\(b.id)", title: L("Symbol"), items: PinboardRules.icons.map { PickerItem(id: $0, title: Self.iconName($0), symbol: $0) },
                               mode: .single(b.symbol))
                }, onPick: { id in edit(b.id) { $0.icon = id } })
                .overlay(alignment: .leading) { Image(systemName: b.symbol).font(UI.icon).foregroundStyle(BoardColor.color(b.color)).allowsHitTesting(false) }
            }
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(L("Suggested first in")).font(UI.title)
                    Text(L("Its items come first in the island while this app is in front")).font(UI.detail).foregroundStyle(UI.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.m)
                ValueButton(id: "boardApp-\(b.id)", title: L("Suggested first in"), value: b.app.flatMap { ClipboardHistory.appName($0) } ?? L("None"), maxWidth: 140, spec: {
                    let apps = ClipboardUI.runningApps(excluding: []).map { PickerItem(id: $0.id, title: $0.name, image: Self.appIcon($0.id)) }
                    var items = [PickerItem(id: "", title: L("None"))]
                    if let a = b.app, !apps.contains(where: { $0.id == a }) { items.append(PickerItem(id: a, title: ClipboardHistory.appName(a) ?? a, image: Self.appIcon(a))) }
                    return PickerSpec(id: "boardApp-\(b.id)", title: L("Suggested first in"), items: items + apps.map { var x = $0; x.section = 1; return x },
                                      mode: .single(b.app ?? ""), sectionTitle: L("Open now"))
                }, onPick: { id in edit(b.id) { $0.app = id.isEmpty ? nil : id } })
            }
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(L("Shortcut")).font(UI.title)
                    Text(rec.recording == .board(b.id) ? (rec.note ?? L("Type the new shortcut. Esc cancels, Delete removes it.")) : L("Opens the island on this pinboard"))
                        .font(UI.detail).foregroundStyle(rec.recording == .board(b.id) && rec.note != nil ? warningColor : UI.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.m)
                ClipShortcutButton(target: .board(b.id), shortcut: b.hotkey, label: b.displayName)
            }
            HStack(spacing: Space.s) {
                Button(L("Rename…")) { rename(b) }.buttonStyle(CocaineButtonStyle())
                Button { move(b, -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(CocaineButtonStyle()).disabled(i == 0)
                    .help(L("Move up")).accessibilityLabel(L("Move up"))
                Button { move(b, 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(CocaineButtonStyle()).disabled(i == h.boards.count - 1)
                    .help(L("Move down")).accessibilityLabel(L("Move down"))
                Spacer(minLength: 0)
                if !b.isFavorites { Button(L("Delete…")) { delete(b) }.buttonStyle(CocaineButtonStyle(kind: .destructive)) }
            }
        }
        .padding(.leading, UI.iconColumn + Space.m)
    }

    private func edit(_ id: UUID, _ change: @escaping (inout ClipBoard) -> Void) {
        h.editBoards { b in
            guard let i = b.firstIndex(where: { $0.id == id }) else { return false }
            change(&b[i])
            return true
        }
    }

    private func move(_ b: ClipBoard, _ n: Int) {
        Haptic.tap(.alignment)
        Motion.with(.dragSettle) { _ = h.editBoards { PinboardRules.move(&$0, b.id, by: n) } }
        A11y.announce(String(format: L("%@ moved"), b.displayName))
    }

    private func rename(_ b: ClipBoard) {
        let spec = DialogSpec(icon: "pin", title: L("Rename the pinboard"),
                              field: DialogField(placeholder: L("Name"), text: b.displayName, validate: { PinboardRules.problem($0, in: h.boards, except: b.id) }),
                              buttons: [DialogButton(id: "ok", title: L("Rename"), needsValidInput: true), Dialogs.cancel], surface: .panel)
        DialogCenter.shared.present(spec) { r in
            guard case .button("ok", let text, _) = r else { return }
            h.editBoards { PinboardRules.rename(&$0, b.id, to: text) }
        }
    }

    private func delete(_ b: ClipBoard) {
        let spec = DialogSpec(icon: "trash", title: String(format: L("Delete the pinboard “%@”?"), b.displayName),
                              message: L("Its items stay in the history; those on no other pinboard can then be removed by the history's limits."),
                              critical: true, buttons: [DialogButton(id: "delete", title: L("Delete"), role: .destructive), Dialogs.cancel], surface: .panel)
        DialogCenter.shared.present(spec) { r in
            guard r.buttonID == "delete" else { return }
            Motion.with(.dragSettle) { h.deleteBoard(b.id) }
            if st.open == b.id { st.open = nil }
        }
    }

    static func appIcon(_ id: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// A symbol's name for VoiceOver and the dropdown.
    static func iconName(_ s: String) -> String {
        switch s {
        case "star.fill": return L("Star")
        case "pin.fill": return L("Pin")
        case "bookmark.fill": return L("Bookmark")
        case "text.quote": return L("Quote")
        case "chevron.left.forwardslash.chevron.right": return L("Code")
        case "terminal.fill": return L("Terminal")
        case "envelope.fill": return L("Mail")
        case "link": return L("Link")
        case "photo": return L("Image")
        case "folder.fill": return L("Folder")
        case "sparkles": return L("Sparkles")
        case "person.fill": return L("Person")
        case "cart.fill": return L("Cart")
        case "flag.fill": return L("Flag")
        default: return L("Heart")
        }
    }
}
