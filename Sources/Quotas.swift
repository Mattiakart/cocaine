// The AI providers' plan limits, from their own official local sources only (no Keychain, no OAuth, no network):
//   Claude Code: the statusline JSON it pipes to `statusLine.command` on every reply (`rate_limits.five_hour/seven_day`:
//   used_percentage and resets_at; only for Pro/Max plans, after the first reply). Cocaine puts itself in front of the user's
//   own statusline as a reversible wrapper (`Cocaine --statusline <previous command, base64>`): it keeps a few fields in its
//   private folder and runs the previous command with the same input and arguments, so an existing statusline keeps working.
//   Codex: the `rate_limits` of its session files (Usage.swift), named by each window's own length (`primary` may be weekly).

import AppKit
import SwiftUI

// MARK: - The wrapper in Claude Code's settings

enum StatusLineHook {
    static let marker = "# cocaine-statusline"

    /// The command that runs Cocaine in front of `previous` (nil: Claude Code had no statusline).
    static func command(binary: String, previous: String?) -> String {
        let arg = previous.map { Data($0.utf8).base64EncodedString() } ?? "-"
        return "'" + binary.replacingOccurrences(of: "'", with: "'\\''") + "' --statusline \(arg) \"$@\" \(marker)"
    }

    static func isOurs(_ command: String) -> Bool { command.contains(marker) && command.contains(" --statusline ") }

    /// The previous command carried by ours: .some(nil) when there was none; nil when ours can't be read.
    static func previous(in command: String) -> String?? {
        guard isOurs(command), let r = command.range(of: " --statusline ") else { return nil }
        let arg = command[r.upperBound...].prefix { $0 != " " }
        if arg == "-" { return .some(nil) }
        guard let d = Data(base64Encoded: String(arg)) else { return nil }
        return .some(String(decoding: d, as: UTF8.self))
    }

