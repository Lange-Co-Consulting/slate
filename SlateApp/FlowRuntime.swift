import AppKit
import AVFoundation
import Observation
import SwiftUI
import SlateFlowCore
import SlateFlowCleanup
import SlateSTT

/// Wires the real OS pieces (tap, mic, STT, inserter) into DictationController
/// and owns the Flow Bar panel. One instance, created by SlateApp, alive for
/// the app's lifetime. M2 swaps the identity `cleanup` for the LLM pass.
@MainActor @Observable
final class FlowRuntime {
    let stt = ParakeetEngine()
    let audio = AudioCapture()
    let inserter = TextInserter()
    let hotkey = HotkeyMonitor()
    /// True while a voice conversation owns the microphone - Fn push-to-talk
    /// and composer dictation stand down (one mic consumer at a time).
    var voiceActive = false
    private(set) var controller: DictationController!
    private var panel: FlowBarPanel?
    private var capTimer: Timer?
    private var panelMoveObserver: NSObjectProtocol?
    /// true = the pill lives inside the Slate window; false = floating panel.
    /// Detach: drag the docked pill past its magnetic tether. Re-dock: drag the
    /// panel near the window's bottom-right corner and it snaps back in.
    var pillDocked: Bool = UserDefaults.standard.object(forKey: "slate.flow.docked") == nil
        ? true : UserDefaults.standard.bool(forKey: "slate.flow.docked") {
        didSet { UserDefaults.standard.set(pillDocked, forKey: "slate.flow.docked") }
    }
    var level: Float = 0
    /// Rolling mic-level history feeding the Flow Bar's scrolling waveform
    /// (newest last, capped). Real data - the animation never fakes voice.
    var levelHistory: [Float] = []
    /// When the current recording started - drives the pill's mm:ss timer.
    var recordStartedAt: Date?
    /// STT model download/load state for settings UI ("Preparing…" chip).
    var preparing = false
    var prepareError: String?

