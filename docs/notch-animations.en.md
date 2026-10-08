# The notch: motion, charging, swipes, sizes, controls, reminders

This page covers what round 6 brought from Boring Notch (TheBoredTeam/boring.notch) and how Cocaine adapts it to its own UI.
Everything uses the motion system in `Sources/Motion.swift` (docs/motion.en.md) and has a Reduce Motion fallback. The island
still opens the moment the pointer reaches the notch: a spring shapes the opening but never delays it.

## What Boring Notch does, and what Cocaine took

The numbers come from reading Boring Notch's source (`ContentView.swift`, `sizing/matters.swift`,
`extensions/PanGesture.swift`, `BoringBattery.swift`, `BatteryActivityManager.swift`).

| Boring Notch | Cocaine |
|---|---|
| Open: `spring(response 0.42, damping 0.8)`. Close: `spring(response 0.45, damping 1.0)`, so it closes critically damped, with no bounce. | New tokens `Motion.notchOpen` (0.42 / 0.8) and `Motion.notchClose` (0.45 / 1.0), used for the `islandOpen` and `islandClose` roles. The window shrinks after `islandSettle` = 0.56 s, which is longer than the close spring takes to settle. |
| The black shape's corner radii animate, closed (6, 14) to open (19, 24). | Cocaine's outline already morphs one progress value (flares, sides, bottom corners). Its closed corners (13.5) and open corners (32 by default) can now be set (see Sizes). |
| A shadow (black 0.7, radius 6) appears when open. | The open island casts a soft shadow (black 0.55, radius 6). It springs in and out with the morph. Closed, the island stays part of the screen's edge. |
| Open content: `.scale(0.8, top)` + opacity, 0.35 s. No stagger. | The page fades in as one piece, a beat after the island starts to open (PageReveal). Each module then rises the last 8 pt one after another (`ModuleStagger`, Motion.stagger per module). The rise is a function of the morph's progress, so a reversal mid-way runs it back from where it is. |
| Gestures: a local scroll monitor, axis dominance 1.5×, sensitivity 200, and a live scale of the whole notch (min 0.6). | Swipes (see below), with the same 1.5× dominance and a live scale of 0.94 to 1.1 on the follow spring (0.38 / 0.8). |
| Battery: listens to `IOPSNotificationCreateRunLoopSource` and Low Power Mode. Shows a 3 s notice of status text plus a battery. The fill is green when charging or full, red at 20 % or less, yellow in Low Power Mode. | The battery HUD (below), with the same colours and the same 3 s. It drops from the notch like every HUD of Cocaine. |
| Hover: 0.3 s minimum hover, 100 ms close grace. | Not taken. Cocaine opens and closes on hover at once, as the user decided. |
| Sneak peek beside the notch for volume and brightness. | Not taken. Cocaine's HUD hangs below the notch (HUDTimeline), and that stays. |
| Music control slots (shuffle, previous, play/pause, next, repeat, favourite…). | The music page belongs to another area. Cocaine adds a **Controls** module instead: picked and ordered by the user, and it can go on any screen (Home, Music…). |
| Calendar with reminders. | A **Reminders** module and screen (EventKit). |

## Roles added to the motion table

| Role | Normal | Reduce Motion | Used for |
|---|---|---|---|
| `chargeIn` | bouncy | 0.15 s fade | the charger's bolt or plug popping in or out |
| `levelFill` | smooth | at once | the battery's fill running to its level |
| `stateSwap` | snappy | 0.08 s fade | a state shown in place changing: play ↔ pause, a control turning on, the closed island's live item, a ticked reminder |
| `gestureFollow` | follow (0.38 / 0.8) | at once (nothing moves) | the island following two fingers |
| `contentIn` | smooth | 0.15 s fade | modules arriving |

## Charging and the battery (Sources/NotchPower.swift)

These events show a HUD under the notch:

