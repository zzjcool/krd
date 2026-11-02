import XCTest
import Darwin

/// The loading card, measured on the **shipped** binary (issue #227).
///
/// WHY a process and not a unit test: the card is on screen only for the few hundred milliseconds a
/// capture grant takes, so `LoadingViewTests` — the file that pins what the card costs — can only
/// measure a `LoadingView` it built itself. That pins the widget and nothing about the path that owns
/// it: `main.swift`'s ordering, the single `?2026` block, `stop()` before the wall takes the row.
/// `--first-frame-delay` holds the first frame so that path can be watched end to end, and the two runs
/// below are the two transports the product can take — a terminal that plays `a=f`, and one that stays
/// silent about it (issue #217's mosaic fallback, proven here through the real binary).
///
/// WHAT is asserted, and why a pty is the only instrument for it:
///
///  * **drawn** — the card is one closed `?2026h … ?2026l` block carrying the transmit (`a=t`) and its
///    one pixel-sized placement (`a=p`), and its two captions follow the block. A card that painted
///    nothing, or painted in two blocks, is indistinguishable from this one in a screenshot.
///  * **gone before the row was taken** — the delete APC `Gi=<id>,a=d,d=i,i=<id>` lands after that
///    block and *before* the first picture frame. The claim is "`stop()` ran before the wall took the
///    row": in the other order the mascot floats over the frame that just arrived, and no byte count
///    would show it.
///  * **0 B while it is up** — the hold writes nothing at all, and nothing has to be filtered out to
///    say so: `--mock` has no 1 Hz `CSI 5n` heartbeat (`rttEnabled` is false on that path),
///    `--no-chrome --no-bar` remove the chrome, `--no-input` removes the ~50 B of mouse-mode setup
///    `startInput()` would otherwise put in this very window, and the stream has not started yet.
///    `--no-input` is load-bearing here, not cosmetic.
///  * **under budget** — the whole card (the start write plus the stop write) against design §5.1's
///    4 KB/s over the hold, printed as bytes *and* B/s.
///  * **the animation started exactly once** — `a=t` once, `a=f,o=z` three times, the base frame's own
///    gap and the loop start once each, and no second transmit for that id anywhere in the session.
///  * **the hold is real** — read off the *child's* log line (`loading card down after <ms> ms`), on
///    the child's clock. That is the one clock-shaped assertion in this file and it is deliberately
///    not this process's clock: a descheduled test process cannot make the hold look short.
///  * run B adds the fallback: no graphics APC in the card at all, the mosaic repainting itself on its
///    110 ms timer at the old ~22 KB per tick (i.e. over the budget, which is why #217 exists), and a
///    stop write with nothing to delete.
///
/// **No assertion here sleeps its way to a verdict.** The wait is `settleFrame`'s rule — a `?2026h`
/// with its `?2026l` after it, i.e. "a picture frame has finished" — applied to the anchor the
/// assertion is about. The card's 110 ms timer and the capture's first frame are frame events, and a
/// runner slow enough to stretch them must not turn into a verdict.
final class LoadingCardProcessTests: XCTestCase {
    // MARK: - A. a terminal that plays `a=f`

