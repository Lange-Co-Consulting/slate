import SwiftUI
import AppKit
import SlateCore

/// Lightweight markdown renderer: collapsible reasoning, fenced code blocks
/// (with copy), and inline markdown (bold/italic/code/links) for prose.
struct MarkdownText: View {
    let text: String
    var workspaceURL: URL? = nil   // non-nil in a Code conversation → enables "Save…" on code blocks
    /// MessageBubble supplies a contrast-safe ink when chat bubbles are custom.
    var foreground: Color = .primary

    var body: some View {
        let parts = MarkdownText.splitThink(text)
        let answer = MarkdownText.stripSpecialTokens(parts.answer)
        VStack(alignment: .leading, spacing: 10) {
            if let thoughts = parts.thoughts, !thoughts.isEmpty {
                ReasoningBlock(text: MarkdownText.stripSpecialTokens(thoughts), streaming: answer.isEmpty)
            }
            ForEach(Array(TranscriptSegments.parse(answer).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .prose(let s):
                    // Block-level markdown (headings, lists, quotes) - the inline-only
                    // AttributedString parser can't do these, so `### x` would show raw.
                    ProseBlocks(text: s, foreground: foreground)
                case .code(let lang, let code):
                    CodeBlock(language: lang, code: code, workspaceURL: workspaceURL)
                case .toolActivity(let lines):
                    // Cockpit: agent tool use as a collapsible card, not raw ⚙-lines.
                    ToolCard(lines: lines)
                }
            }
        }
        .foregroundStyle(foreground)
    }

    // MARK: Parsing

    enum Segment { case prose(String), code(language: String, code: String) }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    /// Strip chat-template special tokens that occasionally leak into a model's
    /// visible output (end-of-turn / end-of-sequence / role markers). Display-only;
    /// the stored message is untouched. Applied to the answer AFTER reasoning is
    /// split out, so harmony channel markers have already been consumed.
    static func stripSpecialTokens(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var s = text
        let tokens = ["<|im_end|>", "<|im_start|>", "<|endoftext|>", "<|eot_id|>",
                      "<|end_of_text|>", "<|end|>", "<|assistant|>", "<|user|>",
                      "<|system|>", "<|im_sep|>", "<|channel|>", "<|message|>",
                      "<|return|>", "</s>", "<s>", "<end_of_turn>", "<start_of_turn>",
                      "<bos>", "<eos>", "<pad>", "<|eom_id|>", "<|start_header_id|>",
                      "<|end_header_id|>"]
        for t in tokens where s.contains(t) { s = s.replacingOccurrences(of: t, with: "") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split a (possibly streaming) reply into reasoning + answer. Handles both
    /// `<think>…</think>` and harmony/channel markers via SlateCore's Reasoning.
    static func splitThink(_ text: String) -> (thoughts: String?, answer: String) {
        Reasoning.split(text)
    }

    static func segments(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var prose: [String] = []
        var inCode = false
        var codeLang = ""
        var code: [String] = []
        func flushProse() {
            let s = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !s.isEmpty { out.append(.prose(s)) }
            prose.removeAll()
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    out.append(.code(language: codeLang, code: code.joined(separator: "\n")))
                    code.removeAll(); inCode = false; codeLang = ""
                } else {
                    flushProse()
                    inCode = true
                    codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode { out.append(.code(language: codeLang, code: code.joined(separator: "\n"))) }
        flushProse()
        if out.isEmpty { out.append(.prose(text)) }
        return out
    }
}

/// A prose segment rendered with block-level markdown. Each block sizes to its
/// own content (no forced full width) so an enclosing chat bubble can hug it.
struct ProseBlocks: View {
    let text: String
    var foreground: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        // Selectable text on macOS is backed by NSText. Give prose a real
        // multiline height so it cannot collapse into an interactive ellipsis.
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .foregroundStyle(foreground)
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let t):
            proseText(t)
                .font(headingFont(level)).fontWeight(.semibold)
                .padding(.top, level <= 2 ? 4 : 1)
        case .paragraph(let p):
            proseText(p)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(foreground.opacity(0.72))
                            .frame(width: 10, alignment: .leading)
                        proseText(it)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).")
                            .foregroundStyle(foreground.opacity(0.72)).monospacedDigit()
                            .frame(minWidth: 22, alignment: .leading)
                        proseText(it)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .quote(let q):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(foreground.opacity(0.5)).frame(width: 3)
                proseText(q)
                    .foregroundStyle(foreground.opacity(0.78))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)   // bar matches the text height, no stray tall bar
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, foreground: foreground)
        }
    }

    /// Keep selection enabled while forcing every response line to wrap within
    /// the chat column and reserve its complete vertical height.
    private func proseText(_ content: String) -> some View {
        Text(MarkdownText.inline(content))
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .textSelection(.enabled)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }
}

