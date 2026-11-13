// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CanonScan",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CanonScan", targets: ["CanonScan"])],
    targets: [
        .executableTarget(name: "CanonScan"),
        .testTarget(name: "CanonScanTests", dependencies: ["CanonScan"])
    ],
    swiftLanguageModes: [.v5]
)
