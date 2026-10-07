#!/bin/zsh
# The Ed25519 key pair that signs update manifests.
#   tools/update-key.sh init     make a new key pair (private key outside the repo, 0600) and embed the public key
#   tools/update-key.sh embed    embed the public key of the existing private key (e.g. on a new checkout)
# The private key path is COCAINE_UPDATE_KEY (default ~/.cocaine-signing/update-ed25519.key). It is never printed and must
# never be committed. Back it up: losing it means installed copies can no longer verify (and so install) new versions,
# and replacing it breaks automatic updates for every copy that embeds the old public key.
# Needs a built app (./build.sh --no-install, any tier) for the CryptoKit commands; rebuild afterwards.
set -euo pipefail
ROOT="${0:A:h:h}"
die() { print -u2 -- "update-key.sh: $*"; exit 1; }
KEY="${COCAINE_UPDATE_KEY:-$HOME/.cocaine-signing/update-ed25519.key}"
SWIFT="${COCAINE_UPDATE_KEY_SWIFT:-$ROOT/Sources/UpdateKey.swift}"
BIN="${COCAINE_BIN:-$ROOT/build.noindex/Cocaine.app/Contents/MacOS/Cocaine}"
[ -x "$BIN" ] || die "build the app first (./build.sh --no-install)"
case "${KEY:A}" in "$ROOT"/*) die "the private key must live outside the repository" ;; esac

embed() {
  [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "unexpected public key format"
  sed -i '' -E "s|(static let publicKeyBase64 = )\"[^\"]*\"|\\1\"$1\"|" "$SWIFT"
  grep -q "\"$1\"" "$SWIFT" || die "couldn't write the key into $SWIFT"
  print -- "embedded the public key in $SWIFT: rebuild, and commit that file (only the public key)."
}

case "${1:-}" in
  init)
    grep -Eq 'publicKeyBase64 = ""' "$SWIFT" || die "a key is already embedded in $SWIFT (rotating it would break updates for installed copies)"
    [ ! -e "$KEY" ] || die "$KEY already exists: use 'embed'"
    mkdir -p "${KEY:h}"; chmod 700 "${KEY:h}"
    PUB=$("$BIN" --update-keygen "$KEY") || die "key generation failed"
    embed "$PUB"
    print -- "private key: $KEY (0600). Back it up somewhere safe and offline." ;;
  embed)
    [ -f "$KEY" ] || die "no private key at $KEY"
    PUB=$("$BIN" --update-public-key "$KEY") || die "can't read $KEY"
    embed "$PUB" ;;
  *) die "usage: tools/update-key.sh init|embed" ;;
esac