    /// A 5 s hold on a terminal that plays the animation: one closed block, 0 B/s while it is up, under
    /// §5.1's budget, the picture deleted before the first frame, and the child's own clock saying the
    /// card was up for the whole hold.
    func testTheHeldAnimatedCardIsUnderBudgetAndDeletedBeforeTheFirstFrame() throws {
        let logPath = NSTemporaryDirectory() + "krd-227-a-\(UUID().uuidString).log"
        let run = try spawn(.playsAnimationFrames, holdMs: 5_000, logPath: logPath)
        defer {
            run.stop()
            try? FileManager.default.removeItem(atPath: logPath)
        }

        // The card is one write and it ends with the second caption's `ESC[0m`. Watching for that byte
        // (rather than sleeping) is what makes the gap printed below a measurement of the card's life.
        guard run.terminal.pump(until: { labelsEnd($0) != nil }, timeoutMs: 25_000) else {
            return XCTFail("the card never finished its start write — no `krd · connecting` caption "
                           + "reached the pane, so the flag drew no card: \(run.terminal.describe)")
        }
        let cardUpAt = Date()

        // ...and this is where it goes away: the card's block, then the first picture frame as its own
        // **closed** block. Two closed `?2026` pairs is the whole wait — no sleep, and deliberately no
        // dependence on the delete: a card that was never taken away has to fail assertion 2 with a
        // sentence, not hang here until the timeout.
        guard run.terminal.pump(until: { closedBlocks($0) >= 2 }, timeoutMs: 25_000) else {
            return XCTFail("the session painted \(closedBlocks(run.terminal.stream)) closed `?2026h … "
                           + "?2026l` block(s) within 25 s, not the card and the first picture frame: "
                           + run.terminal.describe)
        }
        let firstFrameAt = Date()

        let stream = run.terminal.stream
        // Every anchor below is derived from these bytes. The pty says 137x44, but the card is laid out
        // on the grid the terminal's own answers produce (`CSI 6;33;17t` + `CSI 4;792;1020t` gave a
        // 136x35 grid here) — so a hard-coded row would be a test of this file, not of the product.
        guard let cardOpen = stream.index(of: blockOpen),
              let cardClose = stream.index(of: blockClose, from: cardOpen + blockOpen.count) else {
            return XCTFail("the first `?2026h` in the session was never closed with `?2026l`: "
                           + run.terminal.describe)
        }
        guard let frameOpen = stream.index(of: blockOpen, from: cardClose + blockClose.count),
              let frameClose = stream.index(of: blockClose, from: frameOpen + blockOpen.count) else {
            return XCTFail("the block after the card (byte \(cardClose)) is not a closed `?2026h … "
                           + "?2026l` pair: \(run.terminal.describe)")
        }
        let block = Array(stream[cardOpen..<cardClose])
        // A card's block clears its own twenty rows before it places the picture; a picture frame's does
        // not (it transmits tiles and moves the cursor onto their cells). So this is also the anchor that
        // says the first block on this pane *is* a card, which is what makes the failure below name the
        // two shapes it could have been instead.
        guard let firstRow = firstRowClear(block) else {
            return XCTFail("the first `?2026h` block on this pane is not a card: it clears none of its "
                           + "own rows and carries "
                           + "\(block.occurrences(of: Array(",a=t,".utf8))) `a=t` transmit(s), where a "
                           + "card is twenty row clears and exactly one. Either the flag drew no card, "
                           + "or the card was built for the mosaic transport on a terminal that "
                           + "answered `a=f`: \(block.brief)")
        }
        let row = firstRow.row
        guard let id = cardID(stream) else {
            return XCTFail("the card's transmit carries no `i=<id>` in its control list, so there is "
                           + "nothing this test could look for a delete of: \(block.brief)")
        }
        // The delete is resolved **here**, before the stop write's own anchor: a `stop()` that never ran
        // is the regression assertion 2 exists for, and it has to be reported as that rather than as a
        // missing `stopStart` a few lines further down.
        let deleted = stream.index(of: deleteAPC(id: id))
        guard let labelsEnd = labelsEnd(stream, after: cardClose) else {
            return XCTFail("the captions did not follow the card's block (no `krd · connecting` after "
                           + "byte \(cardClose)): \(run.terminal.describe)")
        }
        // The left edge of the stop write is the **last** `ESC[<row>;1H ESC[2K` before the delete — the
        // stop write is the run of row clears that carries the delete, so that is where it begins. Not
        // "the first row clear after the captions": a writer that started the instant the card's start
        // write ended would move that edge onto itself and the window below would measure 0 B by
        // construction, which is the one thing assertion 3 must not be able to say.
        //
        // Not a guard either: a stop write that is not there is what assertions 2 and 3 are about, and
        // they have to be reached and reported before this becomes a missing anchor.
        let stopStart = deleted.flatMap { stream.lastIndex(of: rowClear(row), before: $0) }

        // 1. drawn: one block, a transmit, one placement, and the captions after it.
        XCTAssertTrue(block.contains(string: ",a=t,"),
                      "the card's block carries no frame transmit (`a=t`): it painted either nothing or "
                      + "a placement with no picture behind it: \(block.brief)")
        XCTAssertTrue(block.contains(string: ",a=p,"),
                      "the card's block carries no pixel-sized placement (`a=p`), so the frames it "
                      + "transmitted are never put on screen: \(block.brief)")
        let caption = stream.index(of: Array("waiting for first frame".utf8), from: cardClose)
        XCTAssertNotNil(caption,
                        "the captions are not after the block, so the picture and its label went out in "
                        + "a different order than `startPicture()` writes them: \(block.brief)")
        if let caption, let stopStart {
            XCTAssertLessThan(caption, stopStart,
                              "the `waiting for first frame` caption (byte \(caption)) landed after "
                              + "the stop write (byte \(stopStart)), so the card was taken away before "
                              + "it was ever labelled: "
                              + Array(stream[stopStart..<min(caption, stopStart + 120)]).brief)
        }

        // 2. the card was gone before the row was taken.
        let atFrame = Array(stream[frameOpen..<min(stream.count, frameOpen + 120)]).brief
        XCTAssertNotNil(deleted,
                        "the picture (id \(id)) was never deleted: `stop()` on the `a=f` path has to "
                        + "send `a=d,d=i,i=\(id)`, or the mascot floats over the frame that arrives "
                        + "next. The card's block closed at \(cardClose) and the first picture frame "
                        + "opened at \(frameOpen); the session tail is \(run.terminal.describe)")
        if let deleted {
            let atDelete = Array(stream[cardClose..<min(stream.count, cardClose + 120)]).brief
            let afterDelete = Array(stream[deleted..<min(stream.count, deleted + 120)]).brief
            XCTAssertGreaterThan(deleted, cardClose,
                                 "the delete at byte \(deleted) is inside the card's own block "
                                 + "(\(cardOpen)..<\(cardClose)): a delete inside the `?2026` pair "
                                 + "races the transmit it belongs to: \(afterDelete)")
            XCTAssertLessThan(deleted, frameOpen,
                              "the delete at byte \(deleted) came *after* the first picture frame's "
                              + "block opened at \(frameOpen): `stop()` ran after the wall took the "
                              + "row, which is the regression this assertion exists for: "
                              + "\(atDelete) then \(atFrame)")
        }

        // 3. nothing was licensed to write during the hold — and nothing did.
        guard let stopStart else {
            return XCTFail("the card's stop write (the row clears that end with the delete) is not on the "
                           + "wire after the captions at byte \(labelsEnd), so the card was never taken "
                           + "away from its own rows: the 0 B window and the budget below have no right "
                           + "edge to measure against: \(run.terminal.describe)")
        }
        // ...and it really is the stop write and not a later clear *inside* it: `stop()` clears the
        // card's own `cellRows + 2` rows, in order, so the write begins with twenty of them. This is the
        // check that makes the anchor above self-evident — with a row taken from somewhere else (the
        // pane's 44 rows instead of the grid's 35, say) `lastIndex` lands on the middle of the stop
        // write and the window below comes out 53 B wide instead of telling anyone what went wrong.
        let cardRows = 20
        let stopShape = (0..<cardRows).map { rowClear(row + $0) }.reduce(into: [UInt8]()) { $0 += $1 }
        let stopWriteHead = Array(stream[stopStart..<Swift.min(stream.count, stopStart + stopShape.count)])
        // Compared as escaped bytes rather than with `XCTAssertEqual` on two `[UInt8]`: that one prints
        // both arrays as integers, which is 400 numbers nobody can read.
        XCTAssertTrue(stopWriteHead == stopShape,
                      "the stop write does not begin with the card's \(cardRows) row clears (rows "
                      + "\(row)…\(row + cardRows - 1)), so the anchor at byte \(stopStart) is not the "
                      + "start of `stop()`. There: \(stopWriteHead.brief). Expected: \(stopShape.brief)")
        let steady = stopStart - labelsEnd
        let carrier = Array(stream[labelsEnd..<min(stream.count, labelsEnd + 240)]).brief
        XCTAssertEqual(steady, 0,
                       "\(steady) B arrived between the end of the card's start write (byte "
                       + "\(labelsEnd)) and the first byte of its stop write (byte \(stopStart)); with "
                       + "`--mock --no-chrome --no-bar --no-input` the hold is the one window where the "
                       + "card is the only thing that could write, and it writes 0 B: "
                       + carrier)

        // 4. the budget, over the hold the flag asked for.
        let startWrite = labelsEnd - cardOpen
        let stopWrite = frameOpen - stopStart
        let cardBytes = startWrite + stopWrite
        let bps = cardBytes * 1000 / 5_000
        XCTAssertLessThanOrEqual(bps, 4096,
                                 "the card cost \(cardBytes) B (\(startWrite) B start + \(stopWrite) B "
                                 + "stop) over a 5000 ms hold, i.e. \(bps) B/s — over design §5.1's "
                                 + "4096 B/s. The animated card is one transmit and then 0 B/s, so a "
                                 + "number this high means the terminal is not playing it and the card "
                                 + "is repainting itself: \(block.brief)")

        // 5. the animation was started exactly once, and nowhere else.
        XCTAssertEqual(block.occurrences(of: Array(",a=t,".utf8)), 1,
                       "the card's block transmits \(block.occurrences(of: Array(",a=t,".utf8))) times, "
                       + "not once: the four frames are one `a=t` and three `a=f`: \(block.brief)")
        XCTAssertEqual(block.occurrences(of: Array(",a=f,o=z,".utf8)), 3,
                       "the block carries \(block.occurrences(of: Array(",a=f,o=z,".utf8))) `a=f,o=z` "
                       + "frames, not three: \(block.brief)")
        XCTAssertEqual(block.occurrences(of: Array(",a=a,r=1,z=220".utf8)), 1,
                       "the base frame's own gap (`a=a,r=1,z=220`) went out "
                       + "\(block.occurrences(of: Array(",a=a,r=1,z=220".utf8))) times, not once — "
                       + "kitty gives the base image no gap, so without it the animation plays frame 0 "
                       + "and stops: \(block.brief)")
        XCTAssertEqual(block.occurrences(of: Array(",a=a,s=3,v=1".utf8)), 1,
                       "the loop start (`a=a,s=3,v=1`) went out "
                       + "\(block.occurrences(of: Array(",a=a,s=3,v=1".utf8))) times, not once: "
                       + block.brief)
        let transmit = Array(",a=t,o=z,q=2,i=\(id)".utf8)
        XCTAssertEqual(stream.occurrences(of: transmit), 1,
                       "id \(id) was transmitted \(stream.occurrences(of: transmit)) times in the "
                       + "session, not once: a second transmit is the same picture on the wire twice, "
                       + "which is what the cache exists to prevent: "
                       + Array(stream[max(0, (stream.index(of: transmit) ?? 0) - 60)...].prefix(200)).brief)

        // 6. the hold is real, on the child's own clock.
        let childLog = run.log(waitingFor: "loading card down after")
        let holdMs = number(after: "loading card down after ", in: childLog)
        XCTAssertNotNil(holdMs,
                        "the child logged no `krd: loading card down after <ms> ms (--first-frame-delay "
                        + "5000)` line, so the flag took no hold or the instrument is gone; its log says:\n"
                        + childLog.split(separator: "\n").suffix(6).joined(separator: "\n"))
        // ...and once: the line is gated on the flag and its stamp is cleared where it is read, so two
        // lines would mean the card was taken down twice (or the gate leaked) — a stale second number
        // is exactly the shape of failure a `first match wins` reader would hide.
        XCTAssertEqual(occurrences(of: "loading card down after", in: childLog), 1,
                       "the child logged the card's lifetime "
                       + "\(occurrences(of: "loading card down after", in: childLog)) times, not once: "
                       + childLog.split(separator: "\n").filter { $0.contains("loading card") }
                           .joined(separator: " | "))
        XCTAssertGreaterThanOrEqual(holdMs ?? 0, 5_000,
                                    "the child's own clock says the card was up "
                                    + "\(holdMs.map { String($0) } ?? "?") ms, not the 5000 ms the "
                                    + "flag asked for: the `Task.sleep` is not holding the stream: "
                                    + childLog.split(separator: "\n").filter { $0.contains("loading card") }
                                        .joined(separator: " | "))

        // The dump goes in the PR body: the instrument, the numbers, the verdicts.
        let gap = firstFrameAt.timeIntervalSince(cardUpAt)
        mark("A instrument: the krd `swift test` builds next to the test bundle (debug config, the same\n"
             + "  target the release build ships), `--mock --no-bar --no-chrome --no-input --pane 137x44 "
             + "--first-frame-delay 5000`, behind a pty answering `CSI 6;33;17t` / `CSI 4;792;1020t` "
             + "and `Gi=32,r=2;OK`. The card's bytes are the release build's bytes; the hold's surplus "
             + "over 5000 ms is this build's first-frame production time")
        mark("A card id=\(id): one `?2026` block at bytes \(cardOpen)..<\(cardClose) "
             + "(\(cardClose - cardOpen) B), first row \(row) of the grid those answers produce; "
             + "start write \(startWrite) B, stop write \(stopWrite) B, total \(cardBytes) B")
        mark("A hold \(holdMs.map { String($0) } ?? "?") ms on the child's clock — at least the flag's "
             + "5000 ms, and the surplus is the first frame's own production time in a debug build — "
             + "=> \(bps) B/s over the flag's 5000 ms (budget 4096); carrier between the captions and "
             + "the stop: \(steady) B")
        mark("A delete before the first picture frame's block \(frameOpen)..<\(frameClose): "
             + ((deleted ?? Int.max) < frameOpen ? "yes" : "no")
             + " (byte \(deleted.map { String($0) } ?? "none") < \(frameOpen)); a=f started once: "
             + (block.occurrences(of: Array(",a=f,o=z,".utf8)) == 3
                && stream.occurrences(of: transmit) == 1 ? "yes" : "no")
             + "; this test watched the card go up and the first frame land "
             + String(format: "%.1f", gap) + " s apart")
    }

