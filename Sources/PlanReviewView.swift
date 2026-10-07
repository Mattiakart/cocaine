// The review of a request from an AI, in the island (its whole page: who asks on the left with the actions, what is asked on
// the right, scrolling) and in the panel (one column): a plan in Markdown with Approve / Feedback, a question with its options
// (⌘1–9) and an answer of your own, a tool's full input with its edit as a coloured diff, Allow / Always allow / Deny with a
// reason. Nothing is granted that isn't shown whole (ApprovalRequest.allowable); "In the terminal" always hands it back.

import AppKit
import SwiftUI

struct ApprovalReviewView: View {
    let request: ApprovalRequest
    let index: Int                       // its place in the queue (0-based) and the queue's length
    let count: Int
    let island: Bool
    var accent: Color = CTL.accent
    var warning: Color = .orange
    var step: (Int) -> Void = { _ in }   // the previous / next request in the queue
    @ObservedObject var m = ApprovalReviewModel.shared

    private var r: ApprovalRequest { request }
    private var writing: Bool { m.writing == r.id }
    private var page: Int { min(m.page[r.id] ?? 0, max(0, r.questions.count - 1)) }

    var body: some View {
        Group {
            if island {
                HStack(alignment: .top, spacing: Space.gutter) {
                    VStack(alignment: .leading, spacing: Space.m) {
                        header
                        Spacer(minLength: 0)
                        actions.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 186, alignment: .topLeading)
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: Space.m) {
                    header
                    content
                    actions
                }
                .padding(AgentListView.inset)
                .background(RoundedRectangle(cornerRadius: CTL.innerRadius).fill(Color.white.opacity(0.08)))
            }
        }
        .id(r.id)
        .motionAppear(edge: nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(format: L("Request from %@"), r.from))
    }

    // MARK: who asks

