# Changelog

All notable user-facing changes to Slate are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## [1.0.0] - unreleased

Slate leaves beta. This is the first release signed with an Apple Developer ID and
notarized by Apple. _Prepared, not yet published — the current download is 0.1.1;
see the Releases page._

### Added

- **Signed and notarized by Apple.** Slate now ships with a Developer ID signature,
  the hardened runtime and an Apple notarization ticket stapled to the disk image.
  It opens with a normal double-click — no right-click-to-open detour, no
  “unidentified developer” warning.
- **Stable release channel.** Builds are published on the `stable` channel; the
  signed update feed serves stable releases to everyone on 1.0 and later.

### Fixed

- The **voice button** no longer does nothing when no local model is loaded. It stays
  tappable and explains what it needs, with a one-tap way to load a model.
- **Roundtable** no longer shows a white bar along the bottom of the window in light
  mode.

### Notes

- Slate remains bring-your-own-model: no chat or image models ship with the app, and
  everything you run locally stays on your Mac.
- Upgrading from 0.1.x keeps your conversations, models, settings and licence.

## [0.1.1] - 2026-07-23

### Added

- **Slate Remote (beta).** Pair your iPhone with a QR code (Settings ▸ Remote) and chat
  with your Mac's local models from your phone — live token streaming over an encrypted
  link that never leaves your home Wi-Fi. Revoke a phone any time.
- **Bigger context windows.** Pick a context size up to your model's real trained
  maximum — or half of it — instead of a fixed 131k cap, selectable per model at load.
- **Roundtable: multiple participants per model.** Seat several small-model voices
  alongside a couple on a larger model and let them all debate; the setup is now a
  clear, reorderable seat list instead of a model checklist.
- **Import your existing Claude skills.** Auto-detect and copy in the skills you already
  have under `~/.claude` (Settings ▸ Skills), and remove any skill in-app.
- **Full-width chat.** An optional toggle (Settings ▸ General) lets the transcript and
  composer span the whole pane instead of the centered reading column.

### Fixed

- The Pro prompt's **“Enter licence key”** button now reliably opens Settings ▸ Licence
  (it previously just closed the dialog).
- **New Image** opens a working image composer for everyone; the Pro paywall is on Generate.
- Installed **skills can be removed** in-app (the folder moves to the Trash).

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

## Earlier development - 2026-07-10

### Added

- Local chat and coding agents backed by llama.cpp.
- Vision, local image generation, voice conversations and Slate Flow dictation.
- Local memory, checkpoints, Git tools and optional Claude Code integration.