    // MARK: - B. a terminal that cannot play `a=f`

    /// The same run on a terminal that says nothing about `i=32`: `supportsAnimationFrames()` is `nil`,
    /// so the card animates itself — the card of issue #217's "before", at its old cost, proven through
    /// the real binary instead of a copy of the widget.
    func testATerminalThatCannotAnimateGetsTheMosaicAtItsOldCost() throws {
        let logPath = NSTemporaryDirectory() + "krd-227-b-\(UUID().uuidString).log"
        let run = try spawn(.cannotAnimate, holdMs: 2_000, logPath: logPath)
        defer {
            run.stop()
            try? FileManager.default.removeItem(atPath: logPath)
        }

        // The mosaic opens no `?2026` block at all (`LoadingViewTests` pins that on the widget), so the
        // first block on this pane is the first captured frame — and this waits for it to *close*.
        guard run.terminal.pump(until: { firstFrameClosed($0, after: 0) }, timeoutMs: 25_000) else {
            return XCTFail("the mock never painted a closed picture frame within 25 s, so either the "
                           + "hold never ended or the stream never started: \(run.terminal.describe)")
        }
        let stream = run.terminal.stream
        guard let frameOpen = stream.index(of: blockOpen),
              let frameClose = stream.index(of: blockClose, from: frameOpen + blockOpen.count) else {
            return XCTFail("no closed `?2026h … ?2026l` picture frame: \(run.terminal.describe)")
        }
        guard let cardStart = firstRowClear(stream) else {
            return XCTFail("the pane carries no `ESC[<row>;1H ESC[2K` at all, so the mosaic never "
                           + "painted a row: \(run.terminal.describe)")
        }
        let row = cardStart.row
        let region = Array(stream[cardStart.at..<frameOpen])
        // Each mosaic paint begins with a full clear of the card's own first row; the stop write begins
        // with one too, which is what makes it its own chunk (the one with no `▀` in it).
        let chunks = region.split(separator: rowClear(row), omittingEmptySubsequences: false)
            .map { Array($0) }
        let ticks = chunks.filter { $0.index(of: glyph) != nil }
        let stopChunk = chunks.last ?? []

        // 7. the fallback was taken: no kitty graphics in the card at all.
        XCTAssertNil(region.index(of: Array("\u{1B}_G".utf8)),
                     "a kitty graphics APC reached the card's region (bytes \(cardStart.at)..<"
                     + "\(frameOpen)) even though this terminal never answered the `a=f` question, so "
                     + "the mosaic path is emitting the animated card's bytes: "
                     + (region.index(of: Array("\u{1B}_G".utf8)).map {
                         Array(region[max(0, $0 - 40)..<min(region.count, $0 + 120)]).brief
                       } ?? ""))

        // 8. the card animates itself: the 110 ms timer is live, and its pose cycle repeats.
        //
        // The floor is 4 and not the 18 beats a 2000 ms hold nominally contains, because this count is
        // a *lower* bound on a loaded machine by construction: the mock writes 22 KB a tick and the pty
        // is a pipe, so a slow reader slows the writer, and the ticks the child's timer skips are never
        // produced (measured on an idle box: 13 here, 34 with a reader that drains as fast as the pty
        // allows — same binary, same 2 s window). What this assertion is for is "the fallback still
        // animates itself", which 4 consecutive repaints with their own pose cycle establish; the
        // *cost* claim below does not depend on the count.
        XCTAssertGreaterThanOrEqual(ticks.count, 4,
                                    "the mosaic repainted \(ticks.count) times during the 2000 ms "
                                    + "hold; a live 110 ms timer gets more than four beats into that "
                                    + "window even with a slow reader (measured: 13), so a count this "
                                    + "low means the fallback's clock is not running: "
                                    + run.terminal.describe)
        for (index, tick) in ticks.enumerated() {
            XCTAssertTrue(tick.index(of: Array("38;2;".utf8)) != nil,
                          "repaint \(index + 1) of \(ticks.count) carries no per-cell 24-bit colour "
                          + "(`38;2;`), so it is not the mosaic: \(tick.brief)")
        }
        XCTAssertLessThan(Set(ticks).count, ticks.count,
                          "no two of the \(ticks.count) repaints are byte-identical; the pose cycle is "
                          + "8 ticks and the ellipsis 4, so at least one pair has to repeat — a set of "
                          + "\(Set(ticks).count) distinct writes means the card is painting something "
                          + "new every beat: \(ticks.first?.brief ?? "")")

        // 9. at the old cost — which is why #217 exists.
        let mosaicBytes = frameOpen - cardStart.at
        let bps = mosaicBytes * 1000 / 2_000
        let smallest = ticks.map(\.count).min() ?? 0
        XCTAssertGreaterThan(smallest, 20_000,
                             "the cheapest of the \(ticks.count) mosaic repaints is \(smallest) B; "
                             + "`LoadingViewTests`' floor is 20,000 B a tick, so the fallback has "
                             + "quietly changed shape (or stopped painting the picture): "
                             + (ticks.min(by: { $0.count < $1.count })?.brief ?? ""))
        XCTAssertGreaterThan(bps, 4096,
                             "the mosaic cost \(mosaicBytes) B over a 2000 ms hold, i.e. \(bps) B/s — "
                             + "inside the 4096 B/s budget, which is impossible for the fallback: this "
                             + "run is supposed to prove the *old* cost. Either the terminal answered "
                             + "`a=f` when it should have stayed silent, or the mosaic is no longer "
                             + "painted every 110 ms")

        // 10. nothing to delete — there is no picture on this path, so no delete APC may go out.
        XCTAssertNil(stopChunk.index(of: glyph),
                     "the last write before the first frame carries a `▀`, so the stop write is "
                     + "indistinguishable from a repaint on this path: \(stopChunk.brief)")
        XCTAssertNil(stopChunk.index(of: Array("a=d".utf8)),
                     "the mosaic's stop write carries an `a=d`; this path transmits no picture, so a "
                     + "delete here names an image the terminal does not hold: \(stopChunk.brief)")
        XCTAssertTrue(stopChunk.contains(string: "\u{1B}[\(row);1H"),
                      "the stop write does not put the cursor back on the card's own first row "
                      + "(\(row)): \(stopChunk.brief)")
        // ...and the block that follows the card region is the captured picture, not more card: the
        // mosaic's last write ended where the first frame begins, which is the "before the frame" half
        // of this assertion in run B's shape (the region's right edge *is* the frame's open).
        let tiles = stream.index(of: Array(",a=t,o=z,q=2,i=".utf8), from: frameOpen)
        XCTAssertNotNil(tiles,
                        "the block after the card's region opens with no tile transmit, so it is not a "
                        + "picture frame and the \(region.count) B before it were not the card: "
                        + Array(stream[frameOpen..<min(frameClose, frameOpen + 240)]).brief)
        if let tiles {
            XCTAssertLessThan(tiles, frameClose,
                              "the first tile transmit (\(tiles)) is outside the block it was meant "
                              + "to belong to (\(frameOpen)..<\(frameClose)): the frame is not one "
                              + "block, so nothing here measures the card's end: "
                              + Array(stream[frameOpen..<min(frameClose, frameOpen + 240)]).brief)
        }

        mark("B instrument: the same krd (debug config), `--mock --no-bar --no-chrome --no-input "
             + "--pane 137x44 --first-frame-delay 2000`, behind the same pty but silent about `a=f` "
             + "(`animationFramesAnswer == nil`). A release build over the same 2000 ms drains more "
             + "beats (19 vs 13, both 22548..22636 B): this count is bounded by the reader, not the timer")
        mark("B card: \(ticks.count) mosaic repaints of \(smallest)..\(ticks.map(\.count).max() ?? 0) B "
             + "(floor 20000), \(mosaicBytes) B over the hold on row \(row) of the grid those answers "
             + "produce, \(Set(ticks).count) distinct poses of \(ticks.count)")
        mark("B hold 2000 ms (flag) => \(bps) B/s (budget 4096: over, two orders of magnitude); no "
             + "graphics APC in the card's region: "
             + (region.index(of: Array("\u{1B}_G".utf8)) == nil ? "yes" : "no")
             + "; stop write \(stopChunk.count) B of row clears ending where the first picture frame "
             + "opens (byte \(frameOpen)..<\(frameClose)), carries `a=d`: "
             + (stopChunk.index(of: Array("a=d".utf8)) == nil ? "no" : "yes")
             + " — this is the cost #217 replaced, measured on the shipped binary")
    }

