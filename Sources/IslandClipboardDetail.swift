// The island's clipboard detail view: one item, large. Text scrolls (monospaced for code and JSON), a colour shows its swatch, a
// link its domain (nothing is fetched from the network), an image fits or shows at its real size, with the text in it; files
// show their name, size and icon, with Quick Look. Edit (save as new or replace; ⌘Z inside the editor), rename, pin, paste as
// (transformations), plain or formatted, snippet and its shortcut, delete with Undo.

import AppKit
import Quartz
import SwiftUI

struct ClipDetail: View {
    @ObservedObject var h: ClipboardHistory
    @ObservedObject var ui: ClipPageState
    let item: ClipItem
    let box: ModuleBox

    static func beginEdit(_ c: ClipItem) {
        let ui = ClipPageState.shared
        ui.editText = c.text
        ClipboardWiring.keyable(true)
        Motion.with(.crossfade) { ui.editing = true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header
            info
            if ui.editing { editor } else { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: header: back, name, actions

    private var header: some View {
        HStack(spacing: Space.xs) {
            ClipTool(icon: "chevron.left", title: L("Back (Esc)")) { ui.closeDetail() }
            Text(ClipRow.title(item)).font(UI.groupTitle).lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.s)
            if !ui.editing {
                ClipTool(icon: "doc.on.clipboard", title: L("Paste (Return)")) { ClipActions.paste(item) }
                ClipTool(icon: "square.on.square", title: L("Copy (⌘C)")) { ClipActions.copy(item) }
                if item.kind == .text {
                    ClipTool(icon: "pencil", title: L("Edit (⌘E)")) { Self.beginEdit(item) }
                    ClipTool(icon: "wand.and.stars", title: L("Paste as…")) { ClipActions.transformMenu(item) }
                }
                ClipTool(icon: "character.cursor.ibeam", title: L("Rename (⌘R)")) { ClipActions.rename(item) }
                ClipTool(icon: item.pinned ? "pin.fill" : "pin", on: item.pinned, title: L("Pin to…")) { ClipActions.pinMenu([item.id]) }
                if ClipActions.canShareWithAI { ClipTool(icon: "sparkles", title: L("Use as AI context")) { ClipActions.shareWithAI([item.id]) } }
                ClipTool(icon: "trash", title: L("Delete")) { ClipActions.delete([item.id]) }
            }
        }
    }

    /// Kind, source, date, size; plain/formatted; the pinboards it is on.
    private var info: some View {
        HStack(spacing: Space.s) {
            Text(facts).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
            ForEach(item.boards, id: \.self) { b in
                if let board = h.board(b) {
                    HStack(spacing: 3) {
                        Image(systemName: board.symbol).font(.system(size: 8, weight: .semibold)).foregroundStyle(BoardColor.color(board.color))
                        Text(board.displayName).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Spacer(minLength: 0)
            if item.hasRich && !ui.editing {
                Segments(selection: Binding(get: { ui.plainPreview }, set: { ui.plainPreview = $0 }), values: [false, true], name: L("Formatting"),
                         label: { $0 ? L("Plain") : L("Formatted") }, spoken: { _ in nil })
                    .fixedSize()
                    .help(L("How Paste and Copy put it: with its formatting, or plain text"))
            }
        }
        .frame(minHeight: 18)
    }

    private var facts: String {
        var p: [String] = []
        switch item.kind {
        case .text: p.append(item.snippet != nil ? L("Snippet") : ClipLooks.isLink(item.text) ? L("Link") : item.hasRich ? L("Formatted text") : L("Text"))
                    p.append(String(format: L("%d characters"), item.text.count))
        case .image: p.append(L("Image") + " \(item.width)×\(item.height)")
                     p.append(Int64(item.bytes).formatted(.byteCount(style: .file).locale(Language.locale)))
        case .files: p.append(item.paths.count == 1 ? L("File") : String(format: L("%d files"), item.paths.count))
        }
        if let app = ClipboardHistory.appName(item.source) { p.append(app) }
        p.append(item.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Language.locale)))
        return p.joined(separator: " · ")
    }

    // MARK: content by kind

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text: textContent
        case .image: imageContent
        case .files: filesContent
        }
    }

    private var textContent: some View {
        let link = ClipLooks.link(item.text), col = ClipLooks.color(item.text), code = ClipLooks.isCode(item.text)
        return VStack(alignment: .leading, spacing: Space.s) {
            if let col {
                HStack(spacing: Space.m) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(.sRGB, red: col.r, green: col.g, blue: col.b, opacity: col.a))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
                        .frame(width: 40, height: 24).accessibilityLabel(L("Colour swatch"))
                    Text(String(format: "R %d · G %d · B %d", Int(col.r * 255), Int(col.g * 255), Int(col.b * 255))).font(UI.mono).foregroundStyle(UI.secondary)
                }
            }
            if let link {
                HStack(spacing: Space.s) {
                    Image(systemName: "globe").font(UI.icon).foregroundStyle(UI.secondary)
                    Text(link.host ?? link.absoluteString).font(UI.itemTitle).lineLimit(1)
                    if let t = item.title { Text(t).font(UI.value).foregroundStyle(UI.secondary).lineLimit(1) }
                    Spacer(minLength: 0)
                    Button(L("Open")) { if ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(link) } }
                        .buttonStyle(CocaineButtonStyle(height: 22)).help(L("Opens it in your browser (Cocaine itself never loads it)"))
                }
            }
            ScrollView(.vertical) {
                Text(String(item.text.prefix(200_000))).font(code ? UI.mono : UI.value).foregroundStyle(UI.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
            if item.pinned && item.kind == .text { snippetRow }
        }
    }

