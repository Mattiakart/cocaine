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
import ImageIO
import IOKit
import IOKit.pwr_mgt
import Security
import ServiceManagement
import SwiftUI
import os

private let log = Logger(subsystem: "local.cocaine.toggle", category: "app")
private let scriptPath = Bundle.main.path(forResource: "cocaine", ofType: nil) ?? "/nonexistent/cocaine"
private let anyInput = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType

/// The UI language: the Mac's (the default; English when it isn't one of ours) or one picked in the panel.
private enum Language {
    static let codes = ["en", "it", "zh-Hans", "zh-Hant", "es", "fr", "de", "ja"]
    private static var bundle = makeBundle(UserDefaults.standard.string(forKey: "language"))

    /// nil = same as the Mac.
    static var chosen: String? { UserDefaults.standard.string(forKey: "language") }

    static func set(_ code: String?, persist: Bool = true) {
        if persist {
            if let code { UserDefaults.standard.set(code, forKey: "language") }
            else { UserDefaults.standard.removeObject(forKey: "language") }
        }
        bundle = makeBundle(code)
    }

    private static func makeBundle(_ code: String?) -> Bundle {
        guard let code, let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path)
        else { return .main }                        // .main follows the Mac's languages, English as fallback
        return b
    }

    /// Flag shown on the language button; both Chinese scripts use China's flag (the menu tells them apart by name).
    static func flag(_ code: String) -> String {
        ["en": "🇬🇧", "it": "🇮🇹", "zh-Hans": "🇨🇳", "zh-Hant": "🇨🇳", "es": "🇪🇸", "fr": "🇫🇷", "de": "🇩🇪", "ja": "🇯🇵"][code] ?? "🌐"
    }

    /// The language actually in use when following the Mac (English if the Mac's isn't one of ours).
    static var system: String {
        let first = Bundle.main.preferredLocalizations.first ?? "en"
        return codes.contains(first) ? first : "en"
    }

    /// A language's name written in that language, e.g. "Deutsch", "日本語".
    static func nativeName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
    }

    static func text(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
}

/// The app's version as shown in the panel (CFBundleShortVersionString).
private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

/// UI text in the current language (Localization/*.lproj).
private func L(_ key: String) -> String { Language.text(key) }

@discardableResult
private func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// Runs the bundled engine (`on`, `off`, …) and returns its exit status: 0 ok, 2 not authorized yet.
@discardableResult
private func engine(_ arg: String) -> Int32 { run("/bin/zsh", [scriptPath, arg]) }

// MARK: - System state

private enum System {
    private static func rootDomainFlag(_ key: String) -> Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        return (IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }
    /// The pmset `disablesleep` flag the cocaine script sets.
    static var cocaineOn: Bool { rootDomainFlag("SleepDisabled") }
    static var lidClosed: Bool { rootDomainFlag("AppleClamshellState") }
    /// The script's display helper, matched by its exact argv just like the script does.
    static var displayHeld: Bool {
        let literal = scriptPath.replacingOccurrences(of: "([\\[\\]\\\\.^$*+?(){}|])", with: "\\\\$1",
                                                      options: .regularExpression)
        return run("/usr/bin/pgrep", ["-U", String(getuid()), "-xf", "/bin/zsh \(literal) hold"]) == 0
    }
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

// MARK: - One-time authorization (sudo rule)

private enum Authorization {
    static let rulePath = "/etc/sudoers.d/cocaine"

    /// Shell command that installs the NOPASSWD rule for `user` — validated with visudo before it is put in place,
    /// so a bad rule can never break sudo. `asRoot: false` + another `dest` is for the self-test only.
    static func installCommand(user: String, dest: String = rulePath, asRoot: Bool = true) -> String? {
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        // pmset on/off, plus removing this very rule, so uninstalling needs no password.
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, "
            + "/bin/rm -f \(rulePath)"
        let owner = asRoot ? "-o root -g wheel " : ""
        return "t=$(/usr/bin/mktemp /tmp/cocaine.XXXXXX) || exit 1; /usr/bin/printf '%s\\n' '\(rule)' > \"$t\"; "
            + "/usr/sbin/visudo -cf \"$t\" >/dev/null || { /bin/rm -f \"$t\"; exit 1; }; "
            + "/usr/bin/install -m 0440 \(owner)\"$t\" '\(dest)'; r=$?; /bin/rm -f \"$t\"; exit $r"
    }

    static func appleScript(for command: String, admin: Bool) -> String {   // only for --auth-selftest
        let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(quoted)\"" + (admin ? " with administrator privileges" : "")
    }

    /// Shows the standard macOS admin prompt ("Cocaine wants to make changes", Touch ID or password) and installs
    /// the rule. True on success.
    static func install() -> Bool {
        guard let cmd = installCommand(user: NSUserName()) else { return false }
        return runAsRoot(cmd, prompt: L("Cocaine needs your permission once, to keep your Mac awake."))
    }

    /// Removes the rule (used by the Homebrew uninstall when the rule predates self-removal).
    static func remove() -> Bool {
        runAsRoot("/bin/rm -f \(rulePath)", prompt: L("Cocaine is removing its permission."))
    }

    /// Asks for admin rights through Authorization Services; with `execute: false` it only shows the prompt.
    static func authorize(prompt: String, then body: (AuthorizationRef) -> Bool) -> Bool {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let auth = ref else { return false }
        defer { AuthorizationFree(auth, [.destroyRights]) }
        // Every C string handed to Authorization Services must stay alive for the whole call.
        let status: OSStatus = kAuthorizationRightExecute.withCString { right in
            kAuthorizationEnvironmentPrompt.withCString { promptKey in
                prompt.withCString { text in
                    var rightItem = AuthorizationItem(name: right, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(name: promptKey, valueLength: strlen(text),
                                                       value: UnsafeMutableRawPointer(mutating: text), flags: 0)
                    return withUnsafeMutablePointer(to: &rightItem) { rightPtr in
                        withUnsafeMutablePointer(to: &promptItem) { promptPtr in
                            var rights = AuthorizationRights(count: 1, items: rightPtr)
                            var env = AuthorizationEnvironment(count: 1, items: promptPtr)
                            return AuthorizationCopyRights(auth, &rights, &env,
                                                           [.interactionAllowed, .extendRights, .preAuthorize], nil)
                        }
                    }
                }
            }
        }
        return status == errAuthorizationSuccess && body(auth)
    }

    /// Runs `/bin/sh -c command` as root. AuthorizationExecuteWithPrivileges is deprecated and hidden from Swift,
    /// but it's still the only way to run one command as root without a paid-developer-signed helper.
    static func runAsRoot(_ command: String, prompt: String) -> Bool {
        typealias AEWP = @convention(c) (AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
                                         UnsafePointer<UnsafeMutablePointer<CChar>?>,
                                         UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?) -> OSStatus
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(security, "AuthorizationExecuteWithPrivileges") else { return false }
        let execute = unsafeBitCast(sym, to: AEWP.self)
        return authorize(prompt: prompt) { auth in
            // The command reports its own exit code on stdout, since AEWP doesn't hand back the child's status.
            let args: [UnsafeMutablePointer<CChar>?] = [strdup("-c"), strdup(command + "; echo \"rc=$?\""), nil]
            defer { args.forEach { free($0) } }
            var pipe: UnsafeMutablePointer<FILE>?
            let rc = args.withUnsafeBufferPointer { execute(auth, "/bin/sh", [], $0.baseAddress!, &pipe) }
            guard rc == errAuthorizationSuccess, let pipe else { return false }
            var output = ""
            var buffer = [CChar](repeating: 0, count: 256)
            while fgets(&buffer, 256, pipe) != nil { output += String(cString: buffer) }
            fclose(pipe)
            return output.contains("rc=0")
        }
    }
}

// MARK: - Screen dimming (every display)

/// Dims every screen. The built-in panel and Apple displays go through DisplayServices (the real backlight); any
/// other monitor is dimmed through its gamma table, which macOS restores by itself if the app quits or crashes.
private final class Screens {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    private var getFn: GetFn?, setFn: SetFn?, canFn: CanFn?

