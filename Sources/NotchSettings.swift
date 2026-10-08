// The Notch card of Settings → Island: the battery's HUD, the swipes, the island's sizes, the quick controls and which reminder
// lists show. Plain rows on the panel's card (AwakeRowKit), the app's own switches, segments, sliders and dropdowns.

import AppKit
import SwiftUI

/// Where the card finds the island's reminders (NotchWiring sets it; renders get a sample).
enum NotchSettingsLink {
    static var reminders: RemindersWatch?
}

final class NotchSettingsState: ObservableObject {
    /// Which screens the closed-bar sliders change: "" every screen without a notch, else one screen's key.
    @Published var screenKey = ""
}

struct NotchSettingsView: View {
    @ObservedObject var prefs = NotchPrefs.shared
    @StateObject private var state = NotchSettingsState()
    @StateObject private var power = NotchPowerSettings()
    let kit = AwakeRowKit()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            chargingRows
            divider
            gestureRows
            divider
            sizeRows
            divider
            controlsRows
            if let r = NotchSettingsLink.reminders {
                divider
                NotchRemindersRows(watch: r)
            }
        }
    }

    private var divider: some View { Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, Space.xs) }

    private func section(_ t: String) -> some View {
        Text(t).font(UI.section).foregroundStyle(UI.secondary).padding(.top, Space.xxs)
    }

    // MARK: charging

    private var chargingRows: some View {
        Group {
            section(L("Charging"))
            kit.row(L("Charging notices"), detail: L("Below the notch when the charger goes in or out, the battery is full or Low Power Mode changes")) {
                kit.toggle(L("Charging notices"), $power.hud)
            }
            kit.segRow(L("Low battery notice"), tip: L("Once when the battery reaches this level, and again at 10%"), $power.low, Settings.lowBatteryChoices) {
                $0 == 0 ? L("Off") : "\($0)%"
            }
            .dimGroup(!power.hud)
        }
    }

    // MARK: gestures

    private func gesture(_ kp: WritableKeyPath<NotchGestureSettings, Bool>) -> Binding<Bool> {
        Binding(get: { prefs.gestures[keyPath: kp] }, set: { v in prefs.updateGestures { $0[keyPath: kp] = v } })
    }

    private func sensitivityName(_ s: NotchGestureSettings.Sensitivity) -> String {
        switch s { case .low: return L("Low"); case .medium: return L("Medium"); case .high: return L("High") }
    }

    private var gestureRows: some View {
        Group {
            HStack {
                section(L("Swipes"))
                Spacer()
                kit.toggle(L("Swipes"), gesture(\.enabled))
            }
            Group {
                kit.row(L("Swipe up to close"), detail: L("Two fingers up on the open island; it stays closed until the pointer leaves the notch")) {
                    kit.toggle(L("Swipe up to close"), gesture(\.swipeClose))
                }
                kit.row(L("Swipe down to open"), detail: L("Two fingers down on the closed notch")) {
                    kit.toggle(L("Swipe down to open"), gesture(\.swipeOpen))
                }
                kit.row(L("Swipe sideways for screens"), detail: L("Two fingers left or right on the open island, not over a list that scrolls")) {
                    kit.toggle(L("Swipe sideways for screens"), gesture(\.swipeScreens))
                }
                kit.segRow(L("Sensitivity"), Binding(get: { prefs.gestures.sensitivity }, set: { v in prefs.updateGestures { $0.sensitivity = v } }),
                           NotchGestureSettings.Sensitivity.allCases, sensitivityName)
            }
            .dimGroup(!prefs.gestures.enabled)
        }
    }

    // MARK: sizes

    private func presetName(_ p: NotchSizing.Preset) -> String {
        switch p { case .standard: return L("Standard"); case .large: return L("Large"); case .extraLarge: return L("Extra large"); case .custom: return L("Custom") }
    }

    private func slider(_ title: String, _ value: CGFloat, _ range: ClosedRange<CGFloat>, step: Double = 2, _ set: @escaping (CGFloat) -> Void) -> some View {
        kit.row(title) {
            HStack(spacing: Space.m) {
                CocaineSlider(value: Double(value), range: Double(range.lowerBound)...Double(range.upperBound), step: step, name: title,
                              valueText: "\(Int(value)) pt") { set(CGFloat($0)) }
                    .frame(width: 150)
                Text("\(Int(value)) pt").font(UI.metric).foregroundStyle(UI.secondary).frame(width: 44, alignment: .trailing)
            }
        }
    }

    /// The screens without a notch now connected: their keys and names.
    private var barScreens: [(key: String, name: String)] {
        NSScreen.screens.compactMap { s in
            guard s.safeAreaInsets.top == 0, let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (NotchSizing.displayKey(id), s.localizedName)
        }
    }

    private var screenSpec: PickerSpec {
        let items = [PickerItem(id: "", title: L("Every screen without a notch"))] + barScreens.map { PickerItem(id: $0.key, title: $0.name) }
        return PickerSpec(id: "notch.screen", title: L("Applies to"), items: items, mode: .single(state.screenKey))
    }

    private var sizeRows: some View {
        let s = prefs.sizing
        let key = state.screenKey
        let pill = key.isEmpty ? s.pill : s.pill(for: key)
        func setPill(_ change: @escaping (inout NotchSizing.Pill) -> Void) {
            prefs.updateSizing { z in
                if key.isEmpty { change(&z.pill) } else { var p = z.pill(for: key); change(&p); z.perScreen[key] = p }
            }
        }
        return Group {
            section(L("Size"))
            kit.segRow(L("Open island"), Binding(get: { s.preset }, set: { p in prefs.updateSizing { $0.apply(p) } }),
                       [.standard, .large, .extraLarge], presetName)
            slider(L("Width"), s.openWidth, NotchSizing.openWidths) { v in prefs.updateSizing { $0.openWidth = v } }
            slider(L("Height"), s.openHeight, NotchSizing.openHeights) { v in prefs.updateSizing { $0.openHeight = v } }
            slider(L("Corners"), s.openCorner, NotchSizing.openCorners, step: 1) { v in prefs.updateSizing { $0.openCorner = v } }
            Text(L("Never smaller than the standard size, so no page gets cut.")).font(UI.detail).foregroundStyle(UI.secondary)
                .fixedSize(horizontal: false, vertical: true)
            section(L("Closed, on screens without a notch"))
            if !barScreens.isEmpty {
                kit.row(L("Applies to")) {
                    ValueButton(id: "notch.screen", title: L("Applies to"),
                                value: key.isEmpty ? L("Every screen without a notch") : barScreens.first { $0.key == key }?.name ?? L("Every screen without a notch"),
                                spec: { screenSpec }, onPick: { state.screenKey = $0 })
                }
            }
            slider(L("Width"), pill.width, NotchSizing.pillWidths) { v in setPill { $0.width = v } }
            kit.row(L("As tall as the menu bar")) {
                kit.toggle(L("As tall as the menu bar"), Binding(get: { pill.height == nil }, set: { on in setPill { $0.height = on ? nil : 28 } }))
            }
            if let h = pill.height {
                slider(L("Height"), h, NotchSizing.pillHeights, step: 1) { v in setPill { $0.height = v } }
            }
            if key.isEmpty {
                slider(L("Corners"), s.pillCorner, NotchSizing.pillCorners, step: 1) { v in prefs.updateSizing { $0.pillCorner = v } }
            }
            HStack(spacing: Space.s) {
                if !key.isEmpty && s.perScreen[key] != nil {
                    Button(L("Use the size of every screen")) { prefs.updateSizing { $0.perScreen[key] = nil } }.buttonStyle(CocaineButtonStyle())
                }
                Spacer(minLength: 0)
                Button(L("Reset sizes")) { prefs.updateSizing { $0 = NotchSizing() } }
                    .buttonStyle(CocaineButtonStyle())
                    .disabled(s == NotchSizing())
            }
        }
    }

    // MARK: controls

    private var controlsRows: some View {
        let c = prefs.controls
        return Group {
            section(L("Controls"))
            Text(L("Add the Controls module to a screen in Screens to see them in the island.")).font(UI.detail).foregroundStyle(UI.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(c.shown.enumerated()), id: \.element) { i, id in
                controlRow(id, shown: true, first: i == 0, last: i == c.shown.count - 1)
                    .transition(Motion.appear(.top))
            }
            ForEach(c.hidden, id: \.self) { id in
                controlRow(id, shown: false, first: true, last: true).dimGroup(!c.canAdd).transition(Motion.appear(.top))
            }
        }
        .animation(ScreensMotion.edit, value: c)
    }

    private func controlRow(_ id: String, shown: Bool, first: Bool, last: Bool) -> some View {
        let spec = NotchControlCatalog.spec(id)
        let title = L(spec?.title ?? id)
        return HStack(spacing: Space.m) {
            Image(systemName: spec?.icon ?? "questionmark").font(UI.icon).foregroundStyle(shown ? Island.accent : UI.hint).frame(width: UI.iconColumn)
            Text(title).font(UI.title).foregroundStyle(shown ? UI.primary : UI.secondary).lineLimit(1)
            Spacer(minLength: Space.s)
            if shown {
                arrow("chevron.up", String(format: L("Move %@ up"), title), enabled: !first) { prefs.updateControls { $0.move(id, by: -1) } }
                arrow("chevron.down", String(format: L("Move %@ down"), title), enabled: !last) { prefs.updateControls { $0.move(id, by: 1) } }
            }
            CocaineSwitch(on: shown) { prefs.updateControls { $0.set(id, shown: !shown) } }.accessibilityLabel(title)
        }
        .frame(minHeight: 24)
    }

    private func arrow(_ icon: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(UI.chevron).foregroundStyle(enabled ? UI.primary : UI.hint)
                .frame(width: 22, height: 22).background(Circle().fill(CTL.fill)).contentShape(Circle())
        }
        .buttonStyle(MotionGlyphStyle())
        .disabled(!enabled)
        .help(label).accessibilityLabel(label)
    }
}

