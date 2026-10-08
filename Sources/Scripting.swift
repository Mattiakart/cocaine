// AppleScript (and Shortcuts' "Run AppleScript", JXA, Keyboard Maestro, Raycast…): the dictionary in Cocaine.sdef.
//   tell application "Cocaine" to keep awake for 90
//   tell application "Cocaine" to keep awake until "18:30"
//   tell application "Cocaine" to stop keeping awake
//   tell application "Cocaine" to get {awake, awake until, remaining minutes, screen off mode, trigger active}
// Commands that change what the Mac does are guarded exactly like cocaine:// links: the "Shortcuts app and links" switch, or
// the user's OK in Cocaine's own dialog (one question at a time; after a Don't Allow scripts are refused for 10 minutes).
// Values are checked and bounded (1–1440 minutes, a time within 24 hours); nothing here touches files or runs anything.
// The caller's side: macOS asks once whether that app (Script Editor, Shortcuts…) may control Cocaine (Automation).
// Tests: --awake-test (ScriptingTests below: the commands on a fake app, the sdef loaded by Cocoa, AppleScript compiled and run
// against this very process) and --scripting-serve (a copy that answers real Apple Events on a fake state, for osascript).

import AppKit

/// What the dictionary reads.
struct ScriptStatus: Equatable {
    var on = false
    var until: Date?
    var screenOff = false
    var trigger = false
}

/// Between the commands and the app: set by AppDelegate (or a test's fake).
final class ScriptingCenter {
    static let shared = ScriptingCenter()
    /// Runs a request when it may (the links switch, or the user's OK); `done(allowed)` once, on the main thread.
    var perform: (ControlRequest, @escaping (Bool) -> Void) -> Void = { _, done in done(false) }
    var status: () -> ScriptStatus = { ScriptStatus() }
    /// What the commands report after a change: the target state, not the old one (the engine applies it in the background).
    var target: () -> Bool? = { nil }
}

enum ScriptError {
    static let notAllowed = -1743          // errAEEventNotPermitted: the user said no (or the switch is off and nobody answered)
    static let badValue = -1703            // errAEWrongDataType / out of range, with a message
}

/// A bad value, with the message the script gets.
struct ScriptFailure: Error, Equatable, ExpressibleByStringLiteral {
    let message: String
    init(stringLiteral s: String) { message = s }
}

/// The checks every command shares.
enum ScriptArgs {
    /// `for` minutes and `until` (a date or a text) → the request, or the message for a bad value.
    static func keepAwake(minutes: Any?, until: Any?, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Result<ControlRequest, ScriptFailure> {
        if minutes != nil && until != nil { return .failure("Give either “for” minutes or “until” a time, not both.") }
        if let m = minutes {
            guard let n = (m as? NSNumber)?.doubleValue, n == n.rounded(), ControlURL.minutes.contains(Int(n)) else {
                return .failure("“for” takes whole minutes, 1 to 1440.")
            }
            return .success(ControlRequest(action: .on(minutes: Int(n)), success: nil, failure: nil))
        }
        if let u = until {
            var d: Date?
            if let date = u as? Date { d = date > now && date.timeIntervalSince(now) <= UntilTime.maxAhead ? date : nil }
            else if let s = u as? String { d = UntilTime.parse(s, now: now, calendar: calendar) }
            guard let d else { return .failure("“until” takes a time within the next 24 hours: a date, or text like \"18:30\".") }
            return .success(ControlRequest(action: .on(minutes: nil), success: nil, failure: nil, until: d))
        }
        return .success(ControlRequest(action: .on(minutes: 0), success: nil, failure: nil))   // until stopped (0 = no timer)
    }
}

/// The shared run: guarded through ScriptingCenter.perform, suspended until the user answers, then the new state.
class CocaineScriptCommand: NSScriptCommand {
    func request() -> Result<ControlRequest, ScriptFailure> { .failure("") }

