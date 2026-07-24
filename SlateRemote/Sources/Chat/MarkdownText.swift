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
                    Text(Self.attributed(block.content))
                        .font(.slate(16))
                        .foregroundStyle(ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let lang):
                    CodeBlock(code: block.content, language: lang)
                }
            }
        }
    }

    private static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(s)
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
