import XCTest
@testable import krdcore

/// What a *session start* owes a pane that a dead `krd` left behind.
///
/// Context (docs/PROTOCOL.md):
///
///  * §1 — "The first six escapes are the *heal* sequence: a pane whose parser is waiting for an
///    `ST` shows nothing at all (not even text) until it gets one, which is what a `kill -9`
///    mid-`write()` leaves behind. Re-running krd fixes such a pane automatically". The claim is
///    about the *parser* state: a dangling APC and a dangling `?2026h` block.
///  * §4 — `a=d,d=a` ("delete every placement") is sent "**only** at those two points", `clear()`
///    and `endSession()`; `ESC[2J` is an *erase*, not a placement delete.
///  * §6.3 — `iid = 100 + tileIndex`, `pid = 1000 + tileIndex`, fixed for the session.
///
/// The three facts together mean `beginSession()` alone cannot drop a dead session's placements:
/// it sends no `a=d` at all. The delete comes from the first `clear()`, which every *product* path
/// runs immediately after entering the alternate screen — live mirror (`main.swift:1058`→`:1063`),
/// wall (`:1210`→`:1216`), `resumeWall` (`:1646`→`:1648`). `docs/design-overview.md` states that
/// rule as the design ("A kitty placement also outlives the process that made it, so **every
/// session starts by deleting every image in it** (`ScreenWriter.clear()`)") and
/// `Tests/krdTests/WallProcessTests.testTheWallDropsWhateverImagesThePaneHeld` pins it end to end
/// for the wall binary.
///
/// So these tests pin the invariant where it actually lives (the call-site sequence), pin the one
/// gap that is left (`beginSession()` by itself, which the dev paths `--mock`/`--selftest`/
/// `--bench-wire`/`--replay` still rely on), and pin the id arithmetic that makes a *missing*
/// delete show up as ghost tiles rather than as nothing. They are green on HEAD by design: this
/// suite documents behaviour, it does not ask for a change. See the accompanying report/issue draft
/// for the one doc sentence that is genuinely missing from PROTOCOL §1.
final class SessionHealTests: XCTestCase {
    // MARK: bytes

    /// 8x4-cell tiles, 17x33-px cells — the product defaults (`main.swift:71-75`) and the geometry
    /// `Tests/krdcoreTests/GoldenDumpTests.swift` pins, so the numbers here mean the same thing as
    /// the CLI's.
    private func grid(cols: Int, rows: Int) -> TileGrid {
        TileGrid.make(paneCols: cols, paneRows: rows, cellW: 17, cellH: 33,
                      aspect: 1.7, tileCols: 8, tileRows: 4)
    }

    /// Offsets of `needle` in `hay`. Hand-rolled rather than `firstRange(of:)` so every assertion
    /// below can talk about *all* occurrences: "the delete is there" and "the delete is there once"
    /// are different claims (a per-frame delete would be the regression §6.3 warns about).
    private func occurrences(of needle: [UInt8], in hay: [UInt8]) -> [Int] {
        guard !needle.isEmpty, needle.count <= hay.count else { return [] }
        var found: [Int] = []
        var i = 0
        while i <= hay.count - needle.count {
            if hay[i] == needle[0] {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count {
                    found.append(i)
                    i += needle.count
                    continue
                }
            }
            i += 1
        }
        return found
    }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private var deleteAll: [UInt8] { bytes("\u{1B}_Ga=d,d=a\u{1B}\\") }
    private var altScreenOn: [UInt8] { bytes("\u{1B}[?1049h") }
    private var frameBlockOpen: [UInt8] { bytes("\u{1B}[?2026h") }

