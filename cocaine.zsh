#!/bin/zsh
# cocaine — engine behind Cocaine.app: overrides macOS sleep (pmset disablesleep) and, while
# that override is ON, keeps the display from idle-sleeping (or, in "screen off" mode, lets it sleep).
#
#   cocaine on [duration]     on; with a duration (90, 90m, 2h, 1h30m; 1 min…24 h) it turns off then (Cocaine.app, or the hold helper)
#   cocaine off
#   cocaine status [--json]   ON/OFF (first line), then the display hold; --json for scripts and Shortcuts
#   cocaine mode screen-off|normal|status   screen off: the Mac stays awake but its displays may sleep (and lock)
#   cocaine release | forget  used by Cocaine.app (quit, crash recovery); `watch` is its watchdog, `expire` ends a passed
#                             command-line deadline (Cocaine --boot-check)
# cocaine-recovery: 1   (marker: this engine and its app know release/watch and --prepare-update; the cask checks it)
#
# `disablesleep` shows as `SleepDisabled` in `pmset -g` (never in `pmset -g custom`):
# absent or 0 = OFF, 1 = ON. Changing it needs root; Cocaine.app installs a narrow NOPASSWD
# rule for exactly `pmset -a disablesleep 1|0` (/etc/sudoers.d/cocaine) the first time it runs.
#
# Display hold: `on` starts one detached `cocaine hold` helper, which keeps a child
# `caffeinate -d -w <its pid>` while SleepDisabled is 1 and exits on its own once it reads 0.
# In screen-off mode the child is `caffeinate -i` instead: no display assertion, so the displays sleep on
# idle (or when Cocaine.app turns them off) and macOS locks as set in Lock Screen settings.
# There is one helper per user, whichever copy of the engine started it: it holds $SUPPORT/hold.lock (fcntl) and writes
# its pid to $SUPPORT/hold.pid, and that pair (not the engine's path) is how every copy finds it. It waits with zselect
# (no process spawned while it idles) and reads SleepDisabled every 10 s. It also ends a deadline given here or on the
# iPhone (`on 90m`) when Cocaine.app isn't running to do it, and undoes what a dead Cocaine.app left if its watchdog
# died with it (see `orphan_check`).
# Nothing runs at login unless Cocaine.app itself is a login item. Stored pmset values are never
# changed, and only our own helper (found as above) is ever signalled.
# While the display is held macOS skips the screen saver, so the Mac does not auto-lock on idle.
#
# Sleep claim: the first `on` records in $SUPPORT/sleep-claim what SleepDisabled was before (prior=0|1).
# `release` (Cocaine quitting, or its watchdog after a crash) puts it back only if Cocaine was the one that
# turned it on and nobody has changed it since; `off` is an explicit OFF. on/off/release/forget are
# serialized by a lock, so the app, the iPhone (remote.zsh) and Terminal can't interleave.
# `watch` is the watchdog Cocaine.app starts: it notices when the app is gone (crash, kill -9) and undoes
# what the app left behind (see Sources/Recovery.swift).
#
# Tests point COCAINE_PMSET, COCAINE_SUDO, COCAINE_CAFFEINATE, COCAINE_DOMAIN (a plist path) and COCAINE_SUPPORT at stubs
# and temporary files. They grant nothing: the sudo rule only matches the real /usr/bin/pmset.

