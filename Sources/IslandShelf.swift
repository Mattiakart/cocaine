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
final class ShelfStore: ObservableObject {
    @Published var urls: [URL] = []
    func add(_ u: URL) { if !urls.contains(u) { urls.append(u) } }
    func remove(_ u: URL) { urls.removeAll { $0 == u } }
    func clear() { urls = [] }
}

extension IslandView {
    var shelfTab: some View {
        HStack(alignment: .top, spacing: Space.page) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(L("Shelf")).font(UI.section).foregroundStyle(UI.secondary)
                if model.shelf.urls.isEmpty {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])).foregroundStyle(.white.opacity(0.25))
                        .overlay(Text(L("Drag files onto the notch, then drop them here")).font(UI.value).foregroundStyle(UI.hint).multilineTextAlignment(.center).padding(.horizontal, 12))
                        .frame(height: 96)
                } else {
                    // 5 × 80 + 4 × 8 = 432 pt: inside the 448 pt this column has (the old 5 × 84 + 4 × 10 spilled 6 pt left).
                    FadingScroll(cap: 118) { LazyVGrid(columns: Array(repeating: GridItem(.fixed(80), spacing: Space.m), count: 5), alignment: .leading, spacing: Space.m) {
                        ForEach(model.shelf.urls, id: \.self) { u in
                            VStack(spacing: 3) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 40, height: 40)
                                Text(u.lastPathComponent).font(UI.detail).lineLimit(1).truncationMode(.middle).foregroundStyle(UI.primary)
                            }
                            .frame(width: 80)
                            .overlay(alignment: .topTrailing) {
                                Button { model.shelf.remove(u) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(UI.secondary)
                                        .frame(width: 24, height: 24).contentShape(Rectangle())                   // a 24 pt target
                                }
                                .buttonStyle(.plain).help(L("Remove")).accessibilityLabel(L("Remove"))
                                .offset(x: 6, y: -6)
                            }
                            .onDrag { NSItemProvider(object: u as NSURL) }
                            .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                        }
                    }.padding(.top, 6) }
                }
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
