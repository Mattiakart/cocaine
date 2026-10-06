import Foundation

/// The iPhone Shortcut for protocol v2 (see RemoteProtocol.swift), as Shortcuts actions. It uses only built-in actions —
/// Text, Set Variable, Generate Hash, Base64 Encode, Replace Text (regular expressions), URL Decode, Date, Format Date,
/// Random Number, Get Contents of URL, Wait, Ask, Choose from Menu, Show Result, Stop — and no loops or conditions:
///  • text ↔ bits by table replacements (a symbol followed by a comma can only be the original, so the order is safe),
///  • XOR by putting ciphertext and keystream in one string and pairing each bit with the one exactly N characters later
///    in a single regular expression, then two replacements for the XOR table,
///  • the tag check by a back-reference ("^(tag)=\1$" → OK), which also gates what is decrypted and shown.
/// Nothing the user types is ever put into a pattern or a URL as is: it is Base64-encoded, then encrypted.
struct RemoteShortcutLabels {
    var status = "Status", turnOn = "Turn on", turnOff = "Turn off", projects = "Projects", command = "Command"
    var lastReply = "Last reply"
    var prompt = "Command (for example: start claude my-project Fix the tests)"
    var noAnswer = "No valid answer yet. If the Mac is asleep, try “Last reply” in a few minutes."
}

enum RemoteShortcut {
    /// Parts of a text with variables in it.
    enum Part { case t(String), out(String, String), v(String) }

    final class Builder {
        var actions: [[String: Any]] = []

        static func attachment(_ p: Part) -> [String: Any] {
            switch p {
            case .out(let uuid, let name): return ["OutputUUID": uuid, "Type": "ActionOutput", "OutputName": name]
            case .v(let name): return ["Type": "Variable", "VariableName": name]
            case .t: return [:]
            }
        }
        /// A WFTextTokenString: literal text with outputs/variables at their (UTF-16) positions.
        static func token(_ parts: [Part]) -> [String: Any] {
            var s = ""
            var attachments: [String: Any] = [:]
            for p in parts {
                if case .t(let x) = p { s += x; continue }
                attachments["{\((s as NSString).length), 1}"] = attachment(p)
                s += "\u{FFFC}"
            }
            return ["Value": ["string": s, "attachmentsByRange": attachments], "WFSerializationType": "WFTextTokenString"]
        }
        static func whole(_ p: Part) -> [String: Any] { ["Value": attachment(p), "WFSerializationType": "WFTextTokenAttachment"] }

        @discardableResult
        func add(_ id: String, _ params: [String: Any], output: String? = nil) -> Part {
            var params = params
            let uuid = UUID().uuidString
            params["UUID"] = uuid
            actions.append(["WFWorkflowActionIdentifier": "is.workflow.actions.\(id)", "WFWorkflowActionParameters": params])
            return .out(uuid, output ?? id)
        }
        func text(_ parts: [Part]) -> Part { add("gettext", ["WFTextActionText": Self.token(parts)], output: "Text") }
        func replace(_ input: Part, _ find: [Part], _ with: String, regex: Bool = true, caseSensitive: Bool = true) -> Part {
            add("text.replace", ["WFInput": Self.token([input]), "WFReplaceTextFind": Self.token(find), "WFReplaceTextReplace": with,
                                 "WFReplaceTextRegularExpression": regex, "WFReplaceTextCaseSensitive": caseSensitive], output: "Updated Text")
        }
        func replace(_ input: Part, _ find: String, _ with: String, regex: Bool = true, caseSensitive: Bool = true) -> Part {
            replace(input, [.t(find)], with, regex: regex, caseSensitive: caseSensitive)
        }
        /// Generate Hash and Base64 Encode take their input as a variable (WFTextTokenAttachment): given a text with the
        /// variable inside (WFTextTokenString) they silently output nothing (seen in Shortcuts on macOS 27 and iOS).
        func hash(_ input: Part, _ type: String) -> Part {
            add("hash", ["WFInput": Self.whole(input), "WFHashType": type], output: "Hash")
        }
        func get(_ url: [Part]) -> Part { add("downloadurl", ["WFURL": Self.token(url), "WFHTTPMethod": "GET"], output: "Contents of URL") }
        /// POST `body` (a variable, sent as is) to a fixed URL. Variable content never goes into a URL: Get Contents of URL
        /// finds the link in its text with a data detector, which cuts some long query strings short (seen on macOS 27).
        func post(_ url: String, body: Part) -> Part {
            add("downloadurl", ["WFURL": Self.token([.t(url)]), "WFHTTPMethod": "POST", "WFHTTPBodyType": "File",
                                "WFRequestVariable": Self.whole(body)], output: "Contents of URL")
        }
        func setVariable(_ name: String, _ input: Part) { add("setvariable", ["WFVariableName": name, "WFInput": Self.whole(input)]) }
        func show(_ input: Part) { add("showresult", ["Text": Self.token([input])]) }
    }

