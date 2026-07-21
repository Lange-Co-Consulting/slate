import SwiftUI
import SlateUI

struct FileNode: Identifiable {
    let url: URL
    let isDir: Bool
    var children: [FileNode]?
    var id: URL { url }
    var name: String { url.lastPathComponent }

    static func scan(_ dir: URL, depth: Int = 0) -> [FileNode] {
        let skip: Set<String> = ["node_modules", ".git", "build", ".build", "DerivedData",
                                 ".next", "dist", ".venv", "Pods", ".swiftpm"]
        guard depth < 7,
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        else { return [] }
        let safeItems = items.compactMap { url -> (url: URL, isDirectory: Bool)? in
            guard !skip.contains(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return nil }
            return (url, values.isDirectory == true)
        }
        return safeItems
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.url.lastPathComponent.localizedCaseInsensitiveCompare(b.url.lastPathComponent) == .orderedAscending
            }
            .map { item in
                FileNode(url: item.url, isDir: item.isDirectory,
                         children: item.isDirectory ? scan(item.url, depth: depth + 1) : nil)
            }
    }
}

struct FileTreeView: View {
    let root: URL
    let onOpen: (URL) -> Void
    var onClose: (() -> Void)? = nil
    @State private var nodes: [FileNode] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                SectionLabel(text: "Files", system: "folder")
                Spacer()
                ToolbarIconButton(system: "arrow.clockwise", help: "Rescan files") { nodes = FileNode.scan(root) }
                if let onClose {
                    ToolbarIconButton(system: "xmark", help: "Close files") { onClose() }
                }
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            .padding(.top, 6)
            Divider()
            if nodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("Empty folder").font(.callout).foregroundStyle(.secondary)
                    Text("Files Slate creates or edits appear here.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center).frame(maxWidth: 200)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    OutlineGroup(nodes, children: \.children) { node in
                        HStack(spacing: 6) {
                            Image(systemName: node.isDir ? "folder.fill" : icon(node.name))
                                .foregroundStyle(.secondary).font(.caption)
                                .accessibilityHidden(true)
                            Text(node.name).font(.callout).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if !node.isDir { onOpen(node.url) } }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(node.isDir ? "Folder, \(node.name)" : "File, \(node.name)")
                        .accessibilityAddTraits(node.isDir ? [] : .isButton)
                        .accessibilityHint(node.isDir ? "" : "Opens in the file viewer")
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)   // a navigator rail, never half the window
        .background(.background)   // clean solid panel, matching the Preview column
        .onAppear { nodes = FileNode.scan(root) }
    }

    private func icon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm": return "globe"
        case "css": return "paintbrush"
        case "js", "ts", "swift", "py", "rb", "go", "rs", "java", "c", "cpp", "h": return "curlybraces"
        case "json", "yml", "yaml", "toml": return "list.bullet.rectangle"
        case "md", "txt": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        default: return "doc"
        }
    }
}

struct FileViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: url.lastPathComponent, system: "doc.text") { dismiss() }
            ScrollView([.horizontal, .vertical]) {
                Text(content)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Flexible: sheets clip to the window frame - never larger than it.
        .frame(minWidth: 460, idealWidth: 720, minHeight: 340, idealHeight: 540)
        .onAppear {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  (values?.fileSize ?? .max) <= 2 * 1_024 * 1_024 else {
                content = "(file is binary, special, or larger than 2 MB)"
                return
            }
            content = (try? String(contentsOf: url, encoding: .utf8)) ?? "(binary or unreadable file)"
        }
    }
}
