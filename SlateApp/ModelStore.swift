import Foundation
import Observation
import SlateCore

/// Owns model acquisition: catalog + custom-URL downloads into ~/Models with live
/// progress, post-download verification (exact remote size + GGUF magic), and
/// deletion. AppModel stays responsible for scanning/loading; it is notified via
/// `onModelsChanged` whenever the set of installed files changes.
@MainActor @Observable
final class ModelStore: NSObject {
    struct ActiveDownload: Identifiable {
        let id: String            // target file name
        let url: URL              // source, so a paused download can resume without re-fetching it
        /// Known size from the catalog / Hub file listing - the verification
        /// fallback when the server sends no Content-Length.
        var knownBytes: Int64? = nil
        var received: Int64 = 0
        var expected: Int64 = -1  // -1 until the response arrives
        var isPaused = false
        var progress: Double { expected > 0 ? Double(received) / Double(expected) : 0 }
    }

    private(set) var downloads: [String: ActiveDownload] = [:]
    private(set) var errors: [String: String] = [:]
    /// The secure default is offline. This gate covers Hub metadata as well as
    /// binary transfers, so merely opening the model browser is network-silent.
    private(set) var remoteDownloadsEnabled = false
    var onModelsChanged: (() -> Void)?

    // MARK: HuggingFace Hub browsing

    private(set) var searchResults: [HFHub.Repo] = []
    private(set) var searching = false
    private(set) var searchError: String?
    private(set) var repoFiles: [String: [HFHub.GGUFFile]] = [:]
    private(set) var loadingRepos: Set<String> = []

    private(set) var trending: [HFHub.Repo] = []
    private(set) var loadingTrending = false
    /// Why the last trending fetch showed nothing (network/HTTP/empty), so the UI
    /// can explain the blank list and offer Retry instead of failing silently.
    private(set) var trendingError: String?
    /// How many trending repos the UI shows; "Load more" reveals +10.
    private(set) var trendingVisible = 10
    var visibleTrending: [HFHub.Repo] { Array(trending.prefix(trendingVisible)) }
    var canLoadMoreTrending: Bool { trendingVisible < trending.count }

    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// resumeData blobs for interrupted downloads, keyed by target file name, so a
    /// multi-GB transfer resumes instead of restarting from zero.
    private var resumeData: [String: Data] = [:]
    /// Enough to re-attempt a failed or corrupted download from the UI ("Repair"):
    /// the source URL + known size. Set on every start(), kept through a failure,
    /// cleared on success or cancel.
    private var retryable: [String: RetryInfo] = [:]
    private struct RetryInfo { let url: URL; let knownBytes: Int64? }
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        // A descriptive User-Agent: the HuggingFace Hub increasingly rate-limits or
        // rejects requests carrying only the generic CFNetwork UA, which shows up as
        // an empty trending/search list. Identify the app (and version) explicitly.
        // (No Accept override — this session also downloads binary GGUFs; the Hub
        // returns JSON by default for /api/models.)
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Slate/\(version) (macOS; +https://slate-app.org)",
        ]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    var isDownloading: Bool { !downloads.isEmpty }

    func installedURL(for fileName: String) -> URL? {
        let url = DownloadCatalog.installDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func setRemoteDownloadsEnabled(_ enabled: Bool) {
        guard remoteDownloadsEnabled != enabled else { return }
        remoteDownloadsEnabled = enabled
        guard !enabled else { return }
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        downloads.removeAll()
        searchResults = []
        repoFiles = [:]
        trending = []
        searchError = nil
    }

    func download(_ item: CatalogModel) {
        guard requireNetwork(for: item.fileName) else { return }
        guard requireDiskSpace(bytes: item.bytes, fileName: item.fileName) else { return }
        guard let url = item.url else { errors[item.fileName] = "Invalid URL."; return }
        start(url: url, fileName: item.fileName, knownBytes: item.bytes)
    }

    /// Free-form HuggingFace (or any HTTPS) GGUF URL.
    func download(customURL raw: String) {
        guard requireNetwork(for: "custom") else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), Self.isSecureHTTPS(url),
              url.lastPathComponent.hasSuffix(".gguf") else {
            errors["custom"] = "Enter a direct https URL to a .gguf file."
            return
        }
        errors["custom"] = nil
        start(url: url, fileName: url.lastPathComponent)
    }

