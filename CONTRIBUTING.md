# Contributing to Slate

Thanks for your interest — contributions are genuinely welcome.

## Getting set up

Requires an Apple Silicon Mac on **macOS 26+** with **Swift 6** (Xcode and the
macOS 26 SDK).

```sh
git clone https://github.com/Lange-Co-Consulting/slate.git
cd slate
swift run SlateApp        # builds & runs the free app
./Scripts/verify.sh       # plist + build + test suite
```

SwiftPM resolves [`slate-engine`](https://github.com/Lange-Co-Consulting/slate-engine)
and [`slate-ui`](https://github.com/Lange-Co-Consulting/slate-ui) from GitHub and
downloads the engine's binary frameworks automatically. No manual setup.

Working on the engine or the design system at the same time? Check them out as
siblings of this repo (`../slate-engine`, `../slate-ui`) and the build uses those
local checkouts instead of the pinned GitHub revisions (see `Package.swift`).

## Open core

Slate is open-core. This repo is the **free app** and builds fully on its own. A
small paid layer (**SlatePro** — licensing + a few premium capabilities) lives in
a separate private package and is **not** required to build, run, or contribute.
Pro-gated code paths are behind `#if SLATE_PRO`; in the open build they resolve to
an upgrade prompt. Please don't add hard dependencies on SlatePro from open code —
route anything Pro-related through the `ProFeatures` seam (`SlateApp/ProFeatures.swift`).

## Ground rules

- **Keep it green.** Every change should build and pass `./Scripts/verify.sh`.
- **Small, focused PRs** are much easier to review and land.
- **Match the surrounding style** — Slate is deliberately monochrome and restrained; no new accent colors, no gratuitous animation. Design tokens live in `slate-ui`.
- **Privacy first.** Anything that touches the network must be opt-in and must respect Silent Mode.
- Discuss larger features in an issue before building, so we can agree on the approach.

## Reporting issues

Use [GitHub Issues](https://github.com/Lange-Co-Consulting/slate/issues). Include
your macOS version, the model(s) involved, and steps to reproduce. For anything
security-sensitive, see [SECURITY.md](SECURITY.md) instead of filing a public issue.

## License

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
