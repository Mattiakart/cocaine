# Plan review, questions and requests from the island

With **Answer from the island** on (AI alerts → When, off by default), what an AI agent asks you shows up in the open island (its
whole page) and in the panel's Agents card, and you can answer it there. Everything goes through the tools' own documented hooks
and Cocaine's private socket (0600, answers signed with a per-install key). **Nothing is ever approved on its own**: no answer
within 2 minutes, Cocaine not running, a socket or signature problem, or anything that doesn't fit the request, and the tool asks
in the terminal as usual. **In the terminal** hands a request back at once; **Later** puts it aside (it keeps waiting, the
island shows its pages again).

## What can be answered

| Request | Tool and hook | From the island |
|---|---|---|
| **Plan** (plan mode, `ExitPlanMode`) | Claude Code `PreToolUse`, matcher `ExitPlanMode` | The plan in rendered Markdown (headings, lists, task boxes, code blocks, tables, quotes, bold/italic/code, http(s) links). **Approve** → `allow` with the input echoed as `updatedInput` (the docs say `allow` alone isn't enough). **Feedback…** → `deny` with your text as `permissionDecisionReason`: Claude reads it and stays in plan mode to revise. |
| **Question** (`AskUserQuestion`) | Claude Code `PreToolUse`, matcher `AskUserQuestion` | Its 1–4 questions, one page each, with their options (⌘1–9), multi-select, and **Or type your own answer**. **Send answers** → `allow` with `updatedInput` = the original `questions` + `answers` (question text → label; several labels joined with ", "). Feedback is possible too (a `deny` with your text). |
| **Permission** | Claude Code and Codex `PermissionRequest` | The **whole** input: the command as it is, an Edit/MultiEdit/Write as a coloured diff, every other field. **Allow**, **Deny** (optionally **with a reason** that the model reads as `message`), and for Claude Code **Always allow**: one of the rules Claude Code itself suggests (`permission_suggestions`), echoed as `updatedPermissions`. Codex has no "always" (its hooks fail closed on it). |
| **MCP question** (`Elicitation`) | Claude Code | As before: one button per value of a single choice or yes/no field, else Decline. |

A short request whose single field fits on a list row (a short command, a Read, a search) can still be answered right in the
row; anything else opens **Review** first, so you always see all of what you allow. The old rule that hid **Allow** for anything
longer than 120 characters is gone: the review scrolls instead.

## Safety

- **You see what you approve.** Text from the agent is shown with control characters and text-direction overrides as visible marks.
  If the hook had to cut something (a plan longer than 256 000 characters, any other text longer than 64 000, lists longer than
  500 items: what crosses the socket is bounded), the review says so and **nothing can be granted from the island**: only
  Feedback, Deny or the terminal.
- **The hook decides what goes back.** The app only says *which* answer; the echoed plan, the questions answered and the rule
  for "Always allow" come from the hook's own copy of what the tool sent. Answers that don't match the questions (another
  question's text, a missing one) make no decision.
- **Keys are local.** ⌘Y (allow / approve / send answers), ⌘N (deny / feedback), ⌘1–9 (options, Always allow), ⌘↩ (send),
  ⌘L (later) work only while the island has the keyboard (⌃⌥⌘I, or after clicking its text field) or in the panel. They are
  never global shortcuts: other apps keep their ⌘Y and ⌘N.
- **First answer wins.** A second click, a click after the 2 minutes, or after the request was handed back sends nothing.

## Limits (honestly)

- **"Approve, accept edits"** is offered only when Claude Code asks for the plan through `PermissionRequest` (then
  `updatedPermissions: setMode acceptEdits` is the documented way). Through `PreToolUse`, the usual path, Approve keeps the
  current mode. Whether Claude Code also sends ExitPlanMode through `PermissionRequest` was not verified live.
- While the island holds a plan or a question, Claude Code's own dialog is not shown yet (the hook is waiting) — use
  **In the terminal** to answer there; the same plan or question is then not held a second time.
- The plan and question hooks need Claude Code 2.1.78 or newer (older ones get only the permission hooks). Its version is read
  with a login shell, else from its usual install folders (the native installer, nvm, Homebrew, npm); when it can't be read this
  time (a slow shell, a setup Cocaine can't see), the request hooks already there are kept as they are, and none are added.
- **Codex plans** (`update_plan`) are shown read-only on the session's card (steps done / total, the step in progress), through a
  `PostToolUse` hook that runs Cocaine's binary; Codex asks you to trust that new hook once (`/hooks`). Codex's plan-mode
  "Implement this plan?" can't be answered from outside. **Gemini CLI** plans: no documented hook to show or answer them.
- Live end-to-end tests against a real Claude Code session were not run in the build environment; the hook formats are tested
  against the docs' own sample payloads.

## Session cards

A finished session's card shows the start of its last reply (Claude Code's `Stop` hook `last_assistant_message`, at most 4 000
characters kept, **in memory only**, never in `state.json`; turn off **Last message on the cards** to never show it), the tasks
still running in the background, why it failed (`StopFailure`: usage limit, overloaded, billing…), and for Codex its plan's
progress. These details go over the private socket (`Cocaine --agent-event`), not through `cocaine://` links.
