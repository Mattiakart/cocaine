// A small block-Markdown reader and its view, for an AI's plan (Claude Code's ExitPlanMode) and a finished session's last
// message: headings, paragraphs, bullet/numbered/task lists, code blocks, quotes, tables, rules; inline bold, italic, code and
// links come from Foundation's own inline parser. Pure parsing (MarkdownTests checks it); never runs or fetches anything, and
// only http(s) links can be opened (a plan is text from another program).

import AppKit
import SwiftUI

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownItem])
    case code(language: String?, text: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

struct MarkdownItem: Equatable {
    var level: Int               // 0 = top; one per 2 spaces of indent (a tab is 4), at most 5
    var marker: String           // "•", "1.", "2)"…
    var checked: Bool?           // a task list's box: nil = not a task
    var text: String
}

enum Markdown {
    /// Lines past this many are not parsed (the view says how much was left out).
    static let maxLines = 4000
    /// Blocks past this many are not drawn.
    static let maxBlocks = 600

    private static func indent(_ s: Substring) -> Int {
        var n = 0
        for c in s { if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break } }
        return n
    }

    private static let fence = try! NSRegularExpression(pattern: #"^\s{0,3}(`{3,}|~{3,})\s*([A-Za-z0-9_+.#-]*)"#)
    private static let headingRE = try! NSRegularExpression(pattern: #"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$"#)
    private static let ruleRE = try! NSRegularExpression(pattern: #"^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$"#)
    private static let itemRE = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$"#)
    private static let separatorRE = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$"#)

    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    static func isItem(_ s: String) -> Bool { match(itemRE, s) != nil }
    private static func isTableRow(_ s: String) -> Bool { s.contains("|") }

    /// The cells of a table row: `| a | b |` → ["a", "b"] (an escaped `\|` stays in its cell).
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = [], cur = "", esc = false
        for c in t {
            if esc { cur.append(c); esc = false; continue }
            if c == "\\" { esc = true; cur.append(c); continue }
            if c == "|" { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(c)
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    /// Blocks starts: a line that ends a paragraph.
    private static func startsBlock(_ s: String, next: String?) -> Bool {
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if match(fence, s) != nil || match(headingRE, s) != nil || match(ruleRE, s) != nil || isItem(s) { return true }
        if s.trimmingCharacters(in: .whitespaces).hasPrefix(">") { return true }
        if isTableRow(s), let n = next, match(separatorRE, n) != nil { return true }
        return false
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let all = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lines = Array(all.prefix(maxLines))
        var blocks: [MarkdownBlock] = []
        var i = 0
        func next(_ k: Int) -> String? { k + 1 < lines.count ? lines[k + 1] : nil }
        while i < lines.count, blocks.count < maxBlocks {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            if let f = match(fence, line) {                                       // ``` code ```
                let mark = f[1], lang = f[2].isEmpty ? nil : f[2]
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(String(mark.first!)) && t.allSatisfy({ $0 == mark.first! }) && t.count >= mark.count { i += 1; break }
                    body.append(lines[i]); i += 1
                }
                blocks.append(.code(language: lang, text: body.joined(separator: "\n")))
                continue
            }
            if let h = match(headingRE, line) {
                blocks.append(.heading(level: h[1].count, text: h[2])); i += 1; continue
            }
            if match(ruleRE, line) != nil { blocks.append(.rule); i += 1; continue }
            if trimmed.hasPrefix(">") {                                           // > quote
                var body: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    body.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                blocks.append(.quote(body.joined(separator: " ")))
                continue
            }
            if isTableRow(line), let n = next(i), match(separatorRE, n) != nil {   // | a | b |
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, isTableRow(lines[i]), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    var r = cells(lines[i])
                    if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                    rows.append(Array(r.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if isItem(line) {                                                     // - item, 1. item, - [ ] task
                var items: [MarkdownItem] = []
                while i < lines.count {
                    if let m = match(itemRE, lines[i]) {
                        var text = m[3]
                        var checked: Bool?
                        if text.hasPrefix("[ ] ") || text == "[ ]" { checked = false; text = String(text.dropFirst(3)) }
                        else if text.lowercased().hasPrefix("[x] ") || text.lowercased() == "[x]" { checked = true; text = String(text.dropFirst(3)) }
                        let marker = m[2].first.map { "-*+".contains($0) } == true ? "•" : m[2]
                        items.append(MarkdownItem(level: min(5, indent(Substring(m[1])) / 2), marker: marker, checked: checked,
                                                  text: text.trimmingCharacters(in: .whitespaces)))
                        i += 1
                        continue
                    }
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty {                                                // a blank line: the list goes on if an item follows
                        if let n = next(i), isItem(n) { i += 1; continue }
                        break
                    }
                    if !items.isEmpty, match(fence, lines[i]) == nil,
                       indent(Substring(lines[i])) >= 2 || !startsBlock(lines[i], next: next(i)) {
                        items[items.count - 1].text += " " + t                    // the item's text, carried on
                        i += 1
                        continue
                    }
                    break
                }
                blocks.append(.list(items))
                continue
            }
            var para: [String] = []                                               // a paragraph: until a blank line or a block
            while i < lines.count {
                if !para.isEmpty && startsBlock(lines[i], next: next(i)) { break }
                para.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1
            }
            blocks.append(.paragraph(para.joined(separator: " ")))
        }
        return blocks
    }

    /// Lines left out by the limits (0 = all of it is shown).
    static func omittedLines(_ text: String) -> Int {
        var n = 0
        for c in text.utf8 where c == 10 { n += 1 }
        return max(0, n + 1 - maxLines)
    }

    /// Bold, italic, inline code and links of one block's text; anything Foundation can't read stays plain text. A link that
    /// isn't http(s) keeps its text and loses the link.
    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        guard var a = try? AttributedString(markdown: s, options: opts) else { return AttributedString(s) }
        for run in a.runs {
            if let url = run.link, !safeLink(url) { a[run.range].link = nil }
            if run.inlinePresentationIntent?.contains(.code) == true {
                a[run.range].font = .system(size: 11, design: .monospaced)
                a[run.range].backgroundColor = Color.white.opacity(0.1)
            }
        }
        return a
    }

    static func safeLink(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil }

    /// Plain text of a block's inline Markdown (VoiceOver, previews).
    static func plain(_ s: String) -> String { String(inline(s).characters) }

    /// The first paragraph-ish part of a message, at most `limit` characters, as plain text (a session's completion preview).
    static func preview(_ text: String, limit: Int = 300) -> String {
        for b in parse(String(text.prefix(limit * 8))) {
            let t: String
            switch b {
            case .heading(_, let s), .paragraph(let s), .quote(let s): t = plain(s)
            case .list(let items): t = items.prefix(3).map { plain($0.text) }.joined(separator: " · ")
            default: continue
            }
            let one = t.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if one.isEmpty { continue }
            return one.count > limit ? String(one.prefix(limit - 1)) + "…" : one
        }
        return ""
    }
}

/// The blocks drawn in the app's type scale (dark: the island; the panel is dark too). Links open only when http(s).
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    var omitted = 0

    init(_ text: String) { blocks = Markdown.parse(text); omitted = Markdown.omittedLines(text) }
    init(blocks: [MarkdownBlock]) { self.blocks = blocks }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
            if omitted > 0 {
                Label(String(format: L("%d more lines not shown here"), omitted), systemImage: "scissors")
                    .font(UI.detail).foregroundStyle(UI.secondary)
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in Markdown.safeLink(url) ? .systemAction : .discarded })
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func text(_ s: String, _ font: Font, _ color: Color = UI.primary) -> some View {
        Text(Markdown.inline(s)).font(font).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func block(_ b: MarkdownBlock) -> some View {
        switch b {
        case .heading(let level, let s):
            text(s, level == 1 ? UI.pageTitle : level == 2 ? UI.appTitle : UI.itemTitle)
                .padding(.top, level <= 2 ? Space.xs : 0)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let s):
            text(s, UI.value)
        case .quote(let s):
            HStack(alignment: .top, spacing: Space.m) {
                Capsule().fill(UI.hint).frame(width: 2)
                text(s, UI.value, UI.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1).accessibilityHidden(true)
        case .code(_, let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(UI.mono).foregroundStyle(UI.primary).fixedSize().padding(Space.m)
            }
            .background(RoundedRectangle(cornerRadius: CTL.radius).fill(Color.white.opacity(0.07)))
        case .list(let items):
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        if let c = it.checked {
                            Image(systemName: c ? "checkmark.square.fill" : "square").font(UI.detail)
                                .foregroundStyle(c ? CTL.accent : UI.secondary)
                                .accessibilityLabel(c ? L("Done") : L("To do"))
                        } else {
                            Text(it.marker).font(UI.value.monospacedDigit()).foregroundStyle(UI.secondary).accessibilityHidden(it.marker == "•")
                        }
                        text(it.text, UI.value, it.checked == true ? UI.secondary : UI.primary)
                    }
                    .padding(.leading, CGFloat(it.level) * 14)
                }
            }
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.xs) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, h in text(h, UI.section, UI.secondary) } }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow { ForEach(Array(r.enumerated()), id: \.offset) { _, c in text(c, UI.detail) } }
                    }
                }
                .padding(.vertical, Space.xs)
            }
        }
    }
}

