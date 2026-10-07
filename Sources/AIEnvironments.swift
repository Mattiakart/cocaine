// AI environments: every AI tool, app and web chat Cocaine knows, what it can really detect in each one (the capability
// matrix, printed by `--ai-environments matrix` for docs/ai-integrations.*.md), which environment a hook, a process or a
// browser tab belongs to, and the safe deep links back into a session. Pure data and pure functions; the detectors that use
// them are in Sources/AgentDetectors.swift, the board they feed in Sources/AgentIngest.swift.

import Foundation

enum AIKind: String, CaseIterable { case cli, ide, desktop, web }

/// What can be known about a session (the columns of the matrix).
enum AICap: Int, CaseIterable {
    case open, working, done, needsYou, ended, goBack
    var title: String {
        switch self {
        case .open: return "Session open"
        case .working: return "Processing"
        case .done: return "Response completed"
        case .needsYou: return "Needs you"
        case .ended: return "Activity ended"
        case .goBack: return "Open the session"
        }
    }
    var symbol: String {
        switch self {
        case .open: return "power"
        case .working: return "sparkles"
        case .done: return "checkmark.circle"
        case .needsYou: return "hand.raised"
        case .ended: return "stop.circle"
        case .goBack: return "arrow.uturn.left"
        }
    }
}

/// How well: an official mechanism, a heuristic, impossible, or documented but never seen live on a Mac this was built on.
enum AISupport: Character {
    case supported = "S", partial = "P", none = "N", unverified = "U"
    var word: String {
        switch self { case .supported: return "Supported"; case .partial: return "Partial"; case .none: return "Not possible"; case .unverified: return "Unverified" }
    }
}

/// The ways Cocaine learns about a session there.
enum AIMethod: String, CaseIterable {
    case hook          // the tool's own documented hooks (or plugin), which Cocaine writes into its config
    case stateFile     // a local state file the tool keeps (Claude Code's ~/.claude/sessions/<pid>.json)
    case process       // the CLI's process: started, still running, gone
    case app           // the app running or quitting (NSWorkspace)
    case browserTab    // a chat site's tab in a browser (AppleScript, the address only; opt-in)
    case manual        // the tool can run a command when it finishes, set up by hand (README)
}

struct AIEnvironment: Equatable {
    let id: String
    let name: String
    let kind: AIKind
    var hookTool: String? = nil            // AIHooks tool id whose switch connects it
    var bundleIDs: [String] = []           // the app (desktop or IDE); a trailing "*" matches a prefix
    var executables: [String] = []         // CLI process names that mean an interactive session (Sources/AgentDetectors.swift)
    var hosts: [String] = []               // web chat: host, or host + path prefix ("github.com/copilot")
    var methods: [AIMethod] = []
    /// open, working, done, needs you, ended, go back: S(upported) P(artial) N(ot possible) U(nverified).
    var matrix: String
    /// Seen working end to end on a real session (hooks firing, the row on the board, going back) on the Mac this was built on.
    var liveVerified = false

    func support(_ c: AICap) -> AISupport {
        let chars = Array(matrix)
        return c.rawValue < chars.count ? AISupport(rawValue: chars[c.rawValue]) ?? .none : .none
    }
    func matchesBundle(_ id: String) -> Bool {
        bundleIDs.contains { $0.hasSuffix("*") ? id.hasPrefix(String($0.dropLast())) : $0 == id }
    }
}

enum AIEnvironments {
    static let claudeDesktop = "com.anthropic.claudefordesktop"
    static let codexApp = "com.openai.codex"          // /Applications/ChatGPT.app (the ChatGPT app with Codex), CFBundleURLSchemes codex
    static let chatGPTLegacy = "com.openai.chat"

