#!/bin/zsh
# Regression tests for the signing, notarization and release scripts, with fake `security`, `codesign`, `xcrun`, `spctl`
# and `swiftc` first in PATH: no credentials, no Apple servers, nothing signed for real (except the last test, which uses
# real codesign on throwaway bundles). The key property: a requested tier that isn't available FAILS; nothing falls back.
set -uo pipefail
ROOT="${0:A:h:h}"
T=$(mktemp -d)
LSR=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
# Throwaway bundles are forgotten by Launch Services before they go (a stale "Cocaine" entry could be what `open` picks).
trap 'for a in "$T"/**/*.app(N/); do "$LSR" -u "$a" 2>/dev/null; done; rm -rf "$T"' EXIT
FAILED=0
pass() { print -- "PASS  $1"; }
fail() { print -- "FAIL  $1${2:+  [$2]}"; FAILED=$((FAILED + 1)); }
expect() {            # expect <name> <want exit: 0|nonzero> <grep pattern or ""> -- command…
  local name="$1" want="$2" pat="$3"; shift 4
  local out st
  out=$("$@" 2>&1); st=$?
  if [ "$want" = 0 ] && [ $st -ne 0 ]; then fail "$name" "exit $st: ${out[1,300]}"; return; fi
  if [ "$want" != 0 ] && [ $st -eq 0 ]; then fail "$name" "succeeded: ${out[1,300]}"; return; fi
  if [ -n "$pat" ] && ! print -r -- "$out" | grep -Eq -- "$pat"; then fail "$name" "output lacks /$pat/: ${out[1,300]}"; return; fi
  pass "$name"
}

FAKE="$T/bin"; mkdir -p "$FAKE"
export FAKE_LOG="$T/calls.log"; : > "$FAKE_LOG"
cat > "$FAKE/security" <<'EOF'
#!/bin/sh
echo "security $*" >> "$FAKE_LOG"
case "$1" in
  find-identity)
    i=0
    while [ "$i" -lt "${FAKE_IDS:-0}" ]; do
      i=$((i+1)); printf '  %d) %040d "Developer ID Application: Test Dev %d (TEAM00000%d)"\n' "$i" "$i" "$i" "$i"
    done
    echo "  9) 0000000000000000000000000000000000000009 \"Apple Development: Someone (XYZ)\""
    echo "     $((${FAKE_IDS:-0} + 1)) valid identities found" ;;
  unlock-keychain) exit 0 ;;
  find-certificate) [ -n "${FAKE_LOCAL_HASH:-}" ] || exit 44; echo "SHA-1 hash: $FAKE_LOCAL_HASH" ;;
esac
EOF
cat > "$FAKE/codesign" <<'EOF'
#!/bin/sh
echo "codesign $*" >> "$FAKE_LOG"
case " $* " in *" -dvv "*) printf '%s\n' "${FAKE_DVV:-}" >&2; exit 0 ;; esac
[ "${FAKE_CODESIGN_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
cat > "$FAKE/xcrun" <<'EOF'
#!/bin/sh
echo "xcrun $*" >> "$FAKE_LOG"
case "$1 $2" in
  "notarytool submit") printf '{"id":"11111111-2222-3333-4444-555555555555","status":"%s"}\n' "${FAKE_NOTARY_STATUS:-Accepted}" ;;
  "notarytool log") echo '{"issues":[]}' ;;
  "stapler staple"|"stapler validate") exit 0 ;;
