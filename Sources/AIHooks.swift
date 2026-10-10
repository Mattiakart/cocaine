// AI alerts: the hooks Cocaine adds to Claude Code, Codex and the other AI tools (AIHooks, JSONValue); --agent-request, --ai-alerts.

import AppKit
import AVFoundation
import Combine
import CoreAudio
import EventKit
import Carbon.HIToolbox
import Darwin
import ImageIO
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - AI alerts (hooks in Claude Code and Codex)

/// Just enough JSON to edit another app's config file without reordering its keys or rewriting its values: strings
/// and numbers keep their exact text; only the indentation is redone (2 spaces, as both apps write it).
enum JSONValue: Equatable {
    case object([Member])
    case array([JSONValue])
    case scalar(String)              // a string with its quotes, a number, true, false or null, exactly as written

    struct Member: Equatable {
        var key: String              // the raw text between the quotes
        var value: JSONValue
    }

    static func string(_ s: String) -> JSONValue {
        let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return .scalar(String(decoding: data, as: UTF8.self))
    }

    /// nil unless `text` is valid JSON (Foundation checks it first, so the scanner below can trust the syntax).
    static func parse(_ text: String) -> JSONValue? {
        let b = Array(text.utf8)
        guard (try? JSONSerialization.jsonObject(with: Data(b), options: [.fragmentsAllowed])) != nil else { return nil }
        var i = 0
        func space() { while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 } }
        func token() -> String {
            let start = i
            if b[i] == UInt8(ascii: "\"") {
                i += 1
                while b[i] != UInt8(ascii: "\"") { i += b[i] == UInt8(ascii: "\\") ? 2 : 1 }
                i += 1
            } else {
                while i < b.count, !",]} \t\r\n".utf8.contains(b[i]) { i += 1 }
            }
            return String(decoding: b[start..<i], as: UTF8.self)
        }
        func value() -> JSONValue {
            space()
            let open = b[i]
            guard open == UInt8(ascii: "{") || open == UInt8(ascii: "[") else { return .scalar(token()) }
            let close = open == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
            var members: [Member] = [], items: [JSONValue] = []
            i += 1
            space()
            while b[i] != close {
                if open == UInt8(ascii: "{") {
                    let key = token()
                    space()
                    i += 1                                       // ':'
                    members.append(Member(key: String(key.dropFirst().dropLast()), value: value()))
                } else {
                    items.append(value())
                }
                space()
                if b[i] == UInt8(ascii: ",") { i += 1; space() }
            }
            i += 1
            return open == UInt8(ascii: "{") ? .object(members) : .array(items)
        }
        return value()
    }

    func render(_ indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .scalar(let s):
            return s
        case .array(let items):
            return items.isEmpty ? "[]" : "[\n" + items.map { inner + $0.render(inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .object(let members):
            return members.isEmpty ? "{}"
                : "{\n" + members.map { "\(inner)\"\($0.key)\": " + $0.value.render(inner) }.joined(separator: ",\n") + "\n\(indent)}"
        }
    }

    var items: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var members: [Member]? { if case .object(let m) = self { return m }; return nil }

    subscript(key: String) -> JSONValue? {
        get { members?.first { $0.key == key }?.value }
        set {
            guard var m = members else { return }
            if let i = m.firstIndex(where: { $0.key == key }) {
                if let newValue { m[i].value = newValue } else { m.remove(at: i) }
            } else if let newValue {
                m.append(Member(key: key, value: newValue))
            }
            self = .object(m)
        }
    }
}

/// "AI alerts": hooks that make AI agents open cocaine://alert when they finish or need you. They live in each tool's
/// own config file; turning one off removes only Cocaine's hooks there, every other hook and setting stays as it was.
enum AIHooks {
    /// How a tool's config lists the commands for an event.
    enum Layout {
        case grouped      // "Event": [{ "matcher"?, "hooks": [{ "type": "command", "command": … }] }]  (Claude Code, Codex, …)
        case flat         // "event": [{ "command": … }]                                                 (Cursor, Windsurf)
        case ownFile      // a file of Cocaine's own in the tool's hooks/plugins folder                 (Copilot, OpenCode)
    }

    struct Event {
        let name: String
        let kind: String                                  // the alert: "done" or "input"
        var matcher: String? = nil
        var minVersion: [Int]? = nil                      // only for tools new enough to know this event (Claude Code)
    }

