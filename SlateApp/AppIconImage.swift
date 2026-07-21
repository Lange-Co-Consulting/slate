import AppKit
import CoreGraphics

/// Draws the Slate "Weave" app icon in-process and returns it as an NSImage, so
/// we can set `NSApp.applicationIconImage` at launch. This makes the Dock show the
/// current logo immediately, bypassing macOS's stale icon cache (iconservicesd),
/// which otherwise keeps showing an old bundled icon until a reboot / cache purge.
/// It is also what a terminal build (`swift run SlateApp`, no .app bundle) shows.
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

        // "Weave" mark - four rounded slabs woven around a protected square core:
        // two bright horizontals (warp) over two quiet verticals (weft). Geometry
        // ported 1:1 from Packaging/gen-icon.swift (design viewBox 0..100, bg 6..94).
        // Paint order (weft first, warp last) creates the over/under weave illusion.
        let k = rect.width / 88.0                          // px per design unit
        func slab(_ vx: CGFloat, _ vy: CGFloat, _ vw: CGFloat, _ vh: CGFloat,
                  _ cr: CGFloat, _ cg: CGFloat, _ cb: CGFloat) {
            let x = rect.minX + (vx - 6) * k               // design x → CG x
            let yTop = rect.maxY - (vy - 6) * k            // design y (top edge) → CG y (flip)
            let h = vh * k
            let r = CGRect(x: x, y: yTop - h, width: vw * k, height: h)
            let rad = 5.5 * k
            let p = CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
            ctx.addPath(p)
            ctx.setFillColor(CGColor(red: cr, green: cg, blue: cb, alpha: 1))
            ctx.fillPath()
        }
        let bR: CGFloat = 0.949, bG: CGFloat = 0.949, bB: CGFloat = 0.957   // #f2f2f4 warp (bright)
        let qR: CGFloat = 0.671, qG: CGFloat = 0.671, qB: CGFloat = 0.698   // #ababb2 weft (quiet)
        slab(28, 22, 11, 50, qR, qG, qB)       // left vertical   (weft, under)
        slab(61, 28, 11, 50, qR, qG, qB)       // right vertical  (weft, under)
        slab(22, 61, 50, 11, bR, bG, bB)       // bottom horizontal (warp, over)
        slab(28, 28, 50, 11, bR, bG, bB)       // top horizontal    (warp, over)

        guard let cg = ctx.makeImage() else { return NSImage(size: NSSize(width: 512, height: 512)) }
        return NSImage(cgImage: cg, size: NSSize(width: 512, height: 512))
    }
}
