// The players the island's Music page controls, as pure parts plus one HTTP client: which player is shown when several have a
// track (MusicSources), what each one can do (PlayerCaps), a command as AppleScript for Music and Spotify or as a request
// for YouTube Music through Pear Desktop's API Server plugin (PlayerScripts, PearAPI), and that client (PearClient: loopback
// only, short timeouts, the plugin's own consent flow, the token in the Keychain). MusicWatch (IslandMusic.swift) drives them;
// --media-test runs everything here on fakes (no player, no network).
//
// Pear Desktop (github.com/th-ch/youtube-music, formerly "YouTube Music"): its API Server plugin serves a REST API, by default
// on port 26538. Every /api/v1/… route needs `Authorization: Bearer <JWT>` unless the plugin's auth strategy is NONE; the token
// comes from POST /auth/{clientId}, which shows the user an Allow/Deny dialog in Pear (403 when denied). Not verified live on
// this Mac (Pear Desktop isn't installed here): built from the plugin's source and checked against a fake.

import AppKit
import Foundation

/// The players, in the order they are offered.
enum PlayerApp {
    static let music = "Music", spotify = "Spotify", pear = "YouTube Music"
    static let all = [music, spotify, pear]
    static let bundles: [String: [String]] = [music: ["com.apple.Music"], spotify: ["com.spotify.client"],
                                              pear: ["com.github.th-ch.youtube-music"]]
    /// The player's name as shown (Pear Desktop plays YouTube Music).
    static func title(_ app: String) -> String { app == pear ? "YouTube Music" : app == music ? "Apple Music" : app }
    static func isRunning(_ app: String, running: Set<String>) -> Bool { (bundles[app] ?? []).contains { running.contains($0) } }
}

/// What a player lets another app do. Spotify's scripting has no "save to library"; the others have no dislike here.
struct PlayerCaps: Equatable {
    var like: Bool
    var volume: Bool
    var seek: Bool
    var shuffle: Bool

    static func of(_ app: String) -> PlayerCaps {
        switch app {
        case PlayerApp.music: return PlayerCaps(like: true, volume: true, seek: true, shuffle: true)
        case PlayerApp.spotify: return PlayerCaps(like: false, volume: true, seek: true, shuffle: true)
        case PlayerApp.pear: return PlayerCaps(like: true, volume: true, seek: true, shuffle: true)
        default: return PlayerCaps(like: false, volume: false, seek: false, shuffle: false)
        }
    }
}

/// One thing the user asks a player for.
enum PlayerCommand: Equatable {
    case playPause, next, previous
    case seek(Double)             // to this second
    case skip(Double)             // this many seconds forward (negative: back)
    case shuffle(Bool)
    case like(Bool)               // favourite (Music), like (YouTube Music)
    case volume(Int)              // the player's own volume, 0…100
}

/// What one player has now (from its announcements, its scripting or Pear's API).
struct PlayerSnapshot: Equatable {
    var track: MusicWatch.Track
    var playing: Bool
    var position: Double
    var at: Date
    var shuffle: Bool? = nil
    var liked: Bool? = nil
    var volume: Int? = nil
    var artworkURL: String? = nil
}

enum MusicSources {
    /// The player the page shows: the one the user picked (while it has a track), else the one shown if it still plays, else
    /// the first that plays, else the one shown if it still has a track, else the first with one. Another player pausing
    /// never takes over; a player starting to play does (unless the user picked one).
    static func choose(current: String?, pinned: String?, states: [String: PlayerSnapshot]) -> String? {
        if let p = pinned, states[p] != nil { return p }
        if let c = current, states[c]?.playing == true { return c }
        if let p = PlayerApp.all.first(where: { states[$0]?.playing == true }) { return p }
        if let c = current, states[c] != nil { return c }
        return PlayerApp.all.first { states[$0] != nil }
    }

    /// The players with a track, in order (the switcher shows them when there are two or more).
    static func available(_ states: [String: PlayerSnapshot]) -> [String] { PlayerApp.all.filter { states[$0] != nil } }

