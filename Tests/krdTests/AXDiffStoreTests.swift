import CoreGraphics
import XCTest
@testable import krd

/// Issue #108's storage half: what a `--diff` compares against, and what a schema-2 snapshot has
/// to keep on disk for that comparison to mean anything.
///
/// The rule under test is #102's, applied to the read path: a diff is not allowed to cost a second
/// read of `index.json`, and it must not decode the dumps it passes over. The baseline is chosen
/// from the `at` the index already carries, and exactly one snapshot file is opened -- the baseline
/// itself. Refs are never touched: no renumbering, no resolution, no pruning.
final class AXDiffStoreTests: XCTestCase {
    private let bundle = "com.apple.TextEdit"

    private var store: AXRefStore!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("krd-ax-diff-tests-\(UUID().uuidString)", isDirectory: true)
        store = AXRefStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - fixtures

    private func step(_ index: Int, _ role: String = "AXButton", id: String = "", title: String = "") -> AXStep {
        AXStep(index: index, role: role, identifier: id, title: title)
    }

    /// The trailing link of every chain here: the same window an app would report for one document.
    private var windowStep: AXStep { step(-1, "AXWindow", title: "Untitled") }

    private func scope(all: Bool = false) -> AXSnapshotScope {
        AXSnapshotScope(interactiveOnly: !all, all: all, menuBar: false, depth: 12, maxNodes: 400)
    }

    /// A dump shaped like the one `AXCommand.persist` writes: one node per ref, chained off the
    /// window. `at` is the dump's `createdAt`, which is also the entry's `at` in the index.
    private func snapshot(_ generation: String, appBundle: String? = nil, window: Int = 0,
                          refs: [String], at: Date = Date(),
                          scope: AXSnapshotScope? = nil) -> AXSnapshot {
        AXSnapshot(schema: AXSnapshot.schema, generation: generation, createdAt: at,
                   app: "TextEdit", bundle: appBundle ?? bundle, pid: 4242,
                   windowIndex: window, windowTitle: "Untitled", windowCount: 1,
                   nodes: refs.enumerated().map { offset, ref in
                       AXSnapshotNode(ref: ref, chain: [windowStep, step(offset, title: ref)])
                   },
                   scope: scope)
    }

    // MARK: - which dump is the baseline

    func testThePreviousDumpOfTheSameWindowIsTheBaseline() throws {
        // Two `tree` runs of one window: the second one diffs against the first.
        let first = snapshot("g1", refs: ["@e1", "@e2"], at: Date(timeIntervalSince1970: 10))
        let second = snapshot("g2", refs: ["@e3"], at: Date(timeIntervalSince1970: 20))
        try store.save(first)
        try store.save(second)

        let index = store.loadIndex()
        let baseline = try XCTUnwrap(store.previousSnapshot(bundle: bundle, window: 0,
                                                            excluding: "g2", index: index))
        XCTAssertEqual(baseline.generation, "g1")
        XCTAssertEqual(baseline.snapshot, first)
    }

    func testAFirstEverDumpHasNoBaseline() throws {
        // Fail-open path: nothing to compare against, so `tree --diff` prints the whole tree.
        let dump = store.beginDump(bundle: bundle, window: 0)
        XCTAssertNil(store.previousSnapshot(bundle: bundle, window: 0, excluding: nil,
                                            index: dump.loaded.index))

        // And right after the first dump, the only entry is the current one: still no baseline.
        try dump.save(snapshot("g1", refs: ["@e1"]))
        let next = store.beginDump(bundle: bundle, window: 0)
        XCTAssertNil(store.previousSnapshot(bundle: bundle, window: 0, excluding: "g1",
                                            index: next.loaded.index))
        // Without the exclusion it is there: the baseline is "any other dump", not "no dumps".
        XCTAssertEqual(store.previousSnapshot(bundle: bundle, window: 0, excluding: nil,
                                              index: next.loaded.index)?.generation, "g1")
    }

    func testADumpOfAnotherWindowOrAppIsNeverTheBaseline() throws {
        // A window's nodes only exist in that window, and `--all` on another app is a different
        // tree entirely: diffing against either would report the whole tree as added.
        try store.save(snapshot("other-window", window: 1, refs: ["@e1"],
                                at: Date(timeIntervalSince1970: 10)))
        try store.save(snapshot("other-app", appBundle: "com.apple.Preview", refs: ["@e1"],
                                at: Date(timeIntervalSince1970: 20)))
        let index = store.loadIndex()

        XCTAssertNil(store.previousSnapshot(bundle: bundle, window: 0, excluding: nil, index: index))
        // Each window/app is its own baseline series.
        XCTAssertEqual(store.previousSnapshot(bundle: bundle, window: 1, excluding: nil,
                                              index: index)?.generation, "other-window")
        XCTAssertEqual(store.previousSnapshot(bundle: "com.apple.Preview", window: 0, excluding: nil,
                                              index: index)?.generation, "other-app")
    }

