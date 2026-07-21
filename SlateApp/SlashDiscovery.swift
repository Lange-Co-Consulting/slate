import Foundation
import SlateCore

/// Discovers user- and project-defined Claude Code slash commands from the
/// standard `.claude/commands/*.md` locations, so Slate can suggest them the way
/// the CLI does. Each markdown file `name.md` becomes `/name`; the summary comes
/// from a YAML `description:` front-matter key or the first real line.
enum SlashDiscovery {
    /// The full Cloud command pool: Claude Code's built-ins + discovered custom
    /// commands (project ones win over personal on a name clash).
    static func cloudCommands(folder: URL?) -> [SlashCommand] {
        SlashCommands.claudeBuiltins + scan(projectFolder: folder)
    }

    static func scan(projectFolder: URL?) -> [SlashCommand] {
        var dirs = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/commands")]
        if let p = projectFolder { dirs.append(p.appendingPathComponent(".claude/commands")) }

        var out: [SlashCommand] = []
        var seen = Set(SlashCommands.claudeBuiltins.map(\.name))   // don't shadow a built-in
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in items where f.pathExtension.lowercased() == "md" {
                let name = f.deletingPathExtension().lastPathComponent
                guard !name.isEmpty, !seen.contains(name) else { continue }
                seen.insert(name)
                out.append(SlashCommand(name: name, title: name.capitalized,
                                        summary: description(of: f) ?? "Custom command",
                                        template: ""))
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func description(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= 64 * 1_024,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        // YAML front-matter `description:`
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("description:") {
                let v = String(line.dropFirst("description:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !v.isEmpty { return String(v.prefix(90)) }
            }
        }
        // else first non-empty, non-heading, non-fence line
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("---"), !line.hasPrefix("```") {
                return String(line.prefix(90))
            }
        }
        return nil
    }
}
