// What a request from an AI shows in full before anything can be granted from the notch (Sources/AgentApprovals.swift reads
// the hook's input into these): a command, an edit as a coloured diff, every other field of the tool's input, a plan in
// Markdown, a question's options. Plus the review's own state (drafted answers, feedback, the page of a multi-question) and
// its keys (⌘Y / ⌘N / ⌘1–9 / ⌘↩, only while the island or the panel has the keyboard: never global). Pure where it can be.

import AppKit
import SwiftUI

/// What the user sends back: a decision and, for some, its text (a reason, feedback, the answers as JSON, an index).
struct ApprovalReply: Equatable {
    var decision: String
    var content: String? = nil
}

struct DiffLine: Equatable {
    enum Kind: Equatable { case context, add, remove, header }
    var kind: Kind
    var text: String
}

/// The whole of a tool's input, as the review shows it: nothing that matters is left out (or `truncated` says so).
struct ApprovalDetail: Equatable {
    struct Field: Equatable { var name: String; var value: String }
    var command: String? = nil          // Bash and the like: the command, whole, its lines as they are
    var file: String? = nil             // the file an edit or a write changes
    var diff: [DiffLine] = []
    var fields: [Field] = []            // every other key of the input
    var truncated = false               // something was too long to show: nothing can be granted from here

    var isEmpty: Bool { command == nil && file == nil && diff.isEmpty && fields.isEmpty }
    /// Shown lines, for VoiceOver and the size check.
    var lineCount: Int { (command.map { $0.split(separator: "\n", omittingEmptySubsequences: false).count } ?? 0) + diff.count
        + fields.reduce(0) { $0 + $1.value.split(separator: "\n", omittingEmptySubsequences: false).count } }

    static let maxLines = 4000
    static let maxChars = 400_000

    /// Text from another program made safe to show: line breaks and tabs kept, every other control character and the
    /// text-direction overrides (which can make code read differently from what runs) shown as a visible mark.
    static func visible(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.flatMap { u -> [Unicode.Scalar] in
            if u == "\n" { return [u] }
            if u == "\t" { return Array("    ".unicodeScalars) }
            if u == "\r" { return [] }
            if u.value < 32 || u.value == 127 || (0x202A...0x202E).contains(u.value) || (0x2066...0x2069).contains(u.value)
                || u.value == 0x200B || u.value == 0xFEFF { return ["\u{FFFD}"] }
            return [u]
        }))
    }

    /// A value as text: a string as it is, anything else as sorted JSON.
    static func text(_ v: Any) -> String {
        if let s = v as? String { return visible(s) }
        if let n = v as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue }
        guard JSONSerialization.isValidJSONObject(v) || v is [Any] || v is [String: Any],
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed]) else { return String(describing: v) }
        return visible(String(decoding: d, as: UTF8.self))
    }

    static func lines(_ s: String) -> [String] { s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

    /// The input of `tool` read whole: its command or diff, then every other field. Keys the presentation used are not repeated.
    static func make(tool: String, input args: [String: Any]) -> ApprovalDetail {
        var d = ApprovalDetail()
        var used: Set<String> = []
        let name = tool
        if let c = args["command"] as? String { d.command = visible(c); used.insert("command") }
        switch name {
        case "Edit":
            if let f = args["file_path"] as? String { d.file = visible(f); used.insert("file_path") }
            if let o = args["old_string"] as? String, let n = args["new_string"] as? String {
                d.diff = Diff.lines(old: lines(visible(o)), new: lines(visible(n)))
                used.formUnion(["old_string", "new_string"])
            }
        case "MultiEdit":
            if let f = args["file_path"] as? String { d.file = visible(f); used.insert("file_path") }
            if let edits = args["edits"] as? [[String: Any]] {
                for (i, e) in edits.enumerated() {
                    d.diff.append(DiffLine(kind: .header, text: String(format: L("Change %d of %d"), i + 1, edits.count)
                                           + (e["replace_all"] as? Bool == true ? " · " + L("every occurrence") : "")))
                    d.diff += Diff.lines(old: lines(visible(e["old_string"] as? String ?? "")), new: lines(visible(e["new_string"] as? String ?? "")))
                    let other = e.keys.filter { !["old_string", "new_string", "replace_all"].contains($0) }.sorted()
                    for k in other { d.diff.append(DiffLine(kind: .header, text: "\(k): \(text(e[k]!))")) }
                }
                used.insert("edits")
            }
        case "Write":
            if let f = args["file_path"] as? String { d.file = visible(f); used.insert("file_path") }
            if let c = args["content"] as? String { d.diff = lines(visible(c)).map { DiffLine(kind: .add, text: $0) }; used.insert("content") }
        case "NotebookEdit":
            if let f = args["notebook_path"] as? String { d.file = visible(f); used.insert("notebook_path") }
            if let c = args["new_source"] as? String { d.diff = lines(visible(c)).map { DiffLine(kind: .add, text: $0) }; used.insert("new_source") }
        default: break
        }
        for k in args.keys.sorted() where !used.contains(k) && !k.hasPrefix("_cocaine") {
            d.fields.append(Field(name: visible(k), value: text(args[k]!)))
        }
        let chars = (d.command?.count ?? 0) + d.diff.reduce(0) { $0 + $1.text.count } + d.fields.reduce(0) { $0 + $1.value.count }
        if d.lineCount > maxLines || chars > maxChars { d.truncated = true }
        return d
    }
}

