// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "krd",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .executableTarget(name: "krd", dependencies: ["CZlib"], path: "Sources/krd")
    ]
)
