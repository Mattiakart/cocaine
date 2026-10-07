// The Mac Shortcuts pack: four ready-made shortcuts Cocaine builds, signs (/usr/bin/shortcuts sign, like the iPhone one) and
// opens in the Shortcuts app to add: Keep Awake… (asks how: until turned off, minutes, a time), Keep Awake Off, Toggle Keep
// Awake, Keep Awake Status (returns a Dictionary). They are ordinary shortcuts made of Shortcuts' own "Open X-Callback URL"
// action calling cocaine:// links (the same gate: "Shortcuts app and links", or Cocaine asks once): NOT native App Intents
// actions (those need an Apple-issued signing identity; docs/maintainers/app-intents.md). Built with RemoteShortcut.Builder.
// Signing needs an internet connection and iCloud. Tests: AwakeShortcutTests (part of --awake-test), structure only: they
// never sign, import or run anything.

import AppKit

enum AwakeShortcuts {
    enum Kind: String, CaseIterable { case keepAwake, off, toggle, status }

    static func title(_ k: Kind) -> String {
        switch k {
        case .keepAwake: return L("Keep Awake…")
        case .off: return L("Keep Awake Off")
        case .toggle: return L("Toggle Keep Awake")
        case .status: return L("Keep Awake Status")
        }
    }

    static func symbol(_ k: Kind) -> String {
        switch k {
        case .keepAwake: return "cup.and.saucer"
        case .off: return "moon.zzz"
        case .toggle: return "arrow.left.arrow.right"
        case .status: return "list.bullet.rectangle"
        }
    }

