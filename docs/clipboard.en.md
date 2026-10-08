### Clipboard (island)

The island's Clipboard page keeps what you copy: **text** (with its formatting, RTF and HTML, kept up to 1 MB), **images**
(stored as PNG, with a thumbnail) and **files** (as references to where they are, never copies; a file that has been moved or
deleted is marked and can't be pasted again). Copying the same thing twice never makes a duplicate.

**Pasting.** Click selects an item; **double-click or Return pastes it into the app you were using** (Cocaine puts it on the
clipboard, closes the island and sends ⌘V to that app). ⇧ pastes it the other way: without formatting, or with it if *Paste
without formatting* is on. ⌘1…⌘9 paste the first nine items shown (⇧⌘ for the other formatting). Sending ⌘V needs the
**Accessibility** permission Cocaine already asks for (Stay active, the HUD keys); without it the item is only copied and the
page says "Copy only" with an *Allow…* button. Cocaine sends ⌘V and nothing else, only to the app that was in front (if
another app comes to the front meanwhile, it only copies), and it never watches what you type.

**Several at once.** ⌘-click and ⇧-click (⇧↑ ⇧↓, ⌘A with the keyboard) select more; the bar at the bottom then offers
*Paste all* (in the order you picked them, joined by the separator chosen in Settings: new line, blank line, space, comma,
tab or nothing; images are left out), *Stack*, *Merge* (one new text item, the originals stay), *Pin*, *Delete*.
**Paste Stack**: *Stack* lines the items up; each press of **Paste next** (⌃⌥⌘V by default, its own global shortcut, active
only while a stack waits) pastes the next one. There is no ⌘V-watching keylogger: it is Cocaine's own shortcut.

**Details** (Space, the ⓘ of a row, or *Details*): the item large. Text scrolls (monospaced for code and JSON); a colour
(`#rrggbb`, `rgb()`) shows a swatch; a link shows its domain (nothing is fetched: no titles or icons from the network);
an image fits or shows at its real size, with **Copy text** (the text in it, read on this Mac by Vision); files show name,
size, folder and icon, with **Quick Look** and Show in Finder. From there: *Paste*, *Copy*, **Edit** (⌘E: save as a new item
or replace; ⌘Z inside the editor, and ⌘Z in the list puts back a replaced text), **Rename** (⌘R: a name shown instead of
the content), *Paste as…* (UPPERCASE, lowercase, Title Case, trim, join lines, sort, remove duplicate lines, format or
compact JSON, URL and Base64 encode/decode, remove link tracking), *Pin to…*, *Delete*. A formatted text has a
*Formatted / Plain* switch for that paste. On macOS 15.1 and later with Apple Intelligence the editor offers Writing Tools.

**Pinboards** are named collections (Favorites is the star); see [pinboards.en.md](pinboards.en.md). Chips at the top of the
page show one pinboard (⌥1…⌥9, ⌘[ ⌘]) or one kind (text, images, files, links, colours); drag items onto a chip to pin them.

**Search** filters as you type (any case or accents; text, names, file names and folders, image size, text found in images,
source app) and understands a few filters: `type:image|text|file|link|color`, `app:Safari`, `from:device` or `from:mac`,
`board:Prompts` (quotes for spaces: `board:"My board"`), `date:today|yesterday|3h|7d|2w`. Typing while the list has the
keyboard filters it too.

**Suggestions.** With nothing typed, up to two items marked ✦ come first: what you pasted into the app in front before,
what you copied in it, and the pinboard you tied to it (Settings → Island → Pinboards → *Suggested first in*). Cocaine only
uses what it already knows; it reads nothing from other apps and needs no Screen Recording.

**Other devices.** A copy that arrives from your iPhone, iPad or another Mac through Universal Clipboard is labelled
*Another device* (never the app that happened to be in front), but only with *Copies from other devices* on, which is **off by
default** since 2.9: off, Cocaine doesn't even read such a copy, so Universal Clipboard works exactly as without it. On, only the
plain text is read, 3 seconds after it arrives (never its formatting, images or files, each of which would be one more transfer
from the other device). Settings from before 2.9 are switched off once ([defaults and basics](defaults-and-basics.en.md)). Items to and
from the iPhone through iCloud Drive or the paired iPhone, and keeping Universal Clipboard copies off the saved history:
[iPhone clipboard sync](clipboard-sync.en.md).

**Text in images.** Off by default: with *Find text in images* on, each new image is read on this Mac (Vision, in the
background, not in Low Power Mode) and its text is kept with it for search, with anything that looks like a key, a token or a
card number masked, at most 4,000 characters. *Copy text* works either way, on demand.

**Undo.** Deleting one item, a selection or *Clear history* can be undone for a few seconds (the *Undo* at the bottom, or ⌘Z).
**Pause** stops recording, for 15 minutes, an hour, until tomorrow or until you resume.

**Never kept**: content that password managers and other apps mark as concealed, transient or auto-generated
(nspasteboard.org markers, 1Password's own marker); anything copied while a password manager is in front; apps you exclude in
Settings; and, unless you turn it off, text that looks like a card number or a key/token. You can add your own regular
expressions. These checks are heuristics: they catch common cases, not every secret. Excluding an app later removes what it
copied from the history, except what you pinned.

**Memory only by default.** The history lives in memory and is gone when Cocaine quits or the island is turned off; what you
**pin is always saved** (see pinboards). With **Save on this Mac** the whole history is stored in
`~/Library/Application Support/Cocaine/clipboard`, encrypted (AES-GCM) with a random key kept in your login Keychain (this Mac
only, never synced), files readable only by you. If the Keychain can't be used, nothing is saved and the page says so.
Turning it off asks whether to delete the saved history (pinboards stay) or keep it encrypted for later. Nothing ever leaves the
Mac.

**Limits** (Settings): how many items (25–500), how long (1 hour to 30 days, or no limit), total space (10–250 MB) and the
largest single item (1–25 MB; formatting that doesn't fit is dropped, not the text). Pinned items never count.

**Hide from screen sharing** (off by default) marks the island's window as not capturable while it shows the clipboard. macOS
honours this for screenshots and most recording and sharing apps; some capture tools may still record it, so don't rely on it
for secrets.

**Command line**: `cocaine clip list|get|put|paste` (Terminal, scripts, Shortcuts' *Run Shell Script*). Off by default
(Settings → Island → Clipboard → *Command line*): *Add only* allows `put`; *Full* also allows reading (`list`, `get`) and
`paste`. It talks to the running app over a socket that exists only while allowed (0600, in a private folder, same user
only, every request signed with a per-install key and never accepted twice). There is no `cocaine://` link for the clipboard:
a web page can never read or paste it.

    cocaine clip list [--board NAME] [--limit N] [--json]
    cocaine clip get [N | --id ID] [--board NAME]
    cocaine clip put [--board NAME] [--title TITLE] [--copy] [TEXT…]     (no TEXT: standard input)
    cocaine clip paste [N | --id ID] [--board NAME] [--plain]

The secrets filter and your patterns apply to `put` too.

**Keyboard** (with the clipboard opened by your shortcut, the island opened by ⌃⌥⌘I, or the search field focused; all the keys, the floating panel near the pointer and the search modes: [clipboard-keyboard.en.md](clipboard-keyboard.en.md)): ↑ ↓ move, Return / ⇧Return paste, ⌘1…9 quick
paste, ⇧↑ ⇧↓ ⌘A select, Space (nothing typed) or ⌘Y details, ⌥P favourite, ⌘P pin, ⌥Return copy only, ⌘C copy, ⌘E edit, ⌘R rename, Delete deletes (or edits what you typed), ⌘Z undo,
⌥0…9 and ⌘[ ⌘] pinboards, Esc clears the selection, leaves the details or closes. VoiceOver: activating a row pastes it; its
actions are Copy, Details, Select, Pin to…, Delete. The module can be S (the newest items), M (search and list) or L.

**Limits of this feature**: the clipboard is checked a little more than once a second (not while the screens or the Mac
sleep); the app in front is taken as the source when the copying app doesn't say. Some apps (remote desktops, games, a few
Electron apps) ignore a synthetic ⌘V: then press ⌘V yourself. Quick Look opens the system's panel; with the island it may not
take the keyboard until clicked. With an ad-hoc signed build, macOS asks again for Keychain access after each update; if you
refuse, nothing is saved. Deleting files can't guarantee the bytes are erased on an SSD: what makes a deleted history unreadable
is that its key is deleted too. Universal Clipboard itself (Apple's) needs the devices nearby with Handoff on; whether
copies Cocaine writes are offered to the iPhone was not verified on a device.

**If the saved history can't be read** (damaged, another key, or a newer version), Cocaine moves it with its files into an
`unreadable-<time>` folder next to it, starts empty and never deletes them; the same for the pinboards' file. Older saved
histories (2.6 and before, schema 1) are read as they are and written in the new format at the next save; their favorites
become the Favorites pinboard.