    var enabled: Bool = UserDefaults.standard.bool(forKey: "slate.flow.enabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "slate.flow.enabled")
            enabled ? start() : stopAll()
        }
    }
    /// Language override for the STT pass; nil = auto-detect (per session).
    var language: String? = UserDefaults.standard.string(forKey: "slate.flow.language") {
        didSet {
            UserDefaults.standard.set(language, forKey: "slate.flow.language")
            controller.language = language
        }
    }
    var languageLabel: String { language?.uppercased() ?? "AUTO" }

    /// Cleanup intensity (spec item 6). `.none` = raw mode.
    var style: CleanupStyle = CleanupStyle(rawValue:
        UserDefaults.standard.string(forKey: "slate.flow.style") ?? "medium") ?? .medium {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "slate.flow.style") }
    }
    /// Personal dictionary (spec item 9): wrong→right replacements + prompt terms.
    var dictionary = FlowDictionary.load() {
        didSet { dictionary.save() }
    }
    /// The chat model that powers cleanup - attached by SlateApp after both exist.
    private weak var appModel: AppModel?
    /// History bookkeeping for the entry written after a successful insert.
    private var lastRaw = ""
    private var lastDuration = 0.0
    /// A recording parked by a previous crash, offered for recovery in Settings.
    var recoveredSamples: [Float]?
    /// The app the user is dictating INTO - captured when recording starts
    /// (the pill never steals focus, so frontmost = the target).
    private var targetBundleID: String?
    /// Composer dictation (mic button next to the paperclip): when set, the
    /// finished transcript goes into this closure instead of the system-wide
    /// TextInserter. Needs ONLY mic permission - no tap, no AX, works even
    /// with Flow disabled.
    private var composerInsert: ((String) -> Void)?
    var composerRecording = false
    /// Why the LLM cleanup pass will be skipped right now (nil = ready)  - 
    /// surfaced in Settings so "Medium filtert nichts" is never a mystery.
    var cleanupNote: String?

    init() {
        controller = DictationController(deps: .init(
            startCapture: { [weak self] in
                guard let self else { return }
                if !composerRecording { composerInsert = nil }   // stale-override guard
                targetBundleID = ContextReader.frontmostBundleID()
                levelHistory.removeAll()
                recordStartedAt = .now
                audio.start()
            },
            stopCapture: { [weak self] in
                guard let self else { return [] }
                let samples = audio.stop()
                recordStartedAt = nil
                // Crash safety: park the raw audio until the insert lands.
                FlowHistory.parkRecording(samples)
                lastDuration = Double(samples.count) / 16_000
                return samples
            },
            transcribe: { [weak self, stt] samples, lang in
                let raw = try await stt.transcribe(samples, language: lang).text
                guard let self else { return raw }
                let fixed = dictionary.apply(to: raw)   // deterministic vocab pass
                lastRaw = fixed
                return fixed
            },
            cleanup: { [weak self] text, bundleID in
                await self?.polish(text, bundleID: bundleID) ?? text
            },
            insert: { [weak self] text in await self?.deliver(text) ?? false },
            now: { CFAbsoluteTimeGetCurrent() }))
        controller.language = language
        audio.onLevel = { [weak self] l in
            guard let self else { return }
            level = l
            levelHistory.append(l)
            if levelHistory.count > 64 { levelHistory.removeFirst(levelHistory.count - 64) }
        }
        recoveredSamples = FlowHistory.parkedRecording()
    }

    func connectLLM(_ model: AppModel) { appModel = model }

    /// Rules always run; the LLM pass silently falls back to rules-only when
    /// the engine is missing/busy/slow (CleanupService owns those guards).
    private func polish(_ text: String, bundleID: String?) async -> String {
        let model = appModel
        cleanupNote = model?.flowCleanupBlocker ?? "Not connected to a model."
        let svc = CleanupService(
            generate: { system, user in
                guard let model else { throw AppModel.FlowLLMError.busy }
                return try await model.flowGenerate(system: system, user: user)
            },
            isBusy: { false },   // busy-ness is enforced inside flowGenerate (MainActor state)
            timeout: 8.0)        // thinking models (gpt-oss/Qwen) reason before answering
        let category = AppCategory(rawValue: ContextReader.category(forBundleID: targetBundleID)) ?? .other
        return await svc.polish(text, language: language, style: style,
                                appCategory: category,
                                dictionary: dictionary.promptTerms)
    }

    /// Transcribe a crash-parked recording, put it on the clipboard + history.
    func recoverParkedDictation() async {
        guard let samples = recoveredSamples else { return }
        recoveredSamples = nil
        do {
            let raw = try await stt.transcribe(samples, language: language).text
            let fixed = dictionary.apply(to: raw)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fixed, forType: .string)
            FlowHistory.append(.init(raw: fixed, polished: fixed,
                                     durationSec: Double(samples.count) / 16_000))
            FlowHistory.clearParkedRecording()
        } catch {
            prepareError = "Recovery failed: \(error.localizedDescription)"
        }
    }

    /// Menu-bar action: hide the pill for an hour (spec item 3).
    func hideBarForAnHour() {
        panel?.orderOut(nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3600))
            guard let self, enabled, !pillDocked else { return }
            panel?.orderFrontRegardless()
        }
    }

    // MARK: Dock / detach (magnetic pill)

    /// Called by DockedFlowPill when the drag breaks the magnetic tether: the
    /// pill pops out of the window into the floating panel, right under the
    /// cursor, with a quick fade-in.
    func detachPill() {
        pillDocked = false
        showPanel(at: NSEvent.mouseLocation)
    }

    /// Pull the floating pill back into the window (magnet or menu action).
    func dockPill() {
        pillDocked = true
        if let p = panel {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                p.animator().alphaValue = 0
            }, completionHandler: { Task { @MainActor [weak self] in self?.teardownPanel() } })
        }
    }

    private func showPanel(at screenPoint: NSPoint?) {
        let p: FlowBarPanel
        if let existing = panel { p = existing } else {
            p = FlowBarPanel(content: FlowBarView().environment(self))
            panel = p
            watchPanelMoves(p)
        }
        if let pt = screenPoint {
            p.setFrameOrigin(.init(x: pt.x - p.frame.width / 2, y: pt.y - p.frame.height / 2))
        } else {
            p.positionBottomCenter()
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }
    }

    private func teardownPanel() {
        if let o = panelMoveObserver { NotificationCenter.default.removeObserver(o) }
        panelMoveObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Magnetic re-dock: whenever the floating pill is dragged near its dock
    /// slot - the sidebar's bottom cluster (window bottom-LEFT) - it snaps back
    /// inside.
    private func watchPanelMoves(_ p: FlowBarPanel) {
        panelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel,
                      let win = NSApp.windows.first(where: { $0.isVisible && !($0 is FlowBarPanel) && !($0 is NSPanel) }) else { return }
                let dock = NSPoint(x: win.frame.minX + 145, y: win.frame.minY + 110)
                let center = NSPoint(x: p.frame.midX, y: p.frame.midY)
                if hypot(center.x - dock.x, center.y - dock.y) < 110 {
                    self.dockPill()
                }
            }
        }
    }

    /// Called from SlateApp bootstrap AND whenever the user flips the toggle.
    func start() {
        guard enabled else { return }
        guard HotkeyMonitor.preflight() else { return }         // onboarding prompts separately
        hotkey.onEdge = { [weak self] e in
            guard let self, !self.voiceActive else { return }   // voice session owns the mic
            self.controller.fnEdge(e)
        }
        hotkey.onEsc = { [weak self] in
            self?.controller.cancel()
            self?.composerInsert = nil
            self?.composerRecording = false
        }
        hotkey.start()
        if !pillDocked { showPanel(at: nil) }               // docked pill renders in RootView
        // Enforce the session cap while recording.
        capTimer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.controller.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        capTimer = t
        warmSTT()
    }

    func stopAll() {
        hotkey.stop()
        teardownPanel()
        capTimer?.invalidate()
        capTimer = nil
    }

    /// Download/load the Parakeet models off the critical path.
    func warmSTT() {
        guard !preparing else { return }
        preparing = true
        prepareError = nil
        Task { [stt] in
            do { try await stt.prepare() }
            catch { self.prepareError = "Speech model failed to load: \(error.localizedDescription)" }
            self.preparing = false
        }
    }

    /// Ask for mic + AX + Input Monitoring; returns whether the tap can run.
    func requestPermissions() async -> Bool {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        HotkeyMonitor.requestPermissions()
        return HotkeyMonitor.preflight()
    }

    private func deliver(_ text: String) async -> Bool {
        // Composer route: the transcript lands in Slate's own input field.
        if let intoComposer = composerInsert {
            composerInsert = nil
            composerRecording = false
            intoComposer(text)
            FlowHistory.append(.init(raw: lastRaw, polished: text, durationSec: lastDuration))
            FlowHistory.clearParkedRecording()
            return true
        }
        let ok = await inserter.insert(text, expectedBundleID: targetBundleID)
        if ok {
            FlowHistory.append(.init(raw: lastRaw, polished: text, durationSec: lastDuration))
            FlowHistory.clearParkedRecording()
        } else {
            // Spec item 4: on failure the transcript STAYS on the clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return ok
    }

    /// Mic button next to the paperclip: click to talk, click again to drop the
    /// polished transcript into the chat input. Independent of the Fn hotkey,
    /// the tap, AX - and of the Flow enable toggle.
    func toggleComposerDictation(insert: @escaping (String) -> Void) {
        guard !voiceActive else { return }                       // voice session owns the mic
        if composerRecording {
            controller.toggleManual()                        // finalize → deliver() routes to composer
        } else if controller.state == .idle {
            composerInsert = insert
            composerRecording = true
            warmSTT()
            controller.toggleManual()
        }
    }
}
