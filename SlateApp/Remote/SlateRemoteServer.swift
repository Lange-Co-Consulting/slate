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

    private func drop(_ conn: NWConnection) { connections[ObjectIdentifier(conn)] = nil }

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
        case .hello:
            let items = model.availableModelOptions.map { ModelInfo(ref: $0.ref, label: $0.label, isLocal: $0.isLocal) }
            send(.models(items: items, mac: macName), on: conn)
        case let .prompt(id, modelRef, promptText):
            startRun(id: id, modelRef: modelRef, text: promptText, on: conn)
        case let .stop(id):
            runTasks[id]?.cancel(); runTasks[id] = nil
        }
    }

    private func startRun(id: UUID, modelRef: String, text: String, on conn: NWConnection) {
        // Gate: plain local chat is free; only escalate if a Pro-only path is requested.
        // (Text chat needs no capability; extend here when image/voice/automations arrive.)
        runTasks[id] = Task { @MainActor in
            await runner.run(id: id, modelRef: modelRef, text: text) { [weak self] ev in
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
}
