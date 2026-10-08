// The island's Monitors page: external displays over DDC/CI (DDCDisplays), with its pure parts (DDCCoalescer, DDCMatch,
// DDCReply) tested in Sources/DisplayTests.swift.

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

/// Slider values waiting for the monitor: at most one write per control every `minInterval` (≤10 a second), and only the latest
/// value of a slider that moved meanwhile. Monitors' DDC/CI chips are slow and drop or garble a burst of writes.
struct DDCCoalescer {
    let minInterval: TimeInterval
    private var pending: [String: Int] = [:]
    private var lastWrite: [String: Date] = [:]

    init(minInterval: TimeInterval) { self.minInterval = minInterval }

    /// True: write it now. False: kept (replacing any older value) until `take` finds its turn.
    mutating func offer(key: String, value: Int, now: Date) -> Bool {
        if let l = lastWrite[key], now.timeIntervalSince(l) < minInterval { pending[key] = value; return false }
        lastWrite[key] = now
        pending[key] = nil
        return true
    }

    /// The values whose turn has come.
    mutating func take(now: Date) -> [(key: String, value: Int)] {
        var out: [(key: String, value: Int)] = []
        for (k, v) in pending.sorted(by: { $0.key < $1.key }) where now.timeIntervalSince(lastWrite[k] ?? .distantPast) >= minInterval {
            out.append((k, v)); lastWrite[k] = now; pending[k] = nil
        }
        return out
    }

    var hasPending: Bool { !pending.isEmpty }
}

/// Which DDC service drives which screen: by the monitor's identity (vendor, model, serial from its EDID), then by its name;
/// identical monitors without serials are paired in order, each once. Never by position alone (two monitors' names could swap,
/// and a slider would change the other monitor).
enum DDCMatch {
    struct Service: Equatable { var index: Int; var vendor: UInt32; var model: UInt32; var serial: UInt32; var name: String }
    struct Screen: Equatable { var id: CGDirectDisplayID; var vendor: UInt32; var model: UInt32; var serial: UInt32; var name: String }

    static func match(services: [Service], screens: [Screen]) -> [Int: Screen] {
        var out: [Int: Screen] = [:]
        var free = screens
        func take(_ i: Int, _ ok: (Screen) -> Bool) {
            guard out[i] == nil, let k = free.firstIndex(where: ok) else { return }
            out[i] = free.remove(at: k)
        }
        for s in services where s.serial != 0 { take(s.index) { $0.vendor == s.vendor && $0.model == s.model && $0.serial == s.serial } }
        for s in services where s.vendor != 0 { take(s.index) { $0.vendor == s.vendor && $0.model == s.model } }
        for s in services where !s.name.isEmpty { take(s.index) { $0.name == s.name } }
        return out
    }
}

/// A "Get VCP feature" reply: 6E 88 02 <result> <code> <type> <max hi> <max lo> <cur hi> <cur lo> <checksum>.
enum DDCReply {
    static func parse(_ b: [UInt8]) -> (current: Int, max: Int)? {
        guard b.count >= 10, b[2] == 0x02, b[3] == 0x00 else { return nil }
        let mx = Int(b[6]) << 8 | Int(b[7]), cur = Int(b[8]) << 8 | Int(b[9])
        guard mx > 0, cur <= mx else { return nil }
        return (cur, mx)
    }
}

/// External monitors' own controls over DDC/CI (brightness, contrast, volume, input), written to the display's I2C bus on one
/// serial queue. Apple silicon only (Intel Macs have no such service: the Monitors tab isn't shown there); the monitor has to
/// support DDC/CI. Values are read from the monitor when it answers; one it doesn't answer for shows "–".
final class DDCDisplays: ObservableObject {
    struct Monitor: Identifiable { var id: Int; var name: String; var service: CFTypeRef }
    @Published var monitors: [Monitor] = []
    @Published var values: [String: Double] = [:]          // "<monitor><b|c|v>": 0…100, only what was read or set
    @Published var failed: Set<Int> = []                   // monitors that didn't take a write
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private typealias ReadFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private var create: CreateFn?, write: WriteFn?, read: ReadFn?
    private let queue = DispatchQueue(label: "cocaine.ddc")              // one bus conversation at a time
    private var coalescer = DDCCoalescer(minInterval: 0.1)
    private var flush: Timer?
    private var maxima: [String: Int] = [:]                               // each control's own maximum (often 100)
    private var targets: [String: (monitor: Int, code: UInt8)] = [:]

