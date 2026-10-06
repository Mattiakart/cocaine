import Foundation

// MARK: - Regression tests for remote control (run by --selftest and --remote-test)

/// Runs a built Shortcut the way the Shortcuts app would, for the actions RemoteShortcut uses (with ICU regular
/// expressions, as Shortcuts' Replace Text). It follows what real Shortcuts runs showed (macOS 27, Italian locale; see
/// RemoteShortcut.inputShapes): an input given in a form the action doesn't take comes out empty, as it does there.
/// It can't prove every Apple semantic: RemoteShortcut.problems and a real run (docs/remote-security) cover the rest.
final class ShortcutSim {
    var outputs: [String: String] = [:]
    var vars: [String: String] = [:]
    var shown: [String] = []
    var menuChoice = ""
    var askAnswer = ""
    var groupedNumbers = false          // "123,456,789", as some locales might render numbers in text
    var groupingSeparator = ","         // "." for an Italian-style grouping
    var fractionalDates = false         // "…T12:00:00.123+02:00"
    var http: (_ method: String, _ url: String, _ body: String) -> String = { _, _, _ in "" }
    var onDelay: () -> Void = {}
    var error: String?

    private func attachment(_ a: [String: Any]) -> String {
        if let u = a["OutputUUID"] as? String {
            guard let v = outputs[u] else { error = error ?? "missing output"; return "" }
            return v
        }
        if a["Type"] as? String == "Variable", let n = a["VariableName"] as? String {
            guard let v = vars[n] else { error = error ?? "missing variable \(n)"; return "" }
            return v
        }
        error = error ?? "unknown attachment"
        return ""
    }

    func value(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? Int { return String(n) }
        guard let d = any as? [String: Any], let v = d["Value"] else { return "" }
        if d["WFSerializationType"] as? String == "WFTextTokenAttachment", let a = v as? [String: Any] { return attachment(a) }
        guard let t = v as? [String: Any], let s = t["string"] as? String else { return "" }
        let ns = NSMutableString(string: s)
        let ranges = (t["attachmentsByRange"] as? [String: Any] ?? [:]).compactMap { k, a -> (Int, [String: Any])? in
            let loc = Int(k.dropFirst().split(separator: ",")[0]) ?? -1
            return (a as? [String: Any]).map { (loc, $0) }
        }.sorted { $0.0 > $1.0 }
        for (loc, a) in ranges {
            guard loc >= 0, loc < ns.length, ns.substring(with: NSRange(location: loc, length: 1)) == "\u{FFFC}" else {
                error = error ?? "attachment at a wrong position"; continue
            }
            ns.replaceCharacters(in: NSRange(location: loc, length: 1), with: attachment(a))
        }
        return ns as String
    }

    /// A parameter's value, or "" when it is given in a form the action doesn't take (what Shortcuts does).
    func input(_ id: String, _ p: [String: Any], _ key: String) -> String {
        if let shape = RemoteShortcut.inputShapes[id]?[key], !RemoteShortcut.Shape.of(p[key]).fits(shape) { return "" }
        return value(p[key])
    }

    func run(_ actions: [[String: Any]]) {
        var pc = 0
        while pc < actions.count, error == nil {
            let a = actions[pc]
            let id = String((a["WFWorkflowActionIdentifier"] as? String ?? "").dropFirst("is.workflow.actions.".count))
            let p = a["WFWorkflowActionParameters"] as? [String: Any] ?? [:]
            var out: String?
            switch id {
            case "gettext": out = input(id, p, "WFTextActionText")
            case "setvariable": vars[p["WFVariableName"] as? String ?? ""] = input(id, p, "WFInput")
            case "hash":
                let s = input(id, p, "WFInput")
                out = s.isEmpty ? "" : (p["WFHashType"] as? String == "SHA512" ? RemoteCrypto.sha512(s) : RemoteCrypto.sha256(s))
            case "base64encode":
                var s = Data(input(id, p, "WFInput").utf8).base64EncodedString(options: p["WFBase64LineBreakMode"] as? String == "None" ? [] : .lineLength76Characters)
                if p["WFBase64LineBreakMode"] == nil { s += "\r\n" }
                out = s
            case "text.replace":
                let text = input(id, p, "WFInput"), find = input(id, p, "WFReplaceTextFind"), with = value(p["WFReplaceTextReplace"])
                let cs = p["WFReplaceTextCaseSensitive"] as? Bool ?? true
                if p["WFReplaceTextRegularExpression"] as? Bool == true {
                    guard let r = try? NSRegularExpression(pattern: find, options: cs ? [] : .caseInsensitive) else { error = "bad pattern \(find)"; break }
                    out = r.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: with)
                } else {
                    out = text.replacingOccurrences(of: find, with: with, options: cs ? [] : .caseInsensitive)
                }
            case "urlencode": out = input(id, p, "WFInput").removingPercentEncoding ?? ""
            case "date": out = "now"
            case "format.date":
                guard input(id, p, "WFDate") == "now" else { out = ""; break }
                let f = ISO8601DateFormatter()
                f.timeZone = TimeZone.current
                f.formatOptions = fractionalDates ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
                out = f.string(from: Date())
            case "number.random":
                let n = Int.random(in: (p["WFRandomNumberMinimum"] as? Int ?? 0)...(p["WFRandomNumberMaximum"] as? Int ?? 0))
                if groupedNumbers { let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = groupingSeparator; out = f.string(from: NSNumber(value: n)) }
                else { out = String(n) }
            case "downloadurl":
                // A URL with variable content is not sent as written (Shortcuts' link detection cuts some short).
                guard RemoteShortcut.Shape.of(p["WFURL"]) == .constant else { error = "variable content in a URL"; break }
                let method = p["WFHTTPMethod"] as? String ?? "GET"
                out = http(method, value(p["WFURL"]), method == "POST" ? input(id, p, "WFRequestVariable") : "")
            case "delay": onDelay()
            case "ask": out = askAnswer
            case "showresult": shown.append(input(id, p, "Text"))
            case "exit": return
            case "choosefrommenu":
                let mode = p["WFControlFlowMode"] as? Int ?? -1, group = p["GroupingIdentifier"] as? String
                func find(_ test: ([String: Any]) -> Bool) -> Int? {
                    actions.indices.first { i in i > pc && {
                        let q = actions[i]["WFWorkflowActionParameters"] as? [String: Any] ?? [:]
                        return q["GroupingIdentifier"] as? String == group && test(q)
                    }() }
                }
                if mode == 0 {
                    guard let i = find({ $0["WFControlFlowMode"] as? Int == 1 && $0["WFMenuItemTitle"] as? String == menuChoice }) else { error = "no menu item \(menuChoice)"; break }
                    pc = i
                } else if mode == 1 {
                    guard let i = find({ $0["WFControlFlowMode"] as? Int == 2 }) else { error = "unclosed menu"; break }
                    pc = i
                }
            default: error = "unknown action \(id)"
            }
            if let out, let u = p["UUID"] as? String { outputs[u] = out }
            pc += 1
        }
    }
}

