// The island's Files page: recent downloads and screenshots (FileShelf), their thumbnails and file icons (cached).

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

/// Recent downloads and screenshots. The two folders are watched (a kernel event when something is added, renamed or removed in
/// them) and listed only then; a slow check once a minute catches a moved screenshot location. If a folder can't be watched
/// (not allowed yet), it is listed every 5 s instead.
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
    private var started = false
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fallback: Timer?
    private var watchedShots = ""
    private var pending: DispatchWorkItem?

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
        guard !started else { return }
        started = true
        poll()
        arm()
    }

    func stop() {
        started = false; primed = false
        sources.forEach { $0.cancel() }; sources = []
        fallback?.invalidate(); fallback = nil
        pending?.cancel()
    }

    /// Watches both folders; the fallback timer re-arms when the screenshot folder moved or a folder couldn't be watched.
    private func arm() {
        sources.forEach { $0.cancel() }; sources = []
        let dirs = Array(Set([Self.downloadsFolder.path, Self.screenshotsFolder.path]))
        watchedShots = Self.screenshotsFolder.path
        for dir in dirs {
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: .main)
            s.setEventHandler { [weak self] in self?.changed() }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources.append(s)
        }
        fallback?.invalidate()
        let all = sources.count == dirs.count
        let t = Timer(timeInterval: all ? 60 : 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.poll()
            if Self.screenshotsFolder.path != self.watchedShots || self.sources.count < dirs.count { self.arm() }
        }
        t.tolerance = all ? 10 : 1
        RunLoop.main.add(t, forMode: .common)
        fallback = t
    }

    /// A burst of changes (a download being renamed into place) is listed once, a moment later.
    private func changed() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.poll() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private let queue = DispatchQueue(label: "local.cocaine.files")
    private var busy = false, again = false

    private func poll() {
        // One listing at a time: the first one can wait (macOS asking for the folder) and must not pile up threads behind it.
        guard !busy else { again = true; return }
        busy = true
        queue.async {
            let dl = Self.list(Self.downloadsFolder) { !Self.partial.contains($0.pathExtension.lowercased()) }
            let shotDir = Self.screenshotsFolder
            let sh = Self.list(shotDir) { u in
                let n = u.lastPathComponent
                return ["png", "jpg", "jpeg", "heic", "mov"].contains(u.pathExtension.lowercased())
                    && (shotDir.path != Self.downloadsFolder.path) && Self.shotPrefixes.contains { n.hasPrefix($0) }
            }
            DispatchQueue.main.async {
                self.busy = false
                let all = Set((dl + sh).map(\.url))
                if self.primed {
                    for it in dl where !self.known.contains(it.url) && Date().timeIntervalSince(it.date) < 120 { self.onNew?("arrow.down.circle.fill", it.name) }
                    for it in sh where !self.known.contains(it.url) && Date().timeIntervalSince(it.date) < 120 { self.onNew?("camera.viewfinder", L("Screenshot")) }
                }
                self.known = all; self.primed = true                      // only what is listed now: it never grows
                if dl != self.downloads { self.downloads = dl }
                if sh != self.shots { self.shots = sh }
                if self.again { self.again = false; self.poll() }
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

/// File icons, made once per path (NSWorkspace builds a new image every time it is asked).
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 200; return c }()
    static func icon(_ path: String) -> NSImage {
        if let i = cache.object(forKey: path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(i, forKey: path as NSString)
        return i
    }
}

/// A small image for a file, made off the main thread; the last 60 are kept.
private final class Thumb: ObservableObject {
    @Published var image: NSImage?
    private static let cache: NSCache<NSURL, NSImage> = { let c = NSCache<NSURL, NSImage>(); c.countLimit = 60; return c }()
    func load(_ url: URL, side: CGFloat) {
        if let c = Self.cache.object(forKey: url as NSURL) { image = c; return }
        DispatchQueue.global(qos: .utility).async {
            var img: NSImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side * 2] as CFDictionary) {
                img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
            } else {
                img = NSWorkspace.shared.icon(forFile: url.path)
            }
            DispatchQueue.main.async { if let img { Self.cache.setObject(img, forKey: url as NSURL) }; self.image = img }
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

    /// Recent downloads, a list that scrolls (as many rows as its height holds).
    func downloadsModule(_ b: ModuleBox) -> some View {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(L("Downloads")).font(UI.section).foregroundStyle(UI.secondary)
                if files.downloads.isEmpty { Text(L("Nothing here yet")).font(UI.value).foregroundStyle(UI.hint) }
                FadingScroll(cap: b.size == .l ? 112 + b.extraHeight : max(20, b.height - 24)) { VStack(alignment: .leading, spacing: Space.m) { ForEach(files.downloads) { it in
                    Button { NSWorkspace.shared.activateFileViewerSelecting([it.url]) } label: {
                        HStack(spacing: Space.m) {
                            Image(nsImage: IconCache.icon(it.url.path)).resizable().frame(width: 20, height: 20)
                            Text(it.name).font(UI.value).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: Space.xs)
                            Text(it.size.formatted(.byteCount(style: .file).locale(Language.locale))).font(UI.detail.monospacedDigit()).foregroundStyle(UI.hint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScaleRow))
                    .accessibilityLabel(it.name)
                    .accessibilityValue(it.size.formatted(.byteCount(style: .file).locale(Language.locale)))
                    .accessibilityHint(L("Shows it in Finder"))
                    .onDrag { NSItemProvider(object: it.url as NSURL) }
                } } }
                Spacer(minLength: 0)
            }
    }

    /// Recent screenshots, side by side, scrolling sideways; drag one out to drop it anywhere.
    func screenshotsModule(_ b: ModuleBox) -> some View {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(L("Screenshots")).font(UI.section).foregroundStyle(UI.secondary)
                if files.shots.isEmpty { Text(L("Nothing here yet")).font(UI.value).foregroundStyle(UI.hint) }
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: Space.m) {
                    ForEach(files.shots) { it in
                        Button { NSWorkspace.shared.activateFileViewerSelecting([it.url]) } label: { FileThumb(url: it.url, side: IslandScale.grow(62, b.factor)) }
                            .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScale))
                            .onDrag { NSItemProvider(object: it.url as NSURL) }
                            .help(it.name)
                            .accessibilityLabel(it.name)
                            .accessibilityHint(L("Shows it in Finder"))
                    }
                } }
                .mask(HStack(spacing: 0) { Rectangle(); LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 22) })
                Text(L("Drag a file out to drop it anywhere")).font(UI.detail).foregroundStyle(UI.hint)
                Spacer(minLength: 0)
            }
    }

}
