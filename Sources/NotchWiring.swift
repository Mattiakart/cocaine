// The notch's features wired to the island when it starts (IslandController.start calls attach): the battery HUD
// (Sources/NotchPower.swift), the swipes (Sources/NotchGestures.swift), the sizes (Sources/NotchSizing.swift) and the
// reminders' watch (Sources/IslandReminders.swift).

import AppKit
import Combine

enum NotchWiring {
    private static var gestures: NotchGestureMonitor?
    private static var bag: [AnyCancellable] = []

    static func attach(model: IslandModel, controller: IslandController) {
        guard !AppDefaults.isolated else { return }           // tests and renders: no monitors, no IOKit callbacks
        NotchPowerWatch.shared.post = { [weak model] item in model?.flashItem(item) }
        NotchPowerWatch.shared.start()

        let g = NotchGestureMonitor()
        let prefs = NotchPrefs.shared
        g.settings = prefs.gestures
        g.target = { [weak controller] p in controller?.gestureTarget(at: p) }
        g.blocked = { [weak controller] in controller?.gestureBlocked ?? true }
        g.open = { [weak controller] id in controller?.gestureOpen(id) }
        g.close = { [weak controller] in controller?.setOpen(false) }
        g.screen = { [weak model] n in model?.stepTab(n) }
        g.feedback = { [weak model] p in if model?.gestureProgress != p { model?.gestureProgress = p } }
        g.start()
        gestures = g

        bag = [
            prefs.$gestures.dropFirst().sink { s in g.settings = s },
            // New sizes: every island re-measured and redrawn at once (the windows follow the canvas).
            prefs.$sizing.dropFirst().receive(on: DispatchQueue.main).sink { [weak controller, weak model] _ in
                model?.objectWillChange.send()
                controller?.relayout()
            },
        ]
        model.reminders.start()
    }
}