    static func subtitle(_ r: ApprovalRequest) -> String {
        switch r.kind {
        case .plan: return L("Plan to review")
        case .question: return r.questions.count > 1 ? String(format: L("Asks you %d questions"), r.questions.count) : L("Asks you a question")
        case .elicitation: return String(format: L("%@ asks"), r.title)
        case .permission: return String(format: L("Wants to use %@"), r.title)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.m) {
                Image(systemName: r.kind == .plan ? "list.bullet.clipboard" : r.kind == .question ? "questionmark.bubble.fill" : "hand.raised.fill")
                    .font(UI.icon).foregroundStyle(warning).frame(width: UI.iconColumn).accessibilityHidden(true)
                Text([r.from, r.project].compactMap { $0 }.joined(separator: " · ")).font(UI.itemTitle).lineLimit(1)
            }
            HStack(spacing: Space.s) {
                Text(Self.subtitle(r)).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(1)
                Spacer(minLength: Space.xs)
                if count > 1 {                                      // the queue: which one of how many
                    Button { step(-1) } label: { Image(systemName: "chevron.left").font(UI.chevron) }
                        .buttonStyle(MotionGlyphStyle()).disabled(index == 0).accessibilityLabel(L("Previous request"))
                    Text(String(format: L("%d of %d"), index + 1, count)).font(UI.detail.monospacedDigit()).foregroundStyle(UI.secondary).fixedSize()
                    Button { step(1) } label: { Image(systemName: "chevron.right").font(UI.chevron) }
                        .buttonStyle(MotionGlyphStyle()).disabled(index >= count - 1).accessibilityLabel(L("Next request"))
                }
            }
            if r.answerable {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(String(format: L("Back to the terminal in %@"), AgentListView.countdown(r.deadline, now: ctx.date)))
                        .font(UI.detail.monospacedDigit()).foregroundStyle(UI.hint).lineLimit(1).minimumScaleFactor(0.85)
                }
            }
        }
    }

    // MARK: what is asked

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if writing { writer.motionAppear(edge: .top) }
            if !r.allowable && r.answerable && r.kind != .question {
                Label(L("Too long to show whole here: only the terminal can allow it."), systemImage: "scissors")
                    .font(UI.detail).foregroundStyle(warning).fixedSize(horizontal: false, vertical: true)
            }
            switch r.kind {
            case .plan:
                FadingScroll(cap: island ? nil : 260) { MarkdownView(r.plan ?? "") }
            case .question:
                questionPage
            case .permission:
                FadingScroll(cap: island ? nil : 260) { DetailView(detail: r.detail, summary: r.summary) }
                if !r.suggestions.filter({ !$0.isEmpty }).isEmpty && !writing { suggestionRow }
            case .elicitation:
                Text(r.summary).font(UI.value).fixedSize(horizontal: false, vertical: true)
                if island { HStack(spacing: Space.s) { elicitationChoices } }
            }
        }
        .animation(Motion.animation(.expand), value: writing)
    }

    private var writer: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            TextField(r.kind == .permission ? L("Why (Claude reads it)") : L("What should change? (Claude reads it and revises)"),
                      text: $m.text, axis: .vertical)
                .textFieldStyle(.plain).font(UI.value).lineLimit(2...5)
                .padding(Space.s)
                .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(0.1)))
                .accessibilityLabel(r.kind == .permission ? L("Reason for denying") : L("Feedback"))
                .onSubmit { m.submitWriting(r) }
            HStack(spacing: Space.s) {
                Button(r.kind == .permission ? L("Deny") : L("Send feedback")) { m.submitWriting(r) }
                    .buttonStyle(CocaineButtonStyle(kind: r.kind == .permission ? .destructive : .primary))
                    .disabled(r.kind != .permission && m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("⌘↩")
                Button(L("Cancel")) { m.endWriting() }.buttonStyle(CocaineButtonStyle(kind: .plain))
            }
        }
    }

    private var suggestionRow: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(L("Always allow")).font(UI.section).foregroundStyle(UI.secondary)
            ForEach(Array(r.suggestions.enumerated()), id: \.offset) { i, s in
                if !s.isEmpty {
                    Button { m.reply(r.id, ApprovalReply(decision: "always", content: String(i))) } label: {
                        HStack(spacing: Space.s) {
                            Text("⌘\(i + 1)").font(UI.detail.monospacedDigit()).foregroundStyle(UI.hint)
                            Text(s).font(UI.detail).lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(CocaineButtonStyle(kind: .secondary))
                    .shortcut(island ? nil : KeyEquivalent(Character("\(i + 1)")))
                    .accessibilityLabel(String(format: L("Always allow: %@"), s))
                }
            }
        }
    }

    @ViewBuilder private var questionPage: some View {
        if r.questions.indices.contains(page) {
            let q = r.questions[page]
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    if let h = q.header { Text(h).font(UI.section).foregroundStyle(accent) }
                    if r.questions.count > 1 {
                        Spacer(minLength: 0)
                        Button { m.page[r.id] = max(0, page - 1) } label: { Image(systemName: "chevron.left").font(UI.chevron) }
                            .buttonStyle(MotionGlyphStyle()).disabled(page == 0).accessibilityLabel(L("Previous question"))
                        Text(String(format: L("Question %d of %d"), page + 1, r.questions.count)).font(UI.detail.monospacedDigit()).foregroundStyle(UI.secondary)
                        Button { m.page[r.id] = min(r.questions.count - 1, page + 1) } label: { Image(systemName: "chevron.right").font(UI.chevron) }
                            .buttonStyle(MotionGlyphStyle()).disabled(page >= r.questions.count - 1).accessibilityLabel(L("Next question"))
                    }
                }
                FadingScroll(cap: island ? nil : 220) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text(ApprovalRequest.clean(q.question, 2000)).font(UI.itemTitle).fixedSize(horizontal: false, vertical: true)
                        if q.multiSelect { Text(L("Pick one or more")).font(UI.detail).foregroundStyle(UI.hint) }
                        ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in option(q, i, o) }
                        TextField(L("Or type your own answer"), text: Binding(get: { m.custom[r.id]?[page] ?? "" },
                                                                             set: { var c = m.custom[r.id] ?? [:]; c[page] = $0; m.custom[r.id] = c }))
                            .textFieldStyle(.plain).font(UI.value).padding(Space.s)
                            .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(0.08)))
                            .accessibilityLabel(L("Your own answer"))
                    }
                }
            }
            .animation(Motion.animation(.page), value: page)
        } else {
            Text(r.summary).font(UI.value).foregroundStyle(UI.secondary)
        }
    }

    private func option(_ q: AskQuestion, _ i: Int, _ o: AskQuestion.Option) -> some View {
        let on = m.isPicked(r, page, o.label)
        return Button { m.toggle(r, question: page, label: o.label) } label: {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .font(UI.icon).foregroundStyle(on ? accent : UI.secondary).frame(width: UI.iconColumn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ApprovalRequest.clean(o.label, 200)).font(UI.value).foregroundStyle(UI.primary)
                    if let d = o.description, !d.isEmpty { Text(d).font(UI.detail).foregroundStyle(UI.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: Space.xs)
                if i < 9 { Text("⌘\(i + 1)").font(UI.detail.monospacedDigit()).foregroundStyle(UI.hint) }
            }
            .padding(.vertical, Space.xxs).padding(.horizontal, Space.xs)
            .background(RoundedRectangle(cornerRadius: CTL.innerRadius).fill(Color.white.opacity(on ? 0.12 : 0)))
            .contentShape(Rectangle())
            .motionSelection(on)
        }
        .buttonStyle(MotionGlyphStyle(scale: Motion.Distance.pressScaleRow))
        .shortcut(island || i >= 9 ? nil : KeyEquivalent(Character("\(i + 1)")))
        .accessibilityLabel(ApprovalRequest.clean(o.label, 200))
        .accessibilityValue(on ? L("Selected") : "")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: actions

    private func button(_ title: String, _ kind: CocaineButtonKind, key: String?, wide: Bool? = nil, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(CocaineButtonStyle(kind: kind, height: island ? CTL.hDialog : CTL.h, wide: wide ?? island))
            .help(key.map { "\(title) (\($0))" } ?? title)
            .accessibilityHint(key.map { String(format: L("Shortcut %@"), $0) } ?? "")
    }

    /// At most three rows in the island's column (its page is 158 pt high): the granting answer and its alternative, then the
    /// way to write, then the way out. Choices of an MCP question are listed with the question, on the right.
    @ViewBuilder private var actions: some View {
        let stack = island ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s)) : AnyLayout(HStackLayout(spacing: Space.s))
        stack {
            if !writing {
                switch r.kind {
                case .plan:
                    if r.allowable {
                        HStack(spacing: Space.s) {
                            button(L("Approve"), .primary, key: "⌘Y") { m.reply(r.id, ApprovalReply(decision: "approve")) }.shortcut(island ? nil : "y")
                            if r.acceptEdits {
                                button(L("+ accept edits"), .secondary, key: "⌘2") { m.reply(r.id, ApprovalReply(decision: "approve-edits")) }
                                    .accessibilityLabel(L("Approve, accept edits"))
                            }
                        }
                    }
                    button(L("Feedback…"), .secondary, key: "⌘N") { m.startWriting(r.id) }.shortcut(island ? nil : "n")
                case .question:
                    button(L("Send answers"), .primary, key: "⌘↩") { m.submitAnswers(r) }
                        .disabled(m.answers(r) == nil).shortcut(island ? nil : .return)
                    button(L("Feedback…"), .secondary, key: "⌘N") { m.startWriting(r.id) }
                case .permission:
                    HStack(spacing: Space.s) {
                        if r.allowable { button(L("Allow"), .primary, key: "⌘Y") { m.reply(r.id, ApprovalReply(decision: "allow")) }.shortcut(island ? nil : "y") }
                        button(L("Deny"), .destructive, key: "⌘N") { m.reply(r.id, ApprovalReply(decision: "deny")) }.shortcut(island ? nil : "n")
                    }
                    button(L("Deny with reason…"), .secondary, key: nil) { m.startWriting(r.id) }
                case .elicitation:
                    if !island { elicitationChoices }
                }
            }
            HStack(spacing: Space.xs) {
                button(L("In the terminal"), .plain, key: nil, wide: false) { m.release(r.id); m.focus(r.origin, r.from) }
                    .help(L("Hands the request back to the terminal and goes there"))
                if island { button(L("Later"), .plain, key: "⌘L", wide: false) { m.putAside(r.id) }.help(L("Back to the island's pages; the request keeps waiting")) }
                else { button(L("Close"), .plain, key: nil, wide: false) { m.expanded = nil } }
            }
        }
    }

    @ViewBuilder private var elicitationChoices: some View {
        ForEach(Array(r.choices.enumerated()), id: \.offset) { i, c in
            button(AgentListView.choiceName(c), AgentListView.kind(c, index: i), key: i < 9 ? "⌘\(i + 1)" : nil, wide: false) {
                m.reply(r.id, ApprovalReply(decision: c.decision, content: c.content))
            }
        }
    }
}

