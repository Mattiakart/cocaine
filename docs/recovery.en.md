### Nothing outlives Cocaine

Opening Cocaine turns it on; quitting it puts things back. That now also holds when Cocaine doesn't quit normally:

- **Sleep.** Cocaine remembers whether sleep was already disabled *before* it turned it off (by you, with `pmset`, or by
  another app). When it's done — Quit, logout, `kill`, Ctrl-C, a crash or `kill -9` — sleep goes back to how it was before,
  unless someone changed it in the meantime (then that change is kept). Turning Cocaine **off** with its switch, the iPhone
  or `cocaine off` is still an explicit off. The display-hold helper ends with it. Changes from the app, the iPhone and
  Terminal at the same moment no longer get in each other's way.
- **System indicators.** Before macOS 26, with *Replace system HUD* on, macOS's volume/brightness indicator is kept frozen
  while the island shows the bars (from macOS 26 nothing is frozen: Control Center draws that indicator). If Cocaine crashes or is killed, the indicator is given back within a couple of seconds; if Cocaine hangs, after
  30 seconds.
- **Dimmed screens** go back to their brightness after a crash too — but only while they still show Cocaine's dimming: a
  brightness you set yourself afterwards is kept.
- **Wake-ups for the iPhone** scheduled by Cocaine are cancelled.
- **Updates** don't blink: during a Homebrew upgrade the Mac stays awake and the new version takes over. If the new
  version doesn't start within 3 minutes, sleep is put back as usual.
- **One at a time.** A second copy of Cocaine that is opened while one is running steps aside (after waiting up to 10 s in
  case the first one is quitting).
- **Uninstalling** (`brew uninstall cocaine`) puts sleep and the system indicator back, ends Cocaine's helpers and removes
  its state files before removing its permission. `brew uninstall --zap` also removes `~/Library/Application Support/Cocaine`.

How: a small watchdog (a `zsh` process started by Cocaine, shown as `zsh …/Cocaine.app/Contents/Resources/cocaine watch`)
notices the moment Cocaine is gone and undoes what Cocaine had noted it changed (`~/Library/Application Support/Cocaine/recovery.json`).
No extra permission, nothing installed, nothing running when Cocaine isn't.

**System HUD and permissions (correction).** Freezing the system indicator and showing volume and brightness in the island
need no permission. To handle the volume and brightness *keys* itself (fine steps with ⌥⇧), Cocaine needs **Accessibility**;
it asks for it when you turn the option on. Without it macOS still changes volume and brightness and the island shows them.
(Input Monitoring is not needed.)

**Limits.**
- If Cocaine *and* its watchdog are killed together (e.g. `kill -9` of both, or a power cut), nothing can act at that
  moment: the system indicator comes back at the next logout or the next time Cocaine opens; dimmed screens and wake-ups
  are fixed the next time Cocaine opens.
- After a power cut or forced restart, sleep stays disabled until Cocaine opens again (macOS keeps that setting across
  restarts). With *Open at Login* on this happens by itself at login; otherwise open Cocaine, or run `cocaine off`.
- If Cocaine hangs, only the system indicator is given back; sleep stays as it is until Cocaine recovers or is quit.
- The first upgrade *to* this version still runs the previous version's uninstall step, which turns sleep back on once;
  the hand-over works from the next update on.
