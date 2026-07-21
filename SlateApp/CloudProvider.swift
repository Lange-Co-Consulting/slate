import Foundation

/// A saved cloud model reachable over the OpenAI-compatible chat API. The API
/// key never lives here - it's stored in the macOS Keychain under the provider
/// id, so exported settings / JSON never contain secrets.
struct CloudProvider: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String        // display name, e.g. "OpenAI · gpt-4o"
    var baseURL: String     // e.g. "https://api.openai.com/v1"
    var model: String       // e.g. "gpt-4o"

    init(id: String = UUID().uuidString, name: String, baseURL: String, model: String) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.model = model
    }

    var isLoopback: Bool {
        guard let url = URL(string: baseURL),
              url.user == nil, url.password == nil,
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
    var requiresAPIKey: Bool { !isLoopback }

    /// Ready-to-fill starting points for the "add provider" form.
    struct Preset: Identifiable { let id: String; let name: String; let baseURL: String; let sampleModel: String }
    static let presets: [Preset] = [
        Preset(id: "openai",     name: "OpenAI",     baseURL: "https://api.openai.com/v1",     sampleModel: "gpt-4o"),
        Preset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",  sampleModel: "openai/gpt-4o"),
        Preset(id: "groq",       name: "Groq",       baseURL: "https://api.groq.com/openai/v1", sampleModel: "llama-3.3-70b-versatile"),
        Preset(id: "together",   name: "Together AI", baseURL: "https://api.together.xyz/v1", sampleModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo"),
        Preset(id: "mistral",    name: "Mistral AI", baseURL: "https://api.mistral.ai/v1", sampleModel: "mistral-large-latest"),
        Preset(id: "xai",        name: "xAI", baseURL: "https://api.x.ai/v1", sampleModel: "grok-4"),
        Preset(id: "local",      name: "Local server", baseURL: "http://127.0.0.1:1234/v1", sampleModel: "local-model"),
        Preset(id: "custom",     name: "Custom (OpenAI-compatible)", baseURL: "", sampleModel: ""),
    ]
}

// KeychainStore moved to the public engine (SlateCore) — shared by cloud API keys
// here and the private licensing layer. Same Keychain service; no data migration.
