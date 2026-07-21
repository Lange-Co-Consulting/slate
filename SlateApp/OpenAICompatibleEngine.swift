import Foundation
import SlateCore

/// LLMEngine backed by any OpenAI-compatible `/chat/completions` endpoint
/// (OpenAI, OpenRouter, Groq, Together, local servers…). Bring-your-own key.
/// A plain text engine (not a passthrough agent): Slate drives it exactly like
/// a local model - chat streams directly, code runs through the AgentLoop.
final class OpenAICompatibleEngine: LLMEngine, @unchecked Sendable {
    let provider: CloudProvider
    private let apiKey: String?
    private let stop = StopBox()
    private let session: URLSession

    init(provider: CloudProvider, apiKey: String?) {
        self.provider = provider
        self.apiKey = apiKey
        self.session = LockedDownURLSession.make()
    }

    var isPassthroughAgent: Bool { false }
    var isVision: Bool { false }        // v1: text only
    var contextWindow: Int { 0 }
    var trainedContext: Int { 0 }

    func requestStop() { stop.set() }
    func clearStop() { stop.clear() }

    struct CloudError: LocalizedError { let message: String; var errorDescription: String? { message } }

    func generate(messages: [ChatMessage], grammar: GrammarSpec?, options: GenOptions)
        async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(messages: messages, options: options)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw CloudError(message: "No response from \(provider.name).")
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        let msg = OpenAIStream.errorMessage(fromBody: body) ?? "HTTP \(http.statusCode)"
                        throw CloudError(message: friendlyHTTP(http.statusCode, msg))
                    }
                    for try await line in bytes.lines {
                        if stop.isSet { break }
                        if OpenAIStream.isDone(line) { break }
                        if let token = OpenAIStream.token(fromLine: line) {
                            continuation.yield(token)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func buildRequest(messages: [ChatMessage], options: GenOptions) throws -> URLRequest {
        let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              scheme == "https" || (scheme == "http" && Self.loopbackHosts.contains(host)) else {
            throw CloudError(message: "Cloud endpoints must use HTTPS (HTTP is allowed only for localhost).")
        }
        components.path = components.path.hasSuffix("/")
            ? components.path + "chat/completions"
            : components.path + "/chat/completions"
        guard let url = components.url else {
            throw CloudError(message: "The cloud endpoint URL is invalid.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let payload: [String: Any] = [
            "model": provider.model,
            "stream": true,
            "temperature": options.temperature,
            "max_tokens": options.maxTokens,
            "messages": messages.map { m -> [String: String] in
                // A plain chat engine: tool messages fold into user context.
                let role = (m.role == .tool) ? "user" : m.role.rawValue
                return ["role": role, "content": m.content]
            },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    private func friendlyHTTP(_ code: Int, _ message: String) -> String {
        switch code {
        case 401, 403: return "\(provider.name): the API key was rejected. Check the key in Settings → Cloud."
        case 404:      return "\(provider.name): model ‘\(provider.model)’ or endpoint not found."
        case 429:      return "\(provider.name): rate limited or out of quota. \(message)"
        default:       return "\(provider.name): \(message)"
        }
    }
}

/// Thread-safe cooperative stop flag for the streaming loop.
final class StopBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
    func clear() { lock.lock(); flag = false; lock.unlock() }
}
