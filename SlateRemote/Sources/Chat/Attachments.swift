import Foundation
import SlateRemoteProtocol
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Something staged in the composer, before it is sent with the next prompt.
struct StagedAttachment: Identifiable, Equatable {
    let id = UUID()
    let attachment: Attachment
    /// Thumbnail for images; nil for files, which show a document glyph.
    let preview: UIImage?

    var name: String { attachment.name }
    var isImage: Bool { attachment.kind == .image }
}

enum AttachmentBuilder {
    /// Longest edge after downscaling. A modern iPhone photo is ~4000px and 4 MB; a vision
    /// model sees a few hundred pixels after its own preprocessing, so sending the original
    /// would waste seconds of Wi-Fi for no quality at all.
    private static let maxEdge: CGFloat = 1536
    private static let jpegQuality: CGFloat = 0.8
    /// Text files above this are truncated: they are inlined into the prompt, and a huge file
    /// would blow the model's context rather than help it.
    private static let maxTextBytes = 200_000

    /// Downscale, re-encode as JPEG, and wrap as an image attachment.
    static func image(_ image: UIImage, name: String = "photo.jpg") -> StagedAttachment? {
        let scaled = downscale(image)
        guard let data = scaled.jpegData(compressionQuality: jpegQuality) else { return nil }
        return StagedAttachment(
            attachment: Attachment(kind: .image, name: name, mime: "image/jpeg", data: data),
            preview: scaled)
    }

    /// Wrap a picked file. Text is passed through (truncated if enormous) because the Mac
    /// inlines it into the prompt; anything else is sent as-is and named for the model.
    static func file(at url: URL) -> StagedAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard var data = try? Data(contentsOf: url) else { return nil }

        let type = UTType(filenameExtension: url.pathExtension)
        let isText = type?.conforms(to: .text) ?? false
        if isText, data.count > maxTextBytes { data = data.prefix(maxTextBytes) }

        // An image picked through the file browser still goes down the image path.
        if let type, type.conforms(to: .image), let img = UIImage(data: data) {
            return image(img, name: url.lastPathComponent)
        }
        return StagedAttachment(
            attachment: Attachment(kind: .file, name: url.lastPathComponent,
                                   mime: type?.preferredMIMEType ?? "application/octet-stream",
                                   data: data),
            preview: nil)
    }

    private static func downscale(_ image: UIImage) -> UIImage {
        let w = image.size.width, h = image.size.height
        let longest = max(w, h)
        guard longest > maxEdge else { return image }
        let scale = maxEdge / longest
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// The row of staged attachments above the composer.
struct AttachmentStrip: View {
    let items: [StagedAttachment]
    let remove: (StagedAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let preview = item.preview {
                                Image(uiImage: preview)
                                    .resizable().scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(SlateShape(radius: 12))
                            } else {
                                VStack(spacing: 3) {
                                    Image(systemName: "doc").font(.slate(18))
                                    Text(item.name).font(.slate(9)).lineLimit(1)
                                }
                                .foregroundStyle(Theme.inkSecondary)
                                .frame(width: 64, height: 64)
                                .background(SlateShape(radius: 12).fill(Theme.surface))
                                .overlay(SlateShape(radius: 12).strokeBorder(Theme.hairline, lineWidth: 1))
                            }
                        }
                        Button { remove(item) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.slate(15))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Theme.canvas, Theme.ink)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove \(item.name)")
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 76)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
