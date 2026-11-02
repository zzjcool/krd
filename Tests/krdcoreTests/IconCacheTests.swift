import XCTest
import Foundation
import CZlib
import krdcore

/// The content-addressed icon book (issue #217, design §4.3), pinned on the bytes.
///
/// The claim this cache makes is a *wire* claim — the second draw of a picture carries no image data
/// — and the only thing that can be wrong is the escapes it hands back. So every test here reads
/// `Emit.bytes` (and `payloadBytes`, which is a count *of those bytes*): none of them can pass while
/// the wire is wrong, and none of them consults a hit counter that a broken emitter could still
/// increment.
final class IconCacheTests: XCTestCase {
    private let esc = "\u{1B}"

    override func setUp() {
        super.setUp()
        // The bytes below are the ones a plain terminal sees. `GraphicsAPC.passthrough` is ambience
        // set once at startup (#107), and another suite in this process may have turned it on.
        GraphicsAPC.passthrough = false
    }

    // MARK: - fixtures

    /// A picture with real content: a gradient with a stripe every 16 columns, so zlib has something
    /// to find and no payload is a run of one byte.
    private func image(w: Int, h: Int, seed: UInt8) -> IconImage {
        var pixels = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<pixels.count {
            let x = (i / 3) % w
            let y = (i / 3) / w
            let stripe = x % 16 == 0 ? 90 : 0
            pixels[i] = UInt8(truncatingIfNeeded: Int(seed) + x * 5 + y * 3 + stripe)
        }
        return IconImage(width: w, height: h, pixels: pixels)
    }

    /// Pixels zlib cannot shrink (a murmur-finalised counter, which is what a photograph looks like
    /// to a deflate matcher): the case where a payload crosses the 4096-character chunk boundary.
    private func noise(w: Int, h: Int) -> IconImage {
        var pixels = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<pixels.count {
            var x = UInt32(truncatingIfNeeded: i) &* 2_654_435_761 &+ 0x9E37_79B9
            x = (x ^ (x >> 16)) &* 0x7FEB_352D
            x = (x ^ (x >> 15)) &* 0x846C_A68B
            x ^= x >> 16
            pixels[i] = UInt8(truncatingIfNeeded: x >> 24)
        }
        return IconImage(width: w, height: h, pixels: pixels)
    }

    /// The APCs of one emit, split on the introducer: each starts with `G`, and a control list or
    /// base64 cannot contain ESC, so the split is exact.
    private func apcs(_ bytes: String) -> [String] {
        bytes.components(separatedBy: esc + "_").dropFirst().map { chunk in
            chunk.hasSuffix(esc + "\\") ? String(chunk.dropLast(2)) : chunk
        }
    }

    /// The base64 of a transmit, reassembled across its `m=` chunks: everything after each chunk
    /// header's `;`. An `a=a` control list has no payload and no `;`, so it drops out.
    private func base64Payload(_ apcs: [String]) -> String {
        apcs.compactMap { apc -> String? in
            guard let semicolon = apc.firstIndex(of: ";") else { return nil }
            return String(apc[apc.index(after: semicolon)...])
        }.joined()
    }

    /// Counted in unicode *scalars*: the placeholder plus its row diacritic is one grapheme
    /// cluster in Swift's `String`, so a character-wise count would miss every row's first cell.
    private func cellCount(_ bytes: String) -> Int {
        bytes.unicodeScalars.filter { $0 == "\u{10EEEE}" }.count
    }

    /// The test side of `o=z`, through the same libz the writer uses: "the payload is the picture" is
    /// then checked by the decompressor instead of by trusting the compressor.
    private func inflate(_ input: [UInt8]) -> [UInt8] {
        let capacity = 1 << 24
        var out = [UInt8](repeating: 0, count: capacity)
        var length = uLongf(capacity)
        let status = out.withUnsafeMutableBufferPointer { dst -> Int32 in
            input.withUnsafeBufferPointer { src in
                uncompress(dst.baseAddress, &length, src.baseAddress, uLong(input.count))
            }
        }
        XCTAssertEqual(status, Z_OK, "the payload must be a zlib stream, which is what `o=z` says")
        return Array(out[0..<Int(length)])
    }

    // MARK: - reuse

