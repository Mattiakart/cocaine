#!/bin/zsh
# Builds Cocaine.app (universal: Apple Silicon + Intel) with its engine script inside, in build.noindex/ (Spotlight skips
# folders named *.noindex; `build` is a link to it for older scripts).
#   ./build.sh                    build and install: the one copy on this Mac (see "install" below)
#   ./build.sh --no-install       build only
#   ./build.sh --dmg              build and make dist/Cocaine-<version>.dmg: a RELEASE build. Refuses ad hoc, refuses to
#                                 create a new local identity (that would be a different app to macOS for everyone who
#                                 updates), and requires the update key embedded in Sources/UpdateKey.swift (tools/update-key.sh
#                                 init, run by the maintainer once: it makes the private key outside the repository). Then
#                                 tools/release-sign.sh makes the signed manifest that must be published next to the DMG.
#   --allow-unsigned-updates      with --dmg: build the DMG anyway without the key (or ad hoc). Its copies can never update
#                                 themselves; said loudly.
#   --release                     the same as --dmg (kept for older notes).
#   --sign local|developer-id|adhoc
#                                 the signing tier (default: local). See tools/sign.sh. Nothing ever falls back to another
#                                 tier: if the requested identity is missing the build stops before compiling.
#   --notarize                    with --sign developer-id --dmg: notarize and staple the app and the DMG (tools/notarize.sh,
#                                 needs COCAINE_NOTARY_PROFILE).
#   --app-intents                 with --no-install only, NEVER a release: also compiles Sources/AppIntents (native Shortcuts
#                                 actions, -D COCAINE_APP_INTENTS) and generates Contents/Resources/Metadata.appintents from the
#                                 compiler's const values (tools/gen-appintents-metadata.py). Shortcuts runs those actions only
#                                 for an app signed with a Team ID: see docs/maintainers/app-intents.md. Nothing is registered.
# COCAINE_NO_NEW_IDENTITY=1: never create the local signing identity (verify.sh, CI); a missing one fails instead.
set -euo pipefail
cd "${0:A:h}"
BUILD=build.noindex
APP="$BUILD/Cocaine.app"
LSR=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)

die() { print -u2 -- "build.sh: $*"; exit 1; }

MODE=install TIER=local RELEASE=0 NOTARIZE=0 ALLOW_NOKEY=0 INTENTS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-install) MODE=build ;;
    --app-intents) INTENTS=1 ;;
    --dmg) MODE=dmg ;;
    --release) RELEASE=1 ;;
    --allow-unsigned-updates) ALLOW_NOKEY=1 ;;
    --notarize) NOTARIZE=1 ;;
    --sign) [ $# -ge 2 ] || die "--sign needs a tier"; TIER="$2"; shift ;;
    --sign=*) TIER="${1#--sign=}" ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
case "$TIER" in adhoc|local|developer-id) ;; *) die "unknown tier \"$TIER\" (adhoc, local or developer-id)" ;; esac
[ "$RELEASE" = 0 ] || [ "$MODE" = dmg ] || die "--release goes with --dmg"
[ "$ALLOW_NOKEY" = 0 ] || [ "$MODE" = dmg ] || die "--allow-unsigned-updates goes with --dmg"
# Native App Intents never go into a release or the installed copy (they'd be listed by Shortcuts and fail without a Team ID).
[ "$INTENTS" = 0 ] || { [ "$MODE" = build ] && [ "$RELEASE" = 0 ]; } || die "--app-intents goes with --no-install only (never a release or the installed copy)"
if [ "$NOTARIZE" = 1 ]; then
  [ "$TIER" = developer-id ] && [ "$MODE" = dmg ] || die "--notarize needs --sign developer-id --dmg"
  [ -n "${COCAINE_NOTARY_PROFILE:-}" ] || die "--notarize needs COCAINE_NOTARY_PROFILE (a profile saved with xcrun notarytool store-credentials)"
