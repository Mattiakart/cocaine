// SSH hosts: the AI tools' hooks on a remote machine. The same editor as on this Mac (AIHooks.edited: only Cocaine's own hooks
// are added or removed, everything else stays as written), run here on the files the relay reads there, with commands that run
// the relay there. Nothing is written before the user has seen the exact change (a diff per file) and said yes; each write
// replaces only the file it read (the relay refuses it if the file changed since), keeps a backup there (~/.cocaine/backup),
// and when one file of several can't be written the ones already written are put back. Running it again changes nothing.

import Foundation

/// A config file as the relay read it there.
struct SSHRemoteFile: Equatable {
    var path: String          // relative to the remote home: ".claude/settings.json"
    var exists: Bool
    var text: String?
    var sha: String           // "" when it doesn't exist
}

struct SSHFileChange: Equatable, Identifiable {
    var id: String { path }
    var tool: String
    var toolName: String
    var path: String
    var before: String?       // nil: the file isn't there yet
    var beforeSHA: String
    var after: String
    var diff: [DiffLine]
    var added: Int { diff.filter { $0.kind == .add }.count }
    var removed: Int { diff.filter { $0.kind == .remove }.count }
}

struct SSHInstallPlan: Equatable {
    struct Problem: Equatable { var tool: String; var path: String; var reason: String }
    var on: Bool
    var changes: [SSHFileChange] = []
    var problems: [Problem] = []
    var unchanged: [String] = []      // tools already as wanted
    var isEmpty: Bool { changes.isEmpty }
}

enum SSHInstaller {
    /// A stand-in for the remote home in the tools' paths (they are sent to the relay relative to it).
    static let home = "/~remote"

    static func relative(_ path: String) -> String { path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path }

    /// The tools to change: the ones the relay found there (when adding) or the ones with Cocaine's hooks (when removing).
    static func tools(present: Set<String>, claudeVersion: String?) -> [AIHooks.Tool] {
        let v = claudeVersion.flatMap { s -> [Int]? in
            let parts = s.split(separator: ".").compactMap { Int($0) }
            return parts.count == 3 ? parts : nil
        }
        return AIHooks.remoteTools(home: home, claudeVersion: v).filter { present.contains($0.id) }
    }

    static func paths(_ tools: [AIHooks.Tool]) -> [String] { tools.map { relative($0.file) } }

    /// Hooks written by a Cocaine that runs on that machine itself (a Mac): never Cocaine's to change from here.
    static func localCocaine(_ root: JSONValue) -> Bool {
        func commands(_ v: JSONValue) -> [String] {
            switch v {
            case .scalar(let s): return [s]
            case .array(let a): return a.flatMap(commands)
            case .object(let m): return m.flatMap { commands($0.value) }
            }
        }
        return commands(root["hooks"] ?? .object([])).contains { s in
            s.contains(AIHooks.marker) && (s.contains("--agent-request") || s.contains("--agent-event") || s.contains("pgrep -qx Cocaine"))
        }
    }

    /// What adding (or removing) the hooks would change in each file. Pure.
    static func plan(on: Bool, tools: [AIHooks.Tool], files: [String: SSHRemoteFile]) -> SSHInstallPlan {
        var p = SSHInstallPlan(on: on)
        for t in tools {
            let path = relative(t.file)
            guard let f = files[path] else { p.problems.append(.init(tool: t.id, path: path, reason: "unread")); continue }
            if !f.exists && !on { p.unchanged.append(t.id); continue }
            guard !f.exists || f.text != nil, let root = AIHooks.parse(f.text ?? "") else { p.problems.append(.init(tool: t.id, path: path, reason: "format")); continue }
            if on && localCocaine(root) { p.problems.append(.init(tool: t.id, path: path, reason: "local")); continue }
            guard let new = AIHooks.edited(root, for: t, on: on) else { p.problems.append(.init(tool: t.id, path: path, reason: "format")); continue }
            if new == root && f.exists { p.unchanged.append(t.id); continue }
            let after = new.render() + "\n"
            if f.exists, after == f.text { p.unchanged.append(t.id); continue }
            let before = f.exists ? (f.text ?? "") : nil
            let diff = Diff.lines(old: before.map { lines($0) } ?? [], new: lines(after))
            p.changes.append(SSHFileChange(tool: t.id, toolName: t.name, path: path, before: before, beforeSHA: f.sha, after: after, diff: diff))
        }
        return p
    }

    static func lines(_ s: String) -> [String] {
        var l = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if l.last == "" { l.removeLast() }
        return l
    }

    /// The diff as shown: changed lines with two lines around them; longer unchanged runs become one "…" header.
    static func shown(_ diff: [DiffLine], context: Int = 2) -> [DiffLine] {
        let changed = diff.indices.filter { diff[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for i in changed { for j in max(0, i - context)...min(diff.count - 1, i + context) { keep.insert(j) } }
        var out: [DiffLine] = []
        var skipped = 0
        for (i, l) in diff.enumerated() {
            if keep.contains(i) {
                if skipped > 0 { out.append(DiffLine(kind: .header, text: "…")); skipped = 0 }
                out.append(l)
            } else { skipped += 1 }
        }
        if skipped > 0 { out.append(DiffLine(kind: .header, text: "…")) }
        return out
    }

    /// Which of a host's tools have Cocaine's (relay) hooks in the files read.
    static func hooksOn(files: [String: SSHRemoteFile]) -> [String] {
        AIHooks.remoteTools(home: home, claudeVersion: nil).compactMap { t in
            guard let f = files[relative(t.file)], f.exists, let root = AIHooks.parse(f.text ?? ""), AIHooks.installed(root), !localCocaine(root) else { return nil }
            return t.id
        }
    }

    /// The writes for a plan, in order, and the ones that undo them (for a rollback after a later write failed).
    struct Write: Equatable { var path: String; var old: String; var data: String?; var delete: Bool }
    static func writes(_ p: SSHInstallPlan) -> [(apply: Write, undo: Write)] {
        p.changes.map { c in
            let newSHA = SSHWire.sha256(Data(c.after.utf8))
            let apply = Write(path: c.path, old: c.beforeSHA, data: c.after, delete: false)
            let undo = c.before.map { Write(path: c.path, old: newSHA, data: $0, delete: false) } ?? Write(path: c.path, old: newSHA, data: nil, delete: true)
            return (apply, undo)
        }
    }

    static func body(_ w: Write, r: Int) -> [String: Any] {
        var b: [String: Any] = ["r": r, "path": w.path, "old": w.old]
        if w.delete { b["delete"] = true } else { b["data"] = Data((w.data ?? "").utf8).base64EncodedString() }
        return b
    }

    /// A relay's `file` reply as a file.
    static func file(_ o: [String: Any]) -> SSHRemoteFile? {
        guard o["ok"] as? Bool == true, let path = o["path"] as? String else { return nil }
        guard o["exists"] as? Bool == true else { return SSHRemoteFile(path: path, exists: false, text: nil, sha: "") }
        guard let b = (o["data"] as? String).flatMap({ Data(base64Encoded: $0) }), let sha = o["sha"] as? String,
              SSHWire.sha256(b) == sha else { return nil }
        return SSHRemoteFile(path: path, exists: true, text: String(data: b, encoding: .utf8), sha: sha)   // nil: not UTF-8, hands off
    }
}
