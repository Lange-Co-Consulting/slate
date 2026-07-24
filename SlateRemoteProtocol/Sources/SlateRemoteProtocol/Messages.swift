import Foundation

/// Wire protocol version.
///
/// v1 — chat only: hello / prompt / stop, tokens streaming back.
/// v2 — every conversation kind the Mac has (chat, code, image, roundtable, automations),
///      history browsing, prompt attachments, roundtable speaker attribution, generated images.
///
/// COMPATIBILITY, both directions:
/// • New iPhone ↔ old Mac: the old Mac's `models` reply carries no `proto`, so the client treats
///   the peer as v1 and hides everything v2. It never sends a v2 message to a v1 Mac.
/// • Old iPhone ↔ new Mac: every v1 message keeps its exact v1 shape, and the extra keys the new
///   Mac adds are ignored by the old decoder. The Mac sends v2 messages only to a client whose
///   `hello` announced proto >= 2.
public enum RemoteProtocol {
    public static let version = 2
    /// The lowest version this build can still talk to.
    public static let minimumSupported = 1
}

public struct ModelInfo: Codable, Equatable, Sendable {
    public let ref: String; public let label: String; public let isLocal: Bool
    public init(ref: String, label: String, isLocal: Bool) {
        self.ref = ref; self.label = label; self.isLocal = isLocal
    }
}

public enum ToolPhase: String, Codable, Sendable { case start, end }
public enum RunErrorKind: String, Codable, Sendable {
    case busy, oom, model, internalError = "internal"
}

// MARK: - v2 types

/// The kinds of conversation the Mac app keeps. Mirrors `Conversation.Kind` on the Mac; kept as a
/// plain string enum so an unknown future kind decodes as `.chat` rather than failing the message.
public enum ConversationKind: String, Codable, Hashable, Sendable, CaseIterable {
    case chat, code, image, roundtable, automation

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConversationKind(rawValue: raw) ?? .chat
    }
}

/// One row in the phone's conversation list.
public struct ConversationSummary: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let kind: ConversationKind
    public let title: String
    /// Last message preview, project folder, or seat list depending on kind.
    public let subtitle: String?
    /// Display label, already prettified by the Mac (the phone has no ModelName helper).
    public let model: String?
    public let updatedAt: Date

    public init(id: String, kind: ConversationKind, title: String,
                subtitle: String? = nil, model: String? = nil, updatedAt: Date) {
        self.id = id; self.kind = kind; self.title = title
        self.subtitle = subtitle; self.model = model; self.updatedAt = updatedAt
    }
}

/// A single message when the phone opens a conversation.
public struct HistoryItem: Codable, Equatable, Sendable {
    public let role: String            // "user" | "assistant"
    public let text: String
    /// Roundtable seat name, so the phone can attribute a line without guessing.
    public let speaker: String?
    /// Identifier for a generated image the phone can request.
    public let imageID: String?

    public init(role: String, text: String, speaker: String? = nil, imageID: String? = nil) {
        self.role = role; self.text = text; self.speaker = speaker; self.imageID = imageID
    }
}

/// Something the user attached to a prompt. Sent inline; the transport is a local-network
/// WebSocket, so a photo or a text file is fine, but the Mac still enforces its own size limit.
public struct Attachment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, file }
    public let kind: Kind
    public let name: String
    public let mime: String
    public let data: Data

    public init(kind: Kind, name: String, mime: String, data: Data) {
        self.kind = kind; self.name = name; self.mime = mime; self.data = data
    }
}

// MARK: - Client → server

public enum ClientMessage: Codable, Equatable, Sendable {
    case hello(client: String, proto: Int)
    /// v1 shape plus optional v2 fields. An old Mac decodes id/model/text and ignores the rest.
    case prompt(id: UUID, model: String, text: String,
                attachments: [Attachment] = [], conversation: String? = nil,
                kind: ConversationKind = .chat)
    case stop(id: UUID)
    // v2
    case listConversations(kind: ConversationKind?)
    case openConversation(id: String)
    case fetchImage(imageID: String)

