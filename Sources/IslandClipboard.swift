// The island's Clipboard page (the history itself is in Sources/Clipboard.swift): search with filters, pinboard and kind chips,
// the "Suggested" items for the app in front, the list (click selects, ⌘/⇧-click select more, double-click or Return pastes),
// the selection's actions (paste together, Paste Stack, merge, pin, delete), Undo, and the module's S/M/L sizes. The detail
// view (preview, edit, rename, snippets) is Sources/IslandClipboardDetail.swift; the keys are ClipboardKeys below.

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The clipboard history lives in Sources/Clipboard.swift; its text comes from the Clipboard and Paste string tables.
func clipboardL(_ key: String) -> String { L(key) }

/// What the page shows and has picked (shared by every island's page, so a screen change keeps it).
final class ClipPageState: ObservableObject {
    static let shared = ClipPageState()
    @Published var board: UUID?                    // the pinboard chip picked (nil: everything)
    @Published var kind: ClipQuery.Kind?           // the kind chip picked (nil: every kind)
    @Published var selection = ClipSelection()
    @Published var detail: UUID?                   // the item opened in the detail view
    @Published var editing = false                 // its text is being edited
    @Published var editText = ""
    @Published var zoom = false                    // an image at its real size
    @Published var plainPreview = false            // the detail shows (and pastes) a formatted text without its formatting
    @Published var target: String?                 // the app in front when the island opened (suggestions)
    @Published var dragging: UUID?
    @Published var dropBoard: UUID?
    @Published var recognized: [UUID: String] = [:]   // text read from an image on demand (not kept)
    @Published var keyboardHints = false           // opened with the keyboard: ⌘1…⌘9 shown on the first rows (Sources/ClipKeyboard.swift)

    /// What the list shows now: the search, the chips, newest first.
    func list(_ h: ClipboardHistory) -> [ClipItem] { h.listed(board: board, kind: kind) }

    /// Suggestions for the app in front: only with nothing typed and no chip picked.
    func suggested(_ h: ClipboardHistory) -> [ClipItem] {
        guard h.settings.suggestions, h.query.isEmpty, board == nil, kind == nil else { return [] }
        return ClipSuggest.rank(h.items, front: target, boards: h.boards, now: h.now(), limit: 2)
    }

    func closeDetail() {
        if editing { editing = false; ClipboardWiring.keyable(false) }
        zoom = false
        Motion.with(.page) { detail = nil }
    }
}

// MARK: - What the page's buttons and keys do

enum ClipActions {
    static var h: ClipboardHistory { .shared }
    static var ui: ClipPageState { .shared }
    static var engine: PasteEngine { .shared }

    /// Pastes one item (a snippet gets its placeholders filled). `invert`: ⇧ held, the other formatting than the default.
    static func paste(_ c: ClipItem, invert: Bool = false) {
        Haptic.tap(.generic)
        let plain = invert ? !h.settings.pastePlain : (ui.detail == c.id && c.hasRich ? ui.plainPreview : nil)
        SnippetPaste.paste(c, engine: engine, plain: plain)
        ui.selection.clear()
        if ui.detail != nil { ui.closeDetail() }
    }

    /// Return: the selection (several: pasted together, in the order picked), else the highlighted row, else the first.
    static func pasteCurrent(_ list: [ClipItem], invert: Bool = false) -> Bool {
        let picked = ui.selection.ids.compactMap { id in h.items.first { $0.id == id } }
        if picked.count > 1 {
            Haptic.tap(.generic)
            engine.pasteTogether(picked, plain: invert ? !h.settings.pastePlain : nil)
            ui.selection.clear()
            return true
        }
        guard let c = picked.first ?? list.first(where: { $0.id == h.hovered }) ?? list.first else { return false }
        paste(c, invert: invert)
        return true
    }

    /// ⌥Return: the other way than Return. Return pastes: copy only (and close). Return copies only: paste into the app.
    static func otherAction(_ c: ClipItem, shift: Bool) {
        let plain: Bool? = shift ? !h.settings.pastePlain : nil
        if h.settings.directPaste {
            guard h.copy(c, plain: plain) else { engine.notify("exclamationmark.triangle.fill", c.kind == .files ? L("The file is no longer there") : L("Can't copy it")); return }
            Haptic.tap(.generic)
            ui.selection.clear()
            if ui.detail != nil { ui.closeDetail() }
            engine.closeIsland()
            engine.notify("doc.on.clipboard.fill", L("Copied"))
        } else {
            Haptic.tap(.generic)
            SnippetPaste.paste(c, engine: engine, plain: plain, direct: true)
            ui.selection.clear()
            if ui.detail != nil { ui.closeDetail() }
        }
    }

    /// ⌥P: on or off Favorites (the row's star).
    static func toggleFavorite(_ c: ClipItem) {
        Haptic.tap(.alignment)
        let on = !c.isFavorite
        h.togglePin(c.id)
        A11y.announce(on ? L("Added to favorites") : L("Removed from favorites"))
    }

    /// ⌥⌘⌫: the same choice as the toolbar's trash (history only, or everything), in the surface that asked.
    static func clearMenu() {
        IslandChoices.ask(L("Clear"), icon: "trash", IslandChoices.clipboardTrash) { id in
            if id == "clear" { Motion.with(.appear) { h.clearHistory() }; A11y.announce(L("History cleared")) }
            else { DispatchQueue.main.async { ClipboardUI.confirmDeleteEverything(h, from: ClipPopup.shared.isOpen ? .popup : .island) } }
        }
    }

    static func copy(_ c: ClipItem) {
        if h.copy(c, plain: ui.detail == c.id && c.hasRich ? ui.plainPreview : nil) {
            Haptic.tap(.generic)
            engine.notify("doc.on.clipboard.fill", L("Copied"))
        } else {
            engine.notify("exclamationmark.triangle.fill", c.kind == .files ? L("The file is no longer there") : L("Can't copy it"))
        }
    }