    init() {
        guard Self.supported, let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return }
        create = dlsym(h, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
        write = dlsym(h, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: WriteFn.self) }
        read = dlsym(h, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: ReadFn.self) }
    }

    /// Apple silicon: Intel Macs reach monitors another way, which Cocaine doesn't do.
    static var supported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    var available: Bool { create != nil && write != nil }
    static var externalNames: [String] { NSScreen.screens.filter { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) == 0 } ?? false }.map(\.localizedName) }

    /// The external monitors' services, each paired with its screen by identity (Sources: DDCMatch).
    func refresh() {
        guard available else { return }
        var found: [(service: CFTypeRef, attrs: DDCMatch.Service)] = []
        var it: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        // In the registry each display's framebuffer (with the monitor's identity) comes before its DCPAVServiceProxy.
        var lastAttrs: [String: Any]?
        var entry = IOIteratorNext(it)
        while entry != 0 {
            var cls = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &cls)
            let name = String(cString: cls)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                lastAttrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
            } else if name == "DCPAVServiceProxy" {
                let loc = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                if loc == "External", let ref = create?(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                    let p = lastAttrs?["ProductAttributes"] as? [String: Any] ?? [:]
                    func n(_ k: String) -> UInt32 { (p[k] as? NSNumber)?.uint32Value ?? 0 }
                    found.append((ref, .init(index: found.count, vendor: n("LegacyManufacturerID"), model: n("ProductID"),
                                             serial: n("SerialNumber"), name: p["ProductName"] as? String ?? "")))
                }
                lastAttrs = nil
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(it)
        }
        let screens: [DDCMatch.Screen] = NSScreen.screens.compactMap { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID, CGDisplayIsBuiltin(id) == 0 else { return nil }
            return .init(id: id, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id), name: s.localizedName)
        }
        let pairs = DDCMatch.match(services: found.map(\.attrs), screens: screens)
        // The old services are released with the old list (no references are kept by hand).
        monitors = found.map { f in
            Monitor(id: f.attrs.index, name: pairs[f.attrs.index]?.name ?? (f.attrs.name.isEmpty ? String(format: L("Monitor %d"), f.attrs.index + 1) : f.attrs.name),
                    service: f.service)
        }
        failed = []
        readAll()
    }

    private static func key(_ m: Int, _ code: UInt8) -> String {
        "\(m)" + (code == 0x10 ? "b" : code == 0x12 ? "c" : code == 0x62 ? "v" : String(code))
    }

    /// The current values, read from each monitor in the background (a monitor that doesn't answer keeps "–").
    private func readAll() {
        guard let read, let write else { return }
        for m in monitors.prefix(2) {
            let ref = m.service, id = m.id
            queue.async { [weak self] in
                for code: UInt8 in [0x10, 0x12, 0x62] {
                    var q: [UInt8] = [0x82, 0x01, code, 0]
                    q[3] = 0x6E ^ 0x51 ^ q[0] ^ q[1] ^ q[2]
                    guard write(ref, 0x37, 0x51, &q, 4) == 0 else { continue }
                    usleep(40_000)
                    var reply = [UInt8](repeating: 0, count: 11)
                    guard read(ref, 0x37, 0x51, &reply, 11) == 0, let r = DDCReply.parse(reply) else { continue }
                    let k = Self.key(id, code)
                    DispatchQueue.main.async {
                        self?.maxima[k] = r.max
                        self?.values[k] = (Double(r.current) * 100 / Double(r.max)).rounded()
                    }
                    usleep(20_000)
                }
            }
        }
    }

    /// VCP codes: 0x10 brightness, 0x12 contrast, 0x62 volume, 0x60 input source. Sliders send through the coalescer.
    func set(_ m: Monitor, code: UInt8, value: Int) {
        let k = Self.key(m.id, code)
        if code != 0x60 { values[k] = Double(value) }
        let scaled = code == 0x60 ? value : value * (maxima[k] ?? 100) / 100
        targets[k] = (m.id, code)
        if coalescer.offer(key: k, value: scaled, now: Date()) { send(m, code, scaled) }
        guard coalescer.hasPending, flush == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            for p in self.coalescer.take(now: Date()) {
                guard let target = self.targets[p.key], let mon = self.monitors.first(where: { $0.id == target.monitor }) else { continue }
                self.send(mon, target.code, p.value)
            }
            if !self.coalescer.hasPending { t.invalidate(); self.flush = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        flush = t
    }

    private func send(_ m: Monitor, _ code: UInt8, _ value: Int) {
        guard let write else { return }
        var d: [UInt8] = [0x84, 0x03, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF), 0]
        d[5] = 0x6E ^ 0x51 ^ d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[4]
        let ref = m.service, id = m.id
        queue.async { [weak self] in
            var ok = false
            for _ in 0..<2 { if write(ref, 0x37, 0x51, &d, 6) == 0 { ok = true }; usleep(15_000) }
            DispatchQueue.main.async {
                guard let self else { return }
                if ok { self.failed.remove(id) } else if !self.failed.contains(id) {
                    self.failed.insert(id)
                    log.notice("DDC write to monitor \(id, privacy: .public) failed")
                }
            }
        }
    }
}

