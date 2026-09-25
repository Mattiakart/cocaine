<p align="center"><img src="docs/icona.png" width="128" alt="Cocaine app icon"></p>

<h1 align="center">Cocaine</h1>

<p align="center"><b>Keep your Mac awake, even with the lid closed.</b><br>
A tiny, free, open-source menu bar app for macOS.</p>

<p align="center"><img src="docs/demo.gif" width="360" alt="The baggie in the menu bar fills up when Cocaine turns on"></p>

🇮🇹 [Leggi in italiano](README.it.md)

- **Full baggie = on.** Your Mac doesn't sleep, not even with the lid shut. This works on Apple Silicon too, with no extra helper to install.
- **Empty baggie = off.** Normal sleep behaviour.
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

Leave the Mac working with Cocaine on, and it can call you back when an AI agent finishes or needs you. When you're
away, it wakes the screens, restores the brightness, flashes them and shows who's calling. When you're at the Mac,
the baggie in the menu bar just refills.

**Claude Code and Codex:** turn on **AI alerts** in the panel. Cocaine adds its hooks to `~/.claude/settings.json` and
`~/.codex/hooks.json` (only for the ones you have) and leaves everything else in those files as it was. Turning the
switch off removes them, and so does `brew uninstall`. Claude Code calls when it finishes and when it needs a permission
or an answer; Codex when it finishes and when it asks for approval. The switch only shows on Macs with Claude Code or Codex.

Codex runs a new hook only after you trust it once: it asks when it starts in Terminal, or use Settings → Hooks in the
ChatGPT app. Until then the panel reminds you.

**Anything else** can ring it too:

```
open -g "cocaine://alert?from=My%20script&event=done"     # event=done or event=input, or message=anything
```

Cocaine's hooks run `pgrep -qx Cocaine && open -g '…'; true`, so a closed Cocaine stays closed: alerts only go out while
the app is running.

## Good to know

- While Cocaine is on, your Mac **won't lock by itself**, even with the lid closed. Lock it with ⌃⌘Q before you walk away.
- On battery with the lid closed the Mac keeps running, and it won't sleep even when the battery is almost empty.
- Opening the app turns Cocaine on, and quitting it turns Cocaine off. That covers **Quit**, ⌘Q, logging out and shutting down.

## Uninstall

With Homebrew: `brew uninstall --cask cocaine`. It turns Cocaine off and removes the app, its sudo rule and the AI alerts
hooks, without asking. (`--zap` also deletes the settings.)

Without Homebrew: turn off AI alerts, quit Cocaine (that turns it off), move it to the Trash, then run this in Terminal:

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
