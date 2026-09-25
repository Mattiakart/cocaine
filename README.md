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
- Universal (Apple Silicon and Intel), macOS 14 Sonoma or later, about 600 KB.

- **Speaks your language:** English, Italian, Chinese (Simplified and Traditional), Spanish, French, German and Japanese.
  It follows your Mac's language (English otherwise), or you can pick one from the 🌐 menu in the panel.
  More translations are welcome.

<p align="center"><img src="docs/pannello.png" width="340" alt="Cocaine's menu bar panel"></p>

## Install

Download the latest **Cocaine .dmg** from [Releases](../../releases/latest), or use Homebrew:

```
brew install --cask mattiakart/tap/cocaine
```

1. Drag **Cocaine** into **Applications**.
2. Open it. The first time, macOS blocks it because it isn't notarized by Apple: it's a free app, built without a
   paid developer account. Go to **System Settings → Privacy & Security** and click **Open Anyway**. You only do this once.
3. On first launch Cocaine asks for your **admin password**, once. It uses it to install a sudo rule that allows
   exactly two commands, `pmset -a disablesleep 1` and `pmset -a disablesleep 0`, and nothing else.
   [See the code](cocaine.zsh).

## Good to know

- While Cocaine is on, your Mac **won't lock by itself**, even with the lid closed. Lock it with ⌃⌘Q before you walk away.
- On battery with the lid closed the Mac keeps running, and it won't sleep even when the battery is almost empty.
- Opening the app turns Cocaine on, and quitting it turns Cocaine off. That covers **Quit**, ⌘Q, logging out and shutting down.

## Uninstall

Turn Cocaine off, quit it, move it to the Trash, then run this in Terminal:

```
sudo rm /etc/sudoers.d/cocaine
```

If you installed with Homebrew, `brew uninstall --cask --zap cocaine` does all of this for you. Without `--zap`,
the sudo rule and the settings stay in place, so that `brew upgrade` doesn't ask for your password every time.

## How it works

- `pmset -a disablesleep 1` is the only setting that keeps a Mac awake with the lid closed. `caffeinate` doesn't
  survive a lid close, and changing this setting needs root, hence the narrow sudo rule.
- While Cocaine is on, a small helper holds `caffeinate -d` so the display doesn't idle-sleep.
- The app itself is a Swift/SwiftUI menu bar app ([`main.swift`](main.swift)). The engine is a short zsh script
  ([`cocaine.zsh`](cocaine.zsh)). Screen dimming uses macOS's DisplayServices.

Build it yourself with `./build.sh --dmg`.

## License

MIT. See [LICENSE](LICENSE).
