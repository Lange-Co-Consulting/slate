import Foundation

public enum RemoteProtocol { public static let version = 1 }

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

// Client → server. Flat JSON keyed by "t".
public enum ClientMessage: Codable, Equatable, Sendable {
    case hello(client: String, proto: Int)
    case prompt(id: UUID, model: String, text: String)
    case stop(id: UUID)

    private enum K: String, CodingKey { case t, client, proto, id, model, text }
    private enum Tag: String, Codable { case hello, prompt, stop }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .hello:  self = .hello(client: try c.decode(String.self, forKey: .client),
                                    proto: try c.decode(Int.self, forKey: .proto))
        case .prompt: self = .prompt(id: try c.decode(UUID.self, forKey: .id),
                                     model: try c.decode(String.self, forKey: .model),
                                     text: try c.decode(String.self, forKey: .text))
        case .stop:   self = .stop(id: try c.decode(UUID.self, forKey: .id))
        }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        switch self {
        case let .hello(client, proto):
            try c.encode(Tag.hello, forKey: .t); try c.encode(client, forKey: .client); try c.encode(proto, forKey: .proto)
        case let .prompt(id, model, text):
            try c.encode(Tag.prompt, forKey: .t); try c.encode(id, forKey: .id); try c.encode(model, forKey: .model); try c.encode(text, forKey: .text)
        case let .stop(id):
            try c.encode(Tag.stop, forKey: .t); try c.encode(id, forKey: .id)
        }
    }
}

// Server → client. Flat JSON keyed by "t".
public enum ServerMessage: Codable, Equatable, Sendable {
    case models(items: [ModelInfo], mac: String)
    case token(id: UUID, s: String)
    case tool(id: UUID, name: String, phase: ToolPhase)
    case done(id: UUID)
    case error(id: UUID, kind: RunErrorKind, msg: String)
    case locked(id: UUID, feature: String)

    private enum K: String, CodingKey { case t, items, mac, id, s, name, phase, kind, msg, feature }
    private enum Tag: String, Codable { case models, token, tool, done, error, locked }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .models: self = .models(items: try c.decode([ModelInfo].self, forKey: .items),
                                     mac: try c.decode(String.self, forKey: .mac))
        case .token:  self = .token(id: try c.decode(UUID.self, forKey: .id), s: try c.decode(String.self, forKey: .s))
        case .tool:   self = .tool(id: try c.decode(UUID.self, forKey: .id),
                                   name: try c.decode(String.self, forKey: .name),
                                   phase: try c.decode(ToolPhase.self, forKey: .phase))
        case .done:   self = .done(id: try c.decode(UUID.self, forKey: .id))
        case .error:  self = .error(id: try c.decode(UUID.self, forKey: .id),
                                    kind: try c.decode(RunErrorKind.self, forKey: .kind),
                                    msg: try c.decode(String.self, forKey: .msg))
        case .locked: self = .locked(id: try c.decode(UUID.self, forKey: .id),
                                     feature: try c.decode(String.self, forKey: .feature))
        }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        switch self {
        case let .models(items, mac):
            try c.encode(Tag.models, forKey: .t); try c.encode(items, forKey: .items); try c.encode(mac, forKey: .mac)
        case let .token(id, s):
            try c.encode(Tag.token, forKey: .t); try c.encode(id, forKey: .id); try c.encode(s, forKey: .s)
        case let .tool(id, name, phase):
            try c.encode(Tag.tool, forKey: .t); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(phase, forKey: .phase)
        case let .done(id):
            try c.encode(Tag.done, forKey: .t); try c.encode(id, forKey: .id)
        case let .error(id, kind, msg):
            try c.encode(Tag.error, forKey: .t); try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(msg, forKey: .msg)
        case let .locked(id, feature):
            try c.encode(Tag.locked, forKey: .t); try c.encode(id, forKey: .id); try c.encode(feature, forKey: .feature)
        }
    }
}

public enum RemoteCodec {
    public static func encode<M: Encodable>(_ m: M) throws -> String {
        String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
    }
    public static func decodeClient(_ s: String) throws -> ClientMessage {
        try JSONDecoder().decode(ClientMessage.self, from: Data(s.utf8))
    }
    public static func decodeServer(_ s: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(s.utf8))
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
        self = p
    }
}