    override func performDefaultImplementation() -> Any? {
        let req: ControlRequest
        switch request() {
        case .success(let r): req = r
        case .failure(let f):
            scriptErrorNumber = ScriptError.badValue
            scriptErrorString = f.message
            return nil
        }
        let center = ScriptingCenter.shared
        var answered: Bool?, suspended = false
        func result(_ allowed: Bool) -> Any? {
            guard allowed else {
                scriptErrorNumber = ScriptError.notAllowed
                scriptErrorString = "Cocaine didn't allow this. Turn on “Shortcuts app and links” in Cocaine’s settings, or answer Allow when it asks."
                return nil
            }
            return NSNumber(value: center.target() ?? center.status().on)
        }
        center.perform(req) { [weak self] allowed in
            guard let self, answered == nil else { return }      // once
            answered = allowed
            if suspended { self.resumeExecution(withResult: result(allowed)) }
        }
        if let a = answered { return result(a) }                 // allowed by the switch (or refused at once): no waiting
        suspended = true                                         // the user is being asked: the script waits for the answer
        suspendExecution()
        return nil
    }
}

@objc(CocaineKeepAwakeCommand) final class KeepAwakeScriptCommand: CocaineScriptCommand {
    override func request() -> Result<ControlRequest, ScriptFailure> {
        let a = evaluatedArguments ?? [:]
        return ScriptArgs.keepAwake(minutes: a["minutes"], until: a["until"])
    }
}

@objc(CocaineStopAwakeCommand) final class StopAwakeScriptCommand: CocaineScriptCommand {
    override func request() -> Result<ControlRequest, ScriptFailure> { .success(ControlRequest(action: .off, success: nil, failure: nil)) }
}

@objc(CocaineToggleAwakeCommand) final class ToggleAwakeScriptCommand: CocaineScriptCommand {
    override func request() -> Result<ControlRequest, ScriptFailure> { .success(ControlRequest(action: .toggle, success: nil, failure: nil)) }
}

/// The read-only properties of `application` in Cocaine.sdef (Cocoa scripting reads them by key from NSApp).
extension NSApplication {
    @objc var scriptAwake: NSNumber { NSNumber(value: ScriptingCenter.shared.status().on) }
    @objc var scriptUntil: NSDate? {
        let s = ScriptingCenter.shared.status()
        guard s.on, let u = s.until, u > Date() else { return nil }
        return u as NSDate
    }
    @objc var scriptRemaining: NSNumber {
        let s = ScriptingCenter.shared.status()
        guard s.on, let u = s.until else { return 0 }
        return NSNumber(value: UntilTime.minutesLeft(u, now: Date()))
    }
    @objc var scriptScreenOff: NSNumber { NSNumber(value: ScriptingCenter.shared.status().screenOff) }
    @objc var scriptTrigger: NSNumber { NSNumber(value: ScriptingCenter.shared.status().trigger) }
}

enum ScriptingDialog {
    /// Asked when a script wants to change something and the switch is off. Don't Allow is the default.
    static func spec(_ req: ControlRequest) -> DialogSpec {
        DialogSpec(icon: "applescript", title: L("Allow scripts to control Cocaine?"),
                   message: String(format: L("A script (AppleScript, a Shortcut or another app) asked to %@. If it wasn't you, choose Don't Allow. You can change this in Automation → Shortcuts."),
                                   describe(req)),
                   buttons: [DialogButton(id: "allow", title: L("Allow")), DialogButton(id: "deny", title: L("Don't Allow"), role: .cancel)],
                   safeDefault: true)
    }

    static func describe(_ r: ControlRequest) -> String {
        switch r.action {
        case .off: return L("turn Cocaine off")
        case .toggle: return L("turn Cocaine on or off")
        case .on(let m):
            if let u = r.until { return String(format: L("keep the Mac awake until %@"), PanelView.timeString(u)) }
            if let m, m > 0 { return String(format: L("keep the Mac awake for %@"), Dur.short(minutes: m)) }
            return L("keep the Mac awake")
        case .profile(let name, let enabled):
            return String(format: enabled ? L("turn on the profile “%@”") : L("turn off the profile “%@”"), name)
        default: return L("control Cocaine")
        }
    }
}

// MARK: - --scripting-serve: a copy that answers real Apple Events on a fake state

/// `Cocaine --scripting-serve <seconds>`: runs as an app (so Cocoa installs its scripting handlers) but starts nothing of Cocaine:
/// no engine, no menu-bar item, no island, no single-instance takeover (the Cocaine you use is never touched), settings in
/// memory. Every command is allowed and changes only an in-memory state, printed as `state on=… until=…` lines. Quits after
/// the given seconds (at most 300). For osascript against an isolated copy (docs/scripting.en.md, "Testing").
final class ScriptingServe: NSObject, NSApplicationDelegate {
    private var state = ScriptStatus()
    private let seconds: Double

    init(seconds: Double) { self.seconds = seconds }

