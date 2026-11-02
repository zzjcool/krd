import XCTest
import Darwin

/// Issue #206: **the mirror and the wall must agree about what a cell is worth.**
///
/// The mirror asked ScreenCaptureKit for `cells x cell` using the cell the *terminal reported* and
/// never scaled it by `dpr`, while the wall captures at `PaneGeometry.pictureCell(scale: dpr)`
/// (`cell x dpr`, `main.swift:2051-2066`). On a pane whose cell arrives in points — no `ws_xpixel`,
/// `CSI 16t` answered in points, an unattached block — that is a frame `1/dpr` of its cell box,
/// anchored top-left. Measured on the real pane this issue was filed from: a 141x56 pane of 17x33
/// device px printed
///
///     krd: mirror grid 141x44 cells at 8x16 px, pane 141x56, … frame 1128x704 px
///
/// and 1128/2397 = **47.06 %** by 704/1452 = **48.48 %** of the box those cells occupy on screen.
/// The `placeholder` rect is right, which is why no text-layer test and no screenshot of the
/// cells could see it: only the pixels inside the rect are short.
///
/// WHY a pty and not a unit test of the multiplication: the bug is not "a number was not
/// multiplied", it is that **the two pages of one pane disagreed** — the wall doubled its cell and
/// the mirror did not. The instrument that can see one process's answer end to end is the pty (same
/// reason `WallProcessTests` exists): the geometry is read from a real `winsize` and the layout is
/// the one the run really paints, printed by the run itself.
///
/// The pane is staged with `--mock` + `--pane`, so no capture and no permission is involved, and the
/// assertion is about the *log* line the layout writes — which arrives before the first frame, so
/// these tests do not measure time: they wait for a structural event (the layout line) with a
/// generous deadline, and kill the run the moment it is there (`settle`).
final class MirrorCellDprTests: XCTestCase {
    /// 141x56 of 8x16 *reported* / 17x33 *device* px: the pane and the cell from issue #206. The
    /// 2397x1452 box is what those cells occupy on the operator's screen.
    private let paneCols = 141
    private let paneRows = 56
    private let deviceCell = (w: 17, h: 33)
    /// The source the issue's log shows, so `fit`/`origin`/`rows` are the issue's numbers too.
    private let source = (w: 1512, h: 949)

    private var binary: URL {
        Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("krd")
    }

    // MARK: the instrument

    struct Layout {
        let cellCols: Int
        let cellRows: Int
        /// One cell as the run itself says it is: device pixels, since that is what a frame is made of.
        let cellW: Double
        let cellH: Double
        let frameW: Int
        let frameH: Int
        let line: String

        /// The picture's cell box in device pixels — what the frame has to be (`--scale 1`).
        var boxW: Double { Double(cellCols) * cellW }
        var boxH: Double { Double(cellRows) * cellH }
    }

