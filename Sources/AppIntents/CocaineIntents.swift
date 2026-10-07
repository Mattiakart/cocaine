// Native Shortcuts actions (App Intents), like Lungo's two: "Get Enabled State" and "Set Enabled State". BUILT ONLY with
// `./build.sh --app-intents` (the COCAINE_APP_INTENTS flag) and NEVER shipped in a release: Shortcuts lists App Intents of
// any app, but runs them only for an app signed with an Apple-issued identity that has a Team ID, and Cocaine is signed with
// its local identity (no Team ID). See docs/maintainers/app-intents.md for the blocker, the user decision and the experiment.
// No macros (the Command Line Tools have no AppIntentsMacros), only literal titles (the metadata generator reads them from
// the compiler's const values: tools/gen-appintents-metadata.py). Both actions go through the same gate as cocaine:// links
// and AppleScript (ScriptingCenter, Sources/Scripting.swift).

#if COCAINE_APP_INTENTS
import AppIntents
import Foundation

@available(macOS 13.0, *)
enum CocaineDurationType: String, AppEnum {
    case indefinitely, defaultDuration, custom

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Duration"
    static var caseDisplayRepresentations: [CocaineDurationType: DisplayRepresentation] = [
        .indefinitely: "Indefinitely",
        .defaultDuration: "Default Duration",
        .custom: "Custom",
    ]
}

/// Returns whether Cocaine is keeping the Mac awake.
@available(macOS 13.0, *)
struct GetEnabledStateIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Cocaine State"
    static var description = IntentDescription("Returns whether Cocaine is keeping the Mac awake.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: ScriptingCenter.shared.status().on)
    }
}

/// Turns Cocaine on or off (or toggles it), for a duration: indefinitely, the panel's default timer, or custom minutes.
@available(macOS 13.0, *)
struct SetEnabledStateIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Cocaine State"
    static var description = IntentDescription("Turns Cocaine on or off, or toggles it.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Action", default: false, displayName: Bool.IntentDisplayName(true: "Toggle", false: "Turn"))
    var shouldToggle: Bool

    @Parameter(title: "Is Enabled", default: true)
    var isEnabled: Bool

    @Parameter(title: "Duration", default: .indefinitely)
    var durationType: CocaineDurationType

    @Parameter(title: "Custom Duration (in minutes)", inclusiveRange: (1, 1440))
    var minutes: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$shouldToggle) Cocaine \(\.$isEnabled)") {
            \.$durationType
            \.$minutes
        }
    }

    /// The same request a cocaine:// link or AppleScript would make (pure: tested by --awake-test when built with the flag).
    static func request(toggle: Bool, enabled: Bool, duration: CocaineDurationType, minutes: Int?) -> ControlRequest? {
        if toggle { return ControlRequest(action: .toggle, success: nil, failure: nil) }
        guard enabled else { return ControlRequest(action: .off, success: nil, failure: nil) }
        switch duration {
        case .indefinitely: return ControlRequest(action: .on(minutes: 0), success: nil, failure: nil)
        case .defaultDuration: return ControlRequest(action: .on(minutes: nil), success: nil, failure: nil)
        case .custom:
            guard let m = minutes, ControlURL.minutes.contains(m) else { return nil }
            return ControlRequest(action: .on(minutes: m), success: nil, failure: nil)
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let req = Self.request(toggle: shouldToggle, enabled: isEnabled, duration: durationType, minutes: minutes) else {
            throw CocaineIntentError.badMinutes
        }
        let allowed: Bool = await withCheckedContinuation { c in ScriptingCenter.shared.perform(req) { c.resume(returning: $0) } }
        guard allowed else { throw CocaineIntentError.notAllowed }
        return .result()
    }
}

@available(macOS 13.0, *)
enum CocaineIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notAllowed, badMinutes
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notAllowed: return "Cocaine didn't allow this: turn on “Shortcuts app and links” in its settings."
        case .badMinutes: return "Custom duration takes 1 to 1440 minutes."
        }
    }
}
#endif
