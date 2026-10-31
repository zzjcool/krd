import XCTest
import krdcore
@testable import krd

/// Issue #100: a repaint reuses the pictures it already has, and a page step captures only what is
/// genuinely new on the page.
///
/// What a page step costs the reader is a capture round-trip per panel, so the property that matters
/// is not "the pictures are right" (the geometry tests own that) but **which panels were
/// photographed**. The demo model renders the pattern through the real capture path
/// (`WallPictures.demo`), so this runs anywhere: no window server, no grant, no desktop.
///
/// No render counter: reuse is asserted from the `reused` set the capture reports and from the
/// pixels being equal to the first paint's for the same key, which is the property a reader can see
/// (an identical picture, not a re-rendered one).
final class WallPictureReuseTests: XCTestCase {
    /// A pane whose band fits exactly one card: one page step then changes the window on the card
    /// and nothing else, which is the shape the issue is about (a page of several cards would move
    /// several slots at once and make "which panels were captured" harder to read).
    private func pane(cols: Int = 60, rows: Int = 24) -> PaneGeometry {
        PaneGeometry(cols: cols, rows: rows, cellW: 8, cellH: 16, dpr: 2, source: "test")
    }

    /// The panels `Desk.wallPanels` builds for a page starting at `cardStart` — stamps included,
    /// because the key is made of them (a helper that left them out would make every window look
    /// alike and this suite prove nothing).
    private func plan(model: WallModel, cardStart: Int) -> [WallPanel] {
        var state = WallState()
        state.per = 1
        state.cardStart = cardStart
        let p = pane()
        let display = model.displays[0]
        let aspect = Double(display.width) / Double(display.height)
        let layout = state.layout(cols: p.cols, rows: p.rows,
                                  displays: model.displays.count,
                                  windows: model.windows.count,
                                  stageAspect: aspect,
                                  cellAspect: p.cellAspect)
        let cell = p.pictureCell(scale: 2)
        let cards: [PanelSource?] = layout.cards.indices.map { slot in
            let index = layout.cardStart + slot
            guard model.windows.indices.contains(index) else { return nil }
            let window = model.windows[index]
            let bounds = window.bounds
            return PanelSource(kind: .window(window.windowID),
                               aspect: Double(bounds.width) / Double(bounds.height),
                               stamp: PanelSourceStamp(kind: .window(x: bounds.x, y: bounds.y,
                                                                     width: bounds.width,
                                                                     height: bounds.height,
                                                                     title: window.title)))
        }
        return WallPanels.plan(layout: layout, cellW: cell.w, cellH: cell.h,
                               stageSource: PanelSource(kind: .display(display.id), aspect: aspect,
                                                        stamp: PanelSourceStamp(kind: .display(
                                                            width: display.width,
                                                            height: display.height))),
                               cardSources: cards)
    }

    private func demoPlan(cardStart: Int) -> [WallPanel] {
        plan(model: WallSource.demoModel(), cardStart: cardStart)
    }

    /// `WallPictures.demo`/`.quality`/`.square` are process-wide and set once before a paint, so a
    /// test that sets them has to put them back.
    override func setUp() {
        super.setUp()
        WallPictures.demo = true
    }

    override func tearDown() {
        WallPictures.demo = false
        WallPictures.quality = .wall
        WallPictures.square = false
        super.tearDown()
    }

    private func key(_ panel: WallPanel) -> PanelKey {
        panel.key(quality: WallPictures.quality.value, rounded: !WallPictures.square)
    }

    // MARK: a page step

