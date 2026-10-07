// The custom actions' extras: a key per action (⌥1…⌥9 while the shelf has the keyboard), chaining (A's output files go on to
// B, at most 4 steps, never in a loop), export and import as JSON (no secrets, no approvals: imported actions ask before their
// first run, webhook headers stay in this Mac's Keychain) and the Settings row for them (key, next action, a webhook's method,
// body and secret headers).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ShelfActionKeys {
    /// The digit row's key codes, 1…9 (the same keys on every layout).
    static let codes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    /// The action ⌥ + a digit runs, if one has that key.
    static func action(_ code: UInt16, flags: NSEvent.ModifierFlags, in actions: [ShelfAction]) -> ShelfAction? {
        guard flags.intersection([.command, .control, .option, .shift]) == .option, let n = codes[code] else { return nil }
        return actions.first { $0.key == n }
    }

    static func name(_ n: Int?) -> String { n.map { "⌥\($0)" } ?? L("None") }
}

enum ShelfActionChain {
    static let maxDepth = 4

    /// The next action after `a`, unless the chain is already `maxDepth` long or would come back to an action in it.
    static func next(after a: ShelfAction, in actions: [ShelfAction], depth: Int) -> ShelfAction? {
        guard depth + 1 < maxDepth, let id = a.then, id != a.id, let b = actions.first(where: { $0.id == id }) else { return nil }
        // A loop (B → … → A) stops here: walk B's chain and refuse if it reaches A within the limit.
        var seen: Set<UUID> = [a.id]
        var cur: ShelfAction? = b
        var steps = 0
        while let c = cur, steps < maxDepth {
            if seen.contains(c.id) { return nil }
            seen.insert(c.id)
            cur = c.then.flatMap { t in actions.first { $0.id == t } }
            steps += 1
        }
        return b
    }

    /// What the next action gets: files the first one printed (one absolute path per line, existing) or moved, else the same.
    static func files(output: String, moved: [URL], fallback: [URL], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [URL] {
        if !moved.isEmpty { return moved }
        let paths = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") && exists($0) }
        return paths.isEmpty ? fallback : paths.prefix(ShelfActionEngine.maxFiles).map { URL(fileURLWithPath: $0) }
    }
}

enum ShelfActionIO {
    static let format = "cocaine.shelf-actions"
    static let maxBytes = 1 << 20

    private struct File: Codable { var format: String; var v: Int; var actions: [ShelfAction] }

    /// The actions as JSON: no approvals (whoever imports them is asked again), no secrets (they are in the Keychain).
    static func export(_ actions: [ShelfAction]) -> Data {
        let clean = actions.map { a -> ShelfAction in var c = a; c.approved = nil; return c }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(File(format: format, v: 1, actions: clean))) ?? Data()
    }

    enum Problem: Error, Equatable { case tooBig, notActions, full }

    /// The actions to add from an exported file: new ids (their chains follow), not approved, keys already used dropped, at
    /// most as many as there is room for.
    static func `import`(_ data: Data, existing: [ShelfAction]) throws -> [ShelfAction] {
        guard data.count <= maxBytes else { throw Problem.tooBig }
        guard let f = try? JSONDecoder().decode(File.self, from: data), f.format == format, f.v == 1 else { throw Problem.notActions }
        let room = ShelfConfig.maxActions - existing.count
        guard room > 0 else { throw Problem.full }
        let list = Array(f.actions.prefix(room))
        var ids: [UUID: UUID] = [:]
        for a in list { ids[a.id] = UUID() }
        var usedKeys = Set(existing.compactMap(\.key))
        return list.map { a in
            var c = a
            c.id = ids[a.id]!
            c.approved = nil
            c.then = a.then.flatMap { ids[$0] }
            c.name = String(a.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ShelfLimits.nameChars))
            if c.name.isEmpty { c.name = c.kindTitle }
            if let k = c.key { if !(1...9).contains(k) || usedKeys.contains(k) { c.key = nil } else { usedKeys.insert(k) } }
            c.timeout = max(1, min(3600, c.timeout))
            return c
        }
    }
}

// MARK: - Settings

/// The actions section's Import… / Export… (the system's open and save panels: picking a file is the point).
struct ShelfActionsIOButtons: View {
    @ObservedObject var config: ShelfConfigStore

    var body: some View {
        HStack(spacing: Space.s) {
            Button(L("Import…")) { importFile() }.buttonStyle(CocaineButtonStyle())
            Button(L("Export…")) { exportFile() }.buttonStyle(CocaineButtonStyle())
                .disabled(config.config.actions.isEmpty).opacity(config.config.actions.isEmpty ? CTL.disabled : 1)
        }
    }

    private func exportFile() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Cocaine actions.json"
        p.allowedContentTypes = [.json]
        p.message = L("The actions are saved without secrets; whoever imports them is asked before each one first runs.")
        NSApp.activate()
        p.begin { r in
            guard r == .OK, let u = p.url else { return }
            if !SafeFile.writePrivate(ShelfActionIO.export(config.config.actions), to: u, folderMode: 0o755) {
                DialogCenter.shared.present(Dialogs.message(L("Couldn't save the file"), nil, surface: .panel)) { _ in }
            }
        }
    }

    private func importFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.allowsMultipleSelection = false
        NSApp.activate()
        p.begin { r in
            guard r == .OK, let u = p.url else { return }
            do {
                let d = try Data(contentsOf: u, options: .mappedIfSafe)
                let new = try ShelfActionIO.import(d, existing: config.config.actions)
                config.update { $0.actions += new }
                DialogCenter.shared.present(Dialogs.message(String(format: L("%d actions imported"), new.count),
                                                            L("Each one asks before it first runs."), error: false, surface: .panel)) { _ in }
            } catch let e as ShelfActionIO.Problem {
                let text: String
                switch e {
                case .tooBig: text = L("The file is too big")
                case .notActions: text = L("The file isn't an export of Cocaine actions")
                case .full: text = String(format: L("At most %d actions"), ShelfConfig.maxActions)
                }
                DialogCenter.shared.present(Dialogs.message(L("Couldn't import"), text, surface: .panel)) { _ in }
            } catch {
                DialogCenter.shared.present(Dialogs.message(L("Couldn't import"), error.localizedDescription, surface: .panel)) { _ in }
            }
        }
    }
}

