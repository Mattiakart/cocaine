// The island's Status page: batteries and the AI tools' usage.

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

extension IslandView {
    // MARK: batteries

    private var batteryTab: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if batteries.items.isEmpty {
                Text(L("No devices")).font(UI.value).foregroundStyle(UI.hint)
            }
            let cols = [GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .leading, spacing: Space.l) {
                ForEach(batteries.items.prefix(4)) { item in
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

    /// Batteries on the left, the AI tools' usage on the right.
    var statusTab: some View {
        HStack(alignment: .top, spacing: Space.gutter) {
            batteryTab.frame(width: 250, alignment: .topLeading)
            usageTab.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var usageTab: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Codex").font(UI.groupTitle)
                if usage.codex.isEmpty {
                    Text(usage.loaded ? L("Nothing found") : "…").font(UI.value).foregroundStyle(UI.hint)
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Claude Code").font(UI.groupTitle)
                tokenRow(L("Last 5 hours"), usage.claudeFive)
                tokenRow(L("Last 7 days"), usage.claudeWeek)
                Text(L("Tokens in your conversations on this Mac")).font(UI.detail).foregroundStyle(UI.hint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { usage.refresh() }
    }

    /// A label and a count, on one baseline: "Last 7 days … 8,6 Mln" in the app's language.
    private func tokenRow(_ label: String, _ n: Int) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label).font(UI.detail).foregroundStyle(UI.secondary); Spacer()
            Text(Dur.count(n, locale: Language.locale)).font(UI.metric) }
    }
}