    /// Emit one tile of `grid` inside a frame block, exactly the shape `Desk.handleFrame` uses at
    /// the default `KRD_SYNC=frame`. Returns every byte that reached the sink.
    @discardableResult
    private func emitFirstTile(_ writer: ScreenWriter, _ grid: TileGrid) -> [UInt8] {
        var bytes: [UInt8] = []
        writer.sink = { bytes.append(contentsOf: $0) }
        writer.beginFrame()
        let rect = grid.rect(0, 0)
        let pixels = [UInt8](repeating: 0x40, count: rect.w * rect.h * grid.bpp)
        guard let tile = ScreenWriter.compress(index: 0, rect: rect, pixels: pixels, level: 6) else {
            XCTFail("compress returned nil for tile 0")
            return bytes
        }
        writer.emit(tile, sync: writer.perTileSync)
        writer.endFrame()
        return bytes
    }

    // MARK: 1. the invariant, where it actually lives

    /// A session that re-uses ids `100+k` / `1000+k` must drop whatever placements a predecessor
    /// left before its first tile block — otherwise the ids it does *not* re-use (anything above its
    /// own tile count, §6.3) stay attached to their cells: `ESC[2J` erases characters and leaves
    /// images alone (§4).
    ///
    /// `beginSession()` does not do it (§4 lists the delete only for `clear`/`endSession`), so every
    /// product session runs `clear()` right after it. This test drives byte-for-byte the sequence the
    /// three product paths run and pins the *order*: alternate screen first (a delete answered while
    /// the terminal is still on the main screen does not reach an image keyed to the other one —
    /// `WallProcessTests.testAReturningMirrorLeavesTheAlternateScreenBeforeTheWallTakesIt`), then the
    /// delete, then the first `?2026h`.
    func testALiveSessionDropsTheDeadSessionsPlacementsBeforeTheFirstTileBlock() {
        let writer = ScreenWriter()
        var seen: [UInt8] = []
        writer.sink = { seen.append(contentsOf: $0) }

        writer.beginSession()
        writer.clear()            // main.swift:1058→1063, :1210→1216, :1646→1648
        seen.append(contentsOf: emitFirstTile(writer, grid(cols: 80, rows: 24)))

        let deletes = occurrences(of: deleteAll, in: seen)
        let sessions = occurrences(of: altScreenOn, in: seen)
        let blocks = occurrences(of: frameBlockOpen, in: seen)

        XCTAssertEqual(deletes.count, 1,
                       "a session start must drop the pane's placements exactly once (one `a=d,d=a`); "
                       + "got \(deletes.count) in \(seen.count) B")
        XCTAssertEqual(sessions.count, 1, "one alternate-screen entry per session start")
        guard let deleteAt = deletes.first, let sessionAt = sessions.first, let blockAt = blocks.first else {
            XCTFail("missing delete/session/frame marker in \(String(decoding: seen, as: UTF8.self).debugDescription)")
            return
        }
        XCTAssertLessThan(sessionAt, deleteAt,
                          "the delete must land *after* `?1049h`: a placement can be keyed to the screen "
                          + "it was placed on, and the dead session left that screen entered")
        XCTAssertLessThan(deleteAt, blockAt,
                          "the delete must land *before* the first `?2026h`: once a tile block is open the "
                          + "dead session's placements are already on screen, and the ids this session "
                          + "does not re-use (§6.3) are never overwritten")
    }

    // MARK: 2. the gap that is left, stated exactly

