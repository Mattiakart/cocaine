// The panel's keep-awake rows (Sources/AwakeCenter.swift has their model): "until a time" in the timer card, more Smart
// Triggers, "Keep awake while…", the keep-awake options, and "Shortcuts and scripts". Same look as PanelView's rows: plain
// rows in a subtle card, the app's own controls (Segments, ValueButton, CocaineSwitch, TimeStepper), Motion's tokens.

import AppKit
import SwiftUI

/// Rows drawn like PanelView's (its helpers are private to it).
struct AwakeRowKit {
    @ObservedObject var display = DisplayOptions.shared

    func titleBlock(_ title: String, _ detail: String?, live: Bool = false, warning: Bool = false, wraps: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.s) {
                Text(title).font(UI.title).lineLimit(wraps ? 2 : 1).fixedSize(horizontal: !wraps, vertical: true)
                if live {
                    Group {
                        if display.differentiateWithoutColor { Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Color.green) }
                        else { Circle().fill(Color.green).frame(width: 6, height: 6) }
                    }
                    .help(L("True now")).accessibilityLabel(L("True now"))
                }
            }
            if let detail {
                Text(detail).font(UI.detail).foregroundStyle(warning ? warningColor : UI.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, detail == nil ? 0 : Space.rowAir)
    }

    func row<Control: View>(_ title: String, detail: String? = nil, tip: String? = nil, live: Bool = false, warning: Bool = false,
                            @ViewBuilder _ control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
            titleBlock(title, detail, live: live, warning: warning).frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()
        }
        .frame(minHeight: 22)
        .fixedSize(horizontal: false, vertical: true)
        .help(tip ?? detail ?? title)
    }

    func segRow<T: Hashable>(_ title: String, detail: String? = nil, tip: String? = nil, live: Bool = false, _ selection: Binding<T>, _ values: [T],
                             _ label: @escaping (T) -> String) -> some View {
        let seg = Segments(selection: selection, values: values, name: title, label: label)
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

    func toggle(_ title: String, _ on: Binding<Bool>) -> some View { CocaineSwitch(on).accessibilityLabel(title) }

    /// A card like PanelView's.
    func card<Content: View>(_ icon: String, _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                Image(systemName: icon).font(UI.icon).foregroundStyle(Island.accent).frame(width: UI.iconColumn, height: UI.iconColumn)
                Text(title).font(UI.groupTitle).lineLimit(1)
                Spacer(minLength: Space.m)
            }
            .frame(minHeight: 22)
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Space.s) { content() }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: CTL.cardRadius))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
    }

    static func listValue(_ names: [String]) -> String {
        names.isEmpty ? L("None") : names.count == 1 ? names[0] : "\(names[0]) +\(names.count - 1)"
    }

    /// A multiple choice: the chosen names, then what is there now.
    static func spec(_ id: String, _ title: String, chosen: [String], present: [String], symbol: String) -> PickerSpec {
        let now = present.filter { p in !chosen.contains { $0.lowercased() == p.lowercased() } }
        return PickerSpec(id: id, title: title,
                          items: chosen.map { PickerItem(id: $0, title: $0, symbol: symbol) } + now.map { PickerItem(id: $0, title: $0, symbol: symbol, section: 1) },
                          mode: .multi, selected: Set(chosen), sectionTitle: L("Here now"))
    }

    static func merged(_ old: [String], _ chosen: Set<String>) -> [String] {
        old.filter { chosen.contains($0) } + chosen.subtracting(old).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - The timer card: until a time

struct AwakeUntilRow: View {
    @ObservedObject var am = AwakeModel.shared
    let kit = AwakeRowKit()

    /// The next such time (today, or tomorrow once passed): always within 24 hours.
    private var target: Date? { UntilTime.clock(am.untilClock / 60, am.untilClock % 60, day: nil, now: Date(), calendar: .autoupdatingCurrent) }

    var body: some View {
        let detail = target.map { String(format: L("In %@"), Dur.short(minutes: UntilTime.minutesLeft($0, now: Date()))) }
        kit.row(L("Until a time"), detail: detail, tip: L("Keeps the Mac awake until this time (today, or tomorrow once it has passed)")) {
            HStack(spacing: Space.s) {
                TimeStepper(id: "awakeUntil", title: L("Until a time"), minutes: $am.untilClock)
                Button(L("Start")) { if let t = target { am.keepAwakeUntil(t) } }
                    .buttonStyle(CocaineButtonStyle())
                    .help(L("Keep the Mac awake until this time"))
                    .accessibilityLabel(String(format: L("Keep the Mac awake until %@"), TimeStepper.label(am.untilClock)))
            }
        }
    }
}

// MARK: - Smart Triggers: the new reasons

struct AwakeTriggerRows: View {
    @ObservedObject var am = AwakeModel.shared
    let live: Set<String>
    let kit = AwakeRowKit()

    private func cpuName(_ v: String) -> String { v == "above" ? L("Busy") : v == "below" ? L("Quiet") : L("Off") }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            kit.row(L("A VPN is connected"), tip: L("On while a VPN tunnel is up (WireGuard, Tailscale, IPsec…); off 30 seconds after"), live: live.contains("vpn")) {
                kit.toggle(L("A VPN is connected"), $am.triggerVPN)
            }
            kit.segRow(L("Processor"), detail: am.triggerCPU.isEmpty ? nil : cpuDetail,
                       tip: L("On while the processor stays busy (or quiet) for a while; off a minute after"), live: live.contains("cpu"),
                       $am.triggerCPU, ["", "above", "below"], cpuName)
            if !am.triggerCPU.isEmpty {
                kit.segRow(am.triggerCPU == "above" ? L("Above") : L("Below"), $am.triggerCPUPercent, CPURule.percents) { "\($0)%" }
                kit.segRow(L("For at least"), $am.triggerCPUMinutes, CPURule.minutesChoices) { Dur.short(minutes: $0) }
            }
            kit.row(L("Sound plays through"), tip: L("On while the Mac's sound goes to one of these outputs (headphones, AirPlay…); off 30 seconds after"),
                    live: live.contains("audio")) {
                ValueButton(id: "triggerAudio", title: L("Sound plays through"), value: AwakeRowKit.listValue(am.triggerAudio),
                            spec: { AwakeRowKit.spec("triggerAudio", L("Sound plays through"), chosen: am.triggerAudio,
                                                     present: am.sample?["audio"] ?? SystemAwakeProbe.outputNames(), symbol: "speaker.wave.2") },
                            onChange: { am.triggerAudio = AwakeRowKit.merged(am.triggerAudio, $0) })
            }
            kit.row(L("A disk is connected"), tip: L("On while one of these volumes is mounted; off 30 seconds after"), live: live.contains("volume")) {
                ValueButton(id: "triggerVolumes", title: L("A disk is connected"), value: AwakeRowKit.listValue(am.triggerVolumes),
                            spec: { AwakeRowKit.spec("triggerVolumes", L("A disk is connected"), chosen: am.triggerVolumes,
                                                     present: am.sample?["volumes"] ?? SystemAwakeProbe().mountedVolumes(), symbol: "externaldrive") },
                            onChange: { am.triggerVolumes = AwakeRowKit.merged(am.triggerVolumes, $0) })
            }
            kit.row(L("A USB device is connected"), tip: L("On while one of these USB devices is plugged in; off 30 seconds after"), live: live.contains("usb")) {
                ValueButton(id: "triggerUSB", title: L("A USB device is connected"), value: AwakeRowKit.listValue(am.triggerUSB),
                            spec: { AwakeRowKit.spec("triggerUSB", L("A USB device is connected"), chosen: am.triggerUSB,
                                                     present: am.sample?["usb"] ?? SystemAwakeProbe().usbDevices(), symbol: "cable.connector") },
                            onChange: { am.triggerUSB = AwakeRowKit.merged(am.triggerUSB, $0) })
            }
        }
        .animation(Motion.animation(.notice), value: am.triggerCPU.isEmpty)
    }

    private var cpuDetail: String {
        let now = am.cpuLoad.map { String(format: L("Now %@"), "\($0)%") }
        let rule = String(format: am.triggerCPU == "above" ? L("Above %@ for %@") : L("Below %@ for %@"),
                          "\(am.triggerCPUPercent)%", Dur.short(minutes: am.triggerCPUMinutes))
        return [rule, now].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Keep awake while…

struct AwakeWhileCard: View {
    @ObservedObject var am = AwakeModel.shared
    let kit = AwakeRowKit()

    private var processSpec: PickerSpec {
        let list = am.sample.map { s in (s["processes"] ?? []).enumerated().map { ProcessPick(pid: Int32(4000 + $0.offset), name: $0.element, started: 0) } } ?? ProcessInfoReader.pickable()
        return PickerSpec(id: "whileProcess", title: L("A program runs"),
                          items: list.map { p in
                              PickerItem(id: "\(p.pid)", title: "\(p.name)  ·  \(p.pid)",
                                         image: NSRunningApplication(processIdentifier: p.pid)?.icon)
                          }, mode: .single(nil))
    }

    private func pickProcess(_ id: String) {
        guard let pid = Int32(id), let p = ProcessInfoReader.info(pid) else { return }
        am.startWhile(WhileTarget(kind: .process, pid: p.pid, started: p.started, name: p.name))
    }

    var body: some View {
        kit.card("hourglass.bottomhalf.filled", L("Keep awake while…")) {
            if let t = am.whileTarget {
                kit.row(t.kind == .downloads ? L("Downloads are in progress") : String(format: L("%@ is running"), t.name),
                        detail: t.kind == .downloads ? L("Cocaine turns off a minute after the last download finishes")
                            : L("Cocaine turns off when it quits"), live: true) {
                    Button(L("Stop")) { am.stopWhile() }.buttonStyle(CocaineButtonStyle())
                        .help(L("Stop waiting (Cocaine stays as it is)"))
                }
            } else {
                kit.row(L("A program runs"), tip: L("Pick a running program: Cocaine stays on until it quits, then turns off")) {
                    ValueButton(id: "whileProcess", title: L("A program runs"), value: L("Choose…"), spec: { processSpec }, onPick: pickProcess)
                }
                kit.row(L("Downloads are in progress"), tip: L("Cocaine stays on while files are downloading into the Downloads folder, then turns off")) {
                    Button(L("Start")) { am.startWhile(WhileTarget(kind: .downloads, name: L("Downloads"))) }.buttonStyle(CocaineButtonStyle())
                        .accessibilityLabel(L("Keep awake while downloads are in progress"))
                }
            }
            if let note = am.whileNote {
                Text(note).font(UI.detail).foregroundStyle(warningColor).fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.animation(.notice), value: am.whileTarget)
    }
}

// MARK: - Keep-awake options

struct AwakeOptionsCard: View {
    @ObservedObject var am = AwakeModel.shared
    let statusItemShown: Bool
    let kit = AwakeRowKit()

    private func unplugName(_ s: Int) -> String {
        switch s { case 0: return L("Never"); case 10: return L("At once"); default: return Dur.short(minutes: s / 60) }
    }

    var body: some View {
        kit.card("cup.and.saucer", L("Keep awake")) {
            kit.segRow(L("Turn off when unplugged"), tip: L("When the charger is unplugged Cocaine turns off, however it was turned on (a wiggle of the cable doesn't count)"),
                       $am.unplugOff, UnplugGuard.choices, unplugName)
            kit.row(L("Pause while the screen is locked"), detail: am.lockPause ? L("Not for working with the lid closed: closing it locks the screen") : nil,
                    tip: L("The Mac may sleep while it's locked; Cocaine comes back on when you unlock it")) {
                kit.toggle(L("Pause while the screen is locked"), $am.lockPause)
            }
            kit.segRow(L("Turn on when Cocaine opens"), tip: L("Always, only when you open it yourself (not at login), or never"),
                       $am.launchTurnsOn, LaunchPolicy.values) {
                $0 == "manual" ? L("Not at login") : $0 == "never" ? L("Never") : L("Always")
            }
            kit.row(L("Left click turns it on or off"), detail: statusItemShown ? L("Right click opens this panel") : L("Only with the menu-bar icon (the island is off)"),
                    tip: L("A left click on the menu-bar icon turns Cocaine on or off; a right click (or Control-click) opens the panel")) {
                kit.toggle(L("Left click turns it on or off"), $am.leftClickToggles)
            }
            kit.segRow(L("Menu-bar icon"), tip: L("The island keeps the baggie"), $am.menuIcon, MenuIconStyle.all, MenuIconStyle.name)
            kit.row(L("Notices when it turns on or off"), tip: L("A short notice in the island (or VoiceOver) whenever Cocaine turns on or off")) {
                kit.toggle(L("Notices when it turns on or off"), $am.notifyChanges)
            }
        }
    }
}

// MARK: - Shortcuts and scripts

struct AwakeScriptingCard: View {
    @ObservedObject var am = AwakeModel.shared
    let kit = AwakeRowKit()

    static var guide: URL {
        (Language.chosen ?? Language.system) == "it"
            ? URL(string: "https://github.com/Mattiakart/cocaine/blob/main/docs/scripting.it.md")!
            : URL(string: "https://github.com/Mattiakart/cocaine/blob/main/docs/scripting.en.md")!
    }

    var body: some View {
        kit.card("applescript", L("Shortcuts and scripts")) {
            kit.row(L("Mac Shortcuts"), detail: am.packNote ?? L("Keep Awake…, Off, Toggle and Status, ready to add"),
                    tip: L("Ordinary shortcuts that call Cocaine through its links (not native Shortcuts actions). Making one needs an internet connection and iCloud.")) {
                Button(L("Add…")) { am.addShortcuts() }.buttonStyle(CocaineButtonStyle(busy: am.packBusy)).disabled(am.packBusy)
                    .help(L("Add to Shortcuts"))
            }
            // AppleScript's own words (English in every language, like the dictionary).
            kit.row("AppleScript", detail: "keep awake for 90 · keep awake until \"18:30\" · stop keeping awake · get awake",
                    tip: L("Script Editor, Shortcuts' Run AppleScript and other apps can use Cocaine's dictionary")) { EmptyView() }
            LinkButton(title: L("Scripting guide")) { NSWorkspace.shared.open(Self.guide) }
        }
    }
}
