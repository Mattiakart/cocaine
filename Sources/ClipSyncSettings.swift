// The "iPhone clipboard sync" card of Settings → Island (PanelView puts it in a card under the Clipboard one): the iCloud Drive
// folder (on/off, status, counters, test, Finder, the iPhone Shortcuts, what to do with what arrives, sending), the paired
// iPhone's clipboard switches over the relay, and Universal Clipboard. In-app controls only; everything off by default.

import AppKit
import SwiftUI

struct ClipSyncSettingsView: View {
    @ObservedObject var center = ClipSyncCenter.shared
    @ObservedObject var clip = ClipboardHistory.shared
    @ObservedObject var pickers = PickerCenter.shared
    @StateObject private var local = ClipSyncPanelState()

    var body: some View {
        let s = center.settings
        VStack(alignment: .leading, spacing: Space.s) {
            row(L("Sync through iCloud Drive"), detail: folderDetail, warning: center.status == .noICloud || center.status == .unreadable) {
                CocaineSwitch(on: s.folderOn) {
                    if s.folderOn { center.update { $0.folderOn = false } } else { center.enableFolder() }
                }
                .accessibilityLabel(L("Sync through iCloud Drive"))
            }
            if s.folderOn {
                row(L("Last sync"), detail: counters) {
                    HStack(spacing: Space.s) {
                        Button(center.testing ? L("Testing…") : L("Test")) { center.test() }.buttonStyle(CocaineButtonStyle()).disabled(center.testing)
                            .help(L("Writes a small file into the folder and reads it back"))
                        icon("folder", L("Open in Finder")) { center.openInFinder() }
                    }
                }
                row(L("iPhone Shortcuts"), detail: local.shortcutNote ?? L("“Send to Mac” (Share Sheet or clipboard) and “Get from Mac”")) {
                    Button(L("Add…")) {
                        pickers.close()
                        SyncShortcuts.present(center, pairings: ClipSyncPanelState.pairings()) { local.shortcutNote = $0 }
                    }
                    .buttonStyle(CocaineButtonStyle())
                }
                row(L("Make it the current clipboard"), detail: L("What arrives from the iPhone is also ready to paste here")) {
                    CocaineSwitch(on: s.makeCurrent) { center.update { $0.makeCurrent.toggle() } }.accessibilityLabel(L("Make it the current clipboard"))
                }
                row(L("Pin what arrives to"), detail: nil) {
                    ValueButton(id: "clipsync.pinboard", title: L("Pin what arrives to"), value: boardName(s.pinboard),
                                spec: { boardSpec("clipsync.pinboard", L("Pin what arrives to"), s.pinboard) },
                                onPick: { id in center.update { $0.pinboard = UUID(uuidString: id) } })
                }
                row(L("Send every copy"), detail: L("Off: only what you send with “Send to iPhone”. Never passwords, keys, card numbers or excluded apps.")) {
                    CocaineSwitch(on: s.sendEveryCopy) { center.update { $0.sendEveryCopy.toggle() } }.accessibilityLabel(L("Send every copy"))
                }
                row(L("Keep received files"), detail: s.keepFiles ? L("In the folder's “processed”, removed after a day") : L("Off: deleted once taken in")) {
                    CocaineSwitch(on: s.keepFiles) { center.update { $0.keepFiles.toggle() } }.accessibilityLabel(L("Keep received files"))
                }
            }
            if let n = center.note {
                Text(n).font(UI.detail).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(L("Uses your iCloud Drive: not end-to-end encrypted unless Advanced Data Protection is on. Images and long text go this way."))
                .font(UI.detail).foregroundStyle(UI.hint).fixedSize(horizontal: false, vertical: true)
            divider
            section(L("Short text over the paired iPhone"))
            let pairs = local.pairs
            if pairs.isEmpty {
                Text(L("Pair an iPhone in Settings → Remote work first. End-to-end encrypted, about 2,000 characters at most."))
                    .font(UI.detail).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(pairs, id: \.id) { p in
                let perm = s.perm(p.id)
                row(String(format: L("Allow iPhone %@ to read my clipboard"), String(p.id.prefix(6))), detail: L("The newest item only (or the pinboard below), never secrets")) {
                    CocaineSwitch(on: perm.read) { center.update { $0.remote[p.id, default: ClipRemotePerm()].read.toggle() } }
                        .accessibilityLabel(String(format: L("Allow iPhone %@ to read my clipboard"), String(p.id.prefix(6))))
                }
                row(String(format: L("Allow iPhone %@ to send text to my clipboard"), String(p.id.prefix(6))), detail: nil) {
                    CocaineSwitch(on: perm.write) { center.update { $0.remote[p.id, default: ClipRemotePerm()].write.toggle() } }
                        .accessibilityLabel(String(format: L("Allow iPhone %@ to send text to my clipboard"), String(p.id.prefix(6))))
                }
            }
            if !pairs.isEmpty {
                row(L("Pinboard the iPhone can read"), detail: nil) {
                    ValueButton(id: "clipsync.readable", title: L("Pinboard the iPhone can read"), value: boardName(s.readableBoard),
                                spec: { boardSpec("clipsync.readable", L("Pinboard the iPhone can read"), s.readableBoard) },
                                onPick: { id in center.update { $0.readableBoard = UUID(uuidString: id) } })
                }
            }
            divider
            section(L("Universal Clipboard"))
            row(L("Keep its copies off the saved history"), detail: L("Apple's own: what you copy on a nearby iPhone or iPad shows up as Another device. Kept in memory only.")) {
                CocaineSwitch(on: s.universalOffDisk) { center.update { $0.universalOffDisk.toggle() } }.accessibilityLabel(L("Keep its copies off the saved history"))
            }
        }
        .onAppear { local.refresh(); center.refreshStatus() }
    }

    private var folderDetail: String {
        switch center.status {
        case .ready: return center.folderDisplay
        case .notCreated: return center.settings.folderOn ? L("The folder is missing: turn it off and on again") : String(format: L("Off. When on: %@"), center.folderDisplay)
        case .noICloud: return L("iCloud Drive isn't on for this Mac: turn it on in System Settings → Apple Account → iCloud.")
        case .unreadable: return L("Cocaine can't read the folder: allow it when macOS asks, or in Privacy & Security.")
        }
    }

    private var counters: String {
        var parts = [String(format: L("received %d"), center.received), String(format: L("sent %d"), center.sent)]
        if center.refused > 0 { parts.append(String(format: L("refused %d"), center.refused)) }
        if center.notDownloaded > 0 { parts.append(String(format: L("%d waiting for iCloud"), center.notDownloaded)) }
        let when = center.lastSync.map { $0.formatted(.dateTime.hour().minute().locale(Language.locale)) } ?? L("never")
        return when + " · " + parts.joined(separator: " · ")
    }

    private func boardName(_ id: UUID?) -> String { id.flatMap { clip.board($0)?.displayName } ?? L("None") }

    private func boardSpec(_ id: String, _ title: String, _ chosen: UUID?) -> PickerSpec {
        PickerSpec(id: id, title: title, items: [PickerItem(id: "", title: L("None"), symbol: "minus")]
                       + clip.boards.map { PickerItem(id: $0.id.uuidString, title: $0.displayName, symbol: $0.icon ?? "pin") },
                   mode: .single(chosen?.uuidString ?? ""))
    }

    // MARK: the panel's look (as the Shelf card's)

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.vertical, 2) }

