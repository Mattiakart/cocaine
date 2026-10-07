#!/bin/zsh
# End-to-end dry run of a release, on a copy of the tree with a THROWAWAY update key (deleted afterwards; the real key
# and Sources/UpdateKey.swift of this tree are never touched): key init → `build.sh --dmg --release --sign local` →
# release-sign.sh → check-release.sh, plus the ways it must refuse (wrong declared tier, tampered manifest or DMG,
# a key that isn't the embedded one). Nothing is uploaded.
# Local tier: this Mac's existing identity (read-only use, like build.sh); in CI a throwaway identity in a temp HOME.
set -uo pipefail
ROOT="${0:A:h:h}"
T=$(mktemp -d)
LSR=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
# The copy's builds are forgotten by Launch Services before they go (a stale "Cocaine" entry could be what `open` picks).
trap 'for a in "$T"/**/*.app(N/); do "$LSR" -u "$a" 2>/dev/null; done; rm -rf "$T"' EXIT
FAILED=0
pass() { print -- "PASS  $1"; }
fail() { print -- "FAIL  $1${2:+  [$2]}"; FAILED=$((FAILED + 1)); }

if [ "${CI:-}" = true ]; then
  export HOME="$T/home"; mkdir -p "$HOME"
  zsh "$ROOT/make-signing-identity.sh" >/dev/null 2>&1 || { fail "release flow: throwaway local identity"; exit 1; }
elif [ ! -f "$HOME/.cocaine-signing/cocaine-signing.keychain" ]; then
  print -- "SKIP  release flow (no local signing identity on this Mac)"; exit 0
fi

R="$T/repo"; mkdir -p "$R"
for f in build.sh make-signing-identity.sh Info.plist Cocaine.entitlements main.swift cocaine.zsh remote.zsh Leggimi.txt ReadMe.txt tools Sources Localization; do
  cp -R "$ROOT/$f" "$R/"
done
sed -i '' -E 's|(publicKeyBase64 = )"[^"]*"|\1""|' "$R/Sources/UpdateKey.swift"
export COCAINE_UPDATE_KEY="$T/keys/update.key"
V=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$R/Info.plist")
DMG="$R/dist/Cocaine-$V.dmg"

(cd "$R" && ./build.sh --no-install --sign adhoc >"$T/b1.log" 2>&1) || { fail "release flow: first build" "$(tail -3 "$T/b1.log")"; exit 1; }
if zsh "$R/tools/update-key.sh" init >"$T/key.log" 2>&1 && grep -Eq 'publicKeyBase64 = "[A-Za-z0-9+/]{43}="' "$R/Sources/UpdateKey.swift"; then
  pass "release flow: key pair made, public key embedded"
else fail "release flow: key pair made, public key embedded" "$(cat "$T/key.log")"; fi
[ "$(stat -f %Lp "$COCAINE_UPDATE_KEY")" = 600 ] && pass "release flow: private key is 0600" || fail "release flow: private key is 0600"
grep -qF "$(cat "$COCAINE_UPDATE_KEY")" "$T/key.log" && fail "release flow: private key never printed" || pass "release flow: private key never printed"

if (cd "$R" && ./build.sh --dmg --release --sign local >"$T/b2.log" 2>&1); then pass "release flow: build.sh --dmg --release --sign local"
else fail "release flow: build.sh --dmg --release --sign local" "$(tail -3 "$T/b2.log")"; exit 1; fi

out=$(zsh "$R/tools/release-sign.sh" "$DMG" developer-id 2>&1) && fail "release-sign: declared tier must match the app" "$out" \
  || { print -r -- "$out" | grep -q 'declared tier "developer-id" but the app is "local"' && pass "release-sign: a wrong declared tier is refused" || fail "release-sign: wrong tier message" "$out"; }
[ ! -e "$DMG.manifest.json" ] && pass "release-sign: no manifest after a refusal" || fail "release-sign: no manifest after a refusal"
mkdir -p "$T/other"
"$R/build.noindex/Cocaine.app/Contents/MacOS/Cocaine" --update-keygen "$T/other/key" >/dev/null
out=$(COCAINE_UPDATE_KEY="$T/other/key" zsh "$R/tools/release-sign.sh" "$DMG" local 2>&1) && fail "release-sign: another key is refused" "$out" \
  || { print -r -- "$out" | grep -q "doesn't match the public key embedded" && pass "release-sign: a key that isn't the embedded one is refused" || fail "release-sign: other key message" "$out"; }

if zsh "$R/tools/release-sign.sh" "$DMG" local >"$T/rs.log" 2>&1; then pass "release-sign: signed manifest made for the local tier"
else fail "release-sign: signed manifest made for the local tier" "$(cat "$T/rs.log")"; fi
COCAINE_BIN="$R/build.noindex/Cocaine.app/Contents/MacOS/Cocaine" zsh "$R/tools/check-release.sh" "$DMG" local >"$T/cr.log" 2>&1 \
  && pass "check-release: DMG, manifest and tier agree" || fail "check-release: DMG, manifest and tier agree" "$(cat "$T/cr.log")"
COCAINE_BIN="$R/build.noindex/Cocaine.app/Contents/MacOS/Cocaine" zsh "$R/tools/check-release.sh" "$DMG" notarized >/dev/null 2>&1 \
  && fail "check-release: expecting notarized refuses a local release" || pass "check-release: expecting notarized refuses a local release"

cp "$DMG.manifest.json" "$T/manifest.bak"
sed -i '' -E 's/"tier" : "local"/"tier" : "notarized"/' "$DMG.manifest.json"
COCAINE_BIN="$R/build.noindex/Cocaine.app/Contents/MacOS/Cocaine" zsh "$R/tools/check-release.sh" "$DMG" >/dev/null 2>&1 \
  && fail "check-release: a manifest edited to claim a higher tier is refused" || pass "check-release: a manifest edited to claim a higher tier is refused"
cp "$T/manifest.bak" "$DMG.manifest.json"
printf 'x' >> "$DMG"
COCAINE_BIN="$R/build.noindex/Cocaine.app/Contents/MacOS/Cocaine" zsh "$R/tools/check-release.sh" "$DMG" >/dev/null 2>&1 \
  && fail "check-release: a modified DMG is refused" || pass "check-release: a modified DMG is refused"
# The ROOT tree's key file is untouched.
grep -q 'publicKeyBase64 = ""' "$ROOT/Sources/UpdateKey.swift" && pass "release flow: this tree's UpdateKey.swift untouched" || print -- "INFO  this tree has a real key embedded"

print -- "release flow tests: $([ $FAILED -eq 0 ] && echo "all passed" || echo "$FAILED failed")"
exit $((FAILED > 0))
