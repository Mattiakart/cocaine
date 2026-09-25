// Cocaine — menu-bar front end for ~/bin/cocaine.
//
// Shows whether Cocaine is on (full baggie) or off (empty baggie) in the menu bar; clicking it opens a
// panel that stays open while you change things. It toggles Cocaine through the engine script bundled in
// Contents/Resources/cocaine, which owns the caffeinate -d display hold; the first time it needs to, the app
// asks for an admin password once to install a narrow sudo rule for `pmset -a disablesleep 1|0`. While Cocaine is
// on it restarts that display hold if it is missing (e.g. after a restart) and, after the chosen
// idle time, lowers the built-in display to the chosen minimum brightness (never below 1%, so the
// screen never goes off), restoring the previous brightness on the next keyboard/trackpad input.

import AppKit
import ImageIO
import IOKit
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

// MARK: - Built-in display brightness (DisplayServices, private framework)

private final class Backlight {
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

    private var display: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 && (canFn?($0) ?? false) }
    }

    var value: Float? {
        guard let d = display, let get = getFn else { return nil }
        var b: Float = 0
        return get(d, &b) == 0 ? b : nil
    }

    /// Never below 1%: dimmed, not off.
    func set(_ v: Float) {
        guard let d = display, let s = setFn else { return }
        _ = s(d, min(max(v, 0.01), 1))
    }
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
    /// Brightness to put back if the app quit or crashed while the screen was lowered.
    var savedBrightness: Float? {
        get { (d.object(forKey: "savedBrightness") as? Double).map(Float.init) }
        nonmutating set {
            if let v = newValue { d.set(Double(v), forKey: "savedBrightness") }
            else { d.removeObject(forKey: "savedBrightness") }
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
                    Text("Cocaine").font(.headline)
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
    private let backlight = Backlight()
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
    private var dimmedFrom: Float?      // brightness before we lowered it; nil when not lowered
    private var previewFrom: Float?     // same, during "Preview"
    private var supervising = false
    private let launchedAt = Date()
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
        model.quit = { NSApp.terminate(nil) }
        model.languageChanged = { [weak self] in self?.refreshIcon(on: System.cocaineOn, animate: false) }
        hostView = PanelHostingView(rootView: PanelView(m: model))
        hostView.sizingOptions = [.intrinsicContentSize]
        hostView.onSizeChange = { [weak self] in DispatchQueue.main.async { self?.fitPanel(animated: true) } }
        panel = MenuPanel(content: hostView)

        if let saved = settings.savedBrightness {   // quit or crashed while the screen was lowered
            if let cur = backlight.value, cur < saved { backlight.set(saved) }
            settings.savedBrightness = nil
        }

        signal(SIGTERM, SIG_IGN)                     // quit cleanly (restoring brightness) on kill/pkill
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }
        sigterm?.resume()

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        tick()
        if !System.cocaineOn { toggleCocaine() }     // opening the app turns Cocaine on
    }

    /// Quitting (Quit button, ⌘Q, logout, shutdown) turns Cocaine off, just as opening the app turns it on.
    func applicationWillTerminate(_ n: Notification) {
        fadeTimer?.invalidate()
        if let saved = dimmedFrom ?? previewFrom { backlight.set(saved) }
        settings.savedBrightness = nil
        if System.cocaineOn { engine("off") }
    }

    /// Opening Cocaine again (e.g. from Spotlight) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // An `open` right after launch (Homebrew reopening the app after an upgrade) isn't a request for the panel.
        guard Date().timeIntervalSince(launchedAt) > 5 else { return false }
        if !panel.isVisible { showPanel() }
        return false
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem.button, let barWindow = button.window else { return }
        refreshPanelState()
        let icon = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panelTop = (icon.minY - 6).rounded()
        fitPanel(animated: false, centeredOn: icon.midX, screen: barWindow.screen)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        // Clicks in other apps (or elsewhere in the menu bar) close it; clicks on our own icon toggle it instead.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            // On macOS 27 a click on our own icon also arrives here; leave that one to togglePanel.
            if !icon.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) { self?.hidePanel() }
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
        var x = panel.frame.minX
        if let midX {
            let vis = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
            x = min(max(midX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8).rounded()
        }
        let frame = NSRect(x: x, y: panelTop - size.height, width: size.width, height: size.height)
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
            DispatchQueue.main.async {
                if self.model.holdMissing != missing { self.model.holdMissing = missing }
                if missing { self.superviseHold() }
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
        guard previewFrom == nil else { return }
        let idle = System.idleSeconds
        defer { lastIdle = idle }
        if dimmedFrom != nil {
            if idle < lastIdle || !on || !settings.dimEnabled { restore(); return }   // input since last tick
            // automatic brightness can creep back up while the screen is lowered
            if ticks % 10 == 0, fadeTimer == nil, let cur = backlight.value, cur > settings.level + 0.02 {
                backlight.set(settings.level)
            }
        } else if on, settings.dimEnabled, idle >= settings.delay, !System.lidClosed {
            dim(afterIdle: idle)
        }
    }

    private func dim(afterIdle idle: Double) {
        guard let cur = backlight.value else { return }
        let target = settings.level
        dimmedFrom = cur
        settings.savedBrightness = cur
        log.notice("dim \(cur, privacy: .public) -> \(target, privacy: .public) after \(Int(idle), privacy: .public)s idle")
        if cur > target { fade(to: target, over: 1.5) }
    }

    private func restore() {
        guard let saved = dimmedFrom else { return }
        dimmedFrom = nil
        settings.savedBrightness = nil
        log.notice("restore -> \(saved, privacy: .public)")
        fade(to: saved, over: 0.25)
    }

    private func fade(to target: Float, over seconds: Double, then done: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard let start = backlight.value else { done?(); return }
        let steps = max(1, Int(seconds / 0.025))
        var i = 0
        let t = Timer(timeInterval: seconds / Double(steps), repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            i += 1
            let f = Float(i) / Float(steps)
            self.backlight.set(start + (target - start) * f * f * (3 - 2 * f))   // smoothstep
            if i >= steps { t.invalidate(); self.fadeTimer = nil; done?() }
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    private func preview() {
        guard previewFrom == nil, dimmedFrom == nil, let cur = backlight.value else { return }
        previewFrom = cur
        settings.savedBrightness = cur
        model.previewing = true
        fade(to: settings.level, over: 0.6) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.fade(to: cur, over: 0.4) {
                    self.previewFrom = nil
                    self.settings.savedBrightness = nil
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
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--auth-preview" {
    // Shows the admin prompt without running anything (to check how it looks).
    _ = NSApplication.shared
    exit(Authorization.authorize(prompt: L("Cocaine needs your permission once, to keep your Mac awake.")) { _ in true } ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--remove-rule" {
    _ = NSApplication.shared
    exit(Authorization.remove() ? 0 : 1)
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