    static let hexBits: [(Character, String)] = Array("0123456789abcdef").enumerated().map { i, c in
        (c, String((0..<4).reversed().map { (i >> $0) & 1 == 1 ? "1" : "0" }))
    }
    static func sixBits(_ i: Int) -> String { String((0..<6).reversed().map { (i >> $0) & 1 == 1 ? "1" : "0" }) }

    /// Keystream as "x"/"y" bits (a different alphabet from the content's 0/1, so one pattern can tell them apart).
    static func keystream(_ b: Builder, keys: RemoteKeys, dir: String, nonce: Part, ts: Part, blocks: Int) -> Part {
        var hashes: [Part] = []
        for i in 0..<blocks {
            hashes.append(b.hash(b.text([.t(keys.enc + "|\(dir)|"), nonce, .t("|"), ts, .t("|\(i)")]), "SHA512"))
        }
        var k = b.text(hashes)
        for (c, bits) in hexBits {
            k = b.replace(k, String(c), bits.replacingOccurrences(of: "0", with: "x").replacingOccurrences(of: "1", with: "y"),
                          regex: false, caseSensitive: false)
        }
        return k
    }

    /// content (0/1, `count` long) XOR keystream (x/y): pair each bit with the one `count`+1 characters later.
    static func xor(_ b: Builder, _ content: Part, _ key: Part, count: [Part]) -> Part {
        let joined = b.text([content, .t("#"), key])
        let paired = b.replace(joined, [.t("([01])(?=.{")] + count + [.t("}([xy]))")], "$1$2")
        let cut = b.replace(paired, "#.*$", "")
        return b.replace(b.replace(cut, "0x|1y", "0"), "0y|1x", "1")
    }

    /// Base64 (either alphabet) → bits.
    static func base64Bits(_ b: Builder, _ input: Part, alphabet: [Character]) -> Part {
        let set = alphabet == RemoteCrypto.url ? "A-Za-z0-9_-" : "A-Za-z0-9+/"
        var s = b.replace(b.replace(input, "[^\(set)]", ""), "([\(set)])", "$1,")
        for (i, c) in alphabet.enumerated() { s = b.replace(s, "\(c),", sixBits(i), regex: false) }
        return s
    }

    /// The MAC of `m` (see RemoteCrypto.mac).
    static func mac(_ b: Builder, keys: RemoteKeys, _ m: [Part]) -> Part {
        let inner = b.hash(b.text([.t(keys.macIn)] + m), "SHA256")
        return b.hash(b.text([.t(keys.macOut), inner]), "SHA256")
    }

