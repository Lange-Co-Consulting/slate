import AVFoundation
import Foundation
import SlateCore
import SlateSTT

/// A live voice conversation over one Chat conversation: owns the audio IO,
/// VAD, STT, TTS and drives the pure VoiceTurnMachine. Created when the user
/// starts voice, torn down on end. All UI state is observable.
@MainActor @Observable
final class VoiceSession {
    enum Phase: Equatable {
        case chooseVoice             // first-ever launch: pick Slate's voice
        case preparing(Double)      // model download/load, 0…1
        case live                    // machine.state tells the sub-state
        case failed(String)
    }

    private(set) var phase: Phase = .preparing(0)
    private(set) var machineState: VoiceTurnMachine.State = .listening
    private(set) var micLevel: Float = 0
    /// Last utterance / status line shown under the mark.
    private(set) var caption = ""
    /// Slate's answer as it streams this turn, for the live transcript. Cleared
    /// once the finished message is committed to the conversation.
    private(set) var liveResponse = ""
    var muted = false {
        didSet { if muted { Task { await vad.reset() } } }
    }

    private let model: AppModel
    private let flow: FlowRuntime
    let convoID: Conversation.ID

    private var machine = VoiceTurnMachine()
    private let audio = VoiceAudioEngine()
    private let vad = StreamingVad()
    private let tts = SupertonicTTS()
    private let systemTTS = SystemTTS()
    private let qwen3 = Qwen3VoiceEngine()

    /// The voice to actually use: the saved one if it's a valid system, premium
    /// (installed), or Supertonic voice, else a safe Supertonic default. Heals a
    /// stale/blocked selection so voice never goes silent because of it.
    private var effectiveVoice: String {
        let v = model.settings.assistantVoice
        if SystemTTS.isSystemVoice(v) { return v }
        if Qwen3VoiceBundle.isQwen3Voice(v) {
            return (Qwen3VoiceBundle.enabled && Qwen3VoiceBundle.isInstalled) ? v : "M1"
        }
        if AppSettings.assistantVoices.contains(where: { $0.name == v }) { return v }
        return "M1"
    }

    /// Rolling 16 kHz capture; sliced into utterances on VAD speech-end.
    private var ring: [Float] = []
    private let ringCap = 16_000 * 60          // 60 s hard cap
    /// On speech-start the ring is trimmed to this much history (covers VAD
    /// event lag + its 0.1 s padding) so utterances are speech, not minutes of
    /// inter-turn silence.
    private let preRoll = 16_000 * 3 / 2       // 1.5 s

    /// FIFO pipe into the VAD: per-callback Tasks have no ordering guarantee,
    /// so samples flow through ONE stream consumed by one long-lived task.
    private var vadFeed: AsyncStream<[Float]>.Continuation?
    private var vadPump: Task<Void, Never>?

    private var llmTask: Task<Void, Never>?
    private var chunker = SentenceChunker()
    private var speakQueue: [String] = []
    private var synthesizing = false
    /// The language for the current spoken turn. It remains optional until the
    /// STT result or the local transcript classifier gives us a real signal.
    /// Never default this to German: Parakeet auto-detect currently returns text
    /// without a language code, which used to force every turn into German.
    private var detectedLanguage: String?
    /// The user kept talking while we transcribed: stash the partial text and
    /// stitch the continuation into ONE user turn instead of answering a
    /// truncated question over the user's voice.
    private var continuationOpen = false
    private var stashedUtterance = ""

    init(model: AppModel, flow: FlowRuntime, convoID: Conversation.ID) {
        self.model = model
        self.flow = flow
        self.convoID = convoID
        flow.voiceActive = true
        if model.settings.voiceChoiceMade {
            Task { await prepare() }
        } else {
            phase = .chooseVoice    // first launch: let the user pick Slate's voice
        }
    }

    /// First-launch chooser confirmed: persist the pick and start the session.
    func chooseVoice(_ voice: String) {
        model.speech.stop()          // stop any preview playback
        model.settings.assistantVoice = voice
        model.settings.voiceChoiceMade = true
        phase = .preparing(0)
        Task { await prepare() }
    }

    // MARK: lifecycle

    struct VoicePrepTimeout: Error {}

