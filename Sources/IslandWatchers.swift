// The island's live data: the focus timer, batteries, the microphone and the AI tools' usage.

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

// MARK: Island data

/// Focus / break timer: a minute ruler to set the length, a countdown shown in the closed island.
final class FocusTimer: ObservableObject {
    @Published var focusMinutes = 25
    @Published var breakMinutes = 5
    @Published var isBreak = false
    @Published var endsAt: Date?
    @Published var pausedLeft: TimeInterval?
    @Published var tick = Date()
    var onFinish: ((Bool) -> Void)?                // true when a break just ended
    var onStart: ((Int) -> Void)?
    private var timer: Timer?

    var minutes: Int { get { isBreak ? breakMinutes : focusMinutes } set { if isBreak { breakMinutes = newValue } else { focusMinutes = newValue } } }
    var running: Bool { endsAt != nil }
    var active: Bool { endsAt != nil || pausedLeft != nil }
    var remaining: TimeInterval { endsAt.map { max(0, $0.timeIntervalSinceNow) } ?? pausedLeft ?? Double(minutes) * 60 }
    var text: String { let s = Int(remaining.rounded(.up)); return String(format: "%d:%02d", s / 60, s % 60) }

    func start() {
        Haptic.tap(.generic)
        let left = pausedLeft ?? Double(minutes) * 60
        endsAt = Date().addingTimeInterval(left); pausedLeft = nil
        if !isBreak { onStart?(Int((left / 60).rounded(.up)) + 1) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.step() }
    }
    func pause() { Haptic.tap(.alignment); pausedLeft = remaining; endsAt = nil; timer?.invalidate(); tick = Date() }
    func reset() { Haptic.tap(.alignment); endsAt = nil; pausedLeft = nil; timer?.invalidate(); tick = Date() }
    func setBreak(_ b: Bool) { reset(); isBreak = b }
    private func step() {
        tick = Date()
        guard let e = endsAt, e.timeIntervalSinceNow <= 0 else { return }
        let wasBreak = isBreak
        reset()
        NSSound(named: "Glass")?.play()
        Haptic.finished()
        isBreak.toggle()
        onFinish?(wasBreak)
    }
}

struct BatteryItem: Identifiable {
    var id: String
    var name: String
    var icon: String
    var parts: [(label: String, percent: Int)]
    var charging = false
}

/// Charge of the Mac and of connected Bluetooth devices (AirPods, keyboard, mouse, trackpad).
final class BatteryWatch: ObservableObject {
    @Published var items: [BatteryItem] = []
    private var busy = false

    func refresh() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global().async {
            var list: [BatteryItem] = []
            if let b = System.battery {
                list.append(BatteryItem(id: "mac", name: "Mac", icon: "laptopcomputer", parts: [("", b.percent)], charging: b.onAC))
            }
            list += Self.bluetooth()
            DispatchQueue.main.async { self.items = list; self.busy = false }
        }
    }

    private static func bluetooth() -> [BatteryItem] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let top = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = top["device_connected"] as? [[String: Any]] else { return [] }
        func pct(_ v: Any?) -> Int? { (v as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
        var items: [BatteryItem] = []
        for entry in connected {
            for (name, value) in entry {
                guard let d = value as? [String: Any] else { continue }
                var parts: [(String, Int)] = []
                for (key, label) in [("device_batteryLevelMain", ""), ("device_batteryLevelLeft", "L"), ("device_batteryLevelRight", "R"), ("device_batteryLevelCase", "↳")] {
                    if let v = pct(d[key]) { parts.append((label, v)) }
                }
                guard !parts.isEmpty else { continue }
                let kind = (d["device_minorType"] as? String ?? "").lowercased()
                let icon = kind.contains("head") || name.lowercased().contains("airpods") ? "airpodspro" : kind.contains("keyboard") ? "keyboard"
                    : kind.contains("mouse") ? "computermouse" : kind.contains("trackpad") ? "rectangle.and.hand.point.up.left" : "dot.radiowaves.left.and.right"
                items.append(BatteryItem(id: name, name: name, icon: icon, parts: parts))
            }
        }
        return items.sorted { $0.name < $1.name }
    }
}

