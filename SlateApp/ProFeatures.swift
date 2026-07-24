import Foundation
import SwiftUI
import SlateCore
import SlateUI
import SlateLlama   // LlamaEngine, for building headless automation engines
#if SLATE_PRO
import SlatePro
#endif

/// The seam between the free, open-source app and the private paid layer (SlatePro).
///
/// Every Pro feature gate and every bit of licensing lifecycle the shared app code
/// touches routes through `AppModel.pro` (an `any ProFeatures`). The free build
/// injects `DefaultFreeProFeatures` (Pro capabilities → upsell, licensing inert);
/// the official/owner build injects `SlateProFeatures`, backed by SlatePro's
/// `LicenseService`.
///
/// `ProFeatures` lives in the app (not in SlatePro) on purpose: the free public
/// build must compile with no SlatePro source present, so the protocol the free
/// implementation conforms to cannot live in a module that build omits. The Pro
/// *views* stay in the app under `#if SLATE_PRO`; only the licensing *logic* is
/// private (in SlatePro).
@MainActor
protocol ProFeatures {
    /// The single entitlement question every feature gate asks.
    func allows(_ cap: SlateCapability) -> Bool
    /// Any paid entitlement (trial, pro, founder). Drives a few "is this a Pro user"
    /// UI affordances that aren't tied to one capability.
    var isPro: Bool { get }
    /// Mirror of Silent Mode onto the licensing network client (no-op when free).
    func setNetworkAccessAllowed(_ allowed: Bool)
    /// Throttled launch re-validation (no-op when free).
    func refreshIfDue() async
    /// Drop in-flight licensing state during "Delete all data" (no-op when free).
    func clearLocalStateForDataDeletion()
    /// Whether the one-time local Pro trial can still be started (false when free).
    var trialAvailable: Bool { get }
    /// Start the one-time local Pro trial (no-op when free).
    func startTrial()

    /// Roundtable is freemium: free gets a 2-model taste, Pro gets 3 seats + the
    /// closing synthesis turn. `roundtableModelCap` is the max number of seats and
    /// `roundtableSynthesisAllowed` whether the synthesis turn may run.
    var roundtableModelCap: Int { get }
    var roundtableSynthesisAllowed: Bool { get }

    /// View-factory seam (Phase 3): the app renders a Pro feature's surface through
    /// this rather than constructing the Pro view directly. Free returns an upsell
    /// placeholder; official returns the real view. When a feature's view later moves
    /// physically into SlatePro, only this factory changes, not the call site.
    func imageSurface(_ convo: Conversation) -> AnyView

    /// Image generation is the one Pro surface whose *compute* is private (Phase 3,
    /// pragmatic): only the official build links SlateDiffusion, via slate-pro's
    /// `ProImageEngine`. The free build throws — a recompiled public app can render the
    /// image UI but cannot produce a pixel (a dead button). `onStep` reports (step, total).
    func generateImage(_ job: ImageJob, onStep: @escaping @Sendable (Int, Int) -> Void) async throws -> Data
    /// Free the resident diffusion model's RAM (no-op when free).
    func unloadImageEngine() async

    /// Local tools / MCP (Pro, Phase 3 "move everything"): the whole service + Settings
    /// UI live in slate-pro. The turn loop reads `localToolRegistrations`; the app boots
    /// discovery via `rescanLocalTools`; Settings embeds `localToolsSettings(...)`. Free
    /// returns no tools, a no-op rescan, and an upsell row — the orchestration is absent.
    var localToolRegistrations: [RegisteredTool] { get }
    func rescanLocalTools(gate: any ApprovalGate) async
    func localToolsSettings(gate: any ApprovalGate,
                            requirePro: @escaping () -> Bool,
                            onViewAudit: @escaping () -> Void) -> AnyView

    /// The Automations surface (Pro, Phase: automations). Official returns the real
    /// tab (list + editor, and later the run + scheduler); free returns an upsell.
    func automationsSurface() -> AnyView
}

/// A self-contained image-generation request in public types only (no SlateDiffusion),
/// so the free build's `ProFeatures` seam carries no diffusion dependency. The official
/// build's `SlateProFeatures` unpacks it onto the private `ProImageEngine`.
struct ImageJob: Sendable {
    let modelID: String
    let modelName: String
    let arch: String            // "flux2" | "qwenImage"
    let diffusionPath: URL
    let encoderPath: URL
    let vaePath: URL
    let requiresReferenceImage: Bool
    let prompt: String
    let width: Int
    let height: Int
    let seed: Int64
    let initImagePath: String?
    let strength: Float
}