- the charger plugged in ("Charging", with the time to full once macOS knows it; "Plugged in" while macOS holds the charge; "Fully charged" when the battery is already full),
- the charger unplugged ("On battery", with the time left when known),
- the battery full, said once per time on the charger,
- the battery low on battery power: once at the chosen level (20 % by default) and once more at 10 %. It is said again only after the level has risen 3 points or the charger was in,
- Low Power Mode turned on or off.

The HUD shows the badge (a bolt, or a plug while held), the title (on two lines when there is no detail), the detail, and a
battery glyph with the percentage under it (its digits roll). Round 7 moved the percentage there: "62% · Full in 48 min" on
one line was cut under a 14" notch in most languages, as were Low Power Mode's title and "Plug in the charger soon" (now
"Charge soon"). --island-review-test measures every title and detail in the 8 languages against that width. While the container drops, the glyph's fill runs from empty to the level and the bolt grows in. They follow the drop
frame by frame, so a reversal half-way takes them back with it. Charging then full updates the same glyph in place. A volume
bar arriving over the battery HUD puts it aside, and it comes back after the bar. With Reduce Motion, the container fades in,
the fill is at its level at once, and the bolt fades.

**No brightness bar over it (round 7).** When the charger goes in or out, macOS sets the brightness by itself ("Slightly dim
the display on battery"), and in 2.8.0 that change got a brightness bar that covered the charging HUD. The brightness bar is
now only for the user's own changes (`BrightnessHUDRule` in Sources/HUD.swift):

- For 6 s after the charger goes in or out, or the displays wake, only a brightness key pressed after that change gets a bar.
- Otherwise a key gets its bar for any step, and a bigger jump without a key (a slider in Control Center, System Settings or
  the island) gets one only if the pointer clicked or dragged, or a key was typed, in the last 2 s. Automatic brightness's
  drift and its jumps while nobody touches anything get none.
- The charger's last change comes from the app's one power-source watch (`PowerSourceWatch`, Sources/Power.swift, which the
  idle dimming uses too); it looks again the moment a brightness change is seen, so the first step of the ramp, which can
  come before IOKit's notification is handled, is quiet too. Cocaine's own dimming never gets a bar.

Readings come from IOKit's power-source notification the moment something changes, and from the app's 2 s poll as a backup.
The pure `ChargeEvents` turns readings into at most one event each. Nothing is announced at launch, and a wiggling cable is
said as it is. Settings → Island → Notch: **Charging notices** (on by default) and **Low battery notice** (off, 10, 20 or 30 %).

## Swipes (Sources/NotchGestures.swift)

These are two-finger swipes on a trackpad:

- **Up on the open island** closes it. It stays closed until the pointer leaves the notch, so it doesn't reopen under the pointer.
- **Down just below the closed notch** opens it. The pointer on the notch itself opens the island at once (hover), so this
  swipe starts in a band under the notch and its wings (64 pt down, 48 pt to each side) or on the notch right after a swipe
  up. In 2.8.0 the swipe had to start on the notch, where the island is already open: it could never be used.
- **Left or right on the open island** moves to the next or previous screen, like the trackpad's page swipe.

While the fingers move, the island follows: pushed up it shrinks a little toward the notch, pulled down the closed notch
grows a little. When the fingers lift, it springs back. A swipe acts once, at the threshold set by **Sensitivity** (low 90,
medium 55, high 30 scroll points). The fingers must move mostly along one axis (1.5× the other).

A swipe is ignored in these cases:

- when it started over something that scrolls by itself (a list taller than its box, a two-finger stepper such as the timer's segments),
- for a mouse wheel and for the momentum after the fingers lift,
- while a question, a shelf form or the keyboard mode holds the island.

The gesture's start (where, which island, open or not, whether the island owns it) is kept for diagnostics and logged at
debug level (`log stream --level debug --predicate 'subsystem == "local.cocaine.toggle"'`).

Every switch is in Settings → Island → Notch → Swipes.

Pinch is not used. macOS sends magnify events only to the window under the pointer, and a closed island lets the pointer
through. No island action maps onto a pinch either.

## Sizes (Sources/NotchSizing.swift)

- **Open island**: Standard (640 × 214), Large (700 × 244), Extra large (760 × 274), or the Width (640 to 800) and Height (214 to 300) sliders. The island is never smaller than the standard size, which every page was laid out for.
- **The content grows with it (round 7, Sources/IslandScale.swift).** Each module gets its box in the bigger island and also
  knows its box in the standard one, and what has a fixed size inside it grows from there: the camera's picture takes all of
  the extra height at its own shape (250 × 146 → about 353 × 206 at Extra large), the narrow column of Home, Files and Status
  widens with the page, the media tiles and icons, the screenshots, the round controls, the focus timer and its column, and the
  monitors' sliders grow; lists show more rows and more batteries fit. Text stays on the app's one type scale. Media's tiles
  also never spill out of their box under a tall menu bar (they did by 3 to 9 pt in the standard island).
- **Corners** of the open island: 16 to 40 pt.
- **Closed, on screens without a notch**: width 110 to 260 pt; height as tall as the menu bar (the default) or 22 to 40 pt; corners 4 to 16 pt. **Applies to** picks every screen without a notch, or one screen at a time. A display is recognised by its vendor, model and serial number, so the setting follows it from plug to plug.
- On a notched screen, the closed island is the notch itself, so its size is the hardware's.

## Controls (Sources/NotchControls.swift)

The **Controls** module is a row of round buttons, all the same size: Cocaine, Stay active, previous, play/pause and next
track, mute, the focus timer, Screenshot, turning off the display, Reminders and Settings. Settings → Island → Notch →
Controls picks which ones show (up to 7) and their order. Add the module to a screen in Screens (S: the row; M: with labels).
A control with a state (Cocaine on, Stay active, playing, a focus running) fills with the accent. Its glyph is replaced in
place with the `stateSwap` motion.

## Reminders (Sources/IslandReminders.swift)

- The **Reminders** screen is hidden until you show it in Screens. The **reminders** module can also go on any other screen.
- Before access is given, the module asks from inside the island (**Allow access to Reminders**). If access was refused, it opens Privacy & Security instead.
- **Show**: Today and overdue (the default), Scheduled, or All. Overdue reminders come first, in red.
- A click on a reminder's circle ticks it. It stays ticked and struck through for 1.4 s, so a second click undoes it. Then it is saved as completed and leaves.
- **Quick add**: type and press Return. The new reminder goes to the chosen list (**Add to**) and is due today on the Today page.
- Settings → Island → Notch → Reminders: **Lists shown** and **New reminders go to**.

## Tests and renders

- `--notch-test`: battery events and glyphs, the HUD timeline with them, swipes (including 50 rapid ones), sizes and the island's geometry following them, controls, reminders on a fake source (never EventKit), the new roles, and the module stagger.
- `--render-island <png> --notch-fixture charging|full|low|unplugged|lowpower|reminders|reminders-ask|controls|sizes|large|xl|max|mod-<kind>-<s|m|l>[-xl] [--open]`: sample data only.
- `--island-review-test` (round 7): the brightness rule and the charging HUD chain on fakes, the swipe zone and synthetic
  swipe sequences through the monitor (phases, both scrolling directions, one haptic each), the content scale, and a fit check
  that draws every module at every size in every island size and menu-bar height and measures anything outside its box.
- `--render-panel <png> --auto island [--notch-fixture reminders]`: the Notch card in Settings → Island.

## Not verified live

- **Not verified**: the IOKit power-source callback, on a real plug and unplug. Checked: the events with a fake reader in `--notch-test`, and the HUD in renders.
- **Not verified**: the swipes, on a real trackpad (no events may be posted into the user's session). Checked: the state
  machine in `--notch-test`, and the monitor with synthetic sequences and the swipe zone in `--island-review-test`.
- **Not verified**: the brightness macOS sets on a real plug. Checked: the rule and the whole chain with a fake clock, input
  and power source.
- **Not verified**: EventKit Reminders. Checked: the module and its logic against a fake source.
- **Not verified**: whether the Developer ID tier (hardened runtime) needs more than the existing calendars entitlement for Reminders.
