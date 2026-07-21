import SwiftUI

/// The menu-bar hub: quick Slate actions (new chat, open, models, settings) plus
/// the Flow dictation controls - so the app is one click away even when the main
/// window is closed. A Mac-native touch B2C users expect.
struct SlateMenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(FlowRuntime.self) private var flow

    var body: some View {
        Button("New Chat") { open(); model.newConversation(kind: .chat) }
        Button("Slate Quick") {
            NotificationCenter.default.post(name: .slateQuickToggle, object: nil)
        }
        .keyboardShortcut(.space, modifiers: .option)
        Button("New Code Session") { open(); model.newConversation(kind: .code) }
        Button("Transcribe File…") { open(); model.showTranscription = true }
        Divider()
        Button("Open Slate") { open() }
        Button("Model Manager…") { open(); model.showModelManager = true }
        Button("Settings…") { open(); model.showSettings = true }
        Divider()
        FlowMenuBarView().environment(flow)
        Divider()
        Button("Quit Slate") { NSApp.terminate(nil) }
    }

    /// Bring the main window forward (menu-bar actions should surface the app).
    private func open() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
    }
}
