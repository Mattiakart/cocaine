### AI integrations: what Cocaine really detects, tool by tool

Cocaine learns about AI sessions in five ways, and only these:

1. **Hooks** — the tool's own documented hook (or plugin) system. Cocaine writes its hooks into the tool's config when you turn the tool on in *AI alerts → Detected environments* and removes only its own when you turn it off. This is the only way to know a session is *working*, *finished* or *waiting for you*.
2. **Claude Code's session files** — `~/.claude/sessions/<pid>.json`, which Claude Code keeps for each running session (seen on 2.1.292). The file holds the session id, folder, process and `busy` / `idle`. It is **undocumented**: Cocaine reads only those fields, never the conversation or the `name` field, which is taken from it.
3. **CLI processes** — a known CLI (`codex`, `opencode`, `goose`, `kiro-cli`, `cursor-agent`) started from a shell on a terminal is an open session. When the process exits, the session has ended. Cocaine reads the process's name, path, parent, terminal and folder, never its arguments, which can hold a prompt.
4. **Apps** — an app starting or quitting (NSWorkspace). When an app quits, the sessions that ran inside it end too. This fixes ChatGPT-app threads that stayed "working" after the app was quit.
5. **Web chats** — opt-in, *Web chats* switch. The script asks each open browser (Safari, Chrome, Edge, Brave, Vivaldi, Chromium, Arc) only for the **addresses** of chat-site tabs. It filters inside the browser, so no other tab's address leaves the browser, and it never reads titles or page content. It needs *Automation* permission for each browser, asked only when you turn the switch on. Without permission, that browser is skipped.

The same session seen in several ways is **one row**, identified in this order:
- the tool's session id;
- the same process (pid and start time) for tools that run one session per process;
- the tab's address;
- otherwise a new row.

Sources rank hook > session file > process > app > tab. A weaker source changes a row's state only when the stronger one has been silent for 10 minutes. "Ended" always counts: process gone, app quit, tab closed or `SessionEnd`. It removes the row, unless the row shows a result (finished, error), which then fades as usual. A finished session whose process still runs turns into "Session open" after 30 minutes. An open session never keeps the Mac awake. The rules are in `Sources/AgentIngest.swift` and are covered by `--agents-test`.

**Legend.** *Supported*: an official, documented mechanism (hook schema checked; the installer is tested in a temporary home). *Partial*: a heuristic, explained below. *Not possible*: the tool offers nothing that can be observed from outside, explained below. *Unverified*: documented, but its exact behaviour couldn't be checked. *Tried live*: seen working on a real session on the Mac this was built on.

The table is generated from the code: `Cocaine --ai-environments matrix`. A test checks that this file matches it.

| Environment | Kind | Session open | Processing | Response completed | Needs you | Activity ended | Open the session | Tried live |
|---|---|---|---|---|---|---|---|---|
| Claude Code | cli | Supported | Supported | Supported | Supported | Supported | Supported | yes |
| Claude Desktop · Code | desktop | Supported | Supported | Supported | Unverified | Unverified | Partial | no |
| Claude Cowork | desktop | Partial | Not possible | Not possible | Not possible | Partial | Partial | no |
| Claude Desktop (chat) | desktop | Partial | Not possible | Not possible | Not possible | Partial | Partial | no |
| Codex CLI | cli | Supported | Supported | Supported | Supported | Supported | Supported | no |
| ChatGPT · Codex | desktop | Supported | Supported | Supported | Supported | Partial | Supported | no |
| Codex IDE extension | ide | Supported | Supported | Supported | Supported | Partial | Partial | no |
| ChatGPT (chat) | desktop | Partial | Not possible | Not possible | Not possible | Partial | Partial | no |
| Gemini CLI | cli | Supported | Supported | Supported | Supported | Supported | Supported | no |
| Antigravity | ide | Partial | Not possible | Not possible | Not possible | Partial | Partial | no |
| Copilot CLI | cli | Supported | Supported | Supported | Unverified | Supported | Supported | no |
| Copilot in VS Code | ide | Unverified | Unverified | Unverified | Not possible | Unverified | Partial | no |
| Cursor | ide | Supported | Supported | Supported | Not possible | Supported | Partial | no |
| Windsurf | ide | Partial | Supported | Supported | Not possible | Partial | Partial | no |
| Kiro | ide | Partial | Not possible | Not possible | Not possible | Partial | Partial | no |
| Zed | ide | Partial | Not possible | Not possible | Not possible | Partial | Partial | no |
| JetBrains AI / Junie | ide | Partial | Not possible | Not possible | Not possible | Partial | Partial | no |
| Warp | ide | Partial | Not possible | Not possible | Not possible | Partial | Partial | no |
| Aider | cli | Not possible | Not possible | Partial | Partial | Not possible | Partial | no |
| Cline | ide | Not possible | Partial | Partial | Not possible | Not possible | Partial | no |
| Goose | cli | Partial | Not possible | Not possible | Not possible | Partial | Partial | no |
| Amp | cli | Not possible | Not possible | Not possible | Not possible | Not possible | Not possible | no |
| OpenCode | cli | Partial | Not possible | Supported | Supported | Partial | Supported | no |
| Qwen Code | cli | Not possible | Supported | Supported | Unverified | Not possible | Supported | no |
| Perplexity | desktop | Partial | Not possible | Not possible | Not possible | Partial | Partial | no |
| Microsoft Copilot | desktop | Partial | Not possible | Not possible | Not possible | Partial | Partial | no |
| Claude (web) | web | Partial | Not possible | Not possible | Not possible | Partial | Supported | no |
| ChatGPT (web) | web | Partial | Not possible | Not possible | Not possible | Partial | Supported | no |
| Gemini (web) | web | Partial | Not possible | Not possible | Not possible | Partial | Supported | no |
| Copilot (web) | web | Partial | Not possible | Not possible | Not possible | Partial | Supported | no |
| Perplexity (web) | web | Partial | Not possible | Not possible | Not possible | Partial | Supported | no |
| Le Chat (web) | web | Partial | Not possible | Not possible | Not possible | Partial | Supported | no |
| DeepSeek (web) | web | Partial | Not possible | Not possible | Not possible | Partial | Supported | no |
| Grok (web) | web | Partial | Not possible | Not possible | Not possible | Partial | Supported | no |

