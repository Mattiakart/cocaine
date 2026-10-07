// The island's Music page: what Music or Spotify is playing (MusicWatch), lyrics, the scrubber and the visualizer.

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

/// NSAppleScript isn't thread-safe: every script of the app runs on this one thread, one at a time (a dispatch queue would run
/// them on whichever thread it has at hand).
final class ScriptThread: Thread {
    static let shared = ScriptThread()
    private let cond = NSCondition()
    private var jobs: [() -> Void] = []

    private override init() {
        super.init()
        name = "local.cocaine.scripts"
        qualityOfService = .utility
        start()
    }

    func async(_ job: @escaping () -> Void) {
        cond.lock(); jobs.append(job); cond.signal(); cond.unlock()
    }

    override func main() {
        while true {
            cond.lock()
            while jobs.isEmpty { cond.wait() }
            let job = jobs.removeFirst()
            cond.unlock()
            autoreleasepool { job() }
        }
    }
}

/// Apple Music and Spotify. What plays comes from the apps' own announcements (distributed notifications: no Apple events, no
/// polling, the closed island's visualizer follows play and pause); their scripting is used once per track (artwork, Music's
/// position) and every second only while the Music page is on screen (the scrubber). Lyrics (only if switched on): synced
/// lyrics looked up on lrclib.net by title and artist.
final class MusicWatch: ObservableObject {
    struct Track: Equatable { var id: String; var title: String; var artist: String; var album: String; var duration: Double; var app: String }
    struct Line { var time: Double; var text: String }
    enum LyricsState: Equatable { case idle, loading, found, notFound, failed }
    @Published var track: Track?
    @Published var playing = false
    @Published var shuffle = false
    @Published var artwork: NSImage?
    @Published var lyrics: [Line] = []
    @Published var lyricsState = LyricsState.idle
    @Published var denied = false
    @Published var lyricsOn = AppDefaults.store.bool(forKey: "islandLyrics")
    private(set) var position = 0.0
    private(set) var fetched = Date()
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var busy = false
    private var lyricsFor = ""
    private var compiled: [String: NSAppleScript] = [:]          // on the script thread only

    private static let apps: [(name: String, bundle: String)] = [("Music", "com.apple.Music"), ("Spotify", "com.spotify.client")]

