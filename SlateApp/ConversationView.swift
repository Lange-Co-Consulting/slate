import SwiftUI
import SlateUI
import AppKit
import UniformTypeIdentifiers
import SlateCore

/// Reports the measured height of the floating bottom bar (chat composer or
/// roundtable controls) so the transcript can reserve exactly enough clearance
/// for its last message to clear the bar - regardless of chips, the no-model
/// hint, or a multiline field. A fixed spacer used to let the last bubble slide
/// under the glass bar and bleed through it.
private struct BottomBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 84
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(FlowRuntime.self) private var flow
    @Environment(\.colorScheme) private var scheme
    @Environment(\.slatePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One shared reading column for transcript AND composer, centered in the
    /// window. A tight chat measure (like ChatGPT / Claude-chat) - NOT a wide
    /// slab: short answers (a poem, a one-liner) then sit as a balanced centered
    /// block instead of clinging to the left with a grey void on the right. Both
    /// share it so the input lines up under the text.
    static let contentWidth: CGFloat = 720
    @State private var input = ""
    @State private var showConvoSettings = false
    @State private var showPreview = false
    @State private var showFiles = false
    @State private var viewingFile: URL?
    /// Code-mode live preview of a local dev server (localhost only). Empty = show
    /// the on-disk HTML instead. `previewAutoRefresh` reloads it on a short timer.
    @State private var previewServerURL = ""
    @State private var previewAutoRefresh = false
    @State private var attachedImage: URL?
    @State private var ccNoSessions = false
    @State private var folderSelectionError: String?
    @State private var attachedContextFiles: [URL] = []
    /// Attachments share one SwiftUI importer. Project folders deliberately use
    /// NSOpenPanel below: SwiftUI's folder importer can leave Open disabled even
    /// after a valid folder is selected.
    @State private var fileImport: FileImport?
    /// Sticky copy of the route: macOS can flip isPresented=false (which nils
    /// `fileImport`) BEFORE the completion runs - reading `fileImport` there
    /// then silently routed to .none ("I pick a folder and nothing happens").
    @State private var importRoute: FileImport = .context
    private func openImporter(_ k: FileImport) { importRoute = k; fileImport = k }
    private enum FileImport: Identifiable {
        case context, image
        var id: Self { self }
        var types: [UTType] {
            switch self {
            case .context: return [.item]
            case .image: return [.image]
            }
        }
        var multiple: Bool { self == .context }
    }
    @State private var showGit = false
    @State private var workspaceWidth: CGFloat = 0
    /// Agent Chat: the reconfigure sheet for an active roundtable.
    @State private var showAgentConfig = false
    /// Warn instead of sending while another conversation's task is running.
    @State private var busyElsewhere = false
    @State private var confirmKnowledgeClear = false
    @State private var knowledgeSourceToRemove: String?
    /// Live voice conversation over this chat (nil = none). Created by the
    /// composer waveform button or ⌘⇧V; ends on Esc/✕/conversation switch.
    @State private var voiceSession: VoiceSession?
    /// A file drag is hovering the conversation - show the drop halo.
    @State private var isDropTargeted = false
    /// Compare mode: the next send fans out across models.
    @State private var compareMode = false
    /// The composer "+" attach/compare popover.
    @State private var showAddMenu = false
    // Live git chip (code header): branch name + dirty-file count.
    @State private var gitBranch: String?
    @State private var gitDirty = 0
    @State private var showCheckpoints = false
    @State private var handoffCopied = false
    @State private var showProjectRulesTrust = false
    /// Bumped to force the live preview to re-read HTML from disk (manual refresh
    /// + auto-refresh when a turn finishes and files may have changed).
    @State private var previewRevision = 0
    /// Shared namespace for Liquid Glass morphing: composer field, chips and the
    /// slash menu live in ONE GlassEffectContainer and morph into each other via
    /// glassEffectID - Apple's signature behavior.
    @Namespace private var glassNS
    /// True while the user is at (or near) the transcript's end. Streaming only
    /// auto-scrolls then - scrolling up during generation stays where you are
    /// instead of being yanked back down on every token.
    @State private var pinnedToBottom = true
    /// Live height of the floating bottom bar (composer / roundtable controls),
    /// fed by `BottomBarHeightKey`; drives the transcript's bottom clearance so
    /// the last message always sits fully above the glass bar.
    @State private var bottomBarHeight: CGFloat = 84
    /// Scroll telemetry for the pin logic: direction (offset delta) + at-bottom.
    private struct ScrollProbe: Equatable {
        var offset: CGFloat
        var atBottom: Bool
    }

    var body: some View {
        Group {
            if let convo = model.selected {
                content(convo)
            } else {
                EmptyStateView()
            }
        }
        .navigationTitle("")
        .onChange(of: model.serviceDraft) { _, draft in
            guard let draft else { return }
            input = draft
            model.serviceDraft = nil
        }
    }

    @ViewBuilder
    private func content(_ convo: Conversation) -> some View {
        if convo.kind == .image {
            model.pro.imageSurface(convo)
        } else if convo.kind == .agents {
            agentContent(convo)
        } else {
            chatCodeContent(convo)
        }
    }

    /// Agent Chat: a fresh session shows the roundtable setup full-screen; once a
    /// discussion exists it shows the shared transcript (speaker-colored) with the
    /// roundtable controls in place of the chat composer.
    @ViewBuilder
    private func agentContent(_ convo: Conversation) -> some View {
        if convo.messages.isEmpty {
            RoundtableSetup(convo: convo)
                .id(convo.id)   // fresh @State per conversation - no stale carry-over
                .overlay(alignment: .top) { agentTopBar(convo) }
        } else {
            transcript(convo)
                .overlay(alignment: .top) { agentHeader(convo) }
                .overlay(alignment: .bottom) { roundtableControls(convo) }
                .onPreferenceChange(BottomBarHeightKey.self) { bottomBarHeight = $0 }
                .frame(minWidth: 400)
        }
    }

    /// The pinned roundtable header: ONE glass element carrying the topic row and
    /// "The Table" seat rail (aurora orbs + round progress) - so the seated models,
    /// whose turn it is, and how far the debate is are always visible without two
    /// stacked bars eating space.
    @ViewBuilder
    private func agentHeader(_ convo: Conversation) -> some View {
        let count = convo.agentModels.count
        let running = model.generatingConvoID == convo.id
        let idx: Int? = running ? model.streamingSpeakerIndex : nil
        let activeSeat: Int? = (idx.map { $0 < count } ?? false) ? idx : nil
        let synthesizing: Bool = idx.map { $0 >= count } ?? false
        VStack(spacing: 0) {
            agentTopBarContent(convo)
                .padding(.leading, model.sidebarVisible || model.isFullscreen ? 16 : 78)
                .padding(.trailing, 16).padding(.vertical, 9)
            if count >= 2 {
                Rectangle().fill(.quaternary.opacity(0.55)).frame(height: 1)
                    .padding(.horizontal, 14)
                RoundtableSeatRail(refs: convo.agentModels, activeSeat: activeSeat,
                                   synthesizing: synthesizing, embedded: true,
                                   round: running ? model.streamingRound : nil,
                                   totalRounds: convo.agentRounds)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .clearGlass(RoundedRectangle(cornerRadius: DS.R.stage, style: .continuous))
        .glassShadow(scheme, hero: true)
        .gesture(WindowDragGesture())
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    /// Standalone glassed top bar (used over the setup screen, where no rail exists).
    private func agentTopBar(_ convo: Conversation) -> some View {
        agentTopBarContent(convo)
            .padding(.leading, model.sidebarVisible || model.isFullscreen ? 16 : 78)
            .padding(.trailing, 16).padding(.vertical, 9)
            .clearGlass(RoundedRectangle(cornerRadius: DS.R.stage, style: .continuous))
            .glassShadow(scheme, hero: true)
            .gesture(WindowDragGesture())
            .padding(.horizontal, 12)
            .padding(.top, 10)
    }

    private func agentTopBarContent(_ convo: Conversation) -> some View {
        let displayTopic = convo.messages.last(where: { $0.role == .user })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (displayTopic?.isEmpty == false ? displayTopic : nil)
            ?? (convo.isUntitled ? "Roundtable" : convo.title)
        return HStack(spacing: DS.Space.l) {
            ToolbarIconButton(system: "sidebar.leading", help: "Toggle sidebar") {
                withAnimation(.smooth(duration: 0.28)) { model.sidebarVisible.toggle() }
            }
            SlateMark(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .help(title)
                    .accessibilityLabel(title == "Roundtable" ? title : "Roundtable topic: \(title)")
                if convo.agentModels.count >= 2 {
                    Text("\(convo.agentModels.count) models · \(convo.agentRounds) round\(convo.agentRounds == 1 ? "" : "s")\(convo.agentSynthesis ? " · synthesis" : "")")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityLabel("\(convo.agentModels.count) models, \(convo.agentRounds) round\(convo.agentRounds == 1 ? "" : "s")\(convo.agentSynthesis ? ", with synthesis" : "")")
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Bottom bar for an active roundtable: a Stop button while it runs, otherwise
    /// a compact "new topic" field to start another discussion plus a Reconfigure
    /// button. Uses the same glass composer language as the chat composer.
    @ViewBuilder
    private func roundtableControls(_ convo: Conversation) -> some View {
        let busyHere = model.isGenerating && model.generatingConvoID == convo.id
        VStack(spacing: 6) {
            if busyHere {
                // Glass must live INSIDE the button style. Applying .clearGlass()
                // as an OUTER modifier layers .glassEffect(.clear.interactive())
                // on top of a plain button, and that interactive glass swallowed
                // the tap - so Stop never fired. ClearGlassButtonStyle applies the
                // same glass to the label, keeping the button's tap intact.
                Button { model.stop() } label: {
                    Label("Stop roundtable", systemImage: "stop.fill")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(ClearGlassButtonStyle())
                .liquidHover(1.05)
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    Button { showAgentConfig = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(CircleGlassButtonStyle())
                    .liquidHover(1.08)
                    .help("Reconfigure the roundtable")
                    .accessibilityLabel("Reconfigure roundtable")

                    TextField("New topic for the roundtable…", text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .clearGlass(RoundedRectangle(cornerRadius: DS.R.pill, style: .continuous))
                        .glassShadow(scheme, hero: true)
                        .onSubmit(startRoundtableTopic)

                    Button(action: startRoundtableTopic) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.primary.opacity(canStartTopic ? 1 : 0.25)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStartTopic)
                    .liquidHover(1.08)
                    .accessibilityLabel("Start discussion")
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 16)
        .frame(maxWidth: Self.contentWidth)
        .frame(maxWidth: .infinity)
        .background { GeometryReader { g in Color.clear.preference(key: BottomBarHeightKey.self, value: g.size.height) } }
        .animation(.smooth(duration: 0.2), value: busyHere)
        .sheet(isPresented: $showAgentConfig) {
            RoundtableSetup(convo: convo, isSheet: true, onDone: { showAgentConfig = false })
                .frame(minWidth: 460, minHeight: 520)
        }
    }

    private var canStartTopic: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.selected?.agentModels.count ?? 0 >= 2
            && !model.isGenerating && !model.roundtableActive
    }

    private func startRoundtableTopic() {
        guard canStartTopic, let id = model.selectedID else { return }
        let topic = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        model.runRoundtable(topic: topic, in: id)
    }

    @ViewBuilder
    private func chatCodeContent(_ convo: Conversation) -> some View {
        VStack(spacing: 0) {
            if convo.kind == .code && convo.folderURL == nil {
                topBar(convo)
                folderPrompt(convo)
            } else if showFiles || showPreview || showGit {
                HStack(spacing: 0) {
                    chatColumn(convo)
                    if showFiles, let folder = convo.folderURL {
                        Divider()
                        FileTreeView(root: folder, onOpen: { viewingFile = $0 },
                                     onClose: { withAnimation(.smooth(duration: 0.32)) { showFiles = false } })
                            .frame(width: 260)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    if showGit, let folder = convo.folderURL {
                        Divider()
                        GitPanel(folder: folder, onClose: { withAnimation(.smooth(duration: 0.32)) { showGit = false } })
                            .environment(model)
                            .frame(width: 340)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    if showPreview {
                        Divider()
                        previewColumn(convo)
                            .frame(width: 340)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .accessibilityElement(children: .contain)
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .accessibilityHidden(true)
                            .onAppear { workspaceWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, width in workspaceWidth = width }
                    }
                }
                // Fixed workspace rails stay predictable for keyboard and
                // VoiceOver. Yield the nav sidebar only when the panels need the
                // room; a manual sidebar re-open is never fought afterward.
                .onChange(of: showFiles, initial: true) { _, open in yieldSidebarIfCramped(open, width: workspaceWidth) }
                .onChange(of: showGit, initial: true) { _, open in yieldSidebarIfCramped(open, width: workspaceWidth) }
                .onChange(of: showPreview, initial: true) { _, open in yieldSidebarIfCramped(open, width: workspaceWidth) }
                .onChange(of: workspaceWidth) { _, width in
                    yieldSidebarIfCramped(showFiles || showGit || showPreview, width: width)
                }
            } else {
                chatColumn(convo)
            }
        }
        // Canvas lives ONCE on RootView (behind sidebar panel + detail alike);
        // this column stays transparent and rises to the window's top edge.
        .ignoresSafeArea(.container, edges: .top)
        // The single SwiftUI file picker for attachments, routed by `fileImport`.
        .fileImporter(isPresented: Binding(get: { fileImport != nil }, set: { if !$0 { fileImport = nil } }),
                      allowedContentTypes: importRoute.types,
                      allowsMultipleSelection: importRoute.multiple) { result in
            fileImport = nil
            guard case let .success(urls) = result, let first = urls.first else { return }
            switch importRoute {   // sticky - survives the early isPresented=false
            case .image: attachedImage = first
            case .context: for u in urls where !attachedContextFiles.contains(u) { attachedContextFiles.append(u) }
            }
        }
        .sheet(isPresented: Binding(get: { model.coordinator.pending != nil },
                                    set: { if !$0 { model.coordinator.resolve(false) } })) {
            if let req = model.coordinator.pending { ApprovalSheet(request: req, coordinator: model.coordinator) }
        }
        .sheet(isPresented: Binding(get: { viewingFile != nil }, set: { if !$0 { viewingFile = nil } })) {
            if let u = viewingFile { FileViewer(url: u) }
        }
        .overlay {
            if let session = voiceSession {
                VoiceOverlay(session: session, onEnd: endVoice)
            }
        }
        .background {
            Button("") {
                if let c = model.selected { voiceSession == nil ? startVoice(c) : endVoice() }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift]).opacity(0)
        }
        .onChange(of: convo.id) { _, _ in endVoice() }   // switching conversations ends the session
        // Window closed / view left mid-session: without this, flow.voiceActive
        // stays true and Fn dictation is dead app-wide until restart.
        .onDisappear { endVoice() }
        .alert("A task is still running", isPresented: $busyElsewhere) {
            Button("Go to task") {
                if let id = model.generatingConvoID { model.selectedID = id }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Slate is still working in another conversation. Wait for it to finish (or stop it there) before starting a new one.")
        }
        .alert("Clear attached knowledge?", isPresented: $confirmKnowledgeClear) {
            Button("Clear local index", role: .destructive) {
                model.knowledge.clear(for: convo.id.uuidString)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes Slate’s local index for this conversation. Your original files stay untouched.")
        }
        .alert("Remove local source?", isPresented: Binding(
            get: { knowledgeSourceToRemove != nil },
            set: { if !$0 { knowledgeSourceToRemove = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let name = knowledgeSourceToRemove {
                    model.knowledge.remove(fileNamed: name, from: convo.id.uuidString)
                }
                knowledgeSourceToRemove = nil
            }
            Button("Cancel", role: .cancel) { knowledgeSourceToRemove = nil }
        } message: {
            Text("Remove \(knowledgeSourceToRemove ?? "this source") from Slate’s local index? The original file stays untouched.")
        }
    }

    private func chatColumn(_ convo: Conversation) -> some View {
        transcript(convo)
            .overlay(alignment: .center) { emptyConversationState(convo) }
            .animation(.easeInOut(duration: 0.2), value: convo.messages.count)   // fade the empty state out
            .animation(.easeInOut(duration: 0.2), value: model.isModelLoaded)
            .overlay(alignment: .top) { topBar(convo) }
            .overlay(alignment: .bottom) { composer(convo) }
            // Drop anywhere in the conversation - not just on the composer. Images
            // fill the vision slot (when the model has one); everything else
            // becomes a context chip. A glass halo confirms the drop target.
            .dropDestination(for: URL.self, action: { urls, _ in acceptDrop(urls) },
                             isTargeted: { isDropTargeted = $0 })
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
                        .strokeBorder(.primary.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .background(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).fill(.primary.opacity(0.04)))
                        .padding(10).allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.15), value: isDropTargeted)
            .frame(minWidth: 400)   // split panes can't squeeze the chat into a sliver
            .onPreferenceChange(BottomBarHeightKey.self) { bottomBarHeight = $0 }
            .onChange(of: convo.id) { _, _ in attachedImage = nil }
            .onChange(of: model.activeModelIsVision) { _, vis in if !vis { attachedImage = nil } }
    }

    /// Accept dropped file URLs: images → the vision slot (model permitting),
    /// everything else → a context chip. Shared by the whole conversation area.
    private func acceptDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let vision = model.activeModelIsVision
        for url in urls {
            if vision, Self.isImageFile(url), attachedImage == nil {
                attachedImage = url
            } else if !attachedContextFiles.contains(url) {
                attachedContextFiles.append(url)
            }
        }
        return true
    }

    /// An empty open conversation is not a void: guide to a model when none is
    /// loaded, else a quiet inviting first frame. Fades out once a message lands.
    @ViewBuilder
    private func emptyConversationState(_ convo: Conversation) -> some View {
        let empty = convo.messages.allSatisfy { $0.role == .system }
        if empty && !model.loadingModel && !(model.isGenerating && model.generatingConvoID == convo.id) {
            if !model.isModelLoaded {
                NoModelGuidance(kind: convo.kind == .code ? .code : .chat)
                    .transition(.opacity)
            } else {
                VStack(spacing: 14) {
                    SlateMark(width: 54)
                    VStack(spacing: 6) {
                        Text(convo.kind == .code ? "What are we building?" : "What can I help with?")
                            .font(.system(size: 22, weight: .semibold)).foregroundStyle(.primary)
                        Text(convo.kind == .code ? "Slate can read, edit and run your project - locally."
                                                 : "Ask anything. It runs entirely on your Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        Text("Press")
                        Text("⌘K").font(.caption.monospaced())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.primary.opacity(0.08)))
                        Text("for commands")
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                }
                .transition(.opacity)
            }
        }
    }

    /// Collapse the nav sidebar when a just-opened workspace panel would overflow
    /// the available detail width (chat floor + every open right panel). No-op on
    /// wide windows and when closing a panel, so it never fights the user.
    private func yieldSidebarIfCramped(_ opening: Bool, width: CGFloat) {
        // width <= 1 means geometry isn't measured yet — don't collapse on a bogus 0.
        guard opening, model.sidebarVisible, width > 1 else { return }
        let needed: CGFloat = 400   // chatColumn floor
            + (showFiles ? 200 : 0)
            + (showGit ? 340 : 0)
            + (showPreview ? 340 : 0)
        if needed > width {
            withAnimation(.smooth(duration: 0.28)) { model.sidebarVisible = false }
        }
    }

    // MARK: Live preview (Artifacts)

    private func previewColumn(_ convo: Conversation) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                SectionLabel(text: "Preview", system: "safari")
                TextField("localhost:3000", text: $previewServerURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: 140)
                    .help("Preview a local dev server (localhost only). Leave empty to show the project's HTML.")
                Spacer(minLength: 6)
                ToolbarIconButton(system: previewAutoRefresh ? "bolt.fill" : "bolt",
                                  active: previewAutoRefresh, help: "Auto-refresh the dev server (1.5s)") {
                    previewAutoRefresh.toggle()
                }
                ToolbarIconButton(system: "arrow.clockwise", help: "Refresh preview") {
                    previewRevision &+= 1
                }
                ToolbarIconButton(system: "xmark", help: "Close preview") {
                    withAnimation(.smooth(duration: 0.32)) { showPreview = false }
                }
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            .padding(.top, 6)   // breathing room below the window's top edge
            Divider()
            if let source = previewSource(convo) {
                WebPreview(source: source, folder: convo.folderURL, reloadToken: previewRevision)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "safari").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("No HTML to preview yet").foregroundStyle(.secondary).font(.callout)
                    Text(convo.folderURL != nil
                         ? "Ask Slate to build or edit a web page - index.html renders here live."
                         : "Open a project folder and ask Slate to build a web page.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 340)
        .background(.background)
        .onChange(of: model.isGenerating) { _, generating in
            // A turn just finished → the agent may have written/edited files on disk.
            if !generating {
                previewRevision &+= 1
                refreshGit(model.selected?.folderURL)
            }
        }
        .task(id: model.selected?.folderURL) { refreshGit(model.selected?.folderURL) }
        .task(id: previewAutoRefresh) {
            // Live-refresh a local dev server on a short cadence while enabled.
            guard previewAutoRefresh else { return }
            while !Task.isCancelled && previewAutoRefresh {
                try? await Task.sleep(for: .seconds(1.5))
                if DevServerURL.parse(previewServerURL) != nil { previewRevision &+= 1 }
            }
        }
    }

    /// What the live preview renders. In a Code session the agent writes files
    /// via `write_file`, so prefer the FILE on disk (loaded via loadFileURL  - 
    /// the only way WKWebView gets read access to css/js/images next to it);
    /// in a Chat session fall back to the last HTML code block in a message.
    private func previewSource(_ convo: Conversation) -> PreviewSource? {
        // A typed local dev-server address wins over on-disk HTML.
        if let server = DevServerURL.parse(previewServerURL) {
            return .url(server)
        }
        if let folder = convo.folderURL, let file = newestHTMLFile(in: folder) {
            return .file(file)
        }
        for msg in convo.messages.reversed() where msg.role == .assistant {
            let answer = MarkdownText.splitThink(msg.content).answer
            for seg in MarkdownText.segments(answer).reversed() {
                if case let .code(lang, code) = seg,
                   lang.lowercased().contains("html") || code.contains("<html") || code.contains("<!DOCTYPE") {
                    return .inline(code)
                }
            }
        }
        return nil
    }

    /// Newest HTML document on disk under `folder`: root `index.html` wins,
    /// otherwise the most-recently-modified `.html` anywhere below.
    private func newestHTMLFile(in folder: URL) -> URL? {
        let fm = FileManager.default
        let index = folder.appendingPathComponent("index.html")
        if fm.fileExists(atPath: index.path) { return index }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles]) else { return nil }
        var htmls: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "html" {
            htmls.append(url)
        }
        return htmls.max { a, b in
            let da = (try? a.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    // MARK: Header

    /// Narrow windows / split panes: render the densest row that actually FITS
    /// (full → compact → minimal) instead of letting pills compress until their
    /// text char-wraps into vertical blobs.
    private enum HeaderDensity { case full, compact, minimal }

    private func header(_ convo: Conversation) -> some View {
        ViewThatFits(in: .horizontal) {
            headerRow(convo, .full)
            headerRow(convo, .compact)
            headerRow(convo, .minimal)
        }
    }

    @ViewBuilder
    private func headerRow(_ convo: Conversation, _ density: HeaderDensity) -> some View {
        let codeFolder = convo.kind == .code && convo.folderURL != nil
        HStack(spacing: DS.Space.l) {
            Text(convo.title).font(.headline).lineLimit(1)
                .help(headerSubtitle(convo))   // subtitle lives in the tooltip now
            Spacer(minLength: DS.Space.l)
            if density != .minimal { modelSwitcher }
            if density == .full {
                if model.usingCloud { effortSwitcher }
                // A context gauge is meaningless with no model loaded - only show it
                // when there's an active model whose window it can measure.
                if model.isModelLoaded {
                    ContextGauge(used: model.contextTokens, limit: model.contextLimit, tokensPerSec: model.tokensPerSec)
                        .fixedSize()
                }
            }
            // RAM fit is a core "does this model even run" signal - keep it visible
            // even when the header is too tight for the full status row (only the
            // very narrow minimal tier drops it).
            if density != .minimal { ramGauge }
            if convo.kind == .code, density != .minimal {
                planChip(convo)
                modeToggle
            }
            HStack(spacing: DS.Space.xs) {
                if codeFolder, density == .full {
                    gitChip
                }
                // Files toggle survives into the compact tier so it never becomes
                // unreachable in a crowded header (the panel also has its own close).
                if codeFolder, density != .minimal {
                    ToolbarIconButton(system: "sidebar.squares.leading", active: showFiles, help: "Files") {
                        withAnimation(.smooth(duration: 0.32)) { showFiles.toggle() }
                    }
                }
                // Preview is a dev tool - chat stays a pure messenger.
                if convo.kind == .code, density != .minimal {
                    ToolbarIconButton(system: "safari", active: showPreview, help: "Live web preview") {
                        withAnimation(.smooth(duration: 0.32)) { showPreview.toggle() }
                    }
                }
                // Web search: only for search-capable cloud engines; disabled and
                // grayed out while Silent Mode blocks all network.
                if model.activeEngineSupportsWebSearch, density != .minimal {
                    let silent = model.settings.silentModeEnabled
                    ToolbarIconButton(system: "globe",
                                      active: model.settings.webSearchEnabled && !silent,
                                      help: silent ? "Web search is off in Silent Mode" : "Web search") {
                        model.settings.webSearchEnabled.toggle()
                    }
                    .disabled(silent)
                    .opacity(silent ? 0.4 : 1)
                }
                overflowMenu(convo)
            }
        }
    }

    /// Native model switcher in the header: Cloud (+ its Opus/Sonnet/Haiku choice)
    /// and every installed local model, one click.
    private var modelSwitcher: some View {
        @Bindable var settings = model.settings
        return Menu {
            Button { model.pickClaudeCode() } label: {
                Label("Cloud · Claude Code",
                      systemImage: (model.usingCloud && model.activeCloudProviderID == nil) ? "checkmark" : "cloud")
            }
            Menu {
                Button { settings.claudeModel = nil; model.pickClaudeCode() } label: {
                    Label("Default", systemImage: settings.claudeModel == nil ? "checkmark" : "sparkle")
                }
                ForEach(AppSettings.claudeModelOptions, id: \.self) { m in
                    Button { settings.claudeModel = m; model.pickClaudeCode() } label: {
                        Label(m.capitalized, systemImage: settings.claudeModel == m ? "checkmark" : "cloud")
                    }
                }
            } label: {
                Label("Cloud model · \(settings.claudeModel?.capitalized ?? "Default")", systemImage: "slider.horizontal.3")
            }
            ForEach(model.settings.cloudProviders) { p in
                Button { model.pickCloudModel(p) } label: {
                    Label("Cloud · \(p.name)", systemImage: model.activeCloudProviderID == p.id ? "checkmark" : "cloud")
                }
            }
            ForEach(settings.openCodeModels, id: \.self) { id in
                Button { model.pickOpenCodeModel(id) } label: {
                    Label("OpenCode · \(id)",
                          systemImage: model.activeCloudProviderID == "opencode:\(id)" ? "checkmark" : "terminal")
                }
            }
            if !model.models.isEmpty { Divider() }
            ForEach(model.models) { m in
                Button {
                    if m.url != model.activeModelURL || model.usingCloud { model.pickLocalModel(m.url) }
                } label: {
                    Label(SidebarView.pretty(m.name),
                          systemImage: (m.url == model.activeModelURL && !model.usingCloud) ? "checkmark" : "cpu")
                }
            }
            Divider()
            Button("Manage models…") { model.showModelManager = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.loadingModel ? "hourglass" : (model.usingCloud ? "cloud" : "cpu"))
                    .font(.caption2)
                Text(modelSwitcherLabel)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .headerChip()
            .frame(maxWidth: 200)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Switch model")
    }

    private var modelSwitcherLabel: String {
        if model.loadingModel { return "Loading…" }
        if model.usingCloud { return model.activeModelName ?? "Cloud" }
        return model.activeModelName.map(SidebarView.pretty) ?? "No model"
    }

    /// Thinking-effort switcher - Cloud only (maps to Claude Code's thinking budget).
    private var effortSwitcher: some View {
        @Bindable var settings = model.settings
        return Menu {
            Picker("Thinking effort", selection: $settings.thinkingEffort) {
                ForEach(AppSettings.ThinkingEffort.allCases) { e in
                    Text(e.label).tag(e)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: settings.thinkingEffort.icon).font(.caption2)
                Text(settings.thinkingEffort.short).font(.caption).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(settings.thinkingEffort == .low ? .secondary : .primary)
            .headerChip()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("How hard Cloud turns think (raises Claude Code's thinking budget)")
    }

    private func headerSubtitle(_ convo: Conversation) -> String {
        convo.kind == .code
            ? (convo.folderURL?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Code session · no folder")
            : "Chat · \(model.activeModelName.map(SidebarView.pretty) ?? "no model")"
    }

    private func overflowMenu(_ convo: Conversation) -> some View {
        Menu {
            if convo.kind == .code, convo.folderURL != nil {
                Menu("Checkpoints") {
                    let cps = model.checkpoints(for: convo.id)
                    if cps.isEmpty {
                        Text("No checkpoints yet")
                    } else {
                        ForEach(cps) { cp in
                            Button("Restore  ·  \(cp.label.isEmpty ? "snapshot" : cp.label)  ·  \(cp.createdAt.formatted(date: .omitted, time: .shortened))") {
                                model.restoreCheckpoint(cp, for: convo.id)
                            }
                        }
                    }
                }
                Button("Copy handoff for Claude Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.handoffMarkdown(for: convo.id), forType: .string)
                    withAnimation { handoffCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { handoffCopied = false } }
                }
                Divider()
            }
            Divider()
            Button("Copy as Markdown") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.conversationMarkdown(convo.id), forType: .string)
                withAnimation { handoffCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { handoffCopied = false } }
            }
            Button("Export as Markdown…") { exportMarkdown(convo) }
            Divider()
            Button("Conversation settings…") { showConvoSettings = true }
            if let rules = model.activeProjectRules {
                Divider()
                if model.activeProjectRulesTrusted {
                    Button("Stop trusting \(rules)") { model.setProjectRulesTrusted(false, for: convo.id) }
                } else {
                    Button("Trust \(rules)…") { showProjectRulesTrust = true }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .foregroundStyle(.secondary).fixedSize()
        .help("More")
        .popover(isPresented: $showConvoSettings, arrowEdge: .bottom) {
            ConversationSettingsView(conversation: convo, defaultTemp: model.settings.defaultTemperature)
                .environment(model)
        }
        .alert("Trust project rules?", isPresented: $showProjectRulesTrust) {
            Button("Trust this version", role: .destructive) {
                model.setProjectRulesTrusted(true, for: convo.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rules can influence agent actions. Trust only projects you control. Trust is revoked automatically when the file changes.")
        }
    }

    /// ONE slim floating glass row (~48pt): glyph · title · pills · icons.
    /// Content scrolls visibly underneath and refracts. One slab = ONE glass
    /// shape; nothing inside it carries its own glass (never glass on glass).
    private func topBar(_ convo: Conversation) -> some View {
        HStack(spacing: DS.Space.l) {
            ToolbarIconButton(system: "sidebar.leading", help: "Toggle sidebar") {
                withAnimation(.smooth(duration: 0.28)) { model.sidebarVisible.toggle() }
            }
            SlateMark(width: 18)
            header(convo)
        }
        // The glass BAR stays symmetric (balanced in the window); only the CONTENT
        // insets to clear the floating traffic lights when the sidebar is collapsed
        // - the lights then sit over the empty left of the (still-centered) bar.
        // In fullscreen the lights auto-hide, so no clearance at all.
        .padding(.leading, model.sidebarVisible || model.isFullscreen ? 16 : 78)
        .padding(.trailing, 16).padding(.vertical, 9)
        // Concentric with the window corners (26 − ~10 inset), not a fatter 22.
        .clearGlass(RoundedRectangle(cornerRadius: DS.R.stage, style: .continuous))
        .glassShadow(scheme, hero: true)
        // The glass bar doubles as the window's drag region - native titlebar
        // behavior (buttons inside still win over the drag).
        .gesture(WindowDragGesture())
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .overlay(alignment: .top) {
            if handoffCopied {
                Label("Handoff copied to clipboard", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glassPill()
                    .padding(.top, 74)   // fully BELOW the glass row - never glass on glass
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let learned = model.memoryToast {
                // Quiet moment of delight: Slate just learned something durable.
                Label("Learned: \(learned)", systemImage: "sparkle")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glassPill()
                    .frame(maxWidth: 420)
                    .padding(.top, 74)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.memoryToast)
    }

    private var modeBinding: Binding<PermissionMode> {
        Binding(get: { model.selected?.mode ?? .recommendedDefault },
                set: { if let id = model.selectedID { model.setMode($0, for: id) } })
    }

    /// All three permission levels stay visible: new sessions fail closed with
    /// Ask, while broader access is always a deliberate user choice.
    private var modeToggle: some View {
        let current = model.selected?.mode ?? PermissionMode.recommendedDefault
        return HStack(spacing: 3) {
            modeSegment("ask", .ask, current: current)
            modeSegment("edits", .acceptEdits, current: current)
            modeSegment("auto", .autopilot, current: current)
        }
        .padding(3)
        .background(Capsule().fill(.primary.opacity(scheme == .dark ? 0.13 : 0.08)))
        .overlay(Capsule().strokeBorder(.primary.opacity(scheme == .dark ? 0.15 : 0.10), lineWidth: 0.5))
        .fixedSize()   // never compress into char-wrapped vertical blobs
        .help("Ask confirms every write and command. Edits allows normal file changes but asks before commands. Auto runs safe actions and asks about risky ones; only Settings › Security › Skip permissions removes those prompts.")
    }

    private func modeSegment(_ label: String, _ m: PermissionMode, current: PermissionMode) -> some View {
        Button {
            // Edits & Auto are Pro; Ask stays free. Show the upsell instead of switching.
            if m != .ask, !model.requirePro(.code) { return }
            if let id = model.selectedID { model.setMode(m, for: id) }
        } label: {
            Text(label)
                .font(.caption.weight(current == m ? .bold : .semibold))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .foregroundStyle(current == m ? AnyShapeStyle(modeInk(for: m))
                                              : AnyShapeStyle(.primary.opacity(0.68)))
                .background(Capsule().fill(current == m ? AnyShapeStyle(modeFill(for: m))
                                                           : AnyShapeStyle(.clear)))
                .overlay {
                    if current == m {
                        Capsule().strokeBorder(.white.opacity(scheme == .dark ? 0.24 : 0.38), lineWidth: 0.75)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(permissionAccessibilityLabel(for: m))
        .accessibilityValue(current == m ? "Selected" : "Not selected")
        .help(permissionHelp(for: m))
        .animation(.snappy(duration: 0.15), value: current)
    }

    /// Permission is a safety-relevant state, not a passive filter. The active
    /// segment is deliberately solid: neutral for Ask, the app accent for
    /// normal file edits, and amber for the broadest execution mode.
    private func modeFill(for mode: PermissionMode) -> Color {
        switch mode {
        case .ask:
            return scheme == .dark ? Color(white: 0.92) : Color(white: 0.12)
        case .acceptEdits:
            return palette.enabled ? palette.controlAccent : Color.indigo
        case .autopilot:
            return .orange
        }
    }

    private func modeInk(for mode: PermissionMode) -> Color {
        switch mode {
        case .ask:
            return scheme == .dark ? .black : .white
        case .acceptEdits:
            return palette.enabled ? palette.controlAccentInk : .white
        case .autopilot:
            return .black
        }
    }

    private func permissionAccessibilityLabel(for mode: PermissionMode) -> String {
        switch mode {
        case .ask: return "Ask permission mode"
        case .acceptEdits: return "Edits permission mode"
        case .autopilot: return "Auto permission mode"
        }
    }

    private func permissionHelp(for mode: PermissionMode) -> String {
        switch mode {
        case .ask: return "Ask: confirm every file change and command"
        case .acceptEdits: return "Edits: allow normal file changes, ask before commands"
        case .autopilot: return "Auto: run safe actions, ask about risky actions"
        }
    }

    /// Plan-first execution is intentionally unmistakable when enabled: it
    /// changes how every code turn starts, so a soft tint alone is not enough.
    private func planChip(_ convo: Conversation) -> some View {
        let on = convo.planMode
        return Button {
            model.setPlanMode(!on, for: convo.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "list.number" : "list.bullet")
                    .font(.caption.weight(.semibold))
                Text(on ? "plan on" : "plan")
                    .font(.caption.weight(on ? .bold : .semibold))
            }
            .foregroundStyle(on ? planInk : .primary.opacity(0.70))
            .padding(.horizontal, on ? 11 : 9).padding(.vertical, on ? 5 : 4)
            .background(Capsule().fill(on ? planFill : Color.clear))
            .overlay {
                if on {
                    Capsule().strokeBorder(.white.opacity(scheme == .dark ? 0.28 : 0.46), lineWidth: 0.75)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(on ? "Plan mode on" : "Plan mode off")
        .accessibilityValue(on ? "Enabled" : "Disabled")
        .help(on ? "Plan mode is on: the agent writes a short numbered plan before acting"
                 : "Plan first: the agent writes a short numbered plan, then works through it step by step")
    }

    private var planFill: Color {
        palette.enabled ? palette.controlAccent : Color(red: 0.60, green: 0.55, blue: 1.0)
    }

    private var planInk: Color {
        palette.enabled ? palette.controlAccentInk : .white
    }

    /// Live system-RAM readout - shared RAMChip (Design.swift).
    private var ramGauge: some View { RAMChip(ram: model.ram) }

    /// Quiet live git chip: branch · dirty count. Clicking opens the Git panel.
    private var gitChip: some View {
        Button { withAnimation(.smooth(duration: 0.32)) { showGit.toggle() } } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.caption2)
                Text(gitBranch ?? "git").font(.caption).lineLimit(1)
                    .frame(maxWidth: 110)   // long branch names truncate, never wrap
                if gitDirty > 0 {
                    Text("\(gitDirty)").font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
            }
            .foregroundStyle(showGit ? .primary : .secondary)
            .headerChip(active: showGit)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Git - review & commit")
    }

    private func refreshGit(_ folder: URL?) {
        guard let folder else { gitBranch = nil; gitDirty = 0; return }
        Task.detached(priority: .utility) {
            let branch = Git.isRepo(folder) ? Git.currentBranch(folder) : nil
            let dirty = branch != nil ? Git.status(folder).count : 0
            await MainActor.run { gitBranch = branch; gitDirty = dirty }
        }
    }

    // MARK: Folder prompt (code)

    private func folderPrompt(_ convo: Conversation) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "folder.badge.gearshape").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Code session").font(.title2.bold())
            Text("Choose a project folder. Slate can read, edit, and run commands inside it - within your permission mode.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button { chooseCodeFolder(for: convo, continueFromClaudeCode: false) } label: {
                        Label("Choose project folder…", systemImage: "folder")
                    }
                    .liquidHover()
                    Button { chooseCodeFolder(for: convo, continueFromClaudeCode: true) } label: {
                        Label("Continue from Claude Code", systemImage: "arrow.uturn.forward")
                    }
                    .liquidHover()
                }
                .buttonStyle(ClearGlassButtonStyle())
            }
            Text("“Continue from Claude Code” imports your latest Claude Code session for the chosen folder, so you pick up where it left off.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("No Claude Code sessions", isPresented: $ccNoSessions) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No Claude Code history was found for that folder (looked in ~/.claude/projects).")
        }
        .alert("Choose a folder", isPresented: Binding(get: { folderSelectionError != nil },
                                                        set: { if !$0 { folderSelectionError = nil } })) {
            Button("OK", role: .cancel) { folderSelectionError = nil }
        } message: {
            Text(folderSelectionError ?? "")
        }
    }

    /// Native panel avoids the SwiftUI .fileImporter directory-selection bug.
    /// On macOS 26, a directory-only panel can leave Open disabled even after a
    /// folder is visibly selected. Let the panel accept either item, then enforce
    /// the folder boundary after selection so the user always gets a usable path.
    private func chooseCodeFolder(for convo: Conversation, continueFromClaudeCode: Bool) {
        let panel = NSOpenPanel()
        panel.title = continueFromClaudeCode ? "Choose Claude Code project" : "Choose project folder"
        panel.message = continueFromClaudeCode
            ? "Choose the project folder whose local Claude Code session to import."
            : "Choose the folder Slate may access for this Code session."
        panel.prompt = continueFromClaudeCode ? "Continue" : "Choose Folder"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            folderSelectionError = "“\(folder.lastPathComponent)” is a file. Choose a project folder instead."
            return
        }
        if continueFromClaudeCode {
            if !model.importLatestClaudeCode(folder: folder) { ccNoSessions = true }
        } else {
            model.setFolder(folder, for: convo.id)
        }
    }

    // MARK: Transcript

    /// Per-message roundtable metadata: which turns START a new round (divider) and
    /// which OTHER seat a turn addresses by name (↩ chip). Pure + derived per render
    /// from the visible messages; resets at each user (topic) message.
    private static func roundtableMeta(visible: [ChatMessage], seatCount: Int)
        -> [UUID: (roundStart: Int?, replyTo: String?, replyToIndex: Int?)] {
        guard seatCount >= 2 else { return [:] }
        var nameIndex: [String: Int] = [:]
        for m in visible where m.role == .assistant {
            if let s = m.speaker, let i = m.speakerIndex, s != "Synthesis" { nameIndex[s] = i }
        }
        var out: [UUID: (roundStart: Int?, replyTo: String?, replyToIndex: Int?)] = [:]
        var counter = 0
        for m in visible {
            if m.role == .user { counter = 0; continue }
            guard m.role == .assistant, let s = m.speaker, s != "Synthesis" else { continue }
            let roundStart: Int? = (counter > 0 && counter % seatCount == 0) ? counter / seatCount + 1 : nil
            var reply: (name: String, idx: Int, pos: String.Index)?
            let lower = m.content.lowercased()
            for (name, idx) in nameIndex where name != s {
                if let r = lower.range(of: name.lowercased()),
                   reply == nil || r.lowerBound < reply!.pos {
                    reply = (name, idx, r.lowerBound)
                }
            }
            out[m.id] = (roundStart, reply?.name, reply?.idx)
            counter += 1
        }
        return out
    }

    /// The live "about to speak" turn: a bubble shell with the seat's pulsing
    /// aurora orb and a typing indicator, at the seat's own indent.
    private func agentThinkingBubble(speaker: String, index: Int) -> some View {
        let color = SpeakerStyle.color(index, scheme: scheme)
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    RoundtableSeatOrb(color: SpeakerStyle.aura(index, scheme: scheme),
                                      active: true, reduceMotion: reduceMotion)
                        .scaleEffect(0.62).frame(width: 16, height: 16)
                    Text(speaker.uppercased())
                        .font(.caption2.weight(.semibold)).tracking(0.8)
                        .foregroundStyle(color)
                }
                TypingIndicator()
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(Color.primary.opacity(scheme == .dark ? 0.05 : 0.08),
                        in: RoundedRectangle(cornerRadius: DS.R.bubble, style: .continuous))
            .background(color.opacity(scheme == .dark ? 0.10 : 0.07),
                        in: RoundedRectangle(cornerRadius: DS.R.bubble, style: .continuous))
            Spacer(minLength: 64)
        }
        .accessibilityLabel("\(speaker) is thinking")
    }

    /// Constant per-seat indent for roundtable turns - speakers sit at slightly
    /// different positions, like voices around a table. Capped for 3 seats;
    /// topics, synthesis and normal chats are unaffected.
    private static func seatIndent(kind: Conversation.Kind, speaker: String?, index: Int?) -> CGFloat {
        guard kind == .agents, let speaker, speaker != "Synthesis", let index else { return 0 }
        return CGFloat(min(index, 2)) * 26
    }

    private func transcript(_ convo: Conversation) -> some View {
        let visible = convo.messages.filter { $0.role != .system }
        let lastAssistantID = convo.messages.last(where: { $0.role == .assistant })?.id
        let ws = convo.kind == .code ? convo.folderURL : nil
        let rt = convo.kind == .agents ? Self.roundtableMeta(visible: visible, seatCount: convo.agentModels.count) : [:]
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Color.clear.frame(height: convo.kind == .agents ? 138 : 84).id("top")   // clearance for the floating header (+ roundtable seat rail)
                    ForEach(visible) { msg in
                        Group {
                            // A roundtable's user turns are TOPICS - render them as a
                            // quiet centered header, not a saturated chat bubble that
                            // reads badly (and unreadable under the glass header).
                            if convo.kind == .agents, msg.role == .user {
                                RoundtableTopicHeader(text: msg.content)
                            } else if convo.kind == .agents, msg.speaker == "Synthesis" {
                                RoundtableSynthesisCard(text: msg.content)
                            } else {
                                let meta = rt[msg.id]
                                if let round = meta?.roundStart {
                                    RoundtableRoundDivider(round: round)
                                }
                                MessageBubble(
                                    role: msg.role,
                                    text: msg.content,
                                    imagePath: msg.imagePath,
                                    stats: msg.stats,
                                    speaker: msg.speaker,
                                    speakerIndex: msg.speakerIndex,
                                    replyTo: meta?.replyTo,
                                    replyToIndex: meta?.replyToIndex,
                                    onRegenerate: (msg.id == lastAssistantID && !model.isGenerating && convo.kind != .agents) ? { model.regenerate() } : nil,
                                    onEdit: msg.role == .user ? { if let t = model.beginEdit(messageID: msg.id) { input = t } } : nil,
                                    onSpeak: msg.role == .assistant && !msg.content.isEmpty && voiceSession == nil
                                        ? { model.speech.toggle(msg.content, id: msg.id, voice: model.settings.assistantVoice) } : nil,
                                    isSpeaking: model.speech.speakingID == msg.id,
                                    workspaceURL: ws
                                )
                                .padding(.leading, Self.seatIndent(kind: convo.kind, speaker: msg.speaker, index: msg.speakerIndex))
                            }
                        }
                        .id(msg.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    // The live bubble belongs ONLY to the conversation that
                    // launched the turn - other conversations stay clean.
                    if model.isGenerating, model.generatingConvoID == convo.id {
                        Group {
                            if model.streamingText.isEmpty {
                                if convo.kind == .agents, let sp = model.streamingSpeaker, let idx = model.streamingSpeakerIndex {
                                    // Roundtable: the upcoming turn appears IMMEDIATELY
                                    // as a bubble with its seat's pulsing orb - the
                                    // table feels live before the first token arrives.
                                    agentThinkingBubble(speaker: sp, index: idx)
                                        .padding(.leading, Self.seatIndent(kind: convo.kind, speaker: sp, index: idx))
                                } else {
                                    HStack(alignment: .top, spacing: 0) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(model.streamingSpeaker?.uppercased() ?? "SLATE")
                                                .font(.caption2.weight(.semibold)).tracking(0.8)
                                                .foregroundStyle(model.streamingSpeakerIndex.map { SpeakerStyle.color($0, scheme: scheme) } ?? Color.secondary)
                                            HStack(spacing: 9) {
                                                TypingIndicator()
                                                Text(model.streamingSpeaker != nil ? "\(model.streamingSpeaker!) is thinking…" : "Thinking…")
                                                    .font(.callout).foregroundStyle(.secondary)
                                                    .shimmer()   // specular sweep = "actively working"
                                            }
                                        }
                                        Spacer(minLength: 64)
                                    }
                                }
                            } else {
                                MessageBubble(role: .assistant, text: model.streamingText,
                                              speaker: model.streamingSpeaker,
                                              speakerIndex: model.streamingSpeakerIndex,
                                              streaming: true, workspaceURL: ws)
                                    .padding(.leading, Self.seatIndent(kind: convo.kind, speaker: model.streamingSpeaker, index: model.streamingSpeakerIndex))
                            }
                        }
                        .id("streaming")
                        .transition(.opacity)
                    }
                    // Clearance = the live bottom-bar height (+ gap) so the last
                    // message always clears the floating glass bar instead of
                    // sliding under it and bleeding through.
                    Color.clear.frame(height: bottomBarHeight + 20).id("bottom")
                }
                .padding(.horizontal, 28).padding(.vertical, 18)
                .frame(maxWidth: Self.contentWidth)               // wide, balanced reading column…
                .frame(maxWidth: .infinity, alignment: .center)   // …centered in the window (composer shares it)
                .animation(.smooth(duration: 0.25), value: convo.messages.count)
                .animation(.easeInOut(duration: 0.2), value: model.isGenerating)
            }
            // Scrolling must ALWAYS work, even mid-generation. The old proximity
            // slack (120pt) was a trap: tokens re-anchored you to the bottom
            // faster than you could scroll out of the zone. Now ANY upward move
            // unpins immediately (user intent wins); reaching the very bottom
            // re-pins. Auto-scroll only ever moves DOWN, so it can't self-unpin.
            .onScrollGeometryChange(for: ScrollProbe.self) { g in
                ScrollProbe(offset: g.contentOffset.y,
                            atBottom: g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 24)
            } action: { old, new in
                if new.offset < old.offset - 1 { pinnedToBottom = false }
                else if new.atBottom { pinnedToBottom = true }
            }
            .onChange(of: convo.messages.count) { _, _ in
                if pinnedToBottom { withAnimation(.smooth) { proxy.scrollTo("bottom") } }
            }
            .onChange(of: model.streamingText) { _, _ in
                if pinnedToBottom { proxy.scrollTo("bottom") }
            }
            .onChange(of: convo.id) { _, _ in
                pinnedToBottom = true               // fresh conversation → follow again
                proxy.scrollTo("bottom")
            }
        }
    }

    // MARK: Composer (Liquid Glass)

    /// One row in the composer's "+" attach popover.
    private func addMenuRow(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func composer(_ convo: Conversation) -> some View {
        let ready = model.isModelLoaded
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let vision = model.activeModelIsVision
        let canSend = ready && (hasText || (vision && attachedImage != nil) || !attachedContextFiles.isEmpty)
        // Stop/streaming UI belongs to the conversation that RUNS the turn;
        // everywhere else the send button stays a send button (and warns).
        let busyHere = model.isGenerating && model.generatingConvoID == convo.id
        return VStack(spacing: 6) {
            // Only surface "Chat with your files" once a model is loaded - keep the
            // no-model empty state focused on the single next step (Choose model).
            if convo.kind != .image, ready {
                knowledgeChip(convo)
            }
            if model.lastPromptTrimmedCount > 0 {
                Label("Earlier messages were trimmed to fit this model's context. Type /compact to summarize instead.",
                      systemImage: "scissors")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if !ready {
                if model.loadingModel {
                    Text("Loading model…").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text(model.models.isEmpty ? "No model yet." : "No model loaded.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(model.models.isEmpty ? "Get a model" : "Choose model") {
                            model.showModelManager = true
                        }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.primary)
                    }
                }
            }
            // ONE container for every glass element of the composer, so nearby
            // shapes blend and appearing/disappearing ones morph out of the field
            // (glassEffectID + shared namespace) - 1:1 the Apple behavior.
            GlassEffectContainer(spacing: 14) {
                VStack(spacing: 6) {
                    if input.hasPrefix("/") { slashMenu(convo) }
                    if vision, let img = attachedImage {
                        // No custom transition: the glassEffectID morph IS the
                        // transition (the chip flows out of the composer field).
                        attachmentChip(img)
                    }
                    if !attachedContextFiles.isEmpty { contextChips }
                    HStack(alignment: .bottom, spacing: 10) {
                        // ONE "+" holds the attach / compare actions so the composer
                        // stays calm; mic + voice stay one tap away. A real Button
                        // (same CircleGlassButtonStyle as its neighbours) + a popover -
                        // a styled Menu label collapsed to a bare misaligned glyph.
                        Button { showAddMenu.toggle() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(CircleGlassButtonStyle())
                        .disabled(!ready)
                        .liquidHover(1.08)
                        .help("Attach files or images, compare models")
                        .accessibilityLabel("Add attachment")
                        .popover(isPresented: $showAddMenu, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                addMenuRow("Attach files", "paperclip") { openImporter(.context); showAddMenu = false }
                                if vision {
                                    addMenuRow("Attach image", "photo") { openImporter(.image); showAddMenu = false }
                                }
                                if convo.kind == .chat && model.compareCandidates.count >= 2 {
                                    Divider().padding(.vertical, 2)
                                    addMenuRow(compareMode ? "Comparing across models" : "Compare across models",
                                               compareMode ? "checkmark.rectangle.stack" : "rectangle.split.2x1") {
                                        if model.requirePro(.compare) { compareMode.toggle() }
                                        showAddMenu = false
                                    }
                                }
                            }
                            .padding(6).frame(width: 232)
                        }
                        // Dictate straight into this prompt (click, speak, click).
                        // Independent of the Fn hotkey and the Flow toggle.
                        Button {
                            flow.toggleComposerDictation { text in
                                input += (input.isEmpty || input.hasSuffix(" ") ? "" : " ") + text
                            }
                        } label: {
                            Image(systemName: flow.composerRecording ? "mic.fill" : "mic")
                                .font(.system(size: 16, weight: .medium))
                                .symbolEffect(.pulse, options: .repeat(.continuous),
                                              isActive: flow.composerRecording)
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(CircleGlassButtonStyle())
                        .liquidHover(1.08)
                        .help(flow.composerRecording ? "Stop & insert dictation"
                                                     : "Dictate into this chat (click, speak, click)")
                        .accessibilityLabel(flow.composerRecording ? "Stop dictation" : "Dictate")
                        // Live voice conversation - local model only (v1).
                        if convo.kind == .chat {
                            Button { startVoice(convo) } label: {
                                Image(systemName: "waveform")
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(width: 38, height: 38)
                            }
                            .buttonStyle(CircleGlassButtonStyle())
                            .disabled(!ready || model.usingCloud)
                            .liquidHover(1.08)
                            .accessibilityLabel("Start voice conversation")
                            .help(model.usingCloud
                                  ? "Voice needs a local model (Cloud is active)"
                                  : "Talk to Slate (⌘⇧V)")
                        }

                        TextField(compareMode ? "Ask all models…"
                                  : convo.kind == .code ? "run a task…" : "Message Slate…",
                                  text: $input, axis: .vertical)
                            .textFieldStyle(.plain)
                            // Code = cockpit: the input reads like a command line.
                            .font(convo.kind == .code ? .system(.body, design: .monospaced) : .body)
                            .lineLimit(1...8)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .clearGlass(RoundedRectangle(cornerRadius: DS.R.pill, style: .continuous))
                            .glassShadow(scheme, hero: true)
                            .glassEffectID("composer-field", in: glassNS)
                            .onSubmit(send)
                            // Also locked while the voice overlay runs: the field
                            // keeps first-responder BEHIND the overlay, and Return
                            // must never race a voice turn on the shared engine.
                            .disabled(!ready || voiceSession != nil)

                        Button {
                            busyHere ? model.stop() : send()
                        } label: {
                            // Solid graphite circle (not glassProminent, which frosts
                            // to a washed grey over the light canvas). Inverted icon.
                            Image(systemName: busyHere ? "stop.fill" : "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 40, height: 40)
                                .background(
                                    Circle().fill(.primary.opacity(busyHere || canSend ? 1 : 0.25)))
                        }
                        .buttonStyle(.plain)
                        .disabled(!busyHere && !canSend)
                        .liquidHover(1.08)
                        .animation(.smooth(duration: 0.2), value: busyHere)
                        .accessibilityLabel(busyHere ? "Stop generating" : "Send message")
                    }
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 16)
        .frame(maxWidth: Self.contentWidth)   // same column as the transcript - input lines up under the text
        .frame(maxWidth: .infinity)
        .background { GeometryReader { g in Color.clear.preference(key: BottomBarHeightKey.self, value: g.size.height) } }
        .animation(.snappy(duration: 0.28), value: attachedImage)
        // Key on the Bool, not the text - otherwise every keystroke animates the
        // subtree. Without this the slash menu pops unanimated and its
        // glassEffectID morph never fires.
        .animation(.snappy(duration: 0.25), value: input.hasPrefix("/"))
        // (Drop is handled on the whole conversation area - see chatColumn.)
        .animation(.snappy(duration: 0.25), value: attachedContextFiles)
    }

    /// Slash-command suggestions shown while the composer text starts with "/".
    /// Cloud shows Claude Code's own commands (+ discovered `.claude/commands`);
    /// local shows Slate's prompt-template shortcuts.
    private func slashMenu(_ convo: Conversation) -> some View {
        let prefix = String(input.dropFirst().prefix { !$0.isWhitespace })
        let pool = model.usingCloud
            ? SlashDiscovery.cloudCommands(folder: convo.folderURL)
            : SlashCommands.builtins
        let matches = input.contains(" ") ? [] : Array(SlashCommands.filter(pool, prefix: prefix).prefix(7))
        return VStack(spacing: 0) {
            ForEach(matches) { cmd in
                Button { input = "/\(cmd.name) " } label: {
                    HStack(spacing: 8) {
                        Text("/\(cmd.name)").font(.callout.weight(.semibold).monospaced())
                        Text(cmd.summary).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle()).padding(.horizontal, 12).padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                if cmd.id != matches.last?.id { Divider().opacity(0.4) }
            }
        }
        .clearGlass(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous))
        .glassShadow(scheme)
        .glassEffectID("slash-menu", in: glassNS)
        .frame(maxWidth: 560)
        .opacity(matches.isEmpty ? 0 : 1)
    }

    /// Chips for files attached as prompt context.
    private var contextChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // 16pt gap > container spacing (14): chips stay crisp separate pills at
            // rest (each has its own ✕), and still morph on add/remove.
            HStack(spacing: 16) {
                ForEach(attachedContextFiles, id: \.self) { url in
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text").font(.caption2).foregroundStyle(.secondary)
                        Text(url.lastPathComponent).font(.caption).lineLimit(1)
                        Button { attachedContextFiles.removeAll { $0 == url } } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .glassPill()
                    .glassEffectID("ctx-\(url.path)", in: glassNS)
                    .liquidHover(1.03)
                }
            }
        }
        .frame(maxWidth: 560)
    }

    private func attachmentChip(_ url: URL) -> some View {
        HStack(spacing: 8) {
            ThumbnailImage(path: url.path, maxPixel: 96, fixedSize: 36, corner: 4)   // concentric: chip 12 − 8 inset
            Text(url.lastPathComponent).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button { attachedImage = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove image")
        }
        .padding(8)
        .clearGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .glassShadow(scheme)
        .glassEffectID("attachment", in: glassNS)
        .frame(maxWidth: 560)
    }

    static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    // MARK: Voice session

    private func startVoice(_ convo: Conversation) {
        guard convo.kind == .chat, model.isModelLoaded, !model.usingCloud,
              voiceSession == nil else { return }
        guard model.requirePro(.voice) else { return }
        withAnimation(.smooth(duration: 0.25)) {
            voiceSession = VoiceSession(model: model, flow: flow, convoID: convo.id)
        }
    }

    private func endVoice() {
        voiceSession?.end()
        withAnimation(.smooth(duration: 0.25)) { voiceSession = nil }
    }

    /// "Chat with your files" affordance above the composer: attach files/folders,
    /// then answers are grounded in them (offline). Shows the indexed count + clear.
    @ViewBuilder
    private func knowledgeChip(_ convo: Conversation) -> some View {
        let id = convo.id.uuidString
        if model.knowledge.indexing.contains(id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Indexing your files…").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
        } else if model.knowledge.hasKnowledge(for: id) {
            let names = model.knowledge.fileNames(for: id)
            let importReport = model.knowledge.lastImport(for: id)
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill").font(.caption2)
                Text("\(names.count) source\(names.count == 1 ? "" : "s") · answers grounded locally")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let importReport {
                    Image(systemName: importReport.hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(importReport.hasWarnings ? .orange : .green)
                        .help("Latest local import: \(importReport.summary)")
                        .accessibilityLabel("Latest local import: \(importReport.summary)")
                }
                Button { attachKnowledge(convo) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Add more files")
                    .accessibilityLabel("Add more files")
                Menu {
                    if let importReport, importReport.hasActivity {
                        importReportMenu(importReport)
                        Divider()
                    }
                    ForEach(names, id: \.self) { name in
                        Button {
                            knowledgeSourceToRemove = name
                        } label: {
                            Label("Remove \(name)", systemImage: "minus.circle")
                        }
                    }
                    Divider()
                    Button("Clear all local sources", role: .destructive) {
                        confirmKnowledgeClear = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Manage attached knowledge")
                .accessibilityLabel("Manage attached knowledge")
            }
            .font(.caption2)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
        } else {
            HStack(spacing: 6) {
                Button { attachKnowledge(convo) } label: {
                    Label("Chat with your files", systemImage: "books.vertical")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Attach files or a folder - answers will be grounded in them, 100% offline")
                if let importReport = model.knowledge.lastImport(for: id), importReport.hasActivity {
                    Image(systemName: importReport.hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(importReport.hasWarnings ? .orange : .green)
                        .help("Latest local import: \(importReport.summary)")
                        .accessibilityLabel("Latest local import: \(importReport.summary)")
                }
            }
        }
    }

    /// Native `Menu` only reliably renders actionable rows on macOS. These
    /// disabled buttons are intentionally informational; keeping the list short
    /// makes a large folder import legible without turning the composer menu
    /// into a second file browser.
    @ViewBuilder
    private func importReportMenu(_ report: KnowledgeService.ImportReport) -> some View {
        let visibleLimit = 4
        let rows = report.indexed.map { ($0, "checkmark.circle", "indexed") }
            + report.alreadyIndexed.map { ($0, "arrow.triangle.2.circlepath", "already added") }
            + report.unavailable.map { ($0, "exclamationmark.triangle", "no readable text") }

        Button("Latest local import · \(report.summary)") {}
            .disabled(true)
        ForEach(Array(rows.prefix(visibleLimit)), id: \.0) { row in
            Button {} label: {
                Label("\(row.0) · \(row.2)", systemImage: row.1)
            }
            .disabled(true)
        }
        if rows.count > visibleLimit {
            Button("\(rows.count - visibleLimit) more source\(rows.count - visibleLimit == 1 ? "" : "s")") {}
                .disabled(true)
        }
    }

    private func attachKnowledge(_ convo: Conversation) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files or folders to chat with (indexed locally, never uploaded)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        model.knowledge.add(panel.urls, to: convo.id.uuidString)
    }

    private func exportMarkdown(_ convo: Conversation) {
        let panel = NSSavePanel()
        let safe = convo.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = (safe.isEmpty ? "conversation" : safe) + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.conversationMarkdown(convo.id).write(to: url, atomically: true, encoding: .utf8)
    }

    private func send() {
        guard voiceSession == nil else { return }   // voice owns this conversation
        // One turn at a time: if another conversation is mid-task, warn instead
        // of silently queueing or hijacking the busy engine.
        if model.isGenerating, model.generatingConvoID != model.selectedID {
            busyElsewhere = true
            return
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = attachedImage
        let ctx = attachedContextFiles
        guard model.isModelLoaded, !text.isEmpty || image != nil || !ctx.isEmpty else { return }
        input = ""; attachedImage = nil; attachedContextFiles = []
        var prompt = text.isEmpty ? (image != nil ? "Describe this image in detail." : "") : text
        if !ctx.isEmpty {
            let blocks = ctx.compactMap { url -> String? in
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, (values.fileSize ?? .max) <= 1_000_000,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let content = String(data: data, encoding: .utf8) else { return nil }
                let capped = content.count > 12000 ? String(content.prefix(12000)) + "\n…(truncated)" : content
                return "Context - \(url.lastPathComponent):\n```\n\(capped)\n```"
            }
            prompt = blocks.joined(separator: "\n\n") + (prompt.isEmpty ? "" : "\n\n" + prompt)
        }
        guard !prompt.isEmpty else { return }
        if compareMode && model.compareCandidates.count >= 2 {
            model.compareAcrossModels(prompt, in: model.selectedID ?? UUID())
        } else {
            model.send(prompt, imagePath: image?.path)
        }
    }
}

struct MessageBubble: View {
    let role: ChatMessage.Role
    let text: String
    var imagePath: String? = nil
    var stats: String? = nil
    /// Agent Chat: when set, this assistant turn belongs to a named roundtable
    /// speaker - its name and per-speaker color replace the generic "SLATE" label.
    var speaker: String? = nil
    var speakerIndex: Int? = nil
    /// Roundtable: another seat this turn addresses by name (shows a ↩ chip).
    var replyTo: String? = nil
    var replyToIndex: Int? = nil
    var streaming: Bool = false
    var onRegenerate: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onSpeak: (() -> Void)? = nil
    var isSpeaking: Bool = false
    var workspaceURL: URL? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.slatePalette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if role == .user { Spacer(minLength: 120) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if speakerColor != nil, let speakerIndex {
                        // Roundtable: a mini aurora orb gives the seat a face (ties the
                        // transcript to the seat rail) - still calmer than a stripe.
                        ZStack {
                            Circle().fill(RadialGradient(
                                colors: [SpeakerStyle.aura(speakerIndex, scheme: scheme).opacity(0.95),
                                         SpeakerStyle.aura(speakerIndex, scheme: scheme).opacity(0)],
                                center: .center, startRadius: 0, endRadius: 8))
                            Circle().fill(.white.opacity(0.75)).frame(width: 3.5, height: 3.5)
                        }
                        .frame(width: 13, height: 13)
                        .accessibilityHidden(true)
                    }
                    Text(label).font(.caption2.weight(.semibold)).tracking(0.8)
                        .foregroundStyle(speakerColor ?? (palette.enabled ? bubbleInk.opacity(0.72) : Color.secondary))
                    if let replyTo, let replyToIndex {
                        // This turn addresses another seat by name - show the thread.
                        HStack(spacing: 3) {
                            Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 7))
                            Text(replyTo).font(.caption2)
                        }
                        .foregroundStyle(SpeakerStyle.color(replyToIndex, scheme: scheme))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(SpeakerStyle.color(replyToIndex, scheme: scheme).opacity(0.12)))
                        .accessibilityLabel("Replying to \(replyTo)")
                    }
                    if hovering {
                        actions.transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                contentView
                // Writing caret - only once VISIBLE answer text is flowing. During
                // the <think> phase the answer is empty and a lone bar on blank
                // canvas just looks broken (the Thinking row covers that state).
                if streaming,
                   !MarkdownText.splitThink(text).answer
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    StreamingCursor()
                }
                // Quiet provenance footer, only while hovering - pro, not noisy.
                if hovering, role == .assistant, let stats {
                    Text(stats).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.14), value: hovering)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(background, in: RoundedRectangle(cornerRadius: DS.R.bubble, style: .continuous))
            // Roundtable: a whisper of the seat colour under the neutral fill, so
            // speakers separate at a glance without the (rejected) loud stripe.
            .background((speakerColor ?? .clear).opacity(speakerColor == nil ? 0 : (scheme == .dark ? 0.10 : 0.07)),
                        in: RoundedRectangle(cornerRadius: DS.R.bubble, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.R.bubble, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: role == .assistant ? 0.5 : 0))
            // Wide content (a table or a code block) FILLS the reading column so
            // its horizontal scroll has a bounded width - otherwise it pushes the
            // hugging bubble past the column edge and clips.
            .frame(maxWidth: (role == .assistant && hasWideBlock) ? .infinity : nil, alignment: .leading)
            // WhatsApp-style: you (right) vs agent (left). Each bubble hugs its
            // content - a short answer stays a small bubble - up to a gutter that
            // caps the width.
            if role != .user { Spacer(minLength: hasWideBlock ? 20 : 120) }
        }
        .onHover { hovering = $0 }
    }

    /// True when the answer contains a table or fenced code - those need the
    /// bubble to fill the column (bounded horizontal scroll), not hug.
    private var hasWideBlock: Bool {
        guard role == .assistant else { return false }
        let a = MarkdownText.splitThink(text).answer
        return a.contains("```") || a.contains("|--") || a.contains("| --")
    }

    @ViewBuilder private var contentView: some View {
        switch role {
        case .assistant:
            MarkdownText(text: text, workspaceURL: workspaceURL, foreground: bubbleInk)
        case .tool:
            Text(text).font(.system(.callout, design: .monospaced))
                .foregroundStyle(bubbleInk)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 8) {
                if let imagePath {
                    ThumbnailImage(path: imagePath, maxPixel: 520)
                }
                if !text.isEmpty {
                    Text(text).foregroundStyle(bubbleInk).textSelection(.enabled)   // non-greedy so the bubble hugs the text
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { copy() } label: { Image(systemName: "doc.on.doc") }
                .help("Copy").accessibilityLabel("Copy message")
            if let onSpeak {
                Button(action: onSpeak) { Image(systemName: isSpeaking ? "stop.circle" : "speaker.wave.2") }
                    .help(isSpeaking ? "Stop" : "Read aloud")
                    .accessibilityLabel(isSpeaking ? "Stop reading" : "Read aloud")
            }
            if let onRegenerate { Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") }
                .help("Regenerate").accessibilityLabel("Regenerate") }
            if let onEdit { Button(action: onEdit) { Image(systemName: "pencil") }
                .help("Edit & resend").accessibilityLabel("Edit and resend") }
        }
        .font(.caption2)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var label: String {
        if let speaker { return speaker.uppercased() }
        switch role { case .user: return "YOU"; case .assistant: return "SLATE"
        case .tool: return "TOOL"; case .system: return "SYSTEM" }
    }
    /// The seat color for a roundtable turn (nil for ordinary chat bubbles).
    private var speakerColor: Color? {
        guard role == .assistant, let speakerIndex else { return nil }
        return SpeakerStyle.color(speakerIndex, scheme: scheme)
    }
    private var background: AnyShapeStyle {
        // Light needs a touch more fill to separate bubbles from the pale canvas;
        // dark stays subtle (bright fills glow on near-black).
        let dark = scheme == .dark
        switch role {
        case .user:
            return AnyShapeStyle(palette.enabled
                                 ? palette.userBubble.opacity(dark ? 0.78 : 0.84)
                                 : Color.primary.opacity(dark ? 0.10 : 0.14))
        case .assistant:
            // Agent Chat speakers use the SAME bubble as any assistant reply, so
            // text keeps its contrast-safe ink; identity comes from the colored
            // name label + the thin left rule, not a wash that muddies the text.
            return AnyShapeStyle(palette.enabled
                                 ? palette.assistantBubble.opacity(dark ? 0.78 : 0.84)
                                 : Color.primary.opacity(dark ? 0.05 : 0.08))
        case .tool:
            if palette.enabled {
                return AnyShapeStyle(palette.toolBubble.opacity(dark ? 0.78 : 0.84))
            }
            return AnyShapeStyle(.quaternary.opacity(0.5))
        default: return AnyShapeStyle(Color.clear)
        }
    }

    private var bubbleInk: Color {
        guard palette.enabled else { return .primary }
        switch role {
        case .user: return palette.userBubbleInk
        case .assistant: return palette.assistantBubbleInk
        case .tool: return palette.toolBubbleInk
        case .system: return .primary
        }
    }
}

struct ApprovalSheet: View {
    let request: ApprovalRequest
    let coordinator: ApprovalCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(request.title, systemImage: icon)
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(request.detail.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(Self.fg(line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 1)
                            .background(Self.bg(line))
                    }
                }
            }
            .frame(maxHeight: 340)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
            HStack {
                Button("Reject") { coordinator.resolve(false) }
                    .buttonStyle(ActionGlassButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if request.risk != .destructive {
                    Button("Allow for this session") { coordinator.resolve(true, rememberForSession: true) }
                        .buttonStyle(ActionGlassButtonStyle())
                        .help("Auto-approve only this exact \(scopeName) at the same risk level until Slate quits or Kill all")
                }
                Button("Approve") { coordinator.resolve(true) }
                    .buttonStyle(ActionGlassButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 580)
    }

    private var icon: String {
        switch request.kind {
        case .shellCommand: return "terminal"
        case .fileWrite: return "pencil"
        case .localTool: return "wrench.and.screwdriver"
        }
    }

    private var scopeName: String {
        switch request.kind {
        case .shellCommand: return "command"
        case .fileWrite: return "file path"
        case .localTool: return "tool call and arguments"
        }
    }

    static func fg(_ l: String) -> Color {
        if l.hasPrefix("+ ") { return .green }
        if l.hasPrefix("- ") { return .red }
        return .primary
    }
    static func bg(_ l: String) -> Color {
        if l.hasPrefix("+ ") { return .green.opacity(0.12) }
        if l.hasPrefix("- ") { return .red.opacity(0.12) }
        return .clear
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.slatePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var hasModel: Bool { model.isModelLoaded || model.usingCloud }

    var body: some View {
        VStack(spacing: 28) {
            if !hasModel {
                // Nothing usable yet: getting a model IS the primary action.
                NoModelGuidance(kind: .chat, markWidth: 72)
            } else {
                VStack(spacing: 10) {
                    SlateMark(width: 58)
                    Text("Start with an idea")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Chat, build, or create - all from one private workspace.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                ViewThatFits(in: .horizontal) {
                    // Wide: one balanced row of four.
                    HStack(spacing: 14) {
                        startCard(.chat)
                        startCard(.code)
                        startCard(.image)
                        startCard(.agents)
                    }
                    // Narrower: a tidy 2×2 grid (not a tall, sparse single column).
                    Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                        GridRow { startCard(.chat); startCard(.code) }
                        GridRow { startCard(.image); startCard(.agents) }
                    }
                }
                .frame(maxWidth: 760)
            }

            // Quiet discoverability hint for the command palette.
            HStack(spacing: 5) {
                Text("Press")
                Text("⌘K").font(.caption.monospaced())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.primary.opacity(0.08)))
                Text("for commands")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One-shot entrance - skipped under Reduce Motion.
        .opacity(reduceMotion ? 1 : (appeared ? 1 : 0))
        .offset(y: reduceMotion ? 0 : (appeared ? 0 : 10))
        .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: appeared)
        .onAppear { appeared = true }
    }

    private enum StartKind { case chat, code, image, agents }

    private func startCard(_ kind: StartKind) -> some View {
        let details: (title: String, subtitle: String, system: String, tint: Color, action: () -> Void)
        switch kind {
        case .chat:
            details = ("Chat", "Ask, analyze and translate", "bubble.left.and.bubble.right",
                       palette.enabled ? palette.controlAccent : Color(hue: 0.60, saturation: 0.68, brightness: 0.86),
                       { model.newConversation(kind: .chat) })
        case .code:
            details = ("Code", "Plan, edit and run projects", "chevron.left.forwardslash.chevron.right",
                       palette.enabled ? palette.surface : Color(hue: 0.75, saturation: 0.54, brightness: 0.82),
                       { model.newConversation(kind: .code) })
        case .image:
            details = ("Create", "Generate and remix on-device", "photo",
                       palette.enabled ? palette.accent : Color(hue: 0.10, saturation: 0.70, brightness: 0.90),
                       { model.newConversation(kind: .image) })
        case .agents:
            details = ("Roundtable", "Let 2-3 models discuss ideas", "person.3",
                       palette.enabled ? palette.surface : Color(hue: 0.42, saturation: 0.55, brightness: 0.78),
                       { model.newConversation(kind: .agents) })
        }
        return FeatureLaunchCard(title: details.title, subtitle: details.subtitle,
                                 system: details.system, tint: details.tint,
                                 action: details.action)
            .environment(\.colorScheme, scheme)
    }
}

/// The three primary ways to use Slate. Their equal visual weight turns the
/// otherwise empty home view into a calm feature map: everything important is
/// visible in one glance, while tools remain out of the way until needed.
private struct FeatureLaunchCard: View {
    let title: String
    let subtitle: String
    let system: String
    let tint: Color
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [tint.opacity(0.82), tint.opacity(0.24)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: system)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
                .shadow(color: tint.opacity(hovering ? 0.42 : 0.24), radius: hovering ? 12 : 7, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text("Start").font(.caption.weight(.semibold))
                    Image(systemName: "arrow.right").font(.caption2.weight(.bold))
                }
                .foregroundStyle(tint)
            }
            .padding(15)
            .frame(width: 164, height: 172, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
                    .fill(scheme == .dark ? AnyShapeStyle(.white.opacity(0.075))
                                          : AnyShapeStyle(.white.opacity(0.60)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.20 : 0.65), tint.opacity(hovering ? 0.42 : 0.18)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: hovering ? 1.2 : 0.8)
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.025 : 1)
        .shadow(color: .black.opacity(hovering ? (scheme == .dark ? 0.28 : 0.14) : 0.07),
                radius: hovering ? 16 : 8, y: hovering ? 8 : 4)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18, extraBounce: 0.08), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel("Start \(title)")
        .accessibilityHint(subtitle)
    }
}
