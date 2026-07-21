import SwiftUI
import SlateUI
import SlateCore

/// Provider-grade context gauge: usage bar, "≈ used/limit" tokens, and live tok/s.
/// Renders BARE (no own glass) - it sits directly on the glass top bar, and Apple's
/// Liquid Glass rule is: never stack glass on glass.
struct ContextGauge: View {
    let used: Int
    let limit: Int
    let tokensPerSec: Double

    private var frac: Double { limit > 0 ? min(1, Double(used) / Double(limit)) : 0 }
    // Same severity ramp as the RAM meter, so the two gauges read as one family.
    private var tint: Color { frac >= 0.9 ? .red : frac >= 0.75 ? .orange : Color.primary.opacity(0.55) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.dotted").font(.caption2)
                .foregroundStyle(frac >= 0.75 ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
            GaugeBar(frac: frac, tint: tint)
            Text("≈\(TokenEstimate.short(used))/\(TokenEstimate.short(limit))")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())        // digits roll smoothly as tokens grow
                .animation(.snappy(duration: 0.3), value: used)
            if tokensPerSec > 0.5 {
                Text("· \(Int(tokensPerSec)) t/s")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    .lineLimit(1).transition(.opacity)
            }
        }
        .fixedSize()   // never compress → no one-char-per-line wrapping in a busy header
        .headerChip()
        .animation(.smooth(duration: 0.3), value: tokensPerSec > 0.5)
        .help("Context-window usage: ≈\(used) of \(limit) tokens" + (frac >= 0.9 ? " - near the limit" : ""))
    }
}

/// Checkpoints list (popover): restore the workspace to a pre-edit snapshot.
struct CheckpointsView: View {
    @Environment(AppModel.self) private var model
    let convID: Conversation.ID
    @State private var items: [CheckpointInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Checkpoints").font(.headline).padding(12)
            Divider()
            if items.isEmpty {
                Text("No checkpoints yet.\nSlate snapshots the folder before each edit.")
                    .font(.callout).foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { cp in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(cp.label.isEmpty ? "Snapshot" : cp.label).lineLimit(1).font(.callout)
                                    Text("\(cp.createdAt.formatted(date: .omitted, time: .standard)) · \(cp.fileCount) files")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Button("Restore") { model.restoreCheckpoint(cp, for: convID); refresh() }
                                    .buttonStyle(ActionGlassButtonStyle()).controlSize(.small)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
        .frame(width: 340, height: 320)
        .onAppear(perform: refresh)
    }
    private func refresh() { items = model.checkpoints(for: convID) }
}

/// Git panel: changed files, diff, and commit - review the agent's work in place.
struct GitPanel: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    let onClose: () -> Void
    @State private var changes: [Git.Change] = []
    @State private var branch = "-"
    @State private var message = ""
    @State private var diff = ""
    @State private var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                SectionLabel(text: "Git", system: "arrow.triangle.branch")
                Text(branch).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                ToolbarIconButton(system: "arrow.clockwise", help: "Refresh Git status") { refresh() }
                ToolbarIconButton(system: "xmark", help: "Close Git panel") { onClose() }
            }
            .accessibilityElement(children: .contain)
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            .padding(.top, 6)   // breathing room below the window's top edge
            Divider()
            if changes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(model.gitIsRepo(folder) ? "Working tree clean" : "Not a git repository")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.gitIsRepo(folder) ? "Working tree clean" : "Not a git repository")
            } else {
                List(changes, selection: $selected) { c in
                    Button {
                        selected = c.path
                        diff = model.gitDiff(folder, file: c.path)
                    } label: {
                        HStack(spacing: 8) {
                            Text(c.status.trimmingCharacters(in: .whitespaces).isEmpty ? "··" : c.status)
                                .font(.caption2.monospaced()).foregroundStyle(.secondary).frame(width: 22)
                            Text(c.path).font(.callout).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .tag(c.path)
                    .accessibilityLabel("\(c.path), \(Self.statusWord(c.status))")
                    .accessibilityValue(selected == c.path ? "Selected" : "")
                    .accessibilityHint("Shows the diff for this file")
                }
                .listStyle(.inset)
                .frame(height: 160)
                if !diff.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        Text(diff).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(.quaternary.opacity(0.25))
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("Commit message…", text: $message)
                        .textFieldStyle(.roundedBorder).font(.callout)
                    Button("Commit") {
                        guard !message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        _ = model.gitCommit(folder, message: message); message = ""; diff = ""; selected = nil; refresh()
                    }
                    .buttonStyle(ActionGlassButtonStyle(prominent: true)).controlSize(.regular)
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(10)
            }
        }
        .frame(minWidth: 340)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Git review panel")
        .onAppear(perform: refresh)
    }
    private func refresh() { changes = model.gitStatus(folder); branch = model.gitBranch(folder) ?? "-" }

    /// Spell out git's terse XY status codes for VoiceOver ("M" → "Modified").
    private static func statusWord(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.contains("?") { return "Untracked" }
        if s.contains("U") || s.contains("D") && s.contains("A") { return "Conflicted" }
        switch s.first {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "T": return "Type changed"
        default:  return s.isEmpty ? "Changed" : "Status \(s)"
        }
    }
}
