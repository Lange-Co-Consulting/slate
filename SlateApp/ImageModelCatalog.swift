import Foundation
import SlateCore

/// A downloadable image model = a bundle of files (diffusion transformer + text
/// encoder + VAE) installed together under ~/Models/image/<id>/.
///
/// This catalog is deliberately free of SlateDiffusion: it is pure download metadata
/// (names, URLs, sizes, licenses) plus on-disk existence/format checks. The actual
/// diffusion model is reconstructed from these file paths inside slate-pro's private
/// `ProImageEngine`, so the free public build carries no image-generation code.
struct ImageBundle: Identifiable {
    enum Role { case diffusion, encoder, vae }
    struct File { let role: Role; let name: String; let url: URL; let approxBytes: Int64 }

    let id: String
    let name: String
    /// Diffusion architecture as a plain tag ("flux2" | "qwenImage"); slate-pro maps
    /// it back to `DiffusionModel.Arch`. Kept a String so this file needs no engine import.
    let arch: String
    let note: String
    let licenseName: String
    let licenseNote: String
    let modelCardURL: URL
    let licenseURL: URL
    /// Qwen Image Edit is an img2img model. It needs an image attached to the
    /// composer; plain text-to-image requests are rejected before the engine
    /// is asked to allocate the model.
    let requiresReferenceImage: Bool
    let files: [File]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.approxBytes } }

    private static func hf(_ repo: String, _ path: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)?download=true")!
    }

    // NOTE: FLUX.2 "klein" (Black Forest Labs) was removed from this catalog — despite the
    // Apache-2.0 GGUF re-uploads, the FLUX.2 klein weights ship under BFL's FLUX.2 klein
    // (non-commercial) licence, which must not appear in Slate's commercial download catalog.
    // The `flux2` arch tag is retained (harmless) so a re-add under a commercial licence is easy.
    static let all: [ImageBundle] = [
        ImageBundle(
            id: "qwen-image-compact", name: "Qwen Image · Compact", arch: "qwenImage",
            note: "Text to image · smaller download · Apache-2.0 · ~12 GB",
            licenseName: "Apache-2.0",
            licenseNote: "Apache-2.0 model bundle. Slate downloads the three files only after you review the provider terms.",
            modelCardURL: URL(string: "https://huggingface.co/QuantStack/Qwen-Image-GGUF")!,
            licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
            requiresReferenceImage: false,
            files: [
                .init(role: .diffusion, name: "Qwen_Image-Q2_K.gguf",
                      url: hf("QuantStack/Qwen-Image-GGUF", "Qwen_Image-Q2_K.gguf"), approxBytes: 7_060_000_000),
                .init(role: .encoder, name: "Qwen2.5-VL-7B-Instruct.Q4_K_M.gguf",
                      url: hf("mradermacher/Qwen2.5-VL-7B-Instruct-GGUF", "Qwen2.5-VL-7B-Instruct.Q4_K_M.gguf"), approxBytes: 4_700_000_000),
                .init(role: .vae, name: "qwen_image_vae.safetensors",
                      url: hf("Comfy-Org/Qwen-Image_ComfyUI", "split_files/vae/qwen_image_vae.safetensors"), approxBytes: 250_000_000),
            ]),
        ImageBundle(
            id: "qwen-image", name: "Qwen Image · Detailed", arch: "qwenImage",
            note: "Text to image · higher fidelity · Apache-2.0 · ~18 GB",
            licenseName: "Apache-2.0",
            licenseNote: "Apache-2.0 model bundle. Slate downloads the three files only after you review the provider terms.",
            modelCardURL: URL(string: "https://huggingface.co/QuantStack/Qwen-Image-GGUF")!,
            licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
            requiresReferenceImage: false,
            files: [
                .init(role: .diffusion, name: "Qwen_Image-Q4_K_M.gguf",
                      url: hf("QuantStack/Qwen-Image-GGUF", "Qwen_Image-Q4_K_M.gguf"), approxBytes: 13_100_000_000),
                .init(role: .encoder, name: "Qwen2.5-VL-7B-Instruct.Q4_K_M.gguf",
                      url: hf("mradermacher/Qwen2.5-VL-7B-Instruct-GGUF", "Qwen2.5-VL-7B-Instruct.Q4_K_M.gguf"), approxBytes: 4_700_000_000),
                .init(role: .vae, name: "qwen_image_vae.safetensors",
                      url: hf("Comfy-Org/Qwen-Image_ComfyUI", "split_files/vae/qwen_image_vae.safetensors"), approxBytes: 250_000_000),
            ]),
        ImageBundle(
            id: "qwen-image-edit-compact", name: "Qwen Image Edit · Compact", arch: "qwenImage",
            note: "Transform a reference image · smaller download · Apache-2.0 · ~12 GB",
            licenseName: "Apache-2.0",
            licenseNote: "Apache-2.0 model bundle. This edit model requires a reference image; Slate downloads the three files only after you review the provider terms.",
            modelCardURL: URL(string: "https://huggingface.co/QuantStack/Qwen-Image-Edit-GGUF")!,
            licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
            requiresReferenceImage: true,
            files: [
                .init(role: .diffusion, name: "Qwen_Image_Edit-Q2_K.gguf",
                      url: hf("QuantStack/Qwen-Image-Edit-GGUF", "Qwen_Image_Edit-Q2_K.gguf"), approxBytes: 7_060_000_000),
                .init(role: .encoder, name: "Qwen2.5-VL-7B-Instruct.Q4_K_M.gguf",
                      url: hf("mradermacher/Qwen2.5-VL-7B-Instruct-GGUF", "Qwen2.5-VL-7B-Instruct.Q4_K_M.gguf"), approxBytes: 4_700_000_000),
                .init(role: .vae, name: "qwen_image_vae.safetensors",
                      url: hf("Comfy-Org/Qwen-Image_ComfyUI", "split_files/vae/qwen_image_vae.safetensors"), approxBytes: 250_000_000),
            ]),
        ImageBundle(
            id: "qwen-image-edit", name: "Qwen Image Edit · Detailed", arch: "qwenImage",
            note: "Transform a reference image · higher fidelity · Apache-2.0 · ~18 GB",
            licenseName: "Apache-2.0",
            licenseNote: "Apache-2.0 model bundle. This edit model requires a reference image; Slate downloads the three files only after you review the provider terms.",
            modelCardURL: URL(string: "https://huggingface.co/QuantStack/Qwen-Image-Edit-GGUF")!,
            licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
            requiresReferenceImage: true,
            files: [
                .init(role: .diffusion, name: "Qwen_Image_Edit-Q4_K_M.gguf",
                      url: hf("QuantStack/Qwen-Image-Edit-GGUF", "Qwen_Image_Edit-Q4_K_M.gguf"), approxBytes: 13_100_000_000),
                .init(role: .encoder, name: "Qwen2.5-VL-7B-Instruct.Q4_K_M.gguf",
                      url: hf("mradermacher/Qwen2.5-VL-7B-Instruct-GGUF", "Qwen2.5-VL-7B-Instruct.Q4_K_M.gguf"), approxBytes: 4_700_000_000),
                .init(role: .vae, name: "qwen_image_vae.safetensors",
                      url: hf("Comfy-Org/Qwen-Image_ComfyUI", "split_files/vae/qwen_image_vae.safetensors"), approxBytes: 250_000_000),
            ]),
    ]

    /// Root of the image-model store. Everything below is diffusion bundles
    /// (transformer + encoder + VAE) - the LLM catalog must never scan it.
    static var storeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models/image", isDirectory: true)
    }

    var installDir: URL {
        Self.storeRoot.appendingPathComponent(id, isDirectory: true)
    }

    /// The three installed files (transformer, text encoder, VAE) or nil if any is
    /// missing or fails its format-magic check. No SlateDiffusion is needed here — the
    /// private `ProImageEngine` rebuilds the diffusion model from these paths.
    func installedFiles() -> (diffusion: URL, encoder: URL, vae: URL)? {
        func path(_ r: Role) -> URL? {
            files.first { $0.role == r }.map { installDir.appendingPathComponent($0.name) }
        }
        guard let d = path(.diffusion), let e = path(.encoder), let v = path(.vae) else { return nil }
        let all = [d, e, v]
        guard all.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }),
              all.allSatisfy(Self.isSafeModelFile) else { return nil }
        return (d, e, v)
    }

    /// Initial step estimate for the progress bubble before the engine reports totals
    /// (flux2 is a fast 4-step distillation; Qwen defaults higher).
    var defaultSteps: Int { arch == "flux2" ? 4 : 20 }

    private static func isSafeModelFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "gguf": return DownloadCatalog.hasGGUFMagic(url)
        case "safetensors": return DownloadCatalog.hasSafeTensorsHeader(url)
        default: return false
        }
    }

    var isInstalled: Bool { installedFiles() != nil }
}
