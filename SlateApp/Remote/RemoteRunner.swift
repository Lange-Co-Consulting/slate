import Foundation
import SlateCore
import SlateLlama
import SlateRemoteProtocol

/// Runs one remote prompt headlessly and streams tokens back. The phone companion is a plain
/// conversational chat with your Mac's local model — deliberately NOT the tool-using coding
/// agent. That keeps a remote peer from driving file/shell tools, and stops weak local models
/// from derailing into `<tool_call>` syntax. We stream `grammar: nil` directly (no AgentLoop,
/// no registry, no forced tool grammar), exactly like the Mac's own plain chat.
@MainActor
final class RemoteRunner {
    private unowned let model: AppModel
    init(model: AppModel) { self.model = model }

    /// Run `text` on `modelRef`, forwarding events. Honors the app-wide single-run gate.
    /// Returns after the run ends. `onEvent` is called on the main actor. A cancelled task
    /// (the phone's Stop) asks the engine to stop cooperatively — Task cancellation alone is
    /// unreliable while the engine is actively yielding tokens.
    /// Largest single attachment accepted from a paired phone. The link is PSK-secured and
    /// LAN-only, but a bound still beats trusting the peer with unbounded writes to disk.
    private static let maxAttachmentBytes = 25 * 1024 * 1024

    func run(id: UUID, modelRef: String, text: String, attachments: [Attachment] = [],
             onEvent: @escaping @MainActor (AgentEvent) -> Void) async {
        guard model.tryBeginExclusiveRun() else {
            onEvent(.failed("Your Mac is busy with another run.")); return
        }
        defer { model.endExclusiveRun() }
        let engine: any LLMEngine
        do { engine = try await model.makeEngine(forRef: modelRef) }
        catch { onEvent(.failed(error.localizedDescription)); return }

        let accepted = attachments.filter { $0.data.count <= Self.maxAttachmentBytes }
        let files = accepted.filter { $0.kind == .file }
        // Only the FIRST image is used: the vision path takes a single image per turn.
        let imagePath = accepted.first(where: { $0.kind == .image }).flatMap(Self.writeTemporary)

        let system = """
            You are Slate, a helpful assistant running locally on the user's Mac, answering \
            from their iPhone over the local network. Reply directly and conversationally in \
            prose. You have no tools of your own; anything the user attached is included below.
            """
        var session = ChatSession(system: system)

        // Text attachments are inlined into the turn, which is how the Mac app already feeds
        // context files to a model. Binary files are named but not decoded.
        var prompt = text
        for f in files {
            let body = String(data: f.data, encoding: .utf8)
            prompt += body.map { "\n\n--- \(f.name) ---\n\($0)" }
                       ?? "\n\n(attached \(f.name), \(f.data.count) bytes, not readable as text)"
        }
        session.append(ChatMessage(role: .user, content: prompt, imagePath: imagePath))

        engine.clearStop()                         // the stop flag is sticky — clear stale state
        await withTaskCancellationHandler {
            do {
                for try await tok in await engine.generate(
                    messages: session.messagesForPrompt(), grammar: nil, options: GenOptions()) {
                    onEvent(.token(tok))
                }
                onEvent(.finalAnswer(""))
            } catch is CancellationError { /* stopped via requestStop */ }
            catch { onEvent(.failed(error.localizedDescription)) }
        } onCancel: {
            engine.requestStop()                   // cooperative stop; nonisolated, safe from here
        }
    }

    /// Persist an inbound image so the vision path can read it as a file. Named from a UUID,
    /// never from the peer-supplied filename, so a hostile name cannot escape the directory.
    private static func writeTemporary(_ a: Attachment) -> String? {
        let ext = a.mime.hasSuffix("png") ? "png" : "jpg"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SlateRemoteAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do { try a.data.write(to: url, options: .atomic); return url.path } catch { return nil }
    }

}