    static func open(_ c: ClipItem) {
        ui.zoom = false; ui.editing = false
        ui.plainPreview = h.settings.pastePlain
        Motion.with(.page) { ui.detail = c.id }
        A11y.announce(h.spokenTitle(c))
    }

    /// Deletes (Undo for a few seconds). The selection when it holds the item, else just it.
    static func delete(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        Motion.with(.appear) { h.remove(ids) }
        ui.selection.keep(Set(h.items.map(\.id)))
        if let d = ui.detail, ids.contains(d) { ui.closeDetail() }
        A11y.announce(String(format: L("%d deleted. Undo with ⌘Z"), ids.count))
    }

    /// ⌘Z: what was just deleted, else the text an edit just replaced.
    static func undo() {
        let n = Motion.with(.appear) { h.undoRemove() }
        if n > 0 { A11y.announce(String(format: L("%d restored"), n)); return }
        if let e = ClipboardWiring.lastEdit, h.edit(e.id, text: e.text, replace: true) != nil {
            ClipboardWiring.lastEdit = nil
            A11y.announce(L("Edit undone"))
        }
    }

    /// The pinboards to put `ids` on (or take them off), and a new one.
    static func pinMenu(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let items = ids.compactMap { id in h.items.first { $0.id == id } }
        var choices = h.boards.map { b -> DialogChoice in
            let on = !items.isEmpty && items.allSatisfy { $0.boards.contains(b.id) }
            return DialogChoice(id: b.id.uuidString, title: (on ? "✓ " : "") + b.displayName, symbol: b.symbol)
        }
        choices.append(DialogChoice(id: "new", title: L("New pinboard…"), symbol: "plus"))
        IslandChoices.ask(L("Pin to"), icon: "pin", choices) { id in
            if id == "new" { DispatchQueue.main.async { newBoard { b in h.pin(ids, to: b.id) } }; return }
            guard let b = UUID(uuidString: id) else { return }
            let all = items.allSatisfy { $0.boards.contains(b) }
            Haptic.tap(.alignment)
            if all { h.unpin(ids, from: b) } else { h.pin(ids, to: b) }
        }
    }

    /// Asks for a name and makes a pinboard (where it was asked: the island or the panel).
    static func newBoard(from surface: DialogSurface = .island, _ then: @escaping (ClipBoard) -> Void = { _ in }) {
        let spec = DialogSpec(icon: "pin", title: L("New pinboard"), message: h.settings.persist ? nil : L("Pinboards are saved on this Mac, encrypted, even when the history is kept in memory only."),
                              field: DialogField(placeholder: L("Name"), validate: { PinboardRules.problem($0, in: h.boards) }),
                              buttons: [DialogButton(id: "make", title: L("Create"), needsValidInput: true), Dialogs.cancel], surface: surface)
        DialogCenter.shared.present(spec) { r in
            guard case .button("make", let text, _) = r, let b = h.createBoard(text) else { return }
            then(b)
        }
    }

    static func rename(_ c: ClipItem) {
        let spec = DialogSpec(icon: "character.cursor.ibeam", title: L("Rename"), message: L("Shown in the list instead of its content. Empty: its content again."),
                              field: DialogField(placeholder: L("Name"), text: c.title ?? ""),
                              buttons: [DialogButton(id: "ok", title: L("Rename")), Dialogs.cancel], surface: .island)
        DialogCenter.shared.present(spec) { r in
            guard case .button("ok", let text, _) = r else { return }
            h.rename(c.id, text)
        }
    }

    /// Paste as ▸ a transformation (the ones that change this text).
    static func transformMenu(_ c: ClipItem) {
        guard c.kind == .text else { return }
        let options = ClipTransform.applicable(to: c.text)
        guard !options.isEmpty else { engine.notify("textformat", L("Nothing to change in this text")); return }
        IslandChoices.ask(L("Paste as"), icon: "wand.and.stars", options.map { DialogChoice(id: $0.rawValue, title: $0.title, symbol: $0.symbol) }) { id in
            guard let t = ClipTransform(rawValue: id), let out = t.apply(c.text) else { return }
            Haptic.tap(.generic)
            engine.paste(c, plain: true, text: out)
            ui.selection.clear()
            if ui.detail != nil { ui.closeDetail() }
        }
    }

    static func merge(_ ids: [UUID]) {
        guard let m = Motion.with(.appear, { h.merge(ids) }) else { engine.notify("exclamationmark.triangle.fill", L("Nothing to merge: pick two or more texts")); return }
        ui.selection.only(m.id); h.hovered = m.id
        A11y.announce(L("Merged into a new item"))
    }

    static func stack(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        engine.startStack(ids)
        ui.selection.clear()
    }

    /// The AI-context basket (Sources/MCP*.swift), when it is there.
    static var canShareWithAI: Bool { AIContextHook.add != nil }
    static func shareWithAI(_ ids: [UUID]) {
        guard let add = AIContextHook.add else { return }
        let items = ids.compactMap { id in h.items.first { $0.id == id } }
        add(items.map { (kind: "clip", ref: $0.id.uuidString, title: ClipCLIHandler.preview($0)) })
        engine.notify("sparkles", String(format: L("%d added to the AI context"), items.count))
    }

    /// "Send to iPhone" (Sources/ClipSync.swift), while the iCloud Drive sync is on: what happened, in the island's message.
    static func sendToIPhone(_ ids: [UUID]) {
        guard let send = ClipSyncHook.send else { return }
        let r = send(ids)
        if r.sent > 0 { Haptic.tap(.generic) }
        engine.notify(r.sent > 0 ? "iphone.and.arrow.forward" : "exclamationmark.triangle.fill", r.message)
    }

