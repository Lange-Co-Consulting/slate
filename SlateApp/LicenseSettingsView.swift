import SwiftUI
import SlateUI
import AppKit
import SlateCore
import UniformTypeIdentifiers
#if SLATE_PRO
import SlatePro
#endif

/// A Pro-only capability. Drives the upsell sheet's headline and the "what you
/// get" list, and identifies which gate the user just hit.
enum ProFeature: String, Identifiable, CaseIterable {
    case flow, code, agents, image, voice, memory, compare, quickActions, transcriptionPro, localTools
    var id: String { rawValue }

    var capability: SlateCapability {
        switch self {
        case .flow: return .flow
        case .code: return .codeEdits
        case .agents: return .modelCompare
        case .image: return .imageGeneration
        case .voice: return .voiceConversation
        case .memory: return .memory
        case .compare: return .modelCompare
        case .quickActions: return .quickActions
        case .transcriptionPro: return .transcriptionPro
        case .localTools: return .localTools
        }
    }

    var title: String {
        switch self {
        case .flow:    return "Flow - system-wide dictation"
        case .code:    return "Agentic coding - Edits & Auto"
        case .agents:  return "Roundtable"
        case .image:   return "Local image generation"
        case .voice:   return "Voice conversations"
        case .memory:  return "Memory across chats"
        case .compare: return "Compare models side by side"
        case .quickActions: return "Slate Quick actions"
        case .transcriptionPro: return "Transcribe Pro"
        case .localTools: return "Local tools & MCP"
        }
    }
    var blurb: String {
        switch self {
        case .flow:    return "Dictate into any app on your Mac with one hotkey, cleaned up by a local model."
        case .code:    return "Let the coding agent write and edit files directly - not just read them."
        case .agents:  return "Let two or three models discuss a task in a structured, attributed roundtable."
        case .image:   return "Generate images on-device with your own local image model."
        case .voice:   return "Talk to Slate hands-free, fully offline."
        case .memory:  return "Slate remembers durable facts about you and uses them in later chats."
        case .compare: return "Run one prompt across two models at once and compare the answers."
        case .quickActions: return "Rewrite, transform and replace selected text in any Mac app with one action."
        case .transcriptionPro: return "Queue recordings and label speakers locally for meetings, interviews and podcasts."
        case .localTools: return "Connect local stdio tools while Slate blocks their network access and asks before every run."
        }
    }
    var icon: String {
        switch self {
        case .flow:    return "waveform"
        case .code:    return "chevron.left.forwardslash.chevron.right"
        case .agents:  return "person.3.sequence.fill"
        case .image:   return "photo"
        case .voice:   return "mic"
        case .memory:  return "brain.head.profile"
        case .compare: return "square.split.2x1"
        case .quickActions: return "bolt"
        case .transcriptionPro: return "person.2.wave.2"
        case .localTools: return "wrench.and.screwdriver"
        }
    }

    /// The full Pro list shown on the upsell sheet, in pricing-page order.
    static let proList: [ProFeature] = [.flow, .code, .agents, .image, .voice, .memory, .compare, .quickActions, .transcriptionPro, .localTools]
}

// MARK: - Settings › Licence