    /// `beginSession()` on its own leaves the placement store alone — and that is the whole scope of
    /// §1's heal claim.
    ///
    /// §1 promises the pane recovers ("Re-running krd fixes such a pane automatically") from a
    /// `kill -9` mid-`write()`; what it fixes is the *parser* waiting for an `ST`. §4 puts the only
    /// placement delete in `clear()` and `endSession()`, so a caller that enters a session and does
    /// not clear inherits the previous placements. Today that is the dev paths: `--bench-wire`
    /// (`main.swift:867`), `--selftest` (`:890`), `--mock` (`:918`), `--replay` (`:2041`) call
    /// `beginSession()` with no `clear()`. A `--selftest` in a pane previously drawn by a bigger
    /// layout re-uses only `100..<100+count` and leaves the rest of the old grid on screen.
    ///
    /// Pinning it here keeps the issue honest: the fix (if any) belongs in `beginSession`'s own
    /// bytes — after `?1049h`, never before it — not in a new escape at the call sites.
    func testBeginSessionAloneLeavesThePredecessorsPlacementsInPlace() {
        let writer = ScreenWriter()
        var seen: [UInt8] = []
        writer.sink = { seen.append(contentsOf: $0) }

        writer.beginSession()

        XCTAssertEqual(occurrences(of: deleteAll, in: seen).count, 0,
                       "PROTOCOL §4: `a=d,d=a` is sent only by clear() and endSession(); beginSession's "
                       + "`2J` erases characters and leaves placements attached to their cells")
        XCTAssertEqual(occurrences(of: bytes("a=d"), in: seen).count, 0,
                       "and no other delete shape either — §5 keeps per-tile deletes out of krd")

        // §4's two delete points, for contrast: the same writer *does* delete when told to end.
        writer.sink = { seen.append(contentsOf: $0) }
        seen.removeAll()
        writer.endSession()
        XCTAssertEqual(occurrences(of: deleteAll, in: seen).count, 1,
                       "endSession is one of §4's two delete points and must keep deleting every placement")
    }

    // MARK: 3. what the heal does cover

    /// The heal sequence, in order, byte for byte: `ESC \` (close a dangling APC a killed
    /// predecessor left open — until it arrives the pane shows nothing at all), `?2026l` (close a
    /// dangling synchronized-update block, which otherwise freezes drawing), the three mouse-mode
    /// resets, SGR reset, `?25h`, and only then the alternate screen, `2J`, home and `?25l`.
    ///
    /// Order matters for one reason: everything before `?1049h` is sent to the screen the dead
    /// session was drawing on, so the two "unstick the parser" escapes have to come *first* — if
    /// they arrived after the screen switch the pane would still be swallowing bytes.
    func testTheHealSequenceClosesTheDanglingAPCAndTheSyncBlockFirst() {
        let writer = ScreenWriter()
        var seen: [UInt8] = []
        writer.sink = { seen.append(contentsOf: $0) }
        writer.beginSession()

        let heal = "\u{1B}\\\u{1B}[?2026l\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1006l\u{1B}[0m\u{1B}[?25h"
        let want = heal + "\u{1B}[?1049h\u{1B}[2J\u{1B}[H\u{1B}[?25l"
        // Exact equality, not `hasPrefix`: the claim is that these are the *only* bytes a session
        // start sends, so an extra escape added here has to be an intentional change to §1.
        XCTAssertEqual(String(decoding: seen, as: UTF8.self), want,
                       "beginSession no longer matches PROTOCOL §1 byte for byte")

        // …and the same order as readable offsets, so a failure says which pair moved.
        let order: [(String, [UInt8])] = [
            ("ST", bytes("\u{1B}\\")),
            ("?2026l", bytes("\u{1B}[?2026l")),
            ("?1003l", bytes("\u{1B}[?1003l")),
            ("?1002l", bytes("\u{1B}[?1002l")),
            ("?1006l", bytes("\u{1B}[?1006l")),
            ("0m", bytes("\u{1B}[0m")),
            ("?25h", bytes("\u{1B}[?25h")),
            ("?1049h", altScreenOn),
            ("2J", bytes("\u{1B}[2J")),
            ("H", bytes("\u{1B}[H")),
            ("?25l", bytes("\u{1B}[?25l")),
        ]
        var previous = -1
        for (name, needle) in order {
            guard let at = occurrences(of: needle, in: seen).first else {
                XCTFail("the heal sequence no longer contains \(name.debugDescription)")
                continue
            }
            XCTAssertGreaterThan(at, previous, "\(name.debugDescription) moved out of the §1 order")
            previous = at
        }
    }

    // MARK: 4. the arithmetic behind the ghost tiles

