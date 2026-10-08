# AI context (MCP)

Cocaine can give AI tools (Claude Code, Claude Desktop, Codex, Cursor, Gemini CLI and any other MCP client) **exactly the items
you choose**, and nothing else. You put clipboard items, shelf files and typed notes in the **AI context** from the notch; a tool
you connected and allowed reads them through the Model Context Protocol (MCP). It never sees your clipboard history, your other
files, or anything you didn't put there.

It is **off by default**: Settings → AI → *AI context (MCP)* → *Let AI tools read the AI context*.

## Filling the AI context

- **Clipboard** (island → Clipboard): select items → *Use as AI context*.
- **Shelf** (island → Shelf): select files, images, links or text → *Use as AI context*.
- **Typed text**: the **+** of the *AI context* module.
- **When the AI asks** (`cocaine_request`): the notch shows its reason and up to four recent items (clipboard and shelf) to tick;
  *Share* sends only the ticked ones (they are added to the AI context), *Decline* or Esc sends nothing. No answer within 45
  seconds is a refusal.

The *AI context* module (Settings → Island → Screens, add it to any screen) shows the count and *Clear* (S), the list with a × per
item (M), and the list with previews and which tools are allowed (L).

Items are held **by reference**: a clipboard item's id, a file's path. Their content is read only when a tool asks, so a deleted
clipboard item or a moved file is simply gone. Items leave after **8 hours** (1 h, 8 h, 24 h or never), or with *Clear all*. At most
50 items; a typed text at most 64 KB and never anything that looks like a password, token or card number.

*Keep after restart* (off by default) saves the list in a private file (`ai-context.json`, 0600) in Cocaine's folder: references
and typed text, never the content of clipboard items or files.

**Pinboards**: Settings → AI → *Pinboards shared with AI* lets a tool read whole pinboards you choose (`boards_list`,
`board_get`). Every pinboard starts not shared.

## Connecting a tool

Settings → AI → *AI context (MCP)* → *Connect*. Cocaine first shows exactly what it will do, and does it only when you confirm:

| Tool | What Cocaine does | Undo |
|---|---|---|
| Claude Code | runs `claude mcp add --scope user cocaine -- /Applications/Cocaine.app/Contents/MacOS/Cocaine --mcp` (only if the `claude` command is found; otherwise it shows the command to copy) | `claude mcp remove --scope user cocaine` (*Disconnect*) |
| Claude Desktop | adds `"cocaine"` to `mcpServers` in `~/Library/Application Support/Claude/claude_desktop_config.json` | *Disconnect* removes just that entry |
| Codex | adds the `[mcp_servers.cocaine]` table to `~/.codex/config.toml` | *Disconnect* removes just that table |
| Cursor | adds `"cocaine"` to `mcpServers` in `~/.cursor/mcp.json` | *Disconnect* |
| Gemini CLI | adds `"cocaine"` to `mcpServers` in `~/.gemini/settings.json` | *Disconnect* |

File edits show the change as a diff first, keep every other server and setting, save a backup next to the file
(`<file>.cocaine-backup`), and running *Connect* twice changes nothing. Restart the tool afterwards. *Copy* puts the command or
the entry on the clipboard if you prefer to set it up yourself.

Only a copy of Cocaine installed in Applications can be connected: AI tools start `Cocaine.app/Contents/MacOS/Cocaine --mcp` by
its path, which stays the same across updates. Open Cocaine once before connecting (Gatekeeper must have allowed it).

## What the AI tool sees

Tools (all read-only):

| Tool | Arguments | Returns |
|---|---|---|
| `context_list` | none | the items: id, kind, title, size |
| `context_get` | `id`, `offset` (optional) | one item's content: text, a file's text, the text recognised in an image, or metadata |
| `boards_list` | none | pinboards shared with AI |
| `board_get` | `board` (name or id), `cursor` (optional) | the items of one shared pinboard |
| `cocaine_request` | `reason` (≤ 500 characters), `kinds` (`clipboard`, `shelf`) | what you pick in the notch, or "declined" |
| `cocaine_status` | none | whether Cocaine is running with AI context on |

