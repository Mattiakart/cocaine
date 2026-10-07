// The Shelf card of the settings' Island tab: the collections (rename, colour, delete), how dragging behaves, the watched
// folders (on/off, where files land, their rules, the batch delay, whether macOS lets Cocaine read them) and the custom actions
// (added only here: a script, a Shortcut, a workflow, an app or a folder; output, instant, a test run). Dialogs and dropdowns
// are the app's own, on the panel.

import AppKit
import SwiftUI

/// The card's content (PanelView puts it in a card titled "Shelf").
struct ShelfSettingsView: View {
    var body: some View {
        if let c = ShelfEntry.settingsCenter {
            ShelfSettingsBody(center: c, store: c.store, config: c.config, watch: c.watch)
        } else {
            Text(L("Turn the island on to use the shelf")).font(UI.detail).foregroundStyle(UI.secondary)
        }
    }
}

extension ShelfEntry {
    /// The shelf the settings show: the island's; for renders, a sample one in memory.
    static var settingsCenter: ShelfCenter? {
        if let c = center { return c }
        guard AppDefaults.isolated else { return nil }
        if sample == nil { sample = ShelfFixtures.center("settings") }
        return sample
    }
    private static var sample: ShelfCenter?
}

struct ShelfSettingsBody: View {
    @ObservedObject var center: ShelfCenter
    @ObservedObject var store: ShelfStore
    @ObservedObject var config: ShelfConfigStore
    @ObservedObject var watch: WatchedFolders
    @ObservedObject var pickers = PickerCenter.shared
    @StateObject private var open = ShelfSettingsState()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            section(L("Collections")) {
                Button(L("New…")) { pickers.close(); newCollection() }.buttonStyle(CocaineButtonStyle())
            }
            ForEach(store.collections) { c in collectionRow(c) }
            divider
            row(L("Remove after dragging out"), detail: L("Off: items stay on the shelf and follow a file you moved")) {
                CocaineSwitch(on: config.config.removeAfterDragOut) { config.update { $0.removeAfterDragOut.toggle() } }.accessibilityLabel(L("Remove after dragging out"))
            }
            row(L("Shake to open"), detail: L("Shake the pointer while dragging files: the island opens on the shelf")) {
                CocaineSwitch(on: config.config.shakeToOpen) { config.update { $0.shakeToOpen.toggle() } }.accessibilityLabel(L("Shake to open"))
            }
            row(L("Instant actions"), detail: L("Hold ⌥ while dragging over the island to drop files straight onto an action")) {
                CocaineSwitch(on: config.config.instantActions) { config.update { $0.instantActions.toggle() } }.accessibilityLabel(L("Instant actions"))
            }
            divider
            section(L("Watched folders")) {
                ValueButton(id: "shelf.addFolder", title: L("Add a watched folder"), value: L("Add…"), spec: { addFolderSpec }, onPick: { addFolder($0) })
            }
            if config.config.watched.isEmpty {
                Text(L("New files in a watched folder land on the shelf, e.g. your screenshots or downloads")).font(UI.detail).foregroundStyle(UI.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(config.config.watched) { f in folderRow(f) }
            divider
            section(L("Your actions")) {
                HStack(spacing: Space.s) {
                    ShelfActionsIOButtons(config: config)                         // Sources/ShelfActionsIO.swift
                    ValueButton(id: "shelf.addAction", title: L("Add an action"), value: L("Add…"), spec: { addActionSpec }, onPick: { addAction($0) })
                }
            }
            if config.config.actions.isEmpty {
                Text(L("Scripts, Shortcuts, workflows, apps or folders to use on the selected items. Files are passed one by one, never through a shell line."))
                    .font(UI.detail).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(config.config.actions) { a in actionRow(a) }
        }
    }

    // MARK: building blocks (the panel's look)

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.vertical, 2) }

    private func section<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: Space.m) {
            Text(title).font(UI.groupTitle).lineLimit(1)
            Spacer(minLength: Space.m)
            trailing().fixedSize()
        }
        .frame(minHeight: 22)
    }

    private func row<Control: View>(_ title: String, detail: String? = nil, warning: Bool = false, @ViewBuilder _ control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(UI.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(UI.detail).foregroundStyle(warning ? warningColor : UI.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()
        }
        .frame(minHeight: 22)
        .fixedSize(horizontal: false, vertical: true)
        .help(detail ?? title)
    }

    private func icon(_ symbol: String, _ title: String, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: { Haptic.tap(.alignment); action() }) {
            Image(systemName: symbol).font(UI.icon).foregroundStyle(destructive ? CTL.destructiveInk : UI.secondary)
                .frame(width: CTL.h, height: CTL.h).contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle()).help(title).accessibilityLabel(title)
    }

    // MARK: collections

    private func collectionRow(_ c: ShelfCollection) -> some View {
        HStack(spacing: Space.s) {
            Button { Haptic.tap(.alignment); store.recolorCollection(c.id, (c.color + 1) % ShelfColors.count) } label: {
                Circle().fill(ShelfTabs.color(c.color)).frame(width: 10, height: 10).frame(width: CTL.h, height: CTL.h).contentShape(Rectangle())
            }
            .buttonStyle(MotionGlyphStyle()).help(L("Change the colour")).accessibilityLabel(L("Colour")).accessibilityValue(ShelfColors.name(c.color))
            Text(c.title).font(UI.title).lineLimit(1).truncationMode(.middle)
            Text(String(format: L("%d items"), c.items.count)).font(UI.detail).foregroundStyle(UI.hint).lineLimit(1)
            Spacer(minLength: Space.s)
            icon("pencil", L("Rename…")) { pickers.close(); rename(c) }
            icon("trash", L("Delete…"), destructive: true) { pickers.close(); center.deleteCollection(c.id, surface: .panel) }
                .disabled(store.collections.count < 2).opacity(store.collections.count < 2 ? CTL.disabled : 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func newCollection() {
        let spec = DialogSpec(icon: "plus.rectangle.on.rectangle", title: L("New collection"),
                              field: DialogField(placeholder: L("Name"), validate: { $0.trimmingCharacters(in: .whitespaces).isEmpty ? L("Give it a name") : nil }),
                              buttons: [DialogButton(id: "ok", title: L("Create"), needsValidInput: true), Dialogs.cancel], surface: .panel)
        DialogCenter.shared.present(spec) { r in
            guard case .button("ok", let text, _) = r else { return }
            _ = store.createCollection(text, select: false)
        }
    }

    private func rename(_ c: ShelfCollection) {
        let spec = DialogSpec(icon: "pencil", title: L("Rename collection"),
                              field: DialogField(placeholder: L("Name"), text: c.title, validate: { $0.trimmingCharacters(in: .whitespaces).isEmpty ? L("Give it a name") : nil }),
                              buttons: [DialogButton(id: "ok", title: L("Rename"), needsValidInput: true), Dialogs.cancel], surface: .panel)
        DialogCenter.shared.present(spec) { r in
            guard case .button("ok", let text, _) = r else { return }
            store.renameCollection(c.id, text)
        }
    }

    // MARK: watched folders

    private var addFolderSpec: PickerSpec {
        var items: [PickerItem] = []
        if !config.config.watched.contains(where: { $0.preset == .screenshots }) { items.append(PickerItem(id: "screenshots", title: L("Screenshots"), symbol: "camera.viewfinder")) }
        if !config.config.watched.contains(where: { $0.preset == .downloads }) { items.append(PickerItem(id: "downloads", title: L("Downloads"), symbol: "arrow.down.circle")) }
        items.append(PickerItem(id: "choose", title: L("Choose a folder…"), symbol: "folder.badge.plus"))
        return PickerSpec(id: "shelf.addFolder", title: L("Add a watched folder"), items: items, mode: .action)
    }

    private func addFolder(_ id: String) {
        guard config.config.watched.count < ShelfConfig.maxWatched else { return }
        switch id {
        case "screenshots": config.update { $0.watched.append(.screenshots()) }
        case "downloads": config.update { $0.watched.append(.downloads()) }
        default:
            choose(folders: true) { u in
                config.update { $0.watched.append(WatchedFolder(path: u.path, bookmark: ShelfBookmarks.make(u))) }
            }
        }
    }

    private func folderRow(_ f: WatchedFolder) -> some View {
        let state = watch.state(f.id)
        let target = f.collection.flatMap { store.library.collection($0) }?.title ?? L("Current collection")
        let problem: String? = state == .denied ? L("macOS doesn't let Cocaine read this folder: allow it in System Settings → Privacy & Security → Files and Folders")
            : state == .missing ? L("The folder isn't there") : nil
        let expanded = open.folder == f.id
        return VStack(alignment: .leading, spacing: Space.s) {
            row(f.title, detail: problem ?? (WatchMatch.summary(f) + " · " + String(format: L("after %@ s of quiet"), Self.seconds(f.delay))), warning: problem != nil) {
                HStack(spacing: Space.s) {
                    if state == .denied {
                        Button(L("Open Settings")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!) }
                            .buttonStyle(CocaineButtonStyle())
                    }
                    icon(expanded ? "chevron.up" : "slider.horizontal.3", L("Rules…")) { Motion.with(.expand) { open.folder = expanded ? nil : f.id } }
                    icon("trash", L("Remove"), destructive: true) { config.update { $0.watched.removeAll { $0.id == f.id } } }
                    CocaineSwitch(on: f.enabled) { config.updateFolder(f.id) { $0.enabled.toggle() } }.accessibilityLabel(f.title)
                }
            }
            if expanded { folderRules(f, target: target).padding(.leading, Space.l).motionAppear(edge: .top) }
        }
    }

    private static func seconds(_ d: Double) -> String { d < 1 ? String(format: "%.1f", d) : "\(Int(d))" }

    private func folderRules(_ f: WatchedFolder, target: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            row(L("Into")) {
                ValueButton(id: "shelf.into.\(f.id)", title: L("Into"), value: target, spec: {
                    PickerSpec(id: "shelf.into.\(f.id)", title: L("Into"),
                               items: [PickerItem(id: "current", title: L("Current collection"))] + store.collections.map { PickerItem(id: $0.id.uuidString, title: $0.title) },
                               mode: .single(f.collection?.uuidString ?? "current"))
                }, onPick: { id in config.updateFolder(f.id) { $0.collection = UUID(uuidString: id) } })
            }
            row(L("Batch")) {
                Segments(selection: Binding(get: { f.delay }, set: { v in config.updateFolder(f.id) { $0.delay = v } }), values: WatchedFolder.delays,
                         name: L("Batch"), label: { Self.seconds($0) + " s" })
            }
            row(L("Match")) {
                Segments(selection: Binding(get: { f.matchAll }, set: { v in config.updateFolder(f.id) { $0.matchAll = v } }), values: [true, false],
                         name: L("Match"), label: { $0 ? L("All rules") : L("Any rule") })
            }
            ForEach(f.rules) { r in
                HStack(spacing: Space.s) {
                    Image(systemName: r.negate ? "nosign" : "line.3.horizontal.decrease").font(UI.detail).foregroundStyle(UI.hint)
                    Text(WatchMatch.summary(WatchedFolder(path: "", rules: [r]))).font(UI.value).lineLimit(1)
                    Spacer(minLength: 0)
                    icon(r.negate ? "checkmark.circle" : "nosign", r.negate ? L("Match it") : L("Exclude it")) {
                        config.updateFolder(f.id) { w in if let i = w.rules.firstIndex(where: { $0.id == r.id }) { w.rules[i].negate.toggle() } }
                    }
                    icon("xmark", L("Remove")) { config.updateFolder(f.id) { $0.rules.removeAll { $0.id == r.id } } }
                }
            }
            HStack {
                Spacer(minLength: 0)
                ValueButton(id: "shelf.rule.\(f.id)", title: L("Add a rule"), value: L("Add a rule"), spec: { ruleSpec(f) }, onPick: { addRule($0, to: f) })
            }
        }
    }

    private func ruleSpec(_ f: WatchedFolder) -> PickerSpec {
        let kinds = FileKind.allCases.map { PickerItem(id: "kind:" + $0.rawValue, title: $0.title, symbol: "square.grid.2x2") }
        return PickerSpec(id: "shelf.rule.\(f.id)", title: L("Add a rule"), items: [
            PickerItem(id: "screenshot", title: L("Screenshots only"), symbol: "camera.viewfinder"),
            PickerItem(id: "ext", title: L("Extension is…"), symbol: "doc"),
            PickerItem(id: "nameContains", title: L("Name contains…"), symbol: "textformat"),
            PickerItem(id: "nameStarts", title: L("Name starts with…"), symbol: "textformat"),
            PickerItem(id: "nameEnds", title: L("Name ends with…"), symbol: "textformat"),
        ] + kinds, mode: .action)
    }

    private func addRule(_ id: String, to f: WatchedFolder) {
        func append(_ r: WatchRule) { config.updateFolder(f.id) { $0.rules.append(r) } }
        if id == "screenshot" { append(WatchRule(field: .screenshot)); return }
        if id.hasPrefix("kind:") { append(WatchRule(field: .kind, value: String(id.dropFirst(5)))); return }
        guard let field = WatchRule.Field(rawValue: id) else { return }
        let title = field == .ext ? L("Extensions (e.g. png, jpg)") : L("Text")
        let spec = DialogSpec(icon: "line.3.horizontal.decrease", title: L("Add a rule"),
                              field: DialogField(placeholder: title, validate: { $0.trimmingCharacters(in: .whitespaces).isEmpty ? L("Type something") : nil }),
                              buttons: [DialogButton(id: "ok", title: L("Add"), needsValidInput: true), Dialogs.cancel], surface: .panel)
        DialogCenter.shared.present(spec) { r in
            guard case .button("ok", let text, _) = r else { return }
            append(WatchRule(field: field, value: String(text.trimmingCharacters(in: .whitespaces).prefix(120))))
        }
    }

    // MARK: actions

    private var addActionSpec: PickerSpec {
        PickerSpec(id: "shelf.addAction", title: L("Add an action"), items: ShelfAction.Kind.allCases.map { k in
            let a = ShelfAction(name: "", kind: k, target: "")
            return PickerItem(id: k.rawValue, title: a.kindTitle + "…", symbol: a.symbol)
        }, mode: .action)
    }

    private func addAction(_ id: String) {
        guard let kind = ShelfAction.Kind(rawValue: id), config.config.actions.count < ShelfConfig.maxActions else { return }
        if kind == .webhook {
            let spec = DialogSpec(icon: "paperplane", title: L("Webhook address"), message: L("The files (or their details) are sent there with POST. https only."),
                                  field: DialogField(placeholder: "https://", validate: { ShareWebhook.problem($0) }),
                                  buttons: [DialogButton(id: "ok", title: L("Add"), needsValidInput: true), Dialogs.cancel], surface: .panel)
            DialogCenter.shared.present(spec) { r in
                guard case .button("ok", let text, _) = r else { return }
                let u = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = String(format: L("Send to %@"), URL(string: u)?.host ?? u)
                config.update { $0.actions.append(ShelfAction(name: String(name.prefix(ShelfLimits.nameChars)), kind: .webhook, target: u, hook: WebhookSpec())) }
            }
            return
        }
        if kind == .shortcut {
            let spec = DialogSpec(icon: "square.2.layers.3d", title: L("Which Shortcut?"), message: L("Its name exactly as in the Shortcuts app. The files are its input."),
                                  field: DialogField(placeholder: L("Name"), validate: { t in
                                      let n = t.trimmingCharacters(in: .whitespaces)
                                      return n.isEmpty || n.hasPrefix("-") ? L("A Shortcut's name can't be empty or start with a dash") : nil
                                  }),
                                  buttons: [DialogButton(id: "ok", title: L("Add"), needsValidInput: true), Dialogs.cancel], surface: .panel)
            DialogCenter.shared.present(spec) { r in
                guard case .button("ok", let text, _) = r else { return }
                let n = text.trimmingCharacters(in: .whitespaces)
                config.update { $0.actions.append(ShelfAction(name: n, kind: .shortcut, target: n)) }
            }
            return
        }
        choose(folders: kind == .moveTo, apps: kind == .openWith) { u in
            let name = kind == .openWith ? String(format: L("Open with %@"), ShelfFiles.appName(u))
                : kind == .moveTo ? String(format: L("Move to %@"), FileManager.default.displayName(atPath: u.path))
                : u.deletingPathExtension().lastPathComponent
            config.update { $0.actions.append(ShelfAction(name: String(name.prefix(ShelfLimits.nameChars)), kind: kind, target: u.path)) }
        }
    }

    private func actionRow(_ a: ShelfAction) -> some View {
        let problem = ShelfActionEngine.check(a)
        let shown = a.kind == .shortcut ? a.target : a.kind == .webhook ? (URL(string: a.target)?.host ?? a.target) : (a.target as NSString).lastPathComponent
        let detail = problem?.localizedDescription ?? (a.kindTitle + " · " + shown)
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .center, spacing: Space.m) {
                Image(systemName: a.symbol).font(UI.icon).foregroundStyle(Island.accent).frame(width: UI.iconColumn)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(a.name).font(UI.title).lineLimit(1)
                    Text(detail).font(UI.detail).foregroundStyle(problem == nil ? UI.secondary : warningColor).lineLimit(2).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 2) {
                    if a.runsCode { icon("play", L("Test")) { pickers.close(); test(a) } }
                    icon("pencil", L("Rename…")) { pickers.close(); renameAction(a) }
                    icon("trash", L("Remove"), destructive: true) {
                        config.update { c in
                            c.actions.removeAll { $0.id == a.id }
                            for i in c.actions.indices where c.actions[i].then == a.id { c.actions[i].then = nil }
                        }
                        if a.kind == .webhook { try? ShelfActionEngine.secrets.delete(ShareWebhook.secretAccount(a.id)) }
                    }
                }
                .fixedSize()
            }
            HStack(spacing: Space.m) {
                if a.runsCode {
                    ValueButton(id: "shelf.out.\(a.id)", title: L("Output"), value: outputName(a.output), maxWidth: 140, spec: {
                        PickerSpec(id: "shelf.out.\(a.id)", title: L("Output"), items: ShelfAction.Output.allCases.map { PickerItem(id: $0.rawValue, title: outputName($0)) },
                                   mode: .single(a.output.rawValue))
                    }, onPick: { id in config.updateAction(a.id) { $0.output = ShelfAction.Output(rawValue: id) ?? .ignore } })
                    .padding(.leading, UI.iconColumn + Space.m)
                }
                Spacer(minLength: 0)
                Text(L("Instant")).font(UI.detail).foregroundStyle(UI.secondary)
                CocaineSwitch(on: a.instant) { config.updateAction(a.id) { $0.instant.toggle() } }.accessibilityLabel(L("Instant"))
            }
            ShelfActionExtras(action: a, config: config)                       // key, next action, webhook (ShelfActionsIO.swift)
        }
    }

    private func outputName(_ o: ShelfAction.Output) -> String {
        switch o { case .ignore: return L("Ignore output"); case .clipboard: return L("Output to the clipboard"); case .shelf: return L("Output to the shelf") }
    }

    private func renameAction(_ a: ShelfAction) {
        let spec = DialogSpec(icon: "pencil", title: L("Rename action"),
                              field: DialogField(placeholder: L("Name"), text: a.name, validate: { $0.trimmingCharacters(in: .whitespaces).isEmpty ? L("Give it a name") : nil }),
                              buttons: [DialogButton(id: "ok", title: L("Rename"), needsValidInput: true), Dialogs.cancel], surface: .panel)
        DialogCenter.shared.present(spec) { r in
            guard case .button("ok", let text, _) = r else { return }
            config.updateAction(a.id) { $0.name = text.trimmingCharacters(in: .whitespaces) }
        }
    }

    /// Runs it once with no files and shows what it printed (asks first, like any run).
    private func test(_ a: ShelfAction) {
        func go(_ a: ShelfAction) {
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Result { try ShelfActionEngine.run(a, files: []) }
                DispatchQueue.main.async {
                    let text: String
                    switch r {
                    case .success(let o):
                        let out = [o.output.isEmpty ? nil : L("Output") + ":\n" + o.output, o.errors.isEmpty ? nil : L("Errors") + ":\n" + o.errors].compactMap { $0 }
                        text = (o.ok ? L("It ran without errors.") : o.timedOut ? L("It took too long and was stopped.") : L("It ended with an error.")) + (out.isEmpty ? "" : "\n\n" + String(out.joined(separator: "\n\n").prefix(1500)))
                    case .failure(let e): text = e.localizedDescription
                    }
                    DialogCenter.shared.present(Dialogs.message(String(format: L("Test of “%@”"), a.name), text, error: !((try? r.get())?.ok ?? false), surface: .panel)) { _ in }
                }
            }
        }
        if ShelfActionEngine.needsApproval(a) {
            guard let print = ShelfActionEngine.fingerprint(a) else { return }
            let spec = DialogSpec(icon: "exclamationmark.shield", title: String(format: L("Run “%@”?"), a.name),
                                  message: a.kind == .webhook ? ShelfActionEngine.webhookQuestion(a)
                                      : String(format: L("It runs %@ with your permissions. Cocaine asks again if it changes."), a.target),
                                  buttons: [DialogButton(id: "run", title: L("Run")), Dialogs.cancel], safeDefault: true, surface: .panel)
            DialogCenter.shared.present(spec) { r in
                guard r.buttonID == "run" else { return }
                config.updateAction(a.id) { $0.approved = print }
                var ok = a; ok.approved = print
                go(ok)
            }
        } else { go(a) }
    }

    /// The system's open panel (the point here: the user picks the file, the folder or the app).
    private func choose(folders: Bool, apps: Bool = false, _ picked: @escaping (URL) -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = folders; p.canChooseFiles = !folders; p.allowsMultipleSelection = false; p.canCreateDirectories = folders
        p.treatsFilePackagesAsDirectories = false
        if apps { p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications") }
        NSApp.activate()
        p.begin { r in if r == .OK, let u = p.url { picked(u) } }
    }
}

final class ShelfSettingsState: ObservableObject { @Published var folder: UUID? }
