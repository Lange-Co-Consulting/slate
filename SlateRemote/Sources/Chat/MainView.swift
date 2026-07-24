import SlateRemoteProtocol
import SwiftUI

/// Where a push lands. A conversation the Mac owns is a different thing from a chat this phone
/// is driving, so it gets its own route rather than being forced into `Conversation`.
enum Route: Hashable {
    case macThread(ConversationSummary)
    case settings
}

/// The post-pairing shell.
///
/// The thread is the root, and everything else — the other surfaces, past conversations,
/// Settings — lives in a drawer behind the leading edge. That is the shape Claude, ChatGPT and
/// Gemini all converged on, for the same reason: opening the app should put you in front of a
/// composer, not in front of a filing cabinet. The old shell made a list of chat cards the home
/// screen, so starting to type cost two taps, and the four other surfaces the Mac actually runs
/// — Code, Images, Roundtable, Automations — had nowhere to appear at all.
struct MainView: View {
    @Environment(AppState.self) private var app
    @State private var drawer = false
    @State private var tab: LibraryTab = .chat
    @State private var activeID: Conversation.ID?
    @State private var path = NavigationPath()
    /// Live finger offset while the drawer is being pulled open or pushed shut.
    @GestureState private var drag: CGFloat = 0

    private static let width: CGFloat = 316

    var body: some View {
        ZStack(alignment: .leading) {
            shell
            DrawerPanel(tab: $tab, activeID: activeID,
                        open: open(_:), newChat: startNewChat, push: push, dismiss: close)
                .frame(width: Self.width)
                .offset(x: shift - Self.width)
                .accessibilityHidden(!drawer)
        }
        .canvas()
        .animation(.smooth(duration: 0.34, extraBounce: 0.08), value: drawer)
        .gesture(edgeDrag)
        .task { ensureActiveChat() }
        .onChange(of: tab) { _, new in
            if !new.isInteractive { app.loadLibrary(new) }
        }
    }

    // MARK: Geometry

    /// How far the shell is pushed aside, clamped so a drag can never overshoot either end.
    private var shift: CGFloat {
        min(max((drawer ? Self.width : 0) + drag, 0), Self.width)
    }
    private var progress: CGFloat { shift / Self.width }

    /// Pull from the leading edge to open, drag left anywhere to close. The 20pt activation
    /// distance keeps it from stealing horizontal swipes inside a thread, where code blocks
    /// and tables scroll sideways.
    private var edgeDrag: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
            .updating($drag) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if drawer { state = min(0, value.translation.width) }
                else if value.startLocation.x < 40 { state = max(0, value.translation.width) }
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if drawer, value.translation.width < -60 { close() }
                else if !drawer, value.startLocation.x < 40, value.translation.width > 60 { open() }
            }
    }

    private func open() {
        drawer = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
    private func close() { drawer = false }

    // MARK: Content

    private var shell: some View {
        NavigationStack(path: $path) {
            Group {
                if tab.isInteractive, let id = activeID {
                    ChatView(conversationID: id, menu: menuButton)
                } else {
                    LibraryListView(tab: tab, menu: menuButton)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .macThread(summary): LibraryThreadView(summary: summary)
                case .settings:               SettingsView()
                }
            }
        }
        // The shell shrinks and rounds as the drawer comes out, so the drawer reads as being
        // behind it rather than beside it.
        .clipShape(SlateShape(radius: 38 * progress))
        .scaleEffect(1 - 0.05 * progress, anchor: .trailing)
        .offset(x: shift)
        .shadow(color: .black.opacity(0.35 * progress), radius: 28, x: -8)
        .overlay {
            if progress > 0 {
                Color.black.opacity(0.18 * progress)
                    .allowsHitTesting(drawer)
                    .onTapGesture { close() }
            }
        }
        .disabled(drawer)
    }

    private var menuButton: AnyView {
        AnyView(
            Button { open() } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.slate(17, .medium)).foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("Open the menu")
        )
    }

    // MARK: Actions

    /// There is always a chat to type into. Reuse the newest empty one rather than stacking up
    /// blank threads every time the app is opened.
    private func ensureActiveChat() {
        guard activeID == nil else { return }
        if let blank = app.conversations.first(where: \.isBlank) {
            activeID = blank.id
        } else {
            let convo = app.newConversation()
            app.conversations.insert(convo, at: 0)
            activeID = convo.id
        }
    }

    private func startNewChat() {
        tab = .chat
        path = NavigationPath()
        if let id = activeID, app.conversations.first(where: { $0.id == id })?.isBlank == true {
            close(); return                      // already sitting on a blank chat
        }
        let convo = app.newConversation()
        app.conversations.insert(convo, at: 0)
        activeID = convo.id
        close()
    }

    /// Push from the drawer, then get out of the way. Closing first would animate the drawer
    /// and the push at the same time; the order here lets the push own the transition.
    private func push(_ route: Route) {
        path.append(route)
        close()
    }

    private func open(_ convo: Conversation) {
        tab = .chat
        path = NavigationPath()
        activeID = convo.id
        close()
    }
}
