import SwiftUI
import SlateUI
import SlateCore
#if SLATE_PRO
import SlatePro   // QuickPanelController (Slate Quick, ⌥Space) lives in the paid layer
#endif

@main
struct SlateApp: App {
    @State private var model = AppModel()
    @State private var flow = FlowRuntime()
    // Slate Quick is a Pro-only overlay that lives in slate-pro (Phase 3): only the
    // official build constructs its controller and registers the ⌥Space hotkey.
    #if SLATE_PRO
    @State private var quick = QuickPanelController()
    #endif

    private var menuBarBinding: Binding<Bool> {
        Binding(get: { model.settings.menuBarEnabled },
                set: { model.settings.menuBarEnabled = $0 })
    }

    init() {
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": true])
        // Activate + show in Dock when launched outside a full app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Force the Dock tile to the current Strata icon (bypasses macOS's stale
        // icon cache, which otherwise shows an old bundled icon until a reboot).
        NSApplication.shared.applicationIconImage = SlateAppIcon.make()
        NSApplication.shared.servicesProvider = SlateServicesProvider.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(flow)
                .environment(\.slatePalette, model.settings.palette)
                .preferredColorScheme(model.settings.theme.colorScheme)
                .tint(model.settings.customColorsEnabled ? model.settings.palette.controlAccent : .primary)
                .task {
                    model.bootstrap()
                    flow.connectLLM(model); flow.start()
                    #if SLATE_PRO
                    quick.connect(host: model); quick.start()
                    #endif
                }
        }
        .defaultPosition(.center)
        .restorationBehavior(.automatic)
        .defaultSize(width: 1000, height: 700)
        // Full-bleed canvas: no opaque titlebar strip - the aurora runs to the top
        // edge and the floating glass bars are the only chrome (Apple's new look).
        .windowStyle(.hiddenTitleBar)
        .commands {
            SlateCommands(model: model)
        }
        // NB: no Settings scene - Settings present as an IN-APP sheet (RootView,
        // ⌘, or the sidebar gear) so fullscreen is never left.

        // Slate lives in the menu bar: quick actions + Flow dictation, one click
        // away even when the main window is closed.
        MenuBarExtra("Slate", systemImage: "square.stack.3d.up.fill",
                     isInserted: menuBarBinding) {
            SlateMenuBarView()
                .environment(model)
                .environment(flow)
                .environment(\.slatePalette, model.settings.palette)
                .tint(model.settings.customColorsEnabled ? model.settings.palette.controlAccent : .primary)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Native menu commands for Slate's primary surfaces. Keyboard shortcuts used
/// to be hosted by invisible buttons inside RootView/SidebarView, which worked
/// but left the macOS menu bar generic and made the shortcuts undiscoverable.
@MainActor
struct SlateCommands: Commands {
    let model: AppModel

    private var selectedKind: Conversation.Kind { model.selected?.kind ?? .chat }

    private var contextualNewTitle: String {
        switch selectedKind {
        case .chat: "New Chat"
        case .code: "New Code Session"
        case .image: "New Image"
        case .agents: "New Roundtable"
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(contextualNewTitle) { model.newConversation(kind: selectedKind) }
                .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("New Chat") { model.newConversation(kind: .chat) }
            Button("New Code Session") { model.newConversation(kind: .code) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Image") { model.newConversation(kind: .image) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Roundtable") { model.newConversation(kind: .agents) }
                .keyboardShortcut("n", modifiers: [.command, .control])
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Workspace") {
            Button("Command Palette…") { model.showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("Switch Conversation…") { model.showSwitcher = true }
                .keyboardShortcut("p", modifiers: .command)
            Button("Search Everywhere…") { model.showGlobalSearch = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(.smooth(duration: 0.28)) { model.sidebarVisible.toggle() }
            }
            Button("Model Manager…") { model.showModelManager = true }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Downloads…") { model.showDownloads = true }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Transcribe Audio or Video…") { model.showTranscription = true }
                .keyboardShortcut("t", modifiers: [.command, .option])
        }
    }
}
