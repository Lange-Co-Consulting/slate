import Foundation
import SlateCore

/// Slate's optional CLOUD engine: piggybacks the `claude` CLI (Claude Code) in
/// headless stream-json mode. Inherits whatever `claude` is logged into - a Claude
/// subscription runs over normal usage (no API credits); an API-key login bills
/// credits. Runs its OWN agent loop + tools, so Slate streams it directly.
final class ClaudeCodeEngine: LLMEngine, @unchecked Sendable {
    let cliPath: String
    private let env: [String: String]

    private let lock = NSLock()
    private var _lastSessionId: String?
    private var _lastCostUSD: Double?
    private var _lastTurns: Int?
    private var _proc: Process?
    private var _stopped = false

    /// The Claude Code session id of the most recent turn - AppModel persists this
    /// on the conversation so the next turn resumes it (context continuity).
    var lastSessionId: String? { lock.withLock { _lastSessionId } }
    /// Cost + turn count of the most recent turn (from the result event).
    var lastCostUSD: Double? { lock.withLock { _lastCostUSD } }
    var lastTurns: Int? { lock.withLock { _lastTurns } }

    var isPassthroughAgent: Bool { true }
    var supportsWebSearch: Bool { true }
    var contextWindow: Int { 200_000 }
    var trainedContext: Int { 200_000 }

    /// Fails if the `claude` CLI can't be found - the caller shows a friendly hint.
    init?(cliPath: String? = nil) {
        guard let raw = cliPath ?? Self.locate(), let p = Self.validExecutable(raw) else { return nil }
        self.cliPath = p
        self.env = Self.loginEnvironment()
    }

    func requestStop() {
        lock.withLock { _stopped = true; _proc?.terminate() }
    }
    func clearStop() { lock.withLock { _stopped = false } }

    func generate(messages: [ChatMessage], grammar: GrammarSpec?, options: GenOptions) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.lock.withLock { self._lastCostUSD = nil; self._lastTurns = nil }
            let resume = options.claudeSessionId
            // First turn (no session) → send the whole conversation for context;
            // resumed turns → just the new user message (Claude Code has the rest).
            var prompt = resume == nil ? Self.renderHistory(messages) : Self.lastUserText(messages)
            // Reference an attached image by path so Claude Code can Read it.
            if let img = messages.last(where: { $0.role == .user })?.imagePath {
                prompt += "\n\n(Attached image: \(img) - read it to view.)"
            }
            guard !prompt.isEmpty else { continuation.finish(); return }

