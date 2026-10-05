#!/bin/zsh
# Signing tiers for Cocaine builds. Every tier is explicit and none falls back to another: if the requested identity
# isn't there, this fails and says why.
#
#   tools/sign.sh resolve <tier>          print the identity it would use (fails if unavailable)
#   tools/sign.sh sign <tier> <app>       sign the bundle
#   tools/sign.sh verify <tier> <app>     strict verification + the app's own reading of its tier must match
#
# Tiers:
#   adhoc         no identity. Every build is a different app to macOS: permissions are forgotten at each update.
#   local         the self-signed "Cocaine Local Signing" identity (make-signing-identity.sh). Same designated requirement
#                 for every build signed with it, so macOS can keep permissions across those builds. Not trusted by
#                 Gatekeeper (downloads need "Open Anyway"); another Mac's identity is a different app.
#   developer-id  a "Developer ID Application" identity from your keychains, hardened runtime, Cocaine.entitlements,
#                 secure timestamp. Needs a paid Apple Developer account. Notarization is a separate step (notarize.sh).
#
# Environment: COCAINE_LOCAL_KEYCHAIN (default ~/.cocaine-signing/cocaine-signing.keychain),
#   COCAINE_CREATE_LOCAL_IDENTITY=1 to make the local identity when it's missing (never for releases),
#   COCAINE_DEVELOPER_ID (SHA-1 or exact name) to pick one Developer ID identity when there are several.
set -euo pipefail
ROOT="${0:A:h:h}"
LOCAL_NAME="Cocaine Local Signing"
LOCAL_KC="${COCAINE_LOCAL_KEYCHAIN:-$HOME/.cocaine-signing/cocaine-signing.keychain}"
ENTITLEMENTS="$ROOT/Cocaine.entitlements"

die() { print -u2 -- "sign.sh: $*"; exit 2; }

# Sets IDENTITY (and KEYCHAIN for local) for the tier, or fails.
resolve() {
  IDENTITY="" KEYCHAIN=""
  case "$1" in
    adhoc) IDENTITY="-" ;;
    local)
      if [ ! -f "$LOCAL_KC" ]; then
        [ "${COCAINE_CREATE_LOCAL_IDENTITY:-0}" = 1 ] || die "no local signing identity at $LOCAL_KC (run ./make-signing-identity.sh, or pass --sign adhoc explicitly)"
        print -u2 -- "sign.sh: making a NEW local signing identity. Builds signed with any previous identity are a different app to macOS: their permissions won't carry over."
        zsh "$ROOT/make-signing-identity.sh" >&2 || die "make-signing-identity.sh failed"
      fi
      security unlock-keychain -p cocaine "$LOCAL_KC" >/dev/null 2>&1 || die "can't unlock $LOCAL_KC"
      local out
      out=$(security find-certificate -c "$LOCAL_NAME" -Z "$LOCAL_KC" 2>/dev/null) || die "no \"$LOCAL_NAME\" certificate in $LOCAL_KC"
      IDENTITY=$(print -r -- "$out" | awk '/SHA-1 hash:/ {print $3; exit}')
      [[ "$IDENTITY" =~ ^[0-9A-F]{40}$ ]] || die "can't read the local identity's hash from $LOCAL_KC"
      KEYCHAIN="$LOCAL_KC" ;;
    developer-id)
      local list matches n
      list=$(security find-identity -v -p codesigning 2>/dev/null) || die "security find-identity failed"
      matches=$(print -r -- "$list" | grep -E '^ *[0-9]+\) [0-9A-F]{40} "Developer ID Application: ' || true)
      if [ -n "${COCAINE_DEVELOPER_ID:-}" ]; then
        matches=$(print -r -- "$matches" | grep -F -- "$COCAINE_DEVELOPER_ID" || true)
      fi
      n=$(print -r -- "$matches" | grep -c . || true)
      [ "$n" -ge 1 ] || die "no valid \"Developer ID Application\" identity${COCAINE_DEVELOPER_ID:+ matching \"$COCAINE_DEVELOPER_ID\"} in your keychains (security find-identity -v -p codesigning). Not falling back to another tier."
      [ "$n" -eq 1 ] || die "$n Developer ID Application identities found: set COCAINE_DEVELOPER_ID to the SHA-1 of the one to use"
      IDENTITY=$(print -r -- "$matches" | awk '{print $2}') ;;
    *) die "unknown tier \"$1\" (adhoc, local or developer-id)" ;;
  esac
}

sign_app() {
  local tier="$1" app="$2"
  [ -d "$app" ] || die "no app at $app"
  resolve "$tier"
  case "$tier" in
    adhoc) codesign --force --sign - "$app" ;;
    local) codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$app" ;;
    developer-id)
      [ -f "$ENTITLEMENTS" ] || die "missing $ENTITLEMENTS"
      codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$app" ;;
  esac || die "codesign failed for the $tier tier (nothing was signed with another tier)"
}

# Fails unless the bundle verifies strictly and reads back as the requested tier.
verify_app() {
  local tier="$1" app="$2" want info detected
  codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 || die "codesign --verify --deep --strict failed for $app"
  info=$(codesign -dvv "$app" 2>&1) || die "codesign -dvv failed for $app"
  detected=$("$app/Contents/MacOS/Cocaine" --signature-tier "$app" | sed -n 's/^tier=\([A-Za-z]*\).*/\1/p') || die "the app couldn't read its own signature"
  case "$tier" in
    adhoc) want=adhoc; print -r -- "$info" | grep -q '^Signature=adhoc' || die "expected an ad hoc signature" ;;
    local) want=local; print -r -- "$info" | grep -q "^Authority=$LOCAL_NAME\$" || die "expected Authority=$LOCAL_NAME" ;;
    developer-id)
      want=developerID
      print -r -- "$info" | grep -q '^Authority=Developer ID Application: ' || die "expected a Developer ID Application authority"
      print -r -- "$info" | grep -q '^Timestamp=' || die "no secure timestamp"
      print -r -- "$info" | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime' || die "hardened runtime is off"
      [ "$detected" = notarized ] && want=notarized ;;
    *) die "unknown tier \"$tier\"" ;;
  esac
  [ "$detected" = "$want" ] || die "the app reads its own tier as \"$detected\", expected \"$want\""
  print -- "verified: $app is signed, tier $detected"
}

case "${1:-}" in
  resolve) [ $# -eq 2 ] || die "usage: resolve <tier>"; resolve "$2"; print -- "IDENTITY=$IDENTITY${KEYCHAIN:+ KEYCHAIN=$KEYCHAIN}" ;;
  sign) [ $# -eq 3 ] || die "usage: sign <tier> <app>"; sign_app "$2" "$3" ;;
  verify) [ $# -eq 3 ] || die "usage: verify <tier> <app>"; verify_app "$2" "$3" ;;
  *) die "usage: tools/sign.sh resolve|sign|verify <tier> [app]" ;;
esac
