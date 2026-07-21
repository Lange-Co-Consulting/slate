import Foundation
import SlateCore

/// Piggybacks the user's OpenCode installation. OpenCode owns provider auth and
/// supports its full provider/model catalog; Slate only selects a model, streams
/// JSON events, and persists the returned session id per conversation.
final class OpenCodeEngine: LLMEngine, @unchecked Sendable {
    struct CLIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let cliPath: String
    let modelID: String
    private let lock = NSLock()
    private var _lastSessionID: String?
    private var _lastTokens: Int?
    private var _lastCost: Double?
    private var _process: Process?

    var lastSessionID: String? { lock.withLock { _lastSessionID } }
    var lastTokens: Int? { lock.withLock { _lastTokens } }
    var lastCost: Double? { lock.withLock { _lastCost } }
    var isPassthroughAgent: Bool { true }
    var supportsWebSearch: Bool { true }
    var contextWindow: Int { 0 }
    var trainedContext: Int { 0 }

    init?(modelID: String, cliPath: String? = nil) {
        guard modelID.contains("/"),
              let raw = cliPath ?? Self.locate(),
              let path = Self.validExecutable(raw) else { return nil }
        self.modelID = modelID
        self.cliPath = path
    }

    func requestStop() { lock.withLock { _process?.terminate() } }
    func clearStop() {}

    func generate(messages: [ChatMessage], grammar: GrammarSpec?, options: GenOptions)
        async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let resume = options.openCodeSessionId
            lock.withLock {
                _lastSessionID = resume
                _lastTokens = nil
                _lastCost = nil
            }
            var prompt = resume == nil ? Self.renderHistory(messages) : Self.lastUserText(messages)
            if let system = options.systemPromptOverride, !system.isEmpty {
                prompt = "Additional Slate instructions:\n\(system)\n\n\(prompt)"
            }
            guard !prompt.isEmpty else { continuation.finish(); return }

            let directory = options.workingDirectory ?? Self.scratchDir()
            var args = OpenCodeCLI.arguments(model: modelID, sessionID: resume,
                                             directory: directory,
                                             skipPermissions: options.skipPermissions
                                                && options.permissionMode == .autopilot)
            if let image = messages.last(where: { $0.role == .user })?.imagePath {
                args += ["--file", image]
            }
            args.append(prompt)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            var environment = Self.cliEnvironment()
            environment["OPENCODE_PERMISSION"] = OpenCodeCLI.permissionJSON(
                options.permissionMode ?? .recommendedDefault, webSearch: options.webSearchEnabled)
            process.environment = environment
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            let accumulator = OpenCodeLineAccumulator(maxBytes: 4 * 1_024 * 1_024)
            let streamed = OpenCodeLocked(false)
            let reasoningOpen = OpenCodeLocked(false)
            out.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                guard !bytes.isEmpty else { return }
                guard let lines = accumulator.push(bytes) else {
                    continuation.yield("\n⚠️ OpenCode produced more than 4 MB of output and was stopped.\n")
                    process.terminate()
                    return
                }
                for line in lines {
                    for event in OpenCodeCLI.parse(line) {
                        switch event {
                        case .sessionStarted(let id):
                            self?.lock.withLock { self?._lastSessionID = id }
                        case .text(let text):
                            if reasoningOpen.get() {
                                reasoningOpen.set(false); continuation.yield("\n</think>\n\n")
                            }
                            streamed.set(true); continuation.yield(text)
                        case .reasoning(let text):
                            if !reasoningOpen.get() {
                                reasoningOpen.set(true); continuation.yield("<think>\n")
                            }
                            continuation.yield(text)
                        case .tool(let summary):
                            if reasoningOpen.get() {
                                reasoningOpen.set(false); continuation.yield("\n</think>\n\n")
                            }
                            continuation.yield("\n`⚙ \(summary)`\n")
                        case .finished(let tokens, let cost):
                            self?.lock.withLock {
                                self?._lastTokens = tokens
                                self?._lastCost = cost
                            }
                        case .ignored:
                            break
                        }
                    }
                }
            }

            process.terminationHandler = { [weak self] finished in
                out.fileHandleForReading.readabilityHandler = nil
                if reasoningOpen.get() { continuation.yield("\n</think>\n\n") }
                if finished.terminationStatus != 0, !streamed.get() {
                    continuation.yield("⚠️ OpenCode exited with code \(finished.terminationStatus).\n\nRun `opencode providers login` in Terminal and verify the selected model with `opencode models`.")
                }
                self?.lock.withLock { self?._process = nil }
                continuation.finish()
            }

            do {
                try process.run()
                lock.withLock { _process = process }
            } catch {
                continuation.yield("⚠️ Couldn't launch OpenCode: \(error.localizedDescription)")
                continuation.finish()
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
        }
    }

    static func discoverModels(cliPath: String? = nil) throws -> [String] {
        guard let raw = cliPath ?? locate(), let path = validExecutable(raw) else {
            throw CLIError(message: "OpenCode CLI not found.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["models", "--pure"]
        process.environment = cliEnvironment()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
        defer { timeout.cancel() }
        var data = Data()
        while let chunk = try? out.fileHandleForReading.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 1 * 1_024 * 1_024 {
                if process.isRunning { process.terminate() }
                throw CLIError(message: "OpenCode model discovery produced too much output.")
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError(message: "OpenCode model discovery failed.")
        }
        return OpenCodeCLI.models(from: String(data: data, encoding: .utf8) ?? "")
    }

    static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode",
            "\(home)/.opencode/bin/opencode", "\(home)/.local/bin/opencode",
            "\(home)/.bun/bin/opencode", "/usr/bin/opencode",
        ]
        return candidates.compactMap(validExecutable).first
    }

    private static func lastUserText(_ messages: [ChatMessage]) -> String {
        messages.last { $0.role == .user }?.content ?? ""
    }

    private static func renderHistory(_ messages: [ChatMessage]) -> String {
        messages.filter { $0.role == .user || $0.role == .assistant }
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.content)" }
            .joined(separator: "\n\n")
    }

    private static func scratchDir() -> String {
        let directory = URL.applicationSupportDirectory
            .appendingPathComponent("Slate/cloud/opencode", isDirectory: true)
        try? PrivateStorage.ensureDirectory(directory)
        return directory.path
    }

    private static func cliEnvironment() -> [String: String] {
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

private final class OpenCodeLocked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
}

private final class OpenCodeLineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var receivedBytes = 0
    private let maxBytes: Int

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    /// nil means the process exceeded its complete-stream budget.
    func push(_ data: Data) -> [String]? {
        lock.withLock {
            receivedBytes += data.count
            guard receivedBytes <= maxBytes else { return nil }
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let text = String(data: line, encoding: .utf8) { lines.append(text) }
            }
            return lines
        }
    }
}
