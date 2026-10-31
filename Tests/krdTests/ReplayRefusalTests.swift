import Foundation
import XCTest
@testable import krd

/// The other half of issue #133: a manifest line is a *claim* about a frame, and the replay has to be
/// able to say so out loud. `frame(_:)` answers `nil` for a file that does not match its own line, and
/// before this the only reader of that `nil` was a loop that logged one line, `break`ed, printed the
/// ordinary summary (counting the *declared* frames) and exited 0 -- a valid recording that painted
/// nothing and reported success. `docs/BENCHMARK.md` §5 L4 promises the opposite: "a mismatch is a
/// clear error, not a blank screen".
///
/// `refusal(...)` is the sentence `runReplay` now writes to stderr before `exit(1)`. It is a method on
/// `FrameReplay` rather than a `let` in `runReplay` so the words can be tested here, with a temp
/// directory and no terminal, no capture and no `Desk`.
final class ReplayRefusalTests: XCTestCase {
    private var dir: URL!

    /// A plausible header line, so the fixtures look like what `--record` writes. The frame sizes in
    /// these cases are small and do not need to match it: `refusal(...)` takes the layout as an
    /// argument, which is exactly what lets it be tested without a terminal.
    private static let headerLine =
        #"{"header":{"pane":"137x44","cell":"17x33","tile":"16x8","source":"1920x1200","format":"rgb"}}"#

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("krd-replay-refusal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func writeFile(_ bytes: [UInt8], _ name: String) throws {
        try Data(bytes).write(to: dir.appendingPathComponent(name))
    }

