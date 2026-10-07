The app's code, one file per area (compiled together with main.swift by build.sh). main.swift is only the entry point: the
command-line flags, each calling a `cli…()` function in its area file, then starting the app.
Files other than main.swift can't have top-level statements; a new flag goes in main.swift as one line that calls a function here.
Strings: add them to Localization/<lang>.lproj/<Feature>.strings (tables listed in Language.extraTables), not Localizable.strings.

Where things are:
- Core.swift: logging, the UI language and L(), running the engine, system state, haptics, Settings. Automation.swift: timer,
  Battery Guard, Smart Triggers state, power/lid readings, hotkeys. Power.swift: the triggers' pure logic.
- Authorization.swift (the sudo rule), DimController.swift (idle dimming and the lid rule, over a display provider),
  Screens.swift (the real displays for it), Permissions.swift, Presence.swift (Stay active), HUD.swift
  (volume/brightness HUD and media keys), Recovery*.swift (watchdog and recovery). DisplayTests.swift: --display-test.
- AppDelegate.swift: the app itself (menu-bar item, panel, on/off, dimming, triggers, alerts, links, phone).
- The panel: PanelModel.swift, PanelView.swift (its tabs), MenuPanel.swift (the window), Styles.swift (shared view pieces),
  Controls.swift, Tokens.swift, InAppDialog.swift and Dialogs.swift (the app's dialogs).
- The island: IslandModel.swift, IslandController.swift (the window), IslandView.swift, IslandLayout.swift (geometry),
  IslandWatchers.swift (live data), and one file per page: IslandHome, IslandFocus, IslandStatus, IslandCalendar, IslandMusic,
  IslandMedia, IslandMirror, IslandDisplay, IslandFiles, IslandShelf, IslandClipboard (history in Clipboard.swift).
- AI: AIHooks.swift (the hooks), Alerts.swift (alerts, voices), Agent*.swift (sessions, approvals, focus, list).
- The phone: Phone.swift, Remote*.swift. Updates and signing: Update*.swift, Updater.swift, SigningTier.swift, DistCLI.swift.
- Assets.swift (the baggie glyph, --render-assets), RenderTools.swift (--render-panel, --render-island), SelfTests.swift and
  *Tests.swift (the test flags).
