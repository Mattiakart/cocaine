// The "Music and keyboard" card of the settings' Island tab: the skip step, the YouTube Music connection (Pear Desktop: on/off,
// its port, Connect/Disconnect and what it answered) and the keyboard backlight (level, auto-off when idle, only while Cocaine
// keeps the Mac awake). Also the island's wiring for the backlight (MediaWiring) and the render fixtures (--media-fixture).

import AppKit
import SwiftUI

/// The island tells the backlight where its HUD goes and starts its auto-off rule (IslandModel's init).
enum MediaWiring {
    static func attach(_ m: IslandModel) {
        let kb = KeyboardBacklight.shared
        if kb.hud == nil {
            kb.hud = { [weak m] v in m?.flashNotice(v > 0.01 ? "light.max" : "light.min", L("Keyboard backlight"), level: v) }
        }
        kb.apply()
    }
}

/// The card's content (PanelView puts it in a card titled "Music and keyboard").
struct MediaSettingsView: View {
    var body: some View {
        if let m = MusicWatch.current ?? Self.sample {
            MediaSettingsBody(music: m, pear: m.pear, light: KeyboardBacklight.shared)
        } else {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(L("Turn the island on to control music")).font(UI.detail).foregroundStyle(UI.secondary)
                MediaBacklightSettings(light: KeyboardBacklight.shared)
            }
        }
    }

    /// Renders: a sample watch in memory (AppDefaults.isolated only).
    static var sample: MusicWatch? {
        guard AppDefaults.isolated else { return nil }
        if cached == nil { cached = MusicWatch(pear: PearClient(transport: { _, done in done(PearClient.Reply(status: 0, data: nil)) }, secrets: MemorySecretStore())) }
        return cached
    }
    private static var cached: MusicWatch?
}

struct MediaSettingsBody: View {
    @ObservedObject var music: MusicWatch
    @ObservedObject var pear: PearClient
    @ObservedObject var light: KeyboardBacklight
    @StateObject private var draft = PortDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            MediaRows.section(L("Music"))
            MediaRows.row(L("Skip step"), detail: L("How far the back and forward buttons of the Music page jump")) {
                Segments(selection: Binding(get: { music.skipSeconds }, set: { music.setSkipSeconds($0) }), values: MusicSources.skipChoices,
                         name: L("Skip step"), label: { String(format: L("%d s"), $0) })
            }
            MediaRows.row(L("YouTube Music (Pear Desktop)"),
                          detail: L("Controls YouTube Music in Pear Desktop through its API Server plugin, on this Mac only (127.0.0.1)")) {
                CocaineSwitch(on: music.pearEnabled) { music.setPear(!music.pearEnabled) }.accessibilityLabel(L("YouTube Music (Pear Desktop)"))
            }
            if music.pearEnabled {
                MediaRows.row(L("Port"), detail: String(format: L("Pear Desktop → Plugins → API Server (%d unless you changed it)"), PearAPI.defaultPort)) {
                    CloudTextField(text: Binding(get: { draft.text.isEmpty ? String(pear.port) : draft.text },
                                                 set: { draft.text = $0; if let p = Int($0), (1024...65535).contains(p) { music.setPearPort(p) } }),
                                   placeholder: String(PearAPI.defaultPort), mono: true, label: L("Port"))
                        .frame(width: 64, height: CTL.h)
                        .padding(.horizontal, Space.s)
                        .background(RoundedRectangle(cornerRadius: CTL.radius).fill(CTL.fill))
                }
                let note = PearPrompt.note(enabled: true, status: pear.status)
                MediaRows.row(pear.status == .ready ? L("Connected") : L("Not connected"), detail: note,
                              warning: pear.status == .denied || pear.status == .unreachable) {
                    HStack(spacing: Space.s) {
                        if pear.status == .asking { BusyDots(color: Island.accent) }
                        Button(L("Connect")) { music.connectPear() }.buttonStyle(CocaineButtonStyle()).disabled(pear.status == .asking)
                        if pear.token != nil { Button(L("Disconnect")) { music.disconnectPear() }.buttonStyle(CocaineButtonStyle()) }
                    }
                }
            }
            MediaRows.divider
            MediaBacklightSettings(light: light)
        }
    }
}

