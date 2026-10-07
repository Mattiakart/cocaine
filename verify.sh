#!/bin/zsh
# Builds and checks everything that can be checked without credentials, admin rights or a person at the Mac:
# shell and plist lint, the signing/notarization script tests (with fakes), a universal build of the requested tier,
# the app's own test suites, localization consistency, and any release artifacts in dist/ against their declared tier.
#   ./verify.sh                    local tier when this Mac has the local identity, else ad hoc; never installs, never
#                                  creates a signing identity (VERIFY_SIGN=local fails instead when there is none)
#   VERIFY_SIGN=adhoc ./verify.sh  what CI runs
# The app's suites run from a copy of the build with its own bundle id (local.cocaine.verify-<pid>), deleted and
# forgotten by Launch Services afterwards: they never touch the settings, the Launch Services entry or the processes of
# the Cocaine you use. A check at the end proves the real settings domain (local.cocaine.toggle) and the copy's own
# domain were not written.
# Tests that need the GUI session, privacy permissions, admin rights or third-party network are listed as SKIP with the
# reason; run them by hand when needed (see the list at the end).
set -uo pipefail
cd "${0:A:h}"
KC="$HOME/.cocaine-signing/cocaine-signing.keychain"
if [ -n "${VERIFY_SIGN:-}" ]; then SIGN="$VERIFY_SIGN"
elif [ "${CI:-}" = true ] || [ ! -f "$KC" ]; then SIGN=adhoc
else SIGN=local; fi
export COCAINE_NO_NEW_IDENTITY=1        # verify never makes a signing identity as a side effect
FAILED=() SKIPPED=()
step() { print -- "\n== $1"; }
ok() { print -- "PASS  $1"; }
bad() { print -- "FAIL  $1"; FAILED+=("$1"); }
skipped() { print -- "SKIP  $1  ($2)"; SKIPPED+=("$1"); }
run() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
[ "$SIGN" = adhoc ] && [ -z "${VERIFY_SIGN:-}" ] && [ "${CI:-}" != true ] && print -- "note: no local signing identity on this Mac: building ad hoc (VERIFY_SIGN=local to require it)"