    func testTheNewestDumpThatIsNotTheCurrentOneWins() throws {
        // Three dumps of one window; the middle one is the baseline for the third, not the oldest.
        for (offset, generation) in ["g1", "g2", "g3"].enumerated() {
            try store.save(snapshot(generation, refs: ["@e\(offset + 1)"],
                                    at: Date(timeIntervalSince1970: Double(offset + 1) * 10)))
        }
        let index = store.loadIndex()
        XCTAssertEqual(store.previousSnapshot(bundle: bundle, window: 0, excluding: "g3",
                                              index: index)?.generation, "g2")
        // With nothing excluded the current dump is the newest of all -- the caller's `except` is
        // what makes "previous" mean previous.
        XCTAssertEqual(store.previousSnapshot(bundle: bundle, window: 0, excluding: nil,
                                              index: index)?.generation, "g3")

        // Two dumps saved in the same second must still pick the same baseline every time: the
        // generation id breaks the tie, newest id first (the ordering `prune` uses too).
        for generation in ["tie-a", "tie-b"] {
            try store.save(snapshot(generation, window: 2, refs: ["@e1"],
                                    at: Date(timeIntervalSince1970: 30)))
        }
        let tied = store.loadIndex()
        for _ in 0..<3 {
            XCTAssertEqual(store.previousSnapshot(bundle: bundle, window: 2, excluding: nil,
                                                  index: tied)?.generation, "tie-b")
        }
    }

    func testABaselineWhoseFileIsGoneIsNoBaseline() throws {
        // `prune` keeps an entry whose file is missing rather than collecting a ref someone may
        // hold, so this is a real state. The answer is nil (fail open), not an older dump: one
        // read is the budget.
        try store.save(snapshot("g1", refs: ["@e1"], at: Date(timeIntervalSince1970: 10)))
        try store.save(snapshot("g2", refs: ["@e2"], at: Date(timeIntervalSince1970: 20)))
        try FileManager.default.removeItem(at: store.snapshotPath(generation: "g1"))
        let index = store.loadIndex()
        XCTAssertNil(store.previousSnapshot(bundle: bundle, window: 0, excluding: "g2", index: index))
    }

    // MARK: - the baseline read costs one read, and changes nothing

    func testTheBaselineComesFromTheIndexTheCallerAlreadyRead() throws {
        // #102 as a counter: `beginDump` reads `index.json` once, and a `--diff` on top of it must
        // not read it again nor open the dumps it passes over.
        let activity = AXStoreActivity()
        let counting = AXRefStore(directory: directory, activity: activity)
        for i in 1...3 {
            try counting.save(snapshot("g\(i)", refs: ["@e\(i)"],
                                       at: Date(timeIntervalSince1970: Double(i) * 10)))
        }
        activity.indexReads = 0
        activity.indexWrites = 0
        activity.snapshotReads = 0

        let dump = counting.beginDump(bundle: bundle, window: 0)
        XCTAssertEqual(activity.indexReads, 1)
        let baseline = try XCTUnwrap(counting.previousSnapshot(bundle: bundle, window: 0,
                                                               excluding: "g3",
                                                               index: dump.loaded.index))
        XCTAssertEqual(baseline.generation, "g2")
        XCTAssertEqual(activity.indexReads, 1)     // no re-read: the index handed in is the view
        XCTAssertEqual(activity.indexWrites, 0)    // a diff never writes
        XCTAssertEqual(activity.snapshotReads, 1)  // the baseline, and nothing it passed over
    }

    func testReadingABaselineLeavesRefsAndDumpsAlone() throws {
        // The diff must not renumber, resolve or prune anything: `@e3` still means what the dump
        // that printed it said, and the next dump still starts where the counter stopped.
        try store.save(snapshot("g1", refs: ["@e1", "@e2"], at: Date(timeIntervalSince1970: 10)))
        try store.save(snapshot("g2", refs: ["@e3"], at: Date(timeIntervalSince1970: 20)))
        let index = store.loadIndex()
        let nextRef = index.nextRef(bundle: bundle, window: 0)
        XCTAssertEqual(nextRef, 4)

        _ = store.previousSnapshot(bundle: bundle, window: 0, excluding: "g2", index: index)

        XCTAssertEqual(store.loadIndex(), index)                       // no entry or counter moved
        XCTAssertEqual(store.nextRef(bundle: bundle, window: 0), nextRef)
        XCTAssertNotNil(store.load(generation: "g1"))                  // nothing was aged out
        XCTAssertEqual(store.loadIndex().candidates(for: AXRef(index: 1)).map(\.generation), ["g1"])
    }

