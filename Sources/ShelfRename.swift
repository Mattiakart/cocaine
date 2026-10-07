// Batch rename for the shelf: a rule (find/replace, letter case, prefix/suffix, a date, numbering) worked out as a plan with a
// live preview, checked for conflicts, applied without ever overwriting a file, and undone exactly. Pure except `apply`/`undo`,
// which take the file operations as parameters so tests run them on temporary folders. Tested by --shelf-test.

import Foundation

struct RenameRule: Equatable, Codable {
    enum LetterCase: String, Codable, CaseIterable { case keep, lower, upper, title }
    enum Place: String, Codable, CaseIterable { case before, after }
    enum DateMode: String, Codable, CaseIterable { case none, before, after }

    var find = ""
    var replace = ""
    var caseSensitive = false
    var letterCase = LetterCase.keep
    var prefix = ""
    var suffix = ""
    var numbering = false
    var start = 1
    var digits = 2
    var numberPlace = Place.after
    var separator = " "
    var date = DateMode.none
    var dateFormat = "yyyy-MM-dd"
    /// Replace the whole name with this base (then numbering makes them distinct); empty: keep the names.
    var newBase = ""

    var isIdentity: Bool {
        find.isEmpty && letterCase == .keep && prefix.isEmpty && suffix.isEmpty && !numbering && date == .none && newBase.isEmpty
    }
}

enum RenameEngine {
    /// The name `rule` gives the `index`th file (0-based) called `name`, with `date` for the date part. The extension is never
    /// touched (a folder's "extension" neither: folders keep their whole name as the base).
    static func newName(_ name: String, index: Int, rule: RenameRule, date: Date, isFolder: Bool = false) -> String {
        let ns = name as NSString
        let ext = isFolder ? "" : ns.pathExtension
        var base = ext.isEmpty ? name : ns.deletingPathExtension
        if !rule.newBase.isEmpty { base = rule.newBase }
        if !rule.find.isEmpty {
            base = base.replacingOccurrences(of: rule.find, with: rule.replace,
                                             options: rule.caseSensitive ? [] : [.caseInsensitive])
        }
        switch rule.letterCase {
        case .keep: break
        case .lower: base = base.lowercased()
        case .upper: base = base.uppercased()
        case .title: base = base.capitalized
        }
        base = rule.prefix + base + rule.suffix
        if rule.date != .none {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = safeDateFormat(rule.dateFormat)
            let d = f.string(from: date)
            base = rule.date == .before ? d + rule.separator + base : base + rule.separator + d
        }
        if rule.numbering {
            let n = rule.start + index
            let digits = max(1, min(6, rule.digits))
            let num = n < 0 ? "\(n)" : String(repeating: "0", count: max(0, digits - String(n).count)) + String(n)
            base = rule.numberPlace == .before ? num + rule.separator + base : base + rule.separator + num
        }
        return ext.isEmpty ? base : base + "." + ext
    }

    /// Only date fields (no quotes or text that could add a slash): anything else falls back to yyyy-MM-dd.
    static func safeDateFormat(_ f: String) -> String {
        let allowed = Set("yMdHhmsaEe-_. ")
        return !f.isEmpty && f.count <= 24 && f.allSatisfy({ allowed.contains($0) }) ? f : "yyyy-MM-dd"
    }

    enum Status: Equatable {
        case unchanged
        case ok
        case invalid(String)            // why the name can't be used
        case conflict(String)           // another file has (or would have) that name
    }

    struct Row: Equatable, Identifiable {
        var id: URL { from }
        var from: URL
        var to: URL
        var status: Status
        var oldName: String { from.lastPathComponent }
        var newName: String { to.lastPathComponent }
    }

    struct Plan: Equatable {
        var rows: [Row]
        /// Something would be renamed and nothing stands in the way.
        var canApply: Bool { rows.contains { $0.status == .ok } && !rows.contains { if case .conflict = $0.status { return true }; if case .invalid = $0.status { return true }; return false } }
        var conflicts: Int { rows.filter { if case .conflict = $0.status { return true }; return false }.count }
        var invalid: Int { rows.filter { if case .invalid = $0.status { return true }; return false }.count }
        var changes: Int { rows.filter { $0.status == .ok }.count }
    }

