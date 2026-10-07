// Screen dimming and the lid rule as one state machine (DimController) over an injected display provider (DisplayIO), so it is
// tested with fake displays (Sources/DisplayTests.swift); ClamshellWatcher tells it the instant the lid moves.

import AppKit
import IOKit
import IOKit.pwr_mgt

/// What DimController needs from the displays. `Screens` is the real one; the tests use a fake.
protocol DisplayIO: AnyObject {
    var online: [CGDirectDisplayID] { get }
    /// The lid (AppleClamshellState).
    var lidClosed: Bool { get }
    var now: Date { get }
    func isBuiltin(_ d: CGDirectDisplayID) -> Bool
    func hasBacklight(_ d: CGDirectDisplayID) -> Bool
    func brightness(_ d: CGDirectDisplayID) -> Float?
    func setBrightness(_ d: CGDirectDisplayID, _ v: Float)
    /// Software dimming for a monitor without a controllable backlight: 1 = as it was, lower = darker.
    func setGamma(_ d: CGDirectDisplayID, _ scale: Float)
    /// Puts back exactly what that display had before its first setGamma.
    func restoreGamma(_ d: CGDirectDisplayID)
}

/// What the app knows each tick.
struct DimInputs: Equatable {
    var on = false                  // Cocaine is on
    var dimEnabled = false          // "When idle: dim"
    var screenOff = false           // "When idle: screen off" (no idle dimming then)
    var sessionActive = true        // this user's session is the one on screen (fast user switching)
    var idle: Double = 0            // the user's own idle time
    var delay: Double = 60          // dim after this much idle time
    var level: Float = 0.2          // the idle dim's brightness
    var allowed = true              // false right after an alert: the screens stay bright for a while
}

/// Who lowers which display and how far:
/// - Lid closed with Cocaine on: the built-in display goes to its minimum at once (whatever the idle setting), and back to the
///   level it had before the close when the lid opens. External displays are never touched by the lid.
/// - Idle (Cocaine on, dimming chosen, idle past the delay): every display that's on goes to the chosen level (the built-in with
///   the lid closed stays at the lid's minimum); any input brings them back.
/// The rules are evaluated afresh every tick (nothing to go stale): a display is lowered while a rule wants it and goes back to
/// its *original* level (read once, before Cocaine first lowered it) as soon as none does. The original is kept until the display
/// is really back, so a new dim during a restore fade never records a half-restored level.
final class DimController {
    static let lidLevel: Float = 0.01            // the lowest the backlight goes (Screens never sets less: dimmed, not off)
    static let gammaFloor: Float = 0.12          // software dimming: dimmed, never black
    static let creepTolerance: Float = 0.02      // automatic brightness pushing a lowered screen up a little: put back
    static let userChange: Float = 0.15          // a jump bigger than this in one tick is someone's choice: kept

    enum Kind { case backlight, gamma }
    struct Held {
        var kind: Kind
        var original: Float                      // backlight value, or 1 for gamma
        var value: Float                         // what is applied now
        var goal: Float
        var from: Float, start: Date, duration: Double
        var lowest: Float                        // for the recovery lease: the furthest down this hold went
        var reason: String
    }

    let io: DisplayIO
    private let note: ([RecoveryLease.Dim]) -> Void
    /// A fade has begun: the app runs `fadeStep()` every 25 ms until it returns false.
    var onFade: () -> Void = {}
    var log: (String) -> Void = { _ in }

    private(set) var held: [CGDirectDisplayID: Held] = [:]
    /// Lowered displays that went offline (unplugged, or the built-in in clamshell): put back if they return still lowered.
    private(set) var orphans: [CGDirectDisplayID: (original: Float, value: Float)] = [:]
    private var inputs = DimInputs()
    private(set) var lid: Bool
    private var lastSeen: [CGDirectDisplayID: (value: Float, at: Date)] = [:]
    private var lidOriginal: [CGDirectDisplayID: Float] = [:]  // read at the lid notification itself
    private var previewUntil = Date.distantPast
    private var kept = Set<CGDirectDisplayID>()                 // changed by hand while lowered: left alone until the rule ends
    private var lastLease: [RecoveryLease.Dim] = []

    init(io: DisplayIO, note: @escaping ([RecoveryLease.Dim]) -> Void) {
        self.io = io
        self.note = note
        lid = io.lidClosed
    }

    // MARK: what the app asks