    struct Tool {
        let id: String                                    // stable, for the CLI and the menu
        let name: String                                  // also the alert's title
        let folder: String                                // the tool's config folder: it's installed if this exists
        let file: String
        var layout = Layout.grouped
        var events: [Event] = []
        var handler: (_ command: String, _ kind: String) -> [JSONValue.Member] = AIHooks.typed(timeout: "10")
        var top: [JSONValue.Member] = []                  // top-level keys the file must have (Cursor's "version": 1)
        var contents: ((Tool) -> String)? = nil           // .ownFile: the whole file
        var skipIf: String? = nil                         // an env variable set by another tool that runs these hooks too
        /// Its commands must not change (Codex asks the user to trust a hook again whenever its command changes): the
        /// newer terminals' ids (kitty, cmux, Zellij) are not added to its alert links; its approvals carry them anyway.
        var stableCommands = false
        /// Kinds whose news carries text (the last message, the error, the kind of notification) through `--agent-event`.
        var richKinds: Set<String> = []
        var activeEvents: [Event] {
            if relay != nil {                             // on an SSH host: its relay reads everything, its own Claude Code's version
                return events.filter { e in e.minVersion.map { need in remoteVersion.map { !$0.lexicographicallyPrecedes(need) } ?? false } ?? true }
            }
            return events.filter { ($0.minVersion.map { claudeVersionCheck($0) == true } ?? true) && runnable($0) }
        }
        /// Events this app can run at all (a request or a plan needs the installed app's binary, Codex's alert aside).
        private func runnable(_ e: Event) -> Bool {
            (e.kind != "approve" || id == "codex" || AIHooks.binary != nil) && (e.kind != "plan" || AIHooks.binary != nil)   // only the app's own binary reads a plan
        }
        /// Events left out only because Claude Code's version couldn't be read this time (`claude --version` timed out, or
        /// it isn't where a login shell or the usual install folders find it): Cocaine's hooks already there for them stay as
        /// they are (never removed for a version nobody could read), and none are added.
        var uncertainEvents: Set<String> {
            guard relay == nil else { return [] }
            return Set(events.filter { e in e.minVersion.map { AIHooks.claudeVersionCheck($0) == nil } == true && runnable(e) }.map(\.name))
        }
        var installed: ((Tool) -> Bool)? = nil            // when the folder alone doesn't tell
        /// On an SSH host (Sources/SSHInstall.swift): every hook runs the relay there instead of this app or a cocaine:// link.
        var relay: String? = nil
        var remoteVersion: [Int]? = nil                   // that host's Claude Code version, as its relay read it
    }

    /// The command a remote hook runs (expanded by the remote shell; the same on every host).
    static let relayCommand = "\"$HOME/.cocaine/bin/cocaine-relay\""
    /// The tools whose hooks can be put on an SSH host (JSON configs Cocaine can edit in place).
    static let remoteIDs = ["claude", "codex", "gemini", "qwen", "cursor"]

    /// Those tools as configured on a remote host whose home is `home` (a placeholder: paths are made relative to it).
    static func remoteTools(home: String, claudeVersion: [Int]?) -> [Tool] {
        tools(home: home).filter { remoteIDs.contains($0.id) }.map { t in
            var t = t
            t.relay = relayCommand
            t.remoteVersion = claudeVersion
            return t
        }
    }

    static var home = NSHomeDirectory()                   // `--ai-alerts … --home <dir>` works on a copy
    /// This app's executable, which approval hooks run (`--agent-request`): only from an installed copy (Applications), not a
    /// build folder or a translocated download, whose path won't be there later. COCAINE_HOOK_BINARY sets it, for tests.
    static var binary: String? = {
        if let b = ProcessInfo.processInfo.environment["COCAINE_HOOK_BINARY"], b.hasPrefix("/") { return b }
        guard let b = Bundle.main.executablePath, b.hasSuffix(".app/Contents/MacOS/Cocaine"), !b.contains("/AppTranslocation/"),
              b.hasPrefix("/Applications/") || b.hasPrefix(NSHomeDirectory() + "/Applications/") else { return nil }
        return b
    }()
    static let marker = "cocaine://alert"

    /// `{"type": "command", "command": …, "timeout": …}`: Claude Code, Codex and Qwen Code (seconds).
    private static func typed(timeout: String) -> (String, String) -> [JSONValue.Member] {
        { command, kind in [.init(key: "type", value: .string("command")), .init(key: "command", value: .string(command)),
                            .init(key: "timeout", value: .scalar(kind == "approve" && (AIHooks.binary != nil || command.contains(relayCommand))
                                                                 ? ApprovalTiming.config : timeout))] }
    }