    func testAPageStepReusesTheStageAndCapturesOnlyNewCards() async {
        let cache = WallPictures.PanelCache()
        let pageA = demoPlan(cardStart: 0)
        XCTAssertEqual(pageA.count, 2, "the demo model gives this pane a stage and one card")
        let first = await WallPictures.capture(pageA, cache: cache)
        XCTAssertEqual(first.reused, [], "nothing is cached before the first paint")
        XCTAssertEqual(first.pictures.count, pageA.count)
        let keysAfterA = cache.count

        // One page step: the same pane, the same stage, a different window on the card.
        let pageB = demoPlan(cardStart: 3)
        XCTAssertEqual(pageB.count, 2)
        XCTAssertNotEqual(pageA.map(key), pageB.map(key),
                          "the card is a different window, so the page is a new page")
        let second = await WallPictures.capture(pageB, cache: cache)

        XCTAssertTrue(second.reused.contains(0), "the stage is photographed once per layout")
        XCTAssertEqual(second.reused, [0], "and nothing frozen: the new card is captured")
        XCTAssertEqual(second.pictures.count, 2, "a reused panel is still a picture for its slot")

        // Reused means *the same pixels*, not "a picture of the same size".
        var pixelsA: [PanelKey: [UInt8]] = [:]
        for picture in first.pictures { pixelsA[key(picture.panel)] = picture.pixels }
        for picture in second.pictures where second.reused.contains(picture.panel.slot) {
            XCTAssertEqual(pixelsA[key(picture.panel)], picture.pixels,
                           "slot \(picture.panel.slot): a reused picture is the cached one")
        }

        // The cache grew by exactly the keys it did not have: the new card.
        XCTAssertEqual(cache.count, keysAfterA + 1)
        // And the reused panel came back with *this* page's rectangle, not the one it was
        // photographed at (the picture is what a slot wants drawn).
        for picture in second.pictures {
            XCTAssertEqual(picture.panel, pageB.first { $0.slot == picture.panel.slot })
        }
    }

    // MARK: the wired invalidation rule (not just the key's arithmetic)

    /// A window that is dragged is the same window, the same size, the same slot — and a different
    /// picture. The key has to be what `capture` actually consults, not only what `PanelKey` can
    /// express: this plans the same page twice with one window's origin moved and reads the answer
    /// off the `reused` set.
    func testAWindowThatMovedIsPhotographedAgain() async {
        let cache = WallPictures.PanelCache()
        let model = WallSource.demoModel()
        let pageA = plan(model: model, cardStart: 0)
        _ = await WallPictures.capture(pageA, cache: cache)
        let keysAfterA = cache.count

        var movedModel = model
        let first = model.windows[0]
        movedModel.windows[0] = OrderedWindow(windowID: first.windowID, pid: first.pid,
                                              app: first.app, title: first.title,
                                              bounds: CGRectCompat(x: first.bounds.x + 120,
                                                                   y: first.bounds.y + 80,
                                                                   width: first.bounds.width,
                                                                   height: first.bounds.height))
        let pageB = plan(model: movedModel, cardStart: 0)
        XCTAssertEqual(pageA.map(\.fit), pageB.map(\.fit),
                       "the size is the same: only the stamp moved, or this proves nothing")
        let second = await WallPictures.capture(pageB, cache: cache)
        XCTAssertTrue(second.reused.contains(0), "the display did not move")
        XCTAssertFalse(second.reused.contains(1), "a window that moved is a different picture")
        XCTAssertEqual(cache.count, keysAfterA + 1)
    }

