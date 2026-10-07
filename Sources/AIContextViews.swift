// The "AI context" island module (ModuleCatalog "aicontext"): S = how many items and Clear; M = the list (remove one); L = the
// list with previews and which AI tools may read it. And Settings → AI → "AI context (MCP)": the master switch, the basket's
// options, the pinboards shared with AI, connecting each AI tool, the tools that were allowed or denied (revoke), and the log
// (what was asked, when, by which tool, how much: never content).

import AppKit
import SwiftUI

extension IslandView {
    func aiContextModule(_ b: ModuleBox) -> some View {
        AIContextModuleView(center: .shared, basket: AIContextCenter.shared.basket, audit: AIContextCenter.shared.audit, box: b,
                            openSettings: { model.showSettings() })
    }
}

struct AIContextModuleView: View {
    @ObservedObject var center: AIContextCenter
    @ObservedObject var basket: AIContextBasket
    @ObservedObject var audit: MCPAuditLog
    let box: ModuleBox
    let openSettings: () -> Void

    static func symbol(_ e: AIContextEntry) -> String {
        switch e.kind {
        case .clip: return "doc.on.clipboard"
        case .file: return "doc"
        case .text: return "text.alignleft"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header
            if !center.settings.enabled {
                Text(L("Off: AI tools can't read it. Turn it on in Settings → AI.")).font(UI.detail).foregroundStyle(UI.hint)
                    .lineLimit(box.size == .s ? 1 : 3).fixedSize(horizontal: false, vertical: true)
            }
            if box.size != .s {
                if basket.entries.isEmpty {
                    Text(L("Empty. Add clipboard or shelf items with “Use as AI context”.")).font(UI.value).foregroundStyle(UI.hint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            ForEach(basket.entries) { e in AIContextRow(entry: e, preview: box.size == .l) { basket.remove(e.id) } }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .motion(.selection, value: basket.entries.map(\.id))
                }
                if box.size == .l { access }
            }
            if box.size == .s || basket.entries.isEmpty { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "sparkles").font(UI.icon).foregroundStyle(Island.accent).accessibilityHidden(true)
            Text(L("AI context")).font(UI.section).foregroundStyle(UI.secondary).lineLimit(1)
            Text("\(basket.entries.count)").font(UI.metric).motionNumber(basket.entries.count)
                .accessibilityLabel(String(format: L("%d items"), basket.entries.count))
            Spacer(minLength: Space.xs)
            ShelfGlyph(symbol: "plus", title: L("Add text…")) { addText() }
            ShelfGlyph(symbol: "trash", title: L("Clear all")) { Motion.with(.appear) { basket.clear() }; A11y.announce(L("AI context cleared")) }
                .disabled(basket.entries.isEmpty)
        }
    }

    /// Who may read it (L size): the tools allowed or denied, and the last ones that asked.
    private var access: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(L("Access")).font(UI.section).foregroundStyle(UI.secondary)
            if center.consent.records.isEmpty {
                Text(L("No AI tool has asked yet")).font(UI.detail).foregroundStyle(UI.hint).lineLimit(1)
            }
            ForEach(center.consent.records.prefix(3)) { r in
                HStack(spacing: Space.xs) {
                    Image(systemName: r.decision == .allow ? "checkmark.circle" : "xmark.circle").font(UI.detail)
                        .foregroundStyle(r.decision == .allow ? Color.green : warningColor).accessibilityHidden(true)
                    Text(r.label).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                    Spacer(minLength: Space.xs)
                    Text(r.decision == .allow ? L("Allowed") : L("Denied")).font(UI.detail).foregroundStyle(UI.hint)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func addText() {
        DialogCenter.shared.present(DialogSpec(icon: "text.alignleft", title: L("Add text to the AI context"),
                                               field: DialogField(placeholder: L("Text for the AI"), validate: { t in
                                                   t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("Type some text")
                                                       : t.utf8.count > AIContextLimits.maxTextBytes ? L("Too long") : nil }),
                                               buttons: [DialogButton(id: "add", title: L("Add"), needsValidInput: true), Dialogs.cancel], surface: .island)) { r in
            guard case .button("add", let text, _) = r else { return }
            let res = basket.add([(kind: "text", ref: text, title: "")])
            if res.refused.contains(.secret) { A11y.announce(L("Not added: it looks like a secret")) }
        }
    }
}

struct AIContextRow: View {
    let entry: AIContextEntry
    let preview: Bool
    let remove: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: AIContextModuleView.symbol(entry)).font(UI.icon).foregroundStyle(UI.secondary).frame(width: UI.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(entry.title).font(UI.value).lineLimit(1)
                if preview, let p = previewText { Text(p).font(UI.detail).foregroundStyle(UI.hint).lineLimit(1) }
            }
            Spacer(minLength: Space.xs)
            Button(action: { Haptic.tap(.alignment); Motion.with(.appear) { remove() } }) {
                Image(systemName: "xmark").font(UI.chevron).foregroundStyle(UI.secondary).frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(MotionGlyphStyle())
            .opacity(hover.on ? 1 : 0.0001)
            .accessibilityLabel(L("Remove from the AI context"))
            .help(L("Remove from the AI context"))
        }
        .onHover { hover.on = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.title)
        .accessibilityAction(named: L("Remove from the AI context")) { remove() }
    }

    private var previewText: String? {
        switch entry.kind {
        case .file: return (entry.ref as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .text: return AIContextText.clean(entry.ref, 80)
        case .clip: return L("From the clipboard")
        }
    }
}

// MARK: - Settings → AI → AI context (MCP)

final class MCPRegistrationState: ObservableObject {
    static let shared = MCPRegistrationState()
    @Published var status: [MCPRegistration.Client: (installed: Bool, on: Bool)] = [:]
    @Published var busy: MCPRegistration.Client?
    @Published var note: String?
    @Published var showLog = false                   // the activity log is open in Settings

    func refresh() {
        if AppDefaults.isolated {           // renders and tests: a sample, never the Mac's own AI tools' files
            status = [.claudeCode: (true, true), .claudeDesktop: (true, false), .codex: (true, false), .cursor: (true, false), .gemini: (false, false)]
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let s = Dictionary(uniqueKeysWithValues: MCPRegistration.Client.allCases.map { ($0, (installed: MCPRegistration.installed($0), on: MCPRegistration.registered($0))) })
            DispatchQueue.main.async { self.status = s }
        }
    }

    /// Shows what will change (the command, or the file's diff), and does it only on "Connect"/"Remove".
    func toggle(_ c: MCPRegistration.Client) {
        let on = !(status[c]?.on ?? false)
        switch MCPRegistration.plan(c, on: on) {
        case .failure(.notInstalledCopy):
            DialogCenter.shared.present(Dialogs.message(L("Install Cocaine in Applications first"),
                                                         L("AI tools start Cocaine from where it is installed; this copy runs from elsewhere."))) { _ in }
        case .failure(.noCLI(let cmd)):
            DialogCenter.shared.present(DialogSpec(icon: "terminal", title: String(format: L("Connect %@"), c.title),
                                                   message: L("Claude Code's command wasn't found. Run this in Terminal:") + "\n\n" + cmd,
                                                   buttons: [DialogButton(id: "copy", title: L("Copy command")), Dialogs.cancel])) { r in
                if r.buttonID == "copy" { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string) }
            }
        case .failure(.unreadable(let path)):
            DialogCenter.shared.present(Dialogs.message(L("Can't change this file"), (path as NSString).abbreviatingWithTildeInPath)) { _ in }
        case .success(let p):
            if p.noChange { refresh(); return }
            let what: String
            if let cmd = p.command {
                what = L("Cocaine will run:") + "\n\n" + cmd.split(separator: "&&").map { MCPRegistration.shellLine(Array($0)) }.joined(separator: "\n")
            } else {
                what = String(format: L("Cocaine will change %@ (a backup is kept next to it):"), (p.path as NSString).abbreviatingWithTildeInPath)
                    + "\n\n" + MCPRegistration.diff(p.before, p.after, limit: 16).joined(separator: "\n")
            }
            let title = String(format: on ? L("Connect %@") : L("Disconnect %@"), c.title)
            DialogCenter.shared.present(DialogSpec(icon: on ? "link" : "link.badge.plus", title: title, message: what,
                                                   buttons: [DialogButton(id: "go", title: on ? L("Connect") : L("Disconnect")), Dialogs.cancel])) { [weak self] r in
                guard r.buttonID == "go", let self else { return }
                self.busy = c
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = MCPRegistration.apply(p)
                    DispatchQueue.main.async {
                        self.busy = nil
                        self.note = ok ? (on ? String(format: L("%@ connected: restart it to use Cocaine"), c.title) : String(format: L("%@ disconnected"), c.title))
                                       : String(format: L("Couldn't update %@"), c.title)
                        A11y.announce(self.note ?? "")
                        self.refresh()
                    }
                }
            }
        }
    }

