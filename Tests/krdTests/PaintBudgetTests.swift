import XCTest
import krdcore
@testable import krd

/// `--paint-budget` bounds **one block**, so a full repaint is unrolled top to bottom instead of
/// arriving as a single commit the terminal may not finish.
///
/// Measured (issue #257, do not re-litigate): 140x45 cells = 18x12 = 216 tiles, all of them in one
/// `?2026h … ?2026l` block, is 2.17 MiB -- 0.9 s on a 20 Mbit/s link. The terminal answered `OK` to
/// every image and every placement (`bad=0`) and drew a row-major *prefix* of them, ~108 tiles, 6 of
/// the 12 tile rows. krd only re-sends a tile when its pixels change, so the rest of the picture stays
/// the terminal's background colour for good: a staircase of black at the bottom, in whole tile
/// rectangles.
///
/// The decisions behind the fix are all pure, and three of them are invariants rather than tuning:
///
///  1. the five test/bench paths keep **exactly today's bytes** (`paintBudget`);
///  2. a pass may only be cells-only when the *reason* it was created says so (`oweReason`) -- a
///     quality click that re-places instead of re-encoding would silently do nothing;
///  3. a changed tile is never dropped by the budget (`paintChunk`): `previousFrame` already holds
///     that frame, so a tile the budget refused would never come back.
///
/// Pinned here rather than in a pty test because nothing in these three needs a terminal, a capture,
/// or a lock: they are statements about lists.
final class PaintBudgetTests: XCTestCase {

    // MARK: - the rule that pins the test paths (case 1)

    /// One number, and the paths that must not see it. Each case is a byte contract: `--selftest`'s
    /// sha256, `--bench`/`--bench-wire`'s per-frame measurements, `--replay`'s recorded stream, and
    /// `--pane`, which every process test in `Tests/` passes.
    func testTheTestAndBenchPathsKeepOneBlock() {
        let cases: [(String, (selftest: Bool, bench: Bool, benchWire: Bool, replay: Bool, pane: Bool))] = [
            ("--selftest", (true, false, false, false, false)),
            ("--bench", (false, true, false, false, false)),
            ("--bench-wire", (false, false, true, false, false)),
            ("--replay", (false, false, false, true, false)),
            ("--pane", (false, false, false, false, true)),
        ]
        for (name, flags) in cases {
            let budget = paintBudget(selftest: flags.selftest, bench: flags.bench,
                                     benchWire: flags.benchWire, replay: flags.replay,
                                     pane: flags.pane, requested: 128)
            XCTAssertEqual(budget.kib, 0, "\(name) must keep one block")
            XCTAssertEqual(budget.pinnedBy, name, "and the line has to name the flag that did it")
        }
    }

    /// A live run keeps the number it was given -- including `0`, which is how "one block, exactly as
    /// before" is spelled on a command line. A negative count is normalised, not refused: the parser
    /// is where a non-number is a usage error.
    func testALiveRunKeepsItsNumber() {
        let none = paintBudget(selftest: false, bench: false, benchWire: false, replay: false,
                               pane: false, requested: 128)
        XCTAssertEqual(none.kib, 128)
        XCTAssertNil(none.pinnedBy, "nothing pinned it: the flag is the user's")

        XCTAssertEqual(paintBudget(selftest: false, bench: false, benchWire: false, replay: false,
                                   pane: false, requested: 0).kib, 0)
        XCTAssertEqual(paintBudget(selftest: false, bench: false, benchWire: false, replay: false,
                                   pane: false, requested: -40).kib, 0)
    }

    /// The default itself: 128 KiB is ~10 average tiles in one commit, and the number a report of
    /// "the bottom of my picture is black" is answered with. Asserted, because "the default is 128"
    /// would otherwise be a comment.
    func testTheDefaultIs128KiB() {
        XCTAssertEqual(Options().paintBudgetKiB, 128)
        XCTAssertEqual(Options.defaultPaintBudgetKiB, 128)
    }

