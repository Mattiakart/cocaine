// The clipboard's search filters and suggestions (pure, tested in Sources/PasteTests.swift).
// Search: words (every one must match, any case and accents) plus a few filters, typed or picked as chips: type:text|image|file|
// link|color, app:Safari, from:device|mac, board:Prompts (quotes for spaces: board:"My board"), date:today|yesterday|3h|7d|2w.
// Suggestions: with no Screen Recording and nothing read from other apps, only what Cocaine itself knows: what was copied in
// the app in front, what was pasted into it, and the pinboards the user tied to it.

import AppKit

/// What an item looks like to the filters: a link, a colour, or plain text.
enum ClipLooks {
    /// The whole text is one web or mail link.
    static func isLink(_ s: String) -> Bool { link(s) != nil }

    static func link(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 4_000, !t.isEmpty, t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let lower = t.lowercased()
        if lower.hasPrefix("www.") { return URL(string: "https://" + t) }
        guard ["http://", "https://", "mailto:", "ftp://"].contains(where: { lower.hasPrefix($0) }), let u = URL(string: t), u.scheme != nil else { return nil }
        if lower.hasPrefix("mailto:") { return u }
        return u.host?.isEmpty == false ? u : nil
    }

    /// The whole text is a colour: #RGB, #RRGGBB or #RRGGBBAA (the # is required, so codes and numbers aren't swatches),
    /// rgb(…) / rgba(…). Its components 0…1.
    static func color(_ s: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count <= 40 else { return nil }
        if t.hasPrefix("#") {
            let hex = String(t.dropFirst())
            guard [3, 6, 8].contains(hex.count), hex.allSatisfy({ $0.isHexDigit }), let v = UInt64(hex, radix: 16) else { return nil }
            switch hex.count {
            case 3: return (Double((v >> 8) & 0xF) / 15, Double((v >> 4) & 0xF) / 15, Double(v & 0xF) / 15, 1)
            case 6: return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
            default: return (Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
            }
        }
        for p in ["rgba(", "rgb("] where t.hasPrefix(p) && t.hasSuffix(")") {
            let inner = t.dropFirst(p.count).dropLast()
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init).filter { !$0.isEmpty }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            var v: [Double] = []
            for (i, x) in parts.enumerated() {
                if x.hasSuffix("%"), let n = Double(x.dropLast()), (0...100).contains(n) { v.append(n / 100); continue }
                guard let n = Double(x) else { return nil }
                if i < 3 { guard (0...255).contains(n) else { return nil }; v.append(n / 255) }
                else { guard (0...1).contains(n) else { return nil }; v.append(n) }
            }
            return (v[0], v[1], v[2], v.count == 4 ? v[3] : 1)
        }
        return nil
    }

    /// The text looks like code or JSON (shown in a monospaced font).
    static func isCode(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]")) { return true }
        let sample = String(t.prefix(2_000))
        let marks = sample.filter { "{};=<>()[]$".contains($0) }.count
        let lines = sample.split(separator: "\n").count
        return lines >= 2 && Double(marks) / Double(max(1, sample.count)) > 0.04
    }
}

struct ClipQuery: Equatable {
    enum Kind: String, CaseIterable { case text, image, file, link, color }
    var words: [String] = []
    var kinds: Set<Kind> = []
    var apps: [String] = []
    var remote: Bool?               // true: from another device; false: from this Mac
    var boards: [String] = []
    var since: Date?

    var isEmpty: Bool { words.isEmpty && kinds.isEmpty && apps.isEmpty && remote == nil && boards.isEmpty && since == nil }

    /// The query as typed. Unknown `x:y` tokens are ordinary words.
    static func parse(_ s: String, now: Date = Date(), calendar: Calendar = .current) -> ClipQuery {
        var q = ClipQuery()
        for tok in split(s) {
            guard let colon = tok.firstIndex(of: ":"), colon != tok.startIndex else { q.words.append(tok); continue }
            let key = tok[..<colon].lowercased(), value = String(tok[tok.index(after: colon)...])
            let v = value.lowercased()
            switch key {
            case "type", "is", "kind":
                let map: [String: Kind] = ["text": .text, "image": .image, "images": .image, "img": .image, "file": .file, "files": .file,
                                           "link": .link, "links": .link, "url": .link, "color": .color, "colour": .color, "colors": .color]
                if let k = map[v] { q.kinds.insert(k) } else { q.words.append(tok) }
            case "app": if !value.isEmpty { q.apps.append(value) } else { q.words.append(tok) }
            case "from", "device":
                if ["device", "iphone", "ipad", "phone", "other", "remote", "handoff"].contains(v) { q.remote = true }
                else if ["mac", "this", "local"].contains(v) { q.remote = false }
                else if !value.isEmpty { q.apps.append(value) }
            case "board", "pin", "pinboard": if !value.isEmpty { q.boards.append(value) } else { q.words.append(tok) }
            case "date", "since":
                if let d = since(v, now: now, calendar: calendar) { q.since = d } else { q.words.append(tok) }
            default: q.words.append(tok)
            }
        }
        return q
    }

