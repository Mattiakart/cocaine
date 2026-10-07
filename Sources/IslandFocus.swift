// The island's Focus page, its minute ruler, and the focus / break timer itself (FocusTimer).

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

/// Focus / break timer: a minute ruler sets the length, the countdown shows in the closed island. Its state is kept across a
/// restart or an update ("focus.v1"); nothing ticks while it runs (one timer at the end, in the common run-loop mode so it
/// fires on time while you scroll or drag; the countdown on screen is a TimelineView).
final class FocusTimer: ObservableObject {
    @Published var focusMinutes = 25 { didSet { save() } }
    @Published var breakMinutes = 5 { didSet { save() } }
    @Published var isBreak = false { didSet { save() } }
    @Published private(set) var endsAt: Date?
    @Published private(set) var pausedLeft: TimeInterval?
    /// The end Cocaine was given when this focus turned it on (nil: it was already on, or the user changed it since).
    private(set) var ownedUntil: Date?
    /// A focus or a break just ended (true: a break). The app flashes the island, says it, and alerts when you're away.
    var onFinish: ((Bool) -> Void)?
    /// A focus starts (or resumes) for `minutes`: the app keeps the Mac awake that long. Given the end this focus had set before
    /// (resuming); returns the end it has set now, or nil when Cocaine was on already for another reason.
    var onStart: ((_ minutes: Int, _ owned: Date?) -> Date?)?
    /// Reset: the app turns Cocaine off if this focus turned it on and nobody changed it since (`owned` is still its end).
    var onReset: ((_ owned: Date) -> Void)?
    var now: () -> Date = Date.init
    private var timer: Timer?
    private let defaults: UserDefaults
    private var loading = false
    static let key = "focus.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    var minutes: Int { get { isBreak ? breakMinutes : focusMinutes } set { if isBreak { breakMinutes = newValue } else { focusMinutes = newValue } } }
    var running: Bool { endsAt != nil }
    var active: Bool { endsAt != nil || pausedLeft != nil }
    var remaining: TimeInterval { endsAt.map { max(0, $0.timeIntervalSince(now())) } ?? pausedLeft ?? Double(minutes) * 60 }
    var text: String { let s = Int(remaining.rounded(.up)); return String(format: "%d:%02d", s / 60, s % 60) }
    /// For VoiceOver: "Focus, 24 min left".
    var spoken: String { String(format: L("%@, %@ left"), isBreak ? L("Break") : L("Focus"), Dur.left(seconds: Int(remaining.rounded(.up)))) }

    func start() {
        Haptic.tap(.generic)
        let left = pausedLeft ?? Double(minutes) * 60
        endsAt = now().addingTimeInterval(left); pausedLeft = nil
        if !isBreak, let set = onStart?(Int((left / 60).rounded(.up)) + 1, ownedUntil) { ownedUntil = set }
        schedule()
        save()
    }

    func pause() {
        Haptic.tap(.alignment)
        pausedLeft = remaining; endsAt = nil
        timer?.invalidate(); timer = nil
        save()
    }

    func reset() {
        Haptic.tap(.alignment)
        stop()
        if let owned = ownedUntil { ownedUntil = nil; onReset?(owned) }
        save()
    }

    func setBreak(_ b: Bool) { reset(); isBreak = b }

    private func stop() { endsAt = nil; pausedLeft = nil; timer?.invalidate(); timer = nil }