    /// Fetch the Hub's trending GGUF repos (once loaded; Retry re-runs after a
    /// failure). Never fails silently: a network/HTTP/empty result sets
    /// `trendingError` so the browser can explain the blank list and offer Retry.
    func loadTrending() async {
        guard remoteDownloadsEnabled, trending.isEmpty, !loadingTrending,
              let url = HFHub.trendingURL(limit: 50) else { return }
        loadingTrending = true
        trendingError = nil
        defer { loadingTrending = false }
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse else {
                trendingError = "Couldn't reach HuggingFace. Check your connection and retry."
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                trendingError = "HuggingFace returned an error (\(http.statusCode)). Try again shortly."
                return
            }
            let repos = HFHub.parseRepos(data)
            if repos.isEmpty {
                // Byte count disambiguates a genuinely empty Hub list (a few bytes)
                // from an unexpected non-array payload that parsed to nothing.
                trendingError = "No trending models right now (received \(data.count) bytes)."
            } else {
                trending = repos
            }
        } catch {
            trendingError = "Couldn't load trending models: \(error.localizedDescription)"
        }
    }

    func showMoreTrending() { trendingVisible = min(trendingVisible + 10, max(trending.count, 10)) }

    /// Search the Hub for GGUF repos (sorted by downloads).
    func searchHub(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remoteDownloadsEnabled else {
            searchError = "Remote model browsing is off. Enable Model & voice downloads in Settings → Network Access."
            return
        }
        guard !q.isEmpty, let url = HFHub.searchURL(query: q) else { return }
        searching = true; searchError = nil
        defer { searching = false }
        do {
            let (data, resp) = try await session.data(from: url)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                searchError = "HuggingFace returned an error - try again."
                return
            }
            searchResults = HFHub.parseRepos(data)
            if searchResults.isEmpty { searchError = "No GGUF repos found for “\(q)”." }
        } catch {
            searchError = "Search failed: \(error.localizedDescription)"
        }
    }

    /// Load a repo's GGUF file list (cached per repo for this session).
    func loadFiles(for repo: String) async {
        guard remoteDownloadsEnabled, repoFiles[repo] == nil, !loadingRepos.contains(repo),
              let url = HFHub.treeURL(repo: repo) else { return }
        loadingRepos.insert(repo)
        defer { loadingRepos.remove(repo) }
        do {
            let (data, _) = try await session.data(from: url)
            repoFiles[repo] = HFHub.ggufFiles(repo: repo, tree: HFHub.parseTree(data))
        } catch {
            repoFiles[repo] = []
        }
    }

    /// Download a Hub file through the verified pipeline (size + GGUF magic). For a
    /// vision (VLM) model, the multimodal projector ("mmproj") companion is fetched
    /// automatically into the same directory so the model can actually see images -
    /// otherwise the user downloads a chat model that silently ignores attachments.
    func download(_ file: HFHub.GGUFFile) {
        guard requireNetwork(for: file.fileName) else { return }
        guard requireDiskSpace(bytes: file.bytes, fileName: file.fileName) else { return }
        guard let url = file.downloadURL else { errors[file.fileName] = "Invalid URL."; return }
        start(url: url, fileName: file.fileName, knownBytes: file.bytes > 0 ? file.bytes : nil)
        if !file.isProjector, let projector = companionProjector(in: file.repo) {
            downloadCompanion(projector)
        }
    }

    /// The vision projector that pairs with a repo's chat models: the smallest
    /// mmproj in the repo listing (repos usually ship a single f16 projector).
    /// nil for text-only repos or when the file list has not been loaded.
    private func companionProjector(in repo: String) -> HFHub.GGUFFile? {
        repoFiles[repo]?.filter(\.isProjector).min { $0.bytes < $1.bytes }
    }

    /// Fetch a companion file (the mmproj) alongside its model, skipping it when it
    /// is already installed or already downloading. A missing companion never blocks
    /// the main model - it is best-effort.
    private func downloadCompanion(_ file: HFHub.GGUFFile) {
        guard installedURL(for: file.fileName) == nil, downloads[file.fileName] == nil,
              let url = file.downloadURL else { return }
        start(url: url, fileName: file.fileName, knownBytes: file.bytes > 0 ? file.bytes : nil)
    }

    /// Refuse a download that would not fit on the install volume (plus a safety
    /// margin). Unknown size (`bytes <= 0`) is allowed - verification catches a bad
    /// result later. Returns true if the download may proceed.
    private func requireDiskSpace(bytes: Int64, fileName: String) -> Bool {
        let dir = DownloadCatalog.installDirectory()
        guard let available = DiskSpace.availableBytes(at: dir) else { return true }
        guard DiskSpace.fits(requiredBytes: bytes, availableBytes: available) else {
            let need = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            errors[fileName] = "Not enough disk space: needs about \(need), \(have) free."
            return false
        }
        return true
    }

    private func start(url: URL, fileName: String, knownBytes: Int64? = nil) {
        guard remoteDownloadsEnabled else { errors[fileName] = Self.networkDisabledMessage; return }
        guard Self.isSecureHTTPS(url) else { errors[fileName] = "Only direct HTTPS model URLs are allowed."; return }
        guard let safeName = Self.safeGGUFFilename(fileName) else {
            errors[fileName] = "Unsafe model file name refused."
            return
        }
        guard safeName == fileName else { errors[fileName] = "Unsafe model file name refused."; return }
        guard downloads[fileName] == nil else { return }   // already running
        // Never overwrite an installed model (same file name from another repo  - 
        // possibly the ACTIVE model's weights). Delete first, explicitly.
        guard installedURL(for: fileName) == nil else {
            errors[fileName] = "“\(fileName)” is already installed - delete it first to re-download."
            return
        }
        errors[fileName] = nil
        retryable[fileName] = RetryInfo(url: url, knownBytes: knownBytes)
        downloads[fileName] = ActiveDownload(id: fileName, url: url, knownBytes: knownBytes)
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: fileName) {
            task = session.downloadTask(withResumeData: data)   // continue an interrupted transfer
        } else {
            task = session.downloadTask(with: url)
        }
        task.taskDescription = fileName
        tasks[fileName] = task
        task.resume()
    }

    /// Cancel for good: drop the task, the row and any resume blob.
    func cancel(_ fileName: String) {
        tasks[fileName]?.cancel()
        tasks[fileName] = nil
        downloads[fileName] = nil
        resumeData[fileName] = nil
        retryable[fileName] = nil
    }

    /// True when a failed / corrupted row can be re-downloaded from the UI.
    func canRepair(_ fileName: String) -> Bool { retryable[fileName] != nil }

    /// Clear a failed row the user has read (and its retry context).
    func dismissError(_ fileName: String) {
        errors[fileName] = nil
        retryable[fileName] = nil
    }

    /// Re-download a failed or corrupted file from scratch. A botched *resume* is
    /// what corrupts these, so we drop any stale partial + resume blob and start a
    /// clean transfer. No-op without a remembered source URL.
    func repair(_ fileName: String) {
        guard let info = retryable[fileName] else { return }
        guard remoteDownloadsEnabled else { errors[fileName] = Self.networkDisabledMessage; return }
        let staging = DownloadCatalog.installDirectory()
            .appendingPathComponent(fileName).appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: staging)
        resumeData[fileName] = nil          // force a fresh transfer, never a bad resume
        downloads[fileName] = nil
        tasks[fileName] = nil
        errors[fileName] = nil
        Self.forgetVerified(fileName)
        start(url: info.url, fileName: fileName, knownBytes: info.knownBytes)
    }

    /// Pause a running download but KEEP the row and its progress. URLSession
    /// hands back a resume blob we stash so resume() continues instead of
    /// restarting the multi-GB transfer. (The delegate's didCompleteWithError
    /// early-returns on the resulting cancellation, so the row is not cleared.)
    func pause(_ fileName: String) {
        guard let task = tasks[fileName], downloads[fileName]?.isPaused == false else { return }
        downloads[fileName]?.isPaused = true
        task.cancel(byProducingResumeData: { [weak self] data in
            guard let data else { return }
            MainActor.assumeIsolated { self?.resumeData[fileName] = data }
        })
        tasks[fileName] = nil
    }

    /// Resume a paused download from its resume blob, or restart from the URL if
    /// the server did not return one.
    func resume(_ fileName: String) {
        guard var dl = downloads[fileName], dl.isPaused else { return }
        guard remoteDownloadsEnabled else { errors[fileName] = Self.networkDisabledMessage; return }
        dl.isPaused = false
        downloads[fileName] = dl
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: fileName) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: dl.url)
        }
        task.taskDescription = fileName
        tasks[fileName] = task
        task.resume()
    }

    /// Move an installed model to the Trash - plus its mmproj, but ONLY when no
    /// other installed model pairs with the same projector (one f16 projector
    /// typically serves all quants of a VLM).
    func delete(_ entry: ModelEntry) {
        do {
            if let proj = ModelCatalog.mmproj(for: entry.url) {
                let others = ModelCatalog.scan(directories: ModelCatalog.defaultDirectories(),
                                               excluding: [ImageBundle.storeRoot])
                    .filter { $0.url != entry.url }
                let stillNeeded = others.contains { ModelCatalog.mmproj(for: $0.url) == proj }
                if !stillNeeded {
                    try? FileManager.default.trashItem(at: proj, resultingItemURL: nil)
                }
            }
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            onModelsChanged?()
        } catch {
            errors[entry.name] = "Could not delete: \(error.localizedDescription)"
        }
    }

    // MARK: verification

    /// Exact-size + magic check, then an ATOMIC install into ~/Models (stage in the
    /// destination directory, then rename) - a failed move can never destroy an
    /// existing model or leave a half-written .gguf behind. Any mismatch discards
    /// the file.
    fileprivate func finishDownload(temp: URL, response: URLResponse?, fileName: String) {
        let knownBytes = downloads[fileName]?.knownBytes
        defer { downloads[fileName] = nil; tasks[fileName] = nil; resumeData[fileName] = nil }
        let dest = DownloadCatalog.installDirectory().appendingPathComponent(fileName)
        let staging = dest.appendingPathExtension("partial")   // scan ignores non-.gguf
        do {
            guard Self.safeGGUFFilename(fileName) == fileName else {
                throw NSError(domain: "Slate", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Unsafe model file name refused."])
            }
            guard let finalURL = response?.url, Self.isSecureHTTPS(finalURL) else {
                throw NSError(domain: "Slate", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "The download redirected to an insecure URL."])
            }
            let received = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? -1
            if let http = response as? HTTPURLResponse {
                guard (200..<300).contains(http.statusCode) else {
                    throw NSError(domain: "Slate", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode)."])
                }
            }
            // Verify the finished file's size against every authoritative total we
            // have. The trap is a RESUMED (HTTP 206) transfer: URLSession stitches
            // the full file, but `response.expectedContentLength` then reports only
            // the REMAINING bytes, so a naive `received == expectedContentLength`
            // rejects (and deletes!) a perfectly complete file. Accept when
            // `received` matches ANY of: the 206 Content-Range total, the server
            // Content-Length, or the catalog/Hub known size. A genuine truncation
            // matches none of them and is still refused.
            let http = response as? HTTPURLResponse
            let reported = http.map(\.expectedContentLength).flatMap { $0 > 0 ? $0 : nil }
            let rangeTotal = DownloadCatalog.totalBytes(fromContentRange: http?.value(forHTTPHeaderField: "Content-Range"))
            let totals = [rangeTotal, reported, knownBytes].compactMap { $0 }.filter { $0 > 0 }
            guard !totals.isEmpty else {
                throw NSError(domain: "Slate", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "The server did not report a file size - the download cannot be verified."])
            }
            guard totals.contains(received) else {
                let shown = rangeTotal ?? knownBytes ?? reported ?? -1
                throw NSError(domain: "Slate", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Incomplete download (\(received) of \(shown) bytes)."])
            }
            guard DownloadCatalog.hasGGUFMagic(temp) else {
                throw NSError(domain: "Slate", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "File is not a GGUF model (bad magic)."])
            }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: temp, to: staging)   // may cross volumes (slow copy)
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: dest)  // same dir → atomic rename
            }
            // Ground truth for the launch self-heal + a clean retry record.
            Self.recordVerified(size: received, url: downloads[fileName]?.url, for: fileName)
            retryable[fileName] = nil
            onModelsChanged?()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: staging)
            errors[fileName] = error.localizedDescription
        }
    }

    private func requireNetwork(for key: String) -> Bool {
        guard remoteDownloadsEnabled else {
            errors[key] = Self.networkDisabledMessage
            return false
        }
        return true
    }

    private static let networkDisabledMessage = "Model downloads are blocked. Enable them in Settings → Network Access, or use a verified local file."

    nonisolated private static func isSecureHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false &&
            url.user == nil && url.password == nil
    }

    nonisolated private static func safeGGUFFilename(_ name: String) -> String? {
        guard name.hasSuffix(".gguf"), name != ".", name != "..",
              name.utf8.count <= 240,
              name.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) ||
                  (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
              }) else { return nil }
        return name
    }

    // MARK: launch self-heal (quarantine size-mismatched installs)

    nonisolated private static let verifiedKey = "ModelStore.verifiedFiles.v1"
    private struct VerifiedFile: Codable { let size: Int64; let url: String? }

    nonisolated private static func loadVerified() -> [String: VerifiedFile] {
        guard let data = UserDefaults.standard.data(forKey: verifiedKey),
              let map = try? JSONDecoder().decode([String: VerifiedFile].self, from: data) else { return [:] }
        return map
    }
    nonisolated private static func saveVerified(_ map: [String: VerifiedFile]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(map), forKey: verifiedKey)
    }
    /// Remember the exact verified byte size (+ source URL) of a completed download,
    /// so a later launch can detect a file that was truncated or corrupted.
    nonisolated static func recordVerified(size: Int64, url: URL?, for fileName: String) {
        var map = loadVerified()
        map[fileName] = VerifiedFile(size: size, url: url?.absoluteString)
        saveVerified(map)
    }
    nonisolated static func forgetVerified(_ fileName: String) {
        var map = loadVerified()
        guard map.removeValue(forKey: fileName) != nil else { return }
        saveVerified(map)
    }

    /// At launch: any installed .gguf whose on-disk size no longer matches its
    /// recorded verified size is corrupt (a botched resume, a truncating crash).
    /// Move it to the Trash and surface a Repair-able error so it can never load and
    /// crash mmap. Files with no verified record (hand-imported) are left untouched.
    func quarantineCorruptInstalls() {
        var map = Self.loadVerified()
        guard !map.isEmpty else { return }
        let dir = DownloadCatalog.installDirectory()
        var changed = false
        for (fileName, vf) in map {
            let url = dir.appendingPathComponent(fileName)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
            else { continue }   // not installed → nothing to verify
            guard size != vf.size else { continue }
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            errors[fileName] = "“\(fileName)” was corrupted (\(size) of \(vf.size) bytes) and moved to the Trash. Tap Repair to download it again."
            if let raw = vf.url, let src = URL(string: raw) {
                retryable[fileName] = RetryInfo(url: src, knownBytes: vf.size)
            }
            map[fileName] = nil
            changed = true
        }
        if changed { Self.saveVerified(map); onModelsChanged?() }
    }
}

// URLSession delegate - delegateQueue is .main, so hop is assumeIsolated-safe.
extension ModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { Self.isSecureHTTPS($0) ? request : nil })
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let name = downloadTask.taskDescription ?? ""
        MainActor.assumeIsolated {
            guard var d = downloads[name] else { return }
            d.received = totalBytesWritten
            d.expected = totalBytesExpectedToWrite
            downloads[name] = d
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let name = downloadTask.taskDescription ?? ""
        // The temp file is deleted when this callback returns - move it out first.
        let holding = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-dl-\(UUID().uuidString).gguf")
        try? FileManager.default.moveItem(at: location, to: holding)
        let response = downloadTask.response
        MainActor.assumeIsolated {
            finishDownload(temp: holding, response: response, fileName: name)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let name = task.taskDescription ?? ""
        // Capture resumeData (network drop / sleep) so the next start() continues
        // instead of restarting the multi-GB transfer from zero.
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        MainActor.assumeIsolated {
            if let data { resumeData[name] = data }
            downloads[name] = nil
            tasks[name] = nil
            errors[name] = data != nil ? "Download interrupted - tap Download to resume." : error.localizedDescription
        }
    }
}
