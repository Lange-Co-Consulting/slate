import SwiftUI
import SlateRemoteProtocol

struct ChatView: View {
    @Environment(AppState.self) private var app
    @Environment(\.slatePalette) private var pal
    @Environment(\.colorScheme) private var scheme
    @State var conversation: Conversation
    @State private var input = ""
    @State private var streamTask: Task<Void, Never>?
    @State private var isStreaming = false
    @State private var lastError: String?
    @State private var activeRunID: UUID?     // the assistant bubble currently streaming
    @State private var proNudge: String?      // brief "Slate Pro feature" hint
    @FocusState private var composerFocused: Bool

    /// Live when a real Mac link is up; otherwise we fall back to the demo mock.
    private var isLive: Bool { !app.isDemo && app.client.phase == .ready }

    var body: some View {
        VStack(spacing: 0) {
            if app.macStatus != .reachable {
                MacStatusBanner().padding(.horizontal, 12).padding(.top, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(conversation.messages) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                        if let lastError {
                            RunErrorCard(text: lastError, retry: retry).id("error")
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 14)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: conversation.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(conversation.messages.last?.id, anchor: .bottom) }
                }
                // Streaming grows the last bubble without changing the count —
                // keep it pinned to the bottom as tokens land.
                .onChange(of: conversation.messages.last?.text.count ?? 0) { _, _ in
                    withAnimation(.smooth(duration: 0.15)) {
                        proxy.scrollTo(conversation.messages.last?.id, anchor: .bottom)
                    }
                }
            }
            if let proNudge {
                ProNudgeBar(text: proNudge).padding(.horizontal, 12).padding(.bottom, 6)
                    .transition(.opacity)
            }
            composer
        }
        .animation(.smooth(duration: 0.2), value: proNudge)
        .onAppear { wireCallbacks() }
        .onDisappear {
            // The live client's callbacks are rebound per-view, so leaving mid-stream would
            // orphan the in-flight run (its tokens land in the next chat's callbacks and are
            // dropped, leaving a bubble stuck "streaming"). Stop it cleanly before persisting.
            // Background continuation across navigation is a P1 item in the full-remote-app spec.
            if isStreaming { stop() }
            app.upsert(conversation)
        }
        .task(id: proNudge) {
            guard proNudge != nil else { return }
            try? await Task.sleep(for: .seconds(3.5))
            proNudge = nil
        }
        .canvas()
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The title is just a title; model selection lives in the trailing menu.
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(conversation.title).font(.slate(16, .medium)).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(conversation.model).font(.slate(12)).foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu("Model") {
                        ForEach(app.models, id: \.self) { m in
                            Button { conversation.model = m; app.currentModel = m } label: {
                                Label(m, systemImage: conversation.model == m ? "checkmark" : "cpu")
                            }
                        }
                    }
                    Button("Simulate a model-too-large error", systemImage: "exclamationmark.triangle") {
                        simulateOOM()
                    }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Theme.ink) }
            }
        }
        .toolbarBackground(Theme.washedCanvas(pal, scheme), for: .navigationBar)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack {
                TextField("Message your Mac…", text: $input, axis: .vertical)
                    .font(.slate(16)).foregroundStyle(Theme.ink)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .tint(Theme.ink)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(SlateShape(radius: 18).fill(Theme.surface))
            .overlay(SlateShape(radius: 18).strokeBorder(Theme.hairline, lineWidth: 1))

            if isStreaming {
                Button(action: stop) {
                    Image(systemName: "stop.fill").font(.slate(16, .medium))
                        .foregroundStyle(Theme.canvas)
                        .frame(width: 44, height: 44).background(Circle().fill(Theme.danger))
                }.buttonStyle(.plain)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.slate(17, .medium))
                        .foregroundStyle(input.isEmpty ? Theme.canvas : (pal.enabled ? pal.accentInk : Theme.canvas))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(input.isEmpty ? Theme.inkTertiary
                                                                 : (pal.enabled ? pal.accent : Theme.ink)))
                }
                .buttonStyle(.plain).disabled(input.isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
        .background(Theme.washedCanvas(pal, scheme))
    }

    // MARK: - Send / stream (live client, or demo mock)

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""; lastError = nil; proNudge = nil; composerFocused = false
        conversation.messages.append(.init(role: .user, text: text))
        startRun(for: text)
    }

    private func retry() {
        lastError = nil
        guard let text = conversation.messages.last(where: { $0.role == .user })?.text else { return }
        startRun(for: text)
    }

    /// Append the empty streaming assistant bubble, then either drive it from the
    /// Mac (live) or the in-app mock (demo). Tokens land back by matching `id`.
    private func startRun(for text: String) {
        let assistant = ChatMessage(role: .assistant, text: "", streaming: true)
        conversation.messages.append(assistant)
        let id = assistant.id
        isStreaming = true
        activeRunID = id

        if isLive, let ref = resolveModelRef() {
            app.client.prompt(id: id, model: ref, text: text)
        } else {
            runMock(into: id, reply: cannedReply(for: text),
                    tool: text.lowercased().contains("news") ? "Searching the web…" : nil)
        }
    }

    /// Map the picker's display label back to the Mac's model ref for the wire.
    private func resolveModelRef() -> String? {
        let items = app.client.models
        guard !items.isEmpty else { return nil }
        return items.first(where: { $0.label == conversation.model })?.ref ?? items.first?.ref
    }

    private func stop() {
        if isLive, let id = activeRunID { app.client.stop(id: id) }
        streamTask?.cancel()
        endRun(id: activeRunID, dropIfEmpty: true)
    }

    /// Finish the active bubble: clear its spinner, drop it if nothing streamed.
    private func endRun(id: UUID?, dropIfEmpty: Bool) {
        if let id, let i = conversation.messages.firstIndex(where: { $0.id == id }) {
            conversation.messages[i].streaming = false
            conversation.messages[i].tool = nil
            if dropIfEmpty && conversation.messages[i].text.isEmpty {
                conversation.messages.remove(at: i)
            }
        }
        isStreaming = false
        activeRunID = nil
    }

    // MARK: - Live client callbacks
    //
    // Wired on appear. Each routes by the run's `id` so tokens land in the right
    // bubble; captured bindings let the escaping closures mutate this view's state.
    private func wireCallbacks() {
        let convo = $conversation
        let streaming = $isStreaming
        let error = $lastError
        let nudge = $proNudge
        let active = $activeRunID

        func index(_ id: UUID) -> Int? { convo.wrappedValue.messages.firstIndex(where: { $0.id == id }) }

        app.client.onToken = { id, s in
            guard let i = index(id) else { return }
            if convo.wrappedValue.messages[i].tool != nil { convo.wrappedValue.messages[i].tool = nil }
            convo.wrappedValue.messages[i].text += s
        }
        app.client.onTool = { id, name, phase in
            guard let i = index(id) else { return }
            convo.wrappedValue.messages[i].tool = (phase == .start) ? ChatView.toolLabel(name) : nil
        }
        app.client.onDone = { id in
            if let i = index(id) {
                convo.wrappedValue.messages[i].streaming = false
                convo.wrappedValue.messages[i].tool = nil
            }
            streaming.wrappedValue = false
            active.wrappedValue = nil
            if convo.wrappedValue.title == "New chat" {
                convo.wrappedValue.title = String(convo.wrappedValue.messages.first?.text.prefix(40) ?? "New chat")
            }
        }
        app.client.onError = { id, kind, msg in
            if let i = index(id) {
                convo.wrappedValue.messages[i].streaming = false
                convo.wrappedValue.messages[i].tool = nil
                if convo.wrappedValue.messages[i].text.isEmpty { convo.wrappedValue.messages.remove(at: i) }
            }
            error.wrappedValue = ChatView.errorText(kind, msg)
            streaming.wrappedValue = false
            active.wrappedValue = nil
        }
        app.client.onLocked = { id, feature in
            if let i = index(id) {
                convo.wrappedValue.messages[i].streaming = false
                convo.wrappedValue.messages[i].tool = nil
                if convo.wrappedValue.messages[i].text.isEmpty { convo.wrappedValue.messages.remove(at: i) }
            }
            nudge.wrappedValue = "\(feature.capitalized) is a Slate Pro feature."
            streaming.wrappedValue = false
            active.wrappedValue = nil
        }
    }

    private static func toolLabel(_ name: String) -> String {
        switch name {
        case "web_search", "web", "search": return "Searching the web…"
        default: return "Using \(name.replacingOccurrences(of: "_", with: " "))…"
        }
    }

    private static func errorText(_ kind: RunErrorKind, _ msg: String) -> String {
        switch kind {
        case .oom:
            return "Your Mac ran low on memory for this model. Try a smaller model, or close other apps on the Mac and retry."
        case .busy:
            return "Your Mac is busy with another run. Try again in a moment."
        case .model:
            return msg.isEmpty ? "That model couldn't run on your Mac." : msg
        case .internalError:
            return msg.isEmpty ? "Something went wrong on your Mac. Try again." : msg
        }
    }

    // MARK: - Demo mock

    private func runMock(into id: UUID, reply: String, tool: String?) {
        if tool != nil, let i = conversation.messages.firstIndex(where: { $0.id == id }) {
            conversation.messages[i].tool = tool
        }
        streamTask = Task {
            if tool != nil {
                try? await Task.sleep(for: .seconds(1.0))
                if Task.isCancelled { return }
                if let i = conversation.messages.firstIndex(where: { $0.id == id }) {
                    conversation.messages[i].tool = nil
                }
            }
            for word in reply.split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(45))
                if Task.isCancelled { return }
                guard let i = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
                conversation.messages[i].text += (conversation.messages[i].text.isEmpty ? "" : " ") + word
            }
            endRun(id: id, dropIfEmpty: false)
            if conversation.title == "New chat" {
                conversation.title = String(conversation.messages.first?.text.prefix(40) ?? "New chat")
            }
        }
    }

    private func simulateOOM() {
        lastError = "Your Mac couldn't run \(conversation.model): the model needs more memory than is free right now. Try a smaller model, or close other apps on the Mac and retry."
    }

    private func cannedReply(for text: String) -> String {
        "Running \(conversation.model) on your Mac. Here's a concise answer to “\(text.prefix(40))…” — the key points are laid out below, and I can expand any of them."
    }
}

