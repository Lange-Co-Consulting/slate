import Foundation
import SlateCore
import SlateLlama

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
    func run(id: UUID, modelRef: String, text: String,
             onEvent: @escaping @MainActor (AgentEvent) -> Void) async {
        guard model.tryBeginExclusiveRun() else {
            onEvent(.failed("Your Mac is busy with another run.")); return
        }
        defer { model.endExclusiveRun() }
        let engine: any LLMEngine
        do { engine = try await model.makeEngine(forRef: modelRef) }
        catch { onEvent(.failed(error.localizedDescription)); return }

        let system = """
            You are Slate, a helpful assistant running locally on the user's Mac, answering \
            from their iPhone over the local network. Reply directly and conversationally in \
            prose. You have no tools and cannot access files — answer from what you know.
            """
        var session = ChatSession(system: system)
        session.append(ChatMessage(role: .user, content: text))

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
}
