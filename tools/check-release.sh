#!/bin/zsh
# Checks release artifacts without publishing or signing anything:
#   tools/check-release.sh dist/Cocaine-<v>.dmg [expected tier: local|developerID|notarized]
# The manifest next to the DMG must verify against the public key embedded in this source tree's build (COCAINE_BIN,
# default build.noindex/Cocaine.app), match the DMG's SHA-256 and size, and its declared tier must be what the app inside the DMG
# really is; a format-2 manifest's designated requirement must be the app's. The version and build must not go backwards
# from tools/last-release (the previous release). Exit 0 only if all of that holds.
#   COCAINE_NO_MANIFEST=1: a release published without a manifest (2.3.0, 2.4.0): checks the DMG and the app only, and
#   says loudly that installed copies can't update themselves to it. Fails if the tagged source has an update key embedded
#   (then the manifest is simply missing).
set -euo pipefail
ROOT="${0:A:h:h}"
die() { print -u2 -- "check-release.sh: $*"; exit 1; }
[ $# -ge 1 ] || die "usage: tools/check-release.sh <Cocaine-x.y.z.dmg> [tier]"
DMG="${1:A}" EXPECT="${2:-}"
MAN="$DMG.manifest.json"
BIN="${COCAINE_BIN:-$ROOT/build.noindex/Cocaine.app/Contents/MacOS/Cocaine}"
[ -x "$BIN" ] || die "build the app first (./build.sh --no-install), or set COCAINE_BIN"
NOMAN="${COCAINE_NO_MANIFEST:-0}"
[ -f "$DMG" ] || die "no such DMG: $DMG"
if [ "$NOMAN" = 1 ]; then
  grep -q 'publicKeyBase64 = ""' "$ROOT/Sources/UpdateKey.swift" || die "this source embeds an update key, so the release needs its signed manifest"
  print -- "WARNING: no signed manifest: copies of this release can't verify or install updates by themselves (download only)."
else
  [ -f "$MAN" ] || die "need both $DMG and $MAN"
  "$BIN" --update-verify "$MAN" "$DMG" || die "the manifest doesn't verify against the embedded key or doesn't match the DMG"
fi

MNT=$(mktemp -d)
chmod 700 "$MNT"
cleanup() { hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null || die "can't mount $DMG"
APP="$MNT/Cocaine.app"
[ -d "$APP" ] && [ ! -L "$APP" ] || die "the DMG doesn't contain Cocaine.app at its root"
codesign --verify --deep --strict "$APP" 2>/dev/null || die "the app fails strict signature verification"
INFO=$("$BIN" --signature-tier "$APP")
ACTUAL=$(print -r -- "$INFO" | sed -n 's/^tier=\([A-Za-z]*\).*/\1/p')
AVERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ABUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
[ -z "$EXPECT" ] || [ "$ACTUAL" = "$EXPECT" ] || die "expected tier \"$EXPECT\", the release is \"$ACTUAL\""
case "$ACTUAL" in adhoc|unsigned|otherCertificate) die "tier \"$ACTUAL\" isn't acceptable for a release" ;; esac
[ "${DMG:t}" = "Cocaine-$AVERSION.dmg" ] || die "the DMG must be named Cocaine-$AVERSION.dmg"
if [ "$NOMAN" != 1 ]; then
  DECLARED=$(plutil -extract tier raw -o - "$MAN")
  MVERSION=$(plutil -extract version raw -o - "$MAN")
  MBUILD=$(plutil -extract build raw -o - "$MAN")
  [ "$ACTUAL" = "$DECLARED" ] || die "the manifest declares tier \"$DECLARED\" but the app is \"$ACTUAL\""
  [ "$AVERSION" = "$MVERSION" ] || die "the app's version isn't the manifest's"
  [ "$ABUILD" = "$MBUILD" ] || die "the app's build isn't the manifest's"
  if MREQ=$(plutil -extract requirement raw -o - "$MAN" 2>/dev/null); then
    [ "$MREQ" = "$(print -r -- "$INFO" | sed -n 's/^designated=//p')" ] || die "the manifest's designated requirement isn't the app's"
  else
    print -- "note: format-1 manifest (no designated requirement): copies signed by another certificate find out only after downloading"
  fi
fi
# Not backwards from the previous release (tools/last-release, written by release-sign.sh).
if [ -f "$ROOT/tools/last-release" ]; then
  read -r LASTV LASTB < "$ROOT/tools/last-release"
  if [ "$AVERSION" = "$LASTV" ]; then
    [ "$ABUILD" = "$LASTB" ] || die "$AVERSION was released as build $LASTB, this DMG has build $ABUILD"
  elif "$BIN" --version-newer "$AVERSION" "$LASTV"; then
    [ "$ABUILD" -gt "$LASTB" ] || die "build $ABUILD isn't higher than the last release's ($LASTB): installed copies would never see this version as an update"
  fi
fi
print -- "release ok: $DMG:t, version $AVERSION ($ABUILD), tier $ACTUAL$([ "$NOMAN" = 1 ] && echo ", NO manifest")"
