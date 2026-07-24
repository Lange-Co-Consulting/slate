import SwiftUI
import SlateUI
import AppKit
import UniformTypeIdentifiers
import SlateCore

/// Settings organized into a sidebar of categories, like macOS System Settings:
/// a narrow list of tabs on the left, the selected tab's grouped Form on the
/// right. The search field at the top of the sidebar filters the category list.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: SettingsTab = .general
    @State private var search = ""
    @State private var showModels = false
    @State private var showAudit = false
    @State private var showNotices = false
    @State private var confirmReset = false
    @State private var confirmDelete = false
    @State private var skillImportNote: String?
    @State private var operationMessage: String?
    // Add-cloud-model form
    @State private var newPreset = "openai"
    @State private var newName = "OpenAI"
    @State private var newBaseURL = "https://api.openai.com/v1"
    @State private var newModel = "gpt-4o"
    @State private var newKey = ""
    @State private var webSearchKeyDraft = ""
    @State private var openCodeModels: [String] = []
    @State private var selectedOpenCodeModel = ""
    @State private var openCodeStatus: String?
    @State private var discoveringOpenCode = false
    // Save-a-color-preset prompt
    @State private var showingSavePreset = false
    @State private var newPresetName = ""
    @State private var projectMemories: [ProjectMemorySummary] = []

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, license, dictation, memory, models, skills, hardware, network, remote, cloud, security, privacy, diagnostics, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general:   return "General"
            case .license:   return "Licence"
            case .dictation: return "Dictation"
            case .memory:    return "Memory"
            case .models:    return "Models"
            case .skills:    return "Skills"
            case .hardware:  return "Hardware"
            case .network:   return "Network Access"
            case .remote:    return "Remote"
            case .cloud:     return "Cloud"
            case .security:  return "Security"
            case .privacy:   return "Privacy & Data"
            case .diagnostics: return "Bug Reports"
            case .about:     return "About"
            }
        }
        var icon: String {
            switch self {
            case .general:   return "gearshape"
            case .license:   return "checkmark.seal"
            case .dictation: return "mic"
            case .memory:    return "brain.head.profile"
            case .models:    return "cpu"
            case .skills:    return "puzzlepiece.extension"
            case .hardware:  return "memorychip"
            case .network:   return "network"
            case .remote:    return "iphone.and.arrow.forward"
            case .cloud:     return "cloud"
            case .security:  return "lock.shield"
            case .privacy:   return "lock.shield"
            case .diagnostics: return "ladybug"
            case .about:     return "info.circle"
            }
        }
        var keywords: String {
            switch self {
            case .general:   return "general appearance theme light dark custom colors colour canvas background accent surface panel generation temperature tokens context window language update"
            case .license:   return "licence license pro upgrade unlock activate key buy purchase trial founder plan"
            case .dictation: return "dictation flow microphone language hotkey history dictionary voice"
            case .memory:    return "memory remember privacy facts"
            case .models:    return "models download coding chat fallback launch memory ram safety unload pressure autoload startup"
            case .skills:    return "skills instructions prompts packs offline capabilities agents rules"
            case .hardware:  return "hardware mac chip cpu gpu ram memory apple silicon"
            case .network:   return "network internet offline silent mode block downloads updates licence license cloud privacy air gap"
            case .remote:    return "remote iphone phone pairing qr code lan wifi companion app slate remote"
            case .cloud:     return "cloud claude code cli anthropic openai opencode api key provider model connect"
            case .security:  return "security permissions approval auto autopilot skip dangerous shell delete commands"
            case .privacy:   return "privacy data export import audit reset delete"
            case .diagnostics: return "bug report crash diagnostics submit anonymous"
            case .about:     return "about version licenses acknowledgements credits attribution"
            }
        }
    }

    private var visibleTabs: [SettingsTab] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SettingsTab.allCases }
        return SettingsTab.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.keywords.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 208)
            Divider()
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Deep-link (e.g. the Pro upsell's "Enter licence key") opens a specific tab.
        .onAppear {
            if let target = model.pendingSettingsTab,
               let t = SettingsTab(rawValue: target) {
                tab = t
            }
            model.pendingSettingsTab = nil
        }
        // If Settings is ALREADY open when a deep-link fires (e.g. an upsell shown from
        // inside Settings), .onAppear has already run — switch tabs on the change too.
        .onChange(of: model.pendingSettingsTab) { _, target in
            guard let target, let t = SettingsTab(rawValue: target) else { return }
            tab = t
            model.pendingSettingsTab = nil
        }
        // ColorPicker uses AppKit's process-wide NSColorPanel. Without an
        // explicit close it can outlive this sheet and float over the app.
        .onChange(of: tab) { old, new in
            if old == .general && new != .general { closePalettePicker() }
        }
        .onDisappear { closePalettePicker() }
        .sheet(isPresented: $showAudit) { AuditLogView() }
        .sheet(isPresented: $showModels) { ModelsView().environment(model) }
        .sheet(isPresented: $showNotices) {
            ThirdPartyNoticesView(text: noticesText)
        }
        .alert("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset settings", role: .destructive) {
                model.settings.resetToDefaults()
                model.synchronizeNetworkAccess()
                operationMessage = "Settings were reset to their defaults."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets appearance, model choices, cloud access and generation defaults. Conversations, memories, downloaded models and licence data are kept.")
        }
        .alert("Delete all Slate data?", isPresented: $confirmDelete) {
            Button("Delete permanently", role: .destructive) {
                do { try model.deleteAllUserData(); operationMessage = "All personal Slate data was deleted." }
                catch { operationMessage = "Deletion failed: \(error.localizedDescription)" }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Export your data first if you may need it later.")
        }
        .alert("Slate", isPresented: Binding(get: { operationMessage != nil },
                                              set: { if !$0 { operationMessage = nil } })) {
            Button("OK") { operationMessage = nil }
        } message: { Text(operationMessage ?? "") }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain).font(.callout)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear settings search")
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Capsule().fill(.quinary))
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)

            List(selection: $tab) {
                ForEach(visibleTabs) { t in
                    Label(t.title, systemImage: t.icon).tag(t)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.quaternary.opacity(0.12))
        .onChange(of: search) { _, _ in
            if !visibleTabs.contains(tab), let first = visibleTabs.first { tab = first }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        Form {
            switch tab {
            case .general:   generalTab
            case .license:
                #if SLATE_PRO
                LicenseSettingsSection()
                #else
                FreeLicenseSection()
                #endif
            case .dictation: FlowSettingsSection()
            case .memory:    memoryTab
            case .models:    modelsTab
            case .skills:    skillsTab
            case .hardware:  hardwareTab
            case .network:   networkTab
            case .remote:    RemoteSettingsView()
            case .cloud:     cloudTab
            case .security:  securityTab
            case .privacy:   privacyTab
            case .diagnostics: diagnosticsTab
            case .about:     aboutTab
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var diagnosticsTab: some View {
        @Bindable var settings = model.settings
        Section("Bug Reports") {
            Toggle("Watch for crashes on launch", isOn: $settings.crashReportsEnabled)
            Text("If Slate crashes, it offers to send a fully anonymous report - app and OS version and the sanitized crash signature only. No conversations, files, paths or account names are ever included.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        Section("Detected crashes") {
            if model.crashReports.isEmpty {
                Label("No crashes detected.", systemImage: "checkmark.seal")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.crashReports) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(r.summary).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text(r.date, style: .date).font(.caption2).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Button("Email report") { emailReport(subject: "Slate crash - \(r.summary)", body: r.body) }
                            Button("Copy report") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(r.body, forType: .string)
                                operationMessage = "Anonymous report copied to the clipboard."
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        Section {
            Button("Report a bug…") {
                emailReport(subject: "Slate bug report",
                            body: "Describe what happened:\n\n\n---\nApp \(model.updater.currentVersion) (\(model.updater.currentBuild)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            }
            Text("Opens a pre-filled email to the developer. Nothing is sent automatically.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func emailReport(subject: String, body: String) {
        // mailto query encoding: keep &, +, =, ? out so they don't break the URL.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        // Percent-encoding can ~3× the length; cap the RAW body so the whole
        // mailto URL stays within what mail clients honor (~2 KB), truncating on
        // a char boundary (never mid-escape). The full text is on "Copy report".
        let rawBudget = 1200
        let safeBody = body.count > rawBudget
            ? String(body.prefix(rawBudget)) + "\n…(truncated - use “Copy report” for the full text)"
            : body
        if let url = URL(string: "mailto:\(AppModel.supportEmail)?subject=\(enc(subject))&body=\(enc(safeBody))") {
            NSWorkspace.shared.open(url)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            operationMessage = "Couldn't open Mail - the report was copied to the clipboard. Send it to \(AppModel.supportEmail)."
        }
    }

    @ViewBuilder private var aboutTab: some View {
        Section {
            HStack(spacing: 14) {
                SlateMark(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Slate").font(.title2.bold())
                    Text("Version \(model.updater.currentVersion) (\(model.updater.currentBuild)) · \(buildChannel.capitalized)")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Local-first chat, coding, Roundtable, images and dictation on your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("© 2026 Lange & Co. Consulting")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        Section("Acknowledgements") {
            acknowledgement("NVIDIA Parakeet-TDT 0.6B", "Optional Flow speech model; downloaded or imported by the user. © NVIDIA - CC-BY-4.0.")
            acknowledgement("Supertonic", "Optional Flow neural voices; downloaded or imported by the user. © Supertone · OpenRAIL-M.")
            acknowledgement("Silero VAD", "Optional Flow voice-activity model; downloaded or imported by the user. MIT.")
            acknowledgement("Qwen3-TTS + MLX", "Optional premium voices (Apache-2.0 model, downloaded by the user) on Apple's MLX runtime (MIT).")
            acknowledgement("llama.cpp", "Local language-model inference. MIT.")
            acknowledgement("stable-diffusion.cpp", "Local image generation. MIT.")
            acknowledgement("FluidAudio", "On-device speech stack (CoreML). Apache-2.0.")
            acknowledgement("Curated chat & image models", "Provider-hosted optional downloads. Slate shows each model card and licence before download.")
            Text("Slate ships no model weights. Chat, image and optional Flow models are imported or downloaded by the user and carry their own licenses.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Open full third-party notices…") {
                showNotices = true
            }
            .disabled(noticesURL == nil)
        }
    }

    private var buildChannel: String {
        (Bundle.main.object(forInfoDictionaryKey: "SlateBuildChannel") as? String) ?? "development"
    }

    private func acknowledgement(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.callout.weight(.medium))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    /// THIRD_PARTY_NOTICES.md - bundled in the packaged app (Resources), else the
    /// repo copy for dev runs.
    private var noticesURL: URL? {
        if let inBundle = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
            return inBundle
        }
        let repo = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Projects/Slate/THIRD_PARTY_NOTICES.md")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    private var noticesText: String {
        guard let url = noticesURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Third-party notices are unavailable in this build."
        }
        return text
    }

    @ViewBuilder private var generalTab: some View {
        @Bindable var settings = model.settings
        Section("Appearance") {
            Picker("Theme", selection: $settings.theme) {
                ForEach(AppSettings.Theme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Custom color palette", isOn: $settings.customColorsEnabled)
            if settings.customColorsEnabled {
                presetGallery
                palettePicker("Canvas", detail: "The ambient background tint behind every window.",
                              keyPath: \.canvasColorHex)
                palettePicker("Panels", detail: "Sidebar, cards and secondary surfaces.",
                              keyPath: \.surfaceColorHex)
                palettePicker("Accent", detail: "Selections, focus, progress and active controls.",
                              keyPath: \.accentColorHex)

                HStack(spacing: 10) {
                    PalettePreview(palette: settings.palette)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live preview").font(.callout.weight(.medium))
                        Text("Colors adapt to Light and Dark to preserve contrast.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore Slate") { settings.resetPalette() }
                }
                .padding(.vertical, 4)
            } else {
                Text("Uses Slate's original monochrome controls and blue-violet-teal aurora.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if settings.customColorsEnabled {
            Section("Chat bubbles") {
                palettePicker("Your messages", detail: "The color of messages you send.",
                              keyPath: \.userBubbleColorHex)
                palettePicker("Slate messages", detail: "The color of local AI responses.",
                              keyPath: \.assistantBubbleColorHex)
                palettePicker("Tool activity", detail: "Commands, edits and local tool output in Code.",
                              keyPath: \.toolBubbleColorHex)
                HStack(spacing: 10) {
                    ChatPalettePreview(palette: settings.palette)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Readable by design").font(.callout.weight(.medium))
                        Text("Slate automatically picks light or dark message text for every bubble color.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        Section("Language") {
            Picker("Tutorial & setup language", selection: $settings.interfaceLanguage) {
                Text("System").tag("system")
                Text("English").tag("en")
                Text("Deutsch").tag("de")
            }
            Text("Language of the welcome tour and the hardware setup popup.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Replay welcome & hardware setup") {
                settings.onboardingCompleted = false
                settings.hardwareProfileCompleted = false
                model.showSettings = false   // close Settings so the popups can show
            }
            Toggle("Show Slate in the menu bar", isOn: $settings.menuBarEnabled)
            Toggle("Full-width chat", isOn: $settings.fullWidthChat)
            Text("Let the chat transcript and composer span the whole pane instead of a centered reading column.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        Section("Slate Quick") {
            Toggle("Enable global Quick panel", isOn: $settings.quickEnabled)
            LabeledContent("Shortcut", value: "⌥ Space")
            Text("Ask a local model from any app, include selected text or a screenshot, and copy the result. Quick never uses cloud connectors.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        Section("Software Update") {
            LabeledContent("Current version",
                           value: "\(model.updater.currentVersion) (\(model.updater.currentBuild))")
            Toggle("Check for updates on launch", isOn: $settings.autoCheckUpdates)
            HStack {
                Button("Check now") { Task { await model.updater.check(manual: true) } }
                    .disabled(settings.silentModeEnabled)
                Spacer()
                updateStatus
            }
            DisclosureGroup("Advanced") {
                TextField("Update feed URL", text: Binding(
                    get: { settings.updateFeedURL ?? "" },
                    set: { settings.updateFeedURL = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).font(.callout)
                Text("Optional override for Slate's signed \(buildChannel) update feed. Only manifests signed by the key pinned in this app are accepted.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        Section("Generation defaults") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Temperature")
                    InfoHint(text: "Controls how random the model's output is. **0-0.3** = focused and deterministic - best for code and factual edits. **0.7** = the balanced default for most tasks. **1.0+** = creative and varied - good for brainstorming and prose.")
                    Spacer()
                    Text(String(format: "%.2f", settings.defaultTemperature))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.defaultTemperature, in: 0...1.5)
                Text("0-0.3 precise & repeatable (code, edits) · 0.7 balanced · 1.0+ creative & varied")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Stepper("Max tokens: \(settings.maxTokens)", value: $settings.maxTokens, in: 256...16384, step: 256)
            Stepper("Agent steps: \(settings.agentMaxSteps)", value: $settings.agentMaxSteps, in: 8...200, step: 4)
            Text("How many tool-call steps a Code task may take before it pauses. Higher lets big /goal builds finish; it pauses (never loses work) at the limit so a stuck run can't loop forever.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Longest single reply. Big file writes in Code mode need headroom - 8k+ recommended.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        Section("Context window") {
            Picker("Window", selection: $settings.contextWindow) {
                ForEach(AppSettings.contextWindowOptions(trainedMax: model.activeTrainedContext, current: settings.contextWindow), id: \.self) { n in
                    Text(TokenEstimate.short(n) + " tokens").tag(n)
                }
            }
            .onChange(of: settings.contextWindow) { _, _ in model.reloadActiveModel() }
            if model.activeTrainedContext > 0 {
                LabeledContent("Model supports", value: TokenEstimate.short(model.activeTrainedContext) + " tokens")
                    .foregroundStyle(.secondary)
            }
            Text("Bigger windows keep more of the session in context but use much more RAM (KV cache). Clamped to the model's max. Changing this reloads the model.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func palettePicker(_ title: String, detail: String,
                               keyPath: ReferenceWritableKeyPath<AppSettings, String>) -> some View {
        ColorPicker(selection: Binding(
            get: { Color(slateHex: model.settings[keyPath: keyPath]) },
            set: { if let hex = $0.slateHex { model.settings[keyPath: keyPath] = hex } }),
                    supportsOpacity: false) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func closePalettePicker() {
        guard NSColorPanel.shared.isVisible else { return }
        NSColorPanel.shared.close()
    }

    // MARK: color presets

    /// One-tap palettes: curated built-ins + the user's saved customs + a Save chip.
    /// Applying a preset sets all six colors at once (canvas/panels/accent + the
    /// three message bubbles), so the whole app - including message colors - changes
    /// together and stays readable.
    @ViewBuilder private var presetGallery: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Presets").font(.callout.weight(.medium))
                Spacer()
                Button { newPresetName = ""; showingSavePreset = true } label: {
                    Label("Save current…", systemImage: "plus.circle").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Save the current colors as a custom preset")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PalettePreset.builtins) { presetChip($0, deletable: false) }
                    ForEach(model.settings.customPalettePresets) { presetChip($0, deletable: true) }
                }
                .padding(.vertical, 2).padding(.horizontal, 1)
            }
        }
        .padding(.vertical, 2)
        .alert("Save color preset", isPresented: $showingSavePreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") { model.settings.saveCurrentAsPreset(named: newPresetName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save the current canvas, panel, accent and message colors as a reusable preset.")
        }
    }

    private func presetChip(_ preset: PalettePreset, deletable: Bool) -> some View {
        let active = model.settings.matchesPreset(preset)
        return VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(slateHex: preset.canvasHex))
                HStack(spacing: 4) {
                    Circle().fill(Color(slateHex: preset.accentHex)).frame(width: 11, height: 11)
                    Circle().fill(Color(slateHex: preset.userBubbleHex)).frame(width: 11, height: 11)
                }
            }
            .frame(width: 56, height: 38)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.14),
                                  lineWidth: active ? 2.5 : 1))
            .overlay(alignment: .topTrailing) {
                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.white, Color.accentColor).padding(2)
                }
            }
            Text(preset.name).font(.caption2).lineLimit(1).frame(width: 60)
                .foregroundStyle(active ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { model.settings.applyPreset(preset) } }
        .contextMenu {
            if deletable {
                Button("Delete Preset", role: .destructive) { model.settings.deleteCustomPreset(preset.id) }
            }
        }
        .help(deletable ? "Apply “\(preset.name)” (right-click to delete)" : "Apply the \(preset.name) palette")
    }


    @ViewBuilder private var memoryTab: some View {
        @Bindable var settings = model.settings
        Section("Memory") {
            Toggle(isOn: Binding(
                get: { settings.memoryEnabled && model.pro.allows(.memory) },
                set: { enabled in
                    if enabled, !model.requirePro(.memory) { settings.memoryEnabled = false }
                    else { settings.memoryEnabled = enabled }
                })) {
                HStack {
                    Text("Remember things about you")
                    InfoHint(text: "After local chat turns Slate quietly extracts durable facts (preferences, projects, personal context) and uses them in future chat and voice conversations. Fully offline - stored in one editable file, capped at 100 entries.")
                }
            }
            .accessibilityLabel("Remember things about you")
            if model.memory.entries.isEmpty {
                Text("Nothing remembered yet - memories appear here after chats.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.memory.entries.reversed()) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { m.enabled },
                            set: { model.setMemoryEnabled(m, enabled: $0) }))
                            .labelsHidden().controlSize(.mini)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.text).font(.callout)
                                .foregroundStyle(m.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            if let src = m.source, !src.isEmpty {
                                Text(src).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 6)
                        Button { model.deleteMemory(m.id) } label: {
                            Image(systemName: "trash").font(.caption)
                        }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .help("Forget this")
                    }
                }
                Button("Forget everything", role: .destructive) { model.forgetAllMemories() }
                    .font(.callout)
            }
        }
        Section("Project memory") {
            Text("What Slate has learned about your code projects - build/test commands, conventions, gotchas. Stored outside your repos; the code agent reuses it in future sessions.")
                .font(.caption).foregroundStyle(.secondary)
            if projectMemories.isEmpty {
                Text("Nothing learned yet - facts appear here as you work in Code sessions.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(projectMemories) { proj in
                    DisclosureGroup {
                        ForEach(proj.facts, id: \.text) { fact in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(fact.text).font(.callout)
                                Spacer(minLength: 6)
                                Button {
                                    ProjectMemory.removeFact(text: fact.text, folderPath: proj.folderPath)
                                    reloadProjectMemories()
                                } label: { Image(systemName: "trash").font(.caption) }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Forget this fact")
                            }
                        }
                        Button("Forget all for this project", role: .destructive) {
                            ProjectMemory.clear(folderPath: proj.folderPath)
                            reloadProjectMemories()
                        }.font(.caption)
                    } label: {
                        HStack(spacing: 8) {
                            Text(proj.name).font(.callout.weight(.medium))
                            Text("\(proj.facts.count)")
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                            Spacer()
                        }
                    }
                    .help(proj.folderPath)
                }
            }
        }
        .onAppear { reloadProjectMemories() }
    }

    private func reloadProjectMemories() { projectMemories = ProjectMemory.allProjects() }

    @ViewBuilder private var modelsTab: some View {
        @Bindable var settings = model.settings
        Section("Models") {
            Picker("Coding agent (on launch)", selection: Binding(
                get: { settings.defaultModelPath ?? "" },
                set: { settings.defaultModelPath = $0.isEmpty ? nil : $0 })) {
                Text("Last used").tag("")
                ForEach(model.models) { m in Text(SidebarView.pretty(m.name)).tag(m.url.path) }
            }
            Picker("Chat model", selection: Binding(
                get: { settings.chatModelPath ?? "" },
                set: { settings.chatModelPath = $0.isEmpty ? nil : $0 })) {
                Text("Same as coding agent").tag("")
                ForEach(model.models) { m in Text(SidebarView.pretty(m.name)).tag(m.url.path) }
            }
            Picker("Fallback", selection: Binding(
                get: { settings.fallbackModelPath ?? "" },
                set: { settings.fallbackModelPath = $0.isEmpty ? nil : $0 })) {
                Text("None").tag("")
                ForEach(model.models) { m in Text(SidebarView.pretty(m.name)).tag(m.url.path) }
            }
            Text("The coding agent runs Code conversations (and their subagents); Chat conversations use the chat model. On a one-model Mac, switching kinds reloads the model. If a model can't load (e.g. out of memory), Slate falls back to the smaller one.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Open Model Manager…") { showModels = true }
        }
        Section("Network") {
            LabeledContent("Model & voice downloads",
                           value: settings.silentModeEnabled ? "Blocked by Silent Mode"
                           : (settings.remoteModelDownloadsEnabled ? "Allowed" : "Off"))
                .foregroundStyle(.secondary)
            Button("Open Network Access settings") { tab = .network }
        }
        Section("Memory & safety") {
            Toggle("Load a model automatically on launch", isOn: $settings.autoLoadModelOnLaunch)
            Text("Off keeps a cold start light on RAM - you pick a model when you want one. The choices above apply once this is on.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Free the model when memory gets critical", isOn: $settings.autoUnloadUnderMemoryPressure)
            Text("Protects your Mac from freezing if memory runs out - Slate unloads the model automatically and tells you.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var networkTab: some View {
        @Bindable var settings = model.settings
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: settings.silentModeEnabled ? "network.slash" : "network")
                        .font(.title2.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(settings.silentModeEnabled ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.silentModeEnabled ? "Slate is network-silent" : "Network access is available")
                            .font(.headline)
                        Text(settings.silentModeEnabled
                             ? "Slate's built-in network clients and cloud connectors are blocked."
                             : "Only the features you enable below can connect.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Silent Mode", isOn: Binding(
                        get: { settings.silentModeEnabled },
                        set: { model.setSilentModeEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("Silent Mode")
                }
                Text("Silent Mode is Slate's master network latch. It cancels active Slate downloads and cloud connectors without unloading your local model.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        Section("Slate network clients") {
            Toggle("Model & voice downloads", isOn: Binding(
                get: { settings.remoteModelDownloadsEnabled },
                set: { model.setRemoteModelDownloadsEnabled($0) }))
                .disabled(settings.silentModeEnabled)
            Text("Allows Hugging Face browsing plus explicit chat, image, Parakeet, Supertonic and Silero downloads. Imported local files never need this.")
                .font(.caption2).foregroundStyle(.secondary)

            Toggle("Cloud connectors", isOn: Binding(
                get: { settings.cloudEnabled },
                set: { model.setCloudEnabled($0) }))
                .disabled(settings.silentModeEnabled)
            Text("Allows only connectors you configure in Cloud. Prompts and selected context may leave this Mac when you use one.")
                .font(.caption2).foregroundStyle(.secondary)

            Toggle("Check for updates on launch", isOn: $settings.autoCheckUpdates)
                .disabled(settings.silentModeEnabled)
            LabeledContent("Licence server", value: settings.silentModeEnabled ? "Blocked" : "Activation and periodic re-check only")
                .foregroundStyle(.secondary)
        }
        Section("Always local") {
            Label("Chat and Code with installed local models", systemImage: "checkmark.circle")
            Label("Image generation with an installed image bundle", systemImage: "checkmark.circle")
            Label("Flow and transcription with installed speech files", systemImage: "checkmark.circle")
            Label("Conversations, memory, knowledge, search and audit log", systemImage: "checkmark.circle")
            Text("Opening a web or mail link hands it to another app. Commands and third-party CLIs you explicitly approve are separate processes; Silent Mode is not a system-wide firewall.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var skillsTab: some View {
        Section("Skills") {
            Text("Skills are local instruction packs. Drop a folder with a SKILL.md into your skills folder, enable it here, and Slate follows it when a task matches its purpose. 100% offline - no marketplace, no account.")
                .font(.caption).foregroundStyle(.secondary)
            if model.installedSkills.isEmpty {
                Text("No skills installed yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.installedSkills) { skill in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { model.isSkillEnabled(skill) },
                        set: { on in model.setSkillEnabled(skill, enabled: on) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(skill.name).font(.callout)
                            if !skill.description.isEmpty {
                                Text(skill.description).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    Button(role: .destructive) {
                        model.removeSkill(skill)      // moves the folder to the Trash (recoverable)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this skill (moves its folder to the Trash)")
                }
            }
            if let skillImportNote {
                Text(skillImportNote).font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open skills folder…") { NSWorkspace.shared.open(Skills.directory()) }
                Button("Rescan") { model.rescanSkills() }
                Button("Import from Claude…") {
                    Task {
                        let found = await model.discoverClaudeSkills()
                        model.importSkills(found)
                        skillImportNote = found.isEmpty
                            ? "No new Claude skills found in ~/.claude."
                            : "Imported \(found.count) skill(s) from Claude. Enable the ones you want above."
                    }
                }
                .help("Find skills you already have under ~/.claude and copy them in")
                Spacer()
                Button("Add example skill") { Skills.writeExample(); model.rescanSkills() }
            }
        }

        // Local tools · MCP moved into slate-pro (Phase 3): the whole service + this
        // Settings section live in the private layer. Free build shows an upsell row.
        model.pro.localToolsSettings(gate: model.coordinator,
                                     requirePro: { model.requirePro(.localTools) },
                                     onViewAudit: { showAudit = true })

        Section("Shortcuts & CLI") {
            VStack(alignment: .leading, spacing: 5) {
                Label("Local automation", systemImage: "command.square")
                    .font(.callout.weight(.semibold))
                Text("Use slatectl from Terminal or Apple Shortcuts → Run Shell Script. Search and transcription work directly; ask opens Slate and uses the loaded local model. No local web server, account, or internet connection is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let cliPath = Bundle.main.url(forResource: "slatectl", withExtension: nil)?.path
                ?? "/Applications/Slate.app/Contents/Resources/slatectl"
            LabeledContent("Command", value: cliPath)
                .font(.caption.monospaced())
            HStack {
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cliPath, forType: .string)
                }
                Button("Copy Shortcut example") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\"\(cliPath)\" ask",
                                                   forType: .string)
                }
                Spacer()
                Text("Free · offline").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var hardwareTab: some View {
        @Bindable var settings = model.settings
        Section("Your Mac") {
            Picker("Chip", selection: Binding(
                get: { settings.hwChip ?? "" },
                set: { newChip in
                    settings.hwChip = newChip.isEmpty ? nil : newChip
                    // Narrow GPU/RAM to the new chip; drop now-invalid selections.
                    let c = newChip.isEmpty ? nil : newChip
                    if let g = settings.hwGPU, !HardwareCatalog.gpuOptions(for: c).contains(g) { settings.hwGPU = nil }
                    if settings.hwRAMGB != 0, !HardwareCatalog.ramOptions(for: c).contains(settings.hwRAMGB) { settings.hwRAMGB = 0 }
                })) {
                Text("Not set").tag("")
                ForEach(HardwareCatalog.chips, id: \.self) { Text($0).tag($0) }
            }
            Picker("GPU", selection: Binding(
                get: { settings.hwGPU ?? "" },
                set: { settings.hwGPU = $0.isEmpty ? nil : $0 })) {
                Text("Not set").tag("")
                ForEach(HardwareCatalog.gpuOptions(for: settings.hwChip), id: \.self) { Text($0).tag($0) }
            }
            Picker("Memory (RAM)", selection: $settings.hwRAMGB) {
                Text("Not set").tag(0)
                ForEach(HardwareCatalog.ramOptions(for: settings.hwChip), id: \.self) { Text("\($0) GB").tag($0) }
            }
            Button("Detect automatically") {
                let c = HardwareCatalog.detectedChip()
                if let c { settings.hwChip = c }
                settings.hwGPU = nil   // GPU cores can't be detected reliably; user picks
                settings.hwRAMGB = HardwareCatalog.detectedRAMGB(for: c)
            }
        }
        if settings.hwRAMGB > 0 {
            Section("Model guidance") {
                Label(HardwareCatalog.fitHint(ramGB: settings.hwRAMGB, .resolve(settings.interfaceLanguage)),
                      systemImage: "sparkles")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var webSearchSection: some View {
        @Bindable var settings = model.settings
        Section("Web search · local models") {
            Toggle("Enable web search", isOn: Binding(
                get: { settings.webSearchEnabled }, set: { settings.webSearchEnabled = $0 }))
                .toggleStyle(.checkbox)
                .disabled(settings.silentModeEnabled)
            if settings.silentModeEnabled {
                Label("Web search is paused by Silent Mode.", systemImage: "network.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Provider", selection: Binding(
                get: { settings.webSearchProvider },
                set: { settings.webSearchProvider = $0; webSearchKeyDraft = "" })) {
                ForEach(WebSearchProvider.allCases) { Text($0.label).tag($0) }
            }
            if settings.webSearchProvider == .searxng {
                TextField("SearXNG base URL (https://…)", text: Binding(
                    get: { settings.webSearchSearxngURL ?? "" },
                    set: { settings.webSearchSearxngURL = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
            } else {
                let account = "slate.websearch.\(settings.webSearchProvider.rawValue)"
                let hasKey = KeychainStore.get(account: account)?.isEmpty == false
                HStack {
                    SecureField(hasKey ? "API key saved. Enter a new one to replace" : "\(settings.webSearchProvider.label) API key",
                                text: $webSearchKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        let k = webSearchKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if k.isEmpty { KeychainStore.delete(account: account) } else { KeychainStore.set(k, account: account) }
                        webSearchKeyDraft = ""
                    }
                    .disabled(webSearchKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasKey {
                        Button("Remove", role: .destructive) { KeychainStore.delete(account: account); webSearchKeyDraft = "" }
                    }
                }
            }
            Text("Local models get web_search + fetch_url from your own provider (key stored in the Keychain, never exported). Cloud connectors use their own built-in search. Always off in Silent Mode.")
                .font(.caption2).foregroundStyle(.secondary)
            if let url = URL(string: settings.webSearchProvider.setupURL) {
                Link("Set up \(settings.webSearchProvider.label) ↗", destination: url).font(.caption)
            }
        }
    }

    @ViewBuilder private var cloudTab: some View {
        @Bindable var settings = model.settings
        Section("Cloud connectors") {
            Toggle("Enable cloud mode", isOn: Binding(
                get: { settings.cloudEnabled },
                set: { model.setCloudEnabled($0) }))
                .toggleStyle(.checkbox)
                .disabled(settings.silentModeEnabled)
            if settings.silentModeEnabled {
                Label("Cloud connectors are paused by Silent Mode.", systemImage: "network.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Off by default. When enabled, prompts and selected project context may be sent to the connector you choose. Cloud connectors are available without a Slate Pro licence; provider charges and subscriptions still apply.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        webSearchSection
        Section("CLI · Claude Code") {
            let path = model.settings.claudeCliPath ?? ClaudeCodeEngine.locate()
            LabeledContent("claude CLI", value: path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "not found")
                .foregroundStyle(path == nil ? .red : .secondary)
            TextField("Model alias or id (optional)", text: Binding(
                get: { settings.claudeModel ?? "" },
                set: { settings.claudeModel = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
            TextField("Custom CLI path (optional)", text: Binding(
                get: { settings.claudeCliPath ?? "" },
                set: { settings.claudeCliPath = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder).font(.callout)
            Button("Use Claude Code") { model.pickClaudeCode() }
                .disabled(settings.silentModeEnabled || !settings.cloudEnabled || path == nil)
            Text("Pick “Cloud · Claude Code” in the model menu to use Claude instead of a local model - Slate pipes the `claude` CLI. It inherits your CLI login: a Claude subscription runs over normal usage (no API credits); an API key bills credits. Leave the path empty to auto-detect.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        Section("CLI · OpenCode · 75+ providers") {
            let path = settings.openCodeCliPath ?? OpenCodeEngine.locate()
            LabeledContent("opencode CLI", value: path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "not found")
                .foregroundStyle(path == nil ? .red : .secondary)
            TextField("Custom CLI path (optional)", text: Binding(
                get: { settings.openCodeCliPath ?? "" },
                set: { settings.openCodeCliPath = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder).font(.callout)

            if !settings.openCodeModels.isEmpty {
                ForEach(settings.openCodeModels, id: \.self) { id in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(id).font(.callout)
                            Text("OpenCode CLI").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use") { model.pickOpenCodeModel(id) }
                            .disabled(settings.silentModeEnabled || !settings.cloudEnabled)
                        Button {
                            model.removeOpenCodeModel(id)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
            }

            HStack {
                TextField("provider/model", text: $selectedOpenCodeModel)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addOpenCodeModel() }
                    .disabled(!selectedOpenCodeModel.contains("/"))
            }
            if !openCodeModels.isEmpty {
                Picker("Discovered models", selection: $selectedOpenCodeModel) {
                    Text("Choose a model…").tag("")
                    ForEach(openCodeModels, id: \.self) { Text($0).tag($0) }
                }
            }
            HStack {
                Button(discoveringOpenCode ? "Discovering…" : "Discover configured models") {
                    discoverOpenCodeModels()
                }
                .disabled(settings.silentModeEnabled || discoveringOpenCode || path == nil)
                Button("Connect provider…") {
                    connectOpenCodeProvider(path)
                }
                .disabled(settings.silentModeEnabled || path == nil)
                Button("Copy provider-login command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(path ?? "opencode") providers login", forType: .string)
                    openCodeStatus = "Copied. Run the command in Terminal, then discover models again."
                }
            }
            if let openCodeStatus {
                Text(openCodeStatus).font(.caption2)
                    .foregroundStyle(openCodeStatus.hasPrefix("Found")
                                     || openCodeStatus.hasPrefix("Added")
                                     || openCodeStatus.hasPrefix("Copied")
                                     || openCodeStatus.hasPrefix("Provider login opened")
                                     ? Color.secondary : Color.orange)
            }
            Text("OpenCode owns provider authentication and exposes models as provider/model ids. Slate runs `opencode run --pure --format json`, streams the result, and resumes the OpenCode session on later turns.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        Section("Direct API · OpenAI-compatible") {
            if !settings.cloudEnabled {
                Text("Enable cloud mode above to use API models.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(settings.cloudProviders) { p in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.callout)
                        Text("\(p.model) · \(p.baseURL)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if model.hasCloudKey(p) {
                        Image(systemName: p.requiresAPIKey ? "key.fill" : "desktopcomputer")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("no key").font(.caption2).foregroundStyle(.orange)
                    }
                    Button("Use") { model.pickCloudModel(p) }
                        .disabled(settings.silentModeEnabled || !settings.cloudEnabled || !model.hasCloudKey(p))
                    Button { model.removeCloudProvider(p) } label: { Image(systemName: "trash").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove this cloud model")
                }
            }
            DisclosureGroup("Add a cloud model") {
                Picker("Provider", selection: $newPreset) {
                    ForEach(CloudProvider.presets) { Text($0.name).tag($0.id) }
                }
                .onChange(of: newPreset) { _, id in
                    if let p = CloudProvider.presets.first(where: { $0.id == id }), id != "custom" {
                        newName = p.name; newBaseURL = p.baseURL; newModel = p.sampleModel
                    }
                }
                TextField("Display name", text: $newName).textFieldStyle(.roundedBorder)
                TextField("Base URL (…/v1)", text: $newBaseURL).textFieldStyle(.roundedBorder)
                TextField("Model id", text: $newModel).textFieldStyle(.roundedBorder)
                SecureField("API key", text: $newKey).textFieldStyle(.roundedBorder)
                Button("Save cloud model") {
                    let p = CloudProvider(name: newName.isEmpty ? newModel : newName,
                                          baseURL: newBaseURL, model: newModel)
                    model.saveCloudProvider(p, apiKey: newKey)
                    newKey = ""
                    operationMessage = "Cloud model “\(p.name)” saved. Pick it in the model menu."
                }
                .disabled(newBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
                          || newModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Works with HTTPS OpenAI-compatible endpoints and HTTP on localhost. Keys are stored in your macOS Keychain and only ever sent to the endpoint you configure - never included in settings export.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func addOpenCodeModel() {
        let id = selectedOpenCodeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.contains("/") else { return }
        if !model.settings.openCodeModels.contains(id) {
            model.settings.openCodeModels.append(id)
        }
        selectedOpenCodeModel = ""
        openCodeStatus = "Added \(id)."
    }

    private func discoverOpenCodeModels() {
        discoveringOpenCode = true
        openCodeStatus = nil
        Task {
            do {
                let found = try await model.discoverOpenCodeModels()
                openCodeModels = found
                openCodeStatus = found.isEmpty
                    ? "No configured models found. Connect a provider in OpenCode first."
                    : "Found \(found.count) configured models."
            } catch {
                openCodeStatus = error.localizedDescription
            }
            discoveringOpenCode = false
        }
    }

    private func connectOpenCodeProvider(_ path: String?) {
        guard let path else { return }
        let shellPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "\(shellPath) providers login"
        let literal = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(literal)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            openCodeStatus = "Terminal could not be opened (\(error)). The login command was copied instead."
        } else {
            openCodeStatus = "Provider login opened in Terminal. Discover models after it finishes."
        }
    }

    @ViewBuilder private var privacyTab: some View {
        Section("Privacy & data") {
            Button("Export all my Slate data…") { exportData() }
            Button("Export settings…") { exportSettings() }
            Button("Import settings…") { importSettings() }
            Button("View tool audit log…") { showAudit = true }
            Button("Reset settings to defaults", role: .destructive) { confirmReset = true }
            Button("Delete all my Slate data…", role: .destructive) { confirmDelete = true }
            Text("Deletion removes conversations, memory, generated images, attachments, dictation history and audit entries. Downloaded models are kept.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var securityTab: some View {
        @Bindable var settings = model.settings
        Section("Agent permissions") {
            Toggle("Skip permissions in Auto mode", isOn: $settings.skipPermissions)
                .toggleStyle(.checkbox)
                .onChange(of: settings.skipPermissions) { _, enabled in
                    model.coordinator.resetSessionApprovals()
                    AuditLog.record(.init(category: "security", action: "skip_permissions",
                                          detail: enabled ? "enabled" : "disabled",
                                          approval: "user setting", outcome: "success"))
                }
            Text("Off by default. When off, Auto handles scoped reads and ordinary edits itself, but asks before shell commands and sensitive or destructive changes. When on, Auto may edit files and run commands without approval.")
                .font(.caption2).foregroundStyle(settings.skipPermissions ? .orange : .secondary)
            Label("Hard blocks for deletion, privilege escalation, destructive Git, process termination and direct network-transfer commands remain active in every mode.",
                  systemImage: "exclamationmark.shield")
                .font(.caption2).foregroundStyle(.secondary)
        }
        Section("Permission modes") {
            LabeledContent("Ask", value: "Confirm every write and command")
            LabeledContent("Edits", value: "Allow edits; confirm commands and destructive changes")
            LabeledContent("Auto", value: settings.skipPermissions
                           ? "No approvals; hard blocks still apply"
                           : "Safe actions automatic; risky actions confirmed")
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch model.updater.state {
        case .checking:
            HStack(spacing: 5) { ProgressView().controlSize(.small); Text("Checking…") }
                .font(.caption).foregroundStyle(.secondary)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        case .available(let m):
            Label("Version \(m.version) available", systemImage: "arrow.down.circle")
                .font(.caption).foregroundStyle(.primary)
        case .downloading, .installing:
            Text("Updating…").font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .idle:
            EmptyView()
        }
    }

    private func exportData() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "slate-data-export.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportAllData(to: url); operationMessage = "Your Slate data was exported." }
        catch { operationMessage = "Export failed: \(error.localizedDescription)" }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "slate-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(model.settings.portableSnapshot()).write(to: url, options: .atomic)
            operationMessage = "Settings were exported."
        } catch {
            operationMessage = "Settings export failed: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? .max) <= 1 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            let snapshot = try JSONDecoder().decode(AppSettings.PortableSnapshot.self,
                                                    from: Data(contentsOf: url))
            try model.settings.apply(snapshot)
            model.synchronizeNetworkAccess()
            model.reloadActiveModel()
            operationMessage = "Settings were imported. Cloud mode and remote model downloads remain off; re-enter any cloud key before use."
        } catch {
            operationMessage = "Settings import failed: \(error.localizedDescription)"
        }
    }
}

private struct AuditLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries = AuditLog.recent()

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Tool audit log", system: "ladybug") { dismiss() } trailing: {
                if !entries.isEmpty {
                    Button("Clear", role: .destructive) { try? AuditLog.clear(); entries = [] }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.red)
                }
            }
            if entries.isEmpty {
                ContentUnavailableView("No audited actions", systemImage: "checkmark.shield",
                                       description: Text("Tool commands and AppleEvent fallbacks appear here."))
            } else {
                List(entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.action).font(.callout.weight(.semibold))
                            Spacer()
                            Text(entry.timestamp, style: .date).font(.caption2).foregroundStyle(.secondary)
                            Text(entry.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(entry.detail).font(.caption.monospaced()).lineLimit(3)
                        Text("\(entry.approval) · \(entry.outcome)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 440)
    }
}

private struct ThirdPartyNoticesView: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Third-party notices", system: "doc.text") { dismiss() }
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 700, idealWidth: 820, minHeight: 500, idealHeight: 640)
    }
}

private struct PalettePreview: View {
    let palette: SlatePalette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(palette.canvas.opacity(0.42))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.surface.opacity(0.68))
                .frame(width: 56, height: 28)
            HStack(spacing: 5) {
                Circle().fill(palette.accent).frame(width: 9, height: 9)
                Capsule().fill(palette.surfaceInk.opacity(0.78)).frame(width: 25, height: 5)
            }
        }
        .frame(width: 78, height: 44)
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityLabel("Palette preview")
    }
}

private struct ChatPalettePreview: View {
    let palette: SlatePalette

    var body: some View {
        HStack(spacing: 6) {
            bubble("You", fill: palette.userBubble, ink: palette.userBubbleInk)
            bubble("Slate", fill: palette.assistantBubble, ink: palette.assistantBubbleInk)
            bubble("Tool", fill: palette.toolBubble, ink: palette.toolBubbleInk)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(palette.canvas.opacity(0.36)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityLabel("Chat color preview")
    }

    private func bubble(_ text: String, fill: Color, ink: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
    }
}

struct ConversationSettingsView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let defaultTemp: Double
    @State private var temperature: Double
    @State private var systemPrompt: String

    init(conversation: Conversation, defaultTemp: Double) {
        self.conversation = conversation
        self.defaultTemp = defaultTemp
        _temperature = State(initialValue: conversation.temperature ?? defaultTemp)
        _systemPrompt = State(initialValue: conversation.systemPromptOverride ?? "")
    }

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 14) {
            Text("Conversation settings").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Temperature").font(.callout)
                    InfoHint(text: "How adventurous the model is when picking the next word. **0-0.3**: precise and repeatable - best for code, edits and facts. **0.7**: the balanced default for everyday use. **1.0+**: freer and more varied - brainstorming, prose, naming. High values can drift or make things up.")
                    Spacer()
                    Text(String(format: "%.2f", temperature)).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $temperature, in: 0...1.5)
                    .onChange(of: temperature) { _, v in model.setTemperature(v, for: conversation.id) }
                Text("0-0.3 precise · 0.7 balanced · 1.0+ creative")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Divider()

            // App-wide model knobs, mirrored here because this popover is always
            // reachable (the Settings window may be closed/behind).
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Context window").font(.callout)
                    InfoHint(text: "How much of the conversation the model can see at once, in tokens. Bigger windows remember more but need much more RAM (KV cache). Applies app-wide; changing it reloads the model.")
                    Spacer()
                    Picker("", selection: $settings.contextWindow) {
                        ForEach(AppSettings.contextWindowOptions(trainedMax: model.activeTrainedContext, current: settings.contextWindow), id: \.self) { n in
                            Text(TokenEstimate.short(n)).tag(n)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: settings.contextWindow) { _, _ in model.reloadActiveModel() }
                }
                Stepper("Max tokens per reply: \(settings.maxTokens)",
                        value: $settings.maxTokens, in: 256...16384, step: 256)
                    .font(.callout)
                Text("App-wide · window change reloads the model")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("System prompt override").font(.callout)
                TextEditor(text: $systemPrompt)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 130)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
                    .onChange(of: systemPrompt) { _, v in model.setSystemPrompt(v, for: conversation.id) }
                Text("Leave empty to use the default \(conversation.kind == .code ? "coding-agent" : "assistant") prompt.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(width: 380)
    }
}
