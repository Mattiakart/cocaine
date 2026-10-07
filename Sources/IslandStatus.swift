// The island's Status page: batteries (BatteryWatch) and the AI tools' usage (Usage.swift).

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

struct BatteryItem: Identifiable {
    var id: String
    var name: String
    var icon: String
    var parts: [(label: String, percent: Int)]
    var charging = false
}

/// Charge of the Mac and of connected Bluetooth devices (AirPods, keyboard, mouse, trackpad). The Bluetooth list comes from
/// system_profiler (1–3 s each time): it is kept a minute, so opening the page again is instant.
final class BatteryWatch: ObservableObject {
    @Published var items: [BatteryItem] = []
    private var busy = false
    private var bluetoothCache: (at: Date, items: [BatteryItem])?
    static let bluetoothMaxAge: TimeInterval = 60

    func refresh() {
        guard !busy else { return }
        let mac = System.battery.map { BatteryItem(id: "mac", name: "Mac", icon: "laptopcomputer", parts: [("", $0.percent)], charging: $0.onAC) }
        if let c = bluetoothCache, Date().timeIntervalSince(c.at) < Self.bluetoothMaxAge {
            items = (mac.map { [$0] } ?? []) + c.items
            return
        }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let bt = Self.bluetooth()
            DispatchQueue.main.async {
                self.bluetoothCache = (Date(), bt)
                self.items = (mac.map { [$0] } ?? []) + bt
                self.busy = false
            }
        }
    }

    private static func bluetooth() -> [BatteryItem] {
        let r = Proc.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 15, capture: true, limit: 4 << 20)
        guard r.status == 0, let root = (try? JSONSerialization.jsonObject(with: r.output)) as? [String: Any],
              let top = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = top["device_connected"] as? [[String: Any]] else { return [] }
        func pct(_ v: Any?) -> Int? { (v as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
        var items: [BatteryItem] = []
        for entry in connected {
            for (name, value) in entry {
                guard let d = value as? [String: Any] else { continue }
                var parts: [(String, Int)] = []
                for (key, label) in [("device_batteryLevelMain", ""), ("device_batteryLevelLeft", "L"), ("device_batteryLevelRight", "R"), ("device_batteryLevelCase", "↳")] {
                    if let v = pct(d[key]) { parts.append((label, v)) }
                }
                guard !parts.isEmpty else { continue }
                let kind = (d["device_minorType"] as? String ?? "").lowercased()
                let icon = kind.contains("head") || name.lowercased().contains("airpods") ? "airpodspro" : kind.contains("keyboard") ? "keyboard"
                    : kind.contains("mouse") ? "computermouse" : kind.contains("trackpad") ? "rectangle.and.hand.point.up.left" : "dot.radiowaves.left.and.right"
                items.append(BatteryItem(id: name, name: name, icon: icon, parts: parts))
            }
        }
        return items.sorted { $0.name < $1.name }
    }
}

extension IslandView {
    // MARK: batteries

    /// The batteries: four devices at L, two at M, one at S.
    func batteriesModule(_ b: ModuleBox) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if batteries.items.isEmpty {
                Text(L("No devices")).font(UI.value).foregroundStyle(UI.hint)
            }
            let cols = [GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .leading, spacing: Space.l) {
                ForEach(batteries.items.prefix(b.size == .l ? 4 : b.size == .m ? 2 : 1)) { item in
                    HStack(spacing: Space.m) {
                        Image(systemName: item.icon).font(.system(size: 14)).foregroundStyle(UI.secondary).frame(width: 20)   // a device glyph
                        VStack(alignment: .leading, spacing: Space.xs) {
                            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                Text(item.name).font(UI.itemTitle).lineLimit(1)
                                if item.charging { Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.green) }   // a badge glyph
                                Spacer(minLength: 0)
                                Text(item.parts.map { (Self.partName($0.label).map { $0 + " " } ?? "") + "\($0.percent)%" }.joined(separator: "  "))
                                    .font(UI.metric).foregroundStyle(UI.primary).lineLimit(1)
                            }
                            Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
                                .overlay(alignment: .leading) {
                                    GeometryReader { r in Capsule().fill(Self.level(item.parts.map(\.percent).min() ?? 0)).frame(width: r.size.width * CGFloat(item.parts.map(\.percent).min() ?? 0) / 100) }
                                }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.name)
                    .accessibilityValue(item.parts.map { (Self.partName($0.label).map { $0 + " " } ?? "") + "\($0.percent)%" }.joined(separator: ", ")
                                        + (item.charging ? ", " + L("Charging") : ""))
                }
            }
        }
        .onAppear { batteries.refresh() }
    }

    private static func level(_ p: Int) -> Color { p <= 15 ? .red : p <= 30 ? .orange : .green }

    /// A device part in the app's language: L / R for earbuds (S / D in Italian…), Case for their case.
    static func partName(_ code: String) -> String? {
        switch code {
        case "": return nil
        case "L": return L("Left, short")
        case "R": return L("Right, short")
        case "↳": return L("Case")
        default: return code
        }
    }


    // MARK: usage

    /// The AI tools' usage: Codex's limits and Claude Code's tokens.
    func usageModule(_ b: ModuleBox) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Codex").font(UI.groupTitle)
                if usage.codex.isEmpty {
                    Text(usage.loaded ? L("Nothing found") : "…").font(UI.value).foregroundStyle(UI.hint).shimmer(!usage.loaded)
                }
                ForEach(usage.codex) { l in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) { Text(l.name).font(UI.detail).foregroundStyle(UI.secondary); Spacer()
                            Text("\(Int(l.percent))%").font(UI.metric) }
                        Capsule().fill(Color.white.opacity(0.12)).frame(height: 5)
                            .overlay(alignment: .leading) { GeometryReader { r in Capsule().fill(Island.accent).frame(width: r.size.width * min(1, l.percent / 100)) } }
                        if let d = l.resets {
                            Text(String(format: L("Resets %@"), d.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Language.locale))))
                                .font(UI.detail).foregroundStyle(UI.hint)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Claude Code").font(UI.groupTitle)
                tokenRow(L("Last 5 hours"), usage.claudeFive)
                tokenRow(L("Last 7 days"), usage.claudeWeek)
                Text(usage.partial ? L("Still counting: the totals grow as the rest is read") : L("Tokens in your conversations on this Mac"))
                    .font(UI.detail).foregroundStyle(usage.partial ? warningColor : UI.hint)
                    .shimmer(usage.partial)                              // still reading: a calm light passes over it
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { usage.refresh() }
    }

    /// A label and a count, on one baseline: "Last 7 days … 8,6 Mln" in the app's language.
    private func tokenRow(_ label: String, _ n: Int) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label).font(UI.detail).foregroundStyle(UI.secondary); Spacer()
            Text((usage.partial ? "≥ " : "") + Dur.count(n, locale: Language.locale)).font(UI.metric) }
            .accessibilityElement(children: .combine)
    }
}
