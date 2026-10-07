// The user's own ways back to a session (Application Support/Cocaine/jump-rules.json), for apps Cocaine can't steer by
// itself: when a session runs in the app with `bundleIdentifier`, a click opens `url` with the session's details filled in.
//
//   { "rules": [ { "name": "My editor", "bundleIdentifier": "com.example.Editor",
//                  "url": "example-editor://open?folder={cwd}&session={session_id}" } ] }
//
// Placeholders: {session_id} {cwd} {tty} {pid} {bundle_id} {tmux_pane}, each percent-encoded; a rule whose value is missing
// for a session is skipped (never an empty one). Only https links, and links of a scheme that opens that very app, are
// allowed: never file:, javascript:, a script or shortcut runner, or Cocaine's own links. The file is the user's own (0600 in
// Cocaine's private folder): nothing else can add rules.

import AppKit

enum JumpRules {
    struct Rule: Equatable {
        var name: String
        var app: String
        var template: String

        static let placeholders = ["session_id", "cwd", "tty", "pid", "bundle_id", "tmux_pane"]

        /// The link for a session, or nil when a value it needs is missing.
        func url(for o: AgentOrigin, session: String? = nil) -> String? {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
            var out = template
            let values: [String: String?] = ["session_id": session ?? o.termSession, "cwd": o.cwd, "tty": o.tty, "pid": o.pid.map(String.init),
                                             "bundle_id": AgentFocus.appID(o), "tmux_pane": o.tmuxPane]
            for p in Self.placeholders where out.contains("{\(p)}") {
                guard let v = values[p] ?? nil, !v.isEmpty, let e = v.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
                out = out.replacingOccurrences(of: "{\(p)}", with: e)
            }
            return out
        }
    }

    struct Status: Equatable {
        var exists = false
        var rules = 0
        var errors: [String] = []
    }

    static var file: URL { AgentPaths.support().appendingPathComponent("jump-rules.json") }

    /// Schemes never allowed, whatever app they would open.
    static let blocked: Set<String> = ["file", "javascript", "data", "cocaine", "about", "applescript", "shortcuts", "x-apple-helpbook",
                                       "help", "prefs", "x-apple.systempreferences", "ftp", "smb", "afp", "vnc", "ssh", "telnet", "http",
                                       "mailto", "sms", "tel", "facetime", "facetime-audio", "itms", "itms-apps", "macappstore", "x-callback-url"]

    /// A template's scheme as written, lowercased; nil if it hasn't a valid one.
    static func scheme(_ template: String) -> String? {
        guard let r = template.range(of: #"^[A-Za-z][A-Za-z0-9+.-]{0,30}:"#, options: .regularExpression) else { return nil }
        return template[r].dropLast().lowercased()
    }

    /// Checks one rule as written in the file; the reason it is refused, or nil.
    static func problem(name: String?, app: String?, template: String?) -> String? {
        guard let app, app.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,99}$"#, options: .regularExpression) != nil else { return L("a valid bundleIdentifier is missing") }
        guard let t = template, !t.isEmpty, t.count <= 500, !t.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }) else {
            return L("the url is missing, too long or has spaces")
        }
        guard let s = scheme(t), !blocked.contains(s), !s.hasPrefix("x-apple") else { return L("this kind of link is not allowed") }
        let used = t.matches(of: #/\{([a-z_]+)\}/#).map { String($0.output.1) }
        if let bad = used.first(where: { !Rule.placeholders.contains($0) }) { return String(format: L("unknown placeholder {%@}"), bad) }
        if (name?.count ?? 0) > 60 { return L("the name is too long") }
        return nil
    }

    /// Reads and checks the rules (at most 20). Pure apart from reading the file.
    static func parse(_ data: Data) -> (rules: [Rule], errors: [String]) {
        guard data.count <= 64 * 1024, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ([], [L("The file isn't valid JSON")])
        }
        let list = root["rules"] as? [[String: Any]] ?? []
        var rules: [Rule] = [], errors: [String] = []
        for (i, r) in list.prefix(20).enumerated() {
            let name = r["name"] as? String, app = r["bundleIdentifier"] as? String, t = r["url"] as? String
            if let p = problem(name: name, app: app, template: t) { errors.append("\(name ?? "#\(i + 1)"): \(p)"); continue }
            rules.append(Rule(name: name ?? app!, app: app!, template: t!))
        }
        if list.count > 20 { errors.append(L("Only the first 20 rules are used")) }
        return (rules, errors)
    }

    static func load(_ url: URL = file) -> (rules: [Rule], errors: [String]) {
        guard let d = try? Data(contentsOf: url) else { return ([], []) }
        return parse(d)
    }

    static func status(_ url: URL = file) -> Status {
        guard FileManager.default.fileExists(atPath: url.path) else { return Status() }
        let r = load(url)
        return Status(exists: true, rules: r.rules.count, errors: r.errors)
    }

    /// At the click: https, or a scheme that the system opens with that very app.
    static func allowed(_ link: URL, app: String) -> Bool {
        guard let s = link.scheme?.lowercased(), !blocked.contains(s), !s.hasPrefix("x-apple") else { return false }
        if s == "https" { return link.host != nil }
        guard let opener = NSWorkspace.shared.urlForApplication(toOpen: link), let target = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return false }
        return opener.standardizedFileURL == target.standardizedFileURL
    }

    static let template = """
    {
      "_help": "Cocaine jump rules: when an AI session runs in the app with this bundleIdentifier, clicking it opens this url. Placeholders: {session_id} {cwd} {tty} {pid} {bundle_id} {tmux_pane}. Only https links or links that open that same app. See docs/ai-sessions.en.md.",
      "rules": [
      ]
    }

    """

    /// Opens the file in TextEdit, writing the empty template first (private, 0600) when there is none.
    static func edit() {
        let f = file
        if !FileManager.default.fileExists(atPath: f.path) {
            try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = SafeFile.writePrivate(Data(template.utf8), to: f)
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let te = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([f], withApplicationAt: te, configuration: cfg)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([f])
        }
    }
}