/// A calm, transient "Slate Pro feature" hint above the composer.
struct ProNudgeBar: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.slate(13))
            Text(text).font(.slate(13, .medium))
            Spacer(minLength: 4)
            Text("Slate Pro").font(.slate(12, .medium)).foregroundStyle(Theme.inkSecondary)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(SlateShape(radius: Theme.rControl).fill(Theme.surface))
        .overlay(SlateShape(radius: Theme.rControl).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @Environment(\.slatePalette) private var pal
    var body: some View {
        let isUser = message.role == .user
        let bg: Color = pal.enabled ? (isUser ? pal.userBubble : pal.assistantBubble)
                                     : (isUser ? Theme.surfaceHigh : Theme.surface)
        let fg: Color = pal.enabled ? (isUser ? pal.userBubbleInk : pal.assistantBubbleInk)
                                    : Theme.ink
        // A hairline defines the monochrome assistant bubble against the canvas;
        // saturated palette bubbles carry their own edge.
        let showHairline = !isUser && !pal.enabled
        let hasContent = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let waitingForFirstToken = !isUser && message.streaming && !hasContent && message.tool == nil

        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if let tool = message.tool {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver").font(.slate(12))
                        Text(tool).font(.slate(13))
                        ProgressView().controlSize(.mini).tint(Theme.inkSecondary)
                    }
                    .foregroundStyle(Theme.inkSecondary)
                }

                if waitingForFirstToken {
                    TypingIndicator()
                        .background(SlateShape(radius: Theme.rBubble).fill(bg))
                        .overlay {
                            if showHairline {
                                SlateShape(radius: Theme.rBubble).strokeBorder(Theme.hairline, lineWidth: 1)
                            }
                        }
                } else if hasContent {
                    Group {
                        if isUser {
                            Text(message.text).font(.slate(16)).foregroundStyle(fg)
                                .textSelection(.enabled)
                        } else {
                            MarkdownText(text: message.text, ink: fg)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(SlateShape(radius: Theme.rBubble).fill(bg))
                    .overlay {
                        if showHairline {
                            SlateShape(radius: Theme.rBubble).strokeBorder(Theme.hairline, lineWidth: 1)
                        }
                    }
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

struct RunErrorCard: View {
    let text: String
    let retry: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger).font(.slate(15))
            VStack(alignment: .leading, spacing: 10) {
                Text(text).font(.slate(14)).foregroundStyle(Theme.ink)
                Button(action: retry) {
                    Text("Retry").font(.slate(14, .medium)).foregroundStyle(Theme.canvas)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(SlateShape(radius: 9).fill(Theme.ink))
                }.buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(SlateShape(radius: 16).fill(Theme.danger.opacity(0.08)))
        .overlay(SlateShape(radius: 16).strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1))
    }
}
