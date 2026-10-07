// Custom shelf actions the user defines in Settings (never from a link, a dropped file or another app): a shell script, a
// Shortcut, an Automator workflow, an AppleScript/JXA script, "Open with <app>", "Move to <folder>", a webhook (the files or
// their details sent to the user's https address, secret headers in the Keychain: ShareUploader.swift). An action can have a
// key (⌥1…⌥9 while the shelf has the keyboard) and a next action (its output files, else the same files, go on to it);
// actions can be exported and imported as JSON without secrets or approvals (ShelfActionsIO.swift). Files are always passed as
// separate arguments (absolute paths, so none can be read as an option), never inside a shell string; programs get a small
// environment of their own, a timeout and Cancel; their output can go to the clipboard or the shelf. A script runs only after
// the user said yes to that exact file (its SHA-256): a changed script asks again. Tested by --shelf-test with hostile names.

import AppKit
import CryptoKit
import Foundation

struct ShelfAction: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case shell, shortcut, automator, applescript, openWith, moveTo, webhook }
    enum Output: String, Codable, CaseIterable { case ignore, clipboard, shelf }
    var id = UUID()
    var name: String
    var kind: Kind
    /// The script, workflow, app or folder (a path), or the Shortcut's name.
    var target: String
    var output = Output.ignore
    var timeout = 120.0
    /// Shown as a drop target while files are dragged over the island (holding ⌥).
    var instant = false
    /// The SHA-256 of what the user allowed to run (scripts and workflows; "shortcut:<name>" for a Shortcut). nil: ask first.
    var approved: String? = nil
    /// A webhook's method and body (the address is `target`).
    var hook: WebhookSpec? = nil
    /// ⌥ + this digit (1–9) runs it while the shelf has the keyboard.
    var key: Int? = nil
    /// The action that runs next, on this one's output files (else the same files).
    var then: UUID? = nil

    static let timeouts: [Double] = [30, 120, 600, 3600]

    var symbol: String {
        switch kind {
        case .shell: return "terminal"
        case .shortcut: return "square.2.layers.3d"
        case .automator: return "gearshape.2"
        case .applescript: return "applescript"
        case .openWith: return "arrow.up.forward.app"
        case .moveTo: return "folder"
        case .webhook: return "paperplane"
        }
    }

    var kindTitle: String {
        switch kind {
        case .shell: return L("Shell script")
        case .shortcut: return L("Shortcut")
        case .automator: return L("Automator workflow")
        case .applescript: return L("AppleScript or JavaScript")
        case .openWith: return L("Open with an app")
        case .moveTo: return L("Move to a folder")
        case .webhook: return L("Webhook")
        }
    }

    /// Runs code the user wrote, or sends files to an address (asks once per version of it).
    var runsCode: Bool { [.shell, .shortcut, .automator, .applescript, .webhook].contains(kind) }
}

enum ShelfActionEngine {
    static let shortcuts = "/usr/bin/shortcuts"
    static let automator = "/usr/bin/automator"
    static let osascript = "/usr/bin/osascript"
    static let zsh = "/bin/zsh"
    static let maxFiles = 1000

    enum Problem: Error, LocalizedError, Equatable {
        case missing(String), badName, newlineInName(String), tooMany, notApproved, badAddress(String)
        var errorDescription: String? {
            switch self {
            case .missing(let p): return String(format: L("%@ isn't there any more"), (p as NSString).lastPathComponent)
            case .badName: return L("A Shortcut's name can't be empty or start with a dash")
            case .newlineInName(let n): return String(format: L("Automator can't take a file whose name has a line break (%@)"), n)
            case .tooMany: return String(format: L("At most %d files at a time"), ShelfActionEngine.maxFiles)
            case .notApproved: return L("This action hasn't been allowed to run yet")
            case .badAddress(let why): return why
            }
        }
    }

