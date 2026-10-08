# Settings search

Cocaine has many settings. The field at the top of the Settings panel finds any of them from what you type, in your own
words, in any of the app's languages, and takes you there.

## Using it

- Click the field, press **⌘F**, or just start typing a letter anywhere in the panel.
- Type anything: a setting's name or part of it (`lang`), a word it is about (`brightness`, `wifi`, `password`), a word in
  another language (`luminosità`, `Helligkeit`, `明るさ`, `剪贴板`), or a typo (`clipbaord`, `batery`).
- **↑ ↓** move through the results, **Return** opens the highlighted one, **Esc** clears the query (a second Esc closes the
  panel). A click opens a result too; picking a tab while searching goes to that tab.
- Opening a result switches to its tab, scrolls to its row (or to its card) and lights it up for about two seconds.
- Each result shows where it is (*Automation › Smart Triggers*) and, when it matched through a related word, which one
  (*≈ luminosità tastiera*).
- Island settings can be found while the island is off: the result says to turn on *Show in the notch* first, and opening it
  goes to that switch.

## How it matches

Everything runs on the Mac; nothing is sent anywhere and no model is called.

1. **The index** (`Sources/SettingsIndex.swift`): every setting of the panel with its tab, card and row, its description, and
   the *concepts* it is about. Names are the panel's own strings, so each setting is searchable by its name in all 8
   languages at once (the app's current language weighs a little more).
2. **Concepts** (`Localization/<lang>.lproj/SearchIndex.strings`): for about 60 subjects (brightness, charger, clipboard,
   privacy, AI agents…) the words people use for them, in every language: synonyms, related words, brand names
   (`teams`, `spotify`, `claude`), common ways of saying it (`start at login`, `avvio automatico`).
3. **Folding**: case, accents, full-width characters and separators don't matter (`Wi‑Fi` = `wifi`, `luminosita` =
   `luminosità`). Common filler words (`the`, `di`, `der`…) are ignored.
4. **Matching each word**: exact word, then prefix (`upd` → *Updates*), then a part of a word, then typos (one for words of 4–6
   letters, two from 7; a swapped pair counts once), also against the start of a longer word. Chinese and Japanese are
   matched inside their phrases.
5. **Related words** (optional): for a word that matches nothing well, macOS's on-device word embeddings (NaturalLanguage, for
   English, Italian, Spanish, French and German where installed) suggest neighbours and the word's dictionary form; they count
   for half. Where macOS has no embedding the search works the same without them.
6. **Ranking**: every word of the query must match (with three words or more, one may miss); a setting's own name counts most,
   then its concepts, its card, its description. A name that starts with what you typed comes first. Results far below the
   best one are left out.

## Adding a setting

Add one line to its card in `Sources/SettingsIndex.swift` (the row's title key as the panel shows it, its description key,
its concepts). `--ui-test` fails until every row and card the panel draws is indexed, every key is translated and every
concept has words in all 8 languages. New concepts go in `SearchIndex.strings` in all 8 languages.

## Tests

`--ui-test` (in `verify.sh`): folding, typo distance, ~40 queries in 8 languages that must find their setting near the top,
nonsense finding nothing, speed (each query well under 25 ms), the related-words layer through a stub and its graceful
fallback, the index's coverage of every tab in 4 languages. Pictures: `--render-panel out.png --search "luminosità"`,
`--lit "Smart Triggers|Power"` (a lit row).