/// What is typed in the port field (kept while it isn't a valid port yet).
final class PortDraft: ObservableObject { @Published var text = "" }

/// The keyboard backlight part of the card (shown even while the island is off: it works without it, minus the HUD).
struct MediaBacklightSettings: View {
    @ObservedObject var light: KeyboardBacklight
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            MediaRows.section(L("Keyboard backlight"))
            if !light.available {
                Text(L("This Mac's keyboard has no backlight Cocaine can control")).font(UI.detail).foregroundStyle(UI.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                MediaRows.row(L("Brightness"), detail: light.suppressed ? L("Turned off by macOS") : nil) {
                    CocaineSlider(value: light.level * 100, range: 0...100, step: 10, name: L("Keyboard backlight"),
                                  valueText: "\(Int((light.level * 100).rounded()))%") { light.set($0 / 100) }
                        .frame(width: 160)
                }
                MediaRows.row(L("Turn off when idle"), detail: L("Back on at the next key or touch")) {
                    Segments(selection: Binding(get: { light.idleOff }, set: { light.setIdleOff($0) }), values: KeyboardBacklight.idleChoices,
                             name: L("Turn off when idle"), label: { MediaRows.idleName($0) })
                }
                MediaRows.row(L("Only while Cocaine keeps the Mac awake"), detail: L("Off: whenever the Mac is idle")) {
                    CocaineSwitch(on: light.onlyWhileAwake) { light.setOnlyWhileAwake(!light.onlyWhileAwake) }
                        .accessibilityLabel(L("Only while Cocaine keeps the Mac awake"))
                }
                .dimGroup(light.idleOff == 0)
            }
        }
        .onAppear { light.refresh() }
    }
}

/// The card's look (as the Shelf card's).
enum MediaRows {
    static var divider: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.vertical, 2) }

    static func section(_ title: String) -> some View {
        Text(title).font(UI.groupTitle).lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(minHeight: 22)
            .accessibilityAddTraits(.isHeader)
    }

    static func row<Control: View>(_ title: String, detail: String?, warning: Bool = false, @ViewBuilder _ control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(UI.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(UI.detail).foregroundStyle(warning ? warningColor : UI.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()
        }
        .frame(minHeight: 22)
        .fixedSize(horizontal: false, vertical: true)
        .help(detail ?? title)
    }

    /// "Never", "30 s", "1 min"…
    static func idleName(_ s: Int) -> String {
        if s == 0 { return L("Never") }
        return s < 60 ? String(format: L("%d s"), s) : String(format: L("%d min"), s / 60)
    }
}

// MARK: - Render fixtures

/// `--media-fixture sources` (two players: the switcher), `pear` (YouTube Music open, not connected: the page's prompt),
/// `nolight` (a Mac without a keyboard backlight). Renders only (AppDefaults.isolated).
enum MediaFixtures {
    static func apply(_ args: [String], _ im: IslandModel) {
        guard AppDefaults.isolated, let i = args.firstIndex(of: "--media-fixture"), i + 1 < args.count else { return }
        switch args[i + 1] {
        case "sources":
            im.music.addSampleSource(PlayerApp.spotify, title: "Midnight City", artist: "M83")
            im.music.addSampleSource(PlayerApp.pear, title: "Get Lucky", artist: "Daft Punk")
        case "pear":
            im.music.scriptsEnabled = false
            im.music.running = { ["com.github.th-ch.youtube-music"] }
            im.music.update(PlayerApp.music, nil)
            im.music.start()
        case "nolight":
            (KeyboardBacklight.shared.device as? FakeBacklight)?.available = false
            KeyboardBacklight.shared.refresh()
        default: break
        }
    }
}