    /// A pinned text can be a snippet: placeholders filled when pasted, and its own global shortcut.
    private var snippetRow: some View {
        HStack(spacing: Space.s) {
            CocaineSwitch(on: item.snippet != nil) {
                h.modify(item.id) { $0.snippet = $0.snippet == nil ? SnippetInfo() : nil }
                h.onBoardsChange()
            }
            .accessibilityLabel(L("Snippet"))
            Text(L("Snippet")).font(UI.value)
            Text(L("{clipboard} {date} {time} {input:Name}")).font(UI.mono).foregroundStyle(UI.hint).lineLimit(1)
                .help(L("Filled in when it is pasted. {input:Name} asks for a value."))
            Spacer(minLength: 0)
            if item.snippet != nil {
                ClipShortcutButton(target: .snippet(item.id), shortcut: item.snippet?.hotkey, label: ClipRow.title(item), onBegin: { ClipboardWiring.keyable(true) })
            }
        }
    }

    private var imageContent: some View {
        HStack(alignment: .top, spacing: Space.l) {
            Group {
                if let png = h.imageData(item), let img = NSImage(data: png) {
                    if ui.zoom {
                        ScrollView([.horizontal, .vertical]) { Image(nsImage: img).resizable().frame(width: CGFloat(item.width) / 2, height: CGFloat(item.height) / 2) }
                    } else {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    Text(L("The image can't be read")).font(UI.value).foregroundStyle(UI.hint)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(L("Image") + " \(item.width)×\(item.height)")
            VStack(alignment: .leading, spacing: Space.s) {
                Button { Motion.with(.expand) { ui.zoom.toggle() } } label: { Label(ui.zoom ? L("Fit") : L("Actual size"), systemImage: ui.zoom ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass") }
                    .buttonStyle(CocaineButtonStyle(height: 22))
                Button { readText() } label: { Label(L("Copy text"), systemImage: "text.viewfinder") }
                    .buttonStyle(CocaineButtonStyle(height: 22)).help(L("Reads the text in the image on this Mac and copies it"))
                if let t = ui.recognized[item.id] ?? item.ocr, !t.isEmpty {
                    ScrollView { Text(t).font(UI.detail).foregroundStyle(UI.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .frame(width: 150, alignment: .topLeading)
        }
    }

    private func readText() {
        if let t = ui.recognized[item.id] { copyText(t); return }
        A11y.announce(L("Reading the text…"))
        h.recognizeText(item, store: h.settings.ocr) { text in
            guard let text else { ClipActions.engine.notify("text.viewfinder", L("No text found in the image")); return }
            ui.recognized[item.id] = text
            copyText(text)
        }
    }

    private func copyText(_ t: String) {
        if h.copy(item, text: t) { Haptic.tap(.generic); ClipActions.engine.notify("text.viewfinder", L("Text copied")) }
    }

    private var filesContent: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(item.paths.prefix(50), id: \.self) { p in
                        HStack(spacing: Space.m) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text((p as NSString).lastPathComponent).font(UI.itemTitle).lineLimit(1).truncationMode(.middle)
                                Text(Self.fileFacts(p)).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            HStack(spacing: Space.s) {
                Button { ClipQuickLook.shared.show(item.paths.map { URL(fileURLWithPath: $0) }) } label: { Label(L("Quick Look"), systemImage: "eye") }
                    .buttonStyle(CocaineButtonStyle(height: 22)).disabled(h.missing.contains(item.id))
                Button { NSWorkspace.shared.activateFileViewerSelecting(item.paths.map { URL(fileURLWithPath: $0) }) } label: { Label(L("Show in Finder"), systemImage: "folder") }
                    .buttonStyle(CocaineButtonStyle(height: 22)).disabled(h.missing.contains(item.id))
            }
        }
    }

    /// "1,2 MB · ~/Documents" (or that it is gone).
    static func fileFacts(_ p: String) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: p) else { return L("The file is no longer there") }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let folder = ((p as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        return (a[.type] as? FileAttributeType == .typeDirectory ? L("Folder") : size.formatted(.byteCount(style: .file).locale(Language.locale))) + " · " + folder
    }

    // MARK: the editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            TextEditor(text: Binding(get: { ui.editText }, set: { ui.editText = $0 }))
                .font(ClipLooks.isCode(item.text) ? UI.mono : UI.value)
                .scrollContentBackground(.hidden)
                .padding(Space.xs)
                .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(0.08)))
                .frame(maxHeight: .infinity)
                .accessibilityLabel(L("Text"))
            HStack(spacing: Space.s) {
                Text(String(format: L("%d characters"), ui.editText.count)).font(UI.detail).foregroundStyle(UI.hint)
                Spacer(minLength: 0)
                Button(L("Cancel")) { endEdit() }.buttonStyle(CocaineButtonStyle(height: 22))
                Button(L("Save as new")) { save(replace: false) }.buttonStyle(CocaineButtonStyle(height: 22))
                    .disabled(ui.editText == item.text || ui.editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L("Replace")) { save(replace: true) }.buttonStyle(CocaineButtonStyle(kind: .primary, height: 22))
                    .disabled(ui.editText == item.text || ui.editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func endEdit() {
        ClipboardWiring.keyable(false)
        Motion.with(.crossfade) { ui.editing = false }
    }

    private func save(replace: Bool) {
        let before = item
        guard let saved = h.edit(item.id, text: ui.editText, replace: replace) else { return }
        Haptic.tap(.generic)
        endEdit()
        if replace {
            ClipboardWiring.lastEdit = (saved.id, before.text)
            ClipActions.engine.notify("pencil", L("Replaced. ⌘Z in the list puts the old text back"))
        } else {
            Motion.with(.page) { ui.detail = saved.id }
        }
    }
}

/// Quick Look for file items (the system's own panel: the point of the feature).
final class ClipQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = ClipQuickLook()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        self.urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !self.urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}
