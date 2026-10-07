// The user's own uploader: a command line typed in Settings (curl or a script) that uploads one file and prints the link.
// It is split into arguments here (quotes and backslashes as in a shell, but nothing is expanded: no shell runs it), the
// placeholders are filled argument by argument, the program runs with a small environment of its own, a timeout and bounded
// output, and the link is taken from what it printed (the first https URL, a regular expression or a JSON path). The file is
// handed over as a link with a safe name in a private temporary folder, so a file named `$(rm -rf ~)`, `a;type=x` or `-o x`
// is only ever a harmless path. Secret headers (a token) are kept in the Keychain and handed over as a 0600 file
// ({secret_headers}, e.g. `curl -H @{secret_headers}`), never in the arguments or the environment.
// Like a shelf action, a command runs only after the user allowed that exact command (asked again when it changes).
// Also here: the webhook custom action (ShareWebhook) — POST or PUT the files, or their details, to the user's https URL.
//
// Placeholders: {file} (required), {name} (the safe file name), {mime}, {size} (bytes), {secret_headers}.
// Settings: template, extract (url, regex, json), pattern, timeout (seconds). Secret: headers.

import CryptoKit
import Foundation

enum ShareUploader {
    static let placeholders: Set<String> = ["file", "name", "mime", "size", "secret_headers"]
    static let searchPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
    static let maxTemplate = 2000

    enum Problem: Error, Equatable {
        case empty, newline, unterminatedQuote, tooLong
        case unknownPlaceholder(String)
        case noFile
        case placeholderInProgram
        case programMissing(String)

        var text: String {
            switch self {
            case .empty: return L("Type the command")
            case .newline: return L("The command must be on one line")
            case .unterminatedQuote: return L("A quote isn't closed")
            case .tooLong: return L("The command is too long")
            case .unknownPlaceholder(let p): return String(format: L("Unknown placeholder {%@}"), p)
            case .noFile: return L("The command must use {file}")
            case .placeholderInProgram: return L("The program itself can't be a placeholder")
            case .programMissing(let p): return String(format: L("%@ isn't an installed program"), p)
            }
        }
    }

    /// Splits a command line into arguments: spaces separate, '…' is literal, "…" keeps \" and \\, a bare \ escapes one character.
    static func tokenize(_ s: String) throws -> [String] {
        if s.contains(where: { $0 == "\n" || $0 == "\r" }) { throw Problem.newline }
        if s.count > maxTemplate { throw Problem.tooLong }
        var out: [String] = []
        var cur = ""
        var has = false
        var it = Array(s)
        var i = 0
        func next() -> Character? { i += 1; return i < it.count ? it[i] : nil }
        while i < it.count {
            let c = it[i]
            if c == " " || c == "\t" {
                if has { out.append(cur); cur = ""; has = false }
            } else if c == "'" {
                has = true
                var closed = false
                while let n = next() { if n == "'" { closed = true; break }; cur.append(n) }
                if !closed { throw Problem.unterminatedQuote }
            } else if c == "\"" {
                has = true
                var closed = false
                while let n = next() {
                    if n == "\"" { closed = true; break }
                    if n == "\\", i + 1 < it.count, it[i + 1] == "\"" || it[i + 1] == "\\" { cur.append(next()!) } else { cur.append(n) }
                }
                if !closed { throw Problem.unterminatedQuote }
            } else if c == "\\" {
                has = true
                if let n = next() { cur.append(n) }
            } else {
                has = true
                cur.append(c)
            }
            i += 1
        }
        if has { out.append(cur) }
        it = []
        return out
    }