/// A relay in memory: POST a message to a topic, GET the raw poll, as the Shortcut uses them.
final class FakeRelay {
    var topics: [String: [String]] = [:]
    var tamper: ((String) -> String)?            // applied to what the phone reads
    func request(_ method: String, _ url: String, _ body: String) -> String {
        guard let c = URLComponents(string: url) else { return "" }
        let parts = c.path.split(separator: "/").map(String.init)
        if method == "POST", parts.count == 1 {
            topics[parts[0], default: []].append(body.trimmingCharacters(in: .whitespacesAndNewlines))   // as ntfy does
            return "{}"
        }
        guard method == "GET", parts.count == 2, parts[1] == "raw" else { return "" }
        let all = (topics[parts[0]] ?? []).joined(separator: "\n")
        return tamper?(all) ?? all
    }
}

/// A relay for URLSession: every subscription gets the topic's messages since `since` and then the connection ends
/// (as a flaky network would), so the listener keeps reconnecting and is sent the same messages again and again.
final class MockRelayProtocol: URLProtocol {
    static let lock = NSLock()
    static var messages: [String: [(id: String, time: Int, text: String)]] = [:]
    static var connections = 0

    static func add(_ topic: String, id: String, time: Int, text: String) {
        lock.lock(); messages[topic, default: []].append((id, time, text)); lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let topic = c.path.split(separator: "/").first.map(String.init) ?? ""
        let since = Int(c.queryItems?.first { $0.name == "since" }?.value ?? "0") ?? 0
        Self.lock.lock()
        Self.connections += 1
        let list = (Self.messages[topic] ?? []).filter { $0.time >= since }
        Self.lock.unlock()
        var body = #"{"id":"o","time":1,"event":"open"}"# + "\n"
        for m in list {
            let j = try! JSONSerialization.data(withJSONObject: ["id": m.id, "time": m.time, "event": "message", "message": m.text])
            body += String(decoding: j, as: UTF8.self) + "\n"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum RemoteTests {
    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-remote-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func nonce() -> String { (0..<3).map { _ in String(Int.random(in: 100_000_000...999_999_999)) }.joined() }

    /// `gate`: the path of remote.zsh (to test the gate's refusals), or nil to skip those.
    static func run(gate: String?, _ check: (String, Bool) -> Void) {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let p = Pairing.make(tier: "agents", relay: "https://relay.test", now: now)!
        let k = p.keys!
        let other = Pairing.make(tier: "basic", relay: "https://relay.test", now: now)!
        let ts = RemoteProtocol.timestamp(now)
        func store() -> RemoteReplayStore { RemoteReplayStore(url: dir.appendingPathComponent("state-\(UUID().uuidString).json")) }
        func eval(_ text: String, _ pairing: Pairing = p, store s: RemoteReplayStore, at: Date = now, maxAge: Double = 120,
                  legacyUntil: Date? = nil, active: Bool = true, id: String = UUID().uuidString, time: Int? = nil) -> RemoteDecision {
            RemoteGatekeeper.evaluate(text: text, eventID: id, eventTime: time ?? Int(at.timeIntervalSince1970), pairing: pairing, active: active,
                                      now: at, maxAge: maxAge, legacyUntil: legacyUntil, store: s, expiredText: "EXPIRED", noticeText: "NOTICE")
        }

        // Keys and form
        check("remote: a new pairing is v2, with a key, topics of 192 bits and an expiry", !p.isLegacy && p.key?.count == 64
              && p.cmd.count == 50 && p.reply.count == 50 && (p.expires ?? 0) > now.timeIntervalSince1970 + 170 * 86_400)
        check("remote: keys are one hash block each", k.enc.count == 128 && k.macIn.count == 64 && k.macOut.count == 64 && k != other.keys!)
        let old = #"[{"id":"0011223344556677","cmd":"ccaaaa","reply":"crbbbb","tier":"agents","relay":"https://ntfy.sh"}]"#
        let decoded = try? JSONDecoder().decode([Pairing].self, from: Data(old.utf8))
        check("remote: an old phones.json still loads, as legacy pairings", decoded?.count == 1 && decoded?[0].isLegacy == true && decoded?[0].keys == nil)

        // Commands: round trip, confidentiality, tampering
        let n1 = nonce()
        let sealed = RemoteProtocol.sealCommand("status", pairingID: p.id, keys: k, nonce: n1, ts: ts)
        check("remote: a sealed command opens to the same text", (try? RemoteProtocol.openCommand(sealed, pairingID: p.id, keys: k).get())?.text == "status")
        check("remote: the relay never sees the command", !sealed.contains("status") && !sealed.contains(Data("status".utf8).base64EncodedString().prefix(6)))
        check("remote: every command has the same length on the relay",
              RemoteProtocol.sealCommand("on", pairingID: p.id, keys: k, nonce: n1, ts: ts).count
              == RemoteProtocol.sealCommand(String(repeating: "x", count: 400), pairingID: p.id, keys: k, nonce: n1, ts: ts).count)
        var tamperedAll = true
        let parts = sealed.split(separator: ".").map(String.init)
        for field in 1...5 {
            var q = parts
            let s = Array(q[field])
            let i = s.count / 2
            let flipped: Character = s[i] == "1" ? "2" : (s[i] == "A" ? "B" : (s[i] == "a" ? "b" : (s[i] == "0" ? "1" : "1")))
            q[field] = String(s[..<i]) + String(flipped) + String(s[(i + 1)...])
            if case .success = RemoteProtocol.openCommand(q.joined(separator: "."), pairingID: p.id, keys: k) { tamperedAll = false }
        }
        check("remote: changing any field (id, nonce, time, ciphertext, tag) is refused", tamperedAll)
        if case .failure(let e) = RemoteProtocol.openCommand(sealed, pairingID: other.id, keys: other.keys!) {
            check("remote: another pairing's key/topic can't open it", e == .wrongPairing)
        } else { check("remote: another pairing's key/topic can't open it", false) }
        let forged = RemoteProtocol.sealCommand("status", pairingID: p.id, keys: other.keys!, nonce: n1, ts: ts)
        check("remote: a command made with the wrong key is refused", (try? RemoteProtocol.openCommand(forged, pairingID: p.id, keys: k).get()) == nil)
        check("remote: plain text to a v2 pairing is refused (never run)", eval("status", store: store()) == .drop(.unauthenticated))
        check("remote: oversized lines are refused", eval("c2." + String(repeating: "a", count: 3000), store: store()) == .drop(.malformed))
        let long = RemoteProtocol.sealCommand(String(repeating: "y", count: 520), pairingID: p.id, keys: k, nonce: nonce(), ts: ts)
        if case .answer(let t, _, let why) = eval(long, store: store()) { check("remote: a command too long to fit is refused, and the phone told", t.contains("too long") && why == .tooLong) }
        else { check("remote: a command too long to fit is refused, and the phone told", false) }
        let withNewline = RemoteProtocol.sealCommand("status\nrm -rf ~", pairingID: p.id, keys: k, nonce: nonce(), ts: ts)
        check("remote: control characters inside a command are refused", (try? RemoteProtocol.openCommand(withNewline, pairingID: p.id, keys: k).get()) == nil)

        // Freshness, replay (also after a restart), expiry, revocation
        let s1 = store()
        let fresh = RemoteProtocol.sealCommand("on", pairingID: p.id, keys: k, nonce: nonce(), ts: ts)
        check("remote: a fresh command runs, at the pairing's level", eval(fresh, store: s1) == .run(command: "on", tier: "agents", nonce: fresh.split(separator: ".")[2].description))
        check("remote: the same command again is a replay", eval(fresh, store: s1, id: "other-relay-id") == .drop(.replay))
        let restarted = RemoteReplayStore(url: s1.url)
        check("remote: …also after a restart (state on disk)", eval(fresh, store: restarted, at: now.addingTimeInterval(30)) == .drop(.replay))
        check("remote: …and with a longer wake-up window", eval(fresh, store: restarted, at: now.addingTimeInterval(600), maxAge: 1200) == .drop(.replay))
        let oldTs = RemoteProtocol.timestamp(now.addingTimeInterval(-300))
        check("remote: a command older than allowed is refused", eval(RemoteProtocol.sealCommand("on", pairingID: p.id, keys: k, nonce: nonce(), ts: oldTs), store: store()) == .drop(.stale))
        let futureTs = RemoteProtocol.timestamp(now.addingTimeInterval(600))
        check("remote: a command dated in the future is refused", eval(RemoteProtocol.sealCommand("on", pairingID: p.id, keys: k, nonce: nonce(), ts: futureTs), store: store()) == .drop(.future))
        do {   // a damaged state file must not reopen replays
            let s = store()
            let c = RemoteProtocol.sealCommand("on", pairingID: p.id, keys: k, nonce: nonce(), ts: RemoteProtocol.timestamp(now.addingTimeInterval(-20)))
            _ = eval(c, store: s)
            try? Data("garbage".utf8).write(to: s.url)
            check("remote: a damaged state file refuses everything sent before it was noticed", eval(c, store: RemoteReplayStore(url: s.url)) == .drop(.replay))
            let later = RemoteProtocol.sealCommand("on", pairingID: p.id, keys: k, nonce: nonce(), ts: RemoteProtocol.timestamp(now.addingTimeInterval(5)))
            if case .run = eval(later, store: RemoteReplayStore(url: s.url), at: now.addingTimeInterval(6)) { check("remote: …while newer commands still run", true) }
            else { check("remote: …while newer commands still run", false) }
        }
        var expired = p
        expired.expires = now.timeIntervalSince1970 - 1
        let ec = RemoteProtocol.sealCommand("on", pairingID: p.id, keys: k, nonce: nonce(), ts: ts)
        if case .answer(let t, _, let why) = eval(ec, expired, store: store()) { check("remote: an expired pairing runs nothing (and says why)", t == "EXPIRED" && why == .expired) }
        else { check("remote: an expired pairing runs nothing (and says why)", false) }
        check("remote: a revoked pairing runs nothing", eval(RemoteProtocol.sealCommand("on", pairingID: p.id, keys: k, nonce: nonce(), ts: ts), store: store(), active: false) == .drop(.revoked))

        // Answers: bound to the request, authenticated, encrypted
        let reply = RemoteProtocol.sealReply("Cocaine: ON — 80% 🔋", pairingID: p.id, keys: k, nonce: n1, now: now)
        check("remote: an answer opens for its request", RemoteProtocol.openReply(reply, pairingID: p.id, keys: k, nonce: n1) == "Cocaine: ON — 80% 🔋")
        check("remote: the relay never sees the answer", !reply.contains("Cocaine") && !reply.contains("80%"))
        check("remote: an answer can't be taken for another request's", RemoteProtocol.openReply(reply.replacingOccurrences(of: n1, with: nonce()), pairingID: p.id, keys: k, nonce: nonce()) == nil
              && RemoteProtocol.openReply(reply, pairingID: p.id, keys: k, nonce: nonce()) == nil)
        check("remote: an answer from another pairing (or forged) is refused", RemoteProtocol.openReply(RemoteProtocol.sealReply("x", pairingID: other.id, keys: other.keys!, nonce: n1, now: now), pairingID: p.id, keys: k, nonce: n1) == nil)
        let big = RemoteProtocol.sealReply(String(repeating: "é", count: 3000), pairingID: p.id, keys: k, nonce: n1, now: now)
        check("remote: a long answer is cut to fit the relay's 4096 bytes", big.utf8.count < 4000 && RemoteProtocol.openReply(big, pairingID: p.id, keys: k, nonce: n1)?.hasPrefix("éé") == true)

        // Old Shortcuts (migration)
        let legacy = decoded![0]
        check("remote: by default an old Shortcut runs nothing; it's told to update", eval("status", legacy, store: s1) == .notice("NOTICE"))
        check("remote: …and isn't told again and again", eval("status", legacy, store: s1) == .drop(.unauthenticated))
        let allowed = now.addingTimeInterval(86_400)
        check("remote: when allowed, an old Shortcut gets basic commands only (even if paired for agents)",
              eval("start claude x", legacy, store: s1, legacyUntil: allowed, id: "m1") == .run(command: "start claude x", tier: "basic", nonce: nil))
        check("remote: …a relay duplicate of it is dropped", eval("start claude x", legacy, store: s1, legacyUntil: allowed, id: "m1") == .drop(.replay))
        check("remote: …and once the allowed period is over, nothing", eval("status", legacy, store: s1, at: now.addingTimeInterval(700), legacyUntil: now) == .notice("NOTICE"))
        check("remote: …an old message from the relay doesn't run", eval("status", legacy, store: s1, legacyUntil: allowed, time: Int(now.timeIntervalSince1970) - 600) == .drop(.stale))
        check("remote: a v2 message on an old pairing is refused", eval(fresh, legacy, store: s1) == .drop(.unauthenticated))
        var broken = p
        broken.key = "zz"
        check("remote: a v2 pairing with a damaged key never falls back to plain text (even with old Shortcuts allowed)",
              !broken.isLegacy && eval("status", broken, store: store(), legacyUntil: allowed, id: "b1") == .drop(.malformed))

        // Concurrency: threads and two store objects on one file (as two processes would)
        do {
            let s = store(), twin = RemoteReplayStore(url: s.url)
            let lock = NSLock()
            var freshCount = 0
            let n = nonce()
            DispatchQueue.concurrentPerform(iterations: 48) { i in
                let r = (i % 2 == 0 ? s : twin).claim(pairing: p.id, nonce: n, sentAt: now.timeIntervalSince1970 + 1, now: now.timeIntervalSince1970 + 1)
                if r == .fresh { lock.lock(); freshCount += 1; lock.unlock() }
            }
            check("remote: one nonce claimed from 48 threads at once runs exactly once", freshCount == 1)
            DispatchQueue.concurrentPerform(iterations: 40) { i in
                _ = (i % 2 == 0 ? s : twin).claim(pairing: p.id, nonce: "n\(i)", sentAt: now.timeIntervalSince1970 + 1, now: now.timeIntervalSince1970 + 1)
            }
            check("remote: 40 different commands at once are all recorded", s.snapshot()?.seen[p.id]?.count == 41)
            s.forget(keeping: [], now: now.timeIntervalSince1970)
            check("remote: revoking forgets the pairing's state", s.snapshot()?.seen.isEmpty == true)
            check("remote: …and what it sent before can't run if the pairing comes back (phones.json read again)",
                  s.claim(pairing: p.id, nonce: nonce(), sentAt: now.timeIntervalSince1970 - 1, now: now.timeIntervalSince1970 + 2) == .duplicate)
            let kept = store()
            _ = kept.claim(pairing: p.id, nonce: nonce(), sentAt: now.timeIntervalSince1970 - 5, now: now.timeIntervalSince1970)
            kept.forget(keeping: [p.id], now: now.timeIntervalSince1970)
            check("remote: a sync that drops nothing sets no floor", (kept.snapshot()?.floor ?? -1) == 0)
        }
        do {   // a state file that is there but can't be read is damaged too, not a first use
            let s = store()
            let c = RemoteProtocol.sealCommand("on", pairingID: p.id, keys: k, nonce: nonce(), ts: RemoteProtocol.timestamp(now.addingTimeInterval(-20)))
            _ = eval(c, store: s)
            chmod(s.url.path, 0)
            check("remote: an unreadable state file refuses everything sent before it was noticed", eval(c, store: RemoteReplayStore(url: s.url)) == .drop(.replay))
        }

        // Timestamps as the Shortcut may write them
        check("remote: phone times are read in their time zone", RemoteProtocol.date("2026-10-05T14:03:12p02:00") == RemoteProtocol.date("2026-10-05T12:03:12Z")
              && RemoteProtocol.date("2026-10-05T10:03:12-02:00") == RemoteProtocol.date("2026-10-05T12:03:12Z"))
        check("remote: bad times are refused", RemoteProtocol.date("2026-02-31T12:00:00Z") == nil && RemoteProtocol.date("2026-13-01T12:00:00Z") == nil
              && RemoteProtocol.date("now") == nil && RemoteProtocol.date("2026-10-05T12:03:12+99:00") == nil)

        shortcutTests(p, check)
        listenerTests(p, dir: dir, check)
        if let gate { gateTests(gate, dir: dir, check) }
    }

    /// The generated Shortcut, run in the simulator against the Mac's code.
    static func shortcutTests(_ p: Pairing, _ check: (String, Bool) -> Void) {
        let labels = RemoteShortcutLabels()
        guard let data = RemoteShortcut.build(p, labels: labels),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let actions = plist["WFWorkflowActions"] as? [[String: Any]] else { check("shortcut: builds", false); return }
        let problems = RemoteShortcut.problems(data)
        check("shortcut: structure is sound (\(actions.count) actions, \(data.count / 1024) KB)\(problems.isEmpty ? "" : ": " + problems.prefix(3).joined(separator: "; "))", problems.isEmpty)
        let flat = String(decoding: (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data(), as: UTF8.self)
        check("shortcut: carries derived keys, never the master key", !flat.contains(p.key!) && flat.contains(p.keys!.macIn))
        check("shortcut: an old (legacy) pairing gets no v2 Shortcut", RemoteShortcut.build(Pairing(id: "a", cmd: "b", reply: "c", tier: "basic", relay: "d"), labels: labels) == nil)

        func session(_ choice: String, ask: String = "", grouped: String? = nil, fractional: Bool = false, mac: ((String) -> String)? = nil,
                     tamper: ((String) -> String)? = nil, actions: [[String: Any]] = actions)
            -> (shown: [String], ran: [String], error: String?, relay: FakeRelay, refused: [RemoteReject]) {
            let relay = FakeRelay()
            let store = RemoteReplayStore(url: tempDir().appendingPathComponent("s.json"))
            defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
            var ran: [String] = [], refused: [RemoteReject] = []
            let sim = ShortcutSim()
            sim.menuChoice = choice; sim.askAnswer = ask; sim.fractionalDates = fractional
            if let grouped { sim.groupedNumbers = true; sim.groupingSeparator = grouped }
            sim.http = { relay.request($0, $1, $2) }
            relay.tamper = tamper
            sim.onDelay = {   // the Mac's side, while the phone waits
                for m in relay.topics[p.cmd] ?? [] {
                    let d = RemoteGatekeeper.evaluate(text: m, eventID: UUID().uuidString, eventTime: Int(Date().timeIntervalSince1970), pairing: p,
                                                      active: true, now: Date(), maxAge: 120, legacyUntil: nil, store: store, expiredText: "E", noticeText: "N")
                    if case .run(let c, _, let n?) = d {
                        ran.append(c)
                        relay.topics[p.reply, default: []].append(RemoteProtocol.sealReply(mac?(c) ?? "did: \(c)", pairingID: p.id, keys: p.keys!, nonce: n, now: Date()))
                    } else if case .drop(let why) = d { refused.append(why) }
                }
            }
            sim.run(actions)
            return (sim.shown, ran, sim.error, relay, refused)
        }
        let t0 = Date()
        let st = session(labels.status)
        check("shortcut: Status goes through the Mac and its answer is shown (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s on this Mac)",
              st.error == nil && st.ran == ["status"] && st.shown == ["did: status"])
        check("shortcut: the command travels in a POST body to a fixed URL", st.relay.topics[p.cmd]?.count == 1
              && st.relay.topics[p.cmd]?[0].hasPrefix("c2.\(p.id).") == true)
        let on = session(labels.turnOn, grouped: ",", fractional: true)
        check("shortcut: works when numbers are grouped and times have fractions", on.ran == ["on"] && on.shown == ["did: on"])
        let it = session(labels.turnOff, grouped: ".")
        check("shortcut: works with Italian-style grouping (123.456.789)", it.ran == ["off"] && it.shown == ["did: off"])

        // The defect seen on a real iPhone (v2.0): Generate Hash and Base64 Encode given a text with the variable inside
        // output nothing in Shortcuts, so every command reached the Mac without a tag ("malformed"). Rebuilt that way,
        // the checks and the simulator must both catch it.
        func reshaped(_ id: String) -> [[String: Any]] {
            actions.map { a in
                guard a["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.\(id)",
                      var q = a["WFWorkflowActionParameters"] as? [String: Any], let v = q["WFInput"] as? [String: Any],
                      v["WFSerializationType"] as? String == "WFTextTokenAttachment", let att = v["Value"] as? [String: Any] else { return a }
                q["WFInput"] = ["Value": ["string": "\u{FFFC}", "attachmentsByRange": ["{0, 1}": att]], "WFSerializationType": "WFTextTokenString"]
                var b = a; b["WFWorkflowActionParameters"] = q
                return b
            }
        }
        for id in ["hash", "base64encode"] {
            let old = reshaped(id)
            let data = try? PropertyListSerialization.data(fromPropertyList: ["WFWorkflowActions": old], format: .binary, options: 0)
            let found = RemoteShortcut.problems(data ?? Data()).contains { $0.contains("\(id): WFInput must be given as attachment") }
            let run = session(labels.status, actions: old)
            check("shortcut: \(id) given a text with the variable inside is caught (checks and simulator: nothing runs)",
                  found && run.ran.isEmpty && run.shown == [labels.noAnswer])
        }
        let viaURL = actions.map { a -> [String: Any] in    // the command in the URL instead of the body
            guard var q = a["WFWorkflowActionParameters"] as? [String: Any], q["WFHTTPMethod"] as? String == "POST",
                  let body = q["WFRequestVariable"] as? [String: Any], let att = body["Value"] as? [String: Any] else { return a }
            q = ["WFHTTPMethod": "GET", "UUID": q["UUID"] ?? "",
                 "WFURL": ["Value": ["string": "\(p.relay)/\(p.cmd)/publish?message=\u{FFFC}", "attachmentsByRange": ["{\(p.relay.count + p.cmd.count + 18), 1}": att]],
                           "WFSerializationType": "WFTextTokenString"]]
            var b = a; b["WFWorkflowActionParameters"] = q
            return b
        }
        let urlData = try? PropertyListSerialization.data(fromPropertyList: ["WFWorkflowActions": viaURL], format: .binary, options: 0)
        check("shortcut: variable content in a URL is refused by the checks", RemoteShortcut.problems(urlData ?? Data()).contains { $0.contains("WFURL must be given as constant") })
        let misspelt = actions.map { a -> [String: Any] in
            guard a["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.hash", var q = a["WFWorkflowActionParameters"] as? [String: Any] else { return a }
            q["WFHashType"] = "SHA-512"
            var b = a; b["WFWorkflowActionParameters"] = q
            return b
        }
        let misData = try? PropertyListSerialization.data(fromPropertyList: ["WFWorkflowActions": misspelt], format: .binary, options: 0)
        check("shortcut: an unknown parameter value is refused by the checks", RemoteShortcut.problems(misData ?? Data()).contains { $0.contains("is not a known value") })
        let nasty = #"send claude-x "a'b" $(id) `id` ; | && > ~/x é ✓ \ %41 + #"#
        let cmd = session(labels.command, ask: nasty)
        check("shortcut: typed text arrives exactly as typed (no quoting, no URL damage)", cmd.ran == [nasty] && cmd.shown == ["did: " + nasty])
        let longAnswer = String(repeating: "line of output é\n", count: 200)
        let big = session(labels.projects, mac: { _ in longAnswer })
        check("shortcut: a long, multi-line answer decrypts", big.shown.count == 1 && longAnswer.hasPrefix(big.shown[0]) && big.shown[0].count > 2000)
        let forgedAnswer = session(labels.status, tamper: { body in
            body.split(separator: "\n").map { line -> String in
                var q = line.split(separator: ".").map(String.init)
                guard q.count == 6 else { return String(line) }
                q[4] = String(q[4].reversed())
                return q.joined(separator: ".")
            }.joined(separator: "\n")
        })
        check("shortcut: a tampered answer is not shown", forgedAnswer.shown == [labels.noAnswer] && forgedAnswer.error == nil)
        let stolen = session(labels.status, tamper: { body in    // the relay swaps in a genuine answer to another request
            body + "\n" + RemoteProtocol.sealReply("fake", pairingID: p.id, keys: p.keys!, nonce: nonce(), now: Date())
        })
        check("shortcut: an answer to another request is never shown for this one", stolen.shown == ["did: status"])
        let silent = session(labels.status, mac: nil, tamper: { _ in "" })
        check("shortcut: no answer → says so", silent.shown == [labels.noAnswer])
        // Last reply: whatever came last, verified.
        let sim = ShortcutSim()
        let relay = FakeRelay()
        relay.topics[p.reply] = [RemoteProtocol.sealReply("older", pairingID: p.id, keys: p.keys!, nonce: nonce(), now: Date()),
                                 RemoteProtocol.sealReply("newest", pairingID: p.id, keys: p.keys!, nonce: nonce(), now: Date())]
        sim.http = { relay.request($0, $1, $2) }
        sim.menuChoice = labels.lastReply
        sim.run(actions)
        check("shortcut: Last reply shows the newest genuine answer, sends nothing", sim.shown == ["newest"] && relay.topics[p.cmd] == nil && sim.error == nil)
    }

    /// The listener against a relay that drops the connection after every delivery.
    static func listenerTests(_ p: Pairing, dir: URL, _ check: (String, Bool) -> Void) {
        let lock = NSLock()
        var ran: [String] = [], published: [String] = [], notes: [String] = []
        var publishStatus = 200
        var storeURL = dir.appendingPathComponent("listener.json")
        func listener() -> RemoteListener {
            var h = RemoteListener.Hooks(store: RemoteReplayStore(url: storeURL),
                                         execute: { c, _ in lock.lock(); ran.append(c); lock.unlock(); return "done \(c)" },
                                         publish: { body, _, _, _ in lock.withLock { published.append(body); return publishStatus } })
            h.configuration = { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [MockRelayProtocol.self]; return c }
            h.firstDelay = 0.05
            h.backoff = { _ in 0.05 }
            h.note = { n in lock.withLock { notes.append(n) } }
            return RemoteListener(hooks: h)
        }
        func codes() -> [String] { lock.withLock { notes.map { String($0.split(separator: " ")[2]) } } }
        func wait(_ s: Double) { Thread.sleep(forTimeInterval: s) }
        let k = p.keys!
        let t = Int(Date().timeIntervalSince1970)
        let a = RemoteProtocol.sealCommand("status", pairingID: p.id, keys: k, nonce: nonce(), ts: RemoteProtocol.timestamp(Date()))
        MockRelayProtocol.add(p.cmd, id: "e1", time: t, text: a)
        MockRelayProtocol.add(p.cmd, id: "e2", time: t, text: a)                  // the relay repeats it under another id
        MockRelayProtocol.add(p.cmd, id: "e3", time: t, text: "status")           // forged plain text
        var l: RemoteListener? = listener()
        l!.sync([p])
        wait(1.5)
        let connections = MockRelayProtocol.connections
        lock.lock(); let ran1 = ran, pub1 = published; lock.unlock()
        check("listener: reconnects after drops (\(connections) connections)", connections >= 5)
        check("listener: a command delivered on every reconnection runs once; forged text never", ran1 == ["status"])
        check("listener: its answer is published once, bound to it", pub1.count == 1
              && RemoteProtocol.openReply(pub1[0], pairingID: p.id, keys: k, nonce: String(a.split(separator: ".")[2])) == "done status")
        let c1 = codes()
        check("log: one line per outcome: relay-up once, accepted, reply-sent, replay, unauthenticated (\(Set(c1).sorted().joined(separator: ",")))",
              c1.filter { $0 == "relay-up" }.count == 1 && c1.filter { $0 == "accepted" }.count == 1 && c1.filter { $0 == "reply-sent" }.count == 1
              && c1.contains("replay") && c1.contains("unauthenticated") && !c1.contains("relay-down"))
        let all1 = lock.withLock { notes.joined(separator: "\n") }
        check("log: no key, topic, command or answer in it", !all1.contains(k.enc.prefix(16)) && !all1.contains(k.macIn.prefix(16)) && !all1.contains(p.cmd)
              && !all1.contains(p.reply) && !all1.contains("done status") && !all1.contains(String(a.split(separator: ".")[4].prefix(20))))
        check("log: lines name the pairing and the reason", lock.withLock { notes.allSatisfy { $0.hasPrefix("phone \(p.id.prefix(8)) ") } })
        l!.stop(); l = nil
        wait(0.2)
        l = listener()                                                            // a restart: fresh memory, same disk
        l!.sync([p])
        let b = RemoteProtocol.sealCommand("on", pairingID: p.id, keys: k, nonce: nonce(), ts: RemoteProtocol.timestamp(Date()))
        MockRelayProtocol.add(p.cmd, id: "e4", time: t + 1, text: b)              // sent while the Mac was "down"
        wait(1.0)
        lock.lock(); let ran2 = ran; lock.unlock()
        check("listener: after a restart, old commands don't run again and the one sent meanwhile runs once", ran2 == ["status", "on"])
        l!.sync([])                                                               // revoke
        let c = RemoteProtocol.sealCommand("off", pairingID: p.id, keys: k, nonce: nonce(), ts: RemoteProtocol.timestamp(Date()))
        MockRelayProtocol.add(p.cmd, id: "e5", time: t + 2, text: c)
        wait(0.6)
        lock.lock(); let ran3 = ran; lock.unlock()
        check("listener: after revoking, nothing runs", ran3 == ["status", "on"])
        l = nil

        // What the log says for each kind of refusal, and for an answer the relay doesn't take.
        do {
            let q = Pairing.make(tier: "basic", relay: "https://relay.test")!, qk = q.keys!
            let now = Date(), t = Int(now.timeIntervalSince1970)
            let good = RemoteProtocol.sealCommand("status", pairingID: q.id, keys: qk, nonce: nonce(), ts: RemoteProtocol.timestamp(now))
            let f = good.split(separator: ".").map(String.init)
            let untagged = f[0...4].joined(separator: ".") + "."                                      // what the broken Shortcut sent
            let badTag = f[0...4].joined(separator: ".") + "." + String(repeating: "0", count: 64)
            let stale = RemoteProtocol.sealCommand("status", pairingID: q.id, keys: qk, nonce: nonce(), ts: RemoteProtocol.timestamp(now.addingTimeInterval(-900)))
            let future = RemoteProtocol.sealCommand("status", pairingID: q.id, keys: qk, nonce: nonce(), ts: RemoteProtocol.timestamp(now.addingTimeInterval(900)))
            let foreign = RemoteProtocol.sealCommand("status", pairingID: p.id, keys: k, nonce: nonce(), ts: RemoteProtocol.timestamp(now))
            for (i, m) in [untagged, badTag, stale, future, foreign, good].enumerated() { MockRelayProtocol.add(q.cmd, id: "q\(i)", time: t, text: m) }
            lock.withLock { notes = []; publishStatus = 503 }
            storeURL = dir.appendingPathComponent("listener-log.json")   // the revoke above set a floor in the other one
            let m = listener()
            m.sync([q])
            wait(5.5)                                                      // three publish attempts, 1.5 s + 3 s apart
            m.stop()
            let c = codes(), text = lock.withLock { notes.joined(separator: "\n") }
            check("log: refusals carry their reason (\(Set(c).sorted().joined(separator: ",")))",
                  ["malformed", "bad-tag", "stale", "future", "unknown-pairing", "accepted"].allSatisfy(c.contains))
            check("log: a message without its tag is described by its form", text.contains("6 fields, lengths 2/16/") && text.contains("(bad tag)"))
            check("log: a stale message says how old it was", text.contains("stale age 900 s") || text.contains("stale age 899 s") || text.contains("stale age 901 s"))
            check("log: an answer the relay refuses is logged with its HTTP statuses", c.contains("reply-failed") && text.contains("HTTP 503, HTTP 503, HTTP 503"))
            lock.withLock { publishStatus = 200 }
        }

        // remote-phone.log itself
        do {
            let url = dir.appendingPathComponent("logs/remote-phone.log")
            let log = RemotePhoneLog(url: url, maxBytes: 4000)
            log.write("phone 0123abcd accepted basic\nforged line\u{1B}[2J")
            let first = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var st = stat()
            stat(url.path, &st)
            check("log file: private (0600), one line per event, control characters neutralized",
                  st.st_mode & 0o777 == 0o600 && first.split(separator: "\n").count == 1 && first.contains("accepted basic?forged line?[2J"))
            for i in 0..<200 { log.write("phone 0123abcd reply-sent \(i)") }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            let kept = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check("log file: bounded, keeps the newest lines whole", size <= 4100 && kept.hasSuffix("reply-sent 199\n")
                  && kept.split(separator: "\n").allSatisfy { $0.hasPrefix("20") })
        }
    }

    /// remote.zsh's gate, with a throwaway HOME/support folder and a stub engine: shell syntax never runs anything.
    static func gateTests(_ script: String, dir: URL, _ check: (String, Bool) -> Void) {
        let home = dir.appendingPathComponent("home", isDirectory: true)
        let support = home.appendingPathComponent("support", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let engine = dir.appendingPathComponent("engine")
        try? "#!/bin/sh\necho OFF\n".write(to: engine, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        let marker = dir.appendingPathComponent("pwned").path
        func gate(_ command: String, tier: String = "agents") -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [script, "gate", "--tier=\(tier)"]
            p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "COCAINE_SUPPORT": support.path, "COCAINE_ENGINE": engine.path,
                             "COCAINE_DOMAIN": "local.cocaine.test-\(getpid())", "COCAINE_SCREENDIR": home.appendingPathComponent("s").path,
                             "SSH_ORIGINAL_COMMAND": command]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }
        let attacks = ["status; touch \(marker)", "status && touch \(marker)", "status | touch \(marker)", "$(touch \(marker))",
                       "`touch \(marker)`", "status ${IFS}x", "on --for 1h; touch \(marker)", "log x; touch \(marker)",
                       "start claude ../../x", "start claude /tmp", "touch \(marker)", "status\ntouch \(marker)", "wake-info"]
        let codes = attacks.map { gate($0) }
        check("gate: shell syntax, paths and unknown commands are refused (\(codes.filter { $0 == 126 }.count)/\(attacks.count))", codes.allSatisfy { $0 == 126 })
        check("gate: …and none of them ran anything", !FileManager.default.fileExists(atPath: marker))
        check("gate: the basic level can't start agents", gate("start claude x hello", tier: "basic") == 126)
        check("gate: a plain allowed command passes", gate("status") == 0)
    }
}
