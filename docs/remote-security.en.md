### How the iPhone remote control is protected (protocol v2)

Every Shortcut made by *Remote work → iPhone → Send* carries its own random 256-bit key (plus the two random relay topics).
With it:

- **Commands and answers are end-to-end encrypted.** The relay (ntfy.sh or your own server) only sees ciphertext, a random
  number and a time — not the command, not the status, project names or agent output. Every command has the same length on the relay.
- **Every message is authenticated.** A command without the right key is ignored; so is an answer on the phone. Knowing the
  relay topics (e.g. the relay operator) is no longer enough to control the Mac or to fake an answer.
- **No replays.** Each command carries a one-time number and the phone's time. The Mac runs a command at most once, ever: what it
  has run is saved on disk (`remote-state.json`, written atomically) before it runs, so duplicates the relay delivers again after a
  reconnection, a wake-up, a crash or a restart are dropped. Commands older than 2 minutes (20 with *Wake for iPhone*) or dated in the
  future are refused.
- **Answers belong to their request.** The phone only shows the answer made for the command it just sent; *Last reply* shows the
  newest genuine answer of the last 30 minutes.
- **Revoke and expiry.** *Revoke* stops at once (even a command already running gets no answer). A pairing expires after 180 days:
  its Shortcut then just says so; send a new one.
- Commands still go through the same fixed allow-list (`cocaine remote gate`); what you type is never put into a shell line.

**Shortcuts made before this version** send plain, unauthenticated text. After the update they no longer work: running one shows
"Cocaine was updated and no longer accepts this Shortcut…", and the panel shows an orange *Old Shortcuts* row. Send a new Shortcut
(and delete the old one on the iPhone), then press *Remove*. If you need a few days, *Allow 14 days* lets old Shortcuts run
**status, on/off, projects, agents and runs only** (never starting or steering agents) until the date shown — they are unprotected
meanwhile.

**Limits, honestly.** The Shortcuts app has no encryption action, so the Shortcut does it with SHA-256/SHA-512, Base64 and
regular expressions (a hash-based stream cipher and a nested keyed hash, both standard constructions, verified against the Mac's
CryptoKit code). That makes the Shortcut large (about 650 actions) and a command takes a few seconds on the iPhone; answers longer than
about 2,800 bytes are cut. The key sits in the Shortcut file and on the Mac in `phones.json` (readable only by you): anyone who gets the
Shortcut can still use it, and it syncs through iCloud like any Shortcut — treat it like a key. The relay can still see *when* and
*how often* you send commands, delay or drop them (you then see "No valid answer yet"), and a command whose Mac crashes right after
accepting it is not run (never twice). The generated Shortcut was run for real in the Shortcuts app on a Mac (macOS 27, Italian
locale) through ntfy.sh — Status, a typed command with accents and symbols, a 2,800-byte answer, *Last reply*, a forged answer — but
not yet on an iPhone. The first run asks once to allow the connection to ntfy.sh (or your relay): allow it.

**If the iPhone gets "No valid answer yet".** The Mac writes one line per phone message to
`~/Library/Application Support/Cocaine/remote-phone.log`: `accepted`, `reply-sent` (or `reply-failed` with the relay's HTTP status),
or why a message was refused — `malformed` (with the message's shape: field count and lengths), `bad-tag` (another key: an old or
edited Shortcut), `stale`/`future` (with its age: check the clocks; also a command that arrived while the Mac's connection was down, logged when it reconnects), `replay`, `expired`, `revoked`,
`unknown-pairing`, `decrypt-failed`, `legacy-refused` — plus `relay-up`/`relay-down` for the Mac's connection. It never contains a
key, a topic, a command or an answer. Shortcuts made by the first v2 builds, before this fix, never worked (their Generate Hash actions
received no input, so commands arrived without a tag): delete them and send a new one.