    /// Run the mirror over `--mock` in a pty of the given grid and window pixels, and return the
    /// layout the run logged. `ws_xpixel`/`ws_ypixel` of 0 is the pane that reports **points**.
    private func mirrorLayout(xpixel: Int, ypixel: Int, extra: [String] = [],
                              file: StaticString = #filePath, line: UInt = #line) throws -> Layout {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no krd binary at \(binary.path) — run `swift build` before `swift test`",
                    file: file, line: line)
            throw XCTSkip("no binary")
        }
        let (master, slave) = try openPTY(cols: paneCols, rows: paneRows,
                                          xpixel: xpixel, ypixel: ypixel)
        let logPath = NSTemporaryDirectory() + "krd-206-\(UUID().uuidString).log"
        let child = Process()
        child.executableURL = binary
        child.arguments = ["--mirror", "--mock", "--pane", "\(paneCols)x\(paneRows)",
                           "--mock-size", "\(source.w)x\(source.h)", "--log", logPath] + extra
        // All three descriptors are the pty: the child's own `winsize` (the whole subject) and a
        // sink for whatever it paints, so nothing it writes can ever block on a full pipe.
        let pane = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        child.standardInput = pane
        child.standardOutput = pane
        child.standardError = pane
        try child.run()
        close(slave)
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGTERM) }
            kill(child.processIdentifier, SIGKILL)
            close(master)
            try? FileManager.default.removeItem(atPath: logPath)
        }

        // Structural wait: the layout line, not a time window. The mock path asks its capability
        // batch first (one round trip that a pty never answers, ~500 ms) and then logs; a loaded
        // runner stretches that wait, it does not change what arrives.
        let deadline = Date().addingTimeInterval(30)
        var text = ""
        var painted: [UInt8] = []
        while Date() < deadline {
            if let read = try? String(contentsOfFile: logPath, encoding: .utf8) { text = read }
            if let layout = Self.parse(text) { return layout }
            // Drain the pane: the first frame is megabytes and the child must not block on it, and a
            // usage error (or any die-early path) says so *there*, not in the log.
            painted += drain(master, timeoutMs: 20)
            if !child.isRunning { break }
        }
        XCTFail("no `mirror grid` line within 30 s (status \(child.isRunning ? "running" : "\(child.terminationStatus)")); "
                + "the log has \(text.count) B, the pane \(painted.count) B: "
                + String(decoding: painted, as: UTF8.self).suffix(400).debugDescription,
                file: file, line: line)
        throw XCTSkip("no layout line")
    }

    /// `krd: mirror grid 141x44 cells at 16x32 px (8x16 reported x2), pane 141x56, … frame 2256x1408 px`.
    /// Only the numbers are parsed: the run is free to spell its reasoning however it likes.
    static func parse(_ log: String) -> Layout? {
        guard let mirrored = log.range(of: "mirror grid ") else { return nil }
        let rest = log[mirrored.upperBound...]
        for rawLine in rest.split(separator: "\n") {
            let line = String(rawLine)
            guard let cells = matches(#"^(\d+)x(\d+) cells"#, in: line),
                  let cell = matches(#"at (\d+)x(\d+) px"#, in: line),
                  let frame = matches(#"frame (\d+)x(\d+) px"#, in: line) else { continue }
            return Layout(cellCols: Int(cells[0]) ?? 0, cellRows: Int(cells[1]) ?? 0,
                          cellW: Double(cell[0]) ?? 0, cellH: Double(cell[1]) ?? 0,
                          frameW: Int(frame[0]) ?? 0, frameH: Int(frame[1]) ?? 0,
                          line: "krd: mirror grid " + line)
        }
        return nil
    }

    private static func matches(_ pattern: String, in line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }

    /// Everything the pane has to say right now (empty when it has nothing); the caller decides
    /// whether to keep it.
    private func drain(_ master: Int32, timeoutMs: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        while poll(&descriptor, 1, Int32(timeoutMs)) > 0 {
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            let read = Darwin.read(master, &buffer, buffer.count)
            if read <= 0 { break }
            bytes += buffer[0..<read]
        }
        return bytes
    }

    private func openPTY(cols: Int, rows: Int, xpixel: Int, ypixel: Int) throws -> (Int32, Int32) {
        var master: Int32 = 0
        var slave: Int32 = 0
        // The window size is the whole point: `ws_xpixel`/`ws_ypixel` of 0 is the pane that answers
        // in points (the ssh/`CSI 16t`-in-points case), a real pixel size is the 99 % case.
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols),
                           ws_xpixel: UInt16(xpixel), ws_ypixel: UInt16(ypixel))
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "openpty failed"])
        }
        var t = termios()
        if tcgetattr(slave, &t) == 0 {
            t.c_lflag &= ~UInt(ECHO | ICANON | ISIG | IEXTEN)
            t.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
            t.c_oflag &= ~UInt(OPOST)
            t.c_cflag |= UInt(CS8)
            withUnsafeMutableBytes(of: &t.c_cc) { p in
                p[Int(VMIN)] = 1
                p[Int(VTIME)] = 0
            }
            tcsetattr(slave, TCSANOW, &t)
        }
        return (master, slave)
    }

    // MARK: #206 itself

    /// **The bug, in one number.** On a pane that reports points the frame must be `cells x cell x
    /// dpr` — the picture's cell box in device pixels — and not `cells x cell`.
    ///
    /// This failed on `8211acf` with `frame 1128x704 px` for a 2397x1452 box, i.e. exactly the
    /// 47.06 % x 48.48 % the issue measured.
    func testAPointPaneFramesItsDeviceCellBox() throws {
        let layout = try mirrorLayout(xpixel: 0, ypixel: 0)
        // The box those cells occupy on the operator's screen: 141 columns and the 44 *picture* rows
        // (not the pane's 56) of a 17x33 device cell — 2397x1452, the issue's denominator.
        let box = (w: Double(paneCols * deviceCell.w), h: Double(layout.cellRows * deviceCell.h))
        let ratioW = (Double(layout.frameW) / box.w * 10_000).rounded() / 100
        let ratioH = (Double(layout.frameH) / box.h * 10_000).rounded() / 100
        let measured = "frame \(layout.frameW)x\(layout.frameH) px in a "
            + "\(paneCols * deviceCell.w)x\(paneRows * deviceCell.h) box = "
            + "\(ratioW) % x \(ratioH) % (issue #206: 47.06 % x 48.48 % before the fix)\n  "
            + layout.line

        // The cell the frame is made of is the *device* one: the reported 8x16 was multiplied by the
        // pane's dpr (2, because no `ws_xpixel` and no `--cell`).
        XCTAssertEqual(layout.cellW, 16, "a points cell of 8x16 is 16 device px at dpr 2 — \(measured)")
        XCTAssertEqual(layout.cellH, 32, "…and 32 tall — \(measured)")

        // …so the frame is exactly that cell's box.
        XCTAssertEqual(Double(layout.frameW), layout.boxW, accuracy: 0.001, measured)
        XCTAssertEqual(Double(layout.frameH), layout.boxH, accuracy: 0.001, measured)
        XCTAssertEqual(layout.frameW, paneCols * 16,
                       "141 cells of 16 device px is 2256 px, not 1128 — \(measured)")
        XCTAssertEqual(layout.frameH, 44 * 32,
                       "44 picture rows of 32 device px is 1408 px, not 704 — \(measured)")

        // And, in the issue's own terms: the frame covers the box its cells occupy, up to the error
        // the *fallback cell* carries (8x16 is a guess; the real cell is 17x33, an aspect 6 %
        // different — `--cell 17x33` is the documented cure for that, `dpr` is the cure for this).
        XCTAssertGreaterThanOrEqual(ratioW, 94, measured)
        XCTAssertGreaterThanOrEqual(ratioH, 96, measured)
    }

    /// The other half of the same decision: the transport must not change the frame's size. With
    /// `placeholder`s the terminal fits the picture into its cells, so a short frame is only *soft*
    /// there — but "only soft" is still a quarter of the pixels on a 2x pane, and `--dpr` is
    /// documented as the quality factor.
    func testBothTransportsFrameTheSameDeviceCell() throws {
        let placeholders = try mirrorLayout(xpixel: 0, ypixel: 0, extra: ["--placeholders"])
        let pixels = try mirrorLayout(xpixel: 0, ypixel: 0, extra: ["--no-placeholders"])
        XCTAssertEqual(placeholders.frameW, pixels.frameW,
                       "U=1 and a=p must agree about the cell: \(placeholders.line) vs \(pixels.line)")
        XCTAssertEqual(placeholders.frameH, pixels.frameH,
                       "U=1 and a=p must agree about the cell: \(placeholders.line) vs \(pixels.line)")
        XCTAssertEqual(placeholders.cellCols, pixels.cellCols,
                       "same pane, same cells: \(placeholders.line) vs \(pixels.line)")
        XCTAssertEqual(placeholders.frameW, paneCols * 16, placeholders.line)
        XCTAssertEqual(placeholders.frameH, 44 * 32, placeholders.line)
    }

    /// `--dpr` is "device pixels per reported cell, i.e. picture quality". On a mirror it had no
    /// effect at all (it was read only by the wall), so two values were one run.
    func testDprMovesTheMirrorsFrame() throws {
        let one = try mirrorLayout(xpixel: 0, ypixel: 0, extra: ["--dpr", "1"])
        let two = try mirrorLayout(xpixel: 0, ypixel: 0, extra: ["--dpr", "2"])
        let three = try mirrorLayout(xpixel: 0, ypixel: 0, extra: ["--dpr", "3"])
        XCTAssertEqual(one.frameW, paneCols * 8, "--dpr 1 is the reported cell 1:1 — \(one.line)")
        XCTAssertEqual(one.frameH, 44 * 16, "--dpr 1 is the reported cell 1:1 — \(one.line)")
        XCTAssertEqual(two.frameW, paneCols * 16, "--dpr 2 — \(two.line)")
        XCTAssertEqual(two.frameH, 44 * 32, "--dpr 2 — \(two.line)")
        XCTAssertEqual(three.frameW, paneCols * 24, "--dpr 3 — \(three.line)")
        XCTAssertEqual(three.frameH, 44 * 48, "--dpr 3 — \(three.line)")
        XCTAssertGreaterThan(two.frameW, one.frameW, "the two runs must differ: \(one.line) / \(two.line)")
    }

    /// **The 99 % case pays nothing.** A terminal that reports its window in device pixels (the pty
    /// answered `ws_xpixel`, i.e. every sshd pty and every terminal that fills `TIOCGWINSZ`) already
    /// had the right cell: `dpr` is 1 there, so its frame, its cells and its bytes are today's.
    func testADeviceCellPaneIsUnchanged() throws {
        let layout = try mirrorLayout(xpixel: paneCols * deviceCell.w,
                                      ypixel: paneRows * deviceCell.h)
        XCTAssertEqual(layout.cellW, Double(deviceCell.w), "17x33 reported is 17x33 framed — \(layout.line)")
        XCTAssertEqual(layout.cellH, Double(deviceCell.h), layout.line)
        XCTAssertEqual(Double(layout.frameW), layout.boxW, accuracy: 0.001,
                       "the frame is the cell box, exactly as before — \(layout.line)")
        XCTAssertEqual(Double(layout.frameH), layout.boxH, accuracy: 0.001, layout.line)
        XCTAssertEqual(layout.frameW, paneCols * deviceCell.w, layout.line)
    }
}
