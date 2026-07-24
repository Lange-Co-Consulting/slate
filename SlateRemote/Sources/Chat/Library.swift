import SlateRemoteProtocol
import SwiftUI

/// Everything the paired Mac has, across all of Slate's surfaces.
///
/// The phone used to show only chats it had started itself, so Code, Image, Roundtable and
/// Automations were invisible even though the Mac was full of them. This is the read side of
/// protocol v2: the Mac lists its conversations, the phone browses them, and anything the
/// phone cannot drive says so plainly rather than pretending.
@MainActor @Observable
final class Library {
    var items: [ConversationSummary] = []
    var history: [String: [HistoryItem]] = [:]
    var loading = false
    /// Set when the paired Mac is too old to serve the library.
    var unsupported = false

    func reset() {
        items = []; history = [:]; loading = false; unsupported = false
    }
}

/// Which surfaces the phone shows. `chat` is the one it can drive; the rest are windows onto
/// the Mac. Ordered the way the Mac's own sidebar is, so the two apps read the same.
enum LibraryTab: String, CaseIterable, Identifiable {
    case chat, code, image, roundtable, automation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chats"
        case .code: "Code"
        case .image: "Images"
        case .roundtable: "Roundtable"
        case .automation: "Automations"
        }
    }

    var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .roundtable: "person.3"
        case .automation: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }

    var wireKind: ConversationKind {
        switch self {
        case .chat: .chat
        case .code: .code
        case .image: .image
        case .roundtable: .roundtable
        case .automation: .automation
        }
    }

    /// Only chat can be continued from the phone. Saying this out loud beats a tab that looks
    /// interactive and quietly does nothing.
    var isInteractive: Bool { self == .chat }

    var emptyTitle: String {
        switch self {
        case .chat: "No chats yet"
        case .code: "No code sessions"
        case .image: "No images yet"
        case .roundtable: "No roundtables yet"
        case .automation: "No automations"
        }
    }

    var emptyHint: String {
        switch self {
        case .chat: "Start one below. It runs on your Mac."
        case .code: "Code sessions are started on your Mac, with a project folder."
        case .image: "Images are generated on your Mac."
        case .roundtable: "Seat a few models on your Mac and let them debate."
        case .automation: "Automations are scheduled on your Mac."
        }
    }
}

/// One surface's conversations, as they exist on the Mac.
struct LibraryListView: View {
    @Environment(AppState.self) private var app
    let tab: LibraryTab
    let menu: AnyView

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if app.macStatus != .reachable {
                    MacStatusBanner().padding(.horizontal, 16).padding(.bottom, 10)
                }
                if app.library.unsupported {
                    LibraryNotice(icon: "arrow.up.circle",
                                  title: "Update Slate on your Mac",
                                  detail: "Browsing \(tab.title.lowercased()) needs a newer version of Slate than your Mac is running.")
                } else if app.library.loading && app.library.items.isEmpty {
                    ProgressView().controlSize(.regular).tint(Theme.inkSecondary).padding(.top, 80)
                } else if app.library.items.isEmpty {
                    LibraryNotice(icon: tab.icon, title: tab.emptyTitle, detail: tab.emptyHint)
                } else {
                    ForEach(app.library.items, id: \.id) { item in
                        NavigationLink(value: Route.macThread(item)) {
                            LibraryRow(item: item)
                        }
                        .buttonStyle(PressableCardButtonStyle())
                        Divider().overlay(Theme.hairline).padding(.leading, 16)
                    }
                }
            }
            .padding(.top, 8).padding(.bottom, 40)
        }
        .canvas()
        .navigationTitle(tab.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { menu } }
        .refreshable { app.loadLibrary(tab) }
        .task { app.loadLibrary(tab) }
    }
}

/// Borderless, like every reference app's conversation list. The bordered cards this replaces
/// turned five chats into five competing rectangles and printed the raw model filename as a
/// third line on each one.
private struct LibraryRow: View {
    let item: ConversationSummary

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.slate(16)).foregroundStyle(Theme.ink).lineLimit(1)
                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub).font(.slate(13)).foregroundStyle(Theme.inkSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(item.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.slate(12)).foregroundStyle(Theme.inkTertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// Empty and unsupported states share one calm shape.
private struct LibraryNotice: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Theme.inkTertiary)
            Text(title).font(.slate(20, .medium)).foregroundStyle(Theme.ink)
            Text(detail).font(.slate(15)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 44)
        }
        .padding(.top, 90)
    }
}

/// A read-only thread from the Mac. Reasoning is stripped the same way the live chat does it,
/// so a browsed roundtable never shows a model's inner monologue either.
struct LibraryThreadView: View {
    @Environment(AppState.self) private var app
    let summary: ConversationSummary

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    LibraryTurn(item: item)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 90)
        }
        .canvas()
        .navigationTitle(summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { continueOnMac }
        .task { app.openLibraryConversation(summary.id) }
    }

    private var items: [HistoryItem] { app.library.history[summary.id] ?? [] }

    /// The honest ending: this surface lives on the Mac, and the phone is showing it, not
    /// running it.
    private var continueOnMac: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer").font(.slate(13))
            Text("Continue this on your Mac").font(.slate(13))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

private struct LibraryTurn: View {
    let item: HistoryItem

    private var isUser: Bool { item.role == "user" }
    private var text: String { Reasoning.answer(item.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let speaker = item.speaker, !speaker.isEmpty {
                Text(speaker.uppercased())
                    .font(.slate(10, .semibold)).tracking(1.1)
                    .foregroundStyle(Theme.inkTertiary)
            }
            if !text.isEmpty {
                Text(text)
                    .font(.slate(15))
                    .foregroundStyle(isUser ? Theme.inkSecondary : Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, isUser ? 12 : 0).padding(.vertical, isUser ? 9 : 0)
        .background {
            if isUser { SlateShape(radius: 14).fill(Theme.surface) }
        }
    }
}
