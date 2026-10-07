// The phone: remote control through the relay, scheduled wake-ups, the iPhone Shortcut and phone alerts.

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

// MARK: - Remote control through a relay: the phone publishes a command, the Mac (outbound connection only) runs and answers
//
// The protocol (authenticated, end-to-end encrypted, replay-proof) lives in Sources/RemoteProtocol.swift, the listener in
// Sources/RemoteListener.swift and the Shortcut in Sources/RemoteShortcut.swift; this is the app's side of them.

enum PhoneLink {
    static let file = AgentBoard.directory.appendingPathComponent("phones.json")
    static let store = RemoteReplayStore(url: AgentBoard.directory.appendingPathComponent("remote-state.json"))
    static let legacyDays = 14.0

    /// The relay server: ntfy.sh unless the `relayURL` default points to another (https) ntfy server.
    static var relay: String {
        let v = UserDefaults.standard.string(forKey: "relayURL") ?? ""
        return v.hasPrefix("https://") ? v.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : "https://ntfy.sh"
    }

    /// Until when old (plain-text, unauthenticated) Shortcuts are still answered — basic commands only. Off by default.
    static var legacyUntil: Date? {
        get { let v = UserDefaults.standard.double(forKey: "remoteLegacyUntil"); return v > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: v) : nil }
        set { if let n = newValue { UserDefaults.standard.set(n.timeIntervalSince1970, forKey: "remoteLegacyUntil") } else { UserDefaults.standard.removeObject(forKey: "remoteLegacyUntil") } }
    }

    static func load(_ at: URL = file) -> [Pairing] { loadChecked(at) ?? [] }

    /// nil: the file is there but can't be read or decoded (damaged, a newer format, no permission).
    static func loadChecked(_ at: URL = file) -> [Pairing]? {
        guard let data = try? Data(contentsOf: at) else { return access(at.path, F_OK) == 0 || errno != ENOENT ? nil : [] }
        return try? JSONDecoder().decode([Pairing].self, from: data)
    }

    /// The list to change and save back. One that can't be read is never written over: it's set aside (kept, for the
    /// user or a newer Cocaine) and the change starts from an empty list. nil: it couldn't even be set aside.
    static func loadForChange(_ at: URL = file) -> [Pairing]? {
        if let list = loadChecked(at) { return list }
        let aside = at.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
        guard rename(at.path, aside.path) == 0 else { return nil }
        log.error("phones.json unreadable: kept as \(aside.lastPathComponent, privacy: .public)")
        return []
    }

    /// Atomic and private from the first byte (it holds the pairings' keys): 0600 temporary file, fsync, rename.
    @discardableResult
    static func save(_ list: [Pairing], to at: URL = file) -> Bool {
        let dir = at.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        guard let data = try? JSONEncoder().encode(list) else { return false }
        let tmp = at.path + ".\(getpid()).tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let ok = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) } == data.count && fsync(fd) == 0
        close(fd)
        guard ok, rename(tmp, at.path) == 0 else { unlink(tmp); return false }
        return true
    }

    /// A new pairing: 192-bit topics and a 256-bit key, valid 180 days.
    static func newPairing(tier: String) -> Pairing? { Pairing.make(tier: tier, relay: relay) }

    /// Runs one command from a phone through the gate (the same allow-list as `cocaine remote gate`) and returns what
    /// to answer: its output (cut to fit later). The text only ever travels in an environment variable, never in a shell line.
    static func execute(_ text: String, tier: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [scriptPath, "remote", "gate", "--tier=\(tier == "agents" ? "agents" : "basic")"]
        var env = ProcessInfo.processInfo.environment
        env["SSH_ORIGINAL_COMMAND"] = String(text.prefix(1000))
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        // Read what it prints as it comes and stop when the command ends (or after 25 s): a child that kept the pipe
        // open, such as an agent starting up, must not hold the answer back.
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var data = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            lock.lock(); if data.count < 8192 { data.append(chunk) }; lock.unlock()
        }
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return "cocaine: can't run" }
        if done.wait(timeout: .now() + 25) == .timedOut { p.terminate() }
        Thread.sleep(forTimeInterval: 0.2)               // the last bytes
        out.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let got = data; lock.unlock()
        let text = String(decoding: got.prefix(3500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "OK" : text
    }

    /// The HTTP status of the relay's answer (0: none).
    static func publish(_ text: String, to topic: String, relay: String, session: URLSession) async -> Int {
        guard let url = URL(string: "\(relay)/\(topic)") else { return 0 }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(text.utf8)
        req.setValue("Cocaine", forHTTPHeaderField: "Title")
        req.setValue("no", forHTTPHeaderField: "X-Firebase")       // keep it off Google's push service
        guard let (_, response) = try? await session.data(for: req) else { return 0 }
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// remote-phone.log: why each phone message was (not) run and whether the answer went out (Sources/RemotePhoneLog.swift).
    static let phoneLog = RemotePhoneLog(url: AgentBoard.directory.appendingPathComponent("remote-phone.log"))

    static func listener() -> RemoteListener {
        var h = RemoteListener.Hooks(store: store, execute: { execute($0, tier: $1) },
                                     publish: { await publish($0, to: $1, relay: $2, session: $3) })
        h.legacyUntil = { legacyUntil }
        h.expiredText = L("This pairing has expired. On the Mac: Cocaine → Remote work → iPhone → Send, then use the new Shortcut.")
        h.noticeText = L("Cocaine was updated and no longer accepts this Shortcut. On the Mac: Cocaine → Remote work → iPhone → Send, then use the new Shortcut.")
        h.willRun = { DispatchQueue.main.async { WakeHold.extend(60) } }      // stay awake while it runs and the answer goes out
        h.note = { log.notice("\($0, privacy: .public)"); phoneLog.write($0) }
        return RemoteListener(hooks: h)
    }
}

// MARK: - Waking the Mac on a schedule, so a sleeping Mac still answers the phone within a few minutes

/// A sleeping Mac (lid closed or not) can't hear the relay. With this on, Cocaine schedules a short wake every
/// `minutes` minutes: on wake it reconnects, runs what the phone sent meanwhile, and lets the Mac sleep again.
/// `pmset schedule` needs root, so it goes through the narrow sudo rule Cocaine installs.
enum WakeSchedule {
    static let minutes = 15
    static let owner = "cocaine"
    private static let key = "nextWake"

    /// How long a command may wait for the next wake before it's too old to run.
    static var maxCommandAge: Double { Double(minutes + 5) * 60 }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yy HH:mm:ss"
        return f.string(from: date)
    }

    private static func pmset(_ args: [String]) -> Bool { run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + args) == 0 }

    /// Replaces the scheduled wake with one `minutes` from now. False when sudo isn't allowed to (yet).
    @discardableResult
    static func arm() -> Bool {
        cancel()
        let date = Date().addingTimeInterval(Double(minutes) * 60)
        RecoverySession.shared.noteWake(date.timeIntervalSince1970)   // before: a crash right after still cancels it
        guard pmset(["schedule", "wake", format(date), owner]) else { RecoverySession.shared.noteWake(nil); return false }
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
        return true
    }

    static func cancel() {
        let t = UserDefaults.standard.double(forKey: key)
        guard t > 0 else { RecoverySession.shared.noteWake(nil); return }
        _ = pmset(["schedule", "cancel", "wake", format(Date(timeIntervalSince1970: t)), owner])
        UserDefaults.standard.removeObject(forKey: key)
        RecoverySession.shared.noteWake(nil)
    }
}

