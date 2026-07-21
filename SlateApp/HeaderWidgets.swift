import SwiftUI
import SlateUI

/// Live system-RAM meter for glass headers - the gauge that decides whether the
/// next local model fits. Icon + severity bar + %; click opens the full panel.
/// Amber past 75%, red past 90%, so memory pressure reads at a glance.
struct RAMChip: View {
    let ram: RAMMonitor
    // UI-verification escape hatch: `-slate.showRAM YES` opens the popover on
    // launch, matching the other screenshot hooks in AppModel.bootstrap().
    @State private var showPanel = UserDefaults.standard.bool(forKey: "slate.showRAM")
    private var frac: Double { ram.usedFraction }
    private var tint: Color { frac >= 0.9 ? .red : frac >= 0.75 ? .orange : Color.primary.opacity(0.55) }
    var body: some View {
        Button { showPanel.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "memorychip").font(.caption2)
                    .foregroundStyle(frac >= 0.75 ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                GaugeBar(frac: frac, tint: tint)
                Text("\(Int(frac * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(frac >= 0.9 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.3), value: frac)
            }
            .contentShape(Rectangle())
            .headerChip()
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Memory - click for detail")
        .accessibilityLabel("RAM \(Int(frac * 100)) percent used, show detail")
        .popover(isPresented: $showPanel, arrowEdge: .bottom) { RAMPanel(ram: ram) }
    }
}

/// The expandable memory viewer behind the header RAM meter. Deliberately uses
/// equal stat tiles instead of divider lines: every value has the same visual
/// weight and the panel stays symmetrical at a glance.
struct RAMPanel: View {
    let ram: RAMMonitor
    private var frac: Double { ram.usedFraction }
    private var freeGB: Double { max(0, ram.totalGB - ram.usedGB) }
    private var tint: Color { frac >= 0.9 ? .red : frac >= 0.75 ? .orange : .green }
    private var headroom: (String, Color) {
        freeGB >= 8 ? ("Comfortable headroom for larger models", .green)
        : freeGB >= 4 ? ("Room for small to mid-size models", .orange)
        : ("Low - close some apps before large models", .red)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Memory", systemImage: "memorychip").font(.headline)
                    Text("Live system usage").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(Int(frac * 100))%")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
            }
            GaugeBar(frac: frac, tint: tint, width: 292, height: 8)
            HStack(spacing: 8) {
                stat("Used", String(format: "%.1f GB", ram.usedGB))
                stat("Free", String(format: "%.1f GB", freeGB))
                stat("Total", String(format: "%.0f GB", ram.totalGB))
            }
            HStack(spacing: 7) {
                Circle().fill(headroom.1).frame(width: 7, height: 7)
                Text(headroom.0).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous)
                .fill(headroom.1.opacity(0.09)))
        }
        .padding(18).frame(width: 328)
    }
    private func stat(_ k: String, _ v: String) -> some View {
        VStack(spacing: 3) {
            Text(k).font(.caption2).foregroundStyle(.tertiary)
            Text(v).font(.callout.weight(.medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous)
            .fill(.quaternary.opacity(0.45)))
    }
}

/// Small info glyph that reveals a short definition on hover and click - sits
/// next to a setting label that benefits from a one-line explanation. Quiet
/// tertiary by default, brightens while its popover is open. `help()` carries
/// the same text as a native tooltip fallback.
struct InfoHint: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.caption2.weight(.medium))
            .foregroundStyle(showing ? .primary : .tertiary)
            .contentShape(Rectangle())
            .onHover { h in
                // Hover-to-open, but only when not already pinned by a click  -
                // so moving into the popover doesn't dismiss what you opened.
                if !showing { showing = h }
            }
            .onTapGesture { showing.toggle() }
            .popover(isPresented: $showing, arrowEdge: .top) {
                Text(MarkdownText.inline(text))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)   // wrap - never truncate to one "…" line
                    .multilineTextAlignment(.leading)
                    .padding(12)
                    .frame(width: 280, alignment: .leading)
            }
            .help(text)
    }
}
