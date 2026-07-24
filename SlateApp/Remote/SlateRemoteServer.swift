import Foundation
import Network
import Observation
import SlateCore
import SlateRemoteProtocol

/// The Mac-side LAN server. Advertises Bonjour, accepts PSK-secured WebSocket connections,
/// answers hello→models, and streams a run's AgentEvents as ServerMessages. Free feature;
/// per-prompt Pro gating uses the app's existing capability seam.
///
/// `@Observable` so the Settings pane's status dot/label track `isRunning` — without it the
/// listener flipping to ready never re-renders the view and the pane reads "Starting…" forever.
@MainActor @Observable
final class SlateRemoteServer {
    private unowned let model: AppModel
    private let runner: RemoteRunner
    private var listener: NWListener?
    private(set) var isRunning = false
    private var psk: Data
    private let macName = Host.current().localizedName ?? "This Mac"
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var runTasks: [UUID: Task<Void, Never>] = [:]

    init(model: AppModel, psk: Data) { self.model = model; self.psk = psk; self.runner = RemoteRunner(model: model) }

    var pairingPayload: PairingPayload { PairingPayload(name: macName, psk: psk) }

    func start() throws {
        guard listener == nil else { return }
        let l = try NWListener(using: RemoteTransport.parameters(psk: psk))
        l.service = NWListener.Service(name: macName, type: RemoteTransport.bonjourType)
        l.newConnectionHandler = { [weak self] conn in Task { @MainActor in self?.accept(conn) } }
        l.stateUpdateHandler = { [weak self] st in Task { @MainActor in if case .ready = st { self?.isRunning = true } } }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        runTasks.values.forEach { $0.cancel() }; runTasks.removeAll()
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        listener?.cancel(); listener = nil; isRunning = false
    }

    /// Revoke: rotate the PSK. Existing peers can no longer complete the handshake.
    func rotatePSK() { psk = RemoteTransport.newPSK(); stop(); try? start() }

    private func accept(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = conn
        conn.stateUpdateHandler = { [weak self] st in
            if case .failed = st { Task { @MainActor in self?.drop(conn) } }
            if case .cancelled = st { Task { @MainActor in self?.drop(conn) } }
        }
        conn.start(queue: .main)
        receive(on: conn)
    }

    private func drop(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = nil
        peerProto[ObjectIdentifier(conn)] = nil
    }

