import XCTest
import Darwin

/// The half of #133 that only a process can answer: the status the reader's script sees and the
/// sentence that reaches stderr. `ReplayRefusalTests` pins the wording of `FrameReplay.refusal(...)`;
/// the wiring that turns it into `exit(1)` lives in `runReplay`, which needs a grid, a writer and a
/// `Desk` that a unit test cannot build -- and `--replay --bench` gives exactly that from outside,
/// with no tty, no capture and no permissions.
///
/// On cd9ac5d every case below except the last replays nothing, prints the ordinary summary and exits
/// 0, so a scripted replay of a valid recording reports success while painting nothing. No other test
/// in this bundle spawns the binary, so without this file deleting the pre-flight in `runReplay`
/// leaves every other replay test green -- which is exactly why this file exists.
final class ReplayProcessTests: XCTestCase {
    /// `pane 8x4` of `cell 4x6` is 32x24 px, and a source of the same aspect keeps the grid from
    /// scaling it; 32*24*3 = 2304 B per frame.
    private static let headerLine =
        #"{"header":{"pane":"8x4","cell":"4x6","tile":"4x2","source":"64x48","format":"rgb"}}"#
    private static let frameBytes = 32 * 24 * 3
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("krd-replay-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func writeManifest(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: dir.appendingPathComponent("manifest.jsonl"))
    }

    /// Deterministic, non-zero bytes: the replay only counts and copies them, but an all-zero
    /// recording could hide a copy that never happened.
    private func writeFrame(_ index: Int, bytes: Int) throws {
        let payload = (0..<bytes).map { UInt8(truncatingIfNeeded: $0 &+ index) }
        try Data(payload).write(to: dir.appendingPathComponent(String(format: "%06d.raw", index)))
    }

    private func frameLine(n: Int, w: Int, h: Int, bpp: Int = 3, tMs: Double) -> String {
        String(format: "{\"n\":%d,\"w\":%d,\"h\":%d,\"bpp\":%d,\"t_ms\":%.2f}", n, w, h, bpp, tMs)
    }