/// Keeps the Mac awake a little after a wake-up, long enough to reconnect, run a command and answer.
enum WakeHold {
    private static var assertion: IOPMAssertionID = 0
    private static var releaseAt = Date.distantPast

    static func extend(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        guard until > releaseAt else { return }
        releaseAt = until
        if assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Cocaine is answering your iPhone" as CFString, &assertion)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.5) {
            guard Date() >= releaseAt, assertion != 0 else { return }
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}

/// Tells us when the Mac is about to sleep and when it has woken (including the short "dark" wakes with the lid closed).
final class SleepWatcher {
    var willSleep: (() -> Void)?
    var didWake: (() -> Void)?
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    fileprivate private(set) var root: io_connect_t = 0

    @discardableResult
    func start() -> Bool {
        guard root == 0 else { return true }
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { refcon, _, message, argument in
            guard let refcon else { return }
            let w = Unmanaged<SleepWatcher>.fromOpaque(refcon).takeUnretainedValue()
            switch message {
            case 0xE000_0270, 0xE000_0280:                 // may sleep / will sleep: answer, or sleep waits 30 s
                if message == 0xE000_0280 { w.willSleep?() }
                IOAllowPowerChange(w.root, Int(bitPattern: argument))
            case 0xE000_0300:                              // has powered on
                w.didWake?()
            default: break
            }
        }, &notifier)
        guard root != 0, let port else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        return true
    }
}

