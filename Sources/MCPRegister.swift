// Connecting AI tools to Cocaine's MCP server (`/Applications/Cocaine.app/Contents/MacOS/Cocaine --mcp`), one click each, always
// shown first (the exact command, or the change to the file as a diff) and reversible:
//   Claude Code:    its own CLI, `claude mcp add --scope user cocaine -- <binary> --mcp` (run only when the CLI is found and the
//                   user agrees; otherwise the command to copy). Status read from ~/.claude.json.
//   Claude Desktop: ~/Library/Application Support/Claude/claude_desktop_config.json, "mcpServers" → "cocaine".
//   Codex:          ~/.codex/config.toml, the [mcp_servers.cocaine] table.
//   Cursor:         ~/.cursor/mcp.json, "mcpServers" → "cocaine".
//   Gemini CLI:     ~/.gemini/settings.json, "mcpServers" → "cocaine".
// File edits keep every other server and key (JSONValue / a line edit for TOML), make a backup next to the file first
// (`<file>.cocaine-backup`), write through symlinks, and remove exactly Cocaine's entry when turned off. Only an installed copy
// (Applications) can be registered, like the hooks (AIHooks.binary). `--mcp-register … --home <dir>` works on a copy, for tests.

import Foundation

enum MCPRegistration {
    static var home = NSHomeDirectory()
    static var binary: () -> String? = { AIHooks.binary }
    /// The Claude Code CLI, if this Mac has one (tests inject a fake).
    static var claudeCLI: () -> String? = {
        let h = NSHomeDirectory()
        return [h + "/.local/bin/claude", h + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static let name = "cocaine"

    enum Client: String, CaseIterable, Identifiable {
        case claudeCode = "claude-code", claudeDesktop = "claude-desktop", codex, cursor, gemini
        var id: String { rawValue }
        var title: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .claudeDesktop: return "Claude Desktop"
            case .codex: return "Codex"
            case .cursor: return "Cursor"
            case .gemini: return "Gemini CLI"
            }
        }
        /// The config file Cocaine edits (Claude Code: the one its CLI writes, read for the status).
        var file: String {
            switch self {
            case .claudeCode: return MCPRegistration.home + "/.claude.json"
            case .claudeDesktop: return MCPRegistration.home + "/Library/Application Support/Claude/claude_desktop_config.json"
            case .codex: return MCPRegistration.home + "/.codex/config.toml"
            case .cursor: return MCPRegistration.home + "/.cursor/mcp.json"
            case .gemini: return MCPRegistration.home + "/.gemini/settings.json"
            }
        }
        /// The tool is on this Mac if its folder exists.
        var folder: String {
            switch self {
            case .claudeCode: return MCPRegistration.home + "/.claude"
            default: return (file as NSString).deletingLastPathComponent
            }
        }
    }

    static func installed(_ c: Client) -> Bool {
        if c == .claudeCode { return FileManager.default.fileExists(atPath: c.folder) || claudeCLI() != nil }
        return FileManager.default.fileExists(atPath: c.folder)
    }

    // MARK: status

    /// Whether Cocaine's entry is there (and runs this binary).
    static func registered(_ c: Client) -> Bool {
        switch c {
        case .codex:
            guard let t = try? String(contentsOfFile: c.file, encoding: .utf8) else { return false }
            return tomlTable(t) != nil
        default:
            guard let root = AIHooks.load(c.file) else { return false }
            return root["mcpServers"]?[name] != nil
        }
    }

    // MARK: the edits (pure)

    static func entry(_ c: Client, binary: String) -> JSONValue {
        var m: [JSONValue.Member] = []
        if c == .claudeCode { m.append(.init(key: "type", value: .string("stdio"))) }
        m.append(.init(key: "command", value: .string(binary)))
        m.append(.init(key: "args", value: .array([.string("--mcp")])))
        return .object(m)
    }

    /// The JSON config with Cocaine's server added (or updated where it is) or removed; nil: hands off (not an object).
    static func jsonEdited(_ root: JSONValue, _ c: Client, on: Bool, binary: String?) -> JSONValue? {
        guard root.members != nil else { return nil }
        var root = root
        let servers = root["mcpServers"]
        if let servers, servers.members == nil { return nil }        // something else under that key: not ours to change
        var s = servers ?? .object([])
        if on {
            guard let binary else { return nil }
            s[name] = entry(c, binary: binary)
            root["mcpServers"] = s
        } else {
            guard servers?[name] != nil else { return root }
            s[name] = nil
            root["mcpServers"] = (s.members?.isEmpty ?? true) ? nil : s
        }
        return root
    }