    func testTheFlagAndTheParserAgree() throws {
        XCTAssertEqual(try parseArguments(["krd"]).paintBudgetKiB, 128)
        XCTAssertEqual(try parseArguments(["krd", "--paint-budget", "512"]).paintBudgetKiB, 512)
        XCTAssertEqual(try parseArguments(["krd", "--paint-budget", "0"]).paintBudgetKiB, 0)
        // A negative count is clamped like `--fps 0` is, not refused; a non-number is a usage error
        // that names the flag (issue #122's rule for every value-taking flag).
        XCTAssertEqual(try parseArguments(["krd", "--paint-budget", "-4"]).paintBudgetKiB, 0)
        XCTAssertThrowsError(try parseArguments(["krd", "--paint-budget", "lots"]))
        XCTAssertThrowsError(try parseArguments(["krd", "--paint-budget"]))
    }

    // MARK: - cells-only or not (case 2)

    /// `oweReason` is the whole of "may this pass skip the pixels": `.movedLayout` **only** when the
    /// pixel slicing is unchanged, the terminal still holds its images, and nobody asked for a
    /// re-encode. Every other combination owes pixels.
    func testOnlyAMovedPictureMayGoCellsOnly() {
        var cellsOnly: [(Bool, Bool, Bool)] = []
        for signatureChanged in [false, true] {
            for repaintNeeded in [false, true] {
                for explicitReencode in [false, true] {
                    let reason = Desk.oweReason(signatureChanged: signatureChanged,
                                                repaintNeeded: repaintNeeded,
                                                explicitReencode: explicitReencode)
                    if reason == .movedLayout { cellsOnly.append((signatureChanged, repaintNeeded, explicitReencode)) }
                }
            }
        }
        XCTAssertEqual(cellsOnly.count, 1, "exactly one of the eight cases is a cells-only pass")
        XCTAssertEqual(cellsOnly.first?.0, false)
        XCTAssertEqual(cellsOnly.first?.1, false)
        XCTAssertEqual(cellsOnly.first?.2, false)
    }

    /// Each of the three inputs on its own -- the three failure modes the plan names, one per line:
    /// a resize re-slices the frame, a `clear()` wipes the store (`a=d,d=a`), and a menu rung exists
    /// because the pixels must be encoded again.
    func testEachWrongReasonOwesPixels() {
        XCTAssertEqual(Desk.oweReason(signatureChanged: true, repaintNeeded: false,
                                      explicitReencode: false), .repaint)
        XCTAssertEqual(Desk.oweReason(signatureChanged: false, repaintNeeded: true,
                                      explicitReencode: false), .repaint)
        XCTAssertEqual(Desk.oweReason(signatureChanged: false, repaintNeeded: false,
                                      explicitReencode: true), .repaint)
        XCTAssertEqual(Desk.oweReason(signatureChanged: false, repaintNeeded: false,
                                      explicitReencode: false), .movedLayout)
    }

    // MARK: - the greedy chunk (case 3)

    /// The byte budget is real, and the changed tiles are spent first: with 8 KiB per tile and a 20 KiB
    /// budget a block is two tiles, so a 6-tile repaint takes three blocks.
    func testTheBlockIsSizedByBytes() {
        let taken = Desk.paintChunk(changed: [], owed: [0, 1, 2, 3, 4, 5], mode: .transmit,
                                    tileCount: 6, cap: 20 * 1024, bytes: { _ in 8 * 1024 })
        XCTAssertEqual(taken.chunk.map(\.index), [0, 1])
        XCTAssertEqual(taken.rest, [2, 3, 4, 5], "the rest stays owed, in order")
        XCTAssertEqual(taken.mode, .transmit)
    }

