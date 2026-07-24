import SwiftUI
import UIKit

/// The iOS port of Slate's `SlatePalette` color language (macOS `slate-ui`). Six user
/// hexes — canvas / surface / accent / three chat bubbles — with every ink color DERIVED
/// by WCAG luminance so labels stay readable on any choice, and a dark-mode accent lift so
/// tinted controls keep legible text. The whole thing is gated by `enabled`: when a preset
/// isn't active the app renders in its monochrome `Theme` identity. Mirrors the Mac so a
/// preset picked on either device reads as the same product.
struct SlatePalette: Equatable {
    var enabled: Bool
    var canvas: Color
    var surface: Color
    var accent: Color
    var userBubble: Color
    var assistantBubble: Color
    var toolBubble: Color
    // Derived, readable inks + a scheme-adaptive control accent.
    var accentInk: Color
    var userBubbleInk: Color
    var assistantBubbleInk: Color
    var controlAccent: Color

    init(enabled: Bool, canvas: String, surface: String, accent: String,
         userBubble: String, assistantBubble: String, toolBubble: String) {
        let c = RGB(hex: canvas), s = RGB(hex: surface), a = RGB(hex: accent)
        let ub = RGB(hex: userBubble), ab = RGB(hex: assistantBubble), tb = RGB(hex: toolBubble)
        self.enabled = enabled
        self.canvas = c.color; self.surface = s.color; self.accent = a.color
        self.userBubble = ub.color; self.assistantBubble = ab.color; self.toolBubble = tb.color
        self.accentInk = a.contrastInk
        self.userBubbleInk = ub.contrastInk
        self.assistantBubbleInk = ab.contrastInk
        self.controlAccent = a.adaptiveControlColor
    }

    /// The always-available monochrome identity (custom colors OFF).
    static let monochrome = SlatePalette(
        enabled: false, canvas: "#0A0A0C", surface: "#141416", accent: "#F2F2F4",
        userBubble: "#1C1C1F", assistantBubble: "#141416", toolBubble: "#1C1C1F")
}

/// A named built-in color language. Hexes are 1:1 with the macOS `PalettePreset` set.
struct PalettePreset: Identifiable, Equatable {
    let id: String
    let name: String
    let canvas, surface, accent, userBubble, assistantBubble, toolBubble: String

    func palette(enabled: Bool = true) -> SlatePalette {
        SlatePalette(enabled: enabled, canvas: canvas, surface: surface, accent: accent,
                     userBubble: userBubble, assistantBubble: assistantBubble, toolBubble: toolBubble)
    }

    static let all: [PalettePreset] = [
        .init(id: "aurora",    name: "Aurora",    canvas: "#5752C7", surface: "#2E6F78", accent: "#9B8CFF", userBubble: "#6F5EEA", assistantBubble: "#2B3548", toolBubble: "#3D4657"),
        .init(id: "graphite",  name: "Graphite",  canvas: "#3C3F47", surface: "#2A2D33", accent: "#6B7CE8", userBubble: "#4E5BC8", assistantBubble: "#23252B", toolBubble: "#31343B"),
        .init(id: "slate",     name: "Slate",     canvas: "#33465C", surface: "#22303F", accent: "#7CA9E6", userBubble: "#47698F", assistantBubble: "#1A2029", toolBubble: "#28323F"),
        .init(id: "nord",      name: "Nord",      canvas: "#3B4252", surface: "#2E3440", accent: "#88C0D0", userBubble: "#5E81AC", assistantBubble: "#232830", toolBubble: "#333B49"),
        .init(id: "evergreen", name: "Evergreen", canvas: "#1C5B41", surface: "#123D31", accent: "#3FCF8E", userBubble: "#2E9E6B", assistantBubble: "#17241E", toolBubble: "#22362C"),
        .init(id: "lagoon",    name: "Lagoon",    canvas: "#0F5D63", surface: "#0B3E42", accent: "#34D3BE", userBubble: "#1C8E88", assistantBubble: "#132120", toolBubble: "#1C302E"),
        .init(id: "ocean",     name: "Ocean",     canvas: "#1E4FA0", surface: "#123763", accent: "#5BA8FF", userBubble: "#2C6FE0", assistantBubble: "#16202F", toolBubble: "#223247"),
        .init(id: "amethyst",  name: "Amethyst",  canvas: "#5E2E86", surface: "#3C1E57", accent: "#C084FC", userBubble: "#8B54D6", assistantBubble: "#211A2C", toolBubble: "#322446"),
        .init(id: "rose",      name: "Rosé",      canvas: "#A03A6E", surface: "#5E2444", accent: "#F472B6", userBubble: "#D9508F", assistantBubble: "#241922", toolBubble: "#362430"),
        .init(id: "ember",     name: "Ember",     canvas: "#9A3E12", surface: "#5C2B12", accent: "#FB923C", userBubble: "#E87A1E", assistantBubble: "#261C15", toolBubble: "#38291D"),
        .init(id: "honey",     name: "Honey",     canvas: "#7A5A12", surface: "#4E3A0E", accent: "#FBBF24", userBubble: "#C99A2E", assistantBubble: "#211C12", toolBubble: "#322A1A"),
        .init(id: "crimson",   name: "Crimson",   canvas: "#8E2A2A", surface: "#571B1B", accent: "#F87171", userBubble: "#C7443F", assistantBubble: "#241616", toolBubble: "#35201F"),
    ]

