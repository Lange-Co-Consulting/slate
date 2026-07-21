import Foundation

/// Downloads an image-model bundle's files sequentially into its install dir,
/// reporting aggregate progress. Uses a URLSessionDownloadTask (streamed to disk)
/// so multi-GB files don't sit in memory. delegateQueue = .main → assumeIsolated.
@MainActor
final class ImageDownloader: NSObject, URLSessionDownloadDelegate {
    // Multi-GB transfers stall on the default 60s request timeout with no resume.
    // Wait for connectivity, allow long idle gaps, and a very long resource budget.
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300           // tolerate slow/paused servers
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }()
    private var bundle: ImageBundle?
    private var index = 0
    private var doneBytes: Int64 = 0
    private var attempts = 0                            // resume retries for the current file
    private let maxAttempts = 8
    private var activeTask: URLSessionDownloadTask?
    private var onProgress: ((Double) -> Void)?
    private var onDone: ((Error?) -> Void)?

    func start(_ b: ImageBundle, onProgress: @escaping (Double) -> Void, onDone: @escaping (Error?) -> Void) {
        guard b.files.allSatisfy({ Self.isSecureHTTPS($0.url) && Self.safeFileName($0.name) }) else {
            onDone(NSError(domain: "Slate", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Image bundle contains an unsafe download URL or file name."]))
            return
        }
        bundle = b; self.onProgress = onProgress; self.onDone = onDone; index = 0; doneBytes = 0; attempts = 0
        try? FileManager.default.createDirectory(at: b.installDir, withIntermediateDirectories: true)
        next()
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        reset()
    }

    private func next() {
        guard let b = bundle else { return }
        attempts = 0
        while index < b.files.count {
            let f = b.files[index]
            let dest = b.installDir.appendingPathComponent(f.name)
            if FileManager.default.fileExists(atPath: dest.path) { doneBytes += f.approxBytes; index += 1; continue }
            let task = session.downloadTask(with: f.url)
            task.taskDescription = f.name
            activeTask = task
            task.resume()
            return
        }
        onDone?(nil); reset()
    }
    private func reset() { activeTask = nil; bundle = nil; onProgress = nil; onDone = nil }

    nonisolated func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                                didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite _: Int64) {
        MainActor.assumeIsolated {
            guard let b = bundle else { return }
            onProgress?(min(1, Double(doneBytes + w) / Double(max(1, b.totalBytes))))
        }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        MainActor.assumeIsolated {
            guard let b = bundle, index < b.files.count else { return }
            let name = t.taskDescription ?? ""
            guard let file = b.files.first(where: { $0.name == name }) else {
                onDone?(NSError(domain: "Slate", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected image-model file."]))
                reset()
                return
            }
            let dest = b.installDir.appendingPathComponent(name)
            let staging = dest.appendingPathExtension("partial")
            do {
                guard let http = t.response as? HTTPURLResponse,
                      let finalURL = http.url,
                      (200..<300).contains(http.statusCode),
                      Self.isSecureHTTPS(finalURL) else {
                    throw NSError(domain: "Slate", code: 3, userInfo: [NSLocalizedDescriptionKey: "Image-model download used an insecure response."])
                }
                let expected = http.expectedContentLength
                let received = (try FileManager.default.attributesOfItem(atPath: loc.path)[.size] as? NSNumber)?.int64Value ?? -1
                guard expected > 0, received == expected else {
                    throw NSError(domain: "Slate", code: 4, userInfo: [NSLocalizedDescriptionKey: "Incomplete image-model download (\(received) of \(expected) bytes)."])
                }
                guard Self.safeFileName(file.name) else {
                    throw NSError(domain: "Slate", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unsafe image-model file name."])
                }
                guard !FileManager.default.fileExists(atPath: dest.path) else {
                    throw NSError(domain: "Slate", code: 6, userInfo: [NSLocalizedDescriptionKey: "Model file appeared during download; refusing to overwrite it."])
                }
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.moveItem(at: loc, to: staging)
                try FileManager.default.moveItem(at: staging, to: dest)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                onDone?(error); reset(); return
            }
            doneBytes += file.approxBytes
            activeTask = nil
            index += 1
            next()
        }
    }

    nonisolated func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError e: Error?) {
        guard let e else { return }   // success is handled in didFinishDownloadingTo
        MainActor.assumeIsolated {
            guard let b = bundle, index < b.files.count else { onDone?(e); reset(); return }
            // Transient drop → retry, resuming from where it stalled if possible.
            if attempts < maxAttempts {
                attempts += 1
                let resume = (e as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                let task = resume.map { session.downloadTask(withResumeData: $0) }
                    ?? session.downloadTask(with: b.files[index].url)
                task.taskDescription = b.files[index].name
                activeTask = task
                task.resume()
                return
            }
            onDone?(e); reset()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { Self.isSecureHTTPS($0) ? request : nil })
    }

    nonisolated private static func isSecureHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false &&
            url.user == nil && url.password == nil
    }

    nonisolated private static func safeFileName(_ name: String) -> Bool {
        guard name.utf8.count <= 240,
              (name.hasSuffix(".gguf") || name.hasSuffix(".safetensors")),
              name.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) ||
                  (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
              }) else { return false }
        return true
    }
}
