#!/bin/zsh
# Real runs of the engine (cocaine.zsh) against stub pmset / sudo / caffeinate in a temporary folder: nothing on this Mac
# changes (the stubs keep SleepDisabled in a file; settings go to a temporary plist; the support folder is temporary, so the
# helper found through hold.pid is this test's own). Prints PASS/FAIL lines.
#   zsh tests/engine-test.zsh [path/to/cocaine.zsh]    (needs the Command Line Tools' cc for the caffeinate stub)
ENGINE_SRC=${1:-${0:A:h:h}/cocaine.zsh}
# An engine without the stub overrides would run the real sudo pmset: refuse it.
for v in COCAINE_PMSET COCAINE_SUDO COCAINE_CAFFEINATE COCAINE_DOMAIN; do
  /usr/bin/grep -q "\${$v:-" "$ENGINE_SRC" || { print -r -- "FAIL  engine: $ENGINE_SRC ignores $v (would touch the real system); not run"; exit 1; }
done
T=$(/usr/bin/mktemp -d /tmp/cocaine-engine-test.XXXXXX) || exit 1
T=${T:A}   # the engine sees its own resolved path (/private/tmp)
zmodload zsh/datetime
failed=0
check() { if eval "$2"; then print -r -- "PASS  engine: $1"; else print -r -- "FAIL  engine: $1"; (( failed++ )); fi; }
cleanup() {
  local p; for p in $(/usr/bin/pgrep -f "^/bin/zsh $T/.*cocaine hold$"); do kill -TERM $p 2>/dev/null; done
  /usr/bin/pkill -TERM -f "$T/bin/caffeinate" 2>/dev/null
  /bin/rm -rf "$T"
}
trap cleanup EXIT INT TERM

mkdir -p $T/bin $T/support
print 0 > $T/state
cat > $T/bin/pmset <<EOF
#!/bin/zsh
print -r -- "\$*" >> $T/pmset.log
case "\$1" in
  -g) print "System-wide power settings:"; print " SleepDisabled\t\$(<$T/state)" ;;
  -a) [[ \$2 == disablesleep && ( \$3 == 0 || \$3 == 1 ) ]] && print \$3 > $T/state || exit 1 ;;
  *) exit 1 ;;
