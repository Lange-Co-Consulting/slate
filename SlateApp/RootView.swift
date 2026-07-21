import SwiftUI
import UniformTypeIdentifiers
import SlateCore
import SlateUI

/// Configures the hosting NSWindow: full-size content, transparent titlebar, no
/// toolbar strip - while explicitly KEEPING the standard window buttons (close /
/// minimize / zoom) visible and clickable.
///
/// A one-shot config is NOT enough: NavigationSplitView owns an NSToolbar and
/// AppKit re-installs it on every fullscreen transition - in fullscreen the
/// toolbar gets its own opaque strip ABOVE the content (the black band that
/// covered the glass header). So the hosting view re-asserts the chrome after
/// each transition and mirrors the fullscreen state into AppModel, which drives
/// the traffic-light clearances (hidden in fullscreen → no dead padding).
struct WindowConfigurator: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let v = ChromeEnforcingView()
        v.onFullscreenChange = { [weak model] in model?.isFullscreen = $0 }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeEnforcingView: NSView {
        var onFullscreenChange: ((Bool) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            applyChrome()
            onFullscreenChange?(window.styleMask.contains(.fullScreen))
            // will*: flip the layout flag before the zoom animation, so paddings
            // are already right when the first fullscreen frame renders.
            // did*: AppKit has finished (re)building titlebar + toolbar - strip again.
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(willEnterFS), name: NSWindow.willEnterFullScreenNotification, object: window)
            nc.addObserver(self, selector: #selector(didTransitionFS), name: NSWindow.didEnterFullScreenNotification, object: window)
            nc.addObserver(self, selector: #selector(willExitFS), name: NSWindow.willExitFullScreenNotification, object: window)
            nc.addObserver(self, selector: #selector(didTransitionFS), name: NSWindow.didExitFullScreenNotification, object: window)
        }

        @objc private func willEnterFS() { onFullscreenChange?(true) }
        @objc private func willExitFS() { onFullscreenChange?(false) }
        @objc private func didTransitionFS() {
            applyChrome()
            // SwiftUI can finish re-installing its toolbar after the notification
            // fires - strip once more on the next runloop tick.
            DispatchQueue.main.async { [weak self] in self?.applyChrome() }
        }

        private func applyChrome() {
            guard let window else { return }
            window.setFrameAutosaveName("SlateMainWindow")
            // AppKit swaps the styleMask during fullscreen - never force window
            // shape bits there, only when windowed.
            if !window.styleMask.contains(.fullScreen) {
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
            }
            window.titleVisibility = .hidden
            window.toolbar = nil
            window.isMovableByWindowBackground = false
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(b)?.isHidden = false
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The sidebar is OUR panel, not NavigationSplitView's: the system panel's
    /// corner radius can't be controlled and never matched the window. Ours is
    /// concentric with the macOS 26 window corner (26 − 8pt inset), Apple's rule
    /// for surfaces that hug a rounded container. Dropping NavigationSplitView
    /// also removes the NSToolbar it kept re-installing on fullscreen entry.
    private var sidebarShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.R.window - 8, style: .continuous)
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            if model.sidebarVisible {
                SidebarView()
                    .frame(width: 280)
                    .background {
                        // The panel: behind-content material + the identity wash,
                        // clipped to ONE shape we own.
                        ZStack {
                            Rectangle().fill(.ultraThinMaterial)
                            SidebarWash()
                        }
                    }
                    .clipShape(sidebarShape)
                    .overlay(sidebarShape.strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 12, y: 3)
                    .padding(.leading, 8).padding(.bottom, 8).padding(.trailing, 8)
                    // Windowed: the panel starts below the floating traffic lights
                    // (they live on the canvas, not on the panel); fullscreen: they
                    // auto-hide, so the panel floats symmetrically.
                    .padding(.top, model.isFullscreen ? 8 : 34)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ConversationView()
                .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: model.sidebarVisible)
        // ONE canvas behind sidebar panel AND detail - the panel material blurs
        // it, the glass header refracts it, no seams between columns.
        .background(CanvasWash())
        .ignoresSafeArea(.container, edges: .top)
        // Configure the real NSWindow: full-bleed content, NO toolbar strip (it
        // stayed opaque in fullscreen), but KEEP the traffic lights - the earlier
        // .toolbar(.hidden) removed the close button entirely.
        .background(WindowConfigurator(model: model))
        // While dictating, the window edge glows softly in the sidebar's aurora
        // colors - intensity rides the live mic level. Purely decorative,
        // never intercepts clicks.
        .overlay { FlowEdgeGlow() }
        .overlay(alignment: .top) {
            ToastHost()
                .environment(model)
                .padding(.top, model.isFullscreen ? 12 : 40)
                .padding(.horizontal, 24)
        }
        .overlay {
            if model.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18).ignoresSafeArea()
                        .onTapGesture { model.showPalette = false }
                    CommandPalette().environment(model)
                        .padding(.top, 90)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
                .animation(.snappy(duration: 0.16), value: model.showPalette)
            }
        }
        .overlay {
            if model.showSwitcher {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18).ignoresSafeArea()
                        .onTapGesture { model.showSwitcher = false }
                    SessionSwitcher().environment(model)
                        .padding(.top, 90)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
                .animation(.snappy(duration: 0.16), value: model.showSwitcher)
            }
        }
        .overlay {
            if model.showGlobalSearch {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18).ignoresSafeArea()
                        .onTapGesture { model.showGlobalSearch = false }
                    GlobalSearchView().environment(model)
                        .padding(.top, 70)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
                .animation(.snappy(duration: 0.16), value: model.showGlobalSearch)
            }
        }
        .sheet(isPresented: $model.showModelManager) {
            ModelsView().environment(model)
        }
        .sheet(isPresented: $model.showDownloads) {
            DownloadsView().environment(model).presentationSizing(.fitted)
        }
        .sheet(isPresented: $model.showTranscription) {
            TranscriptionView().environment(model).presentationSizing(.fitted)
        }
        .sheet(isPresented: Binding(
            get: { !model.settings.onboardingCompleted },
            set: { if !$0 { model.settings.onboardingCompleted = true } })) {
            OnboardingView().environment(model)
        }
        // Right after the tutorial: ask about the customer's Mac, once.
        .sheet(isPresented: Binding(
            get: { model.settings.onboardingCompleted && !model.settings.hardwareProfileCompleted },
            set: { if !$0 { model.settings.hardwareProfileCompleted = true } })) {
            HardwareSetupView().environment(model)
        }
        // Settings live in an IN-APP sheet so fullscreen is never left.
        .sheet(isPresented: $model.showSettings) {
            VStack(spacing: 0) {
                SettingsView().environment(model)
                Divider().opacity(0.4)
                HStack {
                    Spacer()
                    Button("Done") { model.showSettings = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            // Wider for the sidebar/tab layout; still tracks small windows.
            .frame(minWidth: 720, idealWidth: 780, minHeight: 500, idealHeight: 640)
        }
        // Pro upsell - shown whenever a Free user taps a locked feature.
        .sheet(item: $model.proUpsell) { feature in
            ProUpsellView(feature: feature).environment(model)
        }
        .alert("Slate closed unexpectedly last time", isPresented: $model.showCrashPrompt) {
            if let report = model.crashReports.first {
                Button("Send report") { model.sendCrashReport(report) }
            }
            Button("Review first") {
                model.markCrashesSeen()
                model.showSettings = true
            }
            Button("Not now", role: .cancel) { model.markCrashesSeen() }
        } message: {
            Text("You can send a fully anonymous report (app/OS version and the crash signature only - no conversations, files or names) so it can be fixed. \"Send report\" opens a pre-filled email - nothing is sent until you press send. Or review it first in Settings → Bug Reports.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .slateServiceRequest)) { note in
            guard let draft = note.object as? String else { return }
            if model.selected?.kind == .image || model.selected == nil {
                model.newConversation(kind: .chat)
            }
            model.serviceDraft = draft
        }
        .onOpenURL { model.handleAutomationURL($0) }
        // Silent, throttled licence re-check on launch (offline-safe).
        .task { await model.pro.refreshIfDue() }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.slatePalette) private var palette
    @State private var importingModel = false
    @State private var search = ""
    @State private var renameID: Conversation.ID?
    @State private var renameText = ""
    /// Which list is shown - chats and code sessions live in separate tabs
    /// (like the Claude app), not one mixed list.
    @State private var tab: Conversation.Kind = .chat

    private var filtered: [Conversation] {
        let base = model.sortedConversations.filter { $0.kind == tab }
        guard !search.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private var emptyListLabel: String {
        if !search.isEmpty { return "No matches" }
        switch tab {
        case .chat:  return "No chats yet"
        case .code:  return "No code sessions yet"
        case .image: return "No images yet"
        case .agents: return "No roundtables yet"
        }
    }

    /// Short, clean display name for a model file. Delegates to the tested
    /// `ModelName.pretty` (keeps family + version + size, drops quant / format /
    /// fine-tune / uploader noise) so every surface shows the same tidy name.
    static func pretty(_ name: String) -> String { ModelName.pretty(name) }

    /// Local models grouped by rough size class for the picker menu (same buckets
    /// as the Roundtable setup). File size is a good proxy for RAM footprint.
    private var localModelGroups: [(label: String, items: [ModelEntry])] {
        let m = model.models
        let small   = m.filter { $0.bytes > 0 && $0.bytes < 3_758_096_384 }              // < 3.5 GB
        let medium  = m.filter { $0.bytes >= 3_758_096_384 && $0.bytes < 9_663_676_416 } // 3.5–9 GB
        let large   = m.filter { $0.bytes >= 9_663_676_416 }                             // ≥ 9 GB
        let unknown = m.filter { $0.bytes <= 0 }
        var groups: [(String, [ModelEntry])] = []
        if !small.isEmpty   { groups.append(("Small", small)) }
        if !medium.isEmpty  { groups.append(("Medium", medium)) }
        if !large.isEmpty   { groups.append(("Large", large)) }
        if !unknown.isEmpty { groups.append(("Models", unknown)) }
        return groups.map { (label: $0.0, items: $0.1) }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // No glass here: the sidebar is already a material panel (glass-on-glass
            // is an Apple no-no) - quiet fills that bloom on hover instead.
            // Own search field (the system .searchable slot died with the toolbar);
            // top padding clears the floating traffic lights in windowed mode.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain).font(.callout)
                Button { model.showGlobalSearch = true } label: {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Search everywhere (⌘⇧F)")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(.quinary))
            .padding(.horizontal, 10)
            // The traffic lights float ABOVE the panel now (RootView insets it),
            // so the panel content only needs breathing room.
            .padding(.top, 10)

            // Chats, code and image sessions are separate spaces. The old
            // icon-only control was visually tidy but hid Slate's three primary
            // capabilities from new users; compact labels make the navigation
            // self-explanatory without adding another panel or section header.
            // Vertical mode nav (macOS source-list style) - calmer and more
            // native than a cramped horizontal segmented pill, and it scales as
            // modes are added.
            VStack(spacing: 2) {
                navRow(.chat, "Chats", "bubble.left.and.bubble.right")
                navRow(.code, "Code", "chevron.left.forwardslash.chevron.right")
                navRow(.image, "Image", "photo")
                navRow(.agents, "Roundtable", "person.3")
            }
            .padding(.horizontal, 8).padding(.top, 8)
            .animation(.snappy(duration: 0.18), value: tab)

            Button { model.newConversation(kind: tab) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .semibold))
                    Text(newLabel).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .foregroundStyle(palette.enabled ? AnyShapeStyle(palette.controlAccent) : AnyShapeStyle(Color.primary))
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(palette.enabled ? palette.controlAccent.opacity(0.12) : Color.primary.opacity(0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain).liquidHover(1.02)
            .help(newButtonHelp)
            .accessibilityLabel(newButtonHelp)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)

            // No native selection binding: NSTableView paints it system-accent
            // blue and ignores .tint - we draw a monochrome highlight ourselves.
            List {
                if filtered.isEmpty {
                    Text(emptyListLabel)
                        .foregroundStyle(.tertiary).font(.callout)
                }
                let pinned = filtered.filter { $0.pinned }
                let others = filtered.filter { !$0.pinned }
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { row($0) }
                    }
                    if !others.isEmpty {
                        Section("Recent") { ForEach(others) { row($0) } }
                    }
                } else {
                    // No pinned items → no section chrome at all, just the rows.
                    ForEach(others) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)   // the panel material shows through
            .onDeleteCommand { model.deleteSelected() }

            VStack(spacing: 8) {
                // Flow's docked home: drag the pill past its magnetic tether to
                // pop it out as the system-wide floating bar.
                DockedFlowPillHost()
                UpdatePill()   // only visible when an update is available
                HStack(spacing: 8) {
                    QuietIconButton(system: "waveform.badge.mic", help: "Transcribe audio or video locally") {
                        model.showTranscription = true
                    }
                    downloadsPill
                    settingsIcon
                    killAllIcon   // demoted from a red bar to a quiet hover-red icon
                }
                modelFooter
            }
            .padding(10)
        }
        .fileImporter(isPresented: $importingModel,
                      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            if case let .success(url) = result { model.pickLocalModel(url) }
        }
        .alert("Rename conversation", isPresented: Binding(get: { renameID != nil },
                                                           set: { if !$0 { renameID = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") { if let id = renameID { model.rename(id, to: renameText) }; renameID = nil }
            Button("Cancel", role: .cancel) { renameID = nil }
        }
        // Jumping to a conversation of the other kind (⌘P, palette) follows its tab.
        .onChange(of: model.selectedID) { _, _ in
            if let k = model.selected?.kind, k != tab {
                withAnimation(.snappy(duration: 0.15)) { tab = k }
            }
        }
        .onAppear { if let k = model.selected?.kind { tab = k } }   // launch: tab matches the open session
        // (The identity wash + material live on RootView's panel - the ONE
        // clipped shape - not here, so nothing can escape the rounded corners.)
    }

    /// Chat and Code are separate spaces (like the Claude app): switching tabs
    /// CLOSES the other-kind conversation and opens this kind's newest session
    /// (or starts a fresh one when there are none).
    private func switchTab(_ k: Conversation.Kind) {
        withAnimation(.snappy(duration: 0.15)) { tab = k }
        guard model.selected?.kind != k else { return }
        if let newest = model.sortedConversations.first(where: { $0.kind == k }) {
            model.selectedID = newest.id
        } else {
            model.newConversation(kind: k)
        }
    }

    private var newButtonHelp: String {
        switch tab {
        case .chat: "New chat (⌘N)"
        case .code: "New code session (⌘N)"
        case .image: "New image (⌘N)"
        case .agents: "New roundtable (⌘N)"
        }
    }

    /// Concise contextual label for the New button (matches the selected mode).
    private var newLabel: String {
        switch tab {
        case .chat: "New chat"; case .code: "New code session"
        case .image: "New image"; case .agents: "New roundtable"
        }
    }

    /// One row of the vertical mode nav: icon + label, full width, with a quiet
    /// selection highlight (the Mail / Notes source-list pattern).
    private func navRow(_ k: Conversation.Kind, _ label: String, _ icon: String) -> some View {
        let selected = tab == k
        return Button { switchTab(k) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                Text(label).font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.enabled ? palette.controlAccent.opacity(0.16) : Color.primary.opacity(0.09))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ c: Conversation) -> some View {
        ConversationRow(conversation: c) { startRename(c) }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.enabled
                          ? palette.controlAccent.opacity(model.selectedID == c.id ? 0.15 : 0)
                          : Color.primary.opacity(model.selectedID == c.id ? 0.09 : 0))
                    .padding(.horizontal, 4)
            )
            .contextMenu {
                Button("Rename") { startRename(c) }
                Button(c.pinned ? "Unpin" : "Pin") { model.togglePin(c.id) }
                Button("Duplicate") { model.duplicate(c.id) }
                Divider()
                Button("Delete", role: .destructive) { model.delete(c.id) }
            }
    }

    private func startRename(_ c: Conversation) {
        renameText = c.title
        renameID = c.id
    }

    /// Emergency stop, demoted to a quiet icon - red only when you aim at it.
    private var killAllIcon: some View {
        KillAllIconButton { model.killAll() }
    }

    /// Settings (theme, defaults, models) - the visible way in, next to the
    /// other footer utilities (⌘, works too). Opens the IN-APP sheet.
    private var settingsIcon: some View {
        QuietIconButton(system: "gearshape", help: "Settings - theme, defaults, models (⌘,)") {
            model.showSettings = true
        }
    }

    /// Glass pill above the model selector: opens the downloads page (active
    /// downloads, loaded model, installed). Shows a count badge when downloads
    /// are running.
    private var downloadsPill: some View {
        @Bindable var model = model
        let llm = model.modelStore.downloads.values
        let imageActive = model.imageDownloadID != nil
        // Aggregate progress across LLM downloads AND the image-model bundle.
        let llmAvg = llm.isEmpty ? 0 : llm.map(\.progress).reduce(0, +) / Double(llm.count)
        let anyDownloading = model.modelStore.isDownloading || imageActive
        let avg = imageActive ? model.imageDownloadProgress : llmAvg
        let count = model.modelStore.downloads.count + (imageActive ? 1 : 0)
        return Button { model.showDownloads = true } label: {
            HStack(spacing: 8) {
                if anyDownloading {
                    // Custom monochrome ring - the system determinate circular
                    // style renders as a murky pie blob on the dark sidebar.
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 2)
                        Circle().trim(from: 0, to: max(0.04, avg))
                            .stroke(palette.enabled ? palette.controlAccent : Color.primary,
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 13, height: 13)
                    .animation(.smooth(duration: 0.4), value: avg)
                } else {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
                Text("Downloads")
                    .font(.callout).lineLimit(1)
                Spacer(minLength: 4)
                if anyDownloading {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill((palette.enabled ? palette.controlAccent : Color.primary).opacity(0.18)))
                        .foregroundStyle(palette.enabled ? palette.controlAccent : Color.primary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Capsule())
            .background(Capsule().fill(.quinary))   // sidebar = material panel: fills, not glass
            .sidebarPillHover()
        }
        .buttonStyle(.plain)
        .help("Active downloads and loaded models")
    }

    private var modelFooter: some View {
        Menu {
            Button {
                model.pickClaudeCode()
            } label: {
                Label("Cloud · Claude Code",
                      systemImage: (model.usingCloud && model.activeCloudProviderID == nil) ? "checkmark" : "cloud")
            }
            ForEach(model.settings.cloudProviders) { p in
                Button {
                    model.pickCloudModel(p)
                } label: {
                    Label("Cloud · \(p.name)",
                          systemImage: model.activeCloudProviderID == p.id ? "checkmark" : "cloud")
                }
            }
            ForEach(model.settings.openCodeModels, id: \.self) { id in
                Button { model.pickOpenCodeModel(id) } label: {
                    Label("OpenCode · \(id)",
                          systemImage: model.activeCloudProviderID == "opencode:\(id)" ? "checkmark" : "terminal")
                }
            }
            Divider()
            ForEach(localModelGroups, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.items) { m in
                        Button {
                            if m.url != model.activeModelURL || model.usingCloud { model.pickLocalModel(m.url) }
                        } label: {
                            Label(Self.pretty(m.name), systemImage: (m.url == model.activeModelURL && !model.usingCloud) ? "checkmark" : "cpu")
                        }
                    }
                }
            }
            Divider()
            Button("Manage models…") { model.showModelManager = true }
            Button("Choose file…") { importingModel = true }
            Button("Rescan") { model.rescanModels() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.loadingModel ? "hourglass" : (model.usingCloud ? "cloud" : "cpu"))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, isActive: model.loadingModel)
                    .contentTransition(.symbolEffect(.replace))
                if model.loadingModel {
                    Text("Loading…")
                        .font(.callout).lineLimit(1)
                        .shimmer()   // multi-GB load feels alive, not frozen
                } else {
                    Text(model.activeModelName.map(Self.pretty) ?? "No model")
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                        .contentTransition(.opacity)
                        .animation(.smooth(duration: 0.25), value: model.activeModelName)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Capsule())
            .background(Capsule().fill(.quinary))   // sidebar = material panel: fills, not glass
            .sidebarPillHover()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .help("Switch the local model")
    }
}

/// Quiet circular sidebar utility icon (same language as the kill icon, but a
/// neutral primary hover instead of red).
struct QuietIconButton: View {
    let system: String
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.quinary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(reduceMotion ? nil : .snappy(duration: 0.14)) { hovering = h } }
        .help(help)
        .accessibilityLabel(help.isEmpty ? system : help)
    }
}

/// Emergency-stop icon: quiet secondary at rest, red only on hover - the alarm
/// color exists only while you aim at it (no permanent red bar in the chrome).
struct KillAllIconButton: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.quinary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(reduceMotion ? nil : .snappy(duration: 0.14)) { hovering = h } }
        .help("Stop all local generation and unload the model (frees RAM)")
        .accessibilityLabel("Stop all generation and unload the model")
    }
}

struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let onRename: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: rowIcon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if conversation.pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
            }
            if hovering {
                Button { model.delete(conversation.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Delete conversation")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onRename() }
        .onTapGesture { model.selectedID = conversation.id }   // manual select (no blue NSTableView highlight)
    }

    private var rowIcon: String {
        switch conversation.kind {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .agents: "person.3"
        case .chat, .image: "bubble.left"
        }
    }

    private var subtitle: String {
        switch conversation.kind {
        case .chat: return "Chat"
        case .code: return conversation.folderURL?.lastPathComponent ?? "Code · no folder yet"
        case .image: return "Image"
        case .agents: return "Roundtable"
        }
    }
}
