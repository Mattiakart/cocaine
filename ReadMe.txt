COCAINE 1.7.1
Keeps your Mac awake, even with the lid closed. Turn it on and off from the baggie in the menu bar.
Requires macOS 14 (Sonoma) or later. Runs on Apple Silicon and Intel Macs.
Languages: English, Italian, Chinese, Spanish, French, German, Japanese. It follows your Mac's language (English otherwise), or pick one from the flag in the panel.

INSTALL
1. Drag Cocaine into the Applications folder.
2. Open it. macOS blocks it because it isn't notarized by Apple (it's a free app).
   Go to System Settings > Privacy & Security, scroll down and click "Open Anyway". You only do this once.
3. On first launch Cocaine asks for your administrator password, once. macOS shows a warning because the app
   isn't notarized by Apple. That's expected. It needs permission to change
   one system setting: the one that prevents your Mac from sleeping.

USE
- Click the baggie in the menu bar to open the panel.
- In the panel, click the little mirror with the powder to turn Cocaine on or off.
- Full baggie = Cocaine is on: your Mac doesn't sleep, not even with the lid closed.
- Empty baggie = Cocaine is off: your Mac behaves normally.
- While it's on, it can dim the screen after a few idle minutes. It never goes fully dark, and it comes back
  as soon as you touch the keyboard or trackpad.
- "Open at login" starts Cocaine every time you log in. Opening the app turns Cocaine on, and quitting it
  (Quit, Cmd-Q, logging out or shutting down) turns it off.

GOOD TO KNOW
- While Cocaine is on your Mac doesn't lock by itself, even with the lid closed. Lock it with Control-Command-Q
  before you walk away.
- On battery with the lid closed the Mac keeps running, and it won't sleep even when the battery is almost empty.

UNINSTALL
1. Quit Cocaine (this also turns it off).
2. Move Cocaine to the Trash.
3. In Terminal: sudo rm /etc/sudoers.d/cocaine
