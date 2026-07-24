import XCTest
import Network
@testable import SlateRemoteProtocol

/// The client can't build a `wss://` URL for a Bonjour peer without first resolving it to a
/// concrete host:port — and on a multi-homed Mac that resolution is fragile. This test proves
/// the robust alternative: connect the WebSocket+TLS-PSK NWConnection *directly* to the browsed
/// `.service` endpoint (the framework resolves it and drives the WS handshake with a "/" target).
/// If this round-trips a text frame, `RemoteClient` can drop its probe→URL dance entirely.
final class BonjourEndpointTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        let received: XCTestExpectation
        var accepted: [NWConnection] = []
        var client: NWConnection?
        init(received: XCTestExpectation) { self.received = received }
        func accept(_ conn: NWConnection) {
            accepted.append(conn); conn.start(queue: .main); receive(on: conn)
        }
        func receive(on conn: NWConnection) {
            conn.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data, String(data: data, encoding: .utf8) == "ping" { self.received.fulfill(); return }
                if error == nil { self.receive(on: conn) }
            }
        }
    }

    func testWebSocketConnectsDirectlyToBonjourServiceEndpoint() async throws {
        let psk = RemoteTransport.newPSK()
        let type = "_slatetest._tcp"          // unique type so it can't clash with a live Slate
        let name = "SlateTest-\(ProcessInfo.processInfo.processIdentifier)"
        let box = Box(received: expectation(description: "listener receives ping over the Bonjour-resolved WS"))

        // Listener: same WS+TLS-PSK stack the real server uses, advertised over Bonjour.
        let listener = try NWListener(using: RemoteTransport.parameters(psk: psk))
        listener.service = NWListener.Service(name: name, type: type)
        listener.newConnectionHandler = { conn in box.accept(conn) }
        let listening = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.start(queue: .main)
        await fulfillment(of: [listening], timeout: 5)

        // Browse for it, then connect the WS client STRAIGHT to the `.service` endpoint.
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: NWParameters())
        let connectedReady = expectation(description: "client WS reaches ready")
        let found = expectation(description: "browser found the service")
        found.assertForOverFulfill = false
        browser.browseResultsChangedHandler = { results, _ in
            guard let result = results.first(where: {
                if case let .service(n, _, _, _) = $0.endpoint { return n == name }; return false
            }) else { return }
            found.fulfill()
            guard box.client == nil else { return }
            let client = NWConnection(to: result.endpoint, using: RemoteTransport.parameters(psk: psk))
            box.client = client
            client.stateUpdateHandler = { state in
                if case .ready = state {
                    connectedReady.fulfill()
                    let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                    let ctx = NWConnection.ContentContext(identifier: "ping", metadata: [meta])
                    client.send(content: Data("ping".utf8), contentContext: ctx,
                                completion: .contentProcessed { _ in })
                }
            }
            client.start(queue: .main)
        }
        browser.start(queue: .main)

        await fulfillment(of: [found, connectedReady, box.received], timeout: 15)

        box.client?.cancel()
        browser.cancel()
        box.accepted.forEach { $0.cancel() }
        listener.cancel()
    }
}
