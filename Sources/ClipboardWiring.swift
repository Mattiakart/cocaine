// Connects the clipboard's parts to the island and the app, in one place (one call from Sources/IslandController.swift): pasting
// closes the island and speaks through its HUD, the clipboard's global shortcuts, the command line's socket (only while allowed),
// text recognition of new images, the app in front when the island opens (suggestions), and the seams other features use
// (PasteHook in Sources/ExtensionHooks.swift).

import AppKit
import Combine

enum ClipboardWiring {
    private static var subs: [AnyCancellable] = []
    /// The island's keyboard (the search field, the editor, a shortcut being recorded).
    static var keyable: (Bool) -> Void = { _ in }
    /// The text an edit replaced (⌘Z in the list puts it back), with its item.
    static var lastEdit: (id: UUID, text: String)?

    /// The island's model and what its controller can do. Called once at launch.
    static func attach(model: IslandModel, openKeyboard: @escaping () -> Void, close: @escaping () -> Void) {
        let h = model.clipboard, engine = PasteEngine.shared, ui = ClipPageState.shared
        keyable = { [weak model] on in
            if ClipPopup.shared.isOpen { ClipPopup.shared.keyable(on); return }     // the floating clipboard has the keyboard already
            model?.setKeyable(on)
        }
        engine.closeIsland = { [weak model] in
            ClipPopup.shared.close(restore: false)                       // pasting from the floating clipboard closes it too
            guard let model else { return }
            model.setKeyable(false)
            if model.open { close() }
        }
        engine.notify = { [weak model] icon, text in model?.flashNotice(icon, text) }
        h.onImage = { [weak h] item in h?.indexImage(item) }
        h.onBoardsChange = { [weak h] in
            guard let h else { return }
            if ClipShortcutRecorder.shared.recording != nil { return }
            ClipHotKeys.shared.apply(ClipHotKeys.wanted(settings: h.settings, stackActive: !engine.stack.isEmpty, boards: h.boards, items: h.items))
        }
        ClipHotKeys.shared.perform = { [weak h, weak model] t in
            guard let h else { return }
            switch t {
            case .open:                                                  // Sources/ClipKeyboard.swift: the island or the floating panel
                guard h.running else { return }
                ClipKeyboard.open(model: model, openKeyboard: openKeyboard)
            case .pasteNext: engine.pasteNext()
            case .snippet(let id): if let c = h.items.first(where: { $0.id == id }) { SnippetPaste.paste(c, engine: engine) }
            case .board(let id):                                         // the island, keyboard in it, on that pinboard
                ui.board = id; ui.detail = nil; ui.selection.clear()
                if let model, !(model.open && model.keyboard) { model.tab = "clipboard"; openKeyboard() } else { model?.tab = "clipboard" }
            }
        }
        ClipShortcutRecorder.shared.save = { [weak h] t, s in
            guard let h else { return }
            switch t {
            case .open: var n = h.settings; n.openShortcut = s; h.update(n)
            case .pasteNext: var n = h.settings; n.pasteNext = s; h.update(n)
            case .board(let id): h.editBoards { b in guard let i = b.firstIndex(where: { $0.id == id }) else { return false }; b[i].hotkey = s; return true }
            case .snippet(let id): h.modify(id) { $0.snippet = SnippetInfo(hotkey: s) }
            }
            keyable(false)
            h.onBoardsChange()
        }
        ClipShortcutRecorder.shared.check = { [weak h] t, s in
            guard let h else { return nil }
            return ClipHotKeys.problem(s, for: t, settings: h.settings, boards: h.boards, items: h.items,
                                       appShortcuts: Array(ShortcutCenter.shared.map.values), system: ShortcutRules.systemShortcuts())
        }
        // The command line's socket exists only while it is allowed.
        subs.append(h.$settings.map(\.cliAccess).removeDuplicates().sink { level in
            if level > 0 { if !ClipServer.shared.start() { log.notice("clipboard: command line socket not started") } } else { ClipServer.shared.stop() }
        })
        // Opening the island: the app in front then is the one suggestions are for (Cocaine's own panel is not).
        subs.append(model.$open.removeDuplicates().sink { open in
            guard open else {
                if ui.editing && !ClipPopup.shared.isOpen { ui.editing = false }
                if !ClipPopup.shared.isOpen { ui.keyboardHints = false }      // the ⌘1…9 marks are for a keyboard opening only
                return
            }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ui.target = front == Bundle.main.bundleIdentifier ? nil : front
        })
        subs.append(engine.$stack.map(\.isEmpty).removeDuplicates().dropFirst().sink { [weak h] _ in h?.onBoardsChange() })
        registerHooks(history: h, engine: engine)
    }

    /// PasteHook (Sources/ExtensionHooks.swift): other features paste a clipboard item by its id.
    static func registerHooks(history h: ClipboardHistory, engine: PasteEngine) {
        PasteHook.paste = { [weak h] id, plain in
            guard let h, let uuid = UUID(uuidString: id), let c = h.items.first(where: { $0.id == uuid }) else { return }
            SnippetPaste.paste(c, engine: engine, plain: plain)
        }
    }
}
