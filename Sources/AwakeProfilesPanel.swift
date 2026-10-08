// The panel's cards for keep-awake profiles (Sources/AwakeProfiles.swift) and "Keep disks awake" (Sources/DriveAlive.swift), in
// Automation; the reminder and statistics rows live in the keep-awake options card (Sources/AwakePanel.swift). Same look as the
// other keep-awake rows (AwakeRowKit): plain rows in a subtle card, the app's own controls, dialogs in-app.

import AppKit
import SwiftUI

// MARK: - Profiles

struct AwakeProfilesCard: View {
    @ObservedObject var am = AwakeModel.shared
    let kit = AwakeRowKit()

    private var templatesSpec: PickerSpec {
        PickerSpec(id: "newProfile", title: L("New profile"), items: AwakeProfiles.templates.map { t in
            PickerItem(id: t, title: AwakeProfiles.template(t)?.name ?? t, symbol: Self.templateSymbol(t))
        }, mode: .action)
    }

    static func templateSymbol(_ t: String) -> String {
        switch t {
        case "office": return "wifi"
        case "desk": return "display"
        case "present": return "rectangle.on.rectangle"
        case "backup": return "externaldrive"
        case "download": return "arrow.down.circle"
        case "lowbattery": return "battery.25"
        default: return "plus"
        }
    }

    private func add(_ template: String) {
        guard am.profiles.count < AwakeProfile.limit, var p = AwakeProfiles.template(template) else { return }
        var n = p.name, i = 2
        while am.profiles.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { n = "\(p.name) \(i)"; i += 1 }
        p.name = n
        am.profiles.append(p)
        am.editingProfile = p.id
    }

    private func status(_ p: AwakeProfile) -> String {
        guard p.enabled else { return L("Off") }
        if am.leadProfile == p.id { return p.action == .letSleep ? L("Deciding now: triggers wait") : L("Deciding now: keeping the Mac awake") }
        if am.engagedProfiles.contains(p.id) { return L("Active (a profile above it decides)") }
        if am.holdingProfiles.contains(p.id) { return String(format: L("Conditions hold: starts after %@"), ProfileWords.seconds(p.startAfter)) }
        return ProfileWords.summary(p)
    }