// MARK: - Tests (part of --agents-test and --selftest)

enum MarkdownTests {
    static func run(_ check: (String, Bool) -> Void) {
        let plan = """
        # Plan: add the notch review

        Two **steps**, then *tests* with `swiftc`.

        ## Steps
        1. Read the hook's input
        2. Show it
           in the island
        - [ ] write tests
        - [x] read the docs
          - nested item

        ```swift
        let x = 1
        // # not a heading
        ```

        > Note: never approve
        > on your own.

        | File | Change |
        |------|:------:|
        | AgentApprovals.swift | plan kind |
        | a \\| b | escaped |

        ---
        A [link](https://example.com) and [bad](file:///etc/passwd).
        """
        let b = Markdown.parse(plan)
        check("markdown: headings with their level", b.first == .heading(level: 1, text: "Plan: add the notch review") && b.contains(.heading(level: 2, text: "Steps")))
        check("markdown: a paragraph keeps its inline marks for the inline parser", b.contains(.paragraph("Two **steps**, then *tests* with `swiftc`.")))
        let lists = b.compactMap { if case .list(let i) = $0 { return i }; return nil }
        check("markdown: numbered items, a continuation line, task boxes and nesting (\(lists))", lists.count == 1 && lists[0].count == 5
              && lists[0][0] == MarkdownItem(level: 0, marker: "1.", checked: nil, text: "Read the hook's input")
              && lists[0][1].text == "Show it in the island"
              && lists[0][2].checked == false && lists[0][3].checked == true && lists[0][3].text == "read the docs"
              && lists[0][4].level == 1 && lists[0][4].marker == "•")
        check("markdown: a fenced code block keeps its lines (a # inside is not a heading)",
              b.contains(.code(language: "swift", text: "let x = 1\n// # not a heading")))
        check("markdown: quote lines join", b.contains(.quote("Note: never approve on your own.")))
        check("markdown: a table with header, rows, escaped pipe",
              b.contains(.table(header: ["File", "Change"], rows: [["AgentApprovals.swift", "plan kind"], ["a | b", "escaped"]])))
        check("markdown: a rule", b.contains(.rule))
        let link = Markdown.inline("A [link](https://example.com) and [bad](file:///etc/passwd).")
        let links = link.runs.compactMap(\.link)
        check("markdown: only http(s) links stay links", links == [URL(string: "https://example.com")!])
        check("markdown: inline marks become plain text for VoiceOver", Markdown.plain("Two **steps** and `code`") == "Two steps and code")
        check("markdown: an unclosed fence takes the rest, no crash", Markdown.parse("```\nnever closed\nstill code") == [.code(language: nil, text: "never closed\nstill code")])
        check("markdown: empty and whitespace-only text: nothing", Markdown.parse("").isEmpty && Markdown.parse("  \n\n\t\n").isEmpty)
        check("markdown: a line with a pipe but no separator is a paragraph", Markdown.parse("a | b\nc") == [.paragraph("a | b c")])
        check("markdown: a heading needs a space after the hashes", Markdown.parse("#tag") == [.paragraph("#tag")])
        let huge = (0..<(Markdown.maxLines + 250)).map { "line \($0)" }.joined(separator: "\n\n")
        let started = Date()
        let hb = Markdown.parse(huge)
        check("markdown: a huge text is bounded (\(hb.count) blocks in \(String(format: "%.2f", Date().timeIntervalSince(started))) s)",
              hb.count <= Markdown.maxBlocks && Date().timeIntervalSince(started) < 3 && Markdown.omittedLines(huge) > 0)
        check("markdown: the completion preview is the first text, plain, bounded",
              Markdown.preview("## Done\n\nAll **tests** pass.") == "Done" && Markdown.preview("```\ncode\n```\nFixed it.") == "Fixed it."
              && Markdown.preview(String(repeating: "word ", count: 200), limit: 50).count == 50)
    }
}
