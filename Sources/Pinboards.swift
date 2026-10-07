// Pinboards: named collections of clipboard items (Paste's "pinboards"). An item can be on several; an item on any pinboard is
// kept for good (never removed by the history's limits) and is saved on this Mac, encrypted with the history's Keychain key,
// even when the history itself is memory-only. The built-in Favorites pinboard is the star of the island's rows.
// Pure rules here (tested in Sources/PasteTests.swift); the list and its saving are in Sources/Clipboard.swift, the island's
// chips in Sources/IslandClipboard.swift, the settings card in Sources/PinboardsSettings.swift.

import AppKit
import SwiftUI

struct ClipBoard: Codable, Equatable, Identifiable {
    /// The Favorites pinboard: always there, can be renamed and recoloured, never deleted.
    static let favoritesID = UUID(uuidString: "C0CA1000-0000-4000-8000-00000000FA70")!

    var id = UUID()
    var name = ""                 // "" on Favorites: its name in the app's language
    var color = 0                 // BoardColor index
    var icon: String?             // an SF Symbol (one of PinboardRules.icons)
    var app: String?              // bundle id: this pinboard's items are suggested first while that app is in front
    var hotkey: Shortcut?         // a global shortcut that opens the island on it (Carbon, no permission)
    var ai = false                // shared with AI tools through MCP (Sources/MCPServer.swift); off unless the user turns it on

    init(id: UUID = UUID(), name: String, color: Int = 0, icon: String? = nil, app: String? = nil, hotkey: Shortcut? = nil) {
        self.id = id; self.name = name; self.color = color; self.icon = icon; self.app = app; self.hotkey = hotkey
    }

    enum CodingKeys: String, CodingKey { case id, name, color, icon, app, hotkey, ai }
    /// Unknown or missing fields take their defaults (a newer Cocaine's pinboard still loads); a missing id is an error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = String(((try? c.decodeIfPresent(String.self, forKey: .name)) ?? "").prefix(PinboardRules.maxName))
        color = min(BoardColor.count - 1, max(0, (try? c.decodeIfPresent(Int.self, forKey: .color)) ?? 0))
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)).flatMap { $0 }.flatMap { PinboardRules.icons.contains($0) ? $0 : nil }
        app = (try? c.decodeIfPresent(String.self, forKey: .app)).flatMap { $0 }
        hotkey = (try? c.decodeIfPresent(Shortcut.self, forKey: .hotkey)).flatMap { $0 }
        ai = (try? c.decodeIfPresent(Bool.self, forKey: .ai)).flatMap { $0 } ?? false
    }

    static var favorites: ClipBoard { ClipBoard(id: favoritesID, name: "", color: 0, icon: "star.fill") }
    var isFavorites: Bool { id == Self.favoritesID }
    var displayName: String { isFavorites && name.isEmpty ? L("Favorites") : name }
    var symbol: String { icon ?? (isFavorites ? "star.fill" : "pin.fill") }
}

/// The eight pinboard colours (tokens: the same eight everywhere; names for VoiceOver).
enum BoardColor {
    static let count = 8
    static func color(_ i: Int) -> Color {
        switch i {
        case 1: return Color(red: 1.0, green: 0.62, blue: 0.27)     // orange
        case 2: return Color(red: 1.0, green: 0.84, blue: 0.30)     // yellow
        case 3: return Color(red: 0.42, green: 0.85, blue: 0.47)    // green
        case 4: return Color(red: 0.35, green: 0.84, blue: 0.84)    // teal
        case 5: return Color(red: 0.75, green: 0.55, blue: 1.0)     // purple
        case 6: return Color(red: 1.0, green: 0.48, blue: 0.68)     // pink
        case 7: return Color(white: 0.68)                           // grey
        default: return Island.accent                               // blue (the island's accent)
        }
    }
    static func name(_ i: Int) -> String {
        [L("Blue"), L("Orange"), L("Yellow"), L("Green"), L("Teal"), L("Purple"), L("Pink"), L("Grey")][min(count - 1, max(0, i))]
    }
}

enum PinboardRules {
    static let maxBoards = 30
    static let maxName = 40
    /// The symbols a pinboard can have (a short, fixed list: they read well at 10 pt in a chip).
    static let icons = ["star.fill", "pin.fill", "bookmark.fill", "text.quote", "chevron.left.forwardslash.chevron.right", "terminal.fill",
                        "envelope.fill", "link", "photo", "folder.fill", "sparkles", "person.fill", "cart.fill", "flag.fill", "heart.fill"]