    var body: some View {
        kit.card("switch.2", L("Profiles")) {
            if am.profiles.isEmpty {
                Text(L("A profile keeps the Mac awake by itself while its conditions hold: a Wi-Fi network, a disk, an app in front, the charger…"))
                    .font(UI.detail).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(am.profiles) { p in
                VStack(alignment: .leading, spacing: Space.s) {
                    kit.row(p.name, detail: status(p), tip: ProfileWords.summary(p), live: am.engagedProfiles.contains(p.id)) {
                        HStack(spacing: Space.s) {
                            Button(am.editingProfile == p.id ? L("Done") : L("Edit")) {
                                am.editingProfile = am.editingProfile == p.id ? nil : p.id
                            }
                            .buttonStyle(CocaineButtonStyle())
                            .accessibilityLabel(String(format: L("Edit %@"), p.name))
                            CocaineSwitch(on: p.enabled) { am.update(p.id) { $0.enabled.toggle() } }
                                .accessibilityLabel(p.name)
                        }
                    }
                    if am.editingProfile == p.id {
                        ProfileEditor(id: p.id).motionAppear()
                    }
                }
            }
            kit.row(L("New profile"), tip: L("Start empty or from a ready-made profile")) {
                ValueButton(id: "newProfile", title: L("New profile"), value: L("Add…"), spec: { templatesSpec }, onPick: add)
                    .disabled(am.profiles.count >= AwakeProfile.limit)
            }
            if am.profiles.count >= 2 {
                Text(L("The first profile whose conditions hold decides; the others wait."))
                    .font(UI.detail).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.animation(.expand), value: am.editingProfile)
    }
}

/// One profile's settings, under its row.
struct ProfileEditor: View {
    @ObservedObject var am = AwakeModel.shared
    let id: String
    let kit = AwakeRowKit()

    private var p: AwakeProfile? { am.profiles.first { $0.id == id } }

    private func bind<T>(_ kp: WritableKeyPath<AwakeProfile, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { p?[keyPath: kp] ?? fallback }, set: { v in am.update(id) { $0[keyPath: kp] = v } })
    }

    var body: some View {
        if let p {
            VStack(alignment: .leading, spacing: Space.s) {
                kit.row(L("Name"), detail: p.name) {
                    Button(L("Rename…")) { rename(p) }.buttonStyle(CocaineButtonStyle())
                }
                if p.conditions.count >= 2 {
                    kit.segRow(L("Turns on when"), tip: L("All: every condition must hold. Any: one is enough."), bind(\.matchAll, true), [true, false]) {
                        $0 ? L("All are true") : L("Any is true")
                    }
                }
                ForEach(p.conditions) { c in ConditionEditor(profile: id, condition: c.id) }
                if p.conditions.count < AwakeProfile.conditionLimit {
                    kit.row(L("Add a condition"), detail: p.conditions.isEmpty ? L("No conditions yet: this profile never starts") : nil, warning: p.conditions.isEmpty) {
                        ValueButton(id: "addCondition-\(id)", title: L("Add a condition"), value: L("Add…"), spec: {
                            PickerSpec(id: "addCondition-\(id)", title: L("Add a condition"), items: AwakeCondition.Kind.allCases.map {
                                PickerItem(id: $0.rawValue, title: ProfileWords.kindTitle($0), symbol: ProfileWords.symbol($0))
                            }, mode: .action)
                        }, onPick: { k in
                            guard let kind = AwakeCondition.Kind(rawValue: k) else { return }
                            am.update(id) { $0.conditions.append(AwakeCondition.make(kind)) }
                        })
                    }
                }
                kit.segRow(L("Then"), tip: L("Keep the Mac awake, or hold every trigger back so the Mac can sleep"), bind(\.action, .keepAwake),
                           [AwakeProfile.Action.keepAwake, .letSleep]) { $0 == .keepAwake ? L("Keep awake") : L("Let the Mac sleep") }
                if p.action == .keepAwake {
                    kit.row(L("Displays may sleep"), detail: p.displaySleep ? L("The Mac stays awake; the screens sleep and lock as macOS is set") : nil) {
                        kit.toggle(L("Displays may sleep"), bind(\.displaySleep, false))
                    }
                }
                kit.segRow(L("Start after"), tip: L("The conditions must hold this long without a break"), bind(\.startAfter, 10),
                           AwakeProfile.startChoices, ProfileWords.seconds)
                kit.segRow(L("Stop after"), tip: L("They must stop holding this long without a break: a flapping reading never turns it off"),
                           bind(\.stopAfter, 60), AwakeProfile.stopChoices, ProfileWords.seconds)
                if p.action == .keepAwake {
                    kit.row(L("At most"), tip: L("The longest it keeps the Mac awake in one go; then it waits until the conditions break")) {
                        ValueButton(id: "maxMinutes-\(id)", title: L("At most"), value: maxName(p.maxMinutes), spec: {
                            PickerSpec(id: "maxMinutes-\(id)", title: L("At most"), items: AwakeProfile.maxChoices.map {
                                PickerItem(id: "\($0)", title: maxName($0))
                            }, mode: .single("\(p.maxMinutes)"))
                        }, onPick: { v in am.update(id) { $0.maxMinutes = Int(v) ?? 0 } })
                    }
                }
                kit.row(L("Notices"), tip: L("A notice when this profile starts and ends")) { kit.toggle(L("Notices"), bind(\.notify, true)) }
                kit.row(L("Priority"), detail: priorityDetail) {
                    HStack(spacing: Space.xs) {
                        glyph("arrow.up", L("Move up")) { move(-1) }.disabled(index == 0)
                        glyph("arrow.down", L("Move down")) { move(1) }.disabled(index == am.profiles.count - 1)
                        Button(L("Delete…")) { delete(p) }.buttonStyle(CocaineButtonStyle(kind: .destructive))
                    }
                }
            }
            .padding(.leading, Space.m)
        }
    }

    private func maxName(_ m: Int) -> String { m == 0 ? L("No limit") : Dur.short(minutes: m) }

    private var index: Int { am.profiles.firstIndex { $0.id == id } ?? 0 }

    private var priorityDetail: String { String(format: L("%1$d of %2$d: the first profile that holds decides"), index + 1, am.profiles.count) }

    private func glyph(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: { Haptic.tap(.alignment); action() }) {
            Image(systemName: symbol).font(UI.icon).foregroundStyle(UI.secondary)
                .frame(width: CTL.h, height: CTL.h).contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle()).help(title).accessibilityLabel(title)
    }

    private func move(_ by: Int) {
        let i = index, j = i + by
        guard am.profiles.indices.contains(j) else { return }
        am.profiles.swapAt(i, j)
    }

