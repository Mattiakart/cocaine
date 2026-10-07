#!/bin/zsh
# Makes the signed update manifest for a release DMG: dist/Cocaine-<v>.dmg.manifest.json. Publishes nothing.
#   tools/release-sign.sh dist/Cocaine-<version>.dmg <local|developer-id|notarized>
# The tier is declared, then checked against what the app inside the DMG really is (its own reading of its signature);
# a mismatch, an ad hoc or unverifiable app, or a version/build that differs from Info.plist stops here.
# The Ed25519 private key is read from COCAINE_UPDATE_KEY (default ~/.cocaine-signing/update-ed25519.key), never from the
# repository and never printed.
set -euo pipefail
ROOT="${0:A:h:h}"
die() { print -u2 -- "release-sign.sh: $*"; exit 1; }
[ $# -eq 2 ] || die "usage: tools/release-sign.sh <Cocaine-x.y.z.dmg> <local|developer-id|notarized>"
DMG="${1:A}" DECLARED="$2"
case "$DECLARED" in local) WANT=local ;; developer-id) WANT=developerID ;; notarized) WANT=notarized ;;
  *) die "declare the tier: local, developer-id or notarized (ad hoc releases aren't allowed)" ;; esac
KEY="${COCAINE_UPDATE_KEY:-$HOME/.cocaine-signing/update-ed25519.key}"
[ -f "$KEY" ] || die "no release key at $KEY (tools/update-key.sh init makes one)"
case "${KEY:A}" in "$ROOT"/*) die "the release key must live outside the repository" ;; esac
[ -f "$DMG" ] || die "no such DMG: $DMG"

MNT=$(mktemp -d)
chmod 700 "$MNT"
cleanup() { hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null || die "can't mount $DMG"
APP="$MNT/Cocaine.app"
[ -d "$APP" ] && [ ! -L "$APP" ] || die "the DMG doesn't contain Cocaine.app at its root"
BIN="$APP/Contents/MacOS/Cocaine"

codesign --verify --deep --strict "$APP" 2>/dev/null || die "the app in the DMG fails strict signature verification"
TIER=$("$BIN" --signature-tier "$APP" | sed -n 's/^tier=\([A-Za-z]*\).*/\1/p') || die "the app couldn't read its own signature"
[ "$TIER" = "$WANT" ] || die "declared tier \"$DECLARED\" but the app is \"$TIER\""
if [ "$WANT" != local ]; then
  spctl --assess --type execute "$APP" 2>/dev/null || die "Gatekeeper rejects the app"
fi
if [ "$WANT" = notarized ]; then
  xcrun stapler validate "$DMG" >/dev/null || die "the DMG has no valid stapled ticket"
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILDNO=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
[ "$VERSION" = "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")" ] || die "the DMG's version ($VERSION) isn't Info.plist's"
[ "$BUILDNO" = "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Info.plist")" ] || die "the DMG's build ($BUILDNO) isn't Info.plist's"
[ "${DMG:t}" = "Cocaine-$VERSION.dmg" ] || die "the DMG must be named Cocaine-$VERSION.dmg"
# The designated requirement of the app in the DMG goes into the signed manifest (format 2): a copy signed by another
# certificate then knows before downloading that this release can't replace it.
REQ=$("$BIN" --signature-tier "$APP" | sed -n 's/^designated=//p')
[ -n "$REQ" ] && [ "$REQ" != "-" ] || die "can't read the app's designated requirement"

# The build number must grow with every release: an installed copy refuses a newer version whose build isn't higher.
SIGNER="$ROOT/build.noindex/Cocaine.app/Contents/MacOS/Cocaine"
[ -x "$SIGNER" ] || die "build the app first (./build.sh): the manifest is signed by this tree's build, not by the DMG's app"
LAST="$ROOT/tools/last-release"
if [ -f "$LAST" ]; then
  read -r LASTV LASTB < "$LAST"
  if [ "$VERSION" != "$LASTV" ]; then
    "$SIGNER" --version-newer "$VERSION" "$LASTV" || die "version $VERSION isn't newer than the last release ($LASTV, tools/last-release)"
    [ "$BUILDNO" -gt "$LASTB" ] || die "build $BUILDNO isn't higher than the last release's ($LASTB): raise CFBundleVersion in Info.plist"
  else
    [ "$BUILDNO" = "$LASTB" ] || die "version $VERSION was released with build $LASTB, the DMG has $BUILDNO: raise the version too"
  fi
fi

OUT="$DMG.manifest.json"
# The private key only ever goes to this tree's own build, never to a binary taken from the DMG being signed (a swapped
# DMG would get the key). That build refuses a key that doesn't match its embedded public key; then the app in the DMG
# must accept the manifest with ITS embedded key (verifying needs no secret).
"$SIGNER" --update-sign "$KEY" "$DMG" "$VERSION" "$BUILDNO" "$TIER" "$OUT" "$REQ" || die "signing the manifest failed"
"$BIN" --update-verify "$OUT" "$DMG" >/dev/null || { rm -f "$OUT"; die "the manifest doesn't verify with the key embedded in the DMG's app"; }
print -r -- "$VERSION $BUILDNO" > "$LAST"
print -- "made $OUT (tier $TIER, version $VERSION, build $BUILDNO, format 2)."
print -- "Recorded $VERSION ($BUILDNO) in tools/last-release: commit it with the release."
print -- "Upload BOTH $DMG:t and $OUT:t to the GitHub release v$VERSION. Nothing was published."
