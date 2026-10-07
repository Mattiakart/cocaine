// The island's Music page: MusicWatch, the transport, the scrubber and the visualizer.

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

// MARK: Island, part 3: music with lyrics, volume/brightness HUDs, camera mirror, external monitors

/// Apple Music and Spotify, through their own scripting: title, artwork, a scrubber and the transport buttons, and (only if
/// switched on) synced lyrics looked up on lrclib.net by title and artist.
final class MusicWatch: ObservableObject {
    struct Track: Equatable { var id: String; var title: String; var artist: String; var album: String; var duration: Double; var app: String }
    struct Line { var time: Double; var text: String }
    @Published var track: Track?
    @Published var playing = false
    @Published var shuffle = false
    @Published var artwork: NSImage?
    @Published var lyrics: [Line] = []
    @Published var denied = false
    @Published var lyricsOn = AppDefaults.store.bool(forKey: "islandLyrics")
    private(set) var position = 0.0
    private(set) var fetched = Date()
    private var timer: Timer?
    private let queue = DispatchQueue(label: "local.cocaine.music")
    private var busy = false
    private var lyricsFor = ""

    private static let apps: [(name: String, bundle: String)] = [("Music", "com.apple.Music"), ("Spotify", "com.spotify.client")]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    func stop() { timer?.invalidate(); timer = nil; track = nil; playing = false }

    /// Where the song is now, in seconds (the scripting value, carried on by the clock between polls).
    var now: Double { min(track?.duration ?? 0, position + (playing ? Date().timeIntervalSince(fetched) : 0)) }

    var currentLine: String? {
        guard lyricsOn, !lyrics.isEmpty else { return nil }
        let t = now + 0.2
        return lyrics.last(where: { $0.time <= t })?.text
    }

    func setLyrics(_ on: Bool) {
        lyricsOn = on
        AppDefaults.store.set(on, forKey: "islandLyrics")
        lyricsFor = ""
        if on, let t = track { loadLyrics(t) } else { lyrics = [] }
    }

    private func script(_ source: String) -> String? {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        let refused = (err?[NSAppleScript.errorNumber] as? Int) == -1743
        if refused || (err == nil && denied) { DispatchQueue.main.async { if self.denied != refused { self.denied = refused } } }   // allowed later: back
        return r?.stringValue
    }

    func setSample(title: String, artist: String, album: String) {
        track = Track(id: "x", title: title, artist: artist, album: album, duration: 200, app: "Music"); playing = true; position = 74; lyricsOn = true
        lyrics = [Line(time: 70, text: "I'm running out of time")]
    }

    private var askedAutomation = Set<String>()

    private func poll() {
        guard !busy else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = Self.apps.filter { running.contains($0.bundle) }
        guard !candidates.isEmpty else { if track != nil { track = nil; playing = false; artwork = nil; lyrics = [] }; return }
        busy = true
        queue.async {
            var found: (Track, Bool, Double, Bool)?
            for a in candidates {
                if !self.askedAutomation.contains(a.bundle) {                         // the first time this app is seen running: check, and ask if needed
                    self.askedAutomation.insert(a.bundle)
                    if Permissions.automation(a.bundle, ask: false) == -1744 {         // never asked: the question, in front
                        DispatchQueue.main.sync { NSApp.activate() }
                        _ = Permissions.automation(a.bundle, ask: true)
                    }
                }
                let isSpotify = a.name == "Spotify"
                let extra = isSpotify
                    ? "set dur to (duration of t) / 1000\n  set shuf to (shuffling as text)\n  set tid to (id of t)"
                    : "set dur to (duration of t)\n  set shuf to (shuffle enabled as text)\n  set tid to ((database ID of t) as text)"
                let src = """
                tell application "\(a.name)"
                  if player state is stopped then return ""
                  set t to current track
                  set pstate to (player state as text)
                  \(extra)
                  return pstate & "\\t" & (name of t) & "\\t" & (artist of t) & "\\t" & (album of t) & "\\t" & dur & "\\t" & (player position) & "\\t" & shuf & "\\t" & tid
                end tell
                """
                guard let out = self.script(src), !out.isEmpty else { continue }
                let f = out.components(separatedBy: "\t")
                guard f.count >= 8 else { continue }
                func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
                let playing = f[0].lowercased().contains("play")
                let t = Track(id: a.name + f[7], title: f[1], artist: f[2], album: f[3], duration: num(f[4]), app: a.name)
                if found == nil || playing { found = (t, playing, num(f[5]), f[6].lowercased() == "true") }
                if playing { break }
            }
            DispatchQueue.main.async {
                self.busy = false
                guard let (t, playing, pos, shuffle) = found else { self.track = nil; self.playing = false; return }
                self.position = pos; self.fetched = Date()
                if self.playing != playing { self.playing = playing }
                if self.shuffle != shuffle { self.shuffle = shuffle }
                if self.track != t {
                    self.track = t; self.artwork = nil; self.lyrics = []
                    self.loadArtwork(t)
                    if self.lyricsOn { self.loadLyrics(t) }
                }
            }
        }
    }

    private func loadArtwork(_ t: Track) {
        queue.async {
            var image: NSImage?
            if t.app == "Spotify" {
                if let u = self.script("tell application \"Spotify\" to return artwork url of current track"), let url = URL(string: u),
                   let d = try? Data(contentsOf: url) { image = NSImage(data: d) }
            } else {
                var err: NSDictionary?
                let r = NSAppleScript(source: "tell application \"Music\" to return raw data of artwork 1 of current track")?.executeAndReturnError(&err)
                if let d = r?.data, d.count > 100 { image = NSImage(data: d) }
            }
            DispatchQueue.main.async { if self.track == t { self.artwork = image } }
        }
    }

