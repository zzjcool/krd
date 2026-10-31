// Refs that outlive the process that printed them, without a daemon.
//
// `krd ax tree` prints `@e7`, and the next invocation has to turn that back into the same
// element. A ref is therefore a *snapshot* plus a *path*: the snapshot is a small JSON file
// under $TMPDIR/keyed by app+window, and the path is the list of children we walked through,
// each carrying what that child looked like at the time (documents/research §8).
//
// The path is verified, not trusted. If a step no longer matches, the ref is stale and the
// command fails with "re-dump" instead of acting on whatever happens to be at that index now:
// a text channel that clicks the wrong button is worse than one that admits it is lost.
//
// Nothing in this file talks to the accessibility API, so it is covered by
// Tests/krdTests/AXRefsTests.swift -- the AX side only supplies "the children of this element".

import Foundation
import krdcore

/// `@e12` -- the handle a dump prints.
struct AXRef: Equatable, Hashable, CustomStringConvertible {
    static let prefix = "@e"
    /// 1-based, exactly as printed (`@e1` is the first node).
    var index: Int

    init(index: Int) { self.index = index }

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(AXRef.prefix) else { return nil }
        let digits = trimmed.dropFirst(AXRef.prefix.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(digits), value >= 1 else { return nil }
        index = value
    }

    var description: String { "\(AXRef.prefix)\(index)" }
}

/// One step from a window root to a node: the child index we walked through, plus a summary
/// of the child, so a later process can tell "the same node" from "some node at this index".
struct AXStep: Codable, Equatable {
    /// -1 for the root of a dump (a window), which has no parent to index into.
    var index: Int
    var role: String
    var identifier: String
    var title: String

    /// Do two descriptions of a node agree?
    ///
    /// An `AXIdentifier` is the only handle an app promises to keep, so when both sides have
    /// one it decides on its own -- a button whose title flips "Start"/"Stop" is still the same
    /// button. Without one, role+title is all there is, and a retitled node reads as gone.
    func matches(_ other: AXStep) -> Bool {
        guard role == other.role else { return false }
        if !identifier.isEmpty, !other.identifier.isEmpty { return identifier == other.identifier }
        return title == other.title
    }
}

/// What one level of a chain lookup found.
enum AXDescent: Equatable {
    /// The node is where it was.
    case same(Int)
    /// The node moved, but exactly one child matches its description.
    case moved(Int)
    /// Several children match: guessing would be worse than failing.
    case ambiguous([Int])
    /// Nothing at this level matches: the node is gone, retitled, or the chain is stale.
    case gone
}

enum AXRefs {
    /// Where a single link of the chain lands among `children`.
    ///
    /// The fast path is the recorded index -- trees barely move, and a matching index needs no
    /// search. Only when that fails do we look at every child, and we accept a moved node only
    /// if exactly one child answers to it.
    static func descend(_ step: AXStep, children: [AXStep]) -> AXDescent {
        if step.index >= 0, step.index < children.count, children[step.index].matches(step) {
            return .same(step.index)
        }
        let hits = children.indices.filter { children[$0].matches(step) }
        switch hits.count {
        case 0: return .gone
        case 1: return .moved(hits[0])
        default: return .ambiguous(hits)
        }
    }
}

/// Which element a chain starts from: a `--menubar` dump walks the menu bar and the window
/// into one snapshot, and their chains are not interchangeable.
enum AXRoot: String, Codable {
    case window
    case menuBar
}

/// What one node of a dump looked like, and how to walk back to it.
struct AXSnapshotNode: Codable, Equatable {
    var ref: String
    /// Root … node. The last element is the node itself.
    var chain: [AXStep]
    /// Absent in snapshots written before this field existed; those are window chains.
    var root: AXRoot?
}

/// One `krd ax tree` / `krd ax find` output, written to disk so refs survive the process.
struct AXSnapshot: Codable, Equatable {
    static let schema = 1

    var schema: Int
    /// Random per dump; also the file name, and what `--snapshot` accepts.
    var generation: String
    var createdAt: Date
    var app: String
    var bundle: String
    var pid: Int32
    var windowIndex: Int
    var windowTitle: String
    var windowCount: Int
    var nodes: [AXSnapshotNode]

    func node(ref: String) -> AXSnapshotNode? {
        nodes.first { $0.ref == ref }
    }
}

/// One line of `index.json`: a ref, and which dump last printed it.
struct AXIndexEntry: Codable, Equatable {
    var generation: String
    var app: String
    var bundle: String
    var pid: Int32
    var window: Int
    var title: String
    var at: Date

