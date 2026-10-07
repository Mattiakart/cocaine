### Shelf (island)

The island's Shelf holds things you want at hand for a while: **files and folders** (as references to where they are, never
copies), **texts**, **links** and **images** dropped or pasted from any app (those three are kept by Cocaine itself, see
*Privacy*). Drag them onto the notch: the island opens on the shelf and they land in the collection shown (or in the
collection tab you drop them on).

**Collections.** Several named shelves, each with a colour: *Shelf* is the first one; add more with **+**, switch with the
tabs, and rename, recolour, reorder, merge or delete them in the collections sheet (the stack button) or in Settings → Island
→ Shelf. Deleting a collection removes its items from the shelf, never the files. Up to 40 collections of 500 items each.

**Files are followed.** Each file is kept with a bookmark: if you rename it or move it to another folder on the same disk,
the shelf finds it again (and saves the new place). A file that was deleted, is in the Trash or is on a disk that isn't
connected stays listed, dimmed with a question mark, until you remove it; operations skip it.

**Selecting.** Click an item; ⇧-click selects a range, ⌘-click adds or removes one, ⌘A selects all, a band dragged over the
empty space selects what it touches. Once you clicked in the shelf it has the keyboard: the arrows move (⇧ extends), Space
shows **Quick Look** (the arrows go through the items, Space or Esc closes), Return opens, ⌫ removes from the shelf (the files
stay), ⌘⌫ moves files to the Trash, ⌘C copies, ⌘V adds what is on the clipboard, Esc clears the selection. With VoiceOver
each item says its kind, whether it is missing or selected, and offers Open, Quick Look, Actions, Move left/right, Remove.

**Dragging out.** Drag any item: the whole selection goes, as separate files (one drop in Finder, Mail, a chat…). As with
Finder, the app you drop on decides: dropping on another folder of the same disk **moves** the file (the shelf follows it),
on another disk copies it, ⌥ forces a copy. Images pasted into the shelf are always copied out. Drag items inside the grid
to **reorder** them, or onto another collection's tab to move them there. *Remove after dragging out* (Settings) makes items
leave the shelf once dropped elsewhere.

**Actions** (right-click an item, or the ⋯ button; with nothing selected they apply to the whole collection):
Open, **Open With…** (only the apps that open every selected file, with their icons), Show in Finder, Quick Look, **Share…**
(macOS's services, AirDrop first), Copy, **Copy Path** (one per line), **Copy to… / Move to…** (pick a folder; names that are
taken become "name 2"), **Rename…**, **Compress (ZIP)**, **Resize or Convert…**, **Recognize Text**, Create PDF, Stitch
Vertically / Side by Side, Remove from Shelf, Move to Trash. Long jobs show their progress under the shelf with Cancel;
results (the archive, the new images, the recognized text) land in the collection.

- **Rename** works like Finder's, with a live preview: find and replace, text before/after, a number (start, digits, before
  or after), the file's date, letter case, or one new name for all (numbered). The extension never changes. A name that is
  taken, used twice in the batch, empty, too long or with / or : is shown in orange and nothing is renamed until it is
  fixed; nothing is ever overwritten. **Undo** appears for a few seconds afterwards.
- **ZIP** uses macOS's own `ditto`, as Finder does (resource forks and extended attributes kept). One item gives
  "name.zip", several give "Archive.zip" with the items at its top level, next to the first item (or in Downloads when that
  folder can't be written). There is no password option: ZIP's password encryption is weak.
- **Images**: resize by width, percent or longest side (never enlarged), convert to PNG, JPEG, HEIC or TIFF (HEIC only when
  this Mac can encode it), quality for JPEG/HEIC, remove metadata (location, camera, XMP; the colour profile stays), keep the
  originals (new files "photo-1200.jpg") or replace them (the originals go to the Trash, so they can come back). There is no
  lossy PNG compression: to make a PNG smaller, convert it to JPEG or HEIC.
- **Recognize Text** reads images and the first 5 pages of PDFs with macOS's Vision (on this Mac, nothing is uploaded),
  your languages first; a PDF that already contains text gives that text. The result goes to the clipboard and onto the shelf.

**Your actions** (Settings → Island → Shelf → Your actions) add your own entries to the actions menu: a **shell script**, a
**Shortcut** (Shortcuts app), an **Automator workflow**, an **AppleScript or JavaScript** file, **Open with an app**, **Move to
a folder**. They can be added only there, by you; never from a link, a dropped file or another app. Files are passed as
separate arguments (absolute paths, so a name can't be read as an option), never pasted into a shell line; Automator gets
them on standard input, one per line (a name with a line break is refused for it). Scripts run with a small environment of
their own (a plain PATH, your HOME and language, `COCAINE_SHELF_COUNT`), a timeout (2 minutes by default) and Cancel; their
output can go to the clipboard or onto the shelf. **The first time a script or Shortcut runs, Cocaine asks**, and asks again
whenever the script file changes (it remembers its SHA-256). *Test* runs it once with no files and shows what it printed.
Turn on *Instant* for an action and hold ⌥ while dragging files over the island: the action appears as a drop target and
runs on the dropped files without adding them.

**Watched folders** (Settings): new files in a folder land in a collection by themselves. Presets for **Screenshots** (it
follows the screenshot location you set in macOS) and **Downloads**, or any folder. Rules: extension, kind (images, videos,
PDF…), name contains / starts / ends with, screenshots only (the flag macOS writes on screenshots, else the screenshot names
macOS uses), each one can be inverted, all or any of them. Files arriving together wait for the folder to be quiet for the
chosen time (0.5–30 s) and land as one batch; downloads in progress (.crdownload, .download, .part…) and files still growing
are never taken. Only files that appear after the watch began count. If macOS doesn't let Cocaine read the folder (Files and
Folders permission for Desktop, Documents, Downloads, removable or network volumes), the row says so with a button to the
right System Settings pane. Watching runs while the island is on.

**Other ways in**: Finder's Services menu (**Add to Cocaine Shelf**, also for text, links and images selected in other apps),
`open -a Cocaine file…`, Finder's Open With (Cocaine is listed as a viewer of anything, never the default app), the command
line `cocaine shelf add <file>…`, `cocaine shelf list [--all] [--json]`, `cocaine shelf clear`, and **Shake to open**
(Settings, off by default): shake the pointer while dragging files and the island opens on the shelf. The `cocaine://` link
scheme has no shelf commands, so a web page can never add paths or read the shelf.

**Sizes.** The Shelf module comes in three sizes (Settings → Island → Screens): S (one line), M (one row of items) and L
(the collection tabs, the toolbar and the grid).

**Privacy.** Everything stays on the Mac. The shelf is saved in `~/Library/Application Support/Cocaine/shelf`
(`library.json`, readable only by you, written atomically): paths, bookmarks and the texts and links you put there. Pasted or
dropped images are kept in its `items` folder (readable only by you) until you remove them. A shelf file that can't be read is
set aside (`library.json.unreadable-<time>`), never deleted. The shelf from before collections is brought over once,
including files that are gone (shown as missing).

**Limits**: the Services entry appears once macOS has registered the app (after it was installed in Applications; at worst
after a log-out). Quick Look brings Cocaine forward while it is open and gives the keyboard back to the app you were in
afterwards. Copy to/Move to into Desktop, Documents, Downloads or other protected places can trigger macOS's permission
question the first time. HEIC encoding isn't available on every Mac. Recognition accuracy depends on the image; handwriting
is often missed. Cloud links (*Share link…*) appear only once a cloud provider is set up (a later Cocaine).