    /// The Music page is on screen: its scrubber and shuffle state are kept current (one script a second).
    var pageVisible = false {
        didSet {
            guard pageVisible != oldValue else { return }
            timer?.invalidate(); timer = nil
            guard pageVisible else { return }
            poll()
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func start() {
        guard observers.isEmpty else { return }
        let dnc = DistributedNotificationCenter.default()
        observers.append((dnc, dnc.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
            self?.announced(app: "Music", n.userInfo)
        }))
        observers.append((dnc, dnc.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            self?.announced(app: "Spotify", n.userInfo)
        }))
        let ws = NSWorkspace.shared.notificationCenter
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard let self, let t = self.track, Self.apps.first(where: { $0.name == t.app })?.bundle == id else { return }
            self.clear()                                                  // the app playing it quit
        }))
        poll()                                                            // once: what already plays
    }

    func stop() {
        for (c, o) in observers { c.removeObserver(o) }
        observers = []
        pageVisible = false
        clear()
    }

    private func clear() {
        if track != nil { track = nil }
        if playing { playing = false }
        artwork = nil; lyrics = []; lyricsState = .idle; lyricsFor = ""
    }

    /// Where the song is now, in seconds (the last known value, carried on by the clock).
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
        if on, let t = track { loadLyrics(t) } else { lyrics = []; lyricsState = .idle }
    }

    func setSample(title: String, artist: String, album: String) {
        track = Track(id: "x", title: title, artist: artist, album: album, duration: 200, app: "Music"); playing = true; position = 74; lyricsOn = true
        lyrics = [Line(time: 70, text: "I'm running out of time")]; lyricsState = .found
    }

    // MARK: what the apps announce

    /// Music: "Player State", "Name", "Artist", "Album", "Total Time" (ms), "PersistentID". Spotify: the same names but
    /// "Duration" (ms), "Playback Position" (s) and "Track ID".
    func announced(app: String, _ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let state = (info["Player State"] as? String ?? "").lowercased()
        let isCurrent = track?.app == app
        if state == "stopped" {
            if isCurrent { clear() }
            return
        }
        let nowPlaying = state == "playing"
        guard nowPlaying || isCurrent || track == nil || !playing else { return }   // another app pausing doesn't take over
        let ms = (info["Total Time"] as? NSNumber ?? info["Duration"] as? NSNumber)?.doubleValue ?? (track?.duration ?? 0) * 1000
        let name = info["Name"] as? String ?? "", artist = info["Artist"] as? String ?? "", album = info["Album"] as? String ?? ""
        let id = Self.trackID(app: app, spotifyID: info["Track ID"] as? String, name: name, artist: artist, album: album)
        let t = Track(id: id, title: name, artist: artist, album: album, duration: ms / 1000, app: app)
        if let pos = (info["Playback Position"] as? NSNumber)?.doubleValue { position = pos; fetched = Date() }
        else if !isCurrent || track?.id != id { position = 0; fetched = Date() }
        else if playing != nowPlaying { position = now; fetched = Date() }
        if playing != nowPlaying { playing = nowPlaying }
        if track != t {
            let changed = track?.id != t.id
            track = t
            if changed { trackChanged(t) }
        }
        if app == "Music" { poll() }                                         // Music doesn't say where it is: one script
    }

    /// The same track whether the app announced it or a script read it: Spotify's own id; for Music its name, artist and album
    /// (its notification and its scripting don't share an id).
    static func trackID(app: String, spotifyID: String?, name: String, artist: String, album: String) -> String {
        if app == "Spotify", let s = spotifyID, !s.isEmpty { return app + s }
        return app + name + "\u{1}" + artist + "\u{1}" + album
    }

    private func trackChanged(_ t: Track) {
        artwork = nil; lyrics = []; lyricsState = .idle
        loadArtwork(t)
        if lyricsOn { loadLyrics(t) }
    }

    // MARK: scripting (the Music page, and once at start)

    private func script(_ source: String) -> String? {
        let s: NSAppleScript? = compiled[source] ?? {
            let n = NSAppleScript(source: source)
            if let n { compiled[source] = n }
            return n
        }()
        var err: NSDictionary?
        let r = s?.executeAndReturnError(&err)
        let refused = (err?[NSAppleScript.errorNumber] as? Int) == -1743
        if refused || (err == nil && denied) { DispatchQueue.main.async { if self.denied != refused { self.denied = refused } } }   // allowed later: back
        return r?.stringValue
    }

    private var askedAutomation = Set<String>()

    private func poll() {
        guard !busy else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = Self.apps.filter { running.contains($0.bundle) }
        guard !candidates.isEmpty else { if track != nil { clear() }; return }
        busy = true
        ScriptThread.shared.async {
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
                    : "set dur to (duration of t)\n  set shuf to (shuffle enabled as text)\n  set tid to \"\""
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
                let t = Track(id: Self.trackID(app: a.name, spotifyID: f[7], name: f[1], artist: f[2], album: f[3]), title: f[1], artist: f[2], album: f[3],
                              duration: num(f[4]), app: a.name)
                if found == nil || playing { found = (t, playing, num(f[5]), f[6].lowercased() == "true") }
                if playing { break }
            }
            DispatchQueue.main.async {
                self.busy = false
                // Nothing from the scripts: stopped, or scripting refused (then what the apps announced stays).
                guard let (t, playing, pos, shuffle) = found else { if !self.denied { self.clear() }; return }
                self.position = pos; self.fetched = Date()
                if self.playing != playing { self.playing = playing }
                if self.shuffle != shuffle { self.shuffle = shuffle }
                if self.track?.id != t.id { self.track = t; self.trackChanged(t) }
                else if self.track != t { self.track = t }
            }
        }
    }

    /// The cover, made small (it is drawn at 128 pt; Music's can be 3000 px, ~36 MB once decoded). Spotify's is a web address:
    /// fetched with a timeout, off the script thread.
    private func loadArtwork(_ t: Track) {
        ScriptThread.shared.async {
            if t.app == "Spotify" {
                guard let u = self.script("tell application \"Spotify\" to return artwork url of current track"), let url = URL(string: u),
                      url.scheme == "https" else { return }
                URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 8)) { data, _, _ in
                    let image = data.flatMap(Self.small)
                    DispatchQueue.main.async { if self.track?.id == t.id { self.artwork = image } }
                }.resume()
            } else {
                var err: NSDictionary?
                let r = NSAppleScript(source: "tell application \"Music\" to return raw data of artwork 1 of current track")?.executeAndReturnError(&err)
                let image = r.map { $0.data }.flatMap { $0.count > 100 ? Self.small($0) : nil }
                DispatchQueue.main.async { if self.track?.id == t.id { self.artwork = image } }
            }
        }
    }

    static func small(_ data: Data) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: lyrics

    /// lrclib.net: the exact match first (title, artist, album, length); when it has none, a search by title and artist. A network
    /// problem is said as such, not as "no lyrics".
    private func loadLyrics(_ t: Track) {
        guard lyricsFor != t.id else { return }
        lyricsFor = t.id
        lyricsState = .loading
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [URLQueryItem(name: "artist_name", value: t.artist), URLQueryItem(name: "track_name", value: t.title),
                          URLQueryItem(name: "album_name", value: t.album), URLQueryItem(name: "duration", value: String(Int(t.duration.rounded())))]
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: t.title), URLQueryItem(name: "artist_name", value: t.artist)]
        guard let g = get.url, let s = search.url else { return }
        Self.fetch(g) { [weak self] json, failed in
            if let synced = (json as? [String: Any])?["syncedLyrics"] as? String, !synced.isEmpty { self?.setLyrics(Self.parse(synced), for: t); return }
            if failed { self?.lyricsDone(.failed, for: t); return }
            Self.fetch(s) { json, failed in
                let hits = (json as? [[String: Any]]) ?? []
                let best = hits.filter { ($0["syncedLyrics"] as? String)?.isEmpty == false }
                    .min { abs(($0["duration"] as? Double ?? 0) - t.duration) < abs(($1["duration"] as? Double ?? 0) - t.duration) }
                if let synced = best?["syncedLyrics"] as? String { self?.setLyrics(Self.parse(synced), for: t) }
                else { self?.lyricsDone(failed ? .failed : .notFound, for: t) }
            }
        }
    }

    /// JSON from lrclib (nil when there is none), and whether it failed (no answer, or a server error) rather than found nothing.
    private static func fetch(_ url: URL, _ done: @escaping (Any?, Bool) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Cocaine (github.com/Mattiakart/cocaine)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            done(code == 200 ? json : nil, error != nil || code == 0 || code >= 500)
        }.resume()
    }

    static func parse(_ synced: String) -> [Line] {
        let re = try? NSRegularExpression(pattern: #"^\[(\d+):(\d+(?:\.\d+)?)\]\s*(.*)$"#)
        return synced.components(separatedBy: "\n").compactMap { l in
            guard let m = re?.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let a = Range(m.range(at: 1), in: l), let b = Range(m.range(at: 2), in: l),
                  let c = Range(m.range(at: 3), in: l), let min = Double(l[a]), let sec = Double(l[b]) else { return nil }
            return Line(time: min * 60 + sec, text: String(l[c]))
        }
    }

    private func setLyrics(_ lines: [Line], for t: Track) {
        DispatchQueue.main.async { if self.track?.id == t.id { self.lyrics = lines; self.lyricsState = lines.isEmpty ? .notFound : .found } }
    }

    private func lyricsDone(_ s: LyricsState, for t: Track) {
        DispatchQueue.main.async {
            guard self.track?.id == t.id else { return }
            self.lyricsState = s
            if s == .failed { self.lyricsFor = "" }               // try again next time the track comes up
        }
    }

    /// What the lyrics line says when there is no line to show.
    var lyricsNote: String {
        switch lyricsState {
        case .loading: return "♪"
        case .failed: return L("Couldn't reach lrclib.net for the lyrics")
        case .notFound: return L("No synced lyrics found")
        case .idle, .found: return lyrics.isEmpty ? "" : "♪"
        }
    }

    // transport
    func playPause() { Haptic.tap(.generic); run("playpause") }
    func next() { Haptic.tap(.alignment); run("next track") }
    func previous() { Haptic.tap(.alignment); run("previous track") }
    func seek(_ seconds: Double) { Haptic.tap(.alignment); position = seconds; fetched = Date(); run("set player position to \(Int(seconds))") }
    func toggleShuffle() { run(track?.app == "Spotify" ? "set shuffling to not shuffling" : "set shuffle enabled to not shuffle enabled"); shuffle.toggle() }
    private func run(_ command: String) {
        guard let app = track?.app else { return }
        ScriptThread.shared.async { _ = self.script("tell application \"\(app)\" to \(command)") }
        if command == "playpause" { position = now; fetched = Date(); playing.toggle() }
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
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                if let t = mu.track {
                    Text(t.title).font(UI.pageTitle).lineLimit(1)
                    Text(t.artist + (t.album.isEmpty ? "" : " — " + t.album)).font(UI.value).foregroundStyle(UI.secondary).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        VStack(spacing: 0) {
                            Scrubber(value: mu.now, total: max(1, t.duration)) { mu.seek($0) }
                            HStack { Text(Self.clock(mu.now)); Spacer(); Text("-" + Self.clock(max(0, t.duration - mu.now))) }
                                .font(UI.detail.monospacedDigit()).foregroundStyle(UI.hint)
                                .accessibilityHidden(true)
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
                        Text(mu.currentLine ?? (mu.lyricsOn ? mu.lyricsNote : ""))
                            .font(UI.groupTitle).foregroundStyle(mu.lyricsState == .failed && mu.currentLine == nil ? warningColor : Island.accent).lineLimit(1)
                    }
                } else {
                    Text(mu.denied ? L("Allow Cocaine to control Music and Spotify in System Settings → Privacy & Security → Automation") : L("Play something in Music or Spotify"))
                        .font(UI.value).foregroundStyle(UI.hint).fixedSize(horizontal: false, vertical: true)
                    if mu.denied {
                        Button(L("Open Settings")) { Permissions.openPane(.automation) }
                            .buttonStyle(CocaineButtonStyle(kind: .primary, height: CTL.hDialog))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { mu.pageVisible = true }
        .onDisappear { mu.pageVisible = false }
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

/// Four bars that dance while music plays (a little, not a spectrum). With Reduce Motion they stand still.
struct Visualizer: View {
    let playing: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(Island.accent).frame(width: 2.5, height: playing ? 5 + 9 * abs(sin(t * (3 + Double(i) * 1.3) + Double(i))) : 4 + CGFloat(i % 2) * 4)
                }
            }
            .frame(height: 16)
        }
        .accessibilityLabel(L("Music playing"))
    }
}