    /// Most used first. Evidence for every cell is in docs/ai-integrations.en.md.
    static let all: [AIEnvironment] = [
        .init(id: "claude-code", name: "Claude Code", kind: .cli, hookTool: "claude", methods: [.hook, .stateFile],
              matrix: "SSSSSS", liveVerified: true),
        .init(id: "claude-desktop-code", name: "Claude Desktop · Code", kind: .desktop, hookTool: "claude", bundleIDs: [claudeDesktop],
              methods: [.hook, .stateFile, .app], matrix: "SSSUUP"),
        .init(id: "cowork", name: "Claude Cowork", kind: .desktop, bundleIDs: [claudeDesktop], methods: [.app], matrix: "PNNNPP"),
        .init(id: "claude-desktop", name: "Claude Desktop (chat)", kind: .desktop, bundleIDs: [claudeDesktop], methods: [.app], matrix: "PNNNPP"),
        .init(id: "codex-cli", name: "Codex CLI", kind: .cli, hookTool: "codex", executables: ["codex"], methods: [.hook, .process],
              matrix: "SSSSSS", liveVerified: true),
        .init(id: "codex-app", name: "ChatGPT · Codex", kind: .desktop, hookTool: "codex", bundleIDs: [codexApp], methods: [.hook, .app],
              matrix: "SSSSPS"),
        .init(id: "codex-ide", name: "Codex IDE extension", kind: .ide, hookTool: "codex", methods: [.hook], matrix: "SSSSPP"),
        .init(id: "chatgpt-desktop", name: "ChatGPT (chat)", kind: .desktop, bundleIDs: [chatGPTLegacy], methods: [.app], matrix: "PNNNPP"),
        .init(id: "gemini-cli", name: "Gemini CLI", kind: .cli, hookTool: "gemini", methods: [.hook], matrix: "SSSSSS"),
        .init(id: "antigravity", name: "Antigravity", kind: .ide, bundleIDs: ["com.google.antigravity"], methods: [.app], matrix: "PNNNPP"),
        .init(id: "copilot-cli", name: "Copilot CLI", kind: .cli, hookTool: "copilot", methods: [.hook], matrix: "SSSUSS"),
        .init(id: "copilot-vscode", name: "Copilot in VS Code", kind: .ide, hookTool: "copilot",
              bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"], methods: [.hook, .app], matrix: "UUUNUP"),
        .init(id: "cursor", name: "Cursor", kind: .ide, hookTool: "cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"],
              executables: ["cursor-agent"], methods: [.hook, .app, .process], matrix: "SSSNSP"),
        .init(id: "windsurf", name: "Windsurf", kind: .ide, hookTool: "windsurf", bundleIDs: ["com.exafunction.windsurf"],
              methods: [.hook, .app], matrix: "PSSNPP"),
        .init(id: "kiro", name: "Kiro", kind: .ide, bundleIDs: ["dev.kiro.desktop"], executables: ["kiro-cli"], methods: [.app, .process],
              matrix: "PNNNPP"),
        .init(id: "zed", name: "Zed", kind: .ide, bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"], methods: [.app], matrix: "PNNNPP"),
        .init(id: "jetbrains", name: "JetBrains AI / Junie", kind: .ide, bundleIDs: ["com.jetbrains.*"], methods: [.app], matrix: "PNNNPP"),
        .init(id: "warp", name: "Warp", kind: .ide, bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"], methods: [.app], matrix: "PNNNPP"),
        .init(id: "aider", name: "Aider", kind: .cli, methods: [.manual], matrix: "NNPPNP"),
        .init(id: "cline", name: "Cline", kind: .ide, methods: [.manual], matrix: "NPPNNP"),
        .init(id: "goose", name: "Goose", kind: .cli, executables: ["goose"], methods: [.process], matrix: "PNNNPP"),
        .init(id: "amp", name: "Amp", kind: .cli, matrix: "NNNNNN"),
        .init(id: "opencode", name: "OpenCode", kind: .cli, hookTool: "opencode", executables: ["opencode"], methods: [.hook, .process],
              matrix: "PNSSPS"),
        .init(id: "qwen", name: "Qwen Code", kind: .cli, hookTool: "qwen", methods: [.hook], matrix: "NSSUNS"),
        .init(id: "perplexity", name: "Perplexity", kind: .desktop, bundleIDs: ["ai.perplexity.macv3", "ai.perplexity.mac"], methods: [.app],
              matrix: "PNNNPP"),
        .init(id: "ms-copilot", name: "Microsoft Copilot", kind: .desktop, bundleIDs: ["com.microsoft.copilot-mac", "com.microsoft.m365copilot"],
              methods: [.app], matrix: "PNNNPP"),
        .init(id: "web-claude", name: "Claude (web)", kind: .web, hosts: ["claude.ai"], methods: [.browserTab], matrix: "PNNNPS"),
        .init(id: "web-chatgpt", name: "ChatGPT (web)", kind: .web, hosts: ["chatgpt.com", "chat.openai.com"], methods: [.browserTab], matrix: "PNNNPS"),
        .init(id: "web-gemini", name: "Gemini (web)", kind: .web, hosts: ["gemini.google.com"], methods: [.browserTab], matrix: "PNNNPS"),
        .init(id: "web-copilot", name: "Copilot (web)", kind: .web, hosts: ["copilot.microsoft.com", "github.com/copilot"], methods: [.browserTab],
              matrix: "PNNNPS"),
        .init(id: "web-perplexity", name: "Perplexity (web)", kind: .web, hosts: ["www.perplexity.ai", "perplexity.ai"], methods: [.browserTab],
              matrix: "PNNNPS"),
        .init(id: "web-lechat", name: "Le Chat (web)", kind: .web, hosts: ["chat.mistral.ai"], methods: [.browserTab], matrix: "PNNNPS"),
        .init(id: "web-deepseek", name: "DeepSeek (web)", kind: .web, hosts: ["chat.deepseek.com"], methods: [.browserTab], matrix: "PNNNPS"),
        .init(id: "web-grok", name: "Grok (web)", kind: .web, hosts: ["grok.com"], methods: [.browserTab], matrix: "PNNNPS"),
    ]

    static func env(_ id: String) -> AIEnvironment? { all.first { $0.id == id } }

    /// Environments where one process runs one session at a time: a new session id on the same process replaced the old one
    /// (Claude Code's /clear). The ChatGPT app and IDE extensions run many threads in one process, so never by process there.
    static let oneSessionPerProcess: Set<String> = ["claude-code", "codex-cli", "gemini-cli", "copilot-cli", "opencode", "qwen", "goose", "kiro"]

    // MARK: classifying

    /// The environment a hook's event belongs to: its tool (the alert's `from`), refined by the app it runs in.
    static func forHook(from: String, origin: AgentOrigin?) -> String {
        let app = origin.flatMap { AgentFocus.appID($0) }
        let ide = app.map { AgentFocus.vscodeFamily.contains($0) } ?? false
        switch from {
        case "Claude Code": return app == claudeDesktop ? "claude-desktop-code" : "claude-code"
        case "Codex": return app == codexApp ? "codex-app" : ide ? "codex-ide" : "codex-cli"
        case "GitHub Copilot": return ide ? "copilot-vscode" : "copilot-cli"
        case "Gemini CLI": return "gemini-cli"
        case "Cursor": return "cursor"
        case "Windsurf": return "windsurf"
        case "Qwen Code": return "qwen"
        case "OpenCode": return "opencode"
        default: return all.first { $0.name == from }?.id ?? "other"
        }
    }

    /// The environment of a desktop or IDE app.
    static func forBundle(_ id: String) -> [AIEnvironment] { all.filter { $0.matchesBundle(id) } }

    /// The environment of a process that may be an interactive CLI session: its name and executable path. Apps' own helpers
    /// (the ChatGPT app's embedded Codex, Claude Desktop's Claude Code) are not sessions of their own: nil.
    static func forProcess(name: String, path: String?) -> String? {
        if let path, path.contains(".app/Contents/") || path.contains("/Application Support/") { return nil }
        return all.first { $0.executables.contains(name) }?.id
    }

    // MARK: web chats

    /// The browsers whose tabs can be read and selected (Safari's and Chromium's scripting dictionaries; Arc's is its own).
    static let safari = "com.apple.Safari"
    static let chromium: [String] = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium"]
    static let arc = "company.thebrowser.Browser"
    static var browsers: [String] { [safari] + chromium + [arc] }

    /// Which chat a tab's address belongs to (https only, a known host and path prefix), or nil.
    static func forURL(_ s: String) -> String? {
        guard let u = URLComponents(string: s), u.scheme == "https", let host = u.host?.lowercased() else { return nil }
        let path = u.path
        return all.first { e in
            e.kind == .web && e.hosts.contains { h in
                let parts = h.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts[0] == host else { return false }
                return parts.count == 1 || path == "/" + parts[1] || path.hasPrefix("/" + parts[1] + "/")
            }
        }?.id
    }

    /// A link Cocaine may open or match: a known chat site's https address, or a Codex thread (codex://threads/<uuid>), with
    /// none of the characters that could break out of an AppleScript string. Anything else: nil.
    static func safeChatURL(_ s: String) -> String? {
        guard s.count <= 500, !s.contains("\""), !s.contains("\\"), !s.unicodeScalars.contains(where: { $0.value < 33 || $0.value > 126 }) else { return nil }
        if s.range(of: #"^codex://threads/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil {
            return s
        }
        return forURL(s) != nil ? s : nil
    }

    /// The documented link to a session inside its app, when there is one: the ChatGPT app opens a Codex thread by its id
    /// (learn.chatgpt.com/docs/reference/commands: codex://threads/<thread-id>; the hook's session_id is that id).
    static func deepLink(env: String, session: String?) -> String? {
        guard env == "codex-app", let s = session else { return nil }
        return safeChatURL("codex://threads/" + s)
    }

    /// The address prefixes a scan keeps, as AppleScript `starts with` tests (the script itself drops every other tab, so no
    /// other address ever leaves the browser).
    static var scanPrefixes: [String] {
        all.filter { $0.kind == .web }.flatMap(\.hosts).map { "https://" + $0 + ($0.contains("/") ? "" : "/") }
    }

    /// AppleScript listing the chat tabs of `browser` (one address per line). nil for a browser it doesn't know.
    static func scanScript(_ browser: String) -> String? {
        let test = scanPrefixes.map { "u starts with \"\($0)\"" }.joined(separator: " or ")
        let tabs: String
        if browser == safari || chromium.contains(browser) || browser == arc { tabs = "tabs of w" } else { return nil }
        return """
        set out to ""
        tell application id "\(browser)"
            repeat with w in windows
                repeat with t in \(tabs)
                    set u to URL of t
                    if u is not missing value then
                        if \(test) then set out to out & u & linefeed
                    end if
                end repeat
            end repeat
        end tell
        return out
        """
    }

    /// The scan's answer, cleaned: chat addresses only (each one checked again), once each.
    static func parseScan(_ text: String) -> [(env: String, url: String)] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let u = String(line).trimmingCharacters(in: .whitespaces)
            guard let safe = safeChatURL(u), let env = forURL(safe), seen.insert(safe).inserted else { return nil }
            return (env, safe)
        }
    }