    /// A tile bigger than the whole budget is still painted -- "at least one tile" -- or a picture of
    /// huge tiles would never be painted at all.
    func testOneTileIsAlwaysTaken() {
        let taken = Desk.paintChunk(changed: [], owed: [3], mode: .transmit, tileCount: 9,
                                    cap: 1024, bytes: { _ in 4 * 1024 * 1024 })
        XCTAssertEqual(taken.chunk.map(\.index), [3])
        XCTAssertTrue(taken.rest.isEmpty)
    }

    /// The failure the plan is explicit about: the scan found more changes than one block can hold.
    /// Those tiles must become *owed* -- and the pass must become a transmit pass -- because
    /// `previousFrame` already holds this frame: a dropped tile would never be seen as dirty again.
    func testAChangedTileTheBudgetRefusesIsOwedNotLost() {
        let taken = Desk.paintChunk(changed: [0, 1, 2], owed: [1, 4], mode: .cellsOnly,
                                    tileCount: 8, cap: 8 * 1024, bytes: { _ in 8 * 1024 })
        XCTAssertEqual(taken.chunk.map(\.index), [0], "the first changed tile, and always one")
        XCTAssertEqual(taken.chunk.map(\.mode), [.transmit], "a changed tile carries its pixels")
        XCTAssertEqual(taken.rest, [1, 2, 4], "2 was refused by the budget; 1 was owed and is not doubled")
        XCTAssertEqual(taken.mode, .transmit, "one list has one mode, and it has to send pixels")
    }

    /// A tile that is both changed and owed is painted **once**, as a change -- its pixels are the
    /// newer ones, so the cells-only placement would draw the stale image.
    func testAChangedTileIsNotPaintedTwice() {
        let taken = Desk.paintChunk(changed: [2], owed: [2, 3], mode: .cellsOnly, tileCount: 6,
                                    cap: 0, bytes: { _ in 1024 })
        XCTAssertEqual(taken.chunk.map(\.index), [2, 3])
        XCTAssertEqual(taken.chunk.map(\.mode), [.transmit, .cellsOnly])
        XCTAssertTrue(taken.rest.isEmpty)
    }

    /// `cap == 0` is `--paint-budget 0`: one block, everything, no ceiling.
    func testAZeroBudgetTakesEverything() {
        let taken = Desk.paintChunk(changed: [0, 1], owed: [0, 1, 2, 3], mode: .transmit,
                                    tileCount: 4, cap: 0, bytes: { _ in 100 * 1024 * 1024 })
        XCTAssertEqual(taken.chunk.map(\.index), [0, 1, 2, 3])
        XCTAssertTrue(taken.rest.isEmpty)
    }

    /// A stale index (an owed list from a bigger grid) is never painted and never kept: it belongs to
    /// a layout that is gone, and keeping it would make the queue a loop that never drains.
    func testAnIndexTheGridNoLongerHasIsDropped() {
        let taken = Desk.paintChunk(changed: [9], owed: [0, 7], mode: .transmit, tileCount: 2,
                                    cap: 0, bytes: { _ in 1024 })
        XCTAssertEqual(taken.chunk.map(\.index), [0])
        XCTAssertTrue(taken.rest.isEmpty)
    }

    // MARK: - the rows a panel vacates

    /// Opening a panel shrinks the area the picture may use, so `applyLayout` re-centres it (measured:
    /// `originRow` 15 -> 12 on the display page this issue was reported on). The rows the old box
    /// covered and the new one does not still hold `U+10EEEE`, and such a cell keeps drawing its
    /// image -- those are exactly the rows `eraseRows` has to clear.
    ///
    /// 800x272 px of desk in a 100x40 cell pane: a 100x17-cell picture centred at row 12 (the number
    /// the issue measured), and the same picture in the 37 rows a three-row panel leaves -- centred
    /// at row 11, so row 28 is vacated.
    func testAMovedUpPictureVacatesItsBottomRow() {
        let whole = grid(area: (top: 1, rows: 40), aspect: 3.0)
        let withPanel = grid(area: (top: 1, rows: 37), aspect: 3.0)
        XCTAssertEqual(whole.originRow, 12)
        XCTAssertEqual(whole.paneRows, 17)
        XCTAssertEqual(withPanel.originRow, 11)
        XCTAssertEqual(Desk.vacatedRows(from: whole, to: withPanel, paneRows: 40), [28..<29])
    }

