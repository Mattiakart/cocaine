### Screen off, Mac awake

General → *Dim the screen when idle* → **Turn the screen off instead**: while Cocaine is on, after the chosen idle time the
displays (built-in and external) are turned off instead of dimmed (`pmset displaysleepnow`, no admin rights). The Mac keeps
running: downloads, builds and AI agents go on. **Now** turns them off at once. Any key, click or trackpad touch lights them again.

- **Lock:** nothing is bypassed. When the displays go off macOS locks as set in *System Settings → Lock Screen* ("Require
  password after screen saver begins or display is turned off"). In this mode Cocaine's engine no longer holds the display
  awake (`caffeinate -i` instead of `-d`), so macOS's own display-sleep timer also applies and may turn the screens off sooner.
  In the normal mode the display is held awake and macOS doesn't auto-lock on idle (unchanged).
- **Lid:** with the lid closed and no external display, the built-in screen is already off; the Mac stays awake as usual
  with Cocaine on. Lid closed with an external display (clamshell): the external display is turned off like any other.
- **Heat and battery:** with the lid closed, on battery, if macOS reports a *serious* or *critical* thermal state (a Mac in a
  bag), Cocaine turns itself off so the Mac can sleep, and tells you. The Battery Guard works as before and also stops every
  Smart Trigger from turning Cocaine back on until the battery recovers or the charger is connected.
- **Stay active:** in this mode it no longer holds the display awake and never sends its invisible mouse event to a sleeping
  display (that would light it up), so chat apps may show you as away while the screens are off. Dimming and screen-off now
  count from your last real input, ignoring Stay active's own events (before, with Stay active on, a 1-minute dim never fired).
- **Alerts** (AI alerts with *Flash* on) still wake the displays on purpose.
- **Limits:** AirPlay, Sidecar and some DisplayLink displays may not honour display sleep. Some monitors show "no signal"
  before going to standby.

### Smart Triggers: power, external display, schedule

Automation → Smart Triggers, next to *An AI is at work* and *These programs are open*:

- **Power:** *On the charger*, or *On battery* while the charge is above a level (10–50 %). A Mac without a battery counts
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
asks (*Allow* / *Don't Allow*; after *Don't Allow* links are ignored for 10 minutes), or turn on Automation → Shortcuts →
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