step "shell syntax"
for f in build.sh make-signing-identity.sh verify.sh cocaine.zsh remote.zsh tools/*.sh tests/*.zsh; do
  run "zsh -n $f" zsh -n "$f"
done
if command -v shellcheck >/dev/null; then
  SH=(${(f)"$(grep -l -E '^#!/bin/(ba)?sh' build.sh make-signing-identity.sh tools/*.sh 2>/dev/null)"})
  if [ ${#SH[@]} -gt 0 ] && [ -n "${SH[1]}" ]; then run "shellcheck ${SH[*]}" shellcheck "${SH[@]}"; else skipped "shellcheck" "all scripts are zsh, which shellcheck doesn't parse"; fi
else
  skipped "shellcheck" "not installed"
fi

step "property lists"
run "plutil -lint Info.plist" plutil -lint -s Info.plist
run "plutil -lint Cocaine.entitlements" plutil -lint -s Cocaine.entitlements
for f in Localization/*.lproj/*.strings; do run "plutil -lint $f" plutil -lint -s "$f"; done
run "Info.plist: bundle id local.cocaine.toggle" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)" = local.cocaine.toggle
BUILDNO=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
run "Info.plist: build number is an integer" zsh -c "[[ '$BUILDNO' == <-> ]]"
if [ -f tools/last-release ]; then
  read -r LASTV LASTB < tools/last-release
  # A version that isn't the last release's needs a higher build: installed copies compare build numbers too.
  run "Info.plist: build $BUILDNO not behind the last release ($LASTV, build $LASTB; higher when the version changed)" \
    zsh -c "[[ '$VERSION' == '$LASTV' ]] && (( $BUILDNO == $LASTB )) || (( $BUILDNO > $LASTB ))"
fi

step "signing and release scripts (fakes, no credentials)"
run "tools/test-scripts.sh" zsh tools/test-scripts.sh

step "universal build, tier $SIGN"
if ./build.sh --no-install --sign "$SIGN"; then
  ok "build ($SIGN)"
  BUILT=build.noindex/Cocaine.app
  BIN=$BUILT/Contents/MacOS/Cocaine
  run "universal binary (arm64 + x86_64)" zsh -c "lipo -archs $BIN | tr ' ' '\n' | sort | tr '\n' ' ' | grep -qx 'arm64 x86_64 '"
  WANT=$([ "$SIGN" = developer-id ] && echo developerID || echo "$SIGN")
  run "the app reads its own tier as $WANT" zsh -c "$BIN --signature-tier $BUILT | grep -q '^tier=$WANT '"
  run "minimum macOS 14 in every slice" zsh -c "for a in arm64 x86_64; do vtool -arch \$a -show-build $BIN | grep -q 'minos 14.0' || exit 1; done"

  # The isolated copy the suites run from (see the top of this file).
  T=$(mktemp -d)
  ISOID="local.cocaine.verify-$$"
  LSR=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
  cleanup_copy() {
    [ -d "$T/Cocaine.app" ] && "$LSR" -u "$T/Cocaine.app" 2>/dev/null
    /usr/bin/defaults delete "$ISOID" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$ISOID.plist"
    rm -rf "$T"
  }
  trap cleanup_copy EXIT
  ditto "$BUILT" "$T/Cocaine.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ISOID" "$T/Cocaine.app/Contents/Info.plist"
  codesign --force --deep --sign - "$T/Cocaine.app" 2>/dev/null
  ISO="$T/Cocaine.app/Contents/MacOS/Cocaine"
  domain() { /usr/bin/defaults export "$1" - 2>/dev/null | /sbin/md5 -q 2>/dev/null; }
  REAL_BEFORE=$(domain local.cocaine.toggle)

  step "app test suites (isolated copy, bundle id $ISOID)"
  run "--selftest" "$ISO" --selftest
  run "--update-test" "$ISO" --update-test
  run "--signature-test" "$ISO" --signature-test
  run "--agents-test" "$ISO" --agents-test
  run "--clipboard-test" "$ISO" --clipboard-test
  run "--calendar-test" "$ISO" --calendar-test
  run "--dialogs-test" "$ISO" --dialogs-test
  run "--remote-test" "$ISO" --remote-test
  run "--recovery-test (its own temporary copy, stand-ins, temporary folders)" "$ISO" --recovery-test
  run "tests/engine-test.zsh (engine and remote.zsh on stubs)" zsh tests/engine-test.zsh
  run "--layout-test" zsh -c "out=\$('$ISO' --layout-test) && print -r -- \"\$out\" | grep -c 'inside that screen: true' | grep -qx 4 && ! print -r -- \"\$out\" | grep -q '^FAIL'"
  run "--l10n-check" "$ISO" --l10n-check Localization main.swift Sources/*.swift
  if [ "${CI:-}" = true ]; then skipped "--auth-selftest" "CI: osascript in a headless session"
  else
    run "--auth-selftest (non-admin, temp file)" zsh -c "'$ISO' --auth-selftest $T/rule && grep -q 'pmset -a disablesleep 1' $T/rule"
  fi
  for t in --permissions --camera-test --gamma-test --share-test --auth-preview; do
    skipped "$t" "needs the GUI session or privacy permissions: run by hand"
  done
  skipped "--relay-test" "talks to the third-party relay: run by hand"

  step "settings isolation (renders and tests never write a settings domain)"
  # Renders fill a panel with sample values (Stay active, schedule, timer…), --selftest flips settings: all in memory.
  "$ISO" --render-panel "$T/p.png" --auto timer --schedule --last >/dev/null 2>&1
  "$ISO" --render-island "$T/i.png" --open --agents >/dev/null 2>&1
  "$ISO" --island-selfcheck >/dev/null 2>&1
  "$ISO" --selftest >/dev/null 2>&1
  run "the copy's own settings domain was never written ($ISOID)" zsh -c "[ \"\$(/usr/bin/defaults export $ISOID - 2>/dev/null | grep -c '<key>')\" = 0 ] && [ ! -e $HOME/Library/Preferences/$ISOID.plist ]"
  run "the real settings domain (local.cocaine.toggle) is unchanged" test "$(domain local.cocaine.toggle)" = "$REAL_BEFORE"
  run "an unknown option doesn't start the app" zsh -c "'$ISO' --no-such-flag 2>/dev/null; [ \$? = 64 ]"

  step "release flow dry run (throwaway update key, copy of the tree)"
  run "tools/test-release-flow.sh" zsh tools/test-release-flow.sh

  step "release artifacts"
  if [ -f "dist/Cocaine-$VERSION.dmg.manifest.json" ]; then
    run "dist/Cocaine-$VERSION.dmg matches its signed manifest and declared tier" zsh tools/check-release.sh "dist/Cocaine-$VERSION.dmg"
  else
    skipped "release artifacts" "no dist/Cocaine-$VERSION.dmg.manifest.json"
  fi
else
  bad "build ($SIGN)"
fi

print -- "\n== summary: ${#FAILED[@]} failed, ${#SKIPPED[@]} skipped"
for f in "${FAILED[@]}"; do print -- "  failed: $f"; done
[ ${#FAILED[@]} -eq 0 ]
