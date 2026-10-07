// The Sharing card of the settings' Island tab (under Shelf): the global switch, the services (added from in-app menus,
// edited in place: non-secret fields saved in Application Support, secret ones straight to the Keychain and never shown again),
// a connection test, removal, and the recent links (copy, open, revoke, remove from the history). Also the toast under the shelf.

import AppKit
import SwiftUI

struct CloudShareSettingsView: View {
    var body: some View { CloudShareSettingsBody(center: .shared, store: CloudShareCenter.shared.store, history: CloudShareCenter.shared.history) }
}

final class CloudEditor: ObservableObject {
    @Published var editing: String?                 // a provider id
    @Published var isNew = false
    @Published var draft = ShareProviderConfig(kind: .s3, title: "")
    @Published var secrets: [String: String] = [:] // typed now (empty: keep what the Keychain has)
    @Published var saved: Set<String> = []         // the secret names the Keychain has for it
    @Published var problem: String?
    @Published var warning: String?
    /// The warning is about privacy (a public third-party host): drawn in the warning colour.
    @Published var alert = false

    /// Renders: a provider shown open in the editor (CloudShareFixtures).
    static var fixture: (ShareProviderConfig, Set<String>, String?)?
    static func make() -> CloudEditor {
        let e = CloudEditor()
        if let (c, saved, w) = fixture { e.draft = c; e.saved = saved; e.warning = w; e.editing = c.id; e.alert = w != nil && w == ShareUploader.presets.first { $0.id == "litterbox" }?.warning }
        return e
    }
}