    private func section(_ title: String) -> some View {
        Text(title).font(UI.groupTitle).lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(minHeight: 22)
            .accessibilityAddTraits(.isHeader)
    }

    private func row<Control: View>(_ title: String, detail: String?, warning: Bool = false, @ViewBuilder _ control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(UI.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(UI.detail).foregroundStyle(warning ? warningColor : UI.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()
        }
        .frame(minHeight: 22)
        .fixedSize(horizontal: false, vertical: true)
        .help(detail ?? title)
    }

    private func icon(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: { Haptic.tap(.alignment); action() }) {
            Image(systemName: symbol).font(UI.icon).foregroundStyle(UI.secondary).frame(width: CTL.h, height: CTL.h).contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle()).help(title).accessibilityLabel(title)
    }
}

/// The card's own state: the paired iPhones (read when it appears) and the last word about a Shortcut.
final class ClipSyncPanelState: ObservableObject {
    @Published var pairs: [Pairing] = []
    @Published var shortcutNote: String?

    func refresh() { pairs = Self.pairings().filter { !$0.isLegacy && $0.keys != nil } }

    /// The paired iPhones; in renders and tests (isolated settings) a sample one, never the real phones.json.
    static func pairings() -> [Pairing] {
        if AppDefaults.isolated {
            return CommandLine.arguments.contains("--no-phone") ? [] : [Pairing.make(tier: "basic", relay: "https://relay.test").map { var p = $0; p.id = "a1b2c3d4e5f60718"; return p }!]
        }
        return PhoneLink.load()
    }
}