    init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        else { return }
        getFn = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        setFn = dlsym(h, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
        canFn = dlsym(h, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanFn.self) }
    }

    var online: [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n)))
    }

    func hasBacklight(_ d: CGDirectDisplayID) -> Bool { canFn?(d) ?? false }

    func brightness(_ d: CGDirectDisplayID) -> Float? {
        guard let get = getFn else { return nil }
        var b: Float = 0
        return get(d, &b) == 0 ? b : nil
    }

    /// Never below 1%: dimmed, not off.
    func setBrightness(_ d: CGDirectDisplayID, _ v: Float) { _ = setFn?(d, min(max(v, 0.01), 1)) }

    /// Software dimming for monitors without a controllable backlight: 1 = normal, lower = darker.
    func setGamma(_ d: CGDirectDisplayID, _ scale: Float) {
        CGSetDisplayTransferByFormula(d, 0, scale, 1, 0, scale, 1, 0, scale, 1)
    }

    func restoreGamma() { CGDisplayRestoreColorSyncSettings() }
}

/// What one dim changes on each screen, so it can be faded in and out and undone exactly.
private struct DimPlan {
    struct Backlit { let id: CGDirectDisplayID; let from: Float; let to: Float }
    var backlit: [Backlit] = []
    var gamma: [(id: CGDirectDisplayID, to: Float)] = []
    var displays: Set<CGDirectDisplayID> { Set(backlit.map(\.id) + gamma.map(\.id)) }
}

// MARK: - Settings

private struct Settings {
    private let d = UserDefaults.standard
    static let delayChoices = [1, 2, 5, 10, 15, 30]   // minutes

    var dimEnabled: Bool {
        get { d.object(forKey: "dimEnabled") as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: "dimEnabled") }
    }
    /// 0.01…0.50; the default is about the lowest brightness-key step (1/16).
    var level: Float {
        get { Float(d.object(forKey: "dimLevel") as? Double ?? 0.06) }
        nonmutating set { d.set(Double(newValue), forKey: "dimLevel") }
    }
    /// Idle time before dimming, in seconds.
    var delay: Double {
        get { d.object(forKey: "dimDelaySeconds") as? Double ?? 120 }
        nonmutating set { d.set(newValue, forKey: "dimDelaySeconds") }
    }
    /// Brightness to put back, per display, if the app quit or crashed while screens were lowered.
    var savedBrightness: [CGDirectDisplayID: Float] {
        get {
            (d.dictionary(forKey: "savedBrightnesses") as? [String: Double] ?? [:]).reduce(into: [:]) { out, kv in
                if let id = CGDirectDisplayID(kv.key) { out[id] = Float(kv.value) }
            }
        }
        nonmutating set {
            if newValue.isEmpty { d.removeObject(forKey: "savedBrightnesses"); return }
            d.set(Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), Double($0.value)) }), forKey: "savedBrightnesses")
        }
    }
}

// MARK: - Baggie glyph

private enum Baggie {
    struct Palette {
        var outline: NSColor
        var fill: NSColor
        var powder: NSColor
        var powderEdge: NSColor?
    }

    /// Draws a see-through zip-lock baggie on an 18×18 grid scaled into `rect`. `level` (0…1) is how full
    /// it is: the powder heap grows from a small pile in the middle to fill the bottom. `pouring` adds a
    /// thin stream of powder falling from the top, used while it fills.
    static func draw(in rect: NSRect, level: CGFloat, pouring: Bool = false, palette: Palette) {
        let s = rect.width / 18
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * s, y: rect.minY + y * s) }

        // Bag: square-cut top, rounded bottom.
        let (l, r, b, t, rb, rt): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (2.9, 15.1, 1.4, 16.2, 2.6, 0.7)
        let bag = NSBezierPath()
        bag.move(to: p(l, t - rt))
        bag.line(to: p(l, b + rb))
        bag.curve(to: p(l + rb, b), controlPoint1: p(l, b + rb * 0.45), controlPoint2: p(l + rb * 0.45, b))
        bag.line(to: p(r - rb, b))
        bag.curve(to: p(r, b + rb), controlPoint1: p(r - rb * 0.45, b), controlPoint2: p(r, b + rb * 0.45))
        bag.line(to: p(r, t - rt))
        bag.curve(to: p(r - rt, t), controlPoint1: p(r, t - rt * 0.45), controlPoint2: p(r - rt * 0.45, t))
        bag.line(to: p(l + rt, t))
        bag.curve(to: p(l, t - rt), controlPoint1: p(l + rt * 0.45, t), controlPoint2: p(l, t - rt * 0.45))
        bag.close()
        palette.fill.setFill()
        bag.fill()
        palette.outline.setStroke()
        bag.lineWidth = 1.25 * s
        bag.lineJoinStyle = .round
        bag.stroke()

        // Zip seal: the double line that makes it read as a zip-lock bag.
        for y in [13.6, 11.9] as [CGFloat] {
            let zip = NSBezierPath()
            zip.move(to: p(l, y))
            zip.line(to: p(r, y))
            zip.lineWidth = 1.0 * s
            zip.stroke()
        }

        let level = min(max(level, 0), 1)
        guard level > 0.01 else { return }
        // Powder: a soft heap on the bottom, slumped a little to one side, scaled around the bottom centre.
        let base: CGFloat = 2.8, cx: CGFloat = 9
        let sx = 0.35 + 0.65 * level, sy = level
        func h(_ x: CGFloat, _ y: CGFloat) -> NSPoint { p(cx + (x - cx) * sx, base + (y - base) * sy) }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 4.3 * s, y: rect.minY + 2.8 * s, width: 9.4 * s, height: 8.0 * s),
                     xRadius: 1.5 * s, yRadius: 1.5 * s).addClip()
        let heap = NSBezierPath()
        heap.move(to: h(3, 0))
        heap.line(to: h(3, 7.3))
        heap.curve(to: h(8.2, 9.5), controlPoint1: h(4.6, 8.3), controlPoint2: h(6.4, 9.5))
        heap.curve(to: h(15, 6.1), controlPoint1: h(10.6, 9.5), controlPoint2: h(12.8, 7.1))
        heap.line(to: h(15, 0))
        heap.close()
        palette.powder.setFill()
        heap.fill()
        if let edge = palette.powderEdge {         // keeps white powder visible on a light bar
            edge.setStroke()
            heap.lineWidth = 0.8 * s
            heap.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        if pouring && level < 0.97 {
            let top = base + 6.7 * sy                // roughly the heap's peak
            let stream = NSBezierPath(rect: NSRect(x: rect.minX + 8.3 * s, y: rect.minY + top * s,
                                                   width: 0.9 * s, height: max(0, 11.2 - top) * s))
            palette.powder.setFill()
            stream.fill()
            if let edge = palette.powderEdge { edge.setStroke(); stream.lineWidth = 0.5 * s; stream.stroke() }
        }
    }

    /// Clear plastic bag with white powder, tuned for a light or a dark menu bar; no color.
    static func palette(dark: Bool) -> Palette {
        dark
            ? Palette(outline: NSColor.white.withAlphaComponent(0.78), fill: NSColor.white.withAlphaComponent(0.14),
                      powder: .white, powderEdge: nil)
            : Palette(outline: NSColor.black.withAlphaComponent(0.55), fill: NSColor.black.withAlphaComponent(0.07),
                      powder: .white, powderEdge: NSColor.black.withAlphaComponent(0.38))
    }

    /// Menu-bar glyph; it redraws for the bar's current (light/dark) appearance.
    static func image(level: CGFloat, pouring: Bool = false, size: CGFloat = 18) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            draw(in: rect, level: level, pouring: pouring, palette: palette(dark: dark))
            return true
        }
    }
}