    // MARK: - anchors, parsed out of the bytes

    /// The card's rows are **not** the pty's 137x44. `originRow` comes from `layout.paneRows`, which is
    /// the grid the terminal's own answers (`CSI 6;33;17t`, `CSI 4;792;1020t`) produce — a 35-row grid
    /// here, so the card starts on row 8, not on the 13 a 44-row pane would give it. Substituting a
    /// constant for `row` is one of the mutations that has to turn this file red (D5), so it is parsed
    /// from the card's own `ESC[<row>;1H ESC[2K` and never written down.
    private func rowClear(_ row: Int) -> [UInt8] { Array("\u{1B}[\(row);1H\u{1B}[2K".utf8) }

    /// The first `ESC[<row>;1H ESC[2K` in `bytes`, with its row: a card clearing the rows it is about to
    /// cover, and the only place this file learns what row that is. The digit requirement is what keeps
    /// a bare `ESC[H` (home) out of it.
    private func firstRowClear(_ bytes: [UInt8]) -> (at: Int, row: Int)? {
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0x1B, bytes[i + 1] == UInt8(ascii: "[") {
                var j = i + 2
                var digits = ""
                while j < bytes.count, bytes[j] >= 0x30, bytes[j] <= 0x39 {
                    digits.append(Character(UnicodeScalar(bytes[j])))
                    j += 1
                }
                let tail = Array(";1H\u{1B}[2K".utf8)
                if let row = Int(digits), !digits.isEmpty, bytes[j...].starts(with: tail) {
                    return (i, row)
                }
            }
            i += 1
        }
        return nil
    }

    /// The byte just past the `ESC[0m` that closes the `krd · connecting` caption: the end of the card's
    /// start write, and the left edge of the window assertion 3 calls empty.
    private func labelsEnd(_ bytes: [UInt8], after from: Int = 0) -> Int? {
        let caption = "krd · connecting"
        guard let captionAt = bytes.index(of: Array(caption.utf8), from: from) else { return nil }
        guard let reset = bytes.index(of: Array("\u{1B}[0m".utf8), from: captionAt + caption.utf8.count)
        else { return nil }
        return reset + 4
    }

    /// The picture's id, from the card's own `a=t` control list
    /// (`ESC_Gf=24,s=36,v=44,a=t,o=z,q=2,i=9000,m=0;…`).
    ///
    /// `LoadingViewTests` reads the same `,i=` on the path it can see; the id itself is `IconCache`'s to
    /// choose (9000 here), so the delete this file looks for cannot be a literal either. The search stops
    /// at the `;`: past it is base64, where `i=` means nothing.
    private func cardID(_ bytes: [UInt8]) -> Int? {
        guard let transmit = bytes.index(of: Array(",a=t,".utf8)) else { return nil }
        let rest = Array(bytes[transmit...])
        guard let semicolon = rest.index(of: Array(";".utf8)) else { return nil }
        let control = Array(rest[..<semicolon])
        guard let id = control.index(of: Array("i=".utf8)) else { return nil }
        var digits = ""
        var i = id + 2
        while i < control.count, control[i] >= 0x30, control[i] <= 0x39 {
            digits.append(Character(UnicodeScalar(control[i])))
            i += 1
        }
        return Int(digits)
    }

    private func deleteAPC(id: Int) -> [UInt8] {
        Array("\u{1B}_Gi=\(id),a=d,d=i,i=\(id)\u{1B}\\".utf8)
    }

    /// A `?2026h` with a `?2026l` after it, at or after `after`: `settleFrame`'s rule (#198 — one frame
    /// is one block), which is also the only "a frame ended" that survives a loaded runner.
    ///
    /// Quiet is deliberately *not* part of this wait, unlike `ThemeFollowProcessTests.settleFrame`: once
    /// the mock's first frame lands it paints at 20 fps and the pane is never silent again, so a wait
    /// that needed silence would time out on exactly the runs that succeeded.
    private func firstFrameClosed(_ bytes: [UInt8], after: Int) -> Bool {
        guard let open = bytes.index(of: blockOpen, from: after) else { return false }
        return bytes.index(of: blockClose, from: open + blockOpen.count) != nil
    }

    /// How many `?2026h … ?2026l` pairs have closed, counted from the start of the stream: the card is
    /// the first, the first picture frame the second. A run where the card was never committed has one
    /// fewer, which is a verdict for the assertions below rather than something to wait for.
    private func closedBlocks(_ bytes: [UInt8]) -> Int {
        var count = 0
        var i = 0
        while let open = bytes.index(of: blockOpen, from: i) {
            guard let close = bytes.index(of: blockClose, from: open + blockOpen.count) else { break }
            count += 1
            i = close + blockClose.count
        }
        return count
    }

    /// The `▀` of the mosaic, as bytes: the one glyph the fallback's repaints and nothing else carry.
    private var glyph: [UInt8] { Array("▀".utf8) }
    private var blockOpen: [UInt8] { Array("\u{1B}[?2026h".utf8) }
    private var blockClose: [UInt8] { Array("\u{1B}[?2026l".utf8) }

    /// `<n>` after `label`, for the child's own log line. A plain prefix scan, because the numbers this
    /// file reads are two and a regex would be a dependency on which of Swift's three regex engines is
    /// current.
    private func number(after label: String, in text: String) -> Int? {
        guard let range = text.range(of: label) else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    /// Non-overlapping occurrences of a substring: the "the instrument spoke once" assertion on the
    /// child's log. (`components(separatedBy:)` would copy the whole log per call; a scan does not.)
    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var found = 0
        var search = haystack[...]
        while let hit = search.range(of: needle) {
            found += 1
            search = search[hit.upperBound...]
        }
        return found
    }

    // MARK: - the process under test

    private struct Run {
        let master: Int32
        let child: Process
        let terminal: FakeTerminal
        let logPath: String

        /// The child's own `--log` file, polled until `needle` is in it. The instrument for the hold is
        /// a line the *product* wrote on the clock it took the hold with; this process's clock would be
        /// measuring the test.
        func log(waitingFor needle: String, timeoutMs: Int = 3_000) -> String {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            var text = ""
            while Date() < deadline {
                text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
                if text.contains(needle) { return text }
                usleep(20_000)
            }
            return text
        }

        func stop() {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            close(master)
            // Reaped, not orphaned: `SIGKILL` plus a closed master leaves a zombie per test until the
            // process table is read, and the `defer` around this call deletes the log file — which a
            // still-running child would be holding open.
            child.waitUntilExit()
        }
    }

    /// D4's two argument vectors: the pty's 137x44 is the pane the numbers are quoted in, `--no-input`
    /// is what makes the 0 B window exact (`startInput()` writes ~50 B of mouse-mode setup between the
    /// card and the stream), and `--log` is what puts the child's own clock where this test can read it.
    private func spawn(_ behaviour: FakeTerminal.Behaviour, holdMs: Int,
                       logPath: String) throws -> Run {
        let binary = try krdBinary()
        let (master, slave) = try openPTY(cols: 137, rows: 44)
        let child = Process()
        child.executableURL = binary
        child.arguments = ["--mock", "--no-bar", "--no-chrome", "--no-input", "--pane", "137x44",
                           "--first-frame-delay", "\(holdMs)", "--log", logPath]
        let pane = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        child.standardInput = pane
        child.standardOutput = pane
        child.standardError = pane
        try child.run()
        close(slave)                                    // the child holds its own copy now
        return Run(master: master, child: child,
                   terminal: FakeTerminal(master: master, behaviour: behaviour), logPath: logPath)
    }

    /// The `krd` built next to the test bundle; a missing one fails loudly rather than skipping.
    private func krdBinary() throws -> URL {
        let binary = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("krd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no krd binary at \(binary.path) — run `swift build` before `swift test`")
            throw NSError(domain: "LoadingCardProcessTests", code: 1)
        }
        return binary
    }

    /// A pty whose `ws_xpixel`/`ws_ypixel` are zero, i.e. the sshd pty: the pixel size a session would
    /// otherwise read from `TIOCGWINSZ` is absent, so the capability burst is what fills it in — and
    /// those answers are also where the card's row and its picture's size come from.
    private func openPTY(cols: Int, rows: Int) throws -> (master: Int32, slave: Int32) {
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
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

    /// One line to `stderr`, unbuffered, so the dump below survives a test that dies before its last
    /// assertion (`FakeTerminal.mark`'s precedent: `print` goes through a buffer the CI log only flushes
    /// at exit).
    private func mark(_ what: String) {
        FileHandle.standardError.write(Data("krd-test: \(what)\n".utf8))
    }
}

