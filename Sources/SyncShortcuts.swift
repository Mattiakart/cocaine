// The iPhone Shortcuts of the clipboard sync, built and signed by Cocaine (like the remote-control and Mac Shortcuts:
// RemoteShortcut.Builder, `/usr/bin/shortcuts sign`):
//   • "Send to Mac"   — the Share Sheet's text, link or image, or the iPhone's clipboard when run on its own, saved as one
//                       uniquely named file in Shortcuts › <folder>/inbox (iCloud Drive). No account, no relay.
//   • "Get from Mac"  — the newest item the Mac sent (outbox/latest.png or latest.txt) onto the iPhone's clipboard.
//   • "Cocaine Clip"  — for a paired iPhone: short text both ways over the relay, end-to-end encrypted with the pairing's keys
//                       (protocol v2, the same construction as the remote Shortcut), in up to 6 pieces (≈ 2 KB).
//
// Only actions and keys whose names were checked in Shortcuts' own action definitions (WorkflowKit/ActionKit in the macOS 27
// dyld cache: see `knownParameters`) are used; `problems` refuses anything else. The two iCloud Shortcuts reach the folder by
// path inside Shortcuts' iCloud folder (Save File / Get File with no folder picked): that is why the sync folder lives there.
// Run in the simulator by the tests (ClipSyncTests); not yet run on an iPhone (docs/clipboard-sync).

import AppKit

struct SyncShortcutLabels {
    var sent = "Sent to your Mac. It shows up in Cocaine's clipboard in a few seconds (iCloud decides when)."
    var copiedImage = "The Mac's image is on the clipboard."
    var copied = "Copied from the Mac:"
    var nothing = "Nothing from the Mac yet. On the Mac: the clipboard item's menu → Send to iPhone."
    var sendClipboard = "Send my clipboard", getNewest = "Get the Mac's newest", list = "List the iPhone pinboard", getItem = "Get a pinboard item…"
    var itemPrompt = "Which item? (its number in the list)"
    var noText = "There is no text on the iPhone's clipboard."
    var noAnswer = "No valid answer yet. If the Mac is asleep, try again in a few minutes."

    /// In the app's language.
    static var localized: SyncShortcutLabels {
        SyncShortcutLabels(sent: L("Sent to your Mac. It shows up in Cocaine's clipboard in a few seconds (iCloud decides when)."),
                           copiedImage: L("The Mac's image is on the clipboard."), copied: L("Copied from the Mac:"),
                           nothing: L("Nothing from the Mac yet. On the Mac: the clipboard item's menu → Send to iPhone."),
                           sendClipboard: L("Send my clipboard"), getNewest: L("Get the Mac's newest"), list: L("List the iPhone pinboard"),
                           getItem: L("Get a pinboard item…"), itemPrompt: L("Which item? (its number in the list)"),
                           noText: L("There is no text on the iPhone's clipboard."),
                           noAnswer: L("No valid answer yet. If the Mac is asleep, try again in a few minutes."))
    }
}

enum SyncShortcuts {
    enum Kind: String, CaseIterable { case sendToMac, getFromMac, clip }
    typealias B = RemoteShortcut.Builder
    typealias Part = RemoteShortcut.Part

    static func title(_ k: Kind) -> String {
        switch k {
        case .sendToMac: return L("Send to Mac")
        case .getFromMac: return L("Get from Mac")
        case .clip: return "Cocaine Clip"
        }
    }
    static func fileName(_ k: Kind) -> String {
        k == .clip ? "Cocaine Clip.shortcut" : "Cocaine – \(title(k).replacingOccurrences(of: "/", with: "-")).shortcut"
    }

    /// The Shortcut's input as a whole variable (what the Share Sheet passed; with no input, the clipboard: see `build`).
    static let shortcutInput: [String: Any] = ["Value": ["Type": "ExtensionInput"], "WFSerializationType": "WFTextTokenAttachment"]

