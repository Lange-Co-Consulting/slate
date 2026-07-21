import Foundation
import SlateCore

struct Conversation: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case chat, code, image, agents
        /// SF Symbol for menus, the command palette, and global search.
        var menuIcon: String {
            switch self {
            case .chat: "bubble.left"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .image: "photo"
            case .agents: "person.3"
            }
        }
        /// Short human label for the same surfaces.
        var menuLabel: String {
            switch self {
            case .chat: "Chat"; case .code: "Code"; case .image: "Image"; case .agents: "Roundtable"
            }
        }
    }

    let id: UUID
    var title: String
    var kind: Kind
    var folderPath: String?
    /// SHA-256 of the exact project-rules file the user trusted. Any content
    /// change automatically revokes trust.
    var trustedProjectRulesDigest: String?
    var permissionMode: String   // PermissionMode.rawValue
    var messages: [ChatMessage]
    var createdAt: Date
    var pinned: Bool
    var manualTitle: Bool
    var temperature: Double?
    var systemPromptOverride: String?
    /// The Claude Code CLI session to resume for this conversation (Cloud engine),
    /// so context carries across turns. nil until the first cloud turn starts one.
    var claudeSessionId: String?
    /// OpenCode's resumable session, kept separate so switching between CLI
    /// backends never feeds one provider another provider's opaque id.
    var openCodeSessionId: String?
    /// Plan-first execution for code tasks: the agent writes a short numbered
    /// plan before touching the codebase (small local models gain a lot).
    var planMode: Bool
    /// The model the user pinned for THIS conversation (so a mid-chat switch
    /// sticks and the next turn just continues, like Claude Code). nil = use the
    /// kind's default (auto-switch). Encoded as a local path, "cloud:<id>", or
    /// "claude-code".
    var pinnedModel: String?
    /// Agent Chat (roundtable) config. Model refs reuse pinnedModel's encoding
    /// (local path | "cloud:<id>" | "opencode:<id>" | "claude-code"); personas is
    /// parallel to models ("" = none). All optional-decoded for back-compat.
    var agentModels: [String]
    var agentPersonas: [String]
    var agentRounds: Int
    var agentSynthesis: Bool

    init(kind: Kind, createdAt: Date) {
        self.id = UUID()
        self.title = switch kind {
        case .chat: "New chat"; case .code: "New code session"
        case .image: "New image"; case .agents: "New roundtable"
        }
        self.kind = kind
        self.folderPath = nil
        self.trustedProjectRulesDigest = nil
        self.permissionMode = PermissionMode.recommendedDefault.rawValue
        self.messages = []
        self.createdAt = createdAt
        self.pinned = false
        self.manualTitle = false
        self.temperature = nil
        self.systemPromptOverride = nil
        self.claudeSessionId = nil
        self.openCodeSessionId = nil
        self.planMode = false
        self.pinnedModel = nil
        self.agentModels = []
        self.agentPersonas = []
        self.agentRounds = 3
        self.agentSynthesis = true
    }

    var folderURL: URL? { folderPath.map { URL(fileURLWithPath: $0) } }
    var mode: PermissionMode { PermissionMode(rawValue: permissionMode) ?? .recommendedDefault }
    var isUntitled: Bool { title == "New chat" || title == "New code session" || title == "New image" || title == "New roundtable" || title == "New agent chat" }

    // Backward/forward-compatible decoding (tolerates older JSON without new keys).
    enum CodingKeys: String, CodingKey {
        case id, title, kind, folderPath, trustedProjectRulesDigest, permissionMode, messages, createdAt, pinned, manualTitle, temperature, systemPromptOverride, claudeSessionId, openCodeSessionId, planMode, pinnedModel, agentModels, agentPersonas, agentRounds, agentSynthesis
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decode(Kind.self, forKey: .kind)
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        trustedProjectRulesDigest = try c.decodeIfPresent(String.self, forKey: .trustedProjectRulesDigest)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
            ?? PermissionMode.recommendedDefault.rawValue
        messages = try c.decode([ChatMessage].self, forKey: .messages)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        manualTitle = try c.decodeIfPresent(Bool.self, forKey: .manualTitle) ?? false
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        systemPromptOverride = try c.decodeIfPresent(String.self, forKey: .systemPromptOverride)
        claudeSessionId = try c.decodeIfPresent(String.self, forKey: .claudeSessionId)
        openCodeSessionId = try c.decodeIfPresent(String.self, forKey: .openCodeSessionId)
        planMode = try c.decodeIfPresent(Bool.self, forKey: .planMode) ?? false
        pinnedModel = try c.decodeIfPresent(String.self, forKey: .pinnedModel)
        agentModels = try c.decodeIfPresent([String].self, forKey: .agentModels) ?? []
        agentPersonas = try c.decodeIfPresent([String].self, forKey: .agentPersonas) ?? []
        agentRounds = try c.decodeIfPresent(Int.self, forKey: .agentRounds) ?? 3
        agentSynthesis = try c.decodeIfPresent(Bool.self, forKey: .agentSynthesis) ?? true
    }
}

enum ConversationStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Slate", isDirectory: true)
        try? PrivateStorage.ensureDirectory(dir)
        return dir.appendingPathComponent("conversations.json")
    }

    static func load() -> [Conversation] {
        // No file yet → genuinely empty (first run).
        guard let data = try? PrivateStorage.read(from: fileURL, maxBytes: 50 * 1_024 * 1_024), !data.isEmpty else { return [] }

        let dec = JSONDecoder()
        if let convos = try? dec.decode([Conversation].self, from: data) { return convos }

        // The file exists but didn't decode as a whole. Recover what we can by
        // decoding each element independently (skips a single corrupt entry rather
        // than losing everything), and NEVER let a bad file be silently overwritten.
        if let salvaged = try? dec.decode([FailableConversation].self, from: data) {
            let convos = salvaged.compactMap(\.value)
            if !convos.isEmpty { return convos }
        }

        // Couldn't recover anything: preserve the original so save() can't destroy it.
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("conversations.corrupt.json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: fileURL, to: backup)
        return []
    }

    static func save(_ convos: [Conversation]) {
        guard let data = try? JSONEncoder().encode(convos) else { return }
        write(data)
    }

    /// Write already-encoded conversation data (used by the debounced, off-main persist).
    static func write(_ data: Data) {
        try? PrivateStorage.write(data, to: fileURL)
    }
}

/// Decodes to nil instead of throwing, so one malformed element in an array
/// doesn't fail the whole decode.
private struct FailableConversation: Decodable {
    let value: Conversation?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(Conversation.self)
    }
}
