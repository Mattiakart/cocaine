### iPhone clipboard sync

Cocaine has no iPhone app and doesn't use Apple's CloudKit (both would need an Apple developer account). Copies still travel
between the iPhone and the Mac in three ways, which work side by side. Everything below is **off by default**; the switches are in
*Settings → Island → iPhone clipboard sync*.

| | What | How far | Encrypted end to end | Set up |
|---|---|---|---|---|
| **Universal Clipboard** (Apple's) | text, images | devices nearby, a short while | Apple's | nothing (Handoff on) |
| **iCloud Drive folder** | text, links, images | anywhere, seconds to minutes | only with Advanced Data Protection | turn on + two Shortcuts |
| **Paired iPhone (relay)** | short text (≈ 2,000 characters) | anywhere, a few seconds | yes | a paired iPhone + one Shortcut |

#### 1. iCloud Drive folder

Turn on *Sync through iCloud Drive*. Cocaine makes a folder **iCloud Drive › Shortcuts › Cocaine Clipboard** (on this Mac:
`~/Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/Cocaine Clipboard/`) with `inbox/` (iPhone → Mac) and
`outbox/` (Mac → iPhone). It lives in the Shortcuts app's own iCloud folder because that is the only place an iPhone Shortcut can
reach by path without you picking a folder on the phone.

*Add…* next to *iPhone Shortcuts* makes, signs and opens two Shortcuts in the Shortcuts app on this Mac; they reach the iPhone
through iCloud like any of your Shortcuts:

- **Send to Mac** — in the Share Sheet for text, links and images; run on its own (widget, Siri, Back Tap) it takes the iPhone's
  clipboard. It saves one uniquely named file in `inbox/`. On the Mac the item appears in the clipboard history marked
  *From your iPhone* (a small iPhone badge), optionally pinned to a pinboard you choose and placed on the Mac's clipboard
  (*Make it the current clipboard*).
- **Get from Mac** — puts the newest item the Mac sent onto the iPhone's clipboard (an image wins over a text). On the Mac, send
  an item with **Send to iPhone** in its menu or in the selection bar; *Send every copy* (off by default) sends each new copy.

How the Mac handles the folder: it watches `inbox/` (folder events, plus a check every 2 seconds while a file is arriving, else every 20), takes a file only once its
size has stopped changing (partial writes and downloads in progress are left alone), skips temporary and hidden files, asks iCloud
for files that are only placeholders (`.name.icloud`) and counts them as *waiting for iCloud* after 3 minutes, takes the same
content arriving twice once, refuses files over 25 MB (text over 1 MB) unread and sets them aside in `processed/`, makes photos
smaller (longest side 2,048 pixels, kept as PNG like any copied image), recognises images by their bytes (whatever the file is
called), and deletes each file once taken (or keeps it in `processed/` with *Keep received files*). Old files in `processed/` and
Cocaine's own files in `outbox/` are removed after a day. *Test* writes a small file into the folder, reads it back and removes it.

What arrives goes through the clipboard's own rules: keys, tokens and card numbers are skipped (with *Skip card numbers and keys*),
so are your excluded patterns and anything too big. What leaves is checked too: **never** what looks like a password, key or card
number (whatever the skip setting says), never your excluded patterns, never an excluded app's or a password manager's copy,
never files (only their names would arrive), and *Send every copy* never sends back what came from a device.

**Limits.** The folder is in your iCloud Drive: it is end-to-end encrypted only if you turned on Advanced Data Protection for
iCloud; otherwise Apple holds the keys. How fast it goes is up to iCloud: usually seconds, sometimes minutes; Low Power Mode and
*Optimize Mac Storage* can delay it. iCloud Drive must be on on both devices. The first run of each Shortcut on the iPhone asks to
allow access to the file. macOS may ask once whether Cocaine may use iCloud Drive. If you send a text right after an image,
wait a few seconds before *Get from Mac*, or the image may still be the newest it sees.

#### 2. Short text over the paired iPhone (end-to-end encrypted)

If you paired an iPhone for remote work (*Settings → Remote work → iPhone*), it can also exchange short text with the clipboard,
through the same relay and the same protocol (authenticated, encrypted end to end, replay-proof: see
[remote-security](remote-security.en.md)). Two switches per paired iPhone, both off: *Allow iPhone … to read my clipboard* and
*Allow iPhone … to send text to my clipboard*. *Add… → Cocaine Clip* makes a separate small Shortcut for that iPhone (it carries
the pairing's key: send it like the remote Shortcut, e.g. with AirDrop). Its menu:

- **Send my clipboard** — the iPhone's text goes into the Mac's history (in up to 6 encrypted pieces, about 2,000 characters;
  longer: use *Send to Mac*).
- **Get the Mac's newest** — the newest item of the history goes onto the iPhone's clipboard; cut to about 2,700 bytes (it says so).
- **List the iPhone pinboard** / **Get a pinboard item…** — the pinboard you chose under *Pinboard the iPhone can read*, by number.

The Mac answers these `clip` commands inside the app, never through a shell (the remote gate refuses them). They work only for
v2 pairings (never for old plain-text Shortcuts), at either level, at most 12 a minute per iPhone. Reading gives the newest item
or the readable pinboard only — never the rest of the history — and never what looks like a secret (an image or a file says to
use the iCloud way). Pieces of a longer text must all arrive within 2 minutes, with consistent numbering, or the text is dropped.
Images don't go this way: the iPhone's Shortcut would have to encrypt them with hash actions, far too slowly.

#### 3. Universal Clipboard (Apple's)

With the same Apple Account, Bluetooth, Wi-Fi and Handoff on, a copy on a nearby iPhone or iPad can be pasted on the Mac (and the
other way round). Cocaine labels such copies *Another device* (macOS marks them; the app in front never gets the credit), and
*Copies from other devices* in the Clipboard settings can leave them out. New: *Keep its copies off the saved history* keeps
them in memory only, even when the history is saved on this Mac (pinned ones are still saved). Search `from:iphone` (or
`from:device`) finds both these and the items from the iPhone sync.

What Cocaine puts on the clipboard (clicking an item, *Make it the current clipboard*) is an ordinary clipboard write. Apple
documents no way for a Mac app to keep a write off Universal Clipboard (iOS has a "local only" option; macOS has none public),
so Cocaine doesn't try: whether Handoff offers such writes to a nearby iPhone is expected but **not verified** on a device.

#### What was checked, and what wasn't

- Tested with fakes (`--clipsync-test`, 145 checks): the folder watcher on temporary folders (placeholders, partial writes,
  duplicates, big and empty files, one level of subfolders, removal, cleaning), what files decode to, the ingestion into a
  history, the outbound filter, the relay commands with every permission, pieces and their edge cases, the rate limit, replay and
  tampering through protocol v2 and the listener, the gate's refusal, and all three Shortcuts run in a simulator of the
  Shortcuts app (text, Unicode, empty, large, an image, no input) in every language the app ships.
- On this Mac: the three Shortcuts were signed by Apple's `shortcuts sign`; the Shortcuts iCloud folder exists and its iCloud
  status can be read without entitlements.
- **Not verified** on an iPhone: the generated Shortcuts' Save File / Get File by path (the Shortcuts folder is where Shortcuts
  puts files by default), *If … has any value*, *Repeat* and the share-sheet input; whether `startDownloadingUbiquitousItem`
  downloads an evicted file for an app signed like Cocaine; whether Handoff advertises Cocaine's own clipboard writes. The action
  and parameter names come from Shortcuts' own action definitions on macOS 27, not from a run on a phone.

**Not built, on purpose:** CloudKit or iCloud sync of the whole history (needs a developer account), an iPhone app, keyboard or
widget, images or long text through the relay (the phone can't encrypt them in time, and unencrypted would break the promise),
S3 or WebDAV (signing chains Shortcuts can't do, or a server that sees plain text), and a passphrase to encrypt the iCloud files
(the iPhone side would need the same slow hash-based cipher as the relay; for text that must be end to end, use the relay).