fi
HASKEY=0
grep -Eq 'publicKeyBase64 = "[A-Za-z0-9+/]{43}="' Sources/UpdateKey.swift && HASKEY=1
if [ "$MODE" = dmg ]; then
  RELEASE=1                                  # every DMG is a release build: the release gate below always applies
  if [ "$ALLOW_NOKEY" = 0 ]; then
    [ "$TIER" != adhoc ] || die "a release can't be signed ad hoc: every update would lose the user's permissions and couldn't update itself (--allow-unsigned-updates to build it anyway)"
    [ "$HASKEY" = 1 ] || die "no update key embedded in Sources/UpdateKey.swift: copies of this DMG could never update themselves.
  The maintainer makes the key once with tools/update-key.sh init (private key outside the repository; back it up), commits
  Sources/UpdateKey.swift, then builds again. --allow-unsigned-updates builds this DMG anyway."
  fi
fi

# The identity is checked before compiling, so a missing one fails fast and nothing half-signed is left behind.
if [ "$RELEASE" = 0 ] && [ "$TIER" = local ] && [ "${COCAINE_NO_NEW_IDENTITY:-0}" != 1 ]; then export COCAINE_CREATE_LOCAL_IDENTITY=1; else export COCAINE_CREATE_LOCAL_IDENTITY=0; fi
zsh tools/sign.sh resolve "$TIER" >/dev/null || die "the \"$TIER\" signing identity isn't available (see above). Nothing was built."

