// A hook's news that carries text (`Cocaine --agent-event <tool> <kind>`): Claude Code's Stop (the last message, for the
// session card's completion preview, and how much is still running in the background), StopFailure (which error), Notification
// (which kind of "needs you") and Codex's update_plan (its checklist, shown read-only). It goes over the app's private socket,
// not a cocaine:// URL (URLs are size-limited and end up in logs), and only what is needed, bounded. The app keeps the text in
// memory only (AgentExtras): never in state.json, never on disk; a setting hides it from the cards.

import AppKit
import Combine

enum AgentEventHook {
    static let maxMessage = 4000

    static func sessionID(_ j: [String: Any]) -> String? {
        let raw = j["session_id"] as? String ?? j["sessionId"] as? String ?? j["conversation_id"] as? String ?? ""
        let s = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-").contains($0) }).prefix(80))
        return s.isEmpty ? nil : s
    }

    /// The bounded event for the app from the tool's JSON. Pure (tested with the docs' sample payloads).
    static func event(kind: String, input j: [String: Any]) -> [String: Any] {
        var e: [String: Any] = ["kind": kind]
        if let h = j["hook_event_name"] as? String { e["hook"] = String(h.prefix(40)) }
        if let s = sessionID(j) { e["session"] = s }
        var running: Int?
        for k in ["background_tasks", "session_crons"] { if let a = j[k] as? [Any] { running = (running ?? 0) + a.count } }
        if let running { e["running"] = running }
        if let bg = j["background_tasks"] as? [Any] { e["background"] = bg.count }
        if let m = j["last_assistant_message"] as? String, !m.isEmpty { e["message"] = String(m.prefix(maxMessage)) }
        if let t = j["notification_type"] as? String { e["notification"] = String(t.prefix(40)) }
        if let t = j["error_type"] as? String { e["error"] = String(t.prefix(40)) }
        if let t = j["error_message"] as? String { e["errorText"] = String(t.prefix(300)) }
        if j["tool_name"] as? String == "update_plan", let input = j["tool_input"] as? [String: Any] {
            let steps = (input["plan"] as? [[String: Any]] ?? []).prefix(50).compactMap { s -> [String: String]? in
                guard let step = s["step"] as? String else { return nil }
                return ["step": String(step.prefix(300)), "status": String((s["status"] as? String ?? "pending").prefix(20))]
            }
            e["steps"] = steps
            if let x = input["explanation"] as? String { e["explanation"] = String(x.prefix(600)) }
        }
        return e
    }

    /// Sends it; false when the app isn't there to take it (the hook then falls back to the plain alert link).
    static func send(tool: String, kind: String, input: Data, env: [String: String]) -> Bool {
        guard let j = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return false }
        guard let (fd, _) = ApprovalHook.connect(env: env) else { return false }
        defer { close(fd) }
        var msg: [String: Any] = ["v": 1, "type": "event", "tool": tool, "event": event(kind: kind, input: j)]
        if let o = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(ApprovalHook.origin(env: env))) { msg["origin"] = o }
        guard var body = try? JSONSerialization.data(withJSONObject: msg) else { return false }
        body.append(0x0A)
        return body.withUnsafeBytes { ApprovalServer.writeAll(fd, $0) }
    }
}

/// `--agent-event <tool> <kind>`, run from main.swift by the hooks AIHooks writes when the app is installed.
func cliAgentEvent() {
    signal(SIGPIPE, SIG_IGN)
    let a = CommandLine.arguments
    let ok = AgentEventHook.send(tool: a[2], kind: a[3], input: ApprovalHook.readInput(seconds: 2), env: ProcessInfo.processInfo.environment)
    exit(ok ? 0 : 1)
}

/// What a session's card shows beyond its state, in memory only.
struct AgentExtra: Equatable {
    var message: String?          // the last reply (Markdown, at most 4000 characters)
    var background = 0            // tasks still running in the background
    var error: String?            // why it stopped, in words
    var notice: String?           // what kind of "needs you"
    var steps: [(step: String, status: String)] = []   // Codex's plan, read-only
    var explanation: String?
    var at = Date()

    static func == (a: AgentExtra, b: AgentExtra) -> Bool {
        a.message == b.message && a.background == b.background && a.error == b.error && a.notice == b.notice
            && a.steps.map(\.step) == b.steps.map(\.step) && a.steps.map(\.status) == b.steps.map(\.status) && a.explanation == b.explanation && a.at == b.at
    }

    /// The error in words, from Claude Code's StopFailure `error_type`.
    static func errorText(_ type: String?) -> String? {
        switch type {
        case nil: return nil
        case "rate_limit"?: return L("hit a usage limit")
        case "overloaded"?: return L("the service is overloaded")
        case "authentication_failed"?, "oauth_org_not_allowed"?: return L("can't sign in")
        case "billing_error"?, "account_on_hold"?: return L("has a billing problem")
        case "max_output_tokens"?: return L("ran out of output tokens")
        case "server_error"?: return L("got a server error")
        default: return L("stopped with an error")
        }
    }
}

