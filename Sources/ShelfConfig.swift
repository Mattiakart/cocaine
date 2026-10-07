// The shelf's settings (watched folders, custom actions, how dragging behaves), kept in AppDefaults.store as JSON under
// `shelf.config.v1` (memory-only for test and render flags). Unknown or damaged values fall back to the defaults.

import Foundation

struct ShelfConfig: Codable, Equatable {
    static let key = "shelf.config.v1"
    static let maxWatched = 12
    static let maxActions = 24
    var v = 1
    var watched: [WatchedFolder] = []
    var actions: [ShelfAction] = []
    /// Items leave the shelf once dragged out (off: they stay, and follow a file that was moved).
    var removeAfterDragOut = false
    /// Shaking the pointer while dragging files opens the island on the shelf.
    var shakeToOpen = false
    /// Holding ⌥ while dragging over the island shows the instant actions.
    var instantActions = true
    /// The last folder picked for Copy to / Move to (its bookmark), to start there next time.
    var lastFolder: Data? = nil

    func sanitized() -> ShelfConfig {
        var c = self
        c.watched = Array(watched.prefix(Self.maxWatched)).map { var w = $0; w.delay = WatchedFolder.delays.contains(w.delay) ? w.delay : 2; w.rules = Array(w.rules.prefix(8)); return w }
        c.actions = Array(actions.prefix(Self.maxActions)).map { var a = $0; a.name = String(a.name.prefix(ShelfLimits.nameChars)); a.timeout = max(1, min(3600, a.timeout)); return a }
        return c
    }

    static func decode(_ d: Data?) -> ShelfConfig {
        guard let d, let c = try? JSONDecoder().decode(ShelfConfig.self, from: d), c.v == 1 else { return ShelfConfig() }
        return c.sanitized()
    }
}

final class ShelfConfigStore: ObservableObject {
    static let shared = ShelfConfigStore()
    @Published private(set) var config: ShelfConfig
    private let defaults: () -> UserDefaults

    init(defaults: @escaping () -> UserDefaults = { AppDefaults.store }) {
        self.defaults = defaults
        config = ShelfConfig.decode(defaults().data(forKey: ShelfConfig.key))
    }

    func update(_ body: (inout ShelfConfig) -> Void) {
        var c = config
        body(&c)
        c = c.sanitized()
        guard c != config else { return }
        config = c
        if let d = try? JSONEncoder().encode(c) { defaults().set(d, forKey: ShelfConfig.key) }
    }

    func updateAction(_ id: UUID, _ body: (inout ShelfAction) -> Void) {
        update { c in if let i = c.actions.firstIndex(where: { $0.id == id }) { body(&c.actions[i]) } }
    }

    func updateFolder(_ id: UUID, _ body: (inout WatchedFolder) -> Void) {
        update { c in if let i = c.watched.firstIndex(where: { $0.id == id }) { body(&c.watched[i]) } }
    }
}
