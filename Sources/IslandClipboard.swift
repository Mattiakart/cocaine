// The island's Clipboard page (the history itself is in Sources/Clipboard.swift).

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

/// The clipboard history lives in Sources/Clipboard.swift; its text comes from the Clipboard string table.
func clipboardL(_ key: String) -> String { L(key) }

/// The island's clipboard page: search, favorites, pause, and the history itself (Sources/Clipboard.swift).
private struct ClipboardPage: View {
    @ObservedObject var h: ClipboardHistory
    let copyClip: (ClipItem) -> Void
    let keyable: (Bool) -> Void

    var body: some View {
        let list = h.visible
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(UI.hint)       // a glyph
                    TextField(L("Search"), text: $h.query).textFieldStyle(.plain).font(UI.value)
                        .onExitCommand { h.query = "" }
                        .onSubmit { if let c = h.visible.first(where: { $0.id == h.hovered }) ?? h.visible.first { copyClip(c) } }   // Return: the highlighted one
                        .help(L("↑ and ↓ pick an item, Return copies it"))
                    if !h.query.isEmpty {
                        Button { h.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(UI.hint)
                                .frame(width: 24, height: 24).contentShape(Rectangle())                         // a 24 pt target
                        }
                        .buttonStyle(.plain).help(L("Clear search")).accessibilityLabel(L("Clear search"))
                        .padding(.trailing, -Space.m)                    // the target may reach into the field's padding
                    }
                }
                .padding(.horizontal, Space.m).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(0.08)))
                tool(h.favoritesOnly ? "star.fill" : "star", on: h.favoritesOnly, L("Favorites only")) { h.favoritesOnly.toggle() }
                tool(h.paused ? "play.fill" : "pause.fill", on: h.paused, h.paused ? L("Resume") : L("Pause")) { h.paused.toggle() }
                tool("trash", on: false, L("Clear")) {
                    IslandChoices.ask(L("Clear"), icon: "trash", IslandChoices.clipboardTrash) { id in
                        if id == "clear" { h.clearHistory() } else { DispatchQueue.main.async { ClipboardUI.confirmDeleteEverything(h, from: .island) } }
                    }
                }
            }
            if list.isEmpty {
                Text(h.items.isEmpty ? L("What you copy will show up here") : h.favoritesOnly && h.query.isEmpty ? L("No favorites yet") : L("Nothing matches"))
                    .font(UI.value).foregroundStyle(UI.hint)
            }
            FadingScroll {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.l), GridItem(.flexible())], alignment: .leading, spacing: Space.s) {
                    ForEach(list) { c in row(c) }
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .onDisappear { keyable(false); h.hovered = nil }      // gives the keyboard back if the search field had it
    }

    /// A small square button of the toolbar, highlighted while its mode is on (like the selected tab).
    private func tool(_ icon: String, on: Bool, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptic.tap(.alignment); action() } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(on ? Island.accent : .white.opacity(0.5))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(on ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private func row(_ c: ClipItem) -> some View {
        let gone = h.missing.contains(c.id), hover = h.hovered == c.id
        return HStack(spacing: 0) {
            Button { copy(c) } label: {
                HStack(spacing: Space.s) {
                    leading(c)
                    Text(title(c)).font(UI.value).lineLimit(1).truncationMode(c.kind == .files ? .middle : .tail)
                        .foregroundStyle(gone ? UI.hint : UI.primary)
                    if gone { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(warningColor) }   // a badge glyph
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // VoiceOver: the row is "copy it"; delete and the star are its actions (the × only shows under the pointer).
            .accessibilityLabel(title(c))
            .accessibilityValue(c.pinned ? L("Favorite") : "")
            .accessibilityHint(gone ? L("The file is no longer there") : L("Copy"))
            .accessibilityAction(named: L("Delete")) { h.remove(c.id) }
            .accessibilityAction(named: c.pinned ? L("Remove from favorites") : L("Add to favorites")) { h.togglePin(c.id) }
            // The two icons: small glyphs, 24 pt targets (side by side, they reach into the row's padding).
            if hover {
                Button { h.remove(c.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(UI.hint).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L("Delete")).accessibilityLabel(L("Delete"))
            }
            Button { Haptic.tap(.alignment); h.togglePin(c.id) } label: {
                Image(systemName: c.pinned ? "star.fill" : "star").font(.system(size: 10))
                    .foregroundStyle(c.pinned ? Island.accent : Color.white.opacity(hover ? 0.65 : 0.4)).frame(width: 24, height: 24).contentShape(Rectangle())   // 3:1 on the row
            }
            .buttonStyle(.plain).help(c.pinned ? L("Remove from favorites") : L("Add to favorites"))
            .accessibilityLabel(c.pinned ? L("Remove from favorites") : L("Add to favorites"))
        }
        .padding(.leading, Space.l).padding(.trailing, 1).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.14 : 0.08)))     // the pointer's row, or the keyboard's
        .onHover { inside in if inside { h.hovered = c.id } else if h.hovered == c.id { h.hovered = nil } }
        .help(gone ? L("The file is no longer there") : tip(c))
        .contextMenu {
            Button(L("Copy")) { copy(c) }
            Button(c.pinned ? L("Remove from favorites") : L("Add to favorites")) { h.togglePin(c.id) }
            if c.kind == .files, !gone { Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(c.paths.map { URL(fileURLWithPath: $0) }) } }
            Divider()
            Button(L("Delete")) { h.remove(c.id) }
        }
    }

    @ViewBuilder private func leading(_ c: ClipItem) -> some View {
        switch c.kind {
        case .text: EmptyView()
        case .image:
            Group {
                if let t = h.thumbnail(c) { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) } else { Color.white.opacity(0.1) }
            }
            .frame(width: 22, height: 16).clipShape(RoundedRectangle(cornerRadius: 3))
        case .files:
            Image(nsImage: NSWorkspace.shared.icon(forFile: c.paths.first ?? "/")).resizable().frame(width: 16, height: 16)
        }
    }

    private func title(_ c: ClipItem) -> String {
        switch c.kind {
        case .text: return c.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        case .image: return L("Image") + " · \(c.width)×\(c.height)"
        case .files: return (c.names.first ?? "") + (c.names.count > 1 ? " +\(c.names.count - 1)" : "")
        }
    }

    private func tip(_ c: ClipItem) -> String {
        var parts: [String] = []
        switch c.kind {
        case .text: parts.append(String(c.text.prefix(300)))
        case .image: parts.append(L("Image") + " · \(c.width)×\(c.height) · " + Int64(c.bytes).formatted(.byteCount(style: .file).locale(Language.locale)))
        case .files: parts.append(c.paths.prefix(5).joined(separator: "\n"))
        }
        if let app = ClipboardHistory.appName(c.source) { parts.append(app) }
        parts.append(c.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Language.locale)))
        return parts.joined(separator: "\n")
    }

    private func copy(_ c: ClipItem) { copyClip(c) }

    /// Where the history is kept, said plainly; a problem (no Keychain, unreadable file) takes its place.
    @ViewBuilder private var footer: some View {
        if let p = h.problem {
            Label(p, systemImage: "exclamationmark.triangle.fill").font(UI.detail).foregroundStyle(warningColor).lineLimit(1).help(p)
        } else if h.paused {
            Label(L("Paused: what you copy now isn't kept."), systemImage: "pause.fill").font(UI.detail).foregroundStyle(UI.hint)
        } else if h.saving {
            Label(L("Saved on this Mac, encrypted. Never from password managers."), systemImage: "lock.fill").font(UI.detail).foregroundStyle(UI.hint)
        } else {
            Text(L("Kept only in memory, never from password managers. Click to copy again.")).font(UI.detail).foregroundStyle(UI.hint)
        }
    }
}

extension IslandView {
    // MARK: clipboard

    var clipboardTab: some View {
        ClipboardPage(h: clipboard, copyClip: { model.copyClip($0) }, keyable: model.setKeyable)
    }

}