/// A tool's input, whole: the file, the command, the diff in colour, then every other field.
struct DetailView: View {
    let detail: ApprovalDetail
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let f = detail.file {
                Label(f, systemImage: "doc").font(UI.detail).foregroundStyle(UI.secondary).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let c = detail.command {
                Text(c).font(UI.mono).foregroundStyle(UI.primary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(Space.s).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(0.07)))
            }
            if !detail.diff.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(detail.diff.prefix(ApprovalDetail.maxLines).enumerated()), id: \.offset) { _, l in DiffRow(line: l) }
                }
                .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(0.04)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DiffRow.spoken(detail.diff))
            }
            ForEach(Array(detail.fields.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.name).font(UI.section).foregroundStyle(UI.secondary)
                    Text(f.value).font(UI.mono).foregroundStyle(UI.primary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if detail.isEmpty { Text(summary).font(UI.mono).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DiffRow: View {
    let line: DiffLine
    var body: some View {
        let (mark, fill, ink): (String, Color, Color) = {
            switch line.kind {
            case .add: return ("+", Color.green.opacity(0.18), Color(red: 0.6, green: 0.95, blue: 0.6))
            case .remove: return ("−", Color.red.opacity(0.2), Color(red: 1, green: 0.62, blue: 0.6))
            case .context: return (" ", .clear, UI.secondary)
            case .header: return ("", Color.white.opacity(0.06), UI.secondary)
            }
        }()
        HStack(alignment: .top, spacing: Space.xs) {
            Text(mark).font(UI.mono).foregroundStyle(ink).frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text).font(line.kind == .header ? UI.section : UI.mono).foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
    }

    /// VoiceOver: how many lines are added and removed, then the lines with their marks.
    static func spoken(_ lines: [DiffLine]) -> String {
        let add = lines.filter { $0.kind == .add }.count, rem = lines.filter { $0.kind == .remove }.count
        return String(format: L("Changes: %d lines added, %d removed"), add, rem) + ". "
            + lines.prefix(40).map { ($0.kind == .add ? L("added") + ": " : $0.kind == .remove ? L("removed") + ": " : "") + $0.text }.joined(separator: ". ")
    }
}

extension View {
    /// A ⌘-key for a button, only where given (the panel; the island has its own local key monitor).
    @ViewBuilder func shortcut(_ key: KeyEquivalent?) -> some View {
        if let key { keyboardShortcut(key, modifiers: .command) } else { self }
    }
}
