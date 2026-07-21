import SwiftUI
import SlateUI
import SlateCore

/// A single palette action.
struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    let run: () -> Void
}

/// ⌘K command palette: fuzzy-search every action - new chats, switch model
/// (incl. Cloud), jump to a conversation, open manager/downloads/settings,
/// cycle theme, Kill all. Monochrome glass, keyboard-first.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private func close() { model.showPalette = false }

    /// All available commands, assembled from live app state.
    private var commands: [PaletteCommand] {
        var c: [PaletteCommand] = [
            .init(title: "New Chat", systemImage: "bubble.left.and.bubble.right") { model.newConversation(kind: .chat); close() },
            .init(title: "New Code Session", systemImage: "chevron.left.forwardslash.chevron.right") { model.newConversation(kind: .code); close() },
            .init(title: "Transcribe Audio or Video…", subtitle: "Local · included in Free", systemImage: "waveform.badge.mic") { model.showTranscription = true; close() },
            .init(title: "Search Everywhere…", subtitle: "Chats, files, transcripts and models · ⌘⇧F", systemImage: "sparkle.magnifyingglass") { model.showGlobalSearch = true; close() },
        ]
        // Switch model - Cloud first, then installed GGUFs.
        c.append(.init(title: "Model · Cloud · Claude Code", subtitle: "Use Claude instead of a local model",
                       systemImage: "cloud") { model.useClaudeCode(); close() })
        for m in AppSettings.claudeModelOptions {
            c.append(.init(title: "Cloud model · \(m.capitalized)",
                           subtitle: model.settings.claudeModel == m ? "current" : "for Claude Code turns",
                           systemImage: "cloud") { model.settings.claudeModel = m; model.useClaudeCode(); close() })
        }
        for id in model.settings.openCodeModels {
            c.append(.init(title: "Model · OpenCode · \(id)",
                           subtitle: "Use the provider login managed by OpenCode",
                           systemImage: "terminal") { model.pickOpenCodeModel(id); close() })
        }
        for provider in model.settings.cloudProviders {
            c.append(.init(title: "Model · Cloud API · \(provider.name)",
                           subtitle: provider.model,
                           systemImage: "cloud") { model.pickCloudModel(provider); close() })
        }
        for m in model.models {
            c.append(.init(title: "Model · \(SidebarView.pretty(m.name))",
                           subtitle: ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file),
                           systemImage: "cpu") { model.pickLocalModel(m.url); close() })
        }
        // Jump to a conversation.
        for convo in model.sortedConversations {
            c.append(.init(title: "Go · \(convo.title)",
                           subtitle: convo.kind.menuLabel,
                           systemImage: convo.kind.menuIcon) {
                model.selectedID = convo.id; close()
            })
        }
        c += [
            .init(title: "Manage Models…", systemImage: "square.stack.3d.up") { model.showModelManager = true; close() },
            .init(title: "Downloads…", systemImage: "arrow.down.circle") { model.showDownloads = true; close() },
            .init(title: "Cycle Theme", subtitle: "System / Light / Dark", systemImage: "circle.lefthalf.filled") { model.cycleTheme() },
            .init(title: "Kill all", subtitle: "Stop generation, unload the model", systemImage: "xmark.octagon") { model.killAll(); close() },
        ]
        return c
    }

    private var filtered: [PaletteCommand] {
        Array(FuzzyMatch.rank(query, commands, key: \.title).prefix(9))
    }

    private func runSelected() {
        let list = filtered
        guard !list.isEmpty else { return }
        list[min(selection, list.count - 1)].run()
    }
    private func move(_ delta: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        selection = (selection + delta + n) % n
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit(runSelected)
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(.horizontal, 18).padding(.vertical, 15)

            if !filtered.isEmpty {
                Divider().opacity(0.15)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { i, cmd in
                                row(cmd, selected: i == selection)
                                    .id(i)
                                    .contentShape(Rectangle())
                                    .onTapGesture { cmd.run() }
                                    .onHover { if $0 { selection = i } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selection) { _, s in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(s) } }
                }
            }
        }
        .frame(width: 560)
        // Continuous curvature - must match the rim stroke below exactly, or the
        // specular edge separates from the glass in the corners.
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .glassRim(RoundedRectangle(cornerRadius: 18, style: .continuous), scheme: scheme)
        .glassShadow(scheme, hero: true)
        .overlay(alignment: .top) { Color.clear.frame(height: 0) }   // keeps layout stable
        // Keyboard: Esc closes; ↑/↓ move; ↩ runs (via onSubmit).
        .onExitCommand(perform: close)
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onAppear { query = ""; selection = 0; focused = true }
    }

    private func row(_ cmd: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: cmd.systemImage)
                .font(.system(size: 14)).foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(cmd.title).font(.callout).lineLimit(1)
                if let s = cmd.subtitle {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if selected { Image(systemName: "return").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // Concentric with the 18pt glass shell at its 6pt inset.
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(selected ? 0.08 : 0)))
    }
}

/// ⌘P session switcher: conversations only, fuzzy-ranked - the fastest way to
/// jump between sessions. Same glass shell as the ⌘K palette.
struct SessionSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private func close() { model.showSwitcher = false }

    private var matches: [Conversation] {
        let all = model.sortedConversations
        guard !query.isEmpty else { return all }
        return FuzzyMatch.rank(query, all, key: \.title)
    }

    private func open(at i: Int) {
        guard matches.indices.contains(i) else { return }
        model.selectedID = matches[i].id
        close()
    }
    private func move(_ delta: Int) {
        let n = matches.count
        guard n > 0 else { return }
        selection = (selection + delta + n) % n
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.right.arrow.left").foregroundStyle(.secondary)
                TextField("Jump to session…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { open(at: selection) }
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(.horizontal, 18).padding(.vertical, 15)

            if !matches.isEmpty {
                Divider().opacity(0.15)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { i, c in
                                HStack(spacing: 10) {
                                    Image(systemName: c.kind.menuIcon)
                                        .font(.system(size: 13))
                                        .foregroundStyle(i == selection ? .primary : .secondary)
                                        .frame(width: 20)
                                    Text(c.title).font(.callout).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(c.kind.menuLabel)
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.primary.opacity(i == selection ? 0.08 : 0)))
                                .contentShape(Rectangle())
                                .onTapGesture { open(at: i) }
                                .onHover { if $0 { selection = i } }
                                .id(i)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selection) { _, s in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(s) } }
                }
            }
        }
        .frame(width: 460)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .glassRim(RoundedRectangle(cornerRadius: 18, style: .continuous), scheme: scheme)
        .glassShadow(scheme, hero: true)
        .onExitCommand(perform: close)
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onAppear { query = ""; selection = 0; focused = true }
    }
}