    // MARK: - schema 2 on disk

    func testEverySnapshotFieldSurvivesADiskRoundTrip() throws {
        // What a diff compares is what the dump printed, so every printed field has to make the
        // trip through the file: name, detail, actions, frame, and the scope that says the two
        // dumps are comparable at all.
        let nodes = [
            AXSnapshotNode(ref: "@e1",
                           chain: [windowStep, step(0, "AXTextField", id: "docText", title: "Untitled")],
                           root: .window, name: "Untitled", detail: "value=\"hi\"",
                           actions: ["press", "setvalue"],
                           frame: AXFrame(x: 10, y: 20, w: 200, h: 24)),
            // A node that prints no frame and no actions: the absent fields stay absent.
            AXSnapshotNode(ref: "@e2", chain: [windowStep, step(1, "AXGroup", title: "Toolbar")],
                           root: .menuBar, name: "Toolbar", detail: "", actions: [], frame: nil),
        ]
        let dump = AXSnapshot(schema: AXSnapshot.schema, generation: "gen-fields", createdAt: Date(),
                              app: "TextEdit", bundle: bundle, pid: 4242, windowIndex: 0,
                              windowTitle: "Untitled", windowCount: 1, nodes: nodes, scope: scope())
        try store.save(dump)

        let loaded = try XCTUnwrap(store.load(generation: "gen-fields"))
        XCTAssertEqual(loaded, dump)
        XCTAssertEqual(loaded.schema, 2)
        XCTAssertEqual(loaded.scope, scope())
        XCTAssertEqual(loaded.nodes[0].name, "Untitled")
        XCTAssertEqual(loaded.nodes[0].detail, "value=\"hi\"")
        XCTAssertEqual(loaded.nodes[0].actions, ["press", "setvalue"])
        XCTAssertEqual(loaded.nodes[0].frame, AXFrame(x: 10, y: 20, w: 200, h: 24))
        XCTAssertEqual(loaded.nodes[0].frame?.text, "[10,20 200x24]")
        XCTAssertEqual(loaded.nodes[0].root, .window)
        XCTAssertEqual(loaded.nodes[1].name, "Toolbar")
        XCTAssertEqual(loaded.nodes[1].detail, "")
        XCTAssertEqual(loaded.nodes[1].actions, [])
        XCTAssertNil(loaded.nodes[1].frame)
        XCTAssertEqual(loaded.nodes[1].root, .menuBar)

        // A 400-node dump is ~120 KB and 16 of them are kept, so an absent field is omitted
        // rather than written as null.
        let written = try Data(contentsOf: store.snapshotPath(generation: "gen-fields"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        XCTAssertEqual(object["schema"] as? Int, 2)   // the literal: the file shape is a contract
        XCTAssertNotNil(object["scope"])
        let writtenNodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        XCTAssertNil(writtenNodes[1]["frame"])
        XCTAssertEqual(writtenNodes[1]["detail"] as? String, "")
        let frame = try XCTUnwrap(writtenNodes[0]["frame"] as? [String: Any])
        XCTAssertEqual(frame["x"] as? Int, 10)
        XCTAssertEqual(frame["y"] as? Int, 20)
        XCTAssertEqual(frame["w"] as? Int, 200)
        XCTAssertEqual(frame["h"] as? Int, 24)
    }

    func testAV1SnapshotStillDecodes() throws {
        // A snapshot written by the last build has no `scope` and no per-node fields. It must
        // decode -- the diff then compares structure only -- or every existing state directory
        // turns into an error after an upgrade.
        let legacy = """
        {"schema":1,
         "generation":"gen-v1",
         "createdAt":700000000,
         "app":"TextEdit","bundle":"com.apple.TextEdit","pid":4242,
         "windowIndex":0,"windowTitle":"Untitled","windowCount":1,
         "nodes":[{"ref":"@e1",
                   "chain":[{"index":-1,"role":"AXWindow","identifier":"","title":"Untitled"}]},
                  {"ref":"@e2",
                   "chain":[{"index":-1,"role":"AXWindow","identifier":"","title":"Untitled"},
                            {"index":2,"role":"AXButton","identifier":"save","title":"Save"}],
                   "root":"window"}]}
        """
        try FileManager.default.createDirectory(
            at: store.snapshotPath(generation: "gen-v1").deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: store.snapshotPath(generation: "gen-v1"))

        let snapshot = try XCTUnwrap(store.load(generation: "gen-v1"))
        XCTAssertEqual(snapshot.schema, 1)
        XCTAssertEqual(snapshot.generation, "gen-v1")
        XCTAssertEqual(snapshot.nodes.count, 2)
        XCTAssertNil(snapshot.scope)
        XCTAssertNil(snapshot.nodes[0].root)
        XCTAssertNil(snapshot.nodes[0].name)
        XCTAssertNil(snapshot.nodes[0].detail)
        XCTAssertNil(snapshot.nodes[0].actions)
        XCTAssertNil(snapshot.nodes[0].frame)
        XCTAssertEqual(snapshot.nodes[1].root, .window)
        XCTAssertEqual(snapshot.nodes[1].chain.count, 2)
        XCTAssertEqual(snapshot.nodes[1].chain[1].identifier, "save")

        // And a v1 dump can still be the baseline: the index an older build wrote points at it,
        // and what comes back is a snapshot whose new fields are simply empty.
        var index = store.loadIndex()
        index.record(snapshot)
        try store.saveIndex(index)
        XCTAssertEqual(store.previousSnapshot(bundle: bundle, window: 0, excluding: nil,
                                              index: store.loadIndex())?.generation, "gen-v1")
    }

    // MARK: - AXFrame is the printed frame

    func testAFrameIsNilExactlyWhenNothingIsPrinted() throws {
        XCTAssertNil(AXFrame(nil))
        // `AXText.frameText` prints nothing for a rect with no area, so neither does AXFrame.
        XCTAssertNil(AXFrame(CGRect(x: 10, y: 10, width: 0, height: 10)))
        XCTAssertNil(AXFrame(CGRect(x: 10, y: 10, width: 10, height: 0)))
        XCTAssertNil(AXFrame(CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10)))
        XCTAssertNil(AXFrame(CGRect(x: 0, y: 0, width: 0, height: 0)))
        XCTAssertNotNil(AXFrame(CGRect(x: 0, y: 0, width: 1, height: 1)))
        // A negative size is standardized by CGRect itself and an infinite one rounds to 0;
        // either way the frame says exactly what the dump prints, which is all a diff compares.
        for rect in [CGRect(x: 10, y: 10, width: -4, height: 10),
                     CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)] {
            XCTAssertEqual(AXFrame(rect)?.text, AXText.frameText(rect))
        }
    }

