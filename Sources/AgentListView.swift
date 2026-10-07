// Every AI session (not just the first few), the ones that need you first, in a list that scrolls; requests that can be
// answered from here on top, with their buttons. Used by the island (dark) and by the panel, in the same type scale.

import SwiftUI

struct AgentListView: View {
    let entries: [AgentEntry]
    let approvals: [ApprovalRequest]
    let notice: String?
    let island: Bool                       // fills the island's column; in the panel it hugs its rows up to maxHeight
    let accent: Color
    let warning: Color
    let maxHeight: CGFloat
    let focus: (AgentOrigin?, String) -> Void
    let answer: (String, Int) -> Void
    let release: (String) -> Void
    /// What the cards show beyond the state (the last message, background tasks, the error), in memory only.
    @ObservedObject var extras = AgentExtras.shared
    @ObservedObject var review = ApprovalReviewModel.shared
    @ObservedObject var prefs = AgentPrefs.shared

    /// Every row's inner inset, the request cards' too, so icons and names sit on one column.
    static let inset: CGFloat = 6

    /// The sessions shown as plain rows: not those whose request is on top already.
    var rows: [AgentEntry] {
        let asking = Set(approvals.compactMap(\.session))
        return entries.filter { !asking.contains($0.id) }
    }

    var body: some View {
        FadingScroll(cap: maxHeight.isFinite ? maxHeight : nil) {
            LazyVStack(alignment: .leading, spacing: Space.s) {
                if let notice {
                    Label(notice, systemImage: "info.circle").font(UI.detail).foregroundStyle(UI.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Self.inset)
                }
                // A request arrives from the top and goes when answered; sessions come, go and change state in place.
                if approvals.count > 1 {                            // the queue: how many wait, of which kinds
                    Text(Self.queueText(approvals)).font(UI.detail).foregroundStyle(UI.secondary).padding(.horizontal, Self.inset)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(approvals) { r in
                    Group {
                        if !island && review.expanded == r.id {
                            ApprovalReviewView(request: r, index: approvals.firstIndex(of: r) ?? 0, count: approvals.count, island: false,
                                               accent: accent, warning: warning)
                        } else {
                            approvalRow(r)
                        }
                    }
                    .motionAppear(edge: .top)
                }
                ForEach(rows) { e in sessionRow(e).motionAppear(edge: nil) }
            }
            .animation(Motion.animation(.notice), value: approvals.map(\.id))
            .animation(Motion.animation(.expand), value: review.expanded)
            .animation(Motion.animation(.notice), value: rows.map(\.id))
            .animation(Motion.animation(.crossfade), value: rows.map(\.state))
        }
    }

    static func icon(_ s: String) -> String {
        ["working": "sparkles", "waiting": "hand.raised.fill", "done": "checkmark.circle.fill", "error": "exclamationmark.triangle.fill", "idle": "circle.dashed"][s] ?? "circle"
    }
    static func name(_ s: String) -> String {
        ["working": agentsL("Working"), "waiting": agentsL("Waiting for you"), "done": agentsL("Done"), "error": agentsL("Error"), "idle": agentsL("Session open")][s] ?? s
    }
    static func age(_ since: Double, now: Date = Date()) -> String { Dur.ago(seconds: Int(now.timeIntervalSince1970 - since)) }
    private func color(_ s: String) -> Color { s == "error" || s == "waiting" ? warning : s == "done" ? .green : s == "idle" ? UI.secondary : accent }

    private func sessionRow(_ e: AgentEntry) -> some View {
        Button { focus(e.origin, e.from) } label: {
            HStack(spacing: Space.m) {
                Image(systemName: Self.icon(e.state)).font(UI.icon).foregroundStyle(color(e.state)).frame(width: UI.iconColumn)
                    .contentTransition(.symbolEffect(.replace))          // working → done: the symbol changes into the next
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.from).font(UI.itemTitle).lineLimit(1)
                    Text(Self.stateLine(e, extras[e.id]))
                        .font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                    if let more = Self.extraLine(e, extras[e.id], preview: prefs.preview) {
                        Text(more).font(UI.detail).foregroundStyle(e.state == "error" ? warning : UI.hint).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(Motion.appear(.top))
                    }
                }
                Spacer(minLength: Space.xs)
                Text(e.restored == true ? "↺ " + Self.age(e.since) : Self.age(e.since))
                    .font(UI.detail.monospacedDigit()).foregroundStyle(UI.secondary).fixedSize()
                    .help(e.restored == true ? agentsL("From before Cocaine restarted: not heard from since") : "")
            }
            .padding(.horizontal, Self.inset)
            .contentShape(Rectangle())
        }
        .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScaleRow))
        .help(agentsL("Go to this session"))
        .accessibilityLabel("\(e.from), \(Self.stateLine(e, extras[e.id]))" + (Self.extraLine(e, extras[e.id], preview: prefs.preview).map { ". \($0)" } ?? ""))
    }

    /// "Done · project · 2 in the background": the state, the project, what still runs.
    static func stateLine(_ e: AgentEntry, _ x: AgentExtra?) -> String {
        var parts = [name(e.state)]
        if let p = e.project { parts.append(p) }
        if let x, x.background > 0, e.state != "idle" { parts.append(String(format: agentsL("%d in the background"), x.background)) }
        if let x, !x.steps.isEmpty {
            parts.append(String(format: agentsL("plan %d/%d"), x.steps.filter { $0.status == "completed" }.count, x.steps.count))
        }
        return parts.joined(separator: " · ")
    }

    /// The card's second line: why it failed, else (when the setting allows) the start of its last message, else what it
    /// is doing on its plan. Plain text, bounded.
    static func extraLine(_ e: AgentEntry, _ x: AgentExtra?, preview: Bool) -> String? {
        guard let x else { return nil }
        if e.state == "error", let err = x.error { return err }
        if e.state == "done", preview, let m = x.message { let p = Markdown.preview(m, limit: 160); if !p.isEmpty { return p } }
        if e.state == "working", let now = x.steps.first(where: { $0.status == "in_progress" }) { return ApprovalRequest.clean(now.step, 160) }
        return nil
    }

    /// "3 requests waiting: 1 plan, 2 permissions".
    static func queueText(_ list: [ApprovalRequest]) -> String {
        let kinds: [(ApprovalRequest.Kind, String)] = [(.plan, agentsL("%d plan(s)")), (.question, agentsL("%d question(s)")),
                                                      (.permission, agentsL("%d permission(s)")), (.elicitation, agentsL("%d MCP question(s)"))]
        let parts = kinds.compactMap { k, f -> String? in let n = list.filter { $0.kind == k }.count; return n > 0 ? String(format: f, n) : nil }
        return String(format: agentsL("%d requests waiting"), list.count) + ": " + parts.joined(separator: ", ")
    }

    /// The granting answer (Allow, Yes, the first choice) is primary; the others are grey.
    static func kind(_ c: ApprovalChoice, index: Int) -> CocaineButtonKind {
        ["allow", "yes"].contains(c.label) || (index == 0 && !["deny", "decline", "no"].contains(c.label)) ? .primary : .secondary
    }

    /// Time left before the request goes back to the terminal: "1:42" (never below 0:00).
    static func countdown(_ deadline: Date, now: Date) -> String {
        let s = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func choiceName(_ c: ApprovalChoice) -> String {
        ["allow": agentsL("Allow"), "deny": agentsL("Deny"), "decline": agentsL("Decline"), "yes": agentsL("Yes"), "no": agentsL("No")][c.label] ?? c.label
    }
    private func choiceLabel(_ c: ApprovalChoice) -> String { Self.choiceName(c) }

    private func approvalRow(_ r: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button { focus(r.origin, r.from) } label: {
                HStack(alignment: .top, spacing: Space.m) {
                    Image(systemName: "hand.raised.fill").font(UI.icon).foregroundStyle(warning).frame(width: UI.iconColumn)
                    VStack(alignment: .leading, spacing: 1) {
                        Text([r.from, r.project].compactMap { $0 }.joined(separator: " · ")).font(UI.itemTitle).lineLimit(1)
                        Text(ApprovalReviewView.subtitle(r))
                            .font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                        if !r.summary.isEmpty {
                            Text(r.summary).font(r.kind == .permission ? UI.mono : UI.detail)
                                .lineLimit(r.inline ? nil : 3).fixedSize(horizontal: false, vertical: true)   // inline: shown whole
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScaleRow)).help(agentsL("Go to this session"))
            HStack(spacing: Space.s) {
                if r.inline {                // one short field says it all: its buttons right here
                    ForEach(Array(r.choices.enumerated()), id: \.offset) { i, c in
                        Button(choiceLabel(c)) { answer(r.id, i) }
                            .buttonStyle(CocaineButtonStyle(kind: Self.kind(c, index: i)))       // Allow/Yes: the one filled button
                            .accessibilityLabel("\(choiceLabel(c)): \(r.title)")
                    }
                } else if r.answerable {     // a plan, a question, a long command or an edit: read it whole first
                    Button(agentsL("Review")) { review.open(r.id) }
                        .buttonStyle(CocaineButtonStyle(kind: .primary))
                        .accessibilityLabel(String(format: agentsL("Review: %@"), ApprovalReviewView.subtitle(r)))
                }
                Button(agentsL("In the terminal")) { release(r.id); focus(r.origin, r.from) }
                    .buttonStyle(CocaineButtonStyle(kind: .plain)).help(agentsL("Hands the request back to the terminal and goes there"))
            }
            .padding(.leading, UI.iconColumn + Space.m)
            if r.answerable {                // how long the island holds it before the terminal asks instead
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(String(format: agentsL("Back to the terminal in %@"), Self.countdown(r.deadline, now: ctx.date)))
                        .font(UI.detail.monospacedDigit()).foregroundStyle(UI.secondary)
                        .padding(.leading, UI.iconColumn + Space.m)
                }
            }
        }
        .padding(Self.inset)
        .background(RoundedRectangle(cornerRadius: CTL.innerRadius).fill(Color.white.opacity(0.08)))

    }
}

/// What Cocaine can detect in an environment, as six small symbols (session open, processing, completed, needs you, ended, go
/// back): full where an official mechanism gives it, dimmer for a heuristic, faint where it's unverified or impossible. Each
/// says its meaning on hover and to VoiceOver.
struct CapabilityStrip: View {
    let env: AIEnvironment
    let accent: Color

    static func word(_ s: AISupport) -> String { agentsL(s.word) }
    static func opacity(_ s: AISupport) -> Double {
        switch s { case .supported: return 1; case .partial: return 0.7; case .unverified: return 0.4; case .none: return 0.18 }
    }
    static func spoken(_ env: AIEnvironment) -> String {
        AICap.allCases.map { "\(agentsL($0.title)): \(word(env.support($0)))" }.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(AICap.allCases, id: \.rawValue) { c in
                let s = env.support(c)
                Image(systemName: c.symbol)
                    .font(UI.detail)
                    .foregroundStyle(s == .supported ? accent : UI.secondary)
                    .opacity(Self.opacity(s))
                    .help("\(agentsL(c.title)): \(Self.word(s))")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(env))
    }
}
