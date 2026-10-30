import Foundation
import XCTest
@testable import krd

/// The replay manifest carries the frame size **per line**, and `FrameReplay` is expected to
/// believe each line about its own frame:
///
///     <dir>/manifest.jsonl   one line per frame: {"n":0,"w":2329,"h":1452,"bpp":3,"t_ms":0}
///     <dir>/000000.raw       raw pixels, exactly w*h*bpp bytes, wire format (3 = RGB)
///                                                            -- Sources/krd/Replay.swift:10-11
///
/// and `docs/BENCHMARK.md` §5 L4 promises the opposite of a silent failure for a size the replay
/// cannot reproduce: "a replay rebuilds the exact layout instead of guessing; **a mismatch is a
/// clear error, not a blank screen**".
///
/// `FrameReplay.open` does not keep the per-line size. It keeps one `width`/`height`/`bpp` that
/// the last parsed frame line wins (`Sources/krd/Replay.swift:98,116`) and `frame(_:)` then
/// requires *every* `.raw` to be exactly that size (`Sources/krd/Replay.swift:124-127`). A
/// recording whose frames disagree in size (resumed recording, two --record dirs concatenated, a
/// manifest edited by hand) therefore reports intact frames as missing, and `runReplay` answers
/// that nil with one stderr line and a `break`
/// (`Sources/krd/main.swift:2046-2049`), then prints the ordinary summary -- counting
/// `replay.entries.count`, the *declared* frames, not the replayed ones
/// (`Sources/krd/main.swift:2067`) -- and `exit(0)` (`Sources/krd/main.swift:2092`). A scripted
/// caller sees success and an empty percentile table.
///
/// Everything here is synthetic: a temp directory, a hand-written `manifest.jsonl` and tiny
/// `.raw` files. No terminal, no screen, no capture, no subprocess.
final class ReplayManifestTests: XCTestCase {
    private var dir: URL!

