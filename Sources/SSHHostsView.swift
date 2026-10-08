// SSH hosts in Settings → AI: the list of hosts with each one's state (a dot and words), its switch, what can be done now
// (install the relay, review the hooks there, log in in Terminal, retry, remove), the review of the hooks' changes (a diff per
// file, nothing written before "Change these files"), and the global switch. Plain rows in the subtle card, the app's own
// controls, Motion's tokens, in-app dialogs, VoiceOver labels. The model: Sources/SSHManager.swift.

import AppKit
import SwiftUI

extension SSHHostManager {
    /// The host's state in words (also what VoiceOver reads for its dot).
    func stateText(_ h: SSHHost) -> String {
        let s = status[h.id] ?? SSHHostStatus()
        if s.working { return s.note ?? L("Working…") }
        if !store.enabled { return L("Off (all SSH hosts)") }
        if !h.deployed { return s.failure.map(Self.failureText) ?? L("Relay not installed yet") }
        if !h.enabled { return L("Off") }
        switch s.phase {
        case .off: return L("Off")
        case .connecting: return L("Connecting…")
        case .connected:
            let names = s.hooksOn.map(SSHEvents.toolName)
            return names.isEmpty ? L("Connected · no hooks there yet") : String(format: L("Connected · hooks: %@"), names.joined(separator: ", "))
        case .retrying(let at):
            return String(format: L("Unreachable: trying again at %@"), PanelView.timeString(at))
        case .stopped(let f): return Self.failureText(f)
        }
    }

    static func failureText(_ f: SSHFailure) -> String {
        switch f {
        case .auth: return L("The login was refused (key, ssh agent or MFA). Log in once in Terminal, or check your key.")
        case .hostKeyChanged: return L("The host's key has CHANGED since it was trusted: Cocaine won't connect. If you expected it, update ~/.ssh/known_hosts in Terminal.")
        case .hostKeyUnknown: return L("This host's key isn't in ~/.ssh/known_hosts yet: connect once in Terminal to check and accept it.")
        case .relayMissing: return L("The relay isn't on that host.")
        case .relayOutdated: return L("Updating the relay…")
        case .noPerl: return L("That host has no perl with JSON::PP and Digest::SHA, which the relay needs.")
        case .keyMismatch: return L("The relay there has another key: install it again.")
        case .badAlias: return L("Not a host name ssh can be given.")
        case .network(let s): return s == "dns" ? L("Can't reach it: unknown host name.") : L("Can't reach it.")
        case .dropped, .noAnswer, .protocolError: return L("The connection was lost.")
        }
    }

    enum Light { case on, busy, off, problem }
    func light(_ h: SSHHost) -> Light {
        let s = status[h.id] ?? SSHHostStatus()
        if s.working { return .busy }
        guard store.enabled, h.enabled else { return .off }
        if !h.deployed { return s.failure == nil ? .off : .problem }
        switch s.phase {
        case .connected: return .on
        case .connecting, .retrying: return .busy
        case .stopped: return .problem
        case .off: return .off
        }
    }
}

/// The state dot: green connected, accent connecting or retrying, warning stopped, grey off; a symbol instead of a colour
/// when "Differentiate without colour" is on.
struct SSHStateDot: View {
    let light: SSHHostManager.Light
    let label: String
    @ObservedObject var display = DisplayOptions.shared

    var body: some View {
        let (color, symbol): (Color, String) = {
            switch light {
            case .on: return (.green, "checkmark.circle.fill")
            case .busy: return (Island.accent, "arrow.triangle.2.circlepath")
            case .problem: return (warningColor, "exclamationmark.triangle.fill")
            case .off: return (UI.hint, "minus.circle")
            }
        }()
        Group {
            if display.differentiateWithoutColor { Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color) }
            else { Circle().fill(color).frame(width: 7, height: 7) }
        }
        .frame(width: 12, height: 12)
        .motionSelection(light == .on)
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

/// The small summary for the Agents card's header: "● 2/3" while hosts are set up.
struct SSHHostsBadge: View {
    @ObservedObject var ssh = SSHHostManager.shared
    var body: some View {
        if ssh.anyConfigured {
            let total = ssh.store.hosts.count, up = ssh.connectedCount
            let light: SSHHostManager.Light = !ssh.store.enabled ? .off : up == total ? .on : up == 0 ? .problem : .busy
            let label = String(format: L("SSH hosts: %d of %d connected"), up, total)
            HStack(spacing: Space.xs) {
                SSHStateDot(light: light, label: label)
                Text("\(up)/\(total)").font(UI.detail.monospacedDigit()).foregroundStyle(UI.secondary)
            }
            .help(label)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
        }
    }
}

struct SSHHostsCard: View {
    @ObservedObject var ssh = SSHHostManager.shared
    let kit = AwakeRowKit()

