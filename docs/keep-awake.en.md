# Keep awake: the extras

What Cocaine adds to "keep the Mac awake" beyond the switch and the timer (see also [Power and triggers](power-and-triggers.en.md)
and [Scripting](scripting.en.md)). Everything new is off until you turn it on, except "until a time", which only acts when you press
Start.

## Until a time

- **Panel**: General → *Keep awake for* → *Until a time*: pick the time (− / +, scrolling, or the list of half hours) and press
  *Start*. The next such time is used: today, or tomorrow once it has passed. The row says how long that is.
- **Link**: `cocaine://on?until=18:30`, `on?until=08:00%20tomorrow`, `on?until=2026-10-07T18:30` (local) or a full ISO 8601 time
  with its zone (`2026-10-07T16:30:00Z`). With x-callback-url the answer carries `until` and `remaining_minutes`.
- **Command line**: `cocaine on until 18:30`, `cocaine on until 08:00 tomorrow`, `cocaine on until 2026-10-07T18:30`.
- **AppleScript**: `keep awake until "18:30"` or a date.
- Rules, the same everywhere: in the future and **at most 24 hours** away (else refused, nothing changes); `until` never together with
  `minutes`. Clock times are read on the wall clock through the calendar, so a daylight-saving change in between is counted right (on
  the 25-hour October day "23:00" seen from 23:30 the day before is 24.5 hours away and refused). A time the clocks skip (02:30 on the
  March jump day) is read as if they hadn't jumped: 03:30. The app and the engine compute the same instants (both tested around
  midnight and both DST changes in Europe/Rome).
- `cocaine://on?timer=off` turns on with no timer, whatever the panel's default (used by the Mac Shortcuts pack).

## More Smart Triggers (Automation → Smart Triggers)

Each one, like the others, turns Cocaine on while it holds and off after a grace period, only if a trigger turned it on; turning it
off yourself wins until the reason goes away; *Any/All* combines them with the rest.

| Trigger | What it reads | Permission | Off after |
|---|---|---|---|
| A VPN is connected | a tunnel interface (`utun`, `ipsec`, `ppp`, `tun`, `tap`, `wg` + number) that is up with an IPv4 or routable IPv6 address (`getifaddrs`). macOS's own utun interfaces (iCloud Private Relay, Continuity) have only link-local addresses and don't count | none | 30 s |
| Processor busy / quiet | the CPU load (`host_statistics`, every 5 s) above (or below) 10/25/50/75 % without a break for 1/2/5/10 min | none | 60 s |
| Sound plays through | the default audio output's name (CoreAudio) contains one you chose (headphones, AirPlay, a display) | none | 30 s |
| A disk is connected | one of the chosen volumes is mounted | none | 30 s |
| A USB device is connected | one of the chosen USB devices is plugged in (IOKit's product names) | none | 30 s |

The **Wi-Fi network**, a **Bluetooth device** and much more are conditions of [profiles](awake-profiles.en.md) (Automation →
Profiles): the Wi-Fi network needs Location Services (since macOS 14 the only way to read its name), Bluetooth no permission.

## Keep awake while… (Automation)

- **A program runs**: pick it from the list of your running processes (apps first). Cocaine turns on with no timer and turns off when
  that process ends (checked every 2 s). The process is known by its pid *and* its start time, so a pid reused by another program
  doesn't count.
- **Downloads are in progress**: Cocaine stays on while the Downloads folder has a browser's partial file (`.crdownload`, `.download`,
  `.part`, `.partial`, `.opdownload`) or a file that grew since the last look, and turns off a minute after the last one finishes.
  It needs the Files and Folders permission for Downloads (if refused, the row says so and nothing starts).
- *Stop* stops waiting and leaves Cocaine as it is; turning Cocaine off by hand ends the wait too. What is waited for is kept across a
  restart of the app (an update) only while Cocaine is still on. If the app crashes, its recovery lease puts sleep back as usual
  ([Recovery](recovery.en.md)): nothing is left keeping the Mac awake.
- The command-line `cocaine watch` is not this: it is the app's own watchdog.

## Keep-awake options (General → Keep awake)

- **Turn off when unplugged**: Never / At once (10 s, so a wiggled cable doesn't count) / 5 min / 15 min after the charger is
  unplugged, however Cocaine was turned on. Only on an actual unplugging: a Mac already on battery when Cocaine opens isn't affected,
  and turning Cocaine back on while on battery is respected. Battery Guard and the 5 % floor work as before.
- **Pause while the screen is locked** (`com.apple.screenIsLocked`/`Unlocked`, no permission): at the lock Cocaine lets the Mac sleep
  and no trigger turns it on; at the unlock an ON made by hand comes back with what was left of its timer (not if the timer ran out
  meanwhile); an ON a trigger made comes back by itself if the trigger still holds. A change from outside while locked (the iPhone,
  `cocaine on`) wins. Don't use it to work with the lid closed: closing the lid locks the screen.
- **Turn on when Cocaine opens**: Always (as before), Not at login (only when you open it yourself; a launch as a login item is told
  by the launch event), Never. A link that starts the app decides by itself either way. *Not verified on this Mac*: that macOS 14–27
  marks a login-item launch of an `SMAppService` app the same way (`keyAELaunchedAsLogInItem`); if it doesn't, "Not at login" behaves
  like "Always".
- **Left click turns it on or off**: with the menu-bar icon shown (island off), a left click toggles and a right click or ⌃-click opens
  the panel. VoiceOver announces the new state.
- **Menu-bar icon**: Baggie (default), Cup, Bolt, Eye or Dot: an outline when off, filled when on (SF Symbols, template). The island
  keeps the baggie.
- **Notices when it turns on or off**: a short notice in the island (or a VoiceOver announcement when the island isn't shown) at every
  change, with the trigger that did it. Off by default. Cocaine doesn't use macOS notifications (they'd need another permission).
