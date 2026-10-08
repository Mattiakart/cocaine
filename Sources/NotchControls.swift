// Quick controls: a row of round buttons the user picks and orders (Settings → Island → Notch → Controls), as the "controls"
// module, which can go on any screen (Home, Music…) through the screens editor. Each control shows its state where it has one
// (Cocaine on, Stay active, playing, a focus running), and that state changes in place with the stateSwap motion (the glyph
// replaced, the fill cross-faded), never by redrawing the row. NotchControlsConfig is the pure part.

import AppKit
import SwiftUI

/// One kind of control: its id (stored, never changes), symbol and title (an L() key).
struct NotchControlSpec: Equatable {
    let id: String
    let icon: String
    let title: String
}

enum NotchControlCatalog {
    static let all: [NotchControlSpec] = [
        NotchControlSpec(id: "cocaine", icon: "power", title: "Cocaine"),
        NotchControlSpec(id: "stayActive", icon: "person.crop.circle.badge.checkmark", title: "Stay active"),
        NotchControlSpec(id: "previous", icon: "backward.fill", title: "Previous track"),
        NotchControlSpec(id: "playPause", icon: "play.fill", title: "Play or pause"),
        NotchControlSpec(id: "next", icon: "forward.fill", title: "Next track"),
        NotchControlSpec(id: "mute", icon: "speaker.slash.fill", title: "Mute"),
        NotchControlSpec(id: "focus", icon: "timer", title: "Focus timer"),
        NotchControlSpec(id: "screenshot", icon: "camera.viewfinder", title: "Screenshot"),
        NotchControlSpec(id: "displaySleep", icon: "moon.zzz.fill", title: "Turn off the display"),
        NotchControlSpec(id: "reminders", icon: "checklist", title: "Reminders"),
        NotchControlSpec(id: "settings", icon: "gearshape", title: "Settings"),
    ]
    static func spec(_ id: String) -> NotchControlSpec? { all.first { $0.id == id } }
}

/// Which controls show, in order.
struct NotchControlsConfig: Codable, Equatable {
    static let standard = ["cocaine", "stayActive", "previous", "playPause", "next", "settings"]
    static let maxShown = 7                         // one row in the narrow column at the one control size
    var shown: [String] = NotchControlsConfig.standard

    /// Known ids only, each once, at most `maxShown`.
    func sanitized() -> NotchControlsConfig {
        var seen = Set<String>()
        let list = shown.filter { NotchControlCatalog.spec($0) != nil && seen.insert($0).inserted }
        return NotchControlsConfig(shown: Array(list.prefix(Self.maxShown)))
    }
    var hidden: [String] { NotchControlCatalog.all.map(\.id).filter { !shown.contains($0) } }
    func isShown(_ id: String) -> Bool { shown.contains(id) }
    var canAdd: Bool { shown.count < Self.maxShown }

    /// Shows (at the end) or hides a control. False when nothing changed (unknown, or the row is full).
    @discardableResult mutating func set(_ id: String, shown on: Bool) -> Bool {
        guard NotchControlCatalog.spec(id) != nil else { return false }
        if on {
            guard !shown.contains(id), canAdd else { return false }
            shown.append(id)
        } else {
            guard let i = shown.firstIndex(of: id) else { return false }
            shown.remove(at: i)
        }
        return true
    }

    /// Moves a shown control by `by` places. False at an end.
    @discardableResult mutating func move(_ id: String, by: Int) -> Bool {
        guard let i = shown.firstIndex(of: id) else { return false }
        let j = i + by
        guard j >= 0, j < shown.count else { return false }
        shown.swapAt(i, j)
        return true
    }
}

// MARK: - The module

extension IslandView {
    /// The controls module: the picked controls, one row; at M a label under each.
    func controlsModule(_ b: ModuleBox) -> some View {
        NotchControlsRow(model: model, m: m, focus: focus, music: model.music, prefs: prefs, labels: b.size != .s)
    }
}

struct NotchControlsRow: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var m: PanelModel
    @ObservedObject var focus: FocusTimer
    @ObservedObject var music: MusicWatch
    @ObservedObject var prefs: NotchPrefs
    var labels = true
    static let size: CGFloat = 30                  // the one size of a round control

    var body: some View {
        let ids = prefs.controls.shown
        VStack(alignment: .leading, spacing: Space.m) {
            Text(L("Controls")).font(UI.section).foregroundStyle(UI.secondary)
            if ids.isEmpty {
                Text(L("No controls picked")).font(UI.value).foregroundStyle(UI.hint)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                        control(id).frame(maxWidth: .infinity)
                            .transition(Motion.appear(.top))
                    }
                }
                .animation(Motion.animation(.expand), value: ids)
            }
            Spacer(minLength: 0)
        }
    }

    /// A control's state now: on (filled), and the symbol it shows.
    private func state(_ id: String) -> (on: Bool, icon: String) {
        let base = NotchControlCatalog.spec(id)?.icon ?? "questionmark"
        switch id {
        case "cocaine": return (m.on, base)
        case "stayActive": return (m.stayActive, base)
        case "playPause": return (music.playing, music.playing ? "pause.fill" : "play.fill")
        case "focus": return (focus.running, focus.running ? "timer.circle.fill" : base)
        default: return (false, base)
        }
    }

    @ViewBuilder private func control(_ id: String) -> some View {
        let spec = NotchControlCatalog.spec(id)
        let st = state(id)
        let title = L(spec?.title ?? id)
        Button { perform(id) } label: {
            VStack(spacing: Space.xs) {
                ZStack {
                    Circle().fill(st.on ? Island.accent : Color.white.opacity(0.12))
                    Image(systemName: st.icon).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(st.on ? CTL.onAccentInk : Color.white)
                        .contentTransition(Motion.reduce || Motion.disabled ? .opacity : .symbolEffect(.replace))
                }
                .frame(width: Self.size, height: Self.size)
                .animation(Motion.animation(.stateSwap), value: st.on)
                .animation(Motion.animation(.stateSwap), value: st.icon)
                if labels {
                    Text(title).font(.system(size: 10)).foregroundStyle(UI.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: 52)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(st.on ? .isSelected : [])
    }

    private func perform(_ id: String) {
        switch id {
        case "cocaine": Haptic.tap(.generic); m.toggleCocaine()
        case "stayActive": Haptic.tap(.generic); m.stayActive.toggle()
        case "previous": music.previous()
        case "playPause": music.playPause()
        case "next": music.next()
        case "mute":
            Haptic.tap(.generic)
            if let r = MediaKeys.changeVolume(key: 7, fine: false) {
                model.flashNotice(r.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", L("Volume"), level: r.muted ? 0 : Double(r.level))
            }
        case "focus":
            Haptic.tap(.generic)
            if focus.running { focus.pause() } else { focus.start() }
        case "screenshot":
            Haptic.tap(.generic)
            NotchActions.screenshot()
        case "displaySleep":
            Haptic.tap(.generic)
            NotchActions.displaySleep()
        case "reminders":
            Haptic.tap(.alignment)
            Motion.with(.page) { model.tab = "reminders" }
        case "settings": model.showSettings()
        default: break
        }
    }
}

/// What a few controls run outside the app: the Screenshot app, the display going to sleep (no admin rights needed).
enum NotchActions {
    static var run: (String, [String]) -> Void = { path, args in
        DispatchQueue.global(qos: .userInitiated).async { _ = Proc.run(path, args, timeout: 5) }
    }
    static func screenshot() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"),
                                           configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
    static func displaySleep() { run("/usr/bin/pmset", ["displaysleepnow"]) }
}
