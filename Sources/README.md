The app's code, one file per area (compiled together with main.swift by build.sh). main.swift is only the entry point: the
command-line flags, each calling a `cli…()` function in its area file, then starting the app.
Files other than main.swift can't have top-level statements; a new flag goes in main.swift as one line that calls a function here.
Strings: add them to Localization/<lang>.lproj/<Feature>.strings (tables listed in Language.extraTables), not Localizable.strings.

Where things are:
- Core.swift: logging, the UI language and L(), running the engine, system state, haptics, Settings. Automation.swift: timer,
  Battery Guard, Smart Triggers state, power/lid readings. Power.swift: the triggers' pure logic. Shortcuts.swift: the
  customisable global shortcuts (rules, key names, Carbon registration, the recorder). Process.swift: Proc (run a program with a
  timeout), ProcessList, SafeFile (private atomic writes). Energy.swift: the pollers' pause point. Accessibility.swift: VoiceOver
  announcements and the display options (Increase Contrast…).
- Authorization.swift (the sudo rule), DimController.swift (idle dimming and the lid rule, over a display provider), Screens.swift (the real displays for it), Permissions.swift, Presence.swift (Stay active), HUD.swift
  (volume/brightness HUD and media keys), Recovery*.swift (watchdog and recovery). DisplayTests.swift: --display-test.
