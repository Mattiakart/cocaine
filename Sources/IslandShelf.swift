// The island's Shelf page: files dropped on the island.

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

// MARK: Island, part 4: a shelf for files, and the charging activity

/// Files dropped on the island, held (as references, never copied) until you drag them out, AirDrop them or clear the shelf.
/// The list is kept across a restart ("shelf.v1", paths only); files that are gone by then are left out.
final class ShelfStore: ObservableObject {
    @Published var urls: [URL] = [] { didSet { if persist { defaults.set(urls.map(\.path), forKey: Self.key) } } }
    private let defaults: UserDefaults
    private var persist = false
    static let key = "shelf.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        urls = (defaults.stringArray(forKey: Self.key) ?? []).filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        persist = true
    }

    func add(_ u: URL) { if !urls.contains(u) { urls.append(u) } }
    func remove(_ u: URL) { urls.removeAll { $0 == u } }
    func clear() { urls = [] }
}

extension IslandView {
    /// The shelf: as many 80 pt columns of files as its width holds beside the two buttons (5 on the whole page).
    func shelfModule(_ b: ModuleBox) -> some View {
        let columns = max(1, min(5, Int((b.width - 110 - Space.page + Space.m) / (80 + Space.m))))
        return HStack(alignment: .top, spacing: Space.page) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(L("Shelf")).font(UI.section).foregroundStyle(UI.secondary)
                if model.shelf.urls.isEmpty {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])).foregroundStyle(.white.opacity(0.25))
                        .overlay(Text(L("Drag files onto the notch, then drop them here")).font(UI.value).foregroundStyle(UI.hint).multilineTextAlignment(.center).padding(.horizontal, 12))
                        .frame(height: 96)
                } else {
                    // 5 × 80 + 4 × 8 = 432 pt: inside the 448 pt this column has (the old 5 × 84 + 4 × 10 spilled 6 pt left).
                    FadingScroll(cap: 118) { LazyVGrid(columns: Array(repeating: GridItem(.fixed(80), spacing: Space.m), count: columns), alignment: .leading, spacing: Space.m) {
                        ForEach(model.shelf.urls, id: \.self) { u in
                            Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: {
                                VStack(spacing: 3) {
                                    Image(nsImage: IconCache.icon(u.path)).resizable().frame(width: 40, height: 40)
                                    Text(u.lastPathComponent).font(UI.detail).lineLimit(1).truncationMode(.middle).foregroundStyle(UI.primary)
                                }
                                .frame(width: 80)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(u.lastPathComponent)
                            .accessibilityHint(L("Shows it in Finder"))
                            .accessibilityAction(named: L("Remove")) { model.shelf.remove(u) }
                            .overlay(alignment: .topTrailing) {
                                Button { model.shelf.remove(u) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(UI.secondary)
                                        .frame(width: 24, height: 24).contentShape(Rectangle())                   // a 24 pt target
                                }
                                .buttonStyle(.plain).help(L("Remove")).accessibilityHidden(true)       // (the item's own Remove action)
                                .offset(x: 6, y: -6)
                            }
                            .onDrag { NSItemProvider(object: u as NSURL) }
                        }
                    }.padding(.top, 6) }
                }
                Text(L("Kept until you remove them; the files aren’t copied")).font(UI.detail).foregroundStyle(UI.hint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: Space.m) {
                Button { model.airDrop(model.shelf.urls) } label: { Label("AirDrop", systemImage: "airplayaudio") }
                    .buttonStyle(CocaineButtonStyle(kind: .primary, height: CTL.hDialog)).disabled(model.shelf.urls.isEmpty)
                Button(L("Clear")) { model.shelf.clear() }
                    .buttonStyle(CocaineButtonStyle(height: CTL.hDialog)).disabled(model.shelf.urls.isEmpty)
                Spacer(minLength: 0)
            }
            .frame(width: 110)
        }
    }
}