    /// The pause, for a while.
    static func pauseMenu() {
        if h.paused { h.paused = false; return }
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())).map { $0.addingTimeInterval(8 * 3600) }
        IslandChoices.ask(L("Pause"), icon: "pause.fill", [
            DialogChoice(id: "15", title: String(format: L("%d min"), 15), symbol: "clock"),
            DialogChoice(id: "60", title: L("1 hour"), symbol: "clock"),
            DialogChoice(id: "tomorrow", title: L("Until tomorrow"), symbol: "moon"),
            DialogChoice(id: "always", title: L("Until I resume"), symbol: "pause.fill"),
        ]) { id in
            switch id {
            case "15": h.pause(until: Date().addingTimeInterval(900))
            case "60": h.pause(until: Date().addingTimeInterval(3600))
            case "tomorrow": h.pause(until: tomorrow)
            default: h.pause(until: nil)
            }
        }
    }

    /// The chips' order for ⌘[ ⌘] and ⌥1…9: everything, then each pinboard.
    static func stepBoard(_ n: Int) {
        let ids: [UUID?] = [nil] + h.boards.map { Optional($0.id) }
        let i = ids.firstIndex { $0 == ui.board } ?? 0
        pickBoard(ids[min(ids.count - 1, max(0, i + n))])
    }

    static func pickBoard(_ id: UUID?) {
        Haptic.tap(.alignment)
        Motion.with(.selection) { ui.board = id }
        ui.selection.clear()
        A11y.announce(id.flatMap { h.board($0)?.displayName } ?? L("All"))
    }
}

// MARK: - The keys (handed in by the island's key monitor, Sources/IslandController.swift)

enum ClipboardKeys {
    /// An input method (Japanese, Chinese, Korean…) is composing text in the field that has the keyboard: every key (↑ ↓ pick a
    /// candidate, Return commits, Esc cancels, digits choose) belongs to it, none to the list. Tests replace it.
    static var composing: () -> Bool = {
        let marked = { (w: NSWindow?) in (w?.firstResponder as? NSTextView)?.hasMarkedText() ?? false }
        return marked(NSApp.keyWindow) || marked(ClipPopup.shared.window)
    }

    /// True when the key was used. `editing`: a text field or editor has the keyboard.
    static func handle(_ code: UInt16, flags: NSEvent.ModifierFlags, editing: Bool, model: IslandModel?) -> Bool {
        if ClipShortcutRecorder.shared.recording != nil { return ClipShortcutRecorder.shared.handle(keyCode: code, flags: flags) }
        if composing() { return false }
        if DialogCenter.shared.isShowing(on: .island) || DialogCenter.shared.isShowing(on: .popup) { return false }
        let h = ClipActions.h, ui = ClipActions.ui
        let mods = flags.intersection([.command, .option, .control, .shift])
        let cmd = mods == .command, shiftCmd = mods == [.command, .shift], opt = mods == .option, shift = mods == .shift, none = mods.isEmpty
        if ui.editing { if code == 53 && none { ui.editing = false; ClipboardWiring.keyable(false); return true }; return false }   // the editor's keys
        let command = ClipKeyCommand.interpret(code, flags: flags, char: ShortcutNames.translate(UInt32(code)), editing: editing)
        if let id = ui.detail, let c = h.items.first(where: { $0.id == id }) {
            switch command {                                                                                     // Sources/ClipKeyboard.swift
            case .otherAction(let shift)?: ClipActions.otherAction(c, shift: shift); return true                // ⌥Return
            case .toggleFavorite?: ClipActions.toggleFavorite(c); return true                                    // ⌥P
            case .pinMenu?: ClipActions.pinMenu([c.id]); return true                                            // ⌘P
            case .details?: ui.closeDetail(); return true                                                       // ⌘Y again: back
            case .deleteItem?: ClipActions.delete([id]); return true                                            // ⌥⌫
            default: break
            }
            switch code {
            case 53 where none, 123 where none && !editing: ui.closeDetail(); return true                       // Esc, ←: back
            case 36 where none || shift, 76 where none || shift: ClipActions.paste(c, invert: shift); return true // Return
            case 8 where cmd: ClipActions.copy(c); return true                                                  // ⌘C
            case 14 where cmd: if c.kind == .text { ClipDetail.beginEdit(c) }; return true                      // ⌘E
            case 15 where cmd: ClipActions.rename(c); return true                                               // ⌘R
            case 51 where none && !editing, 117 where none && !editing: ClipActions.delete([id]); return true   // Delete
            default: return false
            }
        }
        let suggested = ui.suggested(h), picked = Set(suggested.map(\.id))       // once per key, not once per item
        let list = suggested + ui.list(h).filter { !picked.contains($0.id) }
        let ids = list.map(\.id)
        if let n = digit(code), n >= 1 {                                                                         // ⌘1…9, ⇧⌘1…9, ⌥0…9
            if cmd || shiftCmd { guard n <= list.count else { return true }; ClipActions.paste(list[n - 1], invert: shiftCmd); return true }
            if opt { let b = n == 0 ? nil : n <= h.boards.count ? h.boards[n - 1].id : ui.board; ClipActions.pickBoard(b); return true }
        }
        if digit(code) == 0 && opt { ClipActions.pickBoard(nil); return true }
        if let command {                                                                                         // Sources/ClipKeyboard.swift
            let selected = ui.selection.isEmpty ? current(list).map { [$0.id] } ?? [] : ui.selection.ids
            switch command {
            case .otherAction(let shift): if let c = current(list) { ClipActions.otherAction(c, shift: shift) }
            case .toggleFavorite: if let c = current(list) { ClipActions.toggleFavorite(c) }
            case .pinMenu: ClipActions.pinMenu(selected)
            case .deleteItem: ClipActions.delete(selected)
            case .clearHistory: ClipActions.clearMenu()
            case .first: if let f = list.first { h.hovered = f.id; A11y.announce(h.spokenTitle(f)) }
            case .last: if let l = list.last { h.hovered = l.id; A11y.announce(h.spokenTitle(l)) }
            case .page(let n): h.step(n, in: list)
            case .details: if let c = current(list) { ClipActions.open(c) }
            }
            return true
        }
        switch code {
        case 125 where none, 126 where none:                                                                    // ↓ ↑
            h.step(code == 125 ? 1 : -1, in: list); return true
        case 125 where shift, 126 where shift:                                                                  // ⇧↓ ⇧↑: select more
            let cur = ui.selection.step(code == 125 ? 1 : -1, from: h.hovered, in: ids)
            h.hovered = cur
            A11y.announce(String(format: L("%d selected"), ui.selection.count))
            return true
        case 36, 76:                                                                                            // Return, ⇧Return
            guard none || shift else { return false }
            return ClipActions.pasteCurrent(list, invert: shift)
        case 0 where cmd && !editing: ui.selection.selectAll(ids); A11y.announce(String(format: L("%d selected"), ids.count)); return true   // ⌘A
        case 33 where cmd: ClipActions.stepBoard(-1); return true                                              // ⌘[
        case 30 where cmd: ClipActions.stepBoard(1); return true                                               // ⌘]
        case 6 where cmd && !editing: ClipActions.undo(); return true                                          // ⌘Z
        case 8 where cmd && !editing: if let c = current(list) { ClipActions.copy(c) }; return true            // ⌘C
        case 14 where cmd: if let c = current(list), c.kind == .text { ClipActions.open(c); ClipDetail.beginEdit(c) }; return true   // ⌘E
        case 15 where cmd: if let c = current(list) { ClipActions.rename(c) }; return true                     // ⌘R
        case 49 where none && !editing && h.query.isEmpty: if let c = current(list) { ClipActions.open(c) }; return true   // Space: details (typing: a space)
        case 53 where none && !ui.selection.isEmpty: ui.selection.clear(); A11y.announce(L("Selection cleared")); return true
        case 51 where none && !editing, 117 where none && !editing:                                            // Delete
            if !h.query.isEmpty && code == 51 { h.query.removeLast(); return true }                              // the typed filter first
            let sel = ui.selection.isEmpty ? current(list).map { [$0.id] } ?? [] : ui.selection.ids
            ClipActions.delete(sel); return true
        default: break
        }
        // Typing with the list in front filters it (the search field shows what was typed).
        if !editing && (none || shift), let ch = typed(code, flags), ch.count == 1, !h.query.isEmpty || ch != " " {
            h.query += ch
            return true
        }
        return false
    }