    /// If `input` has any value (WFCondition 100) … Otherwise … End If.
    static func ifHasValue(_ b: B, _ input: Part, then: () -> Void, otherwise: (() -> Void)? = nil) {
        let g = UUID().uuidString
        b.add("conditional", ["GroupingIdentifier": g, "WFControlFlowMode": 0, "WFCondition": 100,
                              "WFInput": ["Type": "Variable", "Variable": B.whole(input)]])
        then()
        if let otherwise {
            b.add("conditional", ["GroupingIdentifier": g, "WFControlFlowMode": 1])
            otherwise()
        }
        b.add("conditional", ["GroupingIdentifier": g, "WFControlFlowMode": 2])
    }

    /// Repeat `times` times … End Repeat; the round (1…times) is the magic variable "Repeat Index".
    static func repeatCount(_ b: B, _ times: Int, _ body: () -> Void) {
        let g = UUID().uuidString
        b.add("repeat.count", ["GroupingIdentifier": g, "WFControlFlowMode": 0, "WFRepeatCount": times])
        body()
        b.add("repeat.count", ["GroupingIdentifier": g, "WFControlFlowMode": 2])
    }

    // MARK: Send to Mac / Get from Mac (iCloud Drive)

    static func sendToMac(subpath: String, labels: SyncShortcutLabels) -> [[String: Any]] {
        let b = B()
        let now = b.add("date", ["WFDateActionMode": "Current Date"], output: "Date")
        let stamp = b.add("format.date", ["WFDateFormatStyle": "Custom", "WFDateFormat": "yyyyMMdd-HHmmss", "WFDate": B.token([now])],
                          output: "Formatted Date")
        let r = b.add("number.random", ["WFRandomNumberMinimum": 100_000, "WFRandomNumberMaximum": 999_999], output: "Random Number")
        let name = b.replace(b.text([stamp, .t("-"), r]), "[^0-9-]", "")        // digits only, whatever the phone's locale draws
        let named = b.add("setitemname", ["WFInput": shortcutInput, "WFName": B.token([name])], output: "Renamed Item")
        b.add("documentpicker.save", ["WFInput": B.whole(named), "WFAskWhereToSave": false, "WFSaveFileOverwrite": false,
                                      "WFFileDestinationPath": B.token([.t("/\(subpath)/inbox/"), name])], output: "Saved File")
        b.show(b.text([.t(labels.sent)]))
        return b.actions
    }

    static func getFromMac(subpath: String, labels: SyncShortcutLabels) -> [[String: Any]] {
        let b = B()
        func file(_ leaf: String) -> Part {
            b.add("documentpicker.open", ["WFShowFilePicker": false, "WFGetFilePath": B.token([.t("\(subpath)/outbox/\(leaf)")]),
                                          "WFFileErrorIfNotFound": false], output: "File")
        }
        let image = file(SyncOutbox.latestImage)
        let text = file(SyncOutbox.latestText)
        ifHasValue(b, image, then: {
            b.add("setclipboard", ["WFInput": B.whole(image)])
            b.show(b.text([.t(labels.copiedImage)]))
        }, otherwise: {
            ifHasValue(b, text, then: {
                b.add("setclipboard", ["WFInput": B.whole(text)])
                b.show(b.text([.t(labels.copied + "\n"), text]))
            }, otherwise: {
                b.show(b.text([.t(labels.nothing)]))
            })
        })
        return b.actions
    }

    // MARK: Cocaine Clip (the paired iPhone's relay)

    static let pieceSize = 470            // base64 symbols per `clip part`: "clip part 123456 6/6 " + 470 ≤ 500 bytes