    /// The one asymmetry in the cache, pinned: a **desk change** re-photographs the display (its
    /// stamp is only its resolution, so nothing else can ever dirty it) and leaves the cards alone
    /// (their stamps are the windows). A page step is a click and does not go through
    /// `forgetStage`, which is the case the issue is about.
    func testADeskChangeRePhotographsTheStageAndKeepsTheCards() async {
        let cache = WallPictures.PanelCache()
        let page = demoPlan(cardStart: 0)
        _ = await WallPictures.capture(page, cache: cache)
        let stage = page.first { $0.slot == WallPanels.stageSlot }!
        XCTAssertFalse(cache.isOnScreen(slot: WallPanels.stageSlot, key: key(stage), rect: stage.rect),
                       "nothing is on screen before the first paint records it")
        cache.didPlace(slot: WallPanels.stageSlot, key: key(stage), rect: stage.rect)
        XCTAssertTrue(cache.isOnScreen(slot: WallPanels.stageSlot, key: key(stage), rect: stage.rect))
        cache.forgetStage()
        // Both halves, or the stage would be re-photographed and then not re-emitted: the wall would
        // keep the process's first pixels for ever.
        XCTAssertFalse(cache.isOnScreen(slot: WallPanels.stageSlot, key: key(stage), rect: stage.rect),
                       "a desk change must force the stage out on the wire, not only into the memo")
        let after = await WallPictures.capture(page, cache: cache)
        XCTAssertFalse(after.reused.contains(0), "the desk changed: the display is shot again")
        XCTAssertTrue(after.reused.contains(1), "the card's window did not")
        XCTAssertEqual(after.pictures.count, page.count, "every slot still gets a picture")
    }

    // MARK: the age bound (the one thing a key cannot see)

    /// A window whose *content* moves while its bounds and title stand still — a video, a terminal
    /// scrolling, a document being typed into — has a key that never changes. Without an age the
    /// cache would pin it to its first frame for as long as the wall runs, which is the staleness
    /// bound `WallWatch`/`#169` document (~2.5 s) quietly reopening as unbounded.
    ///
    /// The clock is injected, so "past the bound" is a number a test can assert rather than a sleep.
    func testAPictureOlderThanTheWallsStalenessBoundIsPhotographedAgain() async {
        var now: TimeInterval = 1000
        let cache = WallPictures.PanelCache(now: { now })
        let page = demoPlan(cardStart: 0)

        let first = await WallPictures.capture(page, cache: cache)
        XCTAssertEqual(first.reused, [], "nothing is cached before the first paint")
        // The placement record a paint would have made, so the *second* half of the rule is live.
        for panel in page { cache.didPlace(slot: panel.slot, key: key(panel), rect: panel.rect) }

        // Inside the bound: the same page is free. Half the bound, so the assertion is about the
        // rule and not about a rounding.
        now += WallPictures.PanelCache.maxAge / 2
        let warm = await WallPictures.capture(page, cache: cache)
        XCTAssertEqual(warm.reused, Set(page.map(\.slot)), "inside the bound, nothing is re-shot")
        for panel in page {
            XCTAssertTrue(cache.isOnScreen(slot: panel.slot, key: key(panel), rect: panel.rect),
                          "slot \(panel.slot) is still on screen inside the bound")
        }

        // One whole bound past the *store*: the key still matches, and it must not matter.
        now += WallPictures.PanelCache.maxAge
        let cold = await WallPictures.capture(page, cache: cache)
        XCTAssertEqual(cold.reused, [], "past the bound every panel is photographed again")
        XCTAssertEqual(cold.pictures.count, page.count, "and every slot still gets a picture")
        for panel in page {
            XCTAssertFalse(cache.isOnScreen(slot: panel.slot, key: key(panel), rect: panel.rect),
                           "slot \(panel.slot): a re-captured picture must also be re-sent")
        }

        // The age is a *duration*, not a property of the key: the very next paint is warm again.
        let after = await WallPictures.capture(page, cache: cache)
        XCTAssertEqual(after.reused, Set(page.map(\.slot)),
                       "the fresh capture is cached, so the next paint is free")
    }

    /// The bound is the wall's own number, not a second opinion invented in the cache: a retune of
    /// `WallSource.stalenessBound` (the 2 s poll, #169) has to move the card's age with it, or the
    /// cache silently re-opens the hole for whatever the wall now promises.
    func testThePicturesAgeIsTheWallsStalenessBound() {
        XCTAssertEqual(WallPictures.PanelCache.maxAge, WallSource.stalenessBound)
        XCTAssertLessThan(WallPictures.PanelCache.maxAge, 3.0,
                          "2.51 s: the poll plus one paint, per WallWatch's own bound")
    }

