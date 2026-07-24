import SwiftUI
import SlateUI
import SlateCore

/// Clean liquid-glass downloads page: live downloads (progress + speed + ETA),
/// the currently loaded model, failed transfers, and the full installed-model
/// list. Opened from the "Downloads" pill above the model selector.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.slatePalette) private var palette

    /// Per-download speed sampling (EMA, refreshed twice a second).
    @State private var speeds: [String: Double] = [:]      // bytes/sec
    @State private var lastSample: [String: Int64] = [:]   // bytes at last tick
    @State private var lastTick: Date = .distantPast

    // Same source as the Model Manager: the hardware profile if set, else physical RAM.
    private var ram: UInt64 {
        let gb = model.settings.hwRAMGB
        return gb > 0 ? UInt64(gb) * 1_073_741_824 : ProcessInfo.processInfo.physicalMemory
    }

    private var activeDownloads: [(name: String, dl: ModelStore.ActiveDownload)] {
        model.modelStore.downloads
            .sorted { $0.key < $1.key }
            .map { (name: $0.key, dl: $0.value) }
    }

    private var downloadErrors: [(name: String, message: String)] {
        model.modelStore.errors
            .filter { $0.key != "custom" && model.modelStore.downloads[$0.key] == nil }
            .sorted { $0.key < $1.key }
            .map { (name: $0.key, message: $0.value) }
    }

    /// Ignore a stale identifier (for example after an interrupted app update).
    /// Only a real catalog bundle merits the expanded active-download layout.
    private var activeImageBundle: ImageBundle? {
        guard let id = model.imageDownloadID else { return nil }
        return ImageBundle.all.first { $0.id == id }
    }

    /// A quiet library of a few installed models should read as a compact sheet,
    /// while active transfers and diagnostics keep the room they need.
    private var panelHeight: CGFloat {
        let hasActivity = model.loadingModel || !activeDownloads.isEmpty
            || activeImageBundle != nil || !downloadErrors.isEmpty || model.imageError != nil
        guard !hasActivity else { return 620 }
        if model.models.isEmpty { return 400 }
        return min(600, max(400, 138 + CGFloat(model.models.count) * 72))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Downloads", system: "arrow.down.circle") { dismiss() }

            ScrollView {
                VStack(spacing: 14) {
                    if model.loadingModel {
                        loadingCard
                    }
                    if !activeDownloads.isEmpty {
                        sectionLabel("Active") { ForEach(activeDownloads, id: \.name) { item in
                            downloadCard(item.name, item.dl)
                        } }
                    }
                    if let b = activeImageBundle {
                        sectionLabel("Image model") { imageDownloadCard(b) }
                    }
                    if let url = model.activeModelURL, !model.loadingModel {
                        sectionLabel("Loaded") { loadedModelCard(url) }
                    }
                    if !downloadErrors.isEmpty || model.imageError != nil {
                        sectionLabel("Failed") {
                            ForEach(downloadErrors, id: \.name) { err in
                                errorCard(err.name, err.message)
                            }
                            if let msg = model.imageError {
                                imageErrorCard(msg)
                            }
                        }
                    }
                    sectionLabel("Installed") {
                        if model.models.isEmpty {
                            emptyHint("No models installed yet. Use the Model Manager to download one.")
                        } else {
                            ForEach(model.models) { m in installedCard(m) }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 540, height: panelHeight)
        .animation(.snappy(duration: 0.24), value: panelHeight)
        .task { await sampleLoop() }
    }

    // MARK: - Sections

    private func sectionLabel<Content: View>(_ title: String, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 8) { rows() }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    // MARK: Loading

    private var loadingCard: some View {
        glassCard {
            HStack(spacing: 12) {
                Image(systemName: "hourglass")
                    .font(.title3).foregroundStyle(Color.primary)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loading model…").font(.callout.weight(.medium))
                    Text(model.activeModelName.map(SidebarView.pretty) ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("Loading")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .shimmer()
            }
        }
    }

    // MARK: Active download

    private func downloadCard(_ name: String, _ dl: ModelStore.ActiveDownload) -> some View {
        let speed = speeds[name] ?? 0
        let eta = etaSeconds(dl: dl, speed: speed)
        let pct = dl.expected > 0 ? dl.progress : 0
        return glassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.callout).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text("\(bytes(dl.received)) of \(dl.expected > 0 ? bytes(dl.expected) : "-")")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    Button {
                        if dl.isPaused { model.modelStore.resume(name) } else { model.modelStore.pause(name) }
                    } label: {
                        Image(systemName: dl.isPaused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(dl.isPaused ? "Resume download" : "Pause download")
                    .accessibilityLabel(dl.isPaused ? "Resume download" : "Pause download")
                    Button { model.modelStore.cancel(name) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).help("Cancel download").accessibilityLabel("Cancel download")
                }
                GlassProgress(value: dl.expected > 0 ? pct : nil)
                    .frame(height: 6)
                HStack(spacing: 10) {
                    if dl.isPaused {
                        Label("Paused", systemImage: "pause.fill")
                    } else {
                        Label(formatSpeed(speed), systemImage: "speedometer")
                            .labelStyle(.titleAndIcon)
                        if let eta, eta > 0 { Label(formatETA(eta), systemImage: "clock") }
                    }
                    Spacer()
                    Text(dl.expected > 0 ? "\(Int(pct * 100))%" : (dl.isPaused ? "paused" : "connecting…"))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Image-model bundle download

    private func imageDownloadCard(_ b: ImageBundle) -> some View {
        let pct = model.imageDownloadProgress
        return glassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "photo.artframe").font(.callout).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text("\(bytes(Int64(Double(b.totalBytes) * pct))) of \(bytes(b.totalBytes)) · \(b.files.count) files")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 8)
                }
                GlassProgress(value: pct > 0 ? pct : nil).frame(height: 6)
                HStack {
                    Label("Image model", systemImage: "photo").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text(pct > 0 ? "\(Int(pct * 100))%" : "connecting…")
                        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Loaded model

    private func loadedModelCard(_ url: URL) -> some View {
        let entry = model.models.first { $0.url == url }
        return glassCard {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3).foregroundStyle(Color.primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(SidebarView.pretty(url.lastPathComponent)).font(.callout.weight(.medium))
                    HStack(spacing: 8) {
                        if let b = entry?.bytes, b > 0 {
                            Label(bytes(b), systemImage: "internaldrive")
                        }
                        if model.activeTrainedContext > 0 {
                            Label("\(TokenEstimate.short(model.activeTrainedContext)) ctx", systemImage: "rectangle.expand.vertical")
                        }
                        if model.activeModelIsVision {
                            Label("Vision", systemImage: "eye")
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { model.killAll() } label: {
                    Label("Unload", systemImage: "eject")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(ActionGlassButtonStyle()).controlSize(.small)
                .help("Unload the model and free RAM")
            }
        }
    }

    // MARK: Installed

    private func installedCard(_ m: ModelEntry) -> some View {
        let isActive = m.url == model.activeModelURL
        return glassCard {
            HStack(spacing: 12) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "cpu")
                    .foregroundStyle(isActive ? Color.primary : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(SidebarView.pretty(m.name)).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text([m.bytes > 0 ? bytes(m.bytes) : "",
                          ModelName.qualifier(m.name),
                          ModelCatalog.sourceLabel(for: m.url)]
                         .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                FitDot(bytes: m.bytes, ram: ram, showLabel: true)
                if isActive {
                    Text("Loaded").font(.caption2.weight(.semibold)).foregroundStyle(Color.primary)
                } else {
                    Button { model.pickLocalModel(m.url) } label: {
                        Label("Load", systemImage: "cpu")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(ActionGlassButtonStyle(prominent: true)).controlSize(.small)
                    Button { model.modelStore.delete(m) } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .help("Move to Trash (incl. its vision projector)")
                }
            }
        }
    }

    // MARK: Error

    private func errorCard(_ name: String, _ message: String) -> some View {
        let canRepair = model.modelStore.canRepair(name)
        return glassCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: 8)
                if canRepair {
                    Button { model.modelStore.repair(name) } label: {
                        Label("Repair", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(ActionGlassButtonStyle(prominent: true)).controlSize(.small)
                    .help("Delete the broken file and download it again")
                    .accessibilityLabel("Repair \(name)")
                }
                Button { model.modelStore.dismissError(name) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss \(name) error")
            }
        }
    }

    private func imageErrorCard(_ message: String) -> some View {
        let name = model.imageRepairBundleID.flatMap { id in
            ImageBundle.all.first { $0.id == id }?.name
        } ?? "Image model"
        let canRepair = model.imageRepairBundleID != nil
        return glassCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: 8)
                if canRepair {
                    Button { model.repairImageDownload() } label: {
                        Label("Repair", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(ActionGlassButtonStyle(prominent: true)).controlSize(.small)
                    .help("Download the remaining files again")
                    .accessibilityLabel("Repair \(name)")
                }
                Button { model.dismissImageError() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss image error")
            }
        }
    }

    // MARK: Glass card wrapper

    @ViewBuilder
    private func glassCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
                .fill(palette.enabled ? palette.surface.opacity(0.10) : Color.clear))
            .glassEffect(.regular, in: .rect(cornerRadius: DS.R.card, style: .continuous))
    }

    // MARK: Speed sampling

    private func sampleLoop() async {
        while !Task.isCancelled {
            let now = Date()
            let dt = now.timeIntervalSince(lastTick)
            if dt > 0.3 {
                var newSpeeds = speeds
                for (name, dl) in model.modelStore.downloads {
                    if let prev = lastSample[name], dt > 0 {
                        let instant = Double(dl.received - prev) / dt
                        let smoothed = speeds[name].map { $0 * 0.5 + instant * 0.5 } ?? instant
                        newSpeeds[name] = max(0, smoothed)
                    }
                    lastSample[name] = dl.received
                }
                lastSample = lastSample.filter { model.modelStore.downloads[$0.key] != nil }
                newSpeeds = newSpeeds.filter { model.modelStore.downloads[$0.key] != nil }
                speeds = newSpeeds
                lastTick = now
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: Formatting

    private func etaSeconds(dl: ModelStore.ActiveDownload, speed: Double) -> Double? {
        guard speed > 0, dl.expected > 0, dl.expected > dl.received else { return nil }
        return Double(dl.expected - dl.received) / speed
    }

    private func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func formatSpeed(_ bps: Double) -> String {
        guard bps > 0 else { return "-" }
        if bps < 1_000_000 { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.1f MB/s", bps / 1_000_000)
    }

    private func formatETA(_ s: Double) -> String {
        guard s > 0, s < 3600 * 99 else { return "-" }
        if s < 60 { return "\(Int(s))s left" }
        if s < 3600 {
            let m = Int(s / 60), sec = Int(s.truncatingRemainder(dividingBy: 60))
            return "\(m)m \(sec)s left"
        }
        let h = Int(s / 3600), m = Int((s / 60).truncatingRemainder(dividingBy: 60))
        return "\(h)h \(m)m left"
    }

    /// RAM-fit dot matching the Model Manager: green fits, orange tight, red too big.
}

// MARK: - Glass progress bar

/// Capsule progress bar in the Slate glass aesthetic: quaternary track, accent fill.
/// `nil` value = indeterminate (a slow pulse).
struct GlassProgress: View {
    var value: Double?   // 0...1, or nil for indeterminate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.slatePalette) private var palette
    @State private var indeterminate = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.6))
                if let value {
                    Capsule().fill((palette.enabled ? palette.controlAccent : Color.primary).opacity(0.85))
                        .frame(width: max(2, geo.size.width * min(1, max(0, value))))
                } else {
                    // Reduce Motion: a static centered bar instead of a forever sweep.
                    Capsule().fill((palette.enabled ? palette.controlAccent : Color.primary).opacity(0.5))
                        .frame(width: geo.size.width * (reduceMotion ? 0.5 : 0.35))
                        .offset(x: reduceMotion ? geo.size.width * 0.25 : (indeterminate ? geo.size.width * 0.65 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                   value: indeterminate)
                }
            }
        }
        .onAppear { indeterminate = true }
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue(value.map { "\(Int($0 * 100)) percent" } ?? "in progress")
    }
}
