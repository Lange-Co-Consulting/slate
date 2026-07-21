@preconcurrency import AVFoundation

/// The voice session's audio IO: ONE AVAudioEngine doing both mic capture
/// (16 kHz mono Float32 out via onSamples) and TTS playback (44.1 kHz queue).
/// Voice-processing is enabled on the input node → Apple's echo cancellation,
/// so the VAD doesn't hear Slate's own voice and barge-in works with speakers.
///
/// Inherits AudioCapture's hard-won crash rules (AudioCapture.swift:3-11):
/// prepare() only AFTER the tap is installed; the tap closure is @Sendable and
/// all audio-thread state lives in an @unchecked Sendable box.
@MainActor
final class VoiceAudioEngine {
    enum VoiceAudioError: LocalizedError {
        case noInputDevice
        case engineStartFailed(Int)
        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No microphone found - please connect an input device."
            case .engineStartFailed(let code):
                return "The audio engine couldn't start (error \(code)). Another app may be "
                     + "holding the microphone - close it or try again in a moment."
            }
        }
    }

    /// Once enabling voice processing has wedged a graph in this process (-10875 at
    /// engine.start), every later toggle fails too, even on fresh engines - the HAL's
    /// VPIO state is poisoned until the app relaunches. Remember and never retry it:
    /// voice then runs half-duplex (the proven dictation path) instead of failing.
    private static var vpioBrokenThisProcess = false

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var running = false
    private var playerAttached = false
    private var scheduledBuffers = 0
    private var configObserver: NSObjectProtocol?
    /// AEC actually engaged? (Fallback: mic pauses while speaking - no barge-in.)
    private(set) var echoCancelled = false

    var onSamples: ((_ samples: [Float]) -> Void)?   // 16 kHz mono, main actor
    var onLevel: ((Float) -> Void)?
    var onPlaybackDrained: (() -> Void)?
    /// The audio graph died and couldn't be rebuilt (device unplugged mid-session).
    var onInterrupted: ((String) -> Void)?

    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    func start() throws {
        guard !running else { return }
        // Best-effort AEC. Enabling can "succeed" and the graph still fail to
        // INITIALISE at engine.start() (kAudioUnitErr_FailedInitialization, -10875),
        // a known VPIO quirk. Worse: once that happened, the process's VPIO state is
        // wedged - so we only ever try it while it has never failed here.
        if !Self.vpioBrokenThisProcess {
            do { try engine.inputNode.setVoiceProcessingEnabled(true); echoCancelled = true }
            catch { echoCancelled = false }
        } else {
            echoCancelled = false
        }

        attachPlayerIfNeeded()

        do {
            try startGraph()
        } catch {
            // First start failed. If VPIO was on, blame it and never try it again this
            // process. Either way: retry ONCE on a completely FRESH engine (an engine
            // whose input node saw a VPIO toggle keeps a broken format and cannot be
            // revived - reusing it is why voice used to fail until relaunch). The
            // plain path is what the proven dictation capture uses.
            if echoCancelled {
                Self.vpioBrokenThisProcess = true
                echoCancelled = false
            }
            rebuildEngine()
            Thread.sleep(forTimeInterval: 0.3)          // let the HAL settle
            do { try startGraph() } catch {
                throw VoiceAudioError.engineStartFailed((error as NSError).code)
            }
        }
        running = true
        observeConfigChanges()
    }

    private func attachPlayerIfNeeded() {
        guard !playerAttached else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        playerAttached = true
    }

    /// Throw away the (possibly VPIO-poisoned) engine and build a pristine one.
    private func rebuildEngine() {
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
            configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        playerAttached = false
        scheduledBuffers = 0
        attachPlayerIfNeeded()
    }

    /// Install the converting tap for the CURRENT input format, then start the graph.
    /// Re-runnable: `start()` calls it again (tap removed) if AEC init fails, because
    /// toggling voice-processing changes the input node's format.
    private func startGraph() throws {
        // sampleRate 0 = no usable input device (permission was already granted
        // by the session before calling start).
        guard installTap() else { throw VoiceAudioError.noInputDevice }
        engine.prepare()                    // safe HERE: the graph has tap + player
        try engine.start()
    }

    /// Resolve the CURRENT input device format and install the converting tap.
    private func installTap() -> Bool {
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0,
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let box = VoiceTapBox(from: inFmt, to: outFmt) else { return false }

        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { @Sendable [weak self] buf, _ in
            // Audio thread: convert + measure here, touch NO MainActor state.
            guard let chunk = box.convert(buf) else { return }
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onLevel?(min(1, rms * 12))
                if !chunk.isEmpty { self.onSamples?(chunk) }
            }
        }
        return true
    }

    /// Unplugging the mic / switching AirPods invalidates the graph - playing
    /// on a dead graph raises an NSException. Rebuild for the new device.
    private func observeConfigChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildAfterConfigChange() }
        }
    }

    private func rebuildAfterConfigChange() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        scheduledBuffers = 0
        guard installTap() else {
            stop()
            onInterrupted?("Microphone disconnected - conversation ended.")
            return
        }
        engine.prepare()
        do { try engine.start() } catch {
            stop()
            onInterrupted?("Audio device changed - restart failed.")
            return
        }
        onPlaybackDrained?()   // the queue was dumped; let the turn settle
    }

    func stop() {
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
            configObserver = nil
        }
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        // Leave the process's audio state clean: an input node left with voice
        // processing enabled wedges the NEXT session's VPIO enable (-10875).
        if echoCancelled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            echoCancelled = false
        }
        scheduledBuffers = 0
        running = false
    }

    /// Queue one synthesized chunk (44.1 kHz mono Float32).
    func speak(_ samples: [Float]) {
        guard running, engine.isRunning, !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: playFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        scheduledBuffers += 1
        player.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduledBuffers -= 1
                if self.scheduledBuffers <= 0 {
                    self.scheduledBuffers = 0
                    self.onPlaybackDrained?()
                }
            }
        }
        if !player.isPlaying { player.play() }
    }

    var isSpeaking: Bool { scheduledBuffers > 0 }

    /// Barge-in / session end: dump the queue immediately.
    func stopSpeaking() {
        guard running else { return }
        player.stop()          // fires completions; counter zeroes via them
        scheduledBuffers = 0
    }
}

/// Conversion state confined to the tap's audio queue - the same pattern as
/// AudioCapture's TapBox. @unchecked Sendable is sound because AVFAudio
/// serializes tap callbacks.
private final class VoiceTapBox: @unchecked Sendable {
    private final class FeedState: @unchecked Sendable { var didFeed = false }
    private let converter: AVAudioConverter
    private let outFmt: AVAudioFormat
    private let ratio: Double

    init?(from inFmt: AVAudioFormat, to outFmt: AVAudioFormat) {
        guard let c = AVAudioConverter(from: inFmt, to: outFmt) else { return nil }
        converter = c
        self.outFmt = outFmt
        ratio = outFmt.sampleRate / inFmt.sampleRate
    }

    /// One input buffer → 16 kHz mono Float32 chunk (nil on conversion failure).
    func convert(_ buf: AVAudioPCMBuffer) -> [Float]? {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return nil }
        var err: NSError?
        let feed = FeedState()
        converter.convert(to: out, error: &err) { _, status in
            if feed.didFeed { status.pointee = .noDataNow; return nil }
            feed.didFeed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, let ch = out.floatChannelData else { return nil }
        let n = Int(out.frameLength)
        guard n > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }
}
