import SwiftUI

/// Post-pairing shell: a chat list home that pushes into a thread, with the Mac
/// status banner ambient at the top and Settings a tap away.
struct MainView: View {
    @Environment(AppState.self) private var app
    @State private var path = NavigationPath()
    @State private var showSettings = false
    @State private var showModelPicker = false

    var body: some View {
        NavigationStack(path: $path) {
            ChatListView(open: { path.append($0) }, newChat: startNewChat)
                .navigationDestination(for: Conversation.self) { convo in
                    ChatView(conversation: convo)
                }
                .navigationDestination(for: String.self) { route in
                    if route == "settings" { SettingsView() }
                }
        }
        // Nav chrome inherits the root .tint (accent when a palette is on, else ink).
    }

    private func startNewChat() {
        let convo = Conversation(title: "New chat", subtitle: "", model: app.currentModel, messages: [])
        app.conversations.insert(convo, at: 0)
        path.append(convo)
    }
}

struct ChatListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.slatePalette) private var pal
    @Environment(\.colorScheme) private var scheme
    let open: (Conversation) -> Void
    let newChat: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                MacStatusBanner()
                    .padding(.horizontal, 16).padding(.top, 6)

                if app.conversations.isEmpty {
                    EmptyChatsView(newChat: newChat).padding(.top, 80)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(app.conversations) { convo in
                            Button { open(convo) } label: { ConversationRow(convo: convo) }
                                .buttonStyle(PressableCardButtonStyle())
                                .contextMenu {
                                    Button(role: .destructive) {
                                        app.deleteConversation(convo.id)
                                    } label: {
                                        Label("Delete chat", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 100)
        }
        .canvas()
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: "settings") {
                    Image(systemName: "gearshape").foregroundStyle(Theme.ink)
                }
            }
            // No trailing pencil — the floating "New chat" pill is the single entry point.
        }
        .toolbarBackground(Theme.washedCanvas(pal, scheme), for: .navigationBar)
        .overlay(alignment: .bottom) {
            Button(action: newChat) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil").font(.slate(16, .medium))
                    Text("New chat").font(.slate(16, .medium))
                }
                .foregroundStyle(pal.enabled ? pal.accentInk : Theme.canvas)
                .padding(.horizontal, 22).padding(.vertical, 14)
                .background(Capsule().fill(pal.enabled ? pal.accent : Theme.ink))
                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12),
                        radius: scheme == .dark ? 12 : 10, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
    }
}

struct ConversationRow: View {
    let convo: Conversation
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(convo.title).font(.slate(16, .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if !convo.subtitle.isEmpty {
                    Text(convo.subtitle).font(.slate(13)).foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
                Text(convo.model).font(.slate(12)).foregroundStyle(Theme.inkTertiary)
                    .padding(.top, 1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.slate(13, .medium))
                .foregroundStyle(Theme.inkTertiary)
        }
        .padding(16)
        .slateCard()
    }
}

struct EmptyChatsView: View {
    let newChat: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44)).foregroundStyle(Theme.inkTertiary)
            Text("No chats yet").font(.slate(20, .medium)).foregroundStyle(Theme.ink)
            Text("Start a conversation — it runs on your Mac and appears here.")
                .font(.slate(15)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            PrimaryButton(title: "New chat", icon: "square.and.pencil", action: newChat)
                .padding(.horizontal, 60).padding(.top, 6)
        }
    }
}
