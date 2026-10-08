COCAINE
Keeps your Mac awake, even with the lid closed. Turn it on and off from the baggie in the menu bar or the notch island.
Profiles (Automation) can do it for you: on a Wi-Fi network, with a disk, a USB or Bluetooth device, an app in front, and more.
Full documentation, permissions and limits: https://github.com/Mattiakart/cocaine#readme
Requires macOS 14 (Sonoma) or later. Runs on Apple Silicon and Intel Macs.
Languages: English, Italian, Chinese, Spanish, French, German, Japanese. It follows your Mac's language (English otherwise), or pick one from the flag in the panel.

INSTALL
1. Drag Cocaine onto the Applications folder shortcut in this window.
2. Open it. macOS blocks it because it isn't notarized by Apple (it's a free app signed with Cocaine's own
   certificate; Apple doesn't verify that). Go to System Settings > Privacy & Security, scroll down and click
   "Open Anyway". You only do this once. Permissions you grant are normally kept across updates signed with the same
   certificate, but Apple doesn't guarantee it for self-signed apps: if a switch is off after an update, turn it on again.
3. On first launch Cocaine asks for your administrator password, once. macOS shows a warning because the app
   isn't notarized by Apple. That's expected. It needs permission to change
   one system setting: the one that prevents your Mac from sleeping.

USE
- Cocaine lives in the notch (the "island"): point at the bag left of the notch to open it, and click the gear for the settings
  panel. (With the island off, or while VoiceOver runs, the baggie is in the menu bar: click it to open the panel.)
- Keyboard: Control-Option-Command-C turns Cocaine on or off, -O opens the panel, -P pauses alerts, -I opens the island with the
  keyboard in it. Change them in General > Keyboard shortcuts.
- In the panel, the switch at the top turns Cocaine on or off.
- Full baggie = Cocaine is on: your Mac doesn't sleep, not even with the lid closed.
- Empty baggie = Cocaine is off: your Mac behaves normally.
- While it's on, it can dim the screen after a few idle minutes (it comes back as soon as you touch the keyboard
  or trackpad), or turn the screens fully off while the Mac keeps running (General > When idle > Screen off).
- "Open at login" starts Cocaine every time you log in. Opening the app turns Cocaine on, and quitting it
  (Quit, Cmd-Q, logging out, shutting down, kill or a crash) puts sleep back as it was before.
  After a power cut, sleep stays disabled until Cocaine opens again (or run: cocaine off).

GOOD TO KNOW
- While Cocaine is on your Mac doesn't lock by itself, even with the lid closed. Lock it with Control-Command-Q
  before you walk away.
- On battery with the lid closed the Mac keeps running. At 5 % Cocaine turns itself off so the Mac can sleep,
  even with Battery Guard off.
- With the lid closed the built-in screen goes to its lowest brightness and gets its level back when you open it;
  external monitors are never dimmed by the lid.
- "Stay available" (Automation) also keeps the screen from dimming, sleeping and locking by itself while it runs.

UNINSTALL
1. In the panel, AI alerts: untick your AIs (this removes Cocaine's hooks from their settings); under AI context (MCP),
   Disconnect any connected tool.
2. Quit Cocaine (this also turns it off).
3. Move Cocaine to the Trash.
4. In Terminal: sudo rm /etc/sudoers.d/cocaine