// MARK: - Build-time assets (`Cocaine --render-assets <dir>`)

private enum Assets {
    static func png(_ w: Int, _ h: Int, _ draw: (NSRect) -> Void) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func appIcon(in r: NSRect) {
        let body = r.insetBy(dx: r.width * 0.1, dy: r.width * 0.1)
        let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
        NSGradient(starting: NSColor(white: 0.30, alpha: 1), ending: NSColor(white: 0.13, alpha: 1))!.draw(in: shape, angle: -90)
        let g = body.width * 0.64
        Baggie.draw(in: NSRect(x: body.midX - g / 2, y: body.midY - g / 2, width: g, height: g), level: 1,
                    palette: .init(outline: NSColor.white.withAlphaComponent(0.85), fill: NSColor.white.withAlphaComponent(0.14),
                                   powder: .white, powderEdge: nil))
    }

    /// Animated GIF for the README: the baggie filling and emptying, on a light and a dark background.
    static func renderDemoGIF(to url: URL) {
        let fps = 20.0
        var frames: [(level: CGFloat, pouring: Bool)] = []
        func hold(_ level: CGFloat, _ secs: Double) { for _ in 0..<Int(secs * fps) { frames.append((level, false)) } }
        func ramp(_ a: CGFloat, _ b: CGFloat, _ secs: Double, filling: Bool) {
            let n = Int(secs * fps)
            for i in 1...n {
                let f = CGFloat(i) / CGFloat(n), e = filling ? 1 - (1 - f) * (1 - f) : f * f   // same easing as the app
                frames.append((a + (b - a) * e, filling && i < n))
            }
        }
        hold(0, 0.7); ramp(0, 1, 1.4, filling: true); hold(1, 1.6); ramp(1, 0, 0.7, filling: false)

        let tile = 180, w = tile * 2, h = tile
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames.count, nil)
        else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in frames {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            for (i, dark) in [false, true].enumerated() {
                (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                let cell = NSRect(x: i * tile, y: 0, width: tile, height: tile)
                cell.fill()
                let g = CGFloat(tile) * 0.62
                Baggie.draw(in: NSRect(x: cell.midX - g / 2, y: cell.midY - g / 2, width: g, height: g),
                            level: frame.level, pouring: frame.pouring, palette: Baggie.palette(dark: dark))
            }
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(dest, rep.cgImage!,
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
    }

    static func render(to dir: URL) {
        let iconset = dir.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for pt in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
                try? png(pt * scale, pt * scale, appIcon).write(to: iconset.appendingPathComponent(name))
            }
        }
        // Menu-bar glyph preview: the fill animation at 18 pt @2x, on a light and a dark bar.
        let cell: CGFloat = 60
        let frames: [(CGFloat, Bool)] = [(0, false), (0.35, true), (0.7, true), (1, false)]
        let preview = png(Int(cell) * frames.count, Int(cell) * 2) { _ in
            for (row, bg) in [NSColor(white: 0.93, alpha: 1), NSColor(white: 0.12, alpha: 1)].enumerated() {
                bg.setFill()
                NSRect(x: 0, y: CGFloat(1 - row) * cell, width: cell * CGFloat(frames.count), height: cell).fill()
                for (col, (level, pouring)) in frames.enumerated() {
                    let px: CGFloat = 36
                    let x = CGFloat(col) * cell + (cell - px) / 2, y = CGFloat(1 - row) * cell + (cell - px) / 2
                    Baggie.draw(in: NSRect(x: x, y: y, width: px, height: px), level: level, pouring: pouring,
                                palette: Baggie.palette(dark: row == 1))
                }
            }
        }
        try? preview.write(to: dir.appendingPathComponent("menubar-preview.png"))
    }
}

// MARK: - Panel

private final class PanelModel: ObservableObject {
    private let settings = Settings()
    static let magnets: [Double] = [1, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50]   // % the slider snaps to

    @Published var on = false
    @Published var holdMissing = false
    @Published var needsAuth = false
    @Published var loginEnabled = false
    @Published var previewing = false
    @Published var fillLevel: CGFloat = 0
    @Published var pouring = false
    @Published var ai = AIHooks.Status()   // the "AI alerts" row shows only on Macs with Claude Code or Codex
    @Published var dimEnabled: Bool { didSet { settings.dimEnabled = dimEnabled } }
    @Published private(set) var levelPercent: Double
    @Published var delayMinutes: Int { didSet { if delayMinutes > 0 { settings.delay = Double(delayMinutes * 60) } } }
    /// "" = same as the Mac, otherwise a code from Language.codes. Changes apply at once.
    @Published var language: String = Language.chosen ?? "" {
        didSet { Language.set(language.isEmpty ? nil : language, persist: persistLanguage); languageChanged() }
    }
    var persistLanguage = true
    var languageChanged: () -> Void = {}

    // wired up by AppDelegate
    var toggleCocaine: () -> Void = {}
    var preview: () -> Void = {}
    var setLogin: (Bool) -> Void = { _ in }
    var setAIAlerts: (Bool) -> Void = { _ in }
    var quit: () -> Void = {}

    init() {
        dimEnabled = settings.dimEnabled
        levelPercent = Double((settings.level * 100).rounded())
        delayMinutes = Int(settings.delay) / 60
    }

    /// Free movement in whole percents, but values near a magnet snap to it, with a trackpad "click".
    func setLevel(_ raw: Double) {
        var v = raw.rounded()
        if let near = Self.magnets.min(by: { abs($0 - raw) < abs($1 - raw) }), abs(near - raw) <= 1.2 { v = near }
        guard v != levelPercent else { return }
        if Self.magnets.contains(v) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        levelPercent = v
        settings.level = Float(v) / 100
    }
}

private struct PanelView: View {
    @ObservedObject var m: PanelModel