    /// The placeholders a piece of text uses ({word} with lowercase letters and _ only; other braces, e.g. JSON, are text).
    static func placeholders(in s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "\\{([a-z_]+)\\}")
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
    }

    /// The program the command runs: an absolute path, or a name found in the usual folders.
    static func resolve(_ program: String, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        if program.contains("/") { return program.hasPrefix("/") && isExecutable(program) ? program : nil }
        return searchPath.map { $0 + "/" + program }.first(where: isExecutable)
    }

    /// Checks a template; the program's path when it can run.
    static func check(_ template: String, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Result<String, Problem> {
        let t = template.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .failure(.empty) }
        let args: [String]
        do { args = try tokenize(t) } catch let p as Problem { return .failure(p) } catch { return .failure(.empty) }
        guard let first = args.first else { return .failure(.empty) }
        for a in args { for p in placeholders(in: a) where !placeholders.contains(p) { return .failure(.unknownPlaceholder(p)) } }
        if !placeholders(in: first).isEmpty { return .failure(.placeholderInProgram) }
        if !args.dropFirst().contains(where: { placeholders(in: $0).contains("file") }) { return .failure(.noFile) }
        guard let path = resolve(first, isExecutable: isExecutable) else { return .failure(.programMissing(first)) }
        return .success(path)
    }

    struct Values { var file: String; var name: String; var mime: String; var size: Int64; var secretHeaders: String }

    /// The arguments with the placeholders filled (each in its own argument: nothing is ever re-split).
    static func expand(_ template: String, _ v: Values) throws -> [String] {
        try tokenize(template.trimmingCharacters(in: .whitespaces)).dropFirst().map { a in
            a.replacingOccurrences(of: "{file}", with: v.file).replacingOccurrences(of: "{name}", with: v.name)
                .replacingOccurrences(of: "{mime}", with: v.mime).replacingOccurrences(of: "{size}", with: String(v.size))
                .replacingOccurrences(of: "{secret_headers}", with: v.secretHeaders)
        }
    }

    /// The host the command sends to (the first https URL in it), shown before the first upload.
    static func host(of template: String) -> String? {
        guard let r = template.range(of: "https?://[^\\s\"'/]+", options: .regularExpression) else { return nil }
        return URL(string: String(template[r]))?.host
    }

    /// What the user allows: the command line and how the link is read, plus the program's own bytes when it isn't a system
    /// one (a script that changes asks again).
    static func fingerprint(_ c: ShareProviderConfig) -> String {
        var parts = [c["template"], c["extract"], c["pattern"]]
        if case .success(let p) = check(c["template"]), !p.hasPrefix("/usr/bin/"), !p.hasPrefix("/bin/"),
           let d = try? Data(contentsOf: URL(fileURLWithPath: p), options: .mappedIfSafe), d.count <= 32 << 20 {
            parts.append(SigV4.sha256Hex(d))
        }
        return SigV4.sha256Hex(parts.joined(separator: "\u{1}"))
    }

    static func needsApproval(_ c: ShareProviderConfig) -> Bool { c.approved != fingerprint(c) }

    // MARK: the link in the output

    enum Extract: String, CaseIterable { case url, regex, json
        var title: String {
            switch self { case .url: return L("The first https link it prints"); case .regex: return L("A regular expression"); case .json: return L("A JSON path") }
        }
    }

    static func extract(_ output: String, mode: Extract, pattern: String) -> URL? {
        let out = String(output.prefix(256 << 10))
        var candidate: String?
        switch mode {
        case .url:
            if let r = out.range(of: "https?://[^\\s\"'<>]+", options: .regularExpression) { candidate = String(out[r]) }
        case .regex:
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)) else { return nil }
            let g = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range
            candidate = Range(g, in: out).map { String(out[$0]) }
        case .json:
            guard let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8), options: [.fragmentsAllowed]) else { return nil }
            candidate = jsonPath(obj, pattern) as? String
        }
        guard let s = candidate?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)")),
              let u = URL(string: s), ShareRules.allowed(u) else { return nil }
        return u
    }

    /// `files[0].url`, `data.link`, `$.url`: keys and [n] indexes.
    static func jsonPath(_ root: Any, _ path: String) -> Any? {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("$.") { p.removeFirst(2) } else if p == "$" { return root }
        var cur: Any? = root
        for part in p.split(separator: ".") {
            var s = Substring(part)
            if let b = s.firstIndex(of: "[") {
                let key = s[s.startIndex..<b]
                if !key.isEmpty { cur = (cur as? [String: Any])?[String(key)] }
                s = s[b...]
                while s.hasPrefix("["), let e = s.firstIndex(of: "]") {
                    guard let n = Int(s[s.index(after: s.startIndex)..<e]), let arr = cur as? [Any], n >= 0, n < arr.count else { return nil }
                    cur = arr[n]
                    s = s[s.index(after: e)...]
                }
            } else {
                cur = (cur as? [String: Any])?[String(s)]
            }
            if cur == nil { return nil }
        }
        return cur
    }

    // MARK: presets (text only: they fill the editor, the user saves them)

    struct Preset: Identifiable {
        var id: String
        var title: String
        var template: String
        var extract: Extract
        var pattern: String
        var warning: String
    }

    static var presets: [Preset] { [
        Preset(id: "zipline", title: L("Zipline (your server)"),
               template: "/usr/bin/curl -sS --fail --max-time 600 -H @{secret_headers} -F \"file=@{file};type={mime}\" https://zipline.example.com/api/upload",
               extract: .json, pattern: "files[0].url",
               warning: L("Put your server's address in place of zipline.example.com, and “authorization: <your token>” in Secret headers.")),
        Preset(id: "endpoint", title: L("Your own endpoint (curl, JSON answer)"),
               template: "/usr/bin/curl -sS --fail --max-time 600 -H @{secret_headers} -F \"file=@{file}\" https://upload.example.com/",
               extract: .json, pattern: "url",
               warning: L("Your server gets the file and answers with JSON holding the link.")),
        Preset(id: "script", title: L("A script of yours"),
               template: "/Users/you/bin/upload.sh {file}", extract: .url, pattern: "",
               warning: L("The script gets the file as its first argument and prints the link.")),
        Preset(id: "litterbox", title: L("Litterbox (public, temporary)"),
               template: "/usr/bin/curl -sS --fail --max-time 600 -F reqtype=fileupload -F time=24h -F \"fileToUpload=@{file}\" https://litterbox.catbox.moe/resources/internals/api.php",
               extract: .url, pattern: "",
               warning: L("A public third-party host: anyone with the link can download the file, it isn't encrypted, it can't be deleted before it expires (24 h here) and it may be blocked at work. Use it only for files that may be public.")),
    ] }
}

