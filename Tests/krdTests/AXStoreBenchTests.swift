import CoreGraphics
import Foundation
import XCTest
@testable import krd

/// What `krd ax` costs on the side nobody watches: the snapshot/refs store and the text
/// formatter. Pure Foundation, no accessibility API, no permission prompt — the shapes fed in
/// here are the ones `AXCommand.persist` writes (`AXSnapshot` → one JSON file per dump, plus an
/// `index.json` that maps `@eN` → generation).
///
/// Everything is min-of-5 wall clock, and every measurement goes through `sink`, so the
/// optimiser cannot delete the work being timed. Release only — a debug build is 10x slower
/// and would make the comparison against an accessibility round-trip meaningless:
///
///     swift test -c release --filter AXStoreBenchTests
///
/// The stores live under `NSTemporaryDirectory()/krd-axbench-<uuid>` and are deleted in
/// `tearDown`, so a real `$TMPDIR/krd-ax` state directory is never touched.
///
/// `Sources/…:line` references below are against commit a438e9c — the revision these numbers
/// were first taken on. They are the lines the measurements indict, not a to-do list.
final class AXStoreBenchTests: XCTestCase {
    /// 400 is `krd ax`'s default `--max`, and 4 is the usual chain depth (window → group →
    /// group → the node). Every number below is for that shape.
    private let nodesPerDump = 400
    private let chainDepth = 4
    /// `AXRefStore.keepPerWindow`. Restated so a change there shows up as failing assertions
    /// here instead of silently changing what "16 dumps" means.
    private let keepPerWindow = 16

    private var sink = 0
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    // MARK: - measuring

    private func nano() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Run `body` five times, keep the minimum. Returns milliseconds *per call*: `iterations`
    /// calls are run inside each of the five repetitions, so a nanosecond-scale call gets a
    /// measurement big enough to be real. `body` must return something derived from its result;
    /// it is summed into `sink` so the loop cannot be optimised away.
    private func ms(_ iterations: Int = 1, _ body: () throws -> Int) rethrows -> Double {
        var best = Double.infinity
        for _ in 0..<5 {
            var accumulated = 0
            let start = nano()
            for _ in 0..<iterations { accumulated &+= try body() }
            let elapsed = Double(nano() - start) / 1_000_000
            if elapsed < best { best = elapsed }
            sink &+= accumulated
        }
        return best / Double(iterations)
    }

    // MARK: - printing

    private func lpad(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }

    private func rpad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    private func heading(_ text: String) {
        print("BENCH")
        print("BENCH ## \(text)")
    }

    private func info(_ text: String) {
        print("BENCH #  \(text)")
    }

    /// name / value / unit, padded so the block pastes into an issue as a table.
    private func row(_ name: String, _ value: Double, _ unit: String, _ note: String = "") {
        let number = String(format: "%.3f", value)
        let suffix = note.isEmpty ? "" : "   \(note)"
        print("BENCH \(rpad(name, 58)) \(lpad(number, 12)) \(rpad(unit, 5))\(suffix)")
    }

    private func columns(_ header: [String], _ rows: [[String]], left: Set<Int> = []) {
        let widths = header.indices.map { i in
            max(header[i].count, rows.map { $0[i].count }.max() ?? 0)
        }
        func line(_ cells: [String]) -> String {
            cells.indices.map { left.contains($0) ? rpad(cells[$0], widths[$0]) : lpad(cells[$0], widths[$0]) }
                .joined(separator: "  ")
        }
        print("BENCH " + line(header))
        for cells in rows { print("BENCH " + line(cells)) }
    }

    // MARK: - fixtures

