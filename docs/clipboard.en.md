### Clipboard (island)

The island's Clipboard page keeps what you copy: **text** (rich text is kept as plain text), **images** (stored as PNG, with a
thumbnail) and **files** (as references to where they are, never copies; a file that has been moved or deleted is marked and
can't be copied again). Click an item to put it back on the clipboard with its proper type (text, image, or the files
themselves for Finder); it moves to the top and isn't recorded again. Copying the same thing twice never makes a duplicate.

- **Search** filters as you type (any case or accents; text, file names and folders, image size, source app).
- **Favorites**: the star keeps an item; favorites don't count towards the limits and are never removed by them. The star in
  the toolbar shows only favorites.
- **Pause** stops recording; what you copy while paused is not kept, even after resuming.
- **Delete**: one item (×, or right-click), *Clear history* (keeps favorites), or *Delete everything* (also favorites, saved
  files and their Keychain key).

**Never kept**: content that password managers and other apps mark as concealed, transient or auto-generated
(nspasteboard.org markers, 1Password's own marker); anything copied while a password manager is in front (1Password,
Bitwarden, KeePassXC, LastPass, Dashlane, Enpass, Strongbox, NordPass, Proton Pass, Keychain Access, Passwords); apps you
exclude in Settings; and, unless you turn it off, text that looks like a card number (valid check digit) or a key/token
(private key blocks, JWTs, well-known API key prefixes, long random strings). You can add your own regular expressions.
These checks are heuristics: they catch common cases, not every secret.

**Memory only by default.** The history lives in memory and is gone when Cocaine quits or the island is turned off.
In Settings → Cocaine → Clipboard you can turn on **Save on this Mac**: the history is then stored in
`~/Library/Application Support/Cocaine/clipboard`, encrypted (AES-GCM) with a random key kept in your login Keychain
(this Mac only, never synced), files readable only by you. If the Keychain can't be used, nothing is saved and the page
says so. Turning it off asks whether to delete the saved copy (with its key) or keep it encrypted for later.
Nothing ever leaves the Mac.

**Limits** (Settings): how many items (25–500), how long (1 hour to 30 days, or no limit), total space (10–250 MB) and the
largest single item (1–25 MB). They are applied as you copy, when the history is loaded, and about once a minute.

**Limits of this feature**: the clipboard is checked a little more than once a second; the app in front is taken as the
source when the copying app doesn't say, so an app copying in the background may be attributed to another one. With an
ad-hoc signed build (no local signing identity), macOS asks again for Keychain access after each update; if you refuse,
nothing is saved. Deleting files can't guarantee the bytes are erased on an SSD: what makes the deleted history unreadable
is that its encryption key is deleted too. The search field takes the keyboard while the Clipboard page is open.