    func applicationDidFinishLaunching(_ n: Notification) {
        let c = ScriptingCenter.shared
        c.status = { [unowned self] in self.state }
        c.target = { [unowned self] in self.state.on }
        c.perform = { [unowned self] req, done in
            switch req.action {
            case .on(let m):
                self.state.on = true
                self.state.until = req.until ?? (m ?? 0 > 0 ? Date().addingTimeInterval(Double(m!) * 60) : nil)
            case .off: self.state = ScriptStatus()
            case .toggle: self.state.on.toggle(); if !self.state.on { self.state.until = nil }
            default: break
            }
            print("state on=\(self.state.on) until=\(self.state.until.map { Int($0.timeIntervalSince1970) }.map(String.init) ?? "-")")
            fflush(stdout)
            done(true)
        }
        print("serving \(Bundle.main.bundleIdentifier ?? "?") pid \(getpid())")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
    }
}

func cliScriptingServe() {
    let secs = min(300, max(1, Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "60") ?? 60))
    let app = NSApplication.shared
    let d = ScriptingServe(seconds: secs)
    app.delegate = d
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

// MARK: - Tests (part of --awake-test)

enum ScriptingTests {
    static func run(_ check: (String, Bool) -> Void) {
        let noon = Date(timeIntervalSince1970: 1791367200), cal = AwakeTests.rome
        func ka(_ m: Any?, _ u: Any?) -> ControlRequest? { try? ScriptArgs.keepAwake(minutes: m, until: u, now: noon, calendar: cal).get() }
        check("script: keep awake (no value) = until stopped", ka(nil, nil)?.action == .on(minutes: 0) && ka(nil, nil)?.until == nil)
        check("script: keep awake for 90", ka(NSNumber(value: 90), nil)?.action == .on(minutes: 90))
        check("script: for 0, 1441, 1.5, -3 or text are refused", [NSNumber(value: 0), NSNumber(value: 1441), NSNumber(value: 1.5), NSNumber(value: -3)].allSatisfy { ka($0, nil) == nil }
              && ka("90", nil) == nil)
        check("script: until \"18:30\" (text)", ka(nil, "18:30")?.until?.timeIntervalSince1970 == 1791390600)
        check("script: until a date within 24 h", ka(nil, noon.addingTimeInterval(3600))?.until == noon.addingTimeInterval(3600))
        check("script: until a past date, or more than 24 h away, refused", ka(nil, noon.addingTimeInterval(-60)) == nil && ka(nil, noon.addingTimeInterval(86401)) == nil)
        check("script: for and until together refused", ka(NSNumber(value: 5), "18:30") == nil)
        check("script: the dialog says what was asked, and defaults to Don't Allow",
              DialogLogic.defaultButton(ScriptingDialog.spec(ControlRequest(action: .off, success: nil, failure: nil))) == "deny"
              && ScriptingDialog.describe(ControlRequest(action: .on(minutes: 90), success: nil, failure: nil)).contains(Dur.short(minutes: 90)))

        // The dictionary as Cocoa loads it from the bundle (Info.plist OSAScriptingDefinition → Contents/Resources/Cocaine.sdef).
        let reg = NSScriptSuiteRegistry.shared()
        func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 + FourCharCode($1) } }
        let keep = reg.commandDescription(withAppleEventClass: code("CcAw"), andAppleEventCode: code("KAwk"))
        let stop = reg.commandDescription(withAppleEventClass: code("CcAw"), andAppleEventCode: code("Stop"))
        let toggle = reg.commandDescription(withAppleEventClass: code("CcAw"), andAppleEventCode: code("Tggl"))
        let inBundle = Bundle.main.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String == "Cocaine.sdef"
            && Bundle.main.object(forInfoDictionaryKey: "NSAppleScriptEnabled") as? Bool == true
        if !inBundle {
            check("script: run from the app bundle (Info.plist names Cocaine.sdef)", false)
            return
        }
        check("script: Info.plist enables scripting with Cocaine.sdef, which is in the bundle",
              Bundle.main.url(forResource: "Cocaine", withExtension: "sdef") != nil)
        check("script: Cocoa loads the three commands with our classes",
              keep?.commandClassName == "CocaineKeepAwakeCommand" && stop?.commandClassName == "CocaineStopAwakeCommand"
              && toggle?.commandClassName == "CocaineToggleAwakeCommand")
        check("script: keep awake's parameters are minutes and until", Set(keep?.argumentNames ?? []) == ["minutes", "until"])
        let app = reg.classDescription(withAppleEventCode: code("capp"))
        check("script: the application has the five read-only properties",
              ["scriptAwake", "scriptUntil", "scriptRemaining", "scriptScreenOff", "scriptTrigger"].allSatisfy {
                  app?.appleEventCode(forKey: $0) != nil })