    /// The whole point: the second draw of one picture is the placement and nothing else.
    func testTheSecondDrawOfOnePictureCarriesNoImageData() {
        let cache = IconCache()
        let picture = IconCache.Graphic(frames: [image(w: 4, h: 3, seed: 1)])
        let placement = IconCache.Placement.pixels(cols: 2, rows: 1)

        let first = cache.draw(picture, palette: 0, at: placement)
        XCTAssertTrue(first.transmitted, "the first draw puts the picture on the wire")
        XCTAssertGreaterThan(first.payloadBytes, 0)
        XCTAssertEqual(first.id, 9000, "ids start where every other id in a session cannot be")
        XCTAssertTrue(first.bytes.contains(",a=t,"), "frame 0 is the transmit")
        XCTAssertTrue(first.bytes.hasSuffix(esc + "_Gi=9000,p=9000,a=p,q=2,C=1,c=2,r=1" + esc + "\\"),
                      "the placement comes last: \(first.bytes.suffix(80))")
        XCTAssertFalse(first.bytes.contains("?2026"),
                       "the caller owns the one sync block around its card (D3)")

        let second = cache.draw(picture, palette: 0, at: placement)
        XCTAssertFalse(second.transmitted)
        XCTAssertEqual(second.payloadBytes, 0, "a reused picture is 0 bytes of image data")
        XCTAssertEqual(second.id, first.id, "the id is the picture's while it is cached")
        XCTAssertEqual(second.key, first.key)
        XCTAssertFalse(second.bytes.contains("a=t"))
        XCTAssertFalse(second.bytes.contains("a=f"))
        // Byte for byte the placement and nothing else: 38 bytes for a 2x1-cell card.
        XCTAssertEqual(second.bytes, esc + "_Gi=9000,p=9000,a=p,q=2,C=1,c=2,r=1" + esc + "\\")
        XCTAssertEqual(second.bytes.utf8.count, 38)
    }

    /// The key is the *content*: the same pixels reached through a different array are the same
    /// picture, or a caller that rebuilds its frames every draw would pay for the picture every draw.
    func testTheSamePixelsThroughAnotherArrayReuseTheEntry() {
        let cache = IconCache()
        let placement = IconCache.Placement.pixels(cols: 3, rows: 2)
        let first = cache.draw(.init(frames: [image(w: 5, h: 5, seed: 7)]), palette: 0, at: placement)
        let second = cache.draw(.init(frames: [image(w: 5, h: 5, seed: 7)]), palette: 0, at: placement)
        XCTAssertTrue(first.transmitted)
        XCTAssertEqual(second.payloadBytes, 0, "a fresh [UInt8] with the same bytes is the same picture")
        XCTAssertEqual(second.id, first.id)
        XCTAssertFalse(second.bytes.contains("a=t"))

        // One pixel different is a different picture: the hash has to cover the pixels, not the size.
        var changed = image(w: 5, h: 5, seed: 7)
        changed.pixels[17] = changed.pixels[17] &+ 1
        let third = cache.draw(.init(frames: [changed]), palette: 0, at: placement)
        XCTAssertTrue(third.transmitted, "a changed pixel is a new picture, not a hit")
        XCTAssertNotEqual(third.id, first.id)
        XCTAssertNotEqual(third.key, first.key)
    }

    // MARK: - palette

    /// The same glyph on a light and a dark terminal is two pictures (#213): the colours are the
    /// theme layer's, so their bytes differ and only the shape is shared.
    func testADifferentPaletteIsADifferentPictureAndASharedOneIsAFreeReuse() {
        let cache = IconCache()
        let dark = Palette(foreground: RGB(0xD8_D8_D8), background: RGB(0x12_12_12))
        let light = Palette(foreground: RGB(0x22_22_22), background: RGB(0xF6_F6_F6))
        XCTAssertEqual(IconCache.paletteKey(nil), 0, "no OSC 10/11 answer is the hard-coded table")
        let darkKey = IconCache.paletteKey(dark)
        let lightKey = IconCache.paletteKey(light)
        XCTAssertNotEqual(darkKey, 0, "a real palette must not land on the no-palette key")
        XCTAssertNotEqual(darkKey, lightKey)
        XCTAssertNotEqual(IconCache.paletteKey(dark.inverted()), darkKey,
                          "a scheme switch is a different pair, so a different key")

        let picture = IconCache.Graphic(frames: [image(w: 6, h: 4, seed: 2)])
        let placement = IconCache.Placement.pixels(cols: 3, rows: 2)
        let onDark = cache.draw(picture, palette: darkKey, at: placement)
        XCTAssertTrue(onDark.transmitted)
        XCTAssertEqual(cache.draw(picture, palette: darkKey, at: placement).payloadBytes, 0)
        let onLight = cache.draw(picture, palette: lightKey, at: placement)
        XCTAssertTrue(onLight.transmitted, "the light palette's picture was never sent")
        XCTAssertNotEqual(onLight.id, onDark.id)
        XCTAssertNotEqual(onLight.key, onDark.key)
    }

