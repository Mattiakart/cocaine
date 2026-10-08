// --screens-test (also part of --selftest): the rules of ScreenLayout, the island model following it, and the render
// fixtures (`--screens-fixture <name>` for --render-island and --render-panel).

import AppKit
import SwiftUI

/// Arranged layouts for the renders and the tests.
enum ScreenFixtures {
    static let names = ["standard", "merge", "hide-mirror", "order", "stack", "wide", "overflow", "empty"]

    static func named(_ name: String) -> ScreenLayout? {
        var l = ScreenLayout.standard
        switch name {
        case "standard": break
        case "merge": l.merge("clipboard", into: "status")                       // Status + Clipboard on one screen
        case "hide-mirror": l.setVisible("mirror", false)
        case "order":                                                            // Status first, Music last, opens on Status
            l.moveScreen("status", to: 0); l.moveScreen("music", to: l.screens.count - 1); l.setStart("status")
        case "stack":                                                            // Home: Cocaine M and Batteries S over each other
            l.setSize("cocaine", in: "home", .m); l.addModule("batteries", to: "home")
        case "wide":                                                             // Files: screenshots beside the music player
            l.removeModule("downloads", from: "files"); l.addModule("music", to: "files")
        case "overflow":                                                         // Focus needs the whole screen: Clipboard gives way
            l.addModule("clipboard", to: "focus")
        case "empty": l.removeModule("shelf", from: "shelf")
        default: return nil
        }
        return l
    }
}

/// `--screens-fixture <name>` (renders), and `--screens-edit <screen>` (the panel: that screen's modules open).
func applyScreensFixture(_ args: [String]) {
    if let i = args.firstIndex(of: "--screens-fixture"), i + 1 < args.count {
        guard let f = ScreenFixtures.named(args[i + 1]) else {
            FileHandle.standardError.write(Data("unknown screens fixture \(args[i + 1]): \(ScreenFixtures.names.joined(separator: ", "))\n".utf8))
            exit(64)
        }
        ScreenLayoutStore.shared.set(f)
    }
    if let i = args.firstIndex(of: "--screens-edit"), i + 1 < args.count { ScreensEditorState.shared.editing = args[i + 1] }
}

/// `--screens-test`, run from main.swift.
func cliScreensTest() {
    _ = NSApplication.shared
    var failed = 0
    screenLayoutSelfTest { name, ok in print((ok ? "PASS" : "FAIL") + "  " + name); if !ok { failed += 1 } }
    exit(failed == 0 ? 0 : 1)
}

