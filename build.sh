#!/bin/zsh
# Builds Cocaine.app (universal: Apple Silicon + Intel) with its engine script inside.
#   ./build.sh                    build and install into ~/Applications (quits the running copy first)
#   ./build.sh --no-install       build only
#   ./build.sh --dmg              build and make dist/Cocaine-<version>.dmg
#   --sign local|developer-id|adhoc
#                                 the signing tier (default: local). See tools/sign.sh. Nothing ever falls back to another
#                                 tier: if the requested identity is missing the build stops before compiling.
#   --release                     with --dmg: a release build. Refuses ad hoc, refuses to create a new local identity
#                                 (that would be a different app to macOS for everyone who updates), and requires the
#                                 update key embedded in Sources/UpdateKey.swift. Then sign it with tools/release-sign.sh.
#   --notarize                    with --sign developer-id --dmg: notarize and staple the app and the DMG (tools/notarize.sh,
#                                 needs COCAINE_NOTARY_PROFILE).
set -euo pipefail
cd "${0:A:h}"
BUILD=build
APP="$BUILD/Cocaine.app"
DEST="$HOME/Applications/Cocaine.app"
LSR=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)

die() { print -u2 -- "build.sh: $*"; exit 1; }

MODE=install TIER=local RELEASE=0 NOTARIZE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-install) MODE=build ;;
    --dmg) MODE=dmg ;;
    --release) RELEASE=1 ;;
    --notarize) NOTARIZE=1 ;;
    --sign) [ $# -ge 2 ] || die "--sign needs a tier"; TIER="$2"; shift ;;
    --sign=*) TIER="${1#--sign=}" ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
case "$TIER" in adhoc|local|developer-id) ;; *) die "unknown tier \"$TIER\" (adhoc, local or developer-id)" ;; esac
if [ "$RELEASE" = 1 ]; then
  [ "$MODE" = dmg ] || die "--release goes with --dmg"
  [ "$TIER" != adhoc ] || die "a release can't be signed ad hoc: every update would lose the user's permissions and couldn't update itself"
  grep -Eq 'publicKeyBase64 = "[A-Za-z0-9+/]{43}="' Sources/UpdateKey.swift \
    || die "no update key embedded in Sources/UpdateKey.swift: run tools/update-key.sh init (or embed) first"
fi
if [ "$NOTARIZE" = 1 ]; then
  [ "$TIER" = developer-id ] && [ "$MODE" = dmg ] || die "--notarize needs --sign developer-id --dmg"
  [ -n "${COCAINE_NOTARY_PROFILE:-}" ] || die "--notarize needs COCAINE_NOTARY_PROFILE (a profile saved with xcrun notarytool store-credentials)"
fi

# The identity is checked before compiling, so a missing one fails fast and nothing half-signed is left behind.
if [ "$RELEASE" = 0 ] && [ "$TIER" = local ]; then export COCAINE_CREATE_LOCAL_IDENTITY=1; else export COCAINE_CREATE_LOCAL_IDENTITY=0; fi
zsh tools/sign.sh resolve "$TIER" >/dev/null || die "the \"$TIER\" signing identity isn't available (see above). Nothing was built."

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
: > "$BUILD/.metadata_never_index"            # Spotlight and Launch Services don't list build output as extra copies of Cocaine
SOURCES=(Sources/*.swift(N))
for arch in arm64 x86_64; do                  # each slice is linked as "Cocaine" so logs show the real name
  mkdir -p "$BUILD/$arch"
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 main.swift "${SOURCES[@]}" -o "$BUILD/$arch/Cocaine"
done
lipo -create "$BUILD/arm64/Cocaine" "$BUILD/x86_64/Cocaine" -output "$APP/Contents/MacOS/Cocaine"
"$BUILD/$(uname -m)/Cocaine" --render-assets "$BUILD"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
install -m 0755 cocaine.zsh "$APP/Contents/Resources/cocaine"
install -m 0644 remote.zsh "$APP/Contents/Resources/remote.zsh"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Localization/*.lproj "$APP/Contents/Resources/"   # UI text; macOS picks the Mac's language, else English

# A bundle that couldn't be signed or verified as asked is removed: nothing usable is left with a weaker signature.
zsh tools/sign.sh sign "$TIER" "$APP" || { rm -rf "$APP"; die "signing failed; $APP removed"; }
zsh tools/sign.sh verify "$TIER" "$APP" || { rm -rf "$APP"; die "verification failed; $APP removed"; }
case "$TIER" in
  adhoc) echo "signed ad hoc, as asked: macOS forgets the permissions at every update of this build" ;;
  local) echo "signed with the local identity: permissions carry over only to builds signed with this same identity; Gatekeeper needs \"Open Anyway\" on other Macs" ;;
  developer-id) echo "signed with Developer ID (hardened runtime, timestamp)$([ "$NOTARIZE" = 1 ] && echo "; notarizing next" || echo "; NOT notarized")" ;;
esac

case "$MODE" in
  build)
    echo "built $APP" ;;
  dmg)
    DMG="dist/Cocaine-$VERSION.dmg"
    rm -f "$DMG" "$DMG.manifest.json"
    if [ "$NOTARIZE" = 1 ]; then                                   # staples the app itself before it goes into the image
      zsh tools/notarize.sh "$APP" || die "notarizing the app failed: no DMG made"
    fi
    STAGE="$BUILD/dmg"
    mkdir -p "$STAGE" dist
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applicazioni"
    cp Leggimi.txt "$STAGE/Leggimi.txt"
    cp ReadMe.txt "$STAGE/Read Me.txt"
    hdiutil create -quiet -volname "Cocaine $VERSION" -srcfolder "$STAGE" -format UDZO "$DMG"
    if [ "$TIER" = developer-id ]; then
      ID=$(zsh tools/sign.sh resolve developer-id | sed -n 's/^IDENTITY=\([0-9A-F]*\).*/\1/p')
      codesign --force --timestamp --sign "$ID" "$DMG" || { rm -f "$DMG"; die "signing the DMG failed; DMG removed"; }
    fi
    if [ "$NOTARIZE" = 1 ]; then
      zsh tools/notarize.sh "$DMG" || { rm -f "$DMG"; die "notarizing the DMG failed; DMG removed"; }
    fi
    echo "made $DMG (tier: $("$APP/Contents/MacOS/Cocaine" --signature-tier "$APP" | sed -n 's/^tier=\([A-Za-z]*\).*/\1/p'))"
    [ "$RELEASE" = 1 ] && echo "next: tools/release-sign.sh $DMG $TIER   (makes the signed manifest; publishes nothing)"
    true ;;
  install)
    # One Cocaine on the Mac: the Homebrew copy in /Applications when there is one (brew upgrade keeps it current), else
    # ~/Applications. Any other copy is removed and forgotten by Launch Services, so "Open with" and Spotlight show one app.
    if [ -d /Applications/Cocaine.app ]; then DEST=/Applications/Cocaine.app; else DEST="$HOME/Applications/Cocaine.app"; fi
    pkill -x Cocaine 2>/dev/null && sleep 1 || true   # quit the running copy (it restores brightness)
    mkdir -p "${DEST:h}"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    for other in /Applications/Cocaine.app "$HOME/Applications/Cocaine.app"; do
      [ "$other" = "$DEST" ] || { [ -d "$other" ] && rm -rf "$other"; "$LSR" -u "$other" 2>/dev/null; }
    done
    "$LSR" -u "$PWD/$APP" 2>/dev/null
    "$LSR" -f "$DEST"
    echo "installed $DEST (the only copy)" ;;
esac
