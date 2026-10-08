# Scripting Cocaine: AppleScript, Mac Shortcuts, links, the command line

Four ways for scripts, Shortcuts, Keyboard Maestro, Raycast and the like to drive Cocaine. Whatever **changes** what the Mac does
(on, off, toggle, pause alerts) is guarded the same way everywhere: it runs when General → *Shortcuts app and links* is on; otherwise
Cocaine asks you once in its own dialog (Don't Allow is the default; after a Don't Allow requests are refused for 10 minutes, so
nothing can flood you with questions). Reading the state is never guarded. Values are checked and bounded (1–1440 minutes, a time
within 24 hours); nothing here reads or writes files or runs programs.

## AppleScript (Cocaine.sdef)

```applescript
tell application "Cocaine"
    keep awake                         -- until stopped (no timer)
    keep awake for 90                  -- minutes, 1 to 1440
    keep awake until "18:30"           -- or "08:00 tomorrow", "2026-10-07T18:30", or a date within 24 h
    stop keeping awake
    toggle                             -- on with the panel's timer, or off
    get {awake, awake until, remaining minutes, screen off mode, trigger active}
end tell
```

- The commands return whether Cocaine is now on (the state being applied, not the old one).
- `awake until` is `missing value` when there is no timer or Cocaine is off; `remaining minutes` is then 0.
- Errors: a bad value is error -1703 with a message ("“for” takes whole minutes, 1 to 1440."); refused (by you, or while the 10-minute
  refusal lasts) is -1743.
- The calling app (Script Editor, Shortcuts, osascript in Terminal…) needs your OK once in Privacy & Security → Automation: macOS asks.
- In **Shortcuts**: the *Run AppleScript* action (Shortcuts → Settings → Advanced → *Allow Running Scripts*). (JXA should work too; not tested).
- If Cocaine isn't running, AppleScript starts it; opening Cocaine turns it on unless General → Keep awake → *Turn on when Cocaine
  opens* says otherwise.

## Mac Shortcuts pack (Automation → Shortcuts and scripts → Add…)

Four ready-made shortcuts, chosen one at a time: Cocaine builds it, signs it with `/usr/bin/shortcuts sign` (like the iPhone
Shortcut: it needs an internet connection and iCloud) and opens it in Shortcuts, which asks you to add it.

| Shortcut | What it does |
|---|---|
| Keep Awake… | asks: *Until I turn it off* / *For some minutes…* (asks a number) / *Until a time…* (asks a time) |
| Keep Awake Off | off |
| Toggle Keep Awake | on or off |
| Keep Awake Status | returns a **Dictionary**: `state` (on/off), `until` (ISO 8601 or empty), `remaining_minutes`, `screen_off_mode` (1/0), `trigger_active` (1/0) |

**Honestly:** these are ordinary shortcuts made of Shortcuts' own *Open X-Callback URL* action calling `cocaine://` links (the answer
comes back as the Dictionary). They are not native Shortcuts actions (App Intents) like Lungo's "Set Enabled State": those can't run for
an app without an Apple-issued signature ([maintainers/app-intents.md](maintainers/app-intents.md)). Use them in your own shortcuts
(*Run Shortcut*), in Shortcuts automations (macOS 26+: time of day, Focus, Wi-Fi network, Bluetooth, app opened…: the triggers
Cocaine doesn't have), in the menu bar, Spotlight or with Siri by name. The first run asks the links question once (or turn on
*Shortcuts app and links*). *Not verified here*: running them (that would mean importing into a Shortcuts library); their structure is
checked against Shortcuts' known actions and parameters by `--awake-test`.

## Links

`cocaine://on`, `on?minutes=90`, `on?until=18:30`, `on?timer=off` (no timer), `off`, `toggle`, `timer?minutes=…`, `pause?minutes=…`,
`resume`, `panel`, `status`; with `cocaine://x-callback-url/<command>?x-success=…` Shortcuts gets the state back. Callbacks only ever
go to Shortcuts' own answer address. See [Power and triggers](power-and-triggers.en.md). Keep-awake profiles:
`profile?name=Office&enabled=0|1`, AppleScript `enable profile` / `disable profile` / `active profile` / `profile names`, and
`cocaine profiles` / `cocaine disks` ([Keep-awake profiles](awake-profiles.en.md)).

## Command line

The engine inside the app (`/Applications/Cocaine.app/Contents/Resources/cocaine`): `cocaine on`, `on 90m`, `on until 18:30`,
`on until 08:00 tomorrow`, `off`, `status --json`, `mode screen-off|normal`. It needs no permission question (it's you, in a terminal).

## Testing (maintainers)

- `Cocaine --awake-test`: the rules, the dictionary as Cocoa loads it from the bundle, the commands run on a fake app (the gate
  decides, errors, results), the Shortcuts pack's structure.
- `Cocaine --scripting-selftest`: real AppleScript compiled with the dictionary and sent to the running copy itself (fake state).
- `Cocaine --scripting-serve 60`: a copy that answers real Apple Events from other processes on an in-memory state, starts nothing of
  Cocaine and never takes over the running Cocaine; run it from a copy with its own bundle id (as verify.sh makes) and talk to it with
  `osascript -e 'tell application id "<that id>" to keep awake for 30'`. The first time macOS asks whether Terminal may control it.
