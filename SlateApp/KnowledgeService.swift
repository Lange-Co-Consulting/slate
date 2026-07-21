import Foundation
import NaturalLanguage
import PDFKit
import Vision
import AppKit
import ImageIO
import SlateCore

/// "Chat with your files" - 100% offline retrieval-augmented generation. Reads
/// text/PDF files, chunks + embeds them with Apple's on-device `NLEmbedding`
/// (no model download, fully local), and retrieves the most relevant excerpts
/// to ground a turn. Per-conversation; persisted so it survives relaunch.
@MainActor @Observable
final class KnowledgeService {
    nonisolated private static let maxInputBytes = 50 * 1_024 * 1_024
    nonisolated private static let maxIndexedCharacters = 1_000_000
    nonisolated private static let maxImagePixels = 40_000_000
    nonisolated private static let maxIndexBytes = 64 * 1_024 * 1_024
    /// Bounds for a single conversation's in-memory RAG index. Persisted JSON
    /// is also size-capped, but applying a batch must not temporarily build an
    /// unbounded index before it reaches the disk limit.
    nonisolated private static let maxIndexChunks = 6_000
    nonisolated private static let maxBatchCharacters = 4_000_000
    /// Chunk + its embedding + which file it came from.
    struct Chunk: Codable, Sendable { let file: String; let text: String; let vector: [Float] }
    struct Index: Codable, Sendable { var files: [String] = []; var chunks: [Chunk] = [] }
    /// A deliberately path-free result for the most recent local import. It lets
    /// the UI explain what Slate indexed without retaining the user's source
    /// locations after ingestion.
    struct ImportReport: Equatable, Sendable {
        let indexed: [String]
        let alreadyIndexed: [String]
        let unavailable: [String]

        var hasWarnings: Bool { !alreadyIndexed.isEmpty || !unavailable.isEmpty }
        var hasActivity: Bool { !indexed.isEmpty || !alreadyIndexed.isEmpty || !unavailable.isEmpty }

        var summary: String {
            var parts: [String] = []
            if !indexed.isEmpty { parts.append("\(indexed.count) indexed") }
            if !alreadyIndexed.isEmpty { parts.append("\(alreadyIndexed.count) already added") }
            if !unavailable.isEmpty { parts.append("\(unavailable.count) unavailable") }
            return parts.isEmpty ? "No supported files found" : parts.joined(separator: " · ")
        }
    }
    struct SearchHit: Identifiable, Sendable {
        let id: String
        let conversationID: String
        let file: String
        let text: String
        let score: Int
    }

    /// In-memory per-conversation indexes (loaded lazily from disk).
    private var indexes: [String: Index] = [:]
    /// Conversations currently indexing (for a spinner).
    private(set) var indexing: Set<String> = []
    /// Latest import outcome, kept in memory only. Source paths never enter this
    /// dictionary or the persisted index.
    private var importReports: [String: ImportReport] = [:]
    /// Invalidates in-flight imports when a user changes or clears the sources.
    private var importTokens: [String: UUID] = [:]

    nonisolated static let supportedExtensions: Set<String> = [
        "txt", "md", "markdown", "swift", "py", "js", "ts", "tsx", "jsx", "json",
        "yaml", "yml", "csv", "html", "css", "rs", "go", "java", "kt", "c", "cpp",
        "h", "sh", "rb", "php", "sql", "xml", "log", "text", "pdf",
        "docx", "xlsx", "pptx", "png", "jpg", "jpeg", "heic", "tif", "tiff", "bmp",
    ]

