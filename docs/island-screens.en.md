# The island on every screen, its HUD and haptics

## One island per connected screen

- Every connected screen gets an island: the notch on a screen that has one, a slim pill (150 pt, as tall as that screen's
  menu bar) on the others. A mirror set gets one island. The main island (the built-in notch, else any notch, else the
  built-in display, else the main display) comes first. Island → *Show on all screens* (on by default) off keeps only the main
  island, as in 2.5.0.
- Each island has its own geometry and window; the pages and their data are shared. Only one island is open at a time: the
  pointer touching screen B's notch opens B's island and closes A's. An island with a dialog in it stays open until the question
  is answered; one opened with ⌃⌥⌘I (on the screen with the pointer) stays when the pointer leaves for no island.
- A full-screen app hides only its own screen's island. Displays plugged, unplugged, rearranged, rescaled, mirrored or the lid
  closed: every island is re-anchored at once (and checked again every 1.2 s); an island open on a screen that goes away closes.
- The settings panel and its dialogs hang from the notch of the screen the user is working with: the island last opened, or the
  screen with the pointer when the panel is asked for (not one hidden by a full-screen app). Only that island steps aside for it.
- One watch timer serves every island (full-screen check with one window list per pass, the failsafe per window). The menu-bar
  icon comes back only when no island can be shown.
- VoiceOver: each island has its closed "Cocaine" element; its action opens the island of the screen with the pointer.

## The HUD below the notch

- Volume and brightness bars and the short notices (Downloaded, Screenshot, Copied, AirDrop problems, shortcut feedback,
  charger, focus over, AI notes) appear in a container hanging straight below the notch: as wide as the notch (the pill on
  notch-less screens), centred on it, square-joined to its bottom with small fillets and the island's rounded corners, black.
- A held key or quick presses update the same container: the bar moves to the new level, the time is extended; volume then
  brightness swaps icon and label inside it. It goes back up into the notch after 1.4 s of quiet. A newer notice replaces the
  shown one; a bar arriving over a notice puts it aside and the notice comes back when the bars are done (at most once).
- It gives way when its island opens (and doesn't come back), and isn't shown under an open island. Reduce Motion: it fades.
- Which screen: brightness → the display the key changed (the backlit display under the pointer, else the built-in;
  a mirrored display → its set's island); everything else → the screen under the pointer, else the main island. Every other
  screen stays quiet. A HUD whose screen goes away moves to the pointer's screen (or the main island).
- If that screen's island can't be seen (a full-screen app there, the settings panel over it) the brightness key goes to macOS,
  which shows its own indicator, as in 2.5.0.

## Haptics: one per action

- A click on a Force Touch trackpad is already a tap (its Taptic Engine plays the click). 2.5.0 added its own tap in every
  button's action, felt as a double tap. Now a tap asked for while a click is being handled is not played; taps without a click
  (dragging onto a magnet, the focus ruler, two-finger scroll steps, the island opening under the pointer, the keyboard) are.
- The code doubles are gone (the time stepper's scroll steps, the strip's back button reopening the island), and the same
  pattern twice within 60 ms plays once.

Tests (`--selftest`, `--display-test`): Sources/IslandTests.swift — screen lists, hot-plug, mirror, geometry, the open/hover
state machine, the HUD timeline and routing, a counting HapticSink.