        // The commands on a fake app: the gate is what decides.
        let c = ScriptingCenter.shared
        let saved = (c.perform, c.status, c.target)
        defer { (c.perform, c.status, c.target) = saved }
        var asked: [ControlRequest] = [], allow = true, state = ScriptStatus()
        c.status = { state }
        c.target = { state.on }
        c.perform = { req, done in
            asked.append(req)
            if allow { if case .off = req.action { state.on = false } else { state.on = true } }
            done(allow)
        }
        func run(_ d: NSScriptCommandDescription?, _ args: [String: Any] = [:]) -> (Any?, Int) {
            guard let cmd = d?.createCommandInstance() else { return (nil, 99) }
            cmd.arguments = args
            let r = cmd.execute()
            return (r, cmd.scriptErrorNumber)
        }
        let r1 = run(keep, ["minutes": NSNumber(value: 30)])
        check("script: keep awake for 30 runs through the gate and answers true", asked.last?.action == .on(minutes: 30) && (r1.0 as? NSNumber)?.boolValue == true && r1.1 == 0)
        let r2 = run(keep, ["minutes": NSNumber(value: 5000)])
        check("script: for 5000 is refused before the gate, with an error", asked.count == 1 && r2.1 == ScriptError.badValue)
        allow = false
        let r3 = run(stop)
        check("script: refused by the user: error -1743 and nothing changed", asked.count == 2 && r3.1 == ScriptError.notAllowed && state.on)
        allow = true
        let r4 = run(stop)
        check("script: stop keeping awake answers false", (r4.0 as? NSNumber)?.boolValue == false && r4.1 == 0)
        _ = run(toggle)
        check("script: toggle asks for toggle", asked.last?.action == .toggle)
        state = ScriptStatus(on: true, until: Date().addingTimeInterval(600), screenOff: true, trigger: false)
        check("script: properties read the state", NSApplication.shared.scriptAwake.boolValue && NSApplication.shared.scriptRemaining.intValue == 10 && NSApplication.shared.scriptScreenOff.boolValue
              && !NSApplication.shared.scriptTrigger.boolValue && NSApplication.shared.scriptUntil != nil)
        state.on = false
        check("script: off: no deadline, 0 minutes", NSApplication.shared.scriptUntil == nil && NSApplication.shared.scriptRemaining.intValue == 0)
    }

    /// Real AppleScript, compiled with the dictionary and sent to this process (needs the app running: --scripting-selftest).
    static func appleScript(_ check: (String, Bool) -> Void, bundleID: String) {
        let c = ScriptingCenter.shared
        var state = ScriptStatus()
        var asked: [ControlRequest] = []
        c.status = { state }
        c.target = { state.on }
        c.perform = { req, done in
            asked.append(req)
            switch req.action {
            case .off: state = ScriptStatus()
            case .on(let m): state.on = true; state.until = req.until ?? ((m ?? 0) > 0 ? Date().addingTimeInterval(Double(m!) * 60) : nil)
            default: state.on.toggle()
            }
            done(true)
        }
        func run(_ body: String) -> (NSAppleEventDescriptor?, Int) {
            var err: NSDictionary?
            let s = NSAppleScript(source: "tell application id \"\(bundleID)\"\n\(body)\nend tell")
            let r = s?.executeAndReturnError(&err)
            return (r, (err?[NSAppleScript.errorNumber] as? Int) ?? 0)
        }
        let a = run("keep awake for 45")
        check("applescript: keep awake for 45 compiles and runs", a.1 == 0 && a.0?.booleanValue == true && asked.last?.action == .on(minutes: 45))
        let b = run("keep awake until \"23:59\"")
        check("applescript: keep awake until \"23:59\"", b.1 == 0 && asked.last?.until != nil)
        let p = run("get {awake, remaining minutes, screen off mode, trigger active}")
        check("applescript: the properties read back", p.1 == 0 && p.0?.numberOfItems == 4 && p.0?.atIndex(1)?.booleanValue == true)
        let u = run("get awake until")
        check("applescript: awake until is a date", u.1 == 0 && u.0?.dateValue != nil)
        let bad = run("keep awake for 99999")
        check("applescript: a bad value is an AppleScript error, nothing changed", bad.1 == ScriptError.badValue && asked.count == 2)
        let s = run("stop keeping awake")
        check("applescript: stop keeping awake → false", s.1 == 0 && s.0?.booleanValue == false)
        let t = run("toggle")
        check("applescript: toggle → true", t.1 == 0 && t.0?.booleanValue == true)
        let none = run("get awake until")
        check("applescript: no timer: missing value", none.1 == 0 && none.0?.descriptorType == typeType)
    }
}

/// `--scripting-selftest`: an app run (so Cocoa installs its Apple Event handlers) that sends real AppleScript to itself, then
/// quits. Like --scripting-serve it starts nothing of Cocaine.
final class ScriptingSelfTest: NSObject, NSApplicationDelegate {
    var failed = 0
    func applicationDidFinishLaunching(_ n: Notification) {
        DispatchQueue.main.async {
            ScriptingTests.appleScript({ name, ok in print((ok ? "PASS" : "FAIL") + "  awake: " + name); if !ok { self.failed += 1 } },
                                       bundleID: Bundle.main.bundleIdentifier ?? "")
            print(self.failed == 0 ? "scripting: all passed" : "scripting: \(self.failed) failed")
            exit(self.failed == 0 ? 0 : 1)
        }
    }
}

func cliScriptingSelfTest() {
    let app = NSApplication.shared
    let d = ScriptingSelfTest()
    app.delegate = d
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("FAIL  awake: applescript timed out"); exit(1) }
    app.run()
    exit(1)
}
