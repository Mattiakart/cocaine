#!/bin/zsh
# Makes (once) a self-signed code-signing identity for Cocaine builds, in its own keychain: ~/.cocaine-signing/.
#
# Why: an ad-hoc signature's identity is the hash of each build, so every update looks like a different app to macOS, which then
# forgets the permissions you gave (Accessibility, Camera, Calendar, Automation, Files). Signed with this identity, every build has
# the same requirement ("identifier local.cocaine.toggle and this certificate"), so the permissions survive updates.
# The key never leaves this Mac's keychain file; the keychain password is not a secret (it protects nothing but this build identity).
set -euo pipefail
DIR="$HOME/.cocaine-signing"
KC="$DIR/cocaine-signing.keychain"
NAME="Cocaine Local Signing"
PASS="cocaine"

if [ -f "$KC" ] && security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  echo "identity already there: $KC"
  exit 0
fi

mkdir -p "$DIR"; chmod 700 "$DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Cocaine Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 7300 -config "$WORK/cert.cnf" >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout "pass:$PASS" -name "$NAME" >/dev/null 2>&1
rm -f "$KC"
security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"                       # never auto-lock
security unlock-keychain -p "$PASS" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null 2>&1 || true
echo "made $KC"
