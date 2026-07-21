import Foundation

/// UI language for the onboarding + hardware popups. "system" resolves to the
/// Mac's language; the popups also let the user force EN or DE explicitly, so
/// the tutorial is guaranteed available in both regardless of system language.
enum UILang: String {
    case en, de
    static func resolve(_ setting: String) -> UILang {
        switch setting {
        case "de": return .de
        case "en": return .en
        default: return (Locale.current.language.languageCode?.identifier == "de") ? .de : .en
        }
    }
    /// Pick the right side of an inline bilingual string.
    func callAsFunction(_ en: String, _ de: String) -> String { self == .de ? de : en }
}

/// A real Mac chip and the configurations Apple actually shipped it in, so the
/// GPU + RAM dropdowns only ever offer valid combinations (an M4 Pro is 16- or
/// 20-core GPU with 24 or 48 GB - never 40-core).
struct ChipSpec: Sendable, Equatable {
    let name: String
    let gpus: [String]      // e.g. ["16-core GPU", "20-core GPU"]
    let ramGB: [Int]        // e.g. [24, 48]
}

enum HardwareCatalog {
    /// Verified Apple Silicon configurations (plus generic Intel/Other rows).
    static let chipSpecs: [ChipSpec] = [
        ChipSpec(name: "Apple M1",       gpus: ["7-core GPU", "8-core GPU"],   ramGB: [8, 16]),
        ChipSpec(name: "Apple M1 Pro",   gpus: ["14-core GPU", "16-core GPU"], ramGB: [16, 32]),
        ChipSpec(name: "Apple M1 Max",   gpus: ["24-core GPU", "32-core GPU"], ramGB: [32, 64]),
        ChipSpec(name: "Apple M1 Ultra", gpus: ["48-core GPU", "64-core GPU"], ramGB: [64, 128]),
        ChipSpec(name: "Apple M2",       gpus: ["8-core GPU", "10-core GPU"],  ramGB: [8, 16, 24]),
        ChipSpec(name: "Apple M2 Pro",   gpus: ["16-core GPU", "19-core GPU"], ramGB: [16, 32]),
        ChipSpec(name: "Apple M2 Max",   gpus: ["30-core GPU", "38-core GPU"], ramGB: [32, 64, 96]),
        ChipSpec(name: "Apple M2 Ultra", gpus: ["60-core GPU", "76-core GPU"], ramGB: [64, 128, 192]),
        ChipSpec(name: "Apple M3",       gpus: ["8-core GPU", "10-core GPU"],  ramGB: [8, 16, 24]),
        ChipSpec(name: "Apple M3 Pro",   gpus: ["14-core GPU", "18-core GPU"], ramGB: [18, 36]),
        ChipSpec(name: "Apple M3 Max",   gpus: ["30-core GPU", "40-core GPU"], ramGB: [36, 48, 64, 96, 128]),
        ChipSpec(name: "Apple M3 Ultra", gpus: ["60-core GPU", "80-core GPU"], ramGB: [96, 256, 512]),
        ChipSpec(name: "Apple M4",       gpus: ["8-core GPU", "10-core GPU"],  ramGB: [16, 24, 32]),
        ChipSpec(name: "Apple M4 Pro",   gpus: ["16-core GPU", "20-core GPU"], ramGB: [24, 48]),
        ChipSpec(name: "Apple M4 Max",   gpus: ["32-core GPU", "40-core GPU"], ramGB: [36, 48, 64, 128]),
        ChipSpec(name: "Intel Core i5",  gpus: ["Intel integrated", "AMD Radeon (discrete)"], ramGB: [8, 16, 32]),
        ChipSpec(name: "Intel Core i7",  gpus: ["Intel integrated", "AMD Radeon (discrete)"], ramGB: [8, 16, 32, 64]),
        ChipSpec(name: "Intel Core i9",  gpus: ["AMD Radeon (discrete)"],      ramGB: [16, 32, 64, 128]),
    ]

    /// Fallbacks for an unknown / "Other" Mac - every option, so nobody is stuck.
    static let genericGPUs: [String] = [
        "8-core GPU", "10-core GPU", "14-core GPU", "16-core GPU", "18-core GPU",
        "19-core GPU", "20-core GPU", "24-core GPU", "30-core GPU", "32-core GPU",
        "38-core GPU", "40-core GPU", "48-core GPU", "60-core GPU", "64-core GPU",
        "76-core GPU", "80-core GPU", "Intel integrated", "AMD Radeon (discrete)", "Other",
    ]
    static let genericRAM: [Int] = [8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 256, 512]

    /// Chip names for the picker, plus a trailing "Other".
    static var chips: [String] { chipSpecs.map(\.name) + ["Other"] }

    static func spec(for chip: String?) -> ChipSpec? {
        guard let chip else { return nil }
        return chipSpecs.first { $0.name == chip }
    }

    /// GPU options valid for the selected chip (all of them for unknown/"Other").
    static func gpuOptions(for chip: String?) -> [String] {
        spec(for: chip)?.gpus ?? genericGPUs
    }

    /// RAM options valid for the selected chip (all of them for unknown/"Other").
    static func ramOptions(for chip: String?) -> [Int] {
        spec(for: chip)?.ramGB ?? genericRAM
    }

    // MARK: detection

    /// The CPU brand string (e.g. "Apple M4 Pro"), mapped to the closest catalog
    /// entry, or nil if it can't be read.
    static func detectedChip() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return nil }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let raw = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        // Prefer the most specific catalog match (so "Apple M4 Pro" beats "Apple M4").
        return chipSpecs.map(\.name)
            .filter { raw.localizedCaseInsensitiveContains($0) }
            .max(by: { $0.count < $1.count })
    }

    /// Installed physical memory, snapped to the nearest option the given chip
    /// actually offers (or the generic list when the chip is unknown).
    static func detectedRAMGB(for chip: String?) -> Int {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let options = ramOptions(for: chip)
        return options.min(by: { abs(Double($0) - gb) < abs(Double($1) - gb) }) ?? 16
    }

    /// One-line guidance for the picked RAM - which local models are comfortable.
    static func fitHint(ramGB: Int, _ l: UILang) -> String {
        switch ramGB {
        case ..<16:
            return l("Small models only - up to ~7B at 4-bit. Image generation will be tight.",
                     "Nur kleine Modelle - bis ~7B bei 4-Bit. Bildgenerierung wird knapp.")
        case 16...24:
            return l("Comfortable up to ~14B; a 30B MoE runs at low quant. Local image generation works with CPU offload.",
                     "Bequem bis ~14B; ein 30B-MoE läuft bei niedriger Quantisierung. Lokale Bildgenerierung funktioniert mit CPU-Offload.")
        case 25...48:
            return l("Up to ~30B comfortably, and image generation with headroom.",
                     "Bis ~30B bequem, und Bildgenerierung mit Reserve.")
        default:
            return l("Large models and image generation run comfortably.",
                     "Große Modelle und Bildgenerierung laufen bequem.")
        }
    }
}
