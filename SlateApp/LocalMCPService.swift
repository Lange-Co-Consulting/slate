import Foundation
import Observation
import SlateCore

/// User-configured MCP servers that communicate over local stdio only.
/// Discovery and execution happen in a network-denied child-process sandbox.
@MainActor @Observable
final class LocalMCPService {
    var servers: [LocalMCPServer] = [] {
        didSet { save() }
    }
    private(set) var tools: [LocalMCPTool] = []
    private(set) var registeredTools: [RegisteredTool] = []
    private(set) var statusByServer: [UUID: String] = [:]
    private(set) var isScanning = false

    @ObservationIgnored private let client = LocalMCPClient()
    @ObservationIgnored private var didLoad = false

    private static let fileURL = URL.applicationSupportDirectory
        .appendingPathComponent("Slate", isDirectory: true)
        .appendingPathComponent("mcp-servers.json")

    init() { load() }

    func add(executable url: URL) {
        guard url.isFileURL else { return }
        let path = url.standardizedFileURL.path
        guard !servers.contains(where: { $0.executablePath == path }) else { return }
        guard let server = Self.normalized(LocalMCPServer(name: url.deletingPathExtension().lastPathComponent,
                                                          executablePath: path)) else { return }
        servers.append(server)
    }

    func update(_ server: LocalMCPServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }),
              let normalized = Self.normalized(server) else { return }
        servers[index] = normalized
    }

    func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
        tools.removeAll { $0.serverID == id }
        registeredTools.removeAll { tool in
            !tools.contains(where: { $0.spec.name == tool.spec.name })
        }
        statusByServer[id] = nil
    }

    func rescan(gate: any ApprovalGate) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        var discovered: [LocalMCPTool] = []
        var statuses: [UUID: String] = [:]
        let enabled = servers.filter(\.enabled)
        for server in enabled {
            let detail = [
                "Server: \(server.name)",
                "Executable: \(server.executablePath)",
                "Scope: \(server.workingDirectory ?? "not configured")",
                "Discovery starts this program once with network denied."
            ].joined(separator: "\n")
            let approved = await gate.confirm(ApprovalRequest(
                kind: .localTool, risk: .sensitive,
                title: "Inspect local MCP server?", detail: detail,
                scope: "discover:\(server.id.uuidString)"))
            guard approved else {
                statuses[server.id] = "Discovery rejected"
                AuditLog.record(.init(category: "tool", action: "mcp-discover", detail: server.name,
                                      approval: "rejected", outcome: "not run"))
                continue
            }
            do {
                let found = try await client.discover(server: server)
                discovered += found
                statuses[server.id] = found.isEmpty ? "No tools" : "\(found.count) tool\(found.count == 1 ? "" : "s")"
                AuditLog.record(.init(category: "tool", action: "mcp-discover", detail: server.name,
                                      approval: "approved", outcome: "success"))
            } catch {
                statuses[server.id] = error.localizedDescription
            }
        }
        tools = discovered.sorted { $0.spec.name < $1.spec.name }
        statusByServer = statuses
        let serverMap = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })
        let client = self.client
        registeredTools = tools.compactMap { tool in
            guard let server = serverMap[tool.serverID] else { return nil }
            return RegisteredTool(spec: tool.spec) { arguments in
                let detail = Self.approvalDetail(server: server, tool: tool, arguments: arguments)
                let scope = server.id.uuidString + ":" + tool.originalName + ":" + Self.canonical(arguments)
                let approved = await gate.confirm(ApprovalRequest(
                    kind: .localTool, risk: .sensitive,
                    title: "Run local tool?", detail: detail, scope: scope))
                guard approved else {
                    AuditLog.record(.init(category: "tool", action: tool.spec.name,
                                          detail: "\(server.name) · \(tool.originalName)",
                                          approval: "rejected", outcome: "not run"))
                    return "Local tool rejected by user."
                }
                do {
                    let output = try await client.call(server: server, tool: tool, arguments: arguments)
                    AuditLog.record(.init(category: "tool", action: tool.spec.name,
                                          detail: "\(server.name) · \(tool.originalName)",
                                          approval: "approved", outcome: "success"))
                    return output
                } catch {
                    AuditLog.record(.init(category: "tool", action: tool.spec.name,
                                          detail: "\(server.name) · \(tool.originalName)",
                                          approval: "approved", outcome: "failed: \(error.localizedDescription)"))
                    throw error
                }
            }
        }
    }

    nonisolated private static func canonical(_ arguments: [String: String]) -> String {
        arguments.keys.sorted().map { "\($0)=\(arguments[$0] ?? "")" }.joined(separator: "&")
    }

    nonisolated private static func approvalDetail(server: LocalMCPServer, tool: LocalMCPTool,
                                                   arguments: [String: String]) -> String {
        let args = arguments.keys.sorted().map { "\($0): \(arguments[$0] ?? "")" }
        return (["Server: \(server.name)", "Tool: \(tool.originalName)"] + args).joined(separator: "\n")
    }

    private func load() {
        defer { didLoad = true }
        guard let data = try? PrivateStorage.read(from: Self.fileURL, maxBytes: 1_000_000),
              let decoded = try? JSONDecoder().decode([LocalMCPServer].self, from: data) else { return }
        servers = Array(decoded.prefix(128)).compactMap(Self.normalized)
    }

    private func save() {
        guard didLoad else { return }
        do {
            let data = try JSONEncoder().encode(servers)
            try PrivateStorage.write(data, to: Self.fileURL)
        } catch { /* Settings remain usable; a later edit retries persistence. */ }
    }

    nonisolated private static func normalized(_ server: LocalMCPServer) -> LocalMCPServer? {
        let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = server.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 100,
              executable.hasPrefix("/"), executable.utf8.count <= 4_096,
              server.arguments.count <= 32,
              server.arguments.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") }),
              server.workingDirectory.map({ $0.utf8.count <= 4_096 && !$0.contains("\0") }) ?? true else { return nil }
        var copy = server
        copy.name = name
        copy.executablePath = executable
        copy.arguments = server.arguments.map { String($0.prefix(4_096)) }
        copy.workingDirectory = server.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}
