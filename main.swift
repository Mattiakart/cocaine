// Cocaine — menu-bar front end for ~/bin/cocaine.
//
// Shows whether Cocaine is on (full baggie) or off (empty baggie) in the menu bar; clicking it opens a
// panel that stays open while you change things. It toggles Cocaine through the engine script bundled in
// Contents/Resources/cocaine, which owns the caffeinate -d display hold; the first time it needs to, the app
// asks for an admin password once to install a narrow sudo rule for `pmset -a disablesleep 1|0`. While Cocaine is
// on it restarts that display hold if it is missing (e.g. after a restart) and, after the chosen
// idle time, lowers the built-in display to the chosen minimum brightness (never below 1%, so the
// screen never goes off), restoring the previous brightness on the next keyboard/trackpad input.
// `cocaine://alert` URLs (from AI agents' hooks, which the "AI alerts" switch adds to Claude Code and Codex) wake and
// flash the screens when you're away.

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

// MARK: - Entry point

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--agent-request" {
    // Run by Claude Code's and Codex's request hooks (`AIHooks.command(_, "approve")`): hands the request to the running app
    // and prints its signed answer as the tool's documented hook output, or nothing (the tool then asks in the terminal).
    // Never a decision of its own; always exit 0 (exit 2 would mean "block" to some tools).
    signal(SIGPIPE, SIG_IGN)
    let env = ProcessInfo.processInfo.environment
    let timeout = env["COCAINE_HOOK_TIMEOUT"].flatMap(Double.init).map { min(max($0, 1), ApprovalTiming.hook) } ?? ApprovalTiming.hook
    if let out = ApprovalHook.run(tool: CommandLine.arguments[2], input: ApprovalHook.readInput(), env: env, timeout: timeout) { print(out) }
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--agents-test" {
    // AI sessions: the pure logic, the approval protocol over a real socket with this binary as the hook, and the hooks
    // written into a temporary home (never the real ~/.claude or ~/.codex). PASS/FAIL lines, exit status.
    var failed = 0
    func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    AgentTests.pure(check)
    AgentTests.protocolTests(binary: exe, check)
    let home = AgentTests.tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    AIHooks.home = home.path
    AIHooks.binary = "/Applications/Cocaine.app/Contents/MacOS/Cocaine"
    AIHooks.assumeClaudeVersion([2, 1, 100])
    for d in [".claude", ".codex"] { try? FileManager.default.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true) }
    let settingsPath = home.appendingPathComponent(".claude/settings.json").path
    let mine = #"{"model":"opus","hooks":{"PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-guard.sh"}]}]}}"#
    try? mine.write(toFile: settingsPath, atomically: true, encoding: .utf8)
    let claude = AIHooks.tool("claude")!, codex = AIHooks.tool("codex")!
    func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func commands(_ path: String, _ event: String) -> [String] {
        (AIHooks.load(path)?["hooks"]?[event]?.items ?? []).flatMap { $0["hooks"]?.items ?? [] }.compactMap {
            if case .scalar(let s)? = $0["command"] { return (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed)) as? String }
            return nil
        }
    }
    check("hooks: on (temporary home)", AIHooks.set(true, only: [claude, codex]).isEmpty)
    let pr = commands(settingsPath, "PermissionRequest")
    check("hooks: Claude Code's PermissionRequest runs the app's binary next to the user's own hook",
          pr.count == 2 && pr.contains("my-guard.sh") && pr.contains { $0.contains("'/Applications/Cocaine.app/Contents/MacOS/Cocaine' --agent-request claude") })
    check("hooks: the request hook may wait for the notch (timeout \(ApprovalTiming.config) s)", text(settingsPath).contains("\"timeout\": \(ApprovalTiming.config)"))
    check("hooks: MCP questions (Elicitation) too, and the alerts as before",
          commands(settingsPath, "Elicitation").count == 1 && commands(settingsPath, "Notification").count == 1 && commands(settingsPath, "Stop").count == 1)
    check("hooks: alert commands also send where the session runs", commands(settingsPath, "Stop").first?.contains("\"$PPID\"") == true)
    let once = text(settingsPath)
    _ = AIHooks.set(true, only: [claude, codex])
    check("hooks: turning on twice changes nothing", text(settingsPath) == once)
    check("hooks: Codex's PermissionRequest runs the binary as well",
          commands(codex.file, "PermissionRequest").first?.contains("--agent-request codex") == true)
    check("hooks: off", AIHooks.set(false, only: [claude, codex]).isEmpty)
    let off = text(settingsPath)
    check("hooks: off removes only Cocaine's hooks; the user's own and their settings stay",
          !off.contains(AIHooks.marker) && commands(settingsPath, "PermissionRequest") == ["my-guard.sh"] && off.contains("\"model\": \"opus\""))
    _ = AIHooks.set(false, only: [claude, codex])
    check("hooks: off twice changes nothing", text(settingsPath) == off)
    AIHooks.assumeClaudeVersion([2, 0, 0])
    _ = AIHooks.set(true, only: [claude])
    check("hooks: an older Claude Code gets no request hooks it doesn't know",
          commands(settingsPath, "PermissionRequest") == ["my-guard.sh"] && commands(settingsPath, "Elicitation").isEmpty)
    AIHooks.assumeClaudeVersion([2, 1, 100])
    AIHooks.update()
    check("hooks: …and gets them once it's updated (at the app's launch)", commands(settingsPath, "PermissionRequest").count == 2)
    AIHooks.binary = nil
    _ = AIHooks.set(true, only: [claude, codex])
    check("hooks: without an installed app to run, no request hooks for Claude Code (its Notification alerts)",
          commands(settingsPath, "PermissionRequest") == ["my-guard.sh"])
    check("hooks: …and Codex's request just alerts as before", commands(codex.file, "PermissionRequest").first.map { $0.contains("event=input") && !$0.contains("--agent-request") } == true)
    _ = AIHooks.set(false, only: [claude, codex])

    // The origin the alert command sends, run by a real shell, read back by the app's own parser.
    AIHooks.binary = exe
    let stop = AIHooks.command(claude, "done")
    if let a = stop.range(of: "$(/usr/bin/perl -e 'sub e"), let b = stop.range(of: "\"$PPID\" 2>/dev/null)", range: a.upperBound..<stop.endIndex) {
        let snippet = String(stop[a.lowerBound..<b.upperBound])
        let odd = home.appendingPathComponent("my proj&x=1")
        try? FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "cd \"$1\" && x=" + snippet + "; printf %s \"$x\"", "sh", odd.path]
        p.environment = ["TMUX_PANE": "%7", "TMUX": "/private/tmp/tmux-501/default,123,0", "__CFBundleIdentifier": "com.googlecode.iterm2",
                         "ITERM_SESSION_ID": "w0t1p0:ABCDEF12-0000-1111", "TERM_PROGRAM": "iTerm.app", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let q = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let got = AlertParams.parse(URL(string: "cocaine://alert?from=Claude%20Code&event=done" + q)!).origin
        check("hooks: the session's origin survives the shell, the URL and the parser (\(q.prefix(60))…)",
              got.cwd == odd.resolvingSymlinksInPath().path || got.cwd == odd.path)
        check("hooks: …with its terminal app, iTerm2 session, tmux pane and socket, and the agent's pid",
              got.app == "com.googlecode.iterm2" && got.termSession == "ABCDEF12-0000-1111" && got.tmuxPane == "%7"
              && got.tmuxSocket == "/private/tmp/tmux-501/default" && got.pid == getpid())
    } else { check("hooks: the alert command carries the origin snippet", false) }

    // The exact request-hook command, run by a real shell against a real socket.
    let support = AgentTests.tempDir()
    defer { try? FileManager.default.removeItem(at: support) }
    if let key = ApprovalKey.loadOrCreate(AgentPaths.key(support)) {
        let server = ApprovalServer(path: AgentPaths.socket(support), key: key)
        server.onRequest = { id, _, _, _, _ in server.reply(id, decision: "deny", content: nil) }
        try? server.start()
        let cmd = AIHooks.command(claude, "approve")
        let r = AgentTests.runHook(["-c", cmd], executable: "/bin/sh", input: AgentTests.sampleInput, support: support)
        check("hooks: the installed request command, run by sh, returns the notch's answer", r.out.contains(#""behavior":"deny""#) && r.status == 0)
        server.stop()
        let none = AgentTests.runHook(["-c", cmd], executable: "/bin/sh", input: AgentTests.sampleInput, support: support)
        check("hooks: …and nothing, exit 0, when the app isn't there", none.out.isEmpty && none.status == 0)
        let moved = AgentTests.runHook(["-c", cmd.replacingOccurrences(of: exe, with: "/nonexistent/Cocaine")], executable: "/bin/sh",
                                       input: AgentTests.sampleInput, support: support)
        check("hooks: …and when the app was moved away (exit 0, no decision)", moved.out.isEmpty && moved.status == 0)
    }
    exit(failed == 0 ? 0 : 1)
}
if let code = RecoveryCLI.run(CommandLine.arguments) { exit(code) }   // --recover-after, --prepare-update, … (Sources/Recovery.swift)
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--recovery-test" { exit(RecoveryTest.run()) }
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--recovery-owner" { RecoveryTest.owner(Array(CommandLine.arguments.dropFirst(2))) }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--instance-check" {   // would a launch now give way? 1 = yes
    exit(Recovery.claimSingleInstance(wait: 1) ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--recovery-standin" { while true { sleep(600) } }   // the test's OSDUIHelper
if let status = DistCLI.run(CommandLine.arguments) { exit(status) }   // release tooling and updater/signature tests
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--auth-selftest" {
    // Runs the exact install pipeline (AppleScript quoting, printf, visudo, install) without admin rights,
    // writing the rule to the given file instead of /etc/sudoers.d.
    let cmd = Authorization.installCommand(user: NSUserName(), dest: CommandLine.arguments[2], asRoot: false)!
    exit(run("/usr/bin/osascript", ["-e", Authorization.appleScript(for: cmd, admin: false)]))
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--layout-test" {
    // Where the panel lands for a click on the icon of each screen, for two-monitor layouts.
    let size = NSSize(width: Layout.width, height: 198)
    let layouts: [(String, NSRect, CGFloat)] = [   // name, visible frame (below its menu bar), click x
        ("MacBook, icon near right edge", NSRect(x: 0, y: 0, width: 1512, height: 945), 1460),
        ("external on the right",         NSRect(x: 1512, y: -200, width: 2560, height: 1415), 3900),
        ("external on the left",          NSRect(x: -1920, y: 0, width: 1920, height: 1055), -60),
        ("external above",                NSRect(x: 0, y: 982, width: 1920, height: 1055), 1850),
    ]
    for (name, vis, x) in layouts {
        let f = AppDelegate.panelFrame(size: size, anchorX: x, top: vis.maxY - 6, visible: vis)
        print("\(name): panel \(f.debugDescription)  inside that screen: \(vis.contains(f))")
    }
    // The panel's top strip on other Macs' notches (14" ≈ 185 pt; scaled resolutions make it narrower or wider): no cell under
    // the notch, all inside the frame, none narrower than 24 pt; with and without the AI tab. Too wide a notch: no strip (nil),
    // the panel then shows its tabs as a segmented control, which is also fine.
    var stripFailures = 0
    for notch: CGFloat in [150, 165, 185, 200, 210, 220] {
        for left in [2, 3] {      // back + General (+ AI alerts) | Automation + Island + Quit
            guard let s = StripLayout.make(panelWidth: Layout.width, frameInset: Space.frame, contentInset: Space.l, notchWidth: notch, left: left, right: 3) else {
                print("FAIL  strip, notch \(Int(notch)) pt, \(left)+3 cells: doesn't fit"); stripFailures += 1; continue
            }
            let p = s.problems()
            if !p.isEmpty { stripFailures += 1 }
            print("\(p.isEmpty ? "PASS" : "FAIL")  strip, notch \(Int(notch)) pt, \(left)+3 cells: cell \(s.cell), highlight \(s.highlight), left \(s.leftCells.map { "\($0.lowerBound)…\($0.upperBound)" }), right \(s.rightCells.map { "\($0.lowerBound)…\($0.upperBound)" })" + (p.isEmpty ? "" : " " + p.joined(separator: "; ")))
        }
    }
    let tooWide = StripLayout.make(panelWidth: Layout.width, frameInset: Space.frame, contentInset: Space.l, notchWidth: 300, left: 3, right: 2)
    print(tooWide == nil ? "PASS  strip, notch 300 pt: no strip (tabs fall back to the segmented control)" : "FAIL  strip, notch 300 pt: cells of \(tooWide!.cell) pt")
    if tooWide != nil { stripFailures += 1 }
    // The old layout (4 cells of 38 pt left of a 185 pt notch) must be refused: it put the Automation tab under the notch.
    let old = StripLayout(panelWidth: Layout.width, frameInset: Space.frame, notchWidth: 185, cell: 38, side: 113.5, edgeInset: 4, left: 4, right: 2)
    print(old.problems().isEmpty ? "FAIL  strip: the old 4×38 pt layout isn't caught" : "PASS  strip: the old 4×38 pt layout is caught (\(old.problems()[0]))")
    if old.problems().isEmpty { stripFailures += 1 }
    exit(stripFailures == 0 ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--gamma-test" {
    // Software dimming on the main screen for a moment (what non-Apple monitors get), then restored.
    let d = CGMainDisplayID(), screens = Screens()
    func maxRed() -> Float {
        var rMin: CGGammaValue = 0, rMax: CGGammaValue = 0, rG: CGGammaValue = 0, gMin: CGGammaValue = 0, gMax: CGGammaValue = 0
        var gG: CGGammaValue = 0, bMin: CGGammaValue = 0, bMax: CGGammaValue = 0, bG: CGGammaValue = 0
        CGGetDisplayTransferByFormula(d, &rMin, &rMax, &rG, &gMin, &gMax, &gG, &bMin, &bMax, &bG)
        return rMax
    }
    print("before: \(maxRed())")
    screens.setGamma(d, 0.4); usleep(800_000); print("dimmed: \(maxRed())")
    screens.restoreGamma(); usleep(200_000); print("restored: \(maxRed())")
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--auth-preview" {
    // Shows the admin prompt without running anything (to check how it looks).
    _ = NSApplication.shared
    exit(Authorization.authorize(prompt: L("Cocaine needs your permission once, to keep your Mac awake.")) { _ in true } ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--remove-rule" {
    _ = NSApplication.shared
    exit(Authorization.remove() ? 0 : 1)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--share-test" {
    // Activates the app and performs a sharing service ("airdrop" or "notes") on the signed shortcut, then reports the
    // windows that appear (for tests).
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let file = PhoneShortcut.signedFile(PhoneLink.newPairing(tier: "basic")!) else { print("could not sign"); exit(1) }
    app.activate()
    let services = NSSharingService.sharingServices(forItems: [file])
    print("services: " + services.map(\.title).joined(separator: ", "))
    guard let service = services.first(where: { $0.title.lowercased().contains(CommandLine.arguments[2]) }) else { print("no such service"); exit(1) }
    service.perform(withItems: [file])
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
        let windows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
            
        print("windows: \(windows.filter { ($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0 > 100 }.map { "\($0[kCGWindowOwnerName as String] ?? "")/\($0[kCGWindowName as String] ?? "")" })")
        exit(0)
    }
    app.run()
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--make-shortcut" {
    // Builds and signs the iPhone Shortcut, copies it to the given path (for tests).
    guard let f = PhoneShortcut.signedFile(PhoneLink.newPairing(tier: "basic")!) else { print("could not sign"); exit(1) }
    try? FileManager.default.removeItem(atPath: CommandLine.arguments[2])
    try? FileManager.default.copyItem(at: f, to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("ok")
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--relay-test" {
    // A real round trip through the relay with a throwaway pairing (and its own state file): sends an authenticated,
    // encrypted unknown command ("ping-test"), which the gate refuses, and expects that refusal back, encrypted, for that
    // request. Nothing about this Mac leaves it in clear.
    let pairing = PhoneLink.newPairing(tier: "basic")!, keys = pairing.keys!
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-relay-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    var hooks = RemoteListener.Hooks(store: RemoteReplayStore(url: dir.appendingPathComponent("state.json")),
                                     execute: { PhoneLink.execute($0, tier: $1) },
                                     publish: { await PhoneLink.publish($0, to: $1, relay: $2, session: $3) })
    hooks.firstDelay = 1
    let listener = RemoteListener(hooks: hooks)
    func send(_ text: String) -> String {
        let n = (0..<3).map { _ in String(Int.random(in: 100_000_000...999_999_999)) }.joined()
        _ = RelayTest.curl("\(PhoneLink.relay)/\(pairing.cmd)/publish?message=" +
                           RemoteProtocol.sealCommand(text, pairingID: pairing.id, keys: keys, nonce: n, ts: RemoteProtocol.timestamp(Date())))
        return n
    }
    func answers(_ nonce: String) -> [String] {
        RelayTest.curl("\(PhoneLink.relay)/\(pairing.reply)/raw?poll=1&since=120s").split(separator: "\n")
            .compactMap { RemoteProtocol.openReply(String($0), pairingID: pairing.id, keys: keys, nonce: nonce) }
    }
    listener.sync([pairing])
    Thread.sleep(forTimeInterval: 4)
    let n1 = send("ping-test")
    var answer: [String] = []
    for _ in 0..<12 where answer.isEmpty { Thread.sleep(forTimeInterval: 1.5); answer = answers(n1) }
    let first = answer.count == 1 && answer[0].contains("not allowed")
    print(first ? "PASS  relay round trip: \(answer[0])" : "FAIL  relay round trip: \(answer)")
    // What a sleeping Mac does: the connection is gone, a command arrives meanwhile, and the next wake picks it up.
    listener.stop()
    Thread.sleep(forTimeInterval: 1)
    let n2 = send("ping-while-asleep")
    Thread.sleep(forTimeInterval: 2)
    listener.maxAge = { WakeSchedule.maxCommandAge }
    listener.sync([pairing])
    var second: [String] = []
    for _ in 0..<12 where second.isEmpty { Thread.sleep(forTimeInterval: 1.5); second = answers(n2) }
    print(second.count == 1 ? "PASS  command sent while disconnected is answered after reconnect (once)" : "FAIL  after reconnect: \(second.count) answers")
    Thread.sleep(forTimeInterval: 4)
    listener.reconnect()                                    // the wake-up path: no repeat of what was already handled
    Thread.sleep(forTimeInterval: 6)
    let total = answers(n1).count + answers(n2).count
    print(total == 2 ? "PASS  reconnect doesn't run old commands again" : "FAIL  reconnect repeated a command: \(total) answers")
    exit(first && second.count == 1 && total == 2 ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--remote-test" {
    // Remote control protocol, Shortcut and listener tests only (also part of --selftest).
    var failed = 0
    RemoteTests.run(gate: Bundle.main.path(forResource: "remote", ofType: "zsh")) { name, ok in
        print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 }
    }
    exit(failed == 0 ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--selftest" {
    // The pure automation logic: battery guard, smart triggers, agent board. Prints PASS/FAIL lines.
    var failed = 0
    func check(_ name: String, _ ok: Bool) { print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
    check("launch: an alert-only launch that adopted a session (update hand-over, crash) runs on as the app",
          !Recovery.alertOnly(launchedForAlert: true, adoptedSession: true) && Recovery.alertOnly(launchedForAlert: true, adoptedSession: false)
          && !Recovery.alertOnly(launchedForAlert: false, adoptedSession: false))
    setenv("COCAINE_PROBE_SUDO", "/tmp/evil", 1)
    check("launch: test overrides are dropped from the app's environment (and its children's)",
          TestOverrides.scrub(prefix: "COCAINE_PROBE") == ["COCAINE_PROBE_SUDO"] && Recovery.env["COCAINE_PROBE_SUDO"] == nil && getenv("COCAINE_PROBE_SUDO") == nil)
    do {   // phones.json: never written over when it can't be read; private from the first byte
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-phones-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("phones.json")
        let p1 = Pairing.make(tier: "basic", relay: "https://relay.test")!
        check("phones: missing file = no pairings", PhoneLink.loadChecked(f) == [] && PhoneLink.loadForChange(f) == [])
        check("phones: saved 0600 in a 0700 folder and read back", PhoneLink.save([p1], to: f) && PhoneLink.load(f) == [p1]
              && (try? FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int) == 0o600
              && (try? FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) == 0o700)
        try? Data("{ not json".utf8).write(to: f)
        check("phones: a damaged file reads as 'unknown', not as no pairings", PhoneLink.loadChecked(f) == nil)
        let changed = PhoneLink.loadForChange(f)
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasPrefix("phones.unreadable-") } ?? []
        check("phones: …a change starts empty but the damaged file is kept aside, never overwritten",
              changed == [] && kept.count == 1 && (try? String(contentsOf: dir.appendingPathComponent(kept[0]), encoding: .utf8)) == "{ not json")
    }
    var g = BatteryGuard()
    check("battery: off threshold never fires", !g.check(percent: 5, onAC: false, threshold: 0))
    check("battery: above threshold is quiet", !g.check(percent: 40, onAC: false, threshold: 20))
    check("battery: fires at the threshold", g.check(percent: 20, onAC: false, threshold: 20))
    check("battery: fires only once while it stays low", !g.check(percent: 15, onAC: false, threshold: 20))
    check("battery: not re-armed by a small recovery", !g.check(percent: 22, onAC: false, threshold: 20) && !g.check(percent: 19, onAC: false, threshold: 20))
    check("battery: plugging in re-arms it", !g.check(percent: 19, onAC: true, threshold: 20) && g.check(percent: 19, onAC: false, threshold: 20))
    check("battery: never fires on power", { var x = BatteryGuard(); return !x.check(percent: 3, onAC: true, threshold: 30) }())
    do {   // after an update or a crash the new instance adopts the session: a trigger's ON stays the trigger's
        var fresh = AutoOn(), resumed = AutoOn(); let t = Date()
        resumed.resume(now: t)
        check("triggers: an adopted trigger ON ends with its trigger (after the grace); without it, it would stay on forever",
              resumed.step(active: false, isOn: true, now: t.addingTimeInterval(60)) == .none
              && resumed.step(active: false, isOn: true, now: t.addingTimeInterval(200)) == .turnOff
              && fresh.step(active: false, isOn: true, now: t.addingTimeInterval(200)) == .none)
    }
    var a = AutoOn(); let t0 = Date()
    check("trigger: nothing active, nothing to do", a.step(active: false, isOn: false, now: t0) == .none)
    check("trigger: active and off → turn on", a.step(active: true, isOn: false, now: t0) == .turnOn)
    check("trigger: stays on while active", a.step(active: true, isOn: true, now: t0 + 60) == .none)
    check("trigger: waits out the grace period", a.step(active: false, isOn: true, now: t0 + 120) == .none)
    check("trigger: off after 3 quiet minutes", a.step(active: false, isOn: true, now: t0 + 61 + 180) == .turnOff)
    var b = AutoOn()
    _ = b.step(active: true, isOn: false, now: t0)
    b.userToggled(to: false, triggerActive: true)
    check("trigger: user's OFF is respected while active", b.step(active: true, isOn: false, now: t0 + 10) == .none)
    check("trigger: …until the trigger has gone away", b.step(active: false, isOn: false, now: t0 + 20) == .none && b.step(active: true, isOn: false, now: t0 + 30) == .turnOn)
    var c = AutoOn()
    check("trigger: a manual ON is never turned off by it", { _ = c.step(active: true, isOn: true, now: t0); return c.step(active: false, isOn: true, now: t0 + 999) == .none }())
    var d = AutoOn()
    _ = d.step(active: true, isOn: false, now: t0)
    d.userToggled(to: true, triggerActive: true)
    check("trigger: user takes over an auto-on", d.step(active: false, isOn: true, now: t0 + 999) == .none)
    powerSelfTest(check)
    let board = AgentBoard(); let now = Date()
    board.set("s1", from: "Claude Code", project: "x", state: "working", now: now)
    board.set("s2", from: "Codex", project: nil, state: "waiting", now: now)
    check("board: working and waiting are live", board.anyLive(now))
    board.set("s1", from: "Claude Code", project: "x", state: "done", now: now)
    board.set("s2", from: "Codex", project: nil, state: "done", now: now)
    check("board: nothing live when all are done", !board.anyLive(now))
    board.prune(now.addingTimeInterval(1900))
    check("board: finished sessions fade after 30 minutes", board.entries.isEmpty)
    board.set("s3", from: "Gemini CLI", project: nil, state: "working", now: now)
    board.prune(now.addingTimeInterval(7300))
    check("board: a 'working' nobody updated for 2 hours is dropped", board.entries.isEmpty)
    check("hud: this process is not mistaken for the system helper", !SystemHUD.helperPIDs().contains(getpid()))
    check("hud: volume-up key down is decoded", MediaKeys.decode(data1: (0 << 16) | (0xA << 8))?.down == true)
    check("hud: brightness-down key up is decoded", { let k = MediaKeys.decode(data1: (3 << 16) | (0xB << 8)); return k?.key == 3 && k?.down == false }())
    check("hud: other keys are ignored", MediaKeys.decode(data1: (16 << 16) | (0xA << 8)) == nil)
    do {   // a key left to macOS must keep its release, or macOS repeats it forever (brightness running up by itself)
        var t = MediaKeyTracker()
        check("hud: a key we handled has its release swallowed too", t.down(2, handled: true) && t.up(2))
        check("hud: …but only once", !t.up(2))
        check("hud: a key left to macOS keeps its release (not swallowed)", !t.down(2, handled: false) && !t.up(2))
        check("hud: a release with no press seen is never swallowed", !t.up(3))
        _ = t.down(2, handled: true)
        check("hud: auto-repeat then a pass-through: the release goes to macOS", !t.down(2, handled: false) && !t.up(2))
        _ = t.down(0, handled: true)
        check("hud: keys are tracked separately", !t.up(2) && t.up(0))
    }
    check("wake: date in pmset's format", WakeSchedule.format(Date(timeIntervalSince1970: 1_790_000_000)).range(of: "^\\d\\d/\\d\\d/\\d\\d \\d\\d:\\d\\d:\\d\\d$", options: .regularExpression) != nil)
    check("wake: the sudo rule allows only schedule wake/cancel wake, tagged cocaine",
          Authorization.installCommand(user: "u")?.contains("/usr/bin/pmset schedule wake * cocaine, /usr/bin/pmset schedule cancel wake * cocaine,") == true)
    do {   // the one-time authorization: how its outcome is read (the old code never saw the "rc=" line after `exit`)
        let dir = NSTemporaryDirectory() + "cocaine-auth-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dest = dir + "/rule"
        let cmd = Authorization.installCommand(user: NSUserName(), dest: dest, asRoot: false)!
        check("auth: the install command ends with exit (the case the old report missed)", cmd.hasSuffix("exit $r"))
        check("auth: a successful install is reported as success", Authorization.runPlain(cmd) && FileManager.default.fileExists(atPath: dest))
        check("auth: a failing install is reported as failure", !Authorization.runPlain("exit 3"))
        check("auth: a failure inside the install (bad destination) is reported as failure",
              !Authorization.runPlain(Authorization.installCommand(user: NSUserName(), dest: dir + "/no/such/dir/rule", asRoot: false)!))
        check("auth: no report line (cancelled, killed) is a failure", !Authorization.succeeded("") && !Authorization.succeeded("garbage\n"))
        check("auth: only rc=0 is success", Authorization.succeeded("rc=0\n") && !Authorization.succeeded("rc=1\n") && !Authorization.succeeded("rc=10\n"))
        check("auth: noise before the report is ignored", Authorization.succeeded("warning\nrc=0\n"))
        try? FileManager.default.removeItem(atPath: dest)
        check("auth: retry after a failure works", Authorization.runPlain(cmd) && FileManager.default.fileExists(atPath: dest))
        check("auth: a user name with shell characters is refused", Authorization.installCommand(user: "a; rm -rf /") == nil)
    }
    check("wake: sleep/wake notifications can be registered", SleepWatcher().start())
    check("relay: a message event is read", RemoteListener.message(#"{"id":"a","time":1790000000,"event":"message","message":" status "}"#)?.text == "status")
    check("relay: keepalives and open events are ignored", RemoteListener.message(#"{"id":"a","time":1,"event":"keepalive"}"#) == nil
          && RemoteListener.message(#"{"id":"a","time":1,"event":"open"}"#) == nil && RemoteListener.message("garbage") == nil)
    RemoteTests.run(gate: Bundle.main.path(forResource: "remote", ofType: "zsh"), check)   // iPhone remote control: see Sources/RemoteTests.swift
    check("permissions: camera states", Permissions.cameraState(.authorized) == .granted && Permissions.cameraState(.notDetermined) == .notAsked
          && Permissions.cameraState(.denied) == .denied && Permissions.cameraState(.restricted) == .denied)
    check("permissions: calendar needs full access (write-only counts as refused)", Permissions.calendarState(.fullAccess) == .granted
          && Permissions.calendarState(.writeOnly) == .denied && Permissions.calendarState(.notDetermined) == .notAsked && Permissions.calendarState(.denied) == .denied)
    check("permissions: music apps, the worst answer counts", Permissions.automationState([]) == .granted && Permissions.automationState([0, -600]) == .granted
          && Permissions.automationState([0, -1744]) == .notAsked && Permissions.automationState([-1744, -1743]) == .denied)
    do {
        func st(_ m: [Permission: Permissions.State]) -> (Permission) -> Permissions.State { { m[$0] ?? .granted } }
        check("permissions: nothing listed when all is allowed", AppDelegate.permissionProblems(needed: [.accessibility], island: true, state: st([:])).isEmpty)
        check("permissions: a needed one that is missing is listed", AppDelegate.permissionProblems(needed: [.accessibility], island: false, state: st([.accessibility: .denied])) == [.accessibility])
        check("permissions: page permissions only when refused, only with the island",
              AppDelegate.permissionProblems(needed: [], island: true, state: st([.camera: .denied, .calendar: .notAsked, .files: .denied])) == [.camera, .files]
              && AppDelegate.permissionProblems(needed: [], island: false, state: st([.camera: .denied])).isEmpty)
    }
    if ClipboardTests.run() != 0 { failed += 1 }           // the clipboard history (its own PASS/FAIL lines; temp folders, fake Keychain)
    _ = NSApplication.shared
    AgentTests.pure(check)                                 // AI sessions: order, restore, liveness, URLs, focus plan, requests
    RecoveryTest.selfChecks(check)
    dialogsSelfTest(check)                                 // in-app dialogs: queue, default buttons, validation, the real flows
    designSelfTest(check)                                  // language in dates and durations, scroll steps, the panel strip
    if IslandCheck.run() != 0 { failed += 1 }              // the island as the live window holds it (its own PASS/FAIL lines)
    exit(failed == 0 ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--dialogs-test" {
    // The in-app dialogs alone (also part of --selftest). PASS/FAIL lines, exit status.
    _ = NSApplication.shared
    var failed = 0
    dialogsSelfTest { name, ok in print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
    designPass2SelfTest { name, ok in print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }   // the dropdowns too
    exit(failed == 0 ? 0 : 1)

}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--ai-alerts" {
    // `on|off|status [tool ids…] [--home <dir>]` for the AI alerts hooks: every tool on this Mac unless ids are given.
    // The Homebrew uninstall runs `off`; --home works on a copy, for tests.
    var args = Array(CommandLine.arguments.dropFirst(3))
    if let i = args.firstIndex(of: "--home"), i + 1 < args.count { AIHooks.home = args[i + 1]; args.removeSubrange(i...i + 1) }
    switch CommandLine.arguments[2] {
    case "on", "off":
        let tools = args.isEmpty ? AIHooks.present : args.compactMap(AIHooks.tool)
        let failed = AIHooks.set(CommandLine.arguments[2] == "on", only: tools)
        failed.forEach { print("could not update \($0)") }
        exit(failed.isEmpty ? 0 : 1)
    default:
        let s = AIHooks.status()
        for t in s.tools { print("\(t.id): \(t.installed ? (t.on ? "on" : "off") : "not installed")") }
        print("codex needs trust: \(s.codexNeedsTrust)")
        exit(0)
    }
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--permissions" {
    // The state of every permission for this app, without asking for any (Files: listing the folders is the only check, and it
    // makes macOS ask if it never did; given 3 s, else "notAsked (macOS is asking)"). Then the raw values behind them.
    _ = NSApplication.shared
    var probed = false
    Permissions.probe(files: true) { _ in probed = true }
    let until = Date().addingTimeInterval(3)
    while !probed && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    for p in Permission.allCases {
        print("\(p.rawValue):", p == .files && !probed ? "notAsked (macOS is asking)" : "\(Permissions.state(p))")
    }
    let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: 1 << 14,
                                callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil)
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    print("raw: AXIsProcessTrusted \(AXIsProcessTrusted()), post events \(CGPreflightPostEventAccess()), listen events (Input Monitoring) \(CGPreflightListenEventAccess()),",
          "HUD-key tap \(tap != nil ? "ok" : "refused"), camera \(AVCaptureDevice.authorizationStatus(for: .video).rawValue), calendar \(EKEventStore.authorizationStatus(for: .event).rawValue),",
          "music apps \(Permissions.runningMusicApps().map { "\($0)=\(Permissions.automation($0, ask: false))" })")
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--camera-test" {
    // The camera permission state of this app, and (if allowed) whether frames arrive. Never asks for the permission.
    let st = AVCaptureDevice.authorizationStatus(for: .video)
    print("camera authorization:", st.rawValue, "(0 not asked, 1 restricted, 2 denied, 3 allowed)")
    if st == .authorized {
        let session = AVCaptureSession(), out = AVCaptureVideoDataOutput()
        final class Counter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
            var frames = 0
            func captureOutput(_ o: AVCaptureOutput, didOutput b: CMSampleBuffer, from c: AVCaptureConnection) { frames += 1 }
        }
        let counter = Counter()
        if let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
            session.addInput(input)
            out.setSampleBufferDelegate(counter, queue: DispatchQueue(label: "camtest"))
            if session.canAddOutput(out) { session.addOutput(out) }
            session.startRunning()
            Thread.sleep(forTimeInterval: 3)
            session.stopRunning()
        }
        print("frames in 3 s:", counter.frames)
    }
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--presence-test" {
    // Does a presence nudge reset the system idle time? Prints the permission state and the idle time before and after.
    print("post-event access:", Presence.hasAccess, " accessibility:", AXIsProcessTrusted())
    Thread.sleep(forTimeInterval: 3)
    let before = System.idleSeconds
    let sent = Presence.nudge()
    Thread.sleep(forTimeInterval: 0.3)
    let after = System.idleSeconds
    print(String(format: "idle before %.1f s, nudge sent: %@, idle after %.1f s", before, sent ? "yes" : "no", after))
    print(sent && after < before ? "PASS  the nudge resets the idle time" : "FAIL  no effect (permission missing?)")
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--clipboard-test" {
    exit(ClipboardTests.run() == 0 ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--island-selfcheck" {
    _ = NSApplication.shared
    exit(IslandCheck.run())
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-island" {
    // Draws the island offscreen to a PNG: --open, --tab <id>, --lang <code>, --focus (a running focus), --mic, --agents.
    _ = NSApplication.shared
    let sampleSettings = SavedSettings()
    let args = CommandLine.arguments
    let pm = PanelModel()
    pm.persistLanguage = false
    pm.language = args.firstIndex(of: "--lang").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
    pm.on = !args.contains("--off"); pm.fillLevel = pm.on ? 1 : 0
    pm.ai = AIHooks.Status(tools: AIHooks.tools.enumerated().map { i, t in AIHooks.Entry(id: t.id, name: t.name, installed: i < 3, on: i < 2) }, codexNeedsTrust: false)
    if args.contains("--agents") {
        let t = Date().timeIntervalSince1970
        pm.board = [AgentEntry(id: "1", from: "Claude Code", project: "canonical-com", state: "working", since: t - 400),
                    AgentEntry(id: "2", from: "Codex", project: "PneuSuperStore", state: "waiting", since: t - 90)]
    }
    if args.contains("--many-agents") || args.contains("--approval") {         // the full list, and a request to answer
        (pm.board, pm.approvals) = AgentTests.sample(approval: args.contains("--approval"))
    }
    pm.timerMinutes = 120; pm.onUntil = Date().addingTimeInterval(7000)
    if args.contains("--presence") { pm.presenceActive = true; pm.pinkLevel = 1 }
    if let i = args.firstIndex(of: "--pink-level"), i + 1 < args.count, let v = Double(args[i + 1]) { pm.pinkLevel = CGFloat(v); pm.pinkPouring = v < 1 }        // a frame of the pink powder filling
    let im = IslandModel()
    im.pm = pm
    // --notch-width 210: another Mac's notch (a 14" is 185 pt; scaled resolutions change it).
    let notchW = args.firstIndex(of: "--notch-width").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }.map { CGFloat($0) } ?? 185
    im.geometry = NotchGeometry(frame: .zero, notchWidth: notchW, height: 32, centerX: 0, hasNotch: true)
    im.open = args.contains("--open")
    if let i = args.firstIndex(of: "--tab"), i + 1 < args.count { im.tab = args[i + 1] }
    if args.contains("--focus") { im.focus.start() }
    if args.contains("--mic") { im.mic.active = true }
    im.batteries.items = [BatteryItem(id: "mac", name: "MacBook Pro", icon: "laptopcomputer", parts: [("", 80)], charging: true),
                          BatteryItem(id: "a", name: "AirPods Pro", icon: "airpodspro", parts: [("L", 71), ("R", 64), ("↳", 90)]),
                          BatteryItem(id: "k", name: "Magic Keyboard", icon: "keyboard", parts: [("", 22)])]
    im.usage.codex = [UsageWatch.Limit(id: "w", name: L("Week"), percent: 5, resets: Date().addingTimeInterval(86400 * 5))]
    im.files.downloads = [FileShelf.Item(url: URL(fileURLWithPath: "/Applications/Cocaine.app"), date: Date(), size: 5_200_000),
                          FileShelf.Item(url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), date: Date(), size: 120_000_000)]
    im.files.shots = (0..<5).map { FileShelf.Item(url: URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic").deletingLastPathComponent().appendingPathComponent("shot\($0).png"), date: Date(), size: 1) }
    im.clipboard.replace([ClipItem.text("brew upgrade --cask cocaine"), {
                              var f = ClipItem.files(["/System/Library/CoreServices/Finder.app"]); f.pinned = true; return f }(),
                          ClipItem.text("https://github.com/Mattiakart/cocaine"), ClipItem.text("Ciao Mario, ti mando il file domani mattina"),
                          ClipItem.files(["/tmp/cocaine-no-such-file.pdf"])])
    im.music.setSample(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
    if args.contains("--shelf") { im.shelf.urls = [URL(fileURLWithPath: "/Applications/Cocaine.app"), URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")] }
    im.usage.claudeFive = 412_000; im.usage.claudeWeek = 8_600_000; im.usage.loaded = true
    // The morph: --progress 0.3 (or a list, 0,0.15,0.3…, drawn one under the other) draws those moments of opening; closing runs
    // the same frames backwards. --flash "text" / --level 0.6 shows a flash message, --pink the pink bag, --external the Monitors tab,
    // --notch covers the notch like the hardware does (what you really see), --xray shows it in translucent red instead.
    let progress = args.firstIndex(of: "--progress").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }?
        .split(separator: ",").compactMap { Double($0).map { CGFloat($0) } }
    if let i = args.firstIndex(of: "--flash"), i + 1 < args.count {
        let level = args.firstIndex(of: "--level").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
        im.flash = (level == nil ? "arrow.down.circle.fill" : "speaker.wave.2.fill", args[i + 1], level)
    }
    if args.contains("--pink") { pm.on = false; pm.fillLevel = 0; pm.presenceActive = true; pm.pinkLevel = 1 }        // Stay active alone: the pink bag
    Island.forceExternal = args.contains("--external")
    renderSampleDialog(args, surface: .island)                 // --dialog <kind>: a dialog in the open island
    if args.contains("--live-window") {
        // What the real window shows: the IslandView alone in a hosting view of the live window's size (closed: 465×38 on a
        // 185 pt notch), not the roomy canvas above. --island-selfcheck runs the same thing and checks the pixels.
        let g = NotchGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 185, height: 32, centerX: 756, hasNotch: true)
        im.geometry = g
        if let p = progress?.first { im.renderProgress = p; im.open = p > 0 }
        let rep = IslandCheck.render(im, pm, frame: IslandController.windowFrame(g, open: im.open))
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
        sampleSettings.restore()
        exit(0)
    }
    let notch = args.contains("--notch") ? Color.black : args.contains("--xray") ? Color.red.opacity(0.45) : nil
    func frame(_ p: CGFloat?) -> NSBitmapImageRep {
        if let p { im.renderProgress = p; im.open = p > 0 }
        let l = IslandLayout(notch: notchW, notchH: 32)
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.55, green: 0.7, blue: 0.9), Color(red: 0.8, green: 0.6, blue: 0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
            IslandView(model: im, m: pm, focus: im.focus, batteries: im.batteries, mic: im.mic, usage: im.usage)
            if let notch {
                IslandOutline(pose: IslandPose(p: 0, leftW: 0, rightW: 0), layout: l).fill(notch).frame(width: l.size.width, height: l.size.height)
            }
        }.frame(width: 760, height: im.open || progress != nil ? 250 : 70, alignment: .top).clipped()
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))      // measured sizes (lists that fade when cut) settle
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
    var reps = progress.map { $0.map { frame($0) } } ?? [frame(nil)]
    if reps.count > 1 {                     // a contact sheet, labelled with each frame's progress
        let w = reps[0].size.width, h = reps[0].size.height, sheet = NSImage(size: NSSize(width: w, height: h * CGFloat(reps.count)))
        sheet.lockFocus()
        for (i, r) in reps.enumerated() {
            r.draw(in: NSRect(x: 0, y: h * CGFloat(reps.count - 1 - i), width: w, height: h))
            NSString(string: String(format: "p %.2f", progress![i])).draw(at: NSPoint(x: 8, y: h * CGFloat(reps.count - 1 - i) + 8),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.black])
        }
        sheet.unlockFocus()
        reps = [NSBitmapImageRep(data: sheet.tiffRepresentation!)!]
    }
    try? reps[0].representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
    sampleSettings.restore()
    exit(0)
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-panel" {
    // Draws the panel offscreen to a PNG, in the language picked by -AppleLanguages, to check translations fit.
    _ = NSApplication.shared
    let sampleSettings = SavedSettings()
    let model = PanelModel()
    model.persistLanguage = false
    let langArg = CommandLine.arguments.firstIndex(of: "--lang").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
    model.language = langArg ?? ""                  // never the user's saved choice: "" = same as the Mac
    model.on = !CommandLine.arguments.contains("--off")
    model.fillLevel = model.on ? 1 : 0
    model.needsAuth = CommandLine.arguments.contains("--needs-auth")
    model.holdMissing = CommandLine.arguments.contains("--hold-missing")
    // --ai-on connects the first two tools, --codex-trust shows the Codex reminder, --no-ai hides the row.
    model.ai = AIHooks.Status(tools: AIHooks.tools.enumerated().map { i, t in
        AIHooks.Entry(id: t.id, name: t.name, installed: !CommandLine.arguments.contains("--no-ai") && i < 3,
                      on: CommandLine.arguments.contains("--ai-on") && i < 2)
    }, codexNeedsTrust: CommandLine.arguments.contains("--codex-trust"))
    if CommandLine.arguments.contains("--paused") { model.alertsPausedUntil = Date().addingTimeInterval(3600) }
    if CommandLine.arguments.contains("--ai-open") { model.page = "ai" }
    if CommandLine.arguments.contains("--last") {                  // a sample "Recent alerts" list
        model.history = [("Claude Code", "has finished", "Cocaine", 0.0), ("Codex", "needs your input", "PneuSuperStore", 900),
                         ("Cursor", "has finished", "Gestionale", 4000)]
            .map { AlertRecord(from: $0.0, message: L($0.1), project: $0.2, at: Date().addingTimeInterval(-$0.3)) }
    } else {
        model.history = []                                         // never the user's real alerts (project names) in a render
    }
    // --island / --no-island: hanging from the notch (the strip) or not, whatever the real setting; --notch-width 210: another Mac's notch.
    if CommandLine.arguments.contains("--island") { model.island = true }
    if CommandLine.arguments.contains("--no-island") { model.island = false }
    if let i = CommandLine.arguments.firstIndex(of: "--notch-width"), i + 1 < CommandLine.arguments.count, let w = Double(CommandLine.arguments[i + 1]) {
        NotchGeometry.override = NotchGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: CGFloat(w), height: 32, centerX: 756, hasNotch: true)
    }
    if let i = CommandLine.arguments.firstIndex(of: "--auto"), i + 1 < CommandLine.arguments.count {   // open a group of Automation
        let wanted = CommandLine.arguments[i + 1]
        model.page = ["none", "timer", "battery", "general"].contains(wanted) ? "" : wanted == "ai" ? "ai" : wanted == "island" ? "island" : "auto"
        if wanted == "island" { model.island = true }                 // the Island tab exists only while the island is on
        if CommandLine.arguments.contains("--schedule") { model.triggerSchedule = true; model.scheduleDays = [2, 3, 4, 5, 6]; model.scheduleStart = 540; model.scheduleEnd = 1080 }
        model.triggerAgents = true; model.triggerApps = ["Xcode"]; model.timerMinutes = 120; model.batteryThreshold = 20
        model.phoneCount = CommandLine.arguments.contains("--no-phone") ? 0 : 1; model.phoneLinkUp = true; model.battery = "80%"
        model.phone = "Comando Rapido “Avvisa iPhone”"
    }
    if CommandLine.arguments.contains("--agents") {
        let t = Date().timeIntervalSince1970
        model.board = [AgentEntry(id: "1", from: "Claude Code", project: "canonical-com", state: "working", since: t - 400),
                       AgentEntry(id: "2", from: "Codex", project: "PneuSuperStore", state: "waiting", since: t - 90),
                       AgentEntry(id: "3", from: "Cursor", project: "Gestionale", state: "error", since: t - 30)]
    }
    if CommandLine.arguments.contains("--many-agents") || CommandLine.arguments.contains("--approval") {
        (model.board, model.approvals) = AgentTests.sample(approval: CommandLine.arguments.contains("--approval"))
    }
    if CommandLine.arguments.contains("--speak") {                  // the longest voice name: the widest thing a row can hold
        model.alertSpeak = true
        model.alertVoice = Voices.available.map(\.identifier).max { Voices.name($0).count < Voices.name($1).count } ?? ""
    }
    if CommandLine.arguments.contains("--longsound") { model.alertDuration = 0; model.alertRepeatMinutes = 10 }
    if let i = CommandLine.arguments.firstIndex(of: "--timer"), i + 1 < CommandLine.arguments.count { model.timerMinutes = Int(CommandLine.arguments[i + 1]) ?? 0 }
    renderSampleDialog(CommandLine.arguments, surface: .panel)          // --dialog <kind>: a dialog over the panel
    let checkOverflow = CommandLine.arguments.contains("--overflow-check")
    // The page with its dialog layer on top, as the panel's window stacks them (the dialog is over the visible area).
    let surface = PanelView(m: model).overlay(alignment: .top) { PanelDialogOverlay(m: model) }
    let host = checkOverflow ? NSHostingView(rootView: AnyView(surface.frame(width: Layout.width + 260, alignment: .topLeading)))
                             : NSHostingView(rootView: AnyView(surface.background(Color.black)))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
    if CommandLine.arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
    if CommandLine.arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))      // the dialog card's measured height reaches the panel
    // --picker <id>: that row's dropdown open (language, sound, voice, pause, triggerApps, stayApps, excludedApps, patterns,
    // scheduleStart…), checked to hang under its row, below the strip, inside the panel's frame.
    var pickerReport: String?
    if let i = CommandLine.arguments.firstIndex(of: "--picker"), i + 1 < CommandLine.arguments.count {
        let id = CommandLine.arguments[i + 1]
        if let open = PickerCenter.shared.openers[id] {
            open()
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
            let c = PickerCenter.shared, top = PickerLayer.top(c.anchor)
            let notchBottom = model.island ? Layout.overscan + (NotchGeometry.current()?.height ?? 0) : 0
            let ok = c.isOpen && top > c.anchor.maxY && top >= notchBottom && c.cardHeight > 0
            pickerReport = "\(ok ? "PASS" : "FAIL")  dropdown \(id): row bottom \(String(format: "%.1f", c.anchor.maxY)), card top \(String(format: "%.1f", top)) (under its row; strip ends at \(String(format: "%.1f", notchBottom))), card \(String(format: "%.0f", Layout.width - 2 * Space.frame))×\(String(format: "%.0f", c.cardHeight)) pt"
        } else {
            pickerReport = "FAIL  dropdown \(id): no such value button on this page (\(PickerCenter.shared.openers.keys.sorted().joined(separator: ", ")))"
        }
    }
    window.setContentSize(host.fittingSize)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    if checkOverflow {      // the rightmost painted pixel must stay inside the 14 pt margin
        var maxX = 0
        outer: for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { maxX = x; break outer }
        }
        let right = CGFloat(maxX + 1) * host.bounds.width / CGFloat(rep.pixelsWide)
        let ok = right <= Layout.width - 14 + 0.5
        print("\(ok ? "PASS" : "FAIL")  rightmost painted \(String(format: "%.1f", right)) pt (limit \(Layout.width - 14))")
    }
    if let pickerReport { print(pickerReport) }
    sampleSettings.restore()                                // the sample values above must not stay in the real settings
    print(Bundle.main.preferredLocalizations.first ?? "?")

    exit(0)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-demo-gif" {
    Assets.renderDemoGIF(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-assets" {
    Assets.render(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
// The app itself never takes the test overrides (COCAINE_SUDO, COCAINE_PMSET, COCAINE_SUPPORT…): set with `launchctl setenv`
// they would have Cocaine, its engine and its watchdog run another program with Cocaine's permissions, or use other folders.
TestOverrides.scrub()
// One Cocaine at a time (another may still be quitting, e.g. during an update): this one leaves without touching anything.
guard Recovery.claimSingleInstance() else { exit(0) }
let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
