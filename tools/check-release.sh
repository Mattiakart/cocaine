#!/bin/zsh
# Checks release artifacts without publishing or signing anything:
#   tools/check-release.sh dist/Cocaine-<v>.dmg [expected tier: local|developerID|notarized]
# The manifest next to the DMG must verify against the public key embedded in this source tree's build (COCAINE_BIN,
# default build/Cocaine.app), match the DMG's SHA-256 and size, and its declared tier must be what the app inside the DMG
# really is. Exit 0 only if all of that holds.
set -euo pipefail
ROOT="${0:A:h:h}"
die() { print -u2 -- "check-release.sh: $*"; exit 1; }
[ $# -ge 1 ] || die "usage: tools/check-release.sh <Cocaine-x.y.z.dmg> [tier]"
DMG="${1:A}" EXPECT="${2:-}"
MAN="$DMG.manifest.json"
BIN="${COCAINE_BIN:-$ROOT/build/Cocaine.app/Contents/MacOS/Cocaine}"
[ -x "$BIN" ] || die "build the app first (./build.sh --no-install), or set COCAINE_BIN"
[ -f "$DMG" ] && [ -f "$MAN" ] || die "need both $DMG and $MAN"

"$BIN" --update-verify "$MAN" "$DMG" || die "the manifest doesn't verify against the embedded key or doesn't match the DMG"
DECLARED=$(plutil -extract tier raw -o - "$MAN")
MVERSION=$(plutil -extract version raw -o - "$MAN")
MBUILD=$(plutil -extract build raw -o - "$MAN")

MNT=$(mktemp -d)
chmod 700 "$MNT"
cleanup() { hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null || die "can't mount $DMG"
APP="$MNT/Cocaine.app"
[ -d "$APP" ] && [ ! -L "$APP" ] || die "the DMG doesn't contain Cocaine.app at its root"
codesign --verify --deep --strict "$APP" 2>/dev/null || die "the app fails strict signature verification"
ACTUAL=$("$BIN" --signature-tier "$APP" | sed -n 's/^tier=\([A-Za-z]*\).*/\1/p')
[ "$ACTUAL" = "$DECLARED" ] || die "the manifest declares tier \"$DECLARED\" but the app is \"$ACTUAL\""
[ -z "$EXPECT" ] || [ "$ACTUAL" = "$EXPECT" ] || die "expected tier \"$EXPECT\", the release is \"$ACTUAL\""
case "$ACTUAL" in adhoc|unsigned|otherCertificate) die "tier \"$ACTUAL\" isn't acceptable for a release" ;; esac
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$MVERSION" ] || die "the app's version isn't the manifest's"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = "$MBUILD" ] || die "the app's build isn't the manifest's"
print -- "release ok: $DMG:t, version $MVERSION ($MBUILD), tier $ACTUAL"
