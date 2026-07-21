import SwiftUI
import SlateUI
import SlateCore

private struct GlobalSearchResult: Identifiable {
    let id: String
    let label: String
    let title: String
    let subtitle: String
    let icon: String
    let score: Int
    let run: () -> Void
}

struct GlobalSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [GlobalSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return [] }
        var results: [GlobalSearchResult] = []
        for conversation in model.conversations {
            let body = conversation.messages.map(\.content).joined(separator: "\n")
            let haystack = conversation.title + "\n" + body
            if let score = LocalSearch.score(query: clean, in: haystack) {
                results.append(.init(
                    id: "chat:" + conversation.id.uuidString,
                    label: conversation.kind.menuLabel.uppercased(),
                    title: conversation.title,
                    subtitle: LocalSearch.snippet(query: clean, from: body),
                    icon: conversation.kind.menuIcon,
                    score: score + (LocalSearch.score(query: clean, in: conversation.title) ?? 0),
                    run: { model.selectedID = conversation.id; model.showGlobalSearch = false }
                ))
            }
        }
        for hit in model.knowledge.search(clean, limit: 20) {
            results.append(.init(
                id: "file:" + hit.id, label: "FILE", title: hit.file,
                subtitle: LocalSearch.snippet(query: clean, from: hit.text), icon: "doc.text.magnifyingglass",
                score: hit.score,
                run: {
                    if let id = UUID(uuidString: hit.conversationID) { model.selectedID = id }
                    model.showGlobalSearch = false
                }
            ))
        }
        for transcript in TranscriptionStore.load() {
            let haystack = transcript.sourceName + " " + (transcript.project ?? "") + " " + transcript.text
            if let score = LocalSearch.score(query: clean, in: haystack) {
                results.append(.init(
                    id: "transcript:" + transcript.id.uuidString, label: "TRANSCRIPT",
                    title: transcript.sourceName,
                    subtitle: LocalSearch.snippet(query: clean, from: transcript.text), icon: "waveform.badge.mic",
                    score: score,
                    run: {
                        model.transcriptionHighlightID = transcript.id
                        model.showGlobalSearch = false
                        model.showTranscription = true
                    }
                ))
            }
        }
        for entry in model.models {
            let display = SidebarView.pretty(entry.name)
            if let score = LocalSearch.score(query: clean, in: display) {
                results.append(.init(
                    id: "model:" + entry.url.path, label: "MODEL", title: display,
                    subtitle: ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file),
                    icon: "cpu", score: score,
                    run: { model.pickLocalModel(entry.url); model.showGlobalSearch = false }
                ))
            }
        }
        return Array(results.sorted { $0.score > $1.score }.prefix(30))
    }

    /// A couple of results should feel like a focused command palette, not a
    /// tall empty dialog. The list grows only as far as there is useful content.
    private var resultListHeight: CGFloat {
        min(390, max(160, CGFloat(results.count) * 62 + 10))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats, files, transcripts and models…", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onChange(of: query) { _, _ in selection = 0 }
                Label("Local", systemImage: "lock.fill")
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule().fill(.primary.opacity(scheme == .dark ? 0.08 : 0.06)))
            }
            .padding(.horizontal, 18).padding(.vertical, 15)
            Divider().opacity(0.15)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                ContentUnavailableView("Search everything on this Mac",
                                       systemImage: "magnifyingglass",
                                       description: Text("Type at least two characters. Nothing is uploaded."))
                    .frame(height: 300)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query).frame(height: 300)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            Button { item.run() } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: item.icon).frame(width: 22).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                                        Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    Text(item.label)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7).padding(.vertical, 4)
                                        .background(Capsule().fill(.primary.opacity(scheme == .dark ? 0.08 : 0.06)))
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(index == selection ? 0.08 : 0)))
                            }
                            .buttonStyle(.plain).onHover { if $0 { selection = index } }
                        }
                    }
                    .padding(6)
                }
                .frame(height: resultListHeight)
                HStack {
                    Text("\(results.count) local result\(results.count == 1 ? "" : "s")")
                    Spacer()
                    Text("↑↓ navigate · ↩ open · Esc close")
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
        .frame(width: 680)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .glassRim(RoundedRectangle(cornerRadius: 18, style: .continuous), scheme: scheme)
        .glassShadow(scheme, hero: true)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand { model.showGlobalSearch = false }
        .onKeyPress(.downArrow) {
            guard !results.isEmpty else { return .ignored }
            selection = (selection + 1) % results.count
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !results.isEmpty else { return .ignored }
            selection = (selection - 1 + results.count) % results.count
            return .handled
        }
        .onKeyPress(.return) {
            guard results.indices.contains(selection) else { return .ignored }
            results[selection].run(); return .handled
        }
    }
}
