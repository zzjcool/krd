import XCTest
@testable import krd
@testable import krdcore

/// Refs are the only thing that lasts longer than one `krd ax` process, so the rules for
/// "is this the same node" and "which dump printed this ref" are the safety-critical part of
/// the write path. All of it is pure, so it is tested here.
final class AXRefsTests: XCTestCase {
    private func step(_ index: Int, _ role: String = "AXButton", id: String = "", title: String = "") -> AXStep {
        AXStep(index: index, role: role, identifier: id, title: title)
    }

    // MARK: parsing

    func testRefRoundTrip() {
        XCTAssertEqual(AXRef("@e1"), AXRef(index: 1))
        XCTAssertEqual(AXRef("  @e42 "), AXRef(index: 42))
        XCTAssertEqual(AXRef("@e7")?.description, "@e7")
    }

    func testInvalidRefsAreRefused() {
        // A ref that parses as something else would click the wrong control.
        for text in ["", "@", "@e", "@e0", "@e-1", "@e1x", "e5", "@E5", "@e 5", "@e1.5", "ax@e1"] {
            XCTAssertNil(AXRef(text), "\(text) should not parse")
        }
    }

    // MARK: matching a node across time

    func testIdentifierWinsOverARetitle() {
        // Start/Stop buttons keep their identifier; the title is state, not identity.
        let recorded = step(3, id: "playButton", title: "Start")
        let live = step(3, id: "playButton", title: "Stop")
        XCTAssertTrue(recorded.matches(live))
    }

    func testWithoutAnIdentifierATitleChangeIsADifferentNode() {
        let recorded = step(3, title: "Save")
        let live = step(3, title: "Save As…")
        XCTAssertFalse(recorded.matches(live))
    }

    func testRoleAlwaysHasToMatch() {
        XCTAssertFalse(step(1, "AXButton", title: "OK").matches(step(1, "AXStaticText", title: "OK")))
    }

    // MARK: descending the chain

    func testTheRecordedIndexIsUsedWhenItStillMatches() {
        let children = [step(0, title: "a"), step(1, title: "b"), step(2, title: "c")]
        XCTAssertEqual(AXRefs.descend(step(1, title: "b"), children: children), .same(1))
    }

    func testAMovedNodeIsFoundButAMovedSiblingConflictIsNot() {
        let moved = [step(0, title: "a"), step(1, title: "b"), step(2, title: "c")]
        XCTAssertEqual(AXRefs.descend(step(9, title: "c"), children: moved), .moved(2))

        // Two identical buttons: picking one would be a coin flip, so refuse.
        let twins = [step(0, title: "Delete"), step(1, title: "Delete")]
        XCTAssertEqual(AXRefs.descend(step(7, title: "Delete"), children: twins), .ambiguous([0, 1]))
    }

    func testAGoneNodeIsReportedAsGone() {
        let children = [step(0, title: "a")]
        XCTAssertEqual(AXRefs.descend(step(0, title: "b"), children: children), .gone)
        XCTAssertEqual(AXRefs.descend(step(5), children: []), .gone)
    }

    // MARK: the index

    private func snapshot(_ generation: String, app: String = "Finder", bundle: String = "com.apple.finder",
                          window: Int = 0, refs: [String], at: Date = Date()) -> AXSnapshot {
        AXSnapshot(schema: AXSnapshot.schema, generation: generation, createdAt: at,
                   app: app, bundle: bundle, pid: 42, windowIndex: window,
                   windowTitle: "Desktop", windowCount: 1,
                   nodes: refs.map { AXSnapshotNode(ref: $0, chain: [step(0, "AXWindow", title: "Desktop")]) })
    }

    func testANewDumpOfTheSameWindowSupersedesTheRefsItReprints() {
        var index = AXIndex()
        index.record(snapshot("old", refs: ["@e1", "@e2"]))
        index.record(snapshot("new", refs: ["@e1", "@e3"]))
        // @e1 now means "the newest dump of this window"; the old entry is replaced, not added.
        XCTAssertEqual(index.candidates(for: AXRef(index: 1)).map(\.generation), ["new"])
        XCTAssertEqual(index.candidates(for: AXRef(index: 3)).map(\.generation), ["new"])
        // A ref the new dump no longer prints keeps pointing at the dump that did print it:
        // an action queued before the re-dump is verified against its own snapshot instead of
        // being silently retargeted at whatever @e2 means now.
        XCTAssertEqual(index.candidates(for: AXRef(index: 2)).map(\.generation), ["old"])
    }

