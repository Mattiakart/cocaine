// Tests of the review (part of --agents-test and --selftest): plans and questions read from the docs' own sample payloads,
// what each can be answered with, the request state machine for them, the hook output for every answer, the keys, the diff,
// the bounding of a long input. Pure: no socket (AgentTests.protocolTests does the real one).

import AppKit

enum ReviewTests {
    static let nonce = String(repeating: "ab", count: 16)
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func make(_ input: [String: Any], tool: String = "claude", id: String = "REQ-PLAN0001") -> ApprovalRequest? {
        ApprovalRequest.make(id: id, nonce: nonce, tool: tool, input: input, origin: AgentOrigin(), now: now)
    }

    /// The docs' AskUserQuestion example (code.claude.com/docs/en/hooks), plus a second, multi-select question.
    static let questionInput: [String: Any] = ["session_id": "q", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_use_id": "toolu_q1",
        "tool_input": ["questions": [
            ["question": "Which framework?", "header": "Framework", "multiSelect": false,
             "options": [["label": "React", "description": "Component library"], ["label": "Vue", "description": "Progressive framework"]]],
            ["question": "Which extras?", "header": "Extras", "multiSelect": true,
             "options": [["label": "Router"], ["label": "Store"], ["label": "Tests"]]]]]]

    static let planInput: [String: Any] = ["session_id": "p", "hook_event_name": "PreToolUse", "tool_name": "ExitPlanMode", "tool_use_id": "toolu_p1",
                                          "permission_mode": "plan",
                                          "tool_input": ["plan": "## Refactor auth\n1. Extract the session store\n2. Add tests", "planFilePath": "/Users/x/.claude/plans/refactor-auth.md"]]

    static func wire(_ decision: String, _ content: String? = nil, input: [String: Any], tool: String = "claude") -> String? {
        let key = Data((0..<32).map { UInt8($0) })
        let line = ApprovalWire.answer(key: key, id: "REQ-PLAN0001", nonce: nonce, decision: decision, content: content).dropLast()
        return ApprovalWire.hookOutput(answer: line, key: key, id: "REQ-PLAN0001", nonce: nonce, tool: tool, input: input)
    }