            let args = ClaudeCode.arguments(sessionId: resume,
                                            mode: options.permissionMode ?? .recommendedDefault,
                                            addDir: nil,
                                            skipPermissions: options.skipPermissions,
                                            model: options.claudeModel,
                                            appendSystemPrompt: options.systemPromptOverride,
                                            webSearch: options.webSearchEnabled)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cliPath)
            proc.arguments = args
            // Raise the thinking budget for this turn if an effort is set.
            var runEnv = env
            if let mtt = options.maxThinkingTokens { runEnv["MAX_THINKING_TOKENS"] = String(mtt) }
            proc.environment = runEnv
            // Run in the project folder (Code) or a neutral scratch dir (Chat), so
            // Claude Code never inherits "/" and wander into protected folders
            // (which would fire a TCC prompt attributed to Slate).
            proc.currentDirectoryURL = URL(fileURLWithPath: options.workingDirectory ?? Self.scratchDir())
            let inPipe = Pipe(), outPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = outPipe
            // A cloud CLI is a user-selected external program. Do not allow an
            // unlimited stderr stream to fill a pipe and deadlock Slate.
            proc.standardError = FileHandle.nullDevice

            let streamedAny = Locked(false)
            let inThink = Locked(false)
            let acc = LineAccumulator(maxBytes: 4 * 1_024 * 1_024)
            // Close an open <think> block before emitting non-thinking content.
            let endThink: @Sendable () -> Void = {
                if inThink.get() { inThink.set(false); continuation.yield("\n</think>\n\n") }
            }

            outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let chunk = h.availableData
                guard !chunk.isEmpty else { return }
                guard let lines = acc.push(chunk) else {
                    continuation.yield("\n⚠️ Claude Code produced more than 4 MB of output and was stopped.\n")
                    proc.terminate()
                    return
                }
                for line in lines {
                    for ev in ClaudeCode.parse(line) {
                        switch ev {
                        case .sessionStarted(let sid):
                            self?.lock.withLock { self?._lastSessionId = sid }
                        case .thinking(let t):
                            // Wrap extended thinking in <think>…</think> so Slate's
                            // reasoning UI shows it as a collapsible "Thoughts" block.
                            if !inThink.get() { inThink.set(true); continuation.yield("<think>\n") }
                            continuation.yield(t)
                        case .textDelta(let t):
                            endThink(); streamedAny.set(true); continuation.yield(t)
                        case .toolUse(let s):
                            endThink(); continuation.yield("\n`\(s)`\n")
                        case .toolResult(let s):
                            endThink(); continuation.yield("`\(s)`\n")
                        case .result(let text, let isError, let cost, let turns):
                            endThink()
                            self?.lock.withLock { self?._lastCostUSD = cost; self?._lastTurns = turns }
                            if isError, let text, !text.isEmpty {
                                continuation.yield("\n⚠️ \(text)")
                            } else if !streamedAny.get(), let text, !text.isEmpty {
                                continuation.yield(text)   // nothing streamed → show the final result
                            }
                        case .ignored: break
                        }
                    }
                }
            }

            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                if inThink.get() { inThink.set(false); continuation.yield("\n</think>\n\n") }
                if !streamedAny.get() && p.terminationStatus != 0 {
                    continuation.yield("⚠️ Claude Code exited with code \(p.terminationStatus).\n\nIs the `claude` CLI installed and logged in? Run `claude` once in a terminal to sign in.")
                }
                continuation.finish()
            }

            do {
                try proc.run()
                self.lock.withLock { self._proc = proc }
                // Feed the prompt on stdin (no arg-escaping issues), then close.
                inPipe.fileHandleForWriting.write(Data(prompt.utf8))
                try? inPipe.fileHandleForWriting.close()
            } catch {
                continuation.yield("⚠️ Couldn't launch Claude Code: \(error.localizedDescription)")
                continuation.finish()
            }
            continuation.onTermination = { _ in proc.terminate() }
        }
    }

    // MARK: helpers

    private static func lastUserText(_ messages: [ChatMessage]) -> String {
        messages.last { $0.role == .user }?.content ?? ""
    }
    private static func renderHistory(_ messages: [ChatMessage]) -> String {
        let body = messages.filter { $0.role == .user || $0.role == .assistant }
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.content)" }
            .joined(separator: "\n\n")
        return body.isEmpty ? lastUserText(messages) : body
    }

    /// A neutral working directory for folder-less (Chat) cloud turns.
    private static func scratchDir() -> String {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("Slate/cloud", isDirectory: true)
        try? PrivateStorage.ensureDirectory(dir)
        return dir.path
    }

    /// Never run a login shell just to discover a CLI: shell init files are
    /// executable user-controlled code. Check known locations directly.
    static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude", "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude", "/usr/bin/claude",
        ]
        return candidates.compactMap(validExecutable).first
    }

    /// Do not pass the full Slate environment (API keys, SSH agent, CI tokens,
    /// etc.) into an external CLI. HOME remains only because this user-selected
    /// client needs its own login state.
    private static func loginEnvironment() -> [String: String] {
        ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
         "LANG": "en_US.UTF-8"]
    }

    private static func validExecutable(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path),
              url.path != "/bin/sh", url.path != "/bin/zsh", url.path != "/bin/bash" else { return nil }
        return url.path
    }
}

/// Tiny thread-safe box for the "did we stream anything" flag shared with the
/// readability handler.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}

/// Accumulates piped stdout bytes and returns complete newline-terminated lines.
/// Thread-safe: FileHandle readability callbacks are serialized but Swift 6 still
/// needs the shared buffer boxed.
private final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var receivedBytes = 0
    private let maxBytes: Int

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    /// nil means the process exceeded its complete-stream budget.
    func push(_ chunk: Data) -> [String]? {
        lock.withLock {
            receivedBytes += chunk.count
            guard receivedBytes <= maxBytes else { return nil }
            buffer.append(chunk)
            var lines: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let s = String(data: lineData, encoding: .utf8) { lines.append(s) }
            }
            return lines
        }
    }
}