    /// The supported tools, most used first. Formats from each tool's hooks reference (checked September 2026).
    static var tools: [Tool] { tools(home: home) }

    static func tools(home: String) -> [Tool] {
        [Tool(id: "claude", name: "Claude Code", folder: home + "/.claude", file: home + "/.claude/settings.json",
              events: [.init(name: "Stop", kind: "done"),
                       .init(name: "Notification", kind: "input", matcher: "permission_prompt|elicitation_dialog|agent_needs_input"),
                       .init(name: "SubagentStart", kind: "agentstart"), .init(name: "SubagentStop", kind: "agentstop"),
                       .init(name: "UserPromptSubmit", kind: "start"),
                       // Session open and ended (not "compact": that is the same session carrying on, mid-work).
                       .init(name: "SessionStart", kind: "open", matcher: "startup|resume|clear"), .init(name: "SessionEnd", kind: "end"),
                       .init(name: "StopFailure", kind: "error", minVersion: [2, 1, 78]),
                       // Answered from the notch when the user wants it (the app hands them straight back otherwise).
                       .init(name: "PermissionRequest", kind: "approve", minVersion: [2, 0, 45]),
                       .init(name: "Elicitation", kind: "approve", minVersion: [2, 1, 78]),
                       // A plan to review (ExitPlanMode) and a question to answer (AskUserQuestion), from the notch.
                       .init(name: "PreToolUse", kind: "approve", matcher: "ExitPlanMode|AskUserQuestion", minVersion: [2, 1, 78])],
              skipIf: "CURSOR_VERSION",                // Cursor runs Claude Code's hooks as well; it has its own below
              richKinds: ["done", "error", "input"]),
         Tool(id: "codex", name: "Codex", folder: home + "/.codex", file: home + "/.codex/hooks.json",
              events: [.init(name: "Stop", kind: "done"), .init(name: "PermissionRequest", kind: "approve"),
                       .init(name: "SubagentStart", kind: "agentstart"), .init(name: "SubagentStop", kind: "agentstop"),
                       .init(name: "UserPromptSubmit", kind: "start"),
                       .init(name: "SessionStart", kind: "open"), .init(name: "SessionEnd", kind: "end"),
                       // Its checklist (update_plan), shown read-only on the session's card.
                       .init(name: "PostToolUse", kind: "plan", matcher: "update_plan")],
              stableCommands: true),
         Tool(id: "cursor", name: "Cursor", folder: home + "/.cursor", file: home + "/.cursor/hooks.json", layout: .flat,
              events: [.init(name: "stop", kind: "done"),   // Cursor has no hook for "waiting for you"
                       .init(name: "subagentStart", kind: "agentstart"), .init(name: "subagentStop", kind: "agentstop"),
                       .init(name: "beforeSubmitPrompt", kind: "start"),
                       .init(name: "sessionStart", kind: "open"), .init(name: "sessionEnd", kind: "end")],
              handler: { command, _ in [.init(key: "command", value: .string(command)), .init(key: "timeout", value: .scalar("10"))] },
              top: [.init(key: "version", value: .scalar("1"))]),
         Tool(id: "copilot", name: "GitHub Copilot", folder: home + "/.copilot", file: home + "/.copilot/hooks/cocaine.json",
              layout: .ownFile, contents: copilotFile),  // Copilot CLI and VS Code's Copilot agent both read it
         Tool(id: "gemini", name: "Gemini CLI", folder: home + "/.gemini", file: home + "/.gemini/settings.json",
              events: [.init(name: "AfterAgent", kind: "done"), .init(name: "Notification", kind: "input"),
                       .init(name: "BeforeAgent", kind: "start"),
                       .init(name: "SessionStart", kind: "open"), .init(name: "SessionEnd", kind: "end")],
              handler: { command, kind in                // milliseconds; a name, so it can be disabled by name
                  [.init(key: "name", value: .string("cocaine-\(kind)")), .init(key: "type", value: .string("command")),
                   .init(key: "command", value: .string(command)), .init(key: "timeout", value: .scalar("10000"))] },
              installed: { t in                          // Google Antigravity keeps its things in ~/.gemini/antigravity too
                  let items = (try? FileManager.default.contentsOfDirectory(atPath: t.folder)) ?? []
                  return items.contains { !["antigravity", ".DS_Store"].contains($0) } }),
         Tool(id: "windsurf", name: "Windsurf", folder: home + "/.codeium/windsurf", file: home + "/.codeium/windsurf/hooks.json",
              layout: .flat, events: [.init(name: "post_cascade_response", kind: "done"), .init(name: "pre_user_prompt", kind: "start")],
              handler: { command, _ in [.init(key: "command", value: .string(command)), .init(key: "show_output", value: .scalar("false"))] }),
         Tool(id: "qwen", name: "Qwen Code", folder: home + "/.qwen", file: home + "/.qwen/settings.json",
              events: [.init(name: "Stop", kind: "done"), .init(name: "Notification", kind: "input", matcher: "permission_prompt"),
                       .init(name: "UserPromptSubmit", kind: "start")]),
         Tool(id: "opencode", name: "OpenCode", folder: home + "/.config/opencode", file: home + "/.config/opencode/plugins/cocaine.js",
              layout: .ownFile, contents: openCodeFile)]
    }
    /// Claude Code's version, asked once (a login shell finds it like Terminal does, else its usual install folders); nil in the
    /// cache when it couldn't be found (asked again at the next launch).
    private static var claudeVersionCache: [Int]??
    static func assumeClaudeVersion(_ v: [Int]?) { claudeVersionCache = .some(v) }   // tests: not the Mac's own Claude Code
    /// Tests: as if `claude --version` had timed out (nothing cached).
    static var claudeVersionLookup: () -> [Int]?? = AIHooks.findClaudeVersion
    static func forgetClaudeVersion() { claudeVersionCache = nil }

