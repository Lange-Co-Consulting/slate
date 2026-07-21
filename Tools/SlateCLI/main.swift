import Foundation
import SlateCore
import SlateSTT

@main
enum SlateCLI {
    static func main() async {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else { throw CLIError.usage }
            args.removeFirst()
            switch command {
            case "search": try search(args.joined(separator: " "))
            case "transcribe": try await transcribe(args)
            case "ask":
                let prompt: String
                if args.isEmpty {
                    let input = try FileHandle.standardInput.read(upToCount: 64_001) ?? Data()
                    guard input.count <= 64_000 else { throw CLIError.requestTooLarge }
                    prompt = String(data: input, encoding: .utf8) ?? ""
                } else {
                    prompt = args.joined(separator: " ")
                }
                try await ask(prompt)
            case "help", "--help", "-h": print(usage)
            default: throw CLIError.unknown(command)
            }
        } catch {
            FileHandle.standardError.write(Data(("slatectl: \(error.localizedDescription)\n").utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static let usage = """
    Usage:
      slatectl search QUERY
      slatectl transcribe FILE [--language CODE]
      slatectl ask [PROMPT]      # or pipe text over stdin (recommended)

    Every command runs locally. `ask` opens the installed Slate app and requires
    a local chat model to be loaded. Transcription uses cached/imported models only.
    """

    private static func search(_ query: String) throws {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CLIError.usage }
        let slate = URL.applicationSupportDirectory.appendingPathComponent("Slate", isDirectory: true)
        let files = [slate.appendingPathComponent("conversations.json"),
                     slate.appendingPathComponent("transcriptions.json")]
        var entries: [SearchEntry] = []
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            let object = try JSONSerialization.jsonObject(with: PrivateStorage.read(from: file, maxBytes: 50 * 1_024 * 1_024))
            collect(object, source: file.lastPathComponent, inheritedTitle: nil, into: &entries)
        }
        let matches = entries.compactMap { entry -> (Int, SearchEntry)? in
            guard let score = LocalSearch.score(query: query, in: entry.title + "\n" + entry.text) else { return nil }
            return (score, entry)
        }.sorted { $0.0 > $1.0 }.prefix(40)
        if matches.isEmpty { print("No local matches."); return }
        for (_, entry) in matches {
            print("\(entry.source) · \(entry.title)\n  \(LocalSearch.snippet(query: query, from: entry.text))")
        }
    }

    private static func collect(_ object: Any, source: String, inheritedTitle: String?,
                                into entries: inout [SearchEntry]) {
        if let array = object as? [Any] {
            for value in array {
                collect(value, source: source, inheritedTitle: inheritedTitle, into: &entries)
            }
            return
        }
        guard let dictionary = object as? [String: Any] else { return }
        let title = (dictionary["title"] as? String)
            ?? (dictionary["sourceName"] as? String)
            ?? (dictionary["project"] as? String)
            ?? inheritedTitle
            ?? source
        for key in ["content", "text"] {
            if let text = dictionary[key] as? String, !text.isEmpty {
                entries.append(SearchEntry(source: source, title: title, text: text))
            }
        }
        for value in dictionary.values where value is [Any] || value is [String: Any] {
            collect(value, source: source, inheritedTitle: title, into: &entries)
        }
    }

    private static func transcribe(_ args: [String]) async throws {
        guard let first = args.first, !first.hasPrefix("--") else { throw CLIError.usage }
        let url = URL(fileURLWithPath: (first as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError.noFile(url.path) }
        var language: String?
        if let index = args.firstIndex(of: "--language"), args.indices.contains(index + 1) {
            language = args[index + 1] == "auto" ? nil : args[index + 1]
        }
        let samples = try AudioFileDecoder.decode(url: url)
        let engine = ParakeetEngine()
        let chunkSize = Int(AudioFileDecoder.sampleRate * 10 * 60)
        var parts: [String] = []
        for start in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(samples.count, start + chunkSize)
            let result = try await engine.transcribe(Array(samples[start..<end]), language: language)
            let clean = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { parts.append(clean) }
        }
        print(parts.joined(separator: "\n\n"))
    }

    private static func ask(_ prompt: String) async throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CLIError.usage }
        guard prompt.utf8.count <= 64_000 else { throw CLIError.requestTooLarge }
        try SlateAutomation.prepareDirectories()
        let request = SlateAutomationRequest(action: .ask, text: prompt)
        let requestURL = SlateAutomation.requestURL(for: request.id)
        let responseURL = SlateAutomation.responseURL(for: request.id)
        try? FileManager.default.removeItem(at: responseURL)
        try PrivateStorage.write(JSONEncoder().encode(request), to: requestURL)

        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["slate://automation/\(request.id.uuidString.lowercased())"]
        try opener.run(); opener.waitUntilExit()
        guard opener.terminationStatus == 0 else { throw CLIError.appUnavailable }

        for _ in 0..<600 {
            if let data = try? PrivateStorage.read(from: responseURL, maxBytes: 2 * 1_024 * 1_024),
               let response = try? JSONDecoder().decode(SlateAutomationResponse.self, from: data) {
                try? FileManager.default.removeItem(at: responseURL)
                if let error = response.error { throw CLIError.remote(error) }
                print(response.result ?? "")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw CLIError.timedOut
    }

    private struct SearchEntry { let source: String; let title: String; let text: String }
    private enum CLIError: LocalizedError {
        case usage, unknown(String), noFile(String), appUnavailable, timedOut, requestTooLarge, remote(String)
        var errorDescription: String? {
            switch self {
            case .usage: return SlateCLI.usage
            case .unknown(let command): return "Unknown command ‘\(command)’.\n\(SlateCLI.usage)"
            case .noFile(let path): return "File not found: \(path)"
            case .appUnavailable: return "Slate could not be opened. Install Slate.app in Applications."
            case .timedOut: return "Slate did not answer within 120 seconds."
            case .requestTooLarge: return "The request is larger than Slate's 64 KB local automation limit."
            case .remote(let message): return message
            }
        }
    }
}
