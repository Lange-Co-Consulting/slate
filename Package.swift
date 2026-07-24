// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Open-core build graph.
//
// Public, open-source packages (slate-engine = local-AI engine, slate-ui = design
// system) are consumed from a local sibling checkout when present (fast iteration
// for the maintainer) and otherwise from their public GitHub repos, so anyone who
// clones ONLY this repo can still `swift build` the free app.
//
// The private paid layer (slate-pro) is linked ONLY when SLATE_PRO=1 and is always
// a local path — it is never published, so a public clone can never resolve it. The
// maintainer's paid/owner builds set SLATE_PRO=1 (see deploy.sh / build-dmg.sh); the
// default build here is the FREE app. The app picks the free vs Pro implementation
// behind `#if SLATE_PRO`.
func openDep(_ localPath: String, remote: Package.Dependency) -> Package.Dependency {
    FileManager.default.fileExists(atPath: localPath) ? .package(path: localPath) : remote
}

let linkPro = ProcessInfo.processInfo.environment["SLATE_PRO"] == "1"

var packageDependencies: [Package.Dependency] = [
    openDep("../slate-engine", remote: .package(url: "https://github.com/Lange-Co-Consulting/slate-engine.git", exact: "0.1.5")),
    openDep("../slate-ui", remote: .package(url: "https://github.com/Lange-Co-Consulting/slate-ui.git", exact: "0.1.0")),
    // Qwen3-TTS premium voice (MLX/Metal). Pinned by revision - the repo tags
    // nothing; a moving `main` must never silently change what we ship. App-only.
    .package(url: "https://github.com/AtomGradient/swift-qwen3-tts.git",
             revision: "27a5b5b2c5d55258bead2c6e851208987e1ca225"),
    // Slate Remote wire protocol (shared with the iOS companion). Local sibling at
    // the repo root; Package.swift is also at the root, so the path is unprefixed.
    .package(path: "SlateRemoteProtocol"),
]

var appDependencies: [Target.Dependency] = [
    .product(name: "SlateCore", package: "slate-engine"),
    .product(name: "SlateLlama", package: "slate-engine"),
    // NOTE: SlateDiffusion is intentionally NOT linked by the app. Image generation
    // (the only Pro surface whose compute is private) lives in slate-pro's
    // ProImageEngine; the free build carries no diffusion code and cannot generate.
    .product(name: "SlateSTT", package: "slate-engine"),
    .product(name: "SlateFlowCore", package: "slate-engine"),
    .product(name: "SlateFlowCleanup", package: "slate-engine"),
    .product(name: "SlateUI", package: "slate-ui"),
    .product(name: "Qwen3TTS", package: "swift-qwen3-tts"),
    .product(name: "SlateRemoteProtocol", package: "SlateRemoteProtocol"),
]

// `SLATE_PRO` is emitted iff the private paid layer is actually linked, so `#if
// SLATE_PRO` in the app can never disagree with the link line. A public clone has
// no ../slate-pro and never sets SLATE_PRO, so it always builds the free app.
var appSwiftSettings: [SwiftSetting] = []

if linkPro {
    packageDependencies.append(.package(path: "../slate-pro"))
    appDependencies.append(.product(name: "SlatePro", package: "slate-pro"))
    appSwiftSettings.append(.define("SLATE_PRO"))
}

let package = Package(
    name: "Slate",
    platforms: [.macOS("26.0")], // Liquid Glass APIs (glassEffect, GlassEffectContainer) require macOS 26.
    products: [
        .executable(name: "SlateLicenseTool", targets: ["SlateLicenseTool"]),
        .executable(name: "slatectl", targets: ["SlateBundledCLI"]),
    ],
    dependencies: packageDependencies,
    targets: [
        // Owner-only CLI for generating an Ed25519 key and issuing signed offline
        // licence documents. It is never copied into Slate.app.
        .executableTarget(name: "SlateLicenseTool",
                          dependencies: [.product(name: "SlateCore", package: "slate-engine")],
                          path: "Tools/SlateLicenseTool"),
        // Bundled with the app (Resources/slatectl). Same source as the engine's
        // public `SlateCLI`; a distinct target name avoids a package-graph clash,
        // and the product stays "slatectl" so deploy.sh is unchanged.
        .executableTarget(name: "SlateBundledCLI",
                          dependencies: [.product(name: "SlateCore", package: "slate-engine"),
                                         .product(name: "SlateSTT", package: "slate-engine")],
                          path: "Tools/SlateCLI"),
        // Runnable SwiftUI app via `swift run SlateApp` (no Xcode needed for dev use).
        // The polished .app + DMG (spec §3.6) is built later via an Xcode project.
        .executableTarget(name: "SlateApp",
                          dependencies: appDependencies,
                          path: "SlateApp",
                          exclude: ["Packaging", "Help", "Slate.entitlements",
                                    "PrivacyInfo.xcprivacy", "Localizable.xcstrings"],
                          swiftSettings: appSwiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