PMSET=${COCAINE_PMSET:-/usr/bin/pmset}
SUDO=${COCAINE_SUDO:-/usr/bin/sudo}
CAFFEINATE=${COCAINE_CAFFEINATE:-/usr/bin/caffeinate}
DOMAIN=${COCAINE_DOMAIN:-local.cocaine.toggle}   # where Cocaine.app keeps its settings (onUntil)
SELF=${0:A}   # capture now: inside functions zsh sets $0 to the function name
POLL=${COCAINE_POLL:-10}   # seconds between SleepDisabled checks while holding
HLOCKDIR="${COCAINE_SUPPORT:-$HOME/Library/Application Support/Cocaine}"   # private (0700), never a shared /tmp
/bin/mkdir -p -m 700 "$HLOCKDIR" 2>/dev/null
HLOCK="$HLOCKDIR/hold.lock"
HPID="$HLOCKDIR/hold.pid"     # the running helper's pid, written while it holds hold.lock
DARK="$HLOCKDIR/screen-off"   # present = screen-off mode
SLOCK="$HLOCKDIR/state.lock"
CLAIM="$HLOCKDIR/sleep-claim"
LEASE="$HLOCKDIR/recovery.json"
UNTIL="$HLOCKDIR/until"       # epoch of a deadline set by `on <duration>` or the iPhone, for the helper to enforce
COPY="$HLOCKDIR/engine/cocaine-app"   # the copy of the app Cocaine.app keeps next to this engine (Recovery.installEngineCopy)
HUD=${COCAINE_HUD_NAME:-OSDUIHelper}   # tests: a stand-in process name
MAXMIN=1440
zmodload zsh/system zsh/datetime zsh/zselect

nap() { zselect -t $1 2>/dev/null; return 0; }   # $1 hundredths of a second, without starting /bin/sleep

# Prints 1 or 0; prints nothing and fails if pmset could not be read.
read_flag() {
  local out l w; out=$($PMSET -g 2>/dev/null) && [[ -n $out ]] || return 1
  for l in ${(f)out}; do                 # the first line naming SleepDisabled, its second field (what awk's $2 was)
    [[ $l == *SleepDisabled* ]] || continue
    w=(${=l}); [[ ${w[2]} == 1 ]] && print 1 || print 0
    return 0
  done
  print 0
}
is_on()  { [[ "$(read_flag)" == 1 ]]; }
is_off() { [[ "$(read_flag)" == 0 ]]; }   # a positive OFF read, not a failed one

set_state() {  # $1 = 1|0
  $SUDO -n $PMSET -a disablesleep "$1" 2>/dev/null
}