    // MARK: - ids

    /// Two pictures, two ids, and each key keeps the id it was given: a second picture that took the
    /// first one's id would overwrite the terminal's image and the first icon would change.
    func testTwoPicturesGetDifferentIdsAndAKeyKeepsItsId() {
        let cache = IconCache()
        let a = IconCache.Graphic(frames: [image(w: 3, h: 3, seed: 4)])
        let b = IconCache.Graphic(frames: [image(w: 3, h: 3, seed: 5)])
        let placement = IconCache.Placement.pixels(cols: 2, rows: 2)
        let firstA = cache.draw(a, palette: 0, at: placement)
        let firstB = cache.draw(b, palette: 0, at: placement)
        XCTAssertTrue(firstA.transmitted)
        XCTAssertTrue(firstB.transmitted, "a second picture transmits too")
        XCTAssertEqual(firstA.id, 9000)
        XCTAssertEqual(firstB.id, 9001)
        XCTAssertTrue(firstB.bytes.contains("i=9001,"), "the id travels in the control list")

        XCTAssertEqual(cache.draw(a, palette: 0, at: placement).id, 9000)
        XCTAssertEqual(cache.draw(b, palette: 0, at: placement).id, 9001)
        // The seam is the caller's, so the loader can keep its ids out of another cache's range.
        XCTAssertEqual(IconCache(firstID: 7000).draw(a, palette: 0, at: placement).id, 7000)
    }

    // MARK: - animation

    /// D3's animation, in one draw: frame 0 as `a=t`, three `a=f` with the gap, the root frame's gap,
    /// and "run, loop for ever". The second draw is the placement alone — the terminal plays it.
    func testAnAnimationIsTransmittedOnceAndThenRunsInTheTerminal() throws {
        let cache = IconCache()
        let frames = (0..<4).map { image(w: 6, h: 4, seed: UInt8($0)) }
        let animation = IconCache.Graphic(frames: frames, gapMs: 220)
        let placement = IconCache.Placement.pixels(cols: 3, rows: 2)

        let first = cache.draw(animation, palette: 0, at: placement)
        XCTAssertTrue(first.transmitted)
        let apcs = self.apcs(first.bytes)
        XCTAssertEqual(apcs.count, 4 + 2 + 1, "four frames, two a=a, one placement")

        let transmits = apcs.filter { $0.contains(",a=t,") }
        XCTAssertEqual(transmits.count, 1)
        for transmit in transmits {
            XCTAssertTrue(transmit.hasPrefix("Gf=24,s=6,v=4,a=t,o=z,q=2,i=9000,m=0;"))
            XCTAssertFalse(transmit.contains(",z="), "kitty: the base image carries no gap")
        }

        let forwards = apcs.filter { $0.contains(",a=f,") }
        XCTAssertEqual(forwards.count, 3, "frames 1…3 are a=f")
        for forward in forwards {
            XCTAssertTrue(forward.hasPrefix("Gf=24,s=6,v=4,a=f,o=z,q=2,i=9000,z=220,m="),
                          "every later frame carries its gap: \(forward.prefix(60))")
        }

        XCTAssertTrue(first.bytes.contains(esc + "_Gi=9000,a=a,r=1,z=220" + esc + "\\"))
        XCTAssertTrue(first.bytes.contains(esc + "_Gi=9000,a=a,s=3,v=1" + esc + "\\"))

        // Order is load-bearing: the frames, then the gap, then "run", then the picture appears.
        let lastForward = try XCTUnwrap(first.bytes.range(of: ",a=f,", options: .backwards))
        let play = try XCTUnwrap(first.bytes.range(of: "Gi=9000,a=a,r=1,z=220"))
        let run = try XCTUnwrap(first.bytes.range(of: "Gi=9000,a=a,s=3,v=1"))
        let placed = try XCTUnwrap(first.bytes.range(of: "Gi=9000,p=9000,a=p,q=2,C=1"))
        XCTAssertLessThan(lastForward.lowerBound, play.lowerBound, "the gap follows the frames")
        XCTAssertLessThan(play.lowerBound, run.lowerBound, "the gap is set before the loop runs")
        XCTAssertLessThan(run.lowerBound, placed.lowerBound, "and the picture is placed last")

        let second = cache.draw(animation, palette: 0, at: placement)
        XCTAssertEqual(second.payloadBytes, 0)
        XCTAssertEqual(second.bytes, esc + "_Gi=9000,p=9000,a=p,q=2,C=1,c=3,r=2" + esc + "\\",
                       "a playing animation costs a placement, never a frame")
        XCTAssertFalse(second.bytes.contains("a=f"))
        XCTAssertFalse(second.bytes.contains("a=a"))
    }

