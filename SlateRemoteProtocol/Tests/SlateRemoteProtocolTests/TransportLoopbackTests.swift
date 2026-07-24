import XCTest
import Network
@testable import SlateRemoteProtocol

/// Proves the TLS-PSK + WebSocket stack works: an NWListener and an NWConnection built from
/// the SAME `RemoteTransport.parameters(psk:)` complete the handshake and exchange one WS text
/// frame. If this fails at the handshake, the ciphersuite/version in RemoteTransport is wrong.
///
/// NOTE on the client endpoint: a WebSocket NWConnection must be created toward a `wss://` URL
/// endpoint, not a bare `hostPort`. With `hostPort` the client never emits the WS opening
/// handshake and the peer aborts the connection (POSIX 53) — this reproduces even without TLS,
/// so it is purely the WebSocket layer, not the PSK config. The listener still binds by port.
final class TransportLoopbackTests: XCTestCase {
    /// Holds mutable networking state touched from Network's `@Sendable` callbacks. Every
    /// callback here runs on the serial `.main` queue, so the access is race-free in practice;
    /// `@unchecked Sendable` tells the Swift 6 compiler we vouch for that.
    private final class Endpoint: @unchecked Sendable {
        let received: XCTestExpectation
        var accepted: [NWConnection] = []
        var port: NWEndpoint.Port?
        init(received: XCTestExpectation) { self.received = received }

        func accept(_ conn: NWConnection) {
            accepted.append(conn)
            conn.start(queue: .main)
            receive(on: conn)
        }

        func receive(on conn: NWConnection) {
            conn.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data, String(data: data, encoding: .utf8) == "ping" {
                    self.received.fulfill()
                    return
                }
                if error == nil { self.receive(on: conn) }
            }
        }
    }

    func testPSKWebSocketTextFrameRoundTrips() async throws {
        let psk = RemoteTransport.newPSK()
        let box = Endpoint(received: expectation(description: "listener receives the ping text frame"))

        let listener = try NWListener(using: RemoteTransport.parameters(psk: psk))
        listener.newConnectionHandler = { conn in box.accept(conn) }

        // Await the listener's assigned port before connecting.
        let portReady = expectation(description: "listener ready with a port")
        listener.stateUpdateHandler = { state in
            if case .ready = state, let p = listener.port {
                box.port = p
                portReady.fulfill()
            }
        }
        listener.start(queue: .main)
        await fulfillment(of: [portReady], timeout: 5)
        let port = try XCTUnwrap(box.port)

        // WebSocket clients must connect to a URL endpoint so the framework drives the WS
        // opening handshake; `wss://` selects TLS, whose options come from the same params.
        let url = try XCTUnwrap(URL(string: "wss://127.0.0.1:\(port.rawValue)/"))
        let client = NWConnection(to: .url(url), using: RemoteTransport.parameters(psk: psk))
        client.stateUpdateHandler = { state in
            if case .ready = state {
                let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                let ctx = NWConnection.ContentContext(identifier: "ping", metadata: [meta])
                client.send(content: Data("ping".utf8), contentContext: ctx,
                            completion: .contentProcessed { _ in })
            }
        }
        client.start(queue: .main)

        await fulfillment(of: [box.received], timeout: 5)

        client.cancel()
        box.accepted.forEach { $0.cancel() }
        listener.cancel()
    }
}
