import SwiftUI
import SlateCore

/// Collapsible card for one tool-activity block: summary row (icon + step
/// count), expands to the monospaced ⚙/↳ log with ±diff tinting. Replaces the
/// raw backticked `⚙ …` lines in the transcript with cockpit-grade structure.
struct ToolCard: View {
    let lines: [ToolLine]
    @State private var expanded = false

    private var calls: [ToolLine] { lines.filter { $0.kind == .call } }
    private var summary: String {
        guard let first = calls.first?.text else { return "Tool activity" }
        return calls.count > 1 ? "\(first)  +\(calls.count - 1) more" : first
    }
    private var icon: String {
        let n = (calls.first?.text ?? "").lowercased()
        if n.hasPrefix("edit") || n.hasPrefix("write") { return "hammer" }
        if n.hasPrefix("read") { return "doc.text" }
        if n.hasPrefix("search") || n.hasPrefix("grep") || n.hasPrefix("glob") { return "magnifyingglass" }
        if n.hasPrefix("bash") || n.hasPrefix("run") { return "terminal" }
        if n.hasPrefix("fetch") || n.hasPrefix("web") { return "globe" }
        return "gearshape"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
                    Text(summary).font(.caption.weight(.medium)).lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(lines.count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        logLine(l)
                    }
                }
                .padding(10)
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    @ViewBuilder private func logLine(_ l: ToolLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(l.kind == .call ? "⚙" : "↳").font(.caption2).foregroundStyle(.tertiary)
            Text(diffTinted(l.text))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    /// ± diff tinting for expanded output: lines starting +/− (not +++/---).
    private func diffTinted(_ s: String) -> AttributedString {
        var out = AttributedString()
        for (i, line) in s.components(separatedBy: "\n").enumerated() {
            var a = AttributedString(line)
            if line.hasPrefix("+"), !line.hasPrefix("+++") { a.foregroundColor = .green.opacity(0.85) }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { a.foregroundColor = .red.opacity(0.85) }
            if i > 0 { out += AttributedString("\n") }
            out += a
        }
        return out
    }
}
