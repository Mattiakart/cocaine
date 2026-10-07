// The panel's SwiftUI view (PanelView), its tabs (PanelTabs), the time stepper and the dialog overlay.

import AppKit
import AVFoundation
import Combine
import CoreAudio
import EventKit
import Carbon.HIToolbox
import Darwin
import ImageIO
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import os

private extension View {
    /// The soft rounded card that holds a group of settings.
    func panelCard() -> some View {
        self.background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
    }
}

struct PanelView: View {
    @ObservedObject var m: PanelModel
    @ObservedObject var clip = ClipboardHistory.shared
    @ObservedObject var up = Updater.shared
    @ObservedObject var dialogs = DialogCenter.shared
    @ObservedObject var pickers = PickerCenter.shared

    /// Clock times in the app's language (rebuilt when it changes).
    private static var timeCache: DateFormatter?
    private static var time: DateFormatter {
        let loc = Language.locale
        if let f = timeCache, f.locale == loc { return f }
        let f = DateFormatter(); f.timeStyle = .short; f.locale = loc
        timeCache = f
        return f
    }
    static func timeString(_ d: Date) -> String { time.string(from: d) }

    // MARK: Building blocks

    /// A group of settings: an icon and a name (with an optional control on the right) over its rows, in a card.
    private func card<Trailing: View, Content: View>(_ icon: String, _ title: String, warning: Bool = false,
                                                     @ViewBuilder trailing: () -> Trailing,
                                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                Image(systemName: icon).font(UI.icon).foregroundStyle(Island.accent)
                    .frame(width: UI.iconColumn, height: UI.iconColumn)    // wide symbols (battery, badges) stay centred on the column
                Text(title).font(UI.groupTitle).lineLimit(1)
                if warning { Image(systemName: "exclamationmark.triangle.fill").font(UI.detail).foregroundStyle(warningColor) }
                Spacer(minLength: Space.m)
                trailing().fixedSize()
            }
            .frame(minHeight: 22)
            VStack(alignment: .leading, spacing: Space.s) { content() }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: CTL.cardRadius))     // whatever it holds is cut at the card's edge, never drawn outside
        .panelCard()
    }

    private func card<Content: View>(_ icon: String, _ title: String, warning: Bool = false,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        card(icon, title, warning: warning, trailing: { EmptyView() }, content)
    }

    /// A row's title (with a green dot while what it watches is true now) and its detail line.
    private func titleBlock(_ title: String, _ detail: String?, warning: Bool = false, live: Bool = false, wraps: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.s) {
                Text(title).font(UI.title).lineLimit(wraps ? 2 : 1).fixedSize(horizontal: !wraps, vertical: true)
                if live {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                        .help(L("True now")).accessibilityLabel(L("True now"))
                }
            }
            if let detail {
                Text(detail).font(UI.detail).foregroundStyle(warning ? warningColor : UI.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, detail == nil ? 0 : Space.rowAir)      // a two-line row keeps the same air as one-line rows
    }

    /// One row: its name on the left, its control on the right edge. Always one line for the control; the name wraps.
    private func row<Control: View>(_ title: String, detail: String? = nil, tip: String? = nil, warning: Bool = false, live: Bool = false,
                                    @ViewBuilder _ control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
            titleBlock(title, detail, warning: warning, live: live).frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()
        }
        .frame(minHeight: 22)
        .fixedSize(horizontal: false, vertical: true)
        .help(tip ?? detail ?? title)
    }

    /// A row whose value is a short list: a segmented control beside the title when it fits (in this language), else on its
    /// own full-width line under it. No popup at all.
    private func segRow<T: Hashable>(_ title: String, detail: String? = nil, tip: String? = nil, live: Bool = false, _ selection: Binding<T>, _ values: [T],
                                     spoken: @escaping (T) -> String? = { _ in nil }, _ label: @escaping (T) -> String) -> some View {
        let seg = Segments(selection: selection, values: values, name: title, label: label, spoken: spoken)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Space.m) {
                titleBlock(title, detail, live: live, wraps: false)
                Spacer(minLength: Space.l)
                seg.fixedSize()
            }
            VStack(alignment: .leading, spacing: Space.s) {
                titleBlock(title, detail, live: live)
                seg.frame(maxWidth: .infinity)
            }
        }
        .frame(minHeight: 22)
        .help(tip ?? detail ?? title)
    }

    private func toggle(_ title: String, _ on: Binding<Bool>) -> some View {
        CocaineSwitch(on).accessibilityLabel(title)
    }

    /// What each AI reports, from what its hooks can see.
    private func toolDetail(_ id: String) -> String {
        switch id {
        case "claude", "opencode": return L("Finishes, or asks permission or a question")
        case "codex": return L("Finishes, or asks for approval")
        case "cursor": return L("Finishes (approvals aren't reported)")
        case "copilot": return L("Finishes, or asks permission (CLI and VS Code)")
        case "windsurf": return L("After each reply")
        default: return L("Finishes, or asks permission")
        }
    }

    private func durationName(_ s: Double) -> String { s == 0 ? L("Until you're back") : String(format: L("%d s"), Int(s)) }
    private func repeatName(_ min: Int) -> String { min == 0 ? L("Never") : String(format: L("%d min"), min) }

    /// "∞" for no limit, else "45 min", "2 h" or "2 h 30 min": any length, not just the presets.
    private func durationLabel(_ minutes: Int) -> String { Dur.short(minutes: minutes) }   // the same words as the island's
    private func noLimit(_ minutes: Int) -> String? { minutes == 0 ? L("No limit") : nil }

    /// "A +2" for a list of chosen things (or None).
    private func listValue(_ names: [String]) -> String {
        names.isEmpty ? L("None") : names.count == 1 ? names[0] : "\(names[0]) +\(names.count - 1)"
    }

    /// The new list after a dropdown's boxes changed: what stays keeps its order, what was added follows (A–Z).
    static func merged(_ old: [String], _ chosen: Set<String>) -> [String] {
        old.filter { chosen.contains($0) } + chosen.subtracting(old).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var status: String {
        if m.needsAuth { return L("Admin password needed") }
        if m.on && m.holdMissing { return L("Keeping the screen on…") }
        var parts = [m.on ? L("Your Mac stays awake") : L("Your Mac sleeps as usual")]
        if m.on, let until = m.onUntil, until > Date() { parts.append(String(format: L("until %@"), Self.time.string(from: until))) }
        if m.on, let by = m.triggeredBy { parts.append(String(format: L("Turned on by %@"), by)) }   // why it is on
        else if !m.on, let hold = m.triggerHold { parts.append(hold) }                                 // why a trigger can't turn it on
        if let paused = m.alertsPausedUntil { parts.append("⏸ " + String(format: L("until %@"), Self.time.string(from: paused))) }
        return parts.joined(separator: " · ")
    }

    // MARK: General

    private func stepButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: { Haptic.tap(.alignment); action() }) {
            Image(systemName: symbol).font(UI.chevron).frame(width: 24, height: 24).contentShape(Rectangle())   // a 24 pt target
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Any length you like, in steps of 15 minutes (up to 24 hours): one unit, its readout as wide as the longest value.
    private var customTimer: some View {
        HStack(spacing: 0) {
            stepButton("minus", L("Shorter")) { m.timerMinutes = max(15, (m.timerMinutes <= 0 ? 60 : m.timerMinutes) - 15) }
            Divider().frame(height: 12)
            ZStack {
                Text(durationLabel(1425)).hidden()
                Text(durationLabel(m.timerMinutes))
            }
            .font(UI.value.monospacedDigit()).lineLimit(1).padding(.horizontal, Space.m)
            Divider().frame(height: 12)
            stepButton("plus", L("Longer")) { m.timerMinutes = min(1440, (m.timerMinutes <= 0 ? 60 : m.timerMinutes) + 15) }
        }
        .frame(height: CTL.h)
        .background(RoundedRectangle(cornerRadius: CTL.radius).fill(CTL.track))
        .fixedSize()
        .onScrollSteps(every: 10) { m.timerMinutes = min(1440, max(15, (m.timerMinutes <= 0 ? 60 : m.timerMinutes) + 15 * $0)) }
        .help(L("Any length, in steps of 15 minutes"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Stay on for"))
    }

    /// Scrolling over the presets moves through them (∞ · 30 min … 8 h).
    private func stepTimerPreset(_ n: Int) {
        let c = Settings.timerChoices
        let i = c.firstIndex(of: m.timerMinutes) ?? c.firstIndex { $0 >= m.timerMinutes } ?? 0
        m.timerMinutes = c[min(c.count - 1, max(0, i + n))]
    }

    private var timerCard: some View {
        card("hourglass", L("Stay on for"), trailing: { customTimer }) {
            Segments(selection: $m.timerMinutes, values: Settings.timerChoices, name: L("Stay on for"), label: durationLabel, spoken: noLimit)
                .frame(maxWidth: .infinity)
                .onScrollSteps(every: 24) { n in stepTimerPreset(n) }
            if !m.on {
                Text(L("Picking a length turns Cocaine on for that long")).font(UI.detail).foregroundStyle(UI.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(L("Cocaine turns itself off when the time is up"))
    }

    /// What happens when you leave the Mac alone: nothing, the screens dim, or they turn off (the Mac keeps working).
    private var idleMode: Binding<Int> {
        Binding(get: { !m.dimEnabled ? 0 : m.screenOff ? 2 : 1 }, set: { v in
            switch v {
            case 0: m.dimEnabled = false
            case 1: if m.screenOff { m.screenOff = false }; if !m.dimEnabled { m.dimEnabled = true }
            default: if !m.screenOff { m.screenOff = true }; if !m.dimEnabled { m.dimEnabled = true }
            }
        })
    }

    private var idleCard: some View {
        card("sun.min", L("When idle"), trailing: {
            Button(L("Screens off now")) { m.screenOffNow() }.buttonStyle(CocaineButtonStyle())
                .help(L("Turn the screens off now"))
        }) {
            Segments(selection: idleMode, values: [0, 1, 2], name: L("When idle")) { [L("Nothing"), L("Dim"), L("Screen off")][$0] }
                .frame(maxWidth: .infinity)
            if m.dimEnabled && !m.screenOff {
                HStack(spacing: Space.m) {
                    Image(systemName: "sun.min").font(UI.icon).foregroundStyle(UI.secondary).frame(width: UI.iconColumn)
                    CocaineSlider(value: m.levelPercent, range: 1...50, name: L("Dim the screen when idle"),
                                  valueText: "\(Int(m.levelPercent))%") { m.setLevel($0) }
                    Text("\(Int(m.levelPercent))%").font(UI.value.monospacedDigit()).frame(width: 34, alignment: .trailing)
                    Button(L("Preview")) { m.preview() }.buttonStyle(CocaineButtonStyle()).disabled(m.previewing)
                        .help(L("Shows the minimum brightness for 3 seconds"))
                }
                .frame(minHeight: 22)
            }
            if m.dimEnabled && m.screenOff {
                Text(L("The Mac keeps working with the screen off.")).font(UI.detail).foregroundStyle(UI.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(L("While Cocaine is on. Any key or click turns the screen back on. The Mac locks as set in Lock Screen settings."))
            }
            if m.dimEnabled {
                segRow(L("After"), $m.delayMinutes, Settings.delayChoices) { Dur.short(minutes: $0) }
            }
        }
        .help(L("Goes back to normal as soon as you touch anything"))
    }

    /// Battery Guard: one level for everything battery (the power trigger lets go there too).
    private var batteryCard: some View {
        card("battery.50", L("Battery Guard")) {
            row(L("When the battery reaches"), detail: m.battery.map { String(format: L("On battery only. Now %@"), $0) } ?? L("On battery only")) {
                EmptyView()
            }
            Segments(selection: $m.batteryThreshold, values: Settings.batteryChoices, name: L("Battery Guard")) { $0 == 0 ? L("Off") : "\($0)%" }
                .frame(maxWidth: .infinity)
            segRow(L("Then"), tip: L("What Cocaine does at that level"), $m.batteryTurnsOff, [true, false]) { $0 ? L("Turn Cocaine off") : L("Only warn me") }
                .dimGroup(m.batteryThreshold == 0)
        }
    }

    /// Who is doing what: the AI sessions at work, or, when none is, the latest alerts.
    @ViewBuilder private var activityCard: some View {
        if !m.board.isEmpty || !m.approvals.isEmpty || m.agentNotice != nil {
            card("sparkles", L("Agents")) {             // all of them, those that need you first; a click goes to the session
                AgentListView(entries: m.board, approvals: m.approvals, notice: m.agentNotice, island: false, accent: Island.accent,
                              warning: warningColor, maxHeight: 260, focus: m.focusAgent, answer: m.answerApproval, release: m.releaseApproval)
                    .padding(.horizontal, -AgentListView.inset)   // the rows' icons on the content edge, request cards into the padding
            }
        } else if m.ai.available {
            card("bell", L("Recent alerts"), trailing: {
                if !m.history.isEmpty {
                    Button(L("Clear")) { m.clearHistory() }.buttonStyle(CocaineButtonStyle(kind: .plain))
                        .padding(.trailing, -8)                  // its text on the content edge; the hover pill reaches past it
                }
            }) {
                if m.history.isEmpty {
                    Text(L("Alerts you receive will show up here")).font(UI.detail).foregroundStyle(UI.hint)
                } else {
                    ForEach(m.history.prefix(3)) { r in         // a click goes back to the session that sent it
                        Button { m.focusAgent(r.origin, r.from) } label: {
                            activityRow("bell.fill", UI.secondary, r.from, r.message, r.project, Self.time.string(from: r.at)).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(L("Go to this session"))
                    }
                }
            }
        }
    }

    /// An icon, who and what (the message gives way before the project), and when, on the right edge: the same look as an
    /// agent's row, which takes this place while sessions are live.
    private func activityRow(_ icon: String, _ color: Color, _ title: String, _ message: String, _ project: String?, _ when: String) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
            Image(systemName: icon).font(UI.icon).foregroundStyle(color).frame(width: UI.iconColumn)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(UI.itemTitle).lineLimit(1)
                HStack(spacing: Space.xs) {
                    Text(message.prefix(1).uppercased(with: Language.locale) + message.dropFirst()).lineLimit(1)   // "Has finished", like "Working"
                    if let project { Text("·"); Text(project).lineLimit(1).layoutPriority(1) }
                }
                .font(UI.detail).foregroundStyle(UI.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(when).font(UI.detail.monospacedDigit()).foregroundStyle(UI.secondary).fixedSize()
        }
    }

    private var languageSpec: PickerSpec {
        let code = m.language
        return PickerSpec(id: "language", title: L("Language"),
                          items: [PickerItem(id: "", title: L("Same as Mac"), emoji: Language.flag(Language.system))]
                              + Language.codes.map { PickerItem(id: $0, title: Language.nativeName($0), emoji: Language.flag($0)) },
                          mode: .single(code))
    }

    private var appCard: some View {
        card("gearshape", "Cocaine") {
            row(L("Open at login")) {
                CocaineSwitch(on: m.loginEnabled) { m.setLogin(!m.loginEnabled) }.accessibilityLabel(L("Open at login"))
            }
            row(L("Updates"), detail: up.statusText, warning: { if case .failed = up.phase { return true }; return false }()) { updateControl }
            row(L("Check for updates automatically"), tip: L("Once a day. Nothing is downloaded until you press Install.")) {
                toggle(L("Check for updates automatically"), $up.autoCheck)
            }
            row(L("Language")) {
                let code = m.language.isEmpty ? Language.system : m.language
                ValueButton(id: "language", title: L("Language"), value: "\(Language.flag(code))  \(Language.nativeName(code))",
                            spec: { languageSpec }, onPick: { m.language = $0 })
            }
            row(L("Show in the notch"), detail: L("Replaces the menu-bar icon"),
                tip: L("Shows Cocaine and its tools in the notch, or at the top of the screen")) { toggle(L("Show in the notch"), $m.island) }
            row(L("Haptic feedback"), tip: L("A light tap on the trackpad when you change a timer, switch a page or toggle something")) { toggle(L("Haptic feedback"), $m.haptics) }
            row(L("Global shortcuts"), detail: "⌃⌥⌘C \(L("on/off")) · ⌃⌥⌘O \(L("panel")) · ⌃⌥⌘P \(L("pause alerts"))",
                tip: "⌃⌥⌘C: " + L("Turn Cocaine on or off") + "\n⌃⌥⌘O: " + L("Open the panel") + "\n⌃⌥⌘P: " + L("Pause or resume alerts")) {
                toggle(L("Global shortcuts"), $m.hotkeys)
            }
            row(L("Shortcuts app and links"),
                tip: L("Lets the Shortcuts app and cocaine:// links turn Cocaine on and off without asking. Off: Cocaine asks you first.")) {
                toggle(L("Shortcuts app and links"), $m.allowLinks)
            }
            if m.permissionProblems.isEmpty {
                row(L("Permissions"), detail: L("Everything Cocaine needs is allowed"), tip: SigningTier.current.panelLine) {
                    Image(systemName: "checkmark.circle.fill").font(UI.icon).foregroundStyle(.green).accessibilityLabel(L("Everything Cocaine needs is allowed"))
                }
            }
            row(L("Feedback or help"), detail: Feedback.address) {
                Button(L("Write…")) { Feedback.compose() }.buttonStyle(CocaineButtonStyle()).help(L("Feedback or help") + " — " + Feedback.address)
            }
        }
    }

    /// Check, Install (or the Homebrew command / the download page when this copy can't update itself), Cancel, Retry.
    @ViewBuilder private var updateControl: some View {
        switch up.phase {
        case .checking, .installing: ProgressView().controlSize(.small).frame(height: CTL.h)
        case .downloading: Button(L("Cancel")) { up.cancel() }.buttonStyle(CocaineButtonStyle())
        case .available:
            if up.eligibility == .homebrew {
                Button(L("Copy command")) { up.copyBrewCommand() }.buttonStyle(CocaineButtonStyle()).help(Homebrew.upgradeCommand)
            } else {
                Button(up.eligibility == .ok ? L("Install") : L("Download")) { up.install() }.buttonStyle(CocaineButtonStyle(kind: .primary))
            }
        case .failed(_, let retry): Button(retry ? L("Retry") : L("Check now")) { retry ? up.retry() : up.check() }.buttonStyle(CocaineButtonStyle())
        default: Button(L("Check now")) { up.check() }.buttonStyle(CocaineButtonStyle())
        }
    }

    /// Only when something is missing: what, and a button (when all is fine it is one line in the Cocaine card).
    private var permissionsCard: some View {
        card("lock.shield", L("Permissions"), warning: true) {
            ForEach(m.permissionProblems) { p in
                row(p.title, detail: p.reason, warning: true) { Button(L("Allow")) { m.requestPermission(p) }.buttonStyle(CocaineButtonStyle(kind: .primary)) }
            }
            Text(SigningTier.current.panelLine).font(UI.detail).foregroundStyle(UI.secondary)   // what the permissions are tied to
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if !m.permissionProblems.isEmpty { permissionsCard }
            timerCard
            idleCard
            batteryCard
            appCard
        }
    }

    // MARK: Island (the island's settings: only while it is on)

    private var islandTab: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            card("rectangle.topthird.inset.filled", L("Island")) {
                row(L("Replace system HUD"), detail: L("Cocaine handles the volume and brightness keys and shows their bar in the island. When the island can't be seen (full screen, settings open), macOS shows its own.")) {
                    toggle(L("Replace system HUD"), $m.replaceHUD)
                }
            }
            clipboardCard
        }
    }

    // MARK: Clipboard (the island's page; Sources/Clipboard.swift)

    private func clipSetting<T>(_ kp: WritableKeyPath<ClipSettings, T>) -> Binding<T> {
        Binding(get: { clip.settings[keyPath: kp] }, set: { var s = clip.settings; s[keyPath: kp] = $0; clip.update(s) })
    }

    /// A clipboard age, short, in the app's language ("1 h", "1 w", "30 d"; "∞" for no limit).
    private func ageName(_ hours: Int) -> String {
        guard hours > 0 else { return "∞" }
        let f = DateComponentsFormatter(); f.unitsStyle = .abbreviated
        var cal = Calendar.current; cal.locale = Language.locale; f.calendar = cal
        f.allowedUnits = hours < 24 ? [.hour] : hours % 168 == 0 ? [.weekOfMonth] : [.day]
        return f.string(from: TimeInterval(hours * 3600)) ?? "\(hours)"
    }

    private func appIcon(bundleID id: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private var excludedAppsSpec: PickerSpec {
        let s = clip.settings
        let chosen = s.excludedApps.map { PickerItem(id: $0, title: ClipboardHistory.appName($0) ?? $0, image: appIcon(bundleID: $0)) }
        let open = ClipboardUI.runningApps(excluding: s.excludedApps).map { PickerItem(id: $0.id, title: $0.name, image: appIcon(bundleID: $0.id), section: 1) }
        return PickerSpec(id: "excludedApps", title: L("Excluded apps"), items: chosen + open, mode: .multi, selected: Set(s.excludedApps), sectionTitle: L("Open now"))
    }

    private var patternsSpec: PickerSpec {
        let p = clip.settings.patterns
        return PickerSpec(id: "patterns", title: L("Excluded patterns"), items: p.map { PickerItem(id: $0, title: $0) }, mode: .multi, selected: Set(p))
    }

    private var clipboardCard: some View {
        let s = clip.settings
        return card("doc.on.clipboard", L("Clipboard"), warning: clip.problem != nil) {
            row(L("Save on this Mac"), detail: clip.problem ?? (s.persist ? L("Encrypted, with its key in your Keychain") : L("Off: kept in memory only, gone when Cocaine quits")),
                warning: clip.problem != nil) {
                CocaineSwitch(on: s.persist) { ClipboardUI.setPersist(clip, !s.persist) }.accessibilityLabel(L("Save on this Mac"))
            }
            segRow(L("Keep at most"), tip: L("Favorites don't count and are never removed"), clipSetting(\.maxItems), ClipSettings.itemChoices,
                   spoken: { String(format: L("%d items"), $0) }) { "\($0)" }
            segRow(L("Forget after"), clipSetting(\.maxAgeHours), ClipSettings.ageChoices, spoken: { $0 == 0 ? L("No limit") : nil }, ageName)
            segRow(L("Space in all"), clipSetting(\.maxTotalMB), ClipSettings.totalChoices) { "\($0) MB" }
            segRow(L("Largest item"), tip: L("Bigger images and texts aren't kept"), clipSetting(\.maxItemMB), ClipSettings.itemSizeChoices) { "\($0) MB" }
            row(L("Skip card numbers and keys"), tip: L("Card numbers, private keys, API keys and other tokens aren't kept")) {
                toggle(L("Skip card numbers and keys"), clipSetting(\.skipSecrets))
            }
            row(L("Excluded apps"), detail: L("Password managers are always excluded")) {
                ValueButton(id: "excludedApps", title: L("Excluded apps"), value: listValue(s.excludedApps.map { ClipboardHistory.appName($0) ?? $0 }),
                            spec: { excludedAppsSpec }, onChange: { set in
                                var n = clip.settings; n.excludedApps = Self.merged(n.excludedApps, set); clip.update(n)
                            })
            }
            row(L("Excluded patterns"), tip: L("Text matching one of these regular expressions isn't kept")) {
                HStack(spacing: Space.s) {
                    if !s.patterns.isEmpty {
                        ValueButton(id: "patterns", title: L("Excluded patterns"), value: "\(s.patterns.count)", maxWidth: 120,
                                    spec: { patternsSpec }, onChange: { set in
                                        var n = clip.settings; n.patterns = Self.merged(n.patterns, set); clip.update(n)
                                    })
                    }
                    Button(L("Add…")) { pickers.close(); ClipboardUI.addPattern(clip) }.buttonStyle(CocaineButtonStyle())
                }
            }
            row(L("Delete everything"), detail: L("History, favorites, saved files and their key")) {
                Button(L("Delete…")) { ClipboardUI.confirmDeleteEverything(clip) }.buttonStyle(CocaineButtonStyle(kind: .destructive))
            }
        }
    }

    // MARK: AI alerts

    private var pauseSpec: PickerSpec {
        var items: [PickerItem] = []
        if m.alertsPausedUntil != nil { items.append(PickerItem(id: "resume", title: L("Resume"), symbol: "play.fill")) }
        items += [PickerItem(id: "30", title: String(format: L("%d min"), 30)), PickerItem(id: "60", title: L("1 hour")),
                  PickerItem(id: "tomorrow", title: L("Until tomorrow"))]
        return PickerSpec(id: "pause", title: L("Pause"), items: items, mode: .action)
    }

    private func pause(_ id: String) {
        switch id {
        case "resume": m.pauseAlerts(nil)
        case "30": m.pauseAlerts(Date().addingTimeInterval(1800))
        case "60": m.pauseAlerts(Date().addingTimeInterval(3600))
        default:
            let cal = Calendar.current
            m.pauseAlerts(cal.date(bySettingHour: 8, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date())!))
        }
    }

    private var aiTab: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            activityCard
            card("sparkles", L("Connected AIs"), warning: m.ai.codexNeedsTrust) {
                ForEach(m.ai.tools.filter(\.installed)) { t in
                    let untrusted = t.id == "codex" && m.ai.codexNeedsTrust
                    row(t.name, detail: untrusted ? L("Approve once in Settings → Hooks") : nil, tip: toolDetail(t.id), warning: untrusted) {
                        toggle(t.name, Binding(get: { t.on }, set: { m.setAI(t.id, $0) })).disabled(m.settingAI)
                    }
                }
                let others = m.ai.tools.filter { !$0.installed }.map(\.name)
                LinkButton(title: L("Other apps and scripts")) { NSWorkspace.shared.open(Feedback.alertsGuide) }
                    .help(others.isEmpty ? L("Other apps and scripts") : String(format: L("Also supported: %@"), others.joined(separator: ", ")))
            }
            card("bell.badge", L("When")) {
                row(L("Finishes"), tip: L("When an AI completes its work")) { toggle(L("Finishes"), $m.alertDone) }
                row(L("Needs you"), tip: L("When it asks for a permission or an answer")) { toggle(L("Needs you"), $m.alertInput) }
                row(L("Also at the Mac"), tip: L("Otherwise only when you've been away for 20 seconds")) { toggle(L("Also at the Mac"), $m.alertWhenPresent) }
                row(L("One alert per session"),
                    tip: L("Not for every agent or task that finishes: only when the whole session has had nothing going on for a minute")) {
                    toggle(L("One alert per session"), $m.alertPerSession)
                }
                row(L("Answer from the island"),
                    tip: L("Claude Code and Codex: allow or deny a request (or answer an MCP question) from the island. Nothing is ever allowed on its own: without an answer within 2 minutes the terminal asks as usual.")) {
                    toggle(L("Answer from the island"), $m.agentApprovals)
                }
                row(L("Pause"), tip: L("Silences every alert for a while")) {
                    ValueButton(id: "pause", title: L("Pause"),
                                value: m.alertsPausedUntil.map { String(format: L("until %@"), Self.time.string(from: $0)) } ?? L("Not paused"),
                                spec: { pauseSpec }, onPick: pause)
                }
            }
            card("speaker.wave.2", L("How"), trailing: {
                Button(L("Test")) { m.testAlert() }.buttonStyle(CocaineButtonStyle()).help(L("Shows an alert with these settings"))
            }) {
                row(L("Flash"), tip: L("Wakes the screens and flashes them")) { toggle(L("Flash"), $m.alertFlash) }
                row(L("Sound"), tip: L("Plays when the alert arrives")) {
                    ValueButton(id: "sound", title: L("Sound"), value: m.alertSound.isEmpty ? L("No sound") : m.alertSound,
                                spec: { PickerSpec(id: "sound", title: L("Sound"),
                                                   items: [PickerItem(id: "", title: L("No sound"), symbol: "speaker.slash")]
                                                       + Settings.sounds.map { PickerItem(id: $0, title: $0, symbol: "speaker.wave.2") },
                                                   mode: .single(m.alertSound)) },
                                onPick: { m.alertSound = $0 })
                }
                row(L("Voice"), tip: L("Reads out who's calling and the project")) { toggle(L("Voice"), $m.alertSpeak) }
                if m.alertSpeak {                               // which voice, only when there's one to choose
                    row(L("Voice type"), tip: L("The Mac's voices for your language; you hear it as you pick")) {
                        ValueButton(id: "voice", title: L("Voice type"), value: Voices.name(m.alertVoice),
                                    spec: { PickerSpec(id: "voice", title: L("Voice type"),
                                                       items: ([""] + Voices.available.map(\.identifier)).map { PickerItem(id: $0, title: Voices.name($0)) },
                                                       mode: .single(m.alertVoice)) },
                                    onPick: { m.alertVoice = $0 })
                    }
                }
                segRow(L("On screen"), tip: L("How long the alert stays"), $m.alertDuration, Settings.durationChoices, durationName)
                segRow(L("Repeat"), tip: L("While you're away, for up to 30 minutes"), $m.alertRepeatMinutes, Settings.repeatChoices, repeatName)
            }
        }
    }

    // MARK: Automation

    /// The schedule: the days (in the order this Mac's calendar starts its week) and the hours, on the wall clock.
    @ViewBuilder private var scheduleRows: some View {
        let cal = Language.calendar                         // weekday letters in the app's language
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: Space.xs) {
            ForEach(order, id: \.self) { day in
                let on = m.scheduleDays.contains(day)
                Button {
                    Haptic.tap(.alignment)
                    if on { m.scheduleDays.removeAll { $0 == day } } else { m.scheduleDays = (m.scheduleDays + [day]).sorted() }
                } label: {
                    Text(cal.veryShortStandaloneWeekdaySymbols[day - 1]).font(CTL.label)
                        .frame(maxWidth: .infinity, minHeight: CTL.h)
                        .background(RoundedRectangle(cornerRadius: CTL.radius).fill(on ? Island.accent : CTL.fill))
                        .foregroundStyle(on ? CTL.onAccentInk : Color.primary)        // black on the accent, as every accent fill (8:1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cal.standaloneWeekdaySymbols[day - 1])
                .accessibilityValue(on ? L("On") : L("Off"))
                .accessibilityAddTraits(on ? [.isToggle, .isSelected] : .isToggle)
            }
        }
        row(L("Hours"), detail: m.scheduleEnd <= m.scheduleStart ? L("Ends the next day") : nil,
            tip: L("Local time; follows daylight saving and time-zone changes")) {
            HStack(spacing: Space.xs) {
                TimeStepper(id: "scheduleStart", title: L("From"), minutes: $m.scheduleStart)
                Text("–").font(UI.value)
                TimeStepper(id: "scheduleEnd", title: L("To"), minutes: $m.scheduleEnd)
            }
        }
    }

    /// An app's icon by its name: from the running app, else from the app in /Applications (or the system's), else the generic one.
    private func appIcon(named name: String) -> NSImage? {
        if let a = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }), let i = a.icon { return i }
        for dir in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            let path = dir + "/" + name + ".app"
            if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        }
        return NSWorkspace.shared.icon(for: .application)
    }


    /// A multiple choice of apps by name: the chosen (and suggested) ones, then the ones open now.
    private func appsSpec(_ id: String, _ title: String, chosen: [String], suggested: [String] = []) -> PickerSpec {
        let known = Array(Set(chosen + suggested))
        let running = System.runningAppNames().filter { !known.contains($0) }
        return PickerSpec(id: id, title: title,
                          items: known.map { PickerItem(id: $0, title: $0, image: appIcon(named: $0)) }
                              + running.map { PickerItem(id: $0, title: $0, image: appIcon(named: $0), section: 1) },
                          mode: .multi, selected: Set(chosen), sectionTitle: L("Open now"))
    }

    /// The battery level the power trigger lets go at: Battery Guard's (10 % when it is off).
    private var batteryFloor: Int { PowerRule.batteryFloor(guardLevel: m.batteryThreshold) }

    private var automationTab: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            card("bolt.badge.automatic", L("Smart Triggers")) {
                row(L("An AI is at work"), tip: L("On while an AI works or waits for you; off 3 minutes after"), live: m.liveTriggers.contains("agents")) {
                    toggle(L("An AI is at work"), $m.triggerAgents)
                }
                row(L("These programs are open"), tip: L("On while any is running; off 3 minutes after"), live: m.liveTriggers.contains("apps")) {
                    ValueButton(id: "triggerApps", title: L("These programs are open"), value: listValue(m.triggerApps),
                                spec: { appsSpec("triggerApps", L("These programs are open"), chosen: m.triggerApps) },
                                onChange: { m.triggerApps = Self.merged(m.triggerApps, $0) })
                }
                segRow(L("Power"), detail: m.triggerPower == "battery" ? String(format: L("Until the battery is down to %@"), "\(batteryFloor)%") : nil,
                       tip: L("On while the Mac is on the charger, or on battery above a level; off 30 seconds after"), live: m.liveTriggers.contains("power"),
                       $m.triggerPower, ["", "ac", "battery"]) {
                    $0 == "ac" ? L("On the charger") : $0 == "battery" ? L("On battery") : L("Off")
                }
                segRow(L("External display"), tip: L("On while a display is connected (or while none is); off 30 seconds after"),
                       live: m.liveTriggers.contains("display"), $m.triggerDisplay, ["", "connected", "disconnected"]) {
                    $0 == "connected" ? L("Connected") : $0 == "disconnected" ? L("Not connected") : L("Off")
                }
                row(L("Schedule"), tip: L("On during these hours on the chosen days; off when they end"), live: m.liveTriggers.contains("schedule")) {
                    toggle(L("Schedule"), $m.triggerSchedule)
                }
                if m.triggerSchedule {
                    scheduleRows
                }
                if m.triggerCount >= 2 {
                    segRow(L("Turn on when"), tip: L("Any: one reason is enough. All: every chosen one must hold."), $m.triggerAll, [false, true]) {
                        $0 ? L("All are true") : L("Any is true")
                    }
                }
            }
            card("person.crop.circle.badge.checkmark", L("Stay active")) {
                row(L("Stay available in chat apps"), detail: L("While you're idle it sends an invisible mouse event just before Teams and the like would show you as away. This also keeps the screen saver, the lock and display sleep from starting.")) {
                    toggle(L("Stay available in chat apps"), $m.stayActive)
                }
                Group {
                    segRow(L("When"), tip: L("Only while one of the chosen apps is open, or all the time"), $m.stayActiveAlways, [false, true]) {
                        $0 ? L("Always") : L("While these apps are open")
                    }
                    row(L("Apps"), tip: L("The chat apps to keep available")) {
                        ValueButton(id: "stayApps", title: L("Apps"), value: listValue(m.stayActiveApps),
                                    spec: { appsSpec("stayApps", L("Apps"), chosen: m.stayActiveApps, suggested: Presence.defaultApps) },
                                    onChange: { m.stayActiveApps = Self.merged(m.stayActiveApps, $0) })
                    }
                }
                .dimGroup(!m.stayActive)
                if m.stayActive && !m.presenceAccess {
                    row(L("Needs permission to send input"), detail: L("Allow Cocaine in Privacy & Security → Accessibility"), warning: true) {
                        Button(L("Allow")) { m.requestPresence() }.buttonStyle(CocaineButtonStyle(kind: .primary))
                    }
                }
            }
            card("iphone.gen3", L("Remote work")) {
                row(L("iPhone"), detail: m.phoneCount == 0 ? L("Not set up: send it a Shortcut")
                    : String(format: L("Paired: %d"), m.phoneCount) + " · " + (m.phoneLinkUp ? L("Connected") : L("Connecting…"))) {
                    HStack(spacing: Space.s) {
                        Button(L("Send…")) { m.sendShortcut() }.buttonStyle(CocaineButtonStyle(busy: m.makingShortcut)).disabled(m.makingShortcut)
                            .help(L("Send the Shortcut to your iPhone"))
                        if m.phoneCount + m.oldPhones > 0 { Button(L("Revoke…")) { m.revokePhones() }.buttonStyle(CocaineButtonStyle(kind: .destructive)) }
                    }
                }
                if m.oldPhones > 0 {
                    row(L("Old Shortcuts"), detail: m.oldPhonesAllowedUntil.map { String(format: L("Unprotected, still accepted (status, on/off) until %@"),
                                                                                       $0.formatted(.dateTime.day().month(.abbreviated).year().locale(Language.locale))) }
                        ?? String(format: L("%d without protection or expired: send a new Shortcut"), m.oldPhones), warning: true) {   // warning: the detail only
                        HStack(spacing: Space.s) {
                            if m.oldPhonesAllowedUntil == nil {
                                Button(L("Allow 14 days")) { confirmAllowOldPhones() }.buttonStyle(CocaineButtonStyle())
                                    .help(L("Old Shortcuts send plain, unauthenticated text: anyone who learns their relay topic could use them"))
                            } else {
                                Button(L("Stop")) { m.allowOldPhones(false) }.buttonStyle(CocaineButtonStyle())
                            }
                            Button(L("Remove…")) { confirmRemoveOldPhones() }.buttonStyle(CocaineButtonStyle(kind: .destructive))
                        }
                    }
                }
                row(L("Wake for iPhone"), tip: L("Every 15 minutes it wakes briefly, even with the lid closed, to answer your iPhone")) {
                    toggle(L("Wake for iPhone"), $m.wakeForPhone)
                }
                row(L("Phone alerts"), detail: m.phone.isEmpty ? L("Not set up: see the guide") : m.phone) {
                    Button(L("Test")) { m.testPhone() }.buttonStyle(CocaineButtonStyle()).disabled(m.phone.isEmpty).help(L("Send a test to your phone"))
                }
                LinkButton(title: L("Remote work guide")) { NSWorkspace.shared.open(Feedback.remoteGuide) }
            }
        }
    }

    /// Accepting unprotected Shortcuts lowers the protection: asked first, the safe answer is the default.
    private func confirmAllowOldPhones() {
        DialogCenter.shared.present(Dialogs.allowOldShortcuts()) { r in if r.buttonID == "allow" { m.allowOldPhones(true) } }
    }

    /// Removing old Shortcuts can't be undone (those iPhones stop working): asked first, Cancel is the default.
    private func confirmRemoveOldPhones() {
        DialogCenter.shared.present(Dialogs.removeOldShortcuts()) { r in if r.buttonID == "remove" { m.removeOldPhones() } }
    }

    // MARK: The panel

    private func tabTitle(_ id: String) -> String {
        switch id { case "ai": return L("AI alerts"); case "auto": return L("Automation"); case "island": return L("Island"); default: return L("General") }
    }

    /// General, AI alerts (on Macs with an AI tool), Automation, and Island (only while the island is on).
    private var tabs: [String] { PanelTabs.list(ai: m.ai.available, island: m.island) }

    /// A cell of the top strip: as wide as the strip's layout allows for this notch, its highlight derived from it.
    private func stripButton(_ icon: String, _ title: String, _ s: StripLayout, height: CGFloat, selected: Bool = false,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: { Haptic.tap(.alignment); action() }) {
            ZStack {
                RoundedRectangle(cornerRadius: CTL.innerRadius).fill(Color.white.opacity(selected ? 0.16 : 0)).frame(width: s.highlight, height: min(26, height - 2))
                Image(systemName: icon).font(UI.tabIcon).foregroundStyle(selected ? Color.white : UI.hint)
            }
            .frame(width: s.cell, height: height)              // the whole cell around the icon
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tabIcon(_ id: String) -> String {
        switch id { case "ai": return "sparkles"; case "auto": return "bolt.badge.automatic"; case "island": return "rectangle.topthird.inset.filled"; default: return "house.fill" }
    }

    /// The strip's cells for this notch: back, General and AI alerts left of it; Automation, Island and Quit right of it (nil:
    /// they don't fit; then the tabs are a segmented control under the header).
    private func stripLayout(_ g: NotchGeometry) -> StripLayout? {
        let (l, r) = PanelTabs.split(tabs)
        return StripLayout.make(panelWidth: Layout.width, frameInset: Space.frame, contentInset: Space.l, notchWidth: g.notchWidth,
                                left: 1 + l.count, right: r.count + 1)
    }

    /// The panel's top strip, like the island's: each side gets exactly what the notch leaves, so nothing is ever under it.
    private func strip(_ g: NotchGeometry, _ s: StripLayout) -> some View {
        let (l, r) = PanelTabs.split(tabs)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                stripButton("chevron.backward", L("Back to the island"), s, height: g.height) { m.backToIsland() }   // from the island's gear: back to it
                ForEach(l, id: \.self) { t in
                    stripButton(tabIcon(t), tabTitle(t), s, height: g.height, selected: m.page == t) { m.page = t }
                }
            }
            .padding(.leading, s.edgeInset)
            .frame(width: s.side, alignment: .leading)
            Color.clear.frame(width: s.notchWidth)
            HStack(spacing: 0) {
                ForEach(r, id: \.self) { t in
                    stripButton(tabIcon(t), tabTitle(t), s, height: g.height, selected: m.page == t) { m.page = t }
                }
                stripButton("xmark.circle", L("Quit Cocaine"), s, height: g.height) { m.quit() }
            }
            .padding(.trailing, s.edgeInset)
            .frame(width: s.side, alignment: .trailing)
        }
        .frame(width: Layout.width - 2 * Space.frame, height: g.height)
    }

    private var header: some View {
        HStack(spacing: 10) {                                // header and footer sit on the content edge
            Image(nsImage: Baggie.imageOnDark(level: m.bagLevel, pouring: m.bagPouring, size: 28, pink: m.bagPink))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Cocaine").font(UI.appTitle)
                    Text(appVersion).font(UI.detail).foregroundStyle(UI.hint)   // e.g. "1.7"
                }
                Text(status).font(UI.detail).lineLimit(1)
                    .foregroundStyle(m.needsAuth || (m.on && m.holdMissing) ? warningColor : UI.secondary)
                    .help(status)
            }
            Spacer(minLength: 8)
            CocaineSwitch(on: m.on, powder: m.fillLevel) { m.toggleCocaine() }
                .help(m.on ? L("Turn Cocaine off") : L("Turn Cocaine on"))
                .accessibilityLabel(L("Cocaine, keeps the Mac awake"))
        }
        .padding(.horizontal, 10)
    }

    var body: some View {
        let g = m.island ? NotchGeometry.current() : nil
        let s = g.flatMap(stripLayout)
        let asking = dialogs.isShowing(on: .panel)
        let picking = pickers.isOpen(on: .panel)
        let page = tabs.contains(m.page) ? m.page : ""
        let reserve = max(asking ? PanelDialogOverlay.reserved(dialogs.cardHeight, notch: g) : 0,
                          picking ? PickerLayer.reserved(pickers.anchor, card: pickers.cardHeight, bottom: Space.frame) : 0)
        return VStack(alignment: .leading, spacing: Space.l) {
            if let g {
                if let s { strip(g, s) } else { Color.clear.frame(height: g.height) }      // the notch: nothing goes under it
            }
            VStack(alignment: .leading, spacing: Space.l) {
                header
                if s == nil {
                    Segments(selection: $m.page, values: tabs, name: L("Settings"), label: tabTitle)
                        .frame(maxWidth: .infinity)
                }

                switch page {
                case "ai": aiTab
                case "auto": automationTab
                case "island": islandTab
                default: generalTab
                }

                if s == nil {
                    HStack(spacing: Space.m) {
                        Spacer(minLength: Space.m)
                        Button(L("Quit")) { m.quit() }.buttonStyle(CocaineButtonStyle()).fixedSize()
                            .help(L("Quit Cocaine"))
                    }
                    .padding(.horizontal, Space.l)
                }
            }
        }
        .disabled(asking)                                    // a question is on top (PanelDialogOverlay): nothing under it reacts
        .padding(.horizontal, Space.frame).padding(.bottom, Space.frame).padding(.top, g == nil ? Space.frame : Layout.overscan)
        .frame(width: Layout.width, alignment: .topLeading)   // never centered, never wider: nothing can slide out sideways
        // A dropdown hangs under its row, over the page (never above the row, so never up into the notch).
        .overlay(alignment: .topLeading) {
            PickerLayer(center: pickers, surface: .panel, x: Space.frame, width: Layout.width - 2 * Space.frame)
        }
        .coordinateSpace(name: PickerCenter.space)
        // A dialog or a dropdown taller than the page: the panel grows to hold it.
        .frame(minHeight: reserve, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Language.locale)
    }
}