    static func current(_ list: [ClipItem]) -> ClipItem? {
        let ui = ClipActions.ui, h = ClipActions.h
        if ui.selection.count == 1, let c = h.items.first(where: { $0.id == ui.selection.ids[0] }) { return c }
        return list.first { $0.id == h.hovered } ?? list.first
    }

    /// The digit of a number key (the top row, by position: the same keys on every layout), or nil.
    static func digit(_ code: UInt16) -> Int? {
        let map: [Int: Int] = [kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5, kVK_ANSI_6: 6, kVK_ANSI_7: 7,
                               kVK_ANSI_8: 8, kVK_ANSI_9: 9, kVK_ANSI_0: 0]
        return map[Int(code)]
    }

    /// The character a key types (letters, digits, punctuation; nothing for control keys).
    static func typed(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> String? {
        guard ShortcutNames.special(UInt32(code)) == nil || code == UInt16(kVK_Space) else { return nil }
        if code == UInt16(kVK_Space) { return " " }
        guard let s = ShortcutNames.translate(UInt32(code)), s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return flags.contains(.shift) ? s.uppercased(with: Language.locale) : s
    }
}

// MARK: - The page

private struct ClipboardPage: View {
    @ObservedObject var h: ClipboardHistory
    @ObservedObject var ui: ClipPageState
    @ObservedObject var engine: PasteEngine
    let box: ModuleBox
    let keyable: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let id = ui.detail, let c = h.items.first(where: { $0.id == id }) {
                ClipDetail(h: h, ui: ui, item: c, box: box).transition(Motion.appear(.trailing, anchor: .trailing))
            } else if box.size == .s {
                compact.transition(Motion.appear(.leading, anchor: .leading))
            } else {
                full.transition(Motion.appear(.leading, anchor: .leading))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CaptureGuard(on: h.settings.hideFromCapture))
        .onDisappear { keyable(false); h.hovered = nil }      // gives the keyboard back if the search field had it
        .onChange(of: h.items.map(\.id)) { _, ids in
            ui.selection.keep(Set(ids))
            if let d = ui.detail, !ids.contains(d) { ui.closeDetail() }
        }
    }

    // The S size: the newest items (or the suggestions), nothing else.
    private var compact: some View {
        let suggested = ui.suggested(h), picked = Set(suggested.map(\.id))
        let list = Array((suggested + h.items.filter { !picked.contains($0.id) }).prefix(box.width >= 400 ? 2 : 1))
        return VStack(alignment: .leading, spacing: Space.s) {
            if list.isEmpty { Text(L("What you copy will show up here")).font(UI.value).foregroundStyle(UI.hint).lineLimit(1) }
            HStack(spacing: Space.l) { ForEach(list) { c in ClipRow(h: h, ui: ui, c: c, list: list, suggested: false, compact: true) } }
        }
    }

    private var full: some View {
        let suggested = ui.suggested(h)
        let picked = Set(suggested.map(\.id))
        let rest = ui.list(h).filter { !picked.contains($0.id) }
        let list = suggested + rest
        let twoColumns = box.width >= 400
        return VStack(alignment: .leading, spacing: Space.s) {
            toolbar
            if box.size == .l { ClipChips(h: h, ui: ui) }
            if list.isEmpty { empty }
            FadingScroll {
                LazyVGrid(columns: twoColumns ? [GridItem(.flexible(), spacing: Space.l), GridItem(.flexible())] : [GridItem(.flexible())],
                          alignment: .leading, spacing: Space.s) {
                    ForEach(list) { c in
                        ClipRow(h: h, ui: ui, c: c, list: list, suggested: suggested.contains { $0.id == c.id }, compact: false)
                            .transition(Motion.appear(.top))
                    }
                }
                .motion(.appear, value: list.map(\.id))
            }
            Spacer(minLength: 0)
            if box.size == .l { bottom }
        }
    }