    /// Which snapshot this ref belongs to, for an error message that names the app.
    var origin: String {
        app.isEmpty ? bundle : app
    }
}

/// The ref → snapshot map, so `press @e7` can find the dump that printed it.
struct AXIndex: Codable, Equatable {
    static let schema = 1
    var schema: Int
    var refs: [String: [AXIndexEntry]]
    /// Highest ref handed out per window (`bundle|window`). Refs are monotonic per window so a
    /// re-dump never reuses a number: if `tree` prints @e15 and a later `find` renumbered from
    /// 1, `press @e15` would act on a node the reader never saw. Measured the hard way on
    /// macOS 26: a checkbox press renumbered the next dump and @e19 became the ruler.
    var counters: [String: Int]

    init(schema: Int = AXIndex.schema, refs: [String: [AXIndexEntry]] = [:], counters: [String: Int] = [:]) {
        self.schema = schema
        self.refs = refs
        self.counters = counters
    }

    /// Tolerate an index written by the previous build (no `counters`): a stale cache must not
    /// turn every ref into an error.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? AXIndex.schema
        refs = try container.decodeIfPresent([String: [AXIndexEntry]].self, forKey: .refs) ?? [:]
        counters = try container.decodeIfPresent([String: Int].self, forKey: .counters) ?? [:]
    }

    static func counterKey(bundle: String, window: Int) -> String {
        "\(bundle.isEmpty ? "pid" : bundle)|\(window)"
    }

    /// Where the next dump of this window starts numbering.
    func nextRef(bundle: String, window: Int) -> Int {
        (counters[AXIndex.counterKey(bundle: bundle, window: window)] ?? 0) + 1
    }

    /// Merge a new dump. Refs are monotonic per window, so a new dump cannot reuse an old
    /// number; the dedupe below only matters when a counter was reset (its snapshots pruned).
    /// A ref the new dump does not reprint keeps pointing at the dump that printed it.
    mutating func record(_ snapshot: AXSnapshot) {
        let entry = AXIndexEntry(generation: snapshot.generation, app: snapshot.app,
                                 bundle: snapshot.bundle, pid: snapshot.pid,
                                 window: snapshot.windowIndex, title: snapshot.windowTitle,
                                 at: snapshot.createdAt)
        for node in snapshot.nodes {
            var list = refs[node.ref] ?? []
            list.removeAll { $0.bundle == entry.bundle && $0.window == entry.window }
            list.append(entry)
            refs[node.ref] = list
        }
    }

    mutating func noteRefs(bundle: String, window: Int, upTo index: Int) {
        let key = AXIndex.counterKey(bundle: bundle, window: window)
        counters[key] = max(counters[key] ?? 0, index)
    }

    /// Candidates for a ref, newest first, optionally narrowed to one app.
    func candidates(for ref: AXRef, app: String? = nil) -> [AXIndexEntry] {
        let all = (refs[ref.description] ?? []).sorted { $0.at > $1.at }
        guard let app, !app.isEmpty else { return all }
        let lowered = app.lowercased()
        return all.filter {
            $0.bundle.lowercased() == lowered || $0.app.lowercased() == lowered
                || $0.app.lowercased().contains(lowered)
        }
    }
}

/// What `index.json` looked like when it was read, cheap enough to check again before writing.
///
/// `saveIndex` writes through a rename, so a rewritten index always carries a new inode:
/// inode + size + mtime is then a reliable "nobody has written this since the read" (#102 --
/// one dump should read the index once, which only holds if the write can prove the read is
/// current).
struct AXIndexStamp: Equatable {
    var inode: UInt64
    var size: Int
    var modified: Date?
}

/// The index plus the stamp it was read at. A writer reuses `index` only while the file still
/// carries `stamp`; anything else means another process got there first and has to be merged.
final class AXStoreActivity {
    var indexReads = 0
    var indexWrites = 0
    /// `load(generation:)`: what `prune` used to do once per live dump. A dump must not.
    var snapshotReads = 0
}
struct AXIndexLoad {
    var index: AXIndex
    var stamp: AXIndexStamp
}