    /// AppleScript that selects the tab whose address starts with `url` and brings its window forward.
    static func tabScript(browser: String, url: String) -> String? {
        guard let url = safeChatURL(url), url.hasPrefix("https://") else { return nil }
        let select: String
        if browser == safari { select = "set current tab of w to t" }
        else if chromium.contains(browser) { select = "set active tab index of w to i" }
        else if browser == arc { select = "tell t to select" }
        else { return nil }
        return """
        tell application id "\(browser)"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    set u to URL of t
                    if u is not missing value and u starts with "\(url)" then
                        \(select)
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    // MARK: the AI tab's "Detected environments" card

    struct CardRow: Equatable, Identifiable {
        enum Kind: Equatable { case hook(String), app, web }
        var id: String
        var kind: Kind
        var title: String
        var env: String              // whose capabilities the row shows
        var also: [String] = []      // other environments the same switch covers that are on this Mac
        var running = false
    }

    /// One row per hook tool on this Mac (its switch; the app environments it also covers named under it), one per app or CLI
    /// without hooks that is installed or running (environments of the same app with the same capabilities share a row), and
    /// the web chats' row last.
    static func cardRows(hookTools: [(id: String, name: String, installed: Bool)], installed: Set<String>, running: Set<String>) -> [CardRow] {
        var rows: [CardRow] = []
        for t in hookTools where t.installed {
            let mine = all.filter { $0.hookTool == t.id }
            guard let primary = mine.first else { continue }
            let also = mine.dropFirst().filter { installed.contains($0.id) || running.contains($0.id) }.map(\.name)
            rows.append(CardRow(id: "hook-" + t.id, kind: .hook(t.id), title: t.name, env: primary.id, also: also,
                                running: mine.contains { running.contains($0.id) }))
        }
        var groups: [(key: String, envs: [AIEnvironment])] = []
        for e in all where e.hookTool == nil && e.kind != .web && (installed.contains(e.id) || running.contains(e.id)) {
            let key = e.bundleIDs.joined(separator: ",") + "#" + e.matrix
            if let i = groups.firstIndex(where: { $0.key == key && !e.bundleIDs.isEmpty }) { groups[i].envs.append(e) }
            else { groups.append((key, [e])) }
        }
        for g in groups {
            rows.append(CardRow(id: "app-" + g.envs[0].id, kind: .app, title: g.envs.map(\.name).joined(separator: " / "), env: g.envs[0].id,
                                running: g.envs.contains { running.contains($0.id) }))
        }
        rows.append(CardRow(id: "web", kind: .web, title: "Web chats", env: "web-chatgpt"))
        return rows
    }

    // MARK: the matrix as Markdown (docs/ai-integrations.*.md)

    static func markdownMatrix(italian: Bool = false) -> String {
        let marks: [AISupport: String] = italian
            ? [.supported: "Supportato", .partial: "Parziale", .none: "Non possibile", .unverified: "Non verificato"]
            : [.supported: "Supported", .partial: "Partial", .none: "Not possible", .unverified: "Unverified"]
        let heads = italian
            ? ["Ambiente", "Tipo", "Sessione aperta", "Elaborazione", "Risposta completata", "Richiesta di intervento", "Fine attività", "Apri la sessione", "Provato dal vivo"]
            : ["Environment", "Kind", "Session open", "Processing", "Response completed", "Needs you", "Activity ended", "Open the session", "Tried live"]
        var lines = ["| " + heads.joined(separator: " | ") + " |", "|" + String(repeating: "---|", count: heads.count)]
        for e in all {
            let cells = AICap.allCases.map { marks[e.support($0)] ?? "" }
            let live = e.liveVerified ? (italian ? "sì" : "yes") : "no"
            lines.append("| " + ([e.name, e.kind.rawValue] + cells + [live]).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// `--ai-environments matrix [--it]`, run from main.swift: the capability matrix as Markdown, for the docs.
func cliAIEnvironments() {
    let args = CommandLine.arguments
    guard args.count >= 3, args[2] == "matrix" else {
        FileHandle.standardError.write(Data("usage: --ai-environments matrix [--it]\n".utf8)); exit(64)
    }
    print(AIEnvironments.markdownMatrix(italian: args.contains("--it")), terminator: "")
    exit(0)
}