    /// A still picture must never be told to animate: `a=a` on a one-frame image is bytes spent on a
    /// loop of one.
    func testAStillPictureNeverTellsTheTerminalToAnimate() {
        let cache = IconCache()
        let still = IconCache.Graphic(frames: [image(w: 4, h: 4, seed: 3)])
        let emit = cache.draw(still, palette: 0, at: .pixels(cols: 2, rows: 2))
        XCTAssertFalse(emit.bytes.contains("a=a"))
        XCTAssertFalse(emit.bytes.contains(",a=f"))
        XCTAssertFalse(emit.bytes.contains(",z="))
    }

    /// One frame with a gap is a still that would repeat itself, not an animation: the two `a=a` are
    /// only written when there is a second frame to play.
    func testOneFrameWithAGapIsStillAStill() {
        let cache = IconCache()
        let odd = IconCache.Graphic(frames: [image(w: 4, h: 4, seed: 6)], gapMs: 220)
        let emit = cache.draw(odd, palette: 0, at: .pixels(cols: 2, rows: 2))
        XCTAssertTrue(emit.transmitted)
        XCTAssertFalse(emit.bytes.contains("a=a"), "there is nothing to run")
        XCTAssertFalse(emit.bytes.contains(",z="))
    }

    // MARK: - cells

    /// The `U=1` transport: the grid is text on the grid, so it is rewritten on every draw, while the
    /// picture behind it is sent once.
    func testACellPlacementWritesTheGridOnEveryDrawAndThePictureOnce() {
        let cache = IconCache()
        let picture = IconCache.Graphic(frames: [image(w: 4, h: 3, seed: 8)])
        let grid = IconCache.Placement.cells(CellRect(col: 1, row: 1, cols: 4, rows: 3),
                                             paneCols: 80, paneRows: 24)
        let first = cache.draw(picture, palette: 0, at: grid)
        XCTAssertTrue(first.bytes.contains("Gi=9000,p=9000,a=p,U=1,q=2,c=4,r=3"))
        XCTAssertEqual(cellCount(first.bytes), 12, "cols * rows placeholders, no more")
        XCTAssertTrue(first.bytes.contains("\u{10EEEE}" + "\u{0305}"), "row 0 is U+0305")
        XCTAssertTrue(first.bytes.contains("\u{10EEEE}" + "\u{030D}"), "row 1 is U+030D")
        // The image id travels in the foreground colour, three bytes of it: 9000 = 0x002328.
        XCTAssertTrue(first.bytes.contains(esc + "[38;2;0;35;40m"))

        let second = cache.draw(picture, palette: 0, at: grid)
        XCTAssertEqual(second.payloadBytes, 0, "a U=1 picture is re-placed, never re-sent")
        XCTAssertEqual(cellCount(second.bytes), 12, "but the cells are rewritten: they are text")
        XCTAssertFalse(second.bytes.contains("a=t"))
    }

    /// The grid goes where the caller said, in 1-based pane cells: a picture is not the pane's first
    /// cell, and a placeholder grid that ignored the origin would draw the icon in the corner (the chrome's
    /// inline icons are the callers this exists for).
    func testTheGridStartsAtTheCallersCell() {
        let cache = IconCache()
        let picture = IconCache.Graphic(frames: [image(w: 4, h: 3, seed: 12)])
        let emit = cache.draw(picture, palette: 0,
                              at: .cells(CellRect(col: 7, row: 4, cols: 2, rows: 2),
                                         paneCols: 80, paneRows: 24))
        XCTAssertTrue(emit.bytes.contains(esc + "[4;7H"), "row 4, column 7")
        XCTAssertTrue(emit.bytes.contains(esc + "[5;7H"), "and the next row of the grid")
        XCTAssertEqual(cellCount(emit.bytes), 4)
    }