esac
EOF
cat > $T/bin/sudo <<'EOF'
#!/bin/zsh
[[ $1 == -n ]] && shift
exec "$@"
EOF
# caffeinate stand-in: same process name, logs its flags, lives until the -w process exits.
cat > $T/caff.c <<EOF
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int c, char **v) {
  FILE *f = fopen("$T/caff.log", "a"); int w = 0;
  for (int i = 1; i < c; i++) { if (f) fprintf(f, "%s ", v[i]); if (!strcmp(v[i], "-w") && i + 1 < c) w = atoi(v[i + 1]); }
  if (f) { fprintf(f, "\n"); fclose(f); }
  while (w > 0 && kill(w, 0) == 0) usleep(100000);
  return 0;
}
EOF
/usr/bin/cc -o $T/bin/caffeinate $T/caff.c 2>/dev/null || { print "SKIP  engine: no C compiler for the caffeinate stub"; exit 0; }
chmod +x $T/bin/pmset $T/bin/sudo
cp "$ENGINE_SRC" $T/cocaine
export COCAINE_PMSET=$T/bin/pmset COCAINE_SUDO=$T/bin/sudo COCAINE_CAFFEINATE=$T/bin/caffeinate
export COCAINE_SUPPORT=$T/support COCAINE_DOMAIN=$T/prefs COCAINE_POLL=1 COCAINE_DEADLINE_GRACE=0
E=(/bin/zsh $T/cocaine)
waitfor() { local i; for i in {1..${2:-40}}; do eval "$1" && return 0; /bin/sleep 0.1; done; return 1; }
# The helper of this test runs: it holds $T/support/hold.lock and its pid is in hold.pid.
helper_up() { [[ -r $T/support/hold.pid ]] && kill -0 $(<$T/support/hold.pid) 2>/dev/null && /usr/bin/python3 -c 'import fcntl,os,struct,sys
fd=os.open(sys.argv[1],os.O_RDONLY); r=fcntl.fcntl(fd,fcntl.F_GETLK,struct.pack("qqihh",0,0,0,fcntl.F_WRLCK,0)); sys.exit(0 if struct.unpack("qqihh",r)[3]!=fcntl.F_UNLCK else 1)' $T/support/hold.lock; }
lastflag() { /usr/bin/tail -1 $T/caff.log 2>/dev/null | /usr/bin/awk '{print $1}'; }

check "status OFF at the start" '[[ "$($E status)" == OFF ]]'
check "status --json when off" '[[ "$($E status --json)" == *"\"state\":\"OFF\""*"\"until\":null"* ]]'
check "on sets SleepDisabled through sudo pmset" '$E on && [[ $(<$T/state) == 1 ]]'
check "on starts the helper holding the display (-d)" 'waitfor "[[ \$(lastflag) == -d ]]"'
check "status says ON, display held" '[[ "$($E status)" == $'"'"'ON\ndisplay: held'"'"' ]]'
check "on 90m writes the deadline" '$E on 90m && u=$(/usr/bin/defaults read $T/prefs onUntil) && (( ${u%.*} - EPOCHSECONDS >= 5390 && ${u%.*} - EPOCHSECONDS <= 5400 ))'
check "status --json has the minutes left" '[[ "$($E status --json)" == *"\"state\":\"ON\""*"\"remaining_minutes\":90"*"\"screen\":\"kept on\""* ]]'
check "1h30m and plain minutes are read" '$E on 1h30m && $E on 45'
before=$(/usr/bin/wc -l < $T/pmset.log)
for bad in 0 1441 25h 90x "1;id" '$(id)' -5 "" 1e3 "1 2"; do
  check "bad duration '$bad' refused before anything changes" '$E on "$bad" 2>/dev/null; [[ $? == 64 ]]'
done
check "the refused ones never ran pmset -a" '(( $(/usr/bin/grep -c "^-a" $T/pmset.log) == $(/usr/bin/head -n $before $T/pmset.log | /usr/bin/grep -c "^-a") ))'
check "extra arguments are refused" '$E on 5 6 2>/dev/null; [[ $? == 64 ]] && { $E off now 2>/dev/null; [[ $? == 64 ]] }'
check "screen-off mode swaps the helper to -i (no display hold)" '$E mode screen-off && waitfor "[[ \$(lastflag) == -i ]]"'
check "status in screen-off mode" '[[ "$($E status)" == *"may sleep"* && "$($E status --json)" == *"\"screen\":\"may sleep\""*"\"screen_off_mode\":true"* ]]'
check "only one helper" '(( $(/usr/bin/pgrep -f "/bin/zsh $T/cocaine hold" | /usr/bin/wc -l) == 1 ))'
check "normal mode holds the display again" '$E mode normal && waitfor "[[ \$(lastflag) == -d ]]" && [[ "$($E mode status)" == normal ]]'
check "a bad mode is refused" '$E mode bright 2>/dev/null; [[ $? == 64 ]]'
check "off clears SleepDisabled and ends the helper" '$E off && [[ $(<$T/state) == 0 ]] && waitfor "! /usr/bin/pgrep -qf \"/bin/zsh $T/cocaine hold\""'
check "the caffeinate stand-in is gone too" 'waitfor "! /usr/bin/pgrep -qf $T/bin/caffeinate"'
# (the helper reads SleepDisabled every COCAINE_POLL=1 s here; the ON must have worked, or this would pass by itself)
check "OFF from elsewhere ends the helper by itself" '$E on && helper_up && print 0 > $T/state && waitfor "! helper_up" 30'
check "not authorized: exit 2, nothing changed" 'COCAINE_SUDO=/usr/bin/false $E on 2>/dev/null; [[ $? == 2 && $(<$T/state) == 0 ]]'
check "bad status option refused" '$E status --xml 2>/dev/null; [[ $? == 64 ]]'

# An ON that arrives while the helper is ending after an OFF from elsewhere must get a new helper, not the dying one: the
# helper ends while still holding the state lock, so that ON waits for it (before, Cocaine stayed ON with no display hold).
$E off >/dev/null 2>&1
check "ON during the helper's exit after an OFF from elsewhere ends ON with a live helper" 'ok=1; for n in 1 2; do $E off >/dev/null; /bin/rm -f $T/exiting; COCAINE_TEST_HOLD_EXIT=$T/exiting $E on && helper_up && print 0 > $T/state && waitfor "[[ -e $T/exiting ]]" 40 && $E on && /bin/sleep 2.5 && [[ $(<$T/state) == 1 ]] && helper_up || ok=0; done; (( ok ))'
$E off >/dev/null 2>&1

# The helper is found through hold.pid + hold.lock, not its path: another copy of the engine (another Cocaine.app, the copy
# in Application Support) sees it, reuses it and stops it. Before, copy B said "not held", waited 6 s and failed with 3.
mkdir -p $T/b; cp $T/cocaine $T/b/cocaine; B=(/bin/zsh $T/b/cocaine)
$E off >/dev/null 2>&1
check "two copies: A's helper is held for B too" '$E on && [[ "$($B status)" == $'"'"'ON\ndisplay: held'"'"' ]]'
check "two copies: B's ON reuses it at once (no second helper, no wait)" 's=$EPOCHREALTIME; $B on && (( EPOCHREALTIME - s < 2 )) && (( $(/usr/bin/pgrep -f "cocaine hold$" | /usr/bin/xargs -n1 ps -o args= -p 2>/dev/null | /usr/bin/grep -c "^/bin/zsh $T/") == 1 ))'
check "two copies: B's OFF stops A's helper" '$B off && waitfor "! helper_up"'
check "hold.pid is removed with the helper" '[[ ! -e $T/support/hold.pid ]]'
# No process is started while the helper idles (it waits with zselect, not /bin/sleep).
$E on >/dev/null 2>&1
check "the idle helper starts no process (no /bin/sleep every second)" 'h=$(<$T/support/hold.pid) && [[ -n $h ]] && { n=0; for i in {1..25}; do /usr/bin/pgrep -P $h -x sleep >/dev/null && (( n++ )); /bin/sleep 0.1; done; (( n == 0 )) }'
$E off >/dev/null 2>&1

# A deadline from the command line (or the iPhone) when Cocaine.app isn't running: the helper ends it.
check "on 1 writes the deadline for the helper too" '$E on 1 && u=$(<$T/support/until) && (( u - EPOCHSECONDS >= 55 && u - EPOCHSECONDS <= 60 ))'
check "a deadline the app extended meanwhile is kept" 'print $(( EPOCHSECONDS - 5 )) > $T/support/until; /usr/bin/defaults write $T/prefs onUntil -int $(( EPOCHSECONDS + 600 )); /bin/sleep 2.5; [[ $(<$T/state) == 1 && $(<$T/support/until) == $(( $(/usr/bin/defaults read $T/prefs onUntil) )) ]]'
check "a passed deadline turns it off with no app running" '/usr/bin/defaults write $T/prefs onUntil -int $(( EPOCHSECONDS - 5 )); print $(( EPOCHSECONDS - 5 )) > $T/support/until; waitfor "[[ \$(<$T/state) == 0 ]]" 40 && waitfor "! helper_up" && [[ ! -e $T/support/until ]] && ! /usr/bin/defaults read $T/prefs onUntil >/dev/null 2>&1'
check "off removes the deadline file" '$E on 5 && $E off && [[ ! -e $T/support/until ]]'
check "expire (boot check) ends a passed deadline at once" '$E on 5 && helper_up && kill -KILL $(<$T/support/hold.pid) && print $(( EPOCHSECONDS - 1 )) > $T/support/until && /usr/bin/defaults write $T/prefs onUntil -int $(( EPOCHSECONDS - 1 )) && $E expire && [[ $(<$T/state) == 0 ]]'
$E off >/dev/null 2>&1

# The watchdog (P1-1): only a 0 from the app's recovery ends it. A binary that crashes or is missing, even with the
# engine file itself deleted, ends in the essentials done by the watchdog: HUD, wake, sleep, lease.
WAKE=$(( EPOCHSECONDS + 900 ))
lease() { print -r -- "{\"owner\":$1,\"ownerStart\":1,\"ownsSleep\":true,\"hudFrozen\":false,\"dim\":[],\"wake\":$WAKE.25}" > $T/support/recovery.json; }
print '#!/bin/sh\nkill -SEGV $$' > $T/crashbin; chmod +x $T/crashbin
check "watchdog: a crashing app binary is not 'done': sleep, wake and lease are recovered" '$E on && lease 99991 && $E watch 99991 $T/crashbin </dev/null; [[ $(<$T/state) == 0 && ! -e $T/support/recovery.json ]] && /usr/bin/grep -q "^schedule cancel wake $(strftime "%m/%d/%y %H:%M:%S" $WAKE) cocaine" $T/pmset.log && waitfor "! helper_up"'
cp $T/cocaine $T/gone-engine
check "watchdog: the same with no app binary and its own script file deleted (in seconds, not 10 min)" 's=$EPOCHSECONDS; $E on && lease 99992 && { COCAINE_WATCH_MISSING=2 /bin/zsh $T/gone-engine watch 99992 $T/nonexistent </dev/null & w=$!; /bin/sleep 0.5; /bin/rm -f $T/gone-engine; wait $w; } && [[ $(<$T/state) == 0 && ! -e $T/support/recovery.json ]] && (( EPOCHSECONDS - s < 30 )) && waitfor "! helper_up"'
check "watchdog: sleep not authorized: the lease stays for the next launch" '$E on && lease 99993 && COCAINE_SUDO=/usr/bin/false $E watch 99993 $T/crashbin </dev/null; [[ $(<$T/state) == 1 && -e $T/support/recovery.json ]]'
/bin/rm -f $T/support/recovery.json; $E off >/dev/null 2>&1

# remote.zsh on top of this engine (stubbed system, temporary HOME, support folder and settings plist)
cp "${ENGINE_SRC:h}/remote.zsh" $T/remote.zsh
chmod +x $T/cocaine
mkdir -p $T/home
R=(env HOME=$T/home COCAINE_ENGINE=$T/cocaine COCAINE_SCREENDIR=$T/home/s /bin/zsh $T/remote.zsh)
$E off >/dev/null 2>&1
check "remote: status reads OFF from the engine" '[[ "$($R status)" == "Cocaine: OFF"* ]]'
check "remote: on --for 90m turns it on" '$R on --for 90m >/dev/null && [[ $(<$T/state) == 1 && "$($E status | /usr/bin/head -1)" == ON ]]'
check "remote: the deadline is written as an integer (exact)" '[[ "$(/usr/bin/defaults read-type $T/prefs onUntil)" == *integer* ]]'
check "remote: …90 minutes from now" 'u=$(/usr/bin/defaults read $T/prefs onUntil) && [[ $u == <-> ]] && (( u - EPOCHSECONDS >= 5395 && u - EPOCHSECONDS <= 5400 ))'
check "remote: …and tells the engine's helper (until file)" '[[ $(<$T/support/until) == $(/usr/bin/defaults read $T/prefs onUntil) ]]'
check "remote: status --json shows it" '[[ "$($R status --json)" == *"\"cocaine\":\"ON\",\"until\":$(/usr/bin/defaults read $T/prefs onUntil),"* ]]'
check "remote: the engine reads the same deadline" '[[ "$($E status --json)" == *"\"until\":$(/usr/bin/defaults read $T/prefs onUntil),"* ]]'
check "remote: an old float deadline is still read" '/usr/bin/defaults write $T/prefs onUntil -float $(( EPOCHSECONDS + 600 )) && [[ "$($R status --json)" == *"\"until\":1"[0-9]*","* ]]'
check "remote: on without --for drops the deadline" '$R on >/dev/null && ! /usr/bin/defaults read $T/prefs onUntil >/dev/null 2>&1 && [[ ! -e $T/support/until ]]'
check "remote: off turns it off" '$R off >/dev/null && [[ $(<$T/state) == 0 && "$($R status)" == "Cocaine: OFF"* ]]'
check "remote: a bad duration changes nothing" '$R on --for 3d 2>/dev/null; [[ $? != 0 && $(<$T/state) == 0 ]]'
exit $(( failed > 0 ))
