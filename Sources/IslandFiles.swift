// The island's Files page: recent downloads and screenshots, with thumbnails.

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

// MARK: Island, part 2: files and screenshots, clipboard, calendar

/// Recent downloads and screenshots, found by looking at the two folders every couple of seconds.
final class FileShelf: ObservableObject {
    struct Item: Identifiable, Equatable {
        var url: URL
        var id: URL { url }
        var name: String { url.lastPathComponent }
        var date: Date
        var size: Int64
    }
    @Published var downloads: [Item] = []
    @Published var shots: [Item] = []
    var onNew: ((String, String) -> Void)?        // symbol, text: a file just arrived
    private var known = Set<URL>()
    private var primed = false
    private var timer: Timer?

    static var downloadsFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads") }
    static var screenshotsFolder: URL {
        if let p = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }
    private static let shotPrefixes = ["Screenshot", "Screen Shot", "Schermata", "Captura", "Capture", "Bildschirmfoto", "スクリーンショット", "截屏", "屏幕快照", "螢幕快照"]
    private static let partial: Set<String> = ["crdownload", "download", "part", "opdownload", "tmp"]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    func stop() { timer?.invalidate(); timer = nil; primed = false }

    private let queue = DispatchQueue(label: "local.cocaine.files")
    private var busy = false

    private func poll() {
        // One listing at a time: the first one can wait (macOS asking for the folder) and must not pile up threads behind it.
        guard !busy else { return }
        busy = true
        queue.async {
            defer { DispatchQueue.main.async { self.busy = false } }
            let dl = Self.list(Self.downloadsFolder) { !Self.partial.contains($0.pathExtension.lowercased()) }
            let shotDir = Self.screenshotsFolder
            let sh = Self.list(shotDir) { u in
                let n = u.lastPathComponent
                return ["png", "jpg", "jpeg", "heic", "mov"].contains(u.pathExtension.lowercased())
                    && (shotDir.path != Self.downloadsFolder.path) && Self.shotPrefixes.contains { n.hasPrefix($0) }
            }
            DispatchQueue.main.async {
                let all = Set((dl + sh).map(\.url))
                if self.primed {
                    for it in dl where !self.known.contains(it.url) && Date().timeIntervalSince(it.date) < 120 { self.onNew?("arrow.down.circle.fill", it.name) }
                    for it in sh where !self.known.contains(it.url) && Date().timeIntervalSince(it.date) < 120 { self.onNew?("camera.viewfinder", L("Screenshot")) }
                }
                self.known.formUnion(all); self.primed = true
                if dl != self.downloads { self.downloads = dl }
                if sh != self.shots { self.shots = sh }
            }
        }
    }

    private static func list(_ dir: URL, where keep: (URL) -> Bool) -> [Item] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { u -> Item? in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, keep(u) else { return nil }
            return Item(url: u, date: v.contentModificationDate ?? .distantPast, size: Int64(v.fileSize ?? 0))
        }.sorted { $0.date > $1.date }.prefix(6).map { $0 }
    }
}

/// A small image for a file, made off the main thread.
private final class Thumb: ObservableObject {
    @Published var image: NSImage?
    private static var cache: [URL: NSImage] = [:]
    func load(_ url: URL, side: CGFloat) {
        if let c = Self.cache[url] { image = c; return }
        DispatchQueue.global().async {
            var img: NSImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side * 2] as CFDictionary) {
                img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
            } else {
                img = NSWorkspace.shared.icon(forFile: url.path)
            }
            DispatchQueue.main.async { if let img { Self.cache[url] = img }; self.image = img }
        }
    }
}

private struct FileThumb: View {
    let url: URL
    let side: CGFloat
    @StateObject private var thumb = Thumb()
    var body: some View {
        Group {
            if let i = thumb.image { Image(nsImage: i).resizable().aspectRatio(contentMode: .fill) } else { Color.white.opacity(0.08) }
        }
        .frame(width: side * 1.5, height: side).clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { thumb.load(url, side: side) }
    }
}

extension IslandView {
    // MARK: files

    var filesTab: some View {
        HStack(alignment: .top, spacing: Space.gutter) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(L("Downloads")).font(UI.section).foregroundStyle(UI.secondary)
                if files.downloads.isEmpty { Text(L("Nothing here yet")).font(UI.value).foregroundStyle(UI.hint) }
                FadingScroll(cap: 112) { VStack(alignment: .leading, spacing: Space.m) { ForEach(files.downloads) { it in
                    Button { NSWorkspace.shared.activateFileViewerSelecting([it.url]) } label: {
                        HStack(spacing: Space.m) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: it.url.path)).resizable().frame(width: 20, height: 20)
                            Text(it.name).font(UI.value).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: Space.xs)
                            Text(it.size.formatted(.byteCount(style: .file).locale(Language.locale))).font(UI.detail.monospacedDigit()).foregroundStyle(UI.hint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onDrag { NSItemProvider(object: it.url as NSURL) }
                } } }
                Spacer(minLength: 0)
            }
            .frame(width: 250, alignment: .leading)                  // template A: Downloads 250 pt, Screenshots the rest
            VStack(alignment: .leading, spacing: Space.m) {
                Text(L("Screenshots")).font(UI.section).foregroundStyle(UI.secondary)
                if files.shots.isEmpty { Text(L("Nothing here yet")).font(UI.value).foregroundStyle(UI.hint) }
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: Space.m) {
                    ForEach(files.shots) { it in
                        FileThumb(url: it.url, side: 62)
                            .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([it.url]) }
                            .onDrag { NSItemProvider(object: it.url as NSURL) }
                            .help(it.name)
                    }
                } }
                .mask(HStack(spacing: 0) { Rectangle(); LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 22) })
                Text(L("Drag a file out to drop it anywhere")).font(UI.detail).foregroundStyle(UI.hint)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}