    static func run(_ check: (String, Bool) -> Void) {
        // Plans.
        let plan = make(planInput)
        check("plans: ExitPlanMode through PreToolUse is a plan to review, with its Markdown and file",
              plan?.kind == .plan && plan?.answerable == true && plan?.allowable == true && plan?.plan?.hasPrefix("## Refactor auth") == true
              && plan?.planFile == "/Users/x/.claude/plans/refactor-auth.md" && plan?.acceptEdits == false && plan?.toolUseID == "toolu_p1")
        var viaPR = planInput; viaPR["hook_event_name"] = "PermissionRequest"
        check("plans: through PermissionRequest it can also switch to accepting edits", make(viaPR)?.acceptEdits == true)
        var noPlan = planInput; noPlan["tool_input"] = [:] as [String: Any]
        check("plans: no plan text → nothing to review here, the terminal asks", make(noPlan)?.answerable == false)
        check("plans: Codex has no plan review (only Claude Code's hook answers it)", make(planInput, tool: "codex") == nil)
        var otherPre = planInput; otherPre["tool_name"] = "Bash"
        check("plans: PreToolUse for any other tool is never taken", make(otherPre) == nil)
        if let p = plan {
            check("plans: approve and feedback are valid; accept-edits only through PermissionRequest; empty feedback isn't",
                  p.accepts(ApprovalReply(decision: "approve")) && p.accepts(ApprovalReply(decision: "feedback", content: "more tests"))
                  && !p.accepts(ApprovalReply(decision: "approve-edits")) && !p.accepts(ApprovalReply(decision: "feedback", content: "  "))
                  && !p.accepts(ApprovalReply(decision: "allow")) && !p.accepts(ApprovalReply(decision: "feedback", content: String(repeating: "x", count: 9000))))
        }
        var cut = planInput; cut["_cocaine_truncated"] = true
        check("plans: a plan cut on the way can't be approved here, only sent back with feedback",
              make(cut)?.allowable == false && make(cut)?.accepts(ApprovalReply(decision: "approve")) == false
              && make(cut)?.accepts(ApprovalReply(decision: "feedback", content: "shorter please")) == true)

        // Questions.
        let q = make(questionInput)
        check("questions: AskUserQuestion's questions, headers, options and multi-select are read",
              q?.kind == .question && q?.questions.count == 2 && q?.questions[0].header == "Framework" && q?.questions[1].multiSelect == true
              && q?.questions[0].options.map(\.label) == ["React", "Vue"])
        var dup = questionInput
        dup["tool_input"] = ["questions": [["question": "Same?", "options": [["label": "a"]]], ["question": "Same?", "options": [["label": "b"]]]]]
        var five = questionInput
        five["tool_input"] = ["questions": (0..<5).map { ["question": "Q\($0)?", "options": [["label": "a"]]] }]
        check("questions: repeated question texts or more than four questions → the terminal asks", make(dup)?.answerable == false && make(five)?.answerable == false)
        if let q {
            let both = ApprovalReviewModel.answerContent(["Which framework?": "React", "Which extras?": "Router, Tests"])!
            check("questions: only answers to every question, by their exact text, are accepted",
                  q.accepts(ApprovalReply(decision: "answer", content: both))
                  && !q.accepts(ApprovalReply(decision: "answer", content: ApprovalReviewModel.answerContent(["Which framework?": "React"])))
                  && !q.accepts(ApprovalReply(decision: "answer", content: ApprovalReviewModel.answerContent(["which framework?": "React", "Which extras?": "x"])))
                  && !q.accepts(ApprovalReply(decision: "answer", content: "not json")))
            check("questions: picks become the answer (multi-select joined with \", \" in the options' order), a typed one too",
                  ApprovalReviewModel.answers(q, picks: [0: ["React"], 1: ["Tests", "Router"]], custom: [:]) == ["Which framework?": "React", "Which extras?": "Router, Tests"]
                  && ApprovalReviewModel.answers(q, picks: [0: []], custom: [0: "Svelte", 1: "none"]) == ["Which framework?": "Svelte", "Which extras?": "none"]
                  && ApprovalReviewModel.answers(q, picks: [0: ["React"]], custom: [:]) == nil)
            let m = ApprovalReviewModel()
            m.toggle(q, question: 0, label: "React"); m.toggle(q, question: 0, label: "Vue")
            m.toggle(q, question: 1, label: "Router"); m.toggle(q, question: 1, label: "Store"); m.toggle(q, question: 1, label: "Router")
            check("questions: a single choice replaces the previous one; a multi-select toggles", m.picks[q.id]?[0] == ["Vue"] && m.picks[q.id]?[1] == ["Store"])
            var sent: [ApprovalReply] = []
            m.reply = { _, r in sent.append(r) }
            check("questions: sending is refused while one is unanswered", { let m2 = ApprovalReviewModel(); m2.reply = { _, r in sent.append(r) }; m2.toggle(q, question: 0, label: "React"); return !m2.submitAnswers(q) && sent.isEmpty }())
        }

        // The state machine for plans and questions: first answer wins, expiry, a hand-back, stale answers.
        if let p = plan, let q {
            var st = ApprovalStore()
            var q = q; q.id = "REQ-QUES0001"; _ = st.add(p); _ = st.add(q)
            check("store: a plan's feedback is sent once; a second click (Approve) sends nothing",
                  st.answer(p.id, reply: ApprovalReply(decision: "feedback", content: "split it"), now: now) == .send(decision: "feedback", content: "split it")
                  && st.answer(p.id, reply: ApprovalReply(decision: "approve"), now: now) == .alreadyAnswered)
            check("store: an invalid answer to a question changes nothing (still waiting)",
                  st.answer(q.id, reply: ApprovalReply(decision: "answer", content: "{}"), now: now) == .unknown && st.state(q.id) == .pending)
            check("store: after the deadline an answer is refused as expired", st.answer(q.id, reply: ApprovalReply(decision: "feedback", content: "x"), now: q.deadline) == .expired)
            var s2 = ApprovalStore()
            var p2 = p; p2.id = "REQ-PLAN0002"
            _ = s2.add(p2)
            check("store: handed back to the terminal, then approved: nothing sent (a stale answer)", s2.release(p2.id, now: now)
                  && s2.answer(p2.id, reply: ApprovalReply(decision: "approve"), now: now) == .alreadyAnswered)
        }

        // The hook's output for each answer (the docs' formats).
        check("wire: plan approve → PreToolUse allow + updatedInput (allow alone isn't enough for ExitPlanMode)",
              wire("approve", input: planInput) == ###"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"plan":"## Refactor auth\n1. Extract the session store\n2. Add tests","planFilePath":"\/Users\/x\/.claude\/plans\/refactor-auth.md"}}}"###
              || (wire("approve", input: planInput)?.contains(###""permissionDecision":"allow","updatedInput":{"plan":"## Refactor auth"###) == true))
        check("wire: plan feedback → deny with permissionDecisionReason", wire("feedback", "add tests", input: planInput)
              == #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"add tests"}}"#)
        check("wire: an approve sent for a question, or an answer for a plan, prints nothing",
              wire("approve", input: questionInput) == nil && wire("answer", #"{"x":"y"}"#, input: planInput) == nil && wire("feedback", "  ", input: planInput) == nil)
        check("wire: plan through PermissionRequest + accept edits → setMode acceptEdits for the session",
              wire("approve-edits", input: viaPR)?.contains(#""updatedPermissions":[{"destination":"session","mode":"acceptEdits","type":"setMode"}]"#) == true
              && wire("approve-edits", input: planInput) == nil)
        let suggestions: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "npm test"],
            "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test"]], "behavior": "allow", "destination": "localSettings"],
                                       ["type": "setMode", "mode": "bypassPermissions", "destination": "session"]]]
        check("wire: Always allow echoes the suggestion picked, as the docs say",
              wire("always", "0", input: suggestions) == #"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedPermissions":[{"behavior":"allow","destination":"localSettings","rules":[{"ruleContent":"npm test","toolName":"Bash"}],"type":"addRules"}]},"hookEventName":"PermissionRequest"}}"#)
        check("wire: …never one out of range, one that can't be said in words (bypass), or for Codex (fails closed there)",
              wire("always", "5", input: suggestions) == nil && wire("always", "1", input: suggestions) == nil && wire("always", "0", input: suggestions, tool: "codex") == nil)
        let req = make(suggestions)
        check("approvals: Always allow is offered for the suggestions it can describe (\(req?.suggestions ?? []))",
              req?.suggestions.count == 1 && req?.suggestions[0].contains("Bash(npm test)") == true
              && req?.accepts(ApprovalReply(decision: "always", content: "0")) == true && req?.accepts(ApprovalReply(decision: "always", content: "1")) == false)

        // Keys: only ⌘ (never with ⌥⌃⇧), local to the island/panel.
        if let p = plan, let q, let r = req {
            typealias E = ApprovalKeys.Effect
            func eff(_ code: UInt16, _ chars: String?, _ r: ApprovalRequest, flags: NSEvent.ModifierFlags = .command, page: Int = 0, writing: Bool = false) -> E? {
                ApprovalKeys.command(code, chars: chars, flags: flags).flatMap { ApprovalKeys.effect($0, r, page: page, writing: writing) }
            }
            check("keys: ⌘Y approves a plan, allows a request, sends a question's answers",
                  eff(16, "y", p) == .send(ApprovalReply(decision: "approve")) && eff(16, "y", r) == .send(ApprovalReply(decision: "allow")) && eff(16, "y", q) == .submitAnswers)
            check("keys: ⌘N denies a request, opens feedback on a plan", eff(45, "n", r) == .send(ApprovalReply(decision: "deny")) && eff(45, "n", p) == .write)
            check("keys: ⌘1–9 pick a question's options on the page shown, or an Always allow",
                  eff(18, "1", q) == .toggle(question: 0, label: "React") && eff(19, "2", q, page: 1) == .toggle(question: 1, label: "Store")
                  && eff(18, "1", r) == .send(ApprovalReply(decision: "always", content: "0")) && eff(23, "5", q) == nil)
            check("keys: without ⌘, or with another modifier too, nothing happens", eff(16, "y", p, flags: []) == nil && eff(16, "y", p, flags: [.command, .shift]) == nil
                  && eff(16, "y", p, flags: [.command, .option]) == nil)
            check("keys: while typing feedback ⌘↩ sends it and ⌘Y doesn't approve", eff(36, "\r", p, writing: true) == .submitWriting && eff(16, "y", p, writing: true) == nil)
            var cutPlan = p; cutPlan.allowable = false
            check("keys: nothing is granted by a key that the review can't grant", eff(16, "y", cutPlan) == nil)
        }

        // The diff.
        let d = Diff.lines(old: ["a", "b", "c"], new: ["a", "x", "c", "d"])
        check("diff: a line diff keeps the common lines (\(d.map { "\($0.kind)" }))",
              d == [DiffLine(kind: .context, text: "a"), DiffLine(kind: .add, text: "x"), DiffLine(kind: .remove, text: "b"),
                    DiffLine(kind: .context, text: "c"), DiffLine(kind: .add, text: "d")]
              || d == [DiffLine(kind: .context, text: "a"), DiffLine(kind: .remove, text: "b"), DiffLine(kind: .add, text: "x"),
                       DiffLine(kind: .context, text: "c"), DiffLine(kind: .add, text: "d")])
        let big = Diff.lines(old: (0..<600).map { "o\($0)" }, new: (0..<600).map { "n\($0)" })
        check("diff: past its size it lists old then new, quickly", big.count == 1200 && big.first?.kind == .remove && big.last?.kind == .add)
        let edit = ApprovalDetail.make(tool: "MultiEdit", input: ["file_path": "/a.swift", "edits": [["old_string": "x", "new_string": "y", "replace_all": true]]])
        check("diff: MultiEdit's changes each get a header, every field shown", edit.file == "/a.swift" && edit.diff.first?.kind == .header && edit.diff.count == 3 && edit.fields.isEmpty)

        // Bounding what the hook sends.
        let huge = ApprovalHook.bounded(["tool_input": ["plan": String(repeating: "p", count: 300_000), "content": String(repeating: "c", count: 70_000),
                                                         "list": Array(repeating: 1, count: 600)] as [String: Any]])
        let hi = huge["tool_input"] as? [String: Any]
        check("bounded: a plan is cut at 256 K, other texts at 64 K, lists at 500, and marked",
              (hi?["plan"] as? String)?.count == 256_000 && (hi?["content"] as? String)?.count == 64_000 && (hi?["list"] as? [Any])?.count == 500
              && huge["_cocaine_truncated"] as? Bool == true)
        check("bounded: a normal input is unchanged and unmarked", ApprovalHook.bounded(planInput)["_cocaine_truncated"] == nil
              && ((ApprovalHook.bounded(planInput)["tool_input"] as? [String: Any])?["plan"] as? String) == (planInput["tool_input"] as? [String: Any])?["plan"] as? String)
        check("hook: answers PreToolUse only for a plan or a question, and only Claude Code's",
              ApprovalHook.handles(tool: "claude", planInput) && ApprovalHook.handles(tool: "claude", questionInput) && !ApprovalHook.handles(tool: "codex", planInput)
              && !ApprovalHook.handles(tool: "claude", ["hook_event_name": "PreToolUse", "tool_name": "Bash"]))

        // The hooks file: the PreToolUse hook for plans and questions is installed with its matcher.
        if let claude = AIHooks.tool("claude") {
            check("hooks: Claude Code gets a PreToolUse hook for ExitPlanMode|AskUserQuestion",
                  claude.events.contains { $0.name == "PreToolUse" && $0.matcher == "ExitPlanMode|AskUserQuestion" && $0.kind == "approve" }
                  && claude.events.contains { $0.name == "Notification" && $0.matcher?.contains("agent_needs_input") == true })
        }
        if let codex = AIHooks.tool("codex") {
            check("hooks: Codex keeps its alert commands (no new trust needed for them); its plan news only via the app's binary",
                  codex.stableCommands && !AIHooks.command(codex, "done").contains("KITTY") && AIHooks.command(codex, "plan").hasPrefix(AIHooks.binary == nil ? "true" : "'"))
        }
    }
}