    private func rename(_ p: AwakeProfile) {
        let others = am.profiles.filter { $0.id != p.id }.map { $0.name.lowercased() }
        DialogCenter.shared.present(DialogSpec(icon: "pencil", title: L("Rename profile"),
            field: DialogField(placeholder: L("Name"), text: p.name, validate: { t in
                let n = t.trimmingCharacters(in: .whitespaces)
                if n.isEmpty { return L("Give it a name") }
                if n.count > 40 { return L("At most 40 characters") }
                return others.contains(n.lowercased()) ? L("Another profile has this name") : nil
            }),
            buttons: [DialogButton(id: "ok", title: L("Rename"), needsValidInput: true), DialogButton(id: "cancel", title: L("Cancel"), role: .cancel)])) { r in
            if case .button("ok", let text, _) = r { am.update(p.id) { $0.name = AwakeProfiles.cleanName(text, fallback: p.name) } }
        }
    }

    private func delete(_ p: AwakeProfile) {
        DialogCenter.shared.present(DialogSpec(icon: "trash", title: String(format: L("Delete “%@”?"), p.name),
            message: L("Its conditions and settings are deleted. This can't be undone."), critical: true,
            buttons: [DialogButton(id: "delete", title: L("Delete"), role: .destructive), DialogButton(id: "cancel", title: L("Cancel"), role: .cancel)])) { r in
            guard r.buttonID == "delete" else { return }
            am.editingProfile = nil
            am.profiles.removeAll { $0.id == p.id }
        }
    }
}

/// One condition of a profile: its kind, "is / is not", its value, Remove.
struct ConditionEditor: View {
    @ObservedObject var am = AwakeModel.shared
    let profile: String
    let condition: String
    let kit = AwakeRowKit()

    private var c: AwakeCondition? { am.profiles.first { $0.id == profile }?.conditions.first { $0.id == condition } }

    private func change(_ f: @escaping (inout AwakeCondition) -> Void) {
        am.update(profile) { p in if let i = p.conditions.firstIndex(where: { $0.id == condition }) { f(&p.conditions[i]) } }
    }

