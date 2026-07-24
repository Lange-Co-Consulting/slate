import SwiftUI

/// Lightweight markdown for assistant replies — local models emit fenced code + inline
/// **bold**/`code` constantly, and a raw `Text` mangles them. Splits the message into prose
/// and ```code``` blocks; prose renders through `AttributedString(markdown:)` (inline only,
/// newlines preserved), code renders in a monospaced, horizontally-scrolling block that reads
/// identically to the Mac's CodeBlock. Parsing partial text mid-stream is fine — an unclosed
/// fence just renders as code until more tokens arrive.
struct MarkdownText: View {
    let text: String
    var ink: Color = Theme.ink
    var body: some View {
        // Position-stable ids: during streaming the text is re-parsed every token, so keying
        // by offset (not a fresh UUID) lets SwiftUI reuse each block's view + @State (e.g. a
        // CodeBlock's copied flag) instead of tearing the whole stack down on each token.
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .prose:
                    ProseBlock(source: block.content, ink: ink)
                case .code(let lang):
                    CodeBlock(code: block.content, language: lang)
                }
            }
        }
    }

    static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(s)
    }
}

/// Prose between code fences, rendered a line at a time.
///
/// `AttributedString(markdown:)` in inline-only mode handles **bold**, *italic* and `code` but
/// passes block syntax straight through, so a model that answers with headings and a bullet
/// list — which is most of them, most of the time — produced literal `## ` and `- ` on screen.
/// Each line is classified, then its inline markdown still goes through the same parser.
struct ProseBlock: View {
    let source: String
    var ink: Color = Theme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(ProseLine.parse(source).enumerated()), id: \.offset) { _, line in
                switch line.kind {
                case .heading(let level):
                    // The sizes are chosen to land in three *different* Dynamic Type buckets.
                    // `Font.slate` maps 16, 17 and 18 to the same `.body` style, so the obvious
                    // 21/19/17 ramp rendered an h3 at exactly the size of the paragraph under
                    // it, distinguishable only by weight.
                    Text(MarkdownText.attributed(line.text))
                        .font(.slate(level <= 1 ? 26 : level == 2 ? 21 : 19, .medium))
                        .foregroundStyle(ink)
                        .padding(.top, 6)
                case .paragraph:
                    Text(MarkdownText.attributed(line.text))
                        .font(.slate(16)).foregroundStyle(ink)
                case .bullet(let depth):
                    marker("•", indent: depth, text: line.text)
                case .ordered(let number, let depth):
                    marker("\(number).", indent: depth, text: line.text)
                case .quote:
                    HStack(alignment: .top, spacing: 10) {
                        SlateShape(radius: 1).fill(Theme.hairline).frame(width: 3)
                        Text(MarkdownText.attributed(line.text))
                            .font(.slate(16)).foregroundStyle(Theme.inkSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .rule:
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func marker(_ glyph: String, indent: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(glyph).font(.slate(16)).foregroundStyle(Theme.inkSecondary)
                .frame(minWidth: 14, alignment: .trailing)
            Text(MarkdownText.attributed(text)).font(.slate(16)).foregroundStyle(ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }
}

/// One classified line of prose.
struct ProseLine {
    enum Kind: Equatable {
        case heading(level: Int)
        case paragraph
        case bullet(depth: Int)
        case ordered(number: Int, depth: Int)
        case quote
        case rule
    }
    let kind: Kind
    let text: String

    /// Classify by leading syntax, and strip that syntax from the text so it is never shown.
    /// Consecutive plain lines are joined into one paragraph, which is what keeps a wrapped
    /// sentence from being broken across two `Text` views with a gap between them.
    static func parse(_ source: String) -> [ProseLine] {
        var out: [ProseLine] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            out.append(ProseLine(kind: .paragraph, text: paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        for raw in source.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let depth = min(indent / 2, 3)
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty { flush(); continue }

            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), line.count >= 3 {
                flush(); out.append(ProseLine(kind: .rule, text: "")); continue
            }
            if let hashes = headingLevel(line) {
                flush()
                let body = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                out.append(ProseLine(kind: .heading(level: hashes), text: body))
                continue
            }
            if line.hasPrefix("> ") || line == ">" {
                flush()
                out.append(ProseLine(kind: .quote, text: String(line.dropFirst(1))
                    .trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let rest = bulletBody(line) {
                flush()
                out.append(ProseLine(kind: .bullet(depth: depth), text: rest))
                continue
            }
            if let (number, rest) = orderedBody(line) {
                flush()
                out.append(ProseLine(kind: .ordered(number: number, depth: depth), text: rest))
                continue
            }
            paragraph.append(line)
        }
        flush()
        return out
    }

    /// `#` through `####`. Deeper levels are rare and would render the same as a paragraph.
    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...4).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    /// `- `, `* ` or `+ `. A lone `*` is emphasis, not a bullet, so the space is required.
    private static func bulletBody(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    /// `1. ` / `2) `. Keeps the model's own numbering rather than renumbering from one, so a
    /// list that continues after a code block does not silently restart.
    private static func orderedBody(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let n = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (n, String(rest.dropFirst(2)))
    }
}

/// One parsed segment of a message. Rendered with position-stable ids (see MarkdownText),
/// so no Identifiable/UUID here — that would churn during streaming re-parses.
struct MarkdownBlock {
    enum Kind: Equatable { case prose; case code(language: String?) }
    let kind: Kind
    let content: String

    /// Split on ```-fenced code. Everything else is prose (with its whitespace intact).
    static func parse(_ rawText: String) -> [MarkdownBlock] {
        // Normalize CRLF/CR first — CharacterSet.whitespaces excludes \r, so without this a
        // trailing \r leaks into language labels and every code/prose line.
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var inCode = false
        var lang: String?

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.init(kind: .prose, content: joined)) }
            prose.removeAll()
        }
        func flushCode() {
            let joined = code.joined(separator: "\n")
            // Skip a content-less fence (the transient "```lang" first token, or a bare "```")
            // — an empty framed code block with a copy button is just noise.
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.init(kind: .code(language: lang), content: joined))
            }
            code.removeAll(); lang = nil
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { flushCode(); inCode = false }
                else {
                    flushProse()
                    let tag = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                        .trimmingCharacters(in: .whitespaces)
                    lang = tag.isEmpty ? nil : String(tag)
                    inCode = true
                }
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode { flushCode() } else { flushProse() }
        return blocks
    }
}

/// A monospaced code block — quaternary fill, optional language header, horizontal scroll.
struct CodeBlock: View {
    let code: String
    var language: String?
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.slate(11, .medium)).kerning(0.6)
                    .foregroundStyle(Theme.inkTertiary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.slate(12, .medium))
                        .foregroundStyle(copied ? Theme.ok : Theme.inkSecondary)
                        .frame(minWidth: 44, minHeight: 44)   // HIG hit target; glyph stays small
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 12)

            Divider().overlay(Theme.hairline)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(SlateShape(radius: 10).fill(Theme.surfaceHigh))
        .overlay(SlateShape(radius: 10).strokeBorder(Theme.hairline, lineWidth: 1))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4)); copied = false
        }
    }
}

/// Three staggered dots — the "assistant is composing" affordance before the first token.
struct TypingIndicator: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Theme.inkSecondary)
                    .frame(width: 7, height: 7)
                    .opacity(phase ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.18), value: phase)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .onAppear { phase = true }
    }
}

/// A slim blinking caret shown at the tail of streaming text.
struct StreamingCursor: View {
    @State private var on = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.inkSecondary)
            .frame(width: 2.5, height: 15)
            .opacity(on ? 0.9 : 0.15)
            .animation(.easeInOut(duration: 0.55).repeatForever(), value: on)
            .onAppear { on.toggle() }
    }
}
