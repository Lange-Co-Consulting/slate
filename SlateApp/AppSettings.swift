import Foundation
import Observation
import SlateCore
import SwiftUI
import SlateUI

@MainActor @Observable
final class AppSettings {
    struct PortableSnapshot: Codable {
        var theme: String
        var customColorsEnabled: Bool?
        var canvasColorHex: String?
        var surfaceColorHex: String?
        var accentColorHex: String?
        var userBubbleColorHex: String?
        var assistantBubbleColorHex: String?
        var toolBubbleColorHex: String?
        var memoryEnabled: Bool
        var cloudEnabled: Bool
        var silentModeEnabled: Bool?
        var defaultTemperature: Double
        var maxTokens: Int
        var contextWindow: Int
        var defaultModelPath: String?
        var chatModelPath: String?
        var fallbackModelPath: String?
        var claudeCliPath: String?
        var claudeModel: String?
        var openCodeCliPath: String?
        var openCodeModels: [String]?
        var cloudProviders: [CloudProvider]?
        var thinkingEffort: String
    }

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var colorScheme: ColorScheme? {
            switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
        }
    }

    var theme: Theme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "slate.theme") }
    }
    static let defaultCanvasHex = "#5752C7"
    static let defaultSurfaceHex = "#2E6F78"
    static let defaultAccentHex = "#9B8CFF"
    static let defaultUserBubbleHex = "#6F5EEA"
    static let defaultAssistantBubbleHex = "#2B3548"
    static let defaultToolBubbleHex = "#3D4657"

    var customColorsEnabled: Bool {
        didSet { UserDefaults.standard.set(customColorsEnabled, forKey: "slate.customColorsEnabled") }
    }
    var canvasColorHex: String {
        didSet { UserDefaults.standard.set(canvasColorHex, forKey: "slate.canvasColorHex") }
    }
    var surfaceColorHex: String {
        didSet { UserDefaults.standard.set(surfaceColorHex, forKey: "slate.surfaceColorHex") }
    }
    var accentColorHex: String {
        didSet { UserDefaults.standard.set(accentColorHex, forKey: "slate.accentColorHex") }
    }
    var userBubbleColorHex: String {
        didSet { UserDefaults.standard.set(userBubbleColorHex, forKey: "slate.userBubbleColorHex") }
    }
    var assistantBubbleColorHex: String {
        didSet { UserDefaults.standard.set(assistantBubbleColorHex, forKey: "slate.assistantBubbleColorHex") }
    }
    var toolBubbleColorHex: String {
        didSet { UserDefaults.standard.set(toolBubbleColorHex, forKey: "slate.toolBubbleColorHex") }
    }
    static let maxCustomPresets = 24
    /// User-saved palettes, applied in one tap. Persisted as JSON.
    var customPalettePresets: [PalettePreset] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(customPalettePresets) {
                UserDefaults.standard.set(data, forKey: "slate.customPalettePresets")
            }
        }
    }

    var palette: SlatePalette {
        SlatePalette(enabled: customColorsEnabled,
                     canvasHex: canvasColorHex,
                     surfaceHex: surfaceColorHex,
                     accentHex: accentColorHex,
                     userBubbleHex: userBubbleColorHex,
                     assistantBubbleHex: assistantBubbleColorHex,
                     toolBubbleHex: toolBubbleColorHex)
    }
    /// Long-term memory: Slate extracts durable facts about the user after
    /// local chat turns and injects them into chat/voice prompts.
    var memoryEnabled: Bool {
        didSet { UserDefaults.standard.set(memoryEnabled, forKey: "slate.memoryEnabled") }
    }
    /// Allow web search/fetch for search-capable cloud engines (Claude Code /
    /// OpenCode). Off by default (offline-first); always forced off in Silent Mode.
    var webSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(webSearchEnabled, forKey: "slate.webSearchEnabled") }
    }
    /// Cloud execution can send prompts, paths and selected project context to
    /// the configured Claude service. It is always an explicit opt-in.
    var cloudEnabled: Bool {
        didSet { UserDefaults.standard.set(cloudEnabled, forKey: "slate.cloudEnabled") }
    }
    /// Master gate for Slate's built-in network clients. Individual choices are
    /// retained so turning Silent Mode back off restores the user's setup.
    var silentModeEnabled: Bool {
        didSet { UserDefaults.standard.set(silentModeEnabled, forKey: "slate.silentModeEnabled") }
    }
    /// Network model browsing and binary downloads are an explicit, separate
    /// opt-in. Slate remains fully usable with local files while this is off.
    var remoteModelDownloadsEnabled: Bool {
        didSet { UserDefaults.standard.set(remoteModelDownloadsEnabled, forKey: "slate.remoteModelDownloadsEnabled") }
    }
    /// Global safety latch for true unattended execution. This is deliberately
    /// separate from the per-conversation Auto mode and defaults off.
    var skipPermissions: Bool {
        didSet { UserDefaults.standard.set(skipPermissions, forKey: "slate.skipPermissions") }
    }
    var onboardingCompleted: Bool {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: "slate.onboardingCompleted") }
    }
    /// The hardware questionnaire (shown once after onboarding) was answered.
    var hardwareProfileCompleted: Bool {
        didSet { UserDefaults.standard.set(hardwareProfileCompleted, forKey: "slate.hwCompleted") }
    }
    /// Customer Mac profile - guides which models Slate recommends.
    var hwChip: String? {
        didSet { UserDefaults.standard.set(hwChip, forKey: "slate.hwChip") }
    }
    var hwGPU: String? {
        didSet { UserDefaults.standard.set(hwGPU, forKey: "slate.hwGPU") }
    }
    /// Installed RAM in GB (0 = unset).
    var hwRAMGB: Int {
        didSet { UserDefaults.standard.set(hwRAMGB, forKey: "slate.hwRAMGB") }
    }
    /// UI language for the onboarding + hardware popups: "system" | "en" | "de".
    var interfaceLanguage: String {
        didSet { UserDefaults.standard.set(interfaceLanguage, forKey: "slate.interfaceLanguage") }
    }
    /// Check the update feed on launch (throttled) and show the update pill.
    var autoCheckUpdates: Bool {
        didSet { UserDefaults.standard.set(autoCheckUpdates, forKey: "slate.autoCheckUpdates") }
    }
    /// Load the last/default model automatically on launch. OFF by default so a cold
    /// start stays light on RAM - you pick a model when you actually want one.
    var autoLoadModelOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoLoadModelOnLaunch, forKey: "slate.autoLoadModelOnLaunch") }
    }
    /// Free the loaded model automatically when the system hits CRITICAL memory
    /// pressure, so a runaway load can't thrash/hang the whole Mac. ON by default.
    var autoUnloadUnderMemoryPressure: Bool {
        didSet { UserDefaults.standard.set(autoUnloadUnderMemoryPressure, forKey: "slate.autoUnloadUnderMemoryPressure") }
    }
    /// Voice Slate replies with. New installs use an installed macOS system voice;
    /// optional Supertonic voices can be provisioned explicitly.
    var assistantVoice: String {
        didSet { UserDefaults.standard.set(assistantVoice, forKey: "slate.assistantVoice") }
    }
    /// One-time voice choice: the first voice-mode launch shows a chooser so the
    /// user picks Slate's voice deliberately (changeable later in Settings).
    var voiceChoiceMade: Bool {
        didSet { UserDefaults.standard.set(voiceChoiceMade, forKey: "slate.voiceChoiceMade") }
    }
    /// The 10 Supertonic voices, male first (M1 is the default).
    static let assistantVoices: [(name: String, label: String)] = [
        ("M1", "Male 1"), ("M2", "Male 2"), ("M3", "Male 3"), ("M4", "Male 4"), ("M5", "Male 5"),
        ("F1", "Female 1"), ("F2", "Female 2"), ("F3", "Female 3"), ("F4", "Female 4"), ("F5", "Female 5"),
    ]
    /// Watch for crash logs on launch and offer to submit an anonymous report.
    var crashReportsEnabled: Bool {
        didSet { UserDefaults.standard.set(crashReportsEnabled, forKey: "slate.crashReportsEnabled") }
    }
    /// Show the Slate menu-bar item (quick actions + Flow). Default on.
    var menuBarEnabled: Bool {
        didSet { UserDefaults.standard.set(menuBarEnabled, forKey: "slate.menuBarEnabled") }
    }
    /// Global Slate Quick panel (Option-Space). It only talks to an in-process
    /// local model and never falls back to a configured cloud connector.
    var quickEnabled: Bool {
        didSet { UserDefaults.standard.set(quickEnabled, forKey: "slate.quickEnabled") }
    }
    var diarizationModelPath: String? {
        didSet { UserDefaults.standard.set(diarizationModelPath, forKey: "slate.diarizationModelPath") }
    }
    /// Optional update-feed override. nil uses the signed feed pinned into the
    /// release bundle; development builds without a configured feed stay inert.
    var updateFeedURL: String? {
        didSet { UserDefaults.standard.set(updateFeedURL, forKey: "slate.updateFeedURL") }
    }
    /// A version the user chose to skip in the launch update prompt. The prompt stays
    /// hidden for exactly this version; a newer one shows again.
    var skippedUpdateVersion: String? {
        didSet { UserDefaults.standard.set(skippedUpdateVersion, forKey: "slate.skippedUpdateVersion") }
    }
    var defaultTemperature: Double {
        didSet { UserDefaults.standard.set(defaultTemperature, forKey: "slate.defaultTemp") }
    }
    var maxTokens: Int {
        didSet { UserDefaults.standard.set(maxTokens, forKey: "slate.maxTokens") }
    }
    /// Hard cap on agentic tool-call steps per Code turn (a runaway backstop). One
    /// step = one tool call + its result. Higher lets big /goal builds finish.
    var agentMaxSteps: Int {
        didSet { UserDefaults.standard.set(agentMaxSteps, forKey: "slate.agentMaxSteps") }
    }
    /// Requested context window. Clamped to the model's trained max on load; larger
    /// values use much more RAM (KV cache), so this is user-tunable.
    var contextWindow: Int {
        didSet { UserDefaults.standard.set(contextWindow, forKey: "slate.contextWindow") }
    }
    static let contextWindowOptions = [4096, 8192, 16384, 32768, 65536, 131072]

    /// Preferred model loaded on launch (the default coding agent).
    var defaultModelPath: String? {
        didSet { UserDefaults.standard.set(defaultModelPath, forKey: "slate.defaultModelPath") }
    }
    /// Preferred model for Chat conversations (a German business/legal brain, say).
    /// When set, Slate switches to it on the first message of a chat and back to the
    /// coding default for code turns. nil → chat uses the coding default too.
    var chatModelPath: String? {
        didSet { UserDefaults.standard.set(chatModelPath, forKey: "slate.chatModelPath") }
    }
    /// Model to fall back to if the default fails to load (e.g. OOM), and the model
    /// subagents prefer when it can be the resident one.
    var fallbackModelPath: String? {
        didSet { UserDefaults.standard.set(fallbackModelPath, forKey: "slate.fallbackModelPath") }
    }
    /// Optional explicit path to the `claude` CLI (Cloud engine). nil → auto-locate.
    var claudeCliPath: String? {
        didSet { UserDefaults.standard.set(claudeCliPath, forKey: "slate.claudeCliPath") }
    }
    /// Cloud model alias for Claude Code (opus/sonnet/haiku). nil → CLI default.
    var claudeModel: String? {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "slate.claudeModel") }
    }
    /// Optional OpenCode binary override and the provider/model ids the user
    /// chose from OpenCode's catalog.
    var openCodeCliPath: String? {
        didSet { UserDefaults.standard.set(openCodeCliPath, forKey: "slate.openCodeCliPath") }
    }
    var openCodeModels: [String] {
        didSet { UserDefaults.standard.set(openCodeModels, forKey: "slate.openCodeModels") }
    }
    /// Saved OpenAI-compatible cloud models (API keys live in the Keychain, not here).
    var cloudProviders: [CloudProvider] {
        didSet {
            if let data = try? JSONEncoder().encode(cloudProviders) {
                UserDefaults.standard.set(data, forKey: "slate.cloudProviders")
            }
        }
    }
    static let claudeModelOptions = ["opus", "sonnet", "haiku"]

    /// How hard a Cloud (Claude Code) turn works - Claude's effort ladder.
    /// Low = CLI default; the rest raise the `MAX_THINKING_TOKENS` budget.
    /// Ultracode additionally instructs multi-agent orchestration via the
    /// system prompt (subagents, adversarial verification, exhaustiveness).
    enum ThinkingEffort: String, CaseIterable, Identifiable {
        case low, medium, high, xhigh, max, ultracode
        var id: String { rawValue }
        var label: String {
            switch self {
            case .low:       return "Low"
            case .medium:    return "Medium"
            case .high:      return "High"
            case .xhigh:     return "Extra high"
            case .max:       return "Max"
            case .ultracode: return "Ultracode"
            }
        }
        var short: String {
            switch self {
            case .low: return "Low";     case .medium: return "Med"
            case .high: return "High";   case .xhigh: return "XHigh"
            case .max: return "Max";     case .ultracode: return "Ultra"
            }
        }
        var icon: String {
            switch self {
            case .low:       return "gauge.with.dots.needle.0percent"
            case .medium:    return "gauge.with.dots.needle.33percent"
            case .high:      return "gauge.with.dots.needle.50percent"
            case .xhigh:     return "gauge.with.dots.needle.67percent"
            case .max:       return "gauge.with.dots.needle.100percent"
            case .ultracode: return "bolt.fill"
            }
        }
        /// Claude Code thinking-token budget. nil → don't set (CLI default).
        var maxThinkingTokens: Int? {
            switch self {
            case .low:       return nil
            case .medium:    return 8_000
            case .high:      return 16_000
            case .xhigh:     return 24_000
            case .max:       return 31_999
            case .ultracode: return 31_999
            }
        }
        /// Extra system-prompt block for Ultracode turns.
        var systemAddendum: String? {
            self == .ultracode
                ? "ULTRACODE MODE: maximum-effort. For every substantive task, orchestrate parallel subagents via your Task tool (fan out research, implementation checks, and reviews), verify claims adversarially before asserting them, and be exhaustive - token cost is not a constraint."
                : nil
        }
    }
    var thinkingEffort: ThinkingEffort {
        didSet { UserDefaults.standard.set(thinkingEffort.rawValue, forKey: "slate.thinkingEffort") }
    }

    init() {
        // Dark IS the identity - fresh installs (and anyone who never picked) start dark.
        theme = Theme(rawValue: UserDefaults.standard.string(forKey: "slate.theme") ?? "dark") ?? .dark
        customColorsEnabled = (UserDefaults.standard.object(forKey: "slate.customColorsEnabled") as? Bool) ?? true
        canvasColorHex = UserDefaults.standard.string(forKey: "slate.canvasColorHex") ?? Self.defaultCanvasHex
        surfaceColorHex = UserDefaults.standard.string(forKey: "slate.surfaceColorHex") ?? Self.defaultSurfaceHex
        accentColorHex = UserDefaults.standard.string(forKey: "slate.accentColorHex") ?? Self.defaultAccentHex
        userBubbleColorHex = UserDefaults.standard.string(forKey: "slate.userBubbleColorHex") ?? Self.defaultUserBubbleHex
        assistantBubbleColorHex = UserDefaults.standard.string(forKey: "slate.assistantBubbleColorHex") ?? Self.defaultAssistantBubbleHex
        toolBubbleColorHex = UserDefaults.standard.string(forKey: "slate.toolBubbleColorHex") ?? Self.defaultToolBubbleHex
        customPalettePresets = UserDefaults.standard.data(forKey: "slate.customPalettePresets")
            .flatMap { try? JSONDecoder().decode([PalettePreset].self, from: $0) } ?? []
        memoryEnabled = (UserDefaults.standard.object(forKey: "slate.memoryEnabled") as? Bool) ?? true
        webSearchEnabled = (UserDefaults.standard.object(forKey: "slate.webSearchEnabled") as? Bool) ?? false
        cloudEnabled = (UserDefaults.standard.object(forKey: "slate.cloudEnabled") as? Bool) ?? false
        silentModeEnabled = (UserDefaults.standard.object(forKey: "slate.silentModeEnabled") as? Bool) ?? false
        remoteModelDownloadsEnabled = (UserDefaults.standard.object(forKey: "slate.remoteModelDownloadsEnabled") as? Bool) ?? false
        skipPermissions = (UserDefaults.standard.object(forKey: "slate.skipPermissions") as? Bool) ?? false
        onboardingCompleted = (UserDefaults.standard.object(forKey: "slate.onboardingCompleted") as? Bool) ?? false
        hardwareProfileCompleted = (UserDefaults.standard.object(forKey: "slate.hwCompleted") as? Bool) ?? false
        hwChip = UserDefaults.standard.string(forKey: "slate.hwChip")
        hwGPU = UserDefaults.standard.string(forKey: "slate.hwGPU")
        hwRAMGB = (UserDefaults.standard.object(forKey: "slate.hwRAMGB") as? Int) ?? 0
        interfaceLanguage = UserDefaults.standard.string(forKey: "slate.interfaceLanguage") ?? "system"
        autoCheckUpdates = (UserDefaults.standard.object(forKey: "slate.autoCheckUpdates") as? Bool) ?? true
        autoLoadModelOnLaunch = (UserDefaults.standard.object(forKey: "slate.autoLoadModelOnLaunch") as? Bool) ?? false
        autoUnloadUnderMemoryPressure = (UserDefaults.standard.object(forKey: "slate.autoUnloadUnderMemoryPressure") as? Bool) ?? true
        // Supertonic (the neural default) speaks even before provisioning via the
        // runtime system-voice fallback. Stored "kokoro:" (removed engine) and
        // "qwen3:" (premium tier gated off - unreliable model) values heal to M1.
        let storedVoice = UserDefaults.standard.string(forKey: "slate.assistantVoice")
        let stale = (storedVoice?.hasPrefix("kokoro:") ?? false)
            || ((storedVoice?.hasPrefix(Qwen3VoiceBundle.voicePrefix) ?? false) && !Qwen3VoiceBundle.enabled)
        assistantVoice = stale ? "M1" : (storedVoice ?? SystemTTS.defaultVoiceID ?? "M1")
        voiceChoiceMade = (UserDefaults.standard.object(forKey: "slate.voiceChoiceMade") as? Bool) ?? false
        crashReportsEnabled = (UserDefaults.standard.object(forKey: "slate.crashReportsEnabled") as? Bool) ?? true
        menuBarEnabled = (UserDefaults.standard.object(forKey: "slate.menuBarEnabled") as? Bool) ?? true
        quickEnabled = (UserDefaults.standard.object(forKey: "slate.quickEnabled") as? Bool) ?? true
        diarizationModelPath = UserDefaults.standard.string(forKey: "slate.diarizationModelPath")
        updateFeedURL = UserDefaults.standard.string(forKey: "slate.updateFeedURL")
        skippedUpdateVersion = UserDefaults.standard.string(forKey: "slate.skippedUpdateVersion")
        defaultTemperature = (UserDefaults.standard.object(forKey: "slate.defaultTemp") as? Double) ?? 0.7
        maxTokens = (UserDefaults.standard.object(forKey: "slate.maxTokens") as? Int) ?? 2048
        agentMaxSteps = (UserDefaults.standard.object(forKey: "slate.agentMaxSteps") as? Int) ?? 40
        contextWindow = (UserDefaults.standard.object(forKey: "slate.contextWindow") as? Int) ?? 16384
        defaultModelPath = UserDefaults.standard.string(forKey: "slate.defaultModelPath")
        chatModelPath = UserDefaults.standard.string(forKey: "slate.chatModelPath")
        fallbackModelPath = UserDefaults.standard.string(forKey: "slate.fallbackModelPath")
        claudeCliPath = UserDefaults.standard.string(forKey: "slate.claudeCliPath")
        claudeModel = UserDefaults.standard.string(forKey: "slate.claudeModel")
        openCodeCliPath = UserDefaults.standard.string(forKey: "slate.openCodeCliPath")
        openCodeModels = UserDefaults.standard.stringArray(forKey: "slate.openCodeModels") ?? []
        cloudProviders = (UserDefaults.standard.data(forKey: "slate.cloudProviders"))
            .flatMap { try? JSONDecoder().decode([CloudProvider].self, from: $0) } ?? []
        thinkingEffort = ThinkingEffort(rawValue: UserDefaults.standard.string(forKey: "slate.thinkingEffort") ?? "low") ?? .low
    }

    func resetToDefaults() {
        theme = .dark
        customColorsEnabled = true
        resetPalette()
        memoryEnabled = true
        cloudEnabled = false
        silentModeEnabled = false
        remoteModelDownloadsEnabled = false
        skipPermissions = false
        defaultTemperature = 0.7
        maxTokens = 2048
        agentMaxSteps = 40
        contextWindow = 16384
        defaultModelPath = nil
        chatModelPath = nil
        fallbackModelPath = nil
        claudeCliPath = nil
        claudeModel = nil
        openCodeCliPath = nil
        openCodeModels = []
        thinkingEffort = .low
    }

    func resetPalette() {
        canvasColorHex = Self.defaultCanvasHex
        surfaceColorHex = Self.defaultSurfaceHex
        accentColorHex = Self.defaultAccentHex
        userBubbleColorHex = Self.defaultUserBubbleHex
        assistantBubbleColorHex = Self.defaultAssistantBubbleHex
        toolBubbleColorHex = Self.defaultToolBubbleHex
    }

    /// Apply a preset's six colors in one tap (and switch custom colors on).
    func applyPreset(_ preset: PalettePreset) {
        canvasColorHex = preset.canvasHex
        surfaceColorHex = preset.surfaceHex
        accentColorHex = preset.accentHex
        userBubbleColorHex = preset.userBubbleHex
        assistantBubbleColorHex = preset.assistantBubbleHex
        toolBubbleColorHex = preset.toolBubbleHex
        customColorsEnabled = true
    }

    /// Save the current colors as a named custom preset (dedup by name, capped).
    func saveCurrentAsPreset(named name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty else { return }
        var next = customPalettePresets.filter { $0.name.caseInsensitiveCompare(trimmed) != .orderedSame }
        next.append(PalettePreset(name: trimmed,
                                  canvasHex: canvasColorHex, surfaceHex: surfaceColorHex,
                                  accentHex: accentColorHex, userBubbleHex: userBubbleColorHex,
                                  assistantBubbleHex: assistantBubbleColorHex, toolBubbleHex: toolBubbleColorHex))
        if next.count > Self.maxCustomPresets { next.removeFirst(next.count - Self.maxCustomPresets) }
        customPalettePresets = next
    }

    func deleteCustomPreset(_ id: String) {
        customPalettePresets.removeAll { $0.id == id }
    }

    /// True when the current colors match this preset (drives the active ring).
    func matchesPreset(_ preset: PalettePreset) -> Bool {
        canvasColorHex.caseInsensitiveCompare(preset.canvasHex) == .orderedSame
            && accentColorHex.caseInsensitiveCompare(preset.accentHex) == .orderedSame
            && userBubbleColorHex.caseInsensitiveCompare(preset.userBubbleHex) == .orderedSame
    }

    func portableSnapshot() -> PortableSnapshot {
        PortableSnapshot(
            theme: theme.rawValue,
            customColorsEnabled: customColorsEnabled,
            canvasColorHex: canvasColorHex,
            surfaceColorHex: surfaceColorHex,
            accentColorHex: accentColorHex,
            userBubbleColorHex: userBubbleColorHex,
            assistantBubbleColorHex: assistantBubbleColorHex,
            toolBubbleColorHex: toolBubbleColorHex,
            memoryEnabled: memoryEnabled,
            cloudEnabled: cloudEnabled,
            silentModeEnabled: silentModeEnabled,
            defaultTemperature: defaultTemperature,
            maxTokens: maxTokens,
            contextWindow: contextWindow,
            defaultModelPath: defaultModelPath,
            chatModelPath: chatModelPath,
            fallbackModelPath: fallbackModelPath,
            claudeCliPath: claudeCliPath,
            claudeModel: claudeModel,
            openCodeCliPath: openCodeCliPath,
            openCodeModels: openCodeModels,
            cloudProviders: cloudProviders,
            thinkingEffort: thinkingEffort.rawValue)
    }

    func apply(_ snapshot: PortableSnapshot) throws {
        guard let importedTheme = Theme(rawValue: snapshot.theme),
              let importedEffort = ThinkingEffort(rawValue: snapshot.thinkingEffort),
              (0...1.5).contains(snapshot.defaultTemperature),
              (256...16_384).contains(snapshot.maxTokens),
              Self.contextWindowOptions.contains(snapshot.contextWindow) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        theme = importedTheme
        customColorsEnabled = snapshot.customColorsEnabled ?? true
        canvasColorHex = normalizedColor(snapshot.canvasColorHex, fallback: Self.defaultCanvasHex)
        surfaceColorHex = normalizedColor(snapshot.surfaceColorHex, fallback: Self.defaultSurfaceHex)
        accentColorHex = normalizedColor(snapshot.accentColorHex, fallback: Self.defaultAccentHex)
        userBubbleColorHex = normalizedColor(snapshot.userBubbleColorHex, fallback: Self.defaultUserBubbleHex)
        assistantBubbleColorHex = normalizedColor(snapshot.assistantBubbleColorHex,
                                                   fallback: Self.defaultAssistantBubbleHex)
        toolBubbleColorHex = normalizedColor(snapshot.toolBubbleColorHex, fallback: Self.defaultToolBubbleHex)
        memoryEnabled = snapshot.memoryEnabled
        // Importing a file must never silently opt the user into cloud transfer.
        cloudEnabled = false
        silentModeEnabled = snapshot.silentModeEnabled ?? false
        remoteModelDownloadsEnabled = false
        defaultTemperature = snapshot.defaultTemperature
        maxTokens = snapshot.maxTokens
        contextWindow = snapshot.contextWindow
        defaultModelPath = boundedPath(snapshot.defaultModelPath)
        chatModelPath = boundedPath(snapshot.chatModelPath)
        fallbackModelPath = boundedPath(snapshot.fallbackModelPath)
        // An imported settings file must not plant an executable path that runs
        // later when the user enables cloud mode. Re-enter it manually instead.
        claudeCliPath = nil
        claudeModel = snapshot.claudeModel.map { String($0.prefix(128)) }
        openCodeCliPath = nil
        openCodeModels = Array((snapshot.openCodeModels ?? []).prefix(64)).compactMap { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
        }
        // A settings backup may be old or shared. Re-key provider records so an
        // imported endpoint can never inherit a Keychain secret for a previous
        // provider ID; the user must explicitly enable cloud mode and enter a
        // key for the imported endpoint again.
        cloudProviders = importedCloudProviders(snapshot.cloudProviders)
        thinkingEffort = importedEffort
    }

    private func boundedPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096 else { return nil }
        return trimmed
    }

    private func normalizedColor(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return hex.range(of: #"^#?[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil ? hex : fallback
    }

    private func importedCloudProviders(_ providers: [CloudProvider]?) -> [CloudProvider] {
        Array((providers ?? []).prefix(32)).compactMap { provider in
            let name = String(provider.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = String(provider.model.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !name.isEmpty, !model.isEmpty,
                  let url = URL(string: base), url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil,
                  let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
                  scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
            else { return nil }
            return CloudProvider(id: UUID().uuidString, name: name, baseURL: base, model: model)
        }
    }
}
