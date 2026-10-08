// The island's Music page: what Music, Spotify or YouTube Music (Pear Desktop) is playing (MusicWatch), a switcher when several
// have a track, lyrics, the scrubber, skip back/forward, favourite/like, the player's own volume and the visualizer. The players'
// pure parts and Pear's client are in MusicPlayers.swift.

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


/// Apple Music, Spotify and YouTube Music (through Pear Desktop). What Music and Spotify play comes from their own
/// announcements (distributed notifications: no Apple events, no polling, the closed island's visualizer follows play and
/// pause); their scripting is used once per track (artwork, Music's position) and every second only while the Music page is
/// on screen (the scrubber, favourite, volume). Pear Desktop announces nothing: once the user connected it, its local API is
/// asked every 3 s while it is open (every second while the page shows). Each player's state is kept apart (`states`);
/// MusicSources.choose picks the one shown, and the user can pick another when several have a track. Lyrics (only if switched
/// on): synced lyrics looked up on lrclib.net by title and artist.
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
    /// The players that have a track now (the switcher shows when there are two or more), the one the user picked, and the
    /// shown player's favourite and own volume (nil: unknown, or it has none).
    @Published private(set) var sources: [String] = []
    @Published private(set) var pinned: String?
    @Published private(set) var liked: Bool?
    @Published private(set) var volume: Int?
    @Published private(set) var pearRunning = false
    private(set) var states: [String: PlayerSnapshot] = [:]
    private(set) var position = 0.0
    private(set) var fetched = Date()
    private var timer: Timer?
    private var pearTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var busy = false
    private var pearBusy = false
    private var lyricsFor = ""
    private var compiled: [String: NSAppleScript] = [:]          // on the script thread only
    private var volumeWork: DispatchWorkItem?

    /// Pear Desktop's client (the Keychain holds its token; memory under test and render flags).
    let pear: PearClient
    /// Tests: where commands go instead of the players (app, command).
    var commandSink: ((String, PlayerCommand) -> Void)?
    /// The running apps' bundle ids (tests hand in their own).
    var running: () -> Set<String> = { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
    /// Tests and renders: false, so no script is ever sent to the real Music or Spotify (and their states stay as set).
    var scriptsEnabled = true
    /// The island's watch, for the settings card (nil while the island is off).
    static weak var current: MusicWatch?

    init(pear: PearClient? = nil) {
        let port = AppDefaults.store.integer(forKey: "musicPearPort")
        self.pear = pear ?? PearClient(port: (1024...65535).contains(port) ? port : PearAPI.defaultPort,
                                       secrets: AppDefaults.isolated ? MemorySecretStore() : KeychainSecretStore(service: "local.cocaine.media"))
    }

    private static let scripted = [PlayerApp.music, PlayerApp.spotify]

    // MARK: settings

    /// The user turned the YouTube Music connection on (Settings, or Connect on the page). Nothing is sent to Pear before.
    var pearEnabled: Bool { AppDefaults.store.bool(forKey: "musicPear") }
    var skipSeconds: Int { MusicSources.skipSeconds(AppDefaults.store.integer(forKey: "musicSkip")) }

    func setPear(_ on: Bool) {
        AppDefaults.store.set(on, forKey: "musicPear")
        if on { pear.setStatus(.needsAuth); applyPearTimer(); pollPear() }
        else { pear.setStatus(.off); applyPearTimer(); update(PlayerApp.pear, nil) }
        objectWillChange.send()
    }

    func setPearPort(_ p: Int) {
        guard (1024...65535).contains(p) else { return }
        AppDefaults.store.set(p, forKey: "musicPearPort")
        pear.port = p
        if pearEnabled { pollPear() }
    }

    func setSkipSeconds(_ s: Int) { AppDefaults.store.set(MusicSources.skipSeconds(s), forKey: "musicSkip"); objectWillChange.send() }

    /// Connect: turns the connection on and asks Pear for a token (Pear shows its own Allow/Deny dialog).
    func connectPear() {
        if !pearEnabled { AppDefaults.store.set(true, forKey: "musicPear"); applyPearTimer() }
        pear.authorize { [weak self] s in if s == .ready { self?.pollPear() } }
    }

    func disconnectPear() { pear.forget(); setPear(false) }

    /// The Music page is on screen: its scrubber, shuffle, favourite and volume are kept current (one script a second).
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
        Self.current = self
        let dnc = DistributedNotificationCenter.default()
        observers.append((dnc, dnc.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
            self?.announced(app: PlayerApp.music, n.userInfo)
        }))
        observers.append((dnc, dnc.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            self?.announced(app: PlayerApp.spotify, n.userInfo)
        }))
        let ws = NSWorkspace.shared.notificationCenter
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard let self, let id, let app = PlayerApp.all.first(where: { PlayerApp.bundles[$0]?.contains(id) == true }) else { return }
            self.update(app, nil)                                          // the app playing it quit
            if app == PlayerApp.pear { self.pearRunning = false; if self.pearEnabled { self.pear.setStatus(.notRunning) } }
        }))
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard let self, let id, PlayerApp.bundles[PlayerApp.pear]?.contains(id) == true else { return }
            self.pearRunning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.pollPear() }   // its plugin starts a moment later
        }))
        pearRunning = PlayerApp.isRunning(PlayerApp.pear, running: running())
        applyPearTimer()
        poll()                                                            // once: what already plays
    }

    func stop() {
        for (c, o) in observers { c.removeObserver(o) }
        observers = []
        pageVisible = false
        pearTimer?.invalidate(); pearTimer = nil
        states = [:]; pinned = nil
        recompute()
    }

    private func applyPearTimer() {
        pearTimer?.invalidate(); pearTimer = nil
        guard pearEnabled, !observers.isEmpty else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in if self?.pageVisible == false { self?.pollPear() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        pearTimer = t
    }

    private func clearShown() {
        if track != nil { track = nil }
        if playing { playing = false }
        if liked != nil { liked = nil }
        if volume != nil { volume = nil }
        artwork = nil; lyrics = []; lyricsState = .idle; lyricsFor = ""
    }

    /// Where the song is now, in seconds (the last known value, carried on by the clock).
    var now: Double { min(track?.duration ?? 0, position + (playing ? Date().timeIntervalSince(fetched) : 0)) }

    /// What the shown player can do.
    var caps: PlayerCaps { PlayerCaps.of(track?.app ?? "") }

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
        let t = Track(id: "x", title: title, artist: artist, album: album, duration: 200, app: PlayerApp.music)
        scriptsEnabled = false
        states = [PlayerApp.music: PlayerSnapshot(track: t, playing: true, position: 74, at: Date(), shuffle: false, liked: true, volume: 70)]
        recompute()
        lyricsOn = true
        lyrics = [Line(time: 70, text: "I'm running out of time")]; lyricsState = .found
    }

    /// Renders: a second player with a track (the switcher shows).
    func addSampleSource(_ app: String, title: String, artist: String) {
        let t = Track(id: app + title, title: title, artist: artist, album: "", duration: 180, app: app)
        states[app] = PlayerSnapshot(track: t, playing: false, position: 30, at: Date(), liked: app == PlayerApp.spotify ? nil : false, volume: 55)
        recompute()
    }

    // MARK: the players' states

    /// One player's state changed (nil: it has no track any more); the shown player and the published values follow.
    func update(_ app: String, _ s: PlayerSnapshot?) {
        states[app] = s
        recompute()
    }

    private func recompute() {
        let avail = MusicSources.available(states)
        if sources != avail { sources = avail }
        if let p = pinned, states[p] == nil { pinned = nil }
        guard let pick = MusicSources.choose(current: track?.app, pinned: pinned, states: states), let s = states[pick] else { clearShown(); return }
        position = s.position; fetched = s.at
        if playing != s.playing { playing = s.playing }
        if let sh = s.shuffle, shuffle != sh { shuffle = sh }
        if liked != s.liked { liked = s.liked }
        if volume != s.volume { volume = s.volume }
        if track?.id != s.track.id { track = s.track; trackChanged(s.track) }
        else if track != s.track { track = s.track }
    }

    /// The user picks the player shown (the switcher).
    func pick(_ app: String) {
        guard states[app] != nil else { return }
        Haptic.tap(.alignment)
        pinned = app
        recompute()
    }

    // MARK: what the apps announce

    /// Music: "Player State", "Name", "Artist", "Album", "Total Time" (ms), "PersistentID". Spotify: the same names but
    /// "Duration" (ms), "Playback Position" (s) and "Track ID".
    func announced(app: String, _ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let state = (info["Player State"] as? String ?? "").lowercased()
        if state == "stopped" { update(app, nil); return }
        let prev = states[app]
        let nowPlaying = state == "playing"
        let ms = (info["Total Time"] as? NSNumber ?? info["Duration"] as? NSNumber)?.doubleValue ?? (prev?.track.duration ?? 0) * 1000
        let name = info["Name"] as? String ?? "", artist = info["Artist"] as? String ?? "", album = info["Album"] as? String ?? ""
        let id = Self.trackID(app: app, spotifyID: info["Track ID"] as? String, name: name, artist: artist, album: album)
        let t = Track(id: id, title: name, artist: artist, album: album, duration: ms / 1000, app: app)
        let at = Date()
        var pos = 0.0
        if let p = (info["Playback Position"] as? NSNumber)?.doubleValue { pos = p }
        else if let prev, prev.track.id == id { pos = prev.position + (prev.playing ? at.timeIntervalSince(prev.at) : 0) }
        var s = PlayerSnapshot(track: t, playing: nowPlaying, position: pos, at: at)
        if let prev {
            s.shuffle = prev.shuffle; s.volume = prev.volume
            if prev.track.id == id { s.liked = prev.liked }
        }
        update(app, s)
        if app == PlayerApp.music { poll() }                                 // Music doesn't say where it is: one script
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

    /// Runs a script on the script thread; nil when it failed. Only the fixed poll scripts are kept compiled.
    private func script(_ source: String, keep: Bool = false) -> String? {
        let s: NSAppleScript? = compiled[source] ?? {
            let n = NSAppleScript(source: source)
            if keep, let n { compiled[source] = n }
            return n
        }()
        var err: NSDictionary?
        let r = s?.executeAndReturnError(&err)
        let refused = (err?[NSAppleScript.errorNumber] as? Int) == -1743
        if refused || (err == nil && denied) { DispatchQueue.main.async { if self.denied != refused { self.denied = refused } } }   // allowed later: back
        return err == nil ? (r?.stringValue ?? "") : nil
    }

    private var askedAutomation = Set<String>()

    private func poll() {
        pollPear()
        guard !busy, scriptsEnabled else { return }           // tests and renders: the players' states are their own
        let run = running()
        for a in Self.scripted where !PlayerApp.isRunning(a, running: run) && states[a] != nil { update(a, nil) }
        let candidates = Self.scripted.filter { PlayerApp.isRunning($0, running: run) }
        guard !candidates.isEmpty else { return }
        busy = true
        ScriptThread.shared.async {
            var found: [(String, PlayerSnapshot?)] = []
            for a in candidates {
                guard let bundle = PlayerApp.bundles[a]?.first else { continue }
                if !self.askedAutomation.contains(bundle) {                          // the first time this app is seen running: check, and ask if needed
                    self.askedAutomation.insert(bundle)
                    if Permissions.automation(bundle, ask: false) == -1744 {         // never asked: the question, in front
                        DispatchQueue.main.sync { NSApp.activate() }
                        _ = Permissions.automation(bundle, ask: true)
                    }
                }
                guard let out = self.script(PlayerScripts.poll(app: a), keep: true) else { continue }   // refused or failed: what it announced stays
                found.append((a, out.isEmpty ? nil : PlayerScripts.parsePoll(out, app: a)))
            }
            DispatchQueue.main.async {
                self.busy = false
                for (a, s) in found {
                    guard var s else { self.update(a, nil); continue }
                    if s.liked == nil, let prev = self.states[a], prev.track.id == s.track.id { s.liked = prev.liked }
                    self.update(a, s)
                }
            }
        }
    }

    /// Pear Desktop: its song (and, while the page shows or a new song starts, its like and volume). Only once connected.
    private func pollPear() {
        guard pearEnabled else { return }
        let isRunning = PlayerApp.isRunning(PlayerApp.pear, running: running())
        if pearRunning != isRunning { pearRunning = isRunning }
        guard isRunning else { pear.setStatus(.notRunning); if states[PlayerApp.pear] != nil { update(PlayerApp.pear, nil) }; return }
        guard !pearBusy, pear.status != .asking, pear.status != .denied else { return }
        if pear.status == .notRunning || pear.status == .off { pear.setStatus(.needsAuth) }
        pearBusy = true
        pear.call("GET", PearAPI.path("song")) { [weak self] r in
            guard let self else { return }
            self.pearBusy = false
            guard r.status == 200, let d = r.data, let song = PearAPI.parseSong(d) else {
                if self.states[PlayerApp.pear] != nil { self.update(PlayerApp.pear, nil) }
                return
            }
            var s = PearAPI.snapshot(song)
            let prev = self.states[PlayerApp.pear]
            let same = prev?.track.id == s.track.id
            s.liked = same ? prev?.liked : nil
            s.volume = prev?.volume; s.shuffle = prev?.shuffle
            self.update(PlayerApp.pear, s)
            if !same || self.pageVisible { self.pearDetails() }
        }
    }

    private func pearDetails() {
        pear.call("GET", PearAPI.path("like-state")) { [weak self] r in
            guard let self, r.status == 200, let v = r.data.flatMap(PearAPI.parseLike), var s = self.states[PlayerApp.pear], s.liked != v else { return }
            s.liked = v; self.update(PlayerApp.pear, s)
        }
        pear.call("GET", PearAPI.path("volume")) { [weak self] r in
            guard let self, r.status == 200, let v = r.data.flatMap(PearAPI.parseVolume), var s = self.states[PlayerApp.pear], s.volume != v,
                  self.volumeWork == nil else { return }
            s.volume = v; self.update(PlayerApp.pear, s)
        }
    }

    /// The cover, made small (it is drawn at 128 pt; Music's can be 3000 px, ~36 MB once decoded). Spotify's and YouTube
    /// Music's are web addresses: fetched over https with a timeout, off the script thread.
    private func loadArtwork(_ t: Track) {
        if t.app == PlayerApp.pear {
            if let u = states[PlayerApp.pear]?.artworkURL.flatMap(URL.init(string:)) { fetchArtwork(u, for: t) }
            return
        }
        guard Self.scripted.contains(t.app), commandSink == nil else { return }
        ScriptThread.shared.async {
            if t.app == PlayerApp.spotify {
                guard let u = self.script("tell application \"Spotify\" to return artwork url of current track"), let url = URL(string: u) else { return }
                self.fetchArtwork(url, for: t)
            } else {
                var err: NSDictionary?
                let r = NSAppleScript(source: "tell application \"Music\" to return raw data of artwork 1 of current track")?.executeAndReturnError(&err)
                let image = r.map { $0.data }.flatMap { $0.count > 100 ? Self.small($0) : nil }
                DispatchQueue.main.async { if self.track?.id == t.id { self.artwork = image } }
            }
        }
    }

    private func fetchArtwork(_ url: URL, for t: Track) {
        guard url.scheme == "https" else { return }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 8)) { data, _, _ in
            let image = data.flatMap { $0.count < 20 << 20 ? Self.small($0) : nil }
            DispatchQueue.main.async { if self.track?.id == t.id { self.artwork = image } }
        }.resume()
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

    // MARK: transport (to the shown player)

    func playPause() {
        Haptic.tap(.generic); command(.playPause)
        changeShown { s in s.position = self.now; s.at = Date(); s.playing.toggle() }
    }
    func next() { Haptic.tap(.alignment); command(.next) }
    func previous() { Haptic.tap(.alignment); command(.previous) }
    func seek(_ seconds: Double) {
        Haptic.tap(.alignment); command(.seek(seconds))
        changeShown { s in s.position = seconds; s.at = Date() }
    }
    /// Jumps the chosen number of seconds forward or back (Settings: 5, 10, 15 or 30).
    func skip(forward: Bool) {
        guard let t = track else { return }
        Haptic.tap(.alignment)
        let d = Double(skipSeconds) * (forward ? 1 : -1)
        let target = MusicSources.skipTarget(now: now, by: d, duration: t.duration)
        command(t.app == PlayerApp.pear ? .skip(d) : .seek(target))           // Pear has its own go-forward/go-back
        changeShown { s in s.position = target; s.at = Date() }
    }
    func toggleShuffle() {
        command(.shuffle(!shuffle))
        let on = !shuffle
        changeShown { s in s.shuffle = on }
        shuffle = on
    }
    /// Favourite (Apple Music) or like (YouTube Music). Spotify doesn't let other apps save a song.
    func toggleLike() {
        guard caps.like else { return }
        Haptic.tap(.generic)
        let on = !(liked ?? false)
        command(.like(on))
        changeShown { s in s.liked = on }
    }
    /// The shown player's own volume (0…100), sent at most every 0.12 s while a slider moves.
    func setVolume(_ v: Int) {
        guard caps.volume, let app = track?.app else { return }
        let v = PlayerScripts.clampVolume(v)
        changeShown { s in s.volume = v }
        volumeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.volumeWork = nil; self?.deliver(app, .volume(v)) }
        volumeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func changeShown(_ body: (inout PlayerSnapshot) -> Void) {
        guard let app = track?.app, var s = states[app] else { return }
        body(&s)
        update(app, s)
    }

    private func command(_ c: PlayerCommand) {
        guard let app = track?.app else { return }
        deliver(app, c)
    }

    private func deliver(_ app: String, _ c: PlayerCommand) {
        if let sink = commandSink { sink(app, c); return }
        if app == PlayerApp.pear { pear.send(c); return }
        guard let src = PlayerScripts.script(c, app: app) else { return }
        ScriptThread.shared.async { _ = self.script(src) }
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
            .id(mu.track?.id ?? "")                                              // another track: the artwork cross-fades
            .transition(.opacity)
            .animation(Motion.animation(.crossfade), value: mu.track?.id)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                if let t = mu.track {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text(t.title).font(UI.pageTitle).lineLimit(1)
                        Spacer(minLength: 0)
                        if mu.sources.count >= 2 { MusicSourceSwitcher(music: mu) }
                    }
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
                    let step = mu.skipSeconds
                    HStack(spacing: 8) {
                        transport("shuffle", L("Shuffle"), on: mu.shuffle) { mu.toggleShuffle() }
                        transport("backward.fill", L("Previous track")) { mu.previous() }
                        transport(MusicSources.skipSymbol(step, forward: false), String(format: L("Back %d seconds"), step)) { mu.skip(forward: false) }
                        transport(mu.playing ? "pause.fill" : "play.fill", mu.playing ? L("Pause") : L("Play"), size: 20) { mu.playPause() }
                        transport(MusicSources.skipSymbol(step, forward: true), String(format: L("Forward %d seconds"), step)) { mu.skip(forward: true) }
                        transport("forward.fill", L("Next track")) { mu.next() }
                        Spacer(minLength: 0)
                        if mu.caps.like {
                            let on = mu.liked == true
                            transport(on ? "heart.fill" : "heart", t.app == PlayerApp.pear ? (on ? L("Remove the like") : L("Like"))
                                                                                            : (on ? L("Remove from Favourites") : L("Add to Favourites")), on: on) { mu.toggleLike() }
                        }
                        transport("quote.bubble", mu.lyricsOn ? L("Hide lyrics") : L("Show lyrics (looks up the title and artist on lrclib.net)"), on: mu.lyricsOn) { mu.setLyrics(!mu.lyricsOn) }
                    }
                    HStack(spacing: Space.s) {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            let line = mu.currentLine ?? (mu.lyricsOn ? mu.lyricsNote : "")
                            // Each new line cross-fades into the next; looking the lyrics up: a calm light passes over the note.
                            Text(line)
                                .font(UI.groupTitle).foregroundStyle(mu.lyricsState == .failed && mu.currentLine == nil ? warningColor : Island.accent).lineLimit(1)
                                .contentTransition(.opacity)
                                .animation(Motion.animation(.crossfade), value: line)
                                .shimmer(mu.lyricsOn && mu.lyricsState == .loading && mu.currentLine == nil)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if mu.caps.volume, let v = mu.volume {
                            // The player's own volume (not the Mac's): Music, Spotify and YouTube Music each have one.
                            Image(systemName: v == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill").font(.system(size: 11)).foregroundStyle(UI.secondary)
                                .frame(width: 14).accessibilityHidden(true)                       // a glyph
                            CocaineSlider(value: Double(v), range: 0...100, step: 5, name: String(format: L("%@ volume"), PlayerApp.title(t.app)),
                                          valueText: "\(v)%") { mu.setVolume(Int($0.rounded())) }
                                .frame(width: 84)
                        }
                    }
                } else {
                    Text(mu.denied ? L("Allow Cocaine to control Music and Spotify in System Settings → Privacy & Security → Automation") : L("Play something in Music, Spotify or YouTube Music"))
                        .font(UI.value).foregroundStyle(UI.hint).fixedSize(horizontal: false, vertical: true)
                    if mu.denied {
                        Button(L("Open Settings")) { Permissions.openPane(.automation) }
                            .buttonStyle(CocaineButtonStyle(kind: .primary, height: CTL.hDialog))
                    }
                    PearPrompt(music: mu, pear: mu.pear)
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
                .contentTransition(.symbolEffect(.replace))                      // play ↔ pause: one glyph turns into the other
                .animation(Motion.animation(.hudSwap), value: symbol)
                .animation(Motion.animation(.hover), value: on)
                .frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle()).help(title).accessibilityLabel(title)
        .accessibilityAddTraits(on == true ? .isSelected : [])
    }

}