rm -rf "$BUILD"
[ -L build ] || rm -rf build                  # the old folder name: now a link to build.noindex
ln -sfn "$BUILD" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
: > "$BUILD/.metadata_never_index"            # belt and braces next to the .noindex name
SOURCES=(Sources/*.swift(N))
EXTRA=()
if [ "$INTENTS" = 1 ]; then                   # the module name must stay "Cocaine": the metadata's mangled names contain it
  SOURCES+=(Sources/AppIntents/*.swift(N)); EXTRA=(-module-name Cocaine -D COCAINE_APP_INTENTS)
fi
for arch in arm64 x86_64; do                  # each slice is linked as "Cocaine" so logs show the real name
  mkdir -p "$BUILD/$arch"
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 "${EXTRA[@]}" main.swift "${SOURCES[@]}" -o "$BUILD/$arch/Cocaine"
done
lipo -create "$BUILD/arm64/Cocaine" "$BUILD/x86_64/Cocaine" -output "$APP/Contents/MacOS/Cocaine"
"$BUILD/$(uname -m)/Cocaine" --render-assets "$BUILD"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
install -m 0755 cocaine.zsh "$APP/Contents/Resources/cocaine"
install -m 0644 remote.zsh "$APP/Contents/Resources/remote.zsh"
cp Info.plist "$APP/Contents/Info.plist"
install -m 0644 Cocaine.sdef "$APP/Contents/Resources/Cocaine.sdef"   # the AppleScript dictionary (Sources/Scripting.swift)
if [ "$INTENTS" = 1 ]; then                   # the actions' metadata from the compiler's const values, before signing
  swiftc -typecheck -swift-version 5 -target arm64-apple-macos14.0 "${EXTRA[@]}" main.swift "${SOURCES[@]}" \
    -Xfrontend -const-gather-protocols-list -Xfrontend tools/appintents-protocols.json \
    -Xfrontend -emit-const-values-path -Xfrontend "$BUILD/Cocaine.swiftconstvalues" || die "const values pass failed"
  python3 -I tools/gen-appintents-metadata.py generate "$BUILD/Cocaine.swiftconstvalues" "$APP/Contents/Resources" || die "App Intents metadata failed"
  python3 -I tools/gen-appintents-metadata.py check "$APP/Contents/Resources/Metadata.appintents" "$APP/Contents/MacOS/Cocaine" || die "App Intents metadata check failed"
  echo "App Intents built in (NOT for release; Shortcuts runs them only with a Team ID signature: docs/maintainers/app-intents.md)"
fi
cp -R Localization/*.lproj "$APP/Contents/Resources/"   # UI text; macOS picks the Mac's language, else English

# A bundle that couldn't be signed or verified as asked is removed: nothing usable is left with a weaker signature.
zsh tools/sign.sh sign "$TIER" "$APP" || { rm -rf "$APP"; die "signing failed; $APP removed"; }
zsh tools/sign.sh verify "$TIER" "$APP" || { rm -rf "$APP"; die "verification failed; $APP removed"; }
case "$TIER" in
  adhoc) echo "signed ad hoc, as asked: macOS forgets the permissions at every update of this build" ;;
  local) echo "signed with the local identity: permissions carry over only to builds signed with this same identity; Gatekeeper needs \"Open Anyway\" on other Macs" ;;
  developer-id) echo "signed with Developer ID (hardened runtime, timestamp)$([ "$NOTARIZE" = 1 ] && echo "; notarizing next" || echo "; NOT notarized")" ;;
esac

# The pid of a running Cocaine started from exactly `$1` (the app's executable path), or nothing. Never matched by name.
running_from() {
  local exe="$1/Contents/MacOS/Cocaine" pid comm
  ps -axo pid=,comm= | while read -r pid comm; do [ "$comm" = "$exe" ] && print -r -- "$pid"; done
}
# Quits the Cocaine running from bundle `$1`, if any, and waits until it has gone (its quit puts sleep and screens back).
quit_copy() {
  local pid i
  for pid in $(running_from "$1"); do
    kill -TERM "$pid" 2>/dev/null || continue
    for i in {1..300}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null && die "Cocaine (pid $pid, $1) didn't quit within 30 s: nothing was installed, $1 is untouched"
    WASRUNNING=1
  done
  return 0
}

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
    if [ "$HASKEY" = 1 ] && [ "$TIER" != adhoc ]; then
      echo "NEXT, REQUIRED before publishing: tools/release-sign.sh $DMG $TIER   (the signed manifest; publish BOTH files)"
      echo "  A DMG published without its manifest can't be installed by the in-app updater of any copy."
    else
      print -u2 -- "WARNING: built with --allow-unsigned-updates: copies of this DMG can never verify or install updates by themselves."
    fi
    true ;;
  install)
    # One Cocaine on the Mac: the copy in /Applications when there is one (Homebrew's: brew upgrade keeps it current), else
    # ~/Applications. Any other copy is removed and forgotten by Launch Services, so "Open with" and Spotlight show one app.
    if [ -d /Applications/Cocaine.app ]; then DEST=/Applications/Cocaine.app; else DEST="$HOME/Applications/Cocaine.app"; fi
    mkdir -p "${DEST:h}"
    # Everything that could stop the install is checked before anything is quit or touched.
    [ -w "${DEST:h}" ] || die "can't write to ${DEST:h}: nothing was quit or changed"
    [ ! -e "$DEST" ] || [ -w "$DEST" ] || die "can't replace $DEST (not writable): nothing was quit or changed"
    for room in /opt/homebrew/Caskroom/cocaine /usr/local/Caskroom/cocaine; do
      if [ -d "$room" ] && [ "$DEST" = /Applications/Cocaine.app ]; then
        echo "NOTE: $DEST is Homebrew's copy ($room): it is replaced by this build. \`brew upgrade --cask cocaine\` (or reinstall) puts a release back."
      fi
    done
    NEW="$DEST.new.$$" OLD="$DEST.old.$$"
    rm -rf "$NEW"
    ditto "$APP" "$NEW" || { rm -rf "$NEW"; die "copying the app to ${DEST:h} failed: nothing was quit or changed"; }
    WASRUNNING=0
    quit_copy "$DEST"
    for other in /Applications/Cocaine.app "$HOME/Applications/Cocaine.app"; do [ "$other" = "$DEST" ] || quit_copy "$other"; done
    # Two renames, undone if the second fails or this script is interrupted between them: DEST always holds a whole app.
    trap '[ -d "$OLD" ] && [ ! -e "$DEST" ] && mv "$OLD" "$DEST"; rm -rf "$NEW"' EXIT INT TERM
    if [ -e "$DEST" ]; then mv "$DEST" "$OLD" || die "moving the installed app aside failed: it is untouched"; fi
    if ! mv "$NEW" "$DEST"; then [ -d "$OLD" ] && mv "$OLD" "$DEST"; die "putting the new app in place failed: the previous one is back"; fi
    rm -rf "$OLD"
    trap - EXIT INT TERM
    for other in /Applications/Cocaine.app "$HOME/Applications/Cocaine.app"; do
      [ "$other" = "$DEST" ] || { [ -d "$other" ] && rm -rf "$other"; "$LSR" -u "$other" 2>/dev/null; }
    done
    "$LSR" -u "$PWD/$APP" 2>/dev/null; "$LSR" -u "$PWD/build/Cocaine.app" 2>/dev/null
    "$LSR" -f "$DEST"
    echo "installed $DEST (the only copy)"
    if [ "$WASRUNNING" = 1 ]; then open "$DEST" && echo "reopened it (it was running)"; fi
    true ;;
esac
