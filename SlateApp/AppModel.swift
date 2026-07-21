import AppKit
import Foundation
import ImageIO
import Observation
import SlateCore
import SlateUI
import SlateLlama
import SlateFlowCore
#if SLATE_PRO
import SlatePro
#endif

/// Thread-safe holder so the agent's @Sendable mode closure can read the live
/// permission mode without a data race on @MainActor state.
final class ModeHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _mode: PermissionMode = .recommendedDefault
    private var _skipPermissions = false
    var mode: PermissionMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    var skipPermissions: Bool {
        get { lock.withLock { _skipPermissions } }
        set { lock.withLock { _skipPermissions = newValue } }
    }
}

/// Bridges the agent's `await gate.confirm(...)` to a SwiftUI sheet.
@MainActor @Observable
final class ApprovalCoordinator: ApprovalGate {
    private struct SessionApproval: Hashable {
        let kind: ActionKind
        let risk: ActionRisk
        let scope: String
    }
    var pending: ApprovalRequest?
    private var continuation: CheckedContinuation<Bool, Never>?
    /// Exact paths/commands approved for this session. Risk is part of the key,
    /// so approving a normal edit never also approves emptying the same file.
    private var sessionAllowed: Set<SessionApproval> = []

    func confirm(_ request: ApprovalRequest) async -> Bool {
        let key = SessionApproval(kind: request.kind, risk: request.risk, scope: request.scope)
        if request.risk != .destructive, sessionAllowed.contains(key) { return true }
        return await withCheckedContinuation { cont in
            self.continuation = cont
            self.pending = request
        }
    }

    func resolve(_ approved: Bool, rememberForSession: Bool = false) {
        if approved, rememberForSession, let request = pending,
           request.risk != .destructive {
            sessionAllowed.insert(SessionApproval(kind: request.kind, risk: request.risk,
                                                   scope: request.scope))
        }
        pending = nil
        continuation?.resume(returning: approved)
        continuation = nil
    }

    /// Forget session approvals (Kill all / safety reset).
    func resetSessionApprovals() { sessionAllowed = [] }
}

@MainActor @Observable
final class AppModel {
    var conversations: [Conversation] = []
    var selectedID: Conversation.ID?
    var models: [ModelEntry] = []
    var activeModelURL: URL?
    var loadingModel = false
    /// Legacy single-error channel - now FORWARDS into the toast queue so every
    /// existing call site keeps working while notifications go through ONE system.
    var modelError: String? {
        didSet {
            guard let m = modelError else { return }
            SlateDiagnostics.model.error("Model error: \(m, privacy: .private)")
            notify(.warning, m)
            modelError = nil
        }
    }