    /// A plausible header line, so the fixtures look like what `--record` writes
    /// (`ReplayHeader.json`, `Sources/krd/Replay.swift:30-35`). Only the frame lines matter here.
    private static let headerLine =
        #"{"header":{"pane":"137x44","cell":"17x33","tile":"16x8","source":"1920x1200","format":"rgb"}}"#

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("krd-replay-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: fixtures

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

    /// Deterministic, non-uniform bytes so a wrong geometry shows up as wrong pixels, not just a
    /// wrong count.
    private func pixels(count: Int, seed: UInt8) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0) }
    }

    // MARK: 1. per-frame sizes (RED on HEAD)

    /// Frame 0 is 4x2 rgb (24 B), frame 1 is 4x3 rgb (36 B); both `.raw` files are exactly the
    /// size their own manifest line declares, so both are intact. `open()` must not adopt one of
    /// the two sizes for both frames: `frame(0)` is not allowed to report an intact file missing.
    func testIntactFrameIsNotReportedMissingWhenManifestSizesDiffer() throws {
        let frame0 = pixels(count: 4 * 2 * 3, seed: 0x10)          // 24 B
        let frame1 = pixels(count: 4 * 3 * 3, seed: 0x40)          // 36 B
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 4, h: 2, tMs: 0),
            frameLine(n: 1, w: 4, h: 3, tMs: 33.3),
        ])
        try writeFile(frame0, "000000.raw")
        try writeFile(frame1, "000001.raw")

        let replay = try XCTUnwrap(FrameReplay.open(dir.path),
                                   "a manifest with two well-formed frame lines and matching .raw files must open")
        let declaredSizes = [frame0.count, frame1.count]

        // (a) Whatever single size it reports, it has to be one some entry actually declares --
        // and it must not have thrown a frame line away to get there.
        XCTAssertEqual(replay.entries.count, 2,
                       "open() dropped a frame line: the manifest declares 2 frames")
        let reported = replay.width * replay.height * replay.bpp
        XCTAssertTrue(declaredSizes.contains(reported),
                      "FrameReplay reports \(replay.width)x\(replay.height)x\(replay.bpp) = \(reported) B "
                      + "per frame, which no manifest line declares (entries declare \(declaredSizes))")

        // (b) The real contract: both files are intact, so neither may come back nil. HEAD fails
        // here on frame 0 -- the size of the *last* line (36 B) is applied to it, and its 24 B
        // file then looks truncated to `frame(_:)` (Sources/krd/Replay.swift:127).
        for i in replay.entries.indices {
            let expected = declaredSizes[i]
            let got = replay.frame(i)
            XCTAssertNotNil(got,
                            "frame \(i) is intact on disk (\(expected) B = its own manifest line) but "
                            + "FrameReplay.frame(\(i)) returned nil; the single width/height/bpp from the "
                            + "last manifest line (\(replay.width)x\(replay.height)x\(replay.bpp) = \(reported) B) "
                            + "is applied to every entry (Sources/krd/Replay.swift:116,127). runReplay turns "
                            + "that nil into \"frame \(i) is missing or truncated, stopping\" "
                            + "(Sources/krd/main.swift:2047) and still exit(0) (Sources/krd/main.swift:2092)")
            XCTAssertEqual(got?.count, expected,
                           "frame \(i) came back with \(got?.count ?? -1) B, its manifest line declares \(expected) B")
        }
        XCTAssertEqual(replay.frame(0), frame0, "frame 0's bytes must survive the round trip")
        XCTAssertEqual(replay.frame(1), frame1, "frame 1's bytes must survive the round trip")
    }

    // MARK: 2. a genuinely truncated file (tested and fine at this layer)

    /// The honest-error half: one declared size for both frames, but the last `.raw` is 4 bytes
    /// short of what its own manifest line promises. HEAD does the *data* right here -- `open()`
    /// succeeds and `frame(1)` returns nil instead of a short buffer, so a caller can tell before
    /// replaying that frame 1 is unusable (Sources/krd/Replay.swift:124-127, and the format doc
    /// "exactly w*h*bpp bytes", Sources/krd/Replay.swift:11). What HEAD does *not* do is report it:
    /// `runReplay` only notices inside the loop, logs one line (Sources/krd/main.swift:2047),
    /// `break`s (2048), then prints a summary counting both declared frames (2067) and exits 0
    /// (2092). That half has no cheap seam (it needs Desk + stdout capture), so it stays a note on
    /// the issue, not an assertion here.
    func testTruncatedFrameIsReportedAsUnusableNotAsShortBytes() throws {
        let frame0 = pixels(count: 4 * 2 * 3, seed: 0x10)          // 24 B, intact
        let truncated = Array(pixels(count: 4 * 2 * 3, seed: 0x40).prefix(20))   // 20 of 24 B
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 4, h: 2, tMs: 0),
            frameLine(n: 1, w: 4, h: 2, tMs: 33.3),
        ])
        try writeFile(frame0, "000000.raw")
        try writeFile(truncated, "000001.raw")

        let replay = try XCTUnwrap(FrameReplay.open(dir.path),
                                   "a manifest whose files are unreadable at open() time still opens on HEAD")
        XCTAssertEqual(replay.entries.count, 2)
        XCTAssertEqual(replay.frame(0), frame0, "the intact frame must still replay")
        XCTAssertNil(replay.frame(1),
                     "a 20 B file for a 4x2x3 = 24 B frame must not be handed to handleFrame as a frame "
                     + "(Sources/krd/Replay.swift:127 rejects it); returning it would read past the end")
    }

    // MARK: 3. a manifest that is not there (regression pin)

    /// `open()` must keep refusing the two cases the doc comment calls out -- "Manifest first;
    /// everything else (a bare directory of `*.raw`) is refused on purpose, because a frame size
    /// guessed wrong costs a full black screen" (Sources/krd/Replay.swift:89-91).
    func testMissingOrFramelessManifestIsRefused() throws {
        XCTAssertNil(FrameReplay.open(dir.path),
                     "an empty directory has no manifest.jsonl; nothing may be guessed (Replay.swift:89-91)")

        // A bare directory of `*.raw` files, no manifest at all.
        try writeFile(pixels(count: 4 * 2 * 3, seed: 0x10), "000000.raw")
        XCTAssertNil(FrameReplay.open(dir.path),
                     "a directory of .raw files without manifest.jsonl must be refused, not guessed")

        // A manifest with the header line only: recorded zero frames, so there is nothing to replay.
        try writeManifest([Self.headerLine])
        XCTAssertNil(FrameReplay.open(dir.path),
                     "a header-only manifest declares 0 frames; open() returns nil "
                     + "(Sources/krd/Replay.swift:120 requires at least one entry)")
    }
}