/// A line diff (longest common subsequence) for an edit's old and new text; past a size it lists the old lines then the new.
enum Diff {
    static let maxCells = 250_000

    static func lines(old: [String], new: [String]) -> [DiffLine] {
        let n = old.count, m = new.count
        guard n > 0 || m > 0 else { return [] }
        guard n * m <= maxCells, n > 0, m > 0 else {
            return old.map { DiffLine(kind: .remove, text: $0) } + new.map { DiffLine(kind: .add, text: $0) }
        }
        var t = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                t[i][j] = old[i] == new[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] { out.append(DiffLine(kind: .context, text: old[i])); i += 1; j += 1 }
            else if j < m, i == n || t[i][j + 1] >= t[i + 1][j] { out.append(DiffLine(kind: .add, text: new[j])); j += 1 }
            else { out.append(DiffLine(kind: .remove, text: old[i])); i += 1 }
        }
        return out
    }
}

/// One of AskUserQuestion's questions. `question` is kept exactly as the tool sent it: it is the key of its answer.
struct AskQuestion: Equatable {
    struct Option: Equatable { var label: String; var description: String? }
    var question: String
    var header: String?
    var options: [Option]
    var multiSelect: Bool

    static let maxQuestions = 4
    static let maxOptions = 9

    /// The questions of a tool input, or nil when they aren't the documented shape (then the terminal asks).
    static func parse(_ input: [String: Any]) -> [AskQuestion]? {
        guard let raw = input["questions"] as? [[String: Any]], (1...maxQuestions).contains(raw.count) else { return nil }
        var out: [AskQuestion] = []
        for q in raw {
            guard let text = q["question"] as? String, !text.isEmpty, text.count <= 2000,
                  let opts = q["options"] as? [[String: Any]], opts.count <= 20 else { return nil }
            let options = opts.compactMap { o -> Option? in
                guard let l = o["label"] as? String, !l.isEmpty, l.count <= 500 else { return nil }
                return Option(label: l, description: (o["description"] as? String).map { ApprovalRequest.clean($0, 300) })
            }
            guard options.count == opts.count else { return nil }
            out.append(AskQuestion(question: text, header: (q["header"] as? String).map { ApprovalRequest.clean($0, 40) },
                                   options: options, multiSelect: q["multiSelect"] as? Bool ?? false))
        }
        guard Set(out.map(\.question)).count == out.count else { return nil }      // answers are keyed by the text
        return out
    }

    /// The answer's text for these picks (labels joined with ", " for a multi-select, as the docs say) and/or the typed one.
    static func answer(picked: [String], custom: String) -> String? {
        let typed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = picked + (typed.isEmpty ? [] : [typed])
        return all.isEmpty ? nil : all.joined(separator: ", ")
    }
}

/// The "Always allow" choices Claude Code offers with a request (`permission_suggestions`), in words.
enum PermissionSuggestion {
    static func describe(_ s: [String: Any]) -> String? {
        if let label = s["label"] as? String, !label.isEmpty { return ApprovalRequest.clean(label, 120) }
        let dest: String
        switch s["destination"] as? String {
        case "session": dest = L("this session")
        case "localSettings": dest = L("this project, only for you")
        case "projectSettings": dest = L("this project")
        case "userSettings": dest = L("every project")
        default: dest = ""
        }
        switch s["type"] as? String {
        case "addRules":
            guard (s["behavior"] as? String ?? "allow") == "allow", let rules = s["rules"] as? [[String: Any]], !rules.isEmpty else { return nil }
            let r = rules.prefix(3).compactMap { r -> String? in
                guard let t = r["toolName"] as? String else { return nil }
                return (r["ruleContent"] as? String).map { "\(t)(\($0))" } ?? t
            }.joined(separator: ", ")
            return ApprovalRequest.clean(dest.isEmpty ? r : String(format: L("%@ in %@"), r, dest), 160)
        case "setMode":
            guard let mode = s["mode"] as? String, mode != "bypassPermissions" else { return nil }
            return ApprovalRequest.clean(String(format: L("Mode %@"), mode) + (dest.isEmpty ? "" : " · " + dest), 120)
        case "addDirectories":
            let dirs = (s["directories"] as? [String] ?? []).prefix(2).joined(separator: ", ")
            return dirs.isEmpty ? nil : ApprovalRequest.clean(String(format: L("Folder %@"), dirs), 160)
        default: return nil
        }
    }
}

