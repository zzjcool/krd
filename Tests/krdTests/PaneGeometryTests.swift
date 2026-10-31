import XCTest
@testable import krd

/// `PaneGeometry` is the wall's only source of terminal geometry (design §6.9): the layout, the
/// capture size and the mouse mapping all come from one snapshot, so the properties worth pinning
/// are the ones a second source would have disagreed about.
final class PaneGeometryTests: XCTestCase {
    private let pane = PaneGeometry(cols: 137, rows: 44, cellW: 8, cellH: 16, dpr: 2,
                                    source: "test")

    /// `cellAspect` is a cell's **height over its width** - the shape `WallLayout.make` takes. The
    /// opposite convention compiles just as happily and silently fits every picture against a
    /// 1/4-as-tall cell, so it is worth a test.
    func testCellAspectIsHeightOverWidth() {
        XCTAssertEqual(pane.cellAspect, 2.0)                                  // 16 / 8
        var square = pane
        square.cellW = 10
        square.cellH = 10
        XCTAssertEqual(square.cellAspect, 1.0)
    }

    /// The quality factor multiplies *both* axes: a picture scaled on one axis only would be
    /// stretched, and `PanelImage.fit` would then fit a stretched aspect into the same box.
    func testThePictureCellScalesBothAxesByTheSameFactor() {
        let scaleTwo = pane.pictureCell(scale: 2)
        XCTAssertEqual(scaleTwo.w, 16)
        XCTAssertEqual(scaleTwo.h, 32)
        let half = pane.pictureCell(scale: 0.5)
        XCTAssertEqual(half.w, 4)
        XCTAssertEqual(half.h, 8)
        XCTAssertEqual(scaleTwo.w / scaleTwo.h, pane.cellW / pane.cellH, accuracy: 1e-12)
    }

    /// A resize report carries no new cell size: the snapshot keeps the cell it measured and takes
    /// the new grid. Re-measuring per tick is what made the wall ask `CSI 16t` once a second.
    func testAResizeKeepsTheCellAndTakesTheGrid() {
        let resized = pane.with(cols: 200, rows: 50)
        XCTAssertEqual(resized.cols, 200)
        XCTAssertEqual(resized.rows, 50)
        XCTAssertEqual(resized.cellW, pane.cellW)
        XCTAssertEqual(resized.cellH, pane.cellH)
        XCTAssertEqual(resized.source, pane.source)
    }

    /// A terminal that answers 0x0 for its grid (or a resize to nothing) must not divide by zero
    /// later: both axes are at least one cell.
    func testAGridIsNeverEmpty() {
        let empty = pane.with(cols: 0, rows: 0)
        XCTAssertEqual(empty.cols, 1)
        XCTAssertEqual(empty.rows, 1)
    }

    /// A placeholder probe's reply echoes the request, so an accepted placement answers
    /// `i=31,p=1;OK`. Reading only `i=31;OK` made an accepting terminal look like a silent one, and
    /// the wall then drew its pictures one image pixel per device pixel - half size, in the corner.
    func testThePlaceholderProbeVerdictReadsTheEchoedParameters() {
        XCTAssertEqual(TermGeometry.placeholderProbeVerdict("\u{1B}_Gi=31,p=1;OK\u{1B}\\"), true)
        XCTAssertEqual(TermGeometry.placeholderProbeVerdict("\u{1B}_Gi=31;OK\u{1B}\\"), true)
        XCTAssertEqual(TermGeometry.placeholderProbeVerdict("\u{1B}_Gi=31,p=1;EINVAL:bad\u{1B}\\"), false)
        XCTAssertNil(TermGeometry.placeholderProbeVerdict(nil), "no answer")
        XCTAssertNil(TermGeometry.placeholderProbeVerdict(""), "empty answer")
        XCTAssertNil(TermGeometry.placeholderProbeVerdict("\u{1B}_Gi=7,p=1;OK\u{1B}\\"),
                     "another image's reply is not ours")
        XCTAssertNil(TermGeometry.placeholderProbeVerdict("\u{1B}_Gi=31,p=1"), "a partial line")
    }

