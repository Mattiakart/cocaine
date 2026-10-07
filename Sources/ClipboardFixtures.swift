// `--clipboard-fixture <name>` for --render-island and --render-panel: sample clipboard states drawn offscreen (never the user's
// history: everything here is made up and kept in memory).

import AppKit

enum ClipboardFixtures {
    static let names = ["list", "boards", "board", "select", "suggest", "undo", "stack", "noaccess", "empty-board",
                        "detail-text", "detail-json", "detail-color", "detail-link", "detail-image", "detail-files", "edit", "snippet",
                        "size-s", "size-m", "narrow", "settings"]

    /// Before the island's model is made: a layout that draws the clipboard module at S or M, or in the narrow column.
    static func layout(_ args: [String]) {
        guard let name = value(args) else { return }
        var l = ScreenLayout.standard
        switch name {
        case "size-s", "size-m":
            l.merge("clipboard", into: "status")
            l.setSize("clipboard", in: "status", name == "size-s" ? .s : .m)
            if name == "size-s" { l.setSize("batteries", in: "status", .s) }
        case "narrow":
            l.merge("clipboard", into: "status")
            l.removeModule("batteries", from: "status")
        default: return
        }
        ScreenLayoutStore.shared.set(l)
    }

    private static func value(_ args: [String]) -> String? {
        guard let i = args.firstIndex(of: "--clipboard-fixture"), i + 1 < args.count else { return nil }
        guard names.contains(args[i + 1]) else {
            FileHandle.standardError.write(Data("unknown clipboard fixture \(args[i + 1]): \(names.joined(separator: ", "))\n".utf8))
            exit(64)
        }
        return args[i + 1]
    }

    /// The sample history, pinboards and page state for `name`.
    static func apply(_ args: [String], _ im: IslandModel?) {
        guard let name = value(args) else { return }
        let h = ClipboardHistory.shared, ui = ClipPageState.shared, e = PasteEngine.shared
        let now = Date()
        let prompts = ClipBoard(name: L("Prompts"), color: 5, icon: "sparkles", app: "com.apple.Terminal")
        let code = ClipBoard(name: "SQL", color: 3, icon: "terminal.fill", app: "com.tinyapp.TablePlus",
                             hotkey: Shortcut(keyCode: 1, mods: Shortcut.hyper))
        let addresses = ClipBoard(name: L("Addresses"), color: 1, icon: "envelope.fill")
        h.replaceBoards([.favorites, prompts, code, addresses])
        var a = ClipItem.text("Riassumi questo testo in tre punti, in italiano, senza perdere i numeri", date: now, source: "com.apple.Safari")
        a.boards = [prompts.id]; a.snippet = SnippetInfo(); a.title = L("Summary prompt")
        var b = ClipItem.text("SELECT id, email FROM users WHERE created_at > now() - interval '7 days';", date: now - 60, source: "com.tinyapp.TablePlus")
        b.boards = [code.id]; b.used = ["com.tinyapp.TablePlus": 3]
        var c = ClipItem.text("{\"name\": \"Cocaine\", \"version\": \"2.7\", \"features\": [\"pinboards\", \"snippets\", \"paste\"]}", date: now - 120)
        c.boards = [ClipBoard.favoritesID]
        let d = ClipItem.text("#ff6b9d", date: now - 180, source: "com.figma.Desktop")
        var f = ClipItem.text("https://github.com/Mattiakart/cocaine/releases", date: now - 240, source: "com.apple.Safari")
        f.used = ["com.apple.Terminal": 2]
        var g = ClipItem.text("Via Roma 12, 20121 Milano", date: now - 300, source: ClipRules.remoteSource)
        g.boards = [addresses.id, ClipBoard.favoritesID]
        let rtf = Data("{\\rtf1 x}".utf8)
        let rich = ClipItem.text("Ciao Mario, ti mando il file domani mattina", date: now - 360, source: "com.apple.mail", rich: ClipRich(rtf: rtf, html: nil))
        let img = ClipItem.image(png: sampleImage(), width: 640, height: 360, date: now - 420, source: "com.apple.screencaptureui")
        var imgOCR = img; imgOCR.ocr = "Invoice 2026-114\nTotal 1.240,00 €"
        let file = ClipItem.files(["/System/Library/CoreServices/Finder.app", "/Applications/Safari.app"], date: now - 480, source: "com.apple.finder")
        h.replace([a, b, c, d, f, g, rich, imgOCR, file])
        ui.board = nil; ui.kind = nil; ui.selection.clear(); ui.detail = nil; ui.editing = false; ui.target = nil
        e.trusted = { true }
        switch name {
        case "board": ui.board = prompts.id
        case "empty-board": ui.board = addresses.id; h.replace([a, b])
        case "select": ui.selection.only(b.id); ui.selection.toggle(c.id); ui.selection.toggle(f.id)
        case "suggest": ui.target = "com.tinyapp.TablePlus"
        case "undo": h.replace([a, c, d]); h.remove([b.id])
        case "stack": e.startStack([a.id, b.id, c.id]); e.closeIsland = {}
        case "noaccess": e.trusted = { false }
        case "detail-text": ui.detail = rich.id
        case "detail-json": ui.detail = c.id
        case "detail-color": ui.detail = d.id
        case "detail-link": ui.detail = f.id
        case "detail-image": ui.detail = img.id
        case "detail-files": ui.detail = file.id
        case "snippet": ui.detail = a.id
        case "edit": ui.detail = b.id; ui.editText = b.text + "\nLIMIT 50;"; ui.editing = true
        default: break
        }
        if let im, name != "settings" { im.open = true; im.tab = name.hasPrefix("size") || name == "narrow" ? "status" : "clipboard" }
    }

    /// A sample screenshot-like picture (made here, never read from disk).
    static func sampleImage() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 360, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: NSColor(calibratedRed: 0.2, green: 0.3, blue: 0.6, alpha: 1), ending: NSColor(calibratedRed: 0.8, green: 0.4, blue: 0.6, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: 640, height: 360), angle: 30)
        NSString(string: "Invoice 2026-114").draw(at: NSPoint(x: 40, y: 200), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 44), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