    /// Why the action can't run now, if it can't (its file gone, a bad Shortcut name).
    static func check(_ a: ShelfAction, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Problem? {
        switch a.kind {
        case .shortcut:
            let n = a.target.trimmingCharacters(in: .whitespacesAndNewlines)
            if n.isEmpty || n.hasPrefix("-") || n.contains(where: \.isNewline) { return .badName }
        case .webhook:
            if let p = ShareWebhook.problem(a.target) { return .badAddress(p) }
        case .shell, .automator, .applescript, .openWith, .moveTo:
            if !a.target.hasPrefix("/") || !fileExists(a.target) { return .missing(a.target) }
        }
        return nil
    }

    struct Command: Equatable {
        var path: String
        var args: [String]
        var stdin: Data?
        var outputFile: URL?
    }

    /// The exact program and arguments for running `a` on `files` (only for the kinds that run a program). Every file is its own
    /// argument, as an absolute path: a name with spaces, quotes, `$()`, a newline or a leading dash reaches the script as it is.
    static func command(_ a: ShelfAction, files: [URL], isExecutable: (String) -> Bool = { access($0, X_OK) == 0 },
                        outputFile: URL? = nil) throws -> Command {
        if let p = check(a) { throw p }
        guard files.count <= maxFiles else { throw Problem.tooMany }
        let paths = files.map { $0.standardizedFileURL.path }        // absolute: starts with "/", never an option
        switch a.kind {
        case .shell:
            // An executable script runs itself (its #! line); any other file is read by zsh, the script path then the files.
            return isExecutable(a.target) ? Command(path: a.target, args: paths) : Command(path: zsh, args: [a.target] + paths)
        case .shortcut:
            var args = ["run", a.target.trimmingCharacters(in: .whitespacesAndNewlines)]
            for p in paths { args += ["--input-path", p] }
            if let o = outputFile { args += ["--output-path", o.path] }
            return Command(path: shortcuts, args: args, outputFile: outputFile)
        case .automator:
            // Automator reads its input from stdin, one item per line: a name with a line break can't be passed safely.
            if let bad = paths.first(where: { $0.contains("\n") || $0.contains("\r") }) { throw Problem.newlineInName((bad as NSString).lastPathComponent) }
            return Command(path: automator, args: ["-i", "-", a.target], stdin: Data(paths.joined(separator: "\n").utf8))
        case .applescript:
            let js = ["js", "jxa"].contains((a.target as NSString).pathExtension.lowercased())
            return Command(path: osascript, args: (js ? ["-l", "JavaScript"] : []) + [a.target] + paths)
        case .openWith, .moveTo, .webhook:
            throw Problem.missing(a.target)          // not a program: see run()
        }
    }

    /// What the user allows: the SHA-256 of the script (of an Automator workflow's document.wflow), or the Shortcut's name.
    static func fingerprint(_ a: ShelfAction) -> String? {
        switch a.kind {
        case .shortcut: return "shortcut:" + a.target.trimmingCharacters(in: .whitespacesAndNewlines)
        case .shell, .applescript:
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: a.target), options: .mappedIfSafe), d.count <= 32 << 20 else { return nil }
            return sha256(d)
        case .automator:
            let doc = URL(fileURLWithPath: a.target).appendingPathComponent("Contents/document.wflow")
            guard let d = try? Data(contentsOf: doc), d.count <= 32 << 20 else { return nil }
            return sha256(d)
        case .webhook:
            let h = a.hook ?? WebhookSpec()
            return "webhook:\(h.method) \(h.body.rawValue) " + a.target.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openWith, .moveTo: return nil
        }
    }

    /// What a webhook's first run asks.
    static func webhookQuestion(_ a: ShelfAction) -> String {
        let h = a.hook ?? WebhookSpec()
        return String(format: h.body == .file ? L("It sends the files to %@. Cocaine asks again if the address changes.")
                                              : L("It sends the files' names and sizes to %@. Cocaine asks again if the address changes."), a.target)
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// Must the user be asked before it runs (first time, or the script changed since)?
    static func needsApproval(_ a: ShelfAction) -> Bool {
        guard a.runsCode else { return false }
        guard let f = fingerprint(a) else { return true }
        return a.approved != f
    }

    struct Outcome: Equatable {
        var ok: Bool
        var output: String          // stdout (or the Shortcut's output), trimmed, bounded
        var errors: String          // stderr, bounded
        var movedTo: [ShelfFiles.Moved] = []
        var timedOut = false
        var cancelled = false
    }

    /// Runs the action on the files (off the main thread). Never runs code that isn't approved.
    static func run(_ a: ShelfAction, files: [URL], cancel: CancelToken? = nil,
                    open: (URL, [URL]) -> Bool = ShelfActionEngine.openWith) throws -> Outcome {
        if let p = check(a) { throw p }
        if needsApproval(a) { throw Problem.notApproved }
        switch a.kind {
        case .openWith:
            return Outcome(ok: open(URL(fileURLWithPath: a.target), files), output: "", errors: "")
        case .moveTo:
            let r = ShelfFiles.transfer(files, into: URL(fileURLWithPath: a.target), move: true, cancel: cancel)
            return Outcome(ok: r.problem == nil, output: "", errors: r.problem ?? "", movedTo: r.done)
        case .webhook:
            var spec = a.hook ?? WebhookSpec()
            if files.isEmpty { spec.body = .json }                 // a test run: the (empty) list of files, nothing else
            let headers = (try? secrets.load(ShareWebhook.secretAccount(a.id)))?["headers"] ?? ""
            do {
                let out = try ShareWebhook.run(url: a.target, spec: spec, files: files, secretHeaders: headers, timeout: max(1, a.timeout), cancel: cancel, http: http())
                return Outcome(ok: true, output: out, errors: "")
            } catch ShareError.cancelled {
                return Outcome(ok: false, output: "", errors: "", cancelled: true)
            } catch ShareError.timeout {
                return Outcome(ok: false, output: "", errors: "", timedOut: true)
            } catch {
                return Outcome(ok: false, output: "", errors: ShareError.from(error).localizedDescription)
            }
        case .shell, .shortcut, .automator, .applescript:
            var outFile: URL?
            if a.kind == .shortcut && a.output != .ignore {
                outFile = FileManager.default.temporaryDirectory.appendingPathComponent("cocaine-shortcut-\(UUID().uuidString).txt")
            }
            defer { if let o = outFile { try? FileManager.default.removeItem(at: o) } }
            let c = try command(a, files: files, outputFile: outFile)
            let env = ShelfProc.environment(["COCAINE_SHELF_COUNT": "\(files.count)"])
            let r = ShelfProc.run(c.path, c.args, stdin: c.stdin, env: env, cwd: files.first?.deletingLastPathComponent(),
                                  timeout: max(1, a.timeout), cancel: cancel, limit: 1 << 20)
            var out = r.out
            if let o = outFile, let d = try? Data(contentsOf: o), d.count <= 1 << 20 { out = String(decoding: d, as: UTF8.self) }
            return Outcome(ok: r.ok, output: out.trimmingCharacters(in: .whitespacesAndNewlines), errors: r.err.trimmingCharacters(in: .whitespacesAndNewlines),
                           timedOut: r.timedOut, cancelled: r.cancelled)
        }
    }

    /// Where webhook actions' secret headers are (the Keychain; memory in tests and renders) and the HTTP client (tests: a fake).
    static var secrets: ShareSecretStore = AppDefaults.isolated ? MemorySecretStore() : KeychainSecretStore()
    static var http: () -> ShareHTTP = { ShareHTTP() }

    static func openWith(_ app: URL, _ files: [URL]) -> Bool {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: cfg, completionHandler: nil)
        return true
    }
}