func screenLayoutSelfTest(_ check: (String, Bool) -> Void) {
    let std = ScreenLayout.standard
    let box = ScreenLayout.contentSize(stripHeight: 32)
    let oldTabs = ["home", "music", "media", "calendar", "focus", "files", "shelf", "clipboard", "status", "mirror"]

    // The standard layout is the island as it was.
    check("screens: the standard layout is today's tabs, in today's order", std.visibleScreens(external: false).map(\.id) == oldTabs
          && std.visibleScreens(external: true).map(\.id) == oldTabs + ["display"])
    check("screens: Island.tabs from the standard layout = the old list (ids, icons)",
          Island.tabs(external: true, layout: std).map { $0.id + "/" + $0.icon } == ["home/house.fill", "music/music.note", "media/play.rectangle.fill",
          "calendar/calendar", "focus/timer", "files/tray.full.fill", "shelf/tray.and.arrow.down.fill", "clipboard/doc.on.clipboard",
          "status/gauge.with.needle", "mirror/person.crop.square", "display/display"])
    check("screens: the standard start is the last screen used, the first one after launch", std.start == ScreenLayout.lastUsed
          && std.startScreen(current: nil, external: false) == "home" && std.startScreen(current: "files", external: false) == "files")
    do {
        let home = ScreenLayout.resolve(std.config("home")!, in: box)
        check("screens: Home = Cocaine in the 250 pt column, Agents in the rest, both full height",
              home.columns == 2 && home.widths == [250, box.width - 250 - Space.gutter] && home.modules.map(\.kind) == ["cocaine", "agents"]
              && home.modules.allSatisfy { $0.frame.height == box.height } && home.issues.isEmpty)
        let ok = std.screens.allSatisfy { ScreenLayout.resolve($0, in: box).issues.isEmpty }
        check("screens: no standard screen has anything shrunk or left out", ok)
    }

    // Storing: nothing, garbage, a newer version, unknown ids.
    check("screens: nothing stored = the standard layout", ScreenLayout.decode(nil) == std)
    check("screens: an unreadable stored value = the standard layout", ScreenLayout.decode(Data("{ not json".utf8)) == std)
    do {
        var newer = std; newer.version = 2
        check("screens: a value from a newer Cocaine = the standard layout", ScreenLayout.decode(newer.encoded()) == std)
        var odd = std
        odd.screens.insert(ScreenConfig(id: "weather", visible: true, modules: [ModulePlacement("radar", 0)]), at: 0)
        odd.screens[1].modules.append(ModulePlacement("radar", 1))
        odd.screens.removeAll { $0.id == "media" }
        let back = ScreenLayout.decode(odd.encoded())
        check("screens: unknown screens and modules are dropped, a missing screen comes back at the end",
              back.screens.map(\.id) == std.screens.map(\.id).filter { $0 != "media" } + ["media"]
              && back.config("home")?.modules == std.config("home")?.modules)
        var round = std; round.setVisible("mirror", false); round.moveScreen("status", by: -3)
        check("screens: a layout reads back as it was saved", ScreenLayout.decode(round.encoded()) == round)
        var bad = std; bad.screens[0].modules[0].size = .s; bad.screens[0].modules[1].column = 7
        let fixed = ScreenLayout.decode(bad.encoded())
        check("screens: a size a module can't be and a column out of range are put right",
              fixed.config("home")?.modules[1].column == 1 && fixed.config("home")?.modules[0].size == .s
              && ScreenLayout.decode({ var b = std; b.screens[1].modules[0].size = .s; return b }().encoded()).config("music")?.modules[0].size == .l)
    }

    // Reorder, hide, start.
    do {
        var l = std
        check("screens: move down and up", l.moveScreen("home", by: 1) && l.screens.map(\.id).prefix(2) == ["music", "home"]
              && l.moveScreen("home", by: -1) && l == std)
        check("screens: the first can't go up, the last can't go down", !l.moveScreen("home", by: -1) && !l.moveScreen(l.screens.last!.id, by: 1))
        check("screens: drag to a place", l.moveScreen("mirror", to: 0) && l.screens.first?.id == "mirror" && l.screens.count == std.screens.count)
        l = std
        check("screens: a hidden screen leaves the tabs", l.setVisible("mirror", false) && !l.visibleScreens(external: false).map(\.id).contains("mirror"))
        var one = std
        for s in oldTabs.dropFirst() { one.setVisible(s, false) }
        check("screens: the last screen shown can't be hidden (the Monitors screen doesn't count)",
              !one.canHide("home") && !one.setVisible("home", false) && one.visibleScreens(external: false).map(\.id) == ["home"]
              && one.canHide("display"))
        var none = std
        for i in none.screens.indices { none.screens[i].visible = false }
        check("screens: a stored value with nothing shown shows the first screen", none.sanitized().visibleScreens(external: false).map(\.id) == ["home"])
        var st = std
        st.setStart("status")
        check("screens: a start screen is opened on whatever was shown last", st.startScreen(current: "files", external: false) == "status")
        st.setVisible("status", false)
        check("screens: a hidden start screen falls back to the last used, then the first", st.startScreen(current: "files", external: false) == "files"
              && st.startScreen(current: nil, external: false) == "home")
        st.setStart("nonsense")
        check("screens: an unknown start screen is 'last used'", st.start == ScreenLayout.lastUsed)
        var d = std; d.setStart("display")
        check("screens: the Monitors screen as start, without a monitor: the first screen", d.startScreen(current: nil, external: false) == "home"
              && d.startScreen(current: nil, external: true) == "display")
    }

    // Modules: add, merge, move, resize, validation.
    do {
        var l = std
        check("screens: a module is added once per screen", l.addModule("clipboard", to: "home") && !l.addModule("clipboard", to: "home")
              && l.addable(to: "home").allSatisfy { !["cocaine", "agents", "clipboard"].contains($0.id) })
        l = std
        check("screens: adding to a full screen makes room (Batteries next to Cocaine, which goes to M)",
              l.addModule("batteries", to: "home") && l.config("home")?.modules.map { "\($0.kind)\($0.column)\($0.size.letter)" } == ["cocaine0M", "agents1L", "batteries0M"]
              && !l.addModule("batteries", to: "home"))
        let r = ScreenLayout.resolve(l.config("home")!, in: box)
        check("screens: …and it all fits, stacked in the left column", r.issues.isEmpty && r.modules.count == 3
              && r.modules.filter { $0.column == 0 }.map(\.frame.minY) == [0, (box.height - Space.l) / 2 + Space.l])
        var m = std
        check("screens: merge Clipboard into Status: Status holds it, Clipboard is hidden",
              m.merge("clipboard", into: "status") && m.config("status")!.modules.map(\.kind) == ["batteries", "usage", "clipboard"]
              && m.config("clipboard")?.visible == false)
        let rm = ScreenLayout.resolve(m.config("status")!, in: box)
        check("screens: …and nothing of the merged screen is left out or cut", rm.issues.isEmpty && rm.modules.count == 3
              && rm.modules.allSatisfy { $0.frame.maxY <= box.height + 0.01 && $0.frame.maxX <= box.width + 0.01 })
        check("screens: a screen can't be merged into itself, nor twice", !m.merge("status", into: "status") && !m.merge("clipboard", into: "status"))
        var mv = std
        check("screens: move a module and change its column", mv.moveModule("agents", in: "home", by: -1)
              && mv.config("home")!.modules.map(\.kind) == ["agents", "cocaine"] && mv.setColumn("agents", in: "home", 1) && !mv.setColumn("agents", in: "home", 2))
        check("screens: a size the module doesn't have is refused", !mv.setSize("music", in: "music", .s) && mv.setSize("cocaine", in: "home", .s))
        check("screens: remove a module", mv.removeModule("agents", from: "home") && mv.config("home")!.modules.map(\.kind) == ["cocaine"])
        let alone = ScreenLayout.resolve(mv.config("home")!, in: box)
        check("screens: a module alone gets the whole width", alone.columns == 1 && alone.modules[0].frame.width == box.width)

        // Too much in a column: the lowest that can shrink does; when none can, the lowest is left out (never cut).
        let tall = ScreenConfig(id: "home", visible: true, modules: [ModulePlacement("cocaine", 0, .l), ModulePlacement("batteries", 0, .l)])
        let rt = ScreenLayout.resolve(tall, in: box)
        check("screens: too tall: the lower module is drawn smaller, and the editor says so",
              rt.modules.count == 1 || rt.issues.contains { if case .shrunk = $0 { return true }; if case .noRoom = $0 { return true }; return false })
        check("screens: …the column never holds more than its height",
              rt.modules.map(\.frame.height).reduce(0, +) + Space.l * CGFloat(max(0, rt.modules.count - 1)) <= box.height + 0.01)
        // S + S + M (Agents has no S) is more than a column: nothing can shrink further, so the lowest is left out.
        let three = ScreenConfig(id: "home", visible: true, modules: ["cocaine", "batteries", "agents"].map { ModulePlacement($0, 0, .s) })
        let rf = ScreenLayout.resolve(three, in: box)
        check("screens: a column too full even at the smallest sizes: the lowest is left out (\(rf.modules.map(\.kind)))",
              rf.modules.map(\.kind) == ["cocaine", "batteries"] && rf.issues == [.noRoom("agents")]
              && rf.modules.allSatisfy { $0.frame.maxY <= box.height + 0.01 })
        let full = ScreenConfig(id: "focus", visible: true, modules: [ModulePlacement("focus", 0), ModulePlacement("clipboard", 1)])
        let rfu = ScreenLayout.resolve(full, in: box)
        check("screens: a module that needs the whole width keeps the screen", rfu.modules.map(\.kind) == ["focus"]
              && rfu.issues == [.needsWholePage("clipboard", "focus")] && rfu.widths == [box.width])
        let cal = ScreenConfig(id: "calendar", visible: true, modules: [ModulePlacement("batteries", 0, .s), ModulePlacement("calendar", 0)])
        check("screens: the calendar fills its screen alone", ScreenLayout.resolve(cal, in: box).modules.map(\.kind) == ["calendar"])
        let wide = ScreenConfig(id: "files", visible: true, modules: [ModulePlacement("music", 0), ModulePlacement("shelf", 1)])
        let rw = ScreenLayout.resolve(wide, in: box)
        check("screens: two modules that need the wide column: the right one gives way", rw.modules.map(\.kind) == ["music"]
              && rw.issues == [.needsWideColumn("shelf", "music")])
        let wl = ScreenConfig(id: "files", visible: true, modules: [ModulePlacement("music", 0), ModulePlacement("downloads", 1)])
        check("screens: the module that needs room gets the wide column, even on the left",
              ScreenLayout.resolve(wl, in: box).widths == [box.width - 250 - Space.gutter, 250])
        check("screens: an empty screen says so", ScreenLayout.resolve(ScreenConfig(id: "x", visible: true, modules: []), in: box).issues == [.empty])
        check("screens: every fixture lays out inside the page",
              ScreenFixtures.names.allSatisfy { n in ScreenFixtures.named(n)!.screens.allSatisfy { s in
                  ScreenLayout.resolve(s, in: box).modules.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= box.width + 0.01 && $0.frame.maxY <= box.height + 0.01 } } })
        check("screens: every issue has words", [ResolvedScreen.Issue.shrunk("agents", .l, .m), .noRoom("agents"), .needsWholePage("a", "focus"),
              .needsWideColumn("shelf", "music")].allSatisfy { !(ScreensEditor.message($0) ?? "").isEmpty })
    }

    // The store and the island model following it.
    do {
        let mem = MemoryDefaults()
        let store = ScreenLayoutStore(defaults: { mem })
        check("screens store: starts standard, stores nothing", store.isStandard && mem.data(forKey: ScreenLayout.key) == nil)
        store.update { $0.setVisible("mirror", false) }
        check("screens store: a change is saved under screens.v1", ScreenLayout.decode(mem.data(forKey: ScreenLayout.key)) == store.layout && !store.isStandard)
        check("screens store: read back by a new store", ScreenLayoutStore(defaults: { mem }).layout == store.layout)
        store.restoreDefaults()
        check("screens store: Restore defaults forgets the stored value", store.isStandard && mem.data(forKey: ScreenLayout.key) == nil)

        let im = IslandModel(screens: store)
        check("island: the tabs follow the standard layout", im.tabs.map(\.id) == Island.tabs(external: im.external, layout: .standard).map(\.id))
        im.tab = "mirror"
        store.update { $0.setVisible("mirror", false) }
        check("island: hiding the screen shown goes to the start screen", im.tab == "home" && !im.tabs.contains { $0.id == "mirror" })
        store.update { $0.moveScreen("status", to: 0) }
        check("island: reordering reorders the tabs", im.tabs.first?.id == "status")
        im.tab = "status"; im.stepTab(1)
        check("island: → follows the new order", im.tab == "home")
        store.update { $0.merge("shelf", into: "files") }
        im.tab = "shelf"
        check("island: asked for a hidden screen (a file dragged in: 'shelf'), it shows the one holding that module", im.tab == "files" && im.shows("shelf"))
        store.update { $0.setStart("music") }
        im.open = true; im.tab = "files"; im.open = false
        let deadline = Date().addingTimeInterval(1.2)
        while im.tab != "music" && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check("island: with a start screen it opens there next time (set once closed)", im.tab == "music")
        store.restoreDefaults()
        check("island: after Restore defaults the tabs are the standard ones again", im.tabs.map(\.id) == Island.tabs(external: im.external, layout: .standard).map(\.id))
    }
}