    private static func string(_ v: JSONValue?) -> String? {
        guard case .scalar(let raw)? = v, raw.hasPrefix("\"") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) as? String
    }

    /// Whether the settings' statusline is Cocaine's wrapper.
    static func installed(_ root: JSONValue) -> Bool { string(root["statusLine"]?["command"]).map(isOurs) ?? false }

    /// `root` with the wrapper put in front of the statusline (on) or taken out again (off). Only the "command" key changes;
    /// a statusline that wasn't there before goes again. nil = hands off (a statusline of a kind this can't wrap).
    static func edited(_ root: JSONValue, on: Bool, binary: String?) -> JSONValue? {
        guard root.members != nil else { return nil }
        var root = root
        let current = root["statusLine"]
        if on {
            guard let bin = binary else { return nil }
            guard let sl = current else {
                root["statusLine"] = .object([.init(key: "type", value: .string("command")),
                                              .init(key: "command", value: .string(command(binary: bin, previous: nil))),
                                              .init(key: "padding", value: .scalar("0"))])
                return root
            }
            guard sl.members != nil, string(sl["type"]) ?? "command" == "command", let cmd = string(sl["command"]) else { return nil }
            var s = sl
            if isOurs(cmd) {
                guard let prev = previous(in: cmd) else { return nil }
                s["command"] = .string(command(binary: bin, previous: prev))         // the same, or the app moved
            } else {
                s["command"] = .string(command(binary: bin, previous: cmd))
            }
            root["statusLine"] = s
            return root
        }
        guard let sl = current, let cmd = string(sl["command"]), isOurs(cmd) else { return root }      // not ours: as it is
        guard let prev = previous(in: cmd) else { return nil }
        if let prev {
            var s = sl
            s["command"] = .string(prev)
            root["statusLine"] = s
        } else {
            root["statusLine"] = nil
        }
        return root
    }

    static var settingsFile: String { AIHooks.home + "/.claude/settings.json" }

    static func isOn() -> Bool { AIHooks.load(settingsFile).map(installed) ?? false }

    /// Turns the wrapper on or off in ~/.claude/settings.json (keeping everything else as it is). False when it couldn't.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: AIHooks.home + "/.claude") else { return !on }
        guard let root = AIHooks.load(settingsFile), let new = edited(root, on: on, binary: AIHooks.binary) else { return false }
        if new == root { return true }
        return AIHooks.writeConfig(new.render() + "\n", to: settingsFile)
    }

    // MARK: the wrapper itself (`--statusline`)

    /// What is kept of one statusline input: the limits and the session's model, context and cost. No conversation text.
    static func record(_ j: [String: Any], now: Date) -> [String: Any]? {
        guard let session = AgentEventHook.sessionID(j) else { return nil }
        var out: [String: Any] = ["session": session, "at": now.timeIntervalSince1970]
        if let rl = j["rate_limits"] as? [String: Any] {
            var limits: [String: Any] = [:]
            for (k, v) in rl.prefix(8) {
                guard let w = v as? [String: Any], let pct = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
                var x: [String: Any] = ["used_percentage": pct]
                if let r = (w["resets_at"] as? NSNumber)?.doubleValue { x["resets_at"] = r }
                for f in ["used_usd", "limit_usd"] { if let n = (w[f] as? NSNumber)?.doubleValue { x[f] = n } }
                if let p = w["period"] as? String { x["period"] = String(p.prefix(20)) }
                limits[String(k.prefix(40))] = x
            }
            out["rate_limits"] = limits
        }
        if let m = (j["model"] as? [String: Any])?["display_name"] as? String { out["model"] = String(m.prefix(60)) }
        if let c = (j["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber { out["context"] = c.doubleValue }
        if let c = (j["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber { out["cost"] = c.doubleValue }
        if let e = (j["effort"] as? [String: Any])?["level"] as? String { out["effort"] = String(e.prefix(20)) }
        return out
    }

    static func folder(_ env: [String: String]) -> URL { AgentPaths.support(env).appendingPathComponent("claude-status", isDirectory: true) }

    /// Keeps the record, then runs the previous statusline with the same input and arguments and passes on what it prints and
    /// its exit status. Never fails the statusline because of Cocaine: a write that fails is skipped.
    static func run(args: [String], input: Data, env: [String: String], now: Date = Date(),
                    stdout: FileHandle = .standardOutput) -> Int32 {
        if let j = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any], let rec = record(j, now: now),
           let data = try? JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]), let s = rec["session"] as? String {
            let dir = folder(env)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = SafeFile.writePrivate(data, to: dir.appendingPathComponent(s + ".json"))
        }
        guard let first = args.first else { return 0 }
        let previous: String?
        if first == "-" { previous = nil }
        else if let d = Data(base64Encoded: first) { previous = String(decoding: d, as: UTF8.self) }
        else { previous = nil }
        guard let previous, !previous.isEmpty else { return 0 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", previous, "sh"] + args.dropFirst()               // its own arguments stay; ours become $1…
        var e = env
        e.removeValue(forKey: "COCAINE_SUPPORT")
        p.environment = e
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = stdout
        guard (try? p.run()) != nil else { return 0 }
        DispatchQueue.global().async {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// `--statusline [previous|-] [args…]`, run from main.swift by Claude Code (the wrapper above).
func cliStatusLine() {
    signal(SIGPIPE, SIG_IGN)
    let input = ApprovalHook.readInput(seconds: 2)
    exit(StatusLineHook.run(args: Array(CommandLine.arguments.dropFirst(2)), input: input, env: ProcessInfo.processInfo.environment))
}

/// `--quota-hook on|off|status [--home <dir>]`: the statusline wrapper from the command line (tests use a copy of a home).
func cliQuotaHook() {
    var args = Array(CommandLine.arguments.dropFirst(3))
    if let i = args.firstIndex(of: "--home"), i + 1 < args.count { AIHooks.home = args[i + 1]; args.removeSubrange(i...i + 1) }
    switch CommandLine.arguments[2] {
    case "on", "off": exit(StatusLineHook.set(CommandLine.arguments[2] == "on") ? 0 : 1)
    default: print("statusline: \(StatusLineHook.isOn() ? "on" : "off")"); exit(0)
    }
}

// MARK: - Reading the limits

/// One limit window as shown: its name from its length, how much is used, when it resets.
struct QuotaWindow: Equatable, Identifiable {
    var id: String
    var minutes: Int?
    var percent: Double
    var resets: Date?
    /// Its reset time has passed with no news since: shown as reset (0 %), not as the old number.
    var wasReset = false
    var spend: (used: Double, limit: Double)? = nil
    static func == (a: QuotaWindow, b: QuotaWindow) -> Bool {
        a.id == b.id && a.minutes == b.minutes && a.percent == b.percent && a.resets == b.resets && a.wasReset == b.wasReset
            && a.spend?.used == b.spend?.used && a.spend?.limit == b.spend?.limit
    }

    /// "5 h", "Week", "Day", "Month", "Spending" in the app's language.
    var name: String {
        if id == "spend_limit" { return L("Spending") }
        guard let m = minutes else { return id }
        return Quotas.windowName(m)
    }
}

enum Quotas {
    static func windowName(_ minutes: Int) -> String {
        minutes >= 40000 ? L("Month") : minutes >= 10000 ? L("Week") : minutes >= 1440 ? L("Day") : String(format: L("%d h"), max(1, minutes / 60))
    }

    /// "2 d 4 h", "3 h 10 min", "12 min", "now".
    static func resetsIn(_ seconds: Int) -> String {
        guard seconds >= 60 else { return L("now") }
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return String(format: L("%d d"), d) + (h > 0 ? " " + String(format: L("%d h"), h) : "") }
        if h > 0 { return String(format: L("%d h"), h) + (m > 0 ? " " + String(format: L("%d min"), m) : "") }
        return String(format: L("%d min"), m)
    }

    struct ClaudeStatus: Equatable {
        var windows: [QuotaWindow] = []
        var at: Date?                       // when Claude Code last reported them
        var sessions: [String: (model: String?, context: Double?)] = [:]
        static func == (a: ClaudeStatus, b: ClaudeStatus) -> Bool {
            a.windows == b.windows && a.at == b.at && a.sessions.keys.sorted() == b.sessions.keys.sorted()
        }
    }

    /// The newest limits among the wrapper's records (and every recent session's model and context). Records older than a week
    /// are deleted. Pure apart from the folder it is given.
    static func claude(folder: URL, now: Date = Date()) -> ClaudeStatus {
        var out = ClaudeStatus()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var newest: (Double, [String: Any])?
        for f in files.prefix(500) where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), d.count < 65536,
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let at = (j["at"] as? NSNumber)?.doubleValue else { continue }
            if now.timeIntervalSince1970 - at > 7 * 86400 { try? FileManager.default.removeItem(at: f); continue }
            if let s = j["session"] as? String, now.timeIntervalSince1970 - at < 86400 {
                out.sessions[s] = (j["model"] as? String, (j["context"] as? NSNumber)?.doubleValue)
            }
            if let rl = j["rate_limits"] as? [String: Any], !rl.isEmpty, at > (newest?.0 ?? -1) { newest = (at, rl) }
        }
        guard let (at, rl) = newest else { return out }
        out.at = Date(timeIntervalSince1970: at)
        out.windows = windows(rl, now: now)
        return out
    }

    /// Claude Code's `rate_limits` object as windows, the 5-hour one first.
    static func windows(_ rl: [String: Any], now: Date) -> [QuotaWindow] {
        let known = ["five_hour": 300, "seven_day": 10080, "seven_day_opus": 10080, "seven_day_sonnet": 10080]
        var out: [QuotaWindow] = []
        for (k, v) in rl {
            guard let w = v as? [String: Any], let pct = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            var q = QuotaWindow(id: k, minutes: known[k], percent: min(max(pct, 0), 100),
                                resets: ((w["resets_at"] as? NSNumber)?.doubleValue).map { Date(timeIntervalSince1970: $0) })
            if let r = q.resets, r <= now { q.wasReset = true; q.percent = 0 }
            if let u = (w["used_usd"] as? NSNumber)?.doubleValue, let l = (w["limit_usd"] as? NSNumber)?.doubleValue { q.spend = (u, l) }
            out.append(q)
        }
        let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "spend_limit"]
        return out.sorted { (order.firstIndex(of: $0.id) ?? 99, $0.id) < (order.firstIndex(of: $1.id) ?? 99, $1.id) }
    }
}

