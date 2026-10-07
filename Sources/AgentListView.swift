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
                ForEach(approvals) { r in approvalRow(r).motionAppear(edge: .top) }
                ForEach(rows) { e in sessionRow(e).motionAppear(edge: nil) }
            }
            .animation(Motion.animation(.notice), value: approvals.map(\.id))
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
                    Text([Self.name(e.state), e.project].compactMap { $0 }.joined(separator: " · "))
                        .font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                }
                Spacer(minLength: Space.xs)
                Text(e.restored == true ? "↺ " + Self.age(e.since) : Self.age(e.since))
                    .font(UI.detail.monospacedDigit()).foregroundStyle(UI.secondary).fixedSize()
                    .help(e.restored == true ? agentsL("From before Cocaine restarted: not heard from since") : "")
            }
            .padding(.horizontal, Self.inset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(agentsL("Go to this session"))
        .accessibilityLabel("\(e.from), \(Self.name(e.state))" + (e.project.map { ", \($0)" } ?? ""))
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

    private func choiceLabel(_ c: ApprovalChoice) -> String {
        ["allow": agentsL("Allow"), "deny": agentsL("Deny"), "decline": agentsL("Decline"), "yes": agentsL("Yes"), "no": agentsL("No")][c.label] ?? c.label
    }

    private func approvalRow(_ r: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button { focus(r.origin, r.from) } label: {
                HStack(alignment: .top, spacing: Space.m) {
                    Image(systemName: "hand.raised.fill").font(UI.icon).foregroundStyle(warning).frame(width: UI.iconColumn)
                    VStack(alignment: .leading, spacing: 1) {
                        Text([r.from, r.project].compactMap { $0 }.joined(separator: " · ")).font(UI.itemTitle).lineLimit(1)
                        Text(r.event == "Elicitation" ? String(format: agentsL("%@ asks"), r.title) : String(format: agentsL("Wants to use %@"), r.title))
                            .font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                        if !r.summary.isEmpty {
                            Text(r.summary).font(r.event == "Elicitation" ? UI.detail : UI.mono)
                                .lineLimit(r.answerable ? nil : 3).fixedSize(horizontal: false, vertical: true)   // answerable: shown whole
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(agentsL("Go to this session"))
            HStack(spacing: Space.s) {
                ForEach(Array(r.choices.enumerated()), id: \.offset) { i, c in
                    Button(choiceLabel(c)) { answer(r.id, i) }
                        .buttonStyle(CocaineButtonStyle(kind: Self.kind(c, index: i)))       // Allow/Yes: the one filled button
                        .accessibilityLabel("\(choiceLabel(c)): \(r.title)")
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