#if SLATE_PRO
/// The "Licence" tab of Settings: shows the current entitlement and, depending on
/// state, either the activation form (Free) or the active-licence management (Pro).
/// Pro-only — compiled solely into official/owner builds. The free build shows
/// `FreeLicenseSection` instead.
struct LicenseSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var keyInput = ""
    @State private var importingOfflineLicense = false

    private var license: LicenseService { model.license }

    var body: some View {
        Section {
            HStack(spacing: 14) {
                SlateMark(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(license.statusSummary).font(.callout.weight(.semibold))
                    Text(license.isPro
                         ? "All Pro features are unlocked on this Mac."
                         : "Slate is running in Free mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if license.isPro {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2).foregroundStyle(.secondary)
                }
            }
        }

        if license.isPro {
            activeSection
        } else {
            activateSection
        }

        if model.settings.silentModeEnabled {
            Section {
                Label("Silent Mode blocks online activation, re-checks and deactivation. Offline licence files and the local trial still work.",
                      systemImage: "network.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }


        Section("Offline activation") {
            VStack(alignment: .leading, spacing: 8) {
                Text("For Macs that never connect to the internet, import a signed Slate licence file. Verification happens entirely on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Import licence file…") { importingOfflineLicense = true }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(license.installationCode, forType: .string)
                    } label: {
                        Label("Copy installation code", systemImage: "doc.on.doc")
                    }
                }
                if LicenseConfig.offlineLicensePublicKey.isEmpty {
                    Label("Offline licence verification needs the production public key before release.", systemImage: "wrench.and.screwdriver")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .fileImporter(
            isPresented: $importingOfflineLicense,
            allowedContentTypes: [UTType(filenameExtension: "slatelicense") ?? .json]
        ) { result in
            switch result {
            case .success(let url):
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let size = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard size.isRegularFile == true, (size.fileSize ?? 0) <= 256 * 1_024 else {
                        license.lastError = "The selected licence file is not a valid small licence document."
                        return
                    }
                    license.importOfflineLicense(data: try Data(contentsOf: url))
                }
                catch { license.lastError = "The selected licence file couldn’t be read." }
            case .failure:
                break
            }
        }

        Section {
            Text("Slate Pro is available as a monthly or yearly plan, or as a one-time Lifetime purchase. Our Merchant of Record handles checkout and VAT. Your licence key is stored in the macOS Keychain and is sent only to the licence server to activate and re-check this Mac - never included in a settings export.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // Free → activate
    @ViewBuilder private var activateSection: some View {
        Section("Activate a licence") {
            HStack(spacing: 8) {
                TextField("Paste your licence key", text: $keyInput)
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                    .onSubmit(activate)
                    .disabled(license.busy || model.settings.silentModeEnabled)
                Button(action: activate) {
                    if license.busy { ProgressView().controlSize(.small) }
                    else { Text("Activate") }
                }
                .disabled(model.settings.silentModeEnabled || license.busy || keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let err = license.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !LicenseConfig.isConfigured {
                Text("Purchases open at launch. You’ll get a key by email - paste it here and Pro unlocks.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        Section {
            if license.trialAvailable {
                Button("Start a \(LicenseConfig.trialDays)-day Pro trial") { license.startTrial() }
            }
            Button("View Slate Pro plans…") { openBuy() }
            Text("One licence activates on up to \(LicenseConfig.deviceLimit) Macs.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // Pro → manage
    @ViewBuilder private var activeSection: some View {
        Section("This Mac") {
            if case .trial(let d) = license.entitlement {
                LabeledContent("Trial", value: "\(d) day\(d == 1 ? "" : "s") left")
                Button("View Slate Pro plans…") { openBuy() }
                HStack(spacing: 8) {
                    TextField("Paste your licence key", text: $keyInput)
                        .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                        .onSubmit(activate).disabled(license.busy || model.settings.silentModeEnabled)
                    Button("Activate", action: activate)
                        .disabled(model.settings.silentModeEnabled || license.busy || keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let err = license.lastError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            } else {
                LabeledContent("Status", value: license.hasOfflineLicense ? "Offline activated" : "Activated")
                if license.hasOfflineLicense {
                    Button("Remove offline licence", role: .destructive) {
                        license.removeOfflineLicense()
                    }
                    Text("Removing the file-based licence only affects this Mac and does not contact a server.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Deactivate this Mac", role: .destructive) {
                        Task { await license.deactivate() }
                    }
                    .disabled(model.settings.silentModeEnabled)
                    Text("Deactivating frees a seat so you can move the licence to another Mac.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func activate() {
        let key = keyInput
        Task { await license.activate(key: key); if license.isPro { keyInput = "" } }
    }
    private func openBuy() {
        if let u = LicenseConfig.buyProURL { NSWorkspace.shared.open(u) }
    }
}
#endif  // SLATE_PRO

// MARK: - Free licence placeholder (Free users see this in place of activation UI)

/// The Licence tab in the free/open-source build: no activation, just a pointer to
/// Slate Pro. The real activation UI (`LicenseSettingsSection`) is Pro-only.
struct FreeLicenseSection: View {
    var body: some View {
        Section {
            HStack(spacing: 14) {
                SlateMark(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Slate is free and open source").font(.callout.weight(.semibold))
                    Text("Slate Pro unlocks the paid features on top of it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        Section {
            Button("View Slate Pro plans…") {
                if let u = ProInfo.buyProURL { NSWorkspace.shared.open(u) }
            }
        }
    }
}

// MARK: - Pro upsell sheet (shown when a Free user hits a gate)

struct ProUpsellView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let feature: ProFeature

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Unlock Slate Pro", system: "sparkles") { dismiss() }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // The feature they just tried.
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: feature.icon)
                            .font(.title2).frame(width: 34, height: 34)
                            .background(Circle().fill(.quinary))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(feature.title).font(.headline)
                            Text(feature.blurb).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    Text("Everything in Slate Pro").font(.callout.weight(.semibold))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ProFeature.proList) { f in
                            HStack(spacing: 9) {
                                Image(systemName: f == feature ? "checkmark.circle.fill" : "checkmark.circle")
                                    .foregroundStyle(f == feature ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                Text(f.title).font(.callout)
                                    .foregroundStyle(f == feature ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            }
                        }
                    }

                    Text("Monthly, yearly or Lifetime · use on up to \(ProInfo.deviceLimit) Macs · VAT handled at checkout.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }

            Divider().opacity(0.4)

            // Actions
            VStack(spacing: 8) {
                Button { openBuy() } label: {
                    Text("View Slate Pro plans").frame(maxWidth: .infinity)
                }
                .buttonStyle(PaletteProminentButtonStyle()).controlSize(.large)

                HStack(spacing: 10) {
                    if model.pro.trialAvailable {
                        Button("Start free trial") {
                            model.pro.startTrial(); dismiss()
                        }
                    }
                    Button("Enter licence key") { model.openLicenseSettings() }
                    Spacer()
                    Button("Not now") { dismiss() }
                }
                .font(.callout)
            }
            .padding(16)
        }
        .frame(width: 460, height: 560)
    }

    private func openBuy() {
        if let u = ProInfo.buyProURL { NSWorkspace.shared.open(u) }
    }
}