    private var empty: some View {
        let text: String
        if h.items.isEmpty { text = L("What you copy will show up here") }
        else if let b = ui.board, h.query.isEmpty, ui.kind == nil { text = String(format: L("Nothing on “%@” yet: drag items onto its chip"), h.board(b)?.displayName ?? "") }
        else { text = L("Nothing matches") }
        return Text(text).font(UI.value).foregroundStyle(UI.hint).lineLimit(2)
    }

    private var toolbar: some View {
        HStack(spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(UI.hint)       // a glyph
                TextField(L("Search"), text: $h.query).textFieldStyle(.plain).font(UI.value)
                    .onExitCommand { h.query = "" }
                    .onSubmit { _ = ClipActions.pasteCurrent(ui.suggested(h) + ui.list(h), invert: NSEvent.modifierFlags.contains(.shift)) }
                    .help(L("Filters: type:image app:Safari board:Name from:device date:7d. ↑ ↓ pick, Return pastes"))
                    .accessibilityHint(L("Filters: type:image app:Safari board:Name from:device date:7d. ↑ ↓ pick, Return pastes"))
                if !h.query.isEmpty {
                    Button { h.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(UI.hint)
                            .frame(width: 24, height: 24).contentShape(Rectangle())                         // a 24 pt target
                    }
                    .buttonStyle(MotionGlyphStyle()).help(L("Clear search")).accessibilityLabel(L("Clear search"))
                    .padding(.trailing, -Space.m)                    // the target may reach into the field's padding
                }
            }
            .padding(.horizontal, Space.m).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(0.08)))
            if box.size != .l {                                  // no chips at M: the star filters Favorites
                ClipTool(icon: ui.board == ClipBoard.favoritesID ? "star.fill" : "star", on: ui.board == ClipBoard.favoritesID, title: L("Favorites only")) {
                    ClipActions.pickBoard(ui.board == ClipBoard.favoritesID ? nil : ClipBoard.favoritesID)
                }
            }
            ClipTool(icon: h.paused ? "play.fill" : "pause.fill", on: h.paused, title: h.paused ? L("Resume") : L("Pause")) { ClipActions.pauseMenu() }
            ClipTool(icon: "trash", on: false, title: L("Clear")) {
                IslandChoices.ask(L("Clear"), icon: "trash", IslandChoices.clipboardTrash) { id in
                    if id == "clear" { Motion.with(.appear) { h.clearHistory() } } else { DispatchQueue.main.async { ClipboardUI.confirmDeleteEverything(h, from: .island) } }
                }
            }
        }
    }

    /// The bottom line: the selection's actions, an Undo, else where things are kept or why pasting is copy-only.
    @ViewBuilder private var bottom: some View {
        if !ui.selection.isEmpty {
            ClipSelectionBar(h: h, ui: ui).transition(Motion.appear(.bottom, anchor: .bottom))
        } else if let u = h.undo {
            HStack(spacing: Space.s) {
                Image(systemName: "trash").font(UI.detail).foregroundStyle(UI.hint)
                Text(String(format: L("%d deleted"), u.items.count)).font(UI.detail).foregroundStyle(UI.secondary)
                Button(L("Undo")) { ClipActions.undo() }.buttonStyle(CocaineButtonStyle(kind: .plain, height: 18))
                    .help(L("Undo")).accessibilityHint(L("Brings back what was just deleted"))
                Spacer(minLength: 0)
            }
            .transition(Motion.appear(.bottom, anchor: .bottom))
        } else {
            footer
        }
    }

    @ViewBuilder private var footer: some View {
        if let p = h.problem {
            Label(p, systemImage: "exclamationmark.triangle.fill").font(UI.detail).foregroundStyle(warningColor).lineLimit(1).help(p)
        } else if h.paused {
            let until = h.pausedUntil.map { String(format: L("until %@"), PanelView.timeString($0)) }
            Label(L("Paused: what you copy now isn't kept.") + (until.map { " " + $0 } ?? ""), systemImage: "pause.fill")
                .font(UI.detail).foregroundStyle(UI.hint).lineLimit(1)
        } else if !engine.stack.isEmpty {
            HStack(spacing: Space.s) {
                Label(String(format: L("Paste Stack: %d left, %@ pastes the next"), engine.stack.count, h.settings.pasteNext?.glyphs ?? "—"),
                      systemImage: "square.stack.3d.down.right.fill").font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button(L("Clear")) { engine.clearStack() }.buttonStyle(CocaineButtonStyle(kind: .plain, height: 18))
            }
        } else if h.settings.directPaste && !engine.trusted() {
            HStack(spacing: Space.s) {
                Label(L("Copy only: pasting needs Accessibility"), systemImage: "hand.raised.fill").font(UI.detail).foregroundStyle(UI.hint).lineLimit(1)
                Spacer(minLength: 0)
                Button(L("Allow…")) { Presence.requestAccess() }.buttonStyle(CocaineButtonStyle(kind: .plain, height: 18))
                    .help(L("Opens Privacy & Security → Accessibility"))
            }
        } else {
            Text(h.saving ? L("Saved on this Mac, encrypted. Double-click or Return pastes, ⌘-click selects more.")
                          : L("History in memory, pinboards saved. Double-click or Return pastes, ⌘-click selects more."))
                .font(UI.detail).foregroundStyle(UI.hint).lineLimit(1)
                .help(L("Never from password managers. Pinboards are always saved on this Mac, encrypted."))
        }
    }
}