esac
EOF
cat > "$FAKE/spctl" <<'EOF'
#!/bin/sh
echo "spctl $*" >> "$FAKE_LOG"
printf '%s: accepted\nsource=%s\n' "$4" "${FAKE_SPCTL_SOURCE:-Notarized Developer ID}" >&2
EOF
cat > "$FAKE/swiftc" <<'EOF'
#!/bin/sh
echo "swiftc called" >> "$FAKE_LOG"; exit 1
EOF
chmod +x "$FAKE"/*
FP="$FAKE:/usr/bin:/bin:/usr/sbin:/sbin"
APP="$T/Dummy.app"; mkdir -p "$APP/Contents/MacOS"

# --- tools/sign.sh: identity resolution
expect "sign: no Developer ID identity → fails, no fallback" 1 "no valid \"Developer ID Application\" identity.*Not falling back" -- \
  env PATH="$FP" FAKE_IDS=0 zsh "$ROOT/tools/sign.sh" resolve developer-id
expect "sign: an Apple Development identity isn't taken for Developer ID" 1 "no valid" -- env PATH="$FP" FAKE_IDS=0 zsh "$ROOT/tools/sign.sh" resolve developer-id
expect "sign: several Developer ID identities → must choose" 1 "2 Developer ID Application identities" -- \
  env PATH="$FP" FAKE_IDS=2 zsh "$ROOT/tools/sign.sh" resolve developer-id
expect "sign: COCAINE_DEVELOPER_ID picks one of several" 0 "IDENTITY=0{39}2" -- \
  env PATH="$FP" FAKE_IDS=2 COCAINE_DEVELOPER_ID="Test Dev 2" zsh "$ROOT/tools/sign.sh" resolve developer-id
expect "sign: one Developer ID identity is used" 0 "IDENTITY=0{39}1" -- env PATH="$FP" FAKE_IDS=1 zsh "$ROOT/tools/sign.sh" resolve developer-id
expect "sign: local tier without its keychain fails (no silent ad hoc)" 1 "no local signing identity.*--sign adhoc" -- \
  env PATH="$FP" COCAINE_LOCAL_KEYCHAIN="$T/none.keychain" COCAINE_CREATE_LOCAL_IDENTITY=0 zsh "$ROOT/tools/sign.sh" resolve local
touch "$T/empty.keychain"
expect "sign: local keychain without the certificate fails" 1 "no \"Cocaine Local Signing\" certificate" -- \
  env PATH="$FP" COCAINE_LOCAL_KEYCHAIN="$T/empty.keychain" zsh "$ROOT/tools/sign.sh" resolve local
expect "sign: unknown tier fails" 1 "unknown tier" -- env PATH="$FP" zsh "$ROOT/tools/sign.sh" resolve notarised

# --- signing arguments
: > "$FAKE_LOG"
expect "sign: developer-id signs with hardened runtime, timestamp, entitlements" 0 "" -- \
  env PATH="$FP" FAKE_IDS=1 zsh "$ROOT/tools/sign.sh" sign developer-id "$APP"
grep -Eq -- "codesign --force --options runtime --timestamp --entitlements $ROOT/Cocaine.entitlements --sign 0{39}1 $APP" "$FAKE_LOG" \
  && pass "sign: codesign got --options runtime --timestamp --entitlements and the Developer ID" || fail "sign: codesign arguments" "$(cat "$FAKE_LOG")"
: > "$FAKE_LOG"
expect "sign: a failing codesign fails the tier" 1 "codesign failed for the developer-id tier" -- \
  env PATH="$FP" FAKE_IDS=1 FAKE_CODESIGN_FAIL=1 zsh "$ROOT/tools/sign.sh" sign developer-id "$APP"
grep -q -- "--sign - " "$FAKE_LOG" && fail "sign: no ad hoc retry after a failure" || pass "sign: no ad hoc retry after a failure"
: > "$FAKE_LOG"
expect "sign: local signs with its own keychain" 0 "" -- \
  env PATH="$FP" FAKE_LOCAL_HASH=ABCDEF0123456789ABCDEF0123456789ABCDEF01 COCAINE_LOCAL_KEYCHAIN="$T/empty.keychain" zsh "$ROOT/tools/sign.sh" sign local "$APP"
grep -q -- "--sign ABCDEF0123456789ABCDEF0123456789ABCDEF01 --keychain $T/empty.keychain" "$FAKE_LOG" \
  && pass "sign: local uses the stable identity hash" || fail "sign: local uses the stable identity hash" "$(cat "$FAKE_LOG")"

# --- build.sh: refuses before compiling
: > "$FAKE_LOG"
expect "build: --sign developer-id without an identity fails before compiling" 1 "Nothing was built" -- \
  env PATH="$FP" FAKE_IDS=0 zsh "$ROOT/build.sh" --sign developer-id --no-install
grep -q "swiftc called" "$FAKE_LOG" && fail "build: nothing compiled after a missing identity" || pass "build: nothing compiled after a missing identity"
expect "build: a release can't be ad hoc" 1 "can't be signed ad hoc" -- env PATH="$FP" zsh "$ROOT/build.sh" --dmg --release --sign adhoc
expect "build: --release needs --dmg" 1 "--release goes with --dmg" -- env PATH="$FP" zsh "$ROOT/build.sh" --release --sign local
expect "build: --notarize needs developer-id" 1 "--notarize needs --sign developer-id" -- env PATH="$FP" zsh "$ROOT/build.sh" --dmg --notarize --sign local
expect "build: --notarize needs a notary profile" 1 "COCAINE_NOTARY_PROFILE" -- \
  env PATH="$FP" COCAINE_NOTARY_PROFILE= zsh "$ROOT/build.sh" --dmg --notarize --sign developer-id
expect "build: unknown tier fails" 1 "unknown tier" -- env PATH="$FP" zsh "$ROOT/build.sh" --sign whatever --no-install
expect "build: unknown option fails" 1 "unknown option" -- env PATH="$FP" zsh "$ROOT/build.sh" --sgin local

# A copy of the tree with an update key embedded, to reach the identity checks of a release.
COPY="$T/repo"; mkdir -p "$COPY"
cp -R "$ROOT/build.sh" "$ROOT/make-signing-identity.sh" "$ROOT/Info.plist" "$ROOT/Cocaine.entitlements" "$ROOT/tools" "$ROOT/Sources" "$COPY/"
sed -i '' -E 's|(publicKeyBase64 = )"[^"]*"|\1"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="|' "$COPY/Sources/UpdateKey.swift"
# …and one without, whatever this tree has (the test never depends on the real key being there or not).
NOKEY="$T/nokey"; mkdir -p "$NOKEY"
cp -R "$ROOT/build.sh" "$ROOT/make-signing-identity.sh" "$ROOT/Info.plist" "$ROOT/Cocaine.entitlements" "$ROOT/tools" "$ROOT/Sources" "$NOKEY/"
sed -i '' -E 's|(publicKeyBase64 = )"[^"]*"|\1""|' "$NOKEY/Sources/UpdateKey.swift"
: > "$FAKE_LOG"
expect "build: a DMG needs the update key embedded (--dmg alone is a release)" 1 "no update key embedded" -- env PATH="$FP" zsh "$NOKEY/build.sh" --dmg --sign local
expect "build: …also with --release" 1 "no update key embedded" -- env PATH="$FP" zsh "$NOKEY/build.sh" --dmg --release --sign local
grep -q "swiftc called" "$FAKE_LOG" && fail "build: nothing compiled without the key" || pass "build: nothing compiled without the key"
expect "build: --allow-unsigned-updates passes the key gate (stops later, at the missing identity)" 1 "no local signing identity" -- \
  env PATH="$FP" HOME="$T/home" COCAINE_LOCAL_KEYCHAIN="$T/home/none.keychain" zsh "$NOKEY/build.sh" --dmg --allow-unsigned-updates --sign local
expect "build: --allow-unsigned-updates goes with --dmg" 1 "goes with --dmg" -- env PATH="$FP" zsh "$NOKEY/build.sh" --allow-unsigned-updates --no-install
expect "build: COCAINE_NO_NEW_IDENTITY never makes an identity (what verify.sh sets)" 1 "no local signing identity" -- \
  env PATH="$FP" HOME="$T/home" COCAINE_NO_NEW_IDENTITY=1 COCAINE_LOCAL_KEYCHAIN="$T/home/.cocaine-signing/cocaine-signing.keychain" zsh "$NOKEY/build.sh" --no-install --sign local
[ ! -e "$T/home/.cocaine-signing" ] && pass "build: no identity was made by a plain build with COCAINE_NO_NEW_IDENTITY" || fail "build: no identity made with COCAINE_NO_NEW_IDENTITY"
: > "$FAKE_LOG"
expect "build: a release never creates a new local identity" 1 "no local signing identity" -- \
  env PATH="$FP" HOME="$T/home" COCAINE_LOCAL_KEYCHAIN="$T/home/.cocaine-signing/cocaine-signing.keychain" zsh "$COPY/build.sh" --dmg --release --sign local
[ ! -e "$T/home/.cocaine-signing" ] && pass "build: no identity was made for the release" || fail "build: no identity was made for the release"
grep -q "swiftc called" "$FAKE_LOG" && fail "build: release without identity compiled nothing" || pass "build: release without identity compiled nothing"

# --- notarize.sh
DEVID_DVV=$'Authority=Developer ID Application: Test Dev 1 (TEAM000001)\nTimestamp=1 Oct 2026\nCodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1'
expect "notarize: needs a profile" 1 "COCAINE_NOTARY_PROFILE" -- env PATH="$FP" COCAINE_NOTARY_PROFILE= zsh "$ROOT/tools/notarize.sh" "$APP"
: > "$FAKE_LOG"
expect "notarize: refuses a non-Developer ID app before submitting" 1 "isn't signed with Developer ID" -- \
  env PATH="$FP" COCAINE_NOTARY_PROFILE=p FAKE_DVV="Authority=Cocaine Local Signing" zsh "$ROOT/tools/notarize.sh" "$APP"
grep -q "notarytool submit" "$FAKE_LOG" && fail "notarize: nothing submitted for a local build" || pass "notarize: nothing submitted for a local build"
expect "notarize: refuses an app without hardened runtime" 1 "hardened runtime is off" -- \
  env PATH="$FP" COCAINE_NOTARY_PROFILE=p FAKE_DVV=$'Authority=Developer ID Application: X (T)\nTimestamp=x\nCodeDirectory v=1 flags=0x0(none)' zsh "$ROOT/tools/notarize.sh" "$APP"
: > "$FAKE_LOG"
expect "notarize: a rejected submission fails and isn't stapled" 1 "notarization status: Invalid" -- \
  env PATH="$FP" COCAINE_NOTARY_PROFILE=p FAKE_DVV="$DEVID_DVV" FAKE_NOTARY_STATUS=Invalid zsh "$ROOT/tools/notarize.sh" "$APP"
grep -q "stapler staple" "$FAKE_LOG" && fail "notarize: no staple after a rejection" || pass "notarize: no staple after a rejection"
grep -q "notarytool log" "$FAKE_LOG" && pass "notarize: the log is fetched after a rejection" || fail "notarize: the log is fetched after a rejection"
: > "$FAKE_LOG"
expect "notarize: accepted → stapled, validated, assessed" 0 "notarized and stapled" -- \
  env PATH="$FP" COCAINE_NOTARY_PROFILE=p FAKE_DVV="$DEVID_DVV" zsh "$ROOT/tools/notarize.sh" "$APP"
[ "$(grep -oE 'notarytool submit|stapler staple|stapler validate|spctl --assess --type execute' "$FAKE_LOG" | tr '\n' ',')" = "notarytool submit,stapler staple,stapler validate,spctl --assess --type execute," ] \
  && pass "notarize: submit → staple → validate → spctl, in that order" || fail "notarize: order" "$(cat "$FAKE_LOG")"
grep -q -- "--keychain-profile p --wait" "$FAKE_LOG" && pass "notarize: waits, using the keychain profile" || fail "notarize: waits, using the keychain profile"
expect "notarize: Gatekeeper not seeing notarization fails" 1 "doesn't see it as notarized" -- \
  env PATH="$FP" COCAINE_NOTARY_PROFILE=p FAKE_DVV="$DEVID_DVV" FAKE_SPCTL_SOURCE="Developer ID" zsh "$ROOT/tools/notarize.sh" "$APP"

# --- release-sign.sh / update-key.sh guards
touch "$T/Cocaine-9.9.9.dmg"
expect "release-sign: ad hoc can't be declared" 1 "ad hoc releases aren't allowed" -- zsh "$ROOT/tools/release-sign.sh" "$T/Cocaine-9.9.9.dmg" adhoc
expect "release-sign: missing private key fails" 1 "no release key" -- env COCAINE_UPDATE_KEY="$T/nokey" zsh "$ROOT/tools/release-sign.sh" "$T/Cocaine-9.9.9.dmg" local
touch "$COPY/.test-key-inside"                        # in the copy of the tree: nothing is written into the repository
expect "release-sign: a key inside the repository is refused" 1 "outside the repository" -- \
  env COCAINE_UPDATE_KEY="$COPY/.test-key-inside" zsh "$COPY/tools/release-sign.sh" "$T/Cocaine-9.9.9.dmg" local
mkdir -p "$T/bin2"; printf '#!/bin/sh\nexit 0\n' > "$T/bin2/Cocaine"; chmod +x "$T/bin2/Cocaine"
expect "update-key: a key inside the repository is refused" 1 "outside the repository" -- \
  env COCAINE_BIN="$T/bin2/Cocaine" COCAINE_UPDATE_KEY="$ROOT/k" zsh "$ROOT/tools/update-key.sh" init

# --- permission persistence check, with real codesign on throwaway bundles
mkbundle() { mkdir -p "$1/Contents/MacOS"; cp /usr/bin/true "$1/Contents/MacOS/Cocaine"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.cocaine.toggle" -c "Add :CFBundleExecutable string Cocaine" \
    -c "Add :CFBundleShortVersionString string $2" "$1/Contents/Info.plist" >/dev/null; }
mkbundle "$T/A/Cocaine.app" 1.0; mkbundle "$T/B/Cocaine.app" 1.1
/usr/bin/codesign --force --sign - "$T/A/Cocaine.app" 2>/dev/null; /usr/bin/codesign --force --sign - "$T/B/Cocaine.app" 2>/dev/null
expect "persistence: two ad hoc builds don't carry permissions over" 1 "FAIL  the new build does NOT satisfy" -- \
  env HOME="$T/home" zsh "$ROOT/tools/verify-permissions-persistence.sh" "$T/A/Cocaine.app" "$T/B/Cocaine.app"
KC="$HOME/.cocaine-signing/cocaine-signing.keychain"
if [ "${CI:-}" != true ] && [ -f "$KC" ]; then
  /usr/bin/security unlock-keychain -p cocaine "$KC" >/dev/null 2>&1
  H=$(/usr/bin/security find-certificate -c "Cocaine Local Signing" -Z "$KC" 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}')
  /usr/bin/codesign --force --sign "$H" --keychain "$KC" "$T/A/Cocaine.app" 2>/dev/null
  /usr/bin/codesign --force --sign "$H" --keychain "$KC" "$T/B/Cocaine.app" 2>/dev/null
  expect "persistence: two builds with the local identity satisfy each other's requirement" 0 "PASS  the new build satisfies" -- \
    env HOME="$T/home" zsh "$ROOT/tools/verify-permissions-persistence.sh" "$T/A/Cocaine.app" "$T/B/Cocaine.app"
else
  print -- "SKIP  persistence: local identity case ($([ "${CI:-}" = true ] && echo CI || echo "no local signing identity"))"
fi

print -- "script tests: $([ $FAILED -eq 0 ] && echo "all passed" || echo "$FAILED failed")"
exit $((FAILED > 0))
