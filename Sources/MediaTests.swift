// --media-test: the Music page's players (which one is shown, skip, favourite/like, volume, the AppleScript sent to Music and
// Spotify), Pear Desktop's client and API on a fake transport (consent, token, loopback only, timeouts as "no answer"), the
// keyboard backlight's rules on a fake device (the real one is only read, never written), and the shelf's extra group
// operations on a shelf in memory with a private pasteboard. No player, no network, no real backlight, no user data.

import AppKit
import Foundation

enum MediaTests {
    static func run() -> Int {
        _ = NSApplication.shared
        precondition(AppDefaults.isolated, "tests run with memory-only settings (main.swift)")
        var failed = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  media: " + name); if !ok { failed += 1 } }
        sources(check)
        scripts(check)
        pearAPI(check)
        pearClient(check)
        watchCommands(check)
        watchPear(check)
        backlight(check)
        shelf(check)
        print(failed == 0 ? "media: all passed" : "media: \(failed) failed")
        return failed
    }

    /// Runs the main run loop until `done` or the time is up (the fakes answer on the main queue, as the real ones do).
    static func spin(_ seconds: Double = 1, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    static func snap(_ app: String, _ title: String, playing: Bool) -> PlayerSnapshot {
        PlayerSnapshot(track: MusicWatch.Track(id: app + title, title: title, artist: "A", album: "", duration: 200, app: app), playing: playing, position: 10, at: Date())
    }

    // MARK: which player is shown

    static func sources(_ check: (String, Bool) -> Void) {
        let m = PlayerApp.music, s = PlayerApp.spotify, p = PlayerApp.pear
        let both = [m: snap(m, "a", playing: false), s: snap(s, "b", playing: true)]
        check("sources: the one playing is shown", MusicSources.choose(current: nil, pinned: nil, states: both) == s)
        check("sources: the shown one keeps the page while it plays", MusicSources.choose(current: s, pinned: nil, states: [m: snap(m, "a", playing: true), s: snap(s, "b", playing: true)]) == s)
        check("sources: a player starting to play takes over a paused one", MusicSources.choose(current: m, pinned: nil, states: both) == s)
        check("sources: the user's pick wins while it has a track", MusicSources.choose(current: s, pinned: m, states: both) == m)
        check("sources: a pick without a track is ignored", MusicSources.choose(current: nil, pinned: p, states: both) == s)
        check("sources: nothing playing → the shown one stays", MusicSources.choose(current: m, pinned: nil, states: [m: snap(m, "a", playing: false), s: snap(s, "b", playing: false)]) == m)
        check("sources: none → nil", MusicSources.choose(current: m, pinned: nil, states: [:]) == nil)
        check("sources: listed in a fixed order", MusicSources.available([p: snap(p, "c", playing: true), m: snap(m, "a", playing: false)]) == [m, p])
        check("skip: never before the start", MusicSources.skipTarget(now: 5, by: -15, duration: 200) == 0)
        check("skip: never past the last second", MusicSources.skipTarget(now: 195, by: 15, duration: 200) == 199)
        check("skip: in the middle it jumps exactly", MusicSources.skipTarget(now: 60, by: 15, duration: 200) == 75)
        check("skip: only the offered steps (else 15)", MusicSources.skipSeconds(10) == 10 && MusicSources.skipSeconds(7) == 15 && MusicSources.skipSeconds(0) == 15)
        check("skip: the glyphs exist for every step", MusicSources.skipChoices.allSatisfy { NSImage(systemSymbolName: MusicSources.skipSymbol($0, forward: true), accessibilityDescription: nil) != nil
            && NSImage(systemSymbolName: MusicSources.skipSymbol($0, forward: false), accessibilityDescription: nil) != nil })
        check("caps: Spotify can't like (its scripting can't save a song); Music and YouTube Music can",
              !PlayerCaps.of(s).like && PlayerCaps.of(m).like && PlayerCaps.of(p).like && PlayerCaps.of("Other") == PlayerCaps(like: false, volume: false, seek: false, shuffle: false))
    }

    // MARK: AppleScript

    static func scripts(_ check: (String, Bool) -> Void) {
        let m = PlayerApp.music, s = PlayerApp.spotify
        check("script: Music's favourite", PlayerScripts.script(.like(true), app: m)?.contains("set favorited of current track to true") == true)
        check("script: Spotify has no like", PlayerScripts.script(.like(true), app: s) == nil)
        check("script: YouTube Music isn't scripted", PlayerScripts.script(.playPause, app: PlayerApp.pear) == nil)
        check("script: the volume is clamped to 0…100", PlayerScripts.script(.volume(150), app: s)?.contains("set sound volume to 100") == true
              && PlayerScripts.script(.volume(-4), app: m)?.contains("set sound volume to 0") == true)
        check("script: shuffle uses each app's own word", PlayerScripts.script(.shuffle(true), app: s)?.contains("set shuffling to true") == true
              && PlayerScripts.script(.shuffle(false), app: m)?.contains("set shuffle enabled to false") == true)
        check("script: a skip back never goes below 0", PlayerScripts.script(.skip(-15), app: m)?.contains("if p < 0 then set p to 0") == true)
        check("script: seek rounds to whole seconds", PlayerScripts.script(.seek(12.6), app: m)?.contains("set player position to 13") == true)
        check("script: the app's name is the only thing put in it", PlayerScripts.script(.next, app: m) == "tell application \"Music\"\nnext track\nend tell")
        let poll = PlayerScripts.poll(app: m)
        check("script: Music's poll reads the favourite inside a try (older Music says 'loved')", poll.contains("try\n    set fav to (favorited of t as text)"))
        let at = Date()
        let music = PlayerScripts.parsePoll("playing\tSong\tArtist\tAlbum\t200,5\t12,25\ttrue\t\ttrue\t70", app: m, now: at)
        check("poll: Music's answer (comma decimals, favourite, volume)", music?.track.duration == 200.5 && music?.position == 12.25 && music?.playing == true
              && music?.shuffle == true && music?.liked == true && music?.volume == 70 && music?.track.app == m)
        let spot = PlayerScripts.parsePoll("paused\tS\tA\tB\t180\t3\tfalse\tspotify:track:9\t\t40", app: s, now: at)
        check("poll: Spotify's answer (no favourite, its own id)", spot?.liked == nil && spot?.volume == 40 && spot?.playing == false && spot?.track.id == "Spotifyspotify:track:9")
        check("poll: a short answer is no answer", PlayerScripts.parsePoll("playing\tx", app: m) == nil)
    }

    // MARK: Pear's API

    static func pearAPI(_ check: (String, Bool) -> Void) {
        check("pear: skip back is go-back with positive seconds", PearAPI.request(.skip(-10)) == PearAPI.Request(method: "POST", path: "/api/v1/go-back", body: ["seconds": 10]))
        check("pear: skip forward is go-forward", PearAPI.request(.skip(15)) == PearAPI.Request(method: "POST", path: "/api/v1/go-forward", body: ["seconds": 15]))
        check("pear: seek-to, play/pause, next, previous, like, shuffle",
              PearAPI.request(.seek(42.4)).body == ["seconds": 42] && PearAPI.request(.seek(42.4)).path == "/api/v1/seek-to"
              && PearAPI.request(.playPause).path == "/api/v1/toggle-play" && PearAPI.request(.next).path == "/api/v1/next"
              && PearAPI.request(.previous).path == "/api/v1/previous" && PearAPI.request(.like(true)).path == "/api/v1/like"
              && PearAPI.request(.shuffle(true)).path == "/api/v1/shuffle")
        check("pear: volume clamped", PearAPI.request(.volume(300)).body == ["volume": 100])
        check("pear: always the loopback", PearAPI.url(port: 26538, path: "/api/v1/song")?.absoluteString == "http://127.0.0.1:26538/api/v1/song")
        check("pear: no privileged or out-of-range port", PearAPI.url(port: 80, path: "/api/v1/song") == nil && PearAPI.url(port: 70000, path: "/x") == nil)
        check("pear: no dots, queries or hosts smuggled in the path", PearAPI.url(port: 26538, path: "/api/../x") == nil && PearAPI.url(port: 26538, path: "/a?b") == nil
              && PearAPI.url(port: 26538, path: "@evil.com/x") == nil && PearAPI.url(port: 26538, path: "/a b") == nil)
        let json = #"{"title":"Get Lucky","artist":"Daft Punk","album":"RAM","songDuration":369,"elapsedSeconds":61,"isPaused":false,"imageSrc":"https://lh3.googleusercontent.com/x","videoId":"5NV6Rdv1a3I","views":1}"#
        let song = PearAPI.parseSong(Data(json.utf8))
        check("pear: song parsed", song == PearAPI.Song(title: "Get Lucky", artist: "Daft Punk", album: "RAM", duration: 369, elapsed: 61, paused: false,
                                                        imageSrc: "https://lh3.googleusercontent.com/x", videoId: "5NV6Rdv1a3I"))
        let sn = song.map { PearAPI.snapshot($0) }
        check("pear: snapshot (playing, position, https artwork, id from the video)", sn?.playing == true && sn?.position == 61 && sn?.artworkURL != nil
              && sn?.track.id == "YouTube Music5NV6Rdv1a3I")
        let plain = PearAPI.parseSong(Data(#"{"title":"x","artist":"y","songDuration":10,"videoId":"v","imageSrc":"http://a/b"}"#.utf8)).map { PearAPI.snapshot($0) }
        check("pear: an http artwork address isn't used; a missing album is empty", plain?.artworkURL == nil && plain?.track.album == "")
        check("pear: no title → no song", PearAPI.parseSong(Data(#"{"artist":"y"}"#.utf8)) == nil && PearAPI.parseSong(Data("not json".utf8)) == nil)
        check("pear: like state", PearAPI.parseLike(Data(#"{"state":"LIKE"}"#.utf8)) == true && PearAPI.parseLike(Data(#"{"state":"INDIFFERENT"}"#.utf8)) == false
              && PearAPI.parseLike(Data(#"{"state":null}"#.utf8)) == nil)
        check("pear: volume (muted counts as 0)", PearAPI.parseVolume(Data(#"{"state":37.4,"isMuted":false}"#.utf8)) == 37
              && PearAPI.parseVolume(Data(#"{"state":80,"isMuted":true}"#.utf8)) == 0)
        check("pear: token taken only when it is a plain token", PearAPI.parseToken(Data(#"{"accessToken":"eyJ.a.b"}"#.utf8)) == "eyJ.a.b"
              && PearAPI.parseToken(Data(#"{"accessToken":"a b"}"#.utf8)) == nil && PearAPI.parseToken(Data(#"{"accessToken":""}"#.utf8)) == nil)
    }

    /// A fake Pear: answers by path; every request is kept.
    final class FakePear {
        var requests: [URLRequest] = []
        var answers: [String: (Int, String)] = [:]
        var down = false
        lazy var transport: PearClient.Transport = { [unowned self] req, done in
            self.requests.append(req)
            let path = req.url?.path ?? ""
            if self.down { DispatchQueue.global().async { done(PearClient.Reply(status: 0, data: nil)) }; return }
            let a = self.answers[(req.httpMethod ?? "GET") + " " + path] ?? (204, "")
            DispatchQueue.global().async { done(PearClient.Reply(status: a.0, data: Data(a.1.utf8))) }
        }
        func body(_ i: Int) -> [String: Double]? {
            guard i < requests.count, let d = requests[i].httpBody else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Double]
        }
        func last(_ method: String, _ path: String) -> URLRequest? { requests.last { $0.httpMethod == method && $0.url?.path == path } }
    }

    static func pearClient(_ check: (String, Bool) -> Void) {
        let fake = FakePear()
        let secrets = MemorySecretStore()
        let c = PearClient(transport: fake.transport, secrets: secrets)
        fake.answers["POST /auth/Cocaine"] = (403, "")
        var got: PearClient.Status?
        c.authorize { got = $0 }
        check("client: asking shows while Pear's dialog is up", c.status == .asking)
        spin { got != nil }
        check("client: Deny in Pear → denied, no token kept", got == .denied && c.token == nil && (try? secrets.load("pear"))?.isEmpty == true)
        let authReq = fake.requests.last
        check("client: the auth request waits up to a minute for the user and carries no token",
              authReq?.timeoutInterval == 60 && authReq?.value(forHTTPHeaderField: "Authorization") == nil && authReq?.url?.host == "127.0.0.1")
        fake.answers["POST /auth/Cocaine"] = (200, #"{"accessToken":"tok123"}"#)
        got = nil
        c.authorize { got = $0 }
        spin { got != nil }
        check("client: Allow → ready, the token kept in the secret store", got == .ready && c.status == .ready && (try? secrets.load("pear"))?["token"] == "tok123")
        fake.answers["GET /api/v1/song"] = (401, "Unauthorized")
        var reply: PearClient.Reply?
        c.call("GET", PearAPI.path("song")) { reply = $0 }
        spin { reply != nil }
        let songReq = fake.last("GET", "/api/v1/song")
        check("client: calls carry the token as a Bearer header, with a short timeout",
              songReq?.value(forHTTPHeaderField: "Authorization") == "Bearer tok123" && (songReq?.timeoutInterval ?? 99) <= 2)
        check("client: 401 → needs a new token", c.status == .needsAuth)
        fake.down = true
        reply = nil
        c.call("GET", PearAPI.path("song")) { reply = $0 }
        spin { reply != nil }
        check("client: no answer (plugin off, wrong port, timeout) → unreachable", reply?.status == 0 && c.status == .unreachable)
        fake.down = false
        c.forget()
        check("client: Disconnect forgets the token", c.token == nil && (try? secrets.load("pear"))?.isEmpty == true)
        let c2 = PearClient(transport: fake.transport, secrets: secrets)
        c2.port = 80
        var r2: PearClient.Reply?
        let before = fake.requests.count
        c2.call("GET", PearAPI.path("song")) { r2 = $0 }
        check("client: a bad port sends nothing", r2?.status == 0 && fake.requests.count == before)
        var hostOK = true
        PearClient.urlSession(URLRequest(url: URL(string: "http://example.com:26538/api/v1/song")!)) { r in hostOK = r.status == 0 }
        check("client: the real transport refuses any host but 127.0.0.1", hostOK)
    }

    // MARK: MusicWatch's commands

    static func watchCommands(_ check: (String, Bool) -> Void) {
        let fake = FakePear()
        let w = MusicWatch(pear: PearClient(transport: fake.transport, secrets: MemorySecretStore()))
        var sent: [(String, PlayerCommand)] = []
        w.commandSink = { sent.append(($0, $1)) }
        w.scriptsEnabled = false
        w.running = { [] }
        var s = snap(PlayerApp.music, "a", playing: true); s.position = 60; s.at = Date(); s.liked = false; s.volume = 50
        w.update(PlayerApp.music, s)
        w.skip(forward: true)
        if case .seek(let t)? = sent.last?.1 { check("watch: Music's skip is an exact seek (15 s by default)", abs(t - 75) < 1.5 && sent.last?.0 == PlayerApp.music) }
        else { check("watch: Music's skip is an exact seek (15 s by default)", false) }
        check("watch: the scrubber follows the skip at once", abs(w.now - 75) < 1.5)
        w.setSkipSeconds(30)
        w.skip(forward: false)
        if case .seek(let t)? = sent.last?.1 { check("watch: the skip step comes from Settings", abs(t - 45) < 1.5) } else { check("watch: the skip step comes from Settings", false) }
        w.toggleLike()
        check("watch: favourite on Music", sent.last.map { $0.1 == .like(true) } == true && w.liked == true)
        w.setVolume(80)
        check("watch: the volume shows at once", w.volume == 80)
        spin(0.5) { sent.contains { $0.1 == .volume(80) } }
        check("watch: the volume is sent once the slider pauses", sent.filter { if case .volume = $0.1 { return true }; return false }.count == 1)
        w.update(PlayerApp.spotify, snap(PlayerApp.spotify, "b", playing: false))
        check("watch: two players → the switcher lists both", w.sources == [PlayerApp.music, PlayerApp.spotify] && w.track?.app == PlayerApp.music)
        w.pick(PlayerApp.spotify)
        check("watch: picking Spotify shows it", w.track?.app == PlayerApp.spotify && !w.playing)
        let n = sent.count
        w.toggleLike()
        check("watch: no like on Spotify (nothing sent)", sent.count == n && w.liked == nil)
        w.playPause()
        check("watch: play/pause goes to the shown player", sent.last.map { $0.0 == PlayerApp.spotify && $0.1 == .playPause } == true && w.playing)
        w.update(PlayerApp.spotify, nil)
        check("watch: the picked player stopping hands back to the other", w.track?.app == PlayerApp.music && w.sources == [PlayerApp.music])
        check("watch: no request ever reached Pear (it was never turned on)", fake.requests.isEmpty)
        AppDefaults.store.removeObject(forKey: "musicSkip")
    }

    static func watchPear(_ check: (String, Bool) -> Void) {
        let fake = FakePear()
        let w = MusicWatch(pear: PearClient(transport: fake.transport, secrets: MemorySecretStore()))
        let pearBundle = PlayerApp.bundles[PlayerApp.pear]![0]
        w.scriptsEnabled = false
        w.running = { [pearBundle] }
        fake.answers["GET /api/v1/song"] = (200, #"{"title":"Get Lucky","artist":"Daft Punk","songDuration":369,"elapsedSeconds":61,"isPaused":false,"videoId":"v1"}"#)
        fake.answers["GET /api/v1/like-state"] = (200, #"{"state":"LIKE"}"#)
        fake.answers["GET /api/v1/volume"] = (200, #"{"state":64,"isMuted":false}"#)
        w.start()
        spin(0.3) { false }
        check("pear: open but not turned on → nothing is sent (consent first)", fake.requests.isEmpty && w.pearRunning && w.track == nil)
        check("pear: the page offers Connect", PearPrompt.note(enabled: false, status: w.pear.status) != nil)
        w.setPear(true)
        spin { w.track != nil && w.volume != nil && w.liked != nil }
        check("pear: turned on → its song shows", w.track?.title == "Get Lucky" && w.track?.app == PlayerApp.pear && w.playing && abs(w.now - 61) < 2)
        check("pear: its like and volume are read", w.liked == true && w.volume == 64)
        w.skip(forward: true)
        spin { fake.last("POST", "/api/v1/go-forward") != nil }
        let fwd = fake.requests.firstIndex { $0.url?.path == "/api/v1/go-forward" }
        check("pear: skip forward → go-forward with the step", fwd.flatMap { fake.body($0) } == ["seconds": 15])
        w.toggleLike()
        spin { fake.last("POST", "/api/v1/like") != nil }
        check("pear: like is a toggle (sent to remove the like)", fake.last("POST", "/api/v1/like") != nil && w.liked == false)
        w.setVolume(250)
        spin { fake.last("POST", "/api/v1/volume") != nil }
        let vol = fake.requests.firstIndex { $0.url?.path == "/api/v1/volume" && $0.httpMethod == "POST" }
        check("pear: volume sent clamped", vol.flatMap { fake.body($0) } == ["volume": 100] && w.volume == 100)
        check("pear: every request went to 127.0.0.1", fake.requests.allSatisfy { $0.url?.host == "127.0.0.1" && $0.url?.port == PearAPI.defaultPort })
        fake.answers["GET /api/v1/song"] = (204, "")
        w.pageVisible = true
        spin { w.track == nil }
        w.pageVisible = false
        check("pear: nothing playing (204) → no track", w.track == nil)
        w.running = { [] }
        w.pageVisible = true
        spin(0.3) { false }
        w.pageVisible = false
        check("pear: closed → said so", w.pear.status == .notRunning && !w.pearRunning)
        w.setPear(false)
        let n = fake.requests.count
        w.pageVisible = true; spin(0.3) { false }; w.pageVisible = false
        check("pear: turned off → silent again", fake.requests.count == n && w.pear.status == .off)
        w.stop()
        AppDefaults.store.removeObject(forKey: "musicPear")
    }

    // MARK: keyboard backlight

    static func backlight(_ check: (String, Bool) -> Void) {
        typealias K = KeyboardBacklight
        check("backlight: idle past the time → off", K.decide(idle: 61, idleOff: 60, onlyWhileAwake: false, awake: false, dimmed: false) == .dim)
        check("backlight: input again → back on", K.decide(idle: 0.3, idleOff: 60, onlyWhileAwake: false, awake: false, dimmed: true) == .restore)
        check("backlight: never → nothing", K.decide(idle: 9999, idleOff: 0, onlyWhileAwake: false, awake: true, dimmed: false) == .none)
        check("backlight: only while keeping awake, and not keeping awake → nothing", K.decide(idle: 999, idleOff: 30, onlyWhileAwake: true, awake: false, dimmed: false) == .none)
        check("backlight: only while keeping awake, keeping awake → off", K.decide(idle: 999, idleOff: 30, onlyWhileAwake: true, awake: true, dimmed: false) == .dim)
        check("backlight: keep-awake ends while dimmed → back on", K.decide(idle: 999, idleOff: 30, onlyWhileAwake: true, awake: false, dimmed: true) == .restore)

        let dev = FakeBacklight(level: 0.6)
        let kb = K(device: dev, defaults: MemoryDefaults())
        var huds: [Double] = []
        kb.hud = { huds.append($0) }
        var idle = 0.0, awake = false
        kb.idleSeconds = { idle }
        kb.keepingAwake = { awake }
        check("backlight: available, level read", kb.available && abs(kb.level - 0.6) < 0.001)
        kb.set(0.8)
        check("backlight: set → written once, HUD shown", dev.writes == [0.8] && huds == [0.8])
        kb.set(1.7)
        check("backlight: clamped to 0…1", dev.value == 1)
        kb.toggle()
        check("backlight: the switch turns it off", dev.value == 0)
        kb.toggle()
        check("backlight: and back to the last level", dev.value == 1)
        kb.setIdleOff(45)
        check("backlight: only the offered idle times (else never)", kb.idleOff == 0)
        kb.setIdleOff(30)
        idle = 31; kb.tick()
        check("backlight: auto-off after 30 s idle (no HUD for it)", dev.value == 0 && kb.dimmed && huds.count == 4)
        idle = 0.2; kb.tick()
        check("backlight: back to what it was at the next input", dev.value == 1 && !kb.dimmed)
        idle = 40; kb.tick()
        dev.value = 0.3                                   // the user set it meanwhile (the keys, Control Center)
        idle = 0; kb.tick()
        check("backlight: a level the user set while dimmed is left alone", dev.value == 0.3 && !kb.dimmed)
        dev.value = 0
        idle = 99; kb.tick()
        check("backlight: already off → nothing to remember", !kb.dimmed)
        dev.value = 0.5
        kb.setOnlyWhileAwake(true)
        idle = 99; awake = false; kb.tick()
        check("backlight: only while keeping awake: not dimmed otherwise", !kb.dimmed && dev.value == 0.5)
        awake = true; kb.tick()
        check("backlight: …and dimmed while keeping awake", kb.dimmed && dev.value == 0)
        kb.setIdleOff(0)
        check("backlight: auto-off turned off while dimmed → back on", !kb.dimmed && dev.value == 0.5)
        let none = K(device: FakeBacklight(available: false), defaults: MemoryDefaults())
        none.set(0.5)
        check("backlight: a Mac without one → hidden, nothing written", !none.available && (none.device as? FakeBacklight)?.writes.isEmpty == true)
        // This Mac, read only (never written).
        let real = CoreBrightnessBacklight()
        let lv = real.level()
        print("INFO  media: this Mac's keyboard backlight: " + (real.available ? "available, level \(lv.map { String(format: "%.2f", $0) } ?? "unreadable")" : "not available"))
        check("backlight: the real one reads as nothing or a level in 0…1 (read only)", lv == nil || (0...1).contains(lv!))
        check("backlight: the app's own is a fake under test flags", KeyboardBacklight.shared.device is FakeBacklight)
    }

    // MARK: shelf extras

    static func shelf(_ check: (String, Bool) -> Void) {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = ShelfItem(kind: .file, path: "/x/file 10.txt", added: t0.addingTimeInterval(3))
        let b = ShelfItem(kind: .file, path: "/x/file 2.txt", added: t0.addingTimeInterval(1))
        let c = ShelfItem(kind: .image, path: "i.png", text: "Photo.png", added: t0.addingTimeInterval(2))
        let d = ShelfItem(kind: .link, text: "https://example.com/a", added: t0)
        let e = ShelfItem(kind: .text, text: "note", added: t0.addingTimeInterval(4))
        var f = ShelfItem(kind: .file, path: "/x/gone.pdf", added: t0.addingTimeInterval(5)); f.missing = true
        let items = [a, b, c, d, e, f]
        let sizes: [UUID: Int64] = [a.id: 10, b.id: 500, c.id: 70, f.id: 0]
        check("sort: by name, numbers by value (file 2 before file 10)",
              ShelfArrange.order([a, b], by: .name) == [b.id, a.id])
        check("sort: by date added, oldest first", ShelfArrange.order(items, by: .added) == [d.id, b.id, c.id, a.id, e.id, f.id])
        check("sort: by kind (files, images, links, texts)", ShelfArrange.order([e, d, c, a], by: .kind) == [a.id, c.id, d.id, e.id])
        check("sort: by size, largest first", ShelfArrange.order([a, b, c], by: .size, size: { sizes[$0.id] ?? 0 }) == [b.id, c.id, a.id])
        let img: (ShelfItem) -> Bool = { $0.kind == .image || $0.path.hasSuffix(".png") }
        check("pick: images", ShelfArrange.pick(items, .images, isImage: img) == [c.id])
        check("pick: files", ShelfArrange.pick(items, .files, isImage: img) == [a.id, b.id, f.id])
        check("pick: links, texts, missing", ShelfArrange.pick(items, .links, isImage: img) == [d.id] && ShelfArrange.pick(items, .texts, isImage: img) == [e.id]
              && ShelfArrange.pick(items, .missing, isImage: img) == [f.id])
        var sel = ShelfSelection(); sel.set([a.id, b.id])
        sel.invert(items.map(\.id))
        check("select: invert", sel.ids == Set([c.id, d.id, e.id, f.id]) && sel.focus == c.id)
        var lib = ShelfLibrary.fresh()
        lib.collections[0].items = items
        lib.arrange([e.id, d.id], in: lib.current)
        check("arrange: the named first, the others keep their order", lib.collections[0].items.map(\.id) == [e.id, d.id, a.id, b.id, c.id, f.id])
        check("names: one per line, a link's address", ShelfArrange.names([a, d]) == "file 10.txt\nhttps://example.com/a")
        let url: (ShelfItem) -> URL? = { $0.isFileBacked ? URL(fileURLWithPath: $0.path) : nil }
        check("ops: AirDrop and Copy Names for files", ShelfOp.available([a], urlFor: url, cloud: false, ai: false).contains(.airDrop)
              && ShelfOp.available([a], urlFor: url, cloud: false, ai: false).contains(.copyNames))
        check("ops: AirDrop for links, not for a text alone", ShelfOp.available([d], urlFor: url, cloud: false, ai: false).contains(.airDrop)
              && !ShelfOp.available([e], urlFor: url, cloud: false, ai: false).contains(.airDrop))

        // On a shelf in memory, with a private pasteboard.
        let store = ShelfStore(disk: .memory, defaults: MemoryDefaults())
        let center = ShelfCenter(store: store, config: ShelfConfigStore(defaults: { MemoryDefaults() }))
        let pb = NSPasteboard(name: NSPasteboard.Name("local.cocaine.media-test.\(getpid())"))
        center.pasteboard = { pb }
        defer { pb.releaseGlobally() }
        store.replace(.fresh())
        var l = store.library; l.collections[0].items = items; store.replace(l)
        center.sort(.name)
        check("center: sort by name keeps every item", store.items.count == 6 && store.items.map(\.name) == ["example.com/a", "file 2.txt", "file 10.txt", "gone.pdf", "note", "Photo.png"])
        center.select(.missing)
        check("center: select the missing items", store.selection.ids == [f.id])
        center.invertSelection()
        check("center: invert", store.selection.ids.count == 5 && !store.selection.contains(f.id))
        center.copyNames([a, b])
        check("center: Copy Names (private pasteboard)", pb.string(forType: .string) == "file 10.txt\nfile 2.txt")
        center.removeMissing()
        check("center: Remove Missing Items", store.items.count == 5 && !store.items.contains { $0.missing })
        let show = DialogCenter.shared.show
        DialogCenter.shared.show = { $0 }                  // the in-app card, never a system alert
        defer { DialogCenter.shared.show = show }
        center.removeAll()
        check("center: Remove All asks first (more than one item)", store.items.count == 5 && DialogCenter.shared.isShowing(on: .island))
        DialogCenter.shared.cancel()
        var one = store.library; one.collections[0].items = [a]; store.replace(one)
        center.removeAll()
        check("center: one item goes without a question", store.items.isEmpty)
    }
}