/// A small square button of the page's toolbar, highlighted while its mode is on (like the selected tab).
struct ClipTool: View {
    let icon: String
    var on = false
    let title: String
    let action: () -> Void
    var body: some View {
        Button { Haptic.tap(.alignment); action() } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(on ? Island.accent : .white.opacity(0.5))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(on ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle()).help(title).accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Chips: pinboards and kinds

private struct ClipChips: View {
    @ObservedObject var h: ClipboardHistory
    @ObservedObject var ui: ClipPageState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.xs) {
                chip(id: "all", title: L("All"), icon: nil, color: nil, on: ui.board == nil, help: L("Everything (⌥0)")) { ClipActions.pickBoard(nil) }
                ForEach(Array(h.boards.enumerated()), id: \.element.id) { i, b in
                    chip(id: b.id.uuidString, title: b.displayName, icon: b.symbol, color: BoardColor.color(b.color), on: ui.board == b.id,
                         help: i < 9 ? b.displayName + " (⌥\(i + 1))" : b.displayName, board: b.id) { ClipActions.pickBoard(ui.board == b.id ? nil : b.id) }
                }
                Button { Haptic.tap(.alignment); ClipActions.newBoard() } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.secondary)
                        .frame(width: 22, height: 20).background(Capsule().fill(CTL.fill)).contentShape(Capsule())
                }
                .buttonStyle(MotionGlyphStyle()).help(L("New pinboard…")).accessibilityLabel(L("New pinboard…"))
                Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 14).padding(.horizontal, Space.xs).accessibilityHidden(true)
                ForEach(kinds, id: \.0) { k, title, icon in
                    chip(id: k.rawValue, title: title, icon: icon, color: nil, on: ui.kind == k, help: title) {
                        Haptic.tap(.alignment)
                        Motion.with(.selection) { ui.kind = ui.kind == k ? nil : k }
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .frame(height: 22)
        .mask(HStack(spacing: 0) {                         // chips that go on past the edge fade out there (it scrolls)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
        })
        .motion(.dragSettle, value: h.boards.map(\.id))
    }

    private var kinds: [(ClipQuery.Kind, String, String)] {
        [(.text, L("Text"), "text.alignleft"), (.image, L("Images"), "photo"), (.file, L("Files"), "doc"), (.link, L("Links"), "link"), (.color, L("Colours"), "paintpalette")]
    }

    private func chip(id: String, title: String, icon: String?, color: Color?, on: Bool, help: String, board: UUID? = nil, _ action: @escaping () -> Void) -> some View {
        let target = board != nil && ui.dropBoard == board
        return Button(action: action) {
            HStack(spacing: Space.xs) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundStyle(color ?? UI.secondary) }
                Text(title).font(UI.detail).lineLimit(1).foregroundStyle(on ? UI.primary : UI.secondary)
            }
            .padding(.horizontal, Space.m).frame(height: 20)
            .background(Capsule().fill(on ? (color ?? Color.white).opacity(0.28) : target ? Island.accent.opacity(0.3) : CTL.fill))
            .overlay(Capsule().strokeBorder(target ? Island.accent : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
            .motionSelection(on)
        }
        .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScale))
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(board != nil ? L("Shows this pinboard. Drop items here to pin them.") : "")
        .onDrop(of: [UTType.text, UTType.fileURL, UTType.png, UTType.image, UTType.data],
                isTargeted: Binding(get: { board != nil && ui.dropBoard == board }, set: { inside in
                    guard let board else { return }
                    if inside { ui.dropBoard = board } else if ui.dropBoard == board { ui.dropBoard = nil }
                })) { _ in
            guard let board, let dragged = ui.dragging else { return false }
            let ids = ui.selection.contains(dragged) ? ui.selection.ids : [dragged]
            Haptic.tap(.alignment)
            h.move(ids, from: ui.board, to: board)
            ui.dragging = nil; ui.dropBoard = nil
            A11y.announce(String(format: L("Pinned to %@"), h.board(board)?.displayName ?? ""))
            return true
        }
    }
}

// MARK: - A row

struct ClipRow: View {
    @ObservedObject var h: ClipboardHistory
    @ObservedObject var ui: ClipPageState
    let c: ClipItem
    let list: [ClipItem]
    let suggested: Bool
    let compact: Bool

