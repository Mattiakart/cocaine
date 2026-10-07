COCAINE
Keeps your Mac awake, even with the lid closed. Turn it on and off from the baggie in the menu bar or the notch island.
Full documentation, permissions and limits: https://github.com/Mattiakart/cocaine#readme
Requires macOS 14 (Sonoma) or later. Runs on Apple Silicon and Intel Macs.
Languages: English, Italian, Chinese, Spanish, French, German, Japanese. It follows your Mac's language (English otherwise), or pick one from the flag in the panel.

INSTALL
1. Drag Cocaine into the Applications folder.
2. Open it. macOS blocks it because it isn't notarized by Apple (it's a free app signed with Cocaine's own
   certificate; Apple doesn't verify that). Go to System Settings > Privacy & Security, scroll down and click
   "Open Anyway". You only do this once. Permissions you grant are normally kept across updates signed with the same
   certificate, but Apple doesn't guarantee it for self-signed apps: if a switch is off after an update, turn it on again.
3. On first launch Cocaine asks for your administrator password, once. macOS shows a warning because the app
   isn't notarized by Apple. That's expected. It needs permission to change
   one system setting: the one that prevents your Mac from sleeping.

USE
- Click the baggie in the menu bar to open the panel.
- In the panel, the switch at the top turns Cocaine on or off.
- Full baggie = Cocaine is on: your Mac doesn't sleep, not even with the lid closed.
- Empty baggie = Cocaine is off: your Mac behaves normally.
- While it's on, it can dim the screen after a few idle minutes (it comes back as soon as you touch the keyboard
  or trackpad), or turn the screens fully off while the Mac keeps running (General > "Turn the screen off instead").
- "Open at login" starts Cocaine every time you log in. Opening the app turns Cocaine on, and quitting it
  (Quit, Cmd-Q, logging out, shutting down, kill or a crash) puts sleep back as it was before.
  After a power cut, sleep stays disabled until Cocaine opens again (or run: cocaine off).

GOOD TO KNOW
- While Cocaine is on your Mac doesn't lock by itself, even with the lid closed. Lock it with Control-Command-Q
  before you walk away.
- On battery with the lid closed the Mac keeps running, and it won't sleep even when the battery is almost empty.

UNINSTALL
1. Quit Cocaine (this also turns it off).
2. Move Cocaine to the Trash.
3. In Terminal: sudo rm /etc/sudoers.d/cocaine