// MARK: - The review's own state, shared by the island and the panel

final class ApprovalReviewModel: ObservableObject {
    static let shared = ApprovalReviewModel()

    /// Requests the user put aside ("Later"): the island shows its pages again until another one comes.
    @Published var later: Set<String> = []
    /// The request opened in the panel's list.
    @Published var expanded: String?
    /// Which request the island's review page shows (nil = the first one waiting that isn't put aside).
    @Published var selected: String?
    /// Typing feedback (a plan, a question) or a reason (a deny) for this request.
    @Published var writing: String?
    @Published var text = ""
    /// A question's picks, typed answers and page, per request.
    @Published var picks: [String: [Int: [String]]] = [:]
    @Published var custom: [String: [Int: String]] = [:]
    @Published var page: [String: Int] = [:]

    var reply: (_ id: String, _ reply: ApprovalReply) -> Void = { _, _ in }
    var release: (_ id: String) -> Void = { _ in }
    var focus: (_ origin: AgentOrigin?, _ name: String) -> Void = { _, _ in }

    /// The request the island's review page shows.
    func current(in pending: [ApprovalRequest]) -> ApprovalRequest? {
        let open = pending.filter { $0.answerable && !later.contains($0.id) }
        return open.first { $0.id == selected } ?? open.first
    }

    func open(_ id: String) { later.remove(id); selected = id; expanded = id }
    func putAside(_ id: String) { later.insert(id); if selected == id { selected = nil }; if expanded == id { expanded = nil }; endWriting() }
    func endWriting() { writing = nil; text = "" }

    /// Forget what belonged to requests that are gone.
    func prune(keeping ids: Set<String>) {
        later = later.intersection(ids)
        if let s = selected, !ids.contains(s) { selected = nil }
        if let e = expanded, !ids.contains(e) { expanded = nil }
        if let w = writing, !ids.contains(w) { endWriting() }
        picks = picks.filter { ids.contains($0.key) }; custom = custom.filter { ids.contains($0.key) }; page = page.filter { ids.contains($0.key) }
    }

    func toggle(_ r: ApprovalRequest, question q: Int, label: String) {
        guard r.questions.indices.contains(q) else { return }
        var p = picks[r.id] ?? [:]
        var list = p[q] ?? []
        if r.questions[q].multiSelect {
            if let i = list.firstIndex(of: label) { list.remove(at: i) } else { list.append(label) }
        } else {
            list = list == [label] ? [] : [label]
        }
        p[q] = list
        picks[r.id] = p
    }

    func isPicked(_ r: ApprovalRequest, _ q: Int, _ label: String) -> Bool { picks[r.id]?[q]?.contains(label) ?? false }

    /// The answers of every question as AskUserQuestion's `answers`, or nil while one is still unanswered. Pure.
    static func answers(_ r: ApprovalRequest, picks: [Int: [String]], custom: [Int: String]) -> [String: String]? {
        guard r.kind == .question, !r.questions.isEmpty else { return nil }
        var out: [String: String] = [:]
        for (i, q) in r.questions.enumerated() {
            let picked = q.options.map(\.label).filter { (picks[i] ?? []).contains($0) }      // in the options' order
            guard let a = AskQuestion.answer(picked: picked, custom: q.multiSelect || picked.isEmpty ? (custom[i] ?? "") : "") else { return nil }
            out[q.question] = a
        }
        return out
    }

    func answers(_ r: ApprovalRequest) -> [String: String]? { Self.answers(r, picks: picks[r.id] ?? [:], custom: custom[r.id] ?? [:]) }

