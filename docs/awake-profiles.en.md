# Keep-awake profiles, disks kept awake, statistics

What Cocaine took from Amphetamine (its "Triggers", "Drive Alive", session reminders and statistics) and how it works here. See also
[Keep awake](keep-awake.en.md), [Power and triggers](power-and-triggers.en.md) and [Scripting](scripting.en.md).

## Profiles (Automation → Profiles)

A profile is a named set of **conditions**. While they hold, the profile keeps the Mac awake by itself (or, if you choose, holds every
trigger back so the Mac can sleep). Profiles sit next to the Smart Triggers: the Smart Triggers card is unchanged and still works as
before; a profile is simply another reason to keep the Mac awake.

**New profile → Add…** starts empty or from a ready-made one: *At the office* (a Wi-Fi network + the charger), *At the desk* (an
external display + the charger), *Presenting* (screen mirroring or Keynote in front), *Backup disk* (a disk connected, displays may
sleep), *Big downloads*, *Low battery* (on battery below 20 %: let the Mac sleep). **Edit** opens it under its row; the switch turns
it on or off.

### Conditions

| Condition | What it reads | Permission |
|---|---|---|
| Wi-Fi network | the network's name (CoreWLAN), exact, any case | **Location Services** (macOS 14+ gives the name to no app without it; the row has an *Allow* button, asked only when a profile uses it). Your location is never read |
| Wi-Fi is connected | the Wi-Fi interface is up with a routable IPv4 address | none |
| Ethernet is connected | an interface macOS lists as Ethernet (adapters, built-in ports; an iPhone over USB counts) up with a routable IPv4 address | none |
| Personal Hotspot | the Network framework's path is "expensive" (an iPhone's hotspot, or another network macOS marks as costly) | none |
| Internet is reachable | the Network framework's path is satisfied (no traffic is sent) | none |
| IP address | one of the Mac's addresses: whole (`192.168.1.20`), a beginning (`192.168.1.`) or a range (`192.168.1.0/24`); IPv6 by whole or beginning | none |
| DNS server | the system's DNS servers (same forms) | none |
| A VPN is connected | as the Smart Trigger: a tunnel interface with a routable address | none |
| A USB device is connected | IOKit's USB product names, part of the name is enough | none |
| A Bluetooth device is connected | `system_profiler SPBluetoothDataType`'s *connected* list, at most every 20 s, in the background | none (IOBluetooth would need the Bluetooth permission; system_profiler doesn't) |
| Sound plays through | the default output's name contains one you chose | none |
| A disk is connected | one of the chosen volumes is mounted | none |
| Processor | above or below 10/25/50/75 % for 1/2/5/10 minutes without a break (each condition keeps its own stretch) | none |
| App in front | the frontmost app by name or bundle id (Cocaine itself is skipped) | none |
| App is running | a running program by name | none |
| Idle time | less than, or at least, 1/5/10/30/60 minutes since your last input (Stay available's own nudges don't count) | none |
| Downloads are in progress | a browser's partial file in Downloads, or a file there that grew | Files and Folders → Downloads (unreadable: never met) |
| On the charger | the power source | none |
| Battery level | at least, or below, 10/20/30/50/80 % | none |
| External display | one is connected (asleep ones count) | none |
| Screen mirroring | a display is in a mirror set | none |
| Schedule | days and a start/end time (past midnight works as in the Smart Triggers) | none |

Every condition except Processor, Idle time and Battery level can be turned around with **Is / Is not**. A reading that can't be made
(the Wi-Fi name without Location Services, Bluetooth before its first reading, the Downloads folder unreadable, no battery) is
**never met, not even with "Is not"**: an unknown never keeps the Mac awake by mistake. A list condition with nothing chosen is never
met (the row says *Choose at least one*). *Type a name…* in each list adds a name that isn't around now (a network you're not on, a
device that's off).

Only what the enabled profiles use is read, every 5 seconds with the Smart Triggers: no Bluetooth reading, Wi-Fi name or Downloads
look unless a profile asks for it.

### Settings of a profile

- **Turns on when**: *All are true* (default) or *Any is true*.
- **Then**: *Keep awake*, or *Let the Mac sleep* (while it holds, no Smart Trigger and no profile below it turns Cocaine on; an ON a
  trigger made ends; an ON you made by hand is never touched).
- **Displays may sleep** (Keep awake only): while this profile decides, the engine holds the Mac awake but not the displays
  (`caffeinate -i` instead of `-d`, the same hold as *Screen off* mode), so the screens sleep and lock as macOS is set. *Stay available*,
  if on, still keeps the displays awake.
- **Start after** (at once / 10 s / 30 s / 1 min / 5 min) and **Stop after** (at once / 30 s / 1 / 5 / 15 min): the conditions must
  hold, or stop holding, that long **without a break**. This is the hysteresis: a Wi-Fi that drops for a few seconds or a CPU reading
  that wobbles never toggles the profile (tested: flapping every 5 s for two minutes changes nothing).
