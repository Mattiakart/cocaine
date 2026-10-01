<p align="center"><img src="docs/icona.png" width="128" alt="Cocaine app icon"></p>

<h1 align="center">Cocaine</h1>

<p align="center"><b>Keep your Mac awake, even with the lid closed.</b><br>
A tiny, free, open-source menu bar app for macOS.</p>

<p align="center"><img src="docs/demo.gif" width="360" alt="The baggie in the menu bar fills up when Cocaine turns on"></p>

🇮🇹 [Leggi in italiano](README.it.md)

- **Full baggie = on.** Your Mac doesn't sleep, not even with the lid shut. This works on Apple Silicon too, with no extra helper to install.
- **Empty baggie = off.** Normal sleep behaviour.
- **One switch.** The switch at the top of the panel turns Cocaine on or off; a thin line of powder pours into it as
  it turns on.
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
the Mac, or just once per session, when nothing is left running, instead of for every agent or task that finishes), **How** (flash, sound, voice and which one, how long the alert stays on screen, reminders every 2, 5 or 10 minutes while
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

## Remote work

Leave the Mac, keep working from your phone. Cocaine keeps the Mac awake (the lid can stay closed), and a small
command lets you start, follow and steer AI agents from anywhere you can run a command.

**Set up once, from anywhere in the world, no password, no other app.** Cocaine opens no network port and needs neither
Remote Login nor a VPN. The app keeps one outbound connection to a relay ([ntfy](https://ntfy.sh), the same service the
phone alerts can use) and your iPhone's Shortcut talks to the app through it.

1. In the panel: *Remote work → iPhone → Send*. Choose what the phone may do, and Cocaine builds a Shortcut (a
   menu: Status, Turn on, Turn off, Projects, Command, Last reply), signs it (needs internet and iCloud on the Mac) and
   opens the share sheet: AirDrop it or send it by Messages.
2. On the iPhone, add it and run it. That's all: the secret it carries is already known to the Mac.

*Command* takes any `cocaine remote` command, for example `start claude my-project Fix the failing tests`, `log
claude-my-project 30`, `send claude-my-project Yes, go ahead` (the last three need the agents level). The Shortcut waits a
few seconds and shows the answer; *Last reply* shows it again.

How it's kept safe: each paired iPhone gets two random 192-bit topic names on the relay, one for commands and one for
answers; only whoever has the Shortcut knows them. Every command goes through a fixed allow-list (the same for any tier):
the default level allows status, on/off and listing projects; *Also start and steer AI agents* adds starting agents and
typing into them, which amounts to running code as you, so grant it knowingly. Commands older than two minutes are
never run (a Mac that was asleep doesn't replay them), at most 20 a minute are, and every one is logged in
`~/Library/Application Support/Cocaine/remote-phone.log`. *Revoke* forgets every paired iPhone at once: their Shortcuts stop
working. Treat the Shortcut like a key: send it only to your own devices.

What the relay sees: the traffic is HTTPS, but the commands and answers are plain text on that server (a project name, a
battery level), protected only by the unguessable topic names, and it keeps them for about 12 hours. Cocaine asks it not to
forward them to Google's push service. The Shortcut itself syncs through iCloud to your other Apple devices (end-to-end
encrypted only with Advanced Data Protection), and anyone who learns the topics could also post fake answers. If that isn't acceptable, run your own ntfy server and point
Cocaine at it: `defaults write local.cocaine.toggle relayURL https://ntfy.example.com` (https only), then pair again. The Mac
has to be awake to answer: that's what Cocaine on is for.

The same commands run in Terminal:

```
C=/Applications/Cocaine.app/Contents/Resources/cocaine
$C remote status                       # Cocaine, battery, agents at work
$C remote on --for 3h                  # keep the Mac awake for 3 hours
$C remote projects                     # the folders you can start work in
$C remote start claude my-project Fix the failing tests
$C remote start codex my-project --resume
$C remote log claude-my-project 30      # what the agent shows on screen
$C remote send claude-my-project Yes, go ahead
$C remote key claude-my-project enter   # also esc, up, down, tab, ctrl-c, y, n, 1-9
$C remote stop claude-my-project
```

Agents: Claude Code, Codex, Gemini CLI, Cursor, GitHub Copilot, OpenCode, Qwen Code and Aider (`remote agents` lists
what's installed; `--resume` continues the latest conversation for Claude Code, Codex, Cursor, Copilot and OpenCode).
Each one runs in a `screen` session that survives the connection closing (`remote attach <run>` takes it over in a
terminal). Projects are the folders with a `.git` under `~/Developer`, `~/Projects`, `~/Documents` and `~/Desktop`
(change the list in `~/Library/Application Support/Cocaine/projects.conf`). Cocaine turns on when work starts and goes
back to how it was when the last run ends.

**Knowing what's going on.** The AI alerts hooks also tell Cocaine when an agent starts working, waits for you, finishes
or fails, and the panel lists them. `remote status` shows the same, and **Phone alerts** send every alert to you: run
`cocaine remote notify shortcut "Name"` and Cocaine runs that Shortcut (with the alert text as its input; build one that
sends you a message or notification), or `cocaine remote notify ntfy https://ntfy.sh/your-secret-topic` for a
push notification (that sends the alert text to that service). `cocaine remote notify test` tries it.

**Waking the Mac.** Cocaine on is what keeps it reachable. A Mac that has already gone to sleep can't hear the relay, and
nothing on the internet can wake a sleeping MacBook with the lid closed. So, in *Remote work*, turn on **Wake for iPhone**:
Cocaine schedules a short wake every 15 minutes (even with the lid closed). On each wake it reconnects, runs the commands
your iPhone sent meanwhile (up to 20 minutes old), answers, and lets the Mac sleep again. So a command sent to a sleeping
Mac is answered within about 15 minutes: send it, then use *Last reply* later. It asks for your permission once (it extends
Cocaine's sudo rule with `pmset schedule wake`/`cancel wake`, tagged `cocaine`, nothing else), costs a little battery, is
paused on battery at 20% or less, and is cancelled when you quit Cocaine. If it matters that the answer is immediate, keep
Cocaine on. (`cocaine remote wake-info` still prints what a Wake-on-LAN app needs, for use on your home network.)

**Also from Shortcuts on the Mac**, links: `cocaine://on`, `cocaine://off`, `cocaine://toggle`, `cocaine://timer?minutes=90`,
`cocaine://pause?minutes=60`, `cocaine://resume`, `cocaine://panel`.

### Automation

In the panel, each one has its own page (tap it in the list): **Timer** (stay on for 30 minutes … 8 hours, then turn off), **Battery Guard** (on battery, at
10–30 % turn Cocaine off or just warn), **Smart Triggers** (on while an AI works or waits for you, or while chosen programs
run; off 3 minutes after; turning it off by hand wins), and **Shortcuts** (⌃⌥⌘C on/off, ⌃⌥⌘O panel, ⌃⌥⌘P pause alerts).

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