    /// Is Claude Code at least `need`? false when it is older, nil when its version can't be read (timed out, not found).
    static func claudeVersionCheck(_ need: [Int]) -> Bool? {
        if claudeVersionCache == nil {
            guard let found = claudeVersionLookup() else { return nil }   // timed out: not known this time, never cached as "old"
            claudeVersionCache = .some(found)
        }
        guard let have = claudeVersionCache ?? nil else { return nil }
        return have.lexicographicallyPrecedes(need) == false
    }

    static func parseVersion(_ out: String) -> [Int]? {
        guard let r = out.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return out[r].split(separator: ".").compactMap { Int($0) }
    }

    /// Where Claude Code's installers put it, for a login shell that doesn't find it (nvm and others set up in .zshrc only):
    /// the native installer, the old local install, Homebrew, npm's global folders and nvm's node versions.
    static func claudeCandidates(home: String = NSHomeDirectory()) -> [String] {
        var out = [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                   home + "/.npm-global/bin/claude", home + "/.bun/bin/claude", home + "/.volta/bin/claude"]
        let nvm = home + "/.nvm/versions/node"
        let nodes = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        out += nodes.map { nvm + "/" + $0 + "/bin/claude" }
        return out
    }

    /// The newest version the native installer keeps (~/.local/share/claude/versions/<x.y.z>), without running anything.
    static func installedVersions(home: String = NSHomeDirectory()) -> [Int]? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home + "/.local/share/claude/versions")) ?? []
        return names.compactMap { n -> [Int]? in
            guard n.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return nil }
            return parseVersion(n)
        }.max { $0.lexicographicallyPrecedes($1) }
    }

    /// nil: timed out (ask again later); .some(nil): not found anywhere.
    static func findClaudeVersion() -> [Int]?? {
        // A login shell finds it as Terminal does; one that waits for input (a prompt in .zprofile) is given up after 30 s.
        let r = Proc.run("/bin/zsh", ["-lc", "claude --version"], timeout: 30, capture: true, limit: 4096)
        if let v = parseVersion(r.text) { return .some(v) }
        for path in claudeCandidates() where FileManager.default.isExecutableFile(atPath: path) {
            // A node script finds its node next to it (nvm, npm) or in the usual folders.
            let dir = (URL(fileURLWithPath: path).resolvingSymlinksInPath().path as NSString).deletingLastPathComponent
            let env = ["PATH": [(path as NSString).deletingLastPathComponent, dir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":"),
                       "HOME": NSHomeDirectory()]
            let p = Proc.run(path, ["--version"], timeout: 15, capture: true, env: env, limit: 4096)
            if let v = parseVersion(p.text) { return .some(v) }
        }
        if let v = installedVersions() { return .some(v) }
        return r.timedOut ? nil : .some(nil)
    }
    static var present: [Tool] { tools.filter(isInstalled) }
    static func tool(_ id: String) -> Tool? { tools.first { $0.id == id } }
    static func isInstalled(_ t: Tool) -> Bool {
        FileManager.default.fileExists(atPath: t.folder) && (t.installed?(t) ?? true)
    }

    /// ~/.copilot/hooks/cocaine.json: GitHub Copilot's own hooks format.
    private static func copilotFile(_ t: Tool) -> String {
        func hook(_ kind: String, matcher: String? = nil) -> JSONValue {
            .object([.init(key: "type", value: .string("command"))]
                    + (matcher.map { [.init(key: "matcher", value: .string($0))] } ?? [])
                    + [.init(key: "bash", value: .string(command(t, kind))), .init(key: "timeoutSec", value: .scalar("10"))])
        }
        return JSONValue.object([
            .init(key: "version", value: .scalar("1")),
            .init(key: "hooks", value: .object([
                .init(key: "agentStop", value: .array([hook("done")])),
                .init(key: "notification", value: .array([hook("input", matcher: "permission_prompt|elicitation_dialog")])),
                .init(key: "userPromptSubmitted", value: .array([hook("start")])),
                .init(key: "errorOccurred", value: .array([hook("error")])),
                .init(key: "sessionStart", value: .array([hook("open")])),
                .init(key: "sessionEnd", value: .array([hook("end")])),
            ])),
        ]).render() + "\n"
    }

    /// ~/.config/opencode/plugins/cocaine.js: an OpenCode plugin (run by Bun) that listens for its events.
    private static func openCodeFile(_ t: Tool) -> String {
        guard case .scalar(let done) = JSONValue.string(command(t, "done")),
              case .scalar(let input) = JSONValue.string(command(t, "input")),
              case .scalar(let failed) = JSONValue.string(command(t, "error")) else { return "" }
        return """
        // Added by Cocaine ("AI alerts" in its menu-bar panel), which also removes it: it flashes the screen when
        // OpenCode finishes or needs you. https://github.com/Mattiakart/cocaine
        const done = \(done)
        const input = \(input)
        const failed = \(failed)

        export const Cocaine = async ({ $, client }) => ({
          event: async ({ event }) => {
            try {
              if (event.type === "session.idle") {
                const s = await client?.session?.get({ path: { id: event.properties?.sessionID } }).catch(() => null)
                if (s?.data?.parentID) return            // a subagent finished, not the session
                await $`sh -c ${done} < /dev/null`.quiet().nothrow()
              } else if (event.type === "permission.asked" || event.type === "question.asked") {
                await $`sh -c ${input} < /dev/null`.quiet().nothrow()
              } else if (event.type === "session.error") {
                await $`sh -c ${failed} < /dev/null`.quiet().nothrow()
              }
            } catch {}
          },
        })

        """
    }

    /// Does nothing while Cocaine is closed, so a closed Cocaine stays closed. `project` is the folder the agent runs
    /// in, URL-encoded by the perl that comes with macOS. Change it only when needed: Codex asks to trust a hook again
    /// whenever its command changes.
    static func command(_ tool: Tool, _ kind: String) -> String {
        if let relay = tool.relay {                               // on an SSH host: the relay there (relay/cocaine-relay)
            let skip = tool.skipIf.map { "[ -z \"$\($0)\" ] && " } ?? ""
            let out = kind == "approve" ? "2>/dev/null" : ">/dev/null 2>&1"   // only a request's answer is printed
            return skip + relay + " hook \(tool.id) \(kind) \(out); true # \(marker)"
        }
        let from = tool.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? tool.name
        let project = #"$(printf %s "$PWD" | /usr/bin/perl -pe 's|.*/||; s/([^A-Za-z0-9._~-])/sprintf("%%%02X", ord $1)/ge')"#
        // From the JSON the tool sends on stdin (read with the perl and JSON::PP every Mac has): the session, so a
        // session's agents make one alert, and how much of its work is still in flight (Claude Code's background_tasks
        // and session_crons), so a session paused waiting for it isn't "done". Prints "<session> <count>", the count
        // empty when the tool sends no such list; gives up after 2 s if a tool never closes stdin.
        let info = #"$(/usr/bin/perl -MJSON::PP -e 'alarm 2; local $/; my $j = eval { decode_json(<STDIN> // "") } || {}; my $s = $j->{session_id} // $j->{sessionId} // $j->{conversation_id} // $j->{conversationId} // $j->{trajectory_id} // ""; $s =~ s/[^A-Za-z0-9._:-]//g; my $n; for my $k ("background_tasks", "session_crons") { $n += @{$j->{$k}} if ref $j->{$k} eq "ARRAY" } print "$s ", $n // ""' 2>/dev/null)"#
        let skip = tool.skipIf.map { "[ -z \"$\($0)\" ] && " } ?? ""
        // A request that can be answered from the notch: this app's binary sends it over the socket and prints the answer
        // (or nothing). The comment carries the marker that tells Cocaine's hooks apart.
        let quotedBin = binary.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if kind == "approve" {
            guard let bin = quotedBin else { return command(tool, "input") }
            return skip + bin + " --agent-request \(tool.id) 2>/dev/null; true # \(marker)"
        }
        if kind == "plan" {                                       // read-only news with text: only through the app's binary
            guard let bin = quotedBin else { return "true # \(marker)" }
            return skip + bin + " --agent-event \(tool.id) plan >/dev/null 2>&1; true # \(marker)"
        }
        // Where the session runs, for going back to it: the agent's pid (the hook's parent; the app finds its terminal and
        // app from it), its folder, and what the terminal puts in the environment (app, tab/session ids, tmux, WezTerm, and
        // for tools whose commands may change: kitty, cmux, Zellij).
        let more = tool.stableCommands ? "" : #", kitty => $ENV{KITTY_WINDOW_ID}, kittys => $ENV{KITTY_LISTEN_ON}, cmux => $ENV{CMUX_SURFACE_ID}, cmuxw => $ENV{CMUX_WORKSPACE_ID}, cmuxs => $ENV{CMUX_SOCKET_PATH}, zj => $ENV{ZELLIJ_SESSION_NAME}, zjp => $ENV{ZELLIJ_PANE_ID}, term => $ENV{TERM_PROGRAM} // ($ENV{GHOSTTY_RESOURCES_DIR} ? "ghostty" : undef)"#
        let origin = #"$(/usr/bin/perl -e 'sub e { my $v = shift // ""; $v =~ s/([^A-Za-z0-9._~-])/sprintf("%%%02X", ord $1)/ge; $v } my $pp = shift // ""; $pp = "" unless $pp =~ /^[0-9]+$/; my %q = (pid => $pp, cwd => $ENV{PWD}, app => $ENV{__CFBundleIdentifier}, term => $ENV{TERM_PROGRAM}, tsid => $ENV{ITERM_SESSION_ID} // $ENV{TERM_SESSION_ID}, tmux => $ENV{TMUX_PANE}, tmuxs => (split /,/, $ENV{TMUX} // "")[0], wez => $ENV{WEZTERM_PANE}"# + more + #"); print map { defined $q{$_} && length $q{$_} ? "&$_=" . e($q{$_}) : "" } sort keys %q' "$PPID" 2>/dev/null)"#
        let link = "pgrep -qx Cocaine && { j=\(info); open -g \"cocaine://alert?from=\(from)&event=\(kind)"
            + "&session=${j% *}&running=${j#* }&project=\(project)\(origin)\"; }"
        // News with text (Claude Code's last message, its error, the kind of notification): the app's binary sends it over
        // the private socket; if it can't (the app isn't running, an older install), the plain link as before.
        if tool.richKinds.contains(kind), let bin = quotedBin {
            return skip + "{ " + bin + " --agent-event \(tool.id) \(kind) 2>/dev/null || { \(link); }; }; true"
        }
        return skip + link + "; true"
    }

    /// What goes in an event's list: a group holding our handler (with the event's matcher), or the handler itself.
    private static func entry(_ tool: Tool, _ event: Event) -> JSONValue {
        let handler = JSONValue.object(tool.handler(command(tool, event.kind), event.kind))
        guard tool.layout == .grouped else { return handler }
        return .object((event.matcher.map { [.init(key: "matcher", value: .string($0))] } ?? [])
                       + [.init(key: "hooks", value: .array([handler]))])
    }

    private static func isOurs(_ handler: JSONValue) -> Bool {
        guard case .scalar(let s)? = handler["command"] else { return false }
        return s.contains(marker) || s.contains("cocaine:\\/\\/alert")
    }
    private static func hasOurs(_ group: JSONValue) -> Bool { group["hooks"]?.items?.contains(where: isOurs) ?? false }

    /// The file's JSON: {} if it doesn't exist or is empty; nil if it isn't a JSON object this code can round-trip.
    static func load(_ path: String) -> JSONValue? {
        guard FileManager.default.fileExists(atPath: path) else { return .object([]) }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// A config file's text as JSON this code can round-trip: {} when empty; nil when it can't be edited safely.
    static func parse(_ raw: String) -> JSONValue? {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .object([]) }
        guard let v = JSONValue.parse(text), v.members != nil,
              let a = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary,
              let b = try? JSONSerialization.jsonObject(with: Data(v.render().utf8)) as? NSDictionary, a == b
        else { return nil }
        return v
    }

    static func installed(_ root: JSONValue) -> Bool {
        root["hooks"]?.members?.contains { $0.value.items?.contains { isOurs($0) || hasOurs($0) } ?? false } ?? false
    }

    /// `root` with our hooks added or removed. Ones already there are updated where they are, so Codex's trust
    /// (keyed by position) survives; groups, events and "hooks" left empty by a removal go too. nil = hands off.
    static func edited(_ root: JSONValue, for tool: Tool, on: Bool) -> JSONValue? {
        let before = root["hooks"]
        guard let events = (before ?? .object([])).members else { return nil }
        var wanted = on ? Dictionary(uniqueKeysWithValues: tool.activeEvents.map { ($0.name, entry(tool, $0)) }) : [:]
        // Turning on (or bringing up to date) while Claude Code's version can't be read: ours for those events stay as they are.
        let keep = on ? tool.uncertainEvents.subtracting(wanted.keys) : []
        var result: [JSONValue.Member] = []
        for var event in events {
            guard let entries = event.value.items else { wanted[event.key] = nil; result.append(event); continue }
            if keep.contains(event.key) { result.append(event); continue }
            var out: [JSONValue] = []
            for e in entries {
                if tool.layout == .flat {
                    guard isOurs(e) else { out.append(e); continue }
                    if let w = wanted.removeValue(forKey: event.key) { out.append(w) }   // same place; drop repeats
                    continue
                }
                guard hasOurs(e) else { out.append(e); continue }
                if e["hooks"]?.items?.allSatisfy(isOurs) == true, let w = wanted.removeValue(forKey: event.key) {
                    out.append(w)
                    continue
                }
                let kept = (e["hooks"]?.items ?? []).filter { !isOurs($0) }   // ours inside someone else's group
                if !kept.isEmpty { var e = e; e["hooks"] = .array(kept); out.append(e) }
            }
            if let w = wanted.removeValue(forKey: event.key) { out.append(w) }
            if out.isEmpty && !entries.isEmpty { continue }
            event.value = .array(out)
            result.append(event)
        }
        for e in tool.activeEvents { if let w = wanted.removeValue(forKey: e.name) { result.append(.init(key: e.name, value: .array([w]))) } }
        var root = root
        if !result.isEmpty { root["hooks"] = .object(result) }
        else if before?.members?.isEmpty == false { root["hooks"] = nil }
        if on, var members = root.members {                   // e.g. Cursor's "version": 1, first like its docs
            for m in tool.top.reversed() where root[m.key] == nil { members.insert(m, at: 0) }
            root = .object(members)
        }
        return root
    }

    /// Writes through symlinks (dotfile setups) and keeps the file's permissions.
    static func writeConfig(_ text: String, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        guard SafeFile.writePrivate(Data(text.utf8), to: url) else { return false }       // 0600 until its own permissions are back
        if let perms { try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
        return true
    }

    /// Whether Cocaine's hooks are in this tool's config.
    static func isOn(_ t: Tool) -> Bool {
        guard t.layout != .ownFile else { return (try? String(contentsOfFile: t.file, encoding: .utf8))?.contains(marker) ?? false }
        return load(t.file).map(installed) ?? false
    }

    /// Adds or removes the hooks in every tool on this Mac (or just `only`); returns the files it couldn't update.
    @discardableResult
    static func set(_ on: Bool, only: [Tool]? = nil) -> [String] {
        var failed: [String] = []
        for tool in only ?? present {
            if tool.layout == .ownFile, let contents = tool.contents {
                let current = try? String(contentsOfFile: tool.file, encoding: .utf8)
                if on {
                    let want = contents(tool)
                    guard current != want else { continue }
                    if let current, !current.contains(marker) { failed.append(tool.file); continue }   // not ours: hands off
                    try? FileManager.default.createDirectory(atPath: (tool.file as NSString).deletingLastPathComponent,
                                                             withIntermediateDirectories: true)
                    if !writeConfig(want, to: tool.file) { failed.append(tool.file) }
                } else if let current, current.contains(marker) {
                    do { try FileManager.default.removeItem(atPath: tool.file) } catch { failed.append(tool.file) }
                }
                continue
            }
            guard let root = load(tool.file), let new = edited(root, for: tool, on: on) else { failed.append(tool.file); continue }
            if new != root && !writeConfig(new.render() + "\n", to: tool.file) { failed.append(tool.file) }
        }
        return failed
    }

    /// At launch: brings hooks written by an older Cocaine (or by hand) up to date, only where they already are.
    static func update() {
        let tools = present.filter(isOn)
        if !tools.isEmpty { set(true, only: tools) }
        if StatusLineHook.isOn() { StatusLineHook.set(true) }        // the statusline wrapper follows the app if it moved
    }

    /// Codex runs a new hook only after the user trusts it once (/hooks, or Settings → Hooks in the ChatGPT app);
    /// it then keeps `trusted_hash` under [hooks.state."<file>:<event>:<group>:<handler>"] in its config.toml.
    static func codexNeedsTrust() -> Bool {
        guard let codex = tool("codex"), FileManager.default.fileExists(atPath: codex.folder),
              let events = load(codex.file)?["hooks"]?.members else { return false }
        let config = (try? String(contentsOfFile: codex.folder + "/config.toml", encoding: .utf8)) ?? ""
        for event in events {
            let snake = event.key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
            for (g, group) in (event.value.items ?? []).enumerated() {
                for (h, handler) in (group["hooks"]?.items ?? []).enumerated() where isOurs(handler) {
                    if !trusted("\(codex.file):\(snake):\(g):\(h)", in: config) { return true }
                }
            }
        }
        return false
    }

    private static func trusted(_ key: String, in config: String) -> Bool {
        guard let r = config.range(of: "\"\(key)\"") else { return false }
        let rest = config[r.upperBound...]
        let lineEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
        let lineStart = config[..<r.lowerBound].lastIndex(of: "\n").map { config.index(after: $0) } ?? config.startIndex
        guard config[lineStart...].hasPrefix("[") else { return rest[..<lineEnd].contains("trusted_hash") }  // inline table
        let body = rest[lineEnd...]                                                  // [hooks.state."…"] table
        return body[..<(body.range(of: "\n[")?.lowerBound ?? body.endIndex)].contains("trusted_hash")
    }

    struct Entry: Equatable, Identifiable {
        let id: String
        let name: String
        var installed = false
        var on = false
    }

    struct Status: Equatable {
        var tools: [Entry] = []
        var codexNeedsTrust = false
        var available: Bool { tools.contains(where: \.installed) }
        var connected: [Entry] { tools.filter(\.on) }
    }

    static func status() -> Status {
        var s = Status(tools: tools.map { t in
            let installed = isInstalled(t)
            return Entry(id: t.id, name: t.name, installed: installed, on: installed && isOn(t))
        })
        s.codexNeedsTrust = s.tools.contains { $0.id == "codex" && $0.on } && codexNeedsTrust()
        return s
    }
}

