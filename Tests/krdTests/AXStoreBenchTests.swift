import XCTest
@testable import krd
@testable import krdcore

/// Issue #102, as a number instead of a paragraph: one `krd ax tree` write used to read
/// `index.json`, read and write it in `save`, then read and write it again in `prune` — and
/// decode every live snapshot just to learn a date the index already carries. Release only,
/// because a debug build has no inlining and the numbers are noise:
///
///     swift test -c release --filter AXStoreBenchTests 2>&1 | grep '^BENCH'
final class AXStoreBenchTests: XCTestCase {
    private func snapshot(_ generation: Int, nodes: Int = 400) -> AXSnapshot {
        AXSnapshot(schema: AXSnapshot.schema,
                   generation: String(format: "GEN-%04d", generation),
                   createdAt: Date(), app: "Bench", bundle: "com.bench.app",
                   pid: 999, windowIndex: 0, windowTitle: "a window", windowCount: 1,
                   nodes: (0..<nodes).map { i in
                       AXSnapshotNode(ref: "@e\(generation * nodes + i + 1)",
                                      chain: [AXStep(index: -1, role: "AXWindow", identifier: "", title: "a window")]
                                          + (0..<3).map { d in
                                              AXStep(index: i + d, role: "AXButton", identifier: "", title: "Save \(i)")
                                          },
                                      root: .window)
                   })
    }

    private func minOf5(_ body: () -> Void) -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = Date()
            body()
            best = min(best, Date().timeIntervalSince(start) * 1000)
        }
        return best
    }

    private func benchDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("krd-axbench-\(UUID().uuidString)", isDirectory: true)
    }

    /// What one `tree`/`find` pays before it prints: `beginDump` (the one index read, also
    /// supplies `refStart`) and `Dump.save` (record + prune + the one index write).
    func testDumpBookkeepingAsTheStoreFills() {
        let dir = benchDirectory()
        let store = AXRefStore(directory: dir)
        for n in 1...17 {
            let snapshot = snapshot(n)
            // One dump as the command does it: read the index, walk (excluded here), write once.
            let read = minOf5 { _ = store.beginDump(bundle: "com.bench.app", window: 0) }
            let dump = minOf5 {
                let session = store.beginDump(bundle: "com.bench.app", window: 0)
                try? session.save(snapshot)
            }
            let indexBytes = (try? Data(contentsOf: dir.appendingPathComponent("index.json")))?.count ?? 0
            let snapshotBytes = (try? Data(contentsOf: store.snapshotPath(generation: snapshot.generation)))?.count ?? 0
            print(String(format: "BENCH dump=%2d read=%.3f ms dump=%.3f ms index=%d B snapshot=%d B",
                         n, read, dump, indexBytes, snapshotBytes))
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// The pieces the old write path repeated per dump, measured without the read they used to
    /// hide: a full read+decode, an encode, the atomic write, and one snapshot decode per live
    /// dump (16 of them at the 17th).
    func testIndexCostBreakdown() {
        let dir = benchDirectory()
        let store = AXRefStore(directory: dir)
        for n in 1...17 { try? store.save(snapshot(n)) }
        let load = minOf5 { _ = store.loadIndex() }
        let index = store.loadIndex()
        let encode = minOf5 { _ = try? JSONEncoder().encode(index) }
        let write = minOf5 { try? store.saveIndex(index) }
        let decodes = minOf5 {
            for _ in 0..<16 { _ = store.load(generation: "GEN-0017") }
        }
        let bytes = (try? Data(contentsOf: dir.appendingPathComponent("index.json")))?.count ?? 0
        print(String(format: "BENCH index=%d B loadIndex(read+decode)=%.3f ms encode=%.3f ms "
                     + "atomic-write=%.3f ms 16x-snapshot-decode=%.3f ms", bytes, load, encode, write, decodes))
        try? FileManager.default.removeItem(at: dir)
    }
}