    /// The file's name is the shortcut's name in the Shortcuts app.
    static func fileName(_ k: Kind) -> String {
        let t = title(k).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "/", with: "-")
        return "Cocaine – \(t).shortcut"
    }

    /// Shortcuts' own x-callback action: it adds x-success/x-error itself; the reply's values come back as a Dictionary.
    private static func callback(_ b: RemoteShortcut.Builder, _ url: [RemoteShortcut.Part]) -> RemoteShortcut.Part {
        b.add("openxcallbackurl", ["WFXCallbackURL": RemoteShortcut.Builder.token(url), "WFXCallbackCustomCallbackEnabled": false],
              output: "X-Callback Result")
    }

    static func actions(_ k: Kind) -> [[String: Any]] {
        let b = RemoteShortcut.Builder()
        let base = "cocaine://x-callback-url/"
        switch k {
        case .off: _ = callback(b, [.t(base + "off")])
        case .toggle: _ = callback(b, [.t(base + "toggle")])
        case .status:
            let r = callback(b, [.t(base + "status")])
            b.add("output", ["WFOutput": RemoteShortcut.Builder.token([r])])
        case .keepAwake:
            let g = UUID().uuidString
            let items = [L("Until I turn it off"), L("For some minutes…"), L("Until a time…")]
            b.add("choosefrommenu", ["GroupingIdentifier": g, "WFControlFlowMode": 0, "WFMenuPrompt": L("Keep the Mac awake"), "WFMenuItems": items])
            func item(_ t: String) { b.add("choosefrommenu", ["GroupingIdentifier": g, "WFControlFlowMode": 1, "WFMenuItemTitle": t]) }
            item(items[0])
            _ = callback(b, [.t(base + "on?timer=off")])
            item(items[1])
            let n = b.add("ask", ["WFAskActionPrompt": L("For how many minutes? (1 to 1440)"), "WFInputType": "Number",
                                  "WFAskActionAllowsDecimalNumbers": false, "WFAskActionAllowsNegativeNumbers": false], output: "Provided Input")
            let digits = b.replace(n, "[^0-9]", "")                // "1.440" in some languages: only the digits go into the link
            _ = callback(b, [.t(base + "on?minutes="), digits])
            item(items[2])
            let t = b.add("ask", ["WFAskActionPrompt": L("Until what time?"), "WFInputType": "Time"], output: "Provided Input")
            let f = b.add("format.date", ["WFDateFormatStyle": "Custom", "WFDateFormat": "HH:mm", "WFDate": RemoteShortcut.Builder.token([t])],
                          output: "Formatted Date")
            _ = callback(b, [.t(base + "on?until="), f])
            b.add("choosefrommenu", ["GroupingIdentifier": g, "WFControlFlowMode": 2])
        }
        return b.actions
    }

    /// The shortcut as an (unsigned) property list.
    static func build(_ k: Kind) -> Data? {
        let plist: [String: Any] = [
            "WFWorkflowClientVersion": "900", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientRelease": 900,
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowActions": actions(k), "WFWorkflowInputContentItemClasses": [String](), "WFWorkflowTypes": [String](),
            "WFWorkflowImportQuestions": [Any](), "WFWorkflowOutputContentItemClasses": k == .status ? ["WFDictionaryContentItem"] : [String](),
            "WFWorkflowHasOutputFallback": false,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    /// Built and signed in a private temporary folder; nil when signing fails (offline, or not signed in to iCloud).
    static func signedFile(_ k: Kind, sign: (URL, URL) -> Bool = { raw, out in
        run("/usr/bin/shortcuts", ["sign", "--mode", "people-who-know-me", "--input", raw.path, "--output", out.path]) == 0 }) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-mac-shortcut-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let raw = dir.appendingPathComponent("raw.shortcut"), out = dir.appendingPathComponent(fileName(k))
        guard let data = build(k), SafeFile.writePrivate(data, to: raw), sign(raw, out), FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: dir); return nil
        }
        try? FileManager.default.removeItem(at: raw)
        return out
    }

    /// The panel's "Add to Shortcuts…": which one (in-app), then built, signed and opened in Shortcuts, which asks to add it.
    static func present(_ model: AwakeModel) {
        let choices = Kind.allCases.map { DialogChoice(id: $0.rawValue, title: title($0), symbol: symbol($0)) }
        let spec = DialogSpec(icon: "square.stack.3d.up", title: L("Add to Shortcuts"),
                              message: L("Cocaine makes the shortcut, signs it (this needs an internet connection and iCloud) and opens it in Shortcuts, which asks you to add it. It calls Cocaine through its cocaine:// links: these are ordinary shortcuts, not native Shortcuts actions."),
                              choices: choices, choiceMode: .act, buttons: [Dialogs.cancel])
        DialogCenter.shared.present(spec) { r in
            guard case .choice(let id) = r, let k = Kind(rawValue: id) else { return }
            model.packBusy = true
            model.packNote = nil
            DispatchQueue.global().async {
                let file = signedFile(k)
                DispatchQueue.main.async {
                    model.packBusy = false
                    guard let file else {
                        model.packNote = L("Signing it needs an internet connection and iCloud (sign in to it in System Settings).")
                        return
                    }
                    model.packNote = String(format: L("“%@” opened in Shortcuts"), title(k))
                    NSWorkspace.shared.open(file)
                    log.notice("mac shortcut ready: \(file.lastPathComponent, privacy: .public)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 600) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                }
            }
        }
    }

    // MARK: Structure checks (what Shortcuts accepts)

    /// The actions and parameters this pack uses, beyond the iPhone Shortcut's (RemoteShortcut.knownParameters): names as in
    /// WorkflowKit/ActionKit on macOS 27 (nil: any value).
    static let knownParameters: [String: [String: Set<String>?]] = [
        "openxcallbackurl": ["WFXCallbackURL": nil, "WFXCallbackCustomCallbackEnabled": nil],
        "ask": ["WFAskActionPrompt": nil, "WFInputType": ["Text", "Number", "Time"], "WFAskActionAllowsDecimalNumbers": nil,
                "WFAskActionAllowsNegativeNumbers": nil, "WFAllowsMultilineText": nil],
        "format.date": ["WFDate": nil, "WFDateFormatStyle": ["Custom", "ISO 8601"], "WFDateFormat": nil, "WFISO8601IncludeTime": nil],
        "output": ["WFOutput": nil],
    ]

    static func problems(_ data: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let actions = plist["WFWorkflowActions"] as? [[String: Any]], !actions.isEmpty else { return ["not a property list"] }
        var problems: [String] = [], outputs = Set<String>(), depth = 0
        var items: [String: [String]] = [:], branches: [String: [String]] = [:]
        func refs(_ any: Any, _ w: String) {
            if let d = any as? [String: Any] {
                if let u = d["OutputUUID"] as? String, !outputs.contains(u) { problems.append("\(w): output used before it exists") }
                d.values.forEach { refs($0, w) }
            } else if let a = any as? [Any] { a.forEach { refs($0, w) } }
        }
        for (i, a) in actions.enumerated() {
            guard let full = a["WFWorkflowActionIdentifier"] as? String, full.hasPrefix("is.workflow.actions."),
                  let p = a["WFWorkflowActionParameters"] as? [String: Any] else { problems.append("#\(i): malformed"); continue }
            let id = String(full.dropFirst("is.workflow.actions.".count))
            let known = knownParameters[id] ?? RemoteShortcut.knownParameters[id]
            if known == nil { problems.append("#\(i): unknown action \(id)") }
            for (key, value) in p where key != "UUID" {
                guard let allowed = known?[key] ?? RemoteShortcut.knownParameters[id]?[key] else { problems.append("#\(i) \(id): unknown parameter \(key)"); continue }
                if let allowed, !allowed.contains(value as? String ?? "") { problems.append("#\(i) \(id): \(key) = \(value)") }
            }
            if id == "openxcallbackurl" {
                let s = ((p["WFXCallbackURL"] as? [String: Any])?["Value"] as? [String: Any])?["string"] as? String ?? ""
                if !s.hasPrefix("cocaine://x-callback-url/") { problems.append("#\(i): calls something other than cocaine://") }
            }
            refs(p, "#\(i) \(id)")
            if id == "choosefrommenu", let mode = p["WFControlFlowMode"] as? Int {
                let g = p["GroupingIdentifier"] as? String ?? ""
                if mode == 0 { depth += 1; items[g] = p["WFMenuItems"] as? [String] ?? [] }
                if mode == 1 { branches[g, default: []].append(p["WFMenuItemTitle"] as? String ?? "") }
                if mode == 2 { depth -= 1 }
                if depth < 0 { problems.append("#\(i): menu closed before it opened") }
            }
            if let u = p["UUID"] as? String { if outputs.contains(u) { problems.append("#\(i): duplicate UUID") }; outputs.insert(u) }
        }
        if depth != 0 { problems.append("menus not balanced") }
        for (g, list) in items where (branches[g] ?? []).sorted() != list.sorted() || Set(list).count != list.count {
            problems.append("menu items \(list) don't match their branches")
        }
        return problems
    }
}

enum AwakeShortcutTests {
    static func run(_ check: (String, Bool) -> Void) {
        for k in AwakeShortcuts.Kind.allCases {
            let data = AwakeShortcuts.build(k)
            let p = data.map(AwakeShortcuts.problems) ?? ["not built"]
            check("shortcut \(k.rawValue): built, known actions and keys only, menus balanced\(p.isEmpty ? "" : ": " + p.joined(separator: "; "))", p.isEmpty)
        }
        // Every link the pack opens is one Cocaine accepts (and only the guarded ones change anything).
        let urls = AwakeShortcuts.Kind.allCases.flatMap { k in
            AwakeShortcuts.actions(k).compactMap { a -> String? in
                guard a["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.openxcallbackurl" else { return nil }
                let v = ((a["WFWorkflowActionParameters"] as? [String: Any])?["WFXCallbackURL"] as? [String: Any])?["Value"] as? [String: Any]
                return (v?["string"] as? String)?.replacingOccurrences(of: "\u{FFFC}", with: k == .keepAwake ? "" : "")
            }
        }
        check("shortcuts: six links (on×3, off, toggle, status)", urls.count == 6)
        let noon = Date(timeIntervalSince1970: 1791367200)
        func ok(_ s: String) -> ControlRequest? { try? ControlURL.parse(URL(string: s)!, now: noon, calendar: AwakeTests.rome).get() }
        check("shortcuts: 'until I turn it off' is on with no timer", ok("cocaine://x-callback-url/on?timer=off")?.action == .on(minutes: 0))
        check("shortcuts: the minutes and time links work once filled in", ok("cocaine://x-callback-url/on?minutes=90")?.action == .on(minutes: 90)
              && ok("cocaine://x-callback-url/on?until=18:30")?.until?.timeIntervalSince1970 == 1791390600)
        check("links: timer=off only with on, and never with minutes or until", ok("cocaine://off?timer=off") == nil && ok("cocaine://on?timer=off&minutes=5") == nil
              && ok("cocaine://on?timer=off&until=18:30") == nil && ok("cocaine://on?timer=yes") == nil)
        check("shortcuts: off, toggle and status links parse", ok(urls.first { $0.hasSuffix("/off") } ?? "")?.action == .off
              && ok(urls.first { $0.hasSuffix("/toggle") } ?? "")?.action == .toggle && ok(urls.first { $0.hasSuffix("/status") } ?? "")?.action == .status)
        let status = AwakeShortcuts.build(.status).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        check("shortcuts: Status outputs a Dictionary", (status?["WFWorkflowOutputContentItemClasses"] as? [String]) == ["WFDictionaryContentItem"])
        check("shortcuts: file names are the shortcuts' names, no path characters",
              AwakeShortcuts.Kind.allCases.allSatisfy { let f = AwakeShortcuts.fileName($0); return f.hasSuffix(".shortcut") && !f.contains("/") && f.hasPrefix("Cocaine – ") })
        let bad = AwakeShortcuts.problems(try! PropertyListSerialization.data(fromPropertyList: ["WFWorkflowActions": [
            ["WFWorkflowActionIdentifier": "is.workflow.actions.runshellscript", "WFWorkflowActionParameters": ["Script": "rm -rf ~"]]]], format: .binary, options: 0))
        check("shortcuts: the check refuses an action it doesn't know (a shell script)", !bad.isEmpty)
        var signed: [String] = []
        let f = AwakeShortcuts.signedFile(.toggle) { raw, out in signed.append(raw.lastPathComponent); return (try? FileManager.default.copyItem(at: raw, to: out)) != nil }
        check("shortcuts: signing gets the built file and the result is named for Shortcuts (fake signer)", f?.lastPathComponent == AwakeShortcuts.fileName(.toggle) && signed == ["raw.shortcut"])
        if let f {
            check("shortcuts: in a private folder, the unsigned copy removed", (try? FileManager.default.attributesOfItem(atPath: f.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700
                  && !FileManager.default.fileExists(atPath: f.deletingLastPathComponent().appendingPathComponent("raw.shortcut").path))
            try? FileManager.default.removeItem(at: f.deletingLastPathComponent())
        }
        check("shortcuts: a failed signing leaves nothing", AwakeShortcuts.signedFile(.off) { _, _ in false } == nil)
    }
}