// MARK: - Tests (part of --agents-test)

enum JumpRuleTests {
    static func run(_ check: (String, Bool) -> Void) {
        let file = #"""
        {"rules": [
          {"name": "Editor", "bundleIdentifier": "com.example.Editor", "url": "example-editor://open?folder={cwd}&s={session_id}"},
          {"name": "Web", "bundleIdentifier": "com.example.Web", "url": "https://example.com/s/{session_id}"},
          {"name": "Bad scheme", "bundleIdentifier": "com.example.X", "url": "file:///etc/passwd"},
          {"name": "Script", "bundleIdentifier": "com.example.X", "url": "javascript:alert(1)"},
          {"name": "Own links", "bundleIdentifier": "com.example.X", "url": "cocaine://on"},
          {"name": "Placeholder", "bundleIdentifier": "com.example.X", "url": "x://{secret}"},
          {"name": "Spaces", "bundleIdentifier": "com.example.X", "url": "x://a b"},
          {"name": "No app", "url": "x://a"}
        ]}
        """#
        let r = JumpRules.parse(Data(file.utf8))
        check("jump rules: good rules are kept (\(r.rules.map(\.name)))", r.rules.map(\.name) == ["Editor", "Web"])
        check("jump rules: file:, javascript:, cocaine:, unknown placeholders, spaces, no app → refused with a reason", r.errors.count == 6)
        check("jump rules: a damaged file → no rules, one error", JumpRules.parse(Data("{".utf8)).rules.isEmpty && JumpRules.parse(Data("{".utf8)).errors.count == 1)
        let o = AgentOrigin(app: "com.example.Editor", cwd: "/Users/x/My Project & co", pid: 42)
        let url = r.rules[0].url(for: o, session: "abc-1")
        check("jump rules: placeholders are filled in and percent-encoded (\(url ?? "nil"))", url == "example-editor://open?folder=/Users/x/My%20Project%20%26%20co&s=abc-1")
        check("jump rules: a value the rule needs is missing → the rule is skipped, never filled with nothing",
              r.rules[0].url(for: AgentOrigin(app: "com.example.Editor"), session: "abc") == nil)
        check("jump rules: at the click, only https or a scheme that opens that same app",
              JumpRules.allowed(URL(string: "https://example.com/x")!, app: "com.example.Web")
              && !JumpRules.allowed(URL(string: "file:///etc")!, app: "com.apple.Terminal")
              && !JumpRules.allowed(URL(string: "x-apple.systempreferences:com.apple.preference")!, app: "com.apple.systempreferences")
              && !JumpRules.allowed(URL(string: "nosuchscheme-cocaine-test://x")!, app: "com.example.Editor"))
        AgentFocus.rulesOverride = [JumpRules.Rule(name: "E", app: "com.example.Editor", template: "example-editor://open?folder={cwd}")]
        defer { AgentFocus.rulesOverride = nil }
        check("jump rules: a rule for the session's app is tried first",
              AgentFocus.plan(AgentOrigin(app: "com.example.Editor", cwd: "/tmp")).first == .custom(url: "example-editor://open?folder=/tmp", app: "com.example.Editor"))
        check("jump rules: …and not for another app's session", AgentFocus.plan(AgentOrigin(app: AgentFocus.terminal, tty: "ttys001")).first == .terminalTab(tty: "ttys001"))
    }
}
