import XCTest
@testable import krd
import krdcore

/// What the loading card costs the wire — the number issue #217 exists for.
///
/// The card is on screen only until the first captured frame lands, which is why nobody measured it:
/// it is replaced in a few hundred milliseconds, and a few hundred milliseconds of a 22 KB tick is
/// easy to miss and hard to catch in the act. So the measurement is taken through the card's own
/// sink: `LoadingView` is constructed with the closure that receives every byte it writes, and
/// `tick()` is the timer's handler exposed without the timer. Bytes per second is then
/// `one tick's bytes × 9.09`, exactly, with no clock in the test — a test that slept 110 ms nine
/// times would fail on a loaded machine and measure the machine, not the card.
///
/// Two transports, two numbers, and both are pinned here:
///
/// - **`a=f` (the terminal plays the animation)**: one transmit when the card appears, then **0 B**
///   for every tick until it is taken away. The budget — design §5.1's "加载动画 < 4 KB/s" — is
///   asserted over the acceptance window (3 s = 27 ticks) on the *whole* card: the transmit, the
///   placement, the text, everything.
/// - **the mosaic (no `a=f` probe answer)**: today's card, unchanged, ~22 KB *per tick*. It is
///   asserted here on purpose: this is the "before" number of the issue's before/after, taken with
///   the same instrument, and the fallback is not allowed to quietly change (D5).
///
/// The 0 B of a cache reuse is asserted **on the bytes** — a second card on the same `IconCache`
/// writes no `a=t` and no payload — never on a hit counter: a counter would still be right if the
/// bytes went out anyway.
final class LoadingViewTests: XCTestCase {
    private let esc = "\u{1B}"
    /// A 137×44 pane with a 17×33 cell: the pane `--selftest --pane 137x44 --cell 17x33` uses, so a
    /// number quoted here can be compared with a number quoted there.
    private let pane = (cols: 137, rows: 44)
    private let cell = (w: 17.0, h: 33.0)

    /// The card's whole output, recorded the way `main.swift` hands it to the writer.
    private final class Sink {
        private(set) var text = ""
        var bytes: Int { text.utf8.count }
        func write(_ s: String) { text += s }
    }

    private func view(animates: Bool, cache: IconCache = IconCache(), paletteKey: UInt64 = 0,
                      pane: (cols: Int, rows: Int)? = nil,
                      cell: (w: Double, h: Double)? = nil) -> (LoadingView, Sink) {
        let sink = Sink()
        let p = pane ?? self.pane
        let c = cell ?? self.cell
        let view = LoadingView(paneCols: p.cols, paneRows: p.rows, cell: c, animates: animates,
                               cache: cache, paletteKey: paletteKey) { sink.write($0) }
        return (view, sink)
    }

    // MARK: - the animated card

    /// The measurement itself: a tick of the animated card costs nothing, so bytes/second is 0.
    func testOneTickWritesNothingOnceTheTerminalOwnsTheAnimation() {
        let (card, sink) = view(animates: true)
        card.start()
        let afterStart = sink.bytes
        XCTAssertGreaterThan(afterStart, 0, "the card must paint something")
        for tick in 1...9 {
            let before = sink.bytes
            card.tick()
            XCTAssertEqual(sink.bytes, before, "tick \(tick) wrote \(sink.bytes - before) B")
        }
        XCTAssertTrue(sink.text.contains("waiting for first frame"))
    }

