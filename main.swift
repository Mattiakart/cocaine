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

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--agent-request" { cliAgentRequest() }
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
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--ai-alerts" { cliAIAlerts() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--permissions" { cliPermissions() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--camera-test" { cliCameraTest() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--presence-test" { cliPresenceTest() }
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--clipboard-test" {
    exit(ClipboardTests.run() == 0 ? 0 : 1)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--island-selfcheck" { cliIslandSelfcheck() }
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-island" { cliRenderIsland() }
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-panel" { cliRenderPanel() }
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-demo-gif" {
    Assets.renderDemoGIF(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-assets" {
    Assets.render(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
// The app itself never takes the test overrides (COCAINE_SUDO, COCAINE_PMSET, COCAINE_SUPPORT…): set with `launchctl setenv`
// they would have Cocaine, its engine and its watchdog run another program with Cocaine's permissions, or use other folders.
TestOverrides.scrub()
// One Cocaine at a time (another may still be quitting, e.g. during an update): this one leaves without touching anything.
guard Recovery.claimSingleInstance() else { exit(0) }
let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
