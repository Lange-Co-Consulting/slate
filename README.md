# Slate

Slate is a native macOS workspace for **local** language models — GGUF chat and
coding agents, vision, image generation, voice conversations and system-wide
dictation, in one SwiftUI app. Models and data stay on your Mac unless you
explicitly enable a cloud connector, pick Claude Code / OpenCode, configure an
OpenAI-compatible API, or download a model. Cloud is off by default; API keys
live in the macOS Keychain.

This repository is the **free, open-source Slate app** (MIT). It is *open-core*:

- **[slate-engine](https://github.com/Lange-Co-Consulting/slate-engine)** (public, MIT) — the local-AI engine (llama.cpp chat/coding, stable-diffusion.cpp images, FluidAudio speech) and the pure licensing/verification model. Binary frameworks ship as release assets and are resolved automatically by SwiftPM.
- **[slate-ui](https://github.com/Lange-Co-Consulting/slate-ui)** (public, MIT) — the shared design system (palette, tokens, Liquid-Glass surfaces, atoms).
- **SlatePro** (private, not in this repo) — the paid layer (licensing + a few premium capabilities). The app compiles and runs fully without it; Pro features show an upgrade prompt in the free build.

## Requirements

- Apple Silicon Mac running **macOS 26** or newer (Liquid Glass APIs)
- Xcode with the macOS 26 SDK and **Swift 6**

## Build and run

```sh
swift run SlateApp
```

That's it — SwiftPM resolves `slate-engine` and `slate-ui` from GitHub and
downloads the engine's binary frameworks (llama / stable-diffusion) as pinned,
checksummed release assets. No manual framework provisioning.

For the maintainer's workflow, checking out `slate-engine` and `slate-ui` as
siblings of this repo makes the build use those local checkouts instead of the
pinned GitHub revisions (see `Package.swift`).

```sh
./Scripts/verify.sh          # plist + build + tests
```

## Bring your own model

Slate bundles no chat or image models — download your own from Hugging Face via
the in-app Model Manager, or bring a cloud API key. Only the small speech models
ship. Model downloads are always explicit, and every speech component can instead
use a copied folder on an air-gapped Mac. Settings → Network Access has a master
Silent Mode that blocks Slate's update / licence / download / cloud clients while
local work keeps running.

## Project layout

- `SlateApp/` — the SwiftUI app and orchestration
- `Tools/SlateCLI` — `slatectl`, the bundled offline CLI (search, transcription, local-model Q&A for Terminal / Shortcuts)
- `Tools/SlateLicenseTool` — offline licence issuing/verification tooling (the private signing key is never in this repo)
- `Scripts/`, `SlateApp/Packaging/` — verify / version / package scripts

The execution trust model is documented in [SECURITY.md](SECURITY.md); the
release inventory is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT — see [LICENSE](LICENSE). Attribution required for NVIDIA Parakeet-TDT
(CC-BY-4.0), surfaced in Settings → About.
