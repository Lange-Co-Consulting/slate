import AppKit
import Carbon.HIToolbox
import Observation
import ScreenCaptureKit
import SwiftUI
import SlateUI
import SlateCore

extension Notification.Name {
    static let slateQuickToggle = Notification.Name("SlateQuickToggle")
}

enum QuickAction: String, CaseIterable, Identifiable {
    case ask, summarize, rewrite, translate, explain
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .ask: return "sparkles"
        case .summarize: return "text.alignleft"
        case .rewrite: return "pencil.line"
        case .translate: return "character.bubble"
        case .explain: return "lightbulb"
        }
    }
    var isFree: Bool { self == .ask }
    var instruction: String {
        switch self {
        case .ask: return "Answer the user's request directly and concisely."
        case .summarize: return "Summarize the provided content clearly. Preserve important facts."
        case .rewrite: return "Rewrite the provided text so it is clear, polished and natural. Return only the rewritten text."
        case .translate: return "Translate the provided text into the language requested by the user. If none is specified, translate German to English or English to German. Return only the translation."
        case .explain: return "Explain the provided content in plain language with a compact, useful answer."
        }
    }
}

@MainActor @Observable
final class QuickPanelState {
    var prompt = ""
    var selectedText = ""
    var screenshotURL: URL?
    var result = ""
    var error: String?
    var busy = false
    var action: QuickAction = .ask
    var sourceAppName: String?
    @ObservationIgnored var sourcePID: pid_t?
    @ObservationIgnored var selectedElement: AXUIElement?
    @ObservationIgnored var closePanel: (() -> Void)?
    @ObservationIgnored var resizePanel: ((CGFloat) -> Void)?

    func prepare(sourceApplication: NSRunningApplication?) {
        if let screenshotURL { try? FileManager.default.removeItem(at: screenshotURL) }
        prompt = ""
        result = ""
        error = nil
        action = .ask
        screenshotURL = nil
        sourcePID = sourceApplication?.processIdentifier
        sourceAppName = sourceApplication?.localizedName
        let captured = sourceApplication.flatMap { Self.selection(from: $0.processIdentifier) }
        selectedText = captured?.text ?? ""
        selectedElement = captured?.element
    }

    func captureScreenshot() async {
        guard let sourcePID else {
            error = "Open Slate Quick from the app you want to capture."
            return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == sourcePID && $0.isOnScreen && $0.frame.width > 80 && $0.frame.height > 80
            }) else { throw QuickCaptureError.windowUnavailable }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale: CGFloat = min(2, 2_400 / max(window.frame.width, 1))
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let directory = URL.applicationSupportDirectory
                .appendingPathComponent("Slate/QuickCaptures", isDirectory: true)
            try PrivateStorage.ensureDirectory(directory)
            let url = directory.appendingPathComponent("capture-\(UUID().uuidString).png")
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw QuickCaptureError.encodingFailed
            }
            try PrivateStorage.write(png, to: url)
            screenshotURL = url
        } catch {
            self.error = "Screenshot unavailable. Allow Screen Recording for Slate, then try again."
        }
    }

    func perform(_ requestedAction: QuickAction, model: AppModel) async {
        if !requestedAction.isFree, !model.requirePro(.quickActions) {
            closePanel?()
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain { window.makeKeyAndOrderFront(nil) }
            return
        }
        action = requestedAction
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty || !cleanSelection.isEmpty || screenshotURL != nil else {
            error = "Type a request, select text, or add a screenshot."
            return
        }
        var blocks: [String] = []
        if !cleanSelection.isEmpty {
            blocks.append("Selected text from \(sourceAppName ?? "another app"):\n<selection>\n\(String(cleanSelection.prefix(24_000)))\n</selection>")
        }
        if !cleanPrompt.isEmpty { blocks.append("User request:\n\(cleanPrompt)") }
        if screenshotURL != nil { blocks.append("Use the attached screenshot as visual context.") }
        busy = true; error = nil; result = ""
        defer { busy = false }
        do {
            let system = "You are Slate Quick, a private on-device macOS assistant. \(requestedAction.instruction) Never claim to have used a network service."
            result = try await model.quickGenerate(system: system, user: blocks.joined(separator: "\n\n"),
                                                   imagePath: screenshotURL?.path)
            if result.isEmpty { error = "The local model returned an empty answer." }
        } catch {
            self.error = model.isModelLoaded
                ? "The local model is busy. Finish the current task and try again."
                : "Load a local chat model in Slate first. Quick never falls back to cloud."
        }
    }

    func copyResult() {
        guard !result.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    func replaceSelection(model: AppModel) async {
        guard !result.isEmpty else { return }
        guard model.requirePro(.quickActions) else {
            closePanel?()
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain { window.makeKeyAndOrderFront(nil) }
            return
        }
        guard let selectedElement, let sourcePID else {
            error = "The original app no longer exposes an editable selection. Copy the result instead."
            return
        }
        NSRunningApplication(processIdentifier: sourcePID)?.activate()
        try? await Task.sleep(for: .milliseconds(100))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID,
              let current = Self.focusedElement(for: sourcePID),
              !Self.isSecureTextField(current),
              CFEqual(current, selectedElement) else {
            error = "Focus changed or the target is protected. Copy the result instead."
            return
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(current, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            error = "The original selection is no longer editable. Copy the result instead."
            return
        }
        let status = AXUIElementSetAttributeValue(current, kAXSelectedTextAttribute as CFString, result as CFString)
        if status == .success { closePanel?() }
        else { error = "Slate couldn’t replace that selection. Copy the result instead." }
    }

    private static func selection(from pid: pid_t) -> (text: String, element: AXUIElement)? {
        guard AXIsProcessTrusted() else { return nil }
        guard let element = focusedElement(for: pid), !isSecureTextField(element) else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, element)
    }

    private static func focusedElement(for pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(focused, to: AXUIElement.self)
    }

    private static func isSecureTextField(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { return false }
        return (role as? String) == "AXSecureTextField"
    }
}

