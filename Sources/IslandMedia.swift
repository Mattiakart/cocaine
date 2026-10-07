// The island's Media page: music and video launchers.

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

// MARK: Island, part 5: media launchers

/// A music or video service: opened as its app when it is installed, else as its website in the default browser.
private struct MediaApp: Identifiable {
    var id: String
    var name: String
    var symbol: String
    var color: Color
    var bundles: [String]
    var apps: [String]                 // file names to look for in the Applications folders
    var url: String

    static let all: [MediaApp] = [
        MediaApp(id: "music", name: "Apple Music", symbol: "music.note", color: Color(red: 0.98, green: 0.25, blue: 0.35), bundles: ["com.apple.Music"], apps: ["Music.app"], url: "https://music.apple.com"),
        MediaApp(id: "spotify", name: "Spotify", symbol: "waveform", color: Color(red: 0.12, green: 0.73, blue: 0.33), bundles: ["com.spotify.client"], apps: ["Spotify.app"], url: "https://open.spotify.com"),
        MediaApp(id: "ytmusic", name: "YouTube Music", symbol: "music.quarternote.3", color: Color(red: 0.95, green: 0.2, blue: 0.2), bundles: [], apps: ["YouTube Music.app"], url: "https://music.youtube.com"),
        MediaApp(id: "netflix", name: "Netflix", symbol: "play.rectangle.fill", color: Color(red: 0.88, green: 0.08, blue: 0.14), bundles: ["com.netflix.Netflix"], apps: ["Netflix.app"], url: "https://www.netflix.com"),
        MediaApp(id: "prime", name: "Prime Video", symbol: "play.tv.fill", color: Color(red: 0.0, green: 0.6, blue: 0.9), bundles: [], apps: ["Prime Video.app", "Amazon Prime Video.app"], url: "https://www.primevideo.com"),
        MediaApp(id: "youtube", name: "YouTube", symbol: "play.rectangle.on.rectangle.fill", color: Color(red: 1.0, green: 0.1, blue: 0.1), bundles: [], apps: ["YouTube.app"], url: "https://www.youtube.com"),
        MediaApp(id: "disney", name: "Disney+", symbol: "sparkles.tv.fill", color: Color(red: 0.2, green: 0.35, blue: 0.85), bundles: [], apps: ["Disney+.app", "Disney Plus.app"], url: "https://www.disneyplus.com"),
        MediaApp(id: "appletv", name: "Apple TV", symbol: "appletv.fill", color: Color(red: 0.7, green: 0.7, blue: 0.75), bundles: ["com.apple.TV"], apps: ["TV.app"], url: "https://tv.apple.com"),
        MediaApp(id: "twitch", name: "Twitch", symbol: "dot.radiowaves.left.and.right", color: Color(red: 0.57, green: 0.27, blue: 1.0), bundles: [], apps: ["Twitch.app"], url: "https://www.twitch.tv"),
        MediaApp(id: "dazn", name: "DAZN", symbol: "sportscourt.fill", color: Color(red: 0.9, green: 0.9, blue: 0.2), bundles: [], apps: ["DAZN.app"], url: "https://www.dazn.com"),
    ]

    /// Where each app is (nil: not installed), looked up when the page opens, not on every redraw.
    private static var found: [String: URL?] = [:]
    static func refresh() { found = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.lookup()) }) }

    /// Where the app is, if it's installed.
    var installedURL: URL? {
        if let f = Self.found[id] { return f }
        let u = lookup()
        Self.found[id] = u
        return u
    }

    private func lookup() -> URL? {
        for b in bundles { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { return u } }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in ["/Applications", home + "/Applications", "/System/Applications"] {
            for a in apps where FileManager.default.fileExists(atPath: dir + "/" + a) { return URL(fileURLWithPath: dir + "/" + a) }
        }
        return nil
    }

    func open() {
        if let app = installedURL { NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) }
        else if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

extension IslandView {
    var mediaTab: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            // Five equal tiles flush with both page edges (fixed 104 pt tiles left a 24 pt hole on the right).
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.m), count: 5), alignment: .leading, spacing: Space.m) {
                ForEach(MediaApp.all) { app in
                    let url = app.installedURL
                    Button { Haptic.tap(.generic); app.open() } label: {
                        VStack(spacing: 5) {
                            ZStack(alignment: .bottomTrailing) {
                                if let url { Image(nsImage: IconCache.icon(url.path)).resizable().frame(width: 38, height: 38) }
                                else {
                                    RoundedRectangle(cornerRadius: 9).fill(app.color.opacity(0.9)).frame(width: 38, height: 38)
                                        .overlay(Image(systemName: app.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))
                                    Image(systemName: "globe").font(.system(size: 9, weight: .bold)).padding(2).background(Circle().fill(.black)).foregroundStyle(.white).offset(x: 3, y: 3)
                                }
                            }
                            Text(app.name).font(UI.detail).lineLimit(1).foregroundStyle(UI.primary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 66)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScale))
                    .help(url == nil ? String(format: L("Opens %@ on the web"), app.name) : String(format: L("Opens %@"), app.name))
                    .accessibilityLabel(app.name)
                    .accessibilityHint(url == nil ? String(format: L("Opens %@ on the web"), app.name) : String(format: L("Opens %@"), app.name))
                }
            }
            Text(L("Opens the app, or the website if it isn't installed.")).font(UI.detail).foregroundStyle(UI.hint)
        }
        .onAppear { MediaApp.refresh() }          // an app installed or removed since: seen when the page opens
    }
}
