// Basics: Cocaine leaves basic macOS behaviour alone unless the user switched that feature on (2.9). The audit of what the app
// does by default (docs/defaults-and-basics.en.md, .it.md) and the checks `--basics-test` runs on it (Sources/BasicsTests.swift).
//
// Three defaults changed in 2.9 because they touched something basic without being asked:
// - Universal Clipboard (Handoff copy and paste): the clipboard history read every copy from another device at once, all its
//   flavours (RTF, HTML, images, files, the source marker), each one a transfer from that device. Now another device's copy is
//   left alone (not even read) unless "Copies from other devices" is on; then only its plain text, a few seconds later
//   (ClipSettings.includeRemote, SystemPasteboard.snapshot, ClipboardHistory.poll in Sources/Clipboard.swift).
// - ⌃⌘V was taken globally to open the clipboard: it is Paste Special in Microsoft Word, Excel and PowerPoint. No shortcut until
//   the user records one (ClipSettings.openShortcut).
// - Share links went on the clipboard marked "concealed", which can keep a copy from other apps and devices: now a plain copy
//   (CloudClipboard in Sources/CloudShare.swift).
// Settings saved before 2.9 carry no schema: the first two are reset once from their old defaults (ClipSettings.migrate).

import AppKit
import Carbon.HIToolbox

enum Basics {
    /// How a default-on behaviour relates to the system.
    enum Kind: String { case explicit, passive, ownUI, coreFeature }

    struct Entry {
        let what: String
        let kind: Kind
        let check: () -> Bool          // the default is still what the docs say
    }

    /// What Cocaine does with fresh settings, as docs/defaults-and-basics.en.md lists it. Run on memory-only settings.
    static func inventory() -> [Entry] {
        let s = Settings(), clip = ClipSettings()
        return [
            Entry(what: "volume/brightness keys and the system HUD are macOS's (Replace system HUD off)", kind: .explicit) { !s.replaceHUD },
            Entry(what: "no synthetic input, no idle nudges (Stay active off)", kind: .explicit) { !s.stayActive && !s.stayActiveAlways },
            Entry(what: "keyboard backlight never switched off by Cocaine", kind: .explicit) { AppDefaults.store.integer(forKey: "kbIdleOff") == 0 },
            Entry(what: "no scheduled wake for the phone (pmset schedule)", kind: .explicit) { !s.wakeForPhone },
            Entry(what: "no Smart Trigger turns Cocaine on by itself", kind: .explicit) { !s.triggerAgents && !s.triggerSchedule && !s.triggerAll && !s.triggerVPN },
            Entry(what: "links (cocaine://) can't change sleep without asking", kind: .explicit) { !s.allowLinks },
            Entry(what: "Universal Clipboard: another device's copy is not read", kind: .explicit) { !clip.includeRemote },
            Entry(what: "no global shortcut for the clipboard (⌃⌘V stays Office's Paste Special)", kind: .explicit) { clip.openShortcut == nil },
            Entry(what: "clipboard history: in memory, reads this Mac's copies, writes only on a click", kind: .passive) { !clip.persist && clip.cliAccess == 0 },
            Entry(what: "global shortcuts ⌃⌥⌘C/O/P/I (Cocaine's own, no macOS shortcut)", kind: .ownUI) {
                ShortcutAction.allCases.allSatisfy { $0.defaultShortcut.mods == Shortcut.hyper && !ShortcutRules.reserved.contains($0.defaultShortcut) }
            },
            Entry(what: "the island over the notch (its own window; trackpad swipes there are listened to, never blocked)", kind: .ownUI) { s.island },
            Entry(what: "keep-awake at launch, idle dim and the lid rule while Cocaine is on", kind: .coreFeature) { s.dimEnabled },
        ]
    }

    /// The Info.plist claims nothing: no file type handled by default, the URL scheme is Cocaine's own.
    static func bundleClaimsNothing(_ info: [String: Any]?) -> Bool {
        guard let info else { return true }                       // a test binary outside the app bundle
        let docs = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let ranks = docs.map { $0["LSHandlerRank"] as? String ?? "Default" }
        let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return ranks.allSatisfy { $0 == "None" } && schemes.allSatisfy { $0 == "cocaine" }
    }

    static func inventoryChecks() -> [(String, Bool)] {
        var out = inventory().map { ("default (\($0.kind.rawValue)): \($0.what)", $0.check()) }
        out.append(("Info.plist: never the default app for any file type, only the cocaine:// scheme", bundleClaimsNothing(Bundle.main.infoDictionary?["CFBundleIdentifier"] == nil ? nil : Bundle.main.infoDictionary)))
        return out
    }
}