    private var status: String {
        if m.needsAuth { return L("Admin password needed") }
        if m.on && m.holdMissing { return L("Keeping the screen on…") }
        return m.on ? L("Your Mac stays awake") : L("Your Mac sleeps as usual")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: Baggie.image(level: m.fillLevel, pouring: m.pouring, size: 28))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Cocaine").font(.headline)
                        Text(appVersion).font(.caption2).foregroundStyle(.tertiary)   // e.g. "1.7"
                    }
                    Text(status).font(.caption).lineLimit(1)
                        .foregroundStyle(m.needsAuth || (m.on && m.holdMissing) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 6)
                Toggle("Cocaine", isOn: Binding(get: { m.on }, set: { _ in m.toggleCocaine() }))
                    .toggleStyle(.switch).labelsHidden()
            }

            if m.on {                                  // brightness options exist only while Cocaine is on
                Divider()

                HStack {
                    Text(L("Dim the screen when idle")).lineLimit(1)
                    Spacer(minLength: 6)
                    Toggle(L("Dim the screen when idle"), isOn: $m.dimEnabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                .help(L("Goes back to normal as soon as you touch anything"))
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { m.levelPercent }, set: { m.setLevel($0) }), in: 1...50)
                        Text("\(Int(m.levelPercent))%").monospacedDigit().frame(width: 32, alignment: .trailing)
                        Button(L("Preview")) { m.preview() }.controlSize(.small).disabled(m.previewing)
                            .help(L("Shows the minimum brightness for 3 seconds"))
                    }
                    HStack(spacing: 6) {
                        Text(L("After")).fixedSize()
                        Picker(L("After"), selection: $m.delayMinutes) {
                            ForEach(Settings.delayChoices, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                        Text(L("min")).fixedSize()
                    }
                }
                .disabled(!m.dimEnabled)
                .opacity(m.dimEnabled ? 1 : 0.45)
            }

            Divider()

            if m.ai.available {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(L("AI alerts")).lineLimit(1)
                        Spacer(minLength: 6)
                        Toggle(L("AI alerts"), isOn: Binding(get: { m.ai.on }, set: { m.setAIAlerts($0) }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    if m.ai.on && m.ai.codexNeedsTrust {   // Codex runs new hooks only once the user trusts them
                        Text(L("Codex: approve them once in Settings → Hooks"))
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .help(L("Flashes the screen when Claude Code or Codex finishes or needs you"))
            }

            HStack(spacing: 0) {                       // two groups and one flexible gap, no wasted spacing
                HStack(spacing: 6) {
                    Text(L("Open at login")).lineLimit(1)
                    Toggle(L("Open at login"), isOn: Binding(get: { m.loginEnabled }, set: { m.setLogin($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small).fixedSize()
                }
                .layoutPriority(1)                     // text first, empty space last
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    Menu {
                        Picker(L("Language"), selection: $m.language) {
                            Text("\(L("Same as Mac"))  \(Language.flag(Language.system))").tag("")
                            ForEach(Language.codes, id: \.self) { Text("\(Language.flag($0))  \(Language.nativeName($0))").tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(Language.flag(m.language.isEmpty ? Language.system : m.language))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 22)                  // just the flag, no invisible padding
                    .help(L("Language"))
                    Button(L("Quit")) { m.quit() }.controlSize(.small).fixedSize()
                        .help(L("Turns Cocaine off and quits"))
                }
                .layoutPriority(2)                     // never truncated
            }
        }
        .padding(14)
        .frame(width: 312, alignment: .topLeading)     // never centered, so nothing can slide out sideways
        .fixedSize(horizontal: false, vertical: true)
        .focusEffectDisabled()
    }
}

// MARK: - Alerts ("an AI finished / needs you")

/// Drives the overlay's animation (SwiftUI's @State needs full Xcode's macros, which the command-line tools lack).
private final class AlertAnimation: ObservableObject {
    @Published var tint = 0.0
    @Published var shown = false

    func start() {
        withAnimation(.easeOut(duration: 0.25)) { shown = true }
        for (i, value) in [0.55, 0, 0.55, 0].enumerated() {     // two flashes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(i)) {
                withAnimation(.easeInOut(duration: 0.18)) { self.tint = value }
            }
        }
    }
}

/// Full-screen overlay on every screen: two quick flashes, then a card with the message for a few seconds.
private struct AlertView: View {
    let title: String
    let message: String
    @ObservedObject var anim: AlertAnimation

    var body: some View {
        ZStack {
            Color.white.opacity(anim.tint)
            VStack(spacing: 10) {
                Image(nsImage: Baggie.image(level: 1, size: 64))
                Text(title).font(.system(size: 28, weight: .bold))
                Text(message).font(.system(size: 20))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 36).padding(.vertical, 26)
            .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 22))
            .opacity(anim.shown ? 1 : 0)
            .scaleEffect(anim.shown ? 1 : 0.92)
        }
        .ignoresSafeArea()
    }
}

private final class Alerter {
    private var windows: [NSWindow] = []
    private(set) var shownAt: Date?

    var isShowing: Bool { !windows.isEmpty }

    func show(title: String, message: String) {
        close(animated: false)
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size), styleMask: .borderless,
                             backing: .buffered, defer: false, screen: screen)
            w.level = .screenSaver                           // above the menu bar, the Dock and full-screen apps
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let anim = AlertAnimation()
            let host = NSHostingView(rootView: AlertView(title: title, message: message, anim: anim))
            host.sizingOptions = []                          // the window sets the size; SwiftUI must not move it
            host.appearance = NSAppearance(named: .darkAqua)    // light baggie on the dark card
            w.contentView = host
            w.setFrame(screen.frame, display: true)
            log.notice("alert window at \(w.frame.debugDescription, privacy: .public) for screen \(screen.frame.debugDescription, privacy: .public)")
            w.orderFrontRegardless()
            windows.append(w)
            DispatchQueue.main.async { anim.start() }
        }
        shownAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            if let at = self?.shownAt, Date().timeIntervalSince(at) >= 4.4 { self?.close(animated: true) }
        }
    }

    func close(animated: Bool) {
        let closing = windows
        windows = []
        shownAt = nil
        guard animated else { closing.forEach { $0.orderOut(nil) }; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { closing.forEach { $0.orderOut(nil) } })
    }
}

// MARK: - AI alerts (hooks in Claude Code and Codex)

/// Just enough JSON to edit another app's config file without reordering its keys or rewriting its values: strings
/// and numbers keep their exact text; only the indentation is redone (2 spaces, as both apps write it).
private enum JSONValue: Equatable {
    case object([Member])
    case array([JSONValue])
    case scalar(String)              // a string with its quotes, a number, true, false or null, exactly as written

    struct Member: Equatable {
        var key: String              // the raw text between the quotes
        var value: JSONValue
    }

    static func string(_ s: String) -> JSONValue {
        let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return .scalar(String(decoding: data, as: UTF8.self))
    }

