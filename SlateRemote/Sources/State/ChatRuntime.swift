import Foundation
import SlateRemoteProtocol

/// Sending a turn and receiving the answer.
///
/// This used to live inside ChatView, which owned a *copy* of the conversation and rebound the
/// client's callbacks every time it appeared. Two things followed from that: the copy had to be
/// written back by hand on disappear, and leaving a chat mid-answer had to abort the run,
/// because the next view's callbacks would have swallowed the tokens. With the drawer shell —
/// where opening the menu or glancing at another surface tears the view down — that would mean
/// losing an answer for looking away. Runs belong to the app, so they outlive any view.
extension AppState {

    /// Bind the streaming callbacks once, at construction. They address a run by its message id
    /// and search the conversation list for it, so no view identity is involved.
    func wireRuns() {
        client.onToken = { [weak self] id, s in
            guard let self, let at = self.locate(id) else { return }
            if self.conversations[at.c].messages[at.m].tool != nil {
                self.conversations[at.c].messages[at.m].tool = nil
            }
            self.conversations[at.c].messages[at.m].text += s
        }
        client.onTool = { [weak self] id, name, phase in
            guard let self, let at = self.locate(id) else { return }
            self.conversations[at.c].messages[at.m].tool = phase == .start ? AppState.toolLabel(name) : nil
        }
        client.onDone = { [weak self] id in
            self?.finish(id, dropIfEmpty: false)
        }
        client.onError = { [weak self] id, kind, msg in
            guard let self, let convo = self.finish(id, dropIfEmpty: true) else { return }
            self.runError[convo] = AppState.errorText(kind, msg)
        }
        client.onLocked = { [weak self] id, feature in
            guard let self, let convo = self.finish(id, dropIfEmpty: true) else { return }
            self.proNudge[convo] = "\(feature.capitalized) is a Slate Pro feature."
        }
    }

    /// Where a run's message lives right now. Returns nil once the user has deleted the chat
    /// out from under an in-flight run, which is the one case where dropping tokens is correct.
    private func locate(_ messageID: UUID) -> (c: Int, m: Int)? {
        for (c, convo) in conversations.enumerated() {
            if let m = convo.messages.firstIndex(where: { $0.id == messageID }) { return (c, m) }
        }
        return nil
    }

    /// Close out a run: stop its spinner, optionally drop a bubble that never got any text,
    /// and title an untitled chat from its opening line. Returns the conversation it belonged to.
    @discardableResult
    private func finish(_ messageID: UUID, dropIfEmpty: Bool) -> Conversation.ID? {
        guard let at = locate(messageID) else { return nil }
        let convoID = conversations[at.c].id
        conversations[at.c].messages[at.m].streaming = false
        conversations[at.c].messages[at.m].tool = nil
        if dropIfEmpty, conversations[at.c].messages[at.m].text.isEmpty {
            conversations[at.c].messages.remove(at: at.m)
        }
        activeRun[convoID] = nil
        retitleIfNeeded(at.c)
        return convoID
    }

    /// A chat is named after the user's opening line, once, when the first answer lands.
    private func retitleIfNeeded(_ c: Int) {
        guard conversations[c].title == Conversation.untitled,
              let opener = conversations[c].messages.first(where: { $0.role == .user })?.text,
              !opener.isEmpty else { return }
        conversations[c].title = String(opener.prefix(48))
        conversations[c].subtitle = Reasoning.answer(
            conversations[c].messages.last(where: { $0.role == .assistant })?.text ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sending

    /// Post the user's turn and start the answer. An attachment on its own is a valid turn:
    /// "what is this?" is implied by the photo.
    func send(_ text: String, attachments: [Attachment], in convoID: Conversation.ID, shownAs: String) {
        guard let c = conversations.firstIndex(where: { $0.id == convoID }) else { return }
        runError[convoID] = nil
        proNudge[convoID] = nil
        conversations[c].messages.append(.init(role: .user, text: shownAs))
        startRun(text, attachments: attachments, in: convoID)
    }

    /// Re-run the last user turn after a failure. Attachments are not resent: they were
    /// consumed by the first attempt and the composer no longer holds them.
    func retry(in convoID: Conversation.ID) {
        guard let c = conversations.firstIndex(where: { $0.id == convoID }),
              let text = conversations[c].messages.last(where: { $0.role == .user })?.text else { return }
        runError[convoID] = nil
        startRun(text, attachments: [], in: convoID)
    }

    private func startRun(_ text: String, attachments: [Attachment], in convoID: Conversation.ID) {
        guard let c = conversations.firstIndex(where: { $0.id == convoID }) else { return }
        let assistant = ChatMessage(role: .assistant, text: "", streaming: true)
        conversations[c].messages.append(assistant)
        activeRun[convoID] = assistant.id

        let live = !isDemo && client.phase == .ready
        if live, let ref = conversations[c].modelRef ?? client.models.first?.ref {
            client.prompt(id: assistant.id, model: ref, text: text, attachments: attachments)
        } else if live {
            // Connected, but the Mac has no models installed. Saying so beats a bubble that
            // never fills in.
            finish(assistant.id, dropIfEmpty: true)
            runError[convoID] = "Your Mac has no models installed yet. Add one in Slate's Model Manager."
        } else {
            runMock(into: assistant.id, convoID: convoID, prompt: text)
        }
    }

    func stopRun(in convoID: Conversation.ID) {
        guard let id = activeRun[convoID] else { return }
        if !isDemo { client.stop(id: id) }
        mockRuns[convoID]?.cancel(); mockRuns[convoID] = nil
        finish(id, dropIfEmpty: true)
    }

    // MARK: - Demo mock
    //
    // Only ever reached before a Mac is paired, so the concept build stays reviewable in the
    // Simulator. A live app never takes this path.

    private func runMock(into messageID: UUID, convoID: Conversation.ID, prompt: String) {
        guard let c = conversations.firstIndex(where: { $0.id == convoID }) else { return }
        let label = conversations[c].modelLabel
        // Shaped like a real answer — a heading, a list, some emphasis — because a model's
        // output almost always is, and a flat paragraph would let a markdown regression sit
        // unnoticed through every review of the concept build.
        let reply = """
        ### \(prompt.prefix(48))

        Running **\(label)** on your Mac. Nothing left this device.

        - The prompt never touches a server
        - The answer streams straight back over Wi-Fi
        - Your Mac does the work, the phone just asks

        1. Pair once with the code on your Mac
        2. Ask from anywhere on the same network
        """
        mockRuns[convoID] = Task { [weak self] in
            for word in reply.split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(45))
                guard let self, !Task.isCancelled, let at = self.locate(messageID) else { return }
                let existing = self.conversations[at.c].messages[at.m].text
                self.conversations[at.c].messages[at.m].text = existing.isEmpty ? String(word) : existing + " " + word
            }
            guard let self, !Task.isCancelled else { return }
            self.finish(messageID, dropIfEmpty: false)
            self.mockRuns[convoID] = nil
        }
    }

    // MARK: - Copy

    static func toolLabel(_ name: String) -> String {
        switch name {
        case "web_search", "web", "search": return "Searching the web…"
        default: return "Using \(name.replacingOccurrences(of: "_", with: " "))…"
        }
    }

    static func errorText(_ kind: RunErrorKind, _ msg: String) -> String {
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
}
