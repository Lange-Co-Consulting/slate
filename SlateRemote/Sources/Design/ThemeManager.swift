import SwiftUI
import Observation

/// The app's appearance store — two orthogonal axes, exactly like the macOS app:
///  1. **Appearance** (System / Light / Dark) → `preferredColorScheme`, default Dark (the identity).
///  2. **Color** — a `customColorsEnabled` toggle + a selected `PalettePreset`. OFF ⇒ the app
///     renders monochrome; ON ⇒ the six preset hexes tint the app (accent, bubbles, canvas wash).
///
/// Mirrors the existing `AppState` shape (`@MainActor @Observable`, injected via `.environment`)
/// and persists to UserDefaults with the `didSet` idiom so it composes cleanly with `@Observable`.
@MainActor @Observable
final class ThemeManager {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }
        /// nil ⇒ follow the device (System).
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }
    }

    var appearance: Appearance { didSet { Self.defaults.set(appearance.rawValue, forKey: Self.kAppearance) } }
    var customColorsEnabled: Bool { didSet { Self.defaults.set(customColorsEnabled, forKey: Self.kCustom) } }
    var presetID: String { didSet { Self.defaults.set(presetID, forKey: Self.kPreset) } }

    /// The resolved color language handed to the view tree via `\.slatePalette`.
    var palette: SlatePalette {
        customColorsEnabled ? PalettePreset.byID(presetID).palette(enabled: true) : .monochrome
    }

    /// The global `.tint` — palette accent when custom colors are on, else monochrome ink.
    var accent: Color { customColorsEnabled ? palette.controlAccent : Theme.ink }

    var preset: PalettePreset { PalettePreset.byID(presetID) }

    init() {
        let d = Self.defaults
        self.appearance = Appearance(rawValue: d.string(forKey: Self.kAppearance) ?? "") ?? .dark
        // Default OFF: honor the monochrome-dark brand identity; themes are one tap away.
        self.customColorsEnabled = d.object(forKey: Self.kCustom) as? Bool ?? false
        self.presetID = d.string(forKey: Self.kPreset) ?? "graphite"
    }

    private static let defaults = UserDefaults.standard
    private static let kAppearance = "slate.remote.appearance"
    private static let kCustom = "slate.remote.customColors"
    private static let kPreset = "slate.remote.preset"
}