    /// Where a skip lands: never before the start, never past the last second.
    static func skipTarget(now: Double, by delta: Double, duration: Double) -> Double {
        let end = duration > 1 ? duration - 1 : max(0, duration)
        return min(end, max(0, now + delta))
    }

    static let skipChoices = [5, 10, 15, 30]
    /// The seconds a skip button jumps (Settings; 15 by default; only the offered values).
    static func skipSeconds(_ raw: Int) -> Int { skipChoices.contains(raw) ? raw : 15 }
    /// An SF Symbol exists for these steps: gobackward.N / goforward.N.
    static func skipSymbol(_ seconds: Int, forward: Bool) -> String { (forward ? "goforward." : "gobackward.") + String(skipSeconds(seconds)) }
}

// MARK: - AppleScript (Music, Spotify)

enum PlayerScripts {
    static func clampVolume(_ v: Int) -> Int { max(0, min(100, v)) }

    /// The script for a command, or nil when this player can't do it (Spotify has no "like"; Pear isn't scripted).
    static func script(_ c: PlayerCommand, app: String) -> String? {
        guard app == PlayerApp.music || app == PlayerApp.spotify else { return nil }
        let spotify = app == PlayerApp.spotify
        let body: String
        switch c {
        case .playPause: body = "playpause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        case .seek(let s): body = "set player position to \(max(0, Int(s.rounded())))"
        case .skip(let d):
            body = "set p to (player position) + (\(Int(d.rounded())))\nif p < 0 then set p to 0\nset player position to p"
        case .shuffle(let on): body = (spotify ? "set shuffling to " : "set shuffle enabled to ") + (on ? "true" : "false")
        case .like(let on):
            guard !spotify else { return nil }
            body = "set favorited of current track to " + (on ? "true" : "false")
        case .volume(let v): body = "set sound volume to \(clampVolume(v))"
        }
        return "tell application \"\(app)\"\n\(body)\nend tell"
    }

    /// Read once a second while the page shows (and once per track): state, title, artist, album, duration (s), position,
    /// shuffle, Spotify's track id, favourite (Music; "" elsewhere or when unknown), the player's volume. Tab-separated.
    static func poll(app: String) -> String {
        let spotify = app == PlayerApp.spotify
        let extra = spotify
            ? "set dur to (duration of t) / 1000\n  set shuf to (shuffling as text)\n  set tid to (id of t)\n  set fav to \"\""
            : "set dur to (duration of t)\n  set shuf to (shuffle enabled as text)\n  set tid to \"\"\n  set fav to \"\"\n  try\n    set fav to (favorited of t as text)\n  end try"
        return """
        tell application "\(app)"
          if player state is stopped then return ""
          set t to current track
          set pstate to (player state as text)
          \(extra)
          set vol to ""
          try
            set vol to (sound volume as text)
          end try
          return pstate & "\\t" & (name of t) & "\\t" & (artist of t) & "\\t" & (album of t) & "\\t" & dur & "\\t" & (player position) & "\\t" & shuf & "\\t" & tid & "\\t" & fav & "\\t" & vol
        end tell
        """
    }

    /// A poll's answer as a snapshot (nil: not a full answer).
    static func parsePoll(_ out: String, app: String, now: Date = Date()) -> PlayerSnapshot? {
        let f = out.components(separatedBy: "\t")
        guard f.count >= 8 else { return nil }
        func num(_ s: String) -> Double { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0 }
        let t = MusicWatch.Track(id: MusicWatch.trackID(app: app, spotifyID: f[7], name: f[1], artist: f[2], album: f[3]), title: f[1], artist: f[2],
                                 album: f[3], duration: num(f[4]), app: app)
        var s = PlayerSnapshot(track: t, playing: f[0].lowercased().contains("play"), position: num(f[5]), at: now, shuffle: f[6].lowercased() == "true")
        if f.count > 8, !f[8].isEmpty { s.liked = f[8].lowercased() == "true" }
        if f.count > 9, let v = Int(f[9].trimmingCharacters(in: .whitespaces)) { s.volume = PlayerScripts.clampVolume(v) }
        return s
    }
}

