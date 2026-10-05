// Every AI session (not just the first few), the ones that need you first, in a list that scrolls; requests that can be
// answered from here on top, with their buttons. Used by the island (dark) and by the panel.

import SwiftUI

struct AgentListView: View {
    let entries: [AgentEntry]
    let approvals: [ApprovalRequest]
    let notice: String?
    let island: Bool                       // white on black, the island's sizes
    let accent: Color
    let warning: Color
    let maxHeight: CGFloat
    let focus: (AgentOrigin?, String) -> Void
    let answer: (String, Int) -> Void
    let release: (String) -> Void

    private var secondary: Color { island ? .white.opacity(0.55) : .secondary }
    private var titleFont: Font { .system(size: island ? 13 : 12, weight: .medium) }
    private var detailFont: Font { .system(size: 11) }

    /// The sessions shown as plain rows: not those whose request is on top already.
    var rows: [AgentEntry] {
        let asking = Set(approvals.compactMap(\.session))
        return entries.filter { !asking.contains($0.id) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: island ? 8 : 6) {
                if let notice {
                    Label(notice, systemImage: "info.circle").font(detailFont).foregroundStyle(island ? Color.white.opacity(0.8) : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(approvals) { r in approvalRow(r) }
                ForEach(rows) { e in sessionRow(e) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
    }

    static func icon(_ s: String) -> String {
        ["working": "gearshape.fill", "waiting": "hand.raised.fill", "done": "checkmark.circle.fill", "error": "exclamationmark.triangle.fill"][s] ?? "circle"
    }
    static func name(_ s: String) -> String {
        ["working": agentsL("Working"), "waiting": agentsL("Needs you"), "done": agentsL("Done"), "error": agentsL("Error")][s] ?? s
    }
    static func age(_ since: Double, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince1970 - since))
        return s < 60 ? agentsL("now") : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h"
    }
    private func color(_ s: String) -> Color { s == "error" || s == "waiting" ? warning : s == "done" ? .green : accent }

    private func sessionRow(_ e: AgentEntry) -> some View {
        Button { focus(e.origin, e.from) } label: {
            HStack(spacing: 9) {
                Image(systemName: Self.icon(e.state)).font(.system(size: 12, weight: .medium)).foregroundStyle(color(e.state)).frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.from).font(titleFont).lineLimit(1)
                    Text([Self.name(e.state), e.project].compactMap { $0 }.joined(separator: " · "))
                        .font(detailFont).foregroundStyle(secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(e.restored == true ? "↺ " + Self.age(e.since) : Self.age(e.since))
                    .font(detailFont.monospacedDigit()).foregroundStyle(secondary).fixedSize()
                    .help(e.restored == true ? agentsL("From before Cocaine restarted: not heard from since") : "")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(agentsL("Go to this session"))
        .accessibilityLabel("\(e.from), \(Self.name(e.state))" + (e.project.map { ", \($0)" } ?? ""))
    }

    private func choiceLabel(_ c: ApprovalChoice) -> String {
        ["allow": agentsL("Allow"), "deny": agentsL("Deny"), "decline": agentsL("Decline"), "yes": agentsL("Yes"), "no": agentsL("No")][c.label] ?? c.label
    }

    private func approvalRow(_ r: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { focus(r.origin, r.from) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(warning).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text([r.from, r.project].compactMap { $0 }.joined(separator: " · ")).font(titleFont).lineLimit(1)
                        Text(r.event == "Elicitation" ? String(format: agentsL("%@ asks"), r.title) : String(format: agentsL("Wants to use %@"), r.title))
                            .font(detailFont).foregroundStyle(secondary).lineLimit(1)
                        if !r.summary.isEmpty {
                            Text(r.summary).font(.system(size: 11, design: r.event == "Elicitation" ? .default : .monospaced))
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(agentsL("Go to this session"))
            HStack(spacing: 6) {
                ForEach(Array(r.choices.enumerated()), id: \.offset) { i, c in
                    Button(choiceLabel(c)) { answer(r.id, i) }
                        .controlSize(.small)
                        .tint(c.decision == "allow" || c.decision == "accept" ? accent : nil)
                        .accessibilityLabel("\(choiceLabel(c)): \(r.title)")
                }
                Button(agentsL("In the terminal")) { release(r.id); focus(r.origin, r.from) }
                    .controlSize(.small).help(agentsL("Hands the request back to the terminal and goes there"))
            }
            .padding(.leading, 25)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(island ? Color.white.opacity(0.08) : Color.primary.opacity(0.05)))
    }
}
