# Motion

Every animation in Cocaine comes from one system in `Sources/Motion.swift`: a few tokens, a table that gives each kind of change
(a *role*) one curve, and small view helpers built on them. Tests: `--motion-test` (also part of `--selftest`).

## Tokens

| Token | Value | Used for |
|---|---|---|
| `Duration.instant` | 0.08 s | press feedback under Reduce Motion, symbol swaps |
| `Duration.quick` | 0.15 s | hover, every fade under Reduce Motion, HUD label swaps, the panel resizing |
| `Duration.standard` | 0.22 s | content cross-fades (a language change, a busy label) |
| `Duration.slow` | 0.4 s | the full-screen alert fading away |
| `snappy` spring | response 0.24, damping 0.86 | press, selection, values, the HUD's bar |
| `smooth` spring | response 0.32, damping 0.88 | pages, expanding rows, dropdowns, the island closing, wings, the HUD going up, a drag settling |
| `gentle` spring | response 0.42, damping 0.92 | dialogs, notices, request cards, things arriving |
| `bouncy` spring | response 0.36, damping 0.80 | the island opening, the HUD dropping, the switch's knob |
| `stagger` | 0.035 s per item, at most 0.2 s | items arriving together |
| Distances | press 0.97 (glyphs 0.92), enter 8 pt + 0.97 scale, page 16 pt, lift 1.02 + 8 pt shadow, pulse 1.12 | |
| `islandSettle` | 0.5 s | when the island's window shrinks after a close (longer than the close spring takes to settle) |
| Pour | 1.4 s filling (ease-out), 0.7 s emptying (ease-in) | the menu-bar bag |

## Roles

`Motion.animation(.role)` gives the animation for a role now; `Motion.with(.role) { … }` runs a model change with it.

| Role | Normal | Reduce Motion |
|---|---|---|
| press | snappy | 0.08 s fade (it dims instead of shrinking) |
| hover | 0.15 s ease-out | the same |
| selection | snappy | 0.15 s fade |
| toggle | bouncy | at once |
| value, hudBar | snappy | at once |
| expand, dragSettle, wing, islandClose | smooth | at once |
| page, dropdown | smooth | 0.15 s fade |
| appear, dialog, notice | gentle | 0.15 s fade |
| islandOpen, hudDrop | bouncy | at once (island); 0.15 s fade (HUD) |
| hudRetract | smooth | 0.15 s fade |
| crossfade | 0.22 s | 0.15 s |
| hudSwap | 0.15 s | 0.08 s |

## Helpers

- `.pressable(pressed)`: press feedback (`CocaineButtonStyle`, the switch, `MotionGlyphStyle` for glyph buttons, steppers, rows).
- `.motionAppear(edge:)` / `Motion.appear`: arrives from an edge, a little smaller, becoming opaque early (dialogs, dropdowns,
  request cards, shelf items, the screens editor's rows).
- `Motion.page(direction)`: the new page slides in from the side of the tab picked, the old one leaves the other way, fading
  through (the island's screens, the panel's tabs). `PageDirection` is updated by the model when the tab changes.
- `.motionSelection(value)`, `.motionNumber(value)` (rolling digits), `.motionPulse(trigger)`, `.motionLift(lifted)`.
- `.shimmer(active)` and `BusyDots`: loading, calm, opacity only (camera starting, usage still counting, the updater, busy buttons).
- `StripHighlight`: the strips' tab highlight with its hover.

## Rules for a new animation

1. The model is the only truth. Animate a change of it (`Motion.with`, `.motion(_:value:)`), never with a timer or a chain of
   `asyncAfter` steps. A new change retargets a running spring: SwiftUI keeps its velocity, so nothing restarts.
2. Delayed work that a later change can supersede carries a `MotionGeneration`: only the latest one runs.
3. A transition that can be interrupted is a function of one progress value (the island's morph, the page reveal, the HUD's
   `reveal`): reversing half-way continues from where it is.
4. Pick a role; add a role to the table (and its test) only when none fits. Never write a raw duration or spring in a view.
5. Layouts never change for motion: only offset, scale, opacity, blur.
6. No new timers. Loops (`shimmer`, `BusyDots`) run only while something is loading. The bag's pour still redraws only the bag.

## Reduce Motion, Reduce Transparency, renders

- Reduce Motion: nothing moves, scales or bounces. What only moves (the island's morph, wings, the knob, bars) changes at once;
  what arrives fades in 0.15 s; the alert is one soft tint; the segmented control's pill doesn't slide; a pressed control dims.
- Reduce Transparency: the dims behind dialogs are more opaque.
- `Motion.disabled` (set by every render and the snapshot checks): every role's animation is nil and the loops hold still, so
  pictures never catch a transition half-way.
- `--render-motion <prefix> [island page hud dropdown dialog] [--reduce-motion]` draws each transition at 0, 25, 50, 75 and
  100 % with the app's own modifiers, to look at the frames in between.
