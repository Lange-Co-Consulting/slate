#!/usr/bin/env swift
import Foundation

struct Resolved: Decodable {
    struct Pin: Decodable {
        struct State: Decodable { let revision: String; let version: String? }
        let identity: String
        let location: String
        let state: State
    }
    let pins: [Pin]
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resolvedURL = root.appendingPathComponent("Package.resolved")
let resolved = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: resolvedURL))
let version = (try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8))
    .trimmingCharacters(in: .whitespacesAndNewlines)
let lockLines = try String(contentsOf: root.appendingPathComponent("SlateApp/Packaging/release-artifacts.env"), encoding: .utf8)
    .split(separator: "\n")
let artifacts = Dictionary(uniqueKeysWithValues: lockLines.compactMap { line -> (String, String)? in
    let value = line.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty, !value.hasPrefix("#"), let split = value.firstIndex(of: "=") else { return nil }
    return (String(value[..<split]), String(value[value.index(after: split)...]))
})

var packages: [[String: Any]] = resolved.pins.map { pin in
    [
        "SPDXID": "SPDXRef-Package-\(pin.identity)",
        "name": pin.identity,
        "versionInfo": pin.state.version ?? pin.state.revision,
        "downloadLocation": pin.location,
        "filesAnalyzed": false,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": pin.identity == "fluidaudio" ? "Apache-2.0" : "NOASSERTION",
    ]
}
packages.append(contentsOf: [
    ["SPDXID": "SPDXRef-Package-llama-cpp", "name": "llama.cpp", "versionInfo": "sha256:\(artifacts["LLAMA_BINARY_SHA256"] ?? "unknown")", "downloadLocation": "https://github.com/ggml-org/llama.cpp", "filesAnalyzed": false, "licenseConcluded": "MIT", "licenseDeclared": "MIT"],
    ["SPDXID": "SPDXRef-Package-stable-diffusion-cpp", "name": "stable-diffusion.cpp", "versionInfo": artifacts["SD_SOURCE_REVISION"] ?? "unknown", "downloadLocation": "https://github.com/leejet/stable-diffusion.cpp", "filesAnalyzed": false, "licenseConcluded": "MIT", "licenseDeclared": "MIT"],
    ["SPDXID": "SPDXRef-Package-ripgrep", "name": "ripgrep", "versionInfo": artifacts["RIPGREP_VERSION"] ?? "unknown", "downloadLocation": "https://github.com/BurntSushi/ripgrep", "filesAnalyzed": false, "licenseConcluded": "MIT OR Unlicense", "licenseDeclared": "MIT OR Unlicense"],
    ["SPDXID": "SPDXRef-Package-PCRE2", "name": "PCRE2", "versionInfo": "10.45", "downloadLocation": "https://github.com/PCRE2Project/pcre2", "filesAnalyzed": false, "licenseConcluded": "BSD-3-Clause WITH PCRE2-exception", "licenseDeclared": "BSD-3-Clause WITH PCRE2-exception"],
    ["SPDXID": "SPDXRef-Package-fastcluster", "name": "fastcluster", "versionInfo": "via FluidAudio 0.15.5", "downloadLocation": "https://github.com/fastcluster/fastcluster", "filesAnalyzed": false, "licenseConcluded": "BSD-3-Clause", "licenseDeclared": "BSD-3-Clause"],
    ["SPDXID": "SPDXRef-Package-VBx", "name": "VBx", "versionInfo": "via FluidAudio 0.15.5", "downloadLocation": "https://github.com/BUTSpeechFIT/VBx", "filesAnalyzed": false, "licenseConcluded": "Apache-2.0", "licenseDeclared": "Apache-2.0"],
])

let document: [String: Any] = [
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": "Slate-\(version)",
    "documentNamespace": "https://langeundco.com/spdx/slate/\(version)/\(UUID().uuidString.lowercased())",
    "creationInfo": ["created": ISO8601DateFormatter().string(from: Date()), "creators": ["Tool: Slate-SBOM-Generator"]],
    "packages": packages,
]

let output = root.appendingPathComponent("build/Slate.spdx.json")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    .write(to: output, options: .atomic)
print(output.path)