# 90, 90m, 2h, 1h30m → minutes (1…MAXMIN); fails on anything else.
dur_minutes() {
  local s=${1:l} m
  if [[ $s =~ '^[0-9]{1,4}m?$' ]]; then m=$(( 10#${s%m} ))
  elif [[ $s =~ '^([0-9]{1,2})h(([0-9]{1,2})m?)?$' ]]; then m=$(( 10#${match[1]} * 60 + 10#${match[3]:-0} ))
  else return 1; fi
  (( m >= 1 && m <= MAXMIN )) || return 1
  print -r -- $m
}

# The deadline Cocaine.app keeps (epoch seconds), if any.
until_epoch() {
  local u   # exact: `defaults read` prints 1.79e+09
  u=$(/usr/bin/defaults export "$DOMAIN" - 2>/dev/null | /usr/bin/plutil -extract onUntil raw -o - - 2>/dev/null) || return 1
  u=$(printf '%.0f' "$u" 2>/dev/null) && [[ $u == <-> ]] || return 1
  print -r -- $u
}

# The state lock (fcntl, released by the kernel when this process exits). After 20 s go on without it rather than hang.
SLOCK_FD=
lock() {
  [[ -n ${COCAINE_NOLOCK:-} ]] && return 0             # tests only: shows the race the lock prevents
  : >> "$SLOCK" 2>/dev/null
  zsystem flock -t 20 -f SLOCK_FD "$SLOCK" 2>/dev/null || { SLOCK_FD=; print -ru2 -- "cocaine: state lock busy, going on"; }
}
unlock() { [[ -n $SLOCK_FD ]] && zsystem flock -u $SLOCK_FD 2>/dev/null; SLOCK_FD=; }

# prior=0|1 from the claim; fails if there is none.
claim_prior() {
  local l; [[ -r $CLAIM ]] && l=$(<"$CLAIM") && [[ $l == prior=[01]* ]] || return 1
  print -r -- ${l[7]}
}
write_claim() {  # atomic, 0600
  local t="$CLAIM.$$"
  ( umask 077; print -r -- "prior=$1 since=$EPOCHSECONDS" > "$t" ) 2>/dev/null && /bin/mv -f "$t" "$CLAIM"
}
# Someone turned the flag off: our claim is over (a later ON by someone else isn't ours to undo). 0 = it is off.
forget_if_off() { local r=1; lock; is_off && { /bin/rm -f "$CLAIM"; r=0; }; unlock; return $r; }

# True while some process holds `$1` (an fcntl lock, like zsystem flock and the app's own test of hold.lock). The test
# takes the lock in a subshell for an instant; a helper starting right then waits for it (flock -t 2), it doesn't give up.
lock_held() { : >> "$1" 2>/dev/null; ! ( zsystem flock -t 0 "$1" ) 2>/dev/null; }

# The running hold helper's pid, whichever copy of the engine started it; fails if none runs. A helper of an older engine
# (no hold.pid, matched by its argv as before) is still found, so an upgrade doesn't start a second one.
helper_pid() {
  local p
  lock_held "$HLOCK" || return 1
  if [[ -r $HPID ]] && p=$(<"$HPID") 2>/dev/null && [[ $p == <-> ]] && kill -0 $p 2>/dev/null; then
    print -r -- $p; return 0
  fi
  p=$(/usr/bin/pgrep -U $UID -f '^/bin/zsh /.*/Contents/Resources/cocaine hold$' 2>/dev/null) || return 1
  print -r -- ${p%%$'\n'*}
}

start_hold() {  # spawn a helper in its own session, so it outlives whoever started it
  helper_pid >/dev/null && return 0
  if [[ -x /usr/bin/perl ]]; then
    /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); chdir "/"; exec @ARGV or die' -- /bin/zsh "$SELF" hold </dev/null >/dev/null 2>&1 &!
  else
    ( cd / && exec /bin/zsh "$SELF" hold ) </dev/null >/dev/null 2>&1 &!
  fi
  local i; for i in {1..50}; do helper_pid >/dev/null && return 0; nap 10; done; return 1
}

stop_hold() {  # signal only the helper (it ends its own caffeinate child), and wait until it is gone so an `on` right after works
  local p i; p=$(helper_pid) || return 0
  kill -TERM $p 2>/dev/null
  for i in {1..30}; do kill -0 $p 2>/dev/null || return 0; nap 10; done; return 1
}

hold() {  # the helper itself; started by start_hold
  is_on || exit 0
  : >> "$HLOCK" 2>/dev/null
  zsystem flock -t 2 "$HLOCK" 2>/dev/null || exit 0   # another helper already holds it; the lock dies with its holder
  print -r -- $$ >| "$HPID" 2>/dev/null
  local flag kid n=0 want orphan=0
  hold_end() {
    if [[ -n ${COCAINE_TEST_HOLD_EXIT:-} ]]; then : > "$COCAINE_TEST_HOLD_EXIT"; nap 150; fi   # tests: widen the exit window
    [[ -n $kid ]] && kill -TERM $kid 2>/dev/null; [[ -r $HPID && "$(<$HPID)" == $$ ]] && /bin/rm -f "$HPID"; exit 0
  }
  trap hold_end TERM INT
  [[ -e $DARK ]] && flag=-i || flag=-d
  $CAFFEINATE $flag -w $$ & kid=$!
  while :; do
    nap 100
    [[ -e $DARK ]] && want=-i || want=-d
    if [[ $want != $flag ]]; then                  # the mode changed: swap the child
      kill -TERM $kid 2>/dev/null; flag=$want
      $CAFFEINATE $flag -w $$ & kid=$!
    fi
    kill -0 $kid 2>/dev/null || { $CAFFEINATE $flag -w $$ & kid=$!; }   # our caffeinate died: restart it
    (( ++n % POLL )) && continue
    # Turned OFF from anywhere => release at once, re-checked under the state lock, and ended while still holding it (the
    # kernel drops it as this process exits): an `on` waiting for that lock then finds no helper and starts a new one.
    if is_off; then lock; is_off && { /bin/rm -f "$CLAIM"; hold_end; }; unlock; fi
    deadline_check
    orphan_check
  done
}

# A deadline from `cocaine on 90m` or the iPhone: Cocaine.app ends it when it runs (it reads the same onUntil). When the app
# isn't running, the helper does, a minute late at most, after checking the app's setting (it may have been changed there).
deadline_check() {
  local u
  [[ -r $UNTIL ]] && u=$(<"$UNTIL") 2>/dev/null && [[ $u == <-> ]] || return 0
  (( EPOCHSECONDS >= u + ${COCAINE_DEADLINE_GRACE:-60} )) || return 0
  if ! u=$(until_epoch); then /bin/rm -f "$UNTIL"; return 0; fi        # cleared meanwhile (turned off, or timer removed)
  if (( u > EPOCHSECONDS )); then print -r -- $u >| "$UNTIL"; return 0; fi   # extended in the app
  lock
  set_state 0 && { /bin/rm -f "$CLAIM" "$UNTIL"; /usr/bin/defaults delete "$DOMAIN" onUntil 2>/dev/null; }
  unlock                                            # the next SleepDisabled check ends this helper
}

# Cocaine.app and its watchdog both gone (killed together) while this helper runs on: after a grace period (the watchdog's
# own recovery comes first) the helper undoes what the app's lease lists, as the watchdog would have: through the app's
# copy of itself when there is one (screens, wake, HUD, sleep), else the essentials here. A live owner is never touched.
orphan_check() {
  local l owner
  if ! [[ -r $LEASE ]] || ! l=$(<"$LEASE") 2>/dev/null || ! [[ $l =~ '"owner":([0-9]+)' ]]; then orphan=0; return 0; fi
  owner=$match[1]
  if kill -0 $owner 2>/dev/null; then orphan=0; return 0; fi
  (( orphan )) || orphan=$EPOCHSECONDS
  (( EPOCHSECONDS - orphan >= ${COCAINE_ORPHAN_GRACE:-60} )) || return 0
  orphan=$EPOCHSECONDS                             # at most one attempt per grace period
  ( trap - TERM INT; recover_owner $owner ) </dev/null >/dev/null 2>&1 &!   # its `release` ends this helper: not waited for here
}

recover_owner() {  # $1: the dead app's pid. 0 = done or nothing left; else what the last attempt said
  local r=127
  [[ -x $COPY ]] && { "$COPY" --recover-after $1 </dev/null >/dev/null 2>&1; r=$?; }
  (( r == 0 || r == 75 )) && return $r
  essentials $1
}

# Cocaine is done with sleep: back to what it was before Cocaine turned it on, unless someone changed it since.
# 0 done, 2 not authorized (claim kept), 4 pmset unreadable (claim kept).
release() {
  local cur prior
  cur=$(read_flag) || return 4
  if prior=$(claim_prior) && [[ $prior == 0 && $cur == 1 ]]; then set_state 0 || return 2; fi
  /bin/rm -f "$CLAIM" "$UNTIL"
  stop_hold
  return 0
}

# Ends OSDUIHelpers left frozen (SIGSTOP) by Cocaine; launchd starts a fresh one when it's needed. $1: a lease's text; when it
# lists the helpers Cocaine froze ("hudPids"), only those (a helper another tool froze is left alone).
thaw_hud() {
  local p list=
  [[ ${1:-} =~ '"hudPids":\[([0-9,]+)\]' ]] && list=",$match[1],"
  for p in $(/usr/bin/pgrep -U $UID -x "$HUD"); do
    [[ -n $list && $list != *",$p,"* ]] && continue
    [[ $(/bin/ps -o stat= -p $p) == T* ]] && kill -KILL $p 2>/dev/null
  done
}

# What the watchdog (or the hold helper) does itself when no copy of the app can run its recovery: the frozen HUD, the
# scheduled wake and sleep, for app `$1`'s lease. Screens the app dimmed can't be restored from here (that needs the app).
# The lease stays when sleep couldn't be released (not authorized, pmset unreadable): the next launch adopts it.
essentials() {
  local l r=0
  [[ -r $LEASE ]] && l=$(<"$LEASE") 2>/dev/null || return 0
  [[ $l == *"\"owner\":$1,"* || $l == *"\"owner\":$1}"* ]] || return 0
  [[ $l == *'"hudFrozen":true'* ]] && thaw_hud "$l"
  if [[ $l =~ '"wake":([0-9]+)' ]]; then             # the wake's time in this Mac's time zone now (what pmset reads)
    $SUDO -n $PMSET schedule cancel wake "$(strftime '%m/%d/%y %H:%M:%S' $match[1])" cocaine </dev/null >/dev/null 2>&1
  fi
  if [[ $l == *'"ownsSleep":true'* ]]; then lock; release; r=$?; unlock; fi
  (( r == 0 )) && /bin/rm -f "$LEASE"
  return $r
}

# Watchdog: `cocaine watch <app pid> <app binary>`, started by the app in its own session. Its stdin is a pipe whose only
# writer is the app (a heartbeat byte every 2 s), so EOF means the app is gone, however it ended, with no pid-reuse doubt.
# Then it runs the app's `--recover-after` until that says done (0). 75 (an update's hand-over pending, pmset unreadable)
# is retried for up to 15 min; a missing binary (being replaced) for 1 min; any other failure (a crash, a damaged or
# unrunnable binary) 3 times. Then the app's copy of itself in $SUPPORT/engine is tried the same way, then the essentials.
watch() {
  local owner=$1 bin=$2 stall=${COCAINE_WATCH_STALL:-30} buf r term=0
  [[ $owner == <-> && -n $bin ]] || exit 64
  trap '' HUP INT
  trap 'term=1' TERM
  while :; do
    sysread -t $stall -i 0 buf; r=$?
    if (( term )); then                                  # logout or someone ending us: act only if the app is gone too
      sysread -t 0 -i 0 buf; (( $? == 5 )) || exit 0
      break
    fi
    case $r in
      0) ;;                                              # heartbeat
      4) [[ -x $bin ]] && "$bin" --recover-hud $owner </dev/null >/dev/null 2>&1 ;;   # app hung: give the system HUD back
      *) break ;;                                        # EOF (5) or error: the app is gone
    esac
  done
  trap '' TERM
  local fails=0 missing=0 waits=0 alt=0
  local maxfail=${COCAINE_WATCH_FAILS:-3} maxmiss=${COCAINE_WATCH_MISSING:-60} maxwait=${COCAINE_WATCH_WAIT:-900}
  while :; do
    if [[ -x $bin ]]; then "$bin" --recover-after $owner </dev/null >/dev/null 2>&1; r=$?; else r=127; fi
    (( r == 0 )) && exit 0                               # done, or nothing was left to do
    case $r in
      75)  (( ++waits )) ;;
      127) (( ++missing )) ;;
      *)   (( ++fails )) ;;
    esac
    if (( fails >= maxfail || missing >= maxmiss || waits >= maxwait )); then
      if (( ! alt )) && [[ -x $COPY && $COPY != $bin ]]; then
        alt=1; bin=$COPY; fails=0; missing=0; continue
      fi
      essentials $owner
      exit 0
    fi
    nap 100
  done
}