struct UploaderProvider: ShareProvider {
    let config: ShareProviderConfig
    var timeout: TimeInterval { max(10, min(3600, Double(config["timeout"]) ?? 300)) }
    var extract: ShareUploader.Extract { ShareUploader.Extract(rawValue: config["extract"]) ?? .url }

    func validate(secrets: [String: String]) -> String? {
        if case .failure(let p) = ShareUploader.check(config["template"]) { return p.text }
        if extract == .regex && (try? NSRegularExpression(pattern: config["pattern"])) == nil { return L("The regular expression isn't valid") }
        if extract == .json && config["pattern"].isEmpty { return L("Type the JSON path of the link, e.g. files[0].url") }
        return nil
    }

    func upload(_ file: URL, name: String, size: Int64, ctx: ShareContext) throws -> ShareUploaded {
        guard !ShareUploader.needsApproval(config) else { throw ShareError.notApproved }
        guard case .success(let program) = ShareUploader.check(config["template"]) else { throw ShareError.config(validate(secrets: ctx.secrets) ?? "") }
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let safe = ShareRules.safeName(name)
        let local = stage.appendingPathComponent(safe)
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: file.standardizedFileURL)
        let headers = stage.appendingPathComponent("secret-headers")
        let secret = (ctx.secrets["headers"] ?? "").split(whereSeparator: \.isNewline).map(String.init).joined(separator: "\n")
        guard SafeFile.writePrivate(Data((secret.isEmpty ? "" : secret + "\n").utf8), to: headers) else { throw ShareError.tool(L("Couldn't prepare the upload")) }
        let args = try ShareUploader.expand(config["template"], .init(file: local.path, name: safe, mime: ShareRules.contentType(safe), size: size, secretHeaders: headers.path))
        let env = ShelfProc.environment(["COCAINE_UPLOAD_NAME": safe, "COCAINE_SECRET_FILE": headers.path])
        let r = ctx.run(program, args, env, timeout, ctx.cancel)
        if r.cancelled { throw ShareError.cancelled }
        if r.timedOut { throw ShareError.timeout }
        guard r.status == 0 else {
            let line = r.err.split(whereSeparator: \.isNewline).first.map { String($0.prefix(160)) } ?? ""
            throw ShareError.tool(line.isEmpty ? String(format: L("The command ended with an error (%d)"), Int(r.status)) : line)
        }
        guard let link = ShareUploader.extract(r.out, mode: extract, pattern: config["pattern"]) else {
            throw ShareError.badResponse(L("No https link found in what the command printed"))
        }
        ctx.progress(1)
        return ShareUploaded(link: link, ref: "")
    }

    func revoke(_ ref: String, shareID: String?, ctx: ShareContext) throws { throw ShareError.config(L("This service can't take a link back")) }
}

