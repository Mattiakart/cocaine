// The real displays for the dimming (Screens, a DisplayIO: see Sources/DimController.swift); --gamma-test.

import AppKit
import CoreGraphics

// MARK: - Screen dimming (every display)

/// The built-in panel and Apple displays go through DisplayServices (the real backlight); any other monitor is dimmed through its
/// gamma table, which macOS restores by itself if the app quits or crashes.
final class Screens: DisplayIO {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    private var getFn: GetFn?, setFn: SetFn?, canFn: CanFn?
    /// Each gamma-dimmed display's own table, read before the first change and put back exactly: other displays, and colour
    /// changes other apps made to them, are left alone.
    private var savedGamma: [CGDirectDisplayID: (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])] = [:]

    init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        else { return }
        getFn = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        setFn = dlsym(h, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
        canFn = dlsym(h, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanFn.self) }
    }

    /// The displays that are on. A mirror set counts once (its master): the others show the same picture.
    var online: [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n))).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    var lidClosed: Bool { System.lidClosed }
    var now: Date { Date() }
    func isBuiltin(_ d: CGDirectDisplayID) -> Bool { CGDisplayIsBuiltin(d) != 0 }

    func hasBacklight(_ d: CGDirectDisplayID) -> Bool { canFn?(d) ?? false }

    func brightness(_ d: CGDirectDisplayID) -> Float? {
        guard let get = getFn else { return nil }
        var b: Float = 0
        return get(d, &b) == 0 ? b : nil
    }

    /// Never below 1%: dimmed, not off.
    func setBrightness(_ d: CGDirectDisplayID, _ v: Float) { _ = setFn?(d, min(max(v, 0.01), 1)) }

    /// Software dimming for monitors without a controllable backlight: 1 = normal, lower = darker. The display's own table is
    /// scaled, so a calibration stays.
    func setGamma(_ d: CGDirectDisplayID, _ scale: Float) {
        if savedGamma[d] == nil {
            let cap = CGDisplayGammaTableCapacity(d)
            var r = [CGGammaValue](repeating: 0, count: Int(cap)), g = r, b = r
            var n: UInt32 = 0
            if cap > 0, CGGetDisplayTransferByTable(d, cap, &r, &g, &b, &n) == .success, n > 0 {
                savedGamma[d] = (Array(r.prefix(Int(n))), Array(g.prefix(Int(n))), Array(b.prefix(Int(n))))
            }
        }
        if let t = savedGamma[d] {
            let k = CGGammaValue(min(max(scale, 0), 1))
            CGSetDisplayTransferByTable(d, UInt32(t.r.count), t.r.map { $0 * k }, t.g.map { $0 * k }, t.b.map { $0 * k })
        } else {
            CGSetDisplayTransferByFormula(d, 0, scale, 1, 0, scale, 1, 0, scale, 1)
        }
    }

    func restoreGamma(_ d: CGDirectDisplayID) {
        if let t = savedGamma.removeValue(forKey: d) {
            CGSetDisplayTransferByTable(d, UInt32(t.r.count), t.r, t.g, t.b)
        } else {
            CGDisplayRestoreColorSyncSettings()                  // its table was never read: the system's own, for every display
        }
    }

    /// The display a brightness key acts on: the backlit one under the pointer, else the built-in, else the first backlit one
    /// (an Apple display with the lid closed).
    func keyTarget(pointer: CGPoint?) -> CGDirectDisplayID? {
        let list = online.filter(hasBacklight)
        var under = [CGDirectDisplayID](repeating: 0, count: 4)
        var n: UInt32 = 0
        if let p = pointer, CGGetDisplaysWithPoint(p, 4, &under, &n) == .success,
           let d = under.prefix(Int(n)).first(where: { list.contains($0) }) { return d }
        return list.first(where: isBuiltin) ?? list.first
    }
}

/// `--gamma-test`, run from main.swift.
func cliGammaTest() {
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
    screens.restoreGamma(d); usleep(200_000); print("restored: \(maxRed())")
    exit(0)
}