    /// nil unless `text` is valid JSON (Foundation checks it first, so the scanner below can trust the syntax).
    static func parse(_ text: String) -> JSONValue? {
        let b = Array(text.utf8)
        guard (try? JSONSerialization.jsonObject(with: Data(b), options: [.fragmentsAllowed])) != nil else { return nil }
        var i = 0
        func space() { while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 } }
        func token() -> String {
            let start = i
            if b[i] == UInt8(ascii: "\"") {
                i += 1
                while b[i] != UInt8(ascii: "\"") { i += b[i] == UInt8(ascii: "\\") ? 2 : 1 }
                i += 1
            } else {
                while i < b.count, !",]} \t\r\n".utf8.contains(b[i]) { i += 1 }
            }
            return String(decoding: b[start..<i], as: UTF8.self)
        }
        func value() -> JSONValue {
            space()
            let open = b[i]
            guard open == UInt8(ascii: "{") || open == UInt8(ascii: "[") else { return .scalar(token()) }
            let close = open == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
            var members: [Member] = [], items: [JSONValue] = []
            i += 1
            space()
            while b[i] != close {
                if open == UInt8(ascii: "{") {
                    let key = token()
                    space()
                    i += 1                                       // ':'
                    members.append(Member(key: String(key.dropFirst().dropLast()), value: value()))
                } else {
                    items.append(value())
                }
                space()
                if b[i] == UInt8(ascii: ",") { i += 1; space() }
            }
            i += 1
            return open == UInt8(ascii: "{") ? .object(members) : .array(items)
        }
        return value()
    }

    func render(_ indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .scalar(let s):
            return s
        case .array(let items):
            return items.isEmpty ? "[]" : "[\n" + items.map { inner + $0.render(inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .object(let members):
            return members.isEmpty ? "{}"
                : "{\n" + members.map { "\(inner)\"\($0.key)\": " + $0.value.render(inner) }.joined(separator: ",\n") + "\n\(indent)}"
        }
    }

    var items: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var members: [Member]? { if case .object(let m) = self { return m }; return nil }

    subscript(key: String) -> JSONValue? {
        get { members?.first { $0.key == key }?.value }
        set {
            guard var m = members else { return }
            if let i = m.firstIndex(where: { $0.key == key }) {
                if let newValue { m[i].value = newValue } else { m.remove(at: i) }
            } else if let newValue {
                m.append(Member(key: key, value: newValue))
            }
            self = .object(m)
        }
    }
}

/// The "AI alerts" switch: hooks that make Claude Code and Codex open cocaine://alert when they finish or need you.
/// They live in each tool's own config file; turning them off removes only them, every other hook and setting stays.
private enum AIHooks {
    struct Tool {
        let name: String                                  // also the alert's title
        let folder: String                                // the tool's config folder: skipped where it doesn't exist
        let file: String
        let events: [(name: String, kind: String)]        // hook event → alert kind (done or input)
    }

    static var home = NSHomeDirectory()                   // `--ai-alerts … --home <dir>` works on a copy
    static let marker = "cocaine://alert"

    static var tools: [Tool] {
        [Tool(name: "Claude Code", folder: home + "/.claude", file: home + "/.claude/settings.json",
              events: [("Stop", "done"), ("Notification", "input")]),
         Tool(name: "Codex", folder: home + "/.codex", file: home + "/.codex/hooks.json",
              events: [("Stop", "done"), ("PermissionRequest", "input")])]
    }
    static var present: [Tool] { tools.filter { FileManager.default.fileExists(atPath: $0.folder) } }

    /// Does nothing while Cocaine is closed, so a closed Cocaine stays closed. Keep it word for word: Codex asks
    /// to trust a hook again whenever its command changes.
    static func command(_ tool: Tool, _ kind: String) -> String {
        let from = tool.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? tool.name
        return "pgrep -qx Cocaine && open -g 'cocaine://alert?from=\(from)&event=\(kind)'; true"
    }

    private static func group(_ tool: Tool, _ kind: String) -> JSONValue {
        .object([.init(key: "hooks", value: .array([.object([
            .init(key: "type", value: .string("command")),
            .init(key: "command", value: .string(command(tool, kind))),
            .init(key: "timeout", value: .scalar("10")),
        ])]))])
    }

    private static func isOurs(_ handler: JSONValue) -> Bool {
        guard case .scalar(let s)? = handler["command"] else { return false }
        return s.contains(marker) || s.contains("cocaine:\\/\\/alert")
    }
    private static func hasOurs(_ group: JSONValue) -> Bool { group["hooks"]?.items?.contains(where: isOurs) ?? false }

    /// The file's JSON: {} if it doesn't exist or is empty; nil if it isn't a JSON object this code can round-trip.
    static func load(_ path: String) -> JSONValue? {
        guard FileManager.default.fileExists(atPath: path) else { return .object([]) }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .object([]) }
        guard let v = JSONValue.parse(text), v.members != nil,
              let a = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary,
              let b = try? JSONSerialization.jsonObject(with: Data(v.render().utf8)) as? NSDictionary, a == b
        else { return nil }
        return v
    }

    static func installed(_ root: JSONValue) -> Bool {
        root["hooks"]?.members?.contains { $0.value.items?.contains(where: hasOurs) ?? false } ?? false
    }

    /// `root` with our hooks added or removed. Ones already there are updated where they are, so Codex's trust
    /// (keyed by position) survives; groups, events and "hooks" left empty by a removal go too. nil = hands off.
    static func edited(_ root: JSONValue, for tool: Tool, on: Bool) -> JSONValue? {
        let before = root["hooks"]
        guard let events = (before ?? .object([])).members else { return nil }
        var wanted = on ? Dictionary(uniqueKeysWithValues: tool.events.map { ($0.name, group(tool, $0.kind)) }) : [:]
        var result: [JSONValue.Member] = []
        for var event in events {
            guard let groups = event.value.items else { wanted[event.key] = nil; result.append(event); continue }
            var out: [JSONValue] = []
            for g in groups {
                guard hasOurs(g) else { out.append(g); continue }
                if g["hooks"]?.items?.allSatisfy(isOurs) == true, let w = wanted.removeValue(forKey: event.key) {
                    out.append(w)
                    continue
                }
                let kept = (g["hooks"]?.items ?? []).filter { !isOurs($0) }   // ours inside someone else's group
                if !kept.isEmpty { var g = g; g["hooks"] = .array(kept); out.append(g) }
            }
            if let w = wanted.removeValue(forKey: event.key) { out.append(w) }
            if out.isEmpty && !groups.isEmpty { continue }
            event.value = .array(out)
            result.append(event)
        }
        for e in tool.events { if let w = wanted.removeValue(forKey: e.name) { result.append(.init(key: e.name, value: .array([w]))) } }
        var root = root
        if !result.isEmpty { root["hooks"] = .object(result) }
        else if before?.members?.isEmpty == false { root["hooks"] = nil }
        return root
    }

    /// Writes through symlinks (dotfile setups) and keeps the file's permissions.
    private static func write(_ value: JSONValue, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        do { try Data((value.render() + "\n").utf8).write(to: url, options: .atomic) } catch { return false }
        if let perms { try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
        return true
    }

    /// Adds or removes the hooks in every tool on this Mac (or just `only`); returns the files it couldn't update.
    @discardableResult
    static func set(_ on: Bool, only: [Tool]? = nil) -> [String] {
        var failed: [String] = []
        for tool in only ?? present {
            guard let root = load(tool.file), let new = edited(root, for: tool, on: on) else { failed.append(tool.file); continue }
            if new != root && !write(new, to: tool.file) { failed.append(tool.file) }
        }
        return failed
    }

    /// At launch: brings hooks written by an older Cocaine (or by hand) up to date, only where they already are.
    static func update() {
        let tools = present.filter { load($0.file).map(installed) ?? false }
        if !tools.isEmpty { set(true, only: tools) }
    }

    /// Codex runs a new hook only after the user trusts it once (/hooks, or Settings → Hooks in the ChatGPT app);
    /// it then keeps `trusted_hash` under [hooks.state."<file>:<event>:<group>:<handler>"] in its config.toml.
    static func codexNeedsTrust() -> Bool {
        guard let codex = tools.last, FileManager.default.fileExists(atPath: codex.folder),
              let events = load(codex.file)?["hooks"]?.members else { return false }
        let config = (try? String(contentsOfFile: codex.folder + "/config.toml", encoding: .utf8)) ?? ""
        for event in events {
            let snake = event.key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
            for (g, group) in (event.value.items ?? []).enumerated() {
                for (h, handler) in (group["hooks"]?.items ?? []).enumerated() where isOurs(handler) {
                    if !trusted("\(codex.file):\(snake):\(g):\(h)", in: config) { return true }
                }
            }
        }
        return false
    }

    private static func trusted(_ key: String, in config: String) -> Bool {
        guard let r = config.range(of: "\"\(key)\"") else { return false }
        let rest = config[r.upperBound...]
        let lineEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
        let lineStart = config[..<r.lowerBound].lastIndex(of: "\n").map { config.index(after: $0) } ?? config.startIndex
        guard config[lineStart...].hasPrefix("[") else { return rest[..<lineEnd].contains("trusted_hash") }  // inline table
        let body = rest[lineEnd...]                                                  // [hooks.state."…"] table
        return body[..<(body.range(of: "\n[")?.lowerBound ?? body.endIndex)].contains("trusted_hash")
    }

    struct Status: Equatable { var available = false, on = false, codexNeedsTrust = false }

    static func status() -> Status {
        let tools = present
        let on = tools.contains { load($0.file).map(installed) ?? false }
        return Status(available: !tools.isEmpty, on: on, codexNeedsTrust: on && codexNeedsTrust())
    }
}

