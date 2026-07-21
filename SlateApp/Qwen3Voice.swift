import Foundation
@preconcurrency import MLX
@preconcurrency import Qwen3TTS
import SlateSTT

/// The downloadable Qwen3-TTS premium voice (Apache-2.0, mlx-community 4-bit
/// CustomVoice build, ~1.7 GB): the talker model + its speech-tokenizer codec.
/// Fetched from Hugging Face once, then used 100% offline via MLX/Metal.
enum Qwen3VoiceBundle {
    struct File { let path: String; let bytes: Int64 }

    /// Master switch for the premium tier. Currently OFF: the 4-bit vocab-pruned
    /// edge build fails to emit end-of-speech and derails into babble/coughing on
    /// most generations (measured ~75% failure; greedy decoding derails 100%) -
    /// an autoregressive-codec instability, not a tunable parameter. Kept wired
    /// (downloader, engine, metallib, guard) so re-enabling is a one-line change
    /// once a reliable model/build is validated. Supertonic stays the neural voice.
    static let enabled = false

    /// The package author's edge build: vocab-pruned + 4-bit, near-identical
    /// quality at less than half the download, MIT, and tested against the exact
    /// pinned swift-qwen3-tts revision (it also ships the tokenizer.json the Swift
    /// tokenizer requires, which the mlx-community conversions omit).
    static let repo = "AtomGradient/Qwen3-TTS-0.6B-CustomVoice-4bit-pruned-vocab-lite"

    static func url(_ path: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)?download=true")!
    }

    /// Exact byte sizes from the HF file tree, so every file is verifiable and an
    /// interrupted download resumes (complete files are skipped).
    static let files: [File] = [
        .init(path: "config.json", bytes: 6_232),
        .init(path: "generation_config.json", bytes: 245),
        .init(path: "merges.txt", bytes: 1_671_839),
        .init(path: "preprocessor_config.json", bytes: 127),
        .init(path: "tokenizer.json", bytes: 5_364_038),
        .init(path: "tokenizer_config.json", bytes: 7_344),
        .init(path: "vocab.json", bytes: 2_776_833),
        .init(path: "speech_tokenizer/config.json", bytes: 1_097),
        .init(path: "speech_tokenizer/model.safetensors", bytes: 228_678_031),
        .init(path: "model.safetensors", bytes: 579_311_856),
    ]

    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    static var installRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Slate/Qwen3TTS", isDirectory: true)
    }

    static var isInstalled: Bool {
        let fm = FileManager.default
        for f in files {
            let url = installRoot.appendingPathComponent(f.path)
            guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int64, size == f.bytes else {
                return false
            }
        }
        return true
    }

    /// The curated preset speakers exposed in the picker (all cross-lingual; the
    /// model speaks every supported language with each of them).
    static let speakers: [(id: String, label: String)] = [
        ("Ryan", "Ryan · premium male"),
        ("Aiden", "Aiden · premium male"),
        ("Vivian", "Vivian · premium female"),
        ("Serena", "Serena · premium female"),
    ]

    /// Prefix marking an assistantVoice value as a Qwen3 premium voice.
    static let voicePrefix = "qwen3:"
    static func isQwen3Voice(_ v: String) -> Bool { v.hasPrefix(voicePrefix) }
    static func speakerID(from value: String) -> String { String(value.dropFirst(voicePrefix.count)) }
    static func voiceValue(for id: String) -> String { voicePrefix + id }
}

