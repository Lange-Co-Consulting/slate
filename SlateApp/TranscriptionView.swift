import AppKit
import SwiftUI
import SlateUI
import UniformTypeIdentifiers
import SlateSTT
import SlateCore

struct SavedTranscription: Codable, Identifiable, Sendable {
    let id: UUID
    let sourceName: String
    let createdAt: Date
    let durationSeconds: Double
    let language: String?
    let text: String
    var hasSpeakerLabels: Bool?
    var project: String?
}

enum TranscriptionStore {
    static var fileURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Slate", isDirectory: true)
            .appendingPathComponent("transcriptions.json")
    }

    static func load() -> [SavedTranscription] {
        guard let data = try? PrivateStorage.read(from: fileURL, maxBytes: 20 * 1_024 * 1_024),
              let items = try? JSONDecoder().decode([SavedTranscription].self, from: data) else { return [] }
        return Array(items.prefix(200))
    }

    static func append(_ item: SavedTranscription) {
        var items = load()
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > 200 { items.removeLast(items.count - 200) }
        if let data = try? JSONEncoder().encode(items) { try? PrivateStorage.write(data, to: fileURL) }
    }
}

@MainActor @Observable
final class TranscriptionSession {
    var fileURL: URL?
    var files: [URL] = []
    var language = "auto"
    var text = ""
    var error: String?
    var busy = false
    var progress = 0.0
    var durationSeconds = 0.0
    var sourceName: String?
    var project = ""

    func setFiles(_ urls: [URL]) {
        files = urls
        fileURL = urls.first
        sourceName = urls.count > 1 ? "\(urls.count) files queued" : urls.first?.lastPathComponent
        text = ""; error = nil; progress = 0
    }

