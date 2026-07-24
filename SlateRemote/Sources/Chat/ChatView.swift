import PhotosUI
import SwiftUI
import SlateRemoteProtocol

/// One conversation.
///
/// The view is thin on purpose: the conversation and any run in flight belong to `AppState`,
/// so opening the drawer, glancing at another surface or switching chats no longer aborts the
/// answer. It used to hold a `@State` copy and write it back on disappear, which meant leaving
/// the screen mid-answer had to kill the run to stop its tokens landing in the next chat.
struct ChatView: View {
    @Environment(AppState.self) private var app
    let conversationID: Conversation.ID
    let menu: AnyView

    @State private var input = ""
    @State private var staged: [StagedAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var didLand = false
    @FocusState private var composerFocused: Bool

    private var convo: Conversation? { app.conversations.first { $0.id == conversationID } }
    private var messages: [ChatMessage] { convo?.messages ?? [] }
    private var streaming: Bool { app.isStreaming(conversationID) }
    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if app.macStatus != .reachable {
                        MacStatusBanner().padding(.bottom, 4)
                    }
                    if messages.isEmpty { opener }
                    ForEach(messages) { msg in
                        MessageTurn(message: msg).id(msg.id)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                    if let error = app.runError[conversationID] {
                        RunErrorCard(text: error) { app.retry(in: conversationID) }.id("error")
                    }
                    // Room for the floating composer. Without it the newest reply sits under
                    // the glass and has to be scrolled out from beneath it.
                    Color.clear.frame(height: 96).id("bottom")
                }
                .padding(.horizontal, 16).padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .animation(.smooth(duration: 0.28), value: messages.count)
            // Land at the newest message, not the oldest. Opening a long chat used to start at
            // the top, so the first thing shown was whatever was said days ago.
            .task(id: conversationID) {
                didLand = false
                proxy.scrollTo("bottom", anchor: .bottom)
                await Task.yield()
                proxy.scrollTo("bottom", anchor: .bottom)
                didLand = true
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: messages.last?.text.count ?? 0) { _, _ in
                guard didLand else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .canvas()
        .safeAreaInset(edge: .bottom) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { menu }
            ToolbarItem(placement: .principal) { modelControl }
        }
        .task(id: app.proNudge[conversationID]) {
            guard app.proNudge[conversationID] != nil else { return }
            try? await Task.sleep(for: .seconds(3.5))
            app.proNudge[conversationID] = nil
        }
    }

    // MARK: Header