    /// The budget, over the window the issue names: 3 s at the old card's 9.09 Hz is 27 ticks.
    ///
    /// Also the place the *payload* is inspected, because a byte count alone cannot tell "the
    /// terminal is playing it" from "nothing was sent": the four frames have to be on the wire
    /// (`a=t` once and `a=f` three times, each later frame carrying the gap), the loop has to be
    /// started (`s=3,v=1`), and the root frame's own gap has to be set (`a=a,r=1,z=220`) — kitty
    /// gives the base image no gap, so without that APC the animation plays its first frame and
    /// stops.
    func testTheWholeCardCostsLessThanTheBudgetOverThreeSeconds() {
        let (card, sink) = view(animates: true)
        card.start()
        for _ in 0..<27 { card.tick() }
        let total = sink.bytes
        let budget = 4 * 1024 * 3
        XCTAssertLessThan(total, budget,
                          "\(total) B over 3 s is \(Double(total) / 3) B/s, budget 4 KB/s")
        print("loading card, a=f: \(total) B over 3 s = \(String(format: "%.0f", Double(total) / 3)) B/s")

        // The other cell krd is measured on (8x20 asks for a 36x45 picture, 17x33 for a 36x35 one):
        // the taller picture is the more expensive case, and it is the one an 80x24 default window
        // gets. Pinned so the budget cannot be met by quoting only the cheap terminal.
        let tall = view(animates: true, cell: (8, 20))
        tall.0.start()
        for _ in 0..<27 { tall.0.tick() }
        print("loading card, a=f, 8x20 cell: \(tall.1.bytes) B over 3 s = "
              + "\(String(format: "%.0f", Double(tall.1.bytes) / 3)) B/s")
        XCTAssertLessThan(tall.1.bytes, budget, "the 8x20 cell is the expensive one and it fits too")

        XCTAssertEqual(occurrences(of: "\(esc)_Gf=24,", in: sink.text), 4, "four frames")
        XCTAssertEqual(occurrences(of: ",a=t,", in: sink.text), 1, "frame 0 is the transmit")
        XCTAssertEqual(occurrences(of: ",a=f,o=z,", in: sink.text), 3, "frames 1-3 are `a=f`")
        XCTAssertEqual(occurrences(of: ",z=220", in: sink.text), 4, "the three `a=f` and the `a=a`")
        XCTAssertTrue(sink.text.contains("\(esc)_Gi="), "the placement")
        XCTAssertTrue(sink.text.contains(",a=p,q=2,C=1,c=36,r=18"),
                      "one pixel-sized placement on the card's 36x18 cell box")
        XCTAssertTrue(sink.text.contains(",a=a,r=1,z=220"), "the base frame's own gap")
        XCTAssertTrue(sink.text.contains(",a=a,s=3,v=1"), "run, loop forever")
        XCTAssertTrue(sink.text.contains("\(esc)[?2026h") && sink.text.contains("\(esc)[?2026l"),
                      "the card commits as one block")
        XCTAssertTrue(sink.text.contains("waiting for first frame"))
        XCTAssertTrue(sink.text.contains("krd · connecting"))
    }

    /// The picture's pixel box is the cell box's aspect: 36 dots across a 36-cell box and 36 dot
    /// rows down its 18 rows, so a 17×33 cell asks for 35 rows and an 8×20 cell for 45.
    ///
    /// Both terminals krd is measured against treat a `c`/`r` placement differently — one stretches
    /// it, the other fits it with the aspect preserved — and a picture whose own aspect equals the
    /// box's looks identical either way. That is the reason the height is derived and not a constant.
    func testThePictureBoxFollowsTheCell() {
        let tall = view(animates: true, cell: (8, 20))
        tall.0.start()
        XCTAssertTrue(tall.1.text.contains(",s=36,v=45,a=t"), "an 8x20 cell asks for 36x45")
        let square = view(animates: true, cell: (17, 33))
        square.0.start()
        XCTAssertTrue(square.1.text.contains(",s=36,v=35,a=t"), "a 17x33 cell asks for 36x35")
        // A pane nobody has measured yet (0x0) must not trap on `Int(infinity)`.
        let unmeasured = view(animates: true, cell: (0, 0))
        unmeasured.0.start()
        XCTAssertTrue(unmeasured.1.text.contains(",s=36,v=45,a=t"), "the documented fallback")
    }

    /// The picture goes away with the card, and the book goes with it.
    ///
    /// A pixel-sized placement is not part of the text grid: clearing the card's rows would leave the
    /// mascot floating over the frame that just landed, which is why `stop()` deletes it by id — and
    /// why it forgets the cache entry, so a second card in this process re-transmits instead of
    /// placing an image the terminal no longer holds.
    func testStopTakesThePictureAwayAndClearsTheCardsRows() {
        let (card, sink) = view(animates: true)
        card.start()
        let id = firstImageID(in: sink.text)
        XCTAssertNotNil(id, "the card transmits an image with an id")

        let painted = sink.bytes
        card.stop()
        let stopped = String(sink.text.dropFirst(painted))
        XCTAssertTrue(stopped.contains("\(esc)_Gi=\(id!),a=d,d=i,i=\(id!)\(esc)\\"),
                      "the picture is deleted by id, not just cleared")
        XCTAssertEqual(occurrences(of: "\(esc)[2K", in: stopped), 20,
                       "the card's own 20 rows and nothing else")
        XCTAssertTrue(stopped.hasSuffix("\(esc)[\(max(0, (44 - 20) / 2) + 1);1H"),
                      "the cursor comes back to the card's first row")

        let afterStop = sink.bytes
        card.stop()
        XCTAssertEqual(sink.bytes, afterStop, "stop() is idempotent")
    }

