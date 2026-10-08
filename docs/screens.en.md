# The island's screens

Settings → **Island** → **Screens** arranges the island's pages ("screens") and what each one holds.

## What you can change

- **Show or hide** a screen with its switch. A hidden screen leaves the tab strip, the ←/→ keys and VoiceOver's list. At least one
  screen always stays shown (its switch is disabled). The **Monitors** screen appears only while an external monitor that speaks
  DDC/CI is connected, wherever you put it.
- **Order**: drag a row by its handle, or use its ↑/↓ buttons (also VoiceOver actions *Move up* / *Move down*). The first screen
  shown is the cell the bag turns into when the island opens; when it isn't Home, the bag melts into that screen's icon.
- **Start screen**: *Last used* (the default: as before, the first screen after launch) or a specific screen, which the island
  opens on every time (set once it has closed, so closing never jumps). A hidden start screen falls back to the last used one.
- **Modules**: open a screen's modules with its ☰ button. Each module has a column (*Left* / *Right*) and a size: **S** a third of
  the column's height, **M** half, **L** all of it; a module that has only one size says *Fills its column*. *Add module* adds any
  module of any page (each once per screen); *Merge into* moves all of a screen's modules into another and hides it.
- **Preview**: a miniature of the open island with your tabs and the edited screen's modules where the island draws them. It
  follows every change.
- **Restore defaults** (with a confirmation) brings back the built-in layout and forgets the stored one.

## The fixed size

The island's page has the size set in Settings → Island → Notch (640 × 214 by default; the content grows with a bigger island,
see docs/notch-animations.en.md). Two columns are 250 pt (more in a bigger island, in step with the page) and the rest (the column holding a module that needs room, else the one with the
larger module, gets the wider share; on a tie the right one, as the built-in pages); one column takes the whole width. When the
modules of a column don't fit, the lowest that can be smaller is drawn smaller, else the lowest is left out; a module that needs
the whole screen (Calendar, Focus, Media, Mirror, Monitors) leaves out the other column; two modules that need the wide column
(Music, Shelf) can't sit side by side. The card says which module was made smaller or left out and why (⚠ on the row); nothing is
ever drawn cut.

| Module | From | Sizes | Width |
|---|---|---|---|
| Cocaine (switch, timer, Stay active) | Home | S M L | narrow |
| Agents | Home | M L | narrow |
| Batteries | Status | S M L | narrow |
| AI usage | Status | L | narrow |
| Downloads | Files | M L | narrow |
| Screenshots | Files | L | narrow |
| Clipboard | Clipboard | M L | narrow |
| Music | Music | L | wide |
| Shelf | Shelf | L | wide |
| Media, Focus, Mirror, Monitors | their pages | L | whole screen |
| Calendar | Calendar | L | the screen alone |

## Stored

`screens.v1` in Cocaine's settings (JSON, versioned). Nothing stored, a value that can't be read or one written by a newer Cocaine
all mean the built-in layout, which draws every page exactly as before (checked by comparing renders of every page). Unknown
screens and modules are dropped, missing ones come back at the end. Every island (on every display) and the card share one layout.

## Checks

`Cocaine --screens-test` (also in `--selftest`): the rules above, storing, migration, and the island model following the layout.
Renders: `--render-island <png> --open --tab <id> --screens-fixture <standard|merge|hide-mirror|order|stack|wide|overflow|empty>`,
and `--render-panel <png> --auto island --screens-fixture <name> --screens-edit <screen id>` for the card.