    /// Checks and decrypts an answer line (r2.…) for the request `nonce`, and shows it — or the "no valid answer" text.
    static func receive(_ b: Builder, pairing: Pairing, keys: RemoteKeys, line: Part, nonce: Part, labels: RemoteShortcutLabels) {
        let ts = b.replace(line, #"^r2\.\d+\.([^.]+)\..*$"#, "$1")
        let n0 = b.replace(line, #"^r2\.\d+\.[^.]+\.(\d{1,5})\..*$"#, "$1")
        let n = b.replace(n0, #"(?s)^(?!\d{1,5}$).*$"#, "0")              // never anything but digits in the next pattern
        let ct = b.replace(line, #"^r2\.\d+\.[^.]+\.\d+\.([A-Za-z0-9_-]+)\.[0-9a-fA-F]{64}$"#, "$1")
        let tag = b.replace(line, #"^.*\.([0-9a-fA-F]{64})$"#, "$1")
        let expected = mac(b, keys: keys, [.t("r2|\(pairing.id)|"), nonce, .t("|"), ts, .t("|"), n, .t("|"), ct])
        let ok = b.replace(b.replace(b.text([expected, .t("="), tag]), #"(?is)^([0-9a-f]{64})=\1$"#, "OK"), #"(?s)^(?!OK$).*$"#, "BAD")
        let gated = b.replace(b.text([ok, .t(":"), ct]), #"(?s)^(?:OK:([A-Za-z0-9_-]*)|.*)$"#, "$1")
        let bits = base64Bits(b, gated, alphabet: RemoteCrypto.url)
        let key = keystream(b, keys: keys, dir: "r", nonce: nonce, ts: ts, blocks: RemoteProtocol.replyBlocks)
        var hex = b.replace(xor(b, bits, key, count: [n]), "([01]{4})", "$1,")
        for (c, bits) in hexBits { hex = b.replace(hex, bits + ",", String(c), regex: false) }
        let decoded = b.add("urlencode", ["WFEncodeMode": "Decode", "WFInput": Builder.token([b.replace(hex, "([0-9a-f]{2})", "%$1")])],
                            output: "URL Decoded Text")
        let shown = b.replace(b.replace(b.text([ok, .t("\n"), decoded]), #"(?s)^OK\n"#, ""), #"(?s)^BAD\n.*$"#, labels.noAnswer)
        b.show(b.replace(shown, " +$", ""))
    }

    static func actions(_ pairing: Pairing, labels: RemoteShortcutLabels) -> [[String: Any]]? {
        guard let keys = pairing.keys, !pairing.isLegacy else { return nil }
        let b = Builder()
        let relay = pairing.relay
        let fixed: [(String, String)] = [(labels.status, "status"), (labels.turnOn, "on"), (labels.turnOff, "off"), (labels.projects, "projects")]
        let group = UUID().uuidString
        b.add("choosefrommenu", ["GroupingIdentifier": group, "WFControlFlowMode": 0, "WFMenuPrompt": "Cocaine",
                                 "WFMenuItems": fixed.map(\.0) + [labels.command, labels.lastReply]])
        func item(_ title: String) {
            b.add("choosefrommenu", ["GroupingIdentifier": group, "WFControlFlowMode": 1, "WFMenuItemTitle": title])
        }
        for (title, command) in fixed { item(title); b.setVariable("cocaineCommand", b.text([.t(command)])) }
        item(labels.command)
        let asked = b.add("ask", ["WFAskActionPrompt": labels.prompt, "WFInputType": "Text", "WFAllowsMultilineText": false], output: "Provided Input")
        b.setVariable("cocaineCommand", b.text([asked]))
        item(labels.lastReply)
        do {   // the newest answer of the last 30 minutes, whatever it answered
            let raw = b.get([.t("\(relay)/\(pairing.reply)/raw?poll=1&since=30m")])
            let line = b.replace(raw, #"(?s)^.*(r2\.\d+\.\S+)\s*$"#, "$1")
            let nonce = b.replace(line, #"^r2\.(\d{1,40})\..*$"#, "$1")
            receive(b, pairing: pairing, keys: keys, line: line, nonce: nonce, labels: labels)
            b.add("exit", [:])
        }
        b.add("choosefrommenu", ["GroupingIdentifier": group, "WFControlFlowMode": 2])

        // A fresh nonce (≈ 90 random bits) and the time, both reduced to safe characters.
        let r = (0..<3).map { _ in b.add("number.random", ["WFRandomNumberMinimum": 100_000_000, "WFRandomNumberMaximum": 999_999_999], output: "Random Number") }
        let nonce = b.replace(b.text(r), "[^0-9]", "")
        let now = b.add("date", ["WFDateActionMode": "Current Date"], output: "Date")
        let iso = b.add("format.date", ["WFDateFormatStyle": "ISO 8601", "WFISO8601IncludeTime": true, "WFDate": Builder.token([now])],
                        output: "Formatted Date")
        let ts = b.replace(b.replace(b.replace(iso, #"[.,][0-9]+"#, ""), "[^0-9TZ:+-]", ""), "+", "p", regex: false)

        // The command → Base64 → bits, padded/cut to the fixed size, XOR keystream → Base64url.
        let plain = b.text([.v("cocaineCommand"), .t("\n")])
        let b64 = b.add("base64encode", ["WFEncodeMode": "Encode", "WFBase64LineBreakMode": "None", "WFInput": Builder.whole(plain)],
                        output: "Base64 Encoded")
        let bits = base64Bits(b, b64, alphabet: RemoteCrypto.std)
        let size = RemoteProtocol.commandBits
        let fixedSize = b.replace(b.text([bits, .t(String(repeating: "0", count: size))]), "^([01]{\(size)}).*$", "$1")
        let key = keystream(b, keys: keys, dir: "c", nonce: nonce, ts: ts, blocks: RemoteProtocol.commandBlocks)
        var ct = b.replace(xor(b, fixedSize, key, count: [.t(String(size))]), "([01]{6})", "$1,")
        for (i, c) in RemoteCrypto.url.enumerated() { ct = b.replace(ct, sixBits(i) + ",", String(c), regex: false) }
        let tag = mac(b, keys: keys, [.t("c2|\(pairing.id)|"), nonce, .t("|"), ts, .t("|"), ct])
        let message = b.text([.t("c2.\(pairing.id)."), nonce, .t("."), ts, .t("."), ct, .t("."), tag])
        _ = b.post("\(relay)/\(pairing.cmd)?firebase=no", body: message)
        b.add("delay", ["WFDelayTime": 5])

        // Only the answer to this very request (its nonce), checked and decrypted.
        let raw = b.get([.t("\(relay)/\(pairing.reply)/raw?poll=1&since=3m")])
        let line = b.replace(raw, [.t(#"(?s)^.*?(r2\."#), nonce, .t(#"\.\S+).*$"#)], "$1")
        receive(b, pairing: pairing, keys: keys, line: line, nonce: nonce, labels: labels)
        return b.actions
    }

    /// The shortcut as an (unsigned) property list. Sign it before sharing: an iPhone refuses unsigned files.
    static func build(_ pairing: Pairing, labels: RemoteShortcutLabels) -> Data? {
        guard let actions = actions(pairing, labels: labels) else { return nil }
        let plist: [String: Any] = [
            "WFWorkflowClientVersion": "900", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientRelease": 900,
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowActions": actions, "WFWorkflowInputContentItemClasses": [String](), "WFWorkflowTypes": [String](),
            "WFWorkflowImportQuestions": [Any](),
        ]
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    // MARK: what real Shortcuts accept (ground truth)

    /// How a parameter is given: a variable alone (WFTextTokenAttachment), a text with variables in it
    /// (WFTextTokenString with attachments), or a text without variables.
    enum Shape: Equatable {
        case attachment, text, constant, other
        static func of(_ any: Any?) -> Shape {
            guard let d = any as? [String: Any] else { return any is String ? .constant : .other }
            switch d["WFSerializationType"] as? String {
            case "WFTextTokenAttachment": return .attachment
            case "WFTextTokenString":
                let atts = ((d["Value"] as? [String: Any])?["attachmentsByRange"] as? [String: Any]) ?? [:]
                return atts.isEmpty ? .constant : .text
            default: return .other
            }
        }
        /// A constant is a text too; nothing else stands in for another form.
        func fits(_ required: Shape) -> Bool { self == required || (self == .constant && required == .text) }
    }

    /// The form each input must have, as seen running the generated Shortcut in Shortcuts (macOS 27, it_IT): in any
    /// other form the action silently outputs nothing. Generate Hash and Base64 Encode with a text containing the
    /// variable gave "" (the cause of every v2 command arriving without a tag); Format Date and URL Decode, on the
    /// contrary, gave "" with a bare variable. A URL with variable content is cut short by Get Contents of URL's link
    /// detection, so variable content travels only in a POST body.
    static let inputShapes: [String: [String: Shape]] = [
        "hash": ["WFInput": .attachment], "base64encode": ["WFInput": .attachment], "setvariable": ["WFInput": .attachment],
        "format.date": ["WFDate": .text], "urlencode": ["WFInput": .text], "gettext": ["WFTextActionText": .text],
        "text.replace": ["WFInput": .text, "WFReplaceTextFind": .text], "showresult": ["Text": .text],
        "downloadurl": ["WFURL": .constant, "WFRequestVariable": .attachment],
    ]

    /// Every action and parameter key the builder may use, with the values Shortcuts knows (from the action definitions
    /// in WorkflowKit/ActionKit; nil: any value). A misspelt key is silently ignored by Shortcuts, so it's an error here.
    static let knownParameters: [String: [String: Set<String>?]] = [
        "gettext": ["WFTextActionText": nil],
        "setvariable": ["WFVariableName": nil, "WFInput": nil],
        "hash": ["WFInput": nil, "WFHashType": ["MD5", "SHA1", "SHA256", "SHA512"]],
        "base64encode": ["WFInput": nil, "WFEncodeMode": ["Encode", "Decode"], "WFBase64LineBreakMode": ["None", "Every 64 Characters", "Every 76 Characters"]],
        "text.replace": ["WFInput": nil, "WFReplaceTextFind": nil, "WFReplaceTextReplace": nil, "WFReplaceTextRegularExpression": nil,
                         "WFReplaceTextCaseSensitive": nil],
        "urlencode": ["WFInput": nil, "WFEncodeMode": ["Encode", "Decode"]],
        "date": ["WFDateActionMode": ["Current Date", "Specified Date"]],
        "format.date": ["WFDate": nil, "WFDateFormatStyle": ["ISO 8601"], "WFISO8601IncludeTime": nil],
        "number.random": ["WFRandomNumberMinimum": nil, "WFRandomNumberMaximum": nil],
        "downloadurl": ["WFURL": nil, "WFHTTPMethod": ["GET", "POST"], "WFHTTPBodyType": ["File"], "WFRequestVariable": nil],
        "delay": ["WFDelayTime": nil],
        "ask": ["WFAskActionPrompt": nil, "WFInputType": ["Text"], "WFAllowsMultilineText": nil],
        "choosefrommenu": ["GroupingIdentifier": nil, "WFControlFlowMode": nil, "WFMenuPrompt": nil, "WFMenuItems": nil, "WFMenuItemTitle": nil],
        "showresult": ["Text": nil],
        "exit": [:],
    ]

    /// Structural checks of a built Shortcut: known actions, keys and values only, inputs in the form each action takes,
    /// every output used is produced earlier, every variable is set before use, menus are balanced, every constant
    /// pattern compiles. Returns the problems found.
    static func problems(_ data: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let actions = plist["WFWorkflowActions"] as? [[String: Any]] else { return ["not a property list"] }
        let known = Set(knownParameters.keys)
        var problems: [String] = []
        var outputs = Set<String>(), variables = Set<String>()
        var menuDepth = 0
        func refs(_ any: Any, _ where_: String) {
            if let d = any as? [String: Any] {
                if let u = d["OutputUUID"] as? String, !outputs.contains(u) { problems.append("\(where_): output used before it exists") }
                if d["Type"] as? String == "Variable", let n = d["VariableName"] as? String, !variables.contains(n) {
                    problems.append("\(where_): variable \(n) used before it is set")
                }
                d.values.forEach { refs($0, where_) }
            } else if let a = any as? [Any] { a.forEach { refs($0, where_) } }
        }
        for (i, a) in actions.enumerated() {
            guard let full = a["WFWorkflowActionIdentifier"] as? String, full.hasPrefix("is.workflow.actions."),
                  let p = a["WFWorkflowActionParameters"] as? [String: Any] else { problems.append("#\(i): malformed"); continue }
            let id = String(full.dropFirst("is.workflow.actions.".count))
            if !known.contains(id) { problems.append("#\(i): unknown action \(id)") }
            for (key, value) in p where key != "UUID" {
                guard let allowed = knownParameters[id]?[key] else { problems.append("#\(i) \(id): unknown parameter \(key)"); continue }
                if let allowed, !allowed.contains(value as? String ?? "") { problems.append("#\(i) \(id): \(key) = \(value) is not a known value") }
            }
            for (key, shape) in inputShapes[id] ?? [:] where p[key] != nil && !Shape.of(p[key]).fits(shape) {
                problems.append("#\(i) \(id): \(key) must be given as \(shape), not \(Shape.of(p[key]))")
            }
            if id == "downloadurl", p["WFHTTPMethod"] as? String == "POST",
               p["WFHTTPBodyType"] as? String != "File" || p["WFRequestVariable"] == nil { problems.append("#\(i): POST without a body") }
            refs(p, "#\(i) \(id)")
            if id == "choosefrommenu", let mode = p["WFControlFlowMode"] as? Int {
                if mode == 0 { menuDepth += 1 } else if mode == 2 { menuDepth -= 1 }
                if menuDepth < 0 { problems.append("#\(i): menu closed before it opened") }
            }
            if id == "setvariable", let n = p["WFVariableName"] as? String { variables.insert(n) }
            if id == "text.replace", p["WFReplaceTextRegularExpression"] as? Bool == true,
               let find = (p["WFReplaceTextFind"] as? [String: Any])?["Value"] as? [String: Any], let s = find["string"] as? String {
                let sample = s.replacingOccurrences(of: "\u{FFFC}", with: "123")       // variables are digits only
                if (try? NSRegularExpression(pattern: sample)) == nil { problems.append("#\(i): pattern doesn't compile: \(s)") }
            }
            if let u = p["UUID"] as? String {
                if outputs.contains(u) { problems.append("#\(i): duplicate UUID") }
                outputs.insert(u)
            }
        }
        if menuDepth != 0 { problems.append("menus not balanced") }
        return problems
    }
}