#### Evidence and limits, per environment

- **Claude Code (CLI, IDE extensions)**
  - **Hooks** ([code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks)):
    - `SessionStart` (startup, resume and clear; not compact) → open
    - `UserPromptSubmit` → working
    - `Stop` → finished
    - `Notification` (permission_prompt, elicitation_dialog), `PermissionRequest` and `Elicitation` → needs you
    - `StopFailure` → error
    - `SessionEnd` → ended
  - **Session file:** `~/.claude/sessions/<pid>.json` (undocumented). On this Mac, `Cocaine --ai-environments scan` showed one busy and one idle session, with their terminal.
  - **Going back:** the exact Terminal/iTerm2 tab (Automation permission), the tmux pane or the WezTerm pane. For a VS Code-family IDE, its window by folder.
  - **Deep link:** `claude-cli://open?cwd=…&q=…` ([deep links](https://code.claude.com/docs/en/deep-links)) only *starts a new* session. It can't resume one, so it isn't used.
- **Claude Desktop · Code tab**
  - "Hooks and skills defined in settings apply to both" the CLI and Desktop ([code.claude.com/docs/en/desktop](https://code.claude.com/docs/en/desktop)). The same hooks therefore report open, working and finished; the app is recognised by its bundle id `com.anthropic.claudefordesktop`.
  - Needs-you and ended: whether Desktop fires `Notification` and `SessionEnd` was not verified.
  - Going back: there is no documented `claude://` link to a session (the app registers `claude://`; `NSUserActivityTypes` includes `com.anthropic.claude.code.session`, for Handoff only). Cocaine brings Claude forward and says it can't pick the conversation.
- **Claude Cowork**
  - Cowork runs Claude Code in a sandboxed VM, which does not read the host's `~/.claude/settings.json`, so hooks don't fire. This is reported in [issue 40495](https://claudeissues.com/issue/40495-bug-cowork-sessions-ignore-user-hooks-and-managed-settings-sandbox-platform-mism).
  - Cocaine only knows whether Claude is open, and that its sessions end when it quits.
  - The app's `local-agent-mode-sessions` folder is not read: it holds session data, and its timestamps are not a reliable state signal.
- **Claude Desktop (chat), ChatGPT (chat), Perplexity, Microsoft Copilot, Zed, JetBrains, Warp, Antigravity, Kiro**
  - None of these offers hooks or local state that tells working, finished or needs-you apart. Cocaine sees only whether the app runs or quits.
  - Their own notifications can't be read by another app (macOS has no API for that).
  - Zed has built-in "agent waiting" notifications. Warp sends its agent notifications as an in-terminal escape sequence (OSC 777) to itself. Antigravity has no hooks ([forum](https://discuss.ai.google.dev/t/does-antigravity-support-hooks-similar-to-the-hook-functionality-in-windsurf/121062)). Kiro's CLI hooks exist, but their config path couldn't be confirmed, so Cocaine doesn't write them.
  - Window titles are not read: Accessibility is never required, and the titles carry no state.
- **Codex: CLI, the ChatGPT app with Codex (`/Applications/ChatGPT.app`, bundle `com.openai.codex`), IDE extension**
  - **Hooks** ([learn.chatgpt.com/docs/hooks](https://learn.chatgpt.com/docs/hooks)) run "in the desktop app, IDE extension, CLI":
    - `SessionStart` → open
    - `UserPromptSubmit` → working
    - `Stop` → finished
    - `PermissionRequest` → needs you (answerable from the island)
    - `SessionEnd` → ended
  - **Trust:** after an update Codex asks to trust the changed hooks once. The AI tab warns about this.
  - **ChatGPT-app threads open by their documented link** `codex://threads/<thread-id>` ([commands reference](https://learn.chatgpt.com/docs/reference/commands)). `codex` is in the app's `CFBundleURLSchemes`, and LaunchServices resolves it to the app (tested read-only). Opening it on a real thread was not tried.
  - **Ended in the app** is partial: the app keeps threads alive, so only quitting the app ends them on the board.
  - **CLI processes** are seen directly. The app's own embedded `codex` processes are not counted as sessions.
- **ChatGPT, Claude, Gemini, Copilot, Perplexity, Le Chat, DeepSeek, Grok on the web**
  - Hosts: `chatgpt.com`, `chat.openai.com`, `claude.ai`, `gemini.google.com`, `copilot.microsoft.com`, `github.com/copilot`, `perplexity.ai`, `chat.mistral.ai`, `chat.deepseek.com`, `grok.com`.
  - Open and closed come from the tab's address. Clicking selects that tab.
  - Processing, completed and needs-you are not possible: the address doesn't change while a reply is written, and reading the page would need a browser extension (out of scope) or "Allow JavaScript from Apple Events", which Cocaine refuses to require.
  - Not tried live: no real chat tabs were read while building this.
- **Gemini CLI**
  - **Hooks** ([geminicli.com/docs/hooks](https://geminicli.com/docs/hooks/)):
    - `SessionStart` → open
    - `BeforeAgent` → working
    - `AfterAgent` → finished
    - `Notification` (`ToolPermission`) → needs you
    - `SessionEnd` → ended
  - Not installed on this Mac.
- **GitHub Copilot**
  - **CLI hooks** in `~/.copilot/hooks/cocaine.json` ([docs.github.com hooks configuration](https://docs.github.com/en/copilot/reference/hooks-configuration)):
    - `sessionStart` → open
    - `userPromptSubmitted` → working
    - `agentStop` → finished
    - `errorOccurred` → error
    - `sessionEnd` → ended
    - `notification` → needs you (the matcher values are not documented, so *unverified*)
  - **VS Code** reads `~/.copilot/hooks/*.json` ([VS Code hooks](https://code.visualstudio.com/docs/copilot/customization/hooks)) but documents PascalCase events (`Stop`, `SessionStart`…), and has no notification event. Whether it runs the CLI's camelCase events is unverified.
- **Cursor**
  - **Hooks** ([cursor.com/docs/agent/hooks](https://cursor.com/docs/agent/hooks)):
    - `sessionStart` → open
    - `beforeSubmitPrompt` → working
    - `stop` → finished
    - `sessionEnd` → ended
  - Cursor has no "needs you" event.
  - Going back: its window, by folder.
- **Windsurf (Devin Desktop)**
  - **Hooks** ([docs.devin.ai cascade hooks](https://docs.devin.ai/desktop/cascade/hooks)):
    - `pre_user_prompt` → working
    - `post_cascade_response` → finished
  - There is no session or approval event.
  - The bundle id `com.exafunction.windsurf` couldn't be confirmed.
- **OpenCode**
  - Its plugin ([opencode.ai/docs/plugins](https://opencode.ai/docs/plugins/)):
    - `session.idle` → finished
    - `permission.asked` / `question.asked` → needs you
    - `session.error` → error
  - Session open and ended come from its process.
- **Qwen Code**
  - Claude-style hooks: `UserPromptSubmit` → working, `Stop` → finished.
  - The `Notification` event is unconfirmed.
- **Aider**
  - Set it up by hand: `aider --notifications-command 'open -g "cocaine://alert?from=Aider&event=done"'`. Aider runs that command when a reply is ready and it waits for input ([aider notifications](https://aider.chat/docs/usage/notifications.html)).
- **Cline**
  - Hooks such as `TaskStart` and `TaskComplete` are executable files in `~/Documents/Cline/Hooks/` ([docs.cline.bot hooks](https://docs.cline.bot/features/hooks)). Cocaine doesn't write into Documents, which would need the Files permission, so you can add a one-line hook that opens `cocaine://alert?from=Cline&event=done` yourself.
- **Goose, Amp**
  - Goose: no hooks found. Its CLI process is seen when it runs in a terminal.
  - Amp: no documented hook or local state was found.

#### What is not done, on purpose

- No conversation, prompt, chat title, browser history or page content is read.
- The other tabs' addresses never leave the browser.
- A process's arguments are never read.
- Accessibility (window titles) is never required.
- A browser that hasn't allowed Automation is skipped, and you're never asked again in the background.
