### The clipboard from the keyboard

Everything the [clipboard](clipboard.en.md) does can be done without the mouse, from any app, the way
[Maccy](https://github.com/p0deje/Maccy) works.

**Open it.** **⌃⌘V** (Settings → Island → Clipboard → *Open the clipboard*; any combination you record there, or none)
opens the clipboard with the keyboard already in it. Pressed again, or Esc, it closes. *Opens* chooses where:

- **Island** (default): the island's Clipboard page, opened from the notch.
- **Pointer**: a floating panel of Cocaine's own with its top-left corner at the pointer.
- **Centre**: the same panel in the middle of the screen the pointer is on.
- **Last place**: where you last dragged it (drag it by its background); on a screen that is gone, the middle.

The floating panel is drawn by Cocaine, black like the island, with its questions (Pin to…, Rename, Clear) inside it; it is
not a system pop-up. It never makes Cocaine the active app, so the app you were typing in stays the one the paste goes to. If no
screen of the island holds the Clipboard module, the shortcut opens the panel under the top of the screen instead. Each
opening starts fresh: no search, nothing selected, the newest item highlighted.

**Keys** (in the island and in the panel):

| Keys | What they do |
|---|---|
| type | search at once (the panel's search field has the keyboard; in the island typing fills it) |
| ↑ ↓, Home End, ⌘↑ ⌘↓, Page Up/Down | move the highlight |
| Return | paste into the app you were in |
| ⇧Return | paste with the other formatting (without formatting, or with it when *Paste without formatting* is on) |
| ⌥Return, ⌥⇧Return | the other way: copy only (when Return pastes), or paste (when Return copies only) |
| ⌘1 … ⌘9, ⇧⌘1 … ⇧⌘9 | paste the first nine rows (the rows show ⌘1…⌘9 while opened from the keyboard) |
| ⌘Y, Space (nothing typed) | details of the item (again, or Esc: back) |
| ⌥P | add to or remove from Favorites |
| ⌘P | Pin to… a pinboard |
| ⌥⌫ (also while typing), ⌘⌫, Delete (nothing typed) | delete the item (or the selection); ⌘Z undoes |
| ⌥⌘⌫ | clear: the history only, or everything (asked first) |
| ⌘C, ⌘E, ⌘R | copy, edit, rename |
| ⇧↑ ⇧↓, ⌘A | select several (Return pastes them together) |
| ⌥0 … ⌥9, ⌘[ ⌘] | pinboards |
| Esc | clears the search, then the selection, then closes |

Letter keys (P, Y) are found by the letter they type, so they stay on their letter on AZERTY, Dvorak and other layouts.
While an input method is composing (Japanese, Chinese, Korean…), every key is its own: ↑ ↓ pick a candidate, Return
commits, Esc cancels the composition; the list's keys work again once the text is committed.

**Search** (*Search* in the settings):

- **Words** (default): every word, anywhere, any case or accents; the filters `type:`, `app:`, `board:`, `from:`, `date:` still work.
- **Fuzzy**: the letters in order, with gaps (`gpom` finds "git push origin main"); the best matches first.
- **Regex**: a regular expression, any case (an invalid one finds nothing; at most 300 characters; the first 100,000
  characters of each item are searched).
- **Mixed**: whole words first; if nothing matches, a regular expression; if still nothing, fuzzy.

**Order** (*Order*): *Newest* (default), *Most pasted* (how often you pasted it, in any app), or *A–Z* by name or text.

**Pasting into the other app** needs the **Accessibility** permission (Cocaine sends ⌘V and nothing else, only to the app that
was in front). Without it Return copies only, and the bottom of the clipboard says *Copy only: pasting needs Accessibility*
with an *Allow…* button that asks macOS (or opens Privacy & Security → Accessibility). Nothing is pasted behind your back:
if another app comes to the front before ⌘V, the item is only copied.

**VoiceOver.** Opening says how many items there are and the keys; moving the highlight reads the item; each row's actions
are Copy, Paste with/without formatting (formatted text), Details, Select, Pin to…, Send to iPhone, Delete, and its value says
"Command N pastes it" for the first nine. The panel is a floating window named *Clipboard*.

**Limits.** Global shortcuts can be taken by another app first: the shortcut button then turns orange (*Used by another app*).
The floating panel closes when another app takes the keyboard (⌘Tab) or you click elsewhere; Quick Look from its details
takes the keyboard, so the panel closes then. Some apps ignore a synthetic ⌘V (remote desktops, games): press ⌘V yourself.
The paste into another app, the panel's placement and VoiceOver were checked with the test suite (`--keyboard-test`) and
renders, not by sending real keys to other apps in a test.