    /// Wire version each connected phone announced in its `hello`.
    private var peerProto: [ObjectIdentifier: Int] = [:]

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                Task { @MainActor in self.handle(text, on: conn) }
            }
            if error == nil { Task { @MainActor in self.receive(on: conn) } }
        }
    }

    private func send(_ msg: ServerMessage, on conn: NWConnection) {
        guard let text = try? RemoteCodec.encode(msg) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        conn.send(content: Data(text.utf8), contentContext: ctx, completion: .contentProcessed { _ in })
    }

    private func handle(_ text: String, on conn: NWConnection) {
        guard let msg = try? RemoteCodec.decodeClient(text) else { return }
        switch msg {
        case let .hello(_, clientProto):
            // Remember the peer's version: v2 messages are only ever sent to a v2 client.
            peerProto[ObjectIdentifier(conn)] = clientProto
            // Prettify here, not on the phone. `InstalledModel.name` is `url.lastPathComponent`,
            // so the catalog would otherwise reach the phone as raw filenames — the model menu
            // read "Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf". The phone has no ModelName helper,
            // and the Mac already prettifies conversation model labels the same way.
            let items = model.availableModelOptions.map {
                ModelInfo(ref: $0.ref,
                          label: $0.isLocal ? SidebarView.pretty($0.label) : $0.label,
                          isLocal: $0.isLocal)
            }
            send(.models(items: items, mac: macName, proto: RemoteProtocol.version), on: conn)
        case let .prompt(id, modelRef, promptText, attachments, _, _):
            startRun(id: id, modelRef: modelRef, text: promptText, attachments: attachments, on: conn)
        case let .stop(id):
            runTasks[id]?.cancel(); runTasks[id] = nil
        case let .listConversations(kind):
            send(.conversations(items: summaries(kind: kind)), on: conn)
        case let .openConversation(id):
            guard let uuid = UUID(uuidString: id),
                  let convo = model.conversations.first(where: { $0.id == uuid }) else {
                send(.history(id: id, items: []), on: conn); return
            }
            send(.history(id: id, items: history(of: convo)), on: conn)
        case let .fetchImage(imageID):
            guard let data = imageData(for: imageID) else { return }
            send(.image(imageID: imageID, data: data), on: conn)
        }
    }

    private func startRun(id: UUID, modelRef: String, text: String,
                          attachments: [Attachment] = [], on conn: NWConnection) {
        // Gate: plain local chat is free; only escalate if a Pro-only path is requested.
        // (Text chat needs no capability; extend here when image/voice/automations arrive.)
        runTasks[id] = Task { @MainActor in
            await runner.run(id: id, modelRef: modelRef, text: text, attachments: attachments) { [weak self] ev in
                self?.forward(ev, id: id, on: conn)
            }
            self.runTasks[id] = nil
        }
    }

    private func forward(_ ev: AgentEvent, id: UUID, on conn: NWConnection) {
        switch ev {
        case let .token(s):            send(.token(id: id, s: s), on: conn)
        case let .toolCall(name, _):   send(.tool(id: id, name: name, phase: .start), on: conn)
        case let .toolResult(name, _): send(.tool(id: id, name: name, phase: .end), on: conn)
        case let .finalAnswer(s):
            if !s.isEmpty { send(.token(id: id, s: s), on: conn) }
            send(.done(id: id), on: conn)
        case let .failed(m):
            let kind: RunErrorKind = m.lowercased().contains("busy") ? .busy
                : (m.lowercased().contains("memory") || m.lowercased().contains("ram")) ? .oom : .model
            send(.error(id: id, kind: kind, msg: m), on: conn)
        }
    }

    // MARK: - v2: browsing the Mac's conversations

    /// The Mac's own kinds do not match the wire enum one-for-one: `agents` is the roundtable.
    private func wireKind(_ k: Conversation.Kind) -> ConversationKind {
        switch k {
        case .chat: .chat
        case .code: .code
        case .image: .image
        case .agents: .roundtable
        }
    }

    /// Newest first, optionally narrowed to one kind. Titles and model labels are prettified
    /// HERE: the phone has no access to ModelName and should never render a raw GGUF filename.
    private func summaries(kind: ConversationKind?) -> [ConversationSummary] {
        model.conversations
            .filter { kind == nil || wireKind($0.kind) == kind }
            .sorted { ($0.messages.last?.id.uuidString ?? "") > ($1.messages.last?.id.uuidString ?? "") }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(200)
            .map { c in
                let last = c.messages.last(where: { $0.role == .assistant || $0.role == .user })
                let preview = last?.content
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(140)
                let label = c.pinnedModel.map { SidebarView.pretty(URL(fileURLWithPath: $0).lastPathComponent) }
                return ConversationSummary(
                    id: c.id.uuidString,
                    kind: wireKind(c.kind),
                    title: c.title,
                    subtitle: c.kind == .code ? (c.folderPath as String?) ?? preview.map(String.init)
                                              : preview.map(String.init),
                    model: label,
                    updatedAt: c.createdAt)
            }
    }

    /// System and tool turns stay on the Mac: the phone shows a conversation, not a transcript
    /// of the machinery. Reasoning is left in place and stripped by the phone at render time.
    private func history(of c: Conversation) -> [HistoryItem] {
        c.messages
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(300)
            .map { m in
                HistoryItem(role: m.role == .user ? "user" : "assistant",
                            text: m.content,
                            speaker: m.speaker,
                            imageID: m.imagePath == nil ? nil : m.id.uuidString)
            }
    }

    /// Images are addressed by their MESSAGE id, never by path, so the wire never carries the
    /// Mac's filesystem layout and the phone cannot ask for an arbitrary file.
    private func imageData(for imageID: String) -> Data? {
        guard let uuid = UUID(uuidString: imageID) else { return nil }
        for convo in model.conversations {
            guard let m = convo.messages.first(where: { $0.id == uuid }), let path = m.imagePath else { continue }
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        return nil
    }

}
