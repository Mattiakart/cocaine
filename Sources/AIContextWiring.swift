// "AI context (MCP)" in the app: its settings, the basket's hooks (AIContextHook in Sources/ExtensionHooks.swift: the clipboard's
// and the shelf's "Use as AI context"), the socket server (only while the master switch is on, never under a test or render
// flag), and the two questions asked in the notch: may this AI tool read the AI context (Allow / Allow once / Deny), and "pick
// items for the AI" (cocaine_request). Nothing is ever answered on its own: no answer in time is a refusal.

import AppKit
import Combine

final class AIContextCenter: ObservableObject {
    static let shared = AIContextCenter()

    @Published private(set) var settings: MCPSettings
    @Published private(set) var serverProblem: String?
    let basket: AIContextBasket
    let consent: MCPConsentStore
    let audit: MCPAuditLog
    private(set) var handler: MCPHandler!
    private var server: MCPAppServer?
    private let defaults: UserDefaults
    private let support: URL?
    /// The shelf (the island's model owns it): the picker offers its current collection.
    weak var shelf: ShelfStore?
    static let consentTimeout: TimeInterval = 40
    static let pickTimeout: TimeInterval = 45

    /// `support`: Cocaine's private folder (nil: no files at all, as under test and render flags).
    init(defaults: UserDefaults = AppDefaults.store, support: URL? = AppDefaults.isolated ? nil : AgentPaths.support()) {
        self.defaults = defaults
        self.support = support
        let s = MCPSettings.load(defaults)
        settings = s
        basket = AIContextBasket(persistAt: s.persistBasket ? support?.appendingPathComponent("ai-context.json") : nil, expiryHours: s.expiryHours)
        consent = MCPConsentStore(defaults: defaults)
        audit = MCPAuditLog(file: support?.appendingPathComponent("mcp-audit.log"))
        handler = MCPHandler(basket: basket, consent: consent, audit: audit) { [weak self] in self?.settings.enabled ?? false }
        handler.askConsent = { [weak self] c, n, done in self?.askConsent(c, count: n, done) ?? {} }
        handler.askPick = { [weak self] c, reason, kinds, done in self?.askPick(c, reason: reason, kinds: kinds, done) ?? {} }
    }

    // MARK: settings

