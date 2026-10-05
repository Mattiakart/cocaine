#!/bin/zsh
# Real runs of the engine (cocaine.zsh) against stub pmset / sudo / caffeinate in a temporary folder: nothing on this Mac
# changes (the stubs keep SleepDisabled in a file; settings go to a temporary plist). Prints PASS/FAIL lines.
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
  local p; for p in $(/usr/bin/pgrep -f "/bin/zsh $T/cocaine hold"); do kill -TERM $p 2>/dev/null; done
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
export COCAINE_SUPPORT=$T/support COCAINE_DOMAIN=$T/prefs
E=(/bin/zsh $T/cocaine)
waitfor() { local i; for i in {1..40}; do eval "$1" && return 0; /bin/sleep 0.1; done; return 1; }
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
check "OFF from elsewhere ends the helper by itself" '$E on && print 0 > $T/state && waitfor "! /usr/bin/pgrep -qf \"/bin/zsh $T/cocaine hold\"" 2>/dev/null || { /bin/sleep 11; ! /usr/bin/pgrep -qf "/bin/zsh $T/cocaine hold"; }'
check "not authorized: exit 2, nothing changed" 'COCAINE_SUDO=/usr/bin/false $E on 2>/dev/null; [[ $? == 2 && $(<$T/state) == 0 ]]'
check "bad status option refused" '$E status --xml 2>/dev/null; [[ $? == 64 ]]'

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
check "remote: status --json shows it" '[[ "$($R status --json)" == *"\"cocaine\":\"ON\",\"until\":$(/usr/bin/defaults read $T/prefs onUntil),"* ]]'
check "remote: the engine reads the same deadline" '[[ "$($E status --json)" == *"\"until\":$(/usr/bin/defaults read $T/prefs onUntil),"* ]]'
check "remote: an old float deadline is still read" '/usr/bin/defaults write $T/prefs onUntil -float $(( EPOCHSECONDS + 600 )) && [[ "$($R status --json)" == *"\"until\":1"[0-9]*","* ]]'
check "remote: on without --for drops the deadline" '$R on >/dev/null && ! /usr/bin/defaults read $T/prefs onUntil >/dev/null 2>&1'
check "remote: off turns it off" '$R off >/dev/null && [[ $(<$T/state) == 0 && "$($R status)" == "Cocaine: OFF"* ]]'
check "remote: a bad duration changes nothing" '$R on --for 3d 2>/dev/null; [[ $? != 0 && $(<$T/state) == 0 ]]'
exit $(( failed > 0 ))