/// Thrown by the free seam when a Pro-only compute path is invoked (e.g. a recompiled
/// public build that flipped a gate). The feature UI may render, but the private engine
/// is absent — so the action fails cleanly with a clear reason instead of doing nothing.
enum ProUnavailable: LocalizedError {
    case imageGenerationRequiresPro
    var errorDescription: String? {
        switch self {
        case .imageGenerationRequiresPro: return "Image generation is a Slate Pro feature."
        }
    }
}

/// Free build: only free-tier capabilities are permitted, and every licensing
/// lifecycle call is inert — the free app has no licensing at all.
struct DefaultFreeProFeatures: ProFeatures {
    func allows(_ cap: SlateCapability) -> Bool { cap.minimumTier == .free }
    var isPro: Bool { false }
    func setNetworkAccessAllowed(_ allowed: Bool) {}
    func refreshIfDue() async {}
    func clearLocalStateForDataDeletion() {}
    var trialAvailable: Bool { false }
    func startTrial() {}
    var roundtableModelCap: Int { 2 }
    var roundtableSynthesisAllowed: Bool { false }
    // Free users get the real image composer (pick model/aspect/seed, open the Model Manager)
    // — the paywall is on Generate: `ImageSectionView.generate()` calls `requirePro(.image)`
    // and the free `generateImage` throws. A dead placeholder here made "New Image" feel broken.
    func imageSurface(_ convo: Conversation) -> AnyView { AnyView(ImageSectionView(convo: convo)) }
    func generateImage(_ job: ImageJob, onStep: @escaping @Sendable (Int, Int) -> Void) async throws -> Data {
        throw ProUnavailable.imageGenerationRequiresPro
    }
    func unloadImageEngine() async {}
    var localToolRegistrations: [RegisteredTool] { [] }
    func rescanLocalTools(gate: any ApprovalGate) async {}
    func localToolsSettings(gate: any ApprovalGate,
                            requirePro: @escaping () -> Bool,
                            onViewAudit: @escaping () -> Void) -> AnyView {
        AnyView(ProLocalToolsUpsell())
    }
    func automationsSurface() -> AnyView { AnyView(ProFeaturePlaceholder(feature: .automations)) }
}

/// The free build's stand-in for the Local tools · MCP settings section: a single row
/// that opens the upsell. The real service + UI ship only in slate-pro.
private struct ProLocalToolsUpsell: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Section("Local tools · MCP") {
            Button {
                model.proUpsell = .localTools
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: ProFeature.localTools.icon).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ProFeature.localTools.title).font(.callout.weight(.medium))
                        Text(ProFeature.localTools.blurb).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Pro").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

#if SLATE_PRO
/// Official/owner build: the seam is backed by SlatePro's private `LicenseService`.
struct SlateProFeatures: ProFeatures {
    let license: LicenseService
    /// The private, resident diffusion driver. Only this build links SlateDiffusion.
    let imageEngine: ProImageEngine
    /// The private local-tools/MCP service — its whole orchestration lives in slate-pro.
    let localTools: LocalMCPService
    /// The private automation store (definitions + run history), shared with the scheduler.
    let automations: AutomationStore
    /// The shared automation runner + the in-app scheduler that fires due automations.
    let automationRunner: AutomationRunner
    let automationScheduler: AutomationScheduler
    func allows(_ cap: SlateCapability) -> Bool { license.entitlement.allows(cap) }
    var isPro: Bool { license.isPro }
    func setNetworkAccessAllowed(_ allowed: Bool) { license.networkAccessAllowed = allowed }
    func refreshIfDue() async { await license.refreshIfDue() }
    func clearLocalStateForDataDeletion() { license.clearLocalStateForDataDeletion() }
    var trialAvailable: Bool { license.trialAvailable }
    func startTrial() { license.startTrial() }
    var roundtableModelCap: Int { license.isPro ? .max : 2 }
    var roundtableSynthesisAllowed: Bool { license.isPro }
    func imageSurface(_ convo: Conversation) -> AnyView { AnyView(ImageSectionView(convo: convo)) }
    func generateImage(_ job: ImageJob, onStep: @escaping @Sendable (Int, Int) -> Void) async throws -> Data {
        try await imageEngine.generate(modelID: job.modelID, modelName: job.modelName, arch: job.arch,
                                       diffusionPath: job.diffusionPath, encoderPath: job.encoderPath, vaePath: job.vaePath,
                                       requiresReferenceImage: job.requiresReferenceImage,
                                       prompt: job.prompt, width: job.width, height: job.height, seed: job.seed,
                                       initImagePath: job.initImagePath, strength: job.strength, onStep: onStep)
    }
    func unloadImageEngine() async { await imageEngine.unload() }
    var localToolRegistrations: [RegisteredTool] { localTools.registeredTools }
    func rescanLocalTools(gate: any ApprovalGate) async { await localTools.rescan(gate: gate) }
    func localToolsSettings(gate: any ApprovalGate,
                            requirePro: @escaping () -> Bool,
                            onViewAudit: @escaping () -> Void) -> AnyView {
        AnyView(ProLocalToolsSettings(service: localTools, gate: gate,
                                      requirePro: requirePro, onViewAudit: onViewAudit))
    }
    func automationsSurface() -> AnyView { AnyView(AutomationsView(store: automations, runner: automationRunner)) }
}