    /// One timer, at the end (a little tolerance lets macOS batch it).
    private func schedule() {
        timer?.invalidate()
        guard let e = endsAt else { return }
        let t = Timer(fire: max(e, now().addingTimeInterval(0.05)), interval: 0, repeats: false) { [weak self] _ in self?.finish() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The end: the sound, three taps, the other mode ready, and the app's cue (onFinish).
    func finish() {
        guard let e = endsAt, e.timeIntervalSince(now()) <= 0.3 else { schedule(); return }
        let wasBreak = isBreak
        stop()
        ownedUntil = nil                                  // the app's own timer turns Cocaine off a minute later
        NSSound(named: "Glass")?.play()
        Haptic.finished()
        isBreak.toggle()
        save()
        onFinish?(wasBreak)
    }

    private func save() {
        guard !loading else { return }
        var d: [String: Any] = ["focus": focusMinutes, "break": breakMinutes, "isBreak": isBreak]
        if let e = endsAt { d["endsAt"] = e.timeIntervalSince1970 }
        if let p = pausedLeft { d["pausedLeft"] = p }
        if let o = ownedUntil { d["ownedUntil"] = o.timeIntervalSince1970 }
        defaults.set(d, forKey: Self.key)
    }

    /// After a restart or an update: the same lengths and mode, a running focus goes on (one that ended meanwhile is over).
    private func restore() {
        guard let d = defaults.dictionary(forKey: Self.key) else { return }
        loading = true
        defer { loading = false }
        focusMinutes = min(120, max(5, d["focus"] as? Int ?? 25))
        breakMinutes = min(120, max(5, d["break"] as? Int ?? 5))
        isBreak = d["isBreak"] as? Bool ?? false
        pausedLeft = (d["pausedLeft"] as? Double).flatMap { $0 > 0 ? $0 : nil }
        ownedUntil = (d["ownedUntil"] as? Double).map { Date(timeIntervalSince1970: $0) }
        if let e = (d["endsAt"] as? Double).map({ Date(timeIntervalSince1970: $0) }) {
            if e > now() { endsAt = e; schedule() }
            else { isBreak.toggle(); ownedUntil = nil }   // ended while Cocaine wasn't running
        }
    }
}

extension IslandView {
    // MARK: focus

    var focusTab: some View {
        HStack(alignment: .top, spacing: Space.gutter) {
            VStack(alignment: .leading, spacing: Space.l) {
                Segments(selection: Binding(get: { focus.isBreak }, set: { focus.setBreak($0) }), values: [false, true], name: L("Focus")) {
                    $0 ? L("Break") : L("Focus")
                }
                .frame(width: 180)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(focus.text).font(UI.hero)
                        .accessibilityLabel(focus.spoken)
                }
                HStack(spacing: Space.m) {
                    Button { focus.running ? focus.pause() : focus.start() } label: {
                        Label(focus.running ? L("Pause") : L("Start"), systemImage: focus.running ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(CocaineButtonStyle(kind: .primary, height: CTL.hDialog))
                    if focus.active {
                        Button(L("Reset")) { focus.reset() }.buttonStyle(CocaineButtonStyle(height: CTL.hDialog))
                    }
                }
            }
            .frame(width: 250, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.m) {
                Text(L("Minutes")).font(UI.section).foregroundStyle(UI.secondary)
                MinuteRuler(minutes: Binding(get: { focus.minutes }, set: { if !focus.active { focus.minutes = $0 } }))
                    .opacity(focus.active ? 0.4 : 1)
                    .disabled(focus.active)
                Text(L("Drag the ruler to set the length. Cocaine keeps the Mac awake while a focus runs."))
                    .font(UI.detail).foregroundStyle(UI.hint).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

private final class RulerDrag: ObservableObject { var start: Int? }

/// A horizontal ruler of minutes: drag it to set a length from 5 to 120 minutes. VoiceOver: an adjustable "Minutes" (swipe
/// up or down: 5 minutes more or less); two-finger scrolling steps it too.
private struct MinuteRuler: View {
    @Binding var minutes: Int
    @StateObject private var drag = RulerDrag()
    @Environment(\.isEnabled) private var enabled
    private let step: CGFloat = 5          // points per minute

    static func adjusted(_ m: Int, up: Bool) -> Int {
        up ? min(120, (m / 5 + 1) * 5) : max(5, ((m + 4) / 5 - 1) * 5)
    }

    var body: some View {
        GeometryReader { r in
            let mid = r.size.width / 2
            // The ticks glide to a new length (a scroll step, VoiceOver, each minute of a drag) with the value spring, which the
            // next step retargets; Reduce Motion: they jump.
            RulerTicks(position: Double(minutes), step: step, mid: mid)
                .animation(Motion.animation(.value), value: minutes)
                .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))   // the ticks fade at the ends
            RoundedRectangle(cornerRadius: 1.5).fill(Island.accent).frame(width: 3, height: 26).position(x: mid, y: 27)
            // The length, inside the frame and outside the fade (it used to sit above the frame and was masked away).
            Text("\(minutes)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Island.accent)
                .motionNumber(minutes).position(x: mid, y: 6)
        }
        .frame(height: 52)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            if drag.start == nil { drag.start = minutes }
            let new = min(120, max(5, (drag.start ?? minutes) - Int((v.translation.width / step).rounded())))
            if new != minutes { Haptic.tap(new % 5 == 0 ? .levelChange : .alignment) }              // a firmer tick on every fifth minute
            minutes = new
        }.onEnded { _ in drag.start = nil })
        .onScrollSteps(every: 5) { minutes = min(120, max(5, minutes + $0)) }       // (the tap comes from the scroll itself)
        .accessibilityElement()
        .accessibilityLabel(L("Minutes"))
        .accessibilityValue(String(format: L("%d min"), minutes))
        .accessibilityAdjustableAction { d in
            guard enabled else { return }
            switch d {
            case .increment: minutes = Self.adjusted(minutes, up: true)
            case .decrement: minutes = Self.adjusted(minutes, up: false)
            @unknown default: break
            }
        }
    }
}

/// The ruler's ticks around `position` (minutes; fractional while gliding), that length under the middle mark.
struct RulerTicks: View, Animatable {
    var position: Double
    let step: CGFloat
    let mid: CGFloat
    var animatableData: Double { get { position } set { position = newValue } }

    /// The minutes drawn around a position (the ruler shows an hour each side), within 5…120.
    static func range(_ position: Double) -> ClosedRange<Int>? {
        let lo = max(5, Int((position - 60).rounded(.down))), hi = min(120, Int((position + 60).rounded(.up)))
        return lo <= hi ? lo...hi : nil
    }

    var body: some View {
        Canvas { g, size in
            guard let r = Self.range(position) else { return }
            for v in r {
                let x = mid + CGFloat(Double(v) - position) * step
                guard x > 0, x < size.width else { continue }
                let big = v % 10 == 0, mid5 = v % 5 == 0
                let h: CGFloat = big ? 20 : mid5 ? 14 : 8
                g.fill(Path(CGRect(x: x - 0.5, y: size.height - h - 14, width: 1, height: h)), with: .color(.white.opacity(big ? 0.7 : 0.3)))
                if big { g.draw(Text("\(v)").font(.system(size: 9)).foregroundColor(.white.opacity(0.5)), at: CGPoint(x: x, y: size.height - 5)) }
            }
        }
    }
}

// MARK: - Tests (part of --selftest)

enum FocusTests {
    static func run(_ check: (String, Bool) -> Void) {
        let name = "local.cocaine.focus-test-\(getpid())"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let f = FocusTimer(defaults: d)
        f.now = { clock }
        var turnedOn: [Int] = [], resets: [Date] = [], finished: [Bool] = []
        f.onStart = { minutes, owned in turnedOn.append(minutes); return owned ?? clock.addingTimeInterval(Double(minutes) * 60) }
        f.onReset = { resets.append($0) }
        f.onFinish = { finished.append($0) }
        f.focusMinutes = 25
        f.start()
        check("focus: starting keeps the Mac awake for its length + 1 min", turnedOn == [26] && f.running)
        // A restart: a new timer from the same settings carries on.
        let g = FocusTimer(defaults: d)
        g.now = { clock }
        check("focus: a running focus survives a restart or an update (it was lost)", g.running && abs(g.remaining - 25 * 60) < 1 && g.focusMinutes == 25)
        clock = clock.addingTimeInterval(600)
        f.pause()
        check("focus: pause keeps what's left", f.pausedLeft.map { abs($0 - 15 * 60) < 1 } == true && !f.running)
        f.reset()
        check("focus: Reset turns Cocaine off only when this focus turned it on (it gave back its end)", resets.count == 1 && !f.active)
        f.onStart = { _, _ in nil }                            // Cocaine was already on (by hand): not the focus's to turn off
        f.start(); f.reset()
        check("focus: …and leaves a Cocaine it didn't turn on alone", resets.count == 1)
        f.onStart = { minutes, owned in owned ?? clock.addingTimeInterval(Double(minutes) * 60) }
        f.start()
        clock = clock.addingTimeInterval(25 * 60 + 1)
        f.finish()
        check("focus: the end is announced to the app (sound, flash, alert when away)", finished == [false] && f.isBreak && !f.running)
        check("focus: the countdown never shows a negative time", FocusTimer(defaults: d).text.hasPrefix("5:") || FocusTimer(defaults: d).text.hasPrefix("25:"))
        check("focus ruler: VoiceOver steps of 5 minutes, 5…120", MinuteRuler.adjusted(25, up: true) == 30 && MinuteRuler.adjusted(27, up: true) == 30
              && MinuteRuler.adjusted(27, up: false) == 25 && MinuteRuler.adjusted(5, up: false) == 5 && MinuteRuler.adjusted(120, up: true) == 120)
    }
}
