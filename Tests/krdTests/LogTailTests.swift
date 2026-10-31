import XCTest
@testable import krd

/// What the log panel is handed. The panel shows a *window* onto this array and anchors a log at its
/// end (#118), so "the last element is the newest line" has to be true of the array itself.
///
/// The rule that needs a test is the trailing newline: a log file ends in one, and that newline does
/// not start a line. Counting it made the tail one entry longer than the file, and an end-anchored
/// window then spent one of its rows on a blank — at 137x44 that is one of eleven lines.
final class LogTailTests: XCTestCase {
    func testTheNewestLineIsLast() {
        let tail = Log.tail(of: "a\nb\nc\n", lines: 12)
        XCTAssertEqual(tail, ["a", "b", "c"])
        XCTAssertEqual(tail.last, "c", "the newest line is the last one")
    }

    /// A blank line in the middle is a line, and an EOF with no newline is a line: only the newline
    /// that *terminates* the last line is dropped.
    func testBlankLinesInsideAreKeptAndAnUnterminatedLastLineSurvives() {
        XCTAssertEqual(Log.tail(of: "a\n\nb\n", lines: 12), ["a", "", "b"])
        XCTAssertEqual(Log.tail(of: "a\nb", lines: 12), ["a", "b"], "no final newline: nothing to drop")
        XCTAssertEqual(Log.tail(of: "", lines: 12), [], "an empty file has no lines")
    }

    /// The window is the tail, and its size is the caller's: twelve by default, fewer when asked.
    func testItKeepsTheLastLinesOnly() {
        let text = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        XCTAssertEqual(Log.tail(of: text, lines: 12).count, 12)
        XCTAssertEqual(Log.tail(of: text, lines: 12).last, "line 30")
        XCTAssertEqual(Log.tail(of: text, lines: 3), ["line 28", "line 29", "line 30"])
        XCTAssertEqual(Log.tail(of: text, lines: 0), [])
    }
}