    /// In-app notification queue (stackable toasts, newest at the bottom).
    var toasts: [ToastItem] = []
    /// Oldest messages dropped from the LAST local prompt to fit the model's
    /// context window (0 = nothing trimmed). Shown as a subtle transcript note.
    var lastPromptTrimmedCount = 0
    /// True when the active engine can run web search (the cloud passthrough
    /// agents), so the header can show the web-search toggle.
    var activeEngineSupportsWebSearch: Bool { engine?.supportsWebSearch ?? false }
    /// Enqueue a toast. `action` adds an inline button (e.g. "Load model").
    func notify(_ kind: ToastKind, _ text: String, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        toasts.append(ToastItem(kind: kind, text: text, actionLabel: actionLabel, action: action))
        if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }   // cap the stack
    }
    func dismissToast(_ id: ToastItem.ID) { toasts.removeAll { $0.id == id } }
    /// Draft delivered by the macOS Services menu. ConversationView consumes it.
    var serviceDraft: String?
    /// True when the resident engine is Cloud (Claude Code), not a local GGUF.
    var usingCloud = false

    var streamingText = ""
    var isGenerating = false
    /// Agent Chat: while a roundtable turn streams, whose turn it is - drives the
    /// live bubble's name label and per-speaker color. nil outside a roundtable.
    var streamingSpeaker: String?
    var streamingSpeakerIndex: Int?
    /// Live round number (1-based) while a roundtable runs - drives the header's
    /// "Round k/N" progress chip. nil when idle or during the synthesis turn.
    var streamingRound: Int?
    /// The conversation the running turn belongs to. The streaming bubble and
    /// the stop button live ONLY there - other conversations stay clean and
    /// warn instead of sending while the engine is busy.
    var generatingConvoID: Conversation.ID?
    var tokensPerSec: Double = 0          // live generation speed (context dashboard)
    /// The context window actually in use (from the loaded engine), else the requested setting.
    var contextLimit: Int { (engine?.contextWindow ?? 0) > 0 ? engine!.contextWindow : settings.contextWindow }
    /// The loaded model's trained maximum context (0 if unknown / no model).
    var activeTrainedContext: Int { engine?.trainedContext ?? 0 }

    /// Approx tokens of the selected conversation, for the context gauge.
    var contextTokens: Int { TokenEstimate.tokens(selected?.messages ?? []) }
    /// Name of the active per-project rules file (SLATE.md/…), if any.
    var activeProjectRules: String? { selected?.folderURL.flatMap { ProjectRules.find(in: $0)?.name } }
    var activeProjectRulesTrusted: Bool {
        guard let conversation = selected, let folder = conversation.folderURL,
              let rules = ProjectRules.find(in: folder) else { return false }
        return conversation.trustedProjectRulesDigest == rules.digest
    }

    let coordinator = ApprovalCoordinator()
    let settings = AppSettings()
    let modelStore = ModelStore()
    let ram = RAMMonitor()
    /// Installed offline skills (local instruction packs) + which are enabled.
    /// Enabled skills' instructions are injected into the chat/code system prompt.
    var installedSkills: [Skill] = []
    var trustedSkillDigests: [String: String] = UserDefaults.standard.dictionary(forKey: "slate.trustedSkillDigests") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(trustedSkillDigests, forKey: "slate.trustedSkillDigests") }
    }
    var enabledSkills: [Skill] { installedSkills.filter { trustedSkillDigests[$0.id] == $0.digest } }
    func isSkillEnabled(_ skill: Skill) -> Bool { trustedSkillDigests[skill.id] == skill.digest }
    func setSkillEnabled(_ skill: Skill, enabled: Bool) {
        if enabled { trustedSkillDigests[skill.id] = skill.digest }
        else { trustedSkillDigests.removeValue(forKey: skill.id) }
    }
    func rescanSkills() { installedSkills = Skills.scan() }
    /// Native in-app updater (the sidebar update pill + Settings controls).
    @ObservationIgnored private(set) lazy var updater = UpdateService(settings: settings)
    /// "Read aloud" for assistant messages (bundled Supertonic-3 TTS).
    let speech = SpeechService()
    /// Offline "chat with your files" (per-conversation RAG via NLEmbedding).
    let knowledge = KnowledgeService()
    // Pro local stdio tools (MCP) moved into slate-pro (Phase 3): the free build ships
    // no MCP orchestration. Reached only through `pro.localToolRegistrations` /
    // `pro.rescanLocalTools(gate:)` / `pro.localToolsSettings(...)`.

    /// Crash logs macOS recorded for Slate, reduced to anonymous reports.
    var crashReports: [CrashReport] = []
    /// A new crash was detected this launch → prompt the user to submit it.
    var showCrashPrompt = false
    /// Where anonymous crash reports are addressed. Configurable in code.
    static let supportEmail = "info@lange-co-consulting.de"
    private static let lastCrashKey = "slate.lastCrashSeen"

    /// Scan for NEW Slate crash logs off the main thread; prompt once. Old files
    /// are skipped by mtime (since = last seen) so launch never re-reads them all.
    func scanForCrashes() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        let lastSeen = UserDefaults.standard.object(forKey: Self.lastCrashKey) as? Date
        let user = NSUserName(), home = NSHomeDirectory()
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                CrashReporter.scan(directory: dir, since: lastSeen, username: user, homeDir: home)
            }.value
            guard let self else { return }
            crashReports = found
            if settings.crashReportsEnabled, let newest = found.first?.date {
                showCrashPrompt = true
                // Advance the marker NOW so the same crash never re-prompts,
                // regardless of whether the user acts on the alert.
                UserDefaults.standard.set(newest, forKey: Self.lastCrashKey)
            }
        }
    }

    func markCrashesSeen() { showCrashPrompt = false }

    /// Open the user's mail client with a pre-filled anonymous report. Consent is
    /// the click itself; Slate transmits nothing. Falls back to the clipboard.
    func sendCrashReport(_ report: CrashReport) {
        defer { showCrashPrompt = false }
        if let url = CrashMailComposer.mailtoURL(report, to: Self.supportEmail),
           NSWorkspace.shared.open(url) { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.body, forType: .string)
        notify(.notice, "No mail client found - the report was copied to your clipboard.")
    }

    /// Long-term memory about the user (offline, editable in Settings).
    var memory = MemoryStore.load(from: AppModel.memoryURL)
    /// Fact just saved - the header shows a quiet "Learned" toast.
    var memoryToast: String?
    static let memoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Slate/memory.json")
    /// Shows the in-app model manager sheet (sidebar menu / settings entry).
    var showModelManager = false
    /// Shows the downloads page sheet (active downloads, loaded model, installed).
    var showDownloads = false
    /// Free single-file local audio/video transcription sheet.
    var showTranscription = false
    /// Shows the ⌘K command palette.
    var showPalette = false
    /// Shows the ⌘P session switcher (conversations only, fuzzy).
    var showSwitcher = false
    /// Unified offline search across chats, Knowledge, transcripts and models.
    var showGlobalSearch = false
    var transcriptionHighlightID: UUID?
    /// Shows Settings as an IN-APP sheet (a separate window would yank the user
    /// out of fullscreen).
    var showSettings = false
    /// When set, Settings opens on this tab once (SettingsTab.rawValue), then clears.
    var pendingSettingsTab: String?

    #if SLATE_PRO
    /// The private licensing service — official/owner builds only. The free public
    /// build has no licensing; gates and lifecycle route through `pro` instead, and
    /// the licence UI shows an upsell placeholder.
    let license = LicenseService()
    #endif
    /// The Pro-feature seam. Every gate asks `pro.allows(_:)` and every licensing
    /// lifecycle call goes through `pro`, so the free build (DefaultFreeProFeatures
    /// → upsell) and the official build (SlatePro-backed) diverge here and nowhere
    /// else. Set at launch.
    let pro: any ProFeatures
    /// When non-nil, the Pro upsell sheet is shown for this feature.
    var proUpsell: ProFeature?

    init() {
        #if SLATE_PRO
        self.pro = SlateProFeatures(license: license, imageEngine: ProImageEngine(),
                                    localTools: LocalMCPService())
        #else
        self.pro = DefaultFreeProFeatures()
        #endif
    }

    /// Gate a Pro feature. Returns true if allowed; otherwise shows the upsell and
    /// returns false so the caller can bail out of the action.
    @discardableResult
    func requirePro(_ feature: ProFeature) -> Bool {
        if pro.allows(feature.capability) { return true }
        proUpsell = feature
        return false
    }

    /// Jump straight to Settings › Licence (from the upsell "Enter licence key").
    func openLicenseSettings() {
        proUpsell = nil
        pendingSettingsTab = "license"
        showSettings = true
    }
    /// Sidebar visibility - bound to the split view; toggled from the glass
    /// header (there is NO system toolbar anymore, so no native toggle).
    var sidebarVisible = true
    /// True while the window is in native fullscreen (kept in sync by
    /// WindowConfigurator). The traffic lights auto-hide there, so all the
    /// clearance paddings collapse to normal insets.
    var isFullscreen = false

    // MARK: Image generation (diffusion)
    // The diffusion engine itself lives in slate-pro's `ProImageEngine` (Phase 3):
    // generation runs through `pro.generateImage(_:onStep:)` and RAM is freed via
    // `pro.unloadImageEngine()`. The free build links no SlateDiffusion at all.
    var installedImageBundles: [ImageBundle] = []
    var selectedImageModelID: String?
    var imageGenerating = false
    var imageGeneratingConvoID: UUID?
    var imageStep = 0
    var imageTotalSteps = 0
    var imageDownloadID: String?
    var imageDownloadProgress: Double = 0
    /// The bundle whose download last failed, so the Downloads panel can offer a
    /// one-tap Repair (re-download resumes: already-verified files are skipped).
    var imageRepairBundleID: String?
    // Qwen3-TTS premium voice (~1.7 GB, optional) download state.
    var qwen3Downloading = false
    var qwen3DownloadProgress: Double = 0
    var qwen3Error: String?
    var qwen3Installed = Qwen3VoiceBundle.isInstalled
    @ObservationIgnored private lazy var qwen3Downloader = Qwen3VoiceDownloader()
    var imageError: String? {
        didSet {
            if let imageError {
                SlateDiagnostics.model.error("Image error: \(imageError, privacy: .private)")
            }
        }
    }
    @ObservationIgnored private lazy var imageDownloader = ImageDownloader()
    /// A generation waiting on the stop-gate confirmation (LLM must unload first).
    var pendingImage: PendingImage?
    struct PendingImage: Equatable {
        let convoID: UUID; let prompt: String; let width: Int; let height: Int; let seed: Int64
        var initImagePath: String? = nil     // img2img source
        var strength: Float = 0.6
    }

    /// Cycle appearance: System → Light → Dark → System.
    func cycleTheme() {
        settings.theme = switch settings.theme {
        case .system: .light
        case .light: .dark
        case .dark: .system
        }
    }
    private let modeHolder = ModeHolder()
    private var engine: (any LLMEngine)?
    private var genTask: Task<Void, Never>?
    /// Agent Chat: the roundtable's own engine pool, keyed by model ref. Held for
    /// the duration of one roundtable and torn down on completion, Stop, or panic.
    private var roundtableEngines: [String: any LLMEngine] = [:]
    /// True from the moment a roundtable genTask is created until it truly exits
    /// (its defer). Unlike `isGenerating` (which Stop clears immediately, while the
    /// task may still be winding an uninterruptible seat load down) this stays set,
    /// so a second roundtable can't start concurrently and double the RAM load.
    private(set) var roundtableActive = false

    /// One-shot, non-streaming generation for Slate Flow's transcript cleanup.
    /// Local engine only (cloud/passthrough engines behave like agents, not a
    /// text function), and refuses while a chat generation runs - dictation
    /// must never stall the user's conversation. The caller (CleanupService)
    /// treats any throw as "paste the rules-only transcript instead".
    enum FlowLLMError: Error { case busy }

    /// Why Flow's LLM cleanup would be skipped right now; nil = ready. Shown in
    /// the Dictation settings so a silent rules-only fallback is never a mystery.
    var flowCleanupBlocker: String? {
        guard let engine else { return "No model loaded - pick one in the sidebar for smart formatting." }
        if engine.isPassthroughAgent { return "Cloud engine active - smart formatting needs a local model." }
        if loadingModel { return "Model is still loading…" }
        if isGenerating { return "Model is busy with a chat - this dictation pastes rules-only." }
        return nil
    }

    func flowGenerate(system: String, user: String) async throws -> String {
        guard let engine, !engine.isPassthroughAgent, !isGenerating, !loadingModel,
              !voiceGenerating else {
            throw FlowLLMError.busy
        }
        // The stop flag is STICKY (a voice session's end() or a chat Stop leaves
        // it set) - re-arm, or this one-shot aborts instantly forever after.
        engine.clearStop()
        let messages = [ChatMessage(role: .system, content: system),
                        ChatMessage(role: .user, content: user)]
        var out = ""
        let stream = await engine.generate(messages: messages, grammar: nil,
                                           options: GenOptions(temperature: 0.2, maxTokens: 512))
        for try await piece in stream { out += piece }
        return Reasoning.strip(out)   // thinking models wrap output in <think>…</think>
    }

    /// One-shot generation for Slate Quick. This deliberately rejects every cloud
    /// connector even when the user opted into cloud elsewhere in the app.
    func quickGenerate(system: String, user: String, imagePath: String?) async throws -> String {
        guard let engine, !engine.isPassthroughAgent, !usingCloud,
              !isGenerating, !loadingModel, !voiceGenerating else {
            throw FlowLLMError.busy
        }
        engine.clearStop()
        let messages = [
            ChatMessage(role: .system, content: system),
            ChatMessage(role: .user, content: user, imagePath: imagePath)
        ]
        var output = ""
        let stream = await engine.generate(
            messages: messages,
            grammar: nil,
            options: GenOptions(temperature: 0.2, maxTokens: min(settings.maxTokens, 1_024))
        )
        for try await piece in stream { output += piece }
        return Reasoning.strip(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Handles the fixed-size, file-backed request created by `slatectl ask`.
    /// The URL carries only a UUID; prompt and result never leave this Mac.
    func handleAutomationURL(_ url: URL) {
        guard pro.allows(.shortcuts),
              let id = SlateAutomation.id(from: url) else { return }
        Task {
            let response: SlateAutomationResponse
            do {
                try SlateAutomation.prepareDirectories()
                let requestURL = SlateAutomation.requestURL(for: id)
                let data = try PrivateStorage.read(from: requestURL, maxBytes: 256_000)
                try? FileManager.default.removeItem(at: requestURL)
                guard data.count <= 256_000 else {
                    throw AutomationError.invalidRequest("Request is larger than 256 KB.")
                }
                let request = try JSONDecoder().decode(SlateAutomationRequest.self, from: data)
                guard request.id == id, request.action == .ask,
                      !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      request.text.utf8.count <= 64_000 else {
                    throw AutomationError.invalidRequest("Invalid automation request.")
                }
                let result = try await quickGenerate(
                    system: "Answer the request helpfully and concisely. You are running in Slate's offline Shortcuts interface. Never claim to have internet access.",
                    user: request.text, imagePath: nil)
                response = SlateAutomationResponse(id: id, result: result)
            } catch {
                response = SlateAutomationResponse(
                    id: id,
                    error: engine == nil || usingCloud
                        ? "Load a local chat model in Slate, then run the Shortcut again."
                        : error.localizedDescription)
            }
            do {
                let responseURL = SlateAutomation.responseURL(for: id)
                try PrivateStorage.write(JSONEncoder().encode(response), to: responseURL)
            } catch { }
        }
    }

    private enum AutomationError: LocalizedError {
        case invalidRequest(String)
        var errorDescription: String? {
            switch self { case .invalidRequest(let message): return message }
        }
    }

    /// Streaming one-shot turn for a VOICE session: caller-supplied history +
    /// the voice system prompt, short-answer options, NO conversation-state
    /// mutation. Local engine only (voice v1) - same guard as flowGenerate,
    /// plus clearStop(): the engine's stop flag is sticky, and without this a
    /// voice turn right after the user hit Stop would abort instantly.
    /// True while a voice turn streams on the shared engine - chat sends and
    /// Flow cleanup yield to it (symmetric to voiceGenerate's own guards).
    private(set) var voiceGenerating = false

    func voiceGenerate(history: [ChatMessage], user: String, language: String? = nil,
                       onToken: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let engine, !engine.isPassthroughAgent, !isGenerating, !loadingModel else {
            throw FlowLLMError.busy
        }
        voiceGenerating = true
        defer { voiceGenerating = false }
        engine.clearStop()
        var voiceSystem = VoicePrompt.system(language: language)
        if pro.allows(.memory), settings.memoryEnabled,
           let mem = memory.promptBlock() {
            voiceSystem += "\n\n" + mem
        }
        var msgs = [ChatMessage(role: .system, content: voiceSystem)]
        msgs += history.suffix(12).map {
            $0.role == .assistant
                ? ChatMessage(role: .assistant, content: ChatSession.stripThink($0.content))
                : $0
        }
        msgs.append(ChatMessage(role: .user, content: user))
        var out = ""
        let stream = await engine.generate(
            messages: msgs, grammar: nil,
            options: GenOptions(temperature: VoicePrompt.temperature,
                                maxTokens: VoicePrompt.maxTokens))
        for try await piece in stream {
            out += piece
            onToken(piece)
        }
        return Reasoning.strip(out)
    }

    /// Voice sessions log their exchange as ordinary chat messages.
    func appendVoiceMessage(role: ChatMessage.Role, text: String, to id: Conversation.ID) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        update(id) { $0.messages.append(ChatMessage(role: role, content: t)) }
    }

    /// Interrupt a running voice generation (barge-in / session end). Safe:
    /// voiceGenerate's guard proves no chat turn shares the engine.
    func voiceStop() {
        engine?.requestStop()
    }

    /// Models available to compare: the resident local model + every configured
    /// cloud model with a key (when cloud is enabled). Empty if fewer than 2.
    var compareCandidates: [String] {
        var names: [String] = []
        if let engine, !engine.isPassthroughAgent, !usingCloud { names.append(activeModelName ?? "Local") }
        if settings.cloudEnabled && !settings.silentModeEnabled {
            names += settings.cloudProviders.filter { hasCloudKey($0) }.map { $0.name }
            names += settings.openCodeModels.map { "OpenCode · \($0)" }
        }
        return names
    }

    /// Ask the same prompt across up to 3 models at once (cloud runs concurrently,
    /// the single resident local runs too) and post one assistant message with
    /// each answer under a heading. Ephemeral wow - shows off the platform.
    func compareAcrossModels(_ text: String, in id: Conversation.ID) {
        guard requirePro(.compare) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isGenerating, !roundtableActive else { return }
        var panel: [(name: String, engine: any LLMEngine)] = []
        if let engine, !engine.isPassthroughAgent, !usingCloud {
            engine.clearStop()
            panel.append((activeModelName ?? "Local", engine))
        }
        if settings.cloudEnabled && !settings.silentModeEnabled {
            for p in settings.cloudProviders {
                guard panel.count < 3, hasCloudKey(p) else { continue }
                let key = KeychainStore.get(account: p.id)
                panel.append((p.name, OpenAICompatibleEngine(provider: p, apiKey: key)))
            }
            for modelID in settings.openCodeModels where panel.count < 3 {
                if let connector = OpenCodeEngine(modelID: modelID, cliPath: settings.openCodeCliPath) {
                    panel.append(("OpenCode · \(modelID)", connector))
                }
            }
        }
        panel = Array(panel.prefix(3))
        guard panel.count >= 2 else {
            modelError = "Compare needs at least two models - add a cloud model in Settings → Cloud."
            return
        }
        update(id) { $0.messages.append(ChatMessage(role: .user, content: t)) }
        if selected?.id == id, selected?.isUntitled == true { update(id) { $0.title = String(t.prefix(48)) } }
        persist()
        isGenerating = true; generatingConvoID = id; streamingText = "Comparing \(panel.count) models…"
        genTask = Task { @MainActor in
            let results = await withTaskGroup(of: (Int, String, String).self) { group in
                for (i, m) in panel.enumerated() {
                    group.addTask {
                        let msgs = [ChatMessage(role: .system, content: "You are Slate, a concise assistant."),
                                    ChatMessage(role: .user, content: t)]
                        var out = ""
                        let stream = await m.engine.generate(messages: msgs, grammar: nil,
                                                             options: GenOptions(temperature: 0.4, maxTokens: 600))
                        do { for try await piece in stream { out += piece } }
                        catch { out = "⚠️ \(error.localizedDescription)" }
                        return (i, m.name, Reasoning.strip(out).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                var acc: [(Int, String, String)] = []
                for await r in group { acc.append(r) }
                return acc.sorted { $0.0 < $1.0 }
            }
            let combined = results
                .map { "### \($0.1)\n\n\($0.2.isEmpty ? "_(no answer)_" : $0.2)" }
                .joined(separator: "\n\n---\n\n")
            appendAssistant(combined, to: id, stats: "compared \(results.count) models")
            isGenerating = false; generatingConvoID = nil; streamingText = ""
        }
    }

    // MARK: Agent Chat (roundtable)

    private func isLocalRef(_ ref: String) -> Bool {
        !ref.hasPrefix("cloud:") && !ref.hasPrefix("opencode:") && ref != "claude-code"
    }

    /// Run a multi-model roundtable: 2-3 models take turns discussing `topic`,
    /// each seeing the others' contributions, streamed sequentially into one
    /// conversation. Unlike `compareAcrossModels` (concurrent, one-shot), this is
    /// a round-robin loop that holds its OWN engine pool - the resident chat model
    /// is unloaded first to free RAM. Gated behind Pro (reuses the compare gate).
    func runRoundtable(topic rawTopic: String, in id: Conversation.ID, force: Bool = false) {
        // Roundtable is freemium: Free runs a 2-model table; Pro unlocks the 3rd
        // seat and the closing synthesis. The seat cap + synthesis gate below hold
        // even if the setup UI is bypassed (e.g. a config saved while Pro).
        let topic = rawTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        // Also refuse while a chat model is still loading: buildRoundtable will free
        // the resident engine, and a mid-flight load must not race that teardown.
        // `roundtableActive` blocks a second roundtable while a prior one is still
        // winding down an uninterruptible seat load after Stop (isGenerating is
        // already false there, so it alone would let a concurrent run slip through).
        guard !topic.isEmpty, !isGenerating, !voiceGenerating, !loadingModel, !roundtableActive,
              let convo = conversations.first(where: { $0.id == id }) else { return }
        let refs = Array(convo.agentModels.prefix(pro.roundtableModelCap))
        guard refs.count >= 2 else {
            modelError = "Pick at least two models for the roundtable."
            return
        }
        let rounds = max(1, convo.agentRounds)
        let synthesis = convo.agentSynthesis && pro.roundtableSynthesisAllowed
        let personas = convo.agentPersonas
        let temperature = convo.temperature ?? settings.defaultTemperature

        // Seed the transcript with the topic as the opening user message. On a
        // "Try anyway" force-retry the topic is already there - don't duplicate it.
        if !force {
            update(id) { $0.messages.append(ChatMessage(role: .user, content: topic)) }
            if convo.isUntitled { update(id) { $0.title = String(topic.prefix(48)) } }
            persist()
        }

        roundtableActive = true
        isGenerating = true; generatingConvoID = id; streamingText = "Assembling the roundtable…"
        genTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                for e in self.roundtableEngines.values { e.requestStop() }
                self.roundtableEngines = [:]
                self.isGenerating = false; self.generatingConvoID = nil
                self.streamingText = ""; self.streamingSpeaker = nil; self.streamingSpeakerIndex = nil
                self.streamingRound = nil
                self.roundtableActive = false
            }
            let build = await self.buildRoundtable(refs: refs, personas: personas, force: force)
            self.roundtableEngines = build.engines
            // Stopped during the (uninterruptible-per-seat) assembly phase: drop the
            // partially built pool via the defer and exit quietly - no error, no reload.
            if Task.isCancelled { return }
            if let err = build.error {
                self.appendAssistant("⚠️ \(err)", to: id)
                // RAM shortfall: let the user override the guard and try anyway.
                if build.ramRefusal {
                    self.notify(.warning, err, actionLabel: "Try anyway") { [weak self] in
                        self?.runRoundtable(topic: topic, in: id, force: true)
                    }
                }
                return
            }
            let roster = build.roster
            guard roster.count >= 2 else {
                // Models cleared the RAM preflight but still failed to load - almost
                // always genuinely out of memory at load time. Give a clear reason
                // AND a Retry, so it is never a dead end (the earlier build had no
                // recourse here).
                let msg = "Couldn't load the chosen models - most likely not enough free memory. Close other apps, or pick smaller or fewer models, then Retry."
                self.appendAssistant("⚠️ \(msg)", to: id)
                // Nothing ran, but we already freed the resident chat model to make
                // room - restore it so the user isn't stranded with no model loaded.
                if let restore = build.unloaded { self.loadModel(restore) }
                self.notify(.warning, msg, actionLabel: "Retry") { [weak self] in
                    self?.runRoundtable(topic: topic, in: id, force: true)
                }
                return
            }
            do {
                for round in 0..<rounds {
                    self.streamingRound = round + 1
                    for speaker in Roundtable.speakerOrder(roster: roster, synthesis: false) {
                        try Task.checkCancellation()
                        await self.roundtableTurn(speaker: speaker, roster: roster, topic: topic,
                                                  round: round, totalRounds: rounds,
                                                  isSynthesis: false, temperature: temperature, in: id)
                    }
                }
                self.streamingRound = nil
                if synthesis, let host = Roundtable.speakerOrder(roster: roster, synthesis: true).first {
                    try Task.checkCancellation()
                    await self.roundtableTurn(speaker: host, roster: roster, topic: topic,
                                              round: rounds, totalRounds: rounds,
                                              isSynthesis: true, temperature: temperature, in: id)
                }
            } catch {
                // Cancelled by Stop / Kill all - the defer tears the pool down.
            }
        }
    }

    /// Stream one speaker's turn, relabeling the shared transcript from their point
    /// of view, then commit it with speaker attribution. A turn is NEVER silently
    /// dropped: a reasoning seat that spends its whole budget "thinking" is retried
    /// once with a hard no-thinking nudge, and if it still returns nothing a visible
    /// attributed placeholder is committed - so strict alternation always holds and
    /// the other model can never appear to answer twice in a row.
    private func roundtableTurn(speaker: RoundtableParticipant, roster: [RoundtableParticipant],
                                topic: String, round: Int, totalRounds: Int, isSynthesis: Bool,
                                temperature: Double, in id: Conversation.ID) async {
        guard let engine = roundtableEngines[speaker.id],
              let convo = conversations.first(where: { $0.id == id }) else { return }
        // The synthesis turn is labeled distinctly ("Synthesis", its own colour) so
        // it reads as a summary of the discussion, not just another model's turn.
        let label = isSynthesis ? "Synthesis" : speaker.name
        let labelIndex = isSynthesis ? roster.count : speaker.index
        // Only the CURRENT topic's speaker turns (see Roundtable.currentDiscussion):
        // otherwise a second topic in the same conversation would replay the
        // previous discussion, and un-attributed error notices would leak in.
        let discussion = Roundtable.currentDiscussion(in: convo.messages)
        let baseMsgs = Roundtable.prompt(for: speaker, roster: roster, topic: topic, discussion: discussion,
                                         round: round, totalRounds: totalRounds, isSynthesis: isSynthesis)
        let window = engine.contextWindow
        // The roundtable uses its OWN generation ceiling (not the user's global chat
        // maxTokens, which may be lower): a reasoning seat needs the headroom to
        // finish thinking AND answer. clampAnswer trims the VISIBLE reply afterwards,
        // so the user's preference for short replies is still honoured on screen.
        let responseTokens = Roundtable.maxTurnTokens

        streamingSpeaker = label
        streamingSpeakerIndex = labelIndex
        streamingText = ""
        let started = Date()

        // One streamed attempt → (visible answer after stripping <think>, error note).
        func runAttempt(_ msgs: [ChatMessage]) async -> (clean: String, errorNote: String?) {
            var trimmed = msgs
            if window > 0 {
                let budget = max(window - (responseTokens + 512), window / 2)
                trimmed = ContextBudget.trim(msgs, approxTokenBudget: budget).kept
            }
            engine.clearStop()
            var out = ""
            var note: String?
            let stream = await engine.generate(
                messages: trimmed, grammar: nil,
                options: GenOptions(temperature: temperature, maxTokens: max(256, responseTokens)))
            do {
                for try await piece in stream {
                    try Task.checkCancellation()
                    out += piece
                    streamingText = Reasoning.strip(out)
                }
            } catch is CancellationError {
                // Stopped mid-turn: commit whatever text arrived, then unwind.
            } catch {
                if out.isEmpty { note = "⚠️ \(error.localizedDescription)" }
            }
            return (Reasoning.strip(out).trimmingCharacters(in: .whitespacesAndNewlines), note)
        }

        var (clean, errorNote) = await runAttempt(baseMsgs)

        // Empty (reasoning-only) turn → one hard retry so the seat fills its slot.
        if clean.isEmpty, errorNote == nil, !Task.isCancelled {
            var nudged = baseMsgs
            nudged.append(ChatMessage(role: .user,
                content: "You have not answered yet. Reply now with ONLY your final answer in 2-3 sentences. Do not think out loud or use <think> tags."))
            (clean, errorNote) = await runAttempt(nudged)
        }

        streamingText = ""; streamingSpeaker = nil; streamingSpeakerIndex = nil

        if let note = errorNote, clean.isEmpty {
            // A failed seat's error notice is shown WITHOUT speaker attribution so it
            // is not replayed to the others as that seat's "turn".
            appendAssistant(note, to: id)
            return
        }
        if clean.isEmpty {
            // Produced nothing even after the nudge (or Stop during assembly). Keep
            // the slot VISIBLE and attributed so alternation is never broken.
            appendAssistant("_(no answer)_", to: id, speaker: label, speakerIndex: labelIndex)
            return
        }
        // Guarantee brevity even when a (reasoning) model ignores the 2-3 sentence
        // instruction, so a live roundtable stays readable - and strip the
        // "[Name]:" echo some models prefix despite the prompt.
        let committed = Roundtable.clampAnswer(Roundtable.stripNameEcho(clean, speaker: speaker.name))
        appendAssistant(committed, to: id, stats: Self.statsLine(tokens: committed.count / 4, since: started),
                        speaker: label, speakerIndex: labelIndex)
    }

    /// Resolve model refs into a live engine pool. Unloads the resident chat engine
    /// first (roundtable is a focused mode) and refuses, with guidance, when the
    /// local models would not fit in free RAM - a hang is worse than a decline.
    private func buildRoundtable(refs: [String], personas: [String], force: Bool) async
        -> (roster: [RoundtableParticipant], engines: [String: any LLMEngine], error: String?, unloaded: URL?, ramRefusal: Bool) {
        var unloaded: URL?
        let localRefs = refs.filter { isLocalRef($0) }
        if !localRefs.isEmpty {
            var fileSizesGB: [Double] = []
            for ref in localRefs {
                let url = URL(fileURLWithPath: ref)
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    fileSizesGB.append(Double(size) / 1_073_741_824)
                }
            }
            let neededGB = Roundtable.estimatedLocalMemoryGB(fileSizesGB: fileSizesGB)
            // Free RAM AFTER the resident chat model is unloaded - add its size back,
            // like loadModel's guard, since the roundtable frees it before loading.
            var freeGB = max(0, ram.totalGB - ram.usedGB)
            if let cur = activeModelURL,
               let curSize = (try? cur.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                freeGB += Double(curSize) / 1_073_741_824
            }
            if !force, neededGB > freeGB - 2.0 {   // keep ~2 GB headroom for the OS + app
                // Refuse BEFORE unloading, so a declined roundtable leaves the
                // user's current chat model exactly where it was. ramRefusal = true
                // lets the caller offer a "Try anyway" override.
                return ([], [:], String(format: "These models need about %.0f GB together, but only ~%.0f GB is free. Pick smaller models or fewer seats.", neededGB, freeGB), nil, true)
            }
            // Cleared the guard → free the resident chat engine (deinit frees
            // model + ctx) to make the room real before loading the seats. Remember
            // what we unloaded so an aborted roundtable can put it back.
            unloaded = activeModelURL
            engine?.requestStop()
            engine = nil
            loadEpoch += 1        // invalidate any in-flight load: it must NOT reinstall
            pendingTurn = nil
            activeModelURL = nil
            usingCloud = false
            activeCloudProviderID = nil
        }
        var roster: [RoundtableParticipant] = []
        var engines: [String: any LLMEngine] = [:]
        for ref in refs where engines[ref] == nil {   // one engine per distinct ref
            // Stop during assembly: don't begin loading further seats. The seat
            // already loading (a blocking C read) can't be interrupted, but this
            // bounds the damage to one in-flight load instead of the whole roster.
            if Task.isCancelled { break }
            guard let made = await makeRoundtableEngine(ref: ref) else { continue }
            // Persona is parallel to `refs` (the persisted config), so index it by
            // the ref's own position - NOT by roster.count, which lags when a seat
            // is skipped (cloud off, deleted GGUF) and would shift personas.
            let persona = refs.firstIndex(of: ref).flatMap { $0 < personas.count ? personas[$0] : nil } ?? ""
            engines[ref] = made.engine
            let name = uniqueRoundtableName(made.name, taken: roster.map(\.name))
            roster.append(RoundtableParticipant(id: ref, name: name, persona: persona, index: roster.count))
        }
        return (roster, engines, nil, unloaded, false)
    }

    /// Disambiguate display names so the per-speaker relabeling never confuses two
    /// seats (e.g. two quants that prettify to the same label).
    private func uniqueRoundtableName(_ name: String, taken: [String]) -> String {
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) (\(n))") { n += 1 }
        return "\(name) (\(n))"
    }

    /// Build one engine for a model ref. Cloud seats are silently skipped when Cloud
    /// is off or Silent Mode is on (offline-first); returns nil to drop that seat.
    private func makeRoundtableEngine(ref: String) async -> (name: String, engine: any LLMEngine)? {
        if ref == "claude-code" {
            guard settings.cloudEnabled, !settings.silentModeEnabled,
                  let e = ClaudeCodeEngine(cliPath: settings.claudeCliPath) else { return nil }
            return ("Claude Code", e)
        }
        if ref.hasPrefix("cloud:") {
            guard settings.cloudEnabled, !settings.silentModeEnabled else { return nil }
            let pid = String(ref.dropFirst("cloud:".count))
            guard let p = settings.cloudProviders.first(where: { $0.id == pid }), hasCloudKey(p) else { return nil }
            return (p.name, OpenAICompatibleEngine(provider: p, apiKey: KeychainStore.get(account: p.id)))
        }
        if ref.hasPrefix("opencode:") {
            guard settings.cloudEnabled, !settings.silentModeEnabled else { return nil }
            let mid = String(ref.dropFirst("opencode:".count))
            guard let e = OpenCodeEngine(modelID: mid, cliPath: settings.openCodeCliPath) else { return nil }
            return ("OpenCode · \(mid)", e)
        }
        let url = URL(fileURLWithPath: ref)
        guard isLoadableGGUF(url) else { return nil }
        let mmproj = ModelCatalog.mmproj(for: url).flatMap { isLoadableGGUF($0) ? $0.path : nil }
        let ctx = UInt32(Roundtable.localContextWindow)
        let path = url.path
        let eng: LlamaEngine? = await Task.detached(priority: .userInitiated) {
            try? LlamaEngine(modelPath: path, mmprojPath: mmproj, nCtx: ctx)
        }.value
        guard let eng else { return nil }
        return (SidebarView.pretty(url.lastPathComponent), eng)
    }

    // MARK: Long-term memory

    /// After a local chat turn: one short idle-gated generation extracts at
    /// most one durable fact about the user. Silent no-op when busy, on Cloud,
    /// or when memory is off - a background nicety must never cost a turn.
    private func scheduleMemoryExtraction(user: String, answer: String, source: String) {
        guard pro.allows(.memory), settings.memoryEnabled else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))   // let turn state settle
            guard let self else { return }
            let system = """
            You maintain the long-term memory of a personal assistant. From the \
            exchange, extract AT MOST ONE short durable fact about the USER worth \
            remembering in future conversations - stable preferences, personal or \
            business facts, ongoing projects. Not one-off requests, not general \
            world knowledge, nothing about this specific task. Answer with ONLY \
            that one short sentence in the user's language, or exactly NONE.
            """
            let exchange = "User: \(user.prefix(1200))\n\nAssistant: \(ChatSession.stripThink(answer).prefix(1200))"
            guard let raw = try? await flowGenerate(system: system, user: exchange),
                  let fact = MemoryStore.sanitizeExtraction(raw),
                  let saved = memory.add(fact, source: source) else { return }
            memory.save(to: Self.memoryURL)
            memoryToast = saved.text
            try? await Task.sleep(for: .seconds(3))
            memoryToast = nil
        }
    }

    func setMemoryEnabled(_ m: UserMemory, enabled: Bool) {
        var copy = m; copy.enabled = enabled
        memory.replace(copy)
        memory.save(to: Self.memoryURL)
    }

    func deleteMemory(_ id: UUID) {
        memory.remove(id)
        memory.save(to: Self.memoryURL)
    }

    func forgetAllMemories() {
        memory.removeAll()
        memory.save(to: Self.memoryURL)
    }

    // MARK: Data portability

    func exportAllData(to url: URL) throws {
        let payload = SlateDataExport(
            exportedAt: .now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            conversations: conversations,
            memories: memory.entries,
            flowHistory: FlowHistory.load(limit: .max),
            flowDictionary: FlowDictionary.load().entries,
            audit: AuditLog.recent(limit: .max),
            settings: .init(settings))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: url, options: .atomic)
    }

    /// Removes personal Slate data but deliberately keeps downloaded model
    /// binaries, which are reusable assets rather than user content.
    func deleteAllUserData() throws {
        killAll()
        pro.clearLocalStateForDataDeletion()
        KeychainStore.deleteAll()
        let dir = URL.applicationSupportDirectory.appendingPathComponent("Slate", isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("slate.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        settings.resetToDefaults()
        synchronizeNetworkAccess()
        settings.onboardingCompleted = false
        conversations = []
        selectedID = nil
        memory = MemoryStore()
    }

    /// A turn deferred until an auto model-switch (chat↔code) finishes loading.
    private var pendingTurn: Conversation.ID?
    /// Invalidation token for in-flight loads: bumped by every loadModel and by
    /// killAll, so stale completions (superseded pick, panic button) are dropped
    /// instead of reinstalling an engine and re-firing pendingTurn.
    private var loadEpoch = 0
    /// Model paths that failed to load this session - never auto-switched to again
    /// (breaks the auto-switch→fail→fallback→auto-switch livelock).
    private var failedLoads: Set<String> = []

    private static let lastModelKey = "slate.lastModelPath"

    var selected: Conversation? { conversations.first { $0.id == selectedID } }
    /// The active OpenAI-compatible cloud provider, if one is loaded (else nil for
    /// local models or Claude Code).
    var activeCloudProviderID: String?
    var activeModelName: String? {
        if let id = activeCloudProviderID, id.hasPrefix("opencode:") {
            return "OpenCode · \(id.dropFirst("opencode:".count))"
        }
        if let id = activeCloudProviderID,
           let p = settings.cloudProviders.first(where: { $0.id == id }) { return p.name }
        return usingCloud ? "Cloud · Claude Code" : activeModelURL?.lastPathComponent
    }
    var isModelLoaded: Bool { engine != nil }
    /// True when the loaded model has a vision projector - gates image input in the UI.
    var activeModelIsVision: Bool { engine?.isVision ?? false }

    /// Pinned first, then newest first.
    var sortedConversations: [Conversation] {
        conversations.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.createdAt > b.createdAt
        }
    }

    // MARK: Lifecycle

    func bootstrap() {
        let privateRoot = URL.applicationSupportDirectory.appendingPathComponent("Slate", isDirectory: true)
        do { try PrivateStorage.hardenTree(privateRoot) }
        catch {
            AuditLog.record(.init(category: "security", action: "private-storage-migration",
                                  detail: error.localizedDescription,
                                  approval: "automatic", outcome: "failed closed"))
        }
        conversations = ConversationStore.load()
        selectedID = sortedConversations.first?.id
        pro.setNetworkAccessAllowed(!settings.silentModeEnabled)
        modelStore.setRemoteDownloadsEnabled(settings.remoteModelDownloadsEnabled && !settings.silentModeEnabled)
        speech.allowVoiceDownload = settings.remoteModelDownloadsEnabled && !settings.silentModeEnabled
        modelStore.onModelsChanged = { [weak self] in self?.rescanModels() }
        modelStore.quarantineCorruptInstalls()   // trash size-mismatched files before they load
        rescanModels()
        rescanSkills()
        if pro.allows(.localTools) {
            Task { await pro.rescanLocalTools(gate: coordinator) }
        }
        refreshImageModels()
        updater.checkOnLaunch()   // silent unless a newer build is on the feed
        scanForCrashes()          // prompt once if Slate crashed since last launch
        // Flush any pending debounced conversation write on backgrounding so the
        // last turn is never lost (the write is otherwise deferred ~0.6s).
        NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPersist() }
        }
        // On QUIT: flush, then terminate hard with _exit(). The pinned llama/ggml
        // Metal backend aborts (SIGABRT) in its C++ static teardown at process exit
        // once a model has been loaded - a long-standing crash-on-quit that spawns a
        // scary crash report yet never touches user data. Skipping the atexit/global
        // destructors avoids the abort entirely; macOS reclaims all memory + Metal.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPersist()
                Self.terminateChildProcesses()   // don't orphan shell/ripgrep/opencode
                UserDefaults.standard.synchronize()
                _exit(0)
            }
        }
        // Dev/verification escape hatches:
        //   -slate.noAutoload YES  → start WITHOUT loading any model (RAM-tight UI work)
        //   -slate.showModels YES  → open the Model Manager sheet on launch
        //   -slate.showDownloads YES → open Downloads on launch
        //   -slate.showSettings YES -slate.settingsTab general → open a Settings page
        //   -slate.showRAM YES → open a wide Chat with the RAM popover visible
        if UserDefaults.standard.bool(forKey: "slate.showModels") { showModelManager = true }
        if UserDefaults.standard.bool(forKey: "slate.showDownloads") { showDownloads = true }
        if UserDefaults.standard.bool(forKey: "slate.showSettings") {
            pendingSettingsTab = UserDefaults.standard.string(forKey: "slate.settingsTab")
            showSettings = true
        }
        if UserDefaults.standard.bool(forKey: "slate.showRAM") {
            sidebarVisible = false
            if let chat = sortedConversations.first(where: { $0.kind == .chat }) { selectedID = chat.id }
        }
        startMemoryPressureGuard()   // free the model if the Mac hits critical memory
        if UserDefaults.standard.bool(forKey: "slate.noAutoload") { return }
        // Default: start WITHOUT a model loaded - a cold start stays light on RAM.
        // Opt in via Settings → Models → "Load a model automatically on launch".
        guard settings.autoLoadModelOnLaunch else { return }
        let fm = FileManager.default
        if let p = settings.defaultModelPath, fm.fileExists(atPath: p) {
            loadModel(URL(fileURLWithPath: p))                              // preferred default (coding agent)
        } else if let p = UserDefaults.standard.string(forKey: Self.lastModelKey), fm.fileExists(atPath: p) {
            loadModel(URL(fileURLWithPath: p))
        } else if let smallest = models.min(by: { $0.bytes < $1.bytes }) {
            loadModel(smallest.url)
        }
    }

    /// LLM catalog only: the image store (~/Models/image) holds diffusion
    /// transformers + their text encoders - GGUFs, but not chat models.
    func rescanModels() {
        models = ModelCatalog.scan(directories: ModelCatalog.defaultDirectories(),
                                   excluding: [ImageBundle.storeRoot])
    }

    private func friendly(_ error: Error) -> String {
        switch error {
        case GenerationError.decodeFailed:
            return "⚠️ The model ran out of memory while generating. It's likely too large for your Mac - switch to a smaller model in the sidebar (the model menu, bottom-left)."
        case GenerationError.modelLoadFailed, GenerationError.contextCreationFailed:
            return "⚠️ Couldn't load this model. Try a different (smaller) one from the sidebar."
        case GenerationError.grammarParseFailed:
            return "⚠️ Internal grammar error while preparing a tool call."
        case GenerationError.executionFailedText(let m):
            return "⚠️ \(m)"
        case let e as LocalizedError where e.errorDescription != nil:
            // Cloud API errors and other rich errors surface their real message.
            return "⚠️ \(e.errorDescription!)"
        case let e as URLError:
            return "⚠️ Network error: \(e.localizedDescription)"
        default:
            return "⚠️ \(error.localizedDescription)"
        }
    }

    /// Copies a bounded, decoded image into app-owned storage so later model
    /// loads never follow an arbitrary user path or a mutable source file.
    private static func persistImage(_ path: String) -> String? {
        let src = URL(fileURLWithPath: path)
        let dir = URL.applicationSupportDirectory.appendingPathComponent("Slate/attachments", isDirectory: true)
        let rawExtension = src.pathExtension.lowercased()
        let ext = (1...16).contains(rawExtension.utf8.count) && rawExtension.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...122).contains(byte)
        } ? rawExtension : "img"
        let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        let accessing = src.startAccessingSecurityScopedResource()
        defer { if accessing { src.stopAccessingSecurityScopedResource() } }
        do {
            let values = try src.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, (1...50 * 1_024 * 1_024).contains(size),
                  let source = CGImageSourceCreateWithURL(src as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 40_000_000 / height else { return nil }
            let data = try Data(contentsOf: src, options: .mappedIfSafe)
            try PrivateStorage.write(data, to: dest)
            return dest.path
        } catch {
            return nil
        }
    }

    // MARK: Model

    /// Switch the resident engine to Cloud (Claude Code). Reuses the user's `claude`
    /// login - a subscription runs over normal usage; an API key bills credits.
    func useClaudeCode() {
        guard settings.cloudEnabled, !settings.silentModeEnabled else {
            modelError = "Cloud mode is off. Enable it explicitly in Settings before using Claude Code."
            return
        }
        loadEpoch += 1                       // cancel any in-flight local load
        guard let eng = ClaudeCodeEngine(cliPath: settings.claudeCliPath) else {
            modelError = "Couldn't find the ‘claude’ CLI. Install Claude Code and run `claude` once to sign in, then try again."
            return
        }
        engine = eng
        usingCloud = true
        activeCloudProviderID = nil
        activeModelURL = nil
        loadingModel = false
        modelError = nil
        Task { await pro.unloadImageEngine() }   // free the image model's RAM when switching to Cloud
    }

    /// Load a saved OpenAI-compatible cloud model as the active engine.
    func useCloudModel(_ provider: CloudProvider) {
        guard settings.cloudEnabled, !settings.silentModeEnabled else {
            modelError = "Cloud mode is off. Enable it in Settings → Cloud first."; return
        }
        let key = KeychainStore.get(account: provider.id)
        guard !provider.requiresAPIKey || key?.isEmpty == false else {
            modelError = "No API key saved for \(provider.name). Add it in Settings → Cloud."; return
        }
        loadEpoch += 1
        engine = OpenAICompatibleEngine(provider: provider, apiKey: key)
        usingCloud = true
        activeCloudProviderID = provider.id
        activeModelURL = nil
        loadingModel = false
        modelError = nil
        Task { await pro.unloadImageEngine() }
    }

    /// Add or update a cloud provider; the key (if given) goes to the Keychain.
    func saveCloudProvider(_ provider: CloudProvider, apiKey: String?) {
        // Trim: a pasted key with a trailing newline corrupts the Bearer header
        // and reads as a persistent 401 ("key rejected") on a correct key.
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            KeychainStore.set(key, account: provider.id)
        }
        if let i = settings.cloudProviders.firstIndex(where: { $0.id == provider.id }) {
            settings.cloudProviders[i] = provider
        } else {
            settings.cloudProviders.append(provider)
        }
    }

    func removeCloudProvider(_ provider: CloudProvider) {
        KeychainStore.delete(account: provider.id)
        settings.cloudProviders.removeAll { $0.id == provider.id }
        if activeCloudProviderID == provider.id {
            stop()                       // cancel any in-flight turn on this engine
            activeCloudProviderID = nil; engine = nil; usingCloud = false
        }
    }

    func hasCloudKey(_ provider: CloudProvider) -> Bool {
        !provider.requiresAPIKey || KeychainStore.get(account: provider.id)?.isEmpty == false
    }

    /// Discover all model ids exposed by the user's existing OpenCode provider
    /// logins. Runs off the main actor because the CLI may read/update its cache.
    func discoverOpenCodeModels() async throws -> [String] {
        guard settings.cloudEnabled, !settings.silentModeEnabled else {
            throw NSError(domain: "Slate.Network", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Silent Mode blocks cloud model discovery."])
        }
        let path = settings.openCodeCliPath
        return try await Task.detached(priority: .utility) {
            try OpenCodeEngine.discoverModels(cliPath: path)
        }.value
    }

    func useOpenCode(modelID: String) {
        guard settings.cloudEnabled, !settings.silentModeEnabled else {
            modelError = "Cloud mode is off. Enable it in Settings → Cloud first."; return
        }
        loadEpoch += 1
        guard let connector = OpenCodeEngine(modelID: modelID, cliPath: settings.openCodeCliPath) else {
            modelError = "Couldn't find OpenCode or the model id is invalid. Check Settings → Cloud."; return
        }
        engine = connector
        usingCloud = true
        activeCloudProviderID = "opencode:\(modelID)"
        activeModelURL = nil
        loadingModel = false
        modelError = nil
        Task { await pro.unloadImageEngine() }
    }

    func removeOpenCodeModel(_ modelID: String) {
        let pin = "opencode:\(modelID)"
        settings.openCodeModels.removeAll { $0 == modelID }
        for index in conversations.indices where conversations[index].pinnedModel == pin {
            conversations[index].pinnedModel = nil
            conversations[index].openCodeSessionId = nil
        }
        if activeCloudProviderID == pin {
            stop()
            activeCloudProviderID = nil
            engine = nil
            usingCloud = false
        }
    }

    // MARK: manual model pick (per-conversation pin - a mid-chat switch that sticks)

    /// The user picked a local model for the selected conversation. Pin it so the
    /// next turn continues with it (no auto-switch away), and load it now.
    func pickLocalModel(_ url: URL) {
        if let id = selectedID { update(id) { $0.pinnedModel = url.path } }
        loadModel(url)
    }
    func pickCloudModel(_ provider: CloudProvider) {
        guard settings.cloudEnabled, !settings.silentModeEnabled else {
            modelError = "Silent Mode blocks cloud connectors. Turn it off in Settings → Network Access."
            return
        }
        if let id = selectedID { update(id) { $0.pinnedModel = "cloud:\(provider.id)" } }
        useCloudModel(provider)
    }
    func pickClaudeCode() {
        guard settings.cloudEnabled, !settings.silentModeEnabled else {
            modelError = "Silent Mode blocks cloud connectors. Turn it off in Settings → Network Access."
            return
        }
        if let id = selectedID { update(id) { $0.pinnedModel = "claude-code" } }
        useClaudeCode()
    }
    func pickOpenCodeModel(_ modelID: String) {
        guard settings.cloudEnabled, !settings.silentModeEnabled else {
            modelError = "Silent Mode blocks cloud connectors. Turn it off in Settings → Network Access."
            return
        }
        if let id = selectedID {
            update(id) {
                if $0.pinnedModel != "opencode:\(modelID)" { $0.openCodeSessionId = nil }
                $0.pinnedModel = "opencode:\(modelID)"
            }
        }
        useOpenCode(modelID: modelID)
    }
    /// True when a model is pinned for the selected conversation.
    var selectedPinnedModel: String? { selected?.pinnedModel }

    /// Ensure the conversation's pinned engine is active before its turn. Returns
    /// true when a local (async) load was started and the turn should defer.
    private func applyPin(_ pin: String, deferTurnFor id: Conversation.ID) -> Bool {
        if pin == "claude-code" {
            if usingCloud && activeCloudProviderID == nil { return false }   // already active
            useClaudeCode(); return false                                    // synchronous
        }
        if pin.hasPrefix("cloud:") {
            let pid = String(pin.dropFirst("cloud:".count))
            if activeCloudProviderID == pid { return false }
            if let p = settings.cloudProviders.first(where: { $0.id == pid }) { useCloudModel(p) }
            return false
        }
        if pin.hasPrefix("opencode:") {
            let modelID = String(pin.dropFirst("opencode:".count))
            if activeCloudProviderID == pin { return false }
            useOpenCode(modelID: modelID)
            return false
        }
        // Local path.
        if !usingCloud, activeModelURL?.path == pin { return false }          // already resident
        guard FileManager.default.fileExists(atPath: pin), !failedLoads.contains(pin) else { return false }
        pendingTurn = id
        loadModel(URL(fileURLWithPath: pin))
        return true
    }

    /// Returns a warning message if loading `url` would likely exhaust memory and
    /// hang the whole Mac (a model bigger than what will be free after the current
    /// model unloads, or fundamentally too big for this Mac). nil = safe to load.
    private func memoryRiskLoading(_ url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else { return nil }
        let bytes = Int64(size)
        let modelGB = Double(bytes) / 1_073_741_824
        // Free RAM AFTER the current model (loadModel unloads it first) is released.
        var freeGB = max(0, ram.totalGB - ram.usedGB)
        if let cur = activeModelURL, cur.path != url.path,
           let curSize = (try? cur.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            freeGB += Double(curSize) / 1_073_741_824
        }
        let tooBigForMac = ModelRAMFit.evaluate(fileBytes: bytes,
                                                physicalRAM: ProcessInfo.processInfo.physicalMemory) == .tooBig
        guard tooBigForMac || modelGB > freeGB + 1.0 else { return nil }   // 1 GB headroom
        return String(format: "‘%@’ needs about %.0f GB, but only ~%.0f GB is free. Loading it could freeze your Mac - close other apps or pick a smaller model.",
                      SidebarView.pretty(url.lastPathComponent), modelGB, max(0, freeGB))
    }

    /// Keep malformed paths, directories, fifos and non-GGUF files away from
    /// llama.cpp. Model files are selected by the user, but the native parser
    /// still deserves a small, explicit file-type boundary before it opens one.
    private func isLoadableGGUF(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) >= 4 else { return false }
        return DownloadCatalog.hasGGUFMagic(url)
    }

    func loadModel(_ url: URL, allowFallback: Bool = true, force: Bool = false) {
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        guard isLoadableGGUF(url) else {
            if accessedSecurityScope { url.stopAccessingSecurityScopedResource() }
            loadingModel = false
            pendingTurn = nil
            modelError = "‘\(url.lastPathComponent)’ is not a valid GGUF model file."
            return
        }
        // RAM safety: loading a model too big for memory thrashes the system into a
        // swap storm and can HANG the whole Mac (watchdog reboot). Block it behind a
        // "Load anyway" override instead of taking the machine down.
        if !force, let risk = memoryRiskLoading(url) {
            loadingModel = false
            pendingTurn = nil
            notify(.warning, risk, actionLabel: "Load anyway") { [weak self] in
                self?.loadModel(url, allowFallback: allowFallback, force: true)
            }
            return
        }
        loadingModel = true; modelError = nil
        engine = nil
        usingCloud = false
        activeCloudProviderID = nil
        Task { await pro.unloadImageEngine() }   // free the image model's RAM before an LLM loads
        loadEpoch += 1
        let epoch = loadEpoch                 // newest load wins; older completions are dropped
        let path = url.path
        let mmproj = ModelCatalog.mmproj(for: url).flatMap { isLoadableGGUF($0) ? $0.path : nil }
        let ctx = UInt32(settings.contextWindow)
        // Load OFF the main thread - llama_model_load is a blocking multi-GB read that
        // would otherwise freeze the whole UI (no window, dock won't activate) while a
        // large model loads. The window stays responsive and shows "Loading…".
        Task.detached(priority: .userInitiated) {
            do {
                let eng = try LlamaEngine(modelPath: path, mmprojPath: mmproj, nCtx: ctx)
                await MainActor.run {
                    // Superseded by a newer load or Kill all: drop this engine
                    // (deinit frees it) and do NOT re-fire the deferred turn.
                    guard epoch == self.loadEpoch else { return }
                    self.engine = eng
                    self.activeModelURL = url
                    self.failedLoads.remove(path)
                    UserDefaults.standard.set(path, forKey: Self.lastModelKey)
                    self.loadingModel = false
                    self.notify(.success, "\(SidebarView.pretty(url.lastPathComponent)) ready")
                    // Run a turn that was waiting on this (auto chat↔code) switch.
                    if let pt = self.pendingTurn { self.pendingTurn = nil; self.runTurn(pt) }
                }
            } catch {
                await MainActor.run {
                    guard epoch == self.loadEpoch else { return }
                    // Never auto-switch to this path again this session - otherwise a
                    // deferred turn re-triggers the failed load in an endless loop.
                    self.failedLoads.insert(path)
                    // Auto-fall back to the smaller model if the default fails (e.g. OOM).
                    if allowFallback, let fb = self.settings.fallbackModelPath,
                       fb != path, FileManager.default.fileExists(atPath: fb) {
                        self.modelError = "‘\(url.lastPathComponent)’ couldn’t load - falling back to a smaller model."
                        self.loadModel(URL(fileURLWithPath: fb), allowFallback: false)
                    } else {
                        // Clean copy instead of a raw Swift enum dump.
                        self.modelError = self.friendly(error)
                        self.loadingModel = false
                        self.pendingTurn = nil       // don't strand a queued turn
                    }
                }
            }
        }
    }

    /// Reload the active model (e.g. after changing the context window setting).
    func reloadActiveModel() { if let url = activeModelURL { loadModel(url) } }

    /// The model configured for a conversation kind: Chat → chat model (falls back to
    /// the coding default), Code → coding default. nil if none is configured/on disk.
    func preferredModelPath(for kind: Conversation.Kind) -> String? {
        let want = kind == .chat ? (settings.chatModelPath ?? settings.defaultModelPath)
                                 : settings.defaultModelPath
        guard let want, FileManager.default.fileExists(atPath: want) else { return nil }
        return want
    }

    /// Should we auto-switch the resident model to `want` for this turn? Only when the
    /// currently loaded model is one of the two configured kind-defaults (or nothing is
    /// loaded) - so a model the user picked by hand is never yanked out from under them.
    private func shouldAutoSwitch(to want: String) -> Bool {
        guard !failedLoads.contains(want) else { return false }    // failed this session → stay put
        guard activeModelURL?.path != want else { return false }   // already resident
        guard let loaded = activeModelURL?.path else { return true } // nothing loaded → load it
        let code = settings.defaultModelPath
        let chat = settings.chatModelPath ?? settings.defaultModelPath
        return loaded == code || loaded == chat
    }

    // MARK: Conversation management (ChatGPT/Claude-style)

    func newConversation(kind: Conversation.Kind) {
        let c = Conversation(kind: kind, createdAt: Date())
        conversations.append(c)
        selectedID = c.id
        persist()
    }

    func delete(_ id: Conversation.ID) {
        let wasSelected = selectedID == id
        let deletedKind = conversations.first { $0.id == id }?.kind
        conversations.removeAll { $0.id == id }
        if wasSelected {
            if let next = sortedConversations.first(where: { $0.kind == deletedKind }) {
                selectedID = next.id                 // stay on another chat of this kind
            } else if let kind = deletedKind {
                // Closed the last chat of this kind: open a fresh one of the SAME kind
                // so the user stays in this tab on a usable session - never yanked to
                // another tab, never dumped onto the full-screen welcome.
                newConversation(kind: kind)          // appends + selects + persists
                return
            } else {
                selectedID = nil
            }
        }
        persist()
    }

    func deleteSelected() { if let id = selectedID { delete(id) } }

    func rename(_ id: Conversation.ID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed; $0.manualTitle = true }
    }

    func togglePin(_ id: Conversation.ID) { update(id) { $0.pinned.toggle() } }

    func duplicate(_ id: Conversation.ID) {
        guard let c = conversations.first(where: { $0.id == id }) else { return }
        var copy = Conversation(kind: c.kind, createdAt: Date())
        copy.title = c.title + " copy"
        copy.manualTitle = true
        copy.folderPath = c.folderPath
        copy.permissionMode = c.permissionMode
        copy.messages = c.messages
        copy.agentModels = c.agentModels
        copy.agentPersonas = c.agentPersonas
        copy.agentRounds = c.agentRounds
        copy.agentSynthesis = c.agentSynthesis
        conversations.append(copy)
        selectedID = copy.id
        _ = c
        persist()
    }

    func setFolder(_ url: URL, for id: Conversation.ID) {
        update(id) { $0.folderPath = url.path; $0.trustedProjectRulesDigest = nil }
    }
    func setProjectRulesTrusted(_ trusted: Bool, for id: Conversation.ID) {
        update(id) { conversation in
            guard trusted, let folder = conversation.folderURL,
                  let rules = ProjectRules.find(in: folder) else {
                conversation.trustedProjectRulesDigest = nil
                return
            }
            conversation.trustedProjectRulesDigest = rules.digest
        }
    }
    func setMode(_ mode: PermissionMode, for id: Conversation.ID) { update(id) { $0.permissionMode = mode.rawValue } }
    func setPlanMode(_ on: Bool, for id: Conversation.ID) { update(id) { $0.planMode = on } }

    /// The conversation rendered as portable Markdown (copy / export).
    func conversationMarkdown(_ id: Conversation.ID) -> String {
        guard let c = conversations.first(where: { $0.id == id }) else { return "" }
        let date = c.createdAt.formatted(date: .abbreviated, time: .shortened)
        return ConversationExport.markdown(title: c.title, model: activeModelName ?? "local model",
                                           date: date, messages: c.messages)
    }
    /// Agent Chat: persist a roundtable's seat/persona/round configuration.
    func setAgentConfig(models: [String], personas: [String], rounds: Int, synthesis: Bool,
                        for id: Conversation.ID) {
        update(id) {
            $0.agentModels = models
            $0.agentPersonas = personas
            $0.agentRounds = max(1, rounds)
            $0.agentSynthesis = synthesis
        }
    }

    /// Every model that can take a roundtable seat: each downloaded local GGUF,
    /// plus cloud seats (providers with a key, OpenCode models, Claude Code) when
    /// Cloud is enabled and Silent Mode is off.
    var roundtableCandidates: [RoundtableCandidate] {
        var list: [RoundtableCandidate] = []
        for m in models {
            let gb = Double(m.bytes) / 1_073_741_824
            list.append(RoundtableCandidate(ref: m.url.path, name: SidebarView.pretty(m.name),
                                            detail: gb > 0 ? String(format: "%.1f GB", gb) : "local",
                                            sizeGB: gb, isLocal: true))
        }
        if settings.cloudEnabled, !settings.silentModeEnabled {
            for p in settings.cloudProviders where hasCloudKey(p) {
                list.append(RoundtableCandidate(ref: "cloud:\(p.id)", name: p.name,
                                                detail: "Cloud", sizeGB: 0, isLocal: false))
            }
            for mid in settings.openCodeModels {
                list.append(RoundtableCandidate(ref: "opencode:\(mid)", name: "OpenCode · \(mid)",
                                                detail: "Cloud", sizeGB: 0, isLocal: false))
            }
        }
        return list
    }

    func setTemperature(_ t: Double?, for id: Conversation.ID) { update(id) { $0.temperature = t } }
    func setSystemPrompt(_ s: String?, for id: Conversation.ID) {
        update(id) { $0.systemPromptOverride = (s?.isEmpty ?? true) ? nil : s }
    }

    private func update(_ id: Conversation.ID, _ f: (inout Conversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        f(&conversations[i]); persist()
    }

    @ObservationIgnored private var persistTask: Task<Void, Never>?

    /// Coalesce a burst of changes into one write ~0.6s later; the disk write runs
    /// OFF the main actor. Encoding stays here (cheap vs. the write, and yields a
    /// Sendable `Data` snapshot). Atomic write + corruption backup are unchanged.
    private func persist() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        persistTask?.cancel()
        persistTask = Task { [data] in
            try? await Task.sleep(for: .milliseconds(600))
            if Task.isCancelled { return }
            await Task.detached(priority: .utility) { ConversationStore.write(data) }.value
        }
    }

    /// Force any pending write immediately (on quit / resign-active) so nothing is lost.
    func flushPersist() {
        persistTask?.cancel()
        if let data = try? JSONEncoder().encode(conversations) { ConversationStore.write(data) }
    }

    // MARK: Messages

    func send(_ text: String, imagePath: String? = nil) {
        // A live voice turn owns the engine - a chat turn started now would
        // queue behind it and the voice stop flag would cross-kill it.
        guard !voiceGenerating else { return }
        // /compact is a LOCAL control command: summarize older messages instead of
        // sending the literal command to the model (Cloud runs its own /compact).
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/compact",
           let engine, !engine.isPassthroughAgent {
            Task { await runCompact() }
            return
        }
        guard text.utf8.count <= 64 * 1_024 else {
            modelError = "A single message is limited to 64 KB. Attach a file as local knowledge for larger text."
            return
        }
        guard let id = selectedID, let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        var convo = conversations[i]
        let wasFirst = convo.messages.filter { $0.role == .user }.isEmpty
        let storedImage: String?
        if let imagePath {
            guard let copied = Self.persistImage(imagePath) else {
                modelError = "The selected image is not a safe, supported image file (max. 50 MB / 40 megapixels)."
                return
            }
            storedImage = copied
        } else {
            storedImage = nil
        }
        convo.messages.append(ChatMessage(role: .user, content: text, imagePath: storedImage))
        if wasFirst && !convo.manualTitle { convo.title = String(text.prefix(48)) }
        conversations[i] = convo
        persist()
        runTurn(id)
    }

    /// Replace the older half of the current conversation with a model-written
    /// summary. A destructive edit of the stored convo, so it is confirmed first.
    func runCompact() async {
        guard !isGenerating, !roundtableActive else { notify(.notice, "Wait for the current reply to finish."); return }
        guard let id = selectedID,
              let convo = conversations.first(where: { $0.id == id }),
              let engine, !engine.isPassthroughAgent else { return }
        let plan = CompactService.plan(messages: convo.messages, keepRecent: 6)
        guard !plan.toSummarize.isEmpty else { notify(.notice, "Nothing to compact yet."); return }
        guard await coordinator.confirm(ApprovalRequest(
            kind: .fileWrite, risk: .sensitive,
            title: "Compact this conversation?",
            detail: "\(plan.toSummarize.count) older messages will be replaced by a summary. Recent messages are kept.",
            scope: "compact:\(id)")) else { return }
        var summary = ""
        do {
            for try await piece in await engine.generate(
                messages: [ChatMessage(role: .user, content: CompactService.summaryPrompt(for: plan.toSummarize))],
                grammar: nil, options: GenOptions(maxTokens: 1024)) {
                summary += piece
            }
        } catch { notify(.error, "Compact failed: \(error.localizedDescription)"); return }
        let clean = ChatSession.stripThink(summary).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { notify(.error, "Compact produced no summary."); return }
        let note = ChatMessage(role: .assistant, content: "**Summary of earlier conversation**\n\n\(clean)")
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            let systems = conversations[index].messages.filter { $0.role == .system }
            conversations[index].messages = systems + [note] + plan.keep
            persist()
            notify(.success, "Conversation compacted.")
        }
    }

    /// Re-generate the latest assistant response (drops trailing assistant/tool turns).
    func regenerate() {
        guard let id = selectedID, let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        var convo = conversations[i]
        while let last = convo.messages.last, last.role != .user { convo.messages.removeLast() }
        guard convo.messages.last?.role == .user else { return }
        conversations[i] = convo
        persist()
        runTurn(id)
    }

    /// Edit a user message: truncate the conversation to before it and return its
    /// text so the composer can be refilled for resending.
    @discardableResult
    func beginEdit(messageID: ChatMessage.ID) -> String? {
        guard let id = selectedID, let i = conversations.firstIndex(where: { $0.id == id }),
              let mi = conversations[i].messages.firstIndex(where: { $0.id == messageID }),
              conversations[i].messages[mi].role == .user else { return nil }
        let text = conversations[i].messages[mi].content
        conversations[i].messages.removeSubrange(mi...)
        persist()
        return text
    }

    func stop() {
        pendingTurn = nil       // a turn queued behind an auto model-switch must NOT fire after Stop
        engine?.requestStop()   // breaks the C generation loop promptly
        for e in roundtableEngines.values { e.requestStop() }   // Agent Chat: unstick the active seat
        genTask?.cancel()       // unwinds the async consumer + agent loop
        isGenerating = false; generatingConvoID = nil; streamingText = ""; tokensPerSec = 0
        streamingSpeaker = nil; streamingSpeakerIndex = nil
    }

    /// Panic button: stop every in-flight generation, UNLOAD the model (frees the
    /// model's RAM/VRAM as soon as the generation task unwinds), and terminate any
    /// child processes (shell commands, ripgrep). The user then reloads a model.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Safety net against the whole-Mac hang: when macOS reports CRITICAL memory
    /// pressure, free the model (and everything else) so a swap storm can't lock up
    /// the machine. Toggleable in Settings via `autoUnloadUnderMemoryPressure`.
    private func startMemoryPressureGuard() {
        guard memoryPressureSource == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.settings.autoUnloadUnderMemoryPressure,
                      self.isModelLoaded || self.loadingModel else { return }
                self.killAll()   // frees the model + generation + child processes
            }
        }
        src.resume()
        memoryPressureSource = src
    }

    func killAll() {
        loadEpoch += 1               // invalidate any in-flight load: it must NOT reinstall
        pendingTurn = nil            // …and must NOT auto-restart a deferred turn
        engine?.requestStop()        // unstick the C loop so it releases the engine
        genTask?.cancel()
        genTask = nil
        engine = nil                 // drop our reference → deinit frees model + ctx (+ mtmd)
        for e in roundtableEngines.values { e.requestStop() }  // Agent Chat: free its whole pool
        roundtableEngines = [:]
        roundtableActive = false
        activeModelURL = nil
        usingCloud = false
        activeCloudProviderID = nil
        isGenerating = false
        generatingConvoID = nil
        streamingText = ""
        streamingSpeaker = nil
        streamingSpeakerIndex = nil
        if loadingModel {
            // llama.cpp loads are a blocking C call - they can't be aborted, only
            // discarded on completion. Say so instead of looking like a no-op.
            notify(.warning, "Unloading: the in-flight model load can't be aborted - it will be discarded (and RAM freed) the moment it finishes.")
        } else {
            notify(.warning, "Stopped everything and unloaded the model.",
                   actionLabel: "Load model") { [weak self] in self?.showModelManager = true }
        }
        loadingModel = false
        coordinator.resetSessionApprovals()   // safety reset alongside the panic button
        Self.terminateChildProcesses()
    }

    // MARK: Image generation

    func refreshImageModels() {
        installedImageBundles = ImageBundle.all.filter { $0.isInstalled }
        if selectedImageModelID == nil || !installedImageBundles.contains(where: { $0.id == selectedImageModelID }) {
            selectedImageModelID = installedImageBundles.first?.id
        }
    }

    func downloadImageBundle(_ b: ImageBundle) {
        guard imageDownloadID == nil else { return }
        guard settings.remoteModelDownloadsEnabled, !settings.silentModeEnabled else {
            imageError = "Model downloads are blocked. Enable them in Settings → Network Access, or add a verified local model."
            return
        }
        imageDownloadID = b.id; imageDownloadProgress = 0; imageError = nil
        imageRepairBundleID = nil
        imageDownloader.start(b,
            onProgress: { [weak self] p in self?.imageDownloadProgress = p },
            onDone: { [weak self] err in
                guard let self else { return }
                self.imageDownloadID = nil
                if let err {
                    self.imageError = "Download failed: \(err.localizedDescription)"
                    self.imageRepairBundleID = b.id
                } else {
                    self.imageRepairBundleID = nil
                }
                self.refreshImageModels()
            })
    }

    /// Re-download a failed image bundle. Any complete, size-verified files are
    /// skipped, so this resumes rather than restarting; a stray ".partial" staging
    /// file from an interrupted transfer is cleared first so it cannot linger.
    func repairImageDownload() {
        guard let id = imageRepairBundleID, imageDownloadID == nil,
              let bundle = ImageBundle.all.first(where: { $0.id == id }) else { return }
        if let files = try? FileManager.default.contentsOfDirectory(at: bundle.installDir,
                                                                    includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "partial" {
                try? FileManager.default.removeItem(at: f)
            }
        }
        imageError = nil
        imageRepairBundleID = nil
        downloadImageBundle(bundle)
    }

    /// Dismiss a read image-download error and its repair affordance.
    func dismissImageError() {
        imageError = nil
        imageRepairBundleID = nil
    }

    // MARK: Qwen3 premium voice

    /// Download (or resume) the ~820 MB Qwen3-TTS premium voice. Complete files
    /// are skipped, so an interrupted transfer continues instead of restarting.
    func downloadQwen3Voice() {
        guard !qwen3Downloading else { return }
        guard settings.remoteModelDownloadsEnabled, !settings.silentModeEnabled else {
            qwen3Error = "Model downloads are blocked. Enable them in Settings → Network Access."
            return
        }
        qwen3Downloading = true; qwen3DownloadProgress = 0; qwen3Error = nil
        qwen3Downloader.start(
            onProgress: { [weak self] p in self?.qwen3DownloadProgress = p },
            onDone: { [weak self] err in
                guard let self else { return }
                self.qwen3Downloading = false
                self.qwen3Installed = Qwen3VoiceBundle.isInstalled
                self.qwen3Error = err.map { "Voice download failed: \($0.localizedDescription)" }
            })
    }

    func cancelQwen3Download() {
        guard qwen3Downloading else { return }
        qwen3Downloader.cancel()
        qwen3Downloading = false
        qwen3DownloadProgress = 0
    }

    func dismissQwen3Error() { qwen3Error = nil }

    /// Remove the premium voice bundle and fall back off any Qwen3 assistant voice.
    func deleteQwen3Voice() {
        cancelQwen3Download()
        try? FileManager.default.removeItem(at: Qwen3VoiceBundle.installRoot)
        qwen3Installed = false
        if Qwen3VoiceBundle.isQwen3Voice(settings.assistantVoice) {
            settings.assistantVoice = "M1"
        }
    }

    func setRemoteModelDownloadsEnabled(_ enabled: Bool) {
        settings.remoteModelDownloadsEnabled = enabled
        let effective = enabled && !settings.silentModeEnabled
        modelStore.setRemoteDownloadsEnabled(effective)
        guard !effective else { return }
        if imageDownloadID != nil {
            imageDownloader.cancel()
            imageDownloadID = nil
            imageDownloadProgress = 0
            imageError = "Remote image-model download cancelled because network downloads were disabled."
        }
        if qwen3Downloading {
            cancelQwen3Download()
            qwen3Error = "Voice download cancelled because network downloads were disabled."
        }
    }

    /// Central user-facing network latch. It cancels Slate-owned transfers and
    /// active cloud connectors while leaving the resident local model intact.
    func setSilentModeEnabled(_ enabled: Bool) {
        guard settings.silentModeEnabled != enabled else { return }
        settings.silentModeEnabled = enabled
        synchronizeNetworkAccess()
        AuditLog.record(.init(category: "privacy", action: "silent_mode",
                              detail: enabled ? "enabled" : "disabled",
                              approval: "user setting", outcome: "success"))
    }

    /// Re-applies persisted/imported/reset network preferences to the live
    /// clients. This also closes any connection that is no longer permitted.
    func synchronizeNetworkAccess() {
        let silent = settings.silentModeEnabled
        let downloadsAllowed = settings.remoteModelDownloadsEnabled && !silent
        pro.setNetworkAccessAllowed(!silent)
        modelStore.setRemoteDownloadsEnabled(downloadsAllowed)
        speech.allowVoiceDownload = downloadsAllowed
        if silent { updater.enterSilentMode() }
        if !downloadsAllowed, imageDownloadID != nil {
            imageDownloader.cancel()
            imageDownloadID = nil
            imageDownloadProgress = 0
            imageError = silent ? "Download cancelled because Silent Mode was enabled."
                                : "Download cancelled because model downloads were disabled."
        }
        if !downloadsAllowed, qwen3Downloading {
            cancelQwen3Download()
            qwen3Error = silent ? "Voice download cancelled because Silent Mode was enabled."
                                : "Voice download cancelled because model downloads were disabled."
        }
        if usingCloud, silent || !settings.cloudEnabled {
            stop()
            Self.terminateChildProcesses()
            engine = nil
            activeCloudProviderID = nil
            activeModelURL = nil
            usingCloud = false
            if silent { modelError = "Cloud connector stopped because Silent Mode was enabled." }
        }
    }

    func setCloudEnabled(_ enabled: Bool) {
        guard !enabled || !settings.silentModeEnabled else {
            notify(.warning, "Silent Mode is on. Turn it off in Network Access before enabling cloud connectors.")
            return
        }
        settings.cloudEnabled = enabled
        synchronizeNetworkAccess()
    }

    func deleteImageModel(_ b: ImageBundle) {
        try? FileManager.default.removeItem(at: b.installDir)
        refreshImageModels()
    }

    /// From the Image section: if the LLM is loaded / a turn runs, raise the
    /// stop-gate; otherwise generate now.
    func requestImage(prompt: String, width: Int, height: Int, seed: Int64, in convoID: UUID,
                      initImagePath: String? = nil, strength: Float = 0.6) {
        guard prompt.utf8.count <= 16_000,
              (64...2_048).contains(width), (64...2_048).contains(height),
              width % 64 == 0, height % 64 == 0,
              strength.isFinite && (0...1).contains(strength) else {
            imageError = "The image request is outside Slate's safe size limits."
            return
        }
        let storedInitImage: String?
        if let initImagePath {
            guard let copied = Self.persistImage(initImagePath) else {
                imageError = "The source image is not a safe, supported image file (max. 50 MB / 40 megapixels)."
                return
            }
            storedInitImage = copied
        } else {
            storedInitImage = nil
        }
        let req = PendingImage(convoID: convoID, prompt: prompt, width: width, height: height,
                               seed: seed, initImagePath: storedInitImage, strength: strength)
        if engine != nil || isGenerating || usingCloud || loadingModel { pendingImage = req }
        else { runImage(req) }
    }

    func confirmPendingImage() {
        guard let req = pendingImage else { return }
        pendingImage = nil
        // Free memory: stop generation + unload the LLM (quiet killAll).
        loadEpoch += 1; pendingTurn = nil
        engine?.requestStop(); genTask?.cancel(); genTask = nil
        engine = nil; activeModelURL = nil; usingCloud = false; activeCloudProviderID = nil
        isGenerating = false; generatingConvoID = nil; streamingText = ""; loadingModel = false
        runImage(req)
    }
    func cancelPendingImage() { pendingImage = nil }

    private func runImage(_ req: PendingImage) {
        guard let bundle = installedImageBundles.first(where: { $0.id == selectedImageModelID }) ?? installedImageBundles.first,
              let files = bundle.installedFiles() else {
            imageError = "No image model installed - download one in the Model Manager."
            return
        }
        guard !bundle.requiresReferenceImage || req.initImagePath != nil else {
            imageError = "\(bundle.name) needs a reference image. Attach or drop an image, then describe the edit."
            return
        }
        update(req.convoID) { c in
            // img2img: the source rides along on the user message (visible in the transcript).
            c.messages.append(ChatMessage(role: .user, content: req.prompt, imagePath: req.initImagePath))
            if !c.manualTitle && c.isUntitled { c.title = String(req.prompt.prefix(48)) }
        }
        imageGenerating = true; imageGeneratingConvoID = req.convoID
        imageStep = 0; imageTotalSteps = bundle.defaultSteps; imageError = nil
        // All the compute — model load + diffusion — happens inside the private
        // ProImageEngine (slate-pro). The free build's seam throws here, so it can
        // never reach a pixel: image generation is unbypassable by recompiling.
        let job = ImageJob(modelID: bundle.id, modelName: bundle.name, arch: bundle.arch,
                           diffusionPath: files.diffusion, encoderPath: files.encoder, vaePath: files.vae,
                           requiresReferenceImage: bundle.requiresReferenceImage,
                           prompt: req.prompt, width: req.width, height: req.height, seed: req.seed,
                           initImagePath: req.initImagePath, strength: req.strength)
        let convoID = req.convoID
        Task { @MainActor in
            do {
                let png = try await pro.generateImage(job) { [weak self] step, total in
                    Task { @MainActor in self?.imageStep = step; self?.imageTotalSteps = total }
                }
                let path = Self.saveGeneratedImage(png)
                update(convoID) { $0.messages.append(ChatMessage(role: .assistant, content: "", imagePath: path)) }
            } catch {
                imageError = "Generation failed: \(error.localizedDescription)"
                update(convoID) { $0.messages.append(ChatMessage(role: .assistant, content: "⚠️ Image generation failed. \(error.localizedDescription)")) }
            }
            imageGenerating = false; imageGeneratingConvoID = nil
        }
    }

    private static func saveGeneratedImage(_ png: Data) -> String {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("Slate/images", isDirectory: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString).png")
        try? PrivateStorage.write(png, to: dest)
        return dest.path
    }

    // MARK: Checkpoints / Git / Handoff (power features v3)

    func checkpoints(for id: Conversation.ID) -> [CheckpointInfo] { Checkpoints.list(key: id.uuidString) }

    func restoreCheckpoint(_ info: CheckpointInfo, for id: Conversation.ID) {
        guard let folder = conversations.first(where: { $0.id == id })?.folderURL else { return }
        Checkpoints.restore(info, scope: WorkspaceScope(root: folder))
    }

    func gitStatus(_ folder: URL) -> [Git.Change] { Git.status(folder) }
    func gitBranch(_ folder: URL) -> String? { Git.currentBranch(folder) }
    func gitIsRepo(_ folder: URL) -> Bool { Git.isRepo(folder) }
    func gitDiff(_ folder: URL, file: String?) -> String { Git.diff(folder, file: file) }
    @discardableResult
    func gitCommit(_ folder: URL, message: String) -> (ok: Bool, output: String) {
        Git.commit(folder, message: message)
    }

    /// Markdown brief to paste back into Claude Code when the limit resets.
    func handoffMarkdown(for id: Conversation.ID) -> String {
        guard let c = conversations.first(where: { $0.id == id }) else { return "" }
        let changed = c.folderURL.map { Git.status($0).map(\.path) } ?? []
        return Handoff.markdown(title: c.title, folder: c.folderURL?.path, messages: c.messages, changedFiles: changed)
    }

    // MARK: Continue from Claude Code

    func claudeCodeSessions(for folder: URL) -> [ClaudeCodeImport.Session] {
        ClaudeCodeImport.sessions(forFolder: folder)
    }

    /// Import the latest Claude Code session for `folder` into a fresh Code conversation.
    /// Returns false if there are no Claude Code sessions for that folder.
    @discardableResult
    func importLatestClaudeCode(folder: URL) -> Bool {
        guard let latest = ClaudeCodeImport.sessions(forFolder: folder).first else { return false }
        let msgs = ClaudeCodeImport.recentTail(ClaudeCodeImport.messages(from: latest.fileURL))
        var c = Conversation(kind: .code, createdAt: Date())
        c.folderPath = folder.path
        c.title = "↩ " + latest.title
        c.manualTitle = true
        c.messages = msgs
        conversations.append(c)
        selectedID = c.id
        persist()
        return true
    }

    /// Best-effort: TERM all direct child processes of this app (shell/ripgrep).
    private static func terminateChildProcesses() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-TERM", "-P", "\(ProcessInfo.processInfo.processIdentifier)"]
        try? p.run()
    }

    /// Streams a reply for the selected conversation whose last message is a user turn.
    private func runTurn(_ id: Conversation.ID) {
        guard let convo = conversations.first(where: { $0.id == id }) else { return }
        // Honor the conversation's pinned model (a mid-chat switch that sticks,
        // like Claude Code); otherwise auto-switch to the kind's default. A local
        // load defers the turn until it finishes.
        if let pin = convo.pinnedModel {
            if applyPin(pin, deferTurnFor: id) { return }
        } else if !usingCloud, let want = preferredModelPath(for: convo.kind), shouldAutoSwitch(to: want) {
            pendingTurn = id
            loadModel(URL(fileURLWithPath: want))
            return
        }
        guard let engine else {
            modelError = "Select a model in the sidebar to start."; return
        }
        genTask?.cancel()
        engine.clearStop()       // re-arm cooperative stop for this new turn
        streamingText = ""; isGenerating = true; generatingConvoID = id; tokensPerSec = 0
        // Enforcement: only Pro may run elevated permission modes. Free sessions
        // always execute in Ask (fail-closed), even if a stale value is stored.
        modeHolder.mode = pro.allows(.codeEdits) ? convo.mode : .ask
        modeHolder.skipPermissions = settings.skipPermissions

        let kind = convo.kind
        let folder = convo.folderURL
        // Expand any /slash commands in user turns when building the prompt (display
        // keeps the raw text). Idempotent for non-command text.
        var history = convo.messages.map { m in
            m.role == .user
                ? ChatMessage(role: .user, content: SlashCommands.expand(m.content), imagePath: m.imagePath)
                : m
        }
        // Local models have a finite context window; keep the prompt safely under it
        // so long chats never dead-end. Passthrough (Cloud) engines report 0 -> no trim.
        if engine.contextWindow > 0 {
            let reserve = settings.maxTokens + 256
            let budget = max(engine.contextWindow - reserve, engine.contextWindow / 2)
            let (kept, dropped) = ContextBudget.trim(history, approxTokenBudget: budget)
            history = kept
            lastPromptTrimmedCount = dropped
        } else {
            lastPromptTrimmedCount = 0
        }
        let rawMessages = convo.messages   // Cloud passes RAW text so Claude Code's own slash commands work
        let genStart = Date()
        let gate = coordinator
        let holder = modeHolder
        // Ultracode: the effort ladder's top rung also injects an orchestration
        // directive (subagents + adversarial verification) into the system prompt.
        var systemOverride = convo.systemPromptOverride
        if let ultra = settings.thinkingEffort.systemAddendum, engine.isPassthroughAgent {
            systemOverride = [systemOverride, ultra].compactMap { $0 }.joined(separator: "\n\n")
        }
        let opts = GenOptions(temperature: convo.temperature ?? settings.defaultTemperature,
                              maxTokens: settings.maxTokens,
                              workingDirectory: folder?.path,
                              claudeSessionId: convo.claudeSessionId,
                              openCodeSessionId: convo.openCodeSessionId,
                              permissionMode: modeHolder.mode,
                              skipPermissions: modeHolder.skipPermissions,
                              claudeModel: settings.claudeModel,
                              systemPromptOverride: systemOverride,
                              maxThinkingTokens: settings.thinkingEffort.maxThinkingTokens,
                              webSearchEnabled: settings.webSearchEnabled && !settings.silentModeEnabled)
        let passthrough = engine.isPassthroughAgent   // Cloud / Claude Code runs its own agent

        genTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if passthrough {
                    // Stream Claude Code directly (it brings its own tools + slash
                    // commands). Raw messages so /compact, /cost, /review, etc. reach
                    // it verbatim. Persist the session id for context continuity.
                    var full = ""
                    var toks = 0
                    for try await chunk in await engine.generate(messages: rawMessages, grammar: nil, options: opts) {
                        full += chunk; toks += 1
                        self.tokensPerSec = Double(toks) / max(0.2, Date().timeIntervalSince(genStart))
                        self.streamingText = full
                    }
                    var stats = Self.statsLine(tokens: toks, since: genStart)
                    if let cc = engine as? ClaudeCodeEngine {
                        if let sid = cc.lastSessionId { self.update(id) { $0.claudeSessionId = sid } }
                        // NB: the CLI reports `total_cost_usd` (equivalent API price) on
                        // EVERY turn, even on a Claude subscription where nothing is
                        // actually charged - showing it reads as a bill you didn't get.
                        // Keep it out of the footer; surface it only via `/cost` on demand.
                        if let turns = cc.lastTurns, turns > 1 { stats += " · \(turns) turns" }
                    } else if let oc = engine as? OpenCodeEngine {
                        if let sid = oc.lastSessionID { self.update(id) { $0.openCodeSessionId = sid } }
                        if let total = oc.lastTokens { stats += " · \(total) provider tok" }
                    }
                    self.appendAssistant(full, to: id, stats: stats)
                } else if kind == .code, let folder {
                    // Plan mode: an explicit numbered plan FIRST (visible in the
                    // transcript), then the agent works through it - small local
                    // models gain a lot of reliability from this.
                    var planText: String?
                    if convo.planMode, let task = history.last(where: { $0.role == .user })?.content {
                        self.streamingText = "→ planning…"
                        var plan = ""
                        let planMsgs = [ChatMessage(role: .system, content: PlanMode.system),
                                        ChatMessage(role: .user, content: task)]
                        for try await c in await engine.generate(
                            messages: planMsgs, grammar: nil,
                            options: GenOptions(temperature: PlanMode.temperature,
                                                maxTokens: PlanMode.maxTokens)) {
                            plan += c
                            self.streamingText = "→ planning…\n" + plan
                        }
                        let cleaned = Reasoning.strip(plan).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            planText = cleaned
                            self.appendAssistant("📋 **Plan**\n\n" + cleaned, to: id)
                            self.streamingText = ""
                        }
                    }
                    let scope = WorkspaceScope(root: folder)
                    // Per-project memory (Pro + memory enabled): the agent can persist
                    // durable project facts; they're injected into the prompt next session.
                    let projMemOn = self.pro.allows(.memory) && self.settings.memoryEnabled
                    let projectMemoryTool: [RegisteredTool] = projMemOn ? [
                        RegisteredTool(spec: ToolSpec(
                            name: "remember_project_fact",
                            description: "Persist ONE durable fact about THIS project (a build/test command that works, a convention, an architecture decision, a gotcha) so future sessions know it without rediscovering.",
                            parameters: [.init(name: "fact", description: "one short durable project fact", required: true)])) { args in
                                guard let fact = ProjectMemory.sanitize(args["fact"] ?? "") else {
                                    return "Not stored (empty or too long)."
                                }
                                var pm = ProjectMemory.load(for: folder)
                                guard pm.add(fact) else { return "Already known for this project." }
                                pm.save(for: folder)
                                return "Remembered for this project: \(fact)"
                            }
                    ] : []
                    let registry = SlateAgentFactory.fullRegistry(
                        scope: scope, gate: gate, mode: { holder.mode },
                        skipPermissions: { holder.skipPermissions },
                        extraTools: self.pro.localToolRegistrations + projectMemoryTool,
                        engine: engine)
                    // Auto-checkpoint the workspace before the agent may edit it (revertable).
                    let cpLabel = String((history.last(where: { $0.role == .user })?.content ?? "turn").prefix(50))
                    Checkpoints.snapshot(scope: scope, key: id.uuidString, label: cpLabel, now: Date())
                    // System prompt = base + project rules + repo map (so the model knows the codebase).
                    let base = systemOverride ?? SlateAgentFactory.systemPrompt()
                    let discoveredRules = ProjectRules.find(in: folder)
                    let trustedRules = discoveredRules?.digest == convo.trustedProjectRulesDigest ? discoveredRules : nil
                    let withRules = ProjectRules.augment(systemPrompt: base, with: trustedRules)
                    let withMap = RepoMap.augment(systemPrompt: withRules, mapFor: folder)
                    let projectMemory = projMemOn ? ProjectMemory.load(for: folder) : nil
                    let withProjMem = ProjectMemory.augment(systemPrompt: withMap, with: projectMemory, canRemember: projMemOn)
                    let system = Skills.augment(systemPrompt: withProjMem, enabled: self.enabledSkills)
                        + (planText.map(PlanMode.agentAddendum) ?? "")
                    var session = ChatSession(system: system)
                    for m in history { session.append(m) }
                    let loop = AgentLoop(engine: engine, registry: registry,
                                         maxIterations: max(8, self.settings.agentMaxSteps), options: opts)
                    var activity = ""        // completed tool steps
                    var liveChars = 0        // chars in the in-progress turn (live "alive" signal)
                    var turnToks = 0         // engine yields ~one piece per token
                    var toolCalls = 0
                    for try await event in loop.run(session: session) {
                        switch event {
                        case .token(let t):
                            // Don't dump raw tool-call JSON; show a live progress counter so a
                            // long/slow generation never looks frozen.
                            liveChars += t.count
                            turnToks += 1
                            self.tokensPerSec = Double(liveChars / 4) / max(0.2, Date().timeIntervalSince(genStart))
                            // Human progress, not a byte counter: word estimate once
                            // there's enough to count, plain "writing…" before that.
                            let words = liveChars / 6
                            self.streamingText = activity + (words < 12
                                ? "→ writing…"
                                : "→ writing… ~\(words) words")
                        case .toolCall(let n, let args):
                            activity += Self.activityLine(n, args) + "\n"
                            liveChars = 0
                            toolCalls += 1
                            self.streamingText = activity
                        case .toolResult(_, let out):
                            activity += "   ↳ \(Self.snippet(out))\n"
                            self.streamingText = activity
                        case .finalAnswer(let a):
                            self.appendAssistant(a, to: id,
                                stats: Self.statsLine(tokens: turnToks, since: genStart, tools: toolCalls))
                        case .failed(let m): self.appendAssistant("⚠️ \(m)", to: id)
                        }
                    }
                } else {
                    var chatSystem = systemOverride ?? "You are Slate, a helpful, concise assistant."
                    if self.pro.allows(.memory), self.settings.memoryEnabled,
                       let mem = self.memory.promptBlock() {
                        chatSystem += "\n\n" + mem
                    }
                    // Offline RAG: ground the answer in the conversation's attached files.
                    if self.knowledge.hasKnowledge(for: id.uuidString),
                       let q = history.last(where: { $0.role == .user })?.content {
                        let block = RAGPrompt.systemAddendum(self.knowledge.retrieve(q, for: id.uuidString))
                        if !block.isEmpty { chatSystem += "\n\n" + block }
                    }
                    chatSystem = Skills.augment(systemPrompt: chatSystem, enabled: self.enabledSkills)
                    var msgs = [ChatMessage(role: .system, content: chatSystem)]
                    // Feed prior turns, but strip reasoning from assistant history.
                    msgs += history.map { $0.role == .assistant
                        ? ChatMessage(role: .assistant, content: ChatSession.stripThink($0.content)) : $0 }
                    var full = ""
                    var toks = 0
                    for try await chunk in await engine.generate(messages: msgs, grammar: nil, options: opts) {
                        full += chunk
                        toks += 1
                        self.tokensPerSec = Double(toks) / max(0.2, Date().timeIntervalSince(genStart))
                        self.streamingText = full   // raw, so reasoning shows live; rendered by MarkdownText
                    }
                    // Store raw (with <think>) for display.
                    self.appendAssistant(full, to: id, stats: Self.statsLine(tokens: toks, since: genStart))
                    // Learn quietly AFTER the turn (idle-gated, local only).
                    if let lastUser = history.last(where: { $0.role == .user })?.content {
                        self.scheduleMemoryExtraction(user: lastUser, answer: full,
                                                      source: convo.title)
                    }
                }
            } catch is CancellationError {
            } catch {
                // Preserve a partial answer (chat/cloud) instead of replacing it
                // with the error - a dropped connection shouldn't erase text the
                // user already saw. (Code turns stream an activity log, not an
                // answer, so keep only the error there.)
                let partial = self.streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !partial.isEmpty, kind != .code {
                    self.appendAssistant(partial + "\n\n" + self.friendly(error), to: id)
                } else {
                    self.appendAssistant(self.friendly(error), to: id)
                }
            }
            self.streamingText = ""; self.isGenerating = false; self.generatingConvoID = nil; self.tokensPerSec = 0
        }
    }

    /// A clean one-line activity label for a tool call (no raw JSON).
    static func activityLine(_ name: String, _ args: [String: String]) -> String {
        let detail = args["path"] ?? args["command"] ?? args["query"] ?? args["glob"] ?? ""
        return detail.isEmpty ? "→ \(name)" : "→ \(name)  \(detail)"
    }
    /// First line of a tool result, truncated, for the live activity log.
    static func snippet(_ s: String) -> String {
        let line = s.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }

    private func appendAssistant(_ text: String, to id: Conversation.ID, stats: String? = nil,
                                 speaker: String? = nil, speakerIndex: Int? = nil) {
        guard !text.isEmpty else { return }
        update(id) {
            $0.messages.append(ChatMessage(role: .assistant, content: text, stats: stats,
                                           speaker: speaker, speakerIndex: speakerIndex))
        }
    }

    /// Quiet per-response footer: "≈420 tok · 38 t/s · 11.2s (3 tools)".
    private static func statsLine(tokens: Int, since: Date, tools: Int = 0) -> String {
        let dt = Date().timeIntervalSince(since)
        let tps = dt > 0.2 ? Double(tokens) / dt : 0
        var s = "≈\(tokens) tok · \(Int(tps)) t/s · \(String(format: "%.1f", dt))s"
        if tools > 0 { s += " · \(tools) tool\(tools == 1 ? "" : "s")" }
        return s
    }
}