    // MARK: a repaint that changes nothing

    func testTheSamePageTwiceCapturesNothing() async {
        let cache = WallPictures.PanelCache()
        let page = demoPlan(cardStart: 0)
        let first = await WallPictures.capture(page, cache: cache)
        let second = await WallPictures.capture(page, cache: cache)
        XCTAssertEqual(second.reused, Set(page.map(\.slot)),
                       "a repaint of the page already on screen captures no panel")
        XCTAssertEqual(second.pictures.map(\.pixels), first.pictures.map(\.pixels),
                       "and every picture is the one already cached")
        XCTAssertEqual(cache.count, first.pictures.count,
                       "a second paint adds no key")
    }

    // MARK: what the cache keeps

    /// The memo is bounded: 16 pictures, least recently used evicted. Eviction is about the
    /// *capture* cache only — the terminal still holds the payload for a slot it already has, so a
    /// forgotten key costs a re-capture and never a re-emit.
    func testTheCacheKeepsSixteenPicturesAndForgetsTheOldest() async {
        // 17 distinct windows, one card each: 17 distinct keys, which is one more than the cap.
        let model = WallModel(
            displays: [WallDisplay(name: "d", width: 2560, height: 1600, id: 1, main: true)],
            windows: (1...17).map { i in
                OrderedWindow(windowID: UInt32(i), pid: 1, app: "A", title: "w\(i)",
                              bounds: CGRectCompat(x: 0, y: 0, width: 1200, height: 800))
            })
        var panels: [WallPanel] = []
        for start in 0..<17 {
            guard let card = plan(model: model, cardStart: start).first(where: { $0.slot > 0 })
            else { return XCTFail("page \(start) must have a card") }
            panels.append(card)
        }
        XCTAssertEqual(Set(panels.map(key)).count, 17, "17 different pictures")

        let cache = WallPictures.PanelCache()
        let oldest = key(panels[0])
        let freshest = key(panels[16])
        // Pretend the oldest picture is on screen, which is what makes "evicted != re-emitted"
        // checkable: the sent map must survive the eviction.
        cache.didPlace(slot: 1, key: oldest, rect: panels[0].rect)

        let result = await WallPictures.capture(panels, cache: cache)

        XCTAssertEqual(result.reused, [], "every key is new to this cache")
        XCTAssertEqual(cache.count, 16, "the cap is 16 pictures")
        XCTAssertNil(cache.picture(for: oldest), "the least recently used one went")
        XCTAssertNotNil(cache.picture(for: freshest), "the freshest one is still a hit")
        XCTAssertTrue(cache.isOnScreen(slot: 1, key: oldest, rect: panels[0].rect),
                      "eviction forgets the payload, not where the picture is on screen")

        // And the evicted one is re-captured on the next paint, while the freshest stays reused.
        let again = await WallPictures.capture([panels[0], panels[16]], cache: cache)
        XCTAssertEqual(again.reused, [panels[16].slot],
                       "one key was forgotten, the other is still cached")
    }

    // MARK: a slot that stopped showing its picture

    /// A mask is not a picture: when a capture fails the slot's cells are painted with text, so the
    /// cache may not go on believing its payload is on screen. Otherwise the next paint of the same
    /// window skips the emit ("already on screen") and the reader keeps the mask on top of a picture
    /// that is not there — the one way a reuse cache can make the wall *wrong*.
    func testAMaskForgetsTheSlotsPlacementButKeepsTheCachedPicture() async {
        let cache = WallPictures.PanelCache()
        let panels = demoPlan(cardStart: 0)
        let first = await WallPictures.capture(panels, cache: cache)
        XCTAssertEqual(first.pictures.count, panels.count)
        let stage = key(panels[0])
        cache.didPlace(slot: 0, key: stage, rect: panels[0].rect)
        XCTAssertTrue(cache.isOnScreen(slot: 0, key: stage, rect: panels[0].rect))

        // This paint's capture failed on the stage: the slot paints a mask over the picture's cells.
        cache.forget(slot: 0)
        XCTAssertFalse(cache.isOnScreen(slot: 0, key: stage, rect: panels[0].rect),
                       "a mask on those cells means the picture is gone")
        XCTAssertNotNil(cache.picture(for: stage),
                        "the payload itself is still good: forgetting a slot is not evicting")

        // The same window comes back: it is captured from the cache (no re-capture) but it *is*
        // emitted again, because the terminal no longer has it on screen.
        let again = await WallPictures.capture(panels, cache: cache)
        XCTAssertEqual(again.reused, Set(panels.map(\.slot)), "nothing had to be photographed again")
        XCTAssertEqual(again.pictures.map(\.pixels), first.pictures.map(\.pixels))
    }

