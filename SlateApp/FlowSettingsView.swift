import AppKit
import SwiftUI
import SlateFlowCore
import SlateFlowCleanup
import SlateSTT

/// The "Dictation" section inside Slate's Settings form: enable toggle, the
/// permissions bootstrap, language pick and STT-model state. M3 grows this
/// into styles/dictionary/history.
struct FlowSettingsSection: View {
    @Environment(FlowRuntime.self) private var flow
    @Environment(AppModel.self) private var model
    @State private var permissionsOK = HotkeyMonitor.preflight()
    @State private var modelSetupBusy = false
    @State private var modelSetupStatus: String?
    @State private var voicePreviewID = UUID()

    private var downloadsAllowed: Bool {
        model.settings.remoteModelDownloadsEnabled && !model.settings.silentModeEnabled
    }

    /// Download / progress / manage row for the optional Qwen3 premium voice.
    @ViewBuilder
    private var qwen3VoiceRow: some View {
        if !Qwen3VoiceBundle.enabled {
            EmptyView()                 // premium tier gated off until a reliable model ships
        } else if model.qwen3Downloading {
            HStack(spacing: 8) {
                ProgressView(value: model.qwen3DownloadProgress).progressViewStyle(.linear).frame(maxWidth: 180)
                Text("\(Int(model.qwen3DownloadProgress * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Cancel") { model.cancelQwen3Download() }.font(.caption)
                Spacer()
            }
        } else if model.qwen3Installed {
            HStack {
                Label("Premium voices installed", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remove", role: .destructive) { model.deleteQwen3Voice() }.font(.caption)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button { model.downloadQwen3Voice() } label: {
                    Label("Download premium voices (~820 MB)", systemImage: "arrow.down.circle")
                }
                .disabled(!downloadsAllowed)
                Text("Qwen3-TTS: noticeably more natural voices (Apache-2.0), running locally on the GPU. Fully offline after the one-time download.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if let err = model.qwen3Error {
            Text(err).font(.caption2).foregroundStyle(.orange)
        }
    }

    var body: some View {
        @Bindable var flow = flow
        @Bindable var settings = model.settings
        Section("Dictation · Flow") {
            Picker("Assistant voice", selection: $settings.assistantVoice) {
                Section("Slate neural voices · local after setup") {
                    ForEach(AppSettings.assistantVoices, id: \.name) { Text($0.label).tag($0.name) }
                }
                if model.qwen3Installed, Qwen3VoiceBundle.enabled {
                    Section("Premium voices · Qwen3, local") {
                        ForEach(Qwen3VoiceBundle.speakers, id: \.id) { s in
                            Text(s.label).tag(Qwen3VoiceBundle.voiceValue(for: s.id))
                        }
                    }
                }
                let sys = SystemTTS.naturalVoices()
                if !sys.isEmpty {
                    Section("macOS voices · installed & offline") {
                        ForEach(sys, id: \.id) { Text($0.label).tag($0.id) }
                    }
                }
            }
            qwen3VoiceRow
            Button {
                if model.speech.isSpeaking {
                    model.speech.stop()
                } else {
                    voicePreviewID = UUID()
                    model.speech.toggle("Hi! I'm Slate. This is how I sound.",
                                        id: voicePreviewID, voice: settings.assistantVoice)
                }
            } label: {
                Label(model.speech.isSpeaking ? "Stop preview" : "Preview voice",
                      systemImage: model.speech.isSpeaking ? "stop.circle" : "speaker.wave.2")
                    .font(.caption)
            }
            .accessibilityHint("Plays a short sample with the selected assistant voice")
            Text("The voice Slate speaks with. Slate neural M/F voices use an optional, user-downloaded Supertonic model; without it, Slate falls back to an installed macOS voice. Enhanced/Premium macOS voices sound noticeably more human - especially in German - and are added under System Settings › Accessibility › Spoken Content › System Voice › Manage Voices. Applies next time you start voice.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Enable Flow - hold Fn to dictate anywhere", isOn: $flow.enabled)
                .onChange(of: flow.enabled) { _, on in
                    // Flow is Pro. Revert the toggle and show the upsell for Free users.
                    if on, !model.requirePro(.flow) { flow.enabled = false }
                }
            if flow.enabled {
                if !permissionsOK {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Flow needs Microphone, Accessibility and Input Monitoring access.",
                              systemImage: "exclamationmark.shield")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Grant permissions…") {
                                Task {
                                    permissionsOK = await flow.requestPermissions()
                                    if permissionsOK { flow.start() }
                                }
                            }
                            Button("Re-check") {
                                permissionsOK = HotkeyMonitor.preflight()
                                if permissionsOK { flow.start() }
                            }
                        }
                        Text("Also set System Settings → Keyboard → “Press 🌐 key to” = **Do Nothing**, so Fn is free for dictation.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Picker("Language", selection: Binding(
                    get: { flow.language ?? "" },
                    set: { flow.language = $0.isEmpty ? nil : $0 })) {
                    Text("Auto-detect").tag("")
                    Text("Deutsch").tag("de")
                    Text("English").tag("en")
                }
                Toggle("Smart formatting (punctuation, fillers, self-corrections)",
                       isOn: Binding(get: { flow.controller.smartFormatting },
                                     set: { flow.controller.smartFormatting = $0 }))
                if flow.controller.smartFormatting {
                    Picker("Cleanup intensity", selection: $flow.style) {
                        Text("Rules only").tag(CleanupStyle.none)
                        Text("Light").tag(CleanupStyle.light)
                        Text("Medium").tag(CleanupStyle.medium)
                        Text("High").tag(CleanupStyle.high)
                    }
                    .pickerStyle(.segmented)
                    // The #1 "why does Medium not filter anything" answer, live:
                    if flow.style != .none, let blocker = model.flowCleanupBlocker {
                        Label(blocker, systemImage: "exclamationmark.triangle")
                            .font(.caption.weight(.medium)).foregroundStyle(.primary)
                    }
                    Text("Light/Medium/High run the loaded chat model over the transcript (≈0.5-1 s). Falls back to rules-only when the model is busy.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if flow.preparing {
                    Label("Loading the local speech model…", systemImage: "internaldrive")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let err = flow.prepareError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if flow.recoveredSamples != nil {
                    HStack {
                        Label("A dictation from a previous session wasn't inserted.",
                              systemImage: "waveform.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Recover to clipboard") {
                            Task { await flow.recoverParkedDictation() }
                        }
                    }
                }
                Text("Hold **Fn** and speak; release to insert. Double-tap Fn for hands-free; **Esc** cancels.")
                    .font(.caption2).foregroundStyle(.secondary)
                DisclosureGroup("Dictionary (\(flow.dictionary.entries.count))") {
                    FlowDictionaryEditor()
                }
                DisclosureGroup("History") {
                    FlowHistoryList()
                }
            }
            DisclosureGroup("Offline voice model setup") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Normal dictation and voice never download anything. Import copied model folders for an air-gapped Mac, or provision once with the explicit download buttons.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Button("Import speech…") { chooseFolder(.speech) }
                        Button("Download speech…") { provision(.speech) }
                            .disabled(!downloadsAllowed || modelSetupBusy)
                    }
                    HStack {
                        Button("Import neural voices…") { chooseFolder(.voice) }
                        Button("Download neural voices…") { provision(.voice) }
                            .disabled(!downloadsAllowed || modelSetupBusy)
                    }
                    HStack {
                        Button("Import voice detector…") { chooseFolder(.vad) }
                        Button("Download voice detector…") { provision(.vad) }
                            .disabled(!downloadsAllowed || modelSetupBusy)
                    }
                    if modelSetupBusy { ProgressView().controlSize(.small) }
                    if let modelSetupStatus {
                        Text(modelSetupStatus).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Optional speech models are not bundled. Slate shows their provider terms and downloads them only after your explicit action.")
                    .font(.caption2).foregroundStyle(.tertiary)
                HStack(spacing: 10) {
                    Link("Parakeet · CC-BY-4.0", destination: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2/blob/main/LICENSE")!)
                    Link("Supertonic · OpenRAIL-M", destination: URL(string: "https://huggingface.co/Supertone/supertonic/blob/main/LICENSE")!)
                    Link("Silero VAD · MIT", destination: URL(string: "https://huggingface.co/BricksDisplay/silero-vad/blob/main/LICENSE")!)
                }
                .font(.caption2)
            }
        }
        .onAppear { permissionsOK = HotkeyMonitor.preflight() }
    }

    private enum VoiceModelKind { case speech, voice, vad }

    private func chooseFolder(_ kind: VoiceModelKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelSetupBusy = true; modelSetupStatus = nil
        Task {
            do {
                switch kind {
                case .speech: try await flow.stt.useImportedModels(at: url)
                case .voice: try await SupertonicTTS().useImportedModels(at: url)
                case .vad: try await StreamingVad().useImportedModels(at: url)
                }
                modelSetupStatus = "Local model folder verified."
            } catch { modelSetupStatus = error.localizedDescription }
            modelSetupBusy = false
        }
    }

    private func provision(_ kind: VoiceModelKind) {
        guard downloadsAllowed else {
            modelSetupStatus = "Downloads are blocked. Enable Model & voice downloads in Settings → Network Access."
            return
        }
        modelSetupBusy = true; modelSetupStatus = "Downloading only because you requested it…"
        Task {
            do {
                switch kind {
                case .speech: try await flow.stt.downloadAndPrepare()
                case .voice: try await SupertonicTTS().downloadAndPrepare()
                case .vad: try await StreamingVad().downloadAndPrepare()
                }
                modelSetupStatus = "Ready for fully offline use."
            } catch { modelSetupStatus = error.localizedDescription }
            modelSetupBusy = false
        }
    }
}

/// Wrong→right rows; empty "wrong" = vocabulary-only term for the cleanup prompt.
private struct FlowDictionaryEditor: View {
    @Environment(FlowRuntime.self) private var flow
    @State private var wrong = ""
    @State private var right = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(flow.dictionary.entries) { e in
                HStack {
                    Text(e.wrong.isEmpty ? "(vocabulary)" : e.wrong)
                        .foregroundStyle(.secondary).font(.caption)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(e.right).font(.caption)
                    Spacer()
                    Button {
                        flow.dictionary.entries.removeAll { $0.id == e.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("heard as… (optional)", text: $wrong).textFieldStyle(.roundedBorder)
                TextField("write as…", text: $right).textFieldStyle(.roundedBorder)
                Button("Add") {
                    let r = right.trimmingCharacters(in: .whitespaces)
                    guard !r.isEmpty else { return }
                    flow.dictionary.entries.append(
                        .init(wrong: wrong.trimmingCharacters(in: .whitespaces), right: r))
                    wrong = ""; right = ""
                }
            }
            Text("Names & jargon Flow should spell correctly - e.g. “lange und co” → “Lange & Co.”")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

/// Last dictations, newest first, with copy buttons.
private struct FlowHistoryList: View {
    @State private var entries: [FlowHistoryEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty {
                Text("No dictations yet.").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(entries) { e in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.polished).font(.caption).lineLimit(2)
                        Text(e.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e.polished, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { entries = FlowHistory.load(limit: 20) }
    }
}

/// Menu-bar dropdown: quick toggle, language, pill muting.
struct FlowMenuBarView: View {
    @Environment(FlowRuntime.self) private var flow

    var body: some View {
        @Bindable var flow = flow
        Toggle("Enable Flow (hold Fn)", isOn: $flow.enabled)
        Picker("Language", selection: Binding(
            get: { flow.language ?? "" },
            set: { flow.language = $0.isEmpty ? nil : $0 })) {
            Text("Auto-detect").tag("")
            Text("Deutsch").tag("de")
            Text("English").tag("en")
        }
        Divider()
        if flow.pillDocked {
            Button("Float the pill (drag it out works too)") { flow.detachPill() }
                .disabled(!flow.enabled)
        } else {
            Button("Dock pill into the window") { flow.dockPill() }
                .disabled(!flow.enabled)
            Button("Hide bar for 1 hour") { flow.hideBarForAnHour() }
                .disabled(!flow.enabled)
        }
    }
}
