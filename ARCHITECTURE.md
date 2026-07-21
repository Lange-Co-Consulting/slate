# Architecture

A short map of how Slate is put together, for contributors.

## Open core: four packages

Slate is split across four Swift packages:

| Package | Visibility | Role |
|---|---|---|
| **slate** (this repo) | public, MIT | The app: SwiftUI UI + orchestration (`SlateApp/`), the `slatectl` CLI, packaging. |
| **[slate-engine](https://github.com/Lange-Co-Consulting/slate-engine)** | public, MIT | The local-AI engine: llama.cpp chat/coding, stable-diffusion.cpp images, FluidAudio speech, plus the pure licence-verification model. |
| **[slate-ui](https://github.com/Lange-Co-Consulting/slate-ui)** | public, MIT | The design system: palette, `DS` tokens, Liquid-Glass surfaces, button styles, reusable atoms. |
| **SlatePro** | private | The paid layer: licensing (activation, offline licences, owner unlock) and a few premium capabilities. Not required to build or run. |

`Package.swift` resolves `slate-engine` and `slate-ui` from a local sibling
checkout when present (fast iteration for the maintainer) and otherwise from
their pinned public GitHub tags, so a clone of *this* repo alone builds the app.

## The free/paid seam

The app never references SlatePro directly. Instead everything Pro-related goes
through a single seam: `AppModel.pro`, an `any ProFeatures`
([`SlateApp/ProFeatures.swift`](SlateApp/ProFeatures.swift)).

```
protocol ProFeatures {
    func allows(_ cap: SlateCapability) -> Bool   // the one question every gate asks
    var isPro: Bool { get }
    // ... licensing lifecycle + roundtable depth ...
}
```

- **Free build** (default `swift build`) injects `DefaultFreeProFeatures`: Pro
  capabilities return `false`, so the caller shows an upgrade prompt instead of
  running the Pro action. There is no licensing at all.
- **Official/owner build** (`SLATE_PRO=1`) injects `SlateProFeatures`, backed by
  SlatePro's `LicenseService`. The `SLATE_PRO` build define is emitted only when
  the package is actually linked, so `#if SLATE_PRO` can never disagree with the
  link line.

Every feature gate reads `pro.allows(_:)` (or the convenience `AppModel.requirePro(_:)`),
so the free and paid behaviours diverge in exactly one place.

## What is (and isn't) in the open build

The Pro feature *views* live in this repo, but they are inert without SlatePro:
they gate at *action* time (a tap shows the upgrade prompt). Only the licensing
*logic* physically lives in the private package. The public build therefore
contains no licensing implementation and no keys.

Roundtable is freemium rather than fully gated: the free build runs a 2-model
roundtable; a 3rd seat and the closing synthesis turn are Pro (see
`roundtableModelCap` / `roundtableSynthesisAllowed` on `ProFeatures`).

## Where things live

- `SlateApp/AppModel.swift` is the central `@Observable` app state and the agent
  turn loop. Most feature logic hangs off it.
- `SlateApp/ConversationView.swift` is the main chat surface (chat, code, compare,
  and voice modes are woven together here).
- `SlateApp/ProFeatures.swift` is the seam described above.
- `SlateApp/RootView.swift` owns the window chrome and the sidebar (Slate uses its
  own clipped panel, not `NavigationSplitView`).

The engine's execution trust model is documented in [SECURITY.md](SECURITY.md).