    func testTwoWindowsKeepTheirOwnRefsAndCanBeToldApart() {
        var index = AXIndex()
        index.record(snapshot("finder", app: "Finder", bundle: "com.apple.finder", refs: ["@e1"]))
        index.record(snapshot("terminal", app: "Terminal", bundle: "com.apple.Terminal", refs: ["@e1"]))
        XCTAssertEqual(index.candidates(for: AXRef(index: 1)).count, 2)
        XCTAssertEqual(index.candidates(for: AXRef(index: 1), app: "terminal").map(\.generation), ["terminal"])
        XCTAssertEqual(index.candidates(for: AXRef(index: 1), app: "com.apple.finder").map(\.generation), ["finder"])
        XCTAssertEqual(index.candidates(for: AXRef(index: 1), app: "Safari"), [])
    }

    func testANewerEntryComesFirst() {
        var index = AXIndex()
        index.record(snapshot("a", app: "A", bundle: "a", refs: ["@e1"], at: Date(timeIntervalSince1970: 10)))
        index.record(snapshot("b", app: "B", bundle: "b", refs: ["@e1"], at: Date(timeIntervalSince1970: 20)))
        XCTAssertEqual(index.candidates(for: AXRef(index: 1)).map(\.generation), ["b", "a"])
    }

    // MARK: on disk

    private var store: AXRefStore!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("krd-ax-tests-\(UUID().uuidString)", isDirectory: true)
        store = AXRefStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveAndResolveARefEndToEnd() throws {
        let dump = snapshot("gen-1", refs: ["@e1", "@e2"])
        try store.save(dump)

        XCTAssertEqual(store.load(generation: "gen-1"), dump)
        let candidates = store.loadIndex().candidates(for: AXRef(index: 2))
        XCTAssertEqual(candidates.map(\.generation), ["gen-1"])
        XCTAssertEqual(candidates.first?.origin, "Finder")
        XCTAssertEqual(store.load(generation: candidates[0].generation)?.node(ref: "@e2")?.chain.count, 1)
    }

    func testPruningKeepsTheNewestDumpsAndDropsTheirRefs() throws {
        let keep = AXRefStore.keepPerWindow
        for i in 1...(keep + 2) {
            try store.save(snapshot("gen-\(i)", refs: ["@e\(i)"],
                                    at: Date(timeIntervalSince1970: Double(i))))
        }
        let index = store.loadIndex()
        // The newest `keep` survive, the two oldest files are gone with their refs.
        XCTAssertNotNil(store.load(generation: "gen-\(keep + 2)"))
        XCTAssertNotNil(store.load(generation: "gen-3"))
        XCTAssertNil(store.load(generation: "gen-1"))
        XCTAssertNil(store.load(generation: "gen-2"))
        XCTAssertEqual(index.candidates(for: AXRef(index: 1)), [])
        XCTAssertEqual(index.candidates(for: AXRef(index: keep + 2)).map(\.generation), ["gen-\(keep + 2)"])
    }

    func testLoadByPathAndByGeneration() throws {
        let dump = snapshot("gen-2", refs: ["@e1"])
        try store.save(dump)
        let path = store.snapshotPath(generation: "gen-2").path
        XCTAssertEqual(store.load(reference: path), dump)
        XCTAssertEqual(store.load(reference: "gen-2"), dump)
        XCTAssertNil(store.load(reference: "nope"))
    }

    func testRefNumbersAreMonotonicPerWindow() throws {
        // The bug this exists for: dump (1…42), act, dump again. If the second dump starts at 1
        // again, an @e19 printed by the first now names a different node -- and `press` acts on
        // it. Numbers therefore never repeat within a window.
        XCTAssertEqual(store.nextRef(bundle: "com.apple.TextEdit", window: 0), 1)
        try store.save(snapshot("g1", bundle: "com.apple.TextEdit", refs: ["@e1", "@e2", "@e3"]))
        XCTAssertEqual(store.nextRef(bundle: "com.apple.TextEdit", window: 0), 4)
        try store.save(snapshot("g2", bundle: "com.apple.TextEdit", refs: ["@e4", "@e5"]))
        XCTAssertEqual(store.nextRef(bundle: "com.apple.TextEdit", window: 0), 6)
        // A different window keeps its own counter.
        XCTAssertEqual(store.nextRef(bundle: "com.apple.TextEdit", window: 1), 1)
        // And the old ref still resolves to the dump that printed it.
        XCTAssertEqual(store.loadIndex().candidates(for: AXRef(index: 3)).map(\.generation), ["g1"])
    }

    func testTheCounterResetsOnceNoSnapshotOfThatWindowIsLeft() throws {
        try store.save(snapshot("g1", refs: ["@e1", "@e2"]))
        XCTAssertEqual(store.nextRef(bundle: "com.apple.finder", window: 0), 3)
        store.prune(bundle: "com.apple.finder", window: 0, keep: 0)
        XCTAssertNil(store.loadIndex().candidates(for: AXRef(index: 1)).first)
        XCTAssertEqual(store.nextRef(bundle: "com.apple.finder", window: 0), 1)
    }

    func testACorruptIndexDoesNotCrashALookup() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("index.json"))
        XCTAssertEqual(store.loadIndex().candidates(for: AXRef(index: 1)), [])
    }
}