final class AgentExtras: ObservableObject {
    static let shared = AgentExtras()
    @Published private(set) var bySession: [String: AgentExtra] = [:]
    static let maxSessions = 100

    /// Takes an event's details. Pure enough to test: no I/O.
    func take(session: String, event e: [String: Any], now: Date = Date()) {
        var x = bySession[session] ?? AgentExtra()
        x.at = now
        if let m = e["message"] as? String { x.message = String(m.prefix(AgentEventHook.maxMessage)) }
        if let b = e["background"] as? Int { x.background = max(0, min(b, 999)) }
        if e["kind"] as? String == "error" { x.error = AgentExtra.errorText(e["error"] as? String ?? "unknown") }
        else if e["kind"] as? String == "done" || e["kind"] as? String == "start" { x.error = nil }
        if let n = e["notification"] as? String { x.notice = n }
        if let steps = e["steps"] as? [[String: String]] {
            x.steps = steps.compactMap { s in s["step"].map { ($0, s["status"] ?? "pending") } }
            x.explanation = e["explanation"] as? String
        }
        bySession[session] = x
        if bySession.count > Self.maxSessions {
            let old = bySession.sorted { $0.value.at < $1.value.at }.prefix(bySession.count - Self.maxSessions).map(\.key)
            old.forEach { bySession[$0] = nil }
        }
    }

    func forget(keeping ids: Set<String>) {
        let gone = bySession.keys.filter { !ids.contains($0) }
        if !gone.isEmpty { gone.forEach { bySession[$0] = nil } }
    }

    subscript(_ id: String) -> AgentExtra? { bySession[id] }
}

extension Settings {
    /// The cards show a finished session's last message (kept in memory only). Off: never shown.
    var agentPreview: Bool { get { flag("agentPreview", true) } nonmutating set { d.set(newValue, forKey: "agentPreview") } }
}

// MARK: - Tests (part of --agents-test)

enum AgentEventTests {
    static func run(_ check: (String, Bool) -> Void) {
        // The docs' sample payloads (code.claude.com/docs/en/hooks, October 2026).
        let stop: [String: Any] = ["session_id": "abc123", "prompt_id": "550e8400-e29b-41d4-a716-446655440000", "hook_event_name": "Stop",
                                   "last_assistant_message": "I've completed the analysis...",
                                   "background_tasks": [["tool_name": "Bash", "run_in_background": true, "description": "Running tests"]]]
        let e = AgentEventHook.event(kind: "done", input: stop)
        check("events: Stop → session, last message, background tasks, running count",
              e["session"] as? String == "abc123" && e["message"] as? String == "I've completed the analysis..." && e["background"] as? Int == 1 && e["running"] as? Int == 1)
        let failure = AgentEventHook.event(kind: "error", input: ["session_id": "abc123", "hook_event_name": "StopFailure", "error_type": "rate_limit", "error_message": "Rate limit exceeded"])
        check("events: StopFailure → its error type and text", failure["error"] as? String == "rate_limit" && failure["errorText"] as? String == "Rate limit exceeded")
        let long = AgentEventHook.event(kind: "done", input: ["session_id": "s;rm -rf", "last_assistant_message": String(repeating: "x", count: 50_000)])
        check("events: the message is bounded, the session id cleaned", (long["message"] as? String)?.count == AgentEventHook.maxMessage && long["session"] as? String == "srm-rf")
        let plan = AgentEventHook.event(kind: "plan", input: ["session_id": "c", "tool_name": "update_plan",
            "tool_input": ["explanation": "why", "plan": [["step": "Read", "status": "completed"], ["step": "Write", "status": "in_progress"]]]])
        check("events: Codex update_plan → its steps (read-only)", (plan["steps"] as? [[String: String]])?.map { $0["step"]! } == ["Read", "Write"])

        let x = AgentExtras()
        x.take(session: "abc123", event: e)
        x.take(session: "abc123", event: failure)
        check("extras: a card keeps the last message and says the error in words",
              x["abc123"]?.message == "I've completed the analysis..." && x["abc123"]?.error == AgentExtra.errorText("rate_limit") && x["abc123"]?.background == 1)
        x.take(session: "abc123", event: ["kind": "done"])
        check("extras: a later finish clears the error", x["abc123"]?.error == nil)
        for i in 0..<(AgentExtras.maxSessions + 20) { x.take(session: "s\(i)", event: ["kind": "done", "message": "m"], now: Date(timeIntervalSince1970: Double(i))) }
        check("extras: at most \(AgentExtras.maxSessions) sessions are kept in memory", x.bySession.count == AgentExtras.maxSessions && x["s0"] == nil)
        x.forget(keeping: ["s119"])
        check("extras: sessions gone from the board are forgotten", x.bySession.keys.sorted() == ["s119"])
    }
}
