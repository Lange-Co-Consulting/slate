import Foundation

/// Separates a model's hidden reasoning from the answer it is actually giving.
///
/// The Mac streams raw model output over the wire, so anything the model emits — including its
/// chain of thought — arrives verbatim. Reasoning models (Qwen3, DeepSeek-R1, gpt-oss) wrap that
/// in `<think>…</think>`, and their chat templates usually put the OPENING tag in the prompt, so
/// the model itself only ever emits the CLOSING one. Both shapes are handled here.
///
/// This mirrors `Reasoning` in slate-engine, duplicated because the iOS app deliberately depends
/// only on `SlateRemoteProtocol` and never on the engine.
///
/// Splitting happens at RENDER time, not while tokens accumulate: a `<think>` block can be half
/// delivered mid-stream, and the raw text stays intact for retry/copy.
enum Reasoning {
    /// The visible answer, with reasoning removed. While reasoning is still streaming (an opener
    /// with no closer yet) this is empty, which lets the UI show "Thinking…" instead of the
    /// model's inner monologue.
    static func answer(_ raw: String) -> String {
        split(raw).answer
    }

    /// True while the model is inside a reasoning block and has not produced an answer yet.
    static func isThinking(_ raw: String) -> Bool {
        let s = split(raw)
        return s.thoughts != nil && s.answer.isEmpty
    }

    static func split(_ raw: String) -> (thoughts: String?, answer: String) {
        let text = normalizeOrphanedOpener(raw)
        guard text.contains("<think>") else { return (nil, raw) }
        var thoughts: [String] = []
        var answer = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<think>") {
            answer += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            if let close = after.range(of: "</think>") {
                thoughts.append(trim(String(after[..<close.lowerBound])))
                rest = after[close.upperBound...]
            } else {
                // Still streaming inside the block: everything after the opener is thought.
                thoughts.append(trim(String(after)))
                rest = after[after.endIndex...]
                break
            }
        }
        answer += rest
        let t = trim(thoughts.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        return (t.isEmpty ? nil : t, trim(answer))
    }

    /// A closing tag with no opener before it means the template supplied the opener in the
    /// prompt. Re-attach it so the split below sees a well-formed block.
    private static func normalizeOrphanedOpener(_ text: String) -> String {
        guard let close = text.range(of: "</think>") else { return text }
        if let open = text.range(of: "<think>"), open.lowerBound < close.lowerBound { return text }
        return "<think>" + text
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