// MARK: - The compact quota module (ModuleCatalog "quotas")

extension IslandView {
    /// Plan limits only, one bar per window: Claude Code's and Codex's.
    func quotasModule(_ b: ModuleBox) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(L("AI limits")).font(UI.section).foregroundStyle(UI.secondary)
            let rows = usage.claudeLimits.map { ("Claude", $0) } + usage.codex.map { ("Codex", $0.window()) }
            if rows.isEmpty {
                Text(usage.loaded ? L("No limits reported yet") : "…").font(UI.value).foregroundStyle(UI.hint).shimmer(!usage.loaded)
            }
            ForEach(Array(rows.prefix(b.size == .s ? 2 : 4).enumerated()), id: \.offset) { _, r in
                QuotaBar(provider: r.0, window: r.1, compact: true)
            }
        }
        .onAppear { usage.refresh() }
    }
}

/// One limit: provider and window name, percent used, a bar, and the time to its reset.
struct QuotaBar: View {
    let provider: String
    let window: QuotaWindow
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(compact ? "\(provider) · \(window.name)" : window.name).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                Spacer(minLength: Space.xs)
                Text("\(Int(window.percent.rounded()))%").font(UI.metric).motionNumber(Int(window.percent.rounded()))
            }
            Capsule().fill(Color.white.opacity(0.12)).frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { r in
                        Capsule().fill(window.percent >= 90 ? Color.orange : Island.accent)
                            .frame(width: r.size.width * min(1, window.percent / 100))
                    }
                }
            if !compact || window.resets != nil {
                TimelineView(.periodic(from: .now, by: 60)) { ctx in
                    Text(resetText(ctx.date)).font(UI.detail).foregroundStyle(UI.hint).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider), \(window.name)")
        .accessibilityValue(Self.spoken(window, now: Date()))
    }

    /// What VoiceOver reads: "23%, Resets in 2 h", or the percent alone when no reset time is known (no dangling comma).
    static func spoken(_ w: QuotaWindow, now: Date) -> String {
        let reset = resetText(w, now)
        return "\(Int(w.percent.rounded()))%" + (reset.isEmpty ? "" : ", " + reset)
    }

    static func resetText(_ w: QuotaWindow, _ now: Date) -> String {
        if w.wasReset { return L("Reset: no new reading yet") }
        guard let r = w.resets else { return "" }
        if r <= now { return L("Reset: no new reading yet") }          // passed while shown: never "resets in now" for good
        return String(format: L("Resets in %@"), Quotas.resetsIn(Int(r.timeIntervalSince(now))))
    }

    func resetText(_ now: Date) -> String { Self.resetText(window, now) }
}

