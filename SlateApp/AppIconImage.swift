import AppKit
import CoreGraphics

/// Draws the Slate "Strata" app icon in-process and returns it as an NSImage, so
/// we can set `NSApp.applicationIconImage` at launch. This makes the Dock show the
/// current logo immediately, bypassing macOS's stale icon cache (iconservicesd),
/// which otherwise keeps showing an old bundled icon until a reboot / cache purge.
/// Geometry mirrors Packaging/gen-icon.swift exactly.
enum SlateAppIcon {
    static func make() -> NSImage {
        let size = 1024
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: NSSize(width: 512, height: 512))
        }
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

        let margin: CGFloat = 88
        let rect = CGRect(x: margin, y: margin, width: CGFloat(size) - 2*margin, height: CGFloat(size) - 2*margin)
        let radius = rect.width * 0.2237
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Graphite gradient fill.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let fill = [CGColor(red: 0.235, green: 0.235, blue: 0.255, alpha: 1),
                    CGColor(red: 0.075, green: 0.075, blue: 0.085, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: fill, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        }
        let sheen = [CGColor(red: 1, green: 1, blue: 1, alpha: 0.12), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        if let gs = CGGradient(colorsSpace: cs, colors: sheen, locations: [0, 1]) {
            ctx.drawLinearGradient(gs, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
        }
        ctx.restoreGState()

        // Hairline inner edge.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.restoreGState()

        // "Strata" - three offset rounded slabs, lightest on top.
        let s: CGFloat = 8.0
        func bar(_ ax: CGFloat, _ ay: CGFloat, _ aw: CGFloat, white: CGFloat) {
            let x = rect.midX + (ax - 60) * s
            let y = rect.midY - (ay + 15 - 60) * s
            let r = CGRect(x: x, y: y, width: aw * s, height: 15 * s)
            let p = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
            ctx.addPath(p)
            ctx.setFillColor(CGColor(red: white, green: white + 0.008, blue: white + 0.02, alpha: 1))
            ctx.fillPath()
        }
        bar(30, 34, 56, white: 0.929)
        bar(42, 53, 48, white: 0.769)
        bar(30, 72, 56, white: 0.588)

        guard let cg = ctx.makeImage() else { return NSImage(size: NSSize(width: 512, height: 512)) }
        return NSImage(cgImage: cg, size: NSSize(width: 512, height: 512))
    }
}
