import Foundation
import Network
import Observation
import SlateRemoteProtocol

/// The iOS-side LAN client. Browses Bonjour for the paired Mac, opens a PSK-secured
/// WebSocket, sends prompts/stops, and streams the run's `ServerMessage`s back out through
/// callbacks the chat layer subscribes to. Uses the shared `RemoteTransport.parameters(psk:)`
/// so the TLS-PSK + WebSocket config stays byte-for-byte identical with the Mac's `NWListener`.
///
/// Connection path: browse → connect the WebSocket **straight to the browsed `.service`
/// endpoint** (Network.framework resolves it and drives the WS upgrade with a "/" target;
/// proven in `BonjourEndpointTests`). We deliberately do NOT resolve to an IP + build a
/// `wss://host:port/` URL: on a multi-homed Mac the resolved `remoteEndpoint` isn't a
/// `hostPort` at all, so that path silently never connected. It keeps trying while paired:
/// a failed attempt (e.g. before the Mac's firewall is allowed) retries every few seconds
/// without needing an app relaunch.
@MainActor @Observable
final class RemoteClient {
    enum Phase: Equatable { case idle, browsing, connecting, ready, offline(String) }
    private(set) var phase: Phase = .idle
    private(set) var models: [ModelInfo] = []
    private(set) var macName = ""
    /// Wire version the paired Mac speaks. 1 until it tells us otherwise, so an older Mac
    /// simply never sees a v2 request.
    private(set) var macProto = 1
    /// True when the Mac can serve conversation browsing, attachments and the other surfaces.
    var supportsV2: Bool { macProto >= 2 }

    /// Streaming callbacks the chat layer subscribes to.
    var onToken: (@MainActor (UUID, String) -> Void)?
    var onTool: (@MainActor (UUID, String, ToolPhase) -> Void)?
    var onDone: (@MainActor (UUID) -> Void)?
    var onConversations: (@MainActor ([ConversationSummary]) -> Void)?
    var onHistory: (@MainActor (String, [HistoryItem]) -> Void)?
    var onSpeaker: (@MainActor (UUID, String, Int) -> Void)?
    var onImage: (@MainActor (String, Data) -> Void)?
    var onError: (@MainActor (UUID, RunErrorKind, String) -> Void)?
    var onLocked: (@MainActor (UUID, String) -> Void)?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var psk: Data?
    private var lastEndpoint: NWEndpoint?
    private var wantConnected = false
    private var retryTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    // MARK: Lifecycle

    func connect(using pairing: PairingPayload) {
        disconnect()
        psk = pairing.psk; macName = pairing.name
        wantConnected = true
        startBrowsing()
    }

    /// Try again right now, instead of waiting out the backoff. This is what the status
    /// banner's button is for: a user who has just woken their Mac should not have to sit
    /// through a retry timer that started before they did anything.
    func retryNow() {
        guard wantConnected else { return }
        retryTask?.cancel(); retryTask = nil
        timeoutTask?.cancel()
        if let ep = lastEndpoint { open(to: ep) } else { startBrowsing() }
    }

    /// Tear everything down (used before re-pairing, or when leaving live mode).
    func disconnect() {
        wantConnected = false
        retryTask?.cancel(); retryTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        connection?.cancel(); connection = nil
        browser?.cancel(); browser = nil
        phase = .idle
    }

    private func startBrowsing() {
        guard wantConnected, psk != nil else { return }
        browser?.cancel()
        phase = .browsing
        let params = NWParameters()            // infrastructure Wi-Fi only (no peer-to-peer / AWDL)
        let b = NWBrowser(for: .bonjour(type: RemoteTransport.bonjourType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let result = results.first else { return }
            Task { @MainActor in self?.open(to: result.endpoint) }
        }
        b.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st { Task { @MainActor in self?.scheduleRetry(e.localizedDescription) } }
        }
        b.start(queue: .main); browser = b
    }

    // MARK: Connect

