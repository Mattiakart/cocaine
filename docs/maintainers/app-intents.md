# Native Shortcuts actions (App Intents): ready, off, and why

Lungo has exactly two native Shortcuts actions: *Get Enabled State* (returns a Bool) and *Set Enabled State* (Action Turn/Toggle, Is
Enabled, Duration Indefinitely / Default Duration / Custom). Cocaine has the same two, written and building, **behind a build flag that
is off by default and never used for releases**. What ships instead: the AppleScript dictionary and the Mac Shortcuts pack
([scripting.en.md](../scripting.en.md)).

## What is in the tree

- `Sources/AppIntents/CocaineIntents.swift`, compiled only with `-D COCAINE_APP_INTENTS` (build.sh compiles `Sources/*.swift`, not
  the subfolder, unless asked): `GetEnabledStateIntent` (returns Bool), `SetEnabledStateIntent` (`shouldToggle` "Action" Turn/Toggle,
  `isEnabled`, `durationType` Indefinitely/Default Duration/Custom, `minutes` 1–1440), `CocaineDurationType` (an `AppEnum`). Plain
  protocol conformances, literal titles, no macros (the Command Line Tools have no `AppIntentsMacros`). Both go through the same gate
  as links and AppleScript (`ScriptingCenter`).
- `tools/appintents-protocols.json`: the protocols whose conformers the compiler describes (rules_swift's list).
- `tools/gen-appintents-metadata.py`: `generate` turns the compiler's const values (`swiftc -Xfrontend -emit-const-values-path`)
  into `Contents/Resources/Metadata.appintents/{extract.actionsdata, version.json}` (format 3.0, plain JSON, as Xcode's
  `appintentsmetadataprocessor` writes it, which only ships inside Xcode); `check` validates both files against that schema and, given
  the binary, that every `mangledTypeName` has its type descriptor (`$s…Mn`) in every slice.
- `./build.sh --no-install --app-intents`: compiles with the flag (`-module-name Cocaine`: the mangled names contain it), runs the
  const-values pass, generates and checks the metadata, copies it into the bundle before signing. It refuses `--dmg`/`--release` and
  installing.
- `verify.sh` (every run): the intents compile with the flag, the metadata is generated and checked in a temporary folder. Nothing is
  installed, registered with Launch Services or shown to Shortcuts.

## The blocker: a Team ID

Shortcuts lists App Intents of any app it finds, but `linkd` (the daemon that runs them) only runs actions of an app whose signature
has a **Team ID**. Reported for an app built exactly like this one (swiftc + generated metadata, macOS 27.2): ad hoc or self-signed,
the action shows up and fails after about 30 seconds (`LinkDaemon.ProcessRegistry.Errors`; `linkd` logs that it can't get the team
ID); signed with an *Apple Development* certificate it runs (github.com/vorssaint/vorssaint-utils/issues/2476). Cocaine is signed with
"Cocaine Local Signing" (`codesign -dv` shows `TeamIdentifier=not set`). A self-signed certificate can't carry a Team ID (codesign
takes it only from Apple-issued certificates; faking one would be spoofing, and isn't attempted). So with today's signing, shipping
these actions would give users actions that appear and then fail: worse than none.

## The decision (the user's)

1. **Free Apple ID "Personal Team"**: Xcode (installed once) → Settings → Accounts → add your Apple ID → it creates an *Apple
   Development* certificate with a Team ID. Free; names you; renewed about yearly; meant for your own Macs. Unknown: whether `linkd`
   accepts it for copies installed on *other* people's Macs (the Homebrew tap). Good for your Mac; doubtful for distribution.
2. **Paid Apple Developer Program** (99 USD/year): a *Developer ID Application* certificate (Team ID, notarization). build.sh already
   has `--sign developer-id` and `--notarize`. Then the flag could become the default for releases.
3. **Neither** (today): AppleScript + the Mac Shortcuts pack cover the same ground (set state with a duration, get state as a value)
   without a Team ID.

## The 5-minute experiment (by you, on your Mac; nothing here does it for you)

To see the blocker yourself before deciding, with a throwaway copy that can't be confused with Cocaine:

```sh
./build.sh --no-install --app-intents --sign local
cp -R build.noindex/Cocaine.app ~/Applications/CocaineIntentsTest.app
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.cocaine.intents-test" ~/Applications/CocaineIntentsTest.app/Contents/Info.plist
codesign --force --deep -s - ~/Applications/CocaineIntentsTest.app      # or your Apple Development identity, to compare
open ~/Applications/CocaineIntentsTest.app                                # quit the real Cocaine first: one Cocaine at a time
```

Open Shortcuts, search "Cocaine": *Get Cocaine State* and *Set Cocaine State* should be listed. Run *Get Cocaine State*: with the ad
hoc / local signature it is expected to fail after ~30 s; signed with an Apple Development identity it should return true/false.
Watch `log stream --predicate 'process == "linkd"'` meanwhile. Then clean up:

```sh
osascript -e 'quit app id "local.cocaine.intents-test"'
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -u ~/Applications/CocaineIntentsTest.app
rm -rf ~/Applications/CocaineIntentsTest.app
defaults delete local.cocaine.intents-test 2>/dev/null
```

## What is verified and what isn't

- Verified on this Mac (Command Line Tools, Swift 6.4, macOS 27): the intents compile without Xcode; the compiler emits their const
  values; the generator writes metadata that passes the schema check, with every mangled name present in both slices of the binary.
- Not verified (on purpose, nothing was registered): that Shortcuts lists these actions, that the generated `extract.actionsdata` is
  complete enough for it (it covers the keys seen in Lungo's and Apple's own bundles, not every key Xcode writes), and the Team-ID
  failure itself. The format is private and could change in a future macOS.