    private func bind<T>(_ kp: WritableKeyPath<AwakeCondition, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { c?[keyPath: kp] ?? fallback }, set: { v in change { $0[keyPath: kp] = v } })
    }

    private static let negatable: Set<AwakeCondition.Kind> = Set(AwakeCondition.Kind.allCases).subtracting([.cpu, .idle, .battery])

    var body: some View {
        if let c {
            VStack(alignment: .leading, spacing: Space.s) {
                kit.row(ProfileWords.kindTitle(c.kind), detail: [.cpu, .idle, .battery, .schedule].contains(c.kind) ? ProfileWords.value(c) : nil) {
                    HStack(spacing: Space.xs) {
                        if Self.negatable.contains(c.kind) {
                            ValueButton(id: "neg-\(c.id)", title: ProfileWords.kindTitle(c.kind), value: c.negate ? L("Is not") : L("Is"), maxWidth: 90, spec: {
                                PickerSpec(id: "neg-\(c.id)", title: ProfileWords.kindTitle(c.kind),
                                           items: [PickerItem(id: "is", title: L("Is")), PickerItem(id: "not", title: L("Is not"))],
                                           mode: .single(c.negate ? "not" : "is"))
                            }, onPick: { v in change { $0.negate = v == "not" } })
                        }
                        Button(action: { Haptic.tap(.alignment); am.update(profile) { $0.conditions.removeAll { $0.id == condition } } }) {
                            Image(systemName: "xmark.circle.fill").font(UI.icon).foregroundStyle(UI.secondary)
                                .frame(width: CTL.h, height: CTL.h).contentShape(Rectangle())
                        }
                        .buttonStyle(MotionGlyphStyle()).help(L("Remove this condition")).accessibilityLabel(L("Remove this condition"))
                    }
                }
                details(c).padding(.leading, Space.m)
            }
        }
    }

    @ViewBuilder private func details(_ c: AwakeCondition) -> some View {
        switch c.kind {
        case .cpu:
            kit.segRow(L("When"), bind(\.above, true), [true, false]) { $0 ? L("Above") : L("Below") }
            kit.segRow(L("Load"), bind(\.number, 50), CPURule.percents) { "\($0)%" }
            kit.segRow(L("For at least"), bind(\.minutes, 2), CPURule.minutesChoices) { Dur.short(minutes: $0) }
        case .idle:
            kit.segRow(L("When"), bind(\.above, false), [false, true]) { $0 ? L("At least") : L("Less than") }
            kit.segRow(L("Minutes"), bind(\.number, 10), [1, 5, 10, 30, 60]) { Dur.short(minutes: $0) }
        case .battery:
            kit.segRow(L("When"), bind(\.above, true), [true, false]) { $0 ? L("At least") : L("Below") }
            kit.segRow(L("Level"), bind(\.number, 30), [10, 20, 30, 50, 80]) { "\($0)%" }
        case .schedule:
            kit.row(L("Days")) {
                ValueButton(id: "days-\(c.id)", title: L("Days"), value: c.days.isEmpty ? L("None") : ProfileWords.days(c.days),
                            spec: { daysSpec(c) }, onChange: { s in change { $0.days = s.compactMap(Int.init).sorted() } })
            }
            kit.row(L("Hours")) {
                HStack(spacing: Space.s) {
                    TimeStepper(id: "start-\(c.id)", title: L("From"), minutes: bind(\.start, 540))
                    Text("–").font(UI.value)
                    TimeStepper(id: "end-\(c.id)", title: L("To"), minutes: bind(\.end, 1080))
                }
            }
        case .wifi:
            namesRow(c)
            if !am.locationAllowed && am.sample == nil {
                kit.row(L("Needs Location Services"), detail: L("macOS shows the Wi-Fi network's name only to apps allowed in Location Services. Cocaine uses it for nothing else."), warning: true) {
                    Button(L("Allow")) { LocationAccess.shared.request() }.buttonStyle(CocaineButtonStyle(kind: .primary))
                }
            }
        case .bluetooth:
            namesRow(c).onAppear { if am.bluetoothKnown.isEmpty && am.sample == nil { BluetoothScan.known { am.bluetoothKnown = $0 } } }
        default:
            if c.usesNames { namesRow(c) }
        }
    }

    private func daysSpec(_ c: AwakeCondition) -> PickerSpec {
        let f = DateFormatter()
        f.locale = appLocale()
        let names = f.weekdaySymbols ?? []
        let order = [2, 3, 4, 5, 6, 7, 1]
        return PickerSpec(id: "days-\(c.id)", title: L("Days"), items: order.compactMap { d in
            d <= names.count ? PickerItem(id: "\(d)", title: names[d - 1]) : nil
        }, mode: .multi, selected: Set(c.days.map(String.init)))
    }

    /// What can be picked now for a list condition (the sample in renders, never this Mac's there).
    private func present(_ k: AwakeCondition.Kind) -> [String] {
        if let s = am.sample {
            switch k {
            case .wifi: return s["wifi"] ?? []
            case .usb: return s["usb"] ?? []
            case .bluetooth: return s["bluetooth"] ?? []
            case .audio: return s["audio"] ?? []
            case .volume: return s["volumes"] ?? []
            case .frontApp, .appRunning: return s["apps"] ?? []
            case .ipAddress: return ["192.168.1.0/24", "10.0."]
            case .dns: return ["192.168.1.1"]
            default: return []
            }
        }
        switch k {
        case .wifi: return [NetReadings.wifi().ssid].compactMap { $0 }
        case .usb: return SystemAwakeProbe().usbDevices()
        case .bluetooth: return am.bluetoothKnown
        case .audio: return SystemAwakeProbe.outputNames()
        case .volume: return SystemAwakeProbe().mountedVolumes()
        case .frontApp, .appRunning: return System.runningAppNames()
        case .ipAddress: return NetReadings.addresses().filter { $0.key != "lo0" }.flatMap(\.value).sorted()
        case .dns: return NetReadings.dnsServers()
        default: return []
        }
    }

    private static let typeID = "\u{1}type"

    private func namesRow(_ c: AwakeCondition) -> some View {
        kit.row(L("Which"), detail: c.names.isEmpty ? L("Choose at least one") : nil, warning: c.names.isEmpty) {
            ValueButton(id: "names-\(c.id)", title: ProfileWords.kindTitle(c.kind), value: AwakeRowKit.listValue(c.names), spec: {
                var spec = AwakeRowKit.spec("names-\(c.id)", ProfileWords.kindTitle(c.kind), chosen: c.names, present: present(c.kind), symbol: ProfileWords.symbol(c.kind))
                spec.items.insert(PickerItem(id: Self.typeID, title: L("Type a name…"), symbol: "keyboard"), at: 0)
                return spec
            }, onChange: { s in
                if s.contains(Self.typeID) { PickerCenter.shared.close(); type(c); return }
                change { $0.names = AwakeRowKit.merged($0.names, s) }
            })
        }
    }

    private func type(_ c: AwakeCondition) {
        let ip = c.kind == .ipAddress || c.kind == .dns
        DialogCenter.shared.present(DialogSpec(icon: ProfileWords.symbol(c.kind), title: ProfileWords.kindTitle(c.kind),
            message: ip ? L("An address (192.168.1.20), its beginning (192.168.1.) or a range (192.168.1.0/24)") : L("The name as macOS shows it; part of it is enough for devices and outputs"),
            field: DialogField(placeholder: ip ? "192.168.1.0/24" : L("Name"), validate: { t in
                let v = t.trimmingCharacters(in: .whitespaces)
                if v.isEmpty { return L("Give it a name") }
                if v.count > 80 { return L("At most 80 characters") }
                return ip && !IPMatch.valid(v) ? L("Not an address or a range") : nil
            }),
            buttons: [DialogButton(id: "ok", title: L("Add"), needsValidInput: true), DialogButton(id: "cancel", title: L("Cancel"), role: .cancel)])) { r in
            if case .button("ok", let text, _) = r { change { $0.names.append(text.trimmingCharacters(in: .whitespaces)) } }
        }
    }
}

