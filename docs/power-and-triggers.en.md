### Screen off, Mac awake

General → *When idle* → **Screen off**: while Cocaine is on, after the chosen idle time the
displays (built-in and external) are turned off instead of dimmed (`pmset displaysleepnow`, no admin rights). The Mac keeps
running: downloads, builds and AI agents go on. **Now** turns them off at once. Any key, click or trackpad touch lights them again.

- **Lock:** nothing is bypassed. When the displays go off macOS locks as set in *System Settings → Lock Screen* ("Require
  password after screen saver begins or display is turned off"). In this mode Cocaine's engine no longer holds the display
  awake (`caffeinate -i` instead of `-d`), so macOS's own display-sleep timer also applies and may turn the screens off sooner.
  In the normal mode the display is held awake and macOS doesn't auto-lock on idle (unchanged).
- **Lid:** see *Lid closed* below (it works the same in this mode). Lid closed with an external display (clamshell): the
  external display is turned off after the idle time like any other.
- **Heat and battery:** with the lid closed, on battery, if macOS reports a *serious* or *critical* thermal state (a Mac in a
  bag), Cocaine turns itself off so the Mac can sleep, and tells you. The Battery Guard works as before and also stops every
  Smart Trigger from turning Cocaine back on until the battery recovers or the charger is connected. Below it there is a
  fixed floor: at **5 %** on battery Cocaine turns itself off even with Battery Guard off or already used, and again if it is
  turned back on down there; triggers wait until the battery is above 8 % or on the charger.
- **Stay available:** in this mode it no longer holds the display awake and never sends its invisible mouse event to a sleeping
  display (that would light it up), so chat apps may show you as away while the screens are off. Dimming and screen-off now
  count from your last real input, ignoring Stay available’s own events (before, with it on, a 1-minute dim never fired).
- **Alerts** (AI alerts with *Flash* on) still wake the displays on purpose.
- **Limits:** AirPlay, Sidecar and some DisplayLink displays may not honour display sleep. Some monitors show "no signal"
  before going to standby.

### Lid closed, dimming and several displays

- **Lid closed** (Cocaine on): the built-in display goes to its lowest backlight (1 %) at once, whatever *When idle* says, and
  gets back the level it had just before the close when the lid opens. Cocaine hears the lid the moment it moves (the power
  manager's clamshell message, with a poll every 0.5 s as a fallback) and reads the level then; a reading that is already
  dropping (the panel powering down) is not trusted. With no external display the Mac stays awake with a dark built-in. External
  displays are never touched by the lid: in clamshell they stay as they are and follow only the idle dimming. Turning Cocaine
  off with the lid closed gives the built-in its level back. Launched or turned on with the lid already closed works the same.
- **Idle dimming** lowers every display that is on: Apple displays through their backlight, others through their own colour
  table (saved and put back exactly, other displays untouched; it saves no power, the monitor's backlight stays on). A display
  already darker than the chosen level is left alone. Any input brings everything back; automatic brightness creeping up on a
  dimmed screen is put back, but a big change someone makes (a slider, a script) is kept until the next idle stretch.
- **Every case ends back where it started:** a quick close-open-close, an alert, switching to *Screen off*, unplugging a
  display (the others stay dimmed; one plugged back still dimmed is put back), quitting in the middle of a fade, or a crash
  (the watchdog restores backlights that still show Cocaine's level).
- **Fast user switching:** while another user's session is in front nothing is dimmed or forced, Stay available doesn't nudge
  and the volume/brightness keys are left to macOS.
- **Battery floor:** see *Heat and battery* above.
- **Limits:** tested with simulated displays (`--display-test`); the lid and clamshell timing, Apple displays in clamshell and
  DDC were not tried on real hardware here. The wake for the iPhone holds a lid-closed "dark wake" with a system-activity
  assertion for the reply window; how long macOS allows it on battery was not measured (the log says how long each was held).

### Smart Triggers: power, external display, schedule

Automation → Smart Triggers, next to *An AI is at work* and *These programs are open*:

- **Power:** *On the charger*, or *On battery* while the charge is above Battery Guard’s level (10 % with the guard off: one battery level for both). A Mac without a battery counts
  as on the charger.
- **External display:** *Connected* or *Not connected* (asleep displays count; AirPlay/Sidecar count as external).
- **Schedule:** days of the week and a start/end time on the local wall clock. An end at or before the start runs past
  midnight and belongs to the day it starts (Fri 22:00–06:00 includes Saturday 02:00). It follows daylight-saving and
  time-zone changes; on the night clocks go back, a window inside the repeated hour lasts that extra hour.
- **Turn on when:** *Any is true* (one reason is enough, the default) or *All are true* (shown from two triggers on).

Cocaine turns on when the triggers say so and off again after a grace period: 3 minutes for AI and programs, 30 seconds for
power and display (a wiggling cable doesn't flip it), none for the schedule. Precedence: turning Cocaine off yourself (switch,
hotkey, `cocaine://off`, `cocaine off`, `cocaine remote off`, the timer or the Battery Guard) is respected until the triggers
let go; turning it on yourself is never undone by a trigger. Triggers are checked every 5 seconds and at once after a wake, a
clock or time-zone change, or a display change.

### Shortcuts and scripts

The app is built with the Command Line Tools only (`swiftc`). Native Shortcuts actions (App Intents) need the metadata that
Xcode's `appintentsmetadataprocessor` generates at build time; that tool isn't part of the Command Line Tools, and without it
Shortcuts does not list the actions. So Cocaine offers two supported ways instead:

**Links** (Shortcuts → *Open URLs*, or *Open X-Callback URL* to get an answer back):

| Link | Does |
|---|---|
| `cocaine://on` · `cocaine://on?minutes=90` | on (for 1–1440 minutes) |
| `cocaine://off` · `cocaine://toggle` | off · switch |
| `cocaine://timer?minutes=90` | on for that long |
| `cocaine://status` | nothing; with x-callback, the answer |
| `cocaine://x-callback-url/status?x-success=…` | answers `state` (on/off), `until` (ISO 8601), `remaining_minutes`, `screen_off_mode`, `trigger_active` |

Any app or web page can open a link, so links that change something work only after you allow it: the first time Cocaine
asks (*Allow* / *Don't Allow*; after *Don't Allow* links are ignored for 10 minutes), or turn on General →
**Shortcuts app and links**. Answers are sent only to `shortcuts://` callbacks. Bad values (`minutes=0`, `abc`, over 1440)
are refused, not guessed. A link that starts Cocaine doesn't turn it on by itself first; `status` alone starts it, answers
and quits.

**Run Shell Script** (the engine inside the app; runs as you, no app needed):

```sh
C=/Applications/Cocaine.app/Contents/Resources/cocaine   # or ~/Applications/…
$C on            # on (keeps any timer)
$C on 90m        # on for 90 minutes (90, 2h, 1h30m; 1 min–24 h); Cocaine.app turns it off then
$C off
$C status --json # {"state":"ON","on":true,"until":1790000000,"remaining_minutes":42,"screen":"kept on","screen_off_mode":false}
```

Use *Get Dictionary from Input* on the JSON. Turning on/off this way counts as your own choice for the Smart Triggers.
The timed off needs Cocaine.app to be running.
