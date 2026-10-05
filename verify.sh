#!/bin/zsh
# Builds and checks everything that can be checked without credentials, admin rights or a person at the Mac:
# shell and plist lint, the signing/notarization script tests (with fakes), a universal build of the requested tier,
# the app's own test suites, localization consistency, and any release artifacts in dist/ against their declared tier.
#   ./verify.sh                    local tier (this Mac's identity) unless VERIFY_SIGN says otherwise; never installs
#   VERIFY_SIGN=adhoc ./verify.sh  what CI runs
# Tests that need the GUI session, privacy permissions, admin rights or third-party network are listed as SKIP with the
# reason; run them by hand when needed (see the list at the end).
set -uo pipefail
cd "${0:A:h}"
SIGN="${VERIFY_SIGN:-$([ "${CI:-}" = true ] && echo adhoc || echo local)}"
FAILED=() SKIPPED=()
step() { print -- "\n== $1"; }
ok() { print -- "PASS  $1"; }
bad() { print -- "FAIL  $1"; FAILED+=("$1"); }
skipped() { print -- "SKIP  $1  ($2)"; SKIPPED+=("$1"); }
run() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

step "shell syntax"
for f in build.sh make-signing-identity.sh verify.sh cocaine.zsh remote.zsh tools/*.sh; do
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
run "Info.plist: build number is an integer" zsh -c '[[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)" == <-> ]]'

step "signing and release scripts (fakes, no credentials)"
run "tools/test-scripts.sh" zsh tools/test-scripts.sh

step "universal build, tier $SIGN"
if ./build.sh --no-install --sign "$SIGN"; then
  ok "build ($SIGN)"
  BIN=build/Cocaine.app/Contents/MacOS/Cocaine
  run "universal binary (arm64 + x86_64)" zsh -c "lipo -archs $BIN | tr ' ' '\n' | sort | tr '\n' ' ' | grep -qx 'arm64 x86_64 '"
  WANT=$([ "$SIGN" = developer-id ] && echo developerID || echo "$SIGN")
  run "the app reads its own tier as $WANT" zsh -c "$BIN --signature-tier build/Cocaine.app | grep -q '^tier=$WANT '"
  run "minimum macOS 14 in every slice" zsh -c "for a in arm64 x86_64; do vtool -arch \$a -show-build $BIN | grep -q 'minos 14.0' || exit 1; done"

  step "app test suites"
  run "--selftest" "$BIN" --selftest
  run "--update-test" "$BIN" --update-test
  run "--signature-test" "$BIN" --signature-test
  run "--agents-test" "$BIN" --agents-test
  run "--clipboard-test" "$BIN" --clipboard-test
  run "--remote-test" "$BIN" --remote-test
  run "--recovery-test (stand-ins, temporary folders)" "$BIN" --recovery-test
  run "tests/engine-test.zsh (engine and remote.zsh on stubs)" zsh tests/engine-test.zsh
  run "--layout-test" zsh -c "$BIN --layout-test | grep -c 'inside that screen: true' | grep -qx 4"
  run "--l10n-check" "$BIN" --l10n-check Localization main.swift Sources/*.swift
  if [ "${CI:-}" = true ]; then skipped "--auth-selftest" "CI: osascript in a headless session"
  else
    TMPRULE=$(mktemp -d)/rule
    run "--auth-selftest (non-admin, temp file)" zsh -c "$BIN --auth-selftest $TMPRULE && grep -q 'pmset -a disablesleep 1' $TMPRULE"
    rm -rf "${TMPRULE:h}"
  fi
  for t in --permissions --camera-test --gamma-test --share-test --auth-preview; do
    skipped "$t" "needs the GUI session or privacy permissions: run by hand"
  done
  skipped "--relay-test" "talks to the third-party relay: run by hand"

  step "release flow dry run (throwaway update key, copy of the tree)"
  run "tools/test-release-flow.sh" zsh tools/test-release-flow.sh

  step "release artifacts"
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
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
