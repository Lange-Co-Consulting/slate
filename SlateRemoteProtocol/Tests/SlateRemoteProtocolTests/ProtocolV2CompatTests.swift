import Foundation
import Testing
@testable import SlateRemoteProtocol

/// v2 must interoperate with a v1 peer in BOTH directions, so these tests pin the exact v1 wire
/// shapes rather than round-tripping v2 against itself.
@Suite("Protocol v2 stays compatible with v1 peers")
struct ProtocolV2CompatTests {

    // MARK: old iPhone -> new Mac

    @Test("A v1 prompt from an old phone still decodes")
    func decodesV1Prompt() throws {
        let id = UUID()
        let v1 = #"{"t":"prompt","id":"\#(id.uuidString)","model":"m.gguf","text":"hi"}"#
        let msg = try RemoteCodec.decodeClient(v1)
        guard case let .prompt(gotID, model, text, attachments, conversation, kind) = msg else {
            Issue.record("wrong case"); return
        }
        #expect(gotID == id)
        #expect(model == "m.gguf")
        #expect(text == "hi")
        #expect(attachments.isEmpty)
        #expect(conversation == nil)
        #expect(kind == .chat)          // absent key must default, not fail
    }

    @Test("A v1 hello still decodes")
    func decodesV1Hello() throws {
        let msg = try RemoteCodec.decodeClient(#"{"t":"hello","client":"iPhone","proto":1}"#)
        guard case let .hello(client, proto) = msg else { Issue.record("wrong case"); return }
        #expect(client == "iPhone")
        #expect(proto == 1)
    }

    // MARK: new iPhone -> old Mac

    @Test("A plain chat prompt is byte-identical to v1 on the wire")
    func plainPromptEmitsNoV2Keys() throws {
        let id = UUID()
        let json = try RemoteCodec.encode(ClientMessage.prompt(id: id, model: "m.gguf", text: "hi"))
        // An old Mac must not see keys it cannot interpret.
        #expect(json.contains("\"attachments\"") == false)
        #expect(json.contains("\"conversation\"") == false)
        #expect(json.contains("\"kind\"") == false)
        #expect(json.contains("\"t\":\"prompt\""))
    }

    @Test("Attachments and kind appear only when actually used")
    func v2KeysAppearWhenSet() throws {
        let a = Attachment(kind: .image, name: "shot.png", mime: "image/png", data: Data([1, 2, 3]))
        let json = try RemoteCodec.encode(
            ClientMessage.prompt(id: UUID(), model: "m", text: "look", attachments: [a],
                                 conversation: "conv-1", kind: .roundtable))
        #expect(json.contains("\"attachments\""))
        #expect(json.contains("\"conversation\""))
        #expect(json.contains("\"kind\":\"roundtable\""))
    }

    // MARK: peer-version detection

    @Test("A v1 Mac's models reply has no proto, which is how the phone spots an old peer")
    func v1ModelsHasNoProto() throws {
        let v1 = #"{"t":"models","items":[],"mac":"MBP"}"#
        let msg = try RemoteCodec.decodeServer(v1)
        guard case let .models(_, mac, proto) = msg else { Issue.record("wrong case"); return }
        #expect(mac == "MBP")
        #expect(proto == nil)           // nil => treat the Mac as v1
    }

    @Test("A v2 Mac announces its version")
    func v2ModelsCarriesProto() throws {
        let json = try RemoteCodec.encode(ServerMessage.models(items: [], mac: "MBP", proto: 2))
        let back = try RemoteCodec.decodeServer(json)
        guard case let .models(_, _, proto) = back else { Issue.record("wrong case"); return }
        #expect(proto == 2)
    }

    // MARK: v2 payloads

    @Test("Conversation summaries round-trip, dates included")
    func conversationsRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let item = ConversationSummary(id: "c1", kind: .roundtable, title: "Rate limiter",
                                       subtitle: "3 seats", model: "Qwen3 30B", updatedAt: now)
        let back = try RemoteCodec.decodeServer(RemoteCodec.encode(ServerMessage.conversations(items: [item])))
        guard case let .conversations(items) = back else { Issue.record("wrong case"); return }
        #expect(items.first?.id == "c1")
        #expect(items.first?.kind == .roundtable)
        #expect(items.first?.updatedAt == now)
    }

    @Test("An unknown future kind degrades to chat instead of failing the whole message")
    func unknownKindDegrades() throws {
        let json = #"{"t":"conversations","items":[{"id":"c9","kind":"hologram","title":"T","updatedAt":"2026-05-28T00:00:00Z"}]}"#
        let back = try RemoteCodec.decodeServer(json)
        guard case let .conversations(items) = back else { Issue.record("wrong case"); return }
        #expect(items.first?.kind == .chat)
    }

    @Test("Roundtable speaker attribution round-trips")
    func speakerRoundTrip() throws {
        let id = UUID()
        let back = try RemoteCodec.decodeServer(
            RemoteCodec.encode(ServerMessage.speaker(id: id, name: "Qwen3 · the skeptic", index: 1)))
        guard case let .speaker(gotID, name, index) = back else { Issue.record("wrong case"); return }
        #expect(gotID == id)
        #expect(name == "Qwen3 · the skeptic")
        #expect(index == 1)
    }

    @Test("Image payloads survive the JSON round-trip")
    func imageRoundTrip() throws {
        let bytes = Data((0..<64).map { UInt8($0) })
        let back = try RemoteCodec.decodeServer(
            RemoteCodec.encode(ServerMessage.image(imageID: "img-1", data: bytes)))
        guard case let .image(imageID, data) = back else { Issue.record("wrong case"); return }
        #expect(imageID == "img-1")
        #expect(data == bytes)
    }
}

/// The pairing code is the one thing a user types or pastes by hand, so it is the one place a
/// typo, a truncated paste or a foreign QR can enter the system. It used to be decoded and then
/// trusted: any base64 JSON with the right field names became a pairing attempt.
@Suite("Pairing codes are validated, not merely decoded")
struct PairingPayloadGuardTests {

    @Test("A real code round-trips")
    func realCodeRoundTrips() {
        let payload = PairingPayload(name: "A Mac", psk: RemoteTransport.newPSK())
        let parsed = PairingPayload(code: payload.encodedCode())
        #expect(parsed?.name == "A Mac")
        #expect(parsed?.psk.count == RemoteTransport.pskBytes)
    }

    @Test("A truncated key is rejected here, not later inside TLS")
    func shortKeyRejected() {
        let short = PairingPayload(name: "A Mac", psk: Data(repeating: 1, count: 8))
        #expect(PairingPayload(code: short.encodedCode()) == nil)
    }

    @Test("Base64 that happens to decode is still not a pairing code")
    func foreignJSONRejected() {
        let junk = Data(#"{"v":0,"name":"","psk":""}"#.utf8).base64EncodedString()
        #expect(PairingPayload(code: junk) == nil)
    }

    @Test("The generated key is exactly the length the transport needs")
    func generatedKeyMatchesTransport() {
        #expect(RemoteTransport.newPSK().count == RemoteTransport.pskBytes)
    }
}