    /// A picture that shrank *in place* leaves rows on both sides: two ranges, and the rows the new
    /// box covers between them must not be in either (erasing those would erase the picture).
    func testAPictureThatShrankInPlaceVacatesBothSides() {
        let wide = grid(area: (top: 1, rows: 40), aspect: 3.0)      // 17 rows at row 12: 12...28
        let boxy = grid(area: (top: 1, rows: 40), aspect: 6.0)      // 8 rows at row 17: 17...24
        XCTAssertEqual(wide.originRow, 12)
        XCTAssertEqual(boxy.originRow, 17)
        XCTAssertEqual(boxy.paneRows, 8)
        XCTAssertEqual(Desk.vacatedRows(from: wide, to: boxy, paneRows: 40), [12..<17, 25..<29])
        // ...and nothing the new picture covers is erased.
        let covered = boxy.originRow ..< (boxy.originRow + boxy.paneRows)
        for range in Desk.vacatedRows(from: wide, to: boxy, paneRows: 40) {
            for row in range {
                XCTAssertFalse(covered.contains(row), "row \(row) is part of the new picture")
            }
        }
    }

    /// No move, no erase: a picture that kept its rows owes no erasing at all, and a first layout has
    /// nothing to compare against.
    func testAStillPictureVacatesNothing() {
        let a = grid(area: (top: 1, rows: 40), aspect: 3.0)
        let b = grid(area: (top: 1, rows: 40), aspect: 3.0)
        XCTAssertTrue(Desk.vacatedRows(from: a, to: b, paneRows: 40).isEmpty)
        XCTAssertTrue(Desk.vacatedRows(from: nil, to: a, paneRows: 40).isEmpty)
    }

    /// A range is clamped to the pane: a row the terminal does not have is never addressed. Both
    /// halves matter -- the band that is only *partly* inside is cut at the pane's last row (which is
    /// a row like any other and *is* erased: the exclusive upper bound is `paneRows + 1`, and `2K`
    /// cannot arm a wrap), and a band entirely outside is dropped rather than clipped up to row 0.
    func testVacatedRowsAreClampedToThePane() {
        let wide = grid(area: (top: 1, rows: 40), aspect: 3.0)      // 12...28
        let boxy = grid(area: (top: 1, rows: 40), aspect: 12.0)     // 4 rows at row 19: 19...22
        XCTAssertEqual(boxy.originRow, 19)
        XCTAssertEqual(Desk.vacatedRows(from: wide, to: boxy, paneRows: 24), [12..<19, 23..<25])
        // A pane that has only 12 rows keeps the one vacated row it has -- the last one.
        XCTAssertEqual(Desk.vacatedRows(from: wide, to: boxy, paneRows: 12), [12..<13])
        // ...and one whose picture never reached the vacated band gets nothing at all.
        XCTAssertTrue(Desk.vacatedRows(from: wide, to: boxy, paneRows: 1).isEmpty)
    }

    // MARK: - the pass state machine (issue #257 review)

