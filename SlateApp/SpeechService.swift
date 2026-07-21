@preconcurrency import AVFoundation
import SlateCore
import SlateSTT

/// "Read aloud" for any assistant message - reuses the bundled Supertonic-3 TTS
/// and a dedicated playback engine (separate from the Voice session, which owns
/// capture+playback). One at a time: starting playback stops the previous.
@MainActor @Observable
final class SpeechService {
    /// The message currently being read (drives the button state), or nil.
    private(set) var speakingID: UUID?
    private(set) var preparing = false
    /// Mirrors the app's network gate (set by AppModel): when true, picking an
    /// unprovisioned neural voice downloads it once (~100 MB) instead of silently
    /// previewing with the system voice forever.
    var allowVoiceDownload = false

    private let tts = SupertonicTTS()
    private let systemTTS = SystemTTS()
    private let qwen3 = Qwen3VoiceEngine()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: SupertonicTTS.sampleRate, channels: 1)!
    private var attached = false
    private var task: Task<Void, Never>?

    /// Toggle read-aloud for a message: stop if it's already reading, else start.
    func toggle(_ text: String, id: UUID, voice: String = "F1") {
        if speakingID == id { stop(); return }
        stop()
        let clean = Reasoning.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let language = VoiceLanguage.resolve(reported: nil, transcript: clean) ?? VoiceLanguage.systemFallback
        speakingID = id
        preparing = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Pick the backend from the voice value: "qwen3:" → the premium MLX
                // voice, a macOS system voice → AVSpeechSynthesizer, else Supertonic.
                // Each falls back to the system voice if its model is not ready.
                enum Backend { case qwen3(String); case supertonic; case system }
                var backend: Backend
                let useVoice = (Qwen3VoiceBundle.isQwen3Voice(voice) && !Qwen3VoiceBundle.enabled) ? "M1" : voice
                if Qwen3VoiceBundle.enabled, Qwen3VoiceBundle.isQwen3Voice(useVoice) {
                    do { try await qwen3.prepare(); backend = .qwen3(Qwen3VoiceBundle.speakerID(from: useVoice)) }
                    catch { backend = .system }
                } else if SystemTTS.isSystemVoice(useVoice) {
                    backend = .system
                } else {
                    do {
                        try await tts.prepareAllowingDownload(voices: [useVoice], allowDownload: allowVoiceDownload)
                        backend = .supertonic
                    } catch { backend = .system }
                }
                preparing = false
                try startEngine()
                var chunker = SentenceChunker()
                var chunks = chunker.feed(clean); chunks += chunker.finish()
                if chunks.isEmpty { chunks = [clean] }
                for chunk in chunks {
                    if Task.isCancelled { break }
                    var samples: [Float]
                    switch backend {
                    case .qwen3(let speaker):
                        samples = (try? await qwen3.synthesize(chunk, speaker: speaker)) ?? []
                    case .supertonic:
                        samples = (try? await tts.synthesize(chunk, language: language, voice: useVoice)) ?? []
                    case .system:
                        // The user's selected system voice, else the best installed one.
                        if let sv = SystemTTS.isSystemVoice(useVoice) ? useVoice : SystemTTS.defaultVoiceID {
                            samples = (try? await systemTTS.synthesize(chunk, voiceID: sv)) ?? []
                        } else {
                            samples = []
                        }
                    }
                    // A derailed/empty neural chunk must degrade to an audible
                    // system voice for this chunk, never to silence or garbage.
                    if samples.isEmpty, case .system = backend {} else if samples.isEmpty,
                       let sv = SystemTTS.defaultVoiceID {
                        samples = (try? await systemTTS.synthesize(chunk, voiceID: sv)) ?? []
                    }
                    if Task.isCancelled { break }
                    schedule(samples)
                }
                // Finished synthesizing; playback drains and clears the state.
                await waitForDrain()
            } catch {
                // Model unavailable / offline - quietly reset.
            }
            if !Task.isCancelled { finish() }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        if attached { player.stop() }
        systemTTS.stop()
        pending = 0
        speakingID = nil
        preparing = false
    }

    var isSpeaking: Bool { speakingID != nil }

    // MARK: playback

    private var pending = 0

    private func startEngine() throws {
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            attached = true
        }
        if !engine.isRunning { engine.prepare(); try engine.start() }
    }

    private func schedule(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        pending += 1
        player.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor in self?.pending -= 1 }
        }
        if !player.isPlaying { player.play() }
    }

    private func waitForDrain() async {
        while pending > 0 && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private func finish() {
        speakingID = nil
        preparing = false
        if attached { player.stop() }
        engine.stop()
    }
}
