#!/bin/zsh
# Notarizes and staples a Developer ID–signed Cocaine.app or DMG, then checks it the way Gatekeeper does.
#   COCAINE_NOTARY_PROFILE=<profile> tools/notarize.sh build/Cocaine.app | dist/Cocaine-<v>.dmg
# The profile is a keychain item made once with `xcrun notarytool store-credentials <profile>` (Apple ID + app-specific
# password, or an App Store Connect API key); this script never sees the credentials. Anything short of "Accepted",
# a valid staple and a passing spctl assessment is a failure: nothing is shipped as "notarized" on a guess.
set -euo pipefail
die() { print -u2 -- "notarize.sh: $*"; exit 1; }
[ $# -eq 1 ] || die "usage: tools/notarize.sh <Cocaine.app|Cocaine-x.y.z.dmg>"
TARGET="${1%/}"
PROFILE="${COCAINE_NOTARY_PROFILE:-}"
[ -n "$PROFILE" ] || die "set COCAINE_NOTARY_PROFILE to a notarytool keychain profile (xcrun notarytool store-credentials)"
[ -e "$TARGET" ] || die "no such file: $TARGET"

INFO=$(codesign -dvv "$TARGET" 2>&1) || die "$TARGET isn't signed"
print -r -- "$INFO" | grep -q '^Authority=Developer ID Application: ' || die "$TARGET isn't signed with Developer ID: Apple won't notarize it"
print -r -- "$INFO" | grep -q '^Timestamp=' || die "$TARGET has no secure timestamp"
case "$TARGET" in
  *.app)
    print -r -- "$INFO" | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime' || die "hardened runtime is off"
    KIND=execute ;;
  *.dmg) KIND=open ;;
  *) die "expected a .app or a .dmg" ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SUBMIT="$TARGET"
if [ "$KIND" = execute ]; then                       # notarytool takes a zip of the app, not the bundle
  SUBMIT="$WORK/Cocaine.zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT" || die "zipping the app failed"
fi

xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait --output-format json > "$WORK/result.json" \
  || die "notarytool submit failed (see above)"
STATUS=$(plutil -extract status raw -o - "$WORK/result.json" 2>/dev/null || echo unknown)
ID=$(plutil -extract id raw -o - "$WORK/result.json" 2>/dev/null || echo "")
if [ "$STATUS" != Accepted ]; then
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
  die "notarization status: $STATUS"
fi

xcrun stapler staple "$TARGET" || die "stapling failed"
xcrun stapler validate "$TARGET" || die "the stapled ticket doesn't validate"
if [ "$KIND" = execute ]; then
  ASSESS=$(spctl --assess --type execute -vv "$TARGET" 2>&1) || die "Gatekeeper rejects the app: $ASSESS"
else
  ASSESS=$(spctl --assess --type open --context context:primary-signature -vv "$TARGET" 2>&1) || die "Gatekeeper rejects the DMG: $ASSESS"
fi
print -r -- "$ASSESS" | grep -q 'source=Notarized Developer ID' || die "Gatekeeper doesn't see it as notarized: $ASSESS"
print -- "notarized and stapled: $TARGET"
