#!/bin/zsh
# cocaine — engine behind Cocaine.app: overrides macOS sleep (pmset disablesleep) and, while
# that override is ON, keeps the display from idle-sleeping (or, in "screen off" mode, lets it sleep).
#
#   cocaine on [duration]     on; with a duration (90, 90m, 2h, 1h30m; 1 min…24 h) Cocaine.app turns it off then
#   cocaine off
#   cocaine status [--json]   ON/OFF (first line), then the display hold; --json for scripts and Shortcuts
#   cocaine mode screen-off|normal|status   screen off: the Mac stays awake but its displays may sleep (and lock)
#   cocaine release | forget  used by Cocaine.app (quit, crash recovery); `watch` is its watchdog
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
# Nothing runs at login unless Cocaine.app itself is a login item. Stored pmset values are never
# changed, and only our own helper (matched by its exact argv) is ever signalled.
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
SELF_RE=$(print -r -- "$SELF" | /usr/bin/sed 's/[][\\.^$*+?(){}|]/\\&/g')   # the path as a literal regex
POLL=10       # seconds between SleepDisabled checks while holding
HLOCKDIR="${COCAINE_SUPPORT:-$HOME/Library/Application Support/Cocaine}"   # private (0700), never a shared /tmp
/bin/mkdir -p -m 700 "$HLOCKDIR" 2>/dev/null
HLOCK="$HLOCKDIR/hold.lock"
DARK="$HLOCKDIR/screen-off"   # present = screen-off mode
SLOCK="$HLOCKDIR/state.lock"
CLAIM="$HLOCKDIR/sleep-claim"
LEASE="$HLOCKDIR/recovery.json"
HUD=${COCAINE_HUD_NAME:-OSDUIHelper}   # tests: a stand-in process name
MAXMIN=1440
zmodload zsh/system zsh/datetime

# Prints 1 or 0; prints nothing and fails if pmset could not be read.
read_flag() {
  local out; out=$($PMSET -g 2>/dev/null) && [[ -n $out ]] || return 1
  [[ "$(awk '/SleepDisabled/{print $2; exit}' <<< "$out")" == "1" ]] && print 1 || print 0
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

helper_pids() { /usr/bin/pgrep -U $UID -xf "/bin/zsh ${SELF_RE} hold"; }

# PID of the caffeinate held by our helper; fails if none.
hold_pid() {
  local w c
  for w in $(helper_pids); do
    c=$(/usr/bin/pgrep -P $w -x caffeinate) && { print -r -- ${c%%$'\n'*}; return 0; }
  done
  return 1
}

start_hold() {  # spawn a helper in its own session, so it outlives whoever started it
  hold_pid >/dev/null && return 0
  if [[ -x /usr/bin/perl ]]; then
    /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); chdir "/"; exec @ARGV or die' -- /bin/zsh "$SELF" hold </dev/null >/dev/null 2>&1 &!
  else
    ( cd / && exec /bin/zsh "$SELF" hold ) </dev/null >/dev/null 2>&1 &!
  fi
  local i; for i in {1..50}; do hold_pid >/dev/null && return 0; /bin/sleep 0.1; done; return 1
}

