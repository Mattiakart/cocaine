#!/bin/zsh
# cocaine — engine behind Cocaine.app: overrides macOS sleep (pmset disablesleep) and, while
# that override is ON, keeps the display from idle-sleeping. Usage: cocaine on|off|status
#
# `disablesleep` shows as `SleepDisabled` in `pmset -g` (never in `pmset -g custom`):
# absent or 0 = OFF, 1 = ON. Changing it needs root; Cocaine.app installs a narrow NOPASSWD
# rule for exactly `pmset -a disablesleep 1|0` (/etc/sudoers.d/cocaine) the first time it runs.
#
# Display hold: `on` starts one detached `cocaine hold` helper, which keeps a child
# `caffeinate -d -w <its pid>` while SleepDisabled is 1 and exits on its own once it reads 0.
# Nothing runs at login unless Cocaine.app itself is a login item. Stored pmset values are never
# changed, and only our own helper (matched by its exact argv) is ever signalled.
# While the display is held macOS skips the screen saver, so the Mac does not auto-lock on idle.

PMSET=/usr/bin/pmset
SELF=${0:A}   # capture now: inside functions zsh sets $0 to the function name
SELF_RE=$(print -r -- "$SELF" | /usr/bin/sed 's/[][\\.^$*+?(){}|]/\\&/g')   # the path as a literal regex
POLL=10       # seconds between SleepDisabled checks while holding
HLOCK="${TMPDIR:-/tmp}/cocaine.hold.lock"
zmodload zsh/system

# Prints 1 or 0; prints nothing and fails if pmset could not be read.
read_flag() {
  local out; out=$($PMSET -g 2>/dev/null) && [[ -n $out ]] || return 1
  [[ "$(awk '/SleepDisabled/{print $2; exit}' <<< "$out")" == "1" ]] && print 1 || print 0
}
is_on()  { [[ "$(read_flag)" == 1 ]]; }
is_off() { [[ "$(read_flag)" == 0 ]]; }   # a positive OFF read, not a failed one

set_state() {  # $1 = 1|0
  sudo -n $PMSET -a disablesleep "$1" 2>/dev/null
}

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
  local i; for i in {1..30}; do hold_pid >/dev/null || return 0; /bin/sleep 0.1; done; return 1
}

hold() {  # the helper itself; started by start_hold
  is_on || exit 0
  : >> "$HLOCK" 2>/dev/null
  zsystem flock -t 0 "$HLOCK" 2>/dev/null || exit 0   # another helper already holds; lock dies with it
  /usr/bin/caffeinate -d -w $$ &
  local kid=$! n=0
  while :; do
    /bin/sleep 1
    kill -0 $kid 2>/dev/null || { /usr/bin/caffeinate -d -w $$ & kid=$!; }   # our caffeinate died: restart it
    (( ++n % POLL )) && continue
    is_off && exit 0                   # turned OFF from anywhere => exit => caffeinate -w releases
  done
}

case "$1" in
  hold)   hold; exit 0 ;;
  on)     set_state 1 || { print -ru2 -- "not authorized to change sleep settings"; exit 2; }
          start_hold || { print -ru2 -- "display hold not active"; exit 3; }
          exit 0 ;;
  off)    set_state 0 || { print -ru2 -- "not authorized to change sleep settings"; exit 2; }
          stop_hold; exit 0 ;;
  status) if is_on; then print -r -- "ON"; hold_pid >/dev/null && print -r -- "display: held" || print -r -- "display: not held"
          else print -r -- "OFF"; fi
          exit 0 ;;
  *)      print -ru2 -- "usage: cocaine on|off|status"; exit 64 ;;
esac