    // MARK: - paint before probing (issue #99)

    /// The first paint's measurement: with `askTerminal: false` the wall must not sit in a
    /// `CSI 16t`/`14t` query - a terminal may take 500 ms to answer, or never - so it takes the
    /// assumed cell and says in the log which assumption that was.
    ///
    /// The `--cell` and `ws_xpixel` branches need no query, so they keep winning here; the assertion
    /// on `source` is therefore about the *branch* as well. A test host with a tty reports its own
    /// pixel size, and then the pty is the right answer - the exact assumed string is asserted on the
    /// no-pixel-size hosts (CI, ssh), which is the case the first paint exists for.
    func testTheFirstPaintAssumesTheCellWithoutAskingTheTerminal() {
        var lines: [String] = []
        let pane = PaneGeometry.measure(cell: nil, grid: (cols: 137, rows: 44), dpr: nil,
                                        askTerminal: false) { lines.append($0) }
        XCTAssertEqual(lines.count, 1, "one line per measurement, for the bug report")
        XCTAssertFalse(pane.source.hasPrefix("measured from the terminal"),
                       "askTerminal: false ran the cell query; got \"\(pane.source)\"")
        XCTAssertFalse(lines[0].contains("measured from the terminal"),
                       "the log line claimed a terminal answer the first paint never waited for")
        let pty = TermGeometry.read()
        if pty.pixelWidth == 0 || pty.pixelHeight == 0 {
            XCTAssertEqual(pane.source, "assumed (the cell probe runs behind the first paint)")
            XCTAssertEqual(pane.cellW, TermGeometry.fallbackCell.w)
            XCTAssertEqual(pane.cellH, TermGeometry.fallbackCell.h)
            XCTAssertEqual(pane.dpr, 2, "the pixel path's quality multiplier, unchanged")
        }
    }

    /// `--cell` is a pin, not a fallback: it beats every measurement, the first paint's assumed one
    /// included. Losing that would make `--cell 17x33` a slow way to say nothing - and the pixels
    /// the reader typed are device pixels, so no `dpr` doubling either.
    func testAPinnedCellStillWinsWhenTheQueryIsSkipped() {
        let pane = PaneGeometry.measure(cell: (w: 17, h: 33), grid: (cols: 137, rows: 44),
                                        dpr: nil, askTerminal: false) { _ in }
        XCTAssertEqual(pane.source, "--cell")
        XCTAssertEqual(pane.cellW, 17)
        XCTAssertEqual(pane.cellH, 33)
        XCTAssertEqual(pane.dpr, 1)
    }

    /// The second measurement is allowed to answer "nothing moved" (a silent terminal): its fallback
    /// is named differently on purpose, and that sentence must not count as a move - a repaint there
    /// would re-capture every panel to draw the frame that is already on screen.
    func testTheTwoFallbackSentencesAreTheSameGeometry() {
        let assumed = PaneGeometry(cols: 137, rows: 44, cellW: 8, cellH: 16, dpr: 2,
                                   source: "assumed (the cell probe runs behind the first paint)")
        let silent = PaneGeometry(cols: 137, rows: 44, cellW: 8, cellH: 16, dpr: 2,
                                  source: "assumed (the terminal did not answer)")
        XCTAssertNotEqual(assumed, silent, "the log sentences really are different")
        XCTAssertFalse(assumed.paintsDifferently(from: silent))
        // A cell that did move is a move, and so is a grid.
        var wider = silent
        wider.cellW = 17
        XCTAssertTrue(assumed.paintsDifferently(from: wider))
        XCTAssertTrue(assumed.paintsDifferently(from: silent.with(cols: 120, rows: 44)))
    }
}