    /// An interrupted **transmit** pass must forget the store.
    ///
    /// Three blocks, a relayout between block 1 and block 2: the pass is dropped having transmitted a
    /// third of the picture, so the signature it stood for is no longer true. Without this the next
    /// relayout answers `.movedLayout` and re-places tile indices the terminal never received -- a
    /// blank picture that stays blank, which is the bug this whole change is about.
    func testAnInterruptedTransmitPassForgetsTheStore() {
        var queue = Desk.PaintQueue()
        let g = grid(area: (top: 1, rows: 40), aspect: 3.0)
        let signature = Desk.ContentSignature(g, crop: CGRect(x: 0, y: 0, width: 800, height: 600))
        // The store stood complete a moment ago: an earlier pass drained (this is the state the
        // signature is *for*, and the one that makes a later relayout look like a move).
        queue.owe(.repaint, tiles: 3, now: 0)
        XCTAssertNotNil(queue.finish([0, 1, 2], spent: 1024, signature: signature, tileCount: 3,
                                     row: g.originRow, budgetKiB: 128, now: 1))
        queue.drop()                                   // ...and the confirm pass it started is dropped
        XCTAssertEqual(queue.transmitted, signature, "cells-only transmits nothing")
        // Now a *transmit* pass (say a clear() forced a real repaint), nine tiles, three blocks.
        queue.owe(.repaint, tiles: 9, now: 2)
        XCTAssertTrue(queue.active)
        XCTAssertEqual(queue.mode, .transmit)
        XCTAssertNil(queue.transmitted, "nothing has drained, so the store is not known to be complete")
        // Block 1 of 3: three tiles, and the pass is still in flight.
        XCTAssertNil(queue.finish([0, 1, 2], spent: 1024, signature: signature, tileCount: 9,
                                  row: g.originRow, budgetKiB: 128, now: 10))
        XCTAssertTrue(queue.active)
        XCTAssertNil(queue.transmitted, "a third of the picture is not the picture")
        // ...a relayout lands: the rest of the pass belongs to the old grid.
        queue.drop()
        XCTAssertNil(queue.transmitted)
        XCTAssertFalse(queue.active)
        // So the next frame must send pixels -- though nothing else changed.
        XCTAssertEqual(queue.reason(move: true, columnsMoved: false, repaintNeeded: false,
                                    reencode: false, signature: signature), .repaint)
    }

    /// The other half of that rule: a **cells-only** pass transmits nothing, so dropping it (the
    /// confirm re-place, or a move) leaves the store exactly as complete as it was.
    func testAnInterruptedCellsOnlyPassKeepsTheStore() {
        var queue = Desk.PaintQueue()
        let g = grid(area: (top: 1, rows: 40), aspect: 3.0)
        let signature = Desk.ContentSignature(g, crop: CGRect(x: 0, y: 0, width: 800, height: 600))
        queue.owe(.repaint, tiles: 3, now: 0)
        // The transmit pass drains: the store is the picture, and the confirm re-place is queued.
        XCTAssertNotNil(queue.finish([0, 1, 2], spent: 4096, signature: signature, tileCount: 3,
                                     row: g.originRow, budgetKiB: 128, now: 5))
        XCTAssertEqual(queue.transmitted, signature)
        XCTAssertEqual(queue.mode, .cellsOnly)
        XCTAssertTrue(queue.confirm)
        XCTAssertEqual(queue.tiles, [0, 1, 2])
        // Interrupting *that* loses no pixels.
        queue.drop()
        XCTAssertEqual(queue.transmitted, signature)
        XCTAssertEqual(queue.reason(move: true, columnsMoved: false, repaintNeeded: false,
                                    reencode: false, signature: signature), .movedLayout)
    }