    /// Seals `command` (a text Part) like the remote Shortcut and posts it; returns the request's nonce.
    static func sendCommand(_ b: B, pairing: Pairing, keys: RemoteKeys, _ command: Part) -> Part {
        let r = (0..<3).map { _ in b.add("number.random", ["WFRandomNumberMinimum": 100_000_000, "WFRandomNumberMaximum": 999_999_999], output: "Random Number") }
        let nonce = b.replace(b.text(r), "[^0-9]", "")
        let now = b.add("date", ["WFDateActionMode": "Current Date"], output: "Date")
        let iso = b.add("format.date", ["WFDateFormatStyle": "ISO 8601", "WFISO8601IncludeTime": true, "WFDate": B.token([now])], output: "Formatted Date")
        let ts = b.replace(b.replace(b.replace(iso, #"[.,][0-9]+"#, ""), "[^0-9TZ:+-]", ""), "+", "p", regex: false)
        let plain = b.text([command, .t("\n")])
        let b64 = b.add("base64encode", ["WFEncodeMode": "Encode", "WFBase64LineBreakMode": "None", "WFInput": B.whole(plain)], output: "Base64 Encoded")
        let bits = RemoteShortcut.base64Bits(b, b64, alphabet: RemoteCrypto.std)
        let size = RemoteProtocol.commandBits
        let fixedSize = b.replace(b.text([bits, .t(String(repeating: "0", count: size))]), "^([01]{\(size)}).*$", "$1")
        let key = RemoteShortcut.keystream(b, keys: keys, dir: "c", nonce: nonce, ts: ts, blocks: RemoteProtocol.commandBlocks)
        var ct = b.replace(RemoteShortcut.xor(b, fixedSize, key, count: [.t(String(size))]), "([01]{6})", "$1,")
        for (i, c) in RemoteCrypto.url.enumerated() { ct = b.replace(ct, RemoteShortcut.sixBits(i) + ",", String(c), regex: false) }
        let tag = RemoteShortcut.mac(b, keys: keys, [.t("c2|\(pairing.id)|"), nonce, .t("|"), ts, .t("|"), ct])
        _ = b.post("\(pairing.relay)/\(pairing.cmd)?firebase=no", body: b.text([.t("c2.\(pairing.id)."), nonce, .t("."), ts, .t("."), ct, .t("."), tag]))
        return nonce
    }

    /// RemoteShortcut.receive without showing: (OK or BAD, the answer — or the "no valid answer" text).
    static func receive(_ b: B, pairing: Pairing, keys: RemoteKeys, line: Part, nonce: Part, noAnswer: String) -> (ok: Part, text: Part) {
        let ts = b.replace(line, #"^r2\.\d+\.([^.]+)\..*$"#, "$1")
        let n0 = b.replace(line, #"^r2\.\d+\.[^.]+\.(\d{1,5})\..*$"#, "$1")
        let n = b.replace(n0, #"(?s)^(?!\d{1,5}$).*$"#, "0")
        let ct = b.replace(line, #"^r2\.\d+\.[^.]+\.\d+\.([A-Za-z0-9_-]+)\.[0-9a-fA-F]{64}$"#, "$1")
        let tag = b.replace(line, #"^.*\.([0-9a-fA-F]{64})$"#, "$1")
        let expected = RemoteShortcut.mac(b, keys: keys, [.t("r2|\(pairing.id)|"), nonce, .t("|"), ts, .t("|"), n, .t("|"), ct])
        let ok = b.replace(b.replace(b.text([expected, .t("="), tag]), #"(?is)^([0-9a-f]{64})=\1$"#, "OK"), #"(?s)^(?!OK$).*$"#, "BAD")
        let gated = b.replace(b.text([ok, .t(":"), ct]), #"(?s)^(?:OK:([A-Za-z0-9_-]*)|.*)$"#, "$1")
        let bits = RemoteShortcut.base64Bits(b, gated, alphabet: RemoteCrypto.url)
        let key = RemoteShortcut.keystream(b, keys: keys, dir: "r", nonce: nonce, ts: ts, blocks: RemoteProtocol.replyBlocks)
        var hex = b.replace(RemoteShortcut.xor(b, bits, key, count: [n]), "([01]{4})", "$1,")
        for (c, bits) in RemoteShortcut.hexBits { hex = b.replace(hex, bits + ",", String(c), regex: false) }
        let decoded = b.add("urlencode", ["WFEncodeMode": "Decode", "WFInput": B.token([b.replace(hex, "([0-9a-f]{2})", "%$1")])], output: "URL Decoded Text")
        let shown = b.replace(b.replace(b.text([ok, .t("\n"), decoded]), #"(?s)^OK\n"#, ""), #"(?s)^BAD\n.*$"#, noAnswer)
        return (ok, b.replace(shown, " +$", ""))
    }

    static func clip(_ pairing: Pairing, labels: SyncShortcutLabels) -> [[String: Any]]? {
        guard let keys = pairing.keys, !pairing.isLegacy else { return nil }
        let b = B()
        b.setVariable("cocaineLast", b.text([.t("0")]))
        b.setVariable("cocaineCommand", b.text([.t("")]))
        let group = UUID().uuidString
        let items = [labels.sendClipboard, labels.getNewest, labels.list, labels.getItem]
        b.add("choosefrommenu", ["GroupingIdentifier": group, "WFControlFlowMode": 0, "WFMenuPrompt": "Cocaine Clip", "WFMenuItems": items])
        func item(_ t: String) { b.add("choosefrommenu", ["GroupingIdentifier": group, "WFControlFlowMode": 1, "WFMenuItemTitle": t]) }

        item(labels.sendClipboard)
        do {
            let clip = b.add("getclipboard", [:], output: "Clipboard")
            let asText = b.text([clip])                                    // an image on the clipboard becomes no text
            let b64 = b.add("base64encode", ["WFEncodeMode": "Encode", "WFBase64LineBreakMode": "None", "WFInput": B.whole(asText)], output: "Base64 Encoded")
            let clean = b.replace(b64, "[^A-Za-z0-9+/=]", "")
            ifHasValue(b, clean, then: {
                // How many pieces (1…6; "7" = too long, which the Mac answers), and an id tying them together.
                var count = b.replace(clean, "[A-Za-z0-9+/=]{1,\(pieceSize)}", "x")
                for k in (1...ClipRemote.maxParts).reversed() { count = b.replace(count, "^x{\(k)}$", "\(k)") }
                count = b.replace(count, #"(?s)^(?![1-6]$).*$"#, "7")
                let id = b.replace(b.add("number.random", ["WFRandomNumberMinimum": 100_000, "WFRandomNumberMaximum": 999_999], output: "Random Number"), "[^0-9]", "")
                // One piece per round (Repeat Index 1…6), sealed and sent; a round past the end has no piece and sends nothing.
                // A filler piece in front lets the round's own index skip the pieces before it.
                // Too long ("7"): only the first piece goes, for the Mac to answer "too long" without six messages' wait.
                let limited = b.replace(b.text([count, .t("#"), clean]), #"(?s)^(?:7#(.{1,\#(pieceSize)}).*|[1-6]#(.*))$"#, "$1$2")
                let padded = b.text([.t(String(repeating: "#", count: pieceSize)), limited])
                repeatCount(b, ClipRemote.maxParts) {
                    let piece = b.replace(padded, [.t(#"(?s)^(?:(?:.{\#(pieceSize)}){"#), .v("Repeat Index"), .t(#"}(.{1,\#(pieceSize)}).*|.*)$"#)], "$1")
                    ifHasValue(b, piece, then: {
                        let nonce = sendCommand(b, pairing: pairing, keys: keys, b.text([.t("clip part "), id, .t(" "), .v("Repeat Index"), .t("/"), count, .t(" "), piece]))
                        b.setVariable("cocaineLast", nonce)
                    })
                }
            }, otherwise: {
                b.show(b.text([.t(labels.noText)]))
                b.add("exit", [:])
            })
        }
        item(labels.getNewest)
        b.setVariable("cocaineCommand", b.text([.t("clip get")]))
        item(labels.list)
        b.setVariable("cocaineCommand", b.text([.t("clip list")]))
        item(labels.getItem)
        do {
            let asked = b.add("ask", ["WFAskActionPrompt": labels.itemPrompt, "WFInputType": "Text", "WFAllowsMultilineText": false], output: "Provided Input")
            let digits = b.replace(b.replace(asked, "[^0-9]", ""), "^(.{0,2}).*$", "$1")
            b.setVariable("cocaineCommand", b.text([.t("clip get "), digits]))
        }
        b.add("choosefrommenu", ["GroupingIdentifier": group, "WFControlFlowMode": 2])
        let command = b.text([.v("cocaineCommand")])
        ifHasValue(b, command, then: {                                     // get, list or a pinboard item (not set when sending)
            b.setVariable("cocaineLast", sendCommand(b, pairing: pairing, keys: keys, command))
        })

        // The answer to the last command sent (a longer text: its last piece), checked and decrypted; once more after a while.
        func answer() -> (ok: Part, text: Part) {
            b.add("delay", ["WFDelayTime": 5])
            let raw = b.get([.t("\(pairing.relay)/\(pairing.reply)/raw?poll=1&since=3m")])
            let line = b.replace(raw, [.t(#"(?s)^.*?(r2\."#), .v("cocaineLast"), .t(#"\.\S+).*$"#)], "$1")
            return receive(b, pairing: pairing, keys: keys, line: line, nonce: .v("cocaineLast"), noAnswer: labels.noAnswer)
        }
        let first = answer()
        b.setVariable("cocaineReply", first.text)
        ifHasValue(b, b.replace(first.ok, "^OK$", ""), then: {
            b.setVariable("cocaineReply", answer().text)
        })
        // "CLIP:<text>" (a genuine answer to `clip get`) goes on the clipboard; anything else is only shown.
        let reply = b.text([.v("cocaineReply")])
        let toCopy = b.replace(reply, #"(?s)^(?:CLIP:(.*)|.*)$"#, "$1")
        ifHasValue(b, toCopy, then: {
            b.add("setclipboard", ["WFInput": B.whole(toCopy)])
            b.show(b.text([.t(labels.copied + "\n"), toCopy]))
        }, otherwise: {
            b.show(reply)
        })
        return b.actions
    }

    // MARK: files

    /// The Shortcut as an (unsigned) property list; nil for Clip without a v2 pairing, or a folder Shortcuts can't reach.
    static func build(_ k: Kind, subpath: String?, pairing: Pairing?, labels: SyncShortcutLabels) -> Data? {
        let actions: [[String: Any]]
        var plist: [String: Any] = [
            "WFWorkflowClientVersion": "900", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientRelease": 900,
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [Any](), "WFWorkflowInputContentItemClasses": [String](), "WFWorkflowTypes": [String](),
        ]
        switch k {
        case .sendToMac:
            guard let s = subpath, ICloudPaths.validName(s) else { return nil }
            actions = sendToMac(subpath: s, labels: labels)
            // In the Share Sheet for text, links and images; run on its own (widget, Siri, Back Tap): the clipboard.
            plist["WFWorkflowTypes"] = ["ActionExtension"]
            plist["WFWorkflowInputContentItemClasses"] = ["WFStringContentItem", "WFURLContentItem", "WFImageContentItem", "WFRichTextContentItem"]
            plist["WFWorkflowNoInputBehavior"] = ["Name": "WFWorkflowNoInputBehaviorGetClipboard", "Parameters": [String: Any]()]
        case .getFromMac:
            guard let s = subpath, ICloudPaths.validName(s) else { return nil }
            actions = getFromMac(subpath: s, labels: labels)
        case .clip:
            guard let p = pairing, let a = clip(p, labels: labels) else { return nil }
            actions = a
        }
        plist["WFWorkflowActions"] = actions
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    /// Built and signed in a private temporary folder; nil when it can't be built or signing fails (offline, no iCloud).
    static func signedFile(_ k: Kind, subpath: String?, pairing: Pairing?, labels: SyncShortcutLabels = .localized,
                           sign: (URL, URL) -> Bool = { raw, out in
        run("/usr/bin/shortcuts", ["sign", "--mode", "people-who-know-me", "--input", raw.path, "--output", out.path]) == 0 }) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-sync-shortcut-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let raw = dir.appendingPathComponent("raw.shortcut"), out = dir.appendingPathComponent(fileName(k))
        guard let data = build(k, subpath: subpath, pairing: pairing, labels: labels), SafeFile.writePrivate(data, to: raw),
              sign(raw, out), FileManager.default.fileExists(atPath: out.path) else { try? FileManager.default.removeItem(at: dir); return nil }
        try? FileManager.default.removeItem(at: raw)
        return out
    }

    // MARK: what real Shortcuts accepts

    /// The actions and keys used here beyond the remote Shortcut's (RemoteShortcut.knownParameters), with the names found in
    /// the action definitions of WorkflowKit/ActionKit (macOS 27 dyld cache): Copy to Clipboard (WFInput, WFLocalOnly,
    /// WFExpirationDate), Get Clipboard, Save File (WFInput, WFFolder, WFSaveFileOverwrite, WFAskWhereToSave,
    /// WFFileDestinationPath "/Folder/File.txt"), Get File (WFShowFilePicker, WFGetFilePath "folder/file.txt",
    /// WFFileErrorIfNotFound), Set Name (WFInput, WFName, WFDontIncludeFileExtension: "Shortcuts will automatically include a
    /// file extension"), If (the legacy keys WFInput/WFCondition/WFConditionalActionString, mapped by Shortcuts to its
    /// newer Subject/Operator form), Repeat (WFRepeatCount; its round is the magic variable "Repeat Index"), Format Date's Custom
    /// style (WFDateFormat).
    static let knownParameters: [String: [String: Set<String>?]] = [
        "getclipboard": [:],
        "setclipboard": ["WFInput": nil, "WFLocalOnly": nil],
        "documentpicker.save": ["WFInput": nil, "WFAskWhereToSave": nil, "WFSaveFileOverwrite": nil, "WFFileDestinationPath": nil],
        "documentpicker.open": ["WFShowFilePicker": nil, "WFGetFilePath": nil, "WFFileErrorIfNotFound": nil],
        "setitemname": ["WFInput": nil, "WFName": nil, "WFDontIncludeFileExtension": nil],
        "conditional": ["GroupingIdentifier": nil, "WFControlFlowMode": nil, "WFCondition": nil, "WFInput": nil],
        "repeat.count": ["GroupingIdentifier": nil, "WFControlFlowMode": nil, "WFRepeatCount": nil],
        "format.date": ["WFDate": nil, "WFDateFormatStyle": ["Custom", "ISO 8601"], "WFDateFormat": nil, "WFISO8601IncludeTime": nil],
    ]

    /// The form each new input must have (as RemoteShortcut.inputShapes): a variable alone for what an action takes as its
    /// content, a text for names and paths.
    static let inputShapes: [String: [String: RemoteShortcut.Shape]] = [
        "setclipboard": ["WFInput": .attachment], "documentpicker.save": ["WFInput": .attachment, "WFFileDestinationPath": .text],
        "documentpicker.open": ["WFGetFilePath": .text], "setitemname": ["WFInput": .attachment, "WFName": .text],
    ]

    static func shape(_ id: String, _ key: String) -> RemoteShortcut.Shape? { inputShapes[id]?[key] ?? RemoteShortcut.inputShapes[id]?[key] }

    /// Structural checks (as RemoteShortcut.problems, for these Shortcuts): known actions, keys and values; inputs in the form
    /// each action takes; outputs and variables before use; menus and Ifs balanced, with matching branches; If only "has any
    /// value" (100) or "has no value" (101) on a whole variable; patterns compile; POSTs have a body; no file is ever read or
    /// written outside the sync folder.
    static func problems(_ data: Data, subpath: String? = nil) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let actions = plist["WFWorkflowActions"] as? [[String: Any]], !actions.isEmpty else { return ["not a property list"] }
        var problems: [String] = []
        var outputs = Set<String>(), variables = Set<String>()
        var stack: [(kind: String, group: String)] = []
        var menuItems: [String: [String]] = [:], menuBranches: [String: [String]] = [:]
        func refs(_ any: Any, _ w: String) {
            if let d = any as? [String: Any] {
                if let u = d["OutputUUID"] as? String, !outputs.contains(u) { problems.append("\(w): output used before it exists") }
                if d["Type"] as? String == "Variable", let n = d["VariableName"] as? String, !variables.contains(n),
                   !(n == "Repeat Index" && stack.contains { $0.kind == "repeat.count" }) { problems.append("\(w): variable \(n) used before it is set") }
                d.values.forEach { refs($0, w) }
            } else if let a = any as? [Any] { a.forEach { refs($0, w) } }
        }
        func string(_ any: Any?) -> String { ((any as? [String: Any])?["Value"] as? [String: Any])?["string"] as? String ?? "" }
        for (i, a) in actions.enumerated() {
            guard let full = a["WFWorkflowActionIdentifier"] as? String, full.hasPrefix("is.workflow.actions."),
                  let p = a["WFWorkflowActionParameters"] as? [String: Any] else { problems.append("#\(i): malformed"); continue }
            let id = String(full.dropFirst("is.workflow.actions.".count))
            let known = knownParameters[id] ?? RemoteShortcut.knownParameters[id]
            if known == nil { problems.append("#\(i): unknown action \(id)") }
            for (key, value) in p where key != "UUID" {
                guard let allowed = known?[key] ?? RemoteShortcut.knownParameters[id]?[key] else { problems.append("#\(i) \(id): unknown parameter \(key)"); continue }
                if let allowed, !allowed.contains(value as? String ?? "") { problems.append("#\(i) \(id): \(key) = \(value) is not a known value") }
            }
            for key in p.keys {
                if let s = shape(id, key), !RemoteShortcut.Shape.of(p[key]).fits(s) { problems.append("#\(i) \(id): \(key) must be given as \(s), not \(RemoteShortcut.Shape.of(p[key]))") }
            }
            if id == "downloadurl", p["WFHTTPMethod"] as? String == "POST", p["WFHTTPBodyType"] as? String != "File" || p["WFRequestVariable"] == nil { problems.append("#\(i): POST without a body") }
            if id == "documentpicker.save", p["WFAskWhereToSave"] as? Bool != false || p["WFSaveFileOverwrite"] as? Bool != false { problems.append("#\(i): Save File must not ask nor overwrite") }
            if id == "documentpicker.open", p["WFShowFilePicker"] as? Bool != false || p["WFFileErrorIfNotFound"] as? Bool != false { problems.append("#\(i): Get File must not ask nor stop when missing") }
            if let sub = subpath, id == "documentpicker.save" || id == "documentpicker.open" {
                let path = string(p[id == "documentpicker.save" ? "WFFileDestinationPath" : "WFGetFilePath"])
                let inbox = "/\(sub)/inbox/", outbox = "\(sub)/outbox/"
                if id == "documentpicker.save" ? !path.hasPrefix(inbox) : !(path == outbox + SyncOutbox.latestText || path == outbox + SyncOutbox.latestImage) {
                    problems.append("#\(i): a file outside the sync folder: \(path)")
                }
            }
            refs(p, "#\(i) \(id)")
            if id == "conditional" || id == "choosefrommenu" || id == "repeat.count", let mode = p["WFControlFlowMode"] as? Int {
                let g = p["GroupingIdentifier"] as? String ?? ""
                switch mode {
                case 0:
                    stack.append((id, g))
                    if id == "choosefrommenu" { menuItems[g] = p["WFMenuItems"] as? [String] ?? [] }
                    if id == "conditional" {
                        let c = p["WFCondition"] as? Int ?? -1
                        let input = p["WFInput"] as? [String: Any]
                        if c != 100 && c != 101 { problems.append("#\(i): If only with has any value / has no value") }
                        if input?["Type"] as? String != "Variable" || RemoteShortcut.Shape.of(input?["Variable"]) != .attachment { problems.append("#\(i): If needs a whole variable") }
                    }
                case 1:
                    if stack.last?.group != g { problems.append("#\(i): branch outside its block") }
                    if id == "choosefrommenu" { menuBranches[g, default: []].append(p["WFMenuItemTitle"] as? String ?? "") }
                case 2:
                    if stack.last?.group != g || stack.last?.kind != id { problems.append("#\(i): block closed out of order") } else { stack.removeLast() }
                default: problems.append("#\(i): unknown control flow mode")
                }
            }
            if id == "setvariable", let n = p["WFVariableName"] as? String { variables.insert(n) }
            if id == "text.replace", p["WFReplaceTextRegularExpression"] as? Bool == true {
                let s = string(p["WFReplaceTextFind"]).replacingOccurrences(of: "\u{FFFC}", with: "123")
                if (try? NSRegularExpression(pattern: s)) == nil { problems.append("#\(i): pattern doesn't compile: \(s)") }
            }
            if let u = p["UUID"] as? String { if outputs.contains(u) { problems.append("#\(i): duplicate UUID") }; outputs.insert(u) }
        }
        if !stack.isEmpty { problems.append("blocks not closed") }
        for (g, items) in menuItems {
            if Set(items).count != items.count || items.contains(where: \.isEmpty) { problems.append("menu items empty or repeated: \(items)") }
            if (menuBranches[g] ?? []).sorted() != items.sorted() { problems.append("menu items \(items) don't match their branches") }
        }
        return problems
    }

    // MARK: the panel's "Add the iPhone Shortcuts"

    /// Which one (in-app), then built, signed and offered: opened in Shortcuts (it syncs to the iPhone through iCloud) for the
    /// iCloud pair; the Clip one, which carries the pairing's keys, through the share list like the remote Shortcut.
    static func present(_ center: ClipSyncCenter, pairings: [Pairing], done: @escaping (String) -> Void) {
        let sub = center.settings.folderName
        var choices = [DialogChoice(id: Kind.sendToMac.rawValue, title: title(.sendToMac), symbol: "square.and.arrow.up"),
                       DialogChoice(id: Kind.getFromMac.rawValue, title: title(.getFromMac), symbol: "square.and.arrow.down")]
        let usable = pairings.filter { !$0.isLegacy && $0.keys != nil && !$0.expired(at: Date()) }
        for p in usable { choices.append(DialogChoice(id: "clip:" + p.id, title: "Cocaine Clip · " + String(p.id.prefix(6)), symbol: "lock.iphone")) }
        let spec = DialogSpec(icon: "iphone", title: L("Add the iPhone Shortcuts"),
                              message: L("Cocaine makes the Shortcut and signs it (this needs an internet connection and iCloud). “Send to Mac” and “Get from Mac” open in Shortcuts on this Mac and reach the iPhone through iCloud; they need iCloud Drive on both. “Cocaine Clip” carries your pairing's key: send it like the remote Shortcut."),
                              choices: choices, choiceMode: .act, buttons: [Dialogs.cancel])
        DialogCenter.shared.present(spec) { r in
            guard case .choice(let id) = r else { return }
            let pairing = id.hasPrefix("clip:") ? usable.first { "clip:" + $0.id == id } : nil
            let kind = pairing != nil ? Kind.clip : Kind(rawValue: id) ?? .sendToMac
            done(L("Signing…"))
            DispatchQueue.global().async {
                let file = signedFile(kind, subpath: sub, pairing: pairing)
                DispatchQueue.main.async {
                    guard let file else { done(L("Signing it needs an internet connection and iCloud (sign in to it in System Settings).")); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 600) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                    if kind == .clip {
                        let services = Sharing.services(for: [file])
                        DialogCenter.shared.present(Dialogs.share(services)) { r in
                            guard case .choice(let c) = r else { return }
                            if c == "finder" { NSWorkspace.shared.activateFileViewerSelecting([file]); return }
                            guard let i = Int(c.dropFirst()), services.indices.contains(i) else { return }
                            Sharing.shared.perform(services[i], [file], surface: .panel)
                        }
                        done(String(format: L("“%@” is ready to send"), title(kind)))
                    } else {
                        NSWorkspace.shared.open(file)
                        done(String(format: L("“%@” opened in Shortcuts"), title(kind)))
                    }
                }
            }
        }
    }
}

/// `--make-sync-shortcut send|get|clip <path>`, run from main.swift (maintainers): builds and signs one of them (Clip with a
/// throwaway pairing) and copies it to `path`. Never opened, never added to Shortcuts.
func cliMakeSyncShortcut() {
    let a = CommandLine.arguments
    let kind: SyncShortcuts.Kind = a[2] == "get" ? .getFromMac : a[2] == "clip" ? .clip : .sendToMac
    let pairing = kind == .clip ? Pairing.make(tier: "basic", relay: "https://relay.test") : nil
    guard let f = SyncShortcuts.signedFile(kind, subpath: ICloudPaths.defaultName, pairing: pairing, labels: SyncShortcutLabels()) else { print("could not sign"); exit(1) }
    try? FileManager.default.removeItem(atPath: a[3])
    try? FileManager.default.copyItem(at: f, to: URL(fileURLWithPath: a[3]))
    try? FileManager.default.removeItem(at: f.deletingLastPathComponent())
    print("ok")
    exit(0)
}
