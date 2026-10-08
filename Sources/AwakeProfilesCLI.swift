// Keep-awake profiles and kept-awake disks from outside the panel:
//  - links: `cocaine://profile?name=Office&enabled=0` (guarded like every link that changes something: the "Shortcuts app and
//    links" switch, or the user's OK), so Shortcuts' "Open URLs" can turn a profile on or off;
//  - AppleScript (Cocaine.sdef): `enable profile "Office"`, `disable profile "Office"`, `get active profile`, `get profile names`;
//  - the command line (`cocaine profiles …`, `cocaine disks`, run as `Cocaine --profiles …`): reading straight from the app's
//    settings (nothing written), and enable/disable through the same guarded link.

import AppKit

enum ProfileLink {
    /// `name` (1–40 characters, no control characters) and `enabled` (1/0, true/false, on/off, yes/no).
    static func parse(name: String?, enabled: String?) -> ControlAction? {
        guard let raw = name, let e = enabled.map({ $0.lowercased() }) else { return nil }
        let n = raw.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.count <= 40, !n.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        switch e {
        case "1", "true", "on", "yes": return .profile(name: n, enabled: true)
        case "0", "false", "off", "no": return .profile(name: n, enabled: false)
        default: return nil
        }
    }

    static func url(name: String, enabled: Bool) -> URL? {
        var c = URLComponents()
        c.scheme = "cocaine"; c.host = "profile"
        c.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "enabled", value: enabled ? "1" : "0")]
        return c.url
    }
}

enum ProfilesCLI {
    struct Output { var text = ""; var code: Int32 = 0 }

    /// The app's settings domain: its own when run from the bundle; from the engine's copy of the executable
    /// ($SUPPORT/engine/cocaine-app, used by `cocaine profiles` once the bundle is gone) there is no bundle id, and the
    /// standard domain would be the executable's name ("cocaine-app"): empty, so `cocaine profiles` said there were none.
    static func appDefaults(bundleID: String?) -> UserDefaults {
        if bundleID != nil { return .standard }
        return UserDefaults(suiteName: Installer.bundleID) ?? .standard
    }

    /// The work of `--profiles`, on a given settings domain (the app's own when run by `cocaine`, a test's in memory).
    static func run(_ args: [String], defaults d: UserDefaults, mounted: () -> [DriveVolume] = DriveAlive.mounted,
                    open: (URL) -> Bool) -> Output {
        let list = AwakeProfiles.decode(d.data(forKey: "awakeProfiles"))
        let live = Set(d.stringArray(forKey: "profilesLive") ?? [])
        let json = args.contains("--json")
        let words = args.filter { $0 != "--json" }
        func js(_ o: Any) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("[]".utf8), as: UTF8.self) + "\n"
        }
        switch words.first ?? "list" {
        case "list":
            if json {
                return Output(text: js(list.map { p -> [String: Any] in
                    ["name": p.name, "enabled": p.enabled, "active": live.contains(p.name), "action": p.action.rawValue,
                     "match": p.matchAll ? "all" : "any", "conditions": p.conditions.map { $0.kind.rawValue },
                     "display_may_sleep": p.displaySleep, "start_after_s": p.startAfter, "stop_after_s": p.stopAfter, "max_minutes": p.maxMinutes]
                }))
            }
            guard !list.isEmpty else { return Output(text: "no profiles (Cocaine → Automation → Profiles)\n") }
            let w = min(30, list.map(\.name.count).max() ?? 0)
            return Output(text: list.map { p in
                let state = !p.enabled ? "off   " : live.contains(p.name) ? "ACTIVE" : "on    "
                return "\(state)  \(p.name.padding(toLength: w, withPad: " ", startingAt: 0))  \(ProfileWords.summary(p))"
            }.joined(separator: "\n") + "\n")
        case "enable", "disable":
            guard words.count == 2 else { return Output(text: "usage: cocaine profiles enable|disable <name>\n", code: 64) }
            guard let p = AwakeProfiles.find(words[1], in: list) else { return Output(text: "cocaine profiles: no profile named \(words[1].prefix(40))\n", code: 65) }
            guard let u = ProfileLink.url(name: p.name, enabled: words[0] == "enable"), open(u) else {
                return Output(text: "cocaine profiles: Cocaine didn't take the request\n", code: 69)
            }
            return Output(text: "asked Cocaine to turn \(words[0] == "enable" ? "on" : "off") “\(p.name)” (it may ask you first)\n")
        case "disks":
            let chosen = AwakeLists.clean(d.stringArray(forKey: "driveAliveVolumes"))
            let m = mounted()
            let rows = chosen.map { n -> (String, Bool) in (n, m.contains { $0.name.caseInsensitiveCompare(n) == .orderedSame }) }
            let method = d.string(forKey: "driveAliveMethod") == "read" ? "read" : "write"
            let every = d.object(forKey: "driveAliveInterval") as? Int ?? 60
            if json {
                return Output(text: js(["method": method, "interval_s": every, "disks": rows.map { ["name": $0.0, "mounted": $0.1] }] as [String: Any]))
            }
            guard !rows.isEmpty else { return Output(text: "no disks kept awake (Cocaine → Automation → Keep disks awake)\n") }
            return Output(text: "every \(every) s, \(method == "read" ? "read only" : "tiny hidden file")\n"
                          + rows.map { "\($0.1 ? "mounted    " : "not mounted")  \($0.0)" }.joined(separator: "\n") + "\n")
        default:
            return Output(text: "usage: cocaine profiles [list [--json]|enable <name>|disable <name>] · cocaine disks [--json]\n", code: 64)
        }
    }
}

