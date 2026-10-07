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
- **Screen dimming.** While Cocaine is on, it can dim every display to a level you choose after a few idle minutes.
  The screen never goes fully off, and it comes back the moment you touch the keyboard or trackpad.
- **Lid closed.** With Cocaine on, closing the lid puts the built-in display straight to its lowest brightness (whatever the
  idle setting) and opening it gives back the level it had. External monitors are never touched by the lid: in clamshell they
  stay as they are and only dim when idle, like any time. Apple displays dim their backlight, any other monitor dims in
  software. The panel opens under the icon you click, on whichever screen.
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
`pmset -a disablesleep 0`, `pmset schedule wake`/`schedule cancel wake` tagged `cocaine` (used only by *Wake for iPhone*), and
deleting the rule itself. Nothing else. [See the code](cocaine.zsh).

**Signature.** Current releases are signed with Cocaine's own self-signed certificate ("local" tier): free, but not verified
by Apple and not notarized, hence "Open Anyway". The panel shows your copy's tier under *Permissions*. macOS keeps the
permissions you grant across updates signed with the same certificate, but Apple promises nothing for self-signed ones: if a
switch turns off after an update, turn it on once. Developer ID signing and notarization are supported by the build scripts but
not used by releases yet. **In-app updates** (panel → Updates) verify an Ed25519-signed manifest, the DMG hash and the new
app's signature before an atomic swap, but they stay inactive until a release ships a signed manifest and its public key is
built into the app; until then use `brew upgrade --cask cocaine` or the DMG. Homebrew installs are never self-replaced. Details:
[Signature and updates](docs/signing-and-updates.en.md).

## Alerts when an AI finishes

Leave the Mac working, and Cocaine calls you back when an AI agent finishes or needs you. When you're away, it wakes
the screens, restores the brightness, flashes them and shows who's calling and in which project. When you're at the Mac,
the baggie in the menu bar just refills.

The **AI alerts** tab of the panel appears once Cocaine finds a supported AI tool on the Mac. At its top, **Agents** lists the
sessions at work (or, when none is, **Recent alerts**: the three latest, with the project each came from). Then three cards:
**Connected AIs** (a switch for each, with what it reports), **When** (it finishes, it needs you, also while you're at the Mac,
just once per session when nothing is left running, **Answer from the island**, off by default, and **Pause**: 30 minutes, an
hour, or until tomorrow) and **How** (flash, sound, voice and which one, how long the alert stays on screen, reminders every 2, 5
or 10 minutes while you're away, and a test). With VoiceOver, every alert is also read out.

**Every session, in the notch.** The island's Home tab and the panel list all your AI sessions (scrolling when there are many;
up to 100), the ones that need you first. The list is saved and comes back after a restart (marked ↺ with its age); a session
whose process has ended is dropped. **Click a session or an alert** to go back to where it runs: the exact Terminal or iTerm2
tab (needs the *Automation* permission for that app, asked the first time), the tmux or WezTerm pane, or the VS Code, Cursor
or Windsurf window of its folder; when it can't get that far it brings the app forward or opens the folder, and always tells
you what it did. An IDE's built-in terminal, JetBrains, Ghostty, kitty and Warp can only be brought forward as an app, and
sessions started before this version don't say where they run.

**Allow or deny from the island** (off by default; Claude Code 2.0.45+ and Codex): permission requests, and Claude Code's MCP
questions with simple answers (Claude Code 2.1.78+), appear with **Allow** / **Deny** / **In the terminal**. It uses only the tools' documented hooks
(`PermissionRequest`, `Elicitation`) over a private socket, with answers signed and tied to one request. Nothing is approved on
its own: no answer within 2 minutes, Cocaine not running, or any error, and the tool asks in the terminal as usual. Claude Code's
`AskUserQuestion` has no hook for answers, so it is only announced. Other tools in the table only alert. Details:
[AI sessions](docs/ai-sessions.en.md).

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

Cocaine's alert hooks start with `pgrep -qx Cocaine`, so a closed Cocaine stays closed: alerts only go out while the app is
running. The Allow/Deny hook runs Cocaine's own binary instead, which gives no answer (the terminal asks) when the app isn't running.

## Feedback and help

