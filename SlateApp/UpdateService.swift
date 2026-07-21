import Foundation
import AppKit
import SlateCore

/// Native in-app updater. Fetches a small JSON manifest from a feed URL the
/// operator hosts, compares it to the running build, and - when newer - surfaces
/// an update pill. Clicking it downloads the signed DMG and installs it in place
/// (mount → verify signature → replace /Applications/Slate.app → relaunch), with
/// a safe fallback to revealing the DMG in Finder if any step fails.
///
/// The updater is deliberately fail-closed: only an HTTPS manifest signed by a
/// key pinned in the app, plus a hash-verified DMG from the same signed payload,
/// may reach the installer. Dev/self-signed builds never self-update.
@MainActor @Observable
final class UpdateService {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case downloading(Double)     // 0…1
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle

    let currentVersion: String
    let currentBuild: Int

    private let settings: AppSettings
    private let session: URLSession
    private var lastAutoCheck: Date?

    init(settings: AppSettings) {
        self.settings = settings
        self.session = LockedDownURLSession.make()
        let info = Bundle.main.infoDictionary
        currentVersion = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        currentBuild = Int((info?["CFBundleVersion"] as? String) ?? "0") ?? 0
    }

    private var feedURL: URL? {
        let raw = settings.updateFeedURL?.trimmingCharacters(in: .whitespaces)
        let bundled = (Bundle.main.object(forInfoDictionaryKey: "SlateUpdateFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let s = raw?.isEmpty == false ? raw! : (bundled ?? "")
        guard let url = URL(string: s), Self.isSecureEndpoint(url) else { return nil }
        return url
    }

    private static func isSecureEndpoint(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false &&
            url.user == nil && url.password == nil
    }

    private var updatePublicKey: String? {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SlateUpdatePublicKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    /// True when the pill should be visible.
    var hasUpdate: Bool {
        switch state {
        case .available, .downloading, .installing: return true
        default: return false
        }
    }

    var availableManifest: UpdateManifest? {
        if case let .available(m) = state { return m }
        return nil
    }

    /// Launch-time check: only if enabled, a feed is set, and not checked in the
    /// last 6 hours. Never disturbs the UI when there is nothing to report.
    func checkOnLaunch() {
        guard !settings.silentModeEnabled, settings.autoCheckUpdates,
              feedURL != nil, updatePublicKey != nil else { return }
        if let last = lastAutoCheck, Date().timeIntervalSince(last) < 6 * 3600 { return }
        Task { await check(manual: false) }
    }

    /// Fetch the manifest and compare. `manual` surfaces up-to-date / error states
    /// (a launch check stays silent on "already current").
    func check(manual: Bool) async {
        guard !settings.silentModeEnabled else {
            if manual { state = .failed("Silent Mode blocks update checks. Turn it off in Settings → Network Access.") }
            return
        }
        guard let url = feedURL else {
            if manual { state = .failed("Set an HTTPS update feed URL.") }
            return
        }
        guard let key = updatePublicKey else {
            if manual { state = .failed("This build has no pinned update verification key, so self-updates are disabled.") }
            return
        }
        lastAutoCheck = Date()
        state = .checking
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await session.data(for: req)
            guard !settings.silentModeEnabled else { state = .idle; return }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw UpdateError.badResponse
            }
            guard let finalURL = resp.url, Self.isSecureEndpoint(finalURL), data.count <= 256_000 else {
                throw UpdateError.badResponse
            }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            guard manifest.isValidSignature(publicKeyBase64: key) else {
                throw UpdateError.invalidManifestSignature
            }
            if manifest.isNewer(thanVersion: currentVersion, build: currentBuild) {
                state = .available(manifest)
            } else {
                state = manual ? .upToDate : .idle
            }
        } catch {
            if settings.silentModeEnabled { state = .idle; return }
            state = manual ? .failed("Couldn't check for updates: \(error.localizedDescription)") : .idle
        }
    }

    func dismiss() { state = .idle }

    /// Download the update DMG and install it in place, then relaunch. Any
    /// failure falls back to revealing the downloaded DMG in Finder.
    func downloadAndInstall() {
        guard !settings.silentModeEnabled, case let .available(manifest) = state,
              let url = URL(string: manifest.dmgURL), manifest.hasSecureURL else { return }
        state = .downloading(0)
        Task {
            do {
                let dmg = try await download(url, expectedSHA256: manifest.sha256)
                guard !settings.silentModeEnabled else { state = .idle; return }
                state = .installing
                try await installInPlace(dmg: dmg)
                relaunch()   // does not return - replaces the running app
            } catch {
                if settings.silentModeEnabled { state = .idle; return }
                // Safety net: put the DMG where the user can finish manually.
                if let saved = try? revealDownloaded() {
                    state = .failed("Automatic install failed - the update was saved to \(saved.lastPathComponent) in Downloads. Open it and drag Slate to Applications.")
                } else {
                    state = .failed("Update failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: download

    private var downloadedDMG: URL?

    func enterSilentMode() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        state = .idle
    }

    private func download(_ url: URL, expectedSHA256: String) async throws -> URL {
        guard !settings.silentModeEnabled else { throw URLError(.cancelled) }
        guard Self.isSecureEndpoint(url) else { throw UpdateError.insecureURL }
        let (tmp, resp) = try await session.download(for: URLRequest(url: url))
        guard !settings.silentModeEnabled else {
            try? FileManager.default.removeItem(at: tmp)
            throw URLError(.cancelled)
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = resp.url, Self.isSecureEndpoint(finalURL) else {
            throw UpdateError.badResponse
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Slate-update-\(UUID().uuidString).dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        guard try FileIntegrity.sha256(ofFile: dest) == expectedSHA256.lowercased() else {
            try? FileManager.default.removeItem(at: dest)
            throw UpdateError.checksumMismatch
        }
        downloadedDMG = dest
        state = .downloading(1)
        return dest
    }

    private func revealDownloaded() throws -> URL? {
        guard let dmg = downloadedDMG else { return nil }
        let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let dest = downloads.appendingPathComponent("Slate-Update.dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: dmg, to: dest)
        NSWorkspace.shared.activateFileViewerSelecting([dest])
        return dest
    }

    // MARK: in-place install

    private func installInPlace(dmg: URL) async throws {
        let mount = try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-mountrandom", "/private/tmp"])
        // hdiutil prints the mount point as the last whitespace-separated token.
        guard let mountPoint = mount.split(separator: "\n").last?
            .split(separator: "\t").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
              FileManager.default.fileExists(atPath: mountPoint + "/Slate.app") else {
            throw UpdateError.mountFailed
        }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint, "-force"]) }

        let newApp = mountPoint + "/Slate.app"
        // Verify the downloaded app has a valid, intact signature before trusting it.
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp])
        // A Developer ID designated requirement identifies the actual signing
        // certificate/team; matching only the display `Authority=` string does not.
        try assertSameDesignatedRequirement(newApp: newApp)

        let installed = "/Applications/Slate.app"
        // rm+cp: unlinks the old inode so replacing the running app is safe.
        _ = try? run("/bin/rm", ["-rf", installed])
        _ = try run("/bin/cp", ["-R", newApp, installed])
    }

    private func assertSameDesignatedRequirement(newApp: String) throws {
        func requirement(_ path: String) -> String? {
            guard let out = try? run("/usr/bin/codesign", ["-dr", "-", path], mergeStderr: true) else { return nil }
            return out.split(separator: "\n").first { $0.contains("designated =>") }.map(String.init)
        }
        func developerIDTeam(_ path: String) -> String? {
            guard let out = try? run("/usr/bin/codesign", ["-dvv", path], mergeStderr: true) else { return nil }
            guard out.contains("Authority=Developer ID Application:"),
                  let teamLine = out.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }),
                  let team = teamLine.split(separator: "=", maxSplits: 1).last.map(String.init),
                  !team.isEmpty, team != "not set" else { return nil }
            return team
        }
        guard let running = Bundle.main.bundlePath as String?,
              let currentRequirement = requirement(running), let newRequirement = requirement(newApp),
              let currentTeam = developerIDTeam(running), let newTeam = developerIDTeam(newApp),
              currentRequirement == newRequirement, currentTeam == newTeam else {
            throw UpdateError.signatureMismatch
        }
    }

    private func relaunch() {
        let path = "/Applications/Slate.app"
        let helper = "sleep 1; open \(path.replacingOccurrences(of: " ", with: "\\ "))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", helper]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: shell

    @discardableResult
    private func run(_ launch: String, _ args: [String], mergeStderr: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        try p.run()
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: timeout)
        defer { timeout.cancel() }
        var data = Data()
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 1 * 1_024 * 1_024 {
                if p.isRunning { p.terminate() }
                throw UpdateError.commandFailed(launch, -1)
            }
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.commandFailed(launch, p.terminationStatus) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    enum UpdateError: LocalizedError {
        case badResponse, mountFailed, signatureMismatch, invalidManifestSignature, checksumMismatch, insecureURL, commandFailed(String, Int32)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "the server response was invalid"
            case .mountFailed: return "the update image couldn't be opened"
            case .signatureMismatch: return "the update wasn't signed by the same developer"
            case .invalidManifestSignature: return "the update manifest signature was invalid"
            case .checksumMismatch: return "the downloaded update checksum did not match the signed manifest"
            case .insecureURL: return "updates must use HTTPS"
            case .commandFailed(let c, let s): return "\(NSString(string: c).lastPathComponent) failed (\(s))"
            }
        }
    }
}