    /// A dirty frame whose own changes overflow one block is a **queue**, not a pass: no line, no
    /// confirm re-place, and it stays bounded by the grid.
    ///
    /// Why this is a blocker and not tidiness: `finishPass` used to turn any over-budget dirty frame
    /// into a pass, so one scroll frame that changed more than a block's worth of tiles put a
    /// whole-grid cells-only re-place (~50-100 KiB, ~18 commits) on the wire *after every frame* --
    /// re-creating the slow-link condition the change exists to remove.
    func testADirtyFramesTailNeverBecomesAPass() {
        var queue = Desk.PaintQueue()
        let g = grid(area: (top: 1, rows: 40), aspect: 3.0)
        let signature = Desk.ContentSignature(g, crop: CGRect(x: 0, y: 0, width: 800, height: 600))
        var owed: [Int] = []
        var blocks = 0
        for _ in 0..<50 {
            let taken = Desk.paintChunk(changed: Array(0..<200), owed: owed, mode: .transmit,
                                        tileCount: 216, cap: Options.defaultPaintBudgetKiB * 1024,
                                        bytes: { _ in Desk.defaultTileBytes })
            XCTAssertFalse(taken.chunk.isEmpty)
            owed = taken.rest
            blocks += 1
            queue.absorb(taken.rest, mode: taken.mode)      // exactly what `nextChunk` does
            XCTAssertNil(queue.finish(taken.chunk.map(\.index), spent: 1024, signature: signature,
                                      tileCount: 216, row: g.originRow, budgetKiB: 128, now: Double(blocks)),
                         "a dirty frame's tail must never print a picture-painted line")
            XCTAssertFalse(queue.confirm, "and must never start the confirm re-place")
            XCTAssertFalse(queue.active, "it is a queue, not a pass")
            XCTAssertLessThanOrEqual(queue.tiles.count, 216, "the queue is bounded by the grid")
        }
        XCTAssertFalse(queue.tiles.isEmpty, "200 dirty tiles per frame never fit in one block")
    }

    /// The whole pass, drained by the real splitter at the real estimate and the real default cap:
    /// every index exactly once, in order, no block over the cap -- except a single tile, which may be
    /// bigger than the whole budget (the alternative is a picture that never paints).
    ///
    /// The other tests build their blocks by hand, so a dropped last chunk or a silent overshoot was
    /// invisible to them; this is the one that would catch it.
    func testADrainedPassCoversEveryTileOnceAndRespectsTheCap() {
        let cap = Options.defaultPaintBudgetKiB * 1024
        let estimate = Desk.defaultTileBytes
        var owed = Array(0..<216)
        var seen: [Int] = []
        var blocks = 0
        while !owed.isEmpty {
            let before = owed.count
            let taken = Desk.paintChunk(changed: [], owed: owed, mode: .transmit, tileCount: 216,
                                        cap: cap, bytes: { _ in estimate })
            XCTAssertFalse(taken.chunk.isEmpty, "a block that takes nothing is a queue that never drains")
            if taken.chunk.count > 1 {
                let spent = taken.chunk.count * estimate
                XCTAssertLessThanOrEqual(spent, cap, "block \(blocks) is over the budget")
            }
            seen += taken.chunk.map(\.index)
            XCTAssertLessThan(taken.rest.count, before, "no progress at block \(blocks)")
            owed = taken.rest
            blocks += 1
            XCTAssertLessThan(blocks, 1000)
        }
        XCTAssertGreaterThanOrEqual(blocks, 2, "a budgeted pass is several blocks")
        XCTAssertEqual(seen, Array(0..<216), "every tile exactly once, in order")
    }

    // MARK: - the reason: what may be cells-only (issue #257 review)