struct CloudShareSettingsBody: View {
    @ObservedObject var center: CloudShareCenter
    @ObservedObject var store: ShareStore
    @ObservedObject var history: ShareHistory
    @ObservedObject var pickers = PickerCenter.shared
    @StateObject private var ed = CloudEditor.make()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            row(L("Cloud sharing"), detail: L("Upload shelf files to your own storage and copy a link. Off: nothing is uploaded and the shelf offers no link.")) {
                CocaineSwitch(on: store.settings.on) { store.update { $0.on.toggle() } }.accessibilityLabel(L("Cloud sharing"))
            }
            divider
            VStack(alignment: .leading, spacing: Space.s) { services }.dimGroup(!store.settings.on)
        }
    }

    @ViewBuilder private var services: some View {
            HStack(spacing: Space.m) {
                Text(L("Services")).font(UI.groupTitle).lineLimit(1)
                Spacer(minLength: Space.m)
                ValueButton(id: "cloud.add", title: L("Add a service"), value: L("Add…"), spec: { addSpec }, onPick: { add($0) }).fixedSize()
            }
            .frame(minHeight: 22)
            if store.settings.providers.isEmpty {
                Text(L("Your own S3 or R2 bucket, Nextcloud, a WebDAV folder, your server over SFTP, or a command of yours. Nothing is set up for you and nothing is uploaded without a click."))
                    .font(UI.detail).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.settings.providers) { p in providerRow(p) }
            if ed.isNew && ed.editing != nil { editor.motionAppear(edge: .top) }
            divider
            historySection
    }

    // MARK: building blocks

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.vertical, 2) }

    private func row<Control: View>(_ title: String, detail: String? = nil, warning: Bool = false, @ViewBuilder _ control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(UI.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(UI.detail).foregroundStyle(warning ? warningColor : UI.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()
        }
        .frame(minHeight: 22)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func icon(_ symbol: String, _ title: String, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: { Haptic.tap(.alignment); action() }) {
            Image(systemName: symbol).font(UI.icon).foregroundStyle(destructive ? CTL.destructiveInk : UI.secondary)
                .frame(width: CTL.h, height: CTL.h).contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle()).help(title).accessibilityLabel(title)
    }

    // MARK: adding

    private var addSpec: PickerSpec {
        var items = S3Preset.all.map { PickerItem(id: "s3:" + $0.id, title: $0.title, symbol: ShareKind.s3.symbol) }
        items += [PickerItem(id: "nextcloud", title: ShareKind.nextcloud.title, symbol: ShareKind.nextcloud.symbol),
                  PickerItem(id: "webdav", title: ShareKind.webdav.title, symbol: ShareKind.webdav.symbol),
                  PickerItem(id: "sftp", title: ShareKind.sftp.title, symbol: ShareKind.sftp.symbol),
                  PickerItem(id: "uploader:", title: ShareKind.uploader.title + "…", symbol: ShareKind.uploader.symbol)]
        items += ShareUploader.presets.map { PickerItem(id: "uploader:" + $0.id, title: $0.title, symbol: ShareKind.uploader.symbol) }
        return PickerSpec(id: "cloud.add", title: L("Add a service"), items: items, mode: .action)
    }

    private func add(_ id: String) {
        guard store.settings.providers.count < ShareSettings.maxProviders else { return }
        var c: ShareProviderConfig
        var warning: String?
        if id.hasPrefix("s3:"), let p = S3Preset.all.first(where: { "s3:" + $0.id == id }) {
            c = p.config(); warning = p.hint
        } else if id == "nextcloud" {
            c = ShareProviderConfig(kind: .nextcloud, title: "Nextcloud", settings: ["folder": "Cocaine", "expiryDays": "7"])
        } else if id == "webdav" {
            c = ShareProviderConfig(kind: .webdav, title: "WebDAV")
            warning = L("Without a public address the link is the WebDAV address, which asks for your login.")
        } else if id == "sftp" {
            c = ShareProviderConfig(kind: .sftp, title: L("My server"), settings: ["port": "22"])
            warning = L("Keys only: your ssh-agent or a key file. The server must already be in ~/.ssh/known_hosts (connect once with ssh).")
        } else if id.hasPrefix("uploader:") {
            let pid = String(id.dropFirst("uploader:".count))
            if let p = ShareUploader.presets.first(where: { $0.id == pid }) {
                c = ShareProviderConfig(kind: .uploader, title: p.title, settings: ["template": p.template, "extract": p.extract.rawValue, "pattern": p.pattern])
                warning = p.warning
            } else {
                c = ShareProviderConfig(kind: .uploader, title: L("My uploader"), settings: ["template": "/usr/bin/curl -sS --fail -F \"file=@{file}\" https://", "extract": "url"])
            }
        } else { return }
        Motion.with(.expand) {
            ed.draft = c; ed.secrets = [:]; ed.saved = []; ed.problem = nil; ed.warning = warning; ed.alert = id == "uploader:litterbox"
            ed.isNew = true; ed.editing = c.id
        }
    }

    // MARK: a provider

    private func providerRow(_ p: ShareProviderConfig) -> some View {
        let problem = ShareProviders.make(p).validate(secrets: center.secrets(p.id))
        let expanded = ed.editing == p.id && !ed.isNew
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .center, spacing: Space.m) {
                Image(systemName: p.kind.symbol).font(UI.icon).foregroundStyle(Island.accent).frame(width: UI.iconColumn)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(p.title).font(UI.title).lineLimit(1)
                    Text(problem ?? (p.kind.title + (p.host.isEmpty ? "" : " · " + p.host)))
                        .font(UI.detail).foregroundStyle(problem == nil ? UI.secondary : warningColor).lineLimit(2).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 2) {
                    if center.testing == p.id { BusyDots(color: Island.accent).frame(width: CTL.h, height: CTL.h).accessibilityLabel(L("Testing…")) }
                    else { icon("play", L("Test connection")) { pickers.close(); center.test(p.id) }.disabled(problem != nil).opacity(problem == nil ? 1 : CTL.disabled) }
                    icon(expanded ? "chevron.up" : "pencil", L("Edit…")) { pickers.close(); expanded ? close() : edit(p) }
                    icon("trash", L("Remove"), destructive: true) { pickers.close(); remove(p) }
                }
                .fixedSize()
                CocaineSwitch(on: p.enabled) { store.updateProvider(p.id) { $0.enabled.toggle() } }.accessibilityLabel(p.title)
            }
            .accessibilityElement(children: .contain)
            if expanded { editor.padding(.leading, UI.iconColumn + Space.m).motionAppear(edge: .top) }
        }
    }

    private func edit(_ p: ShareProviderConfig) {
        let have = center.secrets(p.id)
        Motion.with(.expand) {
            ed.draft = p; ed.secrets = [:]; ed.saved = Set(have.filter { !$0.value.isEmpty }.keys); ed.problem = nil; ed.warning = nil; ed.alert = false
            ed.isNew = false; ed.editing = p.id
        }
    }

    private func close() { Motion.with(.expand) { ed.editing = nil; ed.isNew = false } }

    private func remove(_ p: ShareProviderConfig) {
        let spec = DialogSpec(icon: "trash", title: String(format: L("Remove “%@”?"), p.title),
                              message: L("Its settings and its Keychain item are deleted. Files already uploaded stay where they are."), critical: true,
                              buttons: [DialogButton(id: "remove", title: L("Remove"), role: .destructive), Dialogs.cancel], surface: .panel)
        DialogCenter.shared.present(spec) { r in
            guard r.buttonID == "remove" else { return }
            if ed.editing == p.id { close() }
            center.removeProvider(p.id)
        }
    }

    // MARK: the editor

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { ed.draft.settings[key] ?? "" }, set: { ed.draft.settings[key] = $0; ed.problem = nil })
    }

    private func secret(_ key: String) -> Binding<String> {
        Binding(get: { ed.secrets[key] ?? "" }, set: { ed.secrets[key] = $0; ed.problem = nil })
    }

    private func field(_ title: String, _ text: Binding<String>, placeholder: String = "", secure: Bool = false, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(UI.detail).foregroundStyle(UI.secondary)
            CloudTextField(text: text, placeholder: placeholder, secure: secure, mono: mono, label: title)
                .frame(height: CTL.h)
                .padding(.horizontal, Space.s)
                .background(RoundedRectangle(cornerRadius: CTL.radius).fill(CTL.fill))
        }
    }

    private func secretField(_ title: String, _ key: String) -> some View {
        field(title, secret(key), placeholder: ed.saved.contains(key) ? L("Saved in the Keychain (type to replace)") : "", secure: true)
    }

    @ViewBuilder private var editor: some View {
        let k = ed.draft.kind
        VStack(alignment: .leading, spacing: Space.s) {
            if let w = ed.warning {
                Label { Text(w).font(UI.detail).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: ed.alert ? "exclamationmark.triangle" : "info.circle") }
                    .foregroundStyle(ed.alert ? warningColor : UI.secondary)
            }
            field(L("Name"), Binding(get: { ed.draft.title }, set: { ed.draft.title = $0 }))
            switch k {
            case .s3:
                field(L("Endpoint"), binding("endpoint"), placeholder: "https://")
                HStack(spacing: Space.s) {
                    field(L("Region"), binding("region"), placeholder: "us-east-1")
                    field(L("Bucket"), binding("bucket"))
                }
                secretField(L("Access key ID"), "accessKey")
                secretField(L("Secret access key"), "secretKey")
                field(L("Key prefix"), binding("prefix"), placeholder: "cocaine")
                row(L("Path-style addresses"), detail: L("On for R2, B2, MinIO and most S3-compatible stores")) {
                    CocaineSwitch(on: ed.draft["pathStyle"] != "0") { ed.draft.settings["pathStyle"] = ed.draft["pathStyle"] == "0" ? "1" : "0" }
                        .accessibilityLabel(L("Path-style addresses"))
                }
                row(L("Link works for")) {
                    Segments(selection: Binding(get: { Int(ed.draft["expiry"]) ?? 86400 }, set: { ed.draft.settings["expiry"] = String($0) }),
                             values: [3600, 86400, 3 * 86400, 7 * 86400], name: L("Link works for"), label: { Self.duration($0) })
                }
                field(L("Public address (optional)"), binding("publicBase"), placeholder: "https://files.example.com")
                Text(L("With a public address (a public bucket or your domain) links don't expire; without it they are signed and expire. Use a key that can only write to this bucket."))
                    .font(UI.detail).foregroundStyle(UI.hint).fixedSize(horizontal: false, vertical: true)
            case .webdav:
                field(L("WebDAV folder address"), binding("url"), placeholder: "https://")
                field(L("User name"), binding("user"))
                secretField(L("Password"), "password")
                field(L("Public address (optional)"), binding("publicBase"), placeholder: "https://")
            case .nextcloud:
                field(L("Server address"), binding("server"), placeholder: "https://cloud.example.com")
                field(L("User name"), binding("user"))
                secretField(L("App password"), "password")
                field(L("Folder"), binding("folder"), placeholder: "Cocaine")
                row(L("Link expires after")) {
                    Segments(selection: Binding(get: { Int(ed.draft["expiryDays"]) ?? 7 }, set: { ed.draft.settings["expiryDays"] = String($0) }),
                             values: [0, 1, 7, 30], name: L("Link expires after"), label: { $0 == 0 ? L("Never") : String(format: L("%d d"), $0) })
                }
                secretField(L("Link password (optional)"), "sharePassword")
                Text(L("Make an app password in Nextcloud: Settings → Security → Devices & sessions.")).font(UI.detail).foregroundStyle(UI.hint)
                    .fixedSize(horizontal: false, vertical: true)
            case .sftp:
                HStack(spacing: Space.s) {
                    field(L("Server"), binding("host"), placeholder: "example.com")
                    field(L("Port"), binding("port"), placeholder: "22").frame(width: 70)
                }
                field(L("User name"), binding("user"))
                field(L("Remote folder"), binding("remoteDir"), placeholder: "public_html/share")
                field(L("Public address of that folder"), binding("publicBase"), placeholder: "https://example.com/share")
                HStack(alignment: .bottom, spacing: Space.s) {
                    field(L("Key file (optional)"), binding("identity"), placeholder: L("The ssh-agent's keys"))
                    Button(L("Choose…")) { chooseKey() }.buttonStyle(CocaineButtonStyle())
                }
            case .uploader:
                field(L("Command"), binding("template"), mono: true)
                Text(L("{file} is the file (required), {name} its name, {mime} its type, {size} its size, {secret_headers} a file with your secret headers (curl -H @{secret_headers}). No shell runs it."))
                    .font(UI.detail).foregroundStyle(UI.hint).fixedSize(horizontal: false, vertical: true)
                row(L("The link is")) {
                    ValueButton(id: "cloud.extract", title: L("The link is"), value: (ShareUploader.Extract(rawValue: ed.draft["extract"]) ?? .url).title, maxWidth: 200, spec: {
                        PickerSpec(id: "cloud.extract", title: L("The link is"), items: ShareUploader.Extract.allCases.map { PickerItem(id: $0.rawValue, title: $0.title) },
                                   mode: .single(ed.draft["extract"].isEmpty ? "url" : ed.draft["extract"]))
                    }, onPick: { ed.draft.settings["extract"] = $0 })
                }
                if ed.draft["extract"] == "regex" || ed.draft["extract"] == "json" {
                    field(ed.draft["extract"] == "json" ? L("JSON path") : L("Regular expression"), binding("pattern"), placeholder: ed.draft["extract"] == "json" ? "files[0].url" : "(https://\\S+)", mono: true)
                }
                secretField(L("Secret headers (optional)"), "headers")
            }
            row(L("Ask before every upload"), detail: L("Says where the files go and how long the link works")) {
                CocaineSwitch(on: ed.draft.confirmEach) { ed.draft.confirmEach.toggle() }.accessibilityLabel(L("Ask before every upload"))
            }
            if let p = ed.problem {
                Text(p).font(UI.detail).foregroundStyle(warningColor).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s) {
                Spacer(minLength: 0)
                Button(L("Cancel")) { close() }.buttonStyle(CocaineButtonStyle())
                Button(L("Save")) { save() }.buttonStyle(CocaineButtonStyle(kind: .primary))
            }
        }
        .padding(Space.m)
        .background(RoundedRectangle(cornerRadius: CTL.innerRadius).fill(Color.white.opacity(0.04)))
    }

    static func duration(_ s: Int) -> String {
        s < 86400 ? String(format: L("%d h"), s / 3600) : String(format: L("%d d"), s / 86400)
    }

    private func chooseKey() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false; p.showsHiddenFiles = true
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        p.message = L("Choose your private key (the public .pub file is on the server)")
        NSApp.activate()
        p.begin { r in if r == .OK, let u = p.url { ed.draft.settings["identity"] = u.path } }
    }

    /// Saves: checks with the secrets as they will be, writes the Keychain first (a failure there keeps the old settings).
    private func save() {
        var c = ed.draft
        c.title = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.title.isEmpty { c.title = c.kind.title }
        c.title = String(c.title.prefix(60))
        var all = center.secrets(c.id)
        for (k, v) in ed.secrets where !v.isEmpty { all[k] = v.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let p = ShareProviders.make(c).validate(secrets: all) { ed.problem = p; return }
        if c.kind == .uploader && c.approved != nil && ShareUploader.needsApproval(c) { c.approved = nil }    // a changed command asks again
        do { try center.setSecrets(c.id, all) } catch {
            ed.problem = L("The Keychain didn't save the secrets: ") + String(describing: error)
            return
        }
        if store.provider(c.id) == nil { store.update { $0.providers.append(c) } } else { store.updateProvider(c.id) { $0 = c } }
        Haptic.tap(.generic)
        close()
    }

    // MARK: history

    @ViewBuilder private var historySection: some View {
        HStack(spacing: Space.m) {
            Text(L("Recent links")).font(UI.groupTitle).lineLimit(1)
            Spacer(minLength: Space.m)
            if !history.records.isEmpty {
                Button(L("Remove expired")) { Motion.with(.appear) { history.removeExpired(now: center.now()) } }.buttonStyle(CocaineButtonStyle())
                Button(L("Clear")) { Motion.with(.appear) { history.clear() } }.buttonStyle(CocaineButtonStyle())
            }
        }
        .frame(minHeight: 22)
        if history.records.isEmpty {
            Text(L("Links you make appear here, with when they expire. Only the link and the file's name are kept, never the file."))
                .font(UI.detail).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(history.records.prefix(10)) { r in historyRow(r) }
    }

    static func status(_ r: ShareRecord, now: Date) -> String {
        if r.revoked { return L("Revoked") }
        guard let e = r.expires else { return L("Doesn't expire") }
        if e <= now { return L("Expired") }
        let f = RelativeDateTimeFormatter(); f.locale = Language.locale; f.unitsStyle = .short
        return String(format: L("Expires %@"), f.localizedString(for: e, relativeTo: now))
    }

    private func historyRow(_ r: ShareRecord) -> some View {
        let now = center.now()
        let live = !r.revoked && !r.expired(now)
        let date = DateFormatter.localizedString(from: r.date, dateStyle: .short, timeStyle: .short)
        return HStack(spacing: Space.m) {
            Image(systemName: "link").font(UI.icon).foregroundStyle(live ? Island.accent : UI.hint).frame(width: UI.iconColumn)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(r.name).font(UI.title).lineLimit(1).truncationMode(.middle)
                Text([r.providerTitle, date, Self.status(r, now: now)].joined(separator: " · ")).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                if live {
                    icon("doc.on.doc", L("Copy link")) { center.copy(r) }
                    icon("arrow.up.forward.square", L("Open")) { center.open(r) }
                    if r.kind.canRevoke { icon("xmark.octagon", L("Revoke…"), destructive: true) { pickers.close(); center.revoke(r, surface: .panel) } }
                }
                icon("minus.circle", L("Remove from the history")) { Motion.with(.appear) { history.remove(r.id) } }
            }
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
    }
}

/// A one-line text field for the card (AppKit's, so typing works in the panel); a secure one hides what is typed.
struct CloudTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var secure = false
    var mono = false
    let label: String

    func makeNSView(context: Context) -> NSTextField {
        let f: NSTextField = secure ? NSSecureTextField() : NSTextField()
        f.isBordered = false; f.drawsBackground = false; f.focusRingType = .exterior; f.isBezeled = false
        let font: NSFont = mono ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
        f.font = font
        f.textColor = .white
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.5), .font: font])
        f.cell?.isScrollable = true; f.cell?.wraps = false; f.lineBreakMode = .byClipping
        f.delegate = context.coordinator
        f.stringValue = text
        f.setAccessibilityLabel(label)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text && f.currentEditor() == nil { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CloudTextField
        init(_ p: CloudTextField) { parent = p }
        func controlTextDidChange(_ n: Notification) { if let f = n.object as? NSTextField { parent.text = f.stringValue } }
    }
}

// MARK: - Under the shelf

/// The upload just made: its link was copied; Copy again, Open, Revoke, close.
struct CloudToast: View {
    @ObservedObject var center: CloudShareCenter
    var compact = false

    var body: some View {
        if let r = center.recent {
            HStack(spacing: Space.xs) {
                Image(systemName: "link").font(UI.detail).foregroundStyle(Island.accent)
                Text(compact ? L("Link copied") : String(format: L("Link copied · %@"), r.providerTitle)).font(UI.detail).foregroundStyle(UI.secondary)
                    .lineLimit(1).truncationMode(.middle)
                glyph("doc.on.doc", L("Copy link")) { center.copy(r) }
                glyph("arrow.up.forward.square", L("Open")) { center.open(r) }
                if r.kind.canRevoke { glyph("xmark.octagon", L("Revoke…")) { center.revoke(r, surface: .island) } }
                glyph("xmark", L("Close")) { center.dismiss() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Link copied"))
            .transition(.opacity)
        }
    }

    private func glyph(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: { Haptic.tap(.alignment); action() }) {
            Image(systemName: symbol).font(UI.detail).foregroundStyle(CTL.accent).frame(width: 18, height: 14).contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle()).help(title).accessibilityLabel(title)
    }
}
