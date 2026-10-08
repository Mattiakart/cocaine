// The settings search's index (Sources/SettingsSearch.swift): every setting of the panel, where it is (tab, card, row) and
// what it is about. Titles are the panel's own string keys, so the words of all 8 languages come from the string tables;
// `concepts` name entries of Localization/<lang>.lproj/SearchIndex.strings (synonyms and related words, every language).
// A new setting: one line here (its row title key, as the panel shows it), its concepts; --ui-test checks that every row the
// panel draws (and every card) is indexed and that every concept exists in all languages.

import Foundation

enum SettingsIndex {
    private struct Card {
        let tab: String, key: String, icon: String
        var concepts: [String] = []
        var rows: [(String, String?, [String])] = []          // title key, detail/tip key, concepts
    }

    private static func r(_ key: String, _ detail: String? = nil, _ concepts: [String] = []) -> (String, String?, [String]) { (key, detail, concepts) }

    private static let cards: [Card] = [
        // General
        Card(tab: "", key: "Stay on for", icon: "hourglass", concepts: ["awake", "timer"], rows: [
            r("Until a time", "Keeps the Mac awake until this time (today, or tomorrow once it has passed)", ["schedule"]),
        ]),
        Card(tab: "", key: "When idle", icon: "sun.min", concepts: ["idle", "dim", "screenoff", "brightness"], rows: [
            r("Dim the screen when idle", "Shows the minimum brightness for 3 seconds", ["dim", "brightness"]),
            r("Screens off now", "Turn the screens off now", ["screenoff"]),
            r("After", nil, ["timer", "idle"]),
        ]),
        Card(tab: "", key: "Battery Guard", icon: "battery.50", concepts: ["battery"], rows: [
            r("When the battery reaches", "On battery only", ["battery"]),
            r("Then", "What Cocaine does at that level", ["battery"]),
        ]),
        Card(tab: "", key: "Keep awake", icon: "cup.and.saucer", concepts: ["awake"], rows: [
            r("Turn off when unplugged", nil, ["charger"]),
            r("Pause while the screen is locked", nil, ["lock"]),
            r("Turn on when Cocaine opens", "Always, only when you open it yourself (not at login), or never", ["login"]),
            r("Left click turns it on or off", "Right click opens this panel", ["click", "menubar"]),
            r("Menu-bar icon", "The island keeps the baggie", ["menubar"]),
            r("Notices when it turns on or off", nil, ["alert"]),
        ]),
        Card(tab: "", key: "Cocaine", icon: "gearshape", rows: [
            r("Open at login", nil, ["login"]),
            r("Updates", nil, ["update"]),
            r("Check for updates automatically", "Once a day. Nothing is downloaded until you press Install.", ["update"]),
            r("Language", nil, ["language"]),
            r("Show in the notch", "Replaces the menu-bar icon", ["notch", "menubar"]),
            r("Haptic feedback", "A light tap on the trackpad when you change a timer, switch a page or toggle something", ["haptic"]),
            r("Shortcuts app and links", nil, ["links", "scripting"]),
            r("Permissions", "Everything Cocaine needs is allowed", ["permissions"]),
            r("Feedback or help", nil, ["help"]),
        ]),
        Card(tab: "", key: "Keyboard shortcuts", icon: "command", concepts: ["hotkey"], rows: [
            r("Turn Cocaine on or off", nil, ["hotkey", "awake"]),
            r("Open the panel", nil, ["hotkey"]),
            r("Pause or resume alerts", nil, ["hotkey", "alert", "quiet"]),
            r("Open the island with the keyboard", nil, ["hotkey", "notch"]),
            r("Reset to defaults", nil, ["delete"]),
        ]),
        // AI alerts
        Card(tab: "ai", key: "Agents", icon: "sparkles", concepts: ["ai"]),
        Card(tab: "ai", key: "Detected environments", icon: "sparkles", concepts: ["ai"], rows: [
            r("Web chats", "Chat tabs in your browser: open, closed, and going back to the tab. Their replies can't be seen.", ["ai"]),
        ]),
        Card(tab: "ai", key: "AI context (MCP)", icon: "sparkles.rectangle.stack", concepts: ["mcp", "ai"], rows: [
            r("Let AI tools read the AI context", nil, ["mcp", "privacy"]),
            r("Keep after restart", nil, ["mcp"]),
            r("Items expire after", nil, ["mcp", "timer"]),
        ]),
        Card(tab: "ai", key: "When", icon: "bell.badge", concepts: ["alert", "ai"], rows: [
            r("Finishes", "When an AI completes its work", ["alert", "ai"]),
            r("Needs you", "When it asks for a permission or an answer", ["alert", "ai"]),
            r("Also at the Mac", "Otherwise only when you've been away for 20 seconds", ["alert", "idle"]),
            r("One alert per session", nil, ["alert"]),
            r("Answer from the island", nil, ["ai", "notch", "permissions"]),
            r("Last message on the cards", nil, ["ai"]),
            r("Claude plan limits", nil, ["ai", "stats"]),
            r("Jump rules", nil, ["ai", "links"]),
            r("Pause", "Silences every alert for a while", ["quiet", "alert"]),
        ]),
        Card(tab: "ai", key: "How", icon: "speaker.wave.2", concepts: ["alert", "sound"], rows: [
            r("Flash", "Wakes the screens and flashes them", ["alert", "brightness"]),
            r("Sound", "Plays when the alert arrives", ["sound"]),
            r("Sound when it finishes", nil, ["sound"]),
            r("Sound when it needs you", nil, ["sound"]),
            r("Sound when it fails", nil, ["sound"]),
            r("Quiet hours", "No sound and no voice in these hours; alerts still show", ["quiet", "schedule"]),
            r("Hours", nil, ["quiet", "schedule"]),
            r("Voice", "Reads out who's calling and the project", ["voice"]),
            r("Voice type", nil, ["voice"]),
            r("On screen", "How long the alert stays", ["alert", "timer"]),
            r("Repeat", "While you're away, for up to 30 minutes", ["alert", "every"]),
        ]),
        Card(tab: "ai", key: "SSH hosts", icon: "server.rack", concepts: ["ssh", "ai"], rows: [
            r("Follow AI agents on SSH hosts", nil, ["ssh", "ai"]),
        ]),
        // Automation
        Card(tab: "auto", key: "Smart Triggers", icon: "bolt.badge.automatic", concepts: ["profile", "awake"], rows: [
            r("An AI is at work", "On while an AI works or waits for you; off 3 minutes after", ["ai"]),
            r("These programs are open", "On while any is running; off 3 minutes after", ["apps"]),
            r("Power", "On while the Mac is on the charger, or on battery above a level; off 30 seconds after", ["charger", "battery"]),
            r("External display", "On while a display is connected (or while none is); off 30 seconds after", ["display"]),
            r("Schedule", "On during these hours on the chosen days; off when they end", ["schedule"]),
            r("A VPN is connected", nil, ["vpn"]),
            r("Processor", nil, ["cpu"]),
            r("Sound plays through", nil, ["audioout"]),
            r("A disk is connected", nil, ["disk"]),
            r("A USB device is connected", nil, ["usb"]),
            r("Hours", "Local time; follows daylight saving and time-zone changes", ["schedule"]),
            r("Turn on when", "Any: one reason is enough. All: every chosen one must hold.", ["profile"]),
        ]),
        Card(tab: "auto", key: "Profiles", icon: "switch.2", concepts: ["profile", "wifi", "awake"], rows: [
            r("New profile", nil, ["profile", "wifi"]),
        ]),
        Card(tab: "auto", key: "Keep awake while…", icon: "hourglass.bottomhalf.filled", concepts: ["awake"], rows: [
            r("A program runs", nil, ["apps"]),
            r("Downloads are in progress", nil, ["download"]),
        ]),
        Card(tab: "auto", key: "Keep disks awake", icon: "externaldrive.badge.timemachine", concepts: ["disk", "awake"], rows: [
            r("Disks", nil, ["disk"]),
            r("Every", nil, ["every"]),
            r("Method", nil, ["disk"]),
        ]),
        Card(tab: "auto", key: "Stay active", icon: "person.crop.circle.badge.checkmark", concepts: ["presence"], rows: [
            r("Stay available in chat apps", nil, ["presence", "idle"]),
            r("When", "Only while one of the chosen apps is open, or all the time", ["presence", "apps"]),
            r("Apps", "The chat apps to keep available", ["presence", "apps"]),
        ]),
        Card(tab: "auto", key: "Remote work", icon: "iphone.gen3", concepts: ["iphone"], rows: [
            r("iPhone", "Send the Shortcut to your iPhone", ["iphone"]),
            r("Wake for iPhone", "Every 15 minutes it wakes briefly, even with the lid closed, to answer your iPhone", ["iphone", "awake"]),
            r("Phone alerts", "When you're away, alerts also go to your phone", ["iphone", "alert"]),
        ]),
        Card(tab: "auto", key: "Shortcuts and scripts", icon: "applescript", concepts: ["scripting"], rows: [
            r("Mac Shortcuts", nil, ["scripting"]),
        ]),
        // Island (only while the island is on; found anyway, with how to show it)
        Card(tab: "island", key: "Island", icon: "rectangle.topthird.inset.filled", concepts: ["notch"], rows: [
            r("Replace system HUD", nil, ["hud", "brightness", "sound"]),
            r("Show on all screens", nil, ["screens", "display"]),
            r("Hide in full-screen apps", nil, ["fullscreen"]),
        ]),
        Card(tab: "island", key: "Notch", icon: "rectangle.topthird.inset.filled", concepts: ["notch", "size"], rows: [
            r("Size", "Never smaller than the standard size, so no page gets cut.", ["size", "camera"]),
            r("Open island", nil, ["size"]),
            r("Charging notices", "Below the notch when the charger goes in or out, the battery is full or Low Power Mode changes", ["charger", "battery", "alert"]),
            r("Low battery notice", "Once when the battery reaches this level, and again at 10%", ["battery", "alert"]),
            r("Swipe down to open", "Two fingers down just below the closed notch", ["swipe"]),
            r("Swipe up to close", nil, ["swipe"]),
            r("Swipe sideways for screens", nil, ["swipe", "modules"]),
            r("Sensitivity", nil, ["swipe"]),
            r("Lists shown", nil, ["reminders"]),
            r("New reminders go to", nil, ["reminders"]),
            r("As tall as the menu bar", nil, ["size", "menubar"]),
        ]),
        Card(tab: "island", key: "Screens", icon: "rectangle.3.group", concepts: ["modules"], rows: [
            r("Start screen", "The island opens on it", ["modules"]),
            r("Restore defaults", nil, ["modules", "delete"]),
        ]),
        Card(tab: "island", key: "Shelf", icon: "tray.and.arrow.down.fill", concepts: ["shelf"], rows: [
            r("Shake to open", "Shake the pointer while dragging files: the island opens on the shelf", ["shelf", "swipe"]),
            r("Remove after dragging out", nil, ["shelf"]),
            r("Instant actions", nil, ["shelf", "scripting"]),
            r("Watched folders", "New files in a watched folder land on the shelf, e.g. your screenshots or downloads", ["shelf", "download"]),
        ]),
        Card(tab: "island", key: "Sharing", icon: "link", concepts: ["cloud"], rows: [
            r("Cloud sharing", nil, ["cloud"]),
            r("Ask before every upload", nil, ["cloud", "privacy"]),
            r("Link expires after", nil, ["cloud", "timer"]),
        ]),
        Card(tab: "island", key: "Music and keyboard", icon: "music.note", concepts: ["music", "kbdlight"], rows: [
            r("YouTube Music (Pear Desktop)", nil, ["music"]),
            r("Skip step", "How far the back and forward buttons of the Music page jump", ["music"]),
            r("Keyboard backlight", nil, ["kbdlight", "brightness"]),
            r("Turn off when idle", nil, ["kbdlight", "idle"]),
        ]),
        Card(tab: "island", key: "Clipboard", icon: "doc.on.clipboard", concepts: ["clipboard"], rows: [
            r("Save on this Mac", "Encrypted, with its key in your Keychain", ["clipboard", "storage", "privacy"]),
            r("Keep at most", "Pinned items don't count and are never removed", ["clipboard", "storage"]),
            r("Forget after", nil, ["clipboard", "timer"]),
            r("Space in all", nil, ["storage"]),
            r("Largest item", "Bigger images and texts aren't kept", ["storage"]),
            r("Skip card numbers and keys", "Card numbers, private keys, API keys and other tokens aren't kept", ["privacy"]),
            r("Excluded apps", "Password managers are always excluded", ["privacy", "apps"]),
            r("Excluded patterns", "Text matching one of these regular expressions isn't kept", ["privacy"]),
            r("Paste with Return and double-click", nil, ["paste"]),
            r("Paste without formatting", "Plain text unless ⇧ is held; off: formatted unless ⇧ is held", ["paste"]),
            r("Between items pasted together", "Used by Paste all and Merge", ["paste"]),
            r("Paste next (Paste Stack)", nil, ["paste", "hotkey"]),
            r("Copies from other devices", "Universal Clipboard: shown as Another device", ["sync"]),
            r("Find text in images", "Read on this Mac when an image is copied; secrets masked", ["ocr"]),
            r("Suggestions for the app in front", nil, ["clipboard", "apps"]),
            r("Hide from screen sharing", nil, ["sharingscreen", "privacy"]),
            r("Command line", "cocaine clip in Terminal and Shortcuts", ["scripting"]),
            r("Open the clipboard", "From any app, with the keyboard in it: type to search, Return pastes", ["hotkey", "clipboard"]),
            r("Opens", nil, ["clipboard"]),
            r("Search", "Mixed: whole words first; if nothing matches, a regular expression; then letters in order", ["clipboard"]),
            r("Order", nil, ["clipboard"]),
            r("Show ⌘1…9 on the rows", nil, ["hotkey"]),
            r("Delete everything", "History, pinboards, saved files and their key", ["delete", "privacy"]),
        ]),
        Card(tab: "island", key: "iPhone clipboard sync", icon: "iphone", concepts: ["sync", "iphone", "clipboard"], rows: [
            r("Send every copy", nil, ["sync"]),
            r("Sync through iCloud Drive", nil, ["sync", "cloud"]),
            r("Pinboard the iPhone can read", nil, ["pinboard", "sync"]),
            r("Make it the current clipboard", "What arrives from the iPhone is also ready to paste here", ["paste", "sync"]),
            r("Keep received files", nil, ["sync", "storage"]),
        ]),
        Card(tab: "island", key: "Pinboards", icon: "pin", concepts: ["pinboard", "clipboard"]),
    ]

    /// Every entry: each card, then its rows, in the panel's order (equal scores keep this order).
    static let entries: [SettingsEntry] = cards.flatMap { c -> [SettingsEntry] in
        [SettingsEntry(tab: c.tab, card: c.key, row: nil, concepts: c.concepts, icon: c.icon)]
            + c.rows.map { SettingsEntry(tab: c.tab, card: c.key, row: $0.0, detail: $0.1, concepts: $0.2, icon: c.icon, cardConcepts: c.concepts) }
    }

    /// Rows the panel draws only to report a problem or a passing state (a permission to give, old Shortcuts): not settings
    /// to look for, so not indexed (--ui-test's coverage check leaves them out).
    static let notIndexed: [String] = ["Needs permission to send input", "Old Shortcuts"]

    /// Every concept the index uses (each must be in SearchIndex.strings in every language: --ui-test).
    static var concepts: Set<String> { Set(entries.flatMap { $0.concepts + $0.cardConcepts }) }
}