    var body: some View {
        let gone = h.missing.contains(c.id), hover = h.hovered == c.id, selected = ui.selection.contains(c.id)
        return HStack(spacing: 0) {
            content(gone: gone)
            if hover && !compact {
                glyph("info.circle", L("Details")) { ClipActions.open(c) }
                glyph("xmark", L("Delete")) { ClipActions.delete([c.id]) }
            }
            if !compact {
                Button { Haptic.tap(.alignment); h.togglePin(c.id) } label: {
                    Image(systemName: c.isFavorite ? "star.fill" : "star").font(.system(size: 10))
                        .foregroundStyle(c.isFavorite ? Island.accent : Color.white.opacity(hover ? 0.65 : 0.4)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(MotionGlyphStyle()).help(c.isFavorite ? L("Remove from favorites") : L("Add to favorites"))
                .accessibilityLabel(c.isFavorite ? L("Remove from favorites") : L("Add to favorites"))
            }
        }
        .padding(.leading, Space.l).padding(.trailing, 1).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Island.accent.opacity(0.24) : Color.white.opacity(hover ? 0.14 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Island.accent.opacity(0.8) : .clear, lineWidth: 1))
        .motionSelection(selected)
        .onHover { inside in if inside { h.hovered = c.id } else if h.hovered == c.id { h.hovered = nil } }
        .help(gone ? L("The file is no longer there") : tip)
        .onDrag {
            ui.dragging = c.id
            return provider()
        }
        .contextMenu { menu(gone: gone) }
    }

    /// The row itself: click selects (⌘ and ⇧ for more), double-click pastes. VoiceOver: activating pastes; the rest are actions.
    private func content(gone: Bool) -> some View {
        HStack(spacing: Space.s) {
            ClipLeading(h: h, c: c)
            Text(ClipRow.title(c)).font(UI.value).lineLimit(1).truncationMode(c.kind == .files ? .middle : .tail)
                .foregroundStyle(gone ? UI.hint : UI.primary)
            if gone { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(warningColor) }   // a badge glyph
            Spacer(minLength: 0)
            badges
        }
        .contentShape(Rectangle())
        .gesture(TapGesture().onEnded { click() })
        .simultaneousGesture(TapGesture(count: 2).onEnded { ClipActions.paste(c, invert: NSEvent.modifierFlags.contains(.shift)) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ClipRow.title(c))
        .accessibilityValue(spokenValue)
        .accessibilityHint(gone ? L("The file is no longer there") : L("Pastes into the app in front"))
        .accessibilityAddTraits(ui.selection.contains(c.id) ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { ClipActions.paste(c) }
        .accessibilityAction(named: L("Copy")) { ClipActions.copy(c) }
        .accessibilityActions {
            if c.kind == .text && c.hasRich {
                Button(h.settings.pastePlain ? L("Paste with formatting") : L("Paste without formatting")) { ClipActions.paste(c, invert: true) }
            }
        }
        .accessibilityAction(named: L("Details")) { ClipActions.open(c) }
        .accessibilityAction(named: ui.selection.contains(c.id) ? L("Deselect") : L("Select")) { ui.selection.toggle(c.id) }
        .accessibilityAction(named: L("Pin to…")) { ClipActions.pinMenu(ui.selection.contains(c.id) ? ui.selection.ids : [c.id]) }
        .accessibilityActions {
            if ClipSyncHook.send != nil { Button(L("Send to iPhone")) { ClipActions.sendToIPhone(ui.selection.contains(c.id) ? ui.selection.ids : [c.id]) } }
        }
        .accessibilityAction(named: L("Delete")) { ClipActions.delete([c.id]) }
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 3) {
            if suggested {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Island.accent)
                    .help(String(format: L("Suggested for %@"), ClipboardHistory.appName(ui.target) ?? ""))
            }
            if c.snippet != nil { Image(systemName: "text.badge.plus").font(.system(size: 9)).foregroundStyle(UI.hint).help(L("Snippet")) }
            if c.remote { Image(systemName: "iphone").font(.system(size: 9)).foregroundStyle(UI.hint).help(L("From another device")) }
            if c.fromIPhone { Image(systemName: "iphone.and.arrow.forward").font(.system(size: 9)).foregroundStyle(UI.hint).help(L("From your iPhone")) }
            ForEach(c.boards.filter { $0 != ClipBoard.favoritesID }.prefix(3), id: \.self) { b in
                Circle().fill(BoardColor.color(h.board(b)?.color ?? 0)).frame(width: 6, height: 6).help(h.board(b)?.displayName ?? "")
            }
            if let n = quickNumber {                                     // opened with the keyboard: ⌘1…⌘9 (Sources/ClipKeyboard.swift)
                Text("⌘\(n)").font(UI.detail.monospacedDigit()).foregroundStyle(UI.hint).fixedSize().accessibilityHidden(true)
            }
        }
        .padding(.trailing, Space.xs)
    }

    /// The number ⌘ pastes this row with, shown while the keyboard is in the clipboard (the first nine rows).
    private var quickNumber: Int? {
        guard !compact, ui.keyboardHints, h.settings.numberHints, let i = list.firstIndex(where: { $0.id == c.id }), i < 9 else { return nil }
        return i + 1
    }

    private var spokenValue: String {
        var parts: [String] = []
        if suggested { parts.append(String(format: L("Suggested for %@"), ClipboardHistory.appName(ui.target) ?? "")) }
        let names = c.boards.compactMap { h.board($0)?.displayName }
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        if c.snippet != nil { parts.append(L("Snippet")) }
        if c.remote { parts.append(L("From another device")) } else if c.fromIPhone { parts.append(L("From your iPhone")) }
        else if let app = ClipboardHistory.appName(c.source) { parts.append(app) }
        if let n = quickNumber { parts.append(String(format: L("Command %d pastes it"), n)) }
        return parts.joined(separator: ", ")
    }

    private func click() {
        let f = NSEvent.modifierFlags
        let ids = list.map(\.id)
        if f.contains(.command) { ui.selection.toggle(c.id) }
        else if f.contains(.shift) { ui.selection.extend(to: c.id, in: ids) }
        else if ui.selection.ids == [c.id] { ui.selection.clear() }
        else { ui.selection.only(c.id) }
        h.hovered = c.id
        Haptic.tap(.alignment)
    }

    private func glyph(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundStyle(UI.hint).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle()).help(title).accessibilityLabel(title)
    }

    @ViewBuilder private func menu(gone: Bool) -> some View {
        Button(L("Paste")) { ClipActions.paste(c) }
        Button(L("Copy")) { ClipActions.copy(c) }
        Button(L("Details")) { ClipActions.open(c) }
        if c.kind == .text { Button(L("Paste as…")) { ClipActions.transformMenu(c) } }
        Button(L("Pin to…")) { ClipActions.pinMenu(ui.selection.contains(c.id) ? ui.selection.ids : [c.id]) }
        Button(L("Rename…")) { ClipActions.rename(c) }
        if c.kind == .files, !gone { Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(c.paths.map { URL(fileURLWithPath: $0) }) } }
        if ClipActions.canShareWithAI { Button(L("Use as AI context")) { ClipActions.shareWithAI(ui.selection.contains(c.id) ? ui.selection.ids : [c.id]) } }
        if ClipSyncHook.send != nil { Button(L("Send to iPhone")) { ClipActions.sendToIPhone(ui.selection.contains(c.id) ? ui.selection.ids : [c.id]) } }
        Divider()
        Button(L("Delete")) { ClipActions.delete(ui.selection.contains(c.id) ? ui.selection.ids : [c.id]) }
    }

    /// Dragged out: the text, the files or the image, to any app; dropped on a chip: pinned (ui.dragging says which).
    private func provider() -> NSItemProvider {
        switch c.kind {
        case .text: return NSItemProvider(object: c.text as NSString)
        case .files: return c.paths.first.map { NSItemProvider(object: URL(fileURLWithPath: $0) as NSURL) } ?? NSItemProvider()
        case .image:
            let p = NSItemProvider()
            if let png = h.imageData(c) { p.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in done(png, nil); return nil } }
            return p
        }
    }

    static func title(_ c: ClipItem) -> String {
        if let t = c.title, !t.isEmpty { return t }
        switch c.kind {
        case .text: return String(c.text.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        case .image: return L("Image") + " · \(c.width)×\(c.height)"
        case .files: return (c.names.first ?? "") + (c.names.count > 1 ? " +\(c.names.count - 1)" : "")
        }
    }

    private var tip: String {
        var parts: [String] = []
        if let t = c.title { parts.append(t) }
        switch c.kind {
        case .text: parts.append(String(c.text.prefix(300)))
        case .image: parts.append(L("Image") + " · \(c.width)×\(c.height) · " + Int64(c.bytes).formatted(.byteCount(style: .file).locale(Language.locale)))
        case .files: parts.append(c.paths.prefix(5).joined(separator: "\n"))
        }
        if let app = ClipboardHistory.appName(c.source) { parts.append(app) }
        parts.append(c.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Language.locale)))
        return parts.joined(separator: "\n")
    }
}