    func copyCommand(_ c: MCPRegistration.Client) {
        let bin = MCPRegistration.binary() ?? "/Applications/Cocaine.app/Contents/MacOS/Cocaine"
        let text: String
        switch c {
        case .claudeCode: text = MCPRegistration.shellLine(MCPRegistration.claudeCommand(on: true, binary: bin))
        case .codex: text = MCPRegistration.tomlEdited("", on: true, binary: bin) ?? ""
        default: text = "\"cocaine\": " + MCPRegistration.entry(c, binary: bin).render()
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        note = L("Copied"); A11y.announce(L("Copied"))
    }
}

struct AIContextSettingsCard: View {
    @ObservedObject var center = AIContextCenter.shared
    @ObservedObject var basket = AIContextCenter.shared.basket
    @ObservedObject var consent = AIContextCenter.shared.consent
    @ObservedObject var audit = AIContextCenter.shared.audit
    @ObservedObject var reg = MCPRegistrationState.shared
    @ObservedObject var clip = ClipboardHistory.shared
    let kit = AwakeRowKit()

    private func bind(_ k: WritableKeyPath<MCPSettings, Bool>) -> Binding<Bool> {
        Binding(get: { center.settings[keyPath: k] }, set: { v in center.update { $0[keyPath: k] = v } })
    }
    private var expiry: Binding<Int> { Binding(get: { center.settings.expiryHours }, set: { v in center.update { $0.expiryHours = v } }) }