private struct SlateDataExport: Codable {
    struct Settings: Codable {
        let theme: String
        let memoryEnabled: Bool
        let cloudEnabled: Bool
        let silentModeEnabled: Bool
        let defaultTemperature: Double
        let maxTokens: Int
        let contextWindow: Int
        let defaultModelPath: String?
        let chatModelPath: String?
        let fallbackModelPath: String?
        let claudeCliPath: String?
        let claudeModel: String?
        let openCodeCliPath: String?
        let openCodeModels: [String]
        let cloudProviders: [CloudProvider]
        let thinkingEffort: String

        @MainActor
        init(_ s: AppSettings) {
            theme = s.theme.rawValue
            memoryEnabled = s.memoryEnabled
            cloudEnabled = s.cloudEnabled
            silentModeEnabled = s.silentModeEnabled
            defaultTemperature = s.defaultTemperature
            maxTokens = s.maxTokens
            contextWindow = s.contextWindow
            defaultModelPath = s.defaultModelPath
            chatModelPath = s.chatModelPath
            fallbackModelPath = s.fallbackModelPath
            claudeCliPath = s.claudeCliPath
            claudeModel = s.claudeModel
            openCodeCliPath = s.openCodeCliPath
            openCodeModels = s.openCodeModels
            cloudProviders = s.cloudProviders
            thinkingEffort = s.thinkingEffort.rawValue
        }
    }

    let exportedAt: Date
    let appVersion: String
    let conversations: [Conversation]
    let memories: [UserMemory]
    let flowHistory: [FlowHistoryEntry]
    let flowDictionary: [FlowDictionary.Entry]
    let audit: [AuditEntry]
    let settings: Settings
}