/// The panel's tabs, and which side of the notch each goes on (pure: --layout-test and --selftest check it).
enum PanelTabs {
    static func list(ai: Bool, island: Bool) -> [String] { [""] + (ai ? ["ai"] : []) + ["auto"] + (island ? ["island"] : []) }
    /// Left of the notch: General and AI alerts (after the back button); right: Automation and Island (before Quit).
    static func split(_ tabs: [String]) -> (left: [String], right: [String]) {
        (tabs.filter { $0 == "" || $0 == "ai" }, tabs.filter { $0 == "auto" || $0 == "island" })
    }
}

/// A time of day (minutes after midnight): − and + in steps of 15 minutes (or two-finger scrolling), and the time itself opens
/// a list of the half hours. No system date picker.
struct TimeStepper: View {
    let id: String
    let title: String
    @Binding var minutes: Int

    static func label(_ minutes: Int) -> String {
        let cal = Calendar.autoupdatingCurrent
        let d = cal.date(bySettingHour: (minutes / 60) % 24, minute: minutes % 60, second: 0, of: cal.startOfDay(for: Date())) ?? Date()
        return PanelView.timeString(d)
    }

    /// The next time on a step of `step` minutes, wrapping around midnight.
    static func stepped(_ minutes: Int, by n: Int, step: Int = 15) -> Int {
        let base = n > 0 ? (minutes / step) * step : ((minutes + step - 1) / step) * step   // off-grid times land on the grid first
        return ((base + n * step) % 1440 + 1440) % 1440
    }