    func testAFramesTextIsTheOneTheDumpPrints() throws {
        // The diff compares the printed form, so the two renderings cannot drift apart.
        for rect in [CGRect(x: 120, y: 80, width: 64, height: 24),
                     CGRect(x: 0, y: 0, width: 1.4, height: 2.6),
                     CGRect(x: 12.5, y: 7.4, width: 300, height: 44)] {
            let frame = try XCTUnwrap(AXFrame(rect))
            XCTAssertEqual(frame.text, AXText.frameText(rect))
            XCTAssertEqual(AXFrame(x: frame.x, y: frame.y, w: frame.w, h: frame.h), frame)
        }
        XCTAssertEqual(try XCTUnwrap(AXFrame(CGRect(x: 120, y: 80, width: 64, height: 24))).text,
                       "[120,80 64x24]")
    }

    func testAHugeCoordinateIsClampedLikeTheDumpClampsIt() throws {
        // The numbers come from another process; `Int(CGFloat)` would trap on a value this big.
        let rect = CGRect(x: 5_000_000, y: -5_000_000, width: 3_000_000, height: 10)
        let frame = try XCTUnwrap(AXFrame(rect))
        XCTAssertEqual(frame.x, 1_000_000)
        XCTAssertEqual(frame.y, -1_000_000)
        XCTAssertEqual(frame.w, 1_000_000)
        XCTAssertEqual(frame.text, AXText.frameText(rect))
    }

    func testAFrameRoundTripsThroughJSON() throws {
        let frame = AXFrame(x: -3, y: 4, w: 5, h: 6)
        let data = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(AXFrame.self, from: data), frame)
        XCTAssertEqual(frame.text, "[-3,4 5x6]")
    }
}