    /// A pending wrap at the final cell of the final pane row scrolls the grid and drags every
    /// placement on it one row up, so that cell is never written.
    func testTheFinalCellOfTheFinalRowIsNeverWritten() {
        let cache = IconCache()
        let picture = IconCache.Graphic(frames: [image(w: 4, h: 3, seed: 9)])
        // Two rows of four cells in a two-row pane of four columns: the last row may hold three.
        let emit = cache.draw(picture, palette: 0,
                              at: .cells(CellRect(col: 1, row: 1, cols: 4, rows: 2),
                                         paneCols: 4, paneRows: 2))
        XCTAssertEqual(cellCount(emit.bytes), 4 + 3, "the last row stops one cell short")
    }

    // MARK: - forget

    /// The caller has just deleted the image, so the book has to let go of it: a placement of a
    /// picture the terminal no longer holds draws nothing. Only that key goes.
    func testForgetMakesTheNextDrawTransmitAgain() {
        let cache = IconCache()
        let picture = IconCache.Graphic(frames: [image(w: 5, h: 4, seed: 10)])
        let other = IconCache.Graphic(frames: [image(w: 5, h: 4, seed: 11)])
        let placement = IconCache.Placement.pixels(cols: 2, rows: 2)
        let first = cache.draw(picture, palette: 0, at: placement)
        XCTAssertTrue(cache.draw(other, palette: 0, at: placement).transmitted)
        XCTAssertEqual(cache.draw(picture, palette: 0, at: placement).payloadBytes, 0)

        cache.forget(picture, palette: 0)
        let again = cache.draw(picture, palette: 0, at: placement)
        XCTAssertTrue(again.transmitted, "a forgotten picture is transmitted again")
        XCTAssertGreaterThan(again.payloadBytes, 0)
        XCTAssertEqual(again.bytes, first.bytes, "and the same picture is the same bytes")
        // The other picture still knows the terminal has it.
        XCTAssertEqual(cache.draw(other, palette: 0, at: placement).payloadBytes, 0)

        // Forgetting a key that was never drawn changes nothing (a card that never started).
        cache.forget(IconCache.Graphic(frames: [noise(w: 2, h: 2)]), palette: 0)
    }

    // MARK: - the payload itself

    /// `o=z` says the payload is a zlib stream, and "the picture is on the wire" means it inflates
    /// back to the pixels the caller gave — not to something the right size.
    func testThePayloadInflatesBackToThePixels() throws {
        let cache = IconCache()
        let picture = IconCache.Graphic(frames: [image(w: 12, h: 9, seed: 12)])
        let emit = cache.draw(picture, palette: 0, at: .pixels(cols: 6, rows: 5))
        let base64 = base64Payload(apcs(emit.bytes))
        XCTAssertEqual(emit.payloadBytes, base64.count, "payloadBytes counts base64 characters")
        let raw = try XCTUnwrap(Data(base64Encoded: base64), "a transmit carries base64")
        XCTAssertEqual(inflate([UInt8](raw)), picture.frames[0].pixels)
    }

    /// A payload wider than 4096 characters is split, and the chunks reassemble in order — the
    /// loader's own picture is bigger than one chunk, so this is not a detail it can omit.
    func testAChunkedPayloadReassemblesToThePixels() throws {
        let cache = IconCache()
        // 96x48 px of noise: ~18 KB of base64, i.e. five chunks at the writer's 4096.
        let picture = IconCache.Graphic(frames: [noise(w: 96, h: 48)])
        let emit = cache.draw(picture, palette: 0, at: .pixels(cols: 12, rows: 6))
        // Only the transmit's own APCs: the placement that ends the emit has no payload.
        let chunks = apcs(emit.bytes).filter { $0.hasPrefix("Gf=") || $0.hasPrefix("Gm=") }
        XCTAssertGreaterThanOrEqual(chunks.count, 2, "the picture must cross the chunk boundary")
        XCTAssertTrue(chunks[0].hasPrefix("Gf=24,s=96,v=48,a=t,o=z,q=2,i=9000,m=1;"),
                      "the first chunk is the control list, and it says there is more")
        for chunk in chunks.dropFirst() {
            XCTAssertTrue(chunk.hasPrefix("Gm="), "a continuation carries m= and no control list")
        }
        // Every chunk but the last is exactly 4096 base64 characters, the writer's chunk size.
        let payloads = chunks.compactMap { apc -> String? in
            guard let semicolon = apc.firstIndex(of: ";") else { return nil }
            return String(apc[apc.index(after: semicolon)...])
        }
        XCTAssertEqual(payloads.count, chunks.count, "every chunk of a transmit has a payload")
        for chunk in payloads.dropLast() {
            XCTAssertEqual(chunk.utf8.count, 4096)
        }
        XCTAssertLessThanOrEqual(payloads.last!.utf8.count, 4096)

        let base64 = payloads.joined()
        XCTAssertEqual(emit.payloadBytes, base64.count)
        let raw = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(inflate([UInt8](raw)), picture.frames[0].pixels)
    }