    /// One `--replay --bench` of the temp recording: what the shell would see, i.e. the exit status
    /// plus the two streams.
    ///
    /// The streams go to **files**, not `Pipe`s: `readDataToEndOfFile` on a pipe deadlocks while this
    /// parent still holds the write end, and a deadlocked test bundle is worse than a red one.
    /// `waitUntilExit()` is avoided for the same reason -- a replay that hangs must fail here, not
    /// hang the suite -- so the child is polled and killed after the deadline.
    private func replay(extraArguments: [String] = []) throws -> (status: Int32, out: String, err: String)? {
        // The test bundle sits next to the executable it is testing. A missing binary fails loudly:
        // a silently skipped test is worse than a failing one, because this is the only place that
        // can catch a replay that reports success without painting.
        let binary = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("krd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no krd binary at \(binary.path) — run `swift build` before `swift test`")
            return nil
        }
        let out = dir.appendingPathComponent("stdout.txt")
        let err = dir.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: out)
        let errHandle = try FileHandle(forWritingTo: err)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let child = Process()
        child.executableURL = binary
        child.arguments = ["--replay", dir.path, "--bench"] + extraArguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = outHandle
        child.standardError = errHandle
        try child.run()

        let deadline = Date().addingTimeInterval(30)
        while child.isRunning, Date() < deadline { usleep(20_000) }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            // Reap it: a recycled pid must not be signalled by a later case, and the failure is
            // reported once, here.
            _ = child.waitUntilExit()
            XCTFail("krd --replay did not finish within 30 s")
            return nil
        }
        return (child.terminationStatus,
                (try? String(contentsOf: out, encoding: .utf8)) ?? "",
                (try? String(contentsOf: err, encoding: .utf8)) ?? "")
    }

    /// A file one line short of what its own manifest line declares: exit 1, no summary on stdout,
    /// and the sentence names the frame, the file and both sizes.
    func testAShortFrameFileExitsNonZeroAndNamesTheFrame() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 32, h: 24, tMs: 0),
            frameLine(n: 1, w: 32, h: 24, tMs: 33.3),
        ])
        try writeFrame(0, bytes: Self.frameBytes)
        try writeFrame(1, bytes: 2300)

        let run = try XCTUnwrap(try replay())
        XCTAssertEqual(run.status, 1, "a replay that painted nothing is not a success: \(run.err)")
        XCTAssertTrue(run.err.contains("frame 1"), run.err)
        XCTAssertTrue(run.err.contains("000001.raw"), run.err)
        XCTAssertTrue(run.err.contains("2300 B"), run.err)
        XCTAssertTrue(run.err.contains("32x24 px"), run.err)
        XCTAssertTrue(run.err.contains("2304 B"), run.err)
        XCTAssertFalse(run.out.contains("frames"),
                       "the summary must not report a replay that did not happen: \(run.out)")
    }

    /// A `.raw` that is not there: same door, and the sentence says `missing` plus the size the
    /// manifest promised.
    func testAMissingFrameFileExitsNonZeroAndNamesTheFrame() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 32, h: 24, tMs: 0),
            frameLine(n: 1, w: 32, h: 24, tMs: 33.3),
        ])
        try writeFrame(0, bytes: Self.frameBytes)

        let run = try XCTUnwrap(try replay())
        XCTAssertEqual(run.status, 1, "a replay that painted nothing is not a success: \(run.err)")
        XCTAssertTrue(run.err.contains("frame 1"), run.err)
        XCTAssertTrue(run.err.contains("000001.raw"), run.err)
        XCTAssertTrue(run.err.contains("missing"), run.err)
        XCTAssertTrue(run.err.contains("2304 B"), "the size the line promised: \(run.err)")
        XCTAssertFalse(run.out.contains("frames"), run.out)
    }

    /// A `.raw` that `stat` can size but the process cannot open: the pre-flight passes it (its size
    /// matches its line exactly), so this is the loop's own branch -- and it must blame the read, not
    /// call a present file missing or truncated.
    func testAnUnreadableFrameExitsNonZeroWithoutBlamingTheManifest() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 32, h: 24, tMs: 0),
            frameLine(n: 1, w: 32, h: 24, tMs: 33.3),
        ])
        try writeFrame(0, bytes: Self.frameBytes)
        try writeFrame(1, bytes: Self.frameBytes)
        let locked = dir.appendingPathComponent("000001.raw")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        }

        let run = try XCTUnwrap(try replay())
        XCTAssertEqual(run.status, 1, run.err)
        XCTAssertTrue(run.err.contains("could not be read"), run.err)
        XCTAssertTrue(run.err.contains("000001.raw"), run.err)
    }

    /// An empty directory: no `manifest.jsonl`, so there is nothing to replay and nothing to
    /// summarise.
    func testAnEmptyDirectoryIsRefusedWithoutASummary() throws {
        let run = try XCTUnwrap(try replay())
        XCTAssertEqual(run.status, 1, run.err)
        XCTAssertTrue(run.err.contains("no usable manifest.jsonl"), run.err)
        XCTAssertFalse(run.out.contains("frames"), run.out)
    }

    /// The recording was made with `--format rgba` and replayed without it. The `--format` hint is a
    /// refusal like any other, and it used to be thrown into the void.
    func testABppMismatchExitsNonZeroAndNamesTheFormatFlag() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 32, h: 24, bpp: 4, tMs: 0),
            frameLine(n: 1, w: 32, h: 24, bpp: 4, tMs: 33.3),
        ])
        try writeFrame(0, bytes: 32 * 24 * 4)
        try writeFrame(1, bytes: 32 * 24 * 4)

        let run = try XCTUnwrap(try replay())
        XCTAssertEqual(run.status, 1, run.err)
        XCTAssertTrue(run.err.contains("--format rgba"), run.err)
    }

    /// Two intact files whose lines disagree (32x26 then 32x24, header renders 32x24): refused before
    /// the first frame, because `handleFrame` is handed the *layout* size -- a mismatched buffer there
    /// is a memcpy past the end, not a message.
    func testAFrameFromAnotherLayoutIsRefusedBeforeTheFirstFrame() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 32, h: 26, tMs: 0),
            frameLine(n: 1, w: 32, h: 24, tMs: 33.3),
        ])
        try writeFrame(0, bytes: 32 * 26 * 3)
        try writeFrame(1, bytes: Self.frameBytes)

        let run = try XCTUnwrap(try replay())
        XCTAssertEqual(run.status, 1, "a frame from another layout has no seat in this grid: \(run.err)")
        XCTAssertFalse(run.out.contains("frames"),
                       "the summary must not report a replay that did not happen: \(run.out)")
        XCTAssertTrue(run.err.contains("frame 0"), run.err)
        XCTAssertTrue(run.err.contains("32x26 px"), run.err)
        XCTAssertTrue(run.err.contains("32x24 px"), run.err)
    }

    /// The other direction, and the one that would paint garbage: a frame *smaller* than the layout.
    /// `handleFrame` reads a buffer of the layout's size, so a short one is read past its end unless
    /// the pre-flight refuses it first.
    func testAFrameSmallerThanTheLayoutIsRefusedBeforeTheFirstFrame() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 32, h: 20, tMs: 0),
        ])
        try writeFrame(0, bytes: 32 * 20 * 3)

        let run = try XCTUnwrap(try replay())
        XCTAssertEqual(run.status, 1, run.err)
        XCTAssertFalse(run.out.contains("frames"), run.out)
        XCTAssertTrue(run.err.contains("frame 0"), run.err)
        XCTAssertTrue(run.err.contains("32x20 px"), run.err)
    }

    /// The path the benchmarks use must keep working end to end: a recording whose lines agree
    /// replays every frame and exits 0, with nothing on stderr.
    func testASingleSizeRecordingReplaysAndExitsZero() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 32, h: 24, tMs: 0),
            frameLine(n: 1, w: 32, h: 24, tMs: 33.3),
        ])
        try writeFrame(0, bytes: Self.frameBytes)
        try writeFrame(1, bytes: Self.frameBytes)

        let run = try XCTUnwrap(try replay())
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertTrue(run.out.contains("32x24"), run.out)
        // `2 frames` is the *declared* count -- the buggy build printed it while painting nothing.
        // The payload column is the only number in the summary that says a frame went through the
        // pipeline, so that is what this asserts.
        let row = try XCTUnwrap(run.out.split(separator: "\n").first { $0.hasPrefix("  bytes") },
                                "no bytes row in the summary: \(run.out)")
        let p50 = try XCTUnwrap(row.split(separator: " ").dropFirst().first.flatMap { Int($0) },
                                "the bytes row carries no number: \(row)")
        XCTAssertGreaterThan(p50, 0, "`2 frames` is the *declared* count; the payload column is the only "
                            + "one that says a frame went through the pipeline")
        XCTAssertEqual(run.err, "", "a replay that works has nothing to explain")
    }

    /// `--mirror` leaves `Log`'s sink on stderr, so the sentence must still be written exactly once:
    /// writing to the log *and* to stderr printed it twice there.
    func testTheRefusalIsSaidOnceEvenWhenTheLogSinkIsStderr() throws {
        try writeManifest([
            Self.headerLine,
            frameLine(n: 0, w: 32, h: 26, tMs: 0),
        ])
        try writeFrame(0, bytes: 32 * 26 * 3)

        let run = try XCTUnwrap(try replay(extraArguments: ["--mirror"]))
        XCTAssertEqual(run.status, 1, run.err)
        // The other `krd:` lines here are setup notices (`--bench` names the quality and scale it pins,
        // the mirror names its grid), so the sentence is what has to be counted.
        let said = run.err.split(separator: "\n").filter { $0.contains("is 32x26 px") }
        XCTAssertEqual(said.count, 1, "once, not once per destination: \(run.err)")
    }
}