/// The battery HUD's two settings, published for the card.
final class NotchPowerSettings: ObservableObject {
    @Published var hud = Settings().notchChargeHUD { didSet { Settings().notchChargeHUD = hud } }
    @Published var low = Settings().notchLowBattery { didSet { Settings().notchLowBattery = low } }
}

/// Which lists the island shows and where a quick add goes (only once the island may see reminders).
struct NotchRemindersRows: View {
    @ObservedObject var watch: RemindersWatch
    let kit = AwakeRowKit()

    static func names(_ n: [String]) -> String { n.isEmpty ? L("None") : n.count == 1 ? n[0] : "\(n[0]) +\(n.count - 1)" }

    var body: some View {
        Group {
            Text(L("Reminders")).font(UI.section).foregroundStyle(UI.secondary).padding(.top, Space.xxs)
            if watch.access != .granted {
                Text(L("Add the Reminders screen in Screens, then allow access from the island.")).font(UI.detail).foregroundStyle(UI.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                kit.row(L("Lists shown")) {
                    ValueButton(id: "notch.lists", title: L("Lists shown"),
                                value: watch.settings.lists.isEmpty ? L("All") : Self.names(watch.settings.lists.compactMap { watch.list($0)?.title }),
                                spec: { PickerSpec(id: "notch.lists", title: L("Lists shown"), items: watch.lists.map { PickerItem(id: $0.id, title: $0.title) },
                                                   mode: .multi, selected: Set(watch.settings.lists)) },
                                onChange: { set in watch.update { $0.lists = watch.lists.map(\.id).filter { set.contains($0) } } })
                }
                kit.row(L("New reminders go to")) {
                    ValueButton(id: "notch.addTo", title: L("New reminders go to"), value: watch.addList?.title ?? L("None"),
                                spec: { PickerSpec(id: "notch.addTo", title: L("New reminders go to"), items: watch.lists.map { PickerItem(id: $0.id, title: $0.title) },
                                                   mode: .single(watch.addList?.id)) },
                                onPick: { id in watch.update { $0.addTo = id } })
                }
            }
        }
    }
}