    /// The format is the wire's channel count *and* part of the key: `f=32` with the same bytes is a
    /// different picture, and a terminal told `f=24` for an RGBA buffer draws the alpha as colour.
    func testTheFormatIsTheChannelCountAndPartOfTheKey() {
        let cache = IconCache()
        let rgba = IconImage(width: 4, height: 4, pixels: [UInt8](repeating: 0x10, count: 4 * 4 * 4),
                             format: .rgba)
        let emit = cache.draw(.init(frames: [rgba]), palette: 0, at: .pixels(cols: 2, rows: 2))
        XCTAssertTrue(emit.bytes.contains("Gf=32,s=4,v=4,a=t,o=z,q=2,i=9000,m=0;"))

        let rgb = IconImage(width: 2, height: 2, pixels: [UInt8](repeating: 9, count: 12))
        let asRGBA = IconImage(width: 2, height: 2, pixels: [UInt8](repeating: 9, count: 12),
                               format: .rgba)
        XCTAssertNotEqual(IconCache.contentHash(frames: [rgb]),
                          IconCache.contentHash(frames: [asRGBA]),
                          "the same bytes in another format are another picture")
    }

    /// The hash covers everything a terminal would see: the size (not only the byte count), the order
    /// of the frames, and the format.
    func testContentHashCoversSizeOrderAndFormat() {
        let wide = IconImage(width: 256, height: 1, pixels: [UInt8](repeating: 4, count: 256 * 3))
        let tall = IconImage(width: 1, height: 256, pixels: [UInt8](repeating: 4, count: 256 * 3))
        XCTAssertNotEqual(IconCache.contentHash(frames: [wide]), IconCache.contentHash(frames: [tall]),
                          "256x1 and 1x256 are the same bytes and different pictures")
        let a = image(w: 3, h: 3, seed: 20)
        let b = image(w: 3, h: 3, seed: 21)
        XCTAssertNotEqual(IconCache.contentHash(frames: [a, b]),
                          IconCache.contentHash(frames: [b, a]),
                          "a frame swapped with its neighbour is another animation")
        XCTAssertNotEqual(IconCache.contentHash(frames: [a]), IconCache.contentHash(frames: [a, a]),
                          "one frame and the same frame twice are different graphics")
    }

    // MARK: - nothing to draw

    /// A graphic that cannot be drawn draws nothing: a placement of an image the terminal never
    /// received is a hole on the grid, and a frame whose buffer does not add up is a sheared picture
    /// (the terminal reads it at its own stride and does not refuse it).
    func testAGraphicThatCannotBeDrawnEmitsNothing() {
        let cache = IconCache()
        let placement = IconCache.Placement.pixels(cols: 2, rows: 2)
        let short = IconImage(width: 4, height: 4, pixels: [0, 0, 0])
        let broken = cache.draw(.init(frames: [short]), palette: 0, at: placement)
        XCTAssertEqual(broken.bytes, "")
        XCTAssertFalse(broken.transmitted)
        XCTAssertEqual(broken.payloadBytes, 0)

        let empty = cache.draw(.init(frames: []), palette: 0, at: placement)
        XCTAssertEqual(empty.bytes, "", "no frames, no transmit — and so no placement either")

        // A rectangle with no cells is not a placement the terminal would accept.
        let drawn = cache.draw(.init(frames: [image(w: 2, h: 2, seed: 30)]), palette: 0,
                              at: .pixels(cols: 0, rows: 0))
        XCTAssertTrue(drawn.bytes.hasSuffix(esc + "\\"), "the transmit is all there is")
        XCTAssertFalse(drawn.bytes.contains("c=0"), "a zero-cell placement is a rejected escape")
    }
}
