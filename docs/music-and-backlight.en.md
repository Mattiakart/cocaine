### Music and keyboard backlight (island)

**Players.** The island's Music page controls **Apple Music**, **Spotify** and **YouTube Music** played in
[Pear Desktop](https://github.com/th-ch/youtube-music) (the desktop app formerly called "YouTube Music"). When more than one
has a track, small chips next to the title switch between them: the one you pick stays shown while it has a track; otherwise
the one playing is shown, and another player pausing never takes over.

**Controls.** Shuffle, previous, **back N seconds**, play/pause, **forward N seconds**, next, the scrubber, lyrics (lrclib.net,
only if you turn them on), and, where the player allows it:

| | Apple Music | Spotify | YouTube Music (Pear) |
|---|---|---|---|
| Skip back/forward | yes (exact seek) | yes (exact seek) | yes (`go-back` / `go-forward`) |
| Favourite / like | yes (Favourite) | **no**: Spotify's scripting can't save a song | yes (Like; pressing it again removes it) |
| The player's own volume | yes (`sound volume`) | yes (`sound volume`) | yes (`/volume`; muted reads as 0) |
| Artwork | from Music | from Spotify's https address | from the song's https address |

The volume slider is the **player's** volume, not the Mac's (the Mac's stays on the volume keys and the HUD). The skip step is
5, 10, 15 or 30 seconds (Settings → Island → *Music and keyboard*, 15 by default).

**Apple Music and Spotify** announce what they play themselves (no polling); Cocaine uses their scripting (the Automation
permission) for the artwork, and, only while the Music page is on screen, once a second for the position, the favourite and
the volume.

**YouTube Music through Pear Desktop.** Pear Desktop has an **API Server** plugin (Plugins → API Server) that serves a small REST
API on this Mac, port **26538** by default. To use it:

1. In Pear Desktop turn on *Plugins → API Server* (keep its authorization strategy on the default, "Auth at first").
2. In Cocaine turn on Settings → Island → *Music and keyboard* → **YouTube Music (Pear Desktop)** (or press **Connect YouTube
   Music** on the empty Music page while Pear is open). Change the port there if you changed it in Pear.
3. Press **Connect**: Pear shows its own dialog asking to allow the client "Cocaine". Allow it. Pear answers with a token that
   Cocaine keeps in your **Keychain** (service `local.cocaine.media`); *Disconnect* forgets it.

Nothing is sent to Pear before you turn this on. Cocaine only ever talks to `127.0.0.1` (never another host, never through a
proxy, no redirects followed), with a 2-second timeout per request (the authorization request waits up to a minute for your
answer in Pear). While Pear is open and connected it asks for the current song every 3 seconds (every second while the Music
page is shown), and for the like state and volume when the song changes. If Pear says no, or its plugin doesn't answer, the
page and Settings say so (*refused*, *doesn't answer: turn on its API Server plugin and check the port*).

Pear's plugin listens on all network interfaces by default (its own setting `hostname`); that is Pear's choice, not Cocaine's.
If you don't want other devices on your network to reach it, set its hostname to `127.0.0.1` in Pear's plugin options.

**Not verified live**: Pear Desktop isn't installed on the Mac this was built on. The client follows the plugin's source code
(routes `/auth/{id}`, `/api/v1/song`, `/toggle-play`, `/next`, `/previous`, `/seek-to`, `/go-back`, `/go-forward`, `/like`,
`/like-state`, `/shuffle`, `/volume`) and is tested against a fake server (`--media-test`). Pear's app id
`com.github.th-ch.youtube-music` is how Cocaine sees it is open.

### Keyboard backlight

On Macs whose keyboard has a backlight (MacBooks), Cocaine can show and set it:

- **In the island**: the **Keyboard backlight** module (add it to any screen in Settings → Island → *Screens*) and a row at the
  top of the Monitors page, each with a switch and a slider. When Cocaine changes the level the HUD under the notch shows it.
- **In Settings** → Island → *Music and keyboard*: the level, **Turn off when idle** (never, 30 s, 1, 2 or 5 min without a key,
  click or touch; it comes back at the next input) and **Only while Cocaine keeps the Mac awake** (the idle rule applies only
  then). If you change the level yourself while it is off for idleness, Cocaine leaves your level alone. When Cocaine quits it
  turns back on what it turned off.

macOS has its own setting for this too (System Settings → Keyboard → *Turn keyboard backlight off after inactivity*); you can
use either.

How: macOS has no public API for the keyboard backlight. Cocaine loads Apple's private **CoreBrightness** framework at run time
and uses its `KeyboardBrightnessClient` (`brightnessForKeyboard:`, `setBrightness:forKeyboard:`), checking every method before
calling it. If a macOS update changes or removes it, or the Mac has no keyboard backlight, the controls simply don't appear
(Settings says *This Mac's keyboard has no backlight Cocaine can control*). Ambient-light dimming by macOS still applies: when
macOS has turned it off (bright light, lid closed) the island says so.

Verified on this Mac **read-only** (the level was read: `--media-test` prints it); writing the real backlight was not done by
any test: the tests and renders use a fake.

### Tests

`Cocaine --media-test` (in `verify.sh`): which player is shown, skip limits, the AppleScript sent to Music and Spotify, Pear's
requests, parsing, consent, token handling and loopback-only rule on a fake server, the backlight's auto-off rules on a fake
device, and the shelf's extra operations on a shelf in memory. No player, no network, no real backlight or user data.
