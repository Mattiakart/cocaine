# Defaults and basic macOS behaviour

Rule (2.9): Cocaine does not change how basic things work on your Mac (copy and paste, Handoff / Universal Clipboard, AirDrop,
volume and brightness keys, Bluetooth, Wi-Fi, Spaces, keyboard shortcuts, Dock and menu bar, Focus, screenshots) unless you turned
that feature on. The one exception is Cocaine's purpose itself: keeping the Mac awake while Cocaine is on.

`--basics-test` checks this table against the code on memory-only settings (Sources/Basics.swift, Sources/BasicsTests.swift).

## Changed in 2.9

| What | Before | Now | Settings from before 2.9 |
|---|---|---|---|
| **Universal Clipboard** (copy on iPhone/iPad/another Mac, paste here, and back) | Every copy from another device was read at once, with all its flavours (formatting, HTML, images, files, source marker): each one a transfer from that device, while the system was still bringing it over | Left alone: not read at all. *Copies from other devices* on: only its plain text, 3 s after it arrived, never images or files | Switched off once (it was the old default; turn it on again and it stays) |
| **⌃⌘V** (open the clipboard from any app) | Registered globally by default, so Microsoft Word, Excel and PowerPoint lost Paste Special | No shortcut until you record one (⌃⌘V is suggested in the setting) | ⌃⌘V freed once; a combination of your own is kept |
| **Share links** on the clipboard | Marked *concealed* (other apps and the system may keep such a copy to this Mac) | An ordinary copy; only Cocaine's own history skips it | — |

## What Cocaine does with fresh settings

| Area | Default | Kind | When | How to turn it off |
|---|---|---|---|---|
| Sleep (pmset `disablesleep`, `caffeinate -d`) | Cocaine turns on at launch | the feature itself | while Cocaine is on; put back at quit, crash or uninstall (watchdog) | *Turn on when Cocaine opens* → Never, or turn Cocaine off |
| Admin password (sudo rule for `pmset -a disablesleep 1/0` only) | asked the first time Cocaine turns on | the feature itself | once | `Cocaine.app/Contents/MacOS/Cocaine --remove-rule` |
| Idle dim / lid rule (brightness or gamma) | on | the feature itself | only while Cocaine is on and you are idle / the lid is closed; restored on input or when off | Settings → *When idle* |
| Volume / brightness keys and the system HUD | macOS's | opt-in | only with *Replace system HUD* (asks for Accessibility) | — |
| Keyboard backlight | never touched | opt-in | only with Keyboard backlight → *Turn off when idle* | — |
| Synthetic input (Stay available) | off | opt-in | only with *Stay available* | — |
| Smart Triggers, VPN, schedule, phone wake | off | opt-in | — | — |
| `cocaine://` links that change sleep | ask first | opt-in | — | — |
| Global shortcuts ⌃⌥⌘C / ⌃⌥⌘O / ⌃⌥⌘P / ⌃⌥⌘I | on | Cocaine's own (no macOS shortcut uses them; checked against System Settings) | always | the *Keyboard shortcuts* card (each one, or all off) |
| Clipboard shortcut (open), Paste Stack (⌃⌥⌘V) | none / only while a stack waits | opt-in | — | Settings → Island → Clipboard |
| Clipboard history | in memory, reads this Mac's copies | passive (reads; writes only when you click an item) | while the island is on | Settings → Island → Clipboard → Pause, or the island off |
| Universal Clipboard copies | not read | opt-in | — | *Copies from other devices* |
| The island over the notch, trackpad swipes there | on | Cocaine's own UI (swipes are listened to, never blocked) | while the island is on | Settings → Island |
| Downloads and screenshot folder (island Files) | read | passive (may show macOS's folder-access prompt) | while the island is on | Settings → Island |
| Music / Spotify | read only if already running | passive (asks for Automation the first time) | while the island is on | — |
| Bluetooth devices list (`system_profiler`) | only on the Status page or for a profile that uses Bluetooth | passive | when shown / needed | — |
| Wi-Fi name, Location | only for a profile that uses Wi-Fi | opt-in | — | — |
| Camera | only on the Mirror page | opt-in | — | — |
| Microphone | never opened (only whether another app uses one) | passive | — | — |
| Update check | once a day | network | — | *Check for updates automatically* |
| Services menu *Add to Cocaine Shelf* | listed | passive | — | System Settings → Keyboard → Keyboard Shortcuts → Services |
| File types, URL schemes | none claimed (`LSHandlerRank None`), only `cocaine://` | — | — | — |
| Login item, Dock icon, other apps' settings, Focus, sounds, screensaver | not touched | — | — | — |

## If Handoff copy and paste doesn't work

1. Quit Cocaine (menu → Quit). On the iPhone copy a word, on the Mac press ⌘V in TextEdit within a minute. Then the other way.
2. Open Cocaine again and repeat. With 2.9 and *Copies from other devices* off, Cocaine doesn't touch such copies at all.
3. If it fails without Cocaine too: same Apple Account on both, Bluetooth and Wi-Fi on, System Settings → General → AirDrop &
   Handoff → *Allow Handoff between this Mac and your iCloud devices*, and on the iPhone Settings → General → AirPlay &
   Continuity → Handoff.