/// The reader behind `Log.readLogTail`: a tick must cost what the writer added, not what the session
/// has written so far, while the panel still gets the same twelve lines it always got (#90).
///
/// These drive a real file in a temporary directory rather than a mock: the three cases that were
/// wrong in the first draft of the reader are all about the file *changing under it* (a truncation,
/// a rotation onto another inode, a line that is only half written), and a mock would have to
/// reproduce exactly the kernel behaviour the bug was about.
final class LogTailReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("krd-logtail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String = "krd.log") -> String {
        dir.appendingPathComponent(name).path
    }

    @discardableResult
    private func append(_ text: String, to file: String? = nil) throws -> String {
        let target = file ?? path()
        if !FileManager.default.fileExists(atPath: target) {
            FileManager.default.createFile(atPath: target, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: target))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        return target
    }

    /// The panel's contract, unchanged by this rewrite: the newest twelve lines, newest last, and a
    /// file that grows one line at a time ends up with the same array the whole-file read produced.
    func testItHandsBackTheSameTwelveLinesAsTheWholeFileRead() throws {
        let file = path()
        FileManager.default.createFile(atPath: file, contents: nil)
        var reader = LogTailReader()
        var seen: [String] = []
        for i in 1...40 {
            try append("line \(i)\n", to: file)
            seen = reader.update(path: file)
        }
        XCTAssertEqual(seen.count, 12, "twelve rows, as `readLogTail`'s default window")
        XCTAssertEqual(seen.last, "line 40", "the newest line is the last one")
        XCTAssertEqual(seen.first, "line 29")
        XCTAssertEqual(seen, Log.tail(of: (1...40).map { "line \($0)\n" }.joined(), lines: 12),
                       "same array as the whole-file read the panel had before, not merely as many rows")
    }

    /// The point of the rewrite: a tick that finds nothing new hands back the lines it already has
    /// without touching the file, and a tick that finds one line does not re-read the rest.
    func testAnUnchangedFileIsNotReadAgain() throws {
        let file = try append("a\nb\nc\n")
        var reader = LogTailReader()
        let first = reader.update(path: file)
        XCTAssertEqual(first, ["a", "b", "c"])
        XCTAssertEqual(reader.update(path: file), first, "nothing was written: same answer")
        XCTAssertEqual(reader.update(path: nil), [], "no `--debug`/`--log`: the panel's empty state")
    }

    /// A truncated (or `: > file`-truncated) log must not keep showing lines that are no longer in
    /// it, and it must not be read from the stale offset either: the reader re-anchors on what is
    /// there now.
    func testATruncatedFileIsReReadFromTheStart() throws {
        let file = path()
        FileManager.default.createFile(atPath: file, contents: nil)
        var reader = LogTailReader()
        for i in 1...5 { try append("old \(i)\n", to: file) }
        XCTAssertEqual(reader.update(path: file).last, "old 5")
        try "fresh 1\nfresh 2\n".write(toFile: file, atomically: false, encoding: .utf8)
        let after = reader.update(path: file)
        XCTAssertEqual(after, ["fresh 1", "fresh 2"], "no line of the pre-truncation file survives")
    }

    /// Rotation: the path is a different file now (another inode, its own content). Coming back with
    /// the old lines would be a panel describing a log that no longer exists.
    func testARotatedFileIsFollowedByPath() throws {
        let file = path()
        FileManager.default.createFile(atPath: file, contents: nil)
        var reader = LogTailReader()
        try append("before 1\nbefore 2\n", to: file)
        XCTAssertEqual(reader.update(path: file), ["before 1", "before 2"])
        let rotated = path("krd.log.1")
        try FileManager.default.moveItem(atPath: file, toPath: rotated)
        try append("after 1\nafter 2\nafter 3\n", to: file)
        XCTAssertEqual(reader.update(path: file), ["after 1", "after 2", "after 3"],
                       "the tail of the file the path names now")
    }

    /// A line the writer has not finished is not painted and then replaced: the panel shows the last
    /// *complete* line, and the rest appears all at once when its newline does.
    func testAHalfWrittenLineIsHeldBackUntilItsNewlineArrives() throws {
        let file = try append("done 1\ndone 2\nhalf wr")
        var reader = LogTailReader()
        XCTAssertEqual(reader.update(path: file), ["done 1", "done 2"],
                       "half a line is not a line: showing it and then completing it is the jump")
        try append("itten\n", to: file)
        XCTAssertEqual(reader.update(path: file), ["done 1", "done 2", "half written"])
    }

    /// A file that holds one unterminated line has nothing else to show, so that line is the tail --
    /// `Log.tail`'s "no final newline" rule, kept for the file the reader is pointed at.
    func testAFileWithOneUnterminatedLineStillShowsIt() throws {
        let file = try append("the only line")
        var reader = LogTailReader()
        XCTAssertEqual(reader.update(path: file), ["the only line"])
    }

    /// A byte that is not UTF-8 must not take the panel down with it. The read this replaces was
    /// `try? String(contentsOfFile:path:encoding:.utf8)`, whose `nil` the guard turned into `[]`:
    /// one bad byte meant *every* line was blanked, not just the ones after it. Decoding lossily
    /// keeps the surrounding bytes and the twelve rows.
    func testANonUTF8ByteDoesNotBlankThePanel() throws {
        let file = try append("before\n")
        var reader = LogTailReader()
        XCTAssertEqual(reader.update(path: file), ["before"])
        let bad = Data([0x62, 0x61, 0x64, 0x20, 0xFF, 0xFE, 0x0A])       // "bad <FF><FE>\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        try handle.seekToEnd()
        try handle.write(contentsOf: bad)
        try handle.close()
        let after = reader.update(path: file)
        XCTAssertEqual(after.count, 2, "the bad line is a row, not the end of the panel")
        XCTAssertEqual(after.first, "before")
        XCTAssertTrue(after.last?.hasPrefix("bad ") == true)
        XCTAssertTrue(after.last?.unicodeScalars.contains("\u{FFFD}") == true,
                      "the replacement character, which the panel measures as one cell")
    }

    /// A log bigger than the reader's window: the tail comes from the end of the file, not from the
    /// first twelve lines of it, and appending one line afterwards is all that has to be read.
    func testAFileBiggerThanTheWindowShowsItsEnd() throws {
        let file = path()
        FileManager.default.createFile(atPath: file, contents: nil)
        let filler = String(repeating: "filler line to make the file longer than the window\n",
                            count: 4000)                       // ~228 KB, well past `windowBytes`
        try append(filler, to: file)
        for i in 1...20 { try append("tail \(i)\n", to: file) }
        var reader = LogTailReader()
        let tail = reader.update(path: file)
        XCTAssertEqual(tail.count, 12)
        XCTAssertEqual(tail.last, "tail 20")
        XCTAssertEqual(tail.first, "tail 9")
        try append("tail 21\n", to: file)
        XCTAssertEqual(reader.update(path: file).last, "tail 21")
    }

    /// A window that starts in the middle of a line drops that partial line whole -- and, since the
    /// window is a byte offset and a line is bytes, it can start in the middle of a *character* too.
    ///
    /// The previous version of this test could not tell: it filled the file with 52-byte lines, so the
    /// 64 KB window held ~1260 of them and the twelve-row window threw the fragment away anyway; the
    /// test passed with the rule deleted. Here the lines are 6001 bytes, so the window holds ten whole
    /// lines -- fewer than the twelve the panel shows -- and a fragment would be the *first row*.
    func testAWindowThatStartsMidLineDropsThePartialLineWhole() throws {
        // 6001 bytes a line: four digit prefix, 470 filler, a 3-byte `€`, 5523 filler, newline. The
        // `€` sits at payload offset 474, and the window starts one byte into it, so a window read
        // without the rule decodes it as replacement characters and shows half a line.
        func line(_ i: Int) -> String {
            String(format: "%04d", i) + String(repeating: "a", count: 470) + "\u{20AC}"
                + String(repeating: "b", count: 5523) + "\n"
        }
        var text = ""
        for i in 1...22 { text += line(i) }
        XCTAssertEqual(Data(text.utf8).count, 22 * 6001, "the file is bigger than one window")
        let file = try append(text)
        let boundary = Data(text.utf8).count - LogTailReader.windowBytes
        XCTAssertEqual(boundary % 6001, 475, "the window starts one byte into a 3-byte character")

        var reader = LogTailReader()
        let rows = reader.update(path: file)
        XCTAssertEqual(rows.count, 10, "ten whole lines in the window, not twelve and not a fragment")
        let whole = { (i: Int) in String(line(i).dropLast()) }
        XCTAssertEqual(rows.first, whole(13), "the first row is a whole line")
        XCTAssertEqual(rows.last, whole(22))
        XCTAssertFalse(rows.joined().unicodeScalars.contains("\u{FFFD}"),
                       "no character was cut in half on the window's edge")
    }

    /// A diff that grew the file past what one continuation digests (16 KB) is a re-anchor, not a read
    /// from the old offset: the gap could not reach twelve rows anyway. The PR's table cited
    /// `testAFileBiggerThanTheWindowShowsItsEnd` for this row, but that test re-anchors a *fresh*
    /// reader on its first tick -- a reader that already has an offset takes the other branch.
    func testAGapBiggerThanTheContinuationReAnchors() throws {
        let file = path()
        FileManager.default.createFile(atPath: file, contents: nil)
        var reader = LogTailReader()
        try append("first\n", to: file)
        XCTAssertEqual(reader.update(path: file), ["first"])
        var burst = ""
        for i in 1...2000 { burst += "burst \(i)\n" }
        XCTAssertGreaterThan(Data(burst.utf8).count, LogTailReader.appendBytes, "more than one continuation")
        try append(burst, to: file)
        let rows = reader.update(path: file)
        XCTAssertEqual(rows.count, 12)
        XCTAssertEqual(rows.last, "burst 2000")
        XCTAssertEqual(rows, Log.tail(of: "first\n" + burst, lines: 12),
                       "the same twelve lines the whole-file read would give")
    }

    /// A file truncated and refilled past the old offset between two ticks. `stat` reports it as the
    /// same `(device, inode)`, larger than the offset the buffer has already read -- which is exactly
    /// what an append looks like. Taken for an append, the read starts at the old offset, which is now
    /// in the middle of the new file's third line, and the panel keeps that fragment (and the line it
    /// remembers from the old file) as its oldest rows for good: `read` has moved past it and no later
    /// tick looks back. The bytes just before the offset are the evidence `stat` cannot give.
    func testATruncateAndRefillPastTheOldOffsetIsNotAnAppend() throws {
        // 100 bytes and no newline: one unterminated line, so the whole file is in the buffer.
        let before = String(repeating: "old ", count: 25)
        let file = try append(before)
        var reader = LogTailReader()
        XCTAssertEqual(reader.update(path: file), [before], "one line, and it is the tail")

        // Inside one tick: truncate, then write 200 bytes -- five 40-byte lines, which puts the old
        // offset of 100 twenty bytes into the third one.
        var after = ""
        for i in 1...5 {
            let head = String(format: "new %02d ", i)
            after += head + String(repeating: "x", count: 39 - head.count) + "\n"
        }
        XCTAssertEqual(Data(after.utf8).count, 200)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(after.utf8))
        try handle.close()

        let rows = reader.update(path: file)
        XCTAssertEqual(rows, Log.tail(of: after, lines: 12), "the tail of the file that is there now")
        XCTAssertEqual(rows.count, 5, "five lines, not the two rows a mid-file read would give")
        XCTAssertEqual(rows.last?.hasPrefix("new 05"), true)
        XCTAssertTrue(rows.allSatisfy { $0.count == 39 }, "every row is a whole line, not a fragment")
        XCTAssertEqual(reader.update(path: file), rows, "and the next tick does not move it")
    }

    /// A file rewritten in place at the same length: nothing about the size moved, so only `mtime` --
    /// already part of the identity -- says the bytes in the buffer are not the bytes in the file.
    func testAnInPlaceRewriteAtTheSameLengthIsReRead() throws {
        let file = try append("aaaa 1111\nbbbb 2222\n")
        var reader = LogTailReader()
        XCTAssertEqual(reader.update(path: file), ["aaaa 1111", "bbbb 2222"])
        Thread.sleep(forTimeInterval: 0.01)                     // a different mtime, the same size
        let rewritten = "cccc 3333\ndddd 4444\n"
        XCTAssertEqual(rewritten.utf8.count, "aaaa 1111\nbbbb 2222\n".utf8.count, "same length")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(rewritten.utf8))      // no truncate: same length, same inode
        try handle.close()
        XCTAssertEqual(reader.update(path: file), ["cccc 3333", "dddd 4444"],
                       "the bytes that are there now, not the ones that were")
    }
}
