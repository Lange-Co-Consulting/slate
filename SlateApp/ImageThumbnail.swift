import SwiftUI
import AppKit
import ImageIO

/// NSImage is not Sendable; this wrapper carries a freshly-decoded, effectively
/// immutable thumbnail across the actor boundary.
private struct SendableImage: @unchecked Sendable { let image: NSImage }

/// Off-main, downsampled, path-keyed thumbnail cache. Avoids re-reading and
/// re-decoding full-resolution images from disk on the main thread every time a
/// view body re-evaluates (e.g. on each streaming token).
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: SendableImage] = [:]

    func thumbnail(path: String, maxPixel: Int) -> NSImage? {
        let key = "\(path)|\(maxPixel)"
        if let hit = cache[key] { return hit.image }
        guard let img = Self.downsample(path: path, maxPixel: maxPixel) else { return nil }
        cache[key] = SendableImage(image: img)
        return img
    }

    private static func downsample(path: String, maxPixel: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Loads a cached thumbnail asynchronously (keyed by path, so it does not re-run
/// on unrelated re-renders) and renders it. `fixedSize` → square aspect-fill chip;
/// otherwise aspect-fit within maxWidth/maxHeight.
struct ThumbnailImage: View {
    let path: String
    let maxPixel: Int
    var fixedSize: CGFloat? = nil
    var maxWidth: CGFloat = 260
    var maxHeight: CGFloat = 260
    var corner: CGFloat = 10
    @State private var image: NSImage?

    var body: some View {
        content.task(id: path) {
            image = await ThumbnailCache.shared.thumbnail(path: path, maxPixel: maxPixel)
        }
    }

    @ViewBuilder private var content: some View {
        if let image {
            if let s = fixedSize {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: s, height: s).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
        } else {
            RoundedRectangle(cornerRadius: corner, style: .continuous).fill(.quaternary.opacity(0.5))
                .frame(width: fixedSize ?? 120, height: fixedSize ?? 90)
                .overlay { Image(systemName: "photo").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