    private enum K: String, CodingKey {
        case t, client, proto, id, model, text, attachments, conversation, kind, imageID
    }
    private enum Tag: String, Codable { case hello, prompt, stop, listConversations, openConversation, fetchImage }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .hello:
            self = .hello(client: try c.decode(String.self, forKey: .client),
                          proto: try c.decode(Int.self, forKey: .proto))
        case .prompt:
            self = .prompt(id: try c.decode(UUID.self, forKey: .id),
                           model: try c.decode(String.self, forKey: .model),
                           text: try c.decode(String.self, forKey: .text),
                           attachments: try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? [],
                           conversation: try c.decodeIfPresent(String.self, forKey: .conversation),
                           kind: try c.decodeIfPresent(ConversationKind.self, forKey: .kind) ?? .chat)
        case .stop:
            self = .stop(id: try c.decode(UUID.self, forKey: .id))
        case .listConversations:
            self = .listConversations(kind: try c.decodeIfPresent(ConversationKind.self, forKey: .kind))
        case .openConversation:
            self = .openConversation(id: try c.decode(String.self, forKey: .id))
        case .fetchImage:
            self = .fetchImage(imageID: try c.decode(String.self, forKey: .imageID))
        }
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        switch self {
        case let .hello(client, proto):
            try c.encode(Tag.hello, forKey: .t)
            try c.encode(client, forKey: .client); try c.encode(proto, forKey: .proto)
        case let .prompt(id, model, text, attachments, conversation, kind):
            try c.encode(Tag.prompt, forKey: .t)
            try c.encode(id, forKey: .id); try c.encode(model, forKey: .model); try c.encode(text, forKey: .text)
            // Only emit the v2 keys when they carry something, so a plain chat prompt stays
            // byte-identical to v1 on the wire.
            if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
            if let conversation { try c.encode(conversation, forKey: .conversation) }
            if kind != .chat { try c.encode(kind, forKey: .kind) }
        case let .stop(id):
            try c.encode(Tag.stop, forKey: .t); try c.encode(id, forKey: .id)
        case let .listConversations(kind):
            try c.encode(Tag.listConversations, forKey: .t)
            try c.encodeIfPresent(kind, forKey: .kind)
        case let .openConversation(id):
            try c.encode(Tag.openConversation, forKey: .t); try c.encode(id, forKey: .id)
        case let .fetchImage(imageID):
            try c.encode(Tag.fetchImage, forKey: .t); try c.encode(imageID, forKey: .imageID)
        }
    }
}

// MARK: - Server → client

public enum ServerMessage: Codable, Equatable, Sendable {
    /// `proto` is absent from a v1 Mac; that absence is how the phone detects an old peer.
    case models(items: [ModelInfo], mac: String, proto: Int? = nil)
    case token(id: UUID, s: String)
    case tool(id: UUID, name: String, phase: ToolPhase)
    case done(id: UUID)
    case error(id: UUID, kind: RunErrorKind, msg: String)
    case locked(id: UUID, feature: String)
    // v2
    case conversations(items: [ConversationSummary])
    case history(id: String, items: [HistoryItem])
    /// The seat now speaking in a roundtable run.
    case speaker(id: UUID, name: String, index: Int)
    /// A generated image, answered for `fetchImage` or pushed when a run produces one.
    case image(imageID: String, data: Data)