extension AXIndex {
    /// Keep the newest `keep` dumps of one window, in memory, and return the generations whose
    /// snapshot files the caller should delete.
    ///
    /// Every entry `record` makes for a dump carries that dump's `createdAt`, so the ordering the
    /// old path got by decoding each live snapshot is already here; `existing` is then a bare "is
    /// there a file". A generation whose file is gone is left in the index rather than collected
    /// -- its file is missing, so there is nothing to delete, and dropping the entry would only
    /// throw away a ref that `--snapshot` can still resolve.
    mutating func prune(bundle: String, window: Int, keep: Int,
                        existing: (String) -> Bool) -> [String] {
        var dates: [String: Date] = [:]
        for list in refs.values {
            for entry in list where entry.bundle == bundle && entry.window == window {
                dates[entry.generation] = entry.at
            }
        }
        // Newest first; ties fall back to the id, so one index prunes the same way twice.
        let ordered = dates.filter { existing($0.key) }
            .sorted { $0.value == $1.value ? $0.key > $1.key : $0.value > $1.value }
        let doomed = ordered.dropFirst(keep).map { $0.key }
        // Dropping entries is the only thing that can empty a ref list or un-reference a window,
        // so the whole-dictionary passes only run when there is something to drop: on the common
        // path (dumps 1-16 of a window) this walks 400 entries, not every ref in the index.
        if !doomed.isEmpty {
            let dropping = Set(doomed)
            refs = refs.mapValues { $0.filter { !dropping.contains($0.generation) } }
            refs = refs.filter { !$0.value.isEmpty }
            let key = AXIndex.counterKey(bundle: bundle, window: window)
            let stillReferenced = refs.values.contains { list in
                list.contains { $0.bundle == bundle && $0.window == window }
            }
            if !stillReferenced { counters[key] = nil }
        }
        return doomed
    }
}

/// Where snapshots live and how they are read and written. No daemon: a directory of JSON files
/// that the next process opens, with the index as the only thing that has to stay consistent.
struct AXRefStore {
    var directory: URL
    /// When someone is counting, the store's file traffic lands here. `nil` for a real command:
    /// the cost #102 is about is reads and writes, and a wall clock cannot tell a second read
    /// from a slower one -- the same reason #104 put the AX reads behind `AXAccess`.
    var activity: AXStoreActivity?

    init(directory: URL? = nil, activity: AXStoreActivity? = nil) {
        self.directory = directory ?? AXRefStore.defaultDirectory()
        self.activity = activity
    }

    /// `KRD_AX_STATE` exists so tests (and a user with a read-only $TMPDIR) can move the state
    /// somewhere else; `NSTemporaryDirectory()` is per-user on macOS and survives between
    /// invocations, which is all a ref needs.
    static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["KRD_AX_STATE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("krd-ax", isDirectory: true)
    }

    private var snapshotsDirectory: URL { directory.appendingPathComponent("snapshots", isDirectory: true) }
    private var indexPath: URL { directory.appendingPathComponent("index.json") }
    /// How many dumps of one window are kept.
    ///
    /// Every `tree`/`find` writes one, and refs are monotonic, so this is really "how far back
    /// can a ref reach". Measured the hard way: at 4, a `tree` → `find` → `tree` → `press`
    /// sequence pruned the dump the agent was still holding a ref from.
    ///
    /// What those 16 cost is larger than it reads: a 400-node dump (`--max 400`, the default) is
    /// ~120 KB of snapshot, so 16 of them are ~2 MB, and the `refs` map keyed by their refs is
    /// ~1 MB of `index.json`. That is why one dump reads that file once and writes it once
    /// (issue #102) instead of reading it twice and writing it twice.
    static let keepPerWindow = 16

    func snapshotPath(generation: String) -> URL {
        snapshotsDirectory.appendingPathComponent("\(generation).json")
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
    }