stop_hold() {  # signal only our helper and its own caffeinate child, so the hold ends at once
  local w kids=()
  for w in $(helper_pids); do kids+=($(/usr/bin/pgrep -P $w -x caffeinate)); kill -TERM $w 2>/dev/null; done
  (( $#kids )) && kill -TERM $kids 2>/dev/null
  # until the helper itself is gone (it still holds hold.lock while it finishes its 1 s sleep), so an `on` right after works
  local i; for i in {1..30}; do helper_pids >/dev/null || return 0; /bin/sleep 0.1; done; return 1
}

hold() {  # the helper itself; started by start_hold
  is_on || exit 0
  : >> "$HLOCK" 2>/dev/null
  zsystem flock -t 0 "$HLOCK" 2>/dev/null || exit 0   # another helper already holds; lock dies with it
  local flag kid n=0 want
  trap '[[ -n $kid ]] && kill -TERM $kid 2>/dev/null; exit 0' TERM INT
  [[ -e $DARK ]] && flag=-i || flag=-d
  $CAFFEINATE $flag -w $$ & kid=$!
  while :; do
    /bin/sleep 1
    [[ -e $DARK ]] && want=-i || want=-d
    if [[ $want != $flag ]]; then                  # the mode changed: swap the child
      kill -TERM $kid 2>/dev/null; flag=$want
      $CAFFEINATE $flag -w $$ & kid=$!
    fi
    kill -0 $kid 2>/dev/null || { $CAFFEINATE $flag -w $$ & kid=$!; }   # our caffeinate died: restart it
    (( ++n % POLL )) && continue
    is_off && forget_if_off && { kill -TERM $kid 2>/dev/null; exit 0; }   # turned OFF from anywhere => release at once (re-checked under the lock)
  done
}

# Cocaine is done with sleep: back to what it was before Cocaine turned it on, unless someone changed it since.
# 0 done, 2 not authorized (claim kept), 4 pmset unreadable (claim kept).
release() {
  local cur prior
  cur=$(read_flag) || return 4
  if prior=$(claim_prior) && [[ $prior == 0 && $cur == 1 ]]; then set_state 0 || return 2; fi
  /bin/rm -f "$CLAIM"
  stop_hold
  return 0
}

# Ends OSDUIHelpers left frozen (SIGSTOP) by Cocaine; launchd starts a fresh one when it's needed.
thaw_hud() {
  local p
  for p in $(/usr/bin/pgrep -U $UID -x "$HUD"); do
    [[ $(/bin/ps -o stat= -p $p) == T* ]] && kill -KILL $p 2>/dev/null
  done
}

# Watchdog: `cocaine watch <app pid> <app binary>`, started by the app in its own session. Its stdin is a pipe whose only
# writer is the app (a heartbeat byte every 2 s), so EOF means the app is gone, however it ended, with no pid-reuse doubt.
watch() {
  local owner=$1 bin=$2 stall=${COCAINE_WATCH_STALL:-30} buf r term=0 tries=0
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
  while :; do
    if [[ -x $bin ]]; then "$bin" --recover-after $owner </dev/null >/dev/null 2>&1; r=$?; else r=127; fi
    (( r == 75 || r == 127 )) || exit 0                  # 75: update hand-over pending; 127: app moved (being updated)
    if (( ++tries >= ${COCAINE_WATCH_TRIES:-600} )); then   # ~10 min without a usable app binary: do the essentials here
      [[ -r $LEASE ]] || exit 0
      local l; l=$(<"$LEASE")
      [[ $l == *"\"owner\":$owner,"* || $l == *"\"owner\":$owner}"* ]] || exit 0
      [[ $l == *'"hudFrozen":true'* ]] && thaw_hud
      if [[ $l == *'"ownsSleep":true'* ]]; then lock; release; unlock; fi
      /bin/rm -f "$LEASE"
      exit 0
    fi
    /bin/sleep 1
  done
}

status_json() {
  local on=false st=OFF u= rem=null screen=null
  is_on && { on=true; st=ON; }
  if [[ $on == true ]]; then
    hold_pid >/dev/null && { [[ -e $DARK ]] && screen='"may sleep"' || screen='"kept on"'; } || screen='"not held"'
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
            if [[ $cur == 1 ]] && ! hold_pid >/dev/null; then write_claim 1; else write_claim 0; fi
            wrote=1
          fi
          set_state 1 || { (( wrote )) && /bin/rm -f "$CLAIM"; unlock; print -ru2 -- "not authorized to change sleep settings"; exit 2; }
          # -int: a -float is 32-bit, off by up to a minute at today's epoch (the app reads either as a number)
          [[ -n $mins ]] && /usr/bin/defaults write "$DOMAIN" onUntil -int $(( EPOCHSECONDS + mins * 60 ))
          start_hold; r=$?
          unlock
          (( r == 0 )) || { print -ru2 -- "display hold not active"; exit 3; }
          exit 0 ;;
  off)    (( $# == 1 )) || { print -ru2 -- "usage: cocaine off"; exit 64; }
          lock
          set_state 0 || { unlock; print -ru2 -- "not authorized to change sleep settings"; exit 2; }
          /bin/rm -f "$CLAIM"
          stop_hold; unlock; exit 0 ;;
  release) lock; release; r=$?; unlock; exit $r ;;
  forget) forget_if_off; exit 0 ;;
  watch)  shift; watch "$@" ;;
  thaw)   thaw_hud; exit 0 ;;
  status) case "${2:-}" in
            --json) status_json ;;
            "")     if is_on; then print -r -- "ON"
                      if hold_pid >/dev/null; then [[ -e $DARK ]] && print -r -- "display: may sleep (screen-off mode)" || print -r -- "display: held"
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