    private func writeManifest(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: dir.appendingPathComponent("manifest.jsonl"))
    }

    private func frameLine(n: Int, w: Int, h: Int, bpp: Int = 3, tMs: Double) -> String {
        String(format: "{\"n\":%d,\"w\":%d,\"h\":%d,\"bpp\":%d,\"t_ms\":%.2f}", n, w, h, bpp, tMs)
    }

    private func pixels(count: Int, seed: UInt8) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0) }
    }

    /// A recording that agrees with itself is the normal case (`--record` writes one size per line
    /// from the frame it just saved) and must never be refused: this is the replay path the
    /// benchmarks and `docs/BENCHMARK.md` §5 L4 depend on.
    func testAnIntactRecordingIsNotRefused() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 4, h: 2, tMs: 0),
            frameLine(n: 1, w: 4, h: 2, tMs: 33.3),
        ])
        try writeFile(pixels(count: 4 * 2 * 3, seed: 0x10), "000000.raw")
        try writeFile(pixels(count: 4 * 2 * 3, seed: 0x40), "000001.raw")

        let replay = try XCTUnwrap(FrameReplay.open(dir.path))
        XCTAssertNil(replay.refusal(layoutWidth: 4, layoutHeight: 2, bpp: 3),
                     "every file is exactly what its own line declares; nothing may be refused")
        XCTAssertNil(replay.refusal(0, layoutWidth: 4, layoutHeight: 2, bpp: 3))
        XCTAssertNotNil(replay.frame(0))
    }

    /// The sentence the reader gets must name the frame, the size its own line declares and the size
    /// on disk -- a number they can compare with `ls -l`. `frame(_:)` alone can only say `nil`, and
    /// `nil` was the whole bug.
    func testAShortFileIsNamedWithItsOwnDeclaredSize() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 4, h: 2, tMs: 0),
            frameLine(n: 1, w: 4, h: 3, tMs: 33.3),
        ])
        try writeFile(pixels(count: 4 * 2 * 3, seed: 0x10), "000000.raw")
        try writeFile(Array(pixels(count: 4 * 3 * 3, seed: 0x40).prefix(20)), "000001.raw")

        let replay = try XCTUnwrap(FrameReplay.open(dir.path))
        let refusal = try XCTUnwrap(replay.refusal(layoutWidth: 4, layoutHeight: 2, bpp: 3),
                                   "a 20 B file cannot stand in for the 36 B frame line 1 declares")
        XCTAssertTrue(refusal.contains("frame 1"), refusal)
        XCTAssertTrue(refusal.contains("000001.raw"), refusal)
        XCTAssertTrue(refusal.contains("20 B"), "the actual size on disk: \(refusal)")
        XCTAssertTrue(refusal.contains(replay.entries[1].declaredSize),
                      "the size its own manifest line declares: \(refusal)")
        XCTAssertTrue(refusal.contains("36 B"), refusal)
        XCTAssertNil(replay.refusal(0, layoutWidth: 4, layoutHeight: 2, bpp: 3),
                     "frame 0 is intact and must not be blamed for its neighbour")
    }

    /// A `.raw` that is not there at all is the same class of failure and gets the same treatment:
    /// named, with the size the manifest promised, instead of a silent `nil`.
    func testAMissingFileIsNamedWithItsDeclaredSize() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 4, h: 2, tMs: 0),
            frameLine(n: 1, w: 4, h: 3, tMs: 33.3),
        ])
        try writeFile(pixels(count: 4 * 2 * 3, seed: 0x10), "000000.raw")

        let replay = try XCTUnwrap(FrameReplay.open(dir.path))
        let refusal = try XCTUnwrap(replay.refusal(layoutWidth: 4, layoutHeight: 2, bpp: 3))
        XCTAssertTrue(refusal.contains("frame 1"), refusal)
        XCTAssertTrue(refusal.contains("000001.raw"), refusal)
        XCTAssertTrue(refusal.contains("missing"), refusal)
        XCTAssertTrue(refusal.contains(replay.entries[1].declaredSize), refusal)
        XCTAssertTrue(refusal.contains("36 B"), refusal)
    }

    /// Two intact files whose lines declare different sizes: `frame(_:)` now believes each line, so
    /// neither comes back `nil` -- but a replay still renders one layout, so the line that disagrees
    /// with the header is named rather than dropped by `handleFrame` without a word.
    func testAFrameFromAnotherLayoutIsRefusedRatherThanDropped() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 4, h: 2, tMs: 0),
            frameLine(n: 1, w: 4, h: 3, tMs: 33.3),
        ])
        try writeFile(pixels(count: 4 * 2 * 3, seed: 0x10), "000000.raw")
        try writeFile(pixels(count: 4 * 3 * 3, seed: 0x40), "000001.raw")

        let replay = try XCTUnwrap(FrameReplay.open(dir.path))
        XCTAssertNotNil(replay.frame(1), "frame 1 is intact at the size its own line declares")
        let refusal = try XCTUnwrap(replay.refusal(layoutWidth: 4, layoutHeight: 2, bpp: 3))
        XCTAssertTrue(refusal.contains("frame 1"), refusal)
        XCTAssertTrue(refusal.contains("4x3 px, 3 bpp"), refusal)
        XCTAssertTrue(refusal.contains("4x2 px, 3 bpp"), refusal)
        // The whole-recording check can never pass for a manifest whose lines disagree -- that is
        // exactly what it is for -- so "this one frame is fine" is the per-index call.
        XCTAssertNil(replay.refusal(1, layoutWidth: 4, layoutHeight: 3, bpp: 3),
                     "frame 1 is exactly what a 4x3 layout renders")
    }

    /// A line that declares no frame at all (a `w` of 0) makes the whole set unusable -- and it sits in
    /// the middle of the file, because a guard that only looked at the first entry would pass this case
    /// (mutation: `entries.allSatisfy(renderable)` -> `renderable(first)` stayed green while the bad line
    /// was first).
    func testAManifestLineDeclaringNoFrameIsRefused() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 4, h: 2, tMs: 0),
            frameLine(n: 1, w: 4, h: 0, tMs: 33.3),
        ])
        try writeFile(pixels(count: 4 * 2 * 3, seed: 0x10), "000000.raw")
        try writeFile(pixels(count: 4 * 2 * 3, seed: 0x40), "000001.raw")

        XCTAssertNil(FrameReplay.open(dir.path), "a middle line with no frame makes the set unusable")
    }

    /// A hand-edited line can declare a size no `Int` holds, and `Entry.byteCount` multiplies it: the
    /// manifest is refused where it is read instead of trapping the pre-flight (measured before this:
    /// `Trace/BPT trap: 5`, exit 133, where cd9ac5d exited 0). Also a middle line, for the reason above.
    func testALineWhoseSizeOverflowsIsRefusedWithoutTrapping() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 4, h: 2, tMs: 0),
            #"{"n":1,"w":100000000000,"h":100000000000,"bpp":3,"t_ms":33.33}"#,
        ])
        try writeFile(pixels(count: 4 * 2 * 3, seed: 0x10), "000000.raw")
        try writeFile(pixels(count: 4 * 2 * 3, seed: 0x40), "000001.raw")

        XCTAssertNil(FrameReplay.open(dir.path), "a size no Int holds is not a frame this build renders")
    }

    /// The replay loop's belt-and-braces branch: an index the manifest never declared has to be named
    /// rather than answered with a bare `nil`.
    func testAFrameIndexPastTheManifestIsNamedNotSilent() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 4, h: 2, tMs: 0),
        ])
        try writeFile(pixels(count: 4 * 2 * 3, seed: 0x10), "000000.raw")

        let replay = try XCTUnwrap(FrameReplay.open(dir.path))
        let refusal = try XCTUnwrap(replay.refusal(99, layoutWidth: 4, layoutHeight: 2, bpp: 3))
        XCTAssertTrue(refusal.contains("does not exist"), refusal)
    }
}