    private func loadLyrics(_ t: Track) {
        guard lyricsFor != t.id else { return }
        lyricsFor = t.id
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [URLQueryItem(name: "artist_name", value: t.artist), URLQueryItem(name: "track_name", value: t.title),
                        URLQueryItem(name: "album_name", value: t.album), URLQueryItem(name: "duration", value: String(Int(t.duration.rounded())))]
        guard let url = c.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Cocaine (github.com/Mattiakart/cocaine)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let synced = json["syncedLyrics"] as? String else { return }
            let re = try? NSRegularExpression(pattern: #"^\[(\d+):(\d+(?:\.\d+)?)\]\s*(.*)$"#)
            let lines: [Line] = synced.components(separatedBy: "\n").compactMap { l in
                guard let m = re?.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let a = Range(m.range(at: 1), in: l), let b = Range(m.range(at: 2), in: l),
                      let c = Range(m.range(at: 3), in: l), let min = Double(l[a]), let sec = Double(l[b]) else { return nil }
                return Line(time: min * 60 + sec, text: String(l[c]))
            }
            DispatchQueue.main.async { if self.track == t { self.lyrics = lines } }
        }.resume()
    }

    // transport
    func playPause() { Haptic.tap(.generic); run("playpause") }
    func next() { Haptic.tap(.alignment); run("next track") }
    func previous() { Haptic.tap(.alignment); run("previous track") }
    func seek(_ seconds: Double) { Haptic.tap(.alignment); position = seconds; fetched = Date(); run("set player position to \(Int(seconds))") }
    func toggleShuffle() { run(track?.app == "Spotify" ? "set shuffling to not shuffling" : "set shuffle enabled to not shuffle enabled"); shuffle.toggle() }
    private func run(_ command: String) {
        guard let app = track?.app else { return }
        queue.async { _ = self.script("tell application \"\(app)\" to \(command)") }
        if command == "playpause" { playing.toggle(); position = now; fetched = Date() }
    }
}

extension IslandView {
    // MARK: music

    var musicTab: some View {
        let mu = model.music
        return HStack(alignment: .top, spacing: Space.page) {
            Group {
                if let a = mu.artwork { Image(nsImage: a).resizable().aspectRatio(contentMode: .fill) }
                else { ZStack { Color.white.opacity(0.08); Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.white.opacity(0.35)) } }
            }
            .frame(width: 128, height: 128).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: Space.xs) {
                if let t = mu.track {
                    Text(t.title).font(UI.pageTitle).lineLimit(1)
                    Text(t.artist + (t.album.isEmpty ? "" : " — " + t.album)).font(UI.value).foregroundStyle(UI.secondary).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        VStack(spacing: 0) {
                            Scrubber(value: mu.now, total: max(1, t.duration)) { mu.seek($0) }
                            HStack { Text(Self.clock(mu.now)); Spacer(); Text("-" + Self.clock(max(0, t.duration - mu.now))) }
                                .font(UI.detail.monospacedDigit()).foregroundStyle(UI.hint)
                        }
                    }
                    // Glyph buttons with 24 pt targets (the gap between them is part of no target).
                    HStack(spacing: 12) {
                        transport("shuffle", L("Shuffle"), on: mu.shuffle) { mu.toggleShuffle() }
                        transport("backward.fill", L("Previous track")) { mu.previous() }
                        transport(mu.playing ? "pause.fill" : "play.fill", mu.playing ? L("Pause") : L("Play"), size: 20) { mu.playPause() }
                        transport("forward.fill", L("Next track")) { mu.next() }
                        Spacer(minLength: 0)
                        transport("quote.bubble", mu.lyricsOn ? L("Hide lyrics") : L("Show lyrics (looks up the title and artist on lrclib.net)"), on: mu.lyricsOn) { mu.setLyrics(!mu.lyricsOn) }
                    }
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(mu.currentLine ?? (mu.lyricsOn ? (mu.lyrics.isEmpty ? L("No synced lyrics found") : "♪") : ""))
                            .font(UI.groupTitle).foregroundStyle(Island.accent).lineLimit(1)
                    }
                } else {
                    Text(mu.denied ? L("Allow Cocaine to control Music and Spotify in System Settings → Privacy & Security → Automation") : L("Play something in Music or Spotify"))
                        .font(UI.value).foregroundStyle(UI.hint).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    fileprivate static func clock(_ s: Double) -> String { let i = Int(s); return String(format: "%d:%02d", i / 60, i % 60) }

    /// A music control: a glyph (accent while its mode is on), a 24 pt target, a name for VoiceOver and the tooltip.
    fileprivate func transport(_ symbol: String, _ title: String, on: Bool? = nil, size: CGFloat = 14, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size))
                .foregroundStyle(on.map { $0 ? Island.accent : UI.hint } ?? UI.primary)
                .frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
        .accessibilityAddTraits(on == true ? .isSelected : [])
    }

}

/// The track position: the app's one slider, seeking when the drag ends (the knob follows the finger meanwhile).
private struct Scrubber: View {
    let value: Double, total: Double
    let seek: (Double) -> Void
    var body: some View {
        CocaineSlider(value: min(value, total), range: 0...max(1, total), step: 10, live: false, name: L("Position"),
                      valueText: IslandView.clock(value) + " / " + IslandView.clock(total)) { seek($0) }
    }
}

/// Four bars that dance while music plays (a little, not a spectrum).
struct Visualizer: View {
    let playing: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(Island.accent).frame(width: 2.5, height: playing ? 5 + 9 * abs(sin(t * (3 + Double(i) * 1.3) + Double(i))) : 4)
                }
            }
            .frame(height: 16)
        }
    }
}
