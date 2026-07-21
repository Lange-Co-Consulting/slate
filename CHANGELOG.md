# Changelog

All notable user-facing changes to Slate are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-07-21

### Added

- **Open source.** The Slate app is now open source (MIT). The local-AI engine
  (`slate-engine`) and design system (`slate-ui`) are public Swift packages; a
  small paid layer (SlatePro) is separate and optional.
- **Roundtable is now freemium:** free users get a 2-model roundtable; Pro
  unlocks a 3rd seat and the closing synthesis turn.
- Beta release channel metadata and a signed, pinned update-feed configuration.
- Reproducible checksums and complete license notices for every bundled native component.
- Production-readiness metadata, privacy manifest and release verification.
- Safe-by-default agent permissions and explicit security documentation.
- First-run onboarding, macOS Services input and Quick Look for code blocks.
- Settings search and portable settings import/export with cloud remaining opt-in.
- Window restoration, Reduce Motion support and global model-error presentation.
- Model-license confirmation, dependency automation, SPDX SBOM generation and
  third-party notices.
- Draft landing page, privacy policy, press kit and English/German localization
  catalog skeleton.
- Offline English/German Apple Help Book covering the complete app, shortcuts,
  privacy, voice-language setup and troubleshooting.
- A central Network Access tab with Silent Mode for updates, licences, model and
  voice downloads, and every built-in cloud connector.
- Explicit model-card and licence review for curated, Hub and custom downloads;
  Parakeet, Supertonic and Silero attribution remains visible in the app.

### Fixed

- Third-party notices now correctly distinguish bundled code from user-downloaded models.
- Swift 6 actor-isolation and audio-converter concurrency diagnostics.
- Hardened-runtime DMG signing on macOS Bash 3.2 and localization embedding in
  packaged app bundles.
- Voice replies now use on-device transcript language detection instead of a
  German fallback when Parakeet does not report a language code.
- Removed FLUX.2 klein from the commercial download catalog after its official
  weights were confirmed to use non-commercial terms; compatible user imports
  remain supported.

## [0.1.0] - 2026-07-10

### Added

- Local chat and coding agents backed by llama.cpp.
- Vision, local image generation, voice conversations and Slate Flow dictation.
- Local memory, checkpoints, Git tools and optional Claude Code integration.