    func fileCount(for id: String) -> Int { index(for: id).files.count }
    func fileNames(for id: String) -> [String] {
        index(for: id).files.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    func hasKnowledge(for id: String) -> Bool { !index(for: id).chunks.isEmpty }
    func lastImport(for id: String) -> ImportReport? { importReports[id] }

    /// Index dropped/picked files or folders into a conversation's knowledge.
    func add(_ urls: [URL], to id: String) {
        guard !urls.isEmpty else { return }
        let token = UUID()
        importTokens[id] = token
        indexing.insert(id)
        Task {
            let files = Self.expand(urls)
            var index = index(for: id)
            // Re-attaching a file must not silently duplicate its chunks and bias
            // retrieval toward that source. We retain only names, not selected
            // absolute paths, so the persisted local index stays private.
            var knownNames = Set(index.files)
            let additions = files.filter { knownNames.insert($0.lastPathComponent).inserted }
            let alreadyIndexed = files
                .filter { !additions.contains($0) }
                .map(\.lastPathComponent)
            guard !additions.isEmpty else {
                if importTokens[id] == token {
                    importReports[id] = ImportReport(indexed: [],
                                                     alreadyIndexed: alreadyIndexed,
                                                     unavailable: [])
                    indexing.remove(id)
                }
                return
            }
            let remainingChunks = max(0, Self.maxIndexChunks - index.chunks.count)
            guard remainingChunks > 0 else {
                if importTokens[id] == token {
                    importReports[id] = ImportReport(indexed: [], alreadyIndexed: alreadyIndexed,
                                                     unavailable: additions.map(\.lastPathComponent))
                    indexing.remove(id)
                }
                return
            }
            let embedded = await Task.detached(priority: .userInitiated) {
                Self.embedFiles(additions, maxChunks: remainingChunks)
            }.value
            guard importTokens[id] == token else { return }
            let indexedNames = Set(embedded.chunks.map(\.file))
            index.files.append(contentsOf: additions.map(\.lastPathComponent).filter(indexedNames.contains))
            index.chunks.append(contentsOf: embedded.chunks)
            indexes[id] = index
            save(id: id)
            importReports[id] = ImportReport(indexed: additions
                                                .map(\.lastPathComponent)
                                                .filter(indexedNames.contains),
                                             alreadyIndexed: alreadyIndexed,
                                             unavailable: embedded.unavailable)
            indexing.remove(id)
        }
    }

    /// Removes only Slate's local index entries. The original file is untouched.
    func remove(fileNamed name: String, from id: String) {
        importTokens[id] = UUID()
        indexing.remove(id)
        importReports[id] = nil
        var index = index(for: id)
        index.files.removeAll { $0 == name }
        index.chunks.removeAll { $0.file == name }
        indexes[id] = index
        save(id: id)
    }

    /// Remove all knowledge for a conversation.
    func clear(for id: String) {
        importTokens[id] = UUID()
        indexing.remove(id)
        importReports[id] = nil
        indexes[id] = Index()
        try? FileManager.default.removeItem(at: Self.url(for: id))
    }

    /// Retrieve the top-k grounding excerpts for a query (empty if no knowledge).
    func retrieve(_ query: String, for id: String, k: Int = 4) -> [RAGPrompt.Source] {
        let idx = index(for: id)
        guard !idx.chunks.isEmpty, let qv = Self.embed(query) else { return [] }
        let scored = idx.chunks.enumerated()
            .map { (i, c) in (i, VectorIndex.cosine(qv, c.vector)) }
            .sorted { $0.1 > $1.1 }
            .prefix(k)
        return scored.enumerated().map { (n, hit) in
            RAGPrompt.Source(ref: n + 1, file: idx.chunks[hit.0].file, text: idx.chunks[hit.0].text)
        }
    }

    func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        var all = indexes
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.dir,
                                                                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            var remainingBytes = Self.maxIndexBytes
            for file in files.prefix(500) where file.pathExtension == "json" {
                let id = file.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: id) != nil else { continue }
                guard all[id] == nil,
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true,
                      let size = values.fileSize, size >= 0, size <= remainingBytes else { continue }
                if let data = try? PrivateStorage.read(from: file, maxBytes: size),
                   let index = try? JSONDecoder().decode(Index.self, from: data) {
                    all[id] = index
                    remainingBytes -= size
                    if remainingBytes == 0 { break }
                }
            }
        }
        return all.flatMap { id, index in
            index.chunks.compactMap { chunk -> SearchHit? in
                guard let score = LocalSearch.score(query: query, in: chunk.file + " " + chunk.text) else { return nil }
                return SearchHit(id: id + ":" + chunk.file + ":" + String(chunk.text.hashValue),
                                 conversationID: id, file: chunk.file, text: chunk.text, score: score)
            }
        }
        .sorted { $0.score > $1.score }
        .prefix(limit).map { $0 }
    }

    // MARK: embedding

    /// Apple on-device sentence embedding. English model (best-supported); returns
    /// nil if unavailable, so RAG degrades gracefully to a normal turn.
    nonisolated static func embed(_ text: String) -> [Float]? {
        guard let e = NLEmbedding.sentenceEmbedding(for: .english),
              let v = e.vector(for: text) else { return nil }
        return v.map { Float($0) }
    }

    private struct EmbeddedFiles: Sendable {
        var chunks: [Chunk] = []
        var unavailable: [String] = []
    }

    nonisolated private static func embedFiles(_ files: [URL], maxChunks: Int) -> EmbeddedFiles {
        var result = EmbeddedFiles()
        var usedCharacters = 0
        for url in files {
            guard result.chunks.count < maxChunks, usedCharacters < maxBatchCharacters else {
                result.unavailable.append(url.lastPathComponent)
                continue
            }
            guard var text = readText(url) else {
                result.unavailable.append(url.lastPathComponent)
                continue
            }
            let remainingCharacters = maxBatchCharacters - usedCharacters
            if text.count > remainingCharacters { text = String(text.prefix(remainingCharacters)) }
            usedCharacters += text.count
            let oldCount = result.chunks.count
            for chunk in TextChunker.chunk(text, maxWords: 220, overlap: 40) {
                guard result.chunks.count < maxChunks else { break }
                guard let v = embed(chunk) else { continue }
                result.chunks.append(Chunk(file: url.lastPathComponent, text: chunk, vector: v))
            }
            if result.chunks.count == oldCount { result.unavailable.append(url.lastPathComponent) }
        }
        return result
    }

    nonisolated private static func readText(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= maxInputBytes else { return nil }
        let ext = url.pathExtension.lowercased()
        if ["docx", "xlsx", "pptx"].contains(ext) {
            return OfficeTextExtractor.text(from: url)
        }
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { return nil }
            let embedded = document.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if embedded.count >= 40 { return String(embedded.prefix(maxIndexedCharacters)) }
            var pages: [String] = []
            for index in 0..<min(document.pageCount, 100) {
                guard let page = document.page(at: index),
                      let image = page.thumbnail(of: NSSize(width: 1_800, height: 2_400), for: .mediaBox)
                        .cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let text = recognizeText(image), !text.isEmpty else { continue }
                pages.append(text)
            }
            return pages.isEmpty ? nil : String(pages.joined(separator: "\n\n").prefix(maxIndexedCharacters))
        }
        if ["png", "jpg", "jpeg", "heic", "tif", "tiff", "bmp"].contains(ext) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= maxImagePixels / height,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4_096,
                    kCGImageSourceShouldCacheImmediately: false,
                  ] as CFDictionary) else { return nil }
            return recognizeText(image)
        }
        return (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(maxIndexedCharacters)) }
    }

    nonisolated private static func recognizeText(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["de-DE", "en-US", "fr-FR", "es-ES"]
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Expand folders to their supported files (one level deep is enough for v1;
    /// enumerator walks the whole tree, capped to keep indexing snappy).
    nonisolated private static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let en = fm.enumerator(at: url,
                                       includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = en?.nextObject() as? URL, files.count < 500 {
                    let values = try? f.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values?.isSymbolicLink == true { en?.skipDescendants(); continue }
                    if values?.isRegularFile == true, supportedExtensions.contains(f.pathExtension.lowercased()) {
                        files.append(f)
                    }
                }
            } else if (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile) == true,
                      (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      supportedExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files
    }

    // MARK: persistence

    private func index(for id: String) -> Index {
        if let i = indexes[id] { return i }
        let loaded = (try? PrivateStorage.read(from: Self.url(for: id), maxBytes: Self.maxIndexBytes))
            .flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index()
        indexes[id] = loaded
        return loaded
    }

    private func save(id: String) {
        guard let idx = indexes[id], let data = try? JSONEncoder().encode(idx),
              data.count <= Self.maxIndexBytes else { return }
        try? PrivateStorage.write(data, to: Self.url(for: id))
    }

    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Slate/knowledge", isDirectory: true)
    }
    private static func url(for id: String) -> URL {
        let safeID = UUID(uuidString: id)?.uuidString.lowercased() ?? "invalid"
        return dir.appendingPathComponent("\(safeID).json")
    }
}
