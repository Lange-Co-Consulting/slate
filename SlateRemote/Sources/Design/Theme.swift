import SwiftUI
import UIKit

/// Slate Remote design tokens — the iOS translation of Slate's settled visual
/// identity: near-black canvas, fully monochrome, semantic green/red only, faint
/// charcoal seams, continuous corner curvature. Mirrors the macOS app's `DS.*`.
///
/// Every color is a **dynamic** `Color(light:dark:)` resolved from the trait
/// environment, so the whole app adapts to Light/Dark with zero call-site churn —
/// all ~160 `Theme.foo` sites keep working. Selectable accent/theme presets ride a
/// separate `SlatePalette` injected through `\.slatePalette` (see Palette.swift);
/// the monochrome base here is the always-present foundation the palette tints over.
enum Theme {
    // Surfaces (near-black canvas + faint "Strata" elevations in dark; a soft paper
    // stack in light). Radii are appearance-independent.
    static let canvas      = Color(light: 0xF6F6F8, dark: 0x0A0A0C)
    static let surface     = Color(light: 0xFFFFFF, dark: 0x141416)   // cards
    static let surfaceHigh = Color(light: 0xEDEDF1, dark: 0x1C1C1F)   // pressed / elevated
    static let hairline    = Color(light: 0xE3E3E9, dark: 0x2A2A2E)
    /// The deep camera "well" behind the QR viewfinder — reads as a lens on both schemes.
    static let well        = Color(light: 0x101014, dark: 0x050506)

    // Ink (monochrome), inverted between schemes.
    static let ink          = Color(light: 0x17171A, dark: 0xF2F2F4)  // primary text
    static let inkSecondary = Color(light: 0x6B6B73, dark: 0x9A9AA2)  // secondary text
    static let inkTertiary  = Color(light: 0x76767E, dark: 0x62626A)  // hints / disabled (light deepened for AA)

    // Semantics — the ONLY colours beyond monochrome. Light channels are deepened to clear
    // WCAG AA (≥4.5:1) for the small status text they colour on a near-white ground.
    static let ok     = Color(light: 0x15754A, dark: 0x63D69B)  // fit / connected / success
    static let danger = Color(light: 0xC6443E, dark: 0xE2554E)  // revoke / offline / error
    static let warn   = Color(light: 0x8A6320, dark: 0xE5B25B)  // waking / degraded

    // Corner radii (continuous curvature everywhere).
    static let rCard: CGFloat = 20
    static let rControl: CGFloat = 14
    static let rChip: CGFloat = 11
    static let rBubble: CGFloat = 18

    /// The flat-color equivalent of `CanvasBackground`'s composite — the palette's canvas
    /// washed over the monochrome base (plusLighter-ish in dark, multiply-ish in light;
    /// a plain linear blend at the same fractions). Pinned bars need an opaque `Color`,
    /// and raw `Theme.canvas` would cut the wash off at the toolbar edge.
    static func washedCanvas(_ pal: SlatePalette, _ scheme: ColorScheme) -> Color {
        guard pal.enabled else { return canvas }
        let dark = scheme == .dark
        let baseR: Double = dark ? 10.0 / 255.0 : 246.0 / 255.0   // canvas 0x0A0A0C / 0xF6F6F8
        let baseG: Double = dark ? 10.0 / 255.0 : 246.0 / 255.0
        let baseB: Double = dark ? 12.0 / 255.0 : 248.0 / 255.0
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(pal.canvas).getRed(&r, green: &g, blue: &b, alpha: &a)
        let f: Double = dark ? 0.16 : 0.10
        let outR: Double = baseR + (Double(r) - baseR) * f
        let outG: Double = baseG + (Double(g) - baseG) * f
        let outB: Double = baseB + (Double(b) - baseB) * f
        return Color(.sRGB, red: outR, green: outG, blue: outB, opacity: 1)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// A trait-reactive color: SwiftUI resolves `light`/`dark` from the active
    /// `colorScheme`, so a single token adapts everywhere it's used.
    init(light: UInt32, dark: UInt32) {
        self = Color(uiColor: UIColor { tc in
            tc.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    // Two weights only (400/500), SF Rounded for the calm, product feel.
    // The requested point size buckets to the nearest TextStyle so every label
    // scales with Dynamic Type instead of freezing at a fixed size.
    static func slate(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let style: Font.TextStyle
        switch size {
        case 32...:   style = .largeTitle
        case 26..<32: style = .title
        case 21..<26: style = .title2
        case 19..<21: style = .title3
        case 16..<19: style = .body
        case 14..<16: style = .subheadline
        case 13..<14: style = .footnote
        case 12..<13: style = .caption
        default:      style = .caption2
        }
        return .system(style, design: .rounded).weight(weight)
    }
}

/// A continuous rounded rectangle — Slate uses continuous curvature everywhere.
/// Insettable so `.strokeBorder` (which insets by half the line width) works.
struct SlateShape: InsettableShape {
    var radius: CGFloat
    var insetAmount: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect.insetBy(dx: insetAmount, dy: insetAmount),
             cornerRadius: max(0, radius - insetAmount), style: .continuous)
    }
    func inset(by amount: CGFloat) -> some InsettableShape {
        var s = self; s.insetAmount += amount; return s
    }
}

extension View {
    /// Standard card treatment: elevated surface, hairline stroke, continuous corners.
    func slateCard(_ radius: CGFloat = Theme.rCard, fill: Color = Theme.surface) -> some View {
        self.background(
            SlateShape(radius: radius).fill(fill)
                .overlay(SlateShape(radius: radius).strokeBorder(Theme.hairline, lineWidth: 1))
        )
    }
}
