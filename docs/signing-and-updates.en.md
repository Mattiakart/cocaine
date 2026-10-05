## Signature, first launch and updates

### How Cocaine is signed

There are three signing tiers. The panel says which one your copy has, under **Permissions**.

| Tier | What it is | First launch from the .dmg | Permissions across updates |
|---|---|---|---|
| **Local** (current releases) | Signed with Cocaine's own self-signed certificate. Free, but Apple doesn't verify it. | macOS blocks it once: **System Settings → Privacy & Security → Open Anyway**. | Kept by updates signed with the same certificate (see below). |
| **Developer ID** | Signed with an Apple Developer ID certificate, hardened runtime. | Still blocked unless also notarized. | Kept by updates signed with the same Developer ID. |
| **Developer ID, notarized** | As above, plus checked by Apple, with the ticket stapled to the app and the .dmg. | Opens normally, no "Open Anyway". | Kept by updates signed with the same Developer ID. |

**Ad hoc** builds (no certificate) exist only when someone builds Cocaine with `--sign adhoc` on purpose. macOS
treats every ad hoc build as a new app, so it forgets the permissions at every update, and such a copy can't update itself.

With Homebrew there's no "Open Anyway": the cask clears the download's quarantine flag on install.

### What carries over to an update, and what doesn't

- **Settings, the sudo rule and the AI alerts hooks** don't depend on the signature: they're always kept.
- **Permissions** (Accessibility, Camera, Calendar, Music and Spotify, Files) are tied by macOS to the app's
  *designated requirement*, which for Cocaine is "this bundle ID, signed with this certificate". An update signed with the
  same certificate meets the same requirement, so macOS can keep them. `tools/verify-permissions-persistence.sh` runs that
  same requirement check on two builds (it passes between 2.2.3 and the current build). Apple doesn't promise
  anything for self-signed certificates, though: if a switch turns off after an update, turn it on again once.
- **Not kept**: when the certificate changes, for example the first release signed with Developer ID instead of the local
  certificate, a copy you built yourself (your own certificate), or any ad hoc build. macOS asks for the permissions again,
  once.

### Updates inside the app

Under **Cocaine → Updates** the panel shows whether a new version exists. With **Check for updates automatically** on (the
default) it asks GitHub at most once a day; nothing is downloaded until you press **Install**, and it never pops up.

When you press **Install**, Cocaine:

1. downloads the .dmg from this repository's GitHub releases only, into a private folder. If the download is interrupted
   (network, sleep, quitting the app) it resumes where it stopped; it stops at the size it was promised, checks the free
   space first, and retries network errors a few times;
2. verifies it before touching anything: the release's manifest must carry a valid Ed25519 signature made with the key
   built into Cocaine; the .dmg must match the signed SHA-256 and size; the version and build must be newer than yours
   (no downgrades, no replays of an old release); and the app inside must be signed with the **same certificate as the
   copy you're running**;
3. swaps the new app in with one atomic rename, keeping the previous one until the new one has started. If anything fails,
   your installed copy stays exactly as it was; if the new version can't open, the previous one is put back and opened.

It doesn't update itself, and tells you so, when:

- you installed it with **Homebrew**: run `brew upgrade --cask cocaine` (the panel copies it for you), so Homebrew's
  records stay right;
- it's signed ad hoc, or it's running from the .dmg or a quarantined location (move it to Applications first);
- its folder isn't writable by you (for example a standard, non-admin account and /Applications): download it from GitHub.

Copies from before the in-app updater (2.2.3 and earlier) update the usual way, once.

### For maintainers

- `./build.sh --sign local|developer-id|adhoc` picks the tier; it never falls back to another one. `--dmg --release`
  refuses ad hoc, never creates a new local certificate, and needs the update key; `--notarize` (Developer ID only)
  notarizes and staples the app and the .dmg with `COCAINE_NOTARY_PROFILE`.
- `tools/update-key.sh init` makes the update key pair once (the private key stays in `~/.cocaine-signing/`, never in the
  repository; back it up: without it no installed copy can verify a new release).
- `tools/release-sign.sh dist/Cocaine-<v>.dmg <tier>` writes `Cocaine-<v>.dmg.manifest.json` after checking the declared
  tier against the app itself. Upload both files to the release. Nothing is published by the scripts.
- `./verify.sh` builds and runs every automatic check (also on GitHub Actions); `tools/check-release.sh` checks published
  artifacts.

Limits: the Developer ID and notarization steps are written and tested against simulated tools, not yet against Apple's
service (that needs a paid developer account). The updater's transfer, verification and installation are tested with a
local server and throwaway keys; the first real update will happen with the first release that ships a signed manifest.