    /// The title IS the model control, the way every reference AI app does it. It used to be a
    /// static label with the picker buried in a submenu behind an ellipsis.
    private var modelControl: some View {
        Menu {
            ForEach(app.client.models, id: \.ref) { m in
                Button { switchModel(ref: m.ref, label: m.label) } label: {
                    Label(m.label, systemImage: convo?.modelRef == m.ref ? "checkmark" : "cpu")
                }
            }
            if app.client.models.isEmpty {
                ForEach(app.models, id: \.self) { label in
                    Button { switchModel(ref: nil, label: label) } label: { Text(label) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(convo?.modelLabel ?? "Slate").font(.slate(16, .medium))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Model: \(convo?.modelLabel ?? "none"). Tap to switch.")
    }

    /// What a brand-new chat shows instead of an empty void.
    private var opener: some View {
        VStack(spacing: 8) {
            WeaveMark(size: 40)
            Text("Ask your Mac anything")
                .font(.slate(21, .medium)).foregroundStyle(Theme.ink)
            Text("It runs on \(convo?.modelLabel ?? "your Mac"), on your own hardware.")
                .font(.slate(14)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90).padding(.bottom, 20)
        .transition(.opacity)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let nudge = app.proNudge[conversationID] {
                ProNudgeBar(text: nudge).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !staged.isEmpty {
                AttachmentStrip(items: staged) { item in
                    withAnimation(.snappy(duration: 0.2)) { staged.removeAll { $0.id == item.id } }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Photo library", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                    Button("Files", systemImage: "folder") { showFileImporter = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.slate(17, .medium)).foregroundStyle(Theme.inkSecondary)
                        .frame(width: 34, height: 34).contentShape(Circle())
                }
                .accessibilityLabel("Attach a photo or file")

                TextField("Message your Mac…", text: $input, axis: .vertical)
                    .font(.slate(16)).foregroundStyle(Theme.ink)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .tint(Theme.ink)
                    .padding(.vertical, 7)

                sendButton
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .glassCapsule(radius: 26)
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
        .animation(.smooth(duration: 0.24), value: staged.count)
        .animation(.smooth(duration: 0.24), value: app.proNudge[conversationID])
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in Task { await stagePhotos(items) } }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            withAnimation(.snappy(duration: 0.2)) {
                staged.append(contentsOf: urls.compactMap(AttachmentBuilder.file(at:)))
            }
        }
    }

    private var sendButton: some View {
        Button { streaming ? app.stopRun(in: conversationID) : send() } label: {
            Image(systemName: streaming ? "stop.fill" : "arrow.up")
                .font(.slate(16, .medium))
                .foregroundStyle(Theme.canvas)
                .frame(width: 34, height: 34)
                .background(Circle().fill(fill))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!streaming && !canSend)
        .animation(.snappy(duration: 0.2), value: streaming)
        .animation(.snappy(duration: 0.2), value: canSend)
        .accessibilityLabel(streaming ? "Stop" : "Send")
    }

    @Environment(\.slatePalette) private var pal
    private var fill: Color {
        if streaming { return Theme.danger }
        guard canSend else { return Theme.inkTertiary }
        return pal.enabled ? pal.accent : Theme.ink
    }

    // MARK: Actions

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let outgoing = staged.map(\.attachment)
        let shown = text.isEmpty ? attachmentSummary(staged) : text
        input = ""
        withAnimation(.snappy(duration: 0.22)) { staged.removeAll() }
        app.send(text, attachments: outgoing, in: conversationID, shownAs: shown)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func attachmentSummary(_ items: [StagedAttachment]) -> String {
        items.count == 1 ? items[0].name : "\(items.count) attachments"
    }

    private func stagePhotos(_ items: [PhotosPickerItem]) async {
        var built: [StagedAttachment] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data) else { continue }
            if let a = AttachmentBuilder.image(img) { built.append(a) }
        }
        let made = built
        await MainActor.run {
            withAnimation(.snappy(duration: 0.2)) { staged.append(contentsOf: made) }
            photoItems = []
        }
    }

    private func switchModel(ref: String?, label: String) {
        guard let i = app.conversations.firstIndex(where: { $0.id == conversationID }),
              app.conversations[i].modelRef != ref || app.conversations[i].modelLabel != label
        else { return }
        withAnimation(.snappy(duration: 0.2)) {
            app.conversations[i].modelRef = ref
            app.conversations[i].modelLabel = label
        }
        app.rememberModel(ref: ref, label: label)
        UISelectionFeedbackGenerator().selectionChanged()
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
        .glassCapsule(radius: Theme.rControl)
    }
}

/// One turn.
///
/// The user is bubbled and trailing; the assistant is plain text running the full width. Every
/// reference app does exactly this, and for a good reason — a long answer inside a bordered card
/// reads as a quotation rather than as the app talking, and the card's inset costs a tenth of
/// the line length on a phone.
struct MessageTurn: View {
    let message: ChatMessage
    @Environment(\.slatePalette) private var pal

    var body: some View {
        let isUser = message.role == .user
        // The Mac streams raw model output, so a reasoning model's chain of thought arrives
        // verbatim. Split it off at render time: thoughts never belong in the chat, and while
        // the model is still thinking we show the typing indicator in their place.
        let visible = isUser ? message.text : Reasoning.answer(message.text)
        let hasContent = !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let thinking = !isUser && message.streaming && Reasoning.isThinking(message.text)
        let waiting = !isUser && message.streaming && !hasContent && message.tool == nil

        HStack {
            if isUser { Spacer(minLength: 44) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                if let tool = message.tool {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver").font(.slate(12))
                        Text(tool).font(.slate(13))
                        ProgressView().controlSize(.mini).tint(Theme.inkSecondary)
                    }
                    .foregroundStyle(Theme.inkSecondary)
                    .transition(.opacity)
                }

                if waiting || thinking {
                    TypingIndicator()
                } else if hasContent {
                    if isUser {
                        Text(visible).font(.slate(16))
                            .foregroundStyle(pal.enabled ? pal.userBubbleInk : Theme.ink)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(SlateShape(radius: Theme.rBubble)
                                .fill(pal.enabled ? pal.userBubble : Theme.surfaceHigh))
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            MarkdownText(text: visible, ink: Theme.ink)
                                .textSelection(.enabled)
                            if message.streaming {
                                // A tail while tokens are still arriving. Without it a slow
                                // model is indistinguishable from a finished short answer —
                                // the indicator above only covers the wait before the first
                                // token, and this cursor was written but never mounted.
                                StreamingCursor()
                            } else {
                                MessageActions(text: visible)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if !isUser { Spacer(minLength: 0) }
        }
    }
}

/// Copy and share, on a finished answer. An answer you cannot get out of the app is an answer
/// you have to retype somewhere else.
private struct MessageActions: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 14) {
            Button {
                UIPasteboard.general.string = text
                withAnimation(.snappy) { copied = true }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.slate(12)).labelStyle(.titleAndIcon)
                    .contentTransition(.symbolEffect(.replace))
            }
            ShareLink(item: text) {
                Label("Share", systemImage: "square.and.arrow.up").font(.slate(12))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.inkTertiary)
        .buttonStyle(.plain)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { copied = false }
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
