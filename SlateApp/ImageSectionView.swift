import SwiftUI
import SlateUI
import AppKit
import SlateCore

/// Chat-to-image (like ChatGPT): a prompt composer at the bottom, each result an
/// image bubble in the transcript. Generation frees the LLM behind a stop-gate.
struct ImageSectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let convo: Conversation

    @State private var prompt = ""
    @State private var aspect: Aspect = .square
    @State private var seedLocked = false
    @State private var lockedSeed: Int64 = 42
    /// img2img: source image + how far the result may drift from it.
    @State private var initImage: URL?
    @State private var strength = 0.6
    @State private var importingInit = false
    @State private var dropTargeted = false

    enum Aspect: String, CaseIterable {
        case square, portrait, landscape
        var size: (Int, Int) { switch self { case .square: (1024,1024); case .portrait: (768,1152); case .landscape: (1152,768) } }
        var icon: String { switch self { case .square: "square"; case .portrait: "rectangle.portrait"; case .landscape: "rectangle" } }
    }

    private var hasModel: Bool { !model.installedImageBundles.isEmpty }
    private var busyHere: Bool { model.imageGenerating && model.imageGeneratingConvoID == convo.id }
    private var selectedImageBundle: ImageBundle? {
        model.installedImageBundles.first { $0.id == model.selectedImageModelID }
            ?? model.installedImageBundles.first
    }
    private var selectedModelNeedsReference: Bool { selectedImageBundle?.requiresReferenceImage == true }

    var body: some View {
        transcript
            .overlay(alignment: .center) {
                if convo.messages.allSatisfy({ $0.role == .system }) && !hasModel && !busyHere {
                    NoModelGuidance(kind: .image)
                }
            }
            .overlay(alignment: .top) { header }
            .overlay(alignment: .bottom) { composer }
            .ignoresSafeArea(.container, edges: .top)   // canvas lives on RootView
            .confirmationDialog("Switch to image generation?",
                                isPresented: Binding(get: { model.pendingImage != nil },
                                                     set: { if !$0 { model.cancelPendingImage() } }),
                                titleVisibility: .visible) {
                Button("Continue") { model.confirmPendingImage() }
                Button("Cancel", role: .cancel) { model.cancelPendingImage() }
            } message: {
                Text("Slate will stop the current model and any running task to free memory for the image model.")
            }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Color.clear.frame(height: 84).id("top")
                    ForEach(convo.messages.filter { $0.role != .system }) { msg in
                        if msg.role == .user {
                            MessageBubble(role: .user, text: msg.content)
                        } else if let path = msg.imagePath {
                            GeneratedImageBubble(path: path)
                        } else {
                            MessageBubble(role: .assistant, text: msg.content)
                        }
                    }
                    if busyHere { generatingBubble }
                    Color.clear.frame(height: 96).id("bottom")
                }
                .padding(.horizontal, 28).padding(.vertical, 18)
                .frame(maxWidth: ConversationView.contentWidth)
                .frame(maxWidth: .infinity, alignment: .center)
                .animation(.smooth(duration: 0.25), value: convo.messages.count)
            }
            .onChange(of: convo.messages.count) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: model.imageStep) { _, _ in proxy.scrollTo("bottom") }
        }
    }

    private var generatingBubble: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SLATE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(model.imageTotalSteps > 0
                         ? "Generating… step \(model.imageStep)/\(model.imageTotalSteps)"
                         : "Generating…")
                        .font(.callout).foregroundStyle(.secondary).shimmer()
                }
            }
            Spacer(minLength: 64)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.l) {
            ToolbarIconButton(system: "sidebar.leading", help: "Toggle sidebar") {
                withAnimation(.smooth(duration: 0.28)) { model.sidebarVisible.toggle() }
            }
            Image(systemName: "photo").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text(convo.title).font(.headline).lineLimit(1)
            Spacer(minLength: DS.Space.l)
            if hasModel { modelPicker }
            ramGauge
            overflow
        }
        .padding(.leading, model.sidebarVisible || model.isFullscreen ? 16 : 78)
        .padding(.trailing, 16).padding(.vertical, 9)
        .clearGlass(RoundedRectangle(cornerRadius: DS.R.stage, style: .continuous))
        .glassShadow(scheme, hero: true)
        .gesture(WindowDragGesture())   // header = native drag region
        .padding(.horizontal, 12).padding(.top, 10)
    }

    private var modelPicker: some View {
        Menu {
            ForEach(model.installedImageBundles) { b in
                Button {
                    model.selectedImageModelID = b.id
                } label: {
                    Label(b.name, systemImage: model.selectedImageModelID == b.id ? "checkmark" : "photo.artframe")
                }
            }
            Divider()
            Button("Manage image models…") { model.showModelManager = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "photo.artframe").font(.caption2)
                Text(model.installedImageBundles.first { $0.id == model.selectedImageModelID }?.name ?? "Image model")
                    .font(.caption).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .headerChip()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Switch image model")
    }

    private var ramGauge: some View { RAMChip(ram: model.ram) }

    private var overflow: some View {
        Menu {
            Button("Manage image models…") { model.showModelManager = true }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).foregroundStyle(.secondary).fixedSize()
        .help("More")
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !hasModel {
                Button { model.showModelManager = true } label: {
                    Label("Download an image model to start", systemImage: "arrow.down.circle")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(ClearGlassButtonStyle())
            }
            if let err = model.imageError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.imageError = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss error")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
                .frame(maxWidth: 560)
            }
            if selectedModelNeedsReference && initImage == nil {
                Label("Attach a reference image to use \(selectedImageBundle?.name ?? "this edit model").",
                      systemImage: "photo.badge.plus")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            if let src = initImage { initImageChip(src) }
            HStack(alignment: .bottom, spacing: 10) {
                attachButton
                aspectPicker
                seedButton
                TextField("Describe an image…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain).font(.body).lineLimit(1...6)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .clearGlass(RoundedRectangle(cornerRadius: DS.R.pill, style: .continuous))
                    .glassShadow(scheme, hero: true)
                    .onSubmit(generate)
                    .disabled(!hasModel || busyHere)
                Button(action: generate) {
                    Image(systemName: busyHere ? "hourglass" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.primary.opacity(canGenerate ? 1 : 0.25)))
                }
                .buttonStyle(.plain).disabled(!canGenerate).liquidHover(1.08)
                .help(busyHere ? "Generating\u{2026}" : "Generate image (\u{21A9})")
                .accessibilityLabel(busyHere ? "Generating" : "Generate image")
            }
        }
        .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 16)
        .frame(maxWidth: ConversationView.contentWidth).frame(maxWidth: .infinity)
        // Drop an image anywhere on the composer → img2img source.
        .dropDestination(for: URL.self, action: { urls, _ in
            guard let url = urls.first(where: ConversationView.isImageFile) else { return false }
            withAnimation(.snappy(duration: 0.25)) { initImage = url }
            return true
        }, isTargeted: { dropTargeted = $0 })
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
                    .strokeBorder(.primary.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).fill(.primary.opacity(0.04)))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.15), value: dropTargeted)
        .fileImporter(isPresented: $importingInit, allowedContentTypes: [.image]) { result in
            if case let .success(url) = result {
                withAnimation(.snappy(duration: 0.25)) { initImage = url }
            }
        }
        .animation(.snappy(duration: 0.25), value: initImage)
    }

    /// img2img source chip: thumbnail, name, drift slider, remove.
    private func initImageChip(_ src: URL) -> some View {
        HStack(spacing: 10) {
            ThumbnailImage(path: src.path, maxPixel: 96, fixedSize: 36, corner: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(src.lastPathComponent).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("Stay close").font(.caption2).foregroundStyle(.tertiary)
                    Slider(value: $strength, in: 0.25...0.9)
                        .controlSize(.mini)
                        .frame(width: 140)
                    Text("Reimagine").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy(duration: 0.25)) { initImage = nil }
            } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Remove source image")
        }
        .padding(8)
        .clearGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .glassShadow(scheme)
        .frame(maxWidth: 560)
        .help("The result starts from this image - the slider sets how far it may drift")
    }

    private var attachButton: some View {
        Button { importingInit = true } label: {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 15, weight: .medium)).frame(width: 38, height: 38)
        }
        .buttonStyle(CircleGlassButtonStyle()).liquidHover(1.08)
        .help("Transform an existing image (img2img) - or just drop one on the composer")
        .accessibilityLabel("Transform an existing image")
    }

    private var canGenerate: Bool {
        hasModel && !busyHere && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!selectedModelNeedsReference || initImage != nil)
    }

    private var aspectPicker: some View {
        Menu {
            ForEach(Aspect.allCases, id: \.self) { a in
                Button { aspect = a } label: {
                    Label(a.rawValue.capitalized, systemImage: aspect == a ? "checkmark" : a.icon)
                }
            }
        } label: {
            Image(systemName: aspect.icon).font(.system(size: 15, weight: .medium)).frame(width: 38, height: 38)
        }
        .buttonStyle(CircleGlassButtonStyle()).menuIndicator(.hidden).fixedSize()
        .help("Aspect ratio")
        .accessibilityLabel("Aspect ratio")
        .accessibilityValue(aspect.rawValue.capitalized)
    }

    private var seedButton: some View {
        Button { seedLocked.toggle(); if seedLocked { lockedSeed = Int64.random(in: 0..<1_000_000) } } label: {
            Image(systemName: seedLocked ? "lock.fill" : "dice")
                .font(.system(size: 15, weight: .medium)).frame(width: 38, height: 38)
        }
        .buttonStyle(CircleGlassButtonStyle()).liquidHover(1.08)
        .help(seedLocked ? "Seed locked (\(lockedSeed)) - same seed reproduces" : "Random seed each time")
        .accessibilityLabel(seedLocked ? "Seed locked" : "Random seed each time")
    }

    private func generate() {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canGenerate else { return }
        guard model.requirePro(.image) else { return }
        prompt = ""
        let (w, h) = aspect.size
        model.requestImage(prompt: p, width: w, height: h,
                           seed: seedLocked ? lockedSeed : -1, in: convo.id,
                           initImagePath: initImage?.path, strength: Float(strength))
        withAnimation(.snappy(duration: 0.25)) { initImage = nil }
    }
}

/// A generated image in the transcript. Save/Copy stay visible in the image's
/// top-right corner instead of appearing only on hover.
struct GeneratedImageBubble: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SLATE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Label("AI-generated locally", systemImage: "sparkles")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("This image was generated by AI locally on this Mac")
                if let img = NSImage(contentsOfFile: path) {
                    Image(nsImage: img)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 460, maxHeight: 460)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
                        .overlay(alignment: .topTrailing) { actionPill.padding(8) }
                        .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider() }
                } else {
                    Text("(image unavailable)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 64)
        }
    }

    /// Always-visible glass pill on the image corner (Save + Copy).
    private var actionPill: some View {
        HStack(spacing: 12) {
            Button { save() } label: { Image(systemName: "square.and.arrow.down") }
                .help("Save image…")
                .accessibilityLabel("Save image")
            Button { copy() } label: { Image(systemName: "doc.on.doc") }
                .help("Copy image")
                .accessibilityLabel("Copy image")
        }
        .font(.system(size: 13, weight: .medium))
        .buttonStyle(.plain).foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "slate-image.png"
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let dst = panel.url {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: dst)
        }
    }
    private func copy() {
        guard let img = NSImage(contentsOfFile: path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }
}