extension IslandView {
    // MARK: external monitors

    var displayTab: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            KeyboardBacklightRow()                                 // the built-in keyboard's light, when it has one (Sources/KeyboardBacklight.swift)
            if model.ddc.monitors.isEmpty {
                Text(L("No external monitor found, or it doesn't support DDC/CI")).font(UI.value).foregroundStyle(UI.hint)
            }
            ForEach(model.ddc.monitors.prefix(2)) { mon in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mon.name).font(UI.itemTitle).lineLimit(1)
                        if model.ddc.failed.contains(mon.id) {
                            Text(L("Not answering over DDC/CI")).font(UI.detail).foregroundStyle(UI.hint).lineLimit(1)
                        }
                    }
                    .frame(width: 130, alignment: .leading)
                    ForEach([("sun.max.fill", UInt8(0x10), "b"), ("circle.lefthalf.filled", UInt8(0x12), "c"), ("speaker.wave.2.fill", UInt8(0x62), "v")], id: \.1) { k in
                        HStack(spacing: Space.s) {
                            Image(systemName: k.0).font(.system(size: 11)).foregroundStyle(UI.secondary).frame(width: 14)   // a glyph
                            let known = model.ddc.values["\(mon.id)\(k.2)"]
                            let v = known ?? 50
                            CocaineSlider(value: v, range: 0...100, step: 5, name: k.2 == "b" ? L("Brightness") : k.2 == "c" ? L("Contrast") : L("Volume"),
                                          valueText: known.map { "\(Int($0))%" } ?? "–") { model.ddc.set(mon, code: k.1, value: Int($0)) }
                                .frame(width: 96)
                        }
                    }
                    IslandValueButton(title: L("Input"), value: L("Input")) {
                        let inputs: [(String, Int)] = [("HDMI 1", 0x11), ("HDMI 2", 0x12), ("DisplayPort 1", 0x0F), ("DisplayPort 2", 0x10), ("USB-C", 0x1B)]
                        IslandChoices.ask(L("Input"), icon: "cable.connector", inputs.map { DialogChoice(id: String($0.1), title: $0.0, symbol: "cable.connector") }) {
                            if let code = Int($0) { model.ddc.set(mon, code: 0x60, value: code) }
                        }
                    }
                }
            }
            Text(L("Controls the monitor itself, over DDC/CI. A value the monitor doesn't report shows –.")).font(UI.detail).foregroundStyle(UI.hint)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)          // on the page's text edge, like every other page
        .onAppear { model.ddc.refresh() }
    }
}
