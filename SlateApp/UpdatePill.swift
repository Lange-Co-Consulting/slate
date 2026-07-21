import SwiftUI
import SlateUI

/// Small sidebar pill that appears only when an update is available (like the
/// update affordance in Claude Code). Click → a popover with the version, notes,
/// and an Install & Relaunch button. Renders nothing when there's no update, so
/// it takes no space in the footer at rest.
struct UpdatePill: View {
    @Environment(AppModel.self) private var model
    @State private var showPopover = false

    var body: some View {
        Group {
            if model.updater.hasUpdate {
                Button { showPopover = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.primary)
                        Text(pillLabel).font(.callout).lineLimit(1)
                        Spacer(minLength: 4)
                        if case .downloading = model.updater.state {
                            ProgressView().controlSize(.small)
                        } else if case .installing = model.updater.state {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Capsule())
                    .background(Capsule().fill(.quaternary))
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                    .sidebarPillHover()
                }
                .buttonStyle(.plain)
                .help("A new version of Slate is available")
                .popover(isPresented: $showPopover, arrowEdge: .trailing) { popover }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.updater.hasUpdate)
    }

    private var pillLabel: String {
        switch model.updater.state {
        case .downloading: return "Downloading…"
        case .installing:  return "Installing…"
        default:           return "Update available"
        }
    }

    @ViewBuilder private var popover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available").font(.headline)
                    if let m = model.updater.availableManifest {
                        Text("Version \(m.version) · you have \(model.updater.currentVersion)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let m = model.updater.availableManifest, !m.notes.isEmpty {
                ScrollView {
                    Text(m.notes).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }

            switch model.updater.state {
            case .downloading(let p):
                ProgressView(value: p) { Text("Downloading update…").font(.caption) }
            case .installing:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Installing - Slate will relaunch…").font(.caption) }
            case .failed(let msg):
                Text(msg).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }

            HStack {
                Button("Later") { showPopover = false }
                Spacer()
                Button("Install & Relaunch") {
                    model.updater.downloadAndInstall()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PaletteProminentButtonStyle())
                .disabled(isBusy)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private var isBusy: Bool {
        switch model.updater.state {
        case .downloading, .installing: return true
        default: return false
        }
    }
}
