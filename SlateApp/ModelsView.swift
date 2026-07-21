import SwiftUI
import SlateUI
import SlateCore

/// In-app model manager: install curated models (or any HF GGUF URL) with live
/// progress and verified integrity, see RAM fit at a glance, delete installed ones.
struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var customURL = ""
    @State private var query = ""
    @State private var expandedRepos: Set<String> = []
    @State private var pendingImageDownload: ImageBundle?
    @State private var pendingCatalogDownload: CatalogModel?
    @State private var pendingHubDownload: HFHub.GGUFFile?
    @State private var pendingCustomDownload: String?
    @State private var tab: BrowseTab = .installed
    enum BrowseTab: String, CaseIterable, Identifiable {
        case installed = "Installed", browse = "Browse", image = "Image"
        var id: String { rawValue }
    }

    /// RAM used for fit guidance: the hardware profile the user set (so they can
    /// plan / override), else this Mac's actual physical memory.
    private var ram: UInt64 {
        let gb = model.settings.hwRAMGB
        return gb > 0 ? UInt64(gb) * 1_073_741_824 : ProcessInfo.processInfo.physicalMemory
    }
    private var catalogNames: Set<String> { Set(DownloadCatalog.models.map(\.fileName)) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Models", system: "cpu") { dismiss() }

            Picker("View", selection: $tab) {
                ForEach(BrowseTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)

            List {
                activeDownloadsSection   // stays visible from any tab while transfers run
                switch tab {
                case .installed:
                    Section("Installed") {
                        if model.models.isEmpty {
                            Text("No models yet - switch to Browse to get one.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("\(model.models.count) model\(model.models.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: model.models.reduce(0) { $0 + $1.bytes }, countStyle: .file))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        ForEach(model.models) { m in installedRow(m) }
                    }
                case .browse:
                    if !model.modelStore.remoteDownloadsEnabled {
                        Section("Offline mode") {
                            Label("Remote model browsing is off", systemImage: "network.slash")
                                .font(.callout.weight(.semibold))
                            Text("Slate is currently network-silent. Choose a verified local GGUF from the main window’s model menu, or enable Model & voice downloads in Settings → Network Access.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        searchSection
                        Section("Recommended") {
                            ForEach(DownloadCatalog.models) { item in catalogRow(item) }
                        }
                        trendingSection
                        customDownloadSection
                    }
                case .image:
                    imageModelsSection
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            // Keyed on the network gate: if the sheet first appeared while remote
            // downloads were off, loadTrending() returned early — re-run it the
            // moment the user enables them, instead of showing a permanent blank.
            .task(id: model.modelStore.remoteDownloadsEnabled) { await model.modelStore.loadTrending() }
            .onAppear { if model.models.isEmpty { tab = .browse } }
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 460,
               idealHeight: tab == .installed ? 500 : 600)
        .confirmationDialog("Review model license", isPresented: Binding(
            get: { pendingImageDownload != nil || pendingCatalogDownload != nil
                || pendingHubDownload != nil || pendingCustomDownload != nil },
            set: { if !$0 {
                pendingImageDownload = nil; pendingCatalogDownload = nil
                pendingHubDownload = nil; pendingCustomDownload = nil
            } })) {
            if let item = pendingImageDownload {
                Link("Open model card", destination: item.modelCardURL)
                Link("Open \(item.licenseName) license", destination: item.licenseURL)
                Button("I reviewed the terms - download") {
                    model.downloadImageBundle(item); pendingImageDownload = nil
                }
            } else if let item = pendingCatalogDownload {
                if let url = item.modelCardURL { Link("Open model card", destination: url) }
                if let url = item.licenseURL { Link("Open \(item.licenseName) license", destination: url) }
                Button("I reviewed the terms - download") {
                    model.modelStore.download(item); pendingCatalogDownload = nil
                }
            } else if let item = pendingHubDownload {
                if let url = URL(string: "https://huggingface.co/\(item.repo)") {
                    Link("Open provider model card & license", destination: url)
                }
                Button("I reviewed the provider terms - download") {
                    model.modelStore.download(item); pendingHubDownload = nil
                }
            } else if let url = pendingCustomDownload {
                Button("I am responsible for this file's terms - download") {
                    model.modelStore.download(customURL: url); pendingCustomDownload = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let license = pendingImageDownload?.licenseNote
                ?? pendingCatalogDownload.map { "\($0.licenseName) model. Slate does not grant usage or redistribution rights; review the provider terms before downloading." }
                ?? "This is a provider-hosted model, not part of Slate. Its model card and licence govern use; Slate grants no model rights."
            Text(license + (pendingFitWarning.map { "\n\n" + $0 } ?? ""))
        }
    }

    /// A RAM warning for the model in the confirm dialog - warn, never block.
    private var pendingFitWarning: String? {
        let bytes = pendingCatalogDownload?.bytes ?? pendingImageDownload?.totalBytes
        guard let bytes else { return nil }
        let ramStr = ByteCountFormatter.string(fromByteCount: Int64(ram), countStyle: .memory)
        switch ModelRAMFit.evaluate(fileBytes: bytes, physicalRAM: ram) {
        case .comfortable: return nil
        case .tight:  return "⚠︎ This is a tight fit for your \(ramStr) - it may run slowly and starve other apps."
        case .tooBig: return "⚠︎ This is larger than your \(ramStr) - it will likely run out of memory. You can still download it."
        }
    }

    // MARK: Image models

    private var imageModelsSection: some View {
        Section {
            ForEach(ImageBundle.all) { imageRow($0) }
        } header: {
            Label("Image models", systemImage: "photo.artframe")
        }
    }

    private func imageRow(_ b: ImageBundle) -> some View {
        let installed = b.isInstalled
        let downloading = model.imageDownloadID == b.id
        return HStack(spacing: 10) {
            Image(systemName: "photo.artframe").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.name).font(.callout)
                Text(b.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if downloading {
                ProgressView(value: model.imageDownloadProgress).progressViewStyle(.circular).controlSize(.small)
                Text("\(Int(model.imageDownloadProgress * 100))%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            } else if installed {
                Text("Installed").font(.caption2).foregroundStyle(.secondary)
                Button(role: .destructive) { model.deleteImageModel(b) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete")
                    .accessibilityLabel("Delete \(b.name)")
                    .accessibilityHint("Moves this downloaded image model to the Trash")
            } else {
                Button { pendingImageDownload = b } label: {
                    Label(ByteCountFormatter.string(fromByteCount: b.totalBytes, countStyle: .file),
                          systemImage: "arrow.down.circle").font(.caption)
                }
                .buttonStyle(ActionGlassButtonStyle(prominent: true)).controlSize(.small)
                .disabled(model.imageDownloadID != nil)
                .accessibilityLabel("Download \(b.name), \(ByteCountFormatter.string(fromByteCount: b.totalBytes, countStyle: .file))")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    // MARK: Trending

    /// The Hub's trending GGUF models right now - 10 at a time, Load more for the rest.
    private var trendingSection: some View {
        Section {
            if model.modelStore.loadingTrending && model.modelStore.trending.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading trending models…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let err = model.modelStore.trendingError, model.modelStore.trending.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(err, systemImage: "wifi.exclamationmark")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { await model.modelStore.loadTrending() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise").font(.callout)
                    }
                    .buttonStyle(ActionGlassButtonStyle()).controlSize(.small)
                    .disabled(model.modelStore.loadingTrending)
                }
                .padding(.vertical, 2)
            }
            ForEach(model.modelStore.visibleTrending) { repo in
                hubRepoRow(repo)
            }
            if model.modelStore.canLoadMoreTrending {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { model.modelStore.showMoreTrending() }
                } label: {
                    Label("Load more", systemImage: "chevron.down")
                        .font(.callout).frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionGlassButtonStyle()).controlSize(.small)
            }
        } header: {
            Label("Trending on HuggingFace", systemImage: "flame")
        }
    }

    /// Shared expandable repo row (trending + search results). A custom disclosure
    /// (no leading outline chevron) keeps the list reading as a clean browser:
    /// dimmed org prefix + prominent model name on the left, fixed-width stat
    /// rails on the right so the flame/download columns line up across every row.
    @ViewBuilder
    private func hubRepoRow(_ repo: HFHub.Repo) -> some View {
        let expanded = expandedRepos.contains(repo.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { toggleRepo(repo.id) }
            } label: {
                HStack(spacing: 10) {
                    repoTitle(repo.id)
                    Spacer(minLength: 8)
                    hubStat(repo.trendingScore.flatMap { $0 > 0 ? "\($0)" : nil },
                            system: "flame.fill", help: "HuggingFace trending score")
                    hubStat(repo.downloads.map(Self.compact),
                            system: "arrow.down.circle", help: "Downloads on HuggingFace")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(repo.id)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Collapses the available files" : "Shows available GGUF files")

            if expanded {
                repoFileRows(repo.id)
                    .padding(.leading, 6).padding(.top, 3)
            }
        }
        .padding(.vertical, 2)
    }

    /// `org/name` with the org prefix dimmed so the model name is what reads.
    /// The name keeps layout priority so tail-truncation eats the org first.
    private func repoTitle(_ id: String) -> some View {
        let slash = id.firstIndex(of: "/")
        let org = slash.map { String(id[..<$0]) + "/" }
        let name = slash.map { String(id[id.index(after: $0)...]) } ?? id
        return HStack(spacing: 0) {
            if let org {
                Text(org).foregroundStyle(.tertiary).lineLimit(1)
            }
            Text(name).foregroundStyle(.primary).fontWeight(.medium)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
        }
        .font(.callout)
    }

    /// One right-aligned stat cell. Fixed width + monospaced digits keep the
    /// columns as clean vertical rails even when a value is absent.
    private func hubStat(_ value: String?, system: String, help: String) -> some View {
        HStack(spacing: 3) {
            if let value {
                Image(systemName: system).font(.system(size: 9, weight: .medium))
                Text(value).font(.caption2.monospacedDigit())
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 52, alignment: .trailing)
        .help(value == nil ? "" : help)
    }

    // MARK: HuggingFace search

    private var customDownloadSection: some View {
        Section("Custom URL") {
            HStack(spacing: 8) {
                TextField("https://huggingface.co/…/resolve/main/model.gguf", text: $customURL)
                    .textFieldStyle(.roundedBorder).font(.callout)
                Button("Download") { pendingCustomDownload = customURL }
                    .buttonStyle(ActionGlassButtonStyle(prominent: true))
                    .disabled(customURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let err = model.modelStore.errors["custom"] {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Text("Direct HTTPS link to a .gguf file. Slate requires a complete response and a valid GGUF header before it appears in the sidebar.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Live Hub search: any GGUF repo → expand → every quant with size + RAM fit
    /// → one-click verified download.
    private var searchSection: some View {
        Section("Search HuggingFace") {
            HStack(spacing: 8) {
                TextField("Search the Hub (e.g. “qwen3 coder”, “mistral german”)…", text: $query)
                    .textFieldStyle(.roundedBorder).font(.callout)
                    .onSubmit { Task { await model.modelStore.searchHub(query) } }
                Button {
                    Task { await model.modelStore.searchHub(query) }
                } label: {
                    if model.modelStore.searching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Search")
                    }
                }
                .buttonStyle(ActionGlassButtonStyle(prominent: true))
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || model.modelStore.searching)
            }
            if let err = model.modelStore.searchError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            ForEach(model.modelStore.searchResults) { repo in
                hubRepoRow(repo)
            }
        }
    }

    @ViewBuilder
    private func repoFileRows(_ repo: String) -> some View {
        if let files = model.modelStore.repoFiles[repo] {
            if files.isEmpty {
                Text("No GGUF files in this repo.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(files) { f in hubFileRow(f) }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading files…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func hubFileRow(_ f: HFHub.GGUFFile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(f.fileName).font(.callout).lineLimit(1).truncationMode(.middle)
                if f.isProjector {
                    Text("Vision projector · downloads automatically with the model").font(.caption2).foregroundStyle(.secondary)
                }
                if let err = model.modelStore.errors[f.fileName] {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
            if f.bytes > 0 {
                Text(ByteCountFormatter.string(fromByteCount: f.bytes, countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                if !f.isProjector { fitBadge(bytes: f.bytes) }
            }
            if model.modelStore.installedURL(for: f.fileName) != nil {
                Label("Installed", systemImage: "checkmark")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let dl = model.modelStore.downloads[f.fileName] {
                downloadProgress(dl, name: f.fileName)
            } else {
                Button("Download") { pendingHubDownload = f }
                    .buttonStyle(ActionGlassButtonStyle(prominent: true)).controlSize(.small)
                    .accessibilityLabel("Download \(f.fileName)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private func toggleRepo(_ repo: String) {
        if expandedRepos.contains(repo) {
            expandedRepos.remove(repo)
        } else {
            expandedRepos.insert(repo)
            Task { await model.modelStore.loadFiles(for: repo) }
        }
    }

    private static func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
        : n >= 1_000 ? String(format: "%.0fk", Double(n) / 1_000) : "\(n)"
    }

    // MARK: active downloads (custom/Hub transfers live here; catalog rows inline too)

    @ViewBuilder
    private var activeDownloadsSection: some View {
        let extraErrors = model.modelStore.errors.filter {
            $0.key != "custom" && !catalogNames.contains($0.key)
                && model.modelStore.downloads[$0.key] == nil
                && model.modelStore.installedURL(for: $0.key) == nil
        }
        if !model.modelStore.downloads.isEmpty || !extraErrors.isEmpty {
            Section("Downloads") {
                ForEach(model.modelStore.downloads.keys.sorted(), id: \.self) { name in
                    if let dl = model.modelStore.downloads[name] {
                        HStack(spacing: 10) {
                            Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            downloadProgress(dl, name: name)
                        }
                    }
                }
                ForEach(extraErrors.keys.sorted(), id: \.self) { name in
                    Label("\(name): \(extraErrors[name] ?? "")", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
    }

    private func downloadProgress(_ dl: ModelStore.ActiveDownload, name: String) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: dl.expected > 0 ? dl.progress : nil)
                .frame(width: 90)
            Text(dl.expected > 0 ? "\(Int(dl.progress * 100))%" : "…")
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            Button { model.modelStore.cancel(name) } label: {
                Image(systemName: "xmark.circle.fill")
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Cancel download")
                .accessibilityLabel("Cancel download of \(name)")
        }
    }

    // MARK: rows

    @ViewBuilder
    private func installedRow(_ m: ModelEntry) -> some View {
        let name = SidebarView.pretty(m.name)
        let size = ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file)
        let value = "\(size), \(m.url == model.activeModelURL ? "loaded, " : "")RAM fit: \(fitDescription(bytes: m.bytes))"

        if m.url == model.activeModelURL {
            installedRowContent(m)
                .accessibilityRepresentation {
                    Text(name)
                        .accessibilityLabel(name)
                        .accessibilityValue(value)
                }
        } else {
            installedRowContent(m)
                .accessibilityRepresentation {
                    HStack {
                        Text(name)
                            .accessibilityLabel(name)
                            .accessibilityValue(value)
                        Button("Load \(name)") {
                            model.loadModel(m.url)
                            dismiss()
                        }
                        Button("Delete \(name)") {
                            model.modelStore.delete(m)
                        }
                    }
                }
        }
    }

    private func installedRowContent(_ m: ModelEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: m.url == model.activeModelURL ? "checkmark.circle.fill" : "cpu")
                .foregroundStyle(m.url == model.activeModelURL ? Color.primary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(SidebarView.pretty(m.name)).font(.callout)
                Text(ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            fitBadge(bytes: m.bytes)
            if m.url != model.activeModelURL {
                Button("Load") {
                    model.loadModel(m.url)
                    dismiss()
                }
                .buttonStyle(ActionGlassButtonStyle(prominent: true))
                .controlSize(.small)
                .disabled(model.loadingModel)
                .help("Load this model")
                Button { model.modelStore.delete(m) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Move to Trash (incl. its vision projector)")
                    .accessibilityLabel("Delete \(SidebarView.pretty(m.name))")
                    .accessibilityHint("Moves this model and its vision projector to the Trash")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func catalogRow(_ item: CatalogModel) -> some View {
        let installed = model.modelStore.installedURL(for: item.fileName) != nil
        let dl = model.modelStore.downloads[item.fileName]
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout)
                Text(item.detail).font(.caption2).foregroundStyle(.secondary)
                if let err = model.modelStore.errors[item.fileName] {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            fitBadge(bytes: item.bytes)
            if installed {
                Label("Installed", systemImage: "checkmark")
                    .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            } else if let dl {
                downloadProgress(dl, name: item.fileName)
            } else {
                Button("Download") { pendingCatalogDownload = item }
                    .buttonStyle(ActionGlassButtonStyle(prominent: true)).controlSize(.small)
                    .accessibilityLabel("Download \(item.name)")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    /// RAM-fit dot: green fits comfortably, orange tight, red too big for this Mac.
    private func fitBadge(bytes: Int64) -> some View {
        FitDot(bytes: bytes, ram: ram, showLabel: true)
    }

    private func fitDescription(bytes: Int64) -> String {
        switch ModelRAMFit.evaluate(fileBytes: bytes, physicalRAM: ram) {
        case .comfortable: "fits"
        case .tight: "tight"
        case .tooBig: "too big"
        }
    }
}
