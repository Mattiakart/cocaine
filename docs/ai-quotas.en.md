# Plan limits (Claude and Codex)

The island's **Status** page (the *AI usage* module) shows, for each provider, how much of each plan window is used and the time
to its reset, next to Claude Code's token counts. A compact **AI limits** module (bars only) can be added to any screen in
Settings → Island → Screens.

## Claude (Pro and Max plans)

Claude Code sends its statusline program a JSON on every reply that includes `rate_limits.five_hour` and
`rate_limits.seven_day` (`used_percentage`, `resets_at`). That is the official, credential-free source, and Cocaine reads only it:

- Turn on **Claude plan limits** (AI alerts → When; off by default, only from the app installed in Applications). Cocaine sets
  `statusLine.command` in `~/.claude/settings.json` to `'…/Cocaine' --statusline <your previous command, base64> "$@"`.
- On every update the wrapper keeps the limits, the model and the context percentage of that session (no conversation text, no
  transcript path) in `~/Library/Application Support/Cocaine/claude-status/<session>.json` (0600; records older than a week are
  deleted), then **runs your previous statusline with the same input and arguments** and passes on what it prints and its exit
  status. Your statusline (ccstatusline and the like) keeps working exactly as before.
- Turning it off puts your previous command back exactly (or removes the statusline if there was none). Turning it on twice
  changes nothing; a statusline of another kind (not a command) is left alone.
- The numbers appear after Claude Code's next reply, only on Pro/Max plans. A window past its reset time with no news since is
  shown as reset, not with the old number.

## Codex

Codex writes `rate_limits` into its session files (`~/.codex/sessions/**`). Each window is named by its own length
(`window_minutes`: 300 = 5 h, 10080 = Week, 1440 = Day, a month = Month): `primary` is **not** always the 5-hour window (on some
plans it is the weekly one and `secondary` is empty). The plan type (`plan_type`) is shown next to it.

## What is not done

No Keychain reads, no OAuth tokens, no `/api/oauth/usage` polling (undocumented, rate-limited, and it would need Claude Code's
credentials), no third-party quota APIs (Kimi, GLM, DeepSeek, Grok…), no price lists downloaded. Everything is local.