private enum QuickCaptureError: Error { case windowUnavailable, encodingFailed }

/// A Spotlight-like overlay: it may take keyboard focus without activating Slate
/// or pulling the user out of the full-screen Space they are working in.
private final class SlateQuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct SlateQuickView: View {
    @Environment(AppModel.self) private var model
    @Environment(QuickPanelState.self) private var state
    @Environment(\.colorScheme) private var scheme
    @Environment(\.slatePalette) private var palette
    @FocusState private var promptFocused: Bool

    private var compactPanelHeight: CGFloat {
        state.selectedText.isEmpty && state.screenshotURL == nil ? 232 : 270
    }
    private var panelHeight: CGFloat { state.result.isEmpty ? compactPanelHeight : 470 }

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SlateMark(width: 22)
                Text("Slate Quick").font(.headline.weight(.semibold))
                Text("⌥ Space").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Label("Local", systemImage: "lock.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.72))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule().fill(.primary.opacity(scheme == .dark ? 0.09 : 0.07)))
                Button { state.closePanel?() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.primary.opacity(scheme == .dark ? 0.08 : 0.06)))
                    .help("Close Slate Quick · Esc")
            }
            .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 10) {
                if !state.selectedText.isEmpty || state.screenshotURL != nil {
                    HStack(spacing: 7) {
                        if !state.selectedText.isEmpty {
                            contextChip("Selection · \(state.selectedText.count) chars", icon: "text.quote") {
                                state.selectedText = ""
                            }
                        }
                        if state.screenshotURL != nil {
                            contextChip("Screenshot", icon: "rectangle.dashed.badge.record") {
                                state.screenshotURL = nil
                            }
                        }
                    }
                    .padding(.bottom, 1)
                }

                ZStack(alignment: .topLeading) {
                    if state.prompt.isEmpty {
                        Text(state.selectedText.isEmpty ? "Ask anything…" : "What should Slate do with the selection?")
                            .foregroundStyle(.secondary).padding(.horizontal, 4).padding(.vertical, 6)
                    }
                    TextEditor(text: $state.prompt)
                        .scrollContentBackground(.hidden)
                        .font(.body)
                        .focused($promptFocused)
                        .frame(minHeight: 58, maxHeight: 82)
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.085) : Color.white.opacity(0.68)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(promptFocused
                                  ? (palette.enabled ? palette.controlAccent.opacity(0.9) : Color.primary.opacity(0.34))
                                  : Color.primary.opacity(scheme == .dark ? 0.14 : 0.10), lineWidth: promptFocused ? 1 : 0.75))

                HStack(spacing: 5) {
                    ForEach(QuickAction.allCases.filter { $0 != .ask }) { action in
                        quickAction(action)
                    }
                    Spacer()
                    Button {
                        Task { await state.captureScreenshot() }
                    } label: { Image(systemName: "camera.viewfinder") }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.primary.opacity(scheme == .dark ? 0.08 : 0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(scheme == .dark ? 0.08 : 0.06), lineWidth: 0.5))
                    .help("Add screenshot from \(state.sourceAppName ?? "front app")")
                    .disabled(state.busy)
                    Button {
                        Task { await state.perform(.ask, model: model) }
                    } label: {
                        Label("Ask", systemImage: "arrow.up")
                    }
                    .buttonStyle(PaletteProminentButtonStyle())
                    .disabled(state.busy)
                    .help("Ask Slate locally · ⌘↩")
                }
                .font(.caption.weight(.medium))

                if state.busy {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Running locally…") }
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = state.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !state.result.isEmpty {
                    HStack {
                        Label("Answer", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Local only").font(.caption2).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(state.result).textSelection(.enabled)
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.primary.opacity(scheme == .dark ? 0.055 : 0.045)))
                    HStack {
                        Button { state.copyResult() } label: { Label("Copy", systemImage: "doc.on.doc") }
                        if !state.selectedText.isEmpty {
                            Button { Task { await state.replaceSelection(model: model) } } label: {
                                Label("Replace selection", systemImage: "arrow.uturn.forward")
                            }
                        }
                        Spacer()
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 15)
        }
        .frame(width: 596, height: panelHeight, alignment: .top)
        // Quick sits over arbitrary third-party windows. A clean, opaque sheet
        // is more reliable here than the app canvas/glass stack: it prevents the
        // canvas' blurred circles and the glass compositor's seam lines from
        // leaking into recordings or screenshots.
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(scheme == .dark
                  ? Color(red: 0.105, green: 0.122, blue: 0.165)
                  : Color(red: 0.965, green: 0.972, blue: 0.988))
            // Keep the user's surface colour behind the entire interface so it
            // cannot wash over text or reintroduce low-contrast controls.
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.enabled ? palette.surface.opacity(scheme == .dark ? 0.16 : 0.08) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.primary.opacity(scheme == .dark ? 0.18 : 0.11), lineWidth: 0.75))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear { promptFocused = true }
        .onChange(of: state.result.isEmpty) { _, _ in state.resizePanel?(panelHeight) }
        .onChange(of: state.selectedText) { _, _ in state.resizePanel?(panelHeight) }
        .onChange(of: state.screenshotURL) { _, _ in state.resizePanel?(panelHeight) }
        .onExitCommand { state.closePanel?() }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            Task { await state.perform(state.action, model: model) }
            return .handled
        }
    }

    private func quickAction(_ action: QuickAction) -> some View {
        Button {
            Task { await state.perform(action, model: model) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: action.icon)
                Text(action.title)
                Image(systemName: "lock.fill").font(.system(size: 8))
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .foregroundStyle(.primary.opacity(0.82))
            .background(Capsule().fill(.primary.opacity(scheme == .dark ? 0.075 : 0.055)))
        }
        .buttonStyle(.plain)
        .disabled(state.busy)
        .help("Slate Pro · \(action.title)")
    }

    private func contextChip(_ title: String, icon: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .font(.caption2).foregroundStyle(.primary.opacity(0.72))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(.primary.opacity(scheme == .dark ? 0.09 : 0.07)))
    }
}