    private func open(to endpoint: NWEndpoint) {
        guard let psk, wantConnected else { return }
        if case .ready = phase { return }       // already connected — don't stack
        lastEndpoint = endpoint
        phase = .connecting
        armTimeout()
        // Connect the WebSocket + TLS-PSK straight to the browsed `.service` endpoint.
        // Network.framework resolves it (picking a reachable interface itself) and drives the
        // WS opening handshake with a "/" target — no manual IP/URL juggling, which the
        // multi-homed Mac resolved to endpoints we couldn't turn into a valid URL host.
        connection?.cancel()
        let conn = NWConnection(to: endpoint, using: RemoteTransport.parameters(psk: psk))
        connection = conn
        conn.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                switch st {
                case .ready:
                    self.timeoutTask?.cancel()
                    self.phase = .ready
                    self.receive()
                    self.send(.hello(client: "ios", proto: RemoteProtocol.version))
                case .failed(let e):
                    self.scheduleRetry(e.localizedDescription)
                case .cancelled:
                    break                        // intentional teardown; don't self-retry
                default: break
                }
            }
        }
        conn.start(queue: .main)
    }

    // MARK: Retry / timeout

    private func armTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            if case .ready = self.phase { return }
            self.scheduleRetry("timed out")
        }
    }

    private func scheduleRetry(_ reason: String) {
        guard wantConnected else { return }
        timeoutTask?.cancel()
        connection?.cancel(); connection = nil
        phase = .offline(reason)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.wantConnected else { return }
            if let ep = self.lastEndpoint { self.open(to: ep) } else { self.startBrowsing() }
        }
    }

    // MARK: Send / receive

    /// Attachments are only sent to a Mac that speaks v2; an older one would ignore the key
    /// and silently answer without them, which would look like the feature is broken.
    func prompt(id: UUID, model: String, text: String, attachments: [Attachment] = []) {
        send(.prompt(id: id, model: model, text: text,
                     attachments: supportsV2 ? attachments : []))
    }
    func stop(id: UUID) { send(.stop(id: id)) }

    /// Browsing the Mac's own conversations. Guarded on the peer's version: a v1 Mac decodes
    /// these as unknown and drops them, so the phone would wait on a reply that never comes.
    func listConversations(kind: ConversationKind?) {
        guard supportsV2 else { return }
        send(.listConversations(kind: kind))
    }
    func openConversation(id: String) {
        guard supportsV2 else { return }
        send(.openConversation(id: id))
    }
    func fetchImage(imageID: String) {
        guard supportsV2 else { return }
        send(.fetchImage(imageID: imageID))
    }

    private func send(_ msg: ClientMessage) {
        guard let conn = connection, let text = try? RemoteCodec.encode(msg) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "m", metadata: [meta])
        conn.send(content: Data(text.utf8), contentContext: ctx, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            if let data, let text = String(data: data, encoding: .utf8),
               let msg = try? RemoteCodec.decodeServer(text) {
                Task { @MainActor in self?.dispatch(msg) }
            }
            if error == nil { Task { @MainActor in self?.receive() } }
        }
    }

    private func dispatch(_ msg: ServerMessage) {
        switch msg {
        case let .models(items, mac, proto):
            models = items; macName = mac
            // Absent on a v1 Mac. The UI uses this to hide anything the peer cannot serve.
            macProto = proto ?? 1
        case let .token(id, s): onToken?(id, s)
        case let .tool(id, name, phase): onTool?(id, name, phase)
        case let .done(id): onDone?(id)
        case let .error(id, kind, m): onError?(id, kind, m)
        case let .locked(id, feature): onLocked?(id, feature)
        // v2 surfaces. Wired up as each screen lands; ignoring them keeps the client
        // forward compatible with a newer Mac instead of dropping the connection.
        case let .conversations(items): onConversations?(items)
        case let .history(id, items): onHistory?(id, items)
        case let .speaker(id, name, index): onSpeaker?(id, name, index)
        case let .image(imageID, data): onImage?(imageID, data)
        }
    }
}