    private func step(_ n: Int) { Haptic.tap(.alignment); minutes = Self.stepped(minutes, by: n) }

    private var spec: PickerSpec {
        let times = Array(stride(from: 0, to: 1440, by: 30))
        let ids = (times.contains(minutes) ? times : (times + [minutes]).sorted()).map(String.init)
        return PickerSpec(id: id, title: title, items: ids.map { PickerItem(id: $0, title: Self.label(Int($0) ?? 0)) }, mode: .single(String(minutes)))
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: { Image(systemName: "minus").font(UI.chevron).frame(width: 22, height: CTL.h).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel(L("Earlier"))
            ValueButton(id: id, title: title, value: Self.label(minutes), maxWidth: 90, spec: { spec }, onPick: { minutes = Int($0) ?? minutes })
                .padding(.trailing, 6)
            Button { step(1) } label: { Image(systemName: "plus").font(UI.chevron).frame(width: 22, height: CTL.h).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel(L("Later"))
        }
        .frame(height: CTL.h)
        .background(RoundedRectangle(cornerRadius: CTL.radius).fill(CTL.track))
        .onScrollSteps(every: 12) { step($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// The panel's dialog, drawn over the panel's visible area rather than inside its scrolling content, so a question asked from
/// the bottom of a long page (Delete everything…) shows where the user is looking, never above it. What is under it is dimmed
/// and a click there is Cancel. The app hosts it above the scroll view (MenuPanel.overlay); the render tool stacks it on the page.
struct PanelDialogOverlay: View {
    @ObservedObject var m: PanelModel                    // m.island: the panel hangs from the notch (the card goes under the strip)
    @ObservedObject var dialogs = DialogCenter.shared

    /// The top of the card: below the strip when the panel hangs from the notch, else at the panel's top inset.
    static func top(notch g: NotchGeometry?) -> CGFloat { g.map { Layout.overscan + $0.height + Space.l } ?? Space.frame }
    /// How tall the panel must be to hold the card.
    static func reserved(_ card: CGFloat, notch g: NotchGeometry?) -> CGFloat { top(notch: g) + card + Space.frame }

    var body: some View {
        let on = dialogs.isShowing(on: .panel)
        ZStack(alignment: .top) {
            if on {
                Color.black.opacity(0.72).contentShape(Rectangle()).onTapGesture { dialogs.cancel() }   // as dim as the old 0.4 × 0.45 page
                InAppDialogCard(center: dialogs, style: UI.dialog)
                    .background(GeometryReader { r in Color.clear.preference(key: DialogCardHeight.self, value: r.size.height) })
                    .padding(.horizontal, Space.frame)
                    .padding(.top, Self.top(notch: m.island ? NotchGeometry.current() : nil))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(DialogCardHeight.self) { h in if abs(dialogs.cardHeight - h) > 0.5 { dialogs.cardHeight = h } }
        .animation(.easeOut(duration: 0.15), value: dialogs.current?.id)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Language.locale)
    }
}

private struct DialogCardHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
