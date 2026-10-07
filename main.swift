// Cocaine — menu-bar front end for ~/bin/cocaine.
//
// Shows whether Cocaine is on (full baggie) or off (empty baggie) in the menu bar; clicking it opens a
// panel that stays open while you change things. It toggles Cocaine through the engine script bundled in
// Contents/Resources/cocaine, which owns the caffeinate -d display hold; the first time it needs to, the app
// asks for an admin password once to install a narrow sudo rule for `pmset -a disablesleep 1|0`. While Cocaine is
// on it restarts that display hold if it is missing (e.g. after a restart) and, after the chosen
// idle time, lowers the built-in display to the chosen minimum brightness (never below 1%, so the
// screen never goes off), restoring the previous brightness on the next keyboard/trackpad input.
// `cocaine://alert` URLs (from AI agents' hooks, which the "AI alerts" switch adds to Claude Code and Codex) wake and
// flash the screens when you're away.
//
// This file is only the entry point: the command-line flags (each runs a function in its area file) and starting the app.
// Everything else lives in Sources/, one file per area (see Sources/README.md).

import AppKit

// MARK: - Entry point

// Test and render flags get memory-only settings before anything reads one: they never write the app's real domain.
AppDefaults.isolateIfTestFlag(CommandLine.arguments)
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--agent-request" { cliAgentRequest() }
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--agent-event" { cliAgentEvent() }       // Sources/AgentEvents.swift
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--statusline" { cliStatusLine() }        // Sources/Quotas.swift
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--quota-hook" { cliQuotaHook() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--agents-test" { cliAgentsTest() }
if let code = RecoveryCLI.run(CommandLine.arguments) { exit(code) }   // --recover-after, --prepare-update, … (Sources/Recovery.swift)
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--recovery-test" { exit(RecoveryTest.run()) }
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--recovery-owner" { RecoveryTest.owner(Array(CommandLine.arguments.dropFirst(2))) }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--instance-check" {   // would a launch now give way? 1 = yes
    exit(Recovery.claimSingleInstance(wait: 1) ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--recovery-standin" { while true { sleep(600) } }   // the test's OSDUIHelper
if let status = DistCLI.run(CommandLine.arguments) { exit(status) }   // release tooling and updater/signature tests
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--auth-selftest" { cliAuthSelftest() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--layout-test" { cliLayoutTest() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--gamma-test" { cliGammaTest() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--auth-preview" { cliAuthPreview() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--remove-rule" { cliRemoveRule() }
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--share-test" { cliShareTest() }
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--make-shortcut" { cliMakeShortcut() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--relay-test" { cliRelayTest() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--remote-test" { cliRemoteTest() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--selftest" { cliSelfTest() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--display-test" { cliDisplayTest() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--dialogs-test" { cliDialogsTest() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--ux-test" { cliUXTest() }
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--ai-alerts" { cliAIAlerts() }
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--ai-environments" { cliAIEnvironments() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--permissions" { cliPermissions() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--camera-test" { cliCameraTest() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--presence-test" { cliPresenceTest() }
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--clip" { cliClip() }   // `cocaine clip …` (Sources/ClipboardCLI.swift)
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--clipboard-test" {
    exit(ClipboardTests.run() == 0 ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--clipsync-test" { exit(ClipSyncTests.run() == 0 ? 0 : 1) }   // Sources/ClipSyncTests.swift
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--island-selfcheck" { cliIslandSelfcheck() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--awake-test" { exit(AwakeTests.run() == 0 ? 0 : 1) }   // Sources/AwakeTests.swift
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--scripting-selftest" { cliScriptingSelfTest() }        // Sources/Scripting.swift
if CommandLine.arguments.count <= 3, CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--scripting-serve" { cliScriptingServe() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--calendar-test" { exit(CalendarTests.run() == 0 ? 0 : 1) }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--screens-test" { cliScreensTest() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--shelf-test" { exit(ShelfTests.run() == 0 ? 0 : 1) }
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--shelf" { exit(ShelfCLI.run(Array(CommandLine.arguments.dropFirst(2)))) }   // cocaine shelf …
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-island" { cliRenderIsland() }
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-panel" { cliRenderPanel() }
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-motion" { cliRenderMotion() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--motion-test" { cliMotionTest() }
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-demo-gif" {
    Assets.renderDemoGIF(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-assets" {
    Assets.render(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1].hasPrefix("--") {    // a mistyped flag must not start the app
    FileHandle.standardError.write(Data("Cocaine: unknown option \(CommandLine.arguments[1])\n".utf8))
    exit(64)
}
// The app itself never takes the test overrides (COCAINE_SUDO, COCAINE_PMSET, COCAINE_SUPPORT…): set with `launchctl setenv`
// they would have Cocaine, its engine and its watchdog run another program with Cocaine's permissions, or use other folders.
TestOverrides.scrub()
EarlyQuit.install()          // a SIGTERM while starting becomes a normal quit once the app runs (Sources/Recovery.swift)
// One Cocaine at a time (another may still be quitting, e.g. during an update). A running one is asked to show its panel; one
// left from a deleted copy of the app is ended and this one starts (Recovery.claimSingleInstance).
guard Recovery.claimSingleInstance(takeOver: true) else { exit(0) }
let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