// MARK: - Tests (part of --agents-test): temporary homes and folders only, never ~/.claude

enum QuotaTests {
    static func run(_ check: (String, Bool) -> Void) {
        let bin = "/Applications/Cocaine.app/Contents/MacOS/Cocaine"
        // The settings edit: on, on again, off → exactly as before; an existing statusline is kept and forwarded.
        let original = #"{"model": "opus", "statusLine": {"type": "command", "command": "ccstatusline --compact 'a b'", "padding": 2}, "hooks": {}}"#
        guard let root = JSONValue.parse(original) else { check("quota: fixture parses", false); return }
        let on = StatusLineHook.edited(root, on: true, binary: bin)
        let on2 = on.flatMap { StatusLineHook.edited($0, on: true, binary: bin) }
        let cmd: String? = { guard case .scalar(let s)? = on?["statusLine"]?["command"] else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])) as? String }()
        check("quota: on puts the wrapper in front of the user's statusline (padding and the rest kept)",
              on.map(StatusLineHook.installed) == true && on?["statusLine"]?["padding"] == .scalar("2") && on?["model"] == .scalar("\"opus\""))
        check("quota: the wrapper carries the previous command whole (its arguments too)",
              cmd.flatMap { StatusLineHook.previous(in: $0) } == .some("ccstatusline --compact 'a b'"))
        check("quota: on twice is the same file", on2 == on)
        let off = on.flatMap { StatusLineHook.edited($0, on: false, binary: bin) }
        check("quota: off gives back exactly the statusline that was there", off.map { $0.render() } == root.render())
        let bare = JSONValue.parse(#"{"hooks": {}}"#)!
        let bareOn = StatusLineHook.edited(bare, on: true, binary: bin)
        check("quota: with no statusline before, off removes the one it added",
              bareOn.map(StatusLineHook.installed) == true && bareOn.flatMap { StatusLineHook.edited($0, on: false, binary: bin) } == bare)
        check("quota: a statusline that isn't a command is left alone",
              StatusLineHook.edited(JSONValue.parse(#"{"statusLine": {"type": "static", "text": "x"}}"#)!, on: true, binary: bin) == nil)
        check("quota: off without ours changes nothing", StatusLineHook.edited(root, on: false, binary: bin) == root)
        check("quota: without an installed app nothing is written", StatusLineHook.edited(root, on: true, binary: nil) == nil)

        // The wrapper itself, in a temp folder, with a fake previous statusline that prints its input and arguments.
        let dir = AgentTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("prev.sh")
        try? "#!/bin/sh\nprintf 'args=%s|' \"$@\"; cat\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o700)
        let sample = #"{"session_id":"sess-1","model":{"id":"claude-opus","display_name":"Opus"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":1.5},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":4102444800},"seven_day":{"used_percentage":41.2,"resets_at":4102444800}},"transcript_path":"/secret/path.jsonl"}"#
        let outFile = dir.appendingPathComponent("out.txt")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        let h = FileHandle(forWritingAtPath: outFile.path)!
        let prev = "'\(script.path)' --flag 'two words'"
        let status = StatusLineHook.run(args: [Data(prev.utf8).base64EncodedString(), "extra"], input: Data(sample.utf8),
                                        env: ["COCAINE_SUPPORT": dir.path, "PATH": "/usr/bin:/bin"], stdout: h)
        try? h.close()
        let printed = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        check("quota: the previous statusline gets the same input and its arguments, ours after (\(printed.prefix(80)))",
              status == 0 && printed.hasPrefix("args=--flag|args=two words|") && printed.hasSuffix(sample))
        let out2 = dir.appendingPathComponent("out2.txt")
        FileManager.default.createFile(atPath: out2.path, contents: nil)
        let h2 = FileHandle(forWritingAtPath: out2.path)!
        _ = StatusLineHook.run(args: [Data("'\(script.path)' \"$@\"".utf8).base64EncodedString(), "x y", "z"], input: Data("{}".utf8),
                               env: ["COCAINE_SUPPORT": dir.path, "PATH": "/usr/bin:/bin"], stdout: h2)
        try? h2.close()
        check("quota: arguments given to the wrapper reach a previous statusline that uses \"$@\", intact",
              (try? String(contentsOf: out2, encoding: .utf8)) == "args=x y|args=z|{}")
        let rec = StatusLineHook.folder(["COCAINE_SUPPORT": dir.path]).appendingPathComponent("sess-1.json")
        let perms = (try? FileManager.default.attributesOfItem(atPath: rec.path))?[.posixPermissions] as? Int
        let recText = (try? String(contentsOf: rec, encoding: .utf8)) ?? ""
        check("quota: the record is private (0600) and holds limits, not the transcript path",
              perms == 0o600 && recText.contains("five_hour") && !recText.contains("secret"))
        let q = Quotas.claude(folder: StatusLineHook.folder(["COCAINE_SUPPORT": dir.path]), now: Date())
        check("quota: Claude's 5-hour and weekly windows, named by their length",
              q.windows.map(\.id) == ["five_hour", "seven_day"] && q.windows[0].percent == 23.5 && q.windows[0].minutes == 300 && q.windows[1].minutes == 10080
              && q.sessions["sess-1"]?.model == "Opus")
        let later = Quotas.windows(["five_hour": ["used_percentage": 80, "resets_at": 1_000], "seven_day": ["used_percentage": 40, "resets_at": 4_102_444_800]], now: Date())
        check("quota: a window past its reset shows as reset, not the old number", later[0].wasReset && later[0].percent == 0 && !later[1].wasReset && later[1].percent == 40)
        let none = StatusLineHook.run(args: ["-"], input: Data("not json".utf8), env: ["COCAINE_SUPPORT": dir.path])
        check("quota: no previous statusline and bad input: prints nothing, never fails", none == 0)

        // Codex: `primary` can be the weekly window (as on this Mac in September 2026): named by window_minutes.
        let weekly = #"{"timestamp":"2026-09-30T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":36.0,"window_minutes":10080,"resets_at":1791000000},"secondary":null,"credits":{"has_credits":false,"balance":"0"},"plan_type":"prolite","rate_limit_reached_type":null}}}"#
        let lim = CodexUsage.parse(weekly) ?? []
        check("quota: Codex's primary window may be weekly: named Week, not 5 h", lim.count == 1 && lim[0].minutes == 10080 && Quotas.windowName(lim[0].minutes) == L("Week"))
        check("quota: Codex's plan type is read", CodexUsage.planType(weekly) == "prolite")
        check("quota: reset countdowns", Quotas.resetsIn(2 * 86400 + 4 * 3600 + 5) == String(format: L("%d d"), 2) + " " + String(format: L("%d h"), 4)
              && Quotas.resetsIn(30) == L("now") && Quotas.resetsIn(3 * 3600) == String(format: L("%d h"), 3))

    }

    /// The real CLI on a temp home (--quota-hook on/on/off), with this binary.
    static func cli(binary: String, _ check: (String, Bool) -> Void) {
        let bin = "/Applications/Cocaine.app/Contents/MacOS/Cocaine"
        let original = #"{"model": "opus", "statusLine": {"type": "command", "command": "ccstatusline --compact 'a b'", "padding": 2}, "hooks": {}}"#
        let home = AgentTests.tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try? FileManager.default.createDirectory(atPath: home.path + "/.claude", withIntermediateDirectories: true)
        let settings = home.path + "/.claude/settings.json"
        try? original.write(toFile: settings, atomically: true, encoding: .utf8)
        func cli(_ a: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = a
            var env = ProcessInfo.processInfo.environment
            env["COCAINE_HOOK_BINARY"] = bin
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            return p.terminationStatus
        }
        let a = cli(["--quota-hook", "on", "--home", home.path])
        let afterOn = (try? String(contentsOfFile: settings, encoding: .utf8)) ?? ""
        _ = cli(["--quota-hook", "on", "--home", home.path])
        let afterOn2 = (try? String(contentsOfFile: settings, encoding: .utf8)) ?? ""
        _ = cli(["--quota-hook", "off", "--home", home.path])
        let afterOff = (try? String(contentsOfFile: settings, encoding: .utf8)) ?? ""
        check("quota: --quota-hook on/on/off in a temp home: idempotent, then back to the same settings",
              a == 0 && afterOn.contains("--statusline") && afterOn == afterOn2 && JSONValue.parse(afterOff) == JSONValue.parse(original))
    }
}
