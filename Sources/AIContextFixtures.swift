// `--aicontext-fixture s|m|l|consent|pick|empty` for --render-island and --render-panel: the AI context module at each size and
// the two notch questions, with made-up items (memory only; renders run with memory-only settings and no files).

import AppKit

enum AIContextFixtures {
    static let names = ["s", "m", "l", "consent", "pick", "empty"]

    static func value(_ args: [String]) -> String? {
        guard let i = args.firstIndex(of: "--aicontext-fixture"), i + 1 < args.count else { return nil }
        guard names.contains(args[i + 1]) else {
            FileHandle.standardError.write(Data("unknown aicontext fixture \(args[i + 1]): \(names.joined(separator: ", "))\n".utf8)); exit(64)
        }
        return args[i + 1]
    }

    /// Before the island's model is made: the Status screen with the AI context module at the size asked.
    static func layout(_ args: [String]) {
        guard let name = value(args), ["s", "m", "l", "empty"].contains(name) else { return }
        var l = ScreenLayout.standard
        l.removeModule("usage", from: "status")
        l.addModule("aicontext", to: "status")
        switch name {
        case "s": l.setSize("batteries", in: "status", .m); l.setSize("aicontext", in: "status", .s)
        case "m": l.setSize("batteries", in: "status", .m); l.setSize("aicontext", in: "status", .m)
        default: l.removeModule("batteries", from: "status"); l.setSize("aicontext", in: "status", .l)
        }
        ScreenLayoutStore.shared.set(l)
    }

    /// The sample basket, tools and questions.
    static func apply(_ args: [String]) {
        guard let name = value(args) else { return }
        let c = AIContextCenter.shared
        c.update { $0.enabled = true }
        guard name != "empty" else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cocaine-aictx-render", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("crash-report.log"); try? Data("x".utf8).write(to: f)
        c.basket.add([(kind: "file", ref: f.path, title: ""),
                      (kind: "clip", ref: UUID().uuidString, title: "SELECT id, email FROM users WHERE created_at > now()"),
                      (kind: "text", ref: "Il cliente vuole la consegna entro venerdì, budget 4.000 €", title: "")])
        c.consent.record(MCPClientIdentity(name: "claude-code", program: "/usr/local/bin/claude"), .allow)
        c.consent.record(MCPClientIdentity(name: "Codex", program: "/opt/homebrew/bin/codex"), .deny)
        DialogCenter.shared.show = { _ in .island }
        switch name {
        case "consent":
            DialogCenter.shared.present(AIContextCenter.consentSpec("claude-code (claude)", count: 3)) { _ in }
        case "pick":
            let options = [AIContextCenter.Candidate(id: "a", kind: "clip", ref: "", title: "Traceback (most recent call last): File \"app.py\", line 42", symbol: "doc.text"),
                           AIContextCenter.Candidate(id: "b", kind: "clip", ref: "", title: "1280×720", symbol: "photo"),
                           AIContextCenter.Candidate(id: "c", kind: "file", ref: "", title: "crash-report.log", symbol: "doc"),
                           AIContextCenter.Candidate(id: "d", kind: "text", ref: "", title: "Note: deploy after 18:00", symbol: "text.alignleft")]
            let shown = options.map { o -> AIContextCenter.Candidate in var o = o; o.title = AIContextText.clean(o.title, 30); return o }   // as candidates() cuts them
            DialogCenter.shared.present(AIContextCenter.pickSpec("Codex", reason: "I need the stack trace you copied to find the bug", options: shown, picked: ["a", "c"])) { _ in }
        default: break
        }
    }
}