**Feedback or help → Write…** in the panel's Cocaine card (General) opens an email to the author, with your Cocaine and macOS versions already filled
in. Bugs and ideas are also welcome as [GitHub issues](https://github.com/Mattiakart/cocaine/issues).

## Island

Cocaine also lives in the notch (or, on a screen without one, in a slim bar at the top; the switch is then called *Show at the top
of the screen*). Closed, the bag sits left of the notch and the most important live thing right of it, one at a time: a short
message (a new download's file name, "Screenshot", "Copied", the volume and brightness bars), a focus countdown, an AI waiting for
you, the microphone in use, AIs at work (✦ and how many), the song playing, Cocaine on and until when, or *Stay available*. Point at
it, or click it, and it opens at once (and closes as soon as the pointer leaves), with these pages:

- **Home**: the switch, the timer, *Stay available*, the AI agents at work.
- **Music**: Apple Music and Spotify, with artwork, scrubber, play/pause/next/previous/shuffle and, if you switch them on,
  synced lyrics (looked up by title and artist on lrclib.net, nothing else is sent; a network problem is said as such). What
  plays comes from the apps' own announcements; their scripting (the Automation permission) is used for the artwork and, while
  this page is open, the position.
- **Calendar**: Day, Week and Month views with previous/next, *Today* and the arrow keys; click an event for its details
  (time, calendar, place, video-call link, people, notes) and *Open in Calendar*. Asks for Calendar access the first time; if
  it was refused, a button opens System Settings. See [docs/calendar.en.md](docs/calendar.en.md).
- **Focus**: a focus/break timer with a minute ruler; starting a focus keeps the Mac awake for its length, *Reset* turns Cocaine
  off again only if the focus turned it on, the end is announced (a sound, a flash, an alert when you're away), and a running
  focus survives a restart or an update.
- **Your screens**: Settings → Island → *Screens* shows or hides each page, reorders them (drag, or the arrows), picks the one the
  island opens on, and puts modules of different pages on one screen (two columns, each module S, M or L) with a live preview and
  *Restore defaults*. See [docs/screens.en.md](docs/screens.en.md).
- **Shelf**: drop files on the island (it opens by itself) and keep them there, then drag them out or send them all by AirDrop.
  It holds references, not copies, and is kept across restarts (files gone meanwhile are left out).
- **Files**: recent downloads and screenshots, to drag out (to any app, Mail, AirDrop…); a flash with the file's name says when a
  new one arrives. The two folders are watched, not re-read every few seconds.
- **Clipboard**: what you copied lately (text, images, file references), with search and favorites; click to copy again. Kept in
  memory only unless you turn on *Save on this Mac* (encrypted, with retention limits, exclusions and *Delete everything*);
  never from password managers. [Details and limits](docs/clipboard.en.md).
- **Status**: the batteries of the Mac, AirPods and other Bluetooth devices (refreshed at most once a minute), and the usage of
  Codex (its limits, from the newest sessions that report them) and Claude Code (tokens in the last 5 hours and 7 days), read from
  their own local files. Claude Code's files are read once, then only what was added; a first count over a large history says
  *Still counting* until it is complete.
- **Media**: Apple Music, Spotify, YouTube Music, Netflix, Prime Video, YouTube, Disney+, Apple TV, Twitch, DAZN: a tap opens the app if it
  is installed, else the website in your default browser.
- **Mirror**: the camera live, on only while that page is open; a switch flips it like a mirror (or shows you as others see you), and
  you can pick the camera.
- **Monitors** (only with an external monitor): brightness, contrast, volume and input of the monitor itself over DDC/CI,
  Apple silicon only (the tab isn't shown on Intel); not every monitor supports it. The current values are read from the monitor
  when it answers (otherwise they show –), and a monitor that doesn't take a change says so.

Plugging the charger in or out is announced too. The island replaces the menu-bar icon: the bag of Cocaine, always on its left, fills and empties as the icon did (white powder: Cocaine is on;
pink powder: Cocaine is off but *Stay available* is on, with or without a chat app open). Turn the island off and the icon comes back. It opens and closes by following the
lines of the notch, with a light tap on the trackpad where it helps (timers, switches, tabs; General → *Haptic feedback* turns it off; with Reduce Motion on in
macOS's Accessibility settings it appears and goes without the morph, and alerts tint the screen once instead of flashing). The gear opens the settings panel;
General → *Show in the notch* turns it off. It hides during full-screen video and games on its screen (a big window on another
monitor doesn't count). There is an island on every connected screen: the notch where there is one, a slim bar on the others;
each opens on its own when the pointer touches it, and a full-screen app hides only its screen's island (Island → *Show on all
screens* off keeps just one: the screen with the notch, else the built-in display, else the main display) ([details](docs/island-screens.en.md)).
With Island → *Replace system HUD* on, Cocaine handles the volume and brightness keys itself
(fine steps with ⌥⇧; ⌥ alone still opens Sound or Displays settings) and their bar appears just below the notch, as wide as the
notch, instead of macOS's; messages such as *Downloaded* or *Copied* appear there too.
This needs the **Accessibility** permission, which it asks for when you turn the option on. Whenever the island can't be seen
(a full-screen app, the settings panel open, another user's session) the keys go to macOS and macOS shows its own indicator.
Before macOS 26 its indicator's helper is also kept frozen while the island shows the bars, and given back when you turn the option
off or quit; if Cocaine crashes or is killed, a small watchdog gives it back within a couple of seconds ([details](docs/recovery.en.md)).
From macOS 26 the indicator is drawn by Control Center, which Cocaine leaves alone. Without the permission, macOS still changes
the volume and brightness and the island shows them.

**From the keyboard and with VoiceOver.** ⌃⌥⌘I (General → *Keyboard shortcuts*, changeable) opens the island with the keyboard
in it: it stays open until Esc, the shortcut again or a click elsewhere; ← and → change tabs, Tab moves between controls (with
Full Keyboard Access), and on the Clipboard page ↑, ↓ and Return copy an item. For VoiceOver the closed island is one element,
"Cocaine", that says what it shows and opens the island; while VoiceOver runs, the menu-bar icon stays too. Flashes, an AI starting
work, alerts and requests, and what a shortcut or a link did are announced. Cocaine follows Increase Contrast, Differentiate
Without Colour and Reduce Motion (no pouring bag, no springs, still visualizer).


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

How it's kept safe: each paired iPhone gets two random topic names on the relay and its own random 256-bit key. Commands and
answers are **authenticated and end-to-end encrypted** with it, so the relay only sees ciphertext (not the command, status,
project names or agent output); a command without the right key is ignored, and a reply is bound to the request it answers.
**Replays are refused for good**: what the Mac has run is saved on disk before it runs, so duplicates delivered again after a
reconnection, a wake-up or a restart are dropped, and commands older than two minutes (20 with *Wake for iPhone*) or from the
future are refused. *Revoke* forgets every paired iPhone at once (a command already running gets no answer); a pairing expires
after 180 days. Every command goes through a fixed allow-list: the default level allows status, on/off and listing projects;
*Also start and steer AI agents* adds starting agents and typing into them, which amounts to running code as you, so grant it
knowingly. At most 20 messages a minute are looked at (more are dropped unread), and every command is logged in
`~/Library/Application Support/Cocaine/remote-phone.log`. Treat the Shortcut like a key: it holds the key, syncs through iCloud
like any Shortcut, and anyone who gets it can use it.

**Shortcuts made before this version** (plain text, unauthenticated) are refused after the update; the panel shows an orange
*Old Shortcuts* row: send a new Shortcut, then *Remove*, or *Allow 14 days* to let old ones run the basic commands meanwhile
(never starting agents), unprotected. 

Limits, honestly: the Shortcuts app has no encryption action, so the Shortcut does it with hashes and regular expressions
(standard constructions, checked against the Mac's code). It is large (about 650 actions), a command takes a few seconds on the
iPhone, and replies over about 2,800 bytes are cut. The relay still sees when and how often you send commands and can delay or
drop them. A command the Mac crashes on right after accepting is not run (never twice). **The new Shortcut has been verified in
a simulator of its actions, not yet on a real iPhone.** The Mac has to be awake to answer: that's what Cocaine on is for. To avoid
a third-party relay, run your own ntfy server: `defaults write local.cocaine.toggle relayURL https://ntfy.example.com` (https
only), then pair again. Full description: [Remote control security](docs/remote-security.en.md).

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
or fails, and the panel lists them. `remote status` shows the same, and **Phone alerts** send the alerts that come while you're
away to your phone: in *Remote work → Phone alerts → Set up…* (or `cocaine remote notify shortcut "Name"`) Cocaine runs that
Shortcut on the Mac with the alert text as its input (build one that sends you a message or notification), or (`notify ntfy
https://ntfy.sh/your-secret-topic`) posts it to an ntfy topic as a push notification (the text leaves the Mac). *Test* (or
`cocaine remote notify test`) tries it and the row says what happened.

**Waking the Mac.** Cocaine on is what keeps it reachable. A Mac that has already gone to sleep can't hear the relay, and
nothing on the internet can wake a sleeping MacBook with the lid closed. So, in *Remote work*, turn on **Wake for iPhone**:
Cocaine schedules a short wake every 15 minutes (even with the lid closed). On each wake it reconnects, runs the commands
your iPhone sent meanwhile (up to 20 minutes old), answers, and lets the Mac sleep again. So a command sent to a sleeping
Mac is answered within about 15 minutes: send it, then use *Last reply* later. It asks for your permission once (it extends
Cocaine's sudo rule with `pmset schedule wake`/`cancel wake`, tagged `cocaine`, nothing else), costs a little battery, is
paused on battery at 20% or less, and is cancelled when you quit Cocaine. If it matters that the answer is immediate, keep
Cocaine on. It can be turned on only once an iPhone is paired. (`cocaine remote wake-info` still prints what a Wake-on-LAN app
needs, for use on your home network.)

**Also from Shortcuts and scripts on the Mac.** Cocaine has no native Shortcuts actions: they need metadata that only Xcode's build
tools produce, and the app is built with the Command Line Tools. Instead: links (`cocaine://on?minutes=90`, `off`, `toggle`, `timer`,
`status` with an x-callback answer; also `pause`, `resume`, `panel`) and the bundled command (`cocaine on 90m`, `off`,
`status --json`, usable from *Run Shell Script*). Links that change something work only after you allow it (a one-time question, or
General → *Shortcuts app and links*), because any app or web page can open a link. See
[Power and triggers](docs/power-and-triggers.en.md).

### Automation

**Stay available** (Automation tab): Teams, Slack, Zoom and similar apps mark you "Away" from the Mac's idle time. While you are
idle, with one of the chosen apps open (or always), Cocaine sends an invisible mouse event just before they would show you away
(after about 4½ minutes, or before your screen saver if it starts earlier), which restarts that clock, and keeps the display awake.
So while it is on, the screen saver, the lock and display sleep don't start either. It needs the Accessibility permission; check
that your workplace allows it.

The panel's tabs sit left and right of the notch: *General* (**Keep awake for**: ∞, 30 minutes … 8 hours, or any length you set in
steps of 15 minutes up to 24 hours, then it turns off; picking a length while Cocaine is off turns it on for that long; **When idle**:
nothing, dim or screen off, and *Screens off now*; **Battery Guard**: on battery, at 10–30 % turn Cocaine off or just warn; the
Cocaine card with login, updates, language, *Show in the notch*, haptics and *Shortcuts app and links*; **Keyboard shortcuts**: on
by default, ⌃⌥⌘C on/off, ⌃⌥⌘O the panel, ⌃⌥⌘P pause alerts, ⌃⌥⌘I the island; click one and type a new combination (Esc
cancels, Delete removes it, *Reset to defaults*); they need no permission, a combination macOS or another app already uses is
refused or marked *Used by another app*, and the names follow your keyboard layout), *AI alerts* (the agents at work or the latest alerts, then the AIs, when and how), *Automation* (**Smart Triggers**: on
while an AI works or waits for you, while chosen programs run, on the charger or on battery down to Battery Guard's level, with an
external display connected or not, or in a weekly time window; any or all must hold; off again after a short grace period; turning
it off by hand wins; the header says which one turned Cocaine on, and a green dot marks the ones true now; then *Stay available* and
*Remote work*) and, while the island is on, *Island* (*Replace system HUD* and the clipboard's settings). Lists open as a card under
their row inside the panel, never as a menu under the notch.

**Screen off, Mac awake** (General → *When idle* → **Screen off**): the displays go fully off after the idle time while

the Mac keeps running. Nothing is bypassed: the lock follows *System Settings → Lock Screen* (in this mode the display is no longer
held awake, so macOS may also turn it off sooner). With the lid closed and on battery, if macOS reports a serious thermal state,
Cocaine turns itself off. *Stay available* pauses while the screens are off, AirPlay/Sidecar/DisplayLink screens may ignore display
sleep, and external-monitor and clamshell behaviour is documented but was not tested on real hardware. See
[Power and triggers](docs/power-and-triggers.en.md).

## Good to know

- While Cocaine is on, your Mac **won't lock by itself**, even with the lid closed. Lock it with ⌃⌘Q before you walk away.
- On battery with the lid closed the Mac keeps running. At 5 % Cocaine turns itself off so the Mac can sleep, even with
  Battery Guard off; set Battery Guard higher to stop earlier.
- Opening the app turns Cocaine on, and quitting it puts things back as they were. That covers **Quit**, ⌘Q, logging out,
  shutting down, `kill` and crashes (a small watchdog notices when Cocaine is gone). If sleep was already disabled before Cocaine
  turned it on, or you changed it meanwhile, that is respected; the same if the app is deleted while it runs. Limits: after a
  power cut or forced restart sleep stays disabled until Cocaine opens again (or run `cocaine off`, or
  `Cocaine.app/Contents/MacOS/Cocaine --boot-check`); if Cocaine and its watchdog are killed together, its display helper
  puts things back after a minute. [Details](docs/recovery.en.md).
- Permissions, each asked only when a feature needs it: **Accessibility** (Stay available, and the volume/brightness keys with
  *Replace system HUD*), **Automation** (Music and Spotify; Terminal and iTerm2 to go back to a session's tab), **Camera** (Mirror),
  **Calendars** (Calendar), **Files and folders** (Downloads and the screenshot folder, for Files). What is missing is listed under
  *Permissions* in the panel with an *Allow* button.
- Questions, messages and the share list appear inside Cocaine's own panel or island, in the same design. What macOS owns stays
  macOS's: the admin-password prompt, the privacy permission questions, System Settings, and the windows AirDrop, Messages and
  Mail open after you pick them (Apple doesn't allow embedding those).
- Only one Cocaine runs at a time: opening it again shows the running one's panel.

## Uninstall

With Homebrew: `brew uninstall --cask cocaine`. It quits Cocaine (ending it if it hangs), puts sleep back and removes the
app, its sudo rule and the AI alerts hooks, without asking. (`--zap` also deletes the settings, the clipboard history and other saved state.) The cask's uninstall step respects the
recovery rules ([notes](docs/maintainers/cask-changes.md)); Homebrew runs the uninstall step of the version that is installed, so
the first upgrade *to* 2.3.0 still uses the previous one, and the hand-over during upgrades works from the next update on.

Without Homebrew: untick your AIs under AI alerts, quit Cocaine (that turns it off), move it to the Trash, then run this in Terminal:

```
sudo rm /etc/sudoers.d/cocaine
```

## How it works

- `pmset -a disablesleep 1` is the only setting that keeps a Mac awake with the lid closed. `caffeinate` doesn't
  survive a lid close, and changing this setting needs root, hence the narrow sudo rule.
- While Cocaine is on, a small helper holds `caffeinate -d` so the display doesn't idle-sleep (`-i` in screen-off mode).
- The app itself is a Swift/SwiftUI menu bar app: [`main.swift`](main.swift) is only the entry point (the command-line flags and
  starting the app); the code is in [`Sources/`](Sources), one file per area (see [`Sources/README.md`](Sources/README.md)).
  The engine is a zsh script ([`cocaine.zsh`](cocaine.zsh)). Screen dimming uses macOS's DisplayServices.

Build it yourself with `./build.sh --no-install` (into `build.noindex/`; plain `./build.sh` also installs it as the one copy on
the Mac). `--sign local|developer-id|adhoc` picks the signing tier and never falls back to another; `--dmg` is a release build
and needs the update key ([details](docs/signing-and-updates.en.md)). `./verify.sh` builds and runs every automatic check
(the app's tests run from a copy with its own settings); the same runs on GitHub Actions.

## License

MIT. See [LICENSE](LICENSE).