    /// The range of lines of Cocaine's TOML table ([mcp_servers.cocaine] and its sub-tables), if there.
    static func tomlTable(_ text: String) -> Range<Int>? {
        let lines = text.components(separatedBy: "\n")
        func header(_ l: String) -> String? {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), let close = t.firstIndex(of: "]") else { return nil }
            return t[t.index(after: t.startIndex)..<close].replacingOccurrences(of: "[", with: "").trimmingCharacters(in: .whitespaces)
        }
        func ours(_ h: String) -> Bool {
            let n = h.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\"", with: "")
            return n == "mcp_servers.\(name)" || n.hasPrefix("mcp_servers.\(name).")
        }
        guard let start = lines.firstIndex(where: { header($0).map(ours) ?? false }) else { return nil }
        var end = start + 1
        while end < lines.count {
            if let h = header(lines[end]), !ours(h) { break }
            end += 1
        }
        // Blank lines just before the next table belong to the gap, not to ours.
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return start..<end
    }

    static func tomlString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    /// Codex's config.toml with Cocaine's table added (or replaced where it is) or removed.
    static func tomlEdited(_ text: String, on: Bool, binary: String?) -> String? {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let block = binary.map { ["[mcp_servers.\(name)]", "command = \(tomlString($0))", "args = [\"--mcp\"]"] }
        if let r = tomlTable(text) {
            if on {
                guard let block else { return nil }
                lines.replaceSubrange(r, with: block)
            } else {
                lines.removeSubrange(r)
                // The blank line that separated our table from the one before goes too.
                if r.lowerBound > 0, r.lowerBound <= lines.count, lines[r.lowerBound - 1].trimmingCharacters(in: .whitespaces).isEmpty,
                   r.lowerBound == lines.count || lines[r.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty || lines[r.lowerBound].hasPrefix("[") {
                    lines.remove(at: r.lowerBound - 1)
                }
            }
        } else if on {
            guard let block else { return nil }
            while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += block
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: plans (what will change, shown before it does)

    struct Plan: Equatable {
        var client: Client
        var on: Bool
        var path: String
        var before: String?          // the file now (nil: it doesn't exist)
        var after: String?           // what it will be (nil: nothing to write)
        var command: [String]?       // Claude Code: the CLI and its arguments
        var noChange: Bool { command == nil && (after == nil || after == before) }
    }

    enum Problem: Error, Equatable { case notInstalledCopy, unreadable(String), noCLI(String) }

    /// The exact command for Claude Code (to run or to copy).
    static func claudeCommand(on: Bool, binary: String, cli: String = "claude") -> [String] {
        on ? [cli, "mcp", "add", "--scope", "user", name, "--", binary, "--mcp"] : [cli, "mcp", "remove", "--scope", "user", name]
    }

    static func shellLine(_ argv: [String]) -> String {
        argv.map { a in a.range(of: "^[A-Za-z0-9_./=:-]+$", options: .regularExpression) != nil ? a : "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }

    static func plan(_ c: Client, on: Bool) -> Result<Plan, Problem> {
        let bin = binary()
        if on && bin == nil { return .failure(.notInstalledCopy) }
        switch c {
        case .claudeCode:
            let isOn = registered(c)
            if on == isOn && (!on || currentClaudeCommand() == bin) { return .success(Plan(client: c, on: on, path: c.file)) }
            guard let cli = claudeCLI() else { return .failure(.noCLI(shellLine(claudeCommand(on: on, binary: bin ?? "/Applications/Cocaine.app/Contents/MacOS/Cocaine")))) }
            var cmds = claudeCommand(on: on, binary: bin ?? "", cli: cli)
            if on && isOn { cmds = claudeCommand(on: false, binary: "", cli: cli) + ["&&"] + claudeCommand(on: true, binary: bin!, cli: cli) }
            return .success(Plan(client: c, on: on, path: c.file, command: cmds))
        case .codex:
            let before = try? String(contentsOfFile: c.file, encoding: .utf8)
            if FileManager.default.fileExists(atPath: c.file) && before == nil { return .failure(.unreadable(c.file)) }
            guard let after = tomlEdited(before ?? "", on: on, binary: bin) else { return .failure(.unreadable(c.file)) }
            return .success(Plan(client: c, on: on, path: c.file, before: before, after: after == (before ?? "") ? nil : after))
        default:
            let exists = FileManager.default.fileExists(atPath: c.file)
            guard let root = AIHooks.load(c.file), let new = jsonEdited(root, c, on: on, binary: bin) else { return .failure(.unreadable(c.file)) }
            let before = exists ? (try? String(contentsOfFile: c.file, encoding: .utf8)) : nil
            let after = new == root ? nil : new.render() + "\n"
            if !on && !exists { return .success(Plan(client: c, on: on, path: c.file)) }
            return .success(Plan(client: c, on: on, path: c.file, before: before, after: after))
        }
    }

    /// The command Claude Code runs for "cocaine" now (from ~/.claude.json), if any.
    static func currentClaudeCommand() -> String? {
        guard case .scalar(let s)? = AIHooks.load(Client.claudeCode.file)?["mcpServers"]?[name]?["command"] else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])) as? String
    }

    /// Carries out a plan (after the user saw it). false: something failed (the file is left as it was).
    static func apply(_ p: Plan) -> Bool {
        if let cmd = p.command {
            // "a && b": run each in turn, stop at the first failure.
            for part in cmd.split(separator: "&&").map(Array.init) where !part.isEmpty {
                let r = Proc.run(part[0], Array(part.dropFirst()), timeout: 30, capture: true, stderr: true)
                if r.status != 0 { return false }
            }
            return true
        }
        guard p.after != nil, p.after != p.before else { return true }
        // The question may have stayed open a while, and the tool may have rewritten its own file meanwhile: the same change is
        // planned again on what is there now (nothing written since is lost, the backup is what was really there).
        func read() -> String? { FileManager.default.fileExists(atPath: p.path) ? try? String(contentsOfFile: p.path, encoding: .utf8) : nil }
        if read() != p.before {
            guard case .success(let fresh) = plan(p.client, on: p.on), fresh.command == nil else { return false }
            guard read() == fresh.before else { return false }                      // still moving: left as it is
            return write(fresh)
        }
        return write(p)
    }

    private static func write(_ p: Plan) -> Bool {
        guard let after = p.after, after != p.before else { return true }
        try? FileManager.default.createDirectory(atPath: (p.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let before = p.before {
            let real = URL(fileURLWithPath: p.path).resolvingSymlinksInPath()
            SafeFile.writePrivate(Data(before.utf8), to: URL(fileURLWithPath: real.path + ".cocaine-backup"))
        }
        return AIHooks.writeConfig(after, to: p.path)
    }

    /// The change as lines: "- old", "+ new", with a little context; at most `limit` lines.
    static func diff(_ before: String?, _ after: String?, limit: Int = 40) -> [String] {
        let a = (before ?? "").components(separatedBy: "\n"), b = (after ?? before ?? "").components(separatedBy: "\n")
        guard a.count * b.count <= 4_000_000 else { return ["(file too large to show the change)"] }
        // Longest common subsequence, then walk it.
        var t = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var out: [(Character, String)] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { out.append((" ", a[i])); i += 1; j += 1 }
            else if j < b.count, i == a.count || t[i][j + 1] >= t[i + 1][j] { out.append(("+", b[j])); j += 1 }
            else { out.append(("-", a[i])); i += 1 }
        }
        let changed = out.indices.filter { out[$0].0 != " " }
        guard !changed.isEmpty else { return [] }
        let keep = Set(changed.flatMap { max(0, $0 - 2)...min(out.count - 1, $0 + 2) })
        var lines: [String] = [], last = -1
        for k in keep.sorted() {
            if last >= 0 && k > last + 1 { lines.append("…") }
            lines.append("\(out[k].0) \(out[k].1)")
            last = k
        }
        return lines.count > limit ? Array(lines.prefix(limit)) + ["…"] : lines
    }
}

/// `--mcp-register on|off|status [client…] [--home <dir>]`, run from main.swift (tests; the Homebrew uninstall can run `off`).
func cliMCPRegister() -> Never {
    var args = Array(CommandLine.arguments.dropFirst(2))
    if let i = args.firstIndex(of: "--home"), i + 1 < args.count { MCPRegistration.home = args[i + 1]; args.removeSubrange(i...i + 1) }
    guard let verb = args.first, ["on", "off", "status"].contains(verb) else {
        FileHandle.standardError.write(Data("usage: Cocaine --mcp-register on|off|status [client…] [--home DIR]\n".utf8)); exit(64)
    }
    let clients = args.count > 1 ? args.dropFirst().compactMap(MCPRegistration.Client.init(rawValue:)) : MCPRegistration.Client.allCases
    var failed = false
    for c in clients {
        if verb == "status" { print("\(c.rawValue): \(MCPRegistration.registered(c) ? "on" : "off")"); continue }
        if c == .claudeCode { print("\(c.rawValue): use the claude CLI: \(MCPRegistration.shellLine(MCPRegistration.claudeCommand(on: verb == "on", binary: MCPRegistration.binary() ?? "<Cocaine>")))"); continue }
        switch MCPRegistration.plan(c, on: verb == "on") {
        case .success(let p): if !MCPRegistration.apply(p) { print("could not update \(p.path)"); failed = true }
        case .failure(let e): print("\(c.rawValue): \(e)"); failed = true
        }
    }
    exit(failed ? 1 : 0)
}
