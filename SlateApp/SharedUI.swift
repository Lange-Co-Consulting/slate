import SwiftUI
import SlateCore
import SlateUI

/// Guidance shown wherever a surface has no usable model - the single source of
/// truth for the app's "get a model" first-run affordance (empty state, an open
/// empty conversation, and the image section all render THIS, so they stay 1:1).
struct NoModelGuidance: View {
    enum Kind { case chat, code, image }
    @Environment(AppModel.self) private var model
    var kind: Kind = .chat
    var markWidth: CGFloat = 64

    var body: some View {
        VStack(spacing: 16) {
            SlateMark(width: markWidth)
            Text(headline)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button { model.showModelManager = true } label: {
                        Label(primaryTitle, systemImage: "arrow.down.circle")
                            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
                    }
                    .liquidHover()
                    if kind != .image {
                        Button {
                            model.pendingSettingsTab = "cloud"
                            model.showSettings = true
                        } label: {
                            Label("Add a cloud model", systemImage: "cloud")
                                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
                        }
                        .liquidHover()
                    }
                }
                .buttonStyle(ClearGlassButtonStyle())
            }
        }
        .frame(maxWidth: 460)
    }

    private var headline: String {
        switch kind {
        case .image: return "No image model yet - download one to start generating."
        default: return model.models.isEmpty
            ? "No model yet - Slate runs your own local models."
            : "No model loaded."
        }
    }
    private var primaryTitle: String {
        switch kind {
        case .image: return "Download an image model"
        default: return model.models.isEmpty ? "Download a model" : "Choose a model"
        }
    }
}

/// Shared RAM-fit indicator - a colored dot, optionally with a text label. Used
/// by the Model Manager and the Downloads sheet so they read identically.
struct FitDot: View {
    let bytes: Int64
    let ram: UInt64
    var showLabel = false
    var body: some View {
        let fit = ModelRAMFit.evaluate(fileBytes: bytes, physicalRAM: ram)
        let (color, text): (Color, String) = switch fit {
        case .comfortable: (.green, "fits")
        case .tight:       (.orange, "tight")
        case .tooBig:      (.red, "too big")
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            if showLabel { Text(text).font(.caption2).foregroundStyle(.secondary) }
        }
        .accessibilityElement()
        .accessibilityLabel("RAM fit: \(text)")
        .help("RAM fit: \(text) on \(ByteCountFormatter.string(fromByteCount: Int64(ram), countStyle: .memory))")
    }
}
