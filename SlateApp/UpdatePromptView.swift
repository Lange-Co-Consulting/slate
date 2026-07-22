import SwiftUI
import SlateUI
import SlateCore

/// The Apple-style update dialog shown at launch when a newer signed build is on the
/// feed. It presents the version, the release notes (changelog), and Install / Later /
/// Skip choices. Download + install progress render in place; on success the app
/// relaunches into the new version. The quiet sidebar `UpdatePill` remains the
/// always-available entry point after this is dismissed.
struct UpdatePromptView: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void

    // Captured once on appear so the content stays stable while the updater state moves
    // through downloading/installing (where `availableManifest` is transiently nil).
    @State private var manifest: UpdateManifest?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    SlateMark(width: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("A new version of Slate is available")
                            .font(.title3.weight(.semibold))
                        if let m = manifest {
                            Text("Slate \(m.version) · you have \(model.updater.currentVersion)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let m = manifest, !m.notes.isEmpty {
                    ScrollView {
                        Text(m.notes)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
                }

                statusRow
            }
            .padding(22)

            Divider().opacity(0.4)

            HStack {
                Button("Skip This Version") {
                    model.settings.skippedUpdateVersion = manifest?.version
                    onClose()
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(isBusy)
                Spacer()
                Button("Later") { onClose() }
                    .disabled(isBusy)
                Button("Install & Relaunch") { model.updater.downloadAndInstall() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PaletteProminentButtonStyle())
                    .disabled(isBusy)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 460)
        .onAppear { if manifest == nil { manifest = model.updater.availableManifest } }
    }

    @ViewBuilder private var statusRow: some View {
        switch model.updater.state {
        case .downloading(let p):
            ProgressView(value: p) { Text("Downloading update…").font(.caption) }
                currentValueLabel: { Text("\(Int((p * 100).rounded()))%").font(.caption2.monospacedDigit()) }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing — Slate will relaunch…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private var isBusy: Bool {
        switch model.updater.state {
        case .downloading, .installing: return true
        default: return false
        }
    }
}