    static func byID(_ id: String) -> PalettePreset { all.first { $0.id == id } ?? all[0] }
}

// MARK: - Environment injection

private struct SlatePaletteKey: EnvironmentKey {
    static let defaultValue = SlatePalette.monochrome
}
extension EnvironmentValues {
    var slatePalette: SlatePalette {
        get { self[SlatePaletteKey.self] }
        set { self[SlatePaletteKey.self] = newValue }
    }
}

// MARK: - WCAG contrast + dark-mode accent lift (UIKit)

private struct RGB {
    let r, g, b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let v = UInt64(cleaned, radix: 16) else {
            self = RGB(r: 0.52, g: 0.49, b: 0.96); return
        }
        self.init(r: Double((v >> 16) & 0xFF) / 255,
                  g: Double((v >> 8) & 0xFF) / 255,
                  b: Double(v & 0xFF) / 255)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
    private var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

    private var relativeLuminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
    private var usesBlackInk: Bool {
        let black = (relativeLuminance + 0.05) / 0.05
        let white = 1.05 / (relativeLuminance + 0.05)
        return black >= white
    }
    /// Stronger of black/white by WCAG contrast — for ink drawn on this fill.
    var contrastInk: Color { usesBlackInk ? .black : .white }

    private func mixedWithWhite(_ amount: Double) -> RGB {
        RGB(r: r + (1 - r) * amount, g: g + (1 - g) * amount, b: b + (1 - b) * amount)
    }
    private func mixedWithBlack(_ amount: Double) -> RGB {
        RGB(r: r * (1 - amount), g: g * (1 - amount), b: b * (1 - amount))
    }
    /// A dark accent lightened until it can carry readable control text in Dark Mode.
    private var darkLifted: RGB {
        guard relativeLuminance < 0.34 else { return self }
        for step in 1...20 {
            let cand = mixedWithWhite(Double(step) * 0.04)
            if cand.relativeLuminance >= 0.34 { return cand }
        }
        return mixedWithWhite(0.8)
    }
    /// The mirror of `darkLifted`: a pastel accent darkened until it holds ≥3:1
    /// contrast as a tint against the light canvas. 3:1 vs white ⇒ L ≤ 0.30.
    private var lightDeepened: RGB {
        guard relativeLuminance > 0.30 else { return self }
        for step in 1...20 {
            let cand = mixedWithBlack(Double(step) * 0.05)
            if cand.relativeLuminance <= 0.30 { return cand }
        }
        return mixedWithBlack(0.8)
    }
    /// Contrast-corrected in BOTH schemes: luminance-lifted in Dark Mode,
    /// luminance-deepened in Light Mode, so tinted controls stay legible.
    var adaptiveControlColor: Color {
        let deepened = lightDeepened.uiColor, lifted = darkLifted.uiColor
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? lifted : deepened })
    }
}
