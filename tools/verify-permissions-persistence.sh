#!/bin/zsh
# Checks, with evidence, whether macOS can carry the permissions given to one build over to another:
#   tools/verify-permissions-persistence.sh <old Cocaine.app> <new Cocaine.app>
# macOS's privacy database (TCC) stores, for each grant, the app's designated requirement (csreq) and later lets in any
# code that satisfies it. So the test is the same one TCC makes: does the NEW build satisfy the OLD build's requirement?
# When the user TCC database is readable (Full Disk Access for the terminal) it also checks the stored csreq of every
# Cocaine grant against the new build. Reads only; changes nothing.
# Exit 0 = the new build satisfies the old one's requirement (and every readable stored grant); 1 = it doesn't.
set -euo pipefail
die() { print -u2 -- "$*"; exit 2; }
[ $# -eq 2 ] || die "usage: tools/verify-permissions-persistence.sh <old.app> <new.app>"
OLD="${1%/}" NEW="${2%/}"
for a in "$OLD" "$NEW"; do codesign --verify --strict "$a" 2>/dev/null || die "$a: missing or invalid signature"; done

info() { codesign -dvv "$1" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Signature)=' | tr '\n' ' '; }
dr() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
print -- "old: $(info "$OLD")"
print -- "new: $(info "$NEW")"
DR_OLD=$(dr "$OLD"); DR_NEW=$(dr "$NEW")
print -- "old designated requirement: $DR_OLD"
print -- "new designated requirement: $DR_NEW"

STATUS=0
if [[ "$DR_OLD" == *cdhash* ]]; then
  print -- "NOTE: the old build is signed ad hoc: its requirement is its own hash, so no other build can ever satisfy it."
fi
if codesign --verify -R="$DR_OLD" "$NEW" 2>/dev/null; then
  print -- "PASS  the new build satisfies the old build's designated requirement"
else
  print -- "FAIL  the new build does NOT satisfy the old build's designated requirement: macOS treats it as a different app"
  STATUS=1
fi

DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
ROWS=$(sqlite3 -readonly "$DB" "select service || '|' || auth_value || '|' || hex(csreq) from access where client = 'local.cocaine.toggle';" 2>/dev/null) || ROWS="__unreadable__"
if [ "$ROWS" = "__unreadable__" ]; then
  print -- "INFO  the TCC database isn't readable from here (needs Full Disk Access): no direct evidence from stored grants"
elif [ -z "$ROWS" ]; then
  print -- "INFO  no stored grants for local.cocaine.toggle in your user TCC database"
else
  WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
  for row in ${(f)ROWS}; do
    svc="${row%%|*}"; rest="${row#*|}"; auth="${rest%%|*}"; hex="${rest#*|}"
    [ -n "$hex" ] || { print -- "INFO  $svc: stored without a requirement"; continue; }
    print -n -- "$hex" | xxd -r -p > "$WORK/req.bin"
    if codesign --verify -R "$WORK/req.bin" "$NEW" 2>/dev/null; then
      print -- "PASS  $svc (auth $auth): the stored requirement accepts the new build"
    else
      print -- "FAIL  $svc (auth $auth): the stored requirement rejects the new build"; STATUS=1
    fi
  done
fi
print -- "What this proves: whether macOS's own requirement check accepts the new build. It doesn't prove how every"
print -- "privacy service behaves (Apple documents no guarantee for self-signed certificates); confirm once by updating and"
print -- "checking that the permissions are still on."
exit $STATUS