- Keep awake extras: AwakeTime.swift (until a time), AwakeTriggers.swift (more triggers, keep awake while…, unplug, lock pause,
  launch, clicks, icon styles: pure, behind AwakeProbe), AwakeCenter.swift (the model and the wiring AppDelegate owns),
  AwakePanel.swift (their panel rows); profiles: AwakeProfiles.swift (conditions, start/stop latch, priority: pure),
  AwakeProfileProbe.swift (the Mac's readings), AwakeProfilesPanel.swift (Profiles, Keep disks awake, statistics rows),
  AwakeProfilesCLI.swift (link, AppleScript, `cocaine profiles|disks`), DriveAlive.swift (keep disks awake), AwakeSessions.swift
  (statistics, reminder), TriggersTests.swift (--triggers-test, render fixtures; strings: Triggers.strings), Scripting.swift (the AppleScript dictionary, Cocaine.sdef), AwakeShortcuts.swift (the Mac
  Shortcuts pack), AwakeTests.swift (--awake-test). AppIntents/ is compiled only by `build.sh --app-intents` (never a release:
  docs/maintainers/app-intents.md).
- AppDelegate.swift: the app itself (menu-bar item, panel, on/off, dimming, triggers, alerts, links, phone).
- The panel: PanelModel.swift, PanelView.swift (its tabs), MenuPanel.swift (the window), Styles.swift (shared view pieces),
  Controls.swift, Tokens.swift, InAppDialog.swift and Dialogs.swift (the app's dialogs).
- The island: IslandModel.swift, IslandController.swift (one window per screen, IslandRouting, the keyboard mode), IslandView.swift,
  IslandLayout.swift (geometry, NotchGeometry.all), IslandHUD.swift (the HUD below the notch), IslandTests.swift (their tests and
  the haptics'), IslandWatchers.swift (the microphone), and one file per page with its data: IslandHome, IslandFocus (FocusTimer),
  IslandStatus (batteries; usage in Usage.swift), IslandCalendar (logic in CalendarGrid.swift, --calendar-test in CalendarTests.swift), IslandMusic, IslandMedia, IslandMirror, IslandDisplay,
  IslandFiles, IslandShelf, IslandClipboard (history in Clipboard.swift). The keyboard-only clipboard: ClipKeyboard.swift (⌃⌘V,
  the floating panel, search modes and order, the extra keys; docs/clipboard-keyboard.en.md), KeyboardTests.swift
  (--keyboard-test, also the exact session links of AgentFocus/AIEnvironments). Strings: Localization/<lang>.lproj/Keyboard.strings. Cloud links from the shelf: ShareProviders.swift (the
  provider protocol, rules, HTTP, Keychain, history, engine), ShareProviders{S3,WebDAV,SFTP}.swift, SigV4.swift, ShareUploader.swift
  (the user's command, webhooks), CloudShare.swift (the hook, confirmations, toast), CloudShareSettings.swift (Settings → Sharing),
  ShelfActionsIO.swift (action keys, chains, import/export), CloudShareTests.swift + CloudShareFakes.swift (--cloud-test).
  Strings: Localization/<lang>.lproj/Cloud.strings. The pages are drawn as modules: ScreenLayout.swift (the
  user's screens, pure rules), ScreenModules.swift (module views, the screen grid), ScreensEditor.swift (the Settings card),
  ScreensTests.swift (--screens-test, render fixtures).
- AI: AIHooks.swift (the hooks), Alerts.swift (alerts, voices, sounds per event, quiet hours, AgentPrefs), Agent*.swift (sessions,
  approvals, focus, list; AgentEvents.swift: `--agent-event`, the cards' in-memory extras). The review of a request:
  PlanReviewModel.swift (detail, diff, questions, review state, ⌘ keys), PlanReviewView.swift, PlanReviewTests.swift,
  PlanReviewFixtures.swift (render fixtures); Markdown.swift (block Markdown for plans); Quotas.swift (the statusline wrapper
  `--statusline` / `--quota-hook`, plan limits, the "quotas" module); JumpRules.swift (the user's jump rules).
  Strings: Localization/<lang>.lproj/Plans.strings.
- AI context (MCP, docs/mcp.en.md): AIContext.swift (the basket, by reference, and reading an item at request time),
  AIContextConsent.swift (settings, per-tool consent, rate limits, the content-free log), MCPProtocol.swift (JSON-RPC/MCP, both
  protocol generations, pure), MCPBridge.swift (`--mcp`: stdio ↔ the private socket), MCPServer.swift (the app's socket and what a
  call may do), AIContextWiring.swift (hooks, the notch questions), AIContextViews.swift (the "aicontext" module, Settings → AI
  card), MCPRegister.swift (connecting Claude Code, Claude Desktop, Codex, Cursor, Gemini CLI; `--mcp-register`),
  AIContextFixtures.swift (renders), MCPTests.swift (`--mcp-test`). Strings: Localization/<lang>.lproj/MCP.strings.
- SSH hosts (AI agents on remote machines; not the iPhone's "Remote"): SSHHosts.swift (the list, ~/.ssh/config names, keys,
  audit log), SSHProtocol.swift (the signed wire, remote hook → request/alert/board), SSHConnection.swift (ssh's command lines,
  the state machine, one connection), SSHManager.swift (every host, answers, relay install, hooks review/apply), SSHInstall.swift
  (the remote hooks' plan and diff, through AIHooks), SSHJump.swift (the local ssh tab), SSHHostsView.swift (Settings → AI card),
  SSHTests*.swift (--ssh-test). The remote side: relay/cocaine-relay (perl, copied into the bundle). Strings: SSH.strings.
- The phone: Phone.swift, Remote*.swift. Updates and signing: Update*.swift, Updater.swift, SigningTier.swift, DistCLI.swift.
- The notch (docs/notch-animations.en.md): NotchPower.swift (the battery HUD: ChargeEvents, the IOKit watch, the glyph),
  NotchGestures.swift (two-finger swipes), NotchSizing.swift (sizes; NotchPrefs keeps the notch's settings), NotchControls.swift
  (the "controls" module), IslandReminders.swift (EventKit reminders, the "reminders" module), NotchSettings.swift (Settings →
  Island → Notch), NotchWiring.swift (attached by IslandController), NotchTests.swift (--notch-test, --notch-fixture). Strings:
  Localization/<lang>.lproj/Notch.strings.
- Music, keyboard backlight and shelf extras (docs/music-and-backlight.en.md): MusicPlayers.swift (players' pure rules, AppleScript,
  Pear Desktop's API client), IslandMusic.swift (MusicWatch and the page), KeyboardBacklight.swift (CoreBrightness, auto-off, the
  island row and module), MediaSettings.swift (Settings → Island → Music and keyboard, MediaWiring, --media-fixture),
  ShelfMore.swift (select by kind, invert, sort, AirDrop, copy names, remove missing/all), MediaTests.swift (--media-test).
  Strings: Localization/<lang>.lproj/Media.strings.
- Motion.swift: the one motion system (tokens, roles, Reduce Motion, .pressable/.motionAppear/page slides/loading; docs/motion.en.md);
  MotionTests.swift: --motion-test (in --selftest) and --render-motion (transition contact sheets).
- Assets.swift (the baggie glyph, --render-assets), RenderTools.swift (--render-panel, --render-island), SelfTests.swift and
  *Tests.swift (the test flags; UXTests.swift: --ux-test, also part of --selftest).
- Strings of the shortcuts, keyboard and accessibility work and its fixes: Localization/<lang>.lproj/Keys.strings.
