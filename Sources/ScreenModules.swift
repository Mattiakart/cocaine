// The island's modules as views: each kind of ModuleCatalog (ScreenLayout.swift) drawn in the box ScreenLayout.resolve gives
// it, and a screen as the grid of its modules. The module views themselves live with their data in the Island*.swift pages.

import AppKit
import SwiftUI

/// The room a module has: its size class and its box in points. `standard` is the box its own page always gave it (the
/// module draws exactly as that page did).
struct ModuleBox: Equatable {
    var size: ModuleSize
    var width: CGFloat
    var height: CGFloat
    /// Its box in the standard 640 × 214 island (Sources/IslandScale.swift): what it grows from in a bigger one. Zero: unknown.
    var standard: CGSize = .zero
    static func of(_ m: ResolvedScreen.Module, standard: ResolvedScreen? = nil) -> ModuleBox {
        ModuleBox(size: m.size, width: m.frame.width, height: m.frame.height,
                  standard: standard?.modules.first { $0.kind == m.kind }?.frame.size ?? .zero)
    }
}

extension IslandView {
    /// One module, in its box.
    @ViewBuilder func module(_ kind: String, _ b: ModuleBox) -> some View {
        switch kind {
        case "cocaine": cocaineModule(b)
        case "agents": agentsModule(b)
        case "music": musicTab
        case "media": mediaModule(b)
        case "calendar": calendarTab
        case "focus": focusModule(b)
        case "downloads": downloadsModule(b)
        case "screenshots": screenshotsModule(b)
        case "shelf": shelfModule(b)
        case "clipboard": clipboardModule(b)
        case "batteries": batteriesModule(b)
        case "usage": usageModule(b)
        case "quotas": quotasModule(b)
        case "aicontext": aiContextModule(b)         // Sources/AIContextViews.swift
        case "mirror": mirrorModule(b)
        case "monitors": displayModule(b)
        case "reminders": remindersModule(b)         // Sources/IslandReminders.swift
        case "controls": controlsModule(b)           // Sources/NotchControls.swift
        case "keyboard": keyboardModule(b)              // Sources/KeyboardBacklight.swift
        default: EmptyView()
        }
    }

    /// A screen: its modules in one or two columns, inside the page's fixed box. One module at full size (every built-in
    /// page but Home, Files and Status) is drawn bare, and two full-height columns as the built-in two-column pages always
    /// were, so the standard layout draws exactly the pages it replaced.
    @ViewBuilder func screenPage(_ id: String) -> some View {
        let box = ScreenLayout.contentSize(stripHeight: g.height)
        let config = model.layout.config(id) ?? ScreenLayout.standard.config("home")!
        let r = ScreenLayout.resolve(config, in: box)
        // The same screen in the standard island: each module's box there is what it grows from (Sources/IslandScale.swift).
        let std = ScreenLayout.resolve(config, in: IslandScale.standardBox(stripHeight: g.height))
        if r.modules.isEmpty {
            emptyScreen
        } else if r.columns == 1 && r.modules.count == 1 && r.modules[0].size == .l {
            module(r.modules[0].kind, .of(r.modules[0], standard: std)).modifier(ModuleStagger(order: 0))
        } else if r.columns == 2 {
            HStack(alignment: .top, spacing: ScreenLayout.gutter) {
                screenColumn(r, std, 0).frame(width: r.widths[0], alignment: .topLeading)
                screenColumn(r, std, 1).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            screenColumn(r, std, 0).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private func screenColumn(_ r: ResolvedScreen, _ std: ResolvedScreen, _ c: Int) -> some View {
        let mods = r.modules(in: c)
        // The order they arrive in when the island opens: down the left column, then down the right one.
        let first = c == 0 ? 0 : r.modules(in: 0).count
        if mods.count == 1 && mods[0].size == .l {
            module(mods[0].kind, .of(mods[0], standard: std)).modifier(ModuleStagger(order: first))
        } else {
            VStack(alignment: .leading, spacing: ScreenLayout.gap) {
                ForEach(Array(mods.enumerated()), id: \.element.kind) { i, m in
                    module(m.kind, .of(m, standard: std)).frame(height: m.frame.height, alignment: .top).modifier(ModuleStagger(order: first + i))
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// A screen with no module left: says where to add some.
    private var emptyScreen: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "square.dashed").font(.system(size: 22)).foregroundStyle(UI.hint).accessibilityHidden(true)    // a glyph
            Text(L("This screen is empty")).font(UI.value).foregroundStyle(UI.secondary)
            Button(L("Add modules in Settings")) { model.showSettings() }
                .buttonStyle(CocaineButtonStyle(height: CTL.hDialog))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The first cell of the open strip when it isn't Home: the closed island's bag melts out as the screen's icon melts in.
struct FirstCellMorph: ViewModifier, Animatable {
    var pose: IslandPose
    let out: Bool
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> { get { pose.data } set { pose.data = newValue } }
    func body(content: Content) -> some View {
        let p = pose.p
        let a = out ? 1 - Island.meltOut(p) : Island.meltIn(p)
        return content.scaleEffect(0.7 + 0.3 * a).blur(radius: 3 * (1 - a)).opacity(a)
    }
}
