import SwiftUI

/// The Slate "Weave" mark — four rounded slabs woven around a protected square core:
/// two bright horizontals (warp) over two quiet verticals (weft). Drawn in code from the
/// brand vector (`BrandAssets/Slate-mark-light.svg`) so it scales crisply and needs no asset.
/// Used on DARK backgrounds (the app's identity), so warp = bright ink, weft = a muted tone.
struct WeaveMark: View {
    var size: CGFloat = 44
    var tint: Color = Theme.ink   // warp (bright); weft is a quieter tone of it

    var body: some View {
        Canvas { ctx, cs in
            // Mark geometry in the brand's 100-unit grid (bbox x[22…72] y[22…78],
            // centre (47,50)). Fit the 50×56 bbox into the square with ~10% padding.
            let k = cs.width / 62.0
            let weft = tint.opacity(0.62)          // ≈ #ABABB2 relative to #F2F2F4
            func slab(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
                let rect = CGRect(x: (x - 47) * k + cs.width / 2,
                                  y: (y - 50) * k + cs.height / 2,
                                  width: w * k, height: h * k)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 5.5 * k, style: .continuous),
                         with: .color(color))
            }
            // weft (quiet verticals) drawn first, warp (bright horizontals) woven over
            slab(28, 22, 11, 50, weft)
            slab(61, 28, 11, 50, weft)
            slab(22, 61, 50, 11, tint)
            slab(28, 28, 50, 11, tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview {
    ZStack { Theme.canvas.ignoresSafeArea(); WeaveMark(size: 96) }
}