    /// Any display lowered (or on its way back).
    var busy: Bool { !held.isEmpty }
    var fading: Bool { held.values.contains { $0.value != $0.goal } }
    /// Lowered because of idle time (an alert counts the user as away then).
    var idleDimmed: Bool { held.values.contains { $0.reason == "idle" && $0.goal != $0.original } }
    var previewing: Bool { io.now < previewUntil }
    func isLowered(_ d: CGDirectDisplayID) -> Bool { held[d] != nil }

    /// Every 0.5 s.
    func tick(_ i: DimInputs) {
        inputs = i
        let polled = io.lidClosed
        if polled != lid { lidChanged(closed: polled) } else { update() }
    }

    /// The lid moved (from the IOPMrootDomain notification, or the poll): the built-in's level is read right now, before macOS
    /// starts powering the panel down; a reading already lower than the one taken just before is not trusted.
    func lidChanged(closed: Bool) {
        guard closed != lid else { return }
        lid = closed
        if closed {
            for d in io.online where io.isBuiltin(d) && held[d] == nil {
                let now = io.now, cur = io.brightness(d)
                let seen = lastSeen[d].flatMap { now.timeIntervalSince($0.at) < 2 ? $0.value : nil }
                if let original = Self.lidOriginal(current: cur, lastSeen: seen) { lidOriginal[d] = original }
            }
        } else {
            lidOriginal = [:]
        }
        log("lid \(closed ? "closed" : "open")")
        update()
    }

    /// The level to give back when the lid opens: the reading at the notification, unless it is already lower than the one taken
    /// just before the close (the panel powering down), or missing.
    static func lidOriginal(current: Float?, lastSeen: Float?) -> Float? {
        guard let current else { return lastSeen }
        if let lastSeen, current < lastSeen - creepTolerance { return lastSeen }
        return current
    }

    /// "Preview": the idle dim for about three seconds.
    func preview() {
        previewUntil = io.now.addingTimeInterval(3.6)
        update()
    }

    /// One step of the running fades (25 ms apart); false once every display has arrived.
    @discardableResult
    func fadeStep() -> Bool {
        let now = io.now
        var finished: [CGDirectDisplayID] = []
        for (d, var h) in held where h.value != h.goal {
            let f = h.duration <= 0 ? 1 : min(1, max(0, Float(now.timeIntervalSince(h.start) / h.duration)))
            h.value = f >= 1 ? h.goal : h.from + (h.goal - h.from) * f * f * (3 - 2 * f)    // smoothstep
            apply(d, h)
            held[d] = h
            if h.value == h.goal && h.goal == h.original { finished.append(d) }
        }
        for (d, h) in held where h.value == h.goal && h.goal == h.original && !finished.contains(d) { finished.append(d) }
        for d in finished {
            if held[d]?.kind == .gamma { io.restoreGamma(d) }
            held[d] = nil
        }
        if !finished.isEmpty { writeLease() }        // cleared only once the display is really back
        return fading
    }

    /// Quitting (also during a fade): every display back to its original at once; the lease is cleared only after that.
    func quit() {
        for (d, h) in held {
            switch h.kind {
            case .backlight: io.setBrightness(d, h.original)
            case .gamma: io.restoreGamma(d)
            }
        }
        held = [:]
        orphans = [:]
        writeLease()
    }

    // MARK: the rules

    /// Where each online display should be now; nil = not lowered.
    func wanted(_ d: CGDirectDisplayID) -> (level: Float, reason: String, duration: Double)? {
        let i = inputs
        let builtin = io.isBuiltin(d)
        if builtin && lid {
            // The lid rule: only the built-in, whatever the idle setting. A built-in without a backlight we can set is left alone
            // (never gamma-dimmed: that would be a dark screen at full backlight behind the lid).
            guard i.on && i.sessionActive && io.hasBacklight(d) else { return nil }
            return (Self.lidLevel, "lid", 0.12)
        }
        let previewing = io.now < previewUntil
        let idle = i.on && i.dimEnabled && !i.screenOff && i.sessionActive && i.allowed && i.idle >= i.delay
        guard idle || (previewing && i.sessionActive) else { return nil }
        let level = max(Self.lidLevel, min(1, i.level))
        if io.hasBacklight(d) { return (level, previewing ? "preview" : "idle", previewing ? 0.6 : 1.5) }
        guard !builtin else { return nil }
        return (Self.gammaFloor + (1 - Self.gammaFloor) * level, previewing ? "preview" : "idle", previewing ? 0.6 : 1.5)
    }