status_json() {
  local on=false st=OFF u= rem=null screen=null
  is_on && { on=true; st=ON; }
  if [[ $on == true ]]; then
    helper_pid >/dev/null && { [[ -e $DARK ]] && screen='"may sleep"' || screen='"kept on"'; } || screen='"not held"'
    u=$(until_epoch) && (( u > EPOCHSECONDS )) && rem=$(( (u - EPOCHSECONDS + 59) / 60 )) || u=
  fi
  print -r -- "{\"state\":\"$st\",\"on\":$on,\"until\":${u:-null},\"remaining_minutes\":$rem,\"screen\":$screen,\"screen_off_mode\":$([[ -e $DARK ]] && print true || print false)}"
}

zmodload zsh/datetime
case "$1" in
  hold)   hold; exit 0 ;;
  on)     (( $# <= 2 )) || { print -ru2 -- "usage: cocaine on [duration]"; exit 64; }
          mins=
          if (( $# == 2 )); then
            mins=$(dur_minutes "$2") || { print -ru2 -- "bad duration '$2' (1 min to 24 h: 90, 90m, 2h, 1h30m)"; exit 64; }
          fi
          lock
          cur=$(read_flag) || { unlock; print -ru2 -- "can't read sleep settings"; exit 4; }
          wrote=0
          if ! claim_prior >/dev/null; then     # first ON: remember what it was (1 with our helper running = an older Cocaine's ON)
            if [[ $cur == 1 ]] && ! helper_pid >/dev/null; then write_claim 1; else write_claim 0; fi
            wrote=1
          fi
          set_state 1 || { (( wrote )) && /bin/rm -f "$CLAIM"; unlock; print -ru2 -- "not authorized to change sleep settings"; exit 2; }
          # -int: a -float is 32-bit, off by up to a minute at today's epoch (the app reads either as a number)
          if [[ -n $mins ]]; then
            /usr/bin/defaults write "$DOMAIN" onUntil -int $(( EPOCHSECONDS + mins * 60 ))
            print -r -- $(( EPOCHSECONDS + mins * 60 )) >| "$UNTIL"   # the helper ends it if Cocaine.app isn't running then
          fi
          start_hold; r=$?
          unlock
          (( r == 0 )) || { print -ru2 -- "display hold not active"; exit 3; }
          exit 0 ;;
  off)    (( $# == 1 )) || { print -ru2 -- "usage: cocaine off"; exit 64; }
          lock
          set_state 0 || { unlock; print -ru2 -- "not authorized to change sleep settings"; exit 2; }
          /bin/rm -f "$CLAIM" "$UNTIL"
          stop_hold; unlock; exit 0 ;;
  release) lock; release; r=$?; unlock; exit $r ;;
  forget) forget_if_off; exit 0 ;;
  watch)  shift; watch "$@" ;;
  thaw)   thaw_hud; exit 0 ;;
  expire) COCAINE_DEADLINE_GRACE=0 deadline_check; exit 0 ;;   # a passed command-line deadline, now (Cocaine --boot-check)
  status) case "${2:-}" in
            --json) status_json ;;
            "")     if is_on; then print -r -- "ON"
                      if helper_pid >/dev/null; then [[ -e $DARK ]] && print -r -- "display: may sleep (screen-off mode)" || print -r -- "display: held"
                      else print -r -- "display: not held"; fi
                    else print -r -- "OFF"; fi ;;
            *)      print -ru2 -- "usage: cocaine status [--json]"; exit 64 ;;
          esac
          exit 0 ;;
  mode)   case "${2:-}" in
            screen-off) : >> "$DARK" ;;
            normal)     /bin/rm -f "$DARK" ;;
            status)     [[ -e $DARK ]] && print -r -- "screen-off" || print -r -- "normal" ;;
            *)          print -ru2 -- "usage: cocaine mode screen-off|normal|status"; exit 64 ;;
          esac
          exit 0 ;;
  remote) shift; exec /bin/zsh "${SELF:h}/remote.zsh" "$@" ;;
  *)      print -ru2 -- "usage: cocaine on [duration]|off|status [--json]|mode …|release|forget|remote …"; exit 64 ;;
esac
