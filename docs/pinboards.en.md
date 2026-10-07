### Pinboards and snippets (island clipboard)

**Pinboards** are named collections of clipboard items: *Prompts*, *Addresses*, *SQL*… **Favorites** (the star on each row) is
the built-in one: it can be renamed and recoloured, not deleted. You can have up to 30.

- **Create**: the **+** chip in the island, *New pinboard…* in Settings → Island → Pinboards, or *Pin to… → New pinboard…*.
- **Pin**: drag a row (or the selection) onto a chip; *Pin to…* in the selection bar, the details or the row's actions; the
  star for Favorites. An item can be on several pinboards; dragging from one pinboard's view onto another chip moves it.
- **Show one**: click its chip, ⌥1…⌥9 (⌥0 shows everything), ⌘[ and ⌘] to step through them. A pinboard can also have a
  **global shortcut** that opens the island on it (Settings → Island → Pinboards → the pinboard → *Shortcut*; Carbon hot
  keys, no permission).
- **Settings** of each pinboard: colour (8), symbol, the app it is **suggested first in** (its items come first in the island
  while that app is in front), shortcut, rename, move up/down, delete (its items stay in the history; those on no other
  pinboard are then subject to the history's limits again).

**Pinned items are kept for good**: the history's limits (count, age, space) never remove them, *Clear history* keeps them,
and they are **always saved on this Mac, encrypted**, even when the history itself is memory-only: in
`~/Library/Application Support/Cocaine/clipboard/boards.ccl` (and one encrypted file per image or formatted text), AES-GCM with
the same random key in your login Keychain, files readable only by you. The first pin creates that key (with an ad-hoc signed
build macOS may ask for Keychain access after updates; refused, pins stay in memory only and the page says so). *Delete
everything* deletes pinboards too, with the files and the key.

**Snippets.** A pinned text can be made a snippet (the switch at the bottom of its details): when pasted, its placeholders are
filled in: `{clipboard}` (what is on the clipboard then), `{date}`, `{time}`, `{datetime}`, `{date:yyyy-MM-dd}` (any date
pattern) and `{input:Name}` (Cocaine asks for a value in the island; up to 5). `{{` and `}}` are literal braces; unknown
placeholders stay as typed; what a placeholder puts in is never expanded again. A snippet can have its own **global
shortcut** that pastes it into the app in front.

**Not built, on purpose**: typing an abbreviation that expands into a snippet. That needs watching every key in every app
(Input Monitoring, a keylogger's technique, which also sees password fields), so Cocaine doesn't do it. Pinboards are not
shared or synced: there is no iCloud/CloudKit sync, shared pinboards or iOS app.