    private var store: AXRefStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("krd-axbench-\(UUID().uuidString)", isDirectory: true)
        directories.append(url)
        return AXRefStore(directory: url)
    }

    private func fileSize(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return -1 }
        return size.intValue
    }

    /// One dump with the default shape: a window, two nested groups, and the node itself —
    /// 4 chain steps, 400 nodes, one fresh generation id per dump.
    private func snapshot(dump: Int, nodes count: Int? = nil, generation: String = UUID().uuidString) -> AXSnapshot {
        let count = count ?? nodesPerDump
        let first = (dump - 1) * count + 1
        let nodes = (0..<count).map { offset -> AXSnapshotNode in
            let number = first + offset
            let role = number % 3 == 0 ? "AXButton" : "AXGroup"
            let title = number % 5 == 0 ? "" : (number % 7 == 0 ? "Save As…" : "Save")
            let chain = [
                AXStep(index: -1, role: "AXWindow", identifier: "", title: "a window"),
                AXStep(index: number % 4, role: "AXGroup", identifier: "", title: ""),
                AXStep(index: number % 6, role: "AXGroup",
                       identifier: number % 9 == 0 ? "group\(number % 9)" : "", title: ""),
                AXStep(index: number % 8, role: role, identifier: "", title: title),
            ]
            precondition(chain.count == chainDepth, "the fixture must build \(chainDepth)-step chains")
            return AXSnapshotNode(ref: "@e\(number)", chain: chain, root: .window)
        }
        return AXSnapshot(schema: 1, generation: generation, createdAt: createdAt(dump),
                          app: "Bench", bundle: "com.bench.app", pid: 999, windowIndex: 0,
                          windowTitle: "a window", windowCount: 1, nodes: nodes)
    }

    /// Explicit, increasing and identical between runs, so `prune`'s "newest by createdAt"
    /// sort is deterministic and two runs prune the same dumps.
    private func createdAt(_ dump: Int) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + Double(dump))
    }

    @discardableResult
    private func fill(_ store: AXRefStore, dumps: Int) throws -> AXRefStore {
        for dump in 1...dumps { try store.save(snapshot(dump: dump)) }
        return store
    }

    // MARK: - 1. the save path as the store fills up

    /// This is the headline: `save` is `loadIndex() + record + noteRefs + saveIndex() + prune`,
    /// and `prune` is another `loadIndex() + one snapshot load per live dump + saveIndex()`. So
    /// one `krd ax tree` pays for the index twice and reads every dump it is keeping — and the
    /// index grows with every dump until `keepPerWindow` refs are live.
    func testSaveCostAsTheStoreFills() throws {
        let reported = [1, 2, 4, 8, 16, 17]
        var bestSaveMS: [Int: Double] = [:]
        var indexBytes: [Int: Int] = [:]
        var snapshotBytes: [Int: Int] = [:]
        var snapshotFiles = 0

        // Five independent stores, each walked from empty to 17 dumps; the minimum per dump is
        // kept. Every store sees exactly the same state at dump N, so the minimum is honest.
        for _ in 0..<5 {
            let store = self.store
            for dump in 1...(keepPerWindow + 1) {
                let dumpSnapshot = snapshot(dump: dump)
                let start = nano()
                try store.save(dumpSnapshot)
                let elapsed = Double(nano() - start) / 1_000_000

                guard reported.contains(dump) else { continue }
                bestSaveMS[dump] = min(bestSaveMS[dump] ?? .infinity, elapsed)
                indexBytes[dump] = fileSize(store.directory.appendingPathComponent("index.json"))
                snapshotBytes[dump] = fileSize(store.snapshotPath(generation: dumpSnapshot.generation))
                snapshotFiles = (try? FileManager.default
                    .contentsOfDirectory(atPath: store.directory.appendingPathComponent("snapshots").path).count) ?? -1
            }
        }

        heading("1. AXRefStore.save — one `krd ax tree` write, \(nodesPerDump) nodes x \(chainDepth)-step chain")
        columns(["dump", "save_ms", "index.json", "1 snapshot", "note"],
                reported.map { dump in
                    let note = dump == keepPerWindow + 1 ? "prune drops dump 1" : ""
                    return ["\(dump)",
                            String(format: "%.3f", bestSaveMS[dump] ?? -1),
                            bytes(indexBytes[dump] ?? -1),
                            bytes(snapshotBytes[dump] ?? -1), note]
                }, left: [4])
        info("snapshot files after 17 dumps: \(snapshotFiles) (keepPerWindow = \(keepPerWindow))")
        info("exact sizes at 16 dumps: index.json = \(indexBytes[keepPerWindow] ?? -1) B, "
            + "one snapshot = \(snapshotBytes[keepPerWindow] ?? -1) B")
        let first = bestSaveMS[1] ?? 0
        let last = bestSaveMS[keepPerWindow] ?? 0
        row("save(16 dumps) / save(1 dump)", last / max(first, 0.000_001), "x",
            "the cost of a dump grows with the store, not with the tree")
        row("index.json(16 dumps) / index.json(1 dump)",
            Double(indexBytes[keepPerWindow] ?? 0) / max(Double(indexBytes[1] ?? 1), 1), "x")
        XCTAssertGreaterThan(indexBytes[keepPerWindow] ?? 0, indexBytes[1] ?? 0,
                             "the index must grow with every dump")
        let size16 = snapshotBytes[keepPerWindow] ?? -1
        let size17 = snapshotBytes[keepPerWindow + 1] ?? -2
        XCTAssertLessThanOrEqual(abs(Double(size16 - size17)), 0.02 * Double(size16),
                                 "a snapshot file is one tree, so its size barely moves — the modulo pattern of "
                                 + "the fixture's titles shifts a few bytes; only the index grows with the store")
        XCTAssertGreaterThan(indexBytes[keepPerWindow] ?? 0, 10 * (indexBytes[1] ?? 1),
                             "16 dumps must mean ~16x the index")
        XCTAssertEqual(snapshotFiles, keepPerWindow, "prune keeps exactly keepPerWindow dumps")

        // Shape only, never an absolute budget: CI runs these in debug, where everything is
        // ~10x slower, and the release numbers are the ones that get quoted. The margins are
        // wide (the observed ratio is ~11x) so a loaded machine cannot trip them.
        XCTAssertGreaterThan(bestSaveMS[keepPerWindow] ?? 0, 3 * (bestSaveMS[1] ?? 0),
                             "a save must get more expensive as the store fills")
        XCTAssertGreaterThan(bestSaveMS[8] ?? 0, 1.5 * (bestSaveMS[2] ?? 0))
    }

    private func bytes(_ count: Int) -> String {
        count < 1024 ? "\(count) B" : String(format: "%.1f KB", Double(count) / 1024)
    }

    // MARK: - 2. how many index round-trips one save implies

    /// `save` should cost about two index round-trips (its own `loadIndex`+`saveIndex`, then
    /// `prune`'s `loadIndex`+`saveIndex`) plus sixteen snapshot loads. Every line that budget is
    /// made of is timed here on its own, so the total is a decomposition and not an inference.
    func testIndexRoundTripCost() throws {
        let store = try fill(self.store, dumps: keepPerWindow)
        let index = store.loadIndex()
        let refCount = index.refs.count
        XCTAssertEqual(refCount, keepPerWindow * nodesPerDump)

        let load = ms { store.loadIndex().refs.count }
        let encode = try ms { try JSONEncoder().encode(index).count }
        let write = try ms { try store.saveIndex(index); return 1 }
        // AXRefs.swift:272 (in `save`) and :313 (in `prune`): a full rebuild of the ref map.
        let churn = ms { index.refs.filter { !$0.value.isEmpty }.count }
        // AXRefs.swift:304: prune decodes every live dump just to read its `createdAt` back.
        let generations = Set(index.refs.values.flatMap { $0 }.map(\.generation)).sorted()
        XCTAssertEqual(generations.count, keepPerWindow)
        let reload = ms { generations.reduce(0) { $0 + (store.load(generation: $1)?.nodes.count ?? 0) } }
        // The 17th dump is the state the ladder reports; time it on its own stores so this test
        // does not depend on another test having run first.
        var saves: [Double] = []
        for _ in 0..<5 {
            let fresh = try fill(self.store, dumps: keepPerWindow)
            let dumpSnapshot = snapshot(dump: keepPerWindow + 1)
            let start = nano()
            try fresh.save(dumpSnapshot)
            saves.append(Double(nano() - start) / 1_000_000)
            try? FileManager.default.removeItem(at: fresh.directory)
        }
        let save = saves.min() ?? 0
        // The budget that adds up to one save. `residual` is what the separately measured parts
        // do not explain (record, noteRefs, the directory work); it is a difference of
        // independent minima, so it can come out slightly negative on a loaded machine.
        let indexIO = 2 * load + 2 * write
        let rebuilds = 2 * churn
        let accounted = indexIO + rebuilds + reload
        let residual = save - accounted

        heading("2. One index round-trip and the budget of a save, on a store holding 16 dumps")
        row("AXRefStore.loadIndex() (read + JSONDecoder) — AXRefs:250", load, "ms",
            "\(bytes(fileSize(store.directory.appendingPathComponent("index.json")))) index")
        row("JSONEncoder().encode(index) (no write)", encode, "ms")
        row("AXRefStore.saveIndex(index) (encode + atomic write)", write, "ms")
        row("index.refs.filter { !$0.value.isEmpty } — AXRefs:272, :313", churn, "ms",
            "rebuilds all \(refCount) refs, and it is not the problem")
        row("prune: \(generations.count) x load(generation:) — AXRefs:304", reload, "ms",
            "full snapshot decodes, only to read createdAt")
        row("AXRefStore.save(snapshot) at 16 dumps", save, "ms", "the whole write path")
        row("  of which: 2 loadIndex + 2 saveIndex", indexIO, "ms",
            "= \(String(format: "%.0f", 100 * indexIO / save))% of the save")
        row("  of which: \(generations.count) snapshot decodes", reload, "ms",
            "= \(String(format: "%.0f", 100 * reload / save))% of the save")
        row("  of which: 2 ref-map rebuilds", rebuilds, "ms",
            "= \(String(format: "%.1f", 100 * rebuilds / save))% of the save")
        row("  of which: everything else", residual, "ms",
            residual < 0 ? "within noise — the parts already exceed the save"
                         : "record, noteRefs, per-key loop")
        info("implied index round-trips per save: save_ms / (load_ms + encode_ms) = "
            + String(format: "%.1f", save / max(load + encode, 0.000_001))
            + "  (2 is the modelled floor: save does loadIndex+saveIndex, prune repeats both;"
            + " the excess is the atomic write plus \(generations.count) snapshot decodes)")

        XCTAssertGreaterThan(save, load, "a save contains at least one index load")
        XCTAssertLessThan(load, 0.5 * save, "the index load is one part of the save, not most of it")
        // The parts are measured separately, so they cover most of the save rather than all of
        // it: 60% is the bar that says "these four lines are the save" without being sensitive
        // to a loaded machine or to a debug build.
        XCTAssertGreaterThan(accounted, 0.6 * save, "the budget must explain the save")
    }

    // MARK: - 3. AXIndex.record on its own

    func testRecordCost() throws {
        let store = try fill(self.store, dumps: keepPerWindow)
        let base = store.loadIndex()
        XCTAssertEqual(base.refs.count, keepPerWindow * nodesPerDump)
        let dumpSnapshot = snapshot(dump: keepPerWindow + 1)

        var best = Double.infinity
        for _ in 0..<5 {
            var index = base
            // Force the copy-on-write of the 6400-entry `refs` dictionary *outside* the timer:
            // in the real path `loadIndex()` hands back a freshly decoded (uniquely owned)
            // index, so `record` must not be charged for a dictionary copy.
            index.refs["\u{0}bench-probe"] = []
            index.refs.removeValue(forKey: "\u{0}bench-probe")
            let start = nano()
            index.record(dumpSnapshot)
            best = min(best, Double(nano() - start) / 1_000_000)
            XCTAssertEqual(index.refs.count, base.refs.count + nodesPerDump,
                           "400 nodes must all be new keys — refs never repeat")
            sink &+= index.refs.count
        }

        heading("3. AXIndex.record(snapshot) — 400 nodes into an index that already has 6400 refs")
        row("record()", best, "ms")
        row("record() per node", best * 1_000 / Double(nodesPerDump), "us")
    }

    // MARK: - 4. nextRef, which sits in front of the walk

    /// `krd ax tree` calls `nextRef` *before* the first accessibility call, so this number is
    /// pure time-to-first-byte: a full index read + decode before the walk begins.
    func testNextRefCost() throws {
        let store = try fill(self.store, dumps: keepPerWindow)
        let value = ms { store.nextRef(bundle: "com.bench.app", window: 0) }
        let next = store.nextRef(bundle: "com.bench.app", window: 0)

        heading("4. AXRefStore.nextRef(bundle:window:) on a 16-dump store")
        row("nextRef()", value, "ms", "= loadIndex() + one dictionary lookup")
        info("returned \(next) for the next dump (refs 1…\(keepPerWindow * nodesPerDump) are taken)")
        XCTAssertEqual(next, keepPerWindow * nodesPerDump + 1)
    }

    // MARK: - 5. AXSnapshot.node(ref:), the linear scan

    func testNodeLookupScan() throws {
        let small = snapshot(dump: 1)                       // 400 nodes
        let big = snapshot(dump: 1, nodes: 20_000)           // 50x the default --max
        XCTAssertNotNil(small.node(ref: "@e\(nodesPerDump)"))
        XCTAssertNotNil(big.node(ref: "@e20000"))

        heading("5. AXSnapshot.node(ref:) — `nodes.first { $0.ref == ref }`")
        let smallLast = ms(2_000) { small.node(ref: "@e\(nodesPerDump)")?.chain.count ?? -1 }
        let smallFirst = ms(2_000) { small.node(ref: "@e1")?.chain.count ?? -1 }
        let bigLast = ms(200) { big.node(ref: "@e20000")?.chain.count ?? -1 }
        columns(["nodes", "lookup", "per call", "per node", "note"], [
            ["400", "first node", String(format: "%.3f us", smallFirst * 1_000), "—", "one comparison"],
            ["400", "last node", String(format: "%.3f us", smallLast * 1_000),
             String(format: "%.1f ns", smallLast * 1_000_000 / Double(nodesPerDump)), "worst case"],
            ["20000", "last node", String(format: "%.3f us", bigLast * 1_000),
             String(format: "%.1f ns", bigLast * 1_000_000 / Double(20_000)), "worst case"],
        ], left: [1, 2, 4])
        info("the scan is O(nodes): "
            + String(format: "%.1f", smallLast * 1_000_000 / Double(nodesPerDump))
            + " ns per node compared at 400, "
            + String(format: "%.1f", bigLast * 1_000_000 / Double(20_000))
            + " ns at 20000 — `press` pays it once per lookup, but it is linear in a tree that grows")
        XCTAssertGreaterThan(smallLast, smallFirst * 10, "the scan must be linear in the node index")
        XCTAssertGreaterThan(bigLast, smallLast * 10, "50x the nodes must cost far more")
    }

    // MARK: - 6. AXText.sanitize

    /// `sanitize` runs once per printed field: role, name, detail, window title. A `[UInt8]`
    /// rewrite is kept *here*, not in Sources/ — this measurement is the argument for it.
    private enum ByteSanitizer {
        /// Same contract as `AXText.sanitize`: every C0/C1 control, DEL, U+2028/9 and U+202E
        /// becomes one space; everything else is copied; once `limit` units are taken the
        /// remainder is replaced by "…". Output is built as UTF-8 bytes and decoded once.
        static func sanitize(_ raw: String, limit: Int = 80) -> String {
            var out: [UInt8] = []
            out.reserveCapacity(min(raw.utf8.count, 4 * limit + 3))
            var taken = 0
            var truncated = false
            for scalar in raw.unicodeScalars {
                // `taken >= limit` is checked in both branches of the original; folding them
                // into one check up front is the same thing.
                if taken >= limit { truncated = true; break }
                let value = scalar.value
                let unsafe = value < 0x20
                    || (0x7F...0x9F).contains(value)
                    || value == 0x2028 || value == 0x2029 || value == 0x202E
                if unsafe {
                    out.append(0x20)
                } else if value < 0x80 {
                    out.append(UInt8(value))
                } else if value < 0x800 {
                    out.append(UInt8(0xC0 | (value >> 6)))
                    out.append(UInt8(0x80 | (value & 0x3F)))
                } else if value < 0x10000 {
                    out.append(UInt8(0xE0 | (value >> 12)))
                    out.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
                    out.append(UInt8(0x80 | (value & 0x3F)))
                } else {
                    out.append(UInt8(0xF0 | (value >> 18)))
                    out.append(UInt8(0x80 | ((value >> 12) & 0x3F)))
                    out.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
                    out.append(UInt8(0x80 | (value & 0x3F)))
                }
                taken += 1
            }
            if truncated { out.append(contentsOf: [0xE2, 0x80, 0xA6]) }   // "…"
            return String(decoding: out, as: UTF8.self)
        }
    }

    func testSanitizeThroughputAndEquivalence() throws {
        let plain = "Some Button Title With Spaces"
        let limits = [0, 1, 3, 24, 60, 80]
        let tricky = [
            "",
            plain,
            "AXButton",
            "\u{1B}[31mred\u{1B}[0m",                                  // ESC / C0
            "c1:\u{9F}\u{80}\u{7F}tail",                                // C1 + DEL
            "line\u{2028}sep\u{2029}paragraph",                         // U+2028 / U+2029
            "rtl\u{202E}override\u{202D}",                              // U+202E bidi override
            "\u{0}null and \u{7}bell",
            String(repeating: "a", count: 200),                          // over limit, ASCII
            String(repeating: "Save ", count: 40),                       // over limit, words
            String(repeating: "x", count: 60),                           // exactly limit
            String(repeating: "x", count: 61),                           // limit + 1
            String(repeating: "🙂", count: 50),                          // over limit, astral
            "e\u{301}\u{302} combining \u{1F1E9}\u{1F1EA}",              // combining + flag
            "Save 💾 保存 🙂 mixed",
            String(repeating: "a", count: 60) + "\u{1B}x",               // unsafe char at the limit
            "  spaced  out  ",
        ]

        // The claim only means something if it is the same string, byte for byte, on inputs
        // that exercise every branch of the predicate.
        var checked = 0
        for input in tricky {
            for limit in limits {
                let expected = AXText.sanitize(input, limit: limit)
                let actual = ByteSanitizer.sanitize(input, limit: limit)
                XCTAssertEqual(actual, expected,
                               "limit \(limit), input \(input.debugDescription)")
                checked += 1
            }
        }

        let iterations = 100_000
        let current = ms(iterations) { AXText.sanitize(plain, limit: 60).utf8.count }
        let candidate = ms(iterations) { ByteSanitizer.sanitize(plain, limit: 60).utf8.count }

        heading("6. AXText.sanitize — \(iterations) calls of \(plain.debugDescription) (limit 60)")
        row("AXText.sanitize (Sources/krd/AXFormat.swift)", current * 1_000_000, "ns/call")
        row("UTF-8 [UInt8] variant (this file)", candidate * 1_000_000, "ns/call")
        row("speed ratio (sanitize / variant)", current / max(candidate, 0.000_001), "x")
        info("equivalence: \(checked) input/limit pairs identical (\(tricky.count) inputs x \(limits.count) limits)")
        info("per emitted line `render` sanitizes role+name; a 400-node dump is ~800-1200 calls = "
            + String(format: "%.3f", 1_000 * current) + " ms total — real but not the bottleneck")
        XCTAssertEqual(ByteSanitizer.sanitize(plain, limit: 60), AXText.sanitize(plain, limit: 60))
    }

    // MARK: - 7. rendering vs the JSON path, and both against an IPC

    private func axNodes(_ count: Int) -> [AXNode] {
        (0..<count).map { index in
            let role = index % 5 == 0 ? "AXButton" : (index % 3 == 0 ? "AXStaticText" : "AXGroup")
            let actions: [String] = role == "AXButton" ? ["press"] : (role == "AXGroup" ? ["showmenu"] : [])
            return AXNode(ref: "@e\(index + 1)", depth: index % 6, role: role,
                          name: "Save \(index % 10)",
                          detail: index % 4 == 0 ? "value=\"on\"" : "",
                          frame: CGRect(x: 120 + index % 40, y: 80 + index % 30, width: 64, height: 24),
                          actions: actions)
        }
    }

    func testRenderAndJSONCost() throws {
        heading("7. Formatting: AXText.render (text output) vs AXTreeJSON + jsonString (--json)")

        for count in [400, 4_000] {
            let nodes = axNodes(count)
            let tree = AXTreeJSON(app: "Bench", pid: 999, windowIndex: 0, windowCount: 1,
                                  windowTitle: "a window", frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                  nodes: nodes, truncated: false, visited: count, generation: "gen")

            let render = ms { nodes.reduce(0) { $0 + AXText.render($1).utf8.count } }
            let dictionary = ms { tree.dictionary.count }
            let json = ms { AXCommand.jsonString(tree.dictionary).utf8.count }
            let textBytes = nodes.reduce(0) { $0 + AXText.render($1).utf8.count }

            row("\(count) x AXText.render (print one line per node)", render, "ms",
                "\(textBytes) B of text")
            row("\(count) x render, per node", render * 1_000 / Double(count), "us")
            row("AXTreeJSON(\(count)).dictionary (build the dict)", dictionary, "ms")
            row("AXTreeJSON + AXCommand.jsonString (\(count) nodes)", json, "ms",
                "dictionary + JSONSerialization")
            // An accessibility call crosses into another process: ~0.1 ms is optimistic and
            // 1 ms is the usual cost. AXWalker makes 3 per node, so a 400-node dump cannot be
            // read in less than 400 x 3 x 0.1 ms = 120 ms even on a perfect machine.
            let ipcLow = Double(count) * 3 * 0.1
            let ipcHigh = Double(count) * 3 * 1.0
            row("AX IPC for the same walk (3 IPC/node, 0.1-1 ms)",
                ipcLow, "ms", String(format: "optimistic; %.0f ms at 1 ms/IPC", ipcHigh))
            row("render as a share of that optimistic walk", 100 * render / ipcLow, "%",
                "formatting is noise next to the round-trips")
            row("json as a share of that optimistic walk", 100 * json / ipcLow, "%")

            // True in debug too (both sides scale with the optimiser), and it is the claim worth
            // keeping: printing a tree is never the expensive part of reading one.
            XCTAssertLessThan(render, ipcLow, "formatting must stay well under one IPC budget")
            XCTAssertLessThan(json, ipcLow, "even --json stays under one optimistic IPC budget")
            XCTAssertGreaterThan(textBytes, count)
        }
    }
}