/// Is something using the microphone right now? (CoreAudio's own "running somewhere" flag of the default input.)
final class MicWatch: ObservableObject {
    @Published var active = false
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr, device != 0 else { return }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return }
        let now = running != 0
        if now != active { active = now }
    }
}

/// Usage of the AI coding tools, read from their own local files: Codex's rate limits, and Claude Code's token counts.
final class UsageWatch: ObservableObject {
    struct Limit: Identifiable { var id: String; var name: String; var percent: Double; var resets: Date? }
    @Published var codex: [Limit] = []
    @Published var claudeFive = 0
    @Published var claudeWeek = 0
    @Published var loaded = false
    private var busy = false, last = Date.distantPast

    func refresh() {
        guard !busy, Date().timeIntervalSince(last) > 30 else { return }
        busy = true
        DispatchQueue.global().async {
            let c = Self.codexLimits(), t = Self.claudeTokens()
            DispatchQueue.main.async { self.codex = c; self.claudeFive = t.five; self.claudeWeek = t.week; self.loaded = true; self.busy = false; self.last = Date() }
        }
    }

    private static func codexLimits() -> [Limit] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var newest: (URL, Date)?
        for case let u as URL in en where u.pathExtension == "jsonl" {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if newest == nil || d > newest!.1 { newest = (u, d) }
        }
        guard let file = newest?.0, let h = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        guard let r = text.range(of: "\"rate_limits\":", options: .backwards) else { return [] }
        let tail = String(text[r.upperBound...].prefix(600))
        guard let re = try? NSRegularExpression(pattern: #""used_percent":([0-9.]+),"window_minutes":(\d+),"resets_at":(\d+)"#) else { return [] }
        return re.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).compactMap { m in
            guard let a = Range(m.range(at: 1), in: tail), let b = Range(m.range(at: 2), in: tail), let c = Range(m.range(at: 3), in: tail),
                  let pct = Double(tail[a]), let win = Int(tail[b]), let reset = Double(tail[c]) else { return nil }
            let name = win >= 10000 ? L("Week") : win >= 1440 ? L("Day") : String(format: L("%d h"), win / 60)
            return Limit(id: "codex\(win)", name: name, percent: pct, resets: Date(timeIntervalSince1970: reset))
        }
    }

    /// Input + output tokens of Claude Code's own conversations in the last 5 hours and 7 days (each message counted once).
    private static func claudeTokens() -> (five: Int, week: Int) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return (0, 0) }
        let now = Date(), weekAgo = now.addingTimeInterval(-7 * 86400), fiveAgo = now.addingTimeInterval(-5 * 3600)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date()
        var byID: [String: (Date, Int)] = [:]
        func number(_ key: String, in s: Substring) -> Int {
            guard let r = s.range(of: key) else { return 0 }
            return Int(s[r.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        for case let u as URL in en where u.pathExtension == "jsonl" {
            guard Date().timeIntervalSince(start) < 4 else { break }
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard (v?.contentModificationDate ?? .distantPast) > weekAgo, (v?.fileSize ?? 0) < 120_000_000, let data = try? Data(contentsOf: u) else { continue }
            for line in data.split(separator: 10) {
                guard line.count > 40, let s = String(data: line, encoding: .utf8), s.contains("\"output_tokens\":") else { continue }
                let sub = Substring(s)
                guard let tsR = sub.range(of: "\"timestamp\":\""), let ts = iso.date(from: String(sub[tsR.upperBound...].prefix(24))) else { continue }
                var id = "\(u.lastPathComponent)\(ts.timeIntervalSince1970)"
                if let idR = sub.range(of: "\"id\":\"msg_") { id = String(sub[idR.upperBound...].prefix { $0 != "\"" }) }
                let total = number("\"input_tokens\":", in: sub) + number("\"output_tokens\":", in: sub)
                if total > (byID[id]?.1 ?? 0) { byID[id] = (ts, total) }
            }
        }
        var five = 0, week = 0
        for (_, v) in byID where v.0 > weekAgo { week += v.1; if v.0 > fiveAgo { five += v.1 } }
        return (five, week)
    }
}