- **At most** (no limit / 30 min … 8 h): the longest the profile keeps the Mac awake in one go; then it stops and waits until its
  conditions break before it can start again.
- **Notices**: a short notice (island, or VoiceOver) when it starts and ends.
- **Priority**: the list's order (↑ ↓). The **first profile whose conditions hold decides**: whether the Mac is kept awake or every
  trigger waits, and whether the displays may sleep. The others below it wait; the row says *Active (a profile above it decides)*.

How it combines with the rest: Cocaine turns on when a Smart Trigger (Any/All, as before) **or** the deciding profile wants it; it turns
off when neither does: after the triggers' grace period, or at once when only a profile was keeping it on (the profile already waited
its *Stop after*). Battery Guard, the 5 % floor, the heat guard and *Pause while the screen is locked* hold profiles back exactly as
they hold the triggers. Turning Cocaine off yourself is respected until the reasons go away, as with the triggers. "Turned on by …" names
the profile.

### From outside

- **Link** (Shortcuts → *Open URLs*): `cocaine://profile?name=Office&enabled=0` (or `1`, `on`/`off`, `true`/`false`); x-callback-url
  works and answers with the status, `x-error` gets `no such profile`. Guarded like every link that changes something.
- **AppleScript**: `enable profile "Office"`, `disable profile "Office"` (answer whether it is now on; an unknown name is an error),
  `get active profile` (the deciding one, or empty text), `get profile names`.
- **Command line**: `cocaine profiles` (state, name, conditions; `--json`), `cocaine profiles enable|disable <name>` (through the
  guarded link: Cocaine may ask first). Reading never writes anything.

## Keep disks awake (Automation → Keep disks awake)

For external drives that spin down too soon (and NAS volumes that park their disks): pick the volumes in **Disks** (built from what is
mounted now; the startup disk isn't offered), the interval (**Every** 30 s / 1 / 2 / 5 / 10 min) and **When** (*While Cocaine is on*,
default, or *Always*). Each chosen volume is touched only while it is mounted; the row says when each was last touched, or why not.

**Method**, honestly:

- **Tiny hidden file** (default; the one that reliably works): Cocaine rewrites one 64-byte file of its own at the volume's top level,
  `.cocaine-drive-alive` (hidden, left out of Time Machine), with `F_NOCACHE` and `F_FULLFSYNC` so the write really reaches the disk
  instead of staying in memory. Always the same file and size: nothing piles up. It is opened with `O_NOFOLLOW` and only if it is a
  small regular file with a single link: a link or someone else's file with that name is left alone (the row says so). Removing a disk
  from the list deletes the file (if the disk is mounted). A read-only volume can't use this method.
- **Read only**: nothing is ever written. Cocaine reads 4 KB with `F_NOCACHE` (read-ahead off) from a different spot of the largest
  visible file near the top of the volume (its top level and one level down). **Best effort**: if macOS already has that piece in
  memory the disk isn't touched, so on a volume of small files it may not keep the disk spinning. Some file systems record an access time.

Each touch opens and closes the file at once (an eject is never blocked), never happens while macOS is unmounting that volume (a minute
of pause), and runs off the main thread, one at a time per volume. Limits: some USB enclosures have their own firmware sleep timer that
may ignore this activity; a disk asleep because the Mac slept wakes with the Mac; macOS may ask once whether Cocaine may use files on a
removable or network volume (Privacy & Security → Files and Folders). `cocaine disks` lists the chosen disks and whether each is mounted.

## Reminder and statistics (General → Keep awake)

- **Remind me while it's on**: Never / 1 / 2 / 4 / 8 h: a notice says how long Cocaine has been on, once per interval of a session.
- **Statistics**: sessions, time awake in all and since when, with **Reset**. A session left open by a quit or a crash is counted only
  up to the last time Cocaine saw it on (saved every minute).

## Tests and what was verified

`Cocaine --triggers-test` (part of `./verify.sh`) checks the conditions on fixed snapshots, the start/stop latch (including flapping),
priority and "let the Mac sleep", storage limits and tolerant decoding, the link, AppleScript commands (on a fake gate) and the
dictionary, the command line on settings in memory, the Bluetooth parser, the disk schedule, the real file operations of both methods
in a temporary folder (links, hard links, big files and unwritable folders refused), statistics and the reminder, and one read-only
reading of this Mac's network, displays and Bluetooth list (only counts are printed).

**Not verified live here**: a real spinning external drive (none was attached), Location Services' prompt and the Wi-Fi name with the
permission granted, a Personal Hotspot, and Bluetooth devices connecting and disconnecting while a profile runs (the parser was run on
this Mac's real `system_profiler` output). Renders: `--render-panel out.png --auto triggers --triggers [--edit-profile]`.
