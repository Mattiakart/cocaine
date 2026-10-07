# Cask changes for crash recovery (homebrew-tap/Casks/cocaine.rb)

**To apply in the tap with the next release** (this repository can't edit the tap). It replaces the `uninstall` stanza of
the previous note; `zap`, `postflight_steps` and `caveats` stay as they are.

Ship together with an app version that contains `Sources/Recovery.swift` (the engine then carries the marker line
`# cocaine-recovery: 1`). The scripts check that marker before passing new flags: an older binary doesn't know
`--prepare-update` / `--uninstall-cleanup` and would treat them as a normal GUI launch (a second Cocaine).

Homebrew runs the uninstall stanza of the cask **that is installed**, so the first upgrade *to* this version still runs the
old stanza; the new behaviour starts from the next upgrade or uninstall.

```ruby
  # Quitting Cocaine puts sleep back as it was before Cocaine (its crash watchdog does the same if it dies).
  # `brew upgrade`/`reinstall`: before the old version quits, it is told an update is coming, so sleep stays as it is
  # and the new version takes the session over (3 minutes at most, then the watchdog puts sleep back). Nothing else.
  # A real uninstall also undoes anything a crashed Cocaine left (sleep setting, frozen system HUD, display helper, state
  # files), removes its AI alerts hooks (leaving the rest of each tool's settings as it was) and its sudo rule,
  # passwordless because the rule allows exactly that (older rules fall back to one Touch ID prompt).
  # If Cocaine is still running after `quit` and `signal` (hung), --uninstall-cleanup ends it itself (pid + start time) and
  # waits; if even that fails it exits 75 and the sudo rule is KEPT: the Cocaine left running notices its app was deleted
  # and quits through its engine copy, which still needs the rule to put sleep back.
  # Not `sudo: true`: Homebrew runs that as `sudo -E`, which the narrow rule refuses.
  uninstall early_script: {
              executable:   "/bin/sh",
              args:         ["-c", <<~SH],
                up=0; p=$PPID
                for i in 1 2 3 4 5; do
                  case "$(/bin/ps -o args= -p "$p")" in *"brew.rb upgrade"*|*"brew.rb reinstall"*|*"brew.rb install"*) up=1 ;; esac
                  p=$(/bin/ps -o ppid= -p "$p" | /usr/bin/tr -d " "); [ -n "$p" ] && [ "$p" -gt 1 ] || break
                done
                [ "$up" = 1 ] || exit 0
                for a in /Applications/Cocaine.app "$HOME/Applications/Cocaine.app"; do
                  /usr/bin/grep -q '^# cocaine-recovery: 1' "$a/Contents/Resources/cocaine" 2>/dev/null || continue
                  "$a/Contents/MacOS/Cocaine" --prepare-update >/dev/null 2>&1
                done
                exit 0
              SH
              must_succeed: false,
            },
            quit:         "local.cocaine.toggle",
            signal:       [["TERM", "local.cocaine.toggle"]],
            script:       {
              executable:   "/bin/sh",
              args:         ["-c", <<~SH],
                up=0; p=$PPID
                for i in 1 2 3 4 5; do
                  case "$(/bin/ps -o args= -p "$p")" in *"brew.rb upgrade"*|*"brew.rb reinstall"*|*"brew.rb install"*) up=1 ;; esac
                  p=$(/bin/ps -o ppid= -p "$p" | /usr/bin/tr -d " "); [ -n "$p" ] && [ "$p" -gt 1 ] || break
                done
                [ "$up" = 1 ] && exit 0
                rc=0
                for a in /Applications/Cocaine.app "$HOME/Applications/Cocaine.app"; do
                  [ -x "$a/Contents/MacOS/Cocaine" ] || continue
                  if /usr/bin/grep -q '^# cocaine-recovery: 1' "$a/Contents/Resources/cocaine" 2>/dev/null; then
                    "$a/Contents/MacOS/Cocaine" --uninstall-cleanup >/dev/null 2>&1; rc=$?
                  elif /usr/bin/pmset -g | /usr/bin/grep -q "SleepDisabled[[:space:]]*1"; then   # an older app: as before
                    /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null
                  fi
                  "$a/Contents/MacOS/Cocaine" --ai-alerts off >/dev/null 2>&1
                  break
                done
                if [ "$rc" = 75 ]; then
                  echo "Cocaine is still running and couldn't be stopped: its sleep permission is kept so it can still put sleep back." >&2
                  echo "Quit it (or run: sudo pmset -a disablesleep 0), then remove the permission: sudo rm /etc/sudoers.d/cocaine" >&2
                  exit 0
                fi
                [ -e /etc/sudoers.d/cocaine ] || exit 0
                /usr/bin/sudo -n /bin/rm -f /etc/sudoers.d/cocaine 2>/dev/null || /usr/bin/osascript -e 'do shell script "/bin/rm -f /etc/sudoers.d/cocaine" with prompt "Cocaine: removing its sleep permission." with administrator privileges'
              SH
              must_succeed: false,
            }

  zap trash: [
    "~/Library/Application Support/Cocaine",
    "~/Library/Preferences/local.cocaine.toggle.plist",
  ]
```

What changed and why:
- **`signal: [["TERM", "local.cocaine.toggle"]]`** after `quit`: Homebrew's `quit` gives up after a few seconds; a TERM
  makes a Cocaine that didn't answer the Apple Event quit cleanly (it handles SIGTERM like Quit: sleep, screens, HUD back).
- **Exit 75 of `--uninstall-cleanup` is no longer ignored.** It means a Cocaine is still running even after the cleanup's
  own SIGTERM/SIGKILL (matched by pid and start time, never by name). The sudo rule is then kept: deleting the app makes
  that Cocaine quit by itself (it notices its bundle is gone) and its release needs the rule. Before, the rule was
  removed and sleep stayed disabled for good.
- `--uninstall-cleanup` (app side, in this release): if a Cocaine runs it is sent SIGTERM (pid + start time from the
  lease or the instance lock), waited for, killed if it hangs, then the cleanup goes on: watchdogs (bundle engine and
  engine copy), frozen HUD, dimmed screens and wake of a crashed session, the engine's `release`, then state files
  (`recovery.json`, `recovery.lock`, `sleep-claim`, `state.lock`, `hold.lock`, `hold.pid`, `until`, `instance.lock`) and
  the engine copy in `engine/`. 69 = sleep couldn't be released (not authorized): the files are kept.
- Upgrade path unchanged: `--prepare-update` marks the running session; the new version adopts it.
- **zap** also removes `~/Library/Application Support/Cocaine` (phone pairings, agent board, engine state, engine copy).

Tested here (stand-ins, `--recovery-test`): `--prepare-update` with and without a running session, the hand-over adopted
and expired, `--uninstall-cleanup` with no app, with a running app (ended, then cleaned up) and with a hung app (killed,
then cleaned up). Not testable here (needs Homebrew, the tap and admin): the stanza as a whole, `signal:` timing.