    static func answerContent(_ a: [String: String]) -> String? {
        (try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Sends the answers of a question; false while one is missing.
    @discardableResult
    func submitAnswers(_ r: ApprovalRequest) -> Bool {
        guard let a = answers(r), let c = Self.answerContent(a) else { return false }
        Haptic.tap(.generic)
        reply(r.id, ApprovalReply(decision: "answer", content: c))
        return true
    }

    /// Sends the typed feedback (plan, question) or reason (a deny). An empty deny reason is a plain deny.
    func submitWriting(_ r: ApprovalRequest) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch r.kind {
        case .permission:
            reply(r.id, ApprovalReply(decision: "deny", content: t.isEmpty ? nil : String(t.prefix(ApprovalRequest.maxReason))))
        case .plan, .question:
            guard !t.isEmpty else { return }
            reply(r.id, ApprovalReply(decision: "feedback", content: String(t.prefix(ApprovalRequest.maxFeedback))))
        case .elicitation: return
        }
        Haptic.tap(.generic)
        endWriting()
    }

    func startWriting(_ id: String) { if writing != id { text = "" }; writing = id }
}

/// The review's keys: what a ⌘-key does to the request shown. Only from a local key monitor (the island) or the panel's own
/// buttons, i.e. while Cocaine has the keyboard; never a global shortcut (other apps' ⌘Y/⌘N stay theirs).
enum ApprovalKeys {
    enum Command: Equatable { case grant, deny, option(Int), submit, later }

    static func command(_ code: UInt16, chars: String?, flags: NSEvent.ModifierFlags) -> Command? {
        let mods = flags.intersection([.command, .option, .control, .shift])
        guard mods == .command else { return nil }
        switch code {
        case 16: return .grant                    // Y (the key's position, so ⌘Y on any layout that has Y there)
        case 45: return .deny                     // N
        case 36, 76: return .submit               // Return / Enter
        case 37: return .later                    // L
        default: break
        }
        if let c = chars?.first, let d = c.wholeNumberValue, (1...9).contains(d), chars?.count == 1 { return .option(d - 1) }
        let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]   // the number row
        return digits[code].map { .option($0 - 1) }
    }

    /// What the command does to `r`: the reply to send, or a change of the review's state (nil = nothing to do).
    enum Effect: Equatable { case send(ApprovalReply), toggle(question: Int, label: String), write, submitWriting, submitAnswers, putAside }

    static func effect(_ c: Command, _ r: ApprovalRequest, page: Int, writing: Bool) -> Effect? {
        switch c {
        case .later: return .putAside
        case .submit:
            if writing { return .submitWriting }
            return r.kind == .question ? .submitAnswers : nil
        case .grant:
            guard r.allowable, !writing else { return nil }
            switch r.kind {
            case .permission: return .send(ApprovalReply(decision: "allow"))
            case .plan: return .send(ApprovalReply(decision: "approve"))
            case .question: return .submitAnswers
            case .elicitation: return r.choices.first.flatMap { $0.decision == "decline" ? nil : .send(ApprovalReply(decision: $0.decision, content: $0.content)) }
            }
        case .deny:
            guard !writing else { return nil }
            switch r.kind {
            case .permission: return .send(ApprovalReply(decision: "deny"))
            case .plan, .question: return .write
            case .elicitation: return .send(ApprovalReply(decision: "decline"))
            }
        case .option(let i):
            guard !writing else { return nil }
            switch r.kind {
            case .question:
                guard r.questions.indices.contains(page), r.questions[page].options.indices.contains(i) else { return nil }
                return .toggle(question: page, label: r.questions[page].options[i].label)
            case .elicitation:
                guard r.choices.indices.contains(i) else { return nil }
                return .send(ApprovalReply(decision: r.choices[i].decision, content: r.choices[i].content))
            case .permission:
                guard r.allowable, r.suggestions.indices.contains(i) else { return nil }
                return .send(ApprovalReply(decision: "always", content: String(i)))
            case .plan:
                return i == 0 && r.allowable ? .send(ApprovalReply(decision: "approve"))
                    : i == 1 && r.allowable && r.acceptEdits ? .send(ApprovalReply(decision: "approve-edits")) : nil
            }
        }
    }

    /// Runs a key on the review model (the island's key monitor). True when it was used.
    static func handle(_ code: UInt16, chars: String?, flags: NSEvent.ModifierFlags, request r: ApprovalRequest?, model m: ApprovalReviewModel) -> Bool {
        guard let r, let c = command(code, chars: chars, flags: flags),
              let e = effect(c, r, page: m.page[r.id] ?? 0, writing: m.writing == r.id) else { return false }
        switch e {
        case .send(let reply): Haptic.tap(.generic); m.reply(r.id, reply)
        case .toggle(let q, let label): Haptic.tap(.alignment); m.toggle(r, question: q, label: label)
        case .write: m.startWriting(r.id)
        case .submitWriting: m.submitWriting(r)
        case .submitAnswers: return m.submitAnswers(r)
        case .putAside: m.putAside(r.id)
        }
        return true
    }
}