// MARK: - Webhook action

/// How a webhook action sends: the files themselves (one request each) or their details as JSON (one request).
struct WebhookSpec: Codable, Equatable {
    enum Body: String, Codable, CaseIterable { case file, json }
    var method = "POST"
    var body = Body.file
}

enum ShareWebhook {
    static let maxFileBytes: Int64 = 1 << 30
    static let secretAccount = { (id: UUID) in "action." + id.uuidString.lowercased() }

    static func problem(_ url: String) -> String? { ShareRules.problem(url, what: L("The webhook address")) }

    /// "Name: value" lines; names must be header tokens, and the ones HTTP itself sets are left out.
    static func headers(_ text: String) -> [(String, String)] {
        let reserved: Set<String> = ["host", "content-length", "transfer-encoding", "connection", "content-type"]
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let c = line.firstIndex(of: ":") else { return nil }
            let name = line[..<c].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.range(of: "^[A-Za-z0-9!#$%&'*+.^_`|~-]+$", options: .regularExpression) != nil,
                  !reserved.contains(name.lowercased()), !value.contains("\r"), !value.contains("\n") else { return nil }
            return (name, value)
        }
    }

    /// The JSON describing the files: name, size, type, date changed (no contents, no folders above them).
    static func metadata(_ files: [URL]) -> Data {
        let iso = ISO8601DateFormatter()
        let list: [[String: Any]] = files.map { u in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return ["name": u.lastPathComponent, "size": v?.fileSize ?? 0, "type": ShareRules.contentType(u.lastPathComponent),
                    "modified": v?.contentModificationDate.map(iso.string(from:)) ?? ""]
        }
        return (try? JSONSerialization.data(withJSONObject: ["files": list, "count": files.count], options: [.sortedKeys])) ?? Data()
    }

    struct Planned { var request: URLRequest; var body: ShareHTTP.Body }

    static func plan(url: String, spec: WebhookSpec, files: [URL], secretHeaders: String, timeout: TimeInterval) throws -> [Planned] {
        if let p = problem(url) { throw ShareError.config(p) }
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ShareError.config(L("The address isn't valid")) }
        let method = spec.method == "PUT" ? "PUT" : "POST"
        func base(_ type: String) -> URLRequest {
            var r = URLRequest(url: u)
            r.httpMethod = method
            r.timeoutInterval = timeout
            r.setValue(type, forHTTPHeaderField: "Content-Type")
            r.setValue("Cocaine", forHTTPHeaderField: "User-Agent")
            for (k, v) in headers(secretHeaders) { r.setValue(v, forHTTPHeaderField: k) }
            return r
        }
        switch spec.body {
        case .json:
            return [Planned(request: base("application/json"), body: .data(metadata(files)))]
        case .file:
            return try files.map { f in
                let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if size > maxFileBytes { throw ShareError.tooBig(maxFileBytes) }
                if ZipTool.isFolder(f) { throw ShareError.config(L("A folder can't be sent: compress it first")) }
                var r = base(ShareRules.contentType(f.lastPathComponent))
                r.setValue(ShareRules.safeName(f.lastPathComponent), forHTTPHeaderField: "X-Cocaine-Filename")
                return Planned(request: r, body: .file(f))
            }
        }
    }

    /// Sends; the answers' text (bounded) is the action's output.
    static func run(url: String, spec: WebhookSpec, files: [URL], secretHeaders: String, timeout: TimeInterval, cancel: CancelToken?,
                    http: ShareHTTP = ShareHTTP()) throws -> String {
        http.timeout = timeout
        http.maxResponse = 256 << 10
        var out: [String] = []
        for p in try plan(url: url, spec: spec, files: files, secretHeaders: secretHeaders, timeout: timeout) {
            let r = try http.expect(p.request, body: p.body, cancel: cancel)
            let text = String(decoding: r.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(text) }
        }
        return String(out.joined(separator: "\n").prefix(64 << 10))
    }
}
