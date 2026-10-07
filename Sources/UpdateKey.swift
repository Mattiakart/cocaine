// The Ed25519 public key that release manifests must be signed with (CryptoKit Curve25519.Signing, raw 32 bytes, base64).
// Written by `tools/update-key.sh init`; the private key stays outside the repository (default ~/.cocaine-signing/).
// Empty means this build can't verify updates: it still tells you a new version exists but never installs one, and
// `build.sh --release` refuses to build it.

enum UpdateKey {
    static let publicKeyBase64 = "ihE79a1kMi1otxZWl7txj1X2YjmjCH0IuuOmD+OEn9s="
}