/// The other end of the pty: the terminal the card is measured against.
///
/// It answers the start-up burst the way a real one does — everything it was just asked, in one write
/// (`ProbeBatchTests`' shape) — and the graphics probe separately, because that one is a separate write
/// and the product reads its answer *before* it builds the card. One knob is the whole point: whether
/// it says it can play `a=f`. Run A does (`Gi=32,r=2;OK`, kitty's own echo of the animation it would
/// keep); run B says nothing about `i=32`, which is `animationFramesAnswer == nil` — issue #217's
/// fallback, and the reason the mosaic path still has to exist.
private final class FakeTerminal {
    enum Behaviour {
        /// `a=f` accepted: the terminal plays the mascot, krd transmits it once and then writes nothing.
        case playsAnimationFrames
        /// Silent about `i=32`: `supportsAnimationFrames()` is `nil`, so the card animates itself.
        case cannotAnimate
    }

    private static let cellQuestion = "\u{1B}[16t"
    private static let windowQuestion = "\u{1B}[14t"
    private static let graphemeQuestion = "\u{1B}[?2027$p"
    private static let da1Question = "\u{1B}[c"
    /// The kitty `U=1` probe's placement, by the parameters only that probe uses: its answer echoes them
    /// (`i=31,p=1;OK`), which is what `placeholderProbeVerdict` matches.
    private static let placeholderQuestion = "i=31,p=1,a=p,U=1"
    /// The `a=f` question's own body. It identifies the *question* and not the answer, so a terminal
    /// that stays silent here is a terminal that was asked and did not know.
    private static let frameQuestion = "a=f,f=24,s=1,v=1,q=0,i=32"