    var body: some View {
        kit.card("server.rack", L("SSH hosts")) {
            kit.row(L("Follow AI agents on SSH hosts"),
                    detail: L("Through your own ssh: alerts, plans, questions and approvals in the notch. No port is opened; each host only after your OK."),
                    tip: L("Cocaine runs /usr/bin/ssh with your ~/.ssh/config and keys, host keys always checked, nothing forwarded")) {
                kit.toggle(L("Follow AI agents on SSH hosts"), Binding(get: { ssh.store.enabled }, set: { ssh.setAllEnabled($0) }))
            }
            ForEach(ssh.store.hosts) { h in hostRow(h) }
            HStack(spacing: Space.s) {
                Button(L("Add host…")) { addHost() }.buttonStyle(CocaineButtonStyle())
                    .disabled(ssh.store.hosts.count >= SSHHostStore.maxHosts)
                Spacer(minLength: 0)
                if ssh.anyConfigured {
                    Button(L("Log")) { showLog() }.buttonStyle(CocaineButtonStyle(kind: .plain))
                        .help(L("What was done on each host, when (never any content)"))
                }
            }
        }
    }

    @ViewBuilder private func hostRow(_ h: SSHHost) -> some View {
        let s = ssh.status[h.id] ?? SSHHostStatus()
        let text = ssh.stateText(h)
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .center, spacing: Space.m) {
                SSHStateDot(light: ssh.light(h), label: text)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(h.label).font(UI.itemTitle).lineLimit(1)
                    Text(text).font(UI.detail).foregroundStyle(ssh.light(h) == .problem ? warningColor : UI.secondary)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    if let note = s.note, !s.working { Text(note).font(UI.detail).foregroundStyle(UI.hint).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                kit.toggle(String(format: L("Connect to %@"), h.label), Binding(get: { h.enabled && h.deployed }, set: { ssh.setEnabled(h.id, $0) }))
                    .disabled(!h.deployed || !ssh.store.enabled)
            }
            actions(h, s)
            if let r = ssh.review, r.host == h.id { SSHReviewView(review: r, host: h) }
        }
        .padding(.vertical, Space.xs)
    }