// MARK: - Tests (part of --selftest)

enum MusicTests {
    static func run(_ check: (String, Bool) -> Void) {
        let m = MusicWatch()
        m.announced(app: "Spotify", ["Player State": "Playing", "Name": "Song", "Artist": "A", "Album": "B", "Duration": 200_000,
                                     "Playback Position": 12.5, "Track ID": "spotify:track:1"])
        check("music: Spotify's announcement sets the track, playing and position, with no script",
              m.track?.title == "Song" && m.track?.duration == 200 && m.playing && abs(m.now - 12.5) < 1)
        m.announced(app: "Music", ["Player State": "Paused", "Name": "Other", "Artist": "C", "Album": "D", "Total Time": 100_000, "PersistentID": 7])
        check("music: another app pausing doesn't take over the one playing", m.track?.title == "Song" && m.playing)
        m.announced(app: "Spotify", ["Player State": "Paused", "Name": "Song", "Artist": "A", "Album": "B", "Duration": 200_000,
                                     "Playback Position": 20.0, "Track ID": "spotify:track:1"])
        check("music: a pause is seen (the visualizer stops)", !m.playing && m.track?.title == "Song" && abs(m.now - 20) < 0.5)
        m.announced(app: "Spotify", ["Player State": "Stopped"])
        check("music: stopped clears the track", m.track == nil && !m.playing)
        check("lyrics: synced lines parsed", MusicWatch.parse("[00:12.50] Hello\n[01:02] World\nnot a line").map(\.time) == [12.5, 62])
        if let png = Assets.png(1200, 1200, { r in NSColor.red.setFill(); r.fill() }) as Data?, let img = MusicWatch.small(png) {
            check("music: artwork is made small (\(Int(img.size.width)) px, from 1200)", img.size.width <= 256)
        }
    }
}