    /// Run an async model-prep step with a hard time budget so voice preparation
    /// can never spin forever. On timeout the loser task is cancelled and the
    /// caller falls back to an installed macOS voice (or skips STT warm-up).
    nonisolated static func withTimeout<T: Sendable>(
        _ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw VoicePrepTimeout()
            }
            guard let result = try await group.next() else { throw VoicePrepTimeout() }
            group.cancelAll()
            return result
        }
    }

    private func prepare() async {
        do {
            // Mic permission first - same call Flow uses (idempotent system prompt).
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                phase = .failed("No microphone access - allow it in System Settings → Privacy & Security.")
                return
            }
            if SystemTTS.isSystemVoice(effectiveVoice) {
                phase = .preparing(0.8)          // system voices need no model download
            } else if Qwen3VoiceBundle.isQwen3Voice(effectiveVoice) {
                do {
                    // First load reads ~1.7 GB into MLX - allow more than the usual
                    // budget, but still never spin forever; fall back to a system
                    // voice on timeout/error so voice always starts.
                    let q = qwen3
                    try await Self.withTimeout(60) { try await q.prepare() }
                    phase = .preparing(0.8)
                } catch {
                    // Runtime fallback ONLY - never rewrite the user's saved choice.
                    guard SystemTTS.defaultVoiceID != nil else { throw error }
                    phase = .preparing(0.8)
                }
            } else {
                do {
                    // Provision the neural voice on first use when downloads are
                    // allowed (~100 MB once) - otherwise picking M1/F1 silently
                    // falls back to the SAME system voice and the choice appears
                    // to do nothing. Downloads blocked → cache-only attempt.
                    let t = tts, voice = effectiveVoice
                    let allowDL = model.settings.remoteModelDownloadsEnabled && !model.settings.silentModeEnabled
                    try await Self.withTimeout(allowDL ? 180 : 25) {
                        try await t.prepareAllowingDownload(voices: [voice], allowDownload: allowDL) { p in
                            Task { @MainActor [weak self] in self?.phase = .preparing(p * 0.8) }
                        }
                    }
                    phase = .preparing(0.8)
                } catch {
                    // Runtime fallback ONLY - never rewrite the user's saved choice.
                    guard SystemTTS.defaultVoiceID != nil else { throw error }
                    phase = .preparing(0.8)
                }
            }
            phase = .preparing(0.85)
            try await vad.prepare()
            phase = .preparing(0.95)
            let stt = flow.stt
            try? await Self.withTimeout(25) { try await stt.prepare() }  // usually warm already (Flow)
            wireAudio()
            try audio.start()
            phase = .live
            caption = audio.echoCancelled
                ? "" : "Without echo cancellation the mic pauses while Slate speaks."
        } catch let e as VoiceAudioEngine.VoiceAudioError {
            phase = .failed(e.localizedDescription)
        } catch {
            phase = .failed("Couldn't load the speech models: \(error.localizedDescription)")
        }
    }

    func end() {
        model.speech.stop()          // a voice-chooser preview may still be playing
        run(machine.handle(.end))
        llmTask?.cancel()
        vadFeed?.finish()
        vadPump?.cancel()
        audio.stop()
        ring.removeAll(keepingCapacity: false)
        stashedUtterance = ""
        speakQueue.removeAll(keepingCapacity: false)
        flow.voiceActive = false
        systemTTS.stop()
        Task { [tts] in await tts.unload() }
        Task { [qwen3] in await qwen3.unload() }   // frees the ~2 GB MLX weights
    }

    // MARK: audio wiring

    private func wireAudio() {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        vadFeed = continuation
        vadPump = Task { [weak self] in
            for await batch in stream {
                guard let self, !Task.isCancelled else { break }
                await self.pumpVad(batch)
            }
        }
        audio.onLevel = { [weak self] l in self?.micLevel = l }
        audio.onSamples = { [weak self] samples in
            guard let self, phase == .live, !muted else { return }
            // Half-duplex fallback: without AEC, ignore the mic while speaking.
            if !audio.echoCancelled && (machineState == .speaking || audio.isSpeaking) { return }
            ring.append(contentsOf: samples)
            if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }
            vadFeed?.yield(samples)   // FIFO - ordering preserved
        }
        audio.onPlaybackDrained = { [weak self] in
            guard let self else { return }
            if speakQueue.isEmpty && !synthesizing { run(machine.handle(.playbackDrained)) }
        }
        audio.onInterrupted = { [weak self] message in
            guard let self else { return }
            model.voiceStop()
            llmTask?.cancel()
            phase = .failed(message)
        }
    }

    private func pumpVad(_ samples: [Float]) async {
        guard let events = try? await vad.feed(samples) else { return }
        for e in events {
            switch e {
            case .speechStart:
                switch machineState {
                case .thinking, .speaking:
                    run(machine.handle(.bargeIn))
                    // Drop the stale thinking/speaking audio (AEC residue of
                    // Slate's own voice) so only the interruption is transcribed.
                    if ring.count > preRoll { ring.removeFirst(ring.count - preRoll) }
                case .listening:
                    // Fresh utterance begins - drop the accumulated inter-turn
                    // silence so Parakeet gets speech, not minutes of quiet.
                    if ring.count > preRoll { ring.removeFirst(ring.count - preRoll) }
                case .transcribing:
                    // User kept talking: DON'T trim (the ring already holds the
                    // continuation since the slice) - stitch both parts later.
                    continuationOpen = true
                case .idle: break
                }
            case .speechEnd:
                if machineState == .listening { run(machine.handle(.speechEnd)) }
            }
        }
    }

    // MARK: command execution

    private func run(_ commands: [VoiceTurnMachine.Command]) {
        machineState = machine.state
        for c in commands { execute(c) }
    }

    private func execute(_ c: VoiceTurnMachine.Command) {
        switch c {
        case .transcribeUtterance:
            let utterance = ring
            ring = []
            Task { [weak self] in
                guard let self else { return }
                // Respect the explicit Dictation setting. In auto mode Parakeet
                // may not return a language code, so resolve from its local text.
                let t = try? await flow.stt.transcribe(utterance, language: flow.language)
                let combined = (stashedUtterance + " " + (t?.text ?? ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                detectedLanguage = VoiceLanguage.resolve(reported: t?.detectedLanguage ?? flow.language,
                                                         transcript: combined)
                caption = combined
                if continuationOpen {
                    // The user is still talking - hold the text, keep listening,
                    // and commit everything as ONE turn when they finish.
                    continuationOpen = false
                    stashedUtterance = combined
                    run(machine.handle(.transcriptPartial))
                } else {
                    stashedUtterance = ""
                    run(machine.handle(.transcript(combined)))
                }
            }
        case .discardUtterance:
            ring = []
            caption = ""
        case .appendUser(let text):
            model.appendVoiceMessage(role: .user, text: text, to: convoID)
        case .startLLM(let text):
            startLLM(user: text)
        case .speak(let chunk):
            speakQueue.append(chunk)
            drainSpeakQueue()
        case .stopSpeaking:
            speakQueue = []
            audio.stopSpeaking()
            systemTTS.stop()
        case .cancelLLM:
            model.voiceStop()
            llmTask?.cancel()
        case .appendAssistant(let text):
            model.appendVoiceMessage(role: .assistant, text: text, to: convoID)
            liveResponse = ""
        }
    }

    private func startLLM(user: String) {
        let history = (model.conversations.first { $0.id == convoID }?.messages ?? [])
            .filter { $0.role == .user || $0.role == .assistant }
            .dropLast()                                    // the just-appended user line
        chunker = SentenceChunker()
        liveResponse = ""
        llmTask = Task { [weak self] in
            guard let self else { return }
            do {
                let full = try await model.voiceGenerate(history: Array(history), user: user,
                                                         language: detectedLanguage) { [weak self] piece in
                    guard let self else { return }
                    self.liveResponse += piece
                    for chunk in chunker.feed(piece) {
                        run(machine.handle(.llmChunk(chunk)))
                    }
                }
                guard !Task.isCancelled else { return }
                for chunk in chunker.finish() { run(machine.handle(.llmChunk(chunk))) }
                run(machine.handle(.llmFinished(full)))
                // Rescue: if playback already drained BEFORE the stream finished
                // (e.g. short intro sentence + long skipped code block), no drain
                // event will ever come again - end the turn here. All state is
                // MainActor-synchronous, so this can't race a pending synth.
                if machineState == .speaking, speakQueue.isEmpty, !synthesizing, !audio.isSpeaking {
                    run(machine.handle(.playbackDrained))
                }
            } catch is CancellationError {
                // barge-in / end - the machine already handled the transition
            } catch {
                caption = "Model not ready - \(error.localizedDescription)"
                run(machine.handle(.llmFailed))
            }
        }
    }

    /// Synthesize queued chunks strictly in order, one at a time.
    private func drainSpeakQueue() {
        guard !synthesizing, !speakQueue.isEmpty else { return }
        synthesizing = true
        let chunk = speakQueue.removeFirst()
        let lang = detectedLanguage ?? VoiceLanguage.systemFallback
        Task { [weak self] in
            guard let self else { return }
            let voice = effectiveVoice
            var samples: [Float]
            if Qwen3VoiceBundle.isQwen3Voice(voice) {
                samples = (try? await qwen3.synthesize(chunk, speaker: Qwen3VoiceBundle.speakerID(from: voice))) ?? []
            } else if SystemTTS.isSystemVoice(voice) {
                samples = (try? await systemTTS.synthesize(chunk, voiceID: voice)) ?? []
            } else {
                samples = (try? await tts.synthesize(chunk, language: lang, voice: voice)) ?? []
            }
            // A neural engine that isn't ready must degrade to an audible system
            // voice for THIS turn, not to silence (the saved choice stays intact).
            if samples.isEmpty, !SystemTTS.isSystemVoice(voice), let sys = SystemTTS.defaultVoiceID {
                samples = (try? await systemTTS.synthesize(chunk, voiceID: sys)) ?? []
            }
            synthesizing = false
            if machineState == .speaking && !samples.isEmpty { audio.speak(samples) }
            if !speakQueue.isEmpty {
                drainSpeakQueue()
            } else if machineState == .speaking && !audio.isSpeaking {
                // Synthesis yielded nothing playable and the player is idle  - 
                // don't strand the turn waiting for a drain that never comes.
                run(machine.handle(.playbackDrained))
            }
        }
    }
}