    /// today, yesterday, 3h, 7d, 2w.
    static func since(_ v: String, now: Date, calendar: Calendar) -> Date? {
        switch v {
        case "today": return calendar.startOfDay(for: now)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        default:
            guard v.count >= 2, let n = Int(v.dropLast()), n > 0, n <= 10_000 else { return nil }
            switch v.last! {
            case "h": return now.addingTimeInterval(-Double(n) * 3600)
            case "d": return now.addingTimeInterval(-Double(n) * 86400)
            case "w": return now.addingTimeInterval(-Double(n) * 7 * 86400)
            default: return nil
            }
        }
    }

    /// Words split on spaces, keeping "quoted parts" together (board:"My board").
    static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        for ch in s.prefix(500) {
            if ch == "\"" { quoted.toggle(); continue }
            if ch.isWhitespace && !quoted { if !cur.isEmpty { out.append(cur); cur = "" }; continue }
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    func kind(of item: ClipItem) -> Set<Kind> {
        switch item.kind {
        case .image: return [.image]
        case .files: return [.file]
        case .text:
            var k: Set<Kind> = [.text]
            if ClipLooks.isLink(item.text) { k.insert(.link) }
            if ClipLooks.color(item.text) != nil { k.insert(.color) }
            return k
        }
    }

    /// Does the item pass every filter? `appName` names a source; `boards` resolves names to pinboards.
    func matches(_ item: ClipItem, boards: [ClipBoard], appName: (String?) -> String?, describe: (ClipItem) -> String) -> Bool {
        if let s = since, item.date < s { return false }
        if let r = remote, item.remote != r { return false }
        if !kinds.isEmpty, kinds.isDisjoint(with: kind(of: item)) { return false }
        for a in apps {
            let src = item.source ?? "", name = appName(item.source) ?? ""
            if src.range(of: a, options: [.caseInsensitive, .diacriticInsensitive]) == nil
                && name.range(of: a, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
        }
        for b in self.boards {
            let ids = boards.filter { $0.displayName.range(of: b, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id)
            if !item.boards.contains(where: { ids.contains($0) }) { return false }
        }
        return ClipHistoryCore.matches(item, words: words, describe: describe)
    }
}

extension ClipboardHistory {
    /// What the island's list shows: the typed query, a chosen pinboard (nil: all) and a chosen kind (nil: all).
    func listed(board: UUID?, kind: ClipQuery.Kind?) -> [ClipItem] {
        let q = ClipQuery.parse(query, now: now())
        let bs = boards
        return items.filter { c in
            if let board, !c.boards.contains(board) { return false }
            if let kind, !q.kind(of: c).contains(kind) { return false }
            return q.matches(c, boards: bs, appName: ClipboardHistory.appName, describe: describe)
        }
    }
}

// MARK: - Suggestions by the app in front

enum ClipSuggest {
    /// Up to `limit` items worth pasting into `front`: pasted into it before (most), on a pinboard tied to it, copied in it;
    /// the newest of equals first. The item on the clipboard now (the first of the history) is never suggested: ⌘V has it.
    static func rank(_ items: [ClipItem], front: String?, boards: [ClipBoard], now: Date, limit: Int = 3) -> [ClipItem] {
        guard let front, !front.isEmpty else { return [] }
        let tied = Set(boards.filter { $0.app == front }.map(\.id))
        var scored: [(ClipItem, Double)] = []
        for (i, c) in items.enumerated() where i > 0 {
            var s = Double(min(c.used[front] ?? 0, 20)) * 3
            if c.boards.contains(where: { tied.contains($0) }) { s += 4 }
            if c.source == front { s += 2 }
            guard s > 0 else { continue }
            let last = max(c.date, c.lastUsed ?? .distantPast)
            let days = max(0, now.timeIntervalSince(last) / 86400)
            s *= 1 / (1 + days / 7)                                       // a week old counts half
            scored.append((c, s))
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }.prefix(limit).map(\.0)
    }
}