    @ViewBuilder private func actions(_ h: SSHHost, _ s: SSHHostStatus) -> some View {
        let up = ssh.connected(h.id)
        let needsRelay = !h.deployed || s.phase == .stopped(.relayMissing) || s.phase == .stopped(.keyMismatch) || s.failure == .relayMissing
        let needsLogin: Bool = { if case .stopped(let f) = s.phase { return f == .auth || f == .hostKeyUnknown }; return s.failure == .auth }()
        let canRetry: Bool = { switch s.phase { case .stopped, .retrying: return h.deployed && h.enabled; default: return false } }()
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s) { buttons(h, up: up, needsRelay: needsRelay, needsLogin: needsLogin, canRetry: canRetry, hooks: !s.hooksOn.isEmpty, busy: s.working) }
            VStack(alignment: .leading, spacing: Space.s) { buttons(h, up: up, needsRelay: needsRelay, needsLogin: needsLogin, canRetry: canRetry, hooks: !s.hooksOn.isEmpty, busy: s.working) }
        }
        .padding(.leading, 12 + Space.m)
    }

    @ViewBuilder private func buttons(_ h: SSHHost, up: Bool, needsRelay: Bool, needsLogin: Bool, canRetry: Bool, hooks: Bool, busy: Bool) -> some View {
        if needsRelay { Button(L("Install relay…")) { installRelay(h) }.buttonStyle(CocaineButtonStyle(kind: .primary, busy: busy)).disabled(busy) }
        if needsLogin { Button(L("Log in in Terminal")) { _ = ssh.connectInTerminal(h.id) }.buttonStyle(CocaineButtonStyle()) }
        if canRetry { Button(L("Retry")) { ssh.retry(h.id) }.buttonStyle(CocaineButtonStyle()) }
        if up && ssh.review?.host != h.id {
            Button(hooks ? L("Check hooks…") : L("Review hooks…")) { ssh.reviewHooks(h.id) }.buttonStyle(CocaineButtonStyle(busy: busy)).disabled(busy)
                .help(L("Shows what would change in the AI tools' settings there, before anything is written"))
            if hooks { Button(L("Remove hooks")) { removeHooks(h) }.buttonStyle(CocaineButtonStyle(kind: .destructive)).disabled(busy) }
        }
        Button(L("Remove…")) { remove(h) }.buttonStyle(CocaineButtonStyle(kind: .destructive)).disabled(busy)
    }

    // MARK: Dialogs

    private func addHost() {
        let names = SSHConfigScan.suggestions().filter { n in !ssh.store.hosts.contains { $0.alias == n } }
        func typed() {
            let spec = DialogSpec(icon: "server.rack", title: L("Add an SSH host"),
                                  message: L("A Host from ~/.ssh/config, or user@host (with :port if needed). Nothing is connected until you install the relay."),
                                  field: DialogField(placeholder: L("user@host or a config Host"), validate: { t in
                                      SSHAlias.destination(t.trimmingCharacters(in: .whitespaces)) == nil ? L("Letters, digits and . _ @ : - only") : nil }),
                                  buttons: [DialogButton(id: "cancel", title: L("Cancel"), role: .cancel),
                                            DialogButton(id: "add", title: L("Add"), needsValidInput: true)])
            DialogCenter.shared.present(spec) { r in
                if case .button("add", let text, _) = r { added(ssh.add(alias: text)) }
            }
        }
        guard !names.isEmpty else { typed(); return }
        let spec = DialogSpec(icon: "server.rack", title: L("Add an SSH host"), message: L("From your ~/.ssh/config and known_hosts (only read):"),
                              choices: names.map { DialogChoice(id: $0, title: $0, symbol: "server.rack") } + [DialogChoice(id: "\u{0}type", title: L("Another host…"), symbol: "keyboard")],
                              choiceMode: .act, buttons: [DialogButton(id: "cancel", title: L("Cancel"), role: .cancel)])
        DialogCenter.shared.present(spec) { r in
            guard case .choice(let id) = r else { return }
            if id == "\u{0}type" { DispatchQueue.main.async { typed() } } else { added(ssh.add(alias: id)) }
        }
    }

    private func added(_ r: Result<SSHHost, SSHHostManager.AddError>) {
        switch r {
        case .success(let h): Haptic.tap(.alignment); DispatchQueue.main.async { installRelay(h) }
        case .failure(let e):
            let text = e == .duplicate ? L("That host is already in the list.") : e == .full ? L("The list is full.") : L("Letters, digits and . _ @ : - only")
            DialogCenter.shared.present(Dialogs.message(L("Can't add that host"), text)) { _ in }
        }
    }

    private func installRelay(_ h: SSHHost) {
        let spec = DialogSpec(icon: "server.rack", title: String(format: L("Install the relay on %@?"), h.label),
                              message: L("Cocaine copies one small script (perl) and a key into ~/.cocaine there, through your own ssh. Nothing else changes and no port is opened. The AI tools' settings there change only after you review them."),
                              buttons: [DialogButton(id: "cancel", title: L("Not now"), role: .cancel), DialogButton(id: "install", title: L("Install"))],
                              safeDefault: true)
        DialogCenter.shared.present(spec) { r in
            if r.buttonID == "install" { ssh.deploy(h.id) }
        }
    }

    private func removeHooks(_ h: SSHHost) {
        let spec = DialogSpec(icon: "server.rack", title: String(format: L("Remove Cocaine's hooks on %@?"), h.label),
                              message: L("Only Cocaine's own lines go; everything else in those files stays. A backup is kept in ~/.cocaine/backup there."),
                              buttons: [DialogButton(id: "cancel", title: L("Cancel"), role: .cancel), DialogButton(id: "remove", title: L("Remove hooks"), role: .destructive)])
        DialogCenter.shared.present(spec) { r in if r.buttonID == "remove" { ssh.removeHooks(h.id) } }
    }

    private func remove(_ h: SSHHost) {
        var choices = [DialogChoice(id: "local", title: L("Remove from Cocaine only"), symbol: "minus.circle")]
        if ssh.connected(h.id) { choices.insert(DialogChoice(id: "clean", title: L("Remove, and take Cocaine off the host"), symbol: "trash", destructive: true), at: 0) }
        let spec = DialogSpec(icon: "server.rack", title: String(format: L("Remove %@?"), h.label),
                              message: ssh.connected(h.id) ? L("Taking Cocaine off the host removes its hooks there and ~/.cocaine.")
                                  : L("It isn't connected: its hooks and ~/.cocaine stay there until you remove them (rm -rf ~/.cocaine, and Cocaine's lines in the AI tools' settings)."),
                              choices: choices, choiceMode: .act, buttons: [DialogButton(id: "cancel", title: L("Cancel"), role: .cancel)])
        DialogCenter.shared.present(spec) { r in
            guard case .choice(let id) = r else { return }
            ssh.remove(h.id, cleanUp: id == "clean")
        }
    }

    private func showLog() {
        let url = SSHHostStore.folder(ssh.support).appendingPathComponent("audit.log")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The hooks' changes on a host, file by file, before anything is written.
struct SSHReviewView: View {
    let review: SSHReview
    let host: SSHHost
    @ObservedObject var ssh = SSHHostManager.shared

    static func reason(_ r: String) -> String {
        switch r {
        case "local": return L("Cocaine runs on that machine itself: its own hooks are left alone.")
        case "format": return L("Not a JSON file Cocaine can edit safely: left alone.")
        default: return L("Couldn't be read: left alone.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if review.plan.changes.isEmpty {
                Text(review.plan.problems.isEmpty ? L("Nothing to change: the hooks there are up to date.") : L("Nothing Cocaine can change there."))
                    .font(UI.detail).foregroundStyle(UI.secondary)
            } else {
                Text(String(format: L("These files on %@ would change:"), host.label)).font(UI.detail).foregroundStyle(UI.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ForEach(review.plan.changes) { c in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("~/" + c.path + "  +\(c.added) −\(c.removed)" + (c.before == nil ? " · " + L("new file") : ""))
                                    .font(UI.section).foregroundStyle(UI.primary)
                                ForEach(Array(SSHInstaller.shown(c.diff).prefix(300).enumerated()), id: \.offset) { _, l in DiffRow(line: l) }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("~/" + c.path + ". " + DiffRow.spoken(c.diff))
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            ForEach(review.plan.problems, id: \.path) { p in
                Text("~/" + p.path + ": " + Self.reason(p.reason)).font(UI.detail).foregroundStyle(warningColor).fixedSize(horizontal: false, vertical: true)
            }
            if review.plan.changes.contains(where: { $0.tool == "codex" }) {
                Text(L("Codex asks to trust new hooks once: run /hooks in Codex there.")).font(UI.detail).foregroundStyle(UI.hint).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s) {
                Spacer(minLength: 0)
                Button(review.plan.changes.isEmpty ? L("Close") : L("Cancel")) { ssh.review = nil }.buttonStyle(CocaineButtonStyle())
                if !review.plan.changes.isEmpty {
                    Button(L("Change these files")) { Haptic.tap(.alignment); ssh.applyReview() }.buttonStyle(CocaineButtonStyle(kind: .primary))
                }
            }
        }
        .padding(Space.m)
        .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(0.05)))
        .motionAppear()
    }
}