/// The players that have a track, as small chips: the shown one highlighted; a click shows another.
struct MusicSourceSwitcher: View {
    @ObservedObject var music: MusicWatch
    var body: some View {
        HStack(spacing: 4) {
            ForEach(music.sources, id: \.self) { app in
                let on = music.track?.app == app
                Button { Motion.with(.selection) { music.pick(app) } } label: {
                    Text(PlayerApp.title(app)).font(UI.detail.weight(on ? .semibold : .regular)).lineLimit(1).fixedSize()
                        .foregroundStyle(on ? Color.white : UI.secondary)
                        .padding(.horizontal, 7).frame(height: 18)
                        .background(Capsule().fill(Color.white.opacity(on ? 0.16 : 0.05)))
                        .contentShape(Capsule())
                        .motionSelection(on)
                }
                .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScale))
                .help(String(format: L("Show %@"), PlayerApp.title(app)))
                .accessibilityLabel(PlayerApp.title(app))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Player"))
    }
}

/// YouTube Music through Pear Desktop, on the empty Music page: what to do to control it (nothing is sent before Connect).
struct PearPrompt: View {
    @ObservedObject var music: MusicWatch
    @ObservedObject var pear: PearClient
    var body: some View {
        if music.pearRunning || (music.pearEnabled && pear.status != .ready && pear.status != .notRunning && pear.status != .off) {
            let note = PearPrompt.note(enabled: music.pearEnabled, status: pear.status)
            VStack(alignment: .leading, spacing: Space.s) {
                if let note { Text(note).font(UI.detail).foregroundStyle(pear.status == .denied || pear.status == .unreachable ? warningColor : UI.secondary)
                    .fixedSize(horizontal: false, vertical: true) }
                if !music.pearEnabled || pear.status == .needsAuth || pear.status == .denied || pear.status == .unreachable {
                    Button(L("Connect YouTube Music")) { music.connectPear() }
                        .buttonStyle(CocaineButtonStyle(kind: .primary, height: CTL.hDialog))
                } else if pear.status == .asking {
                    HStack(spacing: Space.s) { BusyDots(color: Island.accent); Text(L("Answer in Pear Desktop")).font(UI.detail).foregroundStyle(UI.secondary) }
                }
            }
        }
    }