/// `--agent-request`, run from main.swift.
func cliAgentRequest() {
    // Run by Claude Code's and Codex's request hooks (`AIHooks.command(_, "approve")`): hands the request to the running app
    // and prints its signed answer as the tool's documented hook output, or nothing (the tool then asks in the terminal).
    // Never a decision of its own; always exit 0 (exit 2 would mean "block" to some tools).
    signal(SIGPIPE, SIG_IGN)
    let env = ProcessInfo.processInfo.environment
    let timeout = env["COCAINE_HOOK_TIMEOUT"].flatMap(Double.init).map { min(max($0, 1), ApprovalTiming.hook) } ?? ApprovalTiming.hook
    if let out = ApprovalHook.run(tool: CommandLine.arguments[2], input: ApprovalHook.readInput(), env: env, timeout: timeout) { print(out) }
    exit(0)
}

/// `--ai-alerts`, run from main.swift.
func cliAIAlerts() {
    // `on|off|status [tool ids…] [--home <dir>]` for the AI alerts hooks: every tool on this Mac unless ids are given.
    // The Homebrew uninstall runs `off`; --home works on a copy, for tests.
    var args = Array(CommandLine.arguments.dropFirst(3))
    if let i = args.firstIndex(of: "--home"), i + 1 < args.count { AIHooks.home = args[i + 1]; args.removeSubrange(i...i + 1) }
    switch CommandLine.arguments[2] {
    case "on", "off":
        let tools = args.isEmpty ? AIHooks.present : args.compactMap(AIHooks.tool)
        let failed = AIHooks.set(CommandLine.arguments[2] == "on", only: tools)
        failed.forEach { print("could not update \($0)") }
        exit(failed.isEmpty ? 0 : 1)
    default:
        let s = AIHooks.status()
        for t in s.tools { print("\(t.id): \(t.installed ? (t.on ? "on" : "off") : "not installed")") }
        print("codex needs trust: \(s.codexNeedsTrust)")
        exit(0)
    }
}