/// Under an action's row: its key, the action that runs next, and a webhook's method, body and secret headers.
struct ShelfActionExtras: View {
    let action: ShelfAction
    @ObservedObject var config: ShelfConfigStore

    var body: some View {
        let a = action
        VStack(alignment: .leading, spacing: Space.s) {
            if a.kind == .webhook {
                HStack(spacing: Space.m) {
                    ValueButton(id: "shelf.hook.method.\(a.id)", title: L("Method"), value: (a.hook ?? WebhookSpec()).method, maxWidth: 90, spec: {
                        PickerSpec(id: "shelf.hook.method.\(a.id)", title: L("Method"), items: ["POST", "PUT"].map { PickerItem(id: $0, title: $0) },
                                   mode: .single((a.hook ?? WebhookSpec()).method))
                    }, onPick: { m in config.updateAction(a.id) { var h = $0.hook ?? WebhookSpec(); h.method = m; $0.hook = h; $0.approved = nil } })
                    ValueButton(id: "shelf.hook.body.\(a.id)", title: L("Send"), value: Self.bodyName((a.hook ?? WebhookSpec()).body), maxWidth: 150, spec: {
                        PickerSpec(id: "shelf.hook.body.\(a.id)", title: L("Send"), items: WebhookSpec.Body.allCases.map { PickerItem(id: $0.rawValue, title: Self.bodyName($0)) },
                                   mode: .single((a.hook ?? WebhookSpec()).body.rawValue))
                    }, onPick: { b in config.updateAction(a.id) { var h = $0.hook ?? WebhookSpec(); h.body = WebhookSpec.Body(rawValue: b) ?? .file; $0.hook = h; $0.approved = nil } })
                    Spacer(minLength: 0)
                    Button(L("Secret headers…")) { editHeaders(a) }.buttonStyle(CocaineButtonStyle())
                }
            }
            HStack(spacing: Space.m) {
                Text(L("Key")).font(UI.detail).foregroundStyle(UI.secondary)
                ValueButton(id: "shelf.key.\(a.id)", title: L("Key"), value: ShelfActionKeys.name(a.key), maxWidth: 80, spec: {
                    PickerSpec(id: "shelf.key.\(a.id)", title: L("Key"), items: [PickerItem(id: "0", title: L("None"))] + (1...9).map { n in
                        let owner = config.config.actions.first { $0.key == n && $0.id != a.id }
                        return PickerItem(id: String(n), title: "⌥\(n)" + (owner.map { " · " + $0.name } ?? ""))
                    }, mode: .single(String(a.key ?? 0)))
                }, onPick: { id in
                    let n = Int(id) ?? 0
                    config.update { c in
                        for i in c.actions.indices where c.actions[i].key == n { c.actions[i].key = nil }    // one action per key
                        if let i = c.actions.firstIndex(where: { $0.id == a.id }) { c.actions[i].key = n == 0 ? nil : n }
                    }
                })
                .fixedSize()
                Text(L("Then")).font(UI.detail).foregroundStyle(UI.secondary)
                ValueButton(id: "shelf.then.\(a.id)", title: L("Then"), value: config.config.actions.first { $0.id == a.then }?.name ?? L("None"), maxWidth: 150, spec: {
                    PickerSpec(id: "shelf.then.\(a.id)", title: L("Then"),
                               items: [PickerItem(id: "none", title: L("None"))] + config.config.actions.filter { $0.id != a.id }.map { PickerItem(id: $0.id.uuidString, title: $0.name, symbol: $0.symbol) },
                               mode: .single(a.then?.uuidString ?? "none"))
                }, onPick: { id in config.updateAction(a.id) { $0.then = UUID(uuidString: id) } })
                .fixedSize()
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, UI.iconColumn + Space.m)
    }

    static func bodyName(_ b: WebhookSpec.Body) -> String {
        switch b { case .file: return L("The files"); case .json: return L("Their details (JSON)") }
    }

    /// The headers go to the Keychain, never into the settings or an export.
    private func editHeaders(_ a: ShelfAction) {
        let account = ShareWebhook.secretAccount(a.id)
        let has = !((try? ShelfActionEngine.secrets.load(account))?["headers"] ?? "").isEmpty
        let spec = DialogSpec(icon: "key", title: L("Secret headers"),
                              message: (has ? L("Saved in the Keychain. Type new ones to replace them, or leave empty to remove them.") + " " : "")
                                + L("One header, e.g. Authorization: Bearer <token>. Kept in the Keychain on this Mac."),
                              field: DialogField(placeholder: L("Name: value"), validate: { t in
                                  t.trimmingCharacters(in: .whitespaces).isEmpty || !ShareWebhook.headers(t).isEmpty ? nil : L("Type it as Name: value")
                              }),
                              buttons: [DialogButton(id: "ok", title: L("Save"), needsValidInput: true), Dialogs.cancel], surface: .panel)
        DialogCenter.shared.present(spec) { r in
            guard case .button("ok", let text, _) = r else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { try? ShelfActionEngine.secrets.delete(account) } else { try? ShelfActionEngine.secrets.save(account, ["headers": t]) }
        }
    }
}