    private enum K: String, CodingKey {
        case t, items, mac, proto, id, s, name, phase, kind, msg, feature, index, imageID, data
    }
    private enum Tag: String, Codable {
        case models, token, tool, done, error, locked, conversations, history, speaker, image
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .models:
            self = .models(items: try c.decode([ModelInfo].self, forKey: .items),
                           mac: try c.decode(String.self, forKey: .mac),
                           proto: try c.decodeIfPresent(Int.self, forKey: .proto))
        case .token:
            self = .token(id: try c.decode(UUID.self, forKey: .id), s: try c.decode(String.self, forKey: .s))
        case .tool:
            self = .tool(id: try c.decode(UUID.self, forKey: .id),
                         name: try c.decode(String.self, forKey: .name),
                         phase: try c.decode(ToolPhase.self, forKey: .phase))
        case .done:
            self = .done(id: try c.decode(UUID.self, forKey: .id))
        case .error:
            self = .error(id: try c.decode(UUID.self, forKey: .id),
                          kind: try c.decode(RunErrorKind.self, forKey: .kind),
                          msg: try c.decode(String.self, forKey: .msg))
        case .locked:
            self = .locked(id: try c.decode(UUID.self, forKey: .id),
                           feature: try c.decode(String.self, forKey: .feature))
        case .conversations:
            self = .conversations(items: try c.decode([ConversationSummary].self, forKey: .items))
        case .history:
            self = .history(id: try c.decode(String.self, forKey: .id),
                            items: try c.decode([HistoryItem].self, forKey: .items))
        case .speaker:
            self = .speaker(id: try c.decode(UUID.self, forKey: .id),
                            name: try c.decode(String.self, forKey: .name),
                            index: try c.decode(Int.self, forKey: .index))
        case .image:
            self = .image(imageID: try c.decode(String.self, forKey: .imageID),
                          data: try c.decode(Data.self, forKey: .data))
        }
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        switch self {
        case let .models(items, mac, proto):
            try c.encode(Tag.models, forKey: .t)
            try c.encode(items, forKey: .items); try c.encode(mac, forKey: .mac)
            try c.encodeIfPresent(proto, forKey: .proto)
        case let .token(id, s):
            try c.encode(Tag.token, forKey: .t); try c.encode(id, forKey: .id); try c.encode(s, forKey: .s)
        case let .tool(id, name, phase):
            try c.encode(Tag.tool, forKey: .t); try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name); try c.encode(phase, forKey: .phase)
        case let .done(id):
            try c.encode(Tag.done, forKey: .t); try c.encode(id, forKey: .id)
        case let .error(id, kind, msg):
            try c.encode(Tag.error, forKey: .t); try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind); try c.encode(msg, forKey: .msg)
        case let .locked(id, feature):
            try c.encode(Tag.locked, forKey: .t); try c.encode(id, forKey: .id); try c.encode(feature, forKey: .feature)
        case let .conversations(items):
            try c.encode(Tag.conversations, forKey: .t); try c.encode(items, forKey: .items)
        case let .history(id, items):
            try c.encode(Tag.history, forKey: .t); try c.encode(id, forKey: .id); try c.encode(items, forKey: .items)
        case let .speaker(id, name, index):
            try c.encode(Tag.speaker, forKey: .t); try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name); try c.encode(index, forKey: .index)
        case let .image(imageID, data):
            try c.encode(Tag.image, forKey: .t); try c.encode(imageID, forKey: .imageID); try c.encode(data, forKey: .data)
        }
    }
}

public enum RemoteCodec {
    public static func encode<M: Encodable>(_ m: M) throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return String(decoding: try enc.encode(m), as: UTF8.self)
    }
    private static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
    public static func decodeClient(_ s: String) throws -> ClientMessage {
        try decoder().decode(ClientMessage.self, from: Data(s.utf8))
    }
    public static func decodeServer(_ s: String) throws -> ServerMessage {
        try decoder().decode(ServerMessage.self, from: Data(s.utf8))
    }
}

/// The QR / text pairing code: the Mac name + the 32-byte PSK, base64url-JSON.
public struct PairingPayload: Codable, Equatable, Sendable {
    public let v: Int
    public let name: String
    public let psk: Data
    public init(name: String, psk: Data) { self.v = RemoteProtocol.version; self.name = name; self.psk = psk }

    public func encodedCode() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString()
    }
    public init?(code: String) {
        guard let data = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines)),
              let p = try? JSONDecoder().decode(PairingPayload.self, from: data) else { return nil }
        // Decoded, but never previously checked: any base64 JSON with the right field names got
        // through. A version below 1 is not a Slate code, and a short key is a truncated one.
        guard p.v >= 1, p.psk.count == RemoteTransport.pskBytes, !p.name.isEmpty else { return nil }
        self = p
    }
}