/// A row's leading picture: a thumbnail, a file icon, a colour swatch or a link glyph.
struct ClipLeading: View {
    @ObservedObject var h: ClipboardHistory
    let c: ClipItem
    var body: some View {
        switch c.kind {
        case .text:
            if let col = ClipLooks.color(c.text) {
                RoundedRectangle(cornerRadius: 3).fill(Color(.sRGB, red: col.r, green: col.g, blue: col.b, opacity: col.a))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5)).frame(width: 14, height: 14)
            } else if ClipLooks.isLink(c.text) {
                Image(systemName: "link").font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.secondary).frame(width: 14)
            } else if c.hasRich {
                Image(systemName: "textformat").font(.system(size: 9, weight: .semibold)).foregroundStyle(UI.hint).frame(width: 14)
                    .help(L("Formatted text"))
            }
        case .image:
            Group {
                if let t = h.thumbnail(c) { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) } else { Color.white.opacity(0.1) }
            }
            .frame(width: 22, height: 16).clipShape(RoundedRectangle(cornerRadius: 3))
        case .files:
            Image(nsImage: NSWorkspace.shared.icon(forFile: c.paths.first ?? "/")).resizable().frame(width: 16, height: 16)
        }
    }
}

// MARK: - The selection's actions

private struct ClipSelectionBar: View {
    @ObservedObject var h: ClipboardHistory
    @ObservedObject var ui: ClipPageState

    /// With labels when they fit (in this language), else the symbols alone (their names stay for VoiceOver and the tooltip).
    var body: some View {
        ViewThatFits(in: .horizontal) { bar(labels: true); bar(labels: false) }
    }

    private func bar(labels: Bool) -> some View {
        let ids = ui.selection.ids
        let texts = ids.compactMap { id in h.items.first { $0.id == id } }.filter { $0.kind != .image }.count
        let action = { (title: String, icon: String, run: @escaping () -> Void) in self.action(title, icon, labels: labels, run) }
        return HStack(spacing: Space.xs) {
            Text(String(format: L("%d selected"), ids.count)).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1).fixedSize()
            Spacer(minLength: Space.xs)
            action(ids.count > 1 ? L("Paste all") : L("Paste"), "doc.on.clipboard") { _ = ClipActions.pasteCurrent([]) }
            if ids.count > 1 { action(L("Stack"), "square.stack.3d.down.right") { ClipActions.stack(ids) } }
            if ids.count > 1 && texts > 1 { action(L("Merge"), "arrow.triangle.merge") { ClipActions.merge(ids) } }
            if ids.count == 1, let c = h.items.first(where: { $0.id == ids[0] }) { action(L("Details"), "info.circle") { ClipActions.open(c) } }
            action(L("Pin"), "pin") { ClipActions.pinMenu(ids) }
            if ClipActions.canShareWithAI { action(L("AI"), "sparkles") { ClipActions.shareWithAI(ids) } }
            if ClipSyncHook.send != nil { action(L("Send to iPhone"), "iphone.and.arrow.forward") { ClipActions.sendToIPhone(ids) } }
            action(L("Delete"), "trash") { ClipActions.delete(ids) }
            Button { ui.selection.clear() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(UI.hint).frame(width: 20, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(MotionGlyphStyle()).help(L("Clear the selection (Esc)")).accessibilityLabel(L("Clear the selection (Esc)"))
        }
        .frame(height: 18)
    }

    private func action(_ title: String, _ icon: String, labels: Bool, _ run: @escaping () -> Void) -> some View {
        Button { Haptic.tap(.alignment); run() } label: {
            if labels { Label(title, systemImage: icon).labelStyle(.titleAndIcon).font(UI.detail) }
            else { Image(systemName: icon).font(UI.detail) }
        }
        .buttonStyle(CocaineButtonStyle(kind: .plain, height: 18))
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
    }
}

/// While on, the island's window isn't captured by screenshots, recordings or screen sharing (macOS honours this for most
/// capture paths; some capture tools may not), and only while this page is shown.
private struct CaptureGuard: NSViewRepresentable {
    let on: Bool
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ v: NSView, context: Context) { (v as? Probe)?.wanted = on; (v as? Probe)?.apply() }
    static func dismantleNSView(_ v: NSView, coordinator: ()) { (v as? Probe)?.wanted = false; (v as? Probe)?.apply() }
    final class Probe: NSView {
        var wanted = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            guard let w = window else { return }
            let t: NSWindow.SharingType = wanted ? .none : .readOnly
            if w.sharingType != t { w.sharingType = t }
        }
    }
}

/// The page in the floating clipboard (Sources/ClipKeyboard.swift): the same page as the island's, at its L size.
struct ClipboardPopupContent: View {
    let box: ModuleBox
    let keyable: (Bool) -> Void
    var body: some View { ClipboardPage(h: .shared, ui: .shared, engine: .shared, box: box, keyable: keyable) }
}

extension IslandView {
    // MARK: clipboard

    /// The history: two columns of items on a wide box, one in the island's narrow column; S shows the newest only.
    func clipboardModule(_ b: ModuleBox) -> some View {
        ClipboardPage(h: clipboard, ui: .shared, engine: .shared, box: b, keyable: model.setKeyable)
    }
}
