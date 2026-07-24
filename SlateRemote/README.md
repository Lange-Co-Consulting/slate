# Slate Remote — native SwiftUI iOS app

A native SwiftUI companion app for Slate: your Mac runs the models, your iPhone is a
thin, encrypted remote over the local network. This is the approved visualizer
concept turned into a **real native app** (no WebView, no HTML shell) — the full onboarding → pairing → chat → settings flow plus every
edge state, in Slate's monochrome identity.

## Status

- ✅ Native SwiftUI, builds green (Debug + Release), 6 unit tests pass.
- ✅ Every screen verified in the iOS Simulator (iPhone 17 Pro, iOS 26.5): welcome,
  Local-Network priming, the OS permission dialog, QR scan, paired, chat list, chat
  thread, settings, Mac-security/revoke, and the edge-state gallery (loading, success,
  OOM error, offline, waking, wake-failed, empty, Dynamic Type XL).
- ✅ Archives cleanly for device (unsigned Release archive succeeds).
- ⛔ **TestFlight upload is blocked** — this Mac has no Apple Developer Program
  membership, no distribution certificate, and no App Store Connect app record. That
  step needs the operator's Apple ID + a paid membership (see "TestFlight" below). The
  app is otherwise upload-ready.

> **The transport is real.** Pairing and live token streaming run over the shared
> `SlateRemoteProtocol` package against the Mac-side `SlateRemoteServer`
> (`SlateApp/Remote/SlateRemoteServer.swift`), with `Sources/State/RemoteClient.swift`
> as the client. An offline demo state machine still backs the edge-state gallery and
> previews, so the UI can be exercised without a paired Mac.

## Requirements

- Xcode 26+ (uses the iOS 26.5 SDK; deployment target iOS 17.0).
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the
  Xcode project is generated from `project.yml`.

## Build & run

```bash
cd SlateRemote
xcodegen generate          # produces SlateRemote.xcodeproj from project.yml
open SlateRemote.xcodeproj  # then ⌘R to run in the Simulator
```

Or from the command line, into a booted Simulator:

```bash
xcodebuild -project SlateRemote.xcodeproj -scheme SlateRemote \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcrun simctl install booted \
  "$(find ~/Library/Developer/Xcode/DerivedData/SlateRemote-*/Build/Products/Debug-iphonesimulator -name SlateRemote.app | head -1)"
xcrun simctl launch booted com.langeundco.slate.remote
```

## Tests

```bash
xcodebuild -project SlateRemote.xcodeproj -scheme SlateRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Install on your own iPhone via TestFlight

TestFlight (and macOS notarization) are gated on the Lange & Co. Apple Developer
Program membership, currently **pending Apple's org approval**. The complete, single
reference for signing, notarization, App Store Connect, `ExportOptions.plist`, the
archive/upload commands and the release checklist lives in the private repo at
`docs/APPLE-DISTRIBUTION.md`.

## Layout

```
project.yml            xcodegen spec (bundle id, Info.plist, signing knobs)
ExportOptions.plist    App Store Connect / TestFlight export template
Sources/
  App/                 app entry + root routing
  Design/              Theme (Slate tokens), WeaveMark, reusable Components
  State/               RemoteClient (live transport), AppState, MacStatus, models
  Onboarding/          welcome, permission priming, QR scan, pairing, expired-QR
  Chat/                chat list, chat thread (streaming/tools/stop), Mac status banner
  Settings/            settings, Mac security/revoke, edge-state gallery
  Assets.xcassets/     AppIcon (Weave mark) + Canvas launch colour
Tests/                 XCTest unit tests
```
