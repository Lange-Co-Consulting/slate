@preconcurrency import AVFoundation

/// macOS system neural voices (AVSpeechSynthesizer) as an alternative TTS source.
/// Apple's *enhanced* and *premium* voices sound more human than the compact
/// Supertonic model and are fully offline. Output is captured via `write(_:)` and
/// resampled to the engine's 44.1 kHz mono Float32 so it drops into `speak`.
///
/// IMPORTANT: Apple blocks the "Siri" voices from third-party synthesis (they yield
/// no audio), so they are filtered out, and every synth call is bounded by a hard
/// timeout - a voice that produces nothing must never stall the voice turn.
@MainActor
final class SystemTTS {
    private static let outFmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    /// Kept alive for the session so an in-flight `write(_:)` can't be torn down.
    private let synth = AVSpeechSynthesizer()

    init() {}

    /// Natural (enhanced/premium) voices, excluding Siri voices (blocked for
    /// third-party synthesis) and novelty voices. Best language first for the UI.
    nonisolated static func naturalVoices() -> [(id: String, label: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { v in
                (v.quality == .enhanced || v.quality == .premium)
                    && !v.identifier.lowercased().contains("siri")
                    && !v.voiceTraits.contains(.isNoveltyVoice)
            }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
            .map { v in
                let q = v.quality == .premium ? "Premium" : "Enhanced"
                let lang = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
                return (v.identifier, "\(v.name) · \(lang) · \(q)")
            }
    }

    /// A no-download voice that exists on this Mac, preferring the user's
    /// current language and higher-quality installed voices.
    nonisolated static var defaultVoiceID: String? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.identifier.lowercased().contains("siri") && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        return candidates.sorted {
            let l = $0.language.hasPrefix(language) ? 0 : 1
            let r = $1.language.hasPrefix(language) ? 0 : 1
            if l != r { return l < r }
            return $0.quality.rawValue > $1.quality.rawValue
        }.first?.identifier
    }

    /// True for a selectable system voice we can actually drive (excludes Siri ids).
    nonisolated static func isSystemVoice(_ id: String) -> Bool {
        guard !id.lowercased().contains("siri") else { return false }
        return AVSpeechSynthesisVoice(identifier: id) != nil
    }

    /// Synthesize one chunk → 44.1 kHz mono Float32. Empty on any failure OR after a
    /// hard timeout, so a silent/blocked voice can never hang the turn.
    func synthesize(_ text: String, voiceID: String) async throws -> [Float] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let voice = AVSpeechSynthesisVoice(identifier: voiceID) else { return [] }
        let utt = AVSpeechUtterance(string: text)
        utt.voice = voice
        let box = SynthBox(out: Self.outFmt)

        let timeout = Task { [weak synth] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)   // 6 s hard cap
            synth?.stopSpeaking(at: .immediate)
            box.forceResume()
        }
        let samples = await withCheckedContinuation { (cont: CheckedContinuation<[Float], Never>) in
            box.cont = cont
            synth.write(utt) { @Sendable buffer in box.handle(buffer) }
        }
        timeout.cancel()
        return samples
    }

    func stop() { synth.stopSpeaking(at: .immediate) }
}

/// Collects `write(_:)`'s streamed buffers and resamples each to 44.1 kHz mono
/// Float32. Lock-guarded because the write callback AND the timeout task can both
/// try to finish the continuation - resuming twice would crash.
private final class SynthBox: @unchecked Sendable {
    private let lock = NSLock()
    private let outFmt: AVAudioFormat
    private var converter: AVAudioConverter?
    private var collected: [Float] = []
    private var resumed = false
    var cont: CheckedContinuation<[Float], Never>?

    init(out: AVAudioFormat) { outFmt = out }

    func handle(_ buffer: AVAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed, let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 { resumeLocked(); return }   // empty buffer = end
        if converter == nil { converter = AVAudioConverter(from: pcm.format, to: outFmt) }
        if let s = resample(pcm) { collected.append(contentsOf: s) }
    }

    func forceResume() {
        lock.lock(); defer { lock.unlock() }
        resumeLocked()
    }

    private func resumeLocked() {
        guard !resumed else { return }
        resumed = true
        cont?.resume(returning: collected)
        cont = nil
    }

    private func resample(_ buf: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else { return nil }
        let ratio = outFmt.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return nil }
        var err: NSError?
        let source = PCMInputBox(buf)
        converter.convert(to: out, error: &err) { _, status in
            guard let next = source.take() else {
                status.pointee = .noDataNow; return nil
            }
            status.pointee = .haveData; return next
        }
        guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

/// AVAudioConverter marks its input callback Sendable even though AVAudioPCMBuffer
/// is an Objective-C reference type. Single-use, lock-guarded ownership makes the
/// cross-callback handoff explicit and race-free.
private final class PCMInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        lock.withLock { defer { buffer = nil }; return buffer }
    }
}