    /// Why a name can't be a file name here, or nil.
    static func problem(_ name: String) -> String? {
        if name.isEmpty || name == "." || name == ".." { return L("The name can't be empty") }
        if name.contains("/") || name.contains(":") { return L("A name can't contain / or :") }
        if name.hasPrefix(".") { return L("A name starting with a dot would hide the file") }
        if name.utf8.count > 255 { return L("The name is too long") }
        if name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return L("The name has a control character") }
        return nil
    }

    /// How names compare on the Mac's usual volumes (APFS/HFS+: case and Unicode normalization don't make two names different).
    static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    /// The plan for `urls` (each file's date from `dates`, the same order): every new name, and what stops it. A name another
    /// file of the folder already has is a conflict, unless that file is itself renamed away in the same batch.
    static func plan(_ urls: [URL], rule: RenameRule, dates: [Date], isFolder: (URL) -> Bool = { _ in false },
                     exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Plan {
        var rows: [Row] = []
        for (i, u) in urls.enumerated() {
            let name = newName(u.lastPathComponent, index: i, rule: rule, date: i < dates.count ? dates[i] : Date(), isFolder: isFolder(u))
            let to = u.deletingLastPathComponent().appendingPathComponent(name)
            if name == u.lastPathComponent { rows.append(Row(from: u, to: to, status: .unchanged)); continue }
            if let p = problem(name) { rows.append(Row(from: u, to: to, status: .invalid(p))); continue }
            rows.append(Row(from: u, to: to, status: .ok))
        }
        // Two files of the batch ending up with one name.
        var seen: [String: Int] = [:]
        for (i, r) in rows.enumerated() {
            let k = key(r.to.path)
            if let j = seen[k] {
                rows[i].status = .conflict(String(format: L("Same name as %@"), rows[j].oldName))
                if rows[j].status == .ok || rows[j].status == .unchanged { rows[j].status = .conflict(String(format: L("Same name as %@"), rows[i].oldName)) }
            } else { seen[k] = i }
        }
        // A name already taken in the folder by a file that isn't leaving it.
        let leaving = Set(rows.filter { $0.status == .ok }.map { key($0.from.path) })
        for (i, r) in rows.enumerated() where r.status == .ok {
            let k = key(r.to.path)
            let caseOnly = k == key(r.from.path)                 // "a.txt" → "A.txt": the same file
            if !caseOnly && exists(r.to.path) && !leaving.contains(k) {
                rows[i].status = .conflict(L("A file with this name is already there"))
            }
        }
        return Plan(rows: rows)
    }

    struct Done: Equatable {
        var moved: [(from: URL, to: URL)]
        var failed: [(url: URL, why: String)]
        static func == (a: Done, b: Done) -> Bool {
            a.moved.map { [$0.from, $0.to] } == b.moved.map { [$0.from, $0.to] } && a.failed.map(\.url) == b.failed.map(\.url)
        }
        /// The undo: each rename backwards.
        var undo: [(from: URL, to: URL)] { moved.map { ($0.to, $0.from) }.reversed() }
    }

    /// Renames, in two steps (every file to a temporary name first, then to its new name), so swaps (a → b, b → a) and case-only
    /// changes work; `move` must refuse to overwrite (FileManager.moveItem does). A file whose step fails goes back to its name.
    static func apply(_ plan: Plan, move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) -> Done {
        guard plan.canApply else { return Done(moved: [], failed: []) }
        var done = Done(moved: [], failed: [])
        var staged: [(tmp: URL, row: Row)] = []
        for r in plan.rows where r.status == .ok {
            let tmp = r.from.deletingLastPathComponent().appendingPathComponent(".cocaine-rename-\(UUID().uuidString)")
            do { try move(r.from, tmp); staged.append((tmp, r)) } catch { done.failed.append((r.from, error.localizedDescription)) }
        }
        for s in staged {
            do { try move(s.tmp, s.row.to); done.moved.append((s.row.from, s.row.to)) }
            catch {
                try? move(s.tmp, s.row.from)
                done.failed.append((s.row.from, error.localizedDescription))
            }
        }
        return done
    }

    /// Puts the names back (the same two steps, so nothing is overwritten on the way).
    static func undo(_ done: Done, move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) -> Done {
        let rows = done.undo.map { Row(from: $0.from, to: $0.to, status: .ok) }
        return apply(Plan(rows: rows), move: move)
    }
}
