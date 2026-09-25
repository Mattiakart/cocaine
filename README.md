<p align="center"><img src="docs/icona.png" width="128" alt="Cocaine app icon"></p>

<h1 align="center">Cocaine</h1>

<p align="center"><b>Keep your Mac awake, even with the lid closed.</b><br>
A tiny, free, open-source menu bar app for macOS.</p>

<p align="center"><img src="docs/demo.gif" width="360" alt="The baggie in the menu bar fills up when Cocaine turns on"></p>

🇮🇹 [Leggi in italiano](README.it.md)

- **Full baggie = on.** Your Mac doesn't sleep, not even with the lid shut. This works on Apple Silicon too, with no extra helper to install.
- **Empty baggie = off.** Normal sleep behaviour.
- **One tap.** In the panel, click the little mirror: the powder pours in and heaps up as Cocaine turns on, and goes
  when it turns off.
- **Screen dimming.** While Cocaine is on, it can dim the built-in display to a level you choose after a few idle minutes.
  The screen never goes fully off, and it comes back the moment you touch the keyboard or trackpad.
- **External monitors too.** Apple displays dim their backlight, any other monitor dims in software, and with the lid
  closed only the external screens dim. The panel opens under the icon you click, on whichever screen.
- Universal (Apple Silicon and Intel), macOS 14 Sonoma or later, about 600 KB.

- **Speaks your language:** English, Italian, Chinese (Simplified and Traditional), Spanish, French, German and Japanese.
  It follows your Mac's language (English otherwise), or you can pick one from the flag in the panel.
  More translations are welcome.

<p align="center"><img src="docs/pannello.png" width="340" alt="Cocaine's menu bar panel"></p>

## Install

**With Homebrew (easiest):**

```
brew install --cask mattiakart/tap/cocaine
```

Homebrew asks for your Mac password **once**, right there in Terminal, to give Cocaine its permission. If you've turned
on Touch ID for sudo, it's a fingerprint instead. That's all: no pop-ups, no "Open Anyway".
`brew upgrade` never asks for anything, and `brew uninstall --cask cocaine` removes everything without asking.

**Or download the .dmg** from [Releases](../../releases/latest):

1. Drag **Cocaine** into **Applications**.
2. Open it. The first time, macOS blocks it because it isn't notarized by Apple: it's a free app, built without a
   paid developer account. Go to **System Settings → Privacy & Security** and click **Open Anyway**. You only do this once.
3. Cocaine asks for your password once. macOS shows it with a warning because the app isn't notarized by Apple.
   That's expected.

Either way, that authorization installs a sudo rule that allows exactly `pmset -a disablesleep 1`,
`pmset -a disablesleep 0`, and deleting the rule itself. Nothing else. [See the code](cocaine.zsh).

## Alerts when an AI finishes

Leave the Mac working, and Cocaine calls you back when an AI agent finishes or needs you. When you're away, it wakes
the screens, restores the brightness, flashes them and shows who's calling and in which project. When you're at the Mac,
the baggie in the menu bar just refills.

Open **AI alerts** in the panel. Its four groups each show a one-line summary and open one at a time:
**Connected AIs** (a switch for each, with what it reports), **When** (it finishes, it needs you, also while you're at
the Mac), **How** (flash, sound, voice, how long the alert stays on screen, reminders every 2, 5 or 10 minutes while
you're away, and a test) and **Pause** (30 minutes, an hour, or until tomorrow). Below them, apart from the settings,
**Recent alerts** lists the last three, with the project each came from.

| AI | Finishes | Needs you | Cocaine's hook goes in |
|---|---|---|---|
| Claude Code | ✓ | ✓ permission or question | `~/.claude/settings.json` |
| Codex (CLI and ChatGPT app) | ✓ | ✓ approval | `~/.codex/hooks.json` |
| Cursor | ✓ | – | `~/.cursor/hooks.json` |
| GitHub Copilot (CLI and VS Code) | ✓ | ✓ in the CLI | `~/.copilot/hooks/cocaine.json` |
| Gemini CLI | ✓ | ✓ tool permission | `~/.gemini/settings.json` |
| Windsurf | ✓ after each reply | – | `~/.codeium/windsurf/hooks.json` |
| Qwen Code | ✓ | ✓ permission | `~/.qwen/settings.json` |
| OpenCode | ✓ | ✓ permission or question | `~/.config/opencode/plugins/cocaine.js` |

Only Cocaine's own hooks are added; everything else in those files stays as it was. Unticking an AI removes them, and
so does `brew uninstall`. Codex runs a new hook only after you trust it once (it asks when it starts in Terminal, or use
Settings → Hooks in the ChatGPT app); the panel reminds you until you do. Cursor also runs Claude Code's hooks, so
Cocaine's Claude Code hook stays quiet inside Cursor and you never get two alerts.

**Anything else** can ring it too:

```
open -g "cocaine://alert?from=My%20script&event=done"     # event=done or input; project=name; or message=anything
```

- **Other AI agents** with hooks or plugins that can run that command: Aider (`notifications-command` in
  `~/.aider.conf.yml`), Cline (`~/Documents/Cline/Hooks/TaskComplete`), Factory Droid (`~/.factory/hooks.json`), Kiro,
  Amp, Goose, JetBrains Junie (not on its `PermissionRequest` hook: one that exits without a decision approves the action).
- **Builds and terminals:** Xcode (Settings → Behaviors → Run script), any long command (`make; open -g …`), kitty's
  `notify_on_cmd_finish`, iTerm2 Triggers, tmux `alert-silence`.
- **CI and git:** `gh run watch --exit-status; open -g …`, git hooks such as `post-merge`.
- **Automation apps:** Shortcuts ("Open URLs"), Keyboard Maestro, Hammerspoon, BetterTouchTool, launchd `WatchPaths`,
  Mail rules.

Cocaine's hooks start with `pgrep -qx Cocaine`, so a closed Cocaine stays closed: alerts only go out while the app is
running.

## Feedback and help

The ✉︎ next to the version in the panel opens an email to the author, with your Cocaine and macOS versions already filled
in. Bugs and ideas are also welcome as [GitHub issues](https://github.com/Mattiakart/cocaine/issues).

## Good to know

- While Cocaine is on, your Mac **won't lock by itself**, even with the lid closed. Lock it with ⌃⌘Q before you walk away.
- On battery with the lid closed the Mac keeps running, and it won't sleep even when the battery is almost empty.
- Opening the app turns Cocaine on, and quitting it turns Cocaine off. That covers **Quit**, ⌘Q, logging out and shutting down.

## Uninstall

With Homebrew: `brew uninstall --cask cocaine`. It turns Cocaine off and removes the app, its sudo rule and the AI alerts
hooks, without asking. (`--zap` also deletes the settings.)

Without Homebrew: untick your AIs under AI alerts, quit Cocaine (that turns it off), move it to the Trash, then run this in Terminal:

```
sudo rm /etc/sudoers.d/cocaine
```

## How it works

- `pmset -a disablesleep 1` is the only setting that keeps a Mac awake with the lid closed. `caffeinate` doesn't
  survive a lid close, and changing this setting needs root, hence the narrow sudo rule.
- While Cocaine is on, a small helper holds `caffeinate -d` so the display doesn't idle-sleep.
- The app itself is a Swift/SwiftUI menu bar app ([`main.swift`](main.swift)). The engine is a short zsh script
  ([`cocaine.zsh`](cocaine.zsh)). Screen dimming uses macOS's DisplayServices.

Build it yourself with `./build.sh --dmg`.

## License

MIT. See [LICENSE](LICENSE).
