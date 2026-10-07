// The island's Monitors page: external displays over DDC/CI.

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

/// External monitors' own controls over DDC/CI (brightness, contrast, volume, input), written straight to the display's I2C
/// bus. Apple silicon only; the monitor has to support DDC/CI. Nothing here can read a value back, so sliders start at 50.
final class DDCDisplays: ObservableObject {
    struct Monitor: Identifiable { var id: Int; var name: String; var service: UnsafeMutableRawPointer }
    @Published var monitors: [Monitor] = []
    @Published var values: [String: Double] = [:]
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private var create: CreateFn?, write: WriteFn?

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return }
        create = dlsym(h, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
        write = dlsym(h, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: WriteFn.self) }
    }

    var available: Bool { create != nil && write != nil }
    static var externalNames: [String] { NSScreen.screens.filter { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) == 0 } ?? false }.map(\.localizedName) }

    func refresh() {
        guard available else { return }
        var found: [Monitor] = []
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        let names = Self.externalNames
        var svc = IOIteratorNext(it)
        while svc != 0 {
            let loc = IORegistryEntryCreateCFProperty(svc, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if loc == "External", let ref = create?(kCFAllocatorDefault, svc) {
                let i = found.count
                found.append(Monitor(id: i, name: i < names.count ? names[i] : "Monitor \(i + 1)", service: Unmanaged.passRetained(ref.takeRetainedValue()).toOpaque()))
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(it)
        }
        monitors = found
    }

    /// VCP codes: 0x10 brightness, 0x12 contrast, 0x62 volume, 0x60 input source.
    func set(_ m: Monitor, code: UInt8, value: Int) {
        guard let write else { return }
        var d: [UInt8] = [0x84, 0x03, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF), 0]
        d[5] = 0x6E ^ 0x51 ^ d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[4]
        let ref = Unmanaged<CFTypeRef>.fromOpaque(m.service).takeUnretainedValue()
        DispatchQueue.global().async { for _ in 0..<2 { _ = write(ref, 0x37, 0x51, &d, 6); usleep(15_000) } }
    }
}

extension IslandView {
    // MARK: external monitors

    var displayTab: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if model.ddc.monitors.isEmpty {
                Text(L("No external monitor found, or it doesn't support DDC/CI")).font(UI.value).foregroundStyle(UI.hint)
            }
            ForEach(model.ddc.monitors.prefix(2)) { mon in
                HStack(spacing: 14) {
                    Text(mon.name).font(UI.itemTitle).lineLimit(1).frame(width: 130, alignment: .leading)
                    ForEach([("sun.max.fill", UInt8(0x10), "b"), ("circle.lefthalf.filled", UInt8(0x12), "c"), ("speaker.wave.2.fill", UInt8(0x62), "v")], id: \.1) { k in
                        HStack(spacing: Space.s) {
                            Image(systemName: k.0).font(.system(size: 11)).foregroundStyle(UI.secondary).frame(width: 14)   // a glyph
                            let v = model.ddc.values["\(mon.id)\(k.2)"] ?? 50
                            CocaineSlider(value: v, range: 0...100, step: 5, name: k.2 == "b" ? L("Brightness") : k.2 == "c" ? L("Contrast") : L("Volume"),
                                          valueText: "\(Int(v))%") { model.ddc.values["\(mon.id)\(k.2)"] = $0; model.ddc.set(mon, code: k.1, value: Int($0)) }
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
            Text(L("Controls the monitor itself, over DDC/CI. Values start at 50 because monitors can't be read back.")).font(UI.detail).foregroundStyle(UI.hint)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)          // on the page's text edge, like every other page
        .onAppear { model.ddc.refresh() }
    }
}