@MainActor @Observable
final class QuickPanelController {
    private let state = QuickPanelState()
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var model: AppModel?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var eventHandler: EventHandlerRef?
    @ObservationIgnored private var notificationObserver: NSObjectProtocol?
    @ObservationIgnored private var localMouseMonitor: Any?
    @ObservationIgnored private var globalMouseMonitor: Any?

    func connect(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        state.closePanel = { [weak self] in self?.hide() }
        state.resizePanel = { [weak self] height in self?.resize(to: height) }
    }

    func start() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<QuickPanelController>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in controller.toggle() }
            return noErr
        }, 1, &eventType, pointer, &eventHandler)
        let identifier = EventHotKeyID(signature: OSType(0x534C5155), id: 1) // SLQU
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), identifier,
                            GetApplicationEventTarget(), 0, &hotKey)
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .slateQuickToggle, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.toggle() } }
    }

    func toggle() {
        guard model?.settings.quickEnabled != false else { return }
        if panel?.isVisible == true { hide() } else { show() }
    }

    private func show() {
        guard let model else { return }
        let source = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0
        }
        state.prepare(sourceApplication: source)
        let panel = panel ?? makePanel(model: model)
        self.panel = panel
        resize(to: compactHeight)
        position(panel)
        // Do not activate Slate here. Activation exits or obscures a different
        // application's full-screen Space; this panel is intentionally a local
        // overlay above the current Space instead.
        panel.orderFrontRegardless()
        panel.makeKey()
        startOutsideClickMonitoring()
    }

    private func hide() {
        stopOutsideClickMonitoring()
        panel?.orderOut(nil)
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let panel = SlateQuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: 596, height: 232),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView:
            SlateQuickView()
                .environment(model)
                .environment(state)
                .environment(\.slatePalette, model.settings.palette)
                .preferredColorScheme(model.settings.theme.colorScheme)
        )
        return panel
    }

    /// A non-activating panel does not automatically receive clicks in the app
    /// underneath it. Monitor both event streams so Quick closes naturally when
    /// the user clicks away, without swallowing that click or requiring the ×.
    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.dismissIfClickIsOutsidePanel()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.dismissIfClickIsOutsidePanel() }
        }
    }

    private func stopOutsideClickMonitoring() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func dismissIfClickIsOutsidePanel() {
        guard let panel, panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        hide()
    }

    private func position(_ panel: NSPanel) {
        // `NSScreen.main` can still point at Slate's own display while the user
        // invokes Quick from a full-screen app on another monitor. The pointer
        // identifies the active working display without activating Slate.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { panel.center(); return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.maxY - size.height - 90))
    }

    private func resize(to contentHeight: CGFloat) {
        guard let panel else { return }
        let oldFrame = panel.frame
        panel.setContentSize(NSSize(width: 596, height: contentHeight))
        guard panel.isVisible else { return }
        let newFrame = panel.frame
        panel.setFrameOrigin(NSPoint(x: oldFrame.midX - newFrame.width / 2,
                                     y: oldFrame.maxY - newFrame.height))
    }

    private var compactHeight: CGFloat {
        state.selectedText.isEmpty && state.screenshotURL == nil ? 232 : 270
    }

}
