// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "krd",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        // Platform-neutral: no AppKit, no CoreGraphics, no ScreenCaptureKit. The byte contract
        // (tiles, levels, escapes) lives here so it can be tested without a screen (issue #21).
        .target(name: "krdcore", dependencies: ["CZlib"], path: "Sources/krdcore"),
        .executableTarget(name: "krd", dependencies: ["CZlib", "krdcore"], path: "Sources/krd"),
        .testTarget(name: "krdTests", dependencies: ["krd", "krdcore", "CZlib"], path: "Tests/krdTests"),
        // The byte contract's own suite: no screen, no terminal, no tty (issue #21).
        .testTarget(name: "krdcoreTests", dependencies: ["krdcore", "CZlib"], path: "Tests/krdcoreTests")
    ]
)