// MARK: - Pear Desktop's API

enum PearAPI {
    static let version = "v1"
    static let defaultPort = 26538
    static let clientID = "Cocaine"

    struct Request: Equatable {
        var method: String
        var path: String
        var body: [String: Double]?
    }

    static func path(_ route: String) -> String { "/api/\(version)/" + route }

    /// The request for a command (Pear's shuffle and like are toggles: they're sent only to change the state).
    static func request(_ c: PlayerCommand) -> Request {
        switch c {
        case .playPause: return Request(method: "POST", path: path("toggle-play"), body: nil)
        case .next: return Request(method: "POST", path: path("next"), body: nil)
        case .previous: return Request(method: "POST", path: path("previous"), body: nil)
        case .seek(let s): return Request(method: "POST", path: path("seek-to"), body: ["seconds": max(0, s.rounded())])
        case .skip(let d):
            return d >= 0 ? Request(method: "POST", path: path("go-forward"), body: ["seconds": d.rounded()])
                          : Request(method: "POST", path: path("go-back"), body: ["seconds": (-d).rounded()])
        case .shuffle: return Request(method: "POST", path: path("shuffle"), body: nil)
        case .like: return Request(method: "POST", path: path("like"), body: nil)
        case .volume(let v): return Request(method: "POST", path: path("volume"), body: ["volume": Double(PlayerScripts.clampVolume(v))])
        }
    }

    /// The address: always this Mac's loopback (never a name that could resolve elsewhere), a port in the user range.
    static func url(port: Int, path: String) -> URL? {
        guard (1024...65535).contains(port), path.hasPrefix("/"),
              path.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/-_".contains($0)) }) else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    struct Song: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var elapsed: Double
        var paused: Bool
        var imageSrc: String?
        var videoId: String
    }

    /// GET /api/v1/song: { title, artist, album?, songDuration, elapsedSeconds?, isPaused?, imageSrc?, videoId, … }.
    static func parseSong(_ d: Data) -> Song? {
        guard d.count < 1 << 20, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let title = o["title"] as? String, !title.isEmpty else { return nil }
        func n(_ k: String) -> Double { (o[k] as? NSNumber)?.doubleValue ?? 0 }
        return Song(title: String(title.prefix(300)), artist: String((o["artist"] as? String ?? "").prefix(300)),
                    album: String((o["album"] as? String ?? "").prefix(300)), duration: max(0, n("songDuration")),
                    elapsed: max(0, n("elapsedSeconds")), paused: o["isPaused"] as? Bool ?? false,
                    imageSrc: o["imageSrc"] as? String, videoId: o["videoId"] as? String ?? "")
    }

    static func snapshot(_ s: Song, now: Date = Date()) -> PlayerSnapshot {
        let id = PlayerApp.pear + (s.videoId.isEmpty ? s.title + "\u{1}" + s.artist : s.videoId)
        let t = MusicWatch.Track(id: id, title: s.title, artist: s.artist, album: s.album, duration: s.duration, app: PlayerApp.pear)
        return PlayerSnapshot(track: t, playing: !s.paused, position: min(s.elapsed, max(s.duration, s.elapsed)), at: now,
                              artworkURL: s.imageSrc.flatMap { $0.hasPrefix("https://") ? $0 : nil })
    }

    /// GET /api/v1/like-state: { state: "LIKE" | "DISLIKE" | "INDIFFERENT" | null }.
    static func parseLike(_ d: Data) -> Bool? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let s = o["state"] as? String else { return nil }
        return s == "LIKE"
    }

    /// GET /api/v1/volume: { state: 0…100, isMuted }.
    static func parseVolume(_ d: Data) -> Int? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let v = (o["state"] as? NSNumber)?.doubleValue else { return nil }
        if o["isMuted"] as? Bool == true { return 0 }
        return PlayerScripts.clampVolume(Int(v.rounded()))
    }

    /// POST /auth/{id} → { accessToken }.
    static func parseToken(_ d: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let t = o["accessToken"] as? String,
              !t.isEmpty, t.count < 4096, t.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        return t
    }
}