    /// Why this name can't be used for a pinboard (nil: fine). `except`: the pinboard being renamed.
    static func problem(_ raw: String, in boards: [ClipBoard], except: UUID? = nil) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return L("Type a name") }
        if name.count > maxName { return String(format: L("At most %d characters"), maxName) }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return L("Type a name") }
        if boards.contains(where: { $0.id != except && $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return L("A pinboard with this name already exists")
        }
        return nil
    }

    /// A new pinboard at the end (nil: a bad name, or too many).
    static func create(_ boards: inout [ClipBoard], name: String, color: Int? = nil, icon: String? = nil) -> ClipBoard? {
        guard boards.count < maxBoards, problem(name, in: boards) == nil else { return nil }
        let b = ClipBoard(name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: color ?? (boards.count % BoardColor.count),
                          icon: icon.flatMap { icons.contains($0) ? $0 : nil })
        boards.append(b)
        return b
    }

    @discardableResult
    static func rename(_ boards: inout [ClipBoard], _ id: UUID, to name: String) -> Bool {
        guard let i = boards.firstIndex(where: { $0.id == id }), problem(name, in: boards, except: id) == nil else { return false }
        boards[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }

    /// Moves a pinboard up or down by `offset` places (clamped). Favorites can move too.
    @discardableResult
    static func move(_ boards: inout [ClipBoard], _ id: UUID, by offset: Int) -> Bool {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return false }
        let j = min(boards.count - 1, max(0, i + offset))
        guard j != i else { return false }
        boards.insert(boards.remove(at: i), at: j)
        return true
    }

    /// Moves a pinboard to sit before `target` (drag and drop in the settings list).
    @discardableResult
    static func move(_ boards: inout [ClipBoard], _ id: UUID, before target: UUID) -> Bool {
        guard id != target, let i = boards.firstIndex(where: { $0.id == id }) else { return false }
        let b = boards.remove(at: i)
        let j = boards.firstIndex { $0.id == target } ?? boards.count
        boards.insert(b, at: j)
        return true
    }

    /// The list as loaded or edited: Favorites always present (first when it was missing), no duplicate ids, at most maxBoards.
    static func normalized(_ boards: [ClipBoard]) -> [ClipBoard] {
        var seen = Set<UUID>(), out: [ClipBoard] = []
        for b in boards where !seen.contains(b.id) { seen.insert(b.id); out.append(b) }
        if !seen.contains(ClipBoard.favoritesID) { out.insert(.favorites, at: 0) }
        return Array(out.prefix(maxBoards))
    }

    /// Whether the boards differ from the built-in state (only Favorites, as it comes): then they are worth saving.
    static func isCustomized(_ boards: [ClipBoard]) -> Bool { boards != [.favorites] }
}

extension ClipHistoryCore {
    /// Puts items on a pinboard (kept for good from now on).
    mutating func assign(_ ids: [UUID], to board: UUID) {
        for i in items.indices where ids.contains(items[i].id) && !items[i].boards.contains(board) { items[i].boards.append(board) }
    }

    /// Takes items off a pinboard (they stay in the history; the limits apply to them again if they are on no other one).
    mutating func unassign(_ ids: [UUID], from board: UUID) {
        for i in items.indices where ids.contains(items[i].id) { items[i].boards.removeAll { $0 == board } }
    }

    /// Moves items from one pinboard to another (a drag between chips).
    mutating func move(_ ids: [UUID], from: UUID?, to: UUID) {
        if let from, from != to { unassign(ids, from: from) }
        assign(ids, to: to)
    }

    /// A pinboard was deleted: no item is on it any more.
    mutating func forgetBoard(_ id: UUID) {
        for i in items.indices { items[i].boards.removeAll { $0 == id } }
    }

    /// Ids of boards that no longer exist are dropped from the items (a damaged or older boards file).
    mutating func dropUnknownBoards(_ known: Set<UUID>) {
        for i in items.indices where items[i].boards.contains(where: { !known.contains($0) }) { items[i].boards.removeAll { !known.contains($0) } }
    }
}
