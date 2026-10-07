### Nothing outlives Cocaine

Opening Cocaine turns it on; quitting it puts things back. That also holds when Cocaine doesn't quit normally:

- **Sleep.** Cocaine remembers whether sleep was already disabled *before* it turned it off (by you, with `pmset`, or by
  another app). When it's done — Quit, logout, `kill`, Ctrl-C, a crash or `kill -9` — sleep goes back to how it was before,
  unless someone changed it in the meantime (then that change is kept). Turning Cocaine **off** with its switch, the iPhone
  or `cocaine off` is still an explicit off. The display-hold helper ends with it. Changes from the app, the iPhone and
  Terminal at the same moment don't get in each other's way.
- **System indicators.** With *Replace system HUD* on, macOS's volume/brightness indicator is kept frozen while Cocaine
  runs. If Cocaine crashes or is killed, the indicator is given back within a couple of seconds; if Cocaine hangs, after
  30 seconds. Only the indicator Cocaine itself froze is touched (one another tool stopped is left alone).
- **Dimmed screens** go back to their brightness after a crash too — but only while they still show Cocaine's dimming: a
  brightness you set yourself afterwards is kept.
- **Wake-ups for the iPhone** scheduled by Cocaine are cancelled (written in the time zone the Mac has when they are
  cancelled, which is what `pmset` reads).
- **A timer set from Terminal or the iPhone** (`cocaine on 90m`, `cocaine remote on --for 2h`) ends on time even when
  Cocaine.app isn't running: the engine's display-hold helper turns it off (at most a minute late), after checking the
  app's own setting in case you changed the timer there.
- **Updates** don't blink: during a Homebrew upgrade or an in-app update the Mac stays awake and the new version takes
  over. If the new version doesn't start within 3 minutes, sleep is put back as usual. If an in-app update's new version
  crashes, hangs or doesn't start, the previous version is put back and opened, and says so.
- **The app deleted while it runs** (dragged to the Trash, replaced by an install or an upgrade that couldn't quit it):
  Cocaine notices within a few seconds and quits normally, putting sleep back; if it was replaced by another copy, that
  copy is opened and continues the session. This works because Cocaine keeps a copy of its engine (and of itself, a clone
  that takes no extra space on APFS) in `~/Library/Application Support/Cocaine/engine/`, refreshed at every launch.
- **One at a time.** Opening Cocaine again while it runs shows the running one's panel. A Cocaine left running from a
  deleted copy is ended and the new one starts. (An instance that is quitting, e.g. during an update, is waited for up to
  10 s.)
- **Uninstalling** (`brew uninstall cocaine`) asks a running Cocaine to quit (and ends it if it hangs), then puts sleep and
  the system indicator back, ends Cocaine's helpers and removes its state files and engine copy before removing its
  permission. If Cocaine can't be ended, the permission is kept, so sleep can still be put back (see Limits).
  `brew uninstall --zap` also removes `~/Library/Application Support/Cocaine`.

How: a small watchdog (a `zsh` process started by Cocaine, shown as `zsh …/Cocaine.app/Contents/Resources/cocaine watch`)
notices the moment Cocaine is gone and undoes what Cocaine had noted it changed (`~/Library/Application Support/Cocaine/recovery.json`).
It stops only once that has worked: if the app's own recovery can't run (the app was deleted, or a new version crashes)
it uses the copy in `engine/`, and failing that does the essentials itself (indicator, wake-up, sleep). If even sleep
can't be put back (the permission is gone), the note stays and the next launch takes the session over. If the watchdog
was killed together with the app, the display-hold helper, still running, does the same after a minute. No extra
permission, nothing installed, nothing running when Cocaine isn't (except the display-hold helper while sleep is off).

**System HUD and permissions.** Freezing the system indicator and showing volume and brightness in the island need no
permission. To handle the volume and brightness *keys* itself (fine steps with ⌥⇧), Cocaine needs **Accessibility**;
it asks for it when you turn the option on. Without it macOS still changes volume and brightness and the island shows them.
(Input Monitoring is not needed.)

**Limits.**
- After a power cut or a restart, nothing of Cocaine runs: sleep stays disabled until something acts (macOS keeps that
  setting across restarts). With *Open at Login* on, Cocaine does it at login. Otherwise open Cocaine, run `cocaine off`,
  or run `/Applications/Cocaine.app/Contents/MacOS/Cocaine --boot-check` (it undoes what the last session left, and ends
  a command-line timer that has passed; it does nothing while Cocaine runs). Cocaine doesn't install a login item of its
  own for this.
- Screens dimmed by Cocaine can be restored only by Cocaine itself (or its copy in `engine/`); the watchdog's last-resort
  essentials can't, they are restored at the next launch.
- If Cocaine hangs, only the system indicator is given back; sleep stays as it is until Cocaine recovers or is quit.
- If `brew uninstall` can't end a running Cocaine, it stops before removing the sudo rule (the cask change that makes it
  do so is in docs/maintainers/cask-changes.md). Until the tap ships it, an uninstall whose quit gives up still removes
  the rule.
- The first upgrade *to* a version with these changes still runs the previous version's uninstall step.