/// `Cocaine --profiles …` (from `cocaine profiles` / `cocaine disks`).
func cliProfiles() {
    let args = Array(CommandLine.arguments.dropFirst(2))
    let out = ProfilesCLI.run(args, defaults: ProfilesCLI.appDefaults(bundleID: Bundle.main.bundleIdentifier)) { url in   // read only
        Proc.run("/usr/bin/open", ["-g", url.absoluteString], timeout: 10).status == 0
    }
    if out.code == 0 { FileHandle.standardOutput.write(Data(out.text.utf8)) } else { FileHandle.standardError.write(Data(out.text.utf8)) }
    exit(out.code)
}

// MARK: - AppleScript

/// `enable profile "Office"` / `disable profile "Office"`: through the same gate as every command; answers whether the profile is on.
class ProfileScriptCommand: NSScriptCommand {
    var enable: Bool { true }

    override func performDefaultImplementation() -> Any? {
        guard let name = directParameter as? String, let action = ProfileLink.parse(name: name, enabled: enable ? "1" : "0"),
              let p = AwakeProfiles.find(name, in: AwakeModel.shared.profiles) else {
            scriptErrorNumber = ScriptError.badValue
            scriptErrorString = "No profile with that name. Get “profile names” for the list."
            return nil
        }
        _ = action
        let req = ControlRequest(action: .profile(name: p.name, enabled: enable), success: nil, failure: nil)
        var answered: Bool?, suspended = false
        func result(_ allowed: Bool) -> Any? {
            guard allowed else {
                scriptErrorNumber = ScriptError.notAllowed
                scriptErrorString = "Cocaine didn't allow this. Turn on “Shortcuts app and links” in Cocaine’s settings, or answer Allow when it asks."
                return nil
            }
            return NSNumber(value: AwakeProfiles.find(p.id, in: AwakeModel.shared.profiles)?.enabled ?? false)
        }
        ScriptingCenter.shared.perform(req) { [weak self] allowed in
            guard let self, answered == nil else { return }
            answered = allowed
            if suspended { self.resumeExecution(withResult: result(allowed)) }
        }
        if let a = answered { return result(a) }
        suspended = true
        suspendExecution()
        return nil
    }
}

@objc(CocaineEnableProfileCommand) final class EnableProfileScriptCommand: ProfileScriptCommand {}
@objc(CocaineDisableProfileCommand) final class DisableProfileScriptCommand: ProfileScriptCommand { override var enable: Bool { false } }

extension NSApplication {
    /// The profile that decides now ("" when none).
    @objc var scriptActiveProfile: String {
        let m = AwakeModel.shared
        return m.leadProfile.flatMap { id in m.profiles.first { $0.id == id }?.name } ?? ""
    }
    @objc var scriptProfileNames: [String] { AwakeModel.shared.profiles.map(\.name) }
}
