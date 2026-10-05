# Cask changes for crash recovery (homebrew-tap/Casks/cocaine.rb)

Ship together with the app version that contains `Sources/Recovery.swift` (the engine then carries the marker line
`# cocaine-recovery: 1`). The scripts below check that marker before passing new flags: an older binary doesn't know
`--prepare-update` / `--uninstall-cleanup` and would treat them as a normal GUI launch (a second Cocaine).

Homebrew runs the uninstall stanza of the cask **that is installed**, so the first upgrade *to* this version still runs the
old stanza (old app quits → sleep back on; old script forces `disablesleep 0`); the hand-over works from the next upgrade.

Replace the whole `uninstall` stanza and `zap` with:

```ruby
  # Quitting Cocaine puts sleep back as it was before Cocaine (its crash watchdog does the same if it dies).
  # `brew upgrade`/`reinstall`: before the old version quits, it is told an update is coming, so sleep stays as it is
  # and the new version takes the session over (3 minutes at most, then the watchdog puts sleep back). Nothing else.
  # A real uninstall also undoes anything a crashed Cocaine left (sleep setting, frozen system HUD, display helper, state
  # files), removes its AI alerts hooks (leaving the rest of each tool's settings as it was) and its sudo rule,
  # passwordless because the rule allows exactly that (older rules fall back to one Touch ID prompt).
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
            script:       {
              executable:   "/bin/sh",
              args:         ["-c", <<~SH],
                up=0; p=$PPID
                for i in 1 2 3 4 5; do
                  case "$(/bin/ps -o args= -p "$p")" in *"brew.rb upgrade"*|*"brew.rb reinstall"*|*"brew.rb install"*) up=1 ;; esac
                  p=$(/bin/ps -o ppid= -p "$p" | /usr/bin/tr -d " "); [ -n "$p" ] && [ "$p" -gt 1 ] || break
                done
                [ "$up" = 1 ] && exit 0
                for a in /Applications/Cocaine.app "$HOME/Applications/Cocaine.app"; do
                  [ -x "$a/Contents/MacOS/Cocaine" ] || continue
                  if /usr/bin/grep -q '^# cocaine-recovery: 1' "$a/Contents/Resources/cocaine" 2>/dev/null; then
                    "$a/Contents/MacOS/Cocaine" --uninstall-cleanup >/dev/null 2>&1
                  elif /usr/bin/pmset -g | /usr/bin/grep -q "SleepDisabled[[:space:]]*1"; then   # an older app: as before
                    /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null
                  fi
                  "$a/Contents/MacOS/Cocaine" --ai-alerts off >/dev/null 2>&1
                  break
                done
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
- **Upgrade no longer forces `disablesleep 0`.** It overrode a state the user (or another app) had set before Cocaine, and
  it blinked sleep off/on during every update. `--prepare-update` marks the running session (only if it is alive and owns
  sleep); the app's own quit then keeps sleep for the new version, which adopts it at launch.
- **Real uninstall** runs `--uninstall-cleanup` while the binary and the sudo rule still exist: it kills Cocaine's
  watchdogs (SIGKILL, so they don't retry against a deleted app), ends a frozen OSDUIHelper, restores dimmed screens and
  cancels a recorded wake if the app had crashed, runs the engine's `release` (sleep back to its state before Cocaine,
  only if nobody changed it since; display-hold helper stopped) and deletes `recovery.json`, `recovery.lock`, `sleep-claim`,
  `state.lock`, `hold.lock`, `instance.lock`. Then the sudo rule goes, as before.
- **zap** also removes `~/Library/Application Support/Cocaine` (phone pairings, agent board, engine state).
- `postflight_steps` and `caveats` are unchanged.

Not testable here (needs Homebrew + admin): the stanza as a whole. Tested by `--recovery-test`: `--prepare-update` (with and
without a running session), the hand-over adopted and expired, and `--uninstall-cleanup` against stand-ins.

## Note after the integration review

`Cocaine --uninstall-cleanup` now refuses (exit 75) while a Cocaine instance is running, so the cask's uninstall step must quit the app first (for example `quit: "local.cocaine.toggle"` in the `uninstall` stanza, ahead of the `script`), then run the cleanup.