/// Minimal block-level markdown model. Only the shapes LLMs actually emit:
/// ATX headings, `- / * / +` and `1.` lists, `>` quotes, and paragraphs.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case ordered([String])
    case quote(String)
    case table(header: [String], rows: [[String]])

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var para: [String] = [], bullets: [String] = [], ordered: [String] = [], quote: [String] = []
        func flushPara() { if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func flushBullets() { if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] } }
        func flushOrdered() { if !ordered.isEmpty { blocks.append(.ordered(ordered)); ordered = [] } }
        func flushQuote() {
            let q = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty { blocks.append(.quote(q)) }
            quote = []
        }
        func flushAll() { flushPara(); flushBullets(); flushOrdered(); flushQuote() }

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let s = lines[i].trimmingCharacters(in: .whitespaces)
            // Table: a `|`-row immediately followed by a separator row (|---|:--|).
            if s.contains("|"), i + 1 < lines.count, isSeparatorRow(lines[i + 1]) {
                flushAll()
                let header = cells(s)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    guard r.contains("|"), !r.isEmpty else { break }
                    rows.append(cells(r)); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            // Blockquote: MERGE consecutive `>` lines into ONE block (a bare `>`
            // is a blank quoted line) - otherwise each line drew its own stray bar.
            if s.hasPrefix(">") {
                flushPara(); flushBullets(); flushOrdered()
                quote.append(s.hasPrefix("> ") ? String(s.dropFirst(2)) : String(s.dropFirst(1)))
                i += 1; continue
            }
            if s.isEmpty { flushAll(); i += 1; continue }
            if let h = matchHeading(s) { flushAll(); blocks.append(.heading(level: h.0, text: h.1)); i += 1; continue }
            if let b = matchBullet(s) { flushPara(); flushOrdered(); flushQuote(); bullets.append(b); i += 1; continue }
            if let o = matchOrdered(s) { flushPara(); flushBullets(); flushQuote(); ordered.append(o); i += 1; continue }
            flushBullets(); flushOrdered(); flushQuote(); para.append(s); i += 1
        }
        flushAll()
        return blocks.isEmpty ? [.paragraph(text)] : blocks
    }

    /// Split a `| a | b | c |` row into trimmed cells (leading/trailing pipes dropped).
    static func cells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A markdown table separator row: every cell is only `-`, `:` and spaces.
    static func isSeparatorRow(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.contains("|"), s.contains("-") else { return false }
        return cells(s).allSatisfy { c in
            !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    private static func matchHeading(_ s: String) -> (Int, String)? {
        var n = 0
        for ch in s { if ch == "#" { n += 1 } else { break } }
        guard (1...6).contains(n) else { return nil }
        let rest = s.dropFirst(n)
        guard rest.first == " " else { return nil }   // "###x" is not a heading
        return (n, rest.trimmingCharacters(in: .whitespaces))
    }
    private static func matchBullet(_ s: String) -> String? {
        for p in ["- ", "* ", "+ "] where s.hasPrefix(p) { return String(s.dropFirst(2)) }
        return nil
    }
    private static func matchOrdered(_ s: String) -> String? {
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty, s.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(s.dropFirst(digits.count + 2))
    }
}

/// Renders a markdown table as a real grid (header bold, hairline-separated
/// rows) instead of raw `| a | b |` pipes. Scrolls horizontally when wide.
struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    var foreground: Color = .primary
    private var colCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        // Columns share the width EQUALLY and cells WRAP - the whole table fits
        // the reading column (taller, but fully visible at a glance) instead of
        // scrolling horizontally with the first columns hidden.
        VStack(alignment: .leading, spacing: 0) {
            rowView(header, bold: true)
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                rowView(row, bold: false)
                if idx < rows.count - 1 { Divider().opacity(0.2) }
            }
        }
        .padding(.vertical, 2)
    }

    private func rowView(_ row: [String], bold: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(0..<colCount, id: \.self) { c in
                cell(c < row.count ? row[c] : "", bold: bold)
            }
        }
        .padding(.vertical, 5)
    }

    private func cell(_ s: String, bold: Bool) -> some View {
        // Compact: up to 2 wrapped lines, then truncate - the full cell shows in a
        // tooltip on hover (appears on hover, gone on un-hover). Keeps dense tables
        // scannable instead of very tall.
        Text(MarkdownText.inline(s))
            .font(.callout).fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(bold ? AnyShapeStyle(foreground) : AnyShapeStyle(foreground.opacity(0.9)))
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)      // wrap to (up to) 2 lines, don't 1-line-truncate
            .frame(maxWidth: .infinity, alignment: .leading)   // equal-share columns
            .help(s)                                           // full text on hover
    }
}

struct ReasoningBlock: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false   // always collapsed by default; user opens it

    var body: some View {
        // Custom expander (not DisclosureGroup, which greedily fills width and
        // would stop the chat bubble from hugging its content).
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Label(streaming ? "Thinking…" : "Thoughts", systemImage: "brain")
                        .help(streaming ? "The model's reasoning while it works. Not part of the answer."
                                        : "The model's reasoning. Not part of the answer.")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    var workspaceURL: URL? = nil
    @State private var copied = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button { CodeQuickLook.shared.show(code: code, suggestedName: suggestedName) } label: {
                    Label("Quick Look", systemImage: "eye").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                if workspaceURL != nil {
                    Button { save() } label: {
                        Label(saved ? "Saved" : "Save…", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private func save() {
        guard let dir = workspaceURL else { return }
        let panel = NSSavePanel()
        panel.directoryURL = dir
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? code.write(to: url, atomically: true, encoding: .utf8)
            saved = true
        }
    }

    private var suggestedName: String {
        switch language.lowercased() {
        case "html": return "index.html"
        case "css": return "styles.css"
        case "javascript", "js": return "script.js"
        case "json": return "data.json"
        case "markdown", "md": return "README.md"
        case "typescript", "ts": return "untitled.ts"
        case "swift": return "untitled.swift"
        case "python", "py": return "untitled.py"
        case "bash", "sh", "shell", "zsh": return "script.sh"
        default: return "untitled.\(language.isEmpty ? "txt" : language.lowercased())"
        }
    }
}
