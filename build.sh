#!/bin/zsh
# Builds Cocaine.app (universal: Apple Silicon + Intel) with its engine script inside.
#   ./build.sh               build and install into ~/Applications (quits the running copy first)
#   ./build.sh --no-install  build only
#   ./build.sh --dmg         build and make dist/Cocaine-<version>.dmg for download
set -euo pipefail
cd "${0:A:h}"
BUILD=build
APP="$BUILD/Cocaine.app"
DEST="$HOME/Applications/Cocaine.app"
LSR=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do                  # each slice is linked as "Cocaine" so logs show the real name
  mkdir -p "$BUILD/$arch"
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 main.swift $(ls Sources/*.swift 2>/dev/null) -o "$BUILD/$arch/Cocaine"
done
lipo -create "$BUILD/arm64/Cocaine" "$BUILD/x86_64/Cocaine" -output "$APP/Contents/MacOS/Cocaine"
"$BUILD/$(uname -m)/Cocaine" --render-assets "$BUILD"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
install -m 0755 cocaine.zsh "$APP/Contents/Resources/cocaine"
install -m 0644 remote.zsh "$APP/Contents/Resources/remote.zsh"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Localization/*.lproj "$APP/Contents/Resources/"   # UI text; macOS picks the Mac's language, else English
# Signed with the same self-signed identity every time (make-signing-identity.sh), so macOS keeps the permissions you gave across
# updates; without it, an ad-hoc signature (each build looks like a new app, and the permissions are forgotten). Either way the app
# isn't notarized, so other Macs need "Open Anyway" the first time.
SIGN_KC="$HOME/.cocaine-signing/cocaine-signing.keychain"
[ -f "$SIGN_KC" ] || zsh ./make-signing-identity.sh >/dev/null 2>&1 || true
SIGN_HASH=""
if [ -f "$SIGN_KC" ]; then
  security unlock-keychain -p cocaine "$SIGN_KC" 2>/dev/null || true
  SIGN_HASH=$(security find-certificate -c "Cocaine Local Signing" -Z "$SIGN_KC" 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}')
fi
if [ -n "$SIGN_HASH" ] && codesign --force --sign "$SIGN_HASH" --keychain "$SIGN_KC" "$APP" 2>/dev/null; then
  echo "signed with the stable identity $SIGN_HASH"
else
  codesign --force --sign - "$APP"
  echo "signed ad hoc (permissions are forgotten at every update)"
fi

case "${1:-}" in
  --no-install)
    echo "built $APP" ;;
  --dmg)
    STAGE="$BUILD/dmg"
    mkdir -p "$STAGE" dist
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applicazioni"
    cp Leggimi.txt "$STAGE/Leggimi.txt"
    cp ReadMe.txt "$STAGE/Read Me.txt"
    rm -f "dist/Cocaine-$VERSION.dmg"
    hdiutil create -quiet -volname "Cocaine $VERSION" -srcfolder "$STAGE" -format UDZO "dist/Cocaine-$VERSION.dmg"
    echo "made dist/Cocaine-$VERSION.dmg" ;;
  *)
    pkill -x Cocaine 2>/dev/null && sleep 1 || true   # quit the running copy (it restores brightness)
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    "$LSR" -f "$DEST"
    echo "installed $DEST" ;;
esac