    /// What the page and the settings say about the connection.
    static func note(enabled: Bool, status: PearClient.Status) -> String? {
        guard enabled else { return L("YouTube Music is open in Pear Desktop. Connect to control it here (Pear asks you to allow it).") }
        switch status {
        case .off, .ready: return nil
        case .notRunning: return L("Pear Desktop isn't open")
        case .unreachable: return L("Pear Desktop doesn't answer: turn on its API Server plugin (Plugins → API Server) and check the port")
        case .needsAuth: return L("Pear Desktop asks for permission: Connect, then allow Cocaine in Pear")
        case .asking: return L("Answer in Pear Desktop")
        case .denied: return L("Pear Desktop refused the connection. Connect to ask again.")
        }
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
        let m = MusicWatch(pear: PearClient(transport: { _, done in done(PearClient.Reply(status: 0, data: nil)) }, secrets: MemorySecretStore()))
        m.commandSink = { _, _ in }
        m.scriptsEnabled = false
        m.running = { ["com.apple.Music", "com.spotify.client"] }
        m.announced(app: "Spotify", ["Player State": "Playing", "Name": "Song", "Artist": "A", "Album": "B", "Duration": 200_000,
                                     "Playback Position": 12.5, "Track ID": "spotify:track:1"])
        check("music: Spotify's announcement sets the track, playing and position, with no script",
              m.track?.title == "Song" && m.track?.duration == 200 && m.playing && abs(m.now - 12.5) < 1)
        m.announced(app: "Music", ["Player State": "Paused", "Name": "Other", "Artist": "C", "Album": "D", "Total Time": 100_000, "PersistentID": 7])
        check("music: another app pausing doesn't take over the one playing", m.track?.title == "Song" && m.playing && m.sources == ["Music", "Spotify"])
        m.announced(app: "Spotify", ["Player State": "Paused", "Name": "Song", "Artist": "A", "Album": "B", "Duration": 200_000,
                                     "Playback Position": 20.0, "Track ID": "spotify:track:1"])
        check("music: a pause is seen (the visualizer stops)", !m.playing && m.track?.title == "Song" && abs(m.now - 20) < 0.5)
        m.announced(app: "Spotify", ["Player State": "Stopped"])
        check("music: stopped drops that player; the paused one left is shown", m.track?.title == "Other" && !m.playing && m.sources == ["Music"])
        m.announced(app: "Music", ["Player State": "Stopped"])
        check("music: the last player stopping clears the track", m.track == nil && !m.playing && m.sources.isEmpty)
        check("lyrics: synced lines parsed", MusicWatch.parse("[00:12.50] Hello\n[01:02] World\nnot a line").map(\.time) == [12.5, 62])
        if let png = Assets.png(1200, 1200, { r in NSColor.red.setFill(); r.fill() }) as Data?, let img = MusicWatch.small(png) {
            check("music: artwork is made small (\(Int(img.size.width)) px, from 1200)", img.size.width <= 256)
        }
    }
}