    /// `emit` picks its ids from the tile *index* alone (`iid = 100 + tileIndex`,
    /// `pid = 1000 + tileIndex`, §6.3), so the id range a session touches is exactly its own tile
    /// count. Session A in a 137x42-cell pane reaches id 297 / pid 1197; session B in an 80x24-cell
    /// pane reaches id 159 / pid 1059. The 138 placements in between are never transmitted *or*
    /// deleted by B — they keep pointing at the cells the dead session put them on. That is why the
    /// delete at session start is the only thing standing between a `kill -9` and ghost tiles, and
    /// why "the new grid is smaller" is not self-healing.
    func testEmitUsesFixedIdsSoASmallerGridCannotCoverTheOldRange() {
        let small = grid(cols: 80, rows: 24)
        let big = grid(cols: 137, rows: 44)
        // 80x24 cells → 10x6 tiles; 137x42 cells (the aspect fit shrinks 44 rows to 42) → 18x11.
        XCTAssertEqual(small.count, 60, "\(small.tilesX)x\(small.tilesY) tiles in an 80x24 pane")
        XCTAssertEqual(big.count, 198, "\(big.tilesX)x\(big.tilesY) tiles in a 137x44 pane")

        // Every tile of the small grid, in one frame block, ids read back out of the wire bytes.
        let writer = ScreenWriter()
        var seen: [UInt8] = []
        writer.sink = { seen.append(contentsOf: $0) }
        writer.beginFrame()
        let pixels = [UInt8](repeating: 0x40, count: small.pixelW * small.pixelH * small.bpp)
        for index in 0..<small.count {
            let rect = small.rect(index % small.tilesX, index / small.tilesX)
            guard let tile = ScreenWriter.compress(index: index, rect: rect,
                                                  pixels: small.extract(pixels, rect: rect),
                                                  level: 6) else {
                XCTFail("compress returned nil for tile \(index)")
                return
            }
            writer.emit(tile, sync: writer.perTileSync)
        }
        writer.endFrame()

        let commands = apcCommands(seen)
        let iids = commands.filter { $0.hasPrefix("f=") && $0.contains(",a=t") }.compactMap { field($0, "i") }
        let pids = commands.filter { $0.hasPrefix("i=") && $0.contains(",a=p") }.compactMap { field($0, "p") }

        XCTAssertEqual(iids.count, small.count, "one transmission per tile (splitting off any chunking)")
        XCTAssertEqual(iids, Array(100..<(100 + small.count)), "image ids are 100 + tileIndex, in tile order")
        XCTAssertEqual(pids, Array(1000..<(1000 + small.count)), "placement ids are 1000 + tileIndex")

        // The ids the small session never touches, and therefore never overwrites or deletes.
        let dead = Set(100..<(100 + big.count))
        let live = Set(iids)
        XCTAssertEqual(dead.subtracting(live).count, big.count - small.count,
                       "a smaller grid leaves \(big.count - small.count) of the dead session's placements alive")
        XCTAssertEqual(100 + big.count - 1, 297, "highest image id a 137x44 pane ever places")
        XCTAssertEqual(1000 + big.count - 1, 1197, "highest placement id")
    }

    // MARK: id parsing

    /// Every kitty graphics command starts with `ESC _ G`; splitting on that gives one string per
    /// command: the first chunk of a transmission (`f=…,a=t,…,i=<iid>`, then base64), the
    /// continuation chunks (`m=1;…`) and the placement (`i=<iid>,p=<pid>,a=p,…`). base64 can contain
    /// neither `ESC` nor `,`, so each piece ends cleanly at the ST.
    private func apcCommands(_ bytes: [UInt8]) -> [String] {
        let text = String(decoding: bytes, as: UTF8.self)
        let marker = "\u{1B}_G"
        var out: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: marker) {
            let after = rest[start.upperBound...]
            let end = after.range(of: "\u{1B}\\")?.lowerBound ?? after.endIndex
            out.append(String(after[..<end]))
            rest = after[end...]
        }
        return out
    }

    private func field(_ command: String, _ name: String) -> Int? {
        for part in command.split(separator: ",") where part.hasPrefix(name + "=") {
            if let value = Int(part.dropFirst(name.count + 1)) { return value }
        }
        return nil
    }
}