// MARK: - App

/// Tells the app when the SwiftUI content's size changes (e.g. the brightness section appears).
private final class PanelHostingView: NSHostingView<PanelView> {
    var onSizeChange: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}

/// Borderless panel shown under the menu-bar icon. It can take clicks without activating the app, never
/// resizes while open, and closes only when you click elsewhere, press Esc or click the icon again.
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isMovable = false

        let fx = NSVisualEffectView()
        fx.material = .menu
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = MenuPanel.roundedMask(radius: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(content)
        NSLayoutConstraint.activate([      // pinned to the top only: the app sizes the window, top edge fixed
            content.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            content.topAnchor.constraint(equalTo: fx.topAnchor),
        ])
        contentView = fx
    }

    private static func roundedMask(radius r: CGFloat) -> NSImage {
        let edge = 2 * r + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}


private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let model = PanelModel()
    private var statusItem: NSStatusItem!
    private var panel: MenuPanel!
    private var hostView: PanelHostingView!
    private var panelTop: CGFloat = 0
    private var wantOn: Bool?        // what the user last asked for, until the script has applied it
    private var applying = false
    private var panelMonitors: [Any] = []
    private var ticker: Timer?
    private var fadeTimer: Timer?
    private var sigterm: DispatchSourceSignal?
    private var ticks = 0
    private var lastOn: Bool?
    private var lastIdle = 0.0
    private let screens = Screens()
    private var dimPlan: DimPlan?       // screens lowered after idle time; nil when not lowered
    private var previewPlan: DimPlan?   // same, during "Preview"
    private var dimT: Float = 0         // how far the current plan is applied (0 = normal, 1 = fully dimmed)
    private var supervising = false
    private let launchedAt = Date()
    private let alerter = Alerter()
    private var brightUntil = Date.distantPast   // after an alert, don't dim again right away
    private var didFinishLaunching = false
    private var launchedForAlert = false         // started only to show an alert: don't turn Cocaine on
    private var settingAI = false
    private var iconLevel: CGFloat = -1   // -1 = not drawn yet
    private var iconAnim: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        model.toggleCocaine = { [weak self] in self?.toggleCocaine() }
        model.preview = { [weak self] in self?.preview() }
        model.setLogin = { [weak self] in self?.setLogin($0) }
        model.setAIAlerts = { [weak self] in self?.setAIAlerts($0) }
        model.quit = { NSApp.terminate(nil) }
        model.languageChanged = { [weak self] in self?.refreshIcon(on: System.cocaineOn, animate: false) }
        hostView = PanelHostingView(rootView: PanelView(m: model))
        hostView.sizingOptions = [.intrinsicContentSize]
        hostView.onSizeChange = { [weak self] in DispatchQueue.main.async { self?.fitPanel(animated: true) } }
        panel = MenuPanel(content: hostView)

        for (id, saved) in settings.savedBrightness {   // quit or crashed while screens were lowered
            if let cur = screens.brightness(id), cur < saved { screens.setBrightness(id, saved) }
        }
        settings.savedBrightness = [:]
        UserDefaults.standard.removeObject(forKey: "savedBrightness")   // pre-1.6 single-display key

        signal(SIGTERM, SIG_IGN)                     // quit cleanly (restoring brightness) on kill/pkill
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }
        sigterm?.resume()

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        tick()
        didFinishLaunching = true
        if launchedForAlert {                        // `open cocaine://…` started us: show it, then go away again
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
            return
        }
        if !System.cocaineOn { toggleCocaine() }     // opening the app turns Cocaine on
        DispatchQueue.global().async {
            AIHooks.update()
            let ai = AIHooks.status()
            DispatchQueue.main.async { self.model.ai = ai }   // ready before the panel first opens
        }
    }

    /// `cocaine://alert?from=Claude%20Code&event=done|input` (or `&message=…`) from an AI agent's hook or any script.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "cocaine" && url.host == "alert" {
            if !didFinishLaunching { launchedForAlert = true }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            let message = value("message") ?? (value("event") == "input" ? L("needs your input") : L("has finished"))
            alert(from: value("from") ?? "Cocaine", message: message, away: value("test") == "away" ? true : nil)
        }
    }

    /// Away from the Mac (idle 20 s, or screens dimmed): wake the screens, restore brightness, flash them with the
    /// message and play a sound. At the Mac: just refill the baggie in the menu bar.
    private func alert(from: String, message: String, away forced: Bool? = nil) {
        let away = forced ?? (System.idleSeconds >= 20 || dimPlan != nil)
        log.notice("alert from \(from, privacy: .public) (away: \(away, privacy: .public))")
        pulseIcon()
        guard away else { return }
        var activity: IOPMAssertionID = 0                // wakes a sleeping display
        IOPMAssertionDeclareUserActivity("Cocaine alert" as CFString, kIOPMUserActiveLocal, &activity)
        restore()
        brightUntil = Date().addingTimeInterval(max(settings.delay, 60))
        alerter.show(title: from, message: message)
        NSSound(named: "Glass")?.play()
    }

    /// The fill animation again, as a small "something happened" in the menu bar.
    private func pulseIcon() {
        guard System.cocaineOn else { return }
        iconLevel = 0.2
        refreshIcon(on: true)
    }

    /// Quitting (Quit button, ⌘Q, logout, shutdown) turns Cocaine off, just as opening the app turns it on.
    func applicationWillTerminate(_ n: Notification) {
        fadeTimer?.invalidate()
        if let plan = dimPlan ?? previewPlan { apply(plan, 0); if !plan.gamma.isEmpty { screens.restoreGamma() } }
        settings.savedBrightness = [:]
        if System.cocaineOn { engine("off") }
    }

    /// Opening Cocaine again (e.g. from Spotlight) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // An `open` right after launch (Homebrew reopening the app after an upgrade) isn't a request for the panel.
        guard Date().timeIntervalSince(launchedAt) > 5 else { return false }
        if !panel.isVisible { showPanel(fromClick: false) }
        return false
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel(fromClick: true) }
    }

    /// Opens the panel under the icon that was clicked. With several screens the icon is in every screen's menu bar,
    /// so the click position, not the icon's own window, says which one.
    private func showPanel(fromClick: Bool) {
        refreshPanelState()
        let mouse = NSEvent.mouseLocation
        let clicked = fromClick ? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } : nil
        var screen = clicked ?? NSScreen.main
        var anchorX = mouse.x
        if let button = statusItem.button, let bar = button.window {
            let icon = bar.convertToScreen(button.convert(button.bounds, to: nil))
            if clicked == nil || clicked == bar.screen { screen = bar.screen ?? screen; anchorX = icon.midX }
        }
        guard let screen else { return }
        panelTop = (screen.visibleFrame.maxY - 6).rounded()          // just under that screen's menu bar
        fitPanel(animated: false, centeredOn: anchorX, screen: screen)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        // Clicks elsewhere close it; a click on the icon itself (which also arrives here on macOS 27) toggles instead.
        let iconZone = NSRect(x: anchorX - 18, y: screen.frame.maxY - 44, width: 36, height: 44)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            if !iconZone.contains(NSEvent.mouseLocation) { self?.hidePanel() }
        }) { panelMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { self?.hidePanel(); return nil }   // Esc
            return e
        }) { panelMonitors.append(m) }
    }

    /// Sizes the panel to its content with the top edge fixed under the icon, so it only grows or shrinks downward.
    private func fitPanel(animated: Bool, centeredOn midX: CGFloat? = nil, screen: NSScreen? = nil) {
        guard panel.isVisible || midX != nil else { return }
        hostView.layoutSubtreeIfNeeded()
        let size = hostView.fittingSize
        guard size.height > 0 else { return }
        var frame = NSRect(x: panel.frame.minX, y: panelTop - size.height, width: size.width, height: size.height)
        if let midX {
            frame = Self.panelFrame(size: size, anchorX: midX, top: panelTop,
                                    visible: (screen ?? NSScreen.main)?.visibleFrame ?? .zero)
        }
        guard frame != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// Centred under the icon, kept 8 pt inside the screen it opens on.
    static func panelFrame(size: NSSize, anchorX: CGFloat, top: CGFloat, visible: NSRect) -> NSRect {
        let x = min(max(anchorX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8).rounded()
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    private func hidePanel() {
        panelMonitors.forEach(NSEvent.removeMonitor)
        panelMonitors.removeAll()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }

    private func refreshPanelState() {
        let login = SMAppService.mainApp.status == .enabled
        if model.loginEnabled != login { model.loginEnabled = login }
        let on = System.cocaineOn
        DispatchQueue.global().async {
            let missing = on && !System.displayHeld
            let ai = AIHooks.status()
            DispatchQueue.main.async {
                if self.model.holdMissing != missing { self.model.holdMissing = missing }
                if missing { self.superviseHold() }
                if !self.settingAI && self.model.ai != ai { self.model.ai = ai }
            }
        }
    }

    /// Adds or removes the Claude Code / Codex hooks; the switch flips at once, like the Cocaine one.
    private func setAIAlerts(_ enable: Bool) {
        guard !settingAI else { return }
        settingAI = true
        model.ai.on = enable
        DispatchQueue.global().async {
            let failed = AIHooks.set(enable)
            let ai = AIHooks.status()
            DispatchQueue.main.async {
                self.settingAI = false
                self.model.ai = ai
                log.notice("AI alerts \(enable ? "on" : "off", privacy: .public), failed: \(failed.count, privacy: .public)")
                guard !failed.isEmpty else { return }
                self.hidePanel()
                NSApp.activate()
                let a = NSAlert()
                a.messageText = L("Can't change AI alerts")
                a.informativeText = failed.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: "\n")
                a.runModal()
            }
        }
    }

    // MARK: State

    private func tick() {
        ticks += 1
        let on = System.cocaineOn
        if on != lastOn {
            lastOn = on
            refreshIcon(on: on)
            if on { superviseHold() }
        } else if on && ticks % 20 == 0 {
            superviseHold()                          // every 10 s
        }
        if wantOn == nil && model.on != on { model.on = on }   // don't fight a switch the user just flipped
        if panel.isVisible && ticks % 4 == 0 { refreshPanelState() }
        if alerter.isShowing, let at = alerter.shownAt, Date().timeIntervalSince(at) > 1.5, System.idleSeconds < 0.6 {
            alerter.close(animated: true)            // the user is back
        }
        updateDimming(on: on)
    }

    /// Fills the baggie gradually when Cocaine turns on, empties it when it turns off.
    private func refreshIcon(on: Bool, animate: Bool = true) {
        guard let b = statusItem.button else { return }
        b.toolTip = on ? L("Cocaine is on") : L("Cocaine is off")
        b.setAccessibilityLabel(b.toolTip)
        guard animate else { return }
        let target: CGFloat = on ? 1 : 0
        iconAnim?.invalidate()
        guard iconLevel >= 0 else { setIconLevel(target, pouring: false); return }   // first draw: no animation
        let start = iconLevel, duration = on ? 1.4 : 0.7
        let began = Date()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let f = min(1, CGFloat(Date().timeIntervalSince(began) / duration))
            let eased = on ? 1 - (1 - f) * (1 - f) : f * f                 // ease-out filling, ease-in emptying
            self.setIconLevel(start + (target - start) * eased, pouring: on && f < 1)
            if f >= 1 { t.invalidate(); self.iconAnim = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        iconAnim = t
    }

    private func setIconLevel(_ level: CGFloat, pouring: Bool) {
        iconLevel = level
        statusItem.button?.image = Baggie.image(level: level, pouring: pouring)
        model.fillLevel = level
        if model.pouring != pouring { model.pouring = pouring }
    }

    /// While Cocaine is on, make sure the script's display helper runs (it doesn't after a restart).
    private func superviseHold() {
        guard !supervising else { return }
        supervising = true
        DispatchQueue.global().async {
            let missing = System.cocaineOn && !System.displayHeld
            if missing { engine("on") }
            DispatchQueue.main.async {
                self.supervising = false
                if missing { log.notice("display hold was missing; restarted it") }
                if self.panel.isVisible { self.refreshPanelState() }
            }
        }
    }

    /// Flips the switch at once and applies it in the background; clicks made meanwhile are never lost.
    private func toggleCocaine() {
        let target = !(wantOn ?? model.on)
        wantOn = target
        model.on = target
        applyWanted()
    }

    private func applyWanted() {
        guard !applying, let target = wantOn else { return }
        applying = true
        DispatchQueue.global().async {
            let arg = target ? "on" : "off"
            var status = engine(arg)
            if status == 2, Authorization.install() {   // first run on this Mac: ask for the admin password once
                log.notice("sudo rule installed")
                status = engine(arg)
            }
            DispatchQueue.main.async {
                self.applying = false
                self.model.needsAuth = status == 2
                if self.wantOn == target { self.wantOn = nil }
                self.tick()                          // shows the real state (reverts the switch if it failed)
                self.refreshPanelState()
                self.applyWanted()                   // the user changed their mind while this was running
            }
        }
    }

    // MARK: Dimming

    private func updateDimming(on: Bool) {
        guard previewPlan == nil else { return }
        let idle = System.idleSeconds
        defer { lastIdle = idle }
        if let plan = dimPlan {
            let unplugged = !plan.displays.isSubset(of: Set(screens.online))
            if idle < lastIdle || !on || !settings.dimEnabled || unplugged { restore(); return }   // input since last tick
            // automatic brightness can creep back up while the screen is lowered
            if ticks % 10 == 0, fadeTimer == nil {
                for b in plan.backlit where (screens.brightness(b.id) ?? 0) > b.to + 0.02 { screens.setBrightness(b.id, b.to) }
            }
        } else if on, settings.dimEnabled, idle >= settings.delay, Date() > brightUntil {
            dim(afterIdle: idle)
        }
    }

    /// Every screen that's on: the built-in panel is skipped only with the lid shut (it's off anyway).
    private func makePlan(level: Float) -> DimPlan {
        var plan = DimPlan()
        let lidClosed = System.lidClosed
        for d in screens.online {
            if CGDisplayIsBuiltin(d) != 0 && lidClosed { continue }
            if screens.hasBacklight(d) {
                if let cur = screens.brightness(d), cur > level { plan.backlit.append(.init(id: d, from: cur, to: level)) }
            } else {
                plan.gamma.append((d, 0.12 + 0.88 * level))           // software: dimmed, never black
            }
        }
        return plan
    }

    private func dim(afterIdle idle: Double) {
        let plan = makePlan(level: settings.level)
        dimPlan = plan                                              // even if empty, so we don't retry every tick
        settings.savedBrightness = Dictionary(uniqueKeysWithValues: plan.backlit.map { ($0.id, $0.from) })
        log.notice("dim \(plan.backlit.count, privacy: .public) backlit + \(plan.gamma.count, privacy: .public) gamma screens after \(Int(idle), privacy: .public)s idle")
        fade(plan, to: 1, over: 1.5)
    }

    private func restore() {
        guard let plan = dimPlan else { return }
        dimPlan = nil
        settings.savedBrightness = [:]
        log.notice("restore \(plan.displays.count, privacy: .public) screens")
        fade(plan, to: 0, over: 0.25) { if !plan.gamma.isEmpty { self.screens.restoreGamma() } }
    }

    /// Puts every screen in `plan` at `t` (0 = as it was, 1 = fully dimmed).
    private func apply(_ plan: DimPlan, _ t: Float) {
        dimT = t
        for b in plan.backlit { screens.setBrightness(b.id, b.from + (b.to - b.from) * t) }
        for g in plan.gamma { screens.setGamma(g.id, 1 + (g.to - 1) * t) }
    }

    private func fade(_ plan: DimPlan, to target: Float, over seconds: Double, then done: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        let start = dimT
        let steps = max(1, Int(seconds / 0.025))
        var i = 0
        let t = Timer(timeInterval: seconds / Double(steps), repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            i += 1
            let f = Float(i) / Float(steps)
            self.apply(plan, start + (target - start) * f * f * (3 - 2 * f))   // smoothstep
            if i >= steps { t.invalidate(); self.fadeTimer = nil; done?() }
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    private func preview() {
        guard previewPlan == nil, dimPlan == nil else { return }
        let plan = makePlan(level: settings.level)
        previewPlan = plan
        settings.savedBrightness = Dictionary(uniqueKeysWithValues: plan.backlit.map { ($0.id, $0.from) })
        model.previewing = true
        fade(plan, to: 1, over: 0.6) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.fade(plan, to: 0, over: 0.4) {
                    if !plan.gamma.isEmpty { self.screens.restoreGamma() }
                    self.previewPlan = nil
                    self.settings.savedBrightness = [:]
                    self.model.previewing = false
                }
            }
        }
    }

    private func setLogin(_ enable: Bool) {
        let svc = SMAppService.mainApp
        do {
            if enable { try svc.register() } else { try svc.unregister() }
            if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            hidePanel()
            NSApp.activate()
            let a = NSAlert()
            a.messageText = L("Can't change Open at Login")
            a.informativeText = "\(error.localizedDescription)\n\n" + L("You can add Cocaine manually in System Settings → General → Login Items.")
            a.runModal()
        }
        model.loginEnabled = svc.status == .enabled
    }
}

// MARK: - Entry point

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--auth-selftest" {
    // Runs the exact install pipeline (AppleScript quoting, printf, visudo, install) without admin rights,
    // writing the rule to the given file instead of /etc/sudoers.d.
    let cmd = Authorization.installCommand(user: NSUserName(), dest: CommandLine.arguments[2], asRoot: false)!
    exit(run("/usr/bin/osascript", ["-e", Authorization.appleScript(for: cmd, admin: false)]))
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--layout-test" {
    // Where the panel lands for a click on the icon of each screen, for two-monitor layouts.
    let size = NSSize(width: 312, height: 198)
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
    exit(0)
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
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--ai-alerts" {
    // `on`, `off` or `status` for the AI alerts hooks (the Homebrew uninstall runs `off`); `--home <dir>` for tests.
    if let i = CommandLine.arguments.firstIndex(of: "--home"), i + 1 < CommandLine.arguments.count {
        AIHooks.home = CommandLine.arguments[i + 1]
    }
    switch CommandLine.arguments[2] {
    case "on", "off":
        let failed = AIHooks.set(CommandLine.arguments[2] == "on")
        failed.forEach { print("could not update \($0)") }
        exit(failed.isEmpty ? 0 : 1)
    default:
        let s = AIHooks.status()
        print("available: \(s.available)  on: \(s.on)  codex needs trust: \(s.codexNeedsTrust)")
        exit(0)
    }
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-panel" {
    // Draws the panel offscreen to a PNG, in the language picked by -AppleLanguages, to check translations fit.
    _ = NSApplication.shared
    let model = PanelModel()
    model.persistLanguage = false
    let langArg = CommandLine.arguments.firstIndex(of: "--lang").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
    model.language = langArg ?? ""                  // never the user's saved choice: "" = same as the Mac
    model.on = !CommandLine.arguments.contains("--off")
    model.fillLevel = model.on ? 1 : 0
    model.needsAuth = CommandLine.arguments.contains("--needs-auth")
    model.holdMissing = CommandLine.arguments.contains("--hold-missing")
    model.ai = AIHooks.Status(available: !CommandLine.arguments.contains("--no-ai"),
                              on: CommandLine.arguments.contains("--ai-on"),
                              codexNeedsTrust: CommandLine.arguments.contains("--codex-trust"))
    let host = NSHostingView(rootView: PanelView(m: model))
    let size = host.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
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
let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
