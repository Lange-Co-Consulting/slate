import XCTest
@testable import SlateRemoteProtocol

final class MessagesTests: XCTestCase {
    func testClientPromptRoundTrips() throws {
        let id = UUID()
        let msg = ClientMessage.prompt(id: id, model: "/m.gguf", text: "hi")
        let wire = try RemoteCodec.encode(msg)
        XCTAssertTrue(wire.contains("\"t\":\"prompt\""))
        XCTAssertEqual(try RemoteCodec.decodeClient(wire), msg)
    }

    func testServerCasesRoundTrip() throws {
        let id = UUID()
        let cases: [ServerMessage] = [
            .models(items: [ModelInfo(ref: "r", label: "L", isLocal: true)], mac: "Mac"),
            .token(id: id, s: "x"),
            .tool(id: id, name: "web_search", phase: .start),
            .done(id: id),
            .error(id: id, kind: .oom, msg: "no ram"),
            .locked(id: id, feature: "image"),
        ]
        for m in cases {
            XCTAssertEqual(try RemoteCodec.decodeServer(RemoteCodec.encode(m)), m)
        }
    }

    func testPairingPayloadRoundTrips() throws {
        let p = PairingPayload(name: "LUCC's MacBook Pro", psk: Data((0..<32).map { UInt8($0) }))
        let code = p.encodedCode()
        XCTAssertEqual(PairingPayload(code: code), p)
    }
}