// MARK: - The iPhone Shortcut: a menu that sends Cocaine's remote commands through the relay and shows the answer

enum PhoneShortcut {
    /// The shortcut as an (unsigned) property list (protocol v2, see Sources/RemoteShortcut.swift).
    static func build(_ pairing: Pairing) -> Data? {
        RemoteShortcut.build(pairing, labels: RemoteShortcutLabels(
            status: L("Status"), turnOn: L("Turn on"), turnOff: L("Turn off"), projects: L("Projects"), command: L("Command"),
            lastReply: L("Last reply"), prompt: L("Command (for example: start claude my-project Fix the tests)"),
            noAnswer: L("No valid answer yet. If the Mac is asleep, try “Last reply” in a few minutes.")))
    }

    /// Builds and signs `Cocaine.shortcut` for that pairing in a temporary folder; nil if signing fails (it needs to be
    /// online, and signed in to iCloud).
    static func signedFile(_ pairing: Pairing) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-shortcut-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let raw = dir.appendingPathComponent("raw.shortcut"), out = dir.appendingPathComponent("Cocaine.shortcut")
        guard let data = build(pairing), (try? data.write(to: raw)) != nil,
              run("/usr/bin/shortcuts", ["sign", "--mode", "people-who-know-me", "--input", raw.path, "--output", out.path]) == 0,
              FileManager.default.fileExists(atPath: out.path) else { try? FileManager.default.removeItem(at: dir); return nil }
        try? FileManager.default.removeItem(at: raw)
        return out
    }
}

enum RelayTest {
    static func curl(_ url: String) -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-sS", "-m", "10", url]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Phone alerts: a Shortcut and/or an ntfy topic

enum Phone {
    static var configured: Bool { let s = Settings(); return !s.phoneShortcut.isEmpty || !s.phoneNtfy.isEmpty }

    static var summary: String {
        let s = Settings()
        var parts: [String] = []
        if !s.phoneShortcut.isEmpty { parts.append("\(L("Shortcut")) “\(s.phoneShortcut)”") }
        if !s.phoneNtfy.isEmpty { parts.append("ntfy") }
        return parts.isEmpty ? L("Not set up") : parts.joined(separator: " + ")
    }

    /// Sends the alert text to the phone. The Shortcut runs with the text as its input (build one that messages you);
    /// ntfy posts it to the topic, so the text leaves the Mac: only used when the user set that topic.
    static func send(_ text: String) {
        let s = Settings()
        DispatchQueue.global().async {
            if !s.phoneShortcut.isEmpty {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-\(UUID().uuidString).txt")
                if (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil {
                    run("/usr/bin/shortcuts", ["run", s.phoneShortcut, "--input-path", file.path])
                    try? FileManager.default.removeItem(at: file)
                }
            }
            if s.phoneNtfy.hasPrefix("https://") {
                run("/usr/bin/curl", ["-sS", "-m", "10", "-H", "Title: Cocaine", "--data-raw", text, s.phoneNtfy])
            }
        }
    }
}

/// `--share-test`, run from main.swift.
func cliShareTest() {
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

/// `--make-shortcut`, run from main.swift.
func cliMakeShortcut() {
    // Builds and signs the iPhone Shortcut, copies it to the given path (for tests).
    guard let f = PhoneShortcut.signedFile(PhoneLink.newPairing(tier: "basic")!) else { print("could not sign"); exit(1) }
    try? FileManager.default.removeItem(atPath: CommandLine.arguments[2])
    try? FileManager.default.copyItem(at: f, to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("ok")
    exit(0)
}

/// `--relay-test`, run from main.swift.
func cliRelayTest() {
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
