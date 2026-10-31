import XCTest
@testable import krd

/// Issue #84 read as an asymmetry: "the display mirror fills its pane, the window mirror does not".
/// A display card and a window card do **not** have two drawing paths - one `run()`, one `applyLayout`,
/// one pair of decisions - so the only place such a difference could enter is the hand-over's `argv`.
/// These tests pin both ends of that: what a window card carries, and what the mirror decides with it.
///
/// The report's command line is the fixture: `krd --scale 0.8 --quality 70`, wall page, click a window
/// card, terminal 118x73 cells of 17x33 px (Rex), picture pinned to the top-left at 80 % of the area.
final class WindowPageParityTests: XCTestCase {
    private func options(_ arguments: [String]) throws -> Options {
        try parseArguments(["/usr/local/bin/krd"] + arguments)
    }

    /// A window card has to hand the mirror *exactly* what a display card does. `013b8d3` made the
    /// settings survive the hand-over; this is the same contract for the `--window` spelling of it,
    /// which was never pinned - and a page that forgets `--scale 0.8` streams at full resolution on a
    /// link the reader has already said is slow, while one that forgets `--quality 70` spends the
    /// colour budget on top of it.
    func testAWindowCardHandsOverWhatADisplayCardDoes() throws {
        let sticky = Desk.stickyArguments(try options(["--scale", "0.8", "--quality", "70"]))
        let display = Desk.mirrorArguments(windowID: nil, cell: nil, at: (0, 2), sticky: sticky)
        let window = Desk.mirrorArguments(windowID: 950, cell: nil, at: (0, 2), sticky: sticky)

        XCTAssertEqual(display, ["--mirror", "--wall-at", "0:2", "--scale", "0.8", "--quality", "70"])
        XCTAssertEqual(window, ["--window", "950", "--wall-at", "0:2", "--scale", "0.8", "--quality", "70"])
        // The target is the only difference: `--mirror` and `--window <id>` are the same page with a
        // different filter, so everything after them has to be the same list.
        XCTAssertEqual(Array(window.dropFirst(2)), Array(display.dropFirst(1)))

        for argv in [display, window] {
            let mirror = try options(argv)
            XCTAssertFalse(mirror.wall, "\(argv)")
            XCTAssertEqual(mirror.scale, 0.8, "\(argv)")
            XCTAssertTrue(mirror.scalePinned, "\(argv)")
            XCTAssertEqual(mirror.quality.value, 70, "\(argv)")
            XCTAssertTrue(mirror.qualityPinned, "\(argv)")
            XCTAssertEqual(mirror.wallAt?.stage, 0, "and it still knows where the wall was")
            XCTAssertEqual(mirror.wallAt?.card, 2)
        }
        XCTAssertEqual(try options(display).windowQuery, nil)
        XCTAssertEqual(try options(window).windowQuery, "950")
    }

    /// The decision #84 turns on, asked for a *window* page. Neither helper takes a page or a source,
    /// so the answer cannot differ between the two pages - and on a terminal that draws one image
    /// pixel per device pixel both answers fill the picture area, which is what the issue asks for:
    ///
    ///   * `--scale 0.8` unforced: pixel placements (`a=p` with `c`/`r`), which that terminal *does*
    ///     scale into the cells (`013b8d3`), so the frame may be 80 % of the box;
    ///   * `--placeholders` forced: the transport cannot stretch, so the frame is the cell box
    ///     (`fillsCells`, `#121`) and the scale in force is 1.
    ///
    /// The second half is the one that was missing for a window source: its own pixels are fewer than
    /// the box, so a frame of `0.8 x cells` was drawn at 80 % in the box's corner. Pinned here as the
    /// *combination* (a forced transport plus a pinned scale) because that is the pair whose answer
    /// changed, not either one alone (`ScaleTransportTests` has the individual rows).
    func testAWindowPageFillsItsAreaOnEitherTransportOfATerminalThatCannotStretch() {
        XCTAssertTrue(Desk.scaleNeedsPixelPlacements(placeholdersForced: nil, pinnedScale: 0.8,
                                                     deviceCell: true),
                      "the default transport can stretch, so the scale is honoured")
        XCTAssertTrue(Desk.placeholderNeedsCellBox(placeholders: true, deviceCell: true),
                      "a forced placeholder grid cannot, so the frame is the cell box")
        XCTAssertFalse(Desk.scaleNeedsPixelPlacements(placeholdersForced: true, pinnedScale: 0.8,
                                                      deviceCell: true),
                       "an explicit --placeholders is an answer a scale may not overrule")
        // And on a terminal whose cell arrived in points the picture keeps `--scale` on the
        // placeholder transport, because that terminal fits an image into its cells (#121) - the same
        // answer on both pages, which is the point.
        XCTAssertFalse(Desk.scaleNeedsPixelPlacements(placeholdersForced: nil, pinnedScale: 0.8,
                                                      deviceCell: false))
        XCTAssertFalse(Desk.placeholderNeedsCellBox(placeholders: true, deviceCell: false))
    }
}
