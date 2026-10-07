// Render fixtures for the review and the limits (--render-island / --render-panel): --plan-fixture [--feedback],
// --question-fixture, --diff-fixture, --quota-fixture, --expanded (the panel's review open). Samples only: never a real
// session, plan or limit.

import AppKit

enum ReviewFixtures {
    static func apply(_ args: [String], pm: PanelModel, usage: UsageWatch?) {
        let review = ApprovalReviewModel.shared
        var list: [ApprovalRequest] = []
        let origin = AgentOrigin(cwd: "/Users/x/canonical-com")
        if args.contains("--plan-fixture") {
            var input = ReviewTests.planInput
            input["tool_input"] = ["plan": samplePlan, "planFilePath": "/Users/x/.claude/plans/notch-review.md"]
            if var r = ApprovalRequest.make(id: "FIXTURE-PLAN", nonce: ReviewTests.nonce, tool: "claude", input: input, origin: origin, now: Date()) {
                if args.contains("--feedback") { review.writing = r.id; review.text = "Split step 2, and add a test for the 1 MB plan" }
                r.session = "fixture-plan"
                list.append(r)
            }
        }
        if args.contains("--question-fixture"),
           var r = ApprovalRequest.make(id: "FIXTURE-QUES", nonce: ReviewTests.nonce, tool: "claude", input: ReviewTests.questionInput, origin: origin, now: Date()) {
            r.session = "fixture-question"
            review.picks[r.id] = [0: ["React"]]
            list.append(r)
        }
        if args.contains("--diff-fixture") {
            let input: [String: Any] = ["session_id": "fixture-diff", "hook_event_name": "PermissionRequest", "tool_name": "Edit",
                                        "tool_input": ["file_path": "/Users/x/canonical-com/Sources/Island.swift",
                                                       "old_string": "let width = 640\nlet height = 214\nreturn size",
                                                       "new_string": "let width = 640\nlet height = 260 // room for the review\nlet inset = 18\nreturn size"],
                                        "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Edit"]], "behavior": "allow", "destination": "session"]]]
            if let r = ApprovalRequest.make(id: "FIXTURE-DIFF", nonce: ReviewTests.nonce, tool: "claude", input: input, origin: origin, now: Date()) { list.append(r) }
        }
        if !list.isEmpty {
            pm.approvals = list + pm.approvals
            if args.contains("--expanded") { review.expanded = list[0].id }
        }
        if args.contains("--quota-fixture"), let u = usage {
            let now = Date()
            u.claudeLimits = [QuotaWindow(id: "five_hour", minutes: 300, percent: 23, resets: now.addingTimeInterval(3 * 3600 + 600)),
                              QuotaWindow(id: "seven_day", minutes: 10080, percent: 91, resets: now.addingTimeInterval(2 * 86400 + 4 * 3600))]
            u.claudeLimitsOn = true
            u.codex = [UsageWatch.Limit(id: "codex10080", name: Quotas.windowName(10080), percent: 36, resets: now.addingTimeInterval(5 * 86400), minutes: 10080)]
            u.codexPlan = "prolite"
            u.loaded = true
        }
        if args.contains("--extras-fixture") {             // the cards' extras on the sample sessions (AgentTests.sample)
            let x = AgentExtras.shared
            x.take(session: "c", event: ["kind": "done", "message": "## Done\n\nAll **42 tests** pass; the review renders plans and diffs.", "background": 0])
            x.take(session: "d", event: ["kind": "error", "error": "rate_limit"])
            x.take(session: "a", event: ["kind": "done", "background": 2])
            x.take(session: "g", event: ["kind": "plan", "steps": [["step": "Read the hook docs", "status": "completed"],
                                                                   ["step": "Parse update_plan", "status": "in_progress"], ["step": "Tests", "status": "pending"]]])
        }
    }

    static let samplePlan = """
    # Plan: review plans from the notch

    Read **ExitPlanMode** through the `PreToolUse` hook and show it here.

    ## Steps
    1. Capture the plan and its file
    2. Render the Markdown (headings, lists, `code`, tables)
    3. Approve, or send feedback that Claude reads
    - [x] Read the hooks reference
    - [ ] Test a 1 MB plan

    ```swift
    out["updatedInput"] = toolInput
    ```

    | Answer | Hook output |
    |--------|-------------|
    | Approve | allow + updatedInput |
    | Feedback | deny + reason |

    > Nothing is ever approved on its own.
    """
}