    /// What `index.json` is stamped with right now. A missing (or unstatable) index stamps as
    /// absent, which never compares equal to a read one, so the next writer re-reads.
    func indexStamp() -> AXIndexStamp {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: indexPath.path) else {
            return AXIndexStamp(inode: 0, size: -1, modified: nil)
        }
        return AXIndexStamp(inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                            size: (attributes[.size] as? NSNumber)?.intValue ?? -1,
                            modified: attributes[.modificationDate] as? Date)
    }

    /// Read the index and the stamp it was read at. The stamp is taken first: a write that lands
    /// in between then makes it stale, which costs a re-read instead of a lost entry.
    func readIndex() -> AXIndexLoad {
        activity?.indexReads += 1
        let stamp = indexStamp()
        guard let data = try? Data(contentsOf: indexPath),
              let index = try? JSONDecoder().decode(AXIndex.self, from: data) else {
            return AXIndexLoad(index: AXIndex(), stamp: stamp)
        }
        return AXIndexLoad(index: index, stamp: stamp)
    }

    func loadIndex() -> AXIndex {
        readIndex().index
    }

    func saveIndex(_ index: AXIndex) throws {
        activity?.indexWrites += 1
        try ensureDirectories()
        // Default Date coding (seconds since 2001 as a Double): exact round-trip, and a
        // snapshot written twice in the same second still compares and orders correctly.
        try JSONEncoder().encode(index).write(to: indexPath, options: .atomic)
    }

    /// Persist a dump and point the index at it: one index read, one index write.
    ///
    /// `loaded` is the read `beginDump` already did. It is reused only while `index.json` still
    /// carries the same stamp; a write another process made in between is merged, never
    /// overwritten, because a dropped entry is a ref that stops resolving.
    ///
    /// That covers entries, not numbering: two dumps started before either saved still hand out
    /// the same ref numbers (the pre-change store did too -- `AXStep.matches` is what stands
    /// between a reused number and acting on the wrong node).
    func save(_ snapshot: AXSnapshot, reusing loaded: AXIndexLoad? = nil) throws {
        try ensureDirectories()
        try JSONEncoder().encode(snapshot)
            .write(to: snapshotPath(generation: snapshot.generation), options: .atomic)
        // A filesystem that will not give the file an inode cannot prove a read is current, so
        // that read is never reused: a re-read costs time, a lost entry costs a ref.
        let load = loaded.flatMap { $0.stamp.inode != 0 && indexStamp() == $0.stamp ? $0 : nil }
            ?? readIndex()
        var index = load.index
        index.record(snapshot)
        if let highest = snapshot.nodes.compactMap({ AXRef($0.ref)?.index }).max() {
            index.noteRefs(bundle: snapshot.bundle, window: snapshot.windowIndex, upTo: highest)
        }
        // Prune on the copy already in hand: the old path read the index again here and then
        // wrote it a second time.
        let doomed = index.prune(bundle: snapshot.bundle, window: snapshot.windowIndex,
                                 keep: AXRefStore.keepPerWindow, existing: snapshotExists)
        // Write the index before unlinking: the index no longer names these generations, so a
        // reader never asks for a file that is about to go -- and a write that fails leaves the
        // old, still-valid index alone instead of pointing at files this call deleted.
        try saveIndex(index)
        for generation in doomed {
            try? FileManager.default.removeItem(at: snapshotPath(generation: generation))
        }
    }

    private func snapshotExists(_ generation: String) -> Bool {
        FileManager.default.fileExists(atPath: snapshotPath(generation: generation).path)
    }

    /// One dump's index read, taken before the walk so the numbers it hands out and the entry it
    /// writes at the end come from one view of the index. `tree`/`find` used to read the index for
    /// the start number, read and write it in `save`, then read and write it once more in `prune`
    /// (#102).
    struct Dump {
        var store: AXRefStore
        var loaded: AXIndexLoad
        var refStart: Int

        func save(_ snapshot: AXSnapshot) throws {
            try store.save(snapshot, reusing: loaded)
        }
    }

    /// Start a dump of one window: one index read, and the first ref number to print.
    func beginDump(bundle: String, window: Int) -> Dump {
        let loaded = readIndex()
        return Dump(store: self, loaded: loaded,
                    refStart: loaded.index.nextRef(bundle: bundle, window: window))
    }

    /// The first ref number a new dump of this window should use.
    func nextRef(bundle: String, window: Int) -> Int {
        loadIndex().nextRef(bundle: bundle, window: window)
    }

    func load(generation: String) -> AXSnapshot? {
        activity?.snapshotReads += 1
        guard let data = try? Data(contentsOf: snapshotPath(generation: generation)) else { return nil }
        return try? JSONDecoder().decode(AXSnapshot.self, from: data)
    }

    /// Load by generation id or by path, which is what `--snapshot` accepts.
    func load(reference: String) -> AXSnapshot? {
        if reference.contains("/") || reference.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: reference)) else { return nil }
            return try? JSONDecoder().decode(AXSnapshot.self, from: data)
        }
        return load(generation: reference)
    }

    /// Keep the newest `keepPerWindow` dumps of one window and delete the rest.
    ///
    /// The write path does this in memory on the index it already has (`save`); this is the same
    /// thing for a caller (or a test) holding nothing, and it still swallows a write error -- a
    /// cache that cannot be tidied is not a failed command.
    func prune(bundle: String, window: Int, keep: Int = AXRefStore.keepPerWindow) {
        var index = loadIndex()
        let doomed = index.prune(bundle: bundle, window: window, keep: keep, existing: snapshotExists)
        try? saveIndex(index)
        for generation in doomed {
            try? FileManager.default.removeItem(at: snapshotPath(generation: generation))
        }
    }
}