    /// A picture that moved **sideways** is not a move: no row erase can take away the column band it
    /// left behind (it would keep drawing the old picture beside the new one), so it keeps today's
    /// clear-and-transmit. A row move is still the cheap path.
    func testOnlyARowMoveMayGoCellsOnly() {
        // A picture that fills the pane's height (aspect 1.0) and is centred in its width: widening
        // the area by one column moves it one column right and changes nothing else.
        let g51 = TileGrid.make(paneCols: 102, paneRows: 40, cellW: 8, cellH: 16, aspect: 1.0,
                                tileCols: 8, tileRows: 4,
                                area: (top: 1, left: 1, cols: 102, rows: 40))
        let g50 = TileGrid.make(paneCols: 101, paneRows: 40, cellW: 8, cellH: 16, aspect: 1.0,
                                tileCols: 8, tileRows: 4,
                                area: (top: 1, left: 1, cols: 101, rows: 40))
        XCTAssertNotEqual(g51.originCol, g50.originCol, "the picture moved sideways")
        XCTAssertEqual(g51.originRow, g50.originRow)
        XCTAssertTrue(Desk.movedColumns(from: g51, to: g50), "the picture is not where it was")
        XCTAssertEqual(Desk.oweReason(signatureChanged: false, repaintNeeded: false,
                                      explicitReencode: false,
                                      columnMoved: Desk.movedColumns(from: g51, to: g50)), .repaint)
        // Row-only: the same picture, a shorter area to centre it in, so only the row moves.
        let g12 = grid(area: (top: 1, rows: 40), aspect: 3.0)
        let g11 = grid(area: (top: 1, rows: 36), aspect: 3.0)
        XCTAssertNotEqual(g11.originRow, g12.originRow, "the picture moved up")
        XCTAssertEqual(g11.originCol, g12.originCol)
        XCTAssertFalse(Desk.movedColumns(from: g12, to: g11))
        let rowMove = Desk.oweReason(signatureChanged: false, repaintNeeded: false,
                                     explicitReencode: false,
                                     columnMoved: Desk.movedColumns(from: g12, to: g11))
        XCTAssertEqual(rowMove, .movedLayout, "a row move is the cheap path")
        // And the queue's own gate: only a relayout may be a move at all.
        var queue = Desk.PaintQueue()
        let signature = Desk.ContentSignature(g12, crop: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(queue.reason(move: false, columnsMoved: false, repaintNeeded: false,
                                    reencode: false, signature: signature), .repaint,
                       "a reap, a focus step or a clear is never a move")
    }

    /// The signature says what the pixels *are*, so the crop is part of it: a `--zoom-follow` pan
    /// moves the source rectangle without moving the box, and a cells-only pass there would freeze the
    /// mirror on the old picture until something else changed.
    func testAPanChangesTheSignature() {
        let g = grid(area: (top: 1, rows: 40), aspect: 3.0)
        let before = Desk.ContentSignature(g, crop: CGRect(x: 100, y: 50, width: 800, height: 600))
        let after = Desk.ContentSignature(g, crop: CGRect(x: 140, y: 50, width: 800, height: 600))
        XCTAssertNotEqual(before, after, "the same cells hold a different picture after a pan")
        XCTAssertEqual(Desk.oweReason(signatureChanged: before != after, repaintNeeded: false,
                                      explicitReencode: false), .repaint)
        XCTAssertEqual(before, Desk.ContentSignature(g, crop: CGRect(x: 100, y: 50,
                                                                     width: 800, height: 600)))
    }

    /// A cells-only block is sized by what it costs (the invisible grid, ~300 B for an 8x4 tile), not
    /// by the 12 KiB transmit estimate: with the estimate, 216 tiles are eighteen commits of one tile
    /// each, where the whole move is one ~65 KiB block.
    func testACellsOnlyPassIsSizedByItsCells() {
        let perTile = Desk.cellsOnlyTileBytes(cols: 8, rows: 4)
        XCTAssertGreaterThan(perTile, 128)
        XCTAssertLessThan(perTile, 512, "a tile's invisible grid is ~300 B, not ~12 KiB")
        // The decision itself, which is where the bug would be: a cells-only tile is sized by its
        // cells, a transmit tile by the estimate -- through the same function the emitters use.
        let g = grid(area: (top: 1, rows: 40), aspect: 3.0)
        let estimate = { (_: Int) in Desk.defaultTileBytes }
        XCTAssertEqual(Desk.tileCost(index: 0, mode: .cellsOnly, grid: g, estimate: estimate), perTile)
        XCTAssertEqual(Desk.tileCost(index: 0, mode: .transmit, grid: g, estimate: estimate),
                       Desk.defaultTileBytes)
        var owed = Array(0..<216)
        var blocks = 0
        while !owed.isEmpty {
            let taken = Desk.paintChunk(changed: [], owed: owed, mode: .cellsOnly, tileCount: 216,
                                        cap: Options.defaultPaintBudgetKiB * 1024,
                                        bytes: { _ in perTile })
            XCTAssertFalse(taken.chunk.isEmpty)
            owed = taken.rest
            blocks += 1
            XCTAssertLessThan(blocks, 100)
        }
        XCTAssertEqual(blocks, 1, "216 cells-only tiles are ~65 KiB: one block, not eighteen")
    }

    /// The one line a drained pass prints says what it took: the blocks it really used, the payload
    /// KiB, the seconds, and the budget it was given. (The blocks were being reset before the line
    /// was built, and the smoke run printed "painted in 0 blocks".)
    func testTheDrainedPassLineCountsItsBlocks() {
        var queue = Desk.PaintQueue()
        let g = grid(area: (top: 1, rows: 40), aspect: 3.0)
        let signature = Desk.ContentSignature(g, crop: CGRect(x: 0, y: 0, width: 800, height: 600))
        queue.owe(.repaint, tiles: 3, now: 0)
        for index in 0..<2 {
            XCTAssertNil(queue.finish([index], spent: 40 * 1024, signature: signature, tileCount: 3,
                                      row: g.originRow, budgetKiB: 128, now: Double(index)))
        }
        XCTAssertEqual(queue.finish([2], spent: 40 * 1024, signature: signature, tileCount: 3,
                                    row: g.originRow, budgetKiB: 128, now: 1000),
                       "krd: picture painted in 3 blocks, 120 KiB, 1.00 s (--paint-budget 128 KiB)\n")
    }

    /// A reap (`KRD_REAP=n`) sends its own `a=d,d=a`, so the store is gone -- but `repaintNeeded` (which
    /// only `clear()` arms) stays false and `reapIfNeeded` *returns* true instead, which is why
    /// `handleFrame` folds the reap into its store check. A reap that lands on the same frame as a
    /// relayout must therefore still be `.repaint`, never a move.
    func testAReapIsAlwaysARepaint() {
        var queue = Desk.PaintQueue()
        let g = grid(area: (top: 1, rows: 40), aspect: 3.0)
        let signature = Desk.ContentSignature(g, crop: CGRect(x: 0, y: 0, width: 800, height: 600))
        queue.transmitted = signature           // the store held the whole picture a moment ago...
        XCTAssertEqual(queue.reason(move: true, columnsMoved: false, repaintNeeded: true,
                                    reencode: false, signature: signature), .repaint,
                       "...and a reap took it, so those pixels have to be sent again")
        // A full repaint for a reason that is not a relayout is never a move, whatever the store says.
        XCTAssertEqual(queue.reason(move: false, columnsMoved: false, repaintNeeded: false,
                                    reencode: false, signature: signature), .repaint)
    }

    /// `--full-frame` puts the whole picture in one image (id 2), so there are no tile ids to owe and
    /// it keeps its own single-image path; `--paint-budget 0` is today's one block.
    func testFullFrameAndAZeroBudgetNeverJoinTheQueue() {
        XCTAssertFalse(Desk.usesPaintQueue(paintBudgetKiB: 128, fullFrame: true))
        XCTAssertFalse(Desk.usesPaintQueue(paintBudgetKiB: 0, fullFrame: false))
        XCTAssertFalse(Desk.usesPaintQueue(paintBudgetKiB: 0, fullFrame: true))
        XCTAssertTrue(Desk.usesPaintQueue(paintBudgetKiB: 128, fullFrame: false))
        XCTAssertTrue(Desk.usesPaintQueue(paintBudgetKiB: 1, fullFrame: false))
    }

    // MARK: - helper

    /// The reported display page: a 100x40-cell pane of 8x16 px cells, with `aspect` deciding how much
    /// of it the picture fills and `area` how many rows are left to centre it in.
    private func grid(area: (top: Int, rows: Int), aspect: Double) -> TileGrid {
        TileGrid.make(paneCols: 100, paneRows: 40, cellW: 8, cellH: 16, aspect: aspect,
                      tileCols: 8, tileRows: 4,
                      area: (top: area.top, left: 1, cols: 100, rows: area.rows))
    }
}
