import SwiftUI

/// A reviewable gallery of the cross-cutting edge states so every visible screen
/// can be checked in the Simulator without a real Mac backend.
struct StatesGalleryView: View {
    @Environment(\.slatePalette) private var pal
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                galleryItem("Loading") {
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.ink)
                        Text("Connecting to your Mac…").font(.slate(15)).foregroundStyle(Theme.inkSecondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                galleryItem("Success") {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                        Text("Sent to your Mac").font(.slate(15, .medium)).foregroundStyle(Theme.ink)
                    }.frame(maxWidth: .infinity).padding(.vertical, 20)
                }
                galleryItem("Run error (OOM)") {
                    RunErrorCard(text: "Your Mac couldn't run Llama 3.3 70B: not enough free memory. Try a smaller model.") {}
                }
                galleryItem("Mac offline") { statusPreview(.offline) }
                galleryItem("Waking your Mac") { statusPreview(.waking) }
                galleryItem("Wake failed") { statusPreview(.wakeFailed) }
                galleryItem("Empty") {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(Theme.inkTertiary)
                        Text("Nothing here yet").font(.slate(16, .medium)).foregroundStyle(Theme.ink)
                    }.frame(maxWidth: .infinity).padding(.vertical, 20)
                }
                galleryItem("Dynamic Type (XL)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Connected").font(.slate(15, .medium)).foregroundStyle(Theme.ink)
                        Text("LUCC's MacBook Pro reflows without truncation at the largest text size.")
                            .font(.slate(15)).foregroundStyle(Theme.inkSecondary)
                    }
                    .environment(\.dynamicTypeSize, .accessibility3)
                    .padding(4)
                }
            }
            .padding(16).padding(.bottom, 40)
        }
        .canvas()
        .navigationTitle("Edge states")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statusPreview(_ s: MacStatus) -> some View {
        HStack(spacing: 11) {
            Image(systemName: s.icon).foregroundStyle(s.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.label).font(.slate(14, .medium)).foregroundStyle(Theme.ink)
                Text(s.detail).font(.slate(12)).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            if let a = s.action {
                Text(a).font(.slate(13, .medium)).foregroundStyle(Theme.canvas)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(SlateShape(radius: 9).fill(Theme.ink))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(SlateShape(radius: Theme.rControl).strokeBorder(s.tint.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder private func galleryItem<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) {
            SectionCaption(text: label)
            content().padding(14).slateCard()
        }
    }
}
