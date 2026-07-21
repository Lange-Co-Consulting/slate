import AppKit

// Social share card (Open Graph, 1200x630). Weave mark + wordmark, the Roundtable
// positioning headline, and an open-core/one-time-Pro trust pill. Run:
//   swift SlateApp/Packaging/gen-ogcard.swift landing/public/og-card.png

let W = 1200, H = 630
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let gc = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gc
let ctx = gc.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
let Wf = CGFloat(W), Hf = CGFloat(H)

// Background gradient (bottom-left origin; top is y = H).
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.090, green: 0.090, blue: 0.098, alpha: 1),
    CGColor(red: 0.031, green: 0.031, blue: 0.035, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: Hf), end: CGPoint(x: Wf, y: 0), options: [])

// --- Weave mark (top-left). Design units 0..100; bbox x22..72, y22..78. ---
let s: CGFloat = 1.6                    // scale: ~90px tall
let markLeft: CGFloat = 86              // screen x of the bbox left (design x=22)
let markTopFromTop: CGFloat = 60       // screen px from the top edge to bbox top (design y=22)
func slab(_ dx: CGFloat, _ dy: CGFloat, _ dw: CGFloat, _ dh: CGFloat, _ c: NSColor) {
    let x = markLeft + (dx - 22) * s
    let topFromTop = markTopFromTop + (dy - 22) * s
    let h = dh * s, w = dw * s
    let yBottomUp = Hf - topFromTop - h          // flip to bottom-left origin
    let r = CGRect(x: x, y: yBottomUp, width: w, height: h)
    let rad = min(w, h) / 2
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
    ctx.setFillColor(c.cgColor); ctx.fillPath()
}
let bright = NSColor(red: 0.949, green: 0.949, blue: 0.957, alpha: 1)   // #f2f2f4
let quiet  = NSColor(red: 0.671, green: 0.671, blue: 0.698, alpha: 1)   // #ababb2
slab(28, 22, 11, 50, quiet)     // left vertical  (weft)
slab(61, 28, 11, 50, quiet)     // right vertical (weft)
slab(22, 61, 50, 11, bright)    // bottom horizontal (warp)
slab(28, 28, 50, 11, bright)    // top horizontal    (warp)

// --- Text. draw(at:) point = lower-left in this non-flipped context. ---
func draw(_ text: String, x: CGFloat, topFromTop: CGFloat, size: CGFloat,
          weight: NSFont.Weight, color: NSColor, kern: CGFloat = 0) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
    let str = NSAttributedString(string: text, attributes: attrs)
    let h = str.size().height
    str.draw(at: CGPoint(x: x, y: Hf - topFromTop - h))
}

draw("Slate", x: 188, topFromTop: 78, size: 46, weight: .semibold, color: bright, kern: -1)
draw("A council of local models.", x: 84, topFromTop: 236, size: 82, weight: .semibold,
     color: NSColor(red: 0.965, green: 0.965, blue: 0.969, alpha: 1), kern: -3)
draw("One answer.", x: 86, topFromTop: 330, size: 82, weight: .semibold,
     color: NSColor(red: 0.965, green: 0.965, blue: 0.969, alpha: 1), kern: -3)
draw("Several local models debate, then synthesize. 100% offline.", x: 88, topFromTop: 452,
     size: 29, weight: .regular, color: NSColor(red: 0.663, green: 0.663, blue: 0.686, alpha: 1))

// Trust pill.
let pill = CGRect(x: 88, y: Hf - 512 - 60, width: 540, height: 60)
ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 30, cornerHeight: 30, transform: nil))
ctx.setFillColor(bright.cgColor); ctx.fillPath()
draw("Open-source core · one-time Pro · macOS", x: 118, topFromTop: 530, size: 22,
     weight: .semibold, color: NSColor(red: 0.067, green: 0.067, blue: 0.075, alpha: 1))

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "og-card.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