    // MARK: the wire rule for a placeholder panel

    /// A reused panel is **placed** again, never re-sent: from the virtual placement onwards the
    /// bytes of `placePanelAsPlaceholder` are byte-for-byte what `emitPanelAsPlaceholder` writes (the
    /// placement line and the invisible cell grid, no transmit). The picture therefore draws exactly
    /// where it drew before - the text layer blanks those cells every frame, so skipping them would
    /// erase it - for a fraction of the bytes.
    func testRePlacingAPanelEmitsTheCellsAndNoPayload() throws {
        let pixels = DemoPicture.render(width: 96, height: 64)
        func emit(_ body: (ScreenWriter) -> Void) -> [UInt8] {
            let writer = ScreenWriter()
            var bytes: [UInt8] = []
            writer.sink = { bytes.append(contentsOf: $0) }
            writer.beginSession()
            writer.beginFrame()
            body(writer)
            writer.endFrame()
            return bytes
        }
        let full = emit {
            $0.emitPanelAsPlaceholder(id: 5001, placementID: 9001, row: 3, col: 5, cols: 6, rows: 4,
                                      pixels: pixels, width: 96, height: 64, level: 3,
                                      paneCols: 60, paneRows: 24)
        }
        let cells = emit {
            $0.placePanelAsPlaceholder(id: 5001, placementID: 9001, row: 3, col: 5, cols: 6, rows: 4,
                                       paneCols: 60, paneRows: 24)
        }
        XCTAssertFalse(cells.isEmpty, "a re-place still writes something")
        XCTAssertLessThan(cells.count, full.count, "no payload travels for a reused picture")
        XCTAssertTrue(String(decoding: full, as: UTF8.self).contains("a=t"),
                      "the full emit is the one that carries the transmit")
        XCTAssertFalse(String(decoding: cells, as: UTF8.self).contains("a=t"),
                       "and a re-place carries none")

        // The tails: everything from the panel's own APC (`ESC _ G`) onwards, which is the virtual
        // placement plus the cell grid plus the block's close.
        func tail(from marker: Int, _ bytes: [UInt8]) -> [UInt8] { Array(bytes[marker...]) }
        let fullTail = tail(from: try XCTUnwrap(lastAPC(full), "the full emit places the picture"),
                            full)
        let cellTail = tail(from: try XCTUnwrap(lastAPC(cells), "the re-place places the picture"),
                            cells)
        XCTAssertEqual(fullTail, cellTail,
                       "a re-place must write exactly the placement + grid a full emit writes")
        let tailText = String(decoding: cellTail, as: UTF8.self)
        XCTAssertEqual(tailText.unicodeScalars.filter { $0 == "\u{10EEEE}" }.count, 6 * 4,
                       "cols x rows placeholder cells, no more")
    }

    /// The last `ESC _ G` in a stream: the panel's own APC (any transmit before it is earlier).
    private func lastAPC(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 3 else { return nil }
        for i in stride(from: bytes.count - 3, through: 0, by: -1)
        where bytes[i] == 0x1B && bytes[i + 1] == 0x5F && bytes[i + 2] == 0x47 {
            return i
        }
        return nil
    }
}