    var body: some View {
        kit.card("sparkles.rectangle.stack", L("AI context (MCP)")) {
            kit.row(L("Let AI tools read the AI context"), detail: center.serverProblem ?? (center.settings.enabled
                    ? String(format: L("%d item(s) now. Only what you put there, never your clipboard history."), basket.entries.count) : nil),
                    tip: L("Claude Code, Codex, Cursor and other tools connected below can read only the items you put in the AI context, after you allow each tool. Nothing leaves the Mac except what that tool sends to its own AI provider."),
                    warning: center.serverProblem != nil) {
                kit.toggle(L("Let AI tools read the AI context"), bind(\.enabled))
            }
            kit.segRow(L("Items expire after"), tip: L("Then they leave the AI context on their own"),
                       expiry, AIContextLimits.expiryChoices) { $0 == 0 ? L("Never") : Dur.short(minutes: $0 * 60) }
            kit.row(L("Keep after restart"), tip: L("Off: the AI context lives in memory only. On: references and typed text are kept in a private file on this Mac.")) {
                kit.toggle(L("Keep after restart"), bind(\.persistBasket))
            }
            kit.row(L("In the AI context"), detail: basket.entries.isEmpty ? L("Empty") : String(format: L("%d items"), basket.entries.count)) {
                Button(L("Clear all")) { basket.clear() }.buttonStyle(CocaineButtonStyle()).disabled(basket.entries.isEmpty)
            }
            if !clip.boards.isEmpty {
                Text(L("Pinboards shared with AI")).font(UI.section).foregroundStyle(UI.secondary).padding(.top, Space.xs)
                ForEach(clip.boards) { b in
                    kit.row(b.displayName) {
                        kit.toggle(String(format: L("Share %@ with AI"), b.displayName), Binding(get: { b.ai }, set: { v in
                            _ = clip.editBoards { list in guard let i = list.firstIndex(where: { $0.id == b.id }) else { return false }; list[i].ai = v; return true }
                        }))
                    }
                }
            }
            Text(L("Connect")).font(UI.section).foregroundStyle(UI.secondary).padding(.top, Space.xs)
            ForEach(MCPRegistration.Client.allCases) { c in
                let st = reg.status[c]
                kit.row(c.title, detail: st == nil ? "…" : st!.on ? L("Connected") : st!.installed ? L("Not connected") : L("Not installed")) {
                    HStack(spacing: Space.s) {
                        Button(L("Copy")) { reg.copyCommand(c) }.buttonStyle(CocaineButtonStyle())
                            .help(L("Copies the command or the entry, to set it up yourself"))
                            .accessibilityLabel(String(format: L("Copy the setup for %@"), c.title))
                        Button(st?.on == true ? L("Disconnect") : L("Connect")) { reg.toggle(c) }
                            .buttonStyle(CocaineButtonStyle(busy: reg.busy == c)).disabled(reg.busy != nil || (st?.installed == false && st?.on != true))
                            .accessibilityLabel(String(format: st?.on == true ? L("Disconnect %@") : L("Connect %@"), c.title))
                    }
                }
            }
            if let n = reg.note { Text(n).font(UI.detail).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true) }
            Text(L("AI tools")).font(UI.section).foregroundStyle(UI.secondary).padding(.top, Space.xs)
            if consent.records.isEmpty {
                Text(L("No AI tool has asked yet")).font(UI.detail).foregroundStyle(UI.hint)
            }
            ForEach(consent.records) { r in
                kit.row(r.label, detail: (r.decision == .allow ? L("Allowed") : L("Denied")) + (r.lastUsed.map { " · " + String(format: L("last read %@ ago"), Dur.ago(seconds: Int(Date().timeIntervalSince($0)))) } ?? "")) {
                    Button(L("Revoke")) { consent.revoke(r.id) }.buttonStyle(CocaineButtonStyle())
                        .accessibilityLabel(String(format: L("Revoke %@"), r.label))
                }
            }
            kit.row(L("Activity"), detail: audit.recent.isEmpty ? L("Nothing read yet") : String(format: L("%d requests logged; never their content"), audit.recent.count)) {
                HStack(spacing: Space.s) {
                    Button(reg.showLog ? L("Hide") : L("Show")) { Motion.with(.expand) { reg.showLog.toggle() } }.buttonStyle(CocaineButtonStyle()).disabled(audit.recent.isEmpty)
                    Button(L("Clear")) { audit.clear() }.buttonStyle(CocaineButtonStyle()).disabled(audit.recent.isEmpty)
                }
            }
            if reg.showLog {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(audit.recent.prefix(30)) { e in
                        Text(Self.line(e)).font(UI.mono).foregroundStyle(UI.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .transition(Motion.appear(.top, anchor: .top))
            }
            LinkButton(title: L("How AI context works")) { NSWorkspace.shared.open(Self.guide) }
        }
        .onAppear { reg.refresh() }
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f }()
    static func line(_ e: MCPAuditEntry) -> String {
        "\(time.string(from: e.date))  \(e.client)  \(e.action)  \(e.outcome)" + (e.items > 0 ? "  \(e.items)×" : "") + (e.bytes > 0 ? "  \(e.bytes) B" : "")
    }

    static var guide: URL {
        (Language.chosen ?? Language.system) == "it"
            ? URL(string: "https://github.com/Mattiakart/cocaine/blob/main/docs/mcp.it.md")!
            : URL(string: "https://github.com/Mattiakart/cocaine/blob/main/docs/mcp.en.md")!
    }
}