    func transcribe(using engine: ParakeetEngine, speakerLabels: Bool,
                    diarizerModelDirectory: URL?) async {
        let queue = files.isEmpty ? fileURL.map { [$0] } ?? [] : files
        guard !queue.isEmpty else { return }
        busy = true; error = nil; text = ""; progress = 0
        defer { busy = false }
        do {
            var batchOutput: [String] = []
            var totalDuration = 0.0
            for (fileIndex, url) in queue.enumerated() {
                try Task.checkCancellation()
                sourceName = queue.count > 1 ? "\(fileIndex + 1) of \(queue.count) · \(url.lastPathComponent)" : url.lastPathComponent
                let accessing = url.startAccessingSecurityScopedResource()
                let samples: [Float]
                do {
                    samples = try await Task.detached(priority: .userInitiated) {
                        try AudioFileDecoder.decode(url: url)
                    }.value
                } catch {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    throw error
                }
                if accessing { url.stopAccessingSecurityScopedResource() }
                let fileDuration = Double(samples.count) / AudioFileDecoder.sampleRate
                totalDuration += fileDuration
                durationSeconds = totalDuration
                let fileText: String
                if speakerLabels {
                    progress = Double(fileIndex) / Double(queue.count)
                    let segments = try await engine.transcribeWithSpeakers(
                        samples, language: language == "auto" ? nil : language,
                        diarizerModelDirectory: diarizerModelDirectory
                    )
                    fileText = segments.map(\.formatted).joined(separator: "\n\n")
                    progress = Double(fileIndex + 1) / Double(queue.count)
                } else {
                    // Bound peak inference work and keep long recordings responsive.
                    let chunkSize = Int(AudioFileDecoder.sampleRate * 10 * 60)
                    let totalChunks = max(1, Int(ceil(Double(samples.count) / Double(chunkSize))))
                    var parts: [String] = []
                    for index in 0..<totalChunks {
                        let start = index * chunkSize
                        let end = min(samples.count, start + chunkSize)
                        let result = try await engine.transcribe(Array(samples[start..<end]),
                                                                 language: language == "auto" ? nil : language)
                        let clean = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { parts.append(clean) }
                        progress = (Double(fileIndex) + Double(index + 1) / Double(totalChunks)) / Double(queue.count)
                    }
                    fileText = parts.joined(separator: "\n\n")
                }
                guard !fileText.isEmpty else { continue }
                batchOutput.append(queue.count > 1 ? "# \(url.lastPathComponent)\n\n\(fileText)" : fileText)
                TranscriptionStore.append(SavedTranscription(
                    id: UUID(), sourceName: url.lastPathComponent, createdAt: Date(),
                    durationSeconds: fileDuration, language: language == "auto" ? nil : language,
                    text: fileText, hasSpeakerLabels: speakerLabels,
                    project: project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : project.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                progress = Double(fileIndex + 1) / Double(queue.count)
            }
            text = batchOutput.joined(separator: "\n\n---\n\n")
            guard !text.isEmpty else {
                error = "No speech was detected in this file."
                return
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TranscriptionView: View {
    @Environment(AppModel.self) private var model
    @Environment(FlowRuntime.self) private var flow
    @Environment(\.dismiss) private var dismiss
    @State private var session = TranscriptionSession()
    @State private var choosingFile = false
    @State private var saved = TranscriptionStore.load()
    @State private var speakerLabels = false
    @State private var provisioning = false

    private var queuedFileCount: Int {
        session.files.isEmpty ? (session.fileURL == nil ? 0 : 1) : session.files.count
    }

    private var transcribeTitle: String {
        queuedFileCount > 1 ? "Transcribe \(queuedFileCount) files" : "Transcribe file"
    }

    /// Keep the picker state compact for screenshots and short one-off jobs;
    /// completed transcripts retain enough vertical room to read and export.
    private var panelHeight: CGFloat { session.text.isEmpty ? 440 : 680 }

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            SheetHeader(title: "Transcribe", system: "waveform.badge.mic") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !saved.isEmpty {
                        DisclosureGroup("Recent transcripts") {
                            VStack(spacing: 4) {
                                ForEach(saved.prefix(12)) { item in
                                    Button {
                                        session.sourceName = item.sourceName
                                        session.durationSeconds = item.durationSeconds
                                        session.language = item.language ?? "auto"
                                        session.project = item.project ?? ""
                                        speakerLabels = item.hasSpeakerLabels ?? false
                                        session.text = item.text
                                        session.error = nil
                                    } label: {
                                        HStack {
                                            Image(systemName: "doc.text")
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(item.sourceName).lineLimit(1)
                                                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                                    .font(.caption2).foregroundStyle(.secondary)
                                                if let project = item.project {
                                                    Text(project).font(.caption2).foregroundStyle(.tertiary)
                                                }
                                            }
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 6)
                        }
                    }
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "lock.shield")
                            .font(.title2).frame(width: 42, height: 42)
                            .background(Circle().fill(.quinary))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Audio and video stay on this Mac").font(.headline)
                            Text("Parakeet runs on the Neural Engine. No upload, account or API key is used.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.sourceName ?? session.fileURL?.lastPathComponent ?? "No file selected")
                                        .font(.callout.weight(.medium)).lineLimit(1)
                                    Text(queuedFileCount > 1
                                         ? "\(queuedFileCount) files ready · processed privately in sequence"
                                         : "WAV, MP3, M4A, MP4, MOV and Core Audio formats")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(model.pro.isPro ? "Choose files…" : "Choose file…") { choosingFile = true }
                                    .disabled(session.busy)
                            }
                            Picker("Language", selection: $session.language) {
                                Text("Auto-detect").tag("auto")
                                Text("Deutsch").tag("de")
                                Text("English").tag("en")
                                Text("Français").tag("fr")
                                Text("Español").tag("es")
                            }
                            .pickerStyle(.menu)
                            if model.pro.isPro {
                                TextField("Project (optional, for example Interviews)", text: $session.project)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Toggle(isOn: Binding(
                                get: { speakerLabels },
                                set: { requested in
                                    if requested, !model.requirePro(.transcriptionPro) {
                                        speakerLabels = false
                                    } else { speakerLabels = requested }
                                })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Identify speakers")
                                    Text("Pro · local diarization with timestamps")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if speakerLabels {
                                HStack {
                                    Text(model.settings.diarizationModelPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                                         ?? "Default local diarization model")
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Button("Use model folder…") { chooseDiarizerFolder() }
                                        .font(.caption)
                                    Button("Download model…") { downloadDiarizerModel() }
                                        .font(.caption)
                                        .disabled(!downloadsAllowed || provisioning)
                                }
                            }
                            Button {
                                Task {
                                    await session.transcribe(
                                        using: flow.stt, speakerLabels: speakerLabels,
                                        diarizerModelDirectory: model.settings.diarizationModelPath.map(URL.init(fileURLWithPath:))
                                    )
                                }
                            } label: {
                                if session.busy {
                                    HStack {
                                        ProgressView().controlSize(.small)
                                        Text("Transcribing locally… \(Int((session.progress * 100).rounded()))%")
                                    }
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text(transcribeTitle).frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(PaletteProminentButtonStyle())
                            .disabled(session.fileURL == nil || session.busy)
                            if session.busy {
                                ProgressView(value: session.progress) {
                                    Text("Local queue progress")
                                } currentValueLabel: {
                                    Text("\(Int((session.progress * 100).rounded()))%")
                                }
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                            Divider().opacity(0.2)
                            DisclosureGroup("Offline model setup") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Import a complete Parakeet model folder for an air-gapped Mac, or download it once on a connected Mac. Normal transcription never enables network access.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    HStack {
                                        Button("Use speech model folder…") { chooseSpeechModelFolder() }
                                        Button("Download speech model…") { downloadSpeechModel() }
                                            .disabled(!downloadsAllowed || provisioning)
                                        if provisioning { ProgressView().controlSize(.small) }
                                    }
                                    .font(.caption)
                                }
                                .padding(.top, 6)
                            }
                        }
                        .padding(4)
                    }

                    if let error = session.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !session.text.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Transcript").font(.headline)
                                if session.durationSeconds > 0 {
                                    Text(Duration.seconds(session.durationSeconds).formatted(.time(pattern: .minuteSecond)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(session.text, forType: .string)
                                }
                                Button("Save…") { saveTranscript() }
                            }
                            ScrollView {
                                Text(session.text).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 180, maxHeight: 320)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quinary))
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 680, height: panelHeight)
        .animation(.snappy(duration: 0.24), value: session.text.isEmpty)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio, .movie, .mpeg4Movie],
                      allowsMultipleSelection: model.pro.isPro) { result in
            if case .success(let urls) = result {
                _ = queueFiles(urls)
            }
        }
        .onAppear {
            if let id = model.transcriptionHighlightID,
               let item = saved.first(where: { $0.id == id }) {
                session.sourceName = item.sourceName
                session.durationSeconds = item.durationSeconds
                session.language = item.language ?? "auto"
                session.project = item.project ?? ""
                speakerLabels = item.hasSpeakerLabels ?? false
                session.text = item.text
                model.transcriptionHighlightID = nil
            }
        }
        .onChange(of: session.busy) { _, busy in if !busy { saved = TranscriptionStore.load() } }
        .dropDestination(for: URL.self) { urls, _ in
            queueFiles(urls)
        }
    }

    @discardableResult
    private func queueFiles(_ urls: [URL]) -> Bool {
        let media = urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .audio) || type.conforms(to: .movie)
        }
        guard !media.isEmpty else { return false }
        if media.count > 1, !model.pro.allows(.transcriptionPro) {
            session.setFiles([media[0]])
            session.error = "Batch transcription is part of Slate Pro. The first file is ready."
        } else {
            session.setFiles(media)
        }
        return true
    }

    private func saveTranscript() {
        let panel = NSSavePanel()
        let stem = session.fileURL?.deletingPathExtension().lastPathComponent ?? "Transcript"
        panel.nameFieldStringValue = stem + ".txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? session.text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func chooseSpeechModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the complete Parakeet v3 model directory"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        provisioning = true
        Task {
            do { try await flow.stt.useImportedModels(at: url); session.error = nil }
            catch { session.error = "Speech model folder is incomplete: \(error.localizedDescription)" }
            provisioning = false
        }
    }

    private func chooseDiarizerFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the complete offline diarization model directory"
        if panel.runModal() == .OK { model.settings.diarizationModelPath = panel.url?.path }
    }

    private func downloadSpeechModel() {
        guard downloadsAllowed else {
            session.error = "Downloads are blocked. Enable Model & voice downloads in Settings → Network Access."
            return
        }
        provisioning = true; session.error = nil
        Task {
            do { try await flow.stt.downloadAndPrepare() }
            catch { session.error = "Speech model download failed: \(error.localizedDescription)" }
            provisioning = false
        }
    }

    private func downloadDiarizerModel() {
        guard downloadsAllowed else {
            session.error = "Downloads are blocked. Enable Model & voice downloads in Settings → Network Access."
            return
        }
        provisioning = true; session.error = nil
        Task {
            do { try await flow.stt.downloadAndPrepareDiarizer() }
            catch { session.error = "Diarization model download failed: \(error.localizedDescription)" }
            provisioning = false
        }
    }

    private var downloadsAllowed: Bool {
        model.settings.remoteModelDownloadsEnabled && !model.settings.silentModeEnabled
    }
}