    func update(_ change: (inout MCPSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        let old = settings
        settings = s
        s.save(defaults)
        if s.expiryHours != old.expiryHours { basket.setExpiry(hours: s.expiryHours) }
        if s.persistBasket != old.persistBasket { basket.setPersistence(s.persistBasket ? support?.appendingPathComponent("ai-context.json") : nil) }
        if s.enabled != old.enabled { applyServer() }
    }

    /// At launch (and when the switch changes): the socket exists only while AI context is on.
    func applyServer() {
        guard let support, settings.enabled else {
            server?.stop(); server = nil; serverProblem = nil
            return
        }
        guard server == nil else { return }
        let s = MCPAppServer(socket: support.appendingPathComponent("mcp.sock").path, keyPath: support.appendingPathComponent("mcp.key").path)
        s.handle = { [weak self] call, done in self?.handler.handle(call, done) ?? done(MCPHandler.err("off", "off")) }
        do { try s.start(); server = s; serverProblem = nil }
        catch MCPAppServer.StartError.inUse { serverProblem = L("Another Cocaine is answering AI tools") }
        catch { serverProblem = L("AI tools can't connect: the private socket couldn't be opened"); log.notice("mcp: socket not started: \(String(describing: error), privacy: .public)") }
    }

    /// The hooks the clipboard and the shelf call. Once, at launch.
    func registerHooks() {
        AIContextHook.add = { [weak self] list in
            guard let self else { return }
            let r = self.basket.add(list)
            if !r.refused.isEmpty { A11y.announce(String(format: L("%d not added"), r.refused.count)) }
        }
        AIContextHook.count = { [weak self] in self?.basket.entries.count ?? 0 }
    }

    // MARK: the questions in the notch

    private func askConsent(_ c: MCPClientIdentity, count: Int, _ done: @escaping (AIConsentAnswer?) -> Void) -> () -> Void {
        var answered = false
        let finish: (AIConsentAnswer?) -> Void = { a in if !answered { answered = true; done(a) } }
        let id = DialogCenter.shared.present(Self.consentSpec(c.label, count: count)) { r in
            switch r {
            case .choice("allow"): finish(.allow)
            case .choice("once"): finish(.once)
            case .choice("deny"): finish(.deny)
            default: finish(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.consentTimeout) { if !answered { DialogCenter.shared.withdraw(id) } }
        return { DialogCenter.shared.withdraw(id) }
    }

    struct Candidate: Equatable {
        var id: String
        var kind: String          // clip | file | text
        var ref: String
        var title: String
        var symbol: String
    }

    /// What the user can pick from (the island has room for `maxOptions`): the newest clipboard items and the shelf's current
    /// collection, half and half when both are asked for.
    func candidates(kinds: [String]) -> [Candidate] {
        var clips: [Candidate] = [], shelfItems: [Candidate] = []
        if kinds.contains("clipboard") {
            for c in ClipboardHistory.shared.items.prefix(Self.maxOptions) {
                clips.append(Candidate(id: "c" + c.id.uuidString, kind: "clip", ref: c.id.uuidString, title: AIContextText.clean(ClipCLIHandler.preview(c), 30),
                                       symbol: c.kind == .image ? "photo" : c.kind == .files ? "doc" : "doc.text"))
            }
        }
        if kinds.contains("shelf"), let shelf {
            let lib = shelf.library
            for i in lib.collections[lib.currentIndex].items.filter({ !$0.missing }).prefix(Self.maxOptions) {
                switch i.kind {
                case .file, .image:
                    guard let p = shelf.url(of: i)?.path else { continue }
                    shelfItems.append(Candidate(id: "s" + i.id.uuidString, kind: "file", ref: p, title: AIContextText.clean(i.name, 30), symbol: i.kind == .image ? "photo" : "doc"))
                case .text, .link:
                    shelfItems.append(Candidate(id: "s" + i.id.uuidString, kind: "text", ref: i.text ?? "", title: AIContextText.clean(i.name, 30), symbol: "text.alignleft"))
                }
            }
        }
        return Self.balanced(clips, shelfItems, max: Self.maxOptions)
    }

    /// Up to `max` from two lists, half from each when both have enough, the rest from whichever has more.
    static func balanced<T>(_ a: [T], _ b: [T], max: Int) -> [T] {
        let fromB = min(b.count, Swift.max(max / 2, max - a.count))
        return Array(a.prefix(max - fromB)) + Array(b.prefix(fromB))
    }

    private func askPick(_ c: MCPClientIdentity, reason: String, kinds: [String], _ done: @escaping ([(kind: String, ref: String, title: String)]?) -> Void) -> () -> Void {
        let options = candidates(kinds: kinds)
        guard !options.isEmpty else {
            DispatchQueue.main.async { done(nil) }
            return {}
        }
        var picked = Set<String>(), answered = false, current: UUID?
        let deadline = Date().addingTimeInterval(Self.pickTimeout)
        let finish: ([(kind: String, ref: String, title: String)]?) -> Void = { r in if !answered { answered = true; done(r) } }
        func show() {
            guard !answered else { return }
            guard Date() < deadline else { finish(nil); return }
            current = DialogCenter.shared.present(Self.pickSpec(c.label, reason: reason, options: options, picked: picked)) { r in
                guard case .choice(let id) = r else { finish(nil); return }
                if id == "decline" { finish(nil); return }
                if id == "send" {
                    if picked.isEmpty { show(); return }
                    finish(options.filter { picked.contains($0.id) }.map { (kind: $0.kind, ref: $0.ref, title: $0.title) })
                    return
                }
                Haptic.tap(.alignment)
                if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
                show()
            }
        }
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pickTimeout) { if !answered, let current { DialogCenter.shared.withdraw(current) } }
        return { if let current { DialogCenter.shared.withdraw(current) }; finish(nil) }
    }

    /// "May this AI tool read the AI context?" Return and Esc are "Not now" (nothing stored).
    /// It must fit the open island (no scrolling there): a short message and four choices in two columns, no button row.
    static func consentSpec(_ label: String, count: Int) -> DialogSpec {
        DialogSpec(icon: "sparkles", title: String(format: L("Allow %@ to read your AI context?"), label),
                   message: String(format: L("Only the %d item(s) you put there and pinboards you share; what it reads goes to its AI provider."), count),
                   choices: [DialogChoice(id: "allow", title: L("Allow"), symbol: "checkmark.circle"),
                             DialogChoice(id: "once", title: L("Allow once"), symbol: "1.circle"),
                             DialogChoice(id: "deny", title: L("Deny"), symbol: "xmark.circle", destructive: true),
                             DialogChoice(id: "later", title: L("Not now"), symbol: "clock")],
                   choiceMode: .act, buttons: [], safeDefault: true, surface: .island)
    }

    /// "<tool> asks for context": the AI's reason (cleaned, bounded) and the items to tick; "Share n" sends the ticked ones,
    /// "Decline" (or Esc) sends nothing. At most `maxOptions` items, so it fits the open island.
    static let maxOptions = 4
    static func pickSpec(_ label: String, reason: String, options: [Candidate], picked: Set<String>) -> DialogSpec {
        var rows = options.prefix(maxOptions).map { o in DialogChoice(id: o.id, title: o.title, symbol: picked.contains(o.id) ? "checkmark.circle.fill" : "circle") }
        rows.append(DialogChoice(id: "decline", title: L("Decline"), symbol: "xmark"))
        rows.append(DialogChoice(id: "send", title: picked.isEmpty ? L("Pick items") : String(format: L("Share %d"), picked.count), symbol: "paperplane.fill"))
        return DialogSpec(icon: "sparkles", title: String(format: L("%@ asks for context"), label),
                          message: "“" + AIContextText.clean(reason.isEmpty ? "…" : reason, 120) + "”",
                          choices: rows, choiceMode: .act, buttons: [], safeDefault: true, surface: .island)
    }

    // MARK: for the views

    /// The clients that asked recently (from the log), newest first: label → last time.
    var recentClients: [(label: String, date: Date)] {
        var seen = Set<String>(), out: [(String, Date)] = []
        for e in audit.recent where !seen.contains(e.client) { seen.insert(e.client); out.append((e.client, e.date)) }
        return out
    }
}

enum AIContextWiring {
    /// Once at launch (Sources/IslandController.swift): the hooks, the shelf, the socket when on.
    static func attach(model: IslandModel) {
        let c = AIContextCenter.shared
        c.shelf = model.shelf
        c.registerHooks()
        c.applyServer()
    }
}