Also **resources** `cocaine://context/<id>` (in Claude Code: `@cocaine:cocaine://context/…`) and the **prompt** `use_context`
(`/mcp__cocaine__use_context`). Codex documents tools only.

What an item gives:
- text (typed, clipboard, shelf): the text;
- a text-like file (source, Markdown, JSON, logs…, or any UTF-8 file): its first 512 KB;
- a PDF: the text of its first 20 pages;
- an image: the text recognised in it (on this Mac), its size; **never the pixels**;
- a folder, or any other file: name, size, type and date only.

**Limits**: each answer stays under about 20,000 tokens (Claude Code stops at 25,000 by default); a longer item says where to
continue (`offset`, `cursor`). A question in the notch waits at most 45 seconds (Codex stops a call after 60). When the consent question
already used most of a `cocaine_request` call, the picker isn't opened in the same call (it would outlive it): the tool is told to
call again. At most 60 calls a
minute per tool and 4 `cocaine_request` a minute.

## Consent

The first time a tool asks, the notch shows *Allow &lt;tool&gt; to read your AI context?* with:
- **Allow**: remembered for that tool;
- **Allow once**: for that session of the tool only (until it restarts, at most 8 hours);
- **Deny**: remembered; it isn't asked again;
- **Not now** (or Esc, or no answer in 40 seconds): nothing is remembered.

A tool is recognised by the name it gives and by the program that started Cocaine's bridge (e.g. `claude`, `codex`, Claude.app).
Settings → AI → *AI tools* lists the decisions with *Revoke*.

## The activity log

Settings → AI → *Activity*: when, which tool, what kind of request (list, get, board, request), the outcome and how many items
and bytes. **Never the content, titles or paths.** Kept in `mcp-audit.log` (0600) in Cocaine's folder, at most 256 KB; *Clear*
deletes it.

## How it works, and the threat model

`Cocaine --mcp` is a small **stdio** MCP server that the AI tool starts. It speaks both protocol generations in use: the
`initialize` handshake (2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05) and the stateless 2026-07-28 revision (`server/discover`).
It is only a bridge: for each call it opens Cocaine's private socket, answers, and writes nothing but MCP messages to its output.
It never touches the clipboard, the Keychain or your files itself, and exits when the tool closes it.

- **No network port.** The bridge talks to the app over a Unix socket (`mcp.sock`) in Cocaine's private folder (0700), the socket
  0600, only from the same macOS user (`getpeereid`), and both sides prove they hold a per-install key (`mcp.key`, 0600, HMAC over
  fresh nonces). The socket exists only while the switch is on. Nothing listens on TCP, so no website can reach it.
- **Other programs of yours.** Malware running as your own user can read that key, like any of your files. What protects your data
  then is the rest: only the AI context is ever readable, each tool must be allowed in the notch, and the log shows every read.
  A tool's name and program are labels, not proof of identity.
- **Prompt injection.** Copied text can contain instructions aimed at an AI. Item content is always returned between
  `<<<BEGIN COCAINE USER DATA (untrusted…)>>>` and `<<<END COCAINE USER DATA>>>` markers (a copy of a marker inside your data
  is changed, so it can't close the frame; an answer cut at the size limit is closed again), the server tells the tool to treat it as
  data, tool descriptions never contain anything of yours, the AI's reason shown in the notch is cleaned (no control or
  direction-changing characters, at most 120 characters), and there are no write tools. Still, an AI tool can be misled by what it
  reads: put in the AI context only what you would paste into that tool yourself.
- **Leaving the Mac.** Cocaine sends nothing anywhere. What a tool reads goes to that tool's own AI provider, as if you had pasted
  it into the chat: that is what the consent question says.
- **Bounded.** Messages over 4 MB are refused, answers are capped, the basket and the log have fixed limits.

## Limits

- The picker in the notch offers four items at a time (the island has no room for more); put others in the AI context from the
  notch, and the tool reads them with `context_list`.
- Images are shared as recognised text and size only.
- Which protocol version each tool uses, and whether it shows resources and prompts, depends on the tool (Codex: tools only).
  The fake-client test checks both generations; the real tools were not exercised by Cocaine's tests.
- Registering for Claude Code needs its `claude` command; without it, copy the command shown.