/// The host contract slate-pro's Pro feature views call back through (Phase 3). Only
/// the official build links slate-pro, so this conformance is `#if SLATE_PRO`. Every
/// member is a narrowed view onto app state — never the app's fat types.
extension AppModel: ProHost {
    func requireCapability(_ cap: SlateCapability) -> Bool {
        if pro.allows(cap) { return true }
        if let feature = ProFeature.allCases.first(where: { $0.capability == cap }) { proUpsell = feature }
        return false
    }
    var quickEnabled: Bool { settings.quickEnabled }
    var palette: SlatePalette { settings.palette }
    var themeColorScheme: ColorScheme? { settings.theme.colorScheme }
    // `isModelLoaded` and `quickGenerate(system:user:imagePath:)` already exist on AppModel.

    var availableModels: [AutomationModelOption] {
        var out = models.map { AutomationModelOption(ref: $0.url.path, label: $0.name, isLocal: true) }
        out += settings.cloudProviders.filter { hasCloudKey($0) }
            .map { AutomationModelOption(ref: "cloud:\($0.id)", label: $0.name, isLocal: false) }
        out += settings.openCodeModels
            .map { AutomationModelOption(ref: "opencode:\($0)", label: "OpenCode · \($0)", isLocal: false) }
        return out
    }

    func makeAutomationEngine(modelRef: String) async throws -> any LLMEngine {
        if modelRef.hasPrefix("cloud:") {
            let id = String(modelRef.dropFirst("cloud:".count))
            guard let p = settings.cloudProviders.first(where: { $0.id == id }) else {
                throw ProHostError.modelUnavailable("That cloud model is no longer configured.")
            }
            return OpenAICompatibleEngine(provider: p, apiKey: KeychainStore.get(account: p.id))
        }
        if modelRef.hasPrefix("opencode:") {
            let mid = String(modelRef.dropFirst("opencode:".count))
            guard let engine = OpenCodeEngine(modelID: mid, cliPath: settings.openCodeCliPath) else {
                throw ProHostError.modelUnavailable("OpenCode is not available.")
            }
            return engine
        }
        // Local GGUF: build a fresh engine off the main actor (a cold load is heavy).
        let url = URL(fileURLWithPath: modelRef)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProHostError.modelUnavailable("The model file was moved or deleted.")
        }
        let mmproj = ModelCatalog.mmproj(for: url).flatMap { isLoadableGGUF($0) ? $0.path : nil }
        let ctx = UInt32(settings.contextWindow)
        let path = url.path
        return try await Task.detached { try LlamaEngine(modelPath: path, mmprojPath: mmproj, nCtx: ctx) }.value
    }

    func automationWebTools(enabled: Bool) -> [RegisteredTool] {
        guard enabled, !settings.silentModeEnabled, webSearchConfig.isConfigured else { return [] }
        return WebSearch.tools(config: webSearchConfig, session: webSearchSession)
    }

    var isIdleForRun: Bool {
        !isGenerating && !loadingModel && !roundtableActive && !voiceGenerating && !automationRunning
    }

    /// Start the in-app automation scheduler at launch (official builds only). The
    /// scheduler fires due automations while Slate runs and schedules a best-effort wake.
    func startAutomationScheduler() {
        (pro as? SlateProFeatures)?.automationScheduler.start(host: self)
    }
}
#endif

/// The locked-feature surface shown in the free build where a Pro view would be.
/// Tapping "Unlock" opens the upsell sheet for that feature. Phase 3: as each Pro
/// view moves into SlatePro, the free build renders this instead, so no Pro feature
/// code remains in the public repo.
struct ProFeaturePlaceholder: View {
    @Environment(AppModel.self) private var model
    let feature: ProFeature
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: feature.icon).font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(feature.title).font(.title3.weight(.semibold))
            Text(feature.blurb).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            Button("Unlock with Slate Pro") { model.proUpsell = feature }
                .buttonStyle(PaletteProminentButtonStyle()).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Marketing constants shown by the free-facing upsell (`ProUpsellView`), which must
/// compile without SlatePro. These mirror SlatePro's `LicenseConfig` display values;
/// the authoritative copies used by licensing logic live there.
enum ProInfo {
    static let buyProURL = URL(string: "https://slate-app.org/pricing")
    static let deviceLimit = 3
    static let trialDays = 14
}
