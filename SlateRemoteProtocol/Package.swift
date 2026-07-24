// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlateRemoteProtocol",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SlateRemoteProtocol", targets: ["SlateRemoteProtocol"])],
    targets: [
        .target(name: "SlateRemoteProtocol"),
        .testTarget(name: "SlateRemoteProtocolTests", dependencies: ["SlateRemoteProtocol"]),
    ],
    swiftLanguageModes: [.v6]
)
