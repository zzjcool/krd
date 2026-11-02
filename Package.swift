// swift-tools-version:5.9
import Foundation
import PackageDescription

// The headless VT (issue #218) is a *test-only* dependency, and it is not in this repository.
//
// libghostty-vt is 8 MB of xcframework and it must never be able to block a feature (the UI v2 plan's
// P0–P3 rule), so it is not a package dependency: it is an artifact the machine has or does not have,
// named by `KRD_VT_XCFRAMEWORK`. Set → the two targets below exist and the headless render test
// compiles in. Unset → neither target exists, `HeadlessRenderTests.swift` compiles to nothing (its
// whole body is inside `#if KRD_HEADLESS_VT`), and `swift build` / `swift test` are exactly what they
// were before this file mentioned libghostty at all.
//
// The decision is made **here, in Swift**, and not with `#if` in the manifest: a `#if` cannot see an
// environment variable, so it would have to be *edited* to turn the test on — i.e. no switch at all.
// One `export` is the whole switch:
//
//     scripts/build-vt-xcframework.sh                                   # writes .artifacts/
//     KRD_VT_XCFRAMEWORK=.artifacts/ghostty-vt.xcframework swift test    # --filter HeadlessRender
//
// `docs/TESTING.md` §13 has the rule this switch exists for, in one paragraph: a P5 test dependency
// must never be able to stop the product, so the build without it is not a degraded build — it is the
// build.
let vtSetting = (ProcessInfo.processInfo.environment["KRD_VT_XCFRAMEWORK"] ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
let headlessVT = !vtSetting.isEmpty

/// The local artifact, checked.
///
/// Two things have to be said here rather than left to SwiftPM, because both produce a confusing
/// failure far from the variable that caused it:
///
/// 1. **SwiftPM refuses an absolute path** for `binaryTarget(path:)` — "path expected to be relative
///    to package root" — so an `export KRD_VT_XCFRAMEWORK=$HOME/…` is turned into a relative path
///    when it points inside the package. A path *outside* it cannot be expressed that way at all
///    (`..` chains are rejected too), and the answer is a symlink into `.artifacts/`, which is what
///    `scripts/build-vt-xcframework.sh`'s output line suggests.
/// 2. **A typo must not look like "the test is off"**: an absent directory would build a plain
///    package and quietly run 5 fewer tests, so it is a fatal error with the path in it instead.
func localFrameworkPath() -> String {
    let root = (#filePath as NSString).deletingLastPathComponent
    func relative(_ path: String, under root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
    var path = vtSetting
    if path.hasPrefix("/") {
        // The literal path first, then both resolved (`cd` through a symlink gives `$PWD` a prefix
        // that does not match `#filePath`, which is the real one).
        // Resolve the *directory*, not the leaf: the leaf may legitimately be a symlink to a
        // framework outside the package (that is the advised local form).
        let realPath = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
            .resolvingSymlinksInPath().path + "/" + (path as NSString).lastPathComponent
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        if let rel = relative(path, under: root) ?? relative(realPath, under: realRoot) {
            path = rel
        } else {
            fatalError("KRD_VT_XCFRAMEWORK=\(path) is outside the package and SwiftPM only takes a "
                       + "path relative to it; symlink it in:\n"
                       + "    ln -sfn \(path) .artifacts/ghostty-vt.xcframework\n"
                       + "    KRD_VT_XCFRAMEWORK=.artifacts/ghostty-vt.xcframework swift test")
        }
    }
    var isDirectory: ObjCBool = false
    let resolved = path.hasPrefix("/") ? path : root + "/" + path
    if !FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
        || !isDirectory.boolValue {
        fatalError("KRD_VT_XCFRAMEWORK=\(vtSetting) is not a ghostty-vt.xcframework directory "
                   + "(scripts/build-vt-xcframework.sh builds one)")
    }
    return path
}

var targets: [Target] = [
    .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
    // Platform-neutral: no AppKit, no CoreGraphics, no ScreenCaptureKit. The byte contract
    // (tiles, levels, escapes) lives here so it can be tested without a screen (issue #21).
    .target(name: "krdcore", dependencies: ["CZlib"], path: "Sources/krdcore"),
    .executableTarget(name: "krd", dependencies: ["CZlib", "krdcore"], path: "Sources/krd"),
]

// Test-only, both of them: `KrdHeadlessVT` is reachable from `krdTests` and from nothing else, which
// is what keeps the shipping executable free of libghostty (`swift build -c release` links no VT, and
// the release binary is the same size with the variable set and unset — measured in the PR).
if headlessVT {
    targets.append(contentsOf: [
        // Two forms, one switch. A **path** (`…/ghostty-vt.xcframework`, what
        // `scripts/build-vt-xcframework.sh` prints) links the artifact this machine built; any other
        // non-empty value links the published one **pinned by URL and checksum**, which is what CI
        // passes (`KRD_VT_XCFRAMEWORK: pinned` in `.github/workflows/ci.yml`). The checksum is the
        // sha256 of the asset at that URL, produced by that script from ghostty tag `v1.4.0` with
        // Zig 0.17.0 — `scripts/build-vt-xcframework.sh` normalises the zip'"'"'s timestamps, so a rebuild
        // gives this same number rather than "a checksum nobody can check" (docs/TESTING.md §13).
        vtSetting.contains("/")
            ? .binaryTarget(name: "KrdVT", path: localFrameworkPath())
            : .binaryTarget(
                name: "KrdVT",
                url: "https://github.com/zzjcool/krd/releases/download/vt-v1.4.0/ghostty-vt.xcframework.zip",
                checksum: "c0c9a32bf0ce5c56a7a1f7b13f10125740553e8c62ed6d878b707dd5d0b950ce"
            ),
        .target(name: "KrdHeadlessVT", dependencies: ["KrdVT"], path: "Sources/KrdHeadlessVT"),
    ])
}

var testDependencies: [Target.Dependency] = ["krd", "krdcore", "CZlib"]
var testSwiftSettings: [SwiftSetting] = []
if headlessVT {
    testDependencies.append("KrdHeadlessVT")
    // The test file's whole body is inside `#if KRD_HEADLESS_VT`, so with the env var unset it is an
    // empty translation unit: no `XCTSkip`, no skipped-test count, nothing to notice — the same
    // "Executed 0 tests" shape as `KRD_UPDATE_FIXTURE` in `WallCanvasTests`. docs/TESTING.md §13 says
    // so, because "0 failures" must not be mistaken for "it ran".
    testSwiftSettings.append(.define("KRD_HEADLESS_VT"))
}

targets.append(contentsOf: [
    .testTarget(name: "krdTests", dependencies: testDependencies, path: "Tests/krdTests",
                exclude: ["Fixtures"], swiftSettings: testSwiftSettings),
    // The byte contract's own suite: no screen, no terminal, no tty (issue #21).
    .testTarget(name: "krdcoreTests", dependencies: ["krdcore", "CZlib"], path: "Tests/krdcoreTests",
                exclude: ["Fixtures"]),
])

let package = Package(
    name: "krd",
    platforms: [.macOS(.v14)],
    targets: targets
)