/// Talks to Pear Desktop. Every call has a short timeout (the auth call waits for the user's answer in Pear: up to a minute);
/// nothing is sent until the user turned the connection on; the address is the loopback only.
final class PearClient: ObservableObject {
    enum Status: String, Equatable {
        case off            // the user hasn't turned it on
        case notRunning     // Pear Desktop isn't open
        case unreachable    // open, but its API Server plugin doesn't answer on the port
        case needsAuth      // the plugin wants a token: Connect asks for one
        case asking         // waiting for the user's answer in Pear
        case denied         // the user said no in Pear
        case ready
    }
    struct Reply { var status: Int; var data: Data? }        // status 0: no answer (refused, timed out)
    typealias Transport = (URLRequest, @escaping (Reply) -> Void) -> Void

    @Published private(set) var status = Status.off
    var port: Int
    private(set) var token: String?
    let transport: Transport
    let secrets: ShareSecretStore
    private var loaded = false

    init(port: Int = PearAPI.defaultPort, transport: @escaping Transport = PearClient.urlSession, secrets: ShareSecretStore) {
        self.port = port
        self.transport = transport
        self.secrets = secrets
    }

    func setStatus(_ s: Status) { if status != s { status = s } }

    private func loadToken() {
        guard !loaded else { return }
        loaded = true
        token = (try? secrets.load("pear"))?["token"]
    }

    /// Forget the token (Settings' Disconnect).
    func forget() {
        token = nil; loaded = true
        try? secrets.delete("pear")
    }

    func request(_ method: String, _ path: String, body: [String: Double]? = nil, timeout: TimeInterval = 2) -> URLRequest? {
        guard let url = PearAPI.url(port: port, path: path) else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = method
        r.httpShouldHandleCookies = false
        loadToken()
        if let token { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return r
    }

    /// A call; the status follows what the answer says (no answer: unreachable; 401: a token is needed).
    func call(_ method: String, _ path: String, body: [String: Double]? = nil, _ done: @escaping (Reply) -> Void = { _ in }) {
        guard let r = request(method, path, body: body) else { done(Reply(status: 0, data: nil)); return }
        transport(r) { [weak self] reply in
            DispatchQueue.main.async {
                guard let self else { return }
                switch reply.status {
                case 0: self.setStatus(.unreachable)
                case 401, 403: if self.status != .asking { self.setStatus(self.status == .denied ? .denied : .needsAuth) }
                case 200..<300: self.setStatus(.ready)
                default: break
                }
                done(reply)
            }
        }
    }

    func send(_ c: PlayerCommand) {
        let q = PearAPI.request(c)
        call(q.method, q.path, body: q.body)
    }

    /// Asks Pear for a token: Pear shows its Allow/Deny dialog (unless the plugin needs none). Only on the user's click.
    func authorize(_ done: @escaping (Status) -> Void = { _ in }) {
        guard var r = request("POST", "/auth/" + PearAPI.clientID, timeout: 60) else { done(.unreachable); return }
        r.setValue(nil, forHTTPHeaderField: "Authorization")
        setStatus(.asking)
        transport(r) { [weak self] reply in
            DispatchQueue.main.async {
                guard let self else { return }
                let s: Status
                if reply.status == 200, let t = reply.data.flatMap(PearAPI.parseToken) {
                    self.token = t; self.loaded = true
                    try? self.secrets.save("pear", ["token": t])
                    s = .ready
                } else if reply.status == 403 { s = .denied }
                else if reply.status == 0 { s = .unreachable }
                else { s = .needsAuth }
                self.setStatus(s)
                done(s)
            }
        }
    }

    // MARK: the real transport

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]                  // straight to the loopback, never through a proxy
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static let urlSession: Transport = { req, done in
        guard req.url?.host == "127.0.0.1" else { done(Reply(status: 0, data: nil)); return }
        session.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            done(Reply(status: code, data: data.map { $0.count > 1 << 20 ? Data() : $0 }))
        }.resume()
    }
}