/// Sequential, size-verified, resumable downloader for the Qwen3 voice bundle
/// (same shape as the image-bundle downloader: streamed to disk, nested paths,
/// already-complete files skipped so restarts resume).
@MainActor
final class Qwen3VoiceDownloader: NSObject, URLSessionDownloadDelegate {
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }()

    private var files: [Qwen3VoiceBundle.File] = []
    private var index = 0
    private var doneBytes: Int64 = 0
    private var attempts = 0
    private let maxAttempts = 6
    private var activeTask: URLSessionDownloadTask?
    private var onProgress: ((Double) -> Void)?
    private var onDone: ((Error?) -> Void)?

    func start(onProgress: @escaping (Double) -> Void, onDone: @escaping (Error?) -> Void) {
        files = Qwen3VoiceBundle.files
        self.onProgress = onProgress
        self.onDone = onDone
        index = 0; doneBytes = 0; attempts = 0
        guard files.allSatisfy({ Self.safeRelativePath($0.path) }) else {
            onDone(NSError(domain: "Slate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Voice bundle has an unsafe path."]))
            return
        }
        try? FileManager.default.createDirectory(
            at: Qwen3VoiceBundle.installRoot.appendingPathComponent("speech_tokenizer", isDirectory: true),
            withIntermediateDirectories: true)
        next()
    }

    func cancel() {
        activeTask?.cancel()
        reset()
    }

    private func reset() { activeTask = nil; onProgress = nil; onDone = nil; files = [] }

    private func dest(_ f: Qwen3VoiceBundle.File) -> URL {
        Qwen3VoiceBundle.installRoot.appendingPathComponent(f.path)
    }

    private func next() {
        attempts = 0
        while index < files.count {
            let f = files[index]
            if let size = (try? FileManager.default.attributesOfItem(atPath: dest(f).path)[.size]) as? Int64,
               size == f.bytes {
                doneBytes += f.bytes; index += 1; continue   // resume: already complete
            }
            let task = session.downloadTask(with: Qwen3VoiceBundle.url(f.path))
            task.taskDescription = f.path
            activeTask = task
            task.resume()
            return
        }
        onProgress?(1.0)
        onDone?(nil)
        reset()
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                                didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite _: Int64) {
        MainActor.assumeIsolated {
            onProgress?(min(1, Double(doneBytes + w) / Double(max(1, Qwen3VoiceBundle.totalBytes))))
        }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        let holding = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-qwen3-\(UUID().uuidString).part")
        try? FileManager.default.moveItem(at: loc, to: holding)
        let response = t.response
        let name = t.taskDescription ?? ""
        MainActor.assumeIsolated { finish(name: name, holding: holding, response: response) }
    }

    private func finish(name: String, holding: URL, response: URLResponse?) {
        guard index < files.count, files[index].path == name else {
            try? FileManager.default.removeItem(at: holding)
            onDone?(NSError(domain: "Slate", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected voice file."]))
            reset(); return
        }
        let file = files[index]
        do {
            guard let http = response as? HTTPURLResponse, let finalURL = http.url,
                  (200..<300).contains(http.statusCode),
                  finalURL.scheme?.lowercased() == "https" else {
                throw NSError(domain: "Slate", code: 3, userInfo: [NSLocalizedDescriptionKey: "Insecure or failed voice response."])
            }
            let received = (try? FileManager.default.attributesOfItem(atPath: holding.path)[.size] as? Int64) ?? -1
            guard received == file.bytes else {
                throw NSError(domain: "Slate", code: 4, userInfo: [NSLocalizedDescriptionKey: "Incomplete voice file \(file.path) (\(received) of \(file.bytes) bytes)."])
            }
            let d = dest(file)
            try FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: d)
            try FileManager.default.moveItem(at: holding, to: d)
        } catch {
            try? FileManager.default.removeItem(at: holding)
            onDone?(error); reset(); return
        }
        doneBytes += file.bytes
        activeTask = nil
        index += 1
        next()
    }

    nonisolated func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError e: Error?) {
        guard let e, (e as NSError).code != NSURLErrorCancelled else { return }
        MainActor.assumeIsolated {
            guard index < files.count else { onDone?(e); reset(); return }
            attempts += 1
            if attempts <= maxAttempts {
                let f = files[index]
                let task = session.downloadTask(with: Qwen3VoiceBundle.url(f.path))
                task.taskDescription = f.path
                activeTask = task
                task.resume()
            } else {
                onDone?(e); reset()
            }
        }
    }

    nonisolated private static func safeRelativePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains(".."), path.utf8.count <= 200 else { return false }
        let allowedExt = ["json", "txt", "safetensors"]
        guard let ext = path.split(separator: ".").last.map(String.init), allowedExt.contains(ext) else { return false }
        return path.utf8.allSatisfy { b in
            (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) ||
            b == 45 || b == 46 || b == 95 || b == 47
        }
    }
}

/// Offline premium TTS - Qwen3-TTS 0.6B on MLX/Metal. Mirrors SupertonicTTS:
/// prepare()/isReady/unload and synthesize → 44.1 kHz mono Float32 (the model is
/// native 24 kHz; resampled with the tested block-based converter). 100% offline -
/// loads only from the locally installed bundle, never the network.
actor Qwen3VoiceEngine {
    static let sampleRate: Double = 44_100

    private let root: URL
    private var model: Qwen3TTSModel?
    private var preparing: Task<Void, Error>?

    init(root: URL = Qwen3VoiceBundle.installRoot) {
        self.root = root
    }

    var isReady: Bool { model != nil }

    /// Load the MLX model (idempotent, coalesces concurrent callers). The first
    /// load reads ~1.7 GB from disk; subsequent synthesis is warm.
    func prepare() async throws {
        if model != nil { return }
        if let running = preparing { return try await running.value }
        let path = root.path
        let task = Task<Void, Error> {
            let m = try await Qwen3TTSModel.fromPretrained(path)
            self.install(m)
        }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    private func install(_ m: Qwen3TTSModel) { model = m }

    /// Synthesize one speakable chunk → 44.1 kHz mono Float32 samples.
    func synthesize(_ text: String, speaker: String) async throws -> [Float] {
        guard let model else { throw Qwen3VoiceError.notReady }
        let maxTokens = 2048
        let audio = try await model.generate(text: text, speaker: speaker, maxTokens: maxTokens)
        let native = audio.asArray(Float.self)

        // Derail guard: an autoregressive codec that fails to emit end-of-speech
        // runs to the token cap and fills it with silence/babble (laughing,
        // coughing, random syllables). Per-chunk speech is short, so a chunk that
        // (a) runs near the cap or (b) is mostly silence is a runaway - reject it
        // so the caller degrades to a reliable voice instead of playing garbage.
        let nativeRate = Double(model.sampleRate)
        let seconds = Double(native.count) / max(1, nativeRate)
        let capSeconds = Double(maxTokens) / 12.0 * 0.92      // 12 Hz codec frames
        let silence = native.isEmpty ? 1.0
            : Double(native.reduce(0) { $0 + (abs($1) < 0.01 ? 1 : 0) }) / Double(native.count)
        if native.isEmpty || seconds >= capSeconds || silence > 0.55 {
            throw Qwen3VoiceError.derailed
        }

        var samples = AudioResample.convert(native, from: nativeRate, to: Self.sampleRate)
        // Safety limiter - never ship clipping to the speaker.
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 1.0 {
            let gain = 0.985 / peak
            for i in samples.indices { samples[i] *= gain }
        }
        return samples
    }

    func unload() {
        model = nil
    }
}

enum Qwen3VoiceError: Error, LocalizedError {
    case notReady
    case derailed
    var errorDescription: String? {
        switch self {
        case .notReady: return "The premium voice model is not loaded yet."
        case .derailed: return "The premium voice produced an unusable result."
        }
    }
}