    private let master: Int32
    private let behaviour: Behaviour
    /// Where the bytes this terminal has not answered yet begin.
    private var answerCursor = 0

    private(set) var stream: [UInt8] = []

    init(master: Int32, behaviour: Behaviour) {
        self.master = master
        self.behaviour = behaviour
    }

    /// The pane as text, for a failure message that can be read: a count and a tail, never 400 KB.
    var describe: String {
        "\(stream.count) B, tail: " + Array(stream.suffix(400)).escaped
    }

    /// Read the pane, answering every question as it arrives, until `done` or the timeout.
    ///
    /// The read is the `drainUntilQuiet`/`settleFrame` shape without the quiet claim: `poll` on the
    /// master, append what arrived, re-check the predicate. `done` is structural in both runs of this
    /// file (a closed `?2026` pair), so the timeout is a hang guard and nothing else.
    func pump(until done: ([UInt8]) -> Bool, timeoutMs: Int) -> Bool {
        if done(stream) { return true }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var chunk = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 25) > 0 else {
                if done(stream) { return true }
                continue
            }
            let n = read(master, &chunk, chunk.count)
            if n <= 0 { return done(stream) }
            stream.append(contentsOf: chunk[0..<n])
            answerIfAsked()
            if done(stream) { return true }
        }
        return done(stream)
    }

    /// Is the unanswered tail a question? Then a real terminal answers it now.
    ///
    /// The two bursts are answered differently on purpose: the capability batch is answered with the
    /// cell and window this file's numbers are derived from, and the graphics probe with a verdict on
    /// each of its two questions — kitty's own vocabulary (`;OK`), which is what the product's
    /// `placeholderProbeVerdict`/`animationFrameVerdict` parse. The frame's answer goes out **before**
    /// the placement's: the probe stops reading on the placement's `i=31`, so the `a=f` verdict has to
    /// be in the buffer by then or run A would measure the mosaic.
    private func answerIfAsked() {
        guard answerCursor < stream.count else { return }
        let pending = String(decoding: stream[answerCursor...], as: UTF8.self)
        let asksCapability = pending.contains(Self.cellQuestion)
            || pending.contains(Self.windowQuestion)
            || pending.contains(Self.graphemeQuestion)
            || pending.contains(Self.da1Question)
        let asksGraphics = pending.contains(Self.placeholderQuestion)
            || (behaviour == .playsAnimationFrames && pending.contains(Self.frameQuestion))
        guard asksCapability || asksGraphics else { return }

        usleep(20_000)                       // let the rest of the same write land, if the pty split it
        drainAvailable()
        let raw = String(decoding: stream[answerCursor...], as: UTF8.self)
        answerCursor = stream.count

        var reply = ""
        if raw.contains(Self.frameQuestion), behaviour == .playsAnimationFrames {
            reply += "\u{1B}_Gi=32,r=2;OK\u{1B}\\"                                  // it would play it
        }
        if raw.contains(Self.cellQuestion) { reply += "\u{1B}[6;33;17t" }            // 17x33 cell
        if raw.contains(Self.windowQuestion) { reply += "\u{1B}[4;792;1020t" }       // 1020x792 area
        if raw.contains(Self.graphemeQuestion) { reply += "\u{1B}[?2027;2$y" }       // recognised, reset
        if raw.contains(Self.da1Question) { reply += "\u{1B}[?62;22c" }              // DA1, the terminator
        if raw.contains(Self.placeholderQuestion) {
            reply += "\u{1B}_Gi=31,p=1;OK\u{1B}\\"                                   // U=1 accepted
        }
        guard !reply.isEmpty else { return }
        writeAll(reply)
    }

    /// Everything the child has written since the last read — without waiting. Only used inside
    /// `answerIfAsked`, after the quiet window, and bounded: a pane that never stops writing must not
    /// spin here appending megabytes before the test gets a chance to fail.
    private func drainAvailable() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<512 {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 0) > 0 else { return }
            let n = read(master, &chunk, chunk.count)
            if n <= 0 { return }
            stream.append(contentsOf: chunk[0..<n])
        }
    }

    private func writeAll(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            var off = 0
            while off < buf.count {
                let n = write(master, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }
}

private extension Array where Element == UInt8 {
    /// The index of the first `needle` at or after `from`, or `nil`. Lockstep rather than
    /// `Array(self[...]) == needle` per candidate: this runs inside a pump predicate on a stream that
    /// grows to half a megabyte (the mosaic's 22 KB ticks).
    func index(of needle: [UInt8], from: Int = 0) -> Int? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        let first = needle[0]
        var i = Swift.max(0, from)
        let last = count - needle.count
        while i <= last {
            if self[i] == first {
                var j = 1
                while j < needle.count, self[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// The index of the last `needle` that starts before `before`, or `nil`. Backwards, for the one
    /// anchor that has to be found from its right end: the stop write is identified by the delete it
    /// carries, so its first row clear is the last one *before* that delete.
    func lastIndex(of needle: [UInt8], before: Int) -> Int? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        var i = Swift.min(before, count) - needle.count
        while i >= 0 {
            var j = 0
            while j < needle.count, self[i + j] == needle[j] { j += 1 }
            if j == needle.count { return i }
            i -= 1
        }
        return nil
    }

    /// Does the stream carry this byte run?
    func contains(string: String) -> Bool { index(of: Array(string.utf8)) != nil }

    /// Non-overlapping occurrences of a byte run: the "exactly once" assertions.
    func occurrences(of needle: [UInt8]) -> Int {
        guard !needle.isEmpty else { return 0 }
        var found = 0
        var i = 0
        while let hit = index(of: needle, from: i) {
            found += 1
            i = hit + needle.count
        }
        return found
    }

    /// Bytes in a form a failure message can be read in: escapes spelled out, so "the stop write is not
    /// empty" is visible instead of a wall of control characters.
    var escaped: String {
        var out = ""
        for byte in self {
            switch byte {
            case 0x1B: out += "\\e"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            default:
                // Printable ASCII as itself, everything else as a hex byte: a tile payload is binary
                // and printing it raw would bury the assertion it belongs to.
                out += (0x20...0x7E).contains(byte)
                    ? String(UnicodeScalar(byte))
                    : String(format: "\\x%02x", byte)
            }
        }
        return out
    }

    /// The first 240 B of `escaped`, then a count of what is left. A failure message is read inside a CI
    /// log, and GitHub drops a 400 KB line — which turns a failed assertion into a silent one. The count
    /// is kept because that is what a budget test is about.
    var brief: String {
        let limit = 240
        let head = Array(prefix(limit)).escaped
        return count <= limit ? head : head + " … +\(count - limit) B"
    }
}
