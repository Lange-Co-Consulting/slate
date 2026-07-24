import SlateRemoteProtocol
import SwiftUI

/// The navigation drawer: every surface the Mac runs, the conversations inside the current one,
/// and Settings at the foot.
///
/// This is where "Code, Image, Roundtable and Automations should all be visible" is answered.
/// They are not fake tabs — picking one asks the Mac for its real conversations of that kind and
/// browses them. Only chat can be driven from the phone, and the surfaces that cannot say so
/// rather than presenting a composer that goes nowhere.
struct DrawerPanel: View {
    @Environment(AppState.self) private var app
    @Binding var tab: LibraryTab
    let activeID: Conversation.ID?
    let open: (Conversation) -> Void
    let newChat: () -> Void
    /// Push a destination onto the shell's navigation stack. The drawer sits *outside* that
    /// stack — it is a sibling of the shell, not a child — so a `NavigationLink` here has no
    /// stack to push into and silently does nothing. Settings and every Mac thread were
    /// unreachable from the menu for exactly that reason.
    let push: (Route) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    surfaces
                    recents
                }
                .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .frame(maxHeight: .infinity)
        .background(DrawerGlass())
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                WeaveMark(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Slate").font(.slate(17, .medium)).foregroundStyle(Theme.ink)
                    HStack(spacing: 5) {
                        Circle().fill(app.macStatus.tint).frame(width: 6, height: 6)
                        Text(macLine).font(.slate(12)).foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            Button(action: newChat) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil").font(.slate(15, .medium))
                    Text("New chat").font(.slate(15, .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .glassCapsule(radius: Theme.rControl)
            }
            .buttonStyle(PressableCardButtonStyle())
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
    }

    private var macLine: String {
        let name = app.macs.first?.name ?? "Your Mac"
        return app.macStatus == .reachable ? name : app.macStatus.label
    }

    // MARK: Surfaces

    private var surfaces: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionCaption(text: "Surfaces").padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(LibraryTab.allCases) { item in
                Button {
                    guard tab != item else { dismiss(); return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    tab = item
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.icon).font(.slate(15))
                            .frame(width: 22)
                        Text(item.title).font(.slate(16))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(tab == item ? Theme.ink : Theme.inkSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background {
                        if tab == item {
                            SlateShape(radius: Theme.rControl).fill(Theme.surfaceHigh)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Recents

    @ViewBuilder private var recents: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionCaption(text: tab == .chat ? "Recents" : tab.title)
                .padding(.horizontal, 8).padding(.bottom, 4)

            if tab == .chat {
                if app.conversations.filter({ !$0.messages.isEmpty }).isEmpty {
                    hint("Your chats appear here once you send something.")
                } else {
                    ForEach(app.conversations.filter { !$0.messages.isEmpty }) { convo in
                        Button { open(convo) } label: {
                            DrawerRow(title: convo.title,
                                      subtitle: convo.subtitle.isEmpty ? convo.modelLabel : convo.subtitle,
                                      selected: convo.id == activeID)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                app.deleteConversation(convo.id)
                            } label: { Label("Delete chat", systemImage: "trash") }
                        }
                    }
                }
            } else if app.library.unsupported {
                hint("Update Slate on your Mac to browse this from your phone.")
            } else if app.library.loading && app.library.items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.inkSecondary)
                    Text("Loading…").font(.slate(14)).foregroundStyle(Theme.inkSecondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            } else if app.library.items.isEmpty {
                hint(tab.emptyHint)
            } else {
                ForEach(app.library.items, id: \.id) { item in
                    Button { push(.macThread(item)) } label: {
                        DrawerRow(title: item.title, subtitle: item.subtitle ?? item.model ?? "",
                                  selected: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.slate(14)).foregroundStyle(Theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Button { push(.settings) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape").font(.slate(15)).frame(width: 22)
                    Text("Settings").font(.slate(16))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, 24).padding(.top, 14)
                .padding(.bottom, 26)          // clears the home indicator
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// One line in the drawer. Borderless: every reference app lists conversations as plain rows,
/// and the old bordered cards turned a list of five chats into five competing rectangles.
private struct DrawerRow: View {
    let title: String
    let subtitle: String
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.slate(15)).foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle).font(.slate(12)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background {
            if selected { SlateShape(radius: Theme.rControl).fill(Theme.surfaceHigh) }
        }
        .contentShape(Rectangle())
    }
}

/// The drawer's own material. Liquid Glass where the OS provides it, over an opaque scrim so
/// the shell sliding across behind it never shows through as a ghost.
private struct DrawerGlass: View {
    @Environment(\.slatePalette) private var pal
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Theme.washedCanvas(pal, scheme)
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Theme.ink.opacity(scheme == .dark ? 0.04 : 0.02))
        }
        .ignoresSafeArea()
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 1).ignoresSafeArea()
        }
    }
}

extension View {
    /// A glass control surface. Uses the system's Liquid Glass on macOS 26's iOS sibling and
    /// falls back to a material — the app targets iOS 26, so the fallback is only ever hit by
    /// previews and tests.
    @ViewBuilder func glassCapsule(radius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: SlateShape(radius: radius))
        } else {
            self.background(SlateShape(radius: radius).fill(.ultraThinMaterial))
                .overlay(SlateShape(radius: radius).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }
}