// MARK: - Keep disks awake

struct DriveAliveCard: View {
    @ObservedObject var am = AwakeModel.shared
    let kit = AwakeRowKit()

    private var mountedNames: [String] { am.sample?["volumes"] ?? MountedVolumes.shared.current().map(\.name) }

    private func statusLine() -> String? {
        guard !am.driveAliveVolumes.isEmpty else { return nil }
        let mounted = Set(mountedNames.map { $0.lowercased() })
        return am.driveAliveVolumes.map { n in
            guard mounted.contains(n.lowercased()) else { return String(format: L("%@: not connected"), n) }
            if let st = am.driveStatus[n] {
                if let problem = st.problem { return "\(n): \(problem)" }
                if let at = st.at {
                    let s = Int(Date().timeIntervalSince(at))
                    return s < 60 ? String(format: L("%@: touched just now"), n) : String(format: L("%1$@: touched %2$@ ago"), n, Dur.ago(seconds: s))
                }
            }
            return String(format: L("%@: waiting"), n)
        }.joined(separator: "\n")
    }

    private func every(_ s: Int) -> String { s < 60 ? String(format: L("%d s"), s) : Dur.short(minutes: s / 60) }

    var body: some View {
        kit.card("externaldrive.badge.timemachine", L("Keep disks awake")) {
            kit.row(L("Disks"), detail: statusLine(), tip: L("External drives that spin down too soon: Cocaine touches them now and then while they are connected")) {
                ValueButton(id: "driveAlive", title: L("Disks"), value: AwakeRowKit.listValue(am.driveAliveVolumes), spec: {
                    AwakeRowKit.spec("driveAlive", L("Keep disks awake"), chosen: am.driveAliveVolumes, present: mountedNames, symbol: "externaldrive")
                }, onChange: { am.driveAliveVolumes = AwakeRowKit.merged(am.driveAliveVolumes, $0) })
            }
            Group {
                kit.segRow(L("Every"), $am.driveAliveInterval, DriveAlive.intervals, every)
                kit.segRow(L("Method"), detail: am.driveAliveMethod == "read"
                           ? L("Nothing is written. Best effort: if macOS has that part of the disk in memory, the disk isn't touched.")
                           : String(format: L("Rewrites one 64-byte hidden file, %@, at the top of the disk, straight to the disk. Removing the disk from the list deletes it."), DriveAlive.fileName),
                           $am.driveAliveMethod, ["write", "read"]) { $0 == "read" ? L("Read only") : L("Tiny hidden file") }
                kit.segRow(L("When"), $am.driveAliveAlways, [false, true]) { $0 ? L("Always") : L("While Cocaine is on") }
            }
            .dimGroup(am.driveAliveVolumes.isEmpty)
        }
    }
}

// MARK: - Reminder and statistics (in the keep-awake options card)

struct AwakeSessionRows: View {
    @ObservedObject var am = AwakeModel.shared
    let kit = AwakeRowKit()

    private var statsLine: String {
        let s = am.stats, now = Date()
        let since = s.since.formatted(.dateTime.day().month(.abbreviated).locale(appLocale()))
        let mins = Int(s.total(now: now) / 60)
        return String(format: L("%1$d sessions · %2$@ awake since %3$@"), s.sessions,
                      mins > 0 ? Dur.short(minutes: mins) : String(format: agentsL("%d min"), 0), since)
    }

    var body: some View {
        kit.segRow(L("Remind me while it's on"), tip: L("A notice every so often saying how long Cocaine has been on"), $am.remindHours, OnReminder.choices) {
            $0 == 0 ? L("Never") : Dur.short(minutes: $0 * 60)
        }
        kit.row(L("Statistics"), detail: statsLine) {
            Button(L("Reset")) { am.resetStats() }.buttonStyle(CocaineButtonStyle())
        }
    }
}