    /// A second card on the same cache is a placement and nothing else: no `a=t`, no `a=f`, no base64.
    ///
    /// This is issue #217's "the second use of one icon costs 0 B", at the level the user's terminal
    /// sees it — the bytes — rather than as a hit counter that would still be right if the picture
    /// went out again.
    func testASecondCardOnTheSameCacheTransmitsNothing() {
        let cache = IconCache()
        let (first, firstSink) = view(animates: true, cache: cache, paletteKey: 0x1234)
        first.start()
        XCTAssertEqual(occurrences(of: ",a=t,", in: firstSink.text), 1)

        let (second, secondSink) = view(animates: true, cache: cache, paletteKey: 0x1234)
        second.start()
        XCTAssertEqual(occurrences(of: ",a=t,", in: secondSink.text), 0, "no second transmit")
        XCTAssertEqual(occurrences(of: ",a=f,", in: secondSink.text), 0, "and no frame data")
        XCTAssertTrue(secondSink.text.contains(",a=p,"), "but the placement is written")
        // A payload is the only unbroken run of base64 in this stream: the card's own escapes are
        // punctuation and its two captions have spaces, while a picture is a thousand characters of
        // base64 per frame. This is the 0 B, read off the bytes.
        XCTAssertLessThan(longestBase64Run(in: secondSink.text), 64,
                          "a run of base64 this long is picture data, not a placement")
        XCTAssertGreaterThan(longestBase64Run(in: firstSink.text), 512,
                             "and the first card's payload is exactly that kind of run")
        XCTAssertLessThan(secondSink.bytes, firstSink.bytes / 4)
    }

    /// A different palette is a different picture: the same glyph on a light and a dark terminal is
    /// two images (#213 is why the key has a palette half), so this card transmits again.
    func testAnotherPaletteTransmitsAgain() {
        let cache = IconCache()
        let (first, _) = view(animates: true, cache: cache, paletteKey: 1)
        first.start()
        let (second, sink) = view(animates: true, cache: cache, paletteKey: 2)
        second.start()
        XCTAssertEqual(occurrences(of: ",a=t,", in: sink.text), 1)
    }

    // MARK: - the fallback

    /// The card a terminal without `a=f` gets is the card it always got — byte for byte — and it
    /// still costs what it always cost. This is the "before" half of the issue's measurement, taken
    /// with the same instrument as the "after" half.
    func testWithoutAnimationFramesTheCardIsExactlyTodays() {
        let (card, sink) = view(animates: false)
        card.start()
        XCTAssertFalse(sink.text.contains("\(esc)_"), "no kitty graphics at all on this path")
        XCTAssertFalse(sink.text.contains("?2026"), "and no synchronised block")
        XCTAssertTrue(sink.text.contains("▀"), "the half-block mosaic")
        XCTAssertTrue(sink.text.contains("waiting for first frame"))

        let painted = sink.bytes
        card.tick()
        let tick = sink.bytes - painted
        print("loading card, mosaic fallback: \(painted) B first paint, \(tick) B per tick "
              + "= \(String(format: "%.0f", Double(tick) * 1000 / 110)) B/s")
        XCTAssertGreaterThan(tick, 20_000,
                             "the fallback is unchanged: one tick is the whole mosaic again")
        XCTAssertGreaterThan(tick, 4 * 1024 * 3, "which is why the animated path exists")
    }

    /// No terminal at all (`--bench`, a pipe): the card must not put a graphics APC on the wire just
    /// because it was asked to.
    func testASilentTerminalGetsTheMosaic() {
        let (card, sink) = view(animates: false)
        card.start()
        card.tick()
        card.stop()
        XCTAssertFalse(sink.text.contains("\(esc)_"))
    }

    // MARK: - helpers

    /// The longest unbroken run of base64 alphabet characters: the shape image data has on the wire,
    /// and a shape nothing else in this stream has (escapes are punctuation, captions have spaces).
    private func longestBase64Run(in text: String) -> Int {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        var longest = 0, current = 0
        for character in text {
            if alphabet.contains(character) {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack[...]
        while let found = search.range(of: needle) {
            count += 1
            search = search[found.upperBound...]
        }
        return count
    }

    /// The image id the card's own bytes use: `...i=<id>` in the first transmit.
    private func firstImageID(in text: String) -> Int? {
        guard let range = text.range(of: ",i=") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}