    private func update() {
        let now = io.now
        let online = io.online
        let onlineSet = Set(online)
        // Gone: nothing to restore now, but remembered in case it comes back still lowered.
        for (d, h) in held where !onlineSet.contains(d) {
            if h.kind == .backlight { orphans[d] = (h.original, h.value) }
            held[d] = nil
            log("display \(d) went away while lowered")
        }
        // Back: if it still shows our level it is ours again (to put back, or to keep lowered); a level someone set meanwhile stays.
        for (d, o) in orphans where onlineSet.contains(d) {
            orphans[d] = nil
            guard let cur = io.brightness(d), abs(cur - o.value) <= 0.03 else { continue }
            held[d] = Held(kind: .backlight, original: o.original, value: cur, goal: cur, from: cur, start: now, duration: 0, lowest: cur, reason: "back")
        }
        var lowering = false
        for d in online {
            var want = wanted(d)
            if want == nil { kept.remove(d) } else if kept.contains(d) { want = nil }
            if var h = held[d] {
                let goal = want?.level ?? h.original
                let target = h.kind == .backlight ? min(goal, h.original) : goal
                if target != h.goal {
                    h.from = h.value; h.goal = target; h.start = now
                    h.duration = want?.duration ?? (h.reason == "preview" ? 0.4 : 0.25)
                    if let want { h.reason = want.reason }
                    h.lowest = min(h.lowest, target)
                    lowering = lowering || target < h.value
                    held[d] = h
                } else if h.value == h.goal, h.kind == .backlight, let cur = io.brightness(d), cur > h.value + Self.creepTolerance {
                    if cur - h.value > Self.userChange {
                        // Someone set it (a slider, a script): their level is kept, and not lowered again until this rule ends.
                        held[d] = nil
                        kept.insert(d)
                        log("display \(d): brightness changed by hand while lowered, kept")
                    } else {
                        io.setBrightness(d, h.value)             // automatic brightness creeping up
                    }
                }
            } else if let want {
                if io.hasBacklight(d) {
                    let original = (want.reason == "lid" ? lidOriginal[d] : nil) ?? io.brightness(d)
                    guard let original, original > want.level + 0.001 else { continue }    // already that low: nothing to do
                    held[d] = Held(kind: .backlight, original: original, value: original, goal: want.level, from: original,
                                   start: now, duration: want.duration, lowest: want.level, reason: want.reason)
                } else {
                    held[d] = Held(kind: .gamma, original: 1, value: 1, goal: want.level, from: 1, start: now,
                                   duration: want.duration, lowest: want.level, reason: want.reason)
                }
                lowering = true
                log("\(want.reason): display \(d) to \(want.level)")
            }
            // The built-in's own level, read while nothing of ours is on it: the lid's fallback original.
            if held[d] == nil, inputs.on, io.isBuiltin(d), !lid, let b = io.brightness(d) { lastSeen[d] = (b, now) }
        }
        if !lid { lidOriginal = [:] }
        writeLease()                                      // before any lowering is applied: a crash right after still restores
        if lowering || fading { onFade() }
    }

    private func apply(_ d: CGDirectDisplayID, _ h: Held) {
        switch h.kind {
        case .backlight: io.setBrightness(d, h.value)
        case .gamma: io.setGamma(d, h.value)
        }
    }

    private func writeLease() {
        var dims = held.compactMap { d, h in h.kind == .backlight ? RecoveryLease.Dim(id: d, from: h.original, to: h.lowest) : nil }
        dims += orphans.map { RecoveryLease.Dim(id: $0.key, from: $0.value.original, to: $0.value.value) }
        dims.sort { $0.id < $1.id }
        guard dims != lastLease else { return }
        lastLease = dims
        note(dims)
    }
}

// MARK: - The lid, the instant it moves

/// IOPMrootDomain's clamshell message (kIOPMMessageClamshellStateChange): bit 0 of its argument is "closed".
final class ClamshellWatcher {
    var onChange: ((Bool) -> Void)?
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0

    static let message: UInt32 = 0xE003_4100        // iokit_family_msg(sub_iokit_powermanagement, 0x100)

    func start() {
        guard port == nil else { return }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return }
        defer { IOObjectRelease(root) }
        guard let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .commonModes)
        IOServiceAddInterestNotification(p, root, kIOGeneralInterest, { refcon, _, type, arg in
            guard type == ClamshellWatcher.message, let refcon else { return }
            let me = Unmanaged<ClamshellWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let closed = (UInt(bitPattern: arg) & 1) != 0
            me.onChange?(closed)                                  // on the main run loop already
        }, Unmanaged.passUnretained(self).toOpaque(), &notification)
    }
}
